import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'transport.dart';

enum ExternalPixelFormat { bgra8888, rgba8888 }

class _AudioPacket {
  _AudioPacket(this.bytes, this.generation);
  final Uint8List bytes;
  final int generation;
  final done = Completer<bool>();
}

class _VideoPacket {
  _VideoPacket(
      this.bytes, this.width, this.height, this.timestamp, this.generation);
  final Uint8List bytes;
  final int width, height, timestamp, generation;
  final done = Completer<bool>();
}

/// A source-wide gate for one external stream, not a per-peer privacy control.
/// Do not share this stream between independently gated conversations. Capture
/// and processing stay with the caller and can continue while this gate is off.
/// Calls preserve PCM ordering, but do not recover time lost by a stalled caller.
class ExternalMediaBridge {
  ExternalMediaBridge._(
      this._transport, this.maxQueuedAudioFrames, this.timeout);
  final ExternalMediaTransport _transport;
  final int maxQueuedAudioFrames;
  final Duration timeout;
  final _audio = Queue<_AudioPacket>();
  final _errors = StreamController<Object>.broadcast();
  Uint8List _remainder = Uint8List(0);
  _VideoPacket? _video;
  Future<void>? _drainFuture, _disposeFuture;
  Future<void> _control = Future.value();
  bool _sending = false, _disposed = false, _faulted = false;
  int _generation = 0, _lastTimestamp = -1;
  int audioFramesSubmitted = 0,
      audioFramesDropped = 0,
      videoFramesSubmitted = 0,
      videoFramesDropped = 0,
      bytesDiscardedWhileGated = 0;

  static Future<ExternalMediaBridge> create(
      {bool audio = true,
      bool video = true,
      int maxQueuedAudioFrames = 10,
      Duration timeout = const Duration(seconds: 5),
      ExternalMediaTransport? transport}) async {
    if (maxQueuedAudioFrames < 1 ||
        maxQueuedAudioFrames > 100 ||
        timeout <= Duration.zero) {
      throw ArgumentError('Queue must be1..100 frames and timeout positive');
    }
    if (!audio && !video) {
      throw ArgumentError('At least one track is required');
    }
    final bridge = ExternalMediaBridge._(
        transport ??
            await ForkExternalMediaTransport.create(audio: audio, video: video),
        maxQueuedAudioFrames,
        timeout);
    for (final track in bridge.stream.getTracks()) {
      track.enabled = false;
    }
    return bridge;
  }

  MediaStream get stream => _transport.stream;
  bool get sending => _sending && !_disposed && !_faulted;
  bool get hasRenderReference => _transport.hasRenderReference;
  String get videoTimestampSource => _transport.videoTimestampSource;
  Stream<Map<dynamic, dynamic>> get renderReference =>
      _transport.renderReference;
  Stream<Object> get errors => _errors.stream;
  void _check() {
    if (_disposed) throw StateError('Bridge disposed');
    if (_faulted) {
      throw StateError('Bridge faulted; close the peer/source before retrying');
    }
  }

  void _clear() {
    for (final p in _audio) {
      if (!p.done.isCompleted) p.done.complete(false);
      audioFramesDropped++;
    }
    _audio.clear();
    _remainder = Uint8List(0);
    final v = _video;
    _video = null;
    if (v != null) {
      videoFramesDropped++;
      if (!v.done.isCompleted) v.done.complete(false);
    }
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _control.catchError((Object _) {}).then((_) => action());
    _control = next;
    return next;
  }

  /// False immediately rejects new data. The returned barrier drains any already
  /// in-flight native call before flushing and muting tracks. No queued old PCM
  /// survives a stop/start. Detach peer senders as well when ending a session.
  Future<void> setSending(bool enabled) {
    _check();
    _sending = false;
    final generation = ++_generation;
    _clear();
    return _serial(() async {
      _check();
      try {
        await _drainFuture;
        _check();
        await _transport.flush().timeout(timeout);
        if (generation == _generation) {
          for (final track in stream.getTracks()) {
            track.enabled = enabled;
          }
          _sending = enabled;
        }
      } catch (error) {
        if (!_faulted) {
          _faulted = true;
          _sending = false;
          _generation++;
          _clear();
          _errors.add(error);
        }
        rethrow;
      }
    });
  }

  /// Processed little-endian PCM16, mono48k. Resample/process upstream. Arbitrary
  /// even-sized chunks are packetized into480samples; at most1second per call.
  /// Returns false for gated/dropped frames. True means accepted; an incomplete
  /// chunk can remain buffered until the next call, not delivered yet.
  Future<bool> addAudio(Uint8List bytes,
      {int sampleRate = 48000, int channels = 1}) async {
    _check();
    if (sampleRate != 48000 ||
        channels != 1 ||
        bytes.length.isOdd ||
        bytes.length > 96000) {
      throw ArgumentError('Expected mono48k PCM16, even bytes, <=1second');
    }
    if (!sending) {
      bytesDiscardedWhileGated += bytes.length;
      return false;
    }
    final data = Uint8List(_remainder.length + bytes.length)
      ..setAll(0, _remainder)
      ..setAll(_remainder.length, bytes);
    final done = <Future<bool>>[];
    var offset = 0;
    while (data.length - offset >= 960) {
      if (_audio.length >= maxQueuedAudioFrames) {
        final old = _audio.removeFirst();
        old.done.complete(false);
        audioFramesDropped++;
      }
      final packet = _AudioPacket(
          Uint8List.fromList(data.sublist(offset, offset + 960)), _generation);
      _audio.add(packet);
      done.add(packet.done.future);
      offset += 960;
    }
    _remainder = Uint8List.fromList(data.sublist(offset));
    _startDrain();
    if (done.isEmpty) return true;
    return (await Future.wait(done)).every((v) => v);
  }

  /// Caller timestamps must use one monotonic clock across device changes.
  /// Row padding is packed before submission; one pending video frame is kept.
  Future<bool> addVideo(Uint8List bytes,
      {required int width,
      required int height,
      required int timestampUs,
      int? bytesPerRow,
      ExternalPixelFormat format = ExternalPixelFormat.bgra8888}) async {
    _check();
    final stride = bytesPerRow ?? width * 4;
    if (width <= 0 ||
        height <= 0 ||
        width > 1920 ||
        height > 1080 ||
        stride < width * 4 ||
        stride > width * 4 + 4096 ||
        bytes.length != stride * height ||
        timestampUs < 0 ||
        timestampUs <= _lastTimestamp) {
      throw ArgumentError(
          'Expected packed/padded BGRA or RGBA <=1920x1080 and monotonic timestamp');
    }
    _lastTimestamp = timestampUs;
    if (!sending) {
      videoFramesDropped++;
      return false;
    }
    final packed = Uint8List(width * height * 4);
    for (var row = 0; row < height; row++) {
      packed.setRange(
          row * width * 4, (row + 1) * width * 4, bytes, row * stride);
    }
    if (format == ExternalPixelFormat.rgba8888) {
      for (var i = 0; i < packed.length; i += 4) {
        final r = packed[i];
        packed[i] = packed[i + 2];
        packed[i + 2] = r;
      }
    }
    final old = _video;
    if (old != null) {
      videoFramesDropped++;
      old.done.complete(false);
    }
    final packet =
        _VideoPacket(packed, width, height, timestampUs, _generation);
    _video = packet;
    _startDrain();
    return packet.done.future;
  }

  void _startDrain() {
    if (_drainFuture != null ||
        !sending ||
        (_audio.isEmpty && _video == null)) {
      return;
    }
    _drainFuture = _drain();
    // Avoid a synchronous completion race before the field is assigned.
    unawaited(_drainFuture!.whenComplete(() {
      _drainFuture = null;
      if (sending && (_audio.isNotEmpty || _video != null)) _startDrain();
    }));
  }

  Future<void> _drain() async {
    await Future<void>.value();
    while (sending && (_audio.isNotEmpty || _video != null)) {
      final audio = _audio.isEmpty ? null : _audio.removeFirst();
      final video = _video;
      _video = null;
      try {
        if (audio != null) {
          if (audio.generation != _generation) {
            audio.done.complete(false);
            audioFramesDropped++;
          } else {
            await _transport.pushAudio(audio.bytes).timeout(timeout);
            audioFramesSubmitted++;
            audio.done.complete(true);
          }
        }
        if (video != null) {
          if (video.generation != _generation || !sending) {
            video.done.complete(false);
            videoFramesDropped++;
          } else {
            await _transport
                .pushVideo(
                    video.bytes, video.width, video.height, video.timestamp)
                .timeout(timeout);
            videoFramesSubmitted++;
            video.done.complete(true);
          }
        }
      } catch (error) {
        if (audio != null && !audio.done.isCompleted) {
          audio.done.completeError(error);
        }
        if (video != null && !video.done.isCompleted) {
          video.done.completeError(error);
        }
        _faulted = true;
        _sending = false;
        _generation++;
        _clear();
        _errors.add(error);
        return;
      }
    }
  }

  Future<Map<String, Object?>> stats() async => {
        'sending': sending,
        'faulted': _faulted,
        'queuedAudioFrames': _audio.length,
        'maxQueuedAudioFrames': maxQueuedAudioFrames,
        'partialAudioBytes': _remainder.length,
        'audioFramesSubmitted': audioFramesSubmitted,
        'audioFramesDropped': audioFramesDropped,
        'videoFramesSubmitted': videoFramesSubmitted,
        'videoFramesDropped': videoFramesDropped,
        'bytesDiscardedWhileGated': bytesDiscardedWhileGated,
        if (!_disposed) 'native': await _transport.stats().timeout(timeout),
      };
  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    _sending = false;
    _generation++;
    _clear();
    try {
      await _control.catchError((Object _) {});
      await _drainFuture;
      for (final track in stream.getTracks()) {
        track.enabled = false;
      }
    } finally {
      try {
        await _transport.dispose().timeout(timeout);
      } finally {
        await _errors.close();
      }
    }
  }
}
