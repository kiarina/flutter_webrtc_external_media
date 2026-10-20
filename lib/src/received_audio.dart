import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Injection only: what [ReceivedAudio] needs from the fork's remote audio tap.
abstract interface class RemoteAudioSource {
  Stream<RTCRemoteAudioPcm> get pcm;
  Future<Map<dynamic, dynamic>> stats();
  Future<void> detach();
}

class ForkRemoteAudioSource implements RemoteAudioSource {
  ForkRemoteAudioSource._(this._tap);
  final RTCRemoteAudioTap _tap;
  static Future<ForkRemoteAudioSource> attach(MediaStreamTrack track,
          {bool silenceNativePlayout = true}) async =>
      ForkRemoteAudioSource._(await RTCRemoteAudioTap.attach(track,
          silenceNativePlayout: silenceNativePlayout));
  @override
  Stream<RTCRemoteAudioPcm> get pcm => _tap.pcm;
  @override
  Future<Map<dynamic, dynamic>> stats() => _tap.stats();
  @override
  Future<void> detach() => _tap.detach();
}

/// The decoded voice of one remote audio track as 48 kHz mono PCM16, for an
/// application that processes and plays received audio itself (voice
/// conversion, its own mixer and echo cancellation).
///
/// It only converts and forwards: playback, mixing and AEC stay with the
/// caller, and whatever the caller plays is its own render reference. By
/// default the native playout of the track is silenced while decoding goes on.
class ReceivedAudio {
  ReceivedAudio._(this._source) {
    _subscription = _source.pcm.listen(_onPcm, onError: _controller.addError);
  }

  final RemoteAudioSource _source;
  late final StreamSubscription<RTCRemoteAudioPcm> _subscription;
  final _controller = StreamController<Uint8List>.broadcast();
  double _position = 0; // resampler phase in input samples
  int _last = 0;
  int _rate = 0;
  bool _detached = false;
  int inputFrames = 0, outputSamples = 0, events = 0, formatChanges = 0;

  static Future<ReceivedAudio> attach(MediaStreamTrack track,
          {bool silenceNativePlayout = true, RemoteAudioSource? source}) async =>
      ReceivedAudio._(source ??
          await ForkRemoteAudioSource.attach(track,
              silenceNativePlayout: silenceNativePlayout));

  /// Little-endian PCM16, mono, 48 kHz, in the chunks the tap delivered.
  Stream<Uint8List> get pcm => _controller.stream;

  void _onPcm(RTCRemoteAudioPcm p) {
    if (_detached || p.channels <= 0 || p.sampleRate <= 0) return;
    events++;
    inputFrames += p.frames;
    if (p.sampleRate != _rate) {
      if (_rate != 0) formatChanges++;
      _rate = p.sampleRate;
      _position = 0;
    }
    final input = ByteData.sublistView(p.data);
    final frames = p.data.lengthInBytes ~/ (2 * p.channels);
    int mono(int f) {
      var sum = 0;
      for (var c = 0; c < p.channels; c++) {
        sum += input.getInt16((f * p.channels + c) * 2, Endian.little);
      }
      return sum ~/ p.channels;
    }

    final Int16List out;
    if (p.sampleRate == 48000) {
      out = Int16List(frames);
      for (var f = 0; f < frames; f++) {
        out[f] = mono(f);
      }
    } else {
      // Linear interpolation between the previous and current input sample.
      final step = p.sampleRate / 48000;
      final samples = <int>[];
      for (var f = 0; f < frames; f++) {
        final current = mono(f);
        while (_position <= 1) {
          samples.add((_last + (current - _last) * _position).round());
          _position += step;
        }
        _position -= 1;
        _last = current;
      }
      out = Int16List.fromList(samples);
    }
    outputSamples += out.length;
    _controller.add(out.buffer.asUint8List());
  }

  Future<Map<String, Object?>> stats() async => {
        'native': _detached ? null : await _source.stats(),
        'inputFrames': inputFrames,
        'outputSamples': outputSamples,
        'events': events,
        'formatChanges': formatChanges,
      };

  /// Stops forwarding and restores the native playout. Idempotent.
  Future<void> detach() async {
    if (_detached) return;
    _detached = true;
    await _subscription.cancel();
    await _source.detach();
    await _controller.close();
  }
}
