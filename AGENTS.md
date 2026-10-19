# Repository instructions

Read README.md and docs/integration.md before changing the public contract.
Capture devices, processing and peer/session policy belong to the caller. Keep
this package device-free and use only public fork APIs. Do not silently enable
unimplemented platforms or substitute an incompatible official Windows SDK.

Run meaningful bridge tests and focused Dart analysis for changes. Pin tested
fork commits; local pubspec_overrides.yaml is ignored and must not be required
by consumers. Public docs contain no local usernames, hostnames or private paths.
Use main for package development and commit/push only intended files.
