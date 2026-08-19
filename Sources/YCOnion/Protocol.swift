import Foundation

enum YCProtocol {
    static let serviceUUID = "1828"
    static let writeUUID = "2ADD"
    static let notifyUUID = "2ADE"
    static let miniServiceUUID = "FFE0"
    static let miniWriteUUID = "FFE1"
    static let miniNotifyUUID = "FFE2"

    static func frame(serial: Data, payload: [UInt8]) throws -> Data {
        guard serial.count == 8 else {
            throw ControllerError.invalidSerial
        }
        var body = Data([0x5A, 0x02])
        body.append(serial)
        body.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF), 0x00, 0x01])
        body.append(contentsOf: payload)

        let checksum = crc16(body)
        var packet = Data([0x00])
        packet.append(body)
        packet.append(UInt8(checksum >> 8))
        packet.append(UInt8(checksum & 0xFF))
        return packet
    }

    static func brightness(serial: Data, value: Int) throws -> Data {
        guard (0...100).contains(value) else { throw ControllerError.invalidBrightness }
        return try frame(serial: serial, payload: [0x05, UInt8(value)])
    }

    static func hsi(serial: Data, hue: Int, saturation: Int) throws -> Data {
        guard (0...360).contains(hue), (0...100).contains(saturation) else { throw ControllerError.invalidColor }
        return try frame(serial: serial, payload: [0x00, UInt8(hue >> 8), UInt8(hue & 0xFF), UInt8(saturation)])
    }

    static func cct(serial: Data, kelvin: Int, compensation: Int = 0) throws -> Data {
        guard (3200...6200).contains(kelvin), (0...100).contains(compensation) else { throw ControllerError.invalidColor }
        return try frame(serial: serial, payload: [0x01, UInt8(kelvin >> 8), UInt8(kelvin & 0xFF), UInt8(compensation)])
    }

    static func effect(serial: Data, family: EffectFamily, id: Int, speed: Int) throws -> Data {
        guard (1...6).contains(id), (0...100).contains(speed) else { throw ControllerError.invalidEffect }
        // ET Mini firmware uses the legacy no-speed effect payload. Speed is
        // retained in the public command for compatibility with newer models.
        return try frame(serial: serial, payload: [family.rawValue, UInt8(id)])
    }

    // This matches the vendor Android app: initial value 0xACE1,
    // polynomial 0x1021, MSB first, no final XOR.
    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xACE1
        for byte in data {
            for bit in (0..<8).reversed() {
                let input = ((byte >> bit) & 1) == 1
                let top = ((crc >> 15) & 1) == 1
                crc <<= 1
                if input != top {
                    crc ^= 0x1021
                }
            }
        }
        return crc
    }

    static func serial(fromManufacturerData data: Data) -> Data? {
        // CoreBluetooth includes the little-endian Bluetooth company ID.
        // YC Onion uses company ID 0x0504. Android strips that ID, skips two
        // vendor bytes, then copies 8 serial bytes. Arrays.copyOfRange pads the
        // Mini's short advertisement with zeroes, which is intentional.
        if data.count >= 4 && data[0] == 0x04 && data[1] == 0x05 {
            var serial = Data(data.dropFirst(4).prefix(8))
            serial.append(contentsOf: repeatElement(0, count: 8 - serial.count))
            return serial
        }

        // Some adapters/platform versions may present manufacturer payload only.
        guard data.count >= 3 else { return nil }
        var serial = Data(data.dropFirst(2).prefix(8))
        serial.append(contentsOf: repeatElement(0, count: 8 - serial.count))
        return serial
    }

    static func parseSerial(_ value: String) throws -> Data {
        let clean = value.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard clean.count == 16 else { throw ControllerError.invalidSerial }

        var bytes = Data()
        var index = clean.startIndex
        for _ in 0..<8 {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else {
                throw ControllerError.invalidSerial
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

enum EffectFamily: UInt8 {
    case cct = 0x02
    case rgb = 0x03
    case police = 0x04
}

enum LightCommand {
    case brightness(Int)
    case hsi(hue: Int, saturation: Int, brightness: Int)
    case cct(kelvin: Int, compensation: Int, brightness: Int)
    case effect(family: EffectFamily, id: Int, speed: Int, brightness: Int)

    func packets(serial: Data) throws -> [Data] {
        switch self {
        case .brightness(let value):
            return [try YCProtocol.brightness(serial: serial, value: value)]
        case .hsi(let hue, let saturation, let brightness):
            return [try YCProtocol.hsi(serial: serial, hue: hue, saturation: saturation), try YCProtocol.brightness(serial: serial, value: brightness)]
        case .cct(let kelvin, let compensation, let brightness):
            return [try YCProtocol.cct(serial: serial, kelvin: kelvin, compensation: compensation), try YCProtocol.brightness(serial: serial, value: brightness)]
        case .effect(let family, let id, let speed, let brightness):
            return [try YCProtocol.effect(serial: serial, family: family, id: id, speed: speed), try YCProtocol.brightness(serial: serial, value: brightness)]
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined() }

    static func hexadecimal(_ value: String) throws -> Data {
        let clean = value.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard !clean.isEmpty, clean.count.isMultiple(of: 2) else {
            throw ControllerError.invalidPacket
        }
        var result = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else {
                throw ControllerError.invalidPacket
            }
            result.append(byte)
            index = next
        }
        return result
    }
}
