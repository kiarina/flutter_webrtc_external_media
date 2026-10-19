# Native external media smoke

Run from this directory with the pinned parent package/fork dependencies.

- Default: source create, PCM/video push, flush and idempotent dispose.
- `EXTERNAL_MEDIA_LOOPBACK=1`: local synthetic RTP with stop/resume, no provider
  API, physical capture or AEC. Input is silent PCM and a generated video frame.
- `EXTERNAL_MEDIA_EXIT=1`: exit after reporting.
- `EXTERNAL_MEDIA_RESULT`: optional JSON file path permitted by the OS sandbox.
- Windows `EXTERNAL_MEDIA_OUTPUT_MATCH`: explicitly select a speaker label after
  peer creation. Audio RTP alone does not prove decoded PCM/output success.

Build with `flutter build macos --debug` or `flutter build windows --release`.
Reports use `EXTERNAL_MEDIA_REPORT` on stdout. See the parent README and
`docs/integration.md` for contracts and validation limits.
