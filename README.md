# flutter_webrtc_external_media

Experimental caller-owned audio/video bridge for the kiarina Flutter WebRTC fork.
The application keeps camera and microphone capture running and submits processed
media only while sending is enabled. This package never opens a physical camera
or microphone. Capture plugins, processing/AEC and peer negotiation remain owned
by the application.

## Status and dependencies

The initial backend supports Windows x64 and macOS. Android, iOS and Web are
explicitly unsupported pending backend work. This is a development Git package,
not a pub.dev release. `pubspec.yaml` pins the compatible Flutter fork commit;
Windows also requires the matching SDK installed by that fork. Do not substitute
the official DLL or rely on a moving branch. See [integration](docs/integration.md)
for contracts and validation limits, and [physical desktop results](docs/physical-validation.md).

## Usage

```dart
final bridge = await ExternalMediaBridge.create();
// Negotiate bridge.stream tracks with the caller-owned RTCPeerConnection.
await bridge.setSending(true);
await bridge.addAudio(processedPcm16, sampleRate: 48000, channels: 1);
await bridge.addVideo(bgra, width: width, height: height,
    timestampUs: monotonicTimestampUs);
await bridge.setSending(false); // discard backlog, flush and mute
// Capture and processing continue while gated off.
// Detach/close peer senders before releasing the source.
await bridge.dispose();
```

Use one source for one group of senders with the same gate. This gate affects all
peers sharing the stream; it is not an independent privacy gate per conversation.
Applications own permission UI, capture lifetime and cancellation of input feeds.

## Development

Run `flutter test` and `flutter analyze lib test`. The `example` is a native
source create/push/flush/dispose smoke with synthetic data and no capture devices.
Set `EXTERNAL_MEDIA_LOOPBACK=1` for a synthetic local-peer RTP stop/resume
check. Neither mode demonstrates physical capture or echo cancellation. Build it with
`flutter build macos --debug` or `flutter build windows --release`.
Set `EXTERNAL_MEDIA_EXIT=1` to exit after the smoke. Reports use stdout;
`EXTERNAL_MEDIA_RESULT` optionally writes a JSON file in an allowed location.
On Windows, `EXTERNAL_MEDIA_OUTPUT_MATCH` explicitly selects an output device by
label after peer creation; inspect decoded audio separately from RTP packet counts.
