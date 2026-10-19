# Physical desktop validation

The [independent capture/AEC fixture](https://github.com/kiarina/labs/tree/5894f2c032dda1f1b28a07f6d6a4a5bc7f85d7c4/2026/10/20/flutter-fork-external-media-aec) uses this package's public fork
API with real camera + record input, standalone caller-owned AEC and an independent
silent receiver. Current tested consumer pins are bridge8c8ebe2/fork4477798,
Windows SDK20261020.1. See its pins/source-identity record for the byte-identical
Mac bridge source/pin transition.

Both fixtures keep camera and record open once, keep capture/DSP increasing through
a two-second sender-off interval, receive zero audio/video frames in that interval
and resume reception after enabling. Windows uses a connected phone's physical
camera through the OS virtual-camera transport; it is not a synthetic fallback.
Independent negotiated SDK-positive controls detect the microphone path; actual
trials observe SDK microphone0 and record1. Windows ETW reports lost0. Mac observes
input-node/audio-unit ownership stacks; it is not a count of other applications.

AEC quality is not universally accepted. Mac participant reports no echo and
generally good voice with slight loss during double-talk. Windows participant
reports generally good listening without separate numeric/per-item ratings;
full-scale DSP/decoded peaks remain. Identifiable far-only reduction is about47dB
on Mac and30–35dB on Windows; Windows human DT echo separation is inconclusive.
Neither result is an all-criteria, all-device, long-duration or five-OS pass.

The macOS200ms native queue accommodates approximately100ms record bursts plus
jitter. The old100ms bound overflowed; measured final native capture overflow and
inactive drops are0. Explicit flush counts are intentionally discarded old data,
not hidden queue overflow. The reference stream lost one10ms block at shutdown,
with zero drop at all recorded phase endpoints. Recorder bursts and queue limits
remain latency/clock constraints.

Processing is outside this package. Windows fixture uses a lab-local RAW patch to
record_windows2.3.0 plus selected-endpoint Float32 48/96kHz WASAPI loopback; these
are not bundled by this bridge or automatically supplied by stock record_windows.
Applications must own/adapt that processing backend without importing a lab path.
Keep camera enableAudio:false. New-peer reconnect, real product analysis load,
permission/device changes and long sessions remain separate validation gates.
