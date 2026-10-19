import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc_external_media/flutter_webrtc_external_media.dart';

class FakeStream implements MediaStream {
  @override
  String get id => 'test';
  @override
  List<MediaStreamTrack> getTracks() => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTransport implements ExternalMediaTransport {
  @override
  final stream = FakeStream();
  final audio = <Uint8List>[], video = <Uint8List>[];
  Completer<void>? hold, holdFlush;
  bool fail = false, failFlush = false;
  int flushed = 0, disposed = 0;
  @override
  bool get hasRenderReference => false;
  @override
  String get videoTimestampSource => 'arrival';
  @override
  Stream<Map<dynamic, dynamic>> get renderReference =>
      throw UnsupportedError('reference');
  @override
  Future<void> pushAudio(Uint8List pcm) async {
    audio.add(Uint8List.fromList(pcm));
    await hold?.future;
    if (fail) throw StateError('native rejected');
  }

  @override
  Future<void> pushVideo(
      Uint8List bgra, int width, int height, int time) async {
    video.add(Uint8List.fromList(bgra));
  }

  @override
  Future<void> flush() async {
    flushed++;
    await holdFlush?.future;
    if (failFlush) throw StateError("native flush rejected");
  }

  @override
  Future<Map<dynamic, dynamic>> stats() async => {'audio': audio.length};
  @override
  Future<void> dispose() async {
    disposed++;
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);
void main() {
  test('repeated enabled state preserves partial audio and does not flush',
      () async {
    final t = FakeTransport();
    final b = await ExternalMediaBridge.create(transport: t);
    await b.setSending(true);
    await b.addAudio(Uint8List(400)..fillRange(0, 400, 7));
    await b.setSending(true);
    await b.addAudio(Uint8List(560));
    expect(t.flushed, 1);
    expect(t.audio, hasLength(1));
    expect(t.audio.single.take(400), everyElement(7));
    await b.dispose();
  });
  test('repeated enabled state preserves queued audio and video', () async {
    final t = FakeTransport()..hold = Completer<void>();
    final b = await ExternalMediaBridge.create(transport: t);
    await b.setSending(true);
    final a = b.addAudio(Uint8List(960));
    await tick();
    final queued = b.addAudio(Uint8List(960));
    final video = b.addVideo(Uint8List(4), width: 1, height: 1, timestampUs: 1);
    final same = b.setSending(true);
    t.hold!.complete();
    await a;
    await same;
    expect(await queued, true);
    expect(await video, true);
    expect(t.flushed, 1);
    expect(t.audio, hasLength(2));
    expect(t.video, hasLength(1));
    await b.dispose();
  });
  test('duplicate pending requests coalesce without losing opposite request',
      () async {
    final t = FakeTransport()..holdFlush = Completer<void>();
    final b = await ExternalMediaBridge.create(transport: t);
    final on = b.setSending(true);
    await tick();
    final sameOn = b.setSending(true);
    final off = b.setSending(false), sameOff = b.setSending(false);
    t.holdFlush!.complete();
    await Future.wait([on, sameOn, off, sameOff]);
    expect(b.sending, false);
    expect(t.flushed, 2);
    await b.dispose();
  });
  test('failed gate flush faults the source and cannot resume stale media',
      () async {
    final t = FakeTransport(),
        bridge = await ExternalMediaBridge.create(transport: FakeTransport());
    await bridge.dispose();
    final b = await ExternalMediaBridge.create(transport: t);
    await b.setSending(true);
    t.failFlush = true;
    await expectLater(b.setSending(false), throwsStateError);
    expect(b.sending, false);
    expect(() => b.setSending(true), throwsStateError);
    await expectLater(b.addAudio(Uint8List(960)), throwsStateError);
    await b.dispose();
    expect(t.disposed, 1);
  });
  test('gated data is discarded and never replayed on resume', () async {
    final t = FakeTransport(),
        b = await ExternalMediaBridge.create(transport: FakeTransport());
    await b.dispose();
    final bridge = await ExternalMediaBridge.create(transport: t);
    expect(await bridge.addAudio(Uint8List(960)), isFalse);
    await bridge.setSending(true);
    expect(t.audio, isEmpty);
    await bridge.dispose();
    expect(t.disposed, 1);
  });
  test('packetizes and owns bytes, including partial chunks', () async {
    final t = FakeTransport(),
        b = await ExternalMediaBridge.create(transport: t);
    await b.setSending(true);
    final first = Uint8List(400)..fillRange(0, 400, 7);
    expect(await b.addAudio(first), isTrue);
    first.fillRange(0, 400, 99);
    expect(await b.addAudio(Uint8List(560)), isTrue);
    expect(t.audio.single.take(400), everyElement(7));
    await b.dispose();
  });
  test('audio queue is bounded and dropping is explicit', () async {
    final t = FakeTransport()..hold = Completer<void>(),
        b = await ExternalMediaBridge.create(transport: FakeTransport());
    await b.dispose();
    final bridge =
        await ExternalMediaBridge.create(transport: t, maxQueuedAudioFrames: 2);
    await bridge.setSending(true);
    final first = bridge.addAudio(Uint8List(960));
    await tick();
    final dropped = bridge.addAudio(Uint8List(960)),
        next = bridge.addAudio(Uint8List(960)),
        last = bridge.addAudio(Uint8List(960));
    expect(await dropped, isFalse);
    expect((await bridge.stats())['queuedAudioFrames'], 2);
    t.hold!.complete();
    expect(await first, isTrue);
    expect(await next, isTrue);
    expect(await last, isTrue);
    expect(bridge.audioFramesDropped, 1);
    await bridge.dispose();
  });
  test('stop is a barrier and clears partial bytes', () async {
    final t = FakeTransport()..hold = Completer<void>(),
        b = await ExternalMediaBridge.create(transport: t);
    await b.setSending(true);
    final inFlight = b.addAudio(Uint8List(960));
    await tick();
    final queued = b.addAudio(Uint8List(960));
    final stopped = b.setSending(false);
    expect(await queued, isFalse);
    expect(await b.addAudio(Uint8List(960)), isFalse);
    t.hold!.complete();
    await inFlight;
    await stopped;
    expect(t.audio, hasLength(1));
    await b.setSending(true);
    await b.addAudio(Uint8List(400));
    await b.setSending(false);
    await b.setSending(true);
    await b.addAudio(Uint8List(560));
    expect(t.audio, hasLength(1));
    await b.dispose();
  });
  test('rapid enable/disable cannot re-enable a stale generation', () async {
    final t = FakeTransport(),
        b = await ExternalMediaBridge.create(transport: t);
    final a = b.setSending(true), z = b.setSending(false);
    await Future.wait([a, z]);
    expect(b.sending, isFalse);
    await b.dispose();
  });
  test('packs row padding and converts RGBA to BGRA', () async {
    final t = FakeTransport(),
        b = await ExternalMediaBridge.create(transport: t);
    await b.setSending(true);
    await b.addVideo(
        Uint8List.fromList(
            [1, 2, 3, 255, 99, 99, 99, 99, 4, 5, 6, 255, 99, 99, 99, 99]),
        width: 1,
        height: 2,
        timestampUs: 1,
        bytesPerRow: 8,
        format: ExternalPixelFormat.rgba8888);
    expect(t.video.single, [3, 2, 1, 255, 6, 5, 4, 255]);
    await b.dispose();
  });
  test('latest queued video wins while native is busy', () async {
    final t = FakeTransport()..hold = Completer<void>(),
        b = await ExternalMediaBridge.create(transport: t);
    await b.setSending(true);
    final audio = b.addAudio(Uint8List(960));
    await tick();
    final old = b.addVideo(Uint8List(4), width: 1, height: 1, timestampUs: 1);
    final latest = b.addVideo(Uint8List.fromList([4, 5, 6, 255]),
        width: 1, height: 1, timestampUs: 2);
    expect(await old, isFalse);
    t.hold!.complete();
    await audio;
    expect(await latest, isTrue);
    expect(t.video.single, [4, 5, 6, 255]);
    await b.dispose();
  });
  test('validates formats and rejects non-monotonic video', () async {
    final b = await ExternalMediaBridge.create(transport: FakeTransport());
    await b.setSending(true);
    await expectLater(b.addAudio(Uint8List(3)), throwsArgumentError);
    await expectLater(
        b.addAudio(Uint8List(960), sampleRate: 16000), throwsArgumentError);
    await b.addVideo(Uint8List(4), width: 1, height: 1, timestampUs: 10);
    await expectLater(
        b.addVideo(Uint8List(4), width: 1, height: 1, timestampUs: 9),
        throwsArgumentError);
    await b.dispose();
  });
  test('native failure faults the source and still disposes once', () async {
    final t = FakeTransport()..fail = true,
        b = await ExternalMediaBridge.create(transport: t);
    final errors = <Object>[];
    final sub = b.errors.listen(errors.add);
    await b.setSending(true);
    await expectLater(b.addAudio(Uint8List(960)), throwsStateError);
    await tick();
    expect(errors, hasLength(1));
    await expectLater(b.addAudio(Uint8List(960)), throwsStateError);
    await Future.wait([b.dispose(), b.dispose()]);
    expect(t.disposed, 1);
    await sub.cancel();
  });
}
