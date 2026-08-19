# YC Onion Android protocol extraction

This is a clean-room interoperability summary extracted from the retired YC
Onion Android applications. The APKs and decompiled source are not distributed.

## Sources

| Package | Version | SHA-256 | Purpose |
|---|---:|---|---|
| `com.real0168.yconion` | 1.5.4 | `aba7799bf2bf93227232377499eb69bef881a283eccce423f0e0b80745ec8e62` | Multi-product app |
| `com.ycShuYi.puddingLightSE` | 1.1.6 | `2b518d8fcfbaa075c292ace6b08d12af480fb8964deeff65873982c215ac2be3` | Energy Tube app |

## Product catalog recovered from `category-en.json`

- Sliders: Hot Dog III Pro/Basic, Chocolate Milk/Pro/SE, Hot Dog SE,
  Chocolate Pro Cheese.
- Gimbals: DJI Ronin-S, RS 2/3; Zhiyun Weebill 2/S/LAB, Crane and Smooth
  families; Hohem SV2/iSX/SX2; Feiyu Scorp.
- Lights: Energy Tube Mini/Pro 60/Pro 120/standard/SE, Lolly, Pudding I/II,
  Waffle, Toast.
- Other: Burger motorized head and Lasagna teleprompter.

The BLE-name-to-adapter mapping is in `catalog.json`.

## YC framed protocol

Used by Energy Tube lights and newer YC motion products. The unfragmented frame
is:

```text
00 | 5A 02 | SERIAL[8] | LENGTH[2] | COMMAND[2] | PAYLOAD | CRC16[2]
```

- The leading `00` is a BLE fragment marker.
- CRC: initial `0xACE1`, polynomial `0x1021`, MSB-first, big-endian output.
- Manufacturer company ID is `0x0504`. Android removes the company ID, skips
  two type bytes, then copies eight serial bytes, padding short Mini adverts.
- Long frames use fragment markers `40`, `80`, and `C0`.

Common motion commands:

| Command | ID | Payload |
|---|---:|---|
| Read status | `0002` | none |
| Set origin | `7001` | none |
| Set origin offset | `7002` | signed 32-bit |
| Battery | `7004` | none |
| Move relative | `0101` | signed 32-bit |
| Stop movement | `0102` | none |
| Move absolute | `0103` | signed 32-bit |
| Set speed | `0107` | speed u32, accel u16, decel u16 |
| Set A/B | `0111` | u16 selector |
| Start work | `0201` | mode u8, direction u8, arg0 u16, arg1 u16 |
| Stop/pause work | `0202` | none |
| Set loop count | `0203` | u16 (`FFFE` means infinite) |
| Read loop count | `0204` | none |
| Set/read/delete step | `0205` / `0206` / `0207` | structured step / u16 index |
| Set/read parameters | `0209` / `020A` | speed/time values |
| Device information | `7801` / `7803` | serial / details |

Light command `0001` payload modes:

| Payload | Meaning |
|---|---|
| `00 HHHH SS` | HSI hue and saturation |
| `01 KKKK GG` | CCT Kelvin and green/magenta compensation |
| `02 ID [SPEED]` | CCT effect |
| `03 ID [SPEED]` | RGB effect |
| `04 ID [SPEED]` | police effect |
| `05 BB` | brightness, 0–100 |

## Legacy GAIA slider protocol

Service/write is `FFE0`/`FFE1`. Frames are:

```text
FF 01 FLAGS LENGTH 00 01 COMMAND_BE[2] PAYLOAD [XOR]
```

Important commands include mode `0001`, move `0101`, pause `0102`, confirm A/B
`0103`/`0104`, video AB `0201`, video play/loop/buffer/speed/time
`0202`–`0206`, delay setup `0301`, battery `0401`, and connect/status
`0A01`/`0B01`–`0B03`.

## Pudding light protocol

Service/write/notify: `AE00`/`AE02`/`AE01`. Fixed frame:

```text
AA | COMMAND | PAYLOAD padded to 8 bytes | FF
```

Commands: `F1` RGB, `F2` RGB effect state, `F3` power (`01` on, `02` off),
`F4` brightness, `F5` CCT (`2500 + value*60`), `F6` mode, `F7` query.

## Gimbal transports

- Zhiyun: service `FEE9`, write/notify `...9600`/`...9601`; framed commands
  use a sequence byte and CRC. Recovered operations include three-axis move,
  absolute point, stop, reset, photo, video, and focus.
- DJI Ronin: `FFE0`/`FFE1`; recovered operations include angle query, three-axis
  move/stop, absolute point, reset, photo, video, and focus.
- Feiyu: `FFFF`/`FF01`/`FF02`; tagged length frames with additive checksum;
  move/stop/reset, point programming, and delay moves are recovered.
- Hohem: `FFE0`/`FFE1`/`FFE2`; length + device ID + command + payload + additive
  checksum + terminator. Move/stop/reset and angle query are recovered.

These adapters are protocol-recovered but cannot be marked hardware-verified
without the corresponding device.

## Lasagna teleprompter

Service/write/notify `FFF0`/`FFF1`/`FFF2`, plus standard battery
`180F`/`2A19`. Notifications are four-byte button frames whose fourth byte is
the sum of the first three. Button masks: left `01`, right `02`, up `04`, down
`08`, middle `10`, speed-up `20`, speed-down `40`.

## Verification levels

- Energy Tube Mini: hardware verified.
- Other Energy Tube family: same recovered command family, not locally tested.
- All slider, gimbal, head, Pudding, and teleprompter adapters: extracted and
  structurally documented, not locally hardware-tested.
