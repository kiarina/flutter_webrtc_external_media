import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc/src/native/media_stream_track_impl.dart';
import 'package:flutter_webrtc_external_media/flutter_webrtc_external_media.dart';

class FakeSource implements RemoteAudioSource {
  final controller = StreamController<RTCRemoteAudioPcm>.broadcast();
  int detaches = 0;
  @override
  Stream<RTCRemoteAudioPcm> get pcm => controller.stream;
  @override
  Future<Map<dynamic, dynamic>> stats() async => {'deliveredFrames': 1};
  @override
  Future<void> detach() async => detaches++;
}

RTCRemoteAudioPcm frames(List<int> samples, int rate, int channels) {
  final data = Int16List.fromList(samples).buffer.asUint8List();
  return RTCRemoteAudioPcm(data, rate, channels, samples.length ~/ channels);
}

Int16List pcm(Uint8List bytes) => bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);

void main() {
  late FakeSource source;
  late ReceivedAudio audio;
  final track = MediaStreamTrackNative('a', 'a', 'audio', true, 'pc');
  setUp(() async {
    source = FakeSource();
    audio = await ReceivedAudio.attach(track, source: source);
  });

  test('48 kHz mono passes through unchanged', () async {
    final out = audio.pcm.first;
    source.controller.add(frames([1, -2, 3, 32767, -32768], 48000, 1));
    expect(pcm(await out), [1, -2, 3, 32767, -32768]);
    expect(audio.outputSamples, 5);
  });

  test('stereo is down-mixed by averaging', () async {
    final out = audio.pcm.first;
    source.controller.add(frames([100, 300, -100, -300], 48000, 2));
    expect(pcm(await out), [200, -200]);
  });

  test('other rates are resampled to 48 kHz with continuous phase', () async {
    final chunks = <Int16List>[];
    final sub = audio.pcm.listen((b) => chunks.add(pcm(b)));
    for (var i = 0; i < 10; i++) {
      source.controller.add(frames(List.filled(160, 1000), 16000, 1));  // 10 ms
    }
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    final total = chunks.fold<int>(0, (n, c) => n + c.length);
    expect(total, closeTo(4800, 3));  // 100 ms at 48 kHz
    expect(chunks.skip(1).expand((c) => c).every((v) => v == 1000), isTrue);
  });

  test('stats include native counters; detach is idempotent', () async {
    expect((await audio.stats())['native'], {'deliveredFrames': 1});
    await audio.detach();
    await audio.detach();
    expect(source.detaches, 1);
    expect((await audio.stats())['native'], isNull);
  });
}
