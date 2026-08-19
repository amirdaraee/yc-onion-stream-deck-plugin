# YC Onion Control for Stream Deck

An open-source Stream Deck plugin for controlling YC Onion Bluetooth devices on
macOS and Windows—without the discontinued mobile apps.

The plugin provides one-click installation, automatic Bluetooth discovery, and
a per-action device picker. Energy Tube Mini lighting controls are verified on
real hardware. Support for other YC Onion products is based on clean-room
protocol analysis and needs community hardware testing.

## Features

- Power, brightness, white/CCT, HSI color, and built-in lighting effects
- Per-key device selection for setups with multiple YC Onion devices
- Advanced raw BLE commands for protocol development and additional products
- Native Bluetooth LE transport on macOS and Windows
- One `.streamDeckPlugin` installer containing all required components
- Support for Stream Deck hardware, Stream Deck Mobile, and Virtual Stream Deck
  through the macOS or Windows Stream Deck application

## Compatibility

| Platform or product | Status |
|---|---|
| macOS 12 or newer | Supported; Apple Silicon and Intel |
| Windows 10 or newer | Beta; physical-device verification needed before Marketplace submission |
| Energy Tube Mini | Hardware verified on macOS |
| Other Energy Tube models | Protocol compatible; hardware testing needed |
| Pudding lights | Protocol recovered; use Advanced BLE Command |
| Sliders, gimbals, motorized heads, teleprompters | Protocol recovered; use with caution |
| Stream Deck Studio with Bitfocus Companion | Not supported by Stream Deck plugins |

Motion commands can move physical equipment. Always select a specific device
and validate its Stop command before testing movement.

## Installation

1. [Download the latest YC Onion Control installer](https://github.com/amirdaraee/yc-onion-stream-deck-plugin/releases/latest/download/com.amirdaraee.yc-onion.streamDeckPlugin).
2. Double-click it and approve **Install** in Stream Deck.
3. Drag an action from **YC Onion Control** onto a key.
4. Select the target device in the action settings and press the key.

No command-line tools or separate controller applications are required. On the
first command, macOS may request Bluetooth access for **YC Onion Controller**.
Approve it in System Settings > Privacy & Security > Bluetooth.

The release also includes `SHA256SUMS` so the installer can be verified before
opening it:

```sh
shasum -a 256 -c SHA256SUMS
```

Turn the YC Onion device on and close its phone app before testing; most BLE
devices accept only one active controller connection.

## Actions

| Action | Purpose |
|---|---|
| Power | Toggle, turn on, or turn off a light |
| Brightness | Set output from 0–100% |
| White / CCT | Set color temperature and brightness |
| HSI Color | Set hue, saturation, and brightness |
| Effect | Run a built-in RGB, CCT, or police effect |
| Advanced BLE Command | Send a service-specific packet to another product family |

## Troubleshooting

- If no device appears, power-cycle it, close the mobile app, and click
  **Refresh** in the device picker.
- If macOS denied Bluetooth access, enable **YC Onion Controller** under System
  Settings > Privacy & Security > Bluetooth.
- If an action shows a warning triangle, inspect Stream Deck logs at
  `~/Library/Logs/ElgatoStreamDeck/` on macOS or
  `%APPDATA%\Elgato\StreamDeck\logs` on Windows.
- Toggle uses local state. If another controller changes the light, pressing
  Toggle twice restores synchronization.
- The plugin restores its bundled controller permissions automatically after
  installation and whenever Stream Deck restarts; no manual reconnection or
  Bluetooth pairing is required after idle periods.
- After sleep or long idle periods, the controller identifies the saved device
  from a fresh Bluetooth advertisement instead of relying on macOS's potentially
  stale peripheral cache.

## Development

Requirements:

- macOS 12 or newer for building the universal macOS controller
- Swift 5.9 or newer
- Node.js 20 or newer
- Stream Deck 6.9 or newer

Build and test the Swift controller:

```sh
swift test
swift run yc-onion self-test
```

Build the Stream Deck JavaScript plugin:

```sh
cd streamdeck
npm ci
npm run build
```

Create the complete one-click installer on macOS:

```sh
cd streamdeck
npm run release
```

The release script builds a universal Apple Silicon/Intel helper, packages it as
an immutable runtime asset, includes the Windows controller, and writes the
installer to `streamdeck/dist/`. Local builds use an ad-hoc signature for
testing. Public releases must use a Developer ID Application certificate and
Apple notarization as described in [the release guide](docs/RELEASING.md).

## Repository layout

```text
Sources/                  macOS CoreBluetooth controller and protocol encoder
Tests/                    Swift protocol tests
Resources/                macOS helper metadata and Bluetooth permission text
protocols/                Clean-room interoperability notes and product catalog
streamdeck/src/           Stream Deck plugin source
streamdeck/*.sdPlugin/    Manifest, property inspector, icons, and transports
scripts/                  Reproducible release tooling
```

## Protocol research

The retired Android applications are not distributed by this project. Only
independently written interoperability notes and code are included.

- [Protocol notes](protocols/android-protocols.md)
- [Product and adapter catalog](protocols/catalog.json)

The catalog covers YC framed lights and motion products, Pudding lights, legacy
GAIA sliders, supported DJI/Zhiyun/Feiyu/Hohem gimbals, motorized heads, and
Lasagna teleprompter remotes.

## Contributing

Contributions are welcome, especially hardware verification and captured BLE
behavior for untested models. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening a pull request. Please report security issues according to
[SECURITY.md](SECURITY.md).

For help, see [SUPPORT.md](SUPPORT.md). The plugin's data practices are
documented in [PRIVACY.md](PRIVACY.md), and release history is maintained in
[CHANGELOG.md](CHANGELOG.md).

## Legal

This independent project is not affiliated with, endorsed by, or sponsored by
YC Onion or Elgato. Product names and trademarks belong to their respective
owners. Reverse engineering notes are provided solely for interoperability with
lawfully owned hardware.

Licensed under the [MIT License](LICENSE).
