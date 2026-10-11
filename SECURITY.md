# Security

MowerBar controls a machine with blades. Please report anything that could:

- send a command the user did not confirm;
- replay a command later;
- expose a Worx session or a mower's identifiers.

Use a [private security advisory](../../security/advisories/new) rather than a public issue.

## What the app does to stay safe

- Movement commands require a confirmation, a live cloud link and a mower state less than 5 minutes old. They are never queued offline, retained or resent automatically.
- Settings (wheel torque, rain delay, edge cutting) always use `cmd: 0` and cannot move the mower.
- The experimental resume is off by default and asks for a separate confirmation.
- Tokens live only in the macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). The sign-in web view uses a non-persistent data store and only accepts HTTPS.
- Diagnostics never print tokens, serial numbers or raw server bodies.

When you open an issue, remove serial numbers, MAC addresses, MQTT topics and tokens from logs and screenshots.
