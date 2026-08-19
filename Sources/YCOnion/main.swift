import Foundation
import Dispatch
import CoreBluetooth

private var activeController: YCController?

private struct Options {
    var command = "help"
    var brightness: Int?
    var serial: Data?
    var targetSerial: Data?
    var device: String?
    var timeout: TimeInterval = 12
    var service: String?
    var write: String?
    var positionals: [String] = []
}

private func inferredCommand() -> String? {
    let executable = CommandLine.arguments[0].lowercased()
    if executable.contains("toggle.app/") { return "toggle" }
    if executable.contains(" on.app/") { return "on" }
    if executable.contains(" off.app/") { return "off" }
    return nil
}

private func parseOptions() throws -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    if let inferred = inferredCommand(), args.isEmpty {
        options.command = inferred
    } else if let first = args.first, !first.hasPrefix("-") {
        options.command = first.lowercased()
        args.removeFirst()
    }

    var index = 0
    while index < args.count {
        switch args[index] {
        case "--brightness", "-b":
            index += 1
            guard index < args.count, let value = Int(args[index]) else { throw ControllerError.invalidBrightness }
            options.brightness = value
        case "--serial", "-s":
            index += 1
            guard index < args.count else { throw ControllerError.invalidSerial }
            options.serial = try YCProtocol.parseSerial(args[index])
            options.targetSerial = options.serial
        case "--device", "-d":
            index += 1
            guard index < args.count else { throw ControllerError.noDevice }
            options.device = args[index]
        case "--timeout":
            index += 1
            guard index < args.count, let value = TimeInterval(args[index]), value > 0 else { throw ControllerError.timedOut }
            options.timeout = value
        case "--service":
            index += 1
            guard index < args.count else { throw ControllerError.serviceMissing }
            options.service = args[index]
        case "--write":
            index += 1
            guard index < args.count else { throw ControllerError.characteristicMissing }
            options.write = args[index]
        case "--help", "-h":
            options.command = "help"
        default:
            options.positionals.append(args[index])
        }
        index += 1
    }
    return options
}

private func printHelp() {
    print("""
    YC Onion Bluetooth controller for macOS

    Usage:
      yc-onion devices
      yc-onion on [--brightness 1...100] [--device NAME-OR-UUID] [--serial HEX]
      yc-onion off [--device NAME-OR-UUID] [--serial HEX]
      yc-onion toggle [--brightness 1...100]
      yc-onion brightness 0...100
      yc-onion cct 3200...6200 [brightness]
      yc-onion hsi HUE SATURATION [brightness]
      yc-onion color red|orange|yellow|green|cyan|blue|purple|magenta [brightness]
      yc-onion effect cct|rgb|police ID [speed] [brightness]
      yc-onion raw HEX [HEX ...] --service UUID --write UUID --device NAME-OR-UUID

    The first successful command remembers the light, its advertised serial,
    and the last non-zero brightness in ~/Library/Application Support/YCOnion.
    """
    )
}

do {
    let options = try parseOptions()
    if options.command == "help" {
        printHelp()
        exit(0)
    }
    if options.command == "self-test" {
        guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String != nil else {
            throw NSError(domain: "YCOnion", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bluetooth privacy description is missing from the running bundle."])
        }
        let serial = try YCProtocol.parseSerial("0102030405060708")
        let packet = try YCProtocol.brightness(serial: serial, value: 100)
        let miniSerial = YCProtocol.serial(fromManufacturerData: Data([0x04, 0x05, 0x01, 0x19, 0x42]))
        guard miniSerial?.hex == "4200000000000000" else {
            throw NSError(domain: "YCOnion", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mini serial extraction self-test failed."])
        }
        guard packet.hex == "005A020102030405060708000200010564E880" else {
            throw NSError(domain: "YCOnion", code: 3, userInfo: [NSLocalizedDescriptionKey: "Protocol packet self-test failed: \(packet.hex)"])
        }
        print("Protocol self-test passed.")
        exit(0)
    }

    var state = StateStore.load()
    if let brightness = options.brightness, !(0...100).contains(brightness) {
        throw ControllerError.invalidBrightness
    }

    if options.command == "devices" || options.command == "inspect" {
        let mode: YCController.Mode = options.command == "inspect" ? .inspect : .list
        let controller = YCController(mode: mode, preferredSerial: options.targetSerial, nameFilter: options.device)
        activeController = controller
        controller.run(timeout: options.timeout) { result in
            switch result {
            case .success(let devices):
                if devices.isEmpty && options.command == "devices" {
                    print("No Bluetooth devices found.")
                }
                for device in options.command == "devices" ? devices : [] {
                    let serial = device.serial?.hex ?? "unknown"
                    let manufacturer = device.manufacturerData?.hex ?? "none"
                    print("\(device.name)  id=\(device.peripheral.identifier.uuidString)  rssi=\(device.rssi)  serial=\(serial)  manufacturer=\(manufacturer)")
                }
                exit(devices.isEmpty ? 1 : 0)
            case .failure(let error):
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
    }

    if options.command == "raw" {
        guard let service = options.service, !service.isEmpty,
              let write = options.write, !write.isEmpty,
              let device = options.device, !device.isEmpty,
              !options.positionals.isEmpty else {
            throw NSError(domain: "YCOnion", code: 2, userInfo: [NSLocalizedDescriptionKey: "raw requires packet HEX, --service, --write, and --device."])
        }
        let packets = try options.positionals.map(Data.hexadecimal)
        let requestedID = UUID(uuidString: device)
        let controller = YCController(
            mode: .rawWrite(serviceUUID: CBUUID(string: service), writeUUID: CBUUID(string: write), packets: packets),
            preferredID: requestedID,
            preferredSerial: options.targetSerial,
            nameFilter: requestedID == nil ? device : nil
        )
        activeController = controller
        controller.run(timeout: options.timeout) { result in
            switch result {
            case .success(let devices):
                let name = devices.first?.name ?? device
                print("\(name): wrote \(packets.count) packet(s) to \(service)/\(write)")
                exit(0)
            case .failure(let error):
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
    }

    let command: LightCommand
    let resultingBrightness: Int
    let description: String
    switch options.command {
    case "on":
        resultingBrightness = options.brightness ?? max(state.brightness, 1)
        command = .brightness(resultingBrightness)
        description = "on at \(resultingBrightness)%"
    case "off":
        resultingBrightness = 0
        command = .brightness(0)
        description = "off"
    case "toggle":
        resultingBrightness = state.isOn ? 0 : (options.brightness ?? max(state.brightness, 1))
        command = .brightness(resultingBrightness)
        description = resultingBrightness == 0 ? "off" : "on at \(resultingBrightness)%"
    case "brightness":
        guard let brightness = options.brightness ?? options.positionals.first.flatMap(Int.init) else { throw ControllerError.invalidBrightness }
        resultingBrightness = brightness
        command = .brightness(brightness)
        description = "brightness \(brightness)%"
    case "hsi":
        guard options.positionals.count >= 2, let hue = Int(options.positionals[0]), let saturation = Int(options.positionals[1]) else { throw ControllerError.invalidColor }
        resultingBrightness = options.brightness ?? (options.positionals.count > 2 ? Int(options.positionals[2]) : nil) ?? max(state.brightness, 1)
        command = .hsi(hue: hue, saturation: saturation, brightness: resultingBrightness)
        description = "HSI \(hue)° / \(saturation)% at \(resultingBrightness)%"
    case "color":
        let hues = ["red": 0, "orange": 30, "yellow": 60, "green": 120, "cyan": 180, "blue": 240, "purple": 270, "magenta": 300, "pink": 330]
        guard let name = options.positionals.first?.lowercased(), let hue = hues[name] else { throw ControllerError.invalidColor }
        resultingBrightness = options.brightness ?? (options.positionals.count > 1 ? Int(options.positionals[1]) : nil) ?? max(state.brightness, 1)
        command = .hsi(hue: hue, saturation: 100, brightness: resultingBrightness)
        description = "\(name) at \(resultingBrightness)%"
    case "cct":
        guard let first = options.positionals.first, let kelvin = Int(first) else { throw ControllerError.invalidColor }
        resultingBrightness = options.brightness ?? (options.positionals.count > 1 ? Int(options.positionals[1]) : nil) ?? max(state.brightness, 1)
        command = .cct(kelvin: kelvin, compensation: 0, brightness: resultingBrightness)
        description = "\(kelvin)K at \(resultingBrightness)%"
    case "effect":
        guard options.positionals.count >= 2,
              let family = EffectFamily(rawValue: ["cct": 0x02, "rgb": 0x03, "police": 0x04][options.positionals[0].lowercased()] ?? 0),
              let id = Int(options.positionals[1]) else { throw ControllerError.invalidEffect }
        let speed = options.positionals.count > 2 ? (Int(options.positionals[2]) ?? 50) : 50
        resultingBrightness = options.brightness ?? (options.positionals.count > 3 ? Int(options.positionals[3]) : nil) ?? max(state.brightness, 1)
        command = .effect(family: family, id: id, speed: speed, brightness: resultingBrightness)
        description = "effect \(options.positionals[0]) \(id)"
    default:
        printHelp()
        throw NSError(domain: "YCOnion", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown command: \(options.command)"])
    }

    let requestedID: UUID? = {
        if let device = options.device, let id = UUID(uuidString: device) { return id }
        if options.device == nil { return state.peripheralID }
        return nil
    }()
    let controller = YCController(
        mode: .write(command: command, explicitSerial: options.serial),
        preferredID: requestedID,
        preferredSerial: options.targetSerial ?? state.serialHex.flatMap { try? YCProtocol.parseSerial($0) },
        nameFilter: requestedID == nil ? options.device : state.name
    )
    activeController = controller
    controller.run(timeout: options.timeout) { result in
        switch result {
        case .success(let devices):
            if let device = devices.first {
                state.peripheralID = device.peripheral.identifier
                state.name = device.name
                if let serial = options.serial ?? device.serial { state.serialHex = serial.hex }
            } else if let serial = options.serial {
                state.serialHex = serial.hex
            }
            if resultingBrightness > 0 { state.brightness = resultingBrightness }
            state.isOn = resultingBrightness > 0
            do {
                try StateStore.save(state)
                print("\(state.name ?? "YC Onion Energy Tube"): \(description)")
                exit(0)
            } catch {
                fputs("Light updated, but state could not be saved: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        case .failure(let error):
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(2)
}
