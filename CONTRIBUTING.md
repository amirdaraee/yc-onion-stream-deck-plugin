# Contributing

Thank you for helping improve YC Onion Control. Hardware reports are especially
valuable because many YC Onion products are no longer supported by their
original applications.

## Before opening an issue

- Search existing issues for the model name and Bluetooth device name.
- Confirm the device is powered on and disconnected from its mobile app.
- Include the operating system, Stream Deck version, YC Onion model, advertised
  Bluetooth name, and the action that failed.
- Do not upload vendor APKs, decompiled source, credentials, or personal data.

## Development workflow

1. Fork the repository and create a focused branch.
2. Install JavaScript dependencies with `cd streamdeck && npm ci`.
3. Make the smallest change that solves the problem.
4. Run `swift test`, `swift run yc-onion self-test`, and
   `cd streamdeck && npm run build`.
5. Update protocol notes or the product catalog when adding device support.
6. Open a pull request describing the hardware and tests used.

## Protocol contributions

Label findings as one of:

- **Hardware verified** — tested successfully on the named physical product.
- **Protocol recovered** — supported by clean-room analysis but not hardware tested.
- **Experimental** — incomplete or inferred behavior requiring validation.

Movement commands must include a known Stop command and must never default to
automatic execution. Raw packet captures should omit unrelated device and user
information.

## Style

- Format Swift code according to standard Swift conventions.
- Keep TypeScript strict and avoid platform assumptions in the shared plugin.
- Prefer descriptive action settings and actionable error messages.
- Keep generated files out of commits; the release script creates them.
- Use concise, project-focused commit subjects and omit tool-attribution or
  authorship trailers.

By contributing, you agree that your contribution is licensed under the MIT
License included with this repository.
