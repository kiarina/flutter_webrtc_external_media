import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Injection only. Capture devices, processing and peer negotiation belong to
/// the caller. Implement this interface to test without a native SDK/device.
abstract interface class ExternalMediaTransport {
  MediaStream get stream;
  bool get hasRenderReference;
  String get videoTimestampSource;
  Stream<Map<dynamic, dynamic>> get renderReference;
  Future<void> pushAudio(Uint8List pcm);
  Future<void> pushVideo(
      Uint8List bgra, int width, int height, int timestampUs);
  Future<void> flush();
  Future<Map<dynamic, dynamic>> stats();
  Future<void> dispose();
}

class ForkExternalMediaTransport implements ExternalMediaTransport {
  ForkExternalMediaTransport._(this._source);
  final RTCExternalMediaSource _source;
  static Future<ForkExternalMediaTransport> create(
          {bool audio = true, bool video = true}) async =>
      ForkExternalMediaTransport._(await RTCExternalMediaSource.create(
          audio: audio, video: video, audioProcessing: false));
  @override
  MediaStream get stream => _source.stream;
  @override
  bool get hasRenderReference => _source.hasRenderReference;
  @override
  String get videoTimestampSource => _source.videoTimestampSource;
  @override
  Stream<Map<dynamic, dynamic>> get renderReference => _source.renderReference;
  @override
  Future<void> pushAudio(Uint8List pcm) => _source.pushAudio(pcm);
  @override
  Future<void> pushVideo(
          Uint8List bgra, int width, int height, int timestampUs) =>
      _source.pushVideo(bgra, width, height, timestampUs);
  @override
  Future<void> flush() => _source.flush();
  @override
  Future<Map<dynamic, dynamic>> stats() => _source.stats();
  @override
  Future<void> dispose() => _source.dispose();
}
