import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc_external_media/flutter_webrtc_external_media.dart';

/// Synthetic local RTP check. No physical capture or provider/network service.
Future<Map<String, dynamic>> loopback() async {
  ExternalMediaBridge? bridge;
  RTCPeerConnection? sender, receiver;
  StreamSubscription<Map<dynamic, dynamic>>? reference;
  var renderReferenceBytes = 0;
  final candidatesA = <RTCIceCandidate>[], candidatesB = <RTCIceCandidate>[];
  var readyA = false, readyB = false;
  final candidateErrors = <String>[];
  Future<void> candidate(RTCPeerConnection target, RTCIceCandidate c) async {
    try {
      await target.addCandidate(c);
    } catch (e) {
      candidateErrors.add('$e');
    }
  }

  Future<List<Map<String, dynamic>>> inbound(RTCPeerConnection pc) async =>
      (await pc.getStats())
          .where((s) => s.type == 'inbound-rtp')
          .map((s) => <String, dynamic>{'id': s.id, ...s.values})
          .toList();
  try {
    bridge = await ExternalMediaBridge.create();
    if (bridge.hasRenderReference) {
      reference = bridge.renderReference.listen((event) {
        renderReferenceBytes += (event['bytes'] as Uint8List).length;
      });
    }
    sender = await createPeerConnection({'iceServers': []});
    receiver = await createPeerConnection({'iceServers': []});
    final a = sender, b = receiver;
    if (Platform.isWindows) {
      final match = Platform.environment['EXTERNAL_MEDIA_OUTPUT_MATCH'];
      if (match != null) {
        final outputs = await Helper.audiooutputs;
        final selected = outputs.firstWhere((d) => d.label.contains(match));
        // Explicit output selection after factory/peer creation: do not assume
        // the Windows default device supports the SDK shared-mode format.
        await Helper.selectAudioOutput(selected.deviceId);
      }
    }

    a.onIceCandidate = (c) {
      if (readyB) {
        unawaited(candidate(b, c));
      } else {
        candidatesB.add(c);
      }
    };
    b.onIceCandidate = (c) {
      if (readyA) {
        unawaited(candidate(a, c));
      } else {
        candidatesA.add(c);
      }
    };
    for (final track in bridge.stream.getTracks()) {
      await a.addTrack(track, bridge.stream);
    }
    final offer = await a.createOffer();
    await a.setLocalDescription(offer);
    await b.setRemoteDescription(offer);
    readyB = true;
    for (final c in candidatesB) {
      await candidate(b, c);
    }
    final answer = await b.createAnswer();
    await b.setLocalDescription(answer);
    await a.setRemoteDescription(answer);
    readyA = true;
    for (final c in candidatesA) {
      await candidate(a, c);
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    final image = Uint8List(160 * 120 * 4);
    for (var k = 0; k < image.length; k += 4) {
      image[k + 1] = 100;
      image[k + 3] = 255;
    }
    var timestamp = 0;
    Future<void> send() async {
      await bridge!.setSending(true);
      for (var i = 0; i < 150; i++) {
        await bridge!.addAudio(Uint8List(960));
        if (i % 10 == 0) {
          await bridge!.addVideo(image,
              width: 160, height: 120, timestampUs: timestamp += 100000);
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    await send();
    final first = await inbound(b);
    await bridge.setSending(false);
    final gated = await bridge.addAudio(Uint8List(960));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await send();
    final second = await inbound(b);
    await bridge.setSending(false);
    final native = await bridge.stats();
    int count(List<Map<String, dynamic>> rows, String field) =>
        rows.fold(0, (sum, row) => sum + ((row[field] as num?)?.toInt() ?? 0));
    final packets1 = count(first, 'packetsReceived'),
        packets2 = count(second, 'packetsReceived');
    final frames1 = count(first, 'framesDecoded'),
        frames2 = count(second, 'framesDecoded');
    if (packets1 < 5 ||
        packets2 <= packets1 ||
        frames1 < 1 ||
        frames2 <= frames1 ||
        gated ||
        candidateErrors.isNotEmpty) {
      throw StateError(
          'RTP check failed: packets=$packets1/$packets2 frames=$frames1/$frames2 gated=$gated ICE=$candidateErrors');
    }
    return {
      'renderReferenceBytes': renderReferenceBytes,
      'first': first,
      'second': second,
      'native': native,
      'gatedInputAccepted': gated,
      'audioFramesSubmitted': bridge.audioFramesSubmitted,
      'videoFramesSubmitted': bridge.videoFramesSubmitted
    };
  } finally {
    await reference?.cancel();
    await sender?.close();
    await receiver?.close();
    await bridge?.dispose();
    await sender?.dispose();
    await receiver?.dispose();
  }
}
