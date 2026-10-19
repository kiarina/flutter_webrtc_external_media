# Integration contract

The caller owns continuous `camera` + `record` capture, conversion and processing.
This package owns bounded submission queues, packetization and a source-wide gate
around the fork public `RTCExternalMediaSource` API. It imports no private fork
classes. Keep provider authentication and application session state above it.

## Formats and timing

- Audio: processed PCM16 little-endian, mono 48 kHz. Even-sized chunks up to one
  second are split into 480-sample blocks; partial blocks wait for the next chunk.
  Resampling, AEC, denoising and gain control are caller responsibilities.
- Video: BGRA8888 or RGBA8888, optional padded row stride, up to 1920x1080.
  The bridge copies/packs input before asynchronous native submission. Caller
  timestamps must increase for the whole source lifetime, including device changes.
- Windows uses native frame-arrival timestamps; macOS honors caller timestamps. The macOS native input queue has a 200-ms
limit to tolerate approximately 100-ms recorder bursts plus scheduling jitter;
its overflow/inactive/flush counters expose every discard separately. This
native bound is additional to the bridge queue and is not a latency promise.
  `videoTimestampSource` reports this difference.
- Audio has at most ten queued 10-ms blocks by default plus one in flight. On
  overload, oldest queued blocks drop. Video keeps only the latest queued frame
  plus one in flight. Statistics count submission, not RTP reception.

## Gate and lifetime

The source starts muted. Await `setSending(true)` before feeding media. Stop
immediately rejects new input, discards queued/partial old data, waits for the
in-flight call and flushes/mutes. It cannot retract already encoded/RTP media.
Rapid stop/start operations are serialized and guarded by generations. Repeated
requests for the same target share the current operation and preserve partial/
queued media; only a real state transition flushes. Ending a
session also requires caller-owned sender detach/peer close. One source per
factory is currently supported. Do not dispose its underlying stream separately.

Native calls time out after five seconds. A submission error faults the bridge;
listen to `errors`, close the peer/source, then create a replacement. `dispose` is
idempotent. Capture remains with the caller throughout these operations.

## Speaker and AEC

Windows keeps native WebRTC speaker output and requires an external selected-
endpoint loopback reference adapter. `hasRenderReference` is false on Windows.
macOS uses an output-only custom audio device following system default output;
its bounded `renderReference` stream returns PCM actually supplied to that output.
The plugin output selector is unsupported in this macOS mode. Reference drops
and capture underflows are exposed by native statistics. A render reference is
not itself an echo canceller: feed it to the caller-owned processing pipeline.

## Validation boundaries

Thirteen bridge tests cover gating, owned buffers, bounded overload, stop/resume races,
video conversion, timestamp rejection and cleanup. The fork has twenty Dart tests.
macOS debug and Windows x64 release native builds and source smokes pass.
The Windows smoke loaded the pinned DLL SHA256
`73b672f90beba282e04ae6dd9dbcb7b3af574d192977ae9224c382075dbcd740`. Synthetic local RTP reception/stop/resume succeeds on Mac and Windows;
Windows initially received RTP packets without decoded PCM when using default
output. Explicit output selection after peer creation restored decoded sample
progress (105600 to 227040 samples) on the tested speaker. Packet counters alone
do not demonstrate speaker/PCM success. See [recorded counts](validation-20261020.json).
Physical camera/record and caller-owned AEC have now been exercised in the
[separate fixture](physical-validation.md). Acquisition/gates and SDK microphone
ownership pass there. The Mac dev.2 continuity follow-up has successful short-run
human listening, while strict synthetic criteria and Windows peaks remain.
It does not establish production processing ownership, new-peer reconnection,
long-duration/device/permission behavior or all-platform acceptance.
