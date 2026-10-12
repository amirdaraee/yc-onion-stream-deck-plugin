# Changelog

## 1.3.8

- Add the one-button color cycle action.
- Filter Bluetooth discovery by YC Onion manufacturer ID or product name.
- Launch the macOS controller with its Bluetooth privacy description.
- Bound controller runtime and captured output.
- Build the universal controller from SwiftPM's release binaries.

## [1.3.0] - 2026-08-19

### Added

- Per-action device selection for multi-device setups.
- Windows Bluetooth LE transport.
- Universal macOS controller for Apple Silicon and Intel.
- Marketplace-ready support, privacy, release, and contribution documentation.

### Changed

- Reconnect through a fresh Bluetooth advertisement after sleep or idle periods.
- Ship the macOS helper as an immutable archive for Marketplace DRM compatibility.
- Use Marketplace-compliant category, action-list, and key icon dimensions.
- Require Stream Deck 6.9 or newer and use Stream Deck SDK version 3.

### Fixed

- Restored reliable macOS helper execution after Stream Deck installation and restart.
- Corrected brightness, HSI color, and CCT command values.

[Unreleased]: https://github.com/amirdaraee/yc-onion-stream-deck-plugin/compare/v1.3.8...HEAD
[1.3.8]: https://github.com/amirdaraee/yc-onion-stream-deck-plugin/releases/tag/v1.3.8
[1.3.0]: https://github.com/amirdaraee/yc-onion-stream-deck-plugin/releases/tag/v1.3.0
