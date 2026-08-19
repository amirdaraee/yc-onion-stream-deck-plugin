import CoreBluetooth
import Dispatch
import Foundation

enum ControllerError: LocalizedError {
    case bluetoothUnavailable(String)
    case noDevice
    case noSerial
    case connectionFailed(String)
    case serviceMissing
    case characteristicMissing
    case invalidSerial
    case invalidBrightness
    case invalidColor
    case invalidEffect
    case invalidPacket
    case timedOut

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let state): return "Bluetooth is unavailable (\(state))."
        case .noDevice: return "No matching Bluetooth device was found. Turn it on, keep it near the Mac, and close its phone app."
        case .noSerial: return "The light was found, but its 8-byte serial was not advertised. Run `yc-onion devices` and use --serial if shown separately."
        case .connectionFailed(let message): return "Could not connect: \(message)"
        case .serviceMissing: return "The light does not expose a supported YC Onion BLE service."
        case .characteristicMissing: return "The light does not expose a supported writable characteristic."
        case .invalidSerial: return "Serial must be exactly 16 hexadecimal characters (8 bytes)."
        case .invalidBrightness: return "Brightness must be from 0 through 100."
        case .invalidColor: return "Color values are out of range (hue 0–360, saturation 0–100, CCT 3200–6200K)."
        case .invalidEffect: return "Effect values are out of range."
        case .invalidPacket: return "Packet must be a non-empty, even-length hexadecimal string."
        case .timedOut: return "The Bluetooth operation timed out."
        }
    }
}

struct DiscoveredDevice {
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var manufacturerData: Data?
    var serial: Data?
    var advertisesService: Bool
}

final class YCController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Mode {
        case list
        case inspect
        case write(command: LightCommand, explicitSerial: Data?)
        case rawWrite(serviceUUID: CBUUID, writeUUID: CBUUID, packets: [Data])
    }

    private let mode: Mode
    private let preferredID: UUID?
    private let preferredSerial: Data?
    private let nameFilter: String?
    private var isFallbackScan = false
    private var central: CBCentralManager!
    private var devices: [UUID: DiscoveredDevice] = [:]
    private var selected: DiscoveredDevice?
    private var writeCharacteristic: CBCharacteristic?
    private var targetWriteUUID = CBUUID(string: YCProtocol.writeUUID)
    private var pendingPackets: [Data] = []
    private var pendingInspections = 0
    private var timeout: DispatchWorkItem?
    private var scanStop: DispatchWorkItem?
    private var completion: ((Result<[DiscoveredDevice], Error>) -> Void)?

    init(mode: Mode, preferredID: UUID? = nil, preferredSerial: Data? = nil, nameFilter: String? = nil) {
        self.mode = mode
        self.preferredID = preferredID
        self.preferredSerial = preferredSerial
        self.nameFilter = nameFilter?.lowercased()
        super.init()
    }

    func run(timeout seconds: TimeInterval = 12, completion: @escaping (Result<[DiscoveredDevice], Error>) -> Void) {
        self.completion = completion
        central = CBCentralManager(delegate: self, queue: .main)
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(ControllerError.timedOut))
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting {
                finish(.failure(ControllerError.bluetoothUnavailable(String(describing: central.state))))
            }
            return
        }

        // A cached CoreBluetooth peripheral can remain retrievable after the
        // device has slept or changed its radio state, yet hang when connected.
        // When a stable advertised serial is available, scan first and connect
        // to the fresh advertisement instead of trusting that stale cache.
        if preferredSerial == nil,
           let preferredID,
           let known = central.retrievePeripherals(withIdentifiers: [preferredID]).first,
           isWriteMode {
            selected = DiscoveredDevice(
                peripheral: known,
                name: known.name ?? "YC Onion",
                rssi: 0,
                manufacturerData: nil,
                serial: nil,
                advertisesService: true
            )
            known.delegate = self
            central.connect(known)
            return
        }

        startScanning()
    }

    private func startScanning() {
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        let scanStop = DispatchWorkItem { [weak self] in
            self?.stopScanning()
        }
        self.scanStop = scanStop
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: scanStop)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "Unknown"
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasService = services.contains(CBUUID(string: YCProtocol.serviceUUID))
        let lowerName = name.lowercased()
        let isYCManufacturer = manufacturer?.prefix(2) == Data([0x04, 0x05])
        let looksLikeYC = hasService || isYCManufacturer || lowerName.contains("energy") || lowerName.contains("pudding") || lowerName.hasPrefix("et_")
        let isListing: Bool
        if case .list = mode { isListing = true } else { isListing = false }
        let isRaw: Bool
        if case .rawWrite = mode { isRaw = true } else { isRaw = false }
        guard isListing || looksLikeYC || (isRaw && matchesName(name)) || (nameFilter != nil && matchesName(name)) else { return }

        let serial = manufacturer.flatMap(YCProtocol.serial(fromManufacturerData:))
        let candidate = DiscoveredDevice(
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue,
            manufacturerData: manufacturer,
            serial: serial,
            advertisesService: hasService
        )
        if candidate.rssi > (devices[peripheral.identifier]?.rssi ?? -999) {
            devices[peripheral.identifier] = candidate
        }

        let shouldConnectNow: Bool
        switch mode {
        case .inspect: shouldConnectNow = matches(candidate)
        case .write: shouldConnectNow = matches(candidate) && candidate.serial != nil
        case .rawWrite: shouldConnectNow = matches(candidate)
        case .list: shouldConnectNow = false
        }
        if shouldConnectNow {
            central.stopScan()
            scanStop?.cancel()
            connect(candidate)
        }
    }

    private func matches(_ device: DiscoveredDevice) -> Bool {
        if isFallbackScan,
           let savedHex = StateStore.load().serialHex,
           let savedSerial = try? YCProtocol.parseSerial(savedHex),
           device.serial == savedSerial {
            return true
        }
        if let preferredID, !isFallbackScan, device.peripheral.identifier == preferredID { return true }
        if let preferredSerial, device.serial == preferredSerial { return true }
        if let nameFilter { return device.name.lowercased().contains(nameFilter) }
        if preferredID != nil { return false }
        return true
    }

    private func matchesName(_ name: String) -> Bool {
        guard let nameFilter else { return false }
        return name.lowercased().contains(nameFilter)
    }

    private var isWriteMode: Bool {
        switch mode {
        case .write, .rawWrite: return true
        case .list, .inspect: return false
        }
    }

    private func stopScanning() {
        central.stopScan()
        if case .list = mode {
            finish(.success(sortedDevices()))
            return
        }
        guard let candidate = sortedDevices().first(where: matches) else {
            finish(.failure(ControllerError.noDevice))
            return
        }
        connect(candidate)
    }

    private func connect(_ device: DiscoveredDevice) {
        selected = device
        device.peripheral.delegate = self
        central.connect(device.peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if case .inspect = mode {
            peripheral.discoverServices(nil)
        } else if case .rawWrite(let serviceUUID, _, _) = mode {
            peripheral.discoverServices([serviceUUID])
        } else {
            peripheral.discoverServices([
                CBUUID(string: YCProtocol.serviceUUID),
                CBUUID(string: YCProtocol.miniServiceUUID),
            ])
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        recoverConnection(or: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard completion != nil else { return }
        recoverConnection(or: error)
    }

    private func recoverConnection(or error: Error?) {
        guard !isFallbackScan, preferredID != nil, nameFilter != nil else {
            finish(.failure(ControllerError.connectionFailed(error?.localizedDescription ?? "device disconnected")))
            return
        }
        isFallbackScan = true
        selected = nil
        writeCharacteristic = nil
        pendingPackets = []
        startScanning()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            finish(.failure(ControllerError.connectionFailed(error.localizedDescription)))
            return
        }
        if case .inspect = mode {
            let services = peripheral.services ?? []
            guard !services.isEmpty else {
                finish(.failure(ControllerError.serviceMissing))
                return
            }
            pendingInspections = services.count
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
            return
        }
        if case .rawWrite(let serviceUUID, let writeUUID, _) = mode {
            guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
                finish(.failure(ControllerError.serviceMissing))
                return
            }
            targetWriteUUID = writeUUID
            peripheral.discoverCharacteristics([writeUUID], for: service)
            return
        }

        let modernService = peripheral.services?.first(where: { $0.uuid == CBUUID(string: YCProtocol.serviceUUID) })
        let miniService = peripheral.services?.first(where: { $0.uuid == CBUUID(string: YCProtocol.miniServiceUUID) })
        guard let service = modernService ?? miniService else {
            finish(.failure(ControllerError.serviceMissing))
            return
        }
        targetWriteUUID = CBUUID(string: modernService != nil ? YCProtocol.writeUUID : YCProtocol.miniWriteUUID)
        peripheral.discoverCharacteristics([targetWriteUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            finish(.failure(ControllerError.connectionFailed(error.localizedDescription)))
            return
        }
        if case .inspect = mode {
            print("service=\(service.uuid.uuidString)")
            for characteristic in service.characteristics ?? [] {
                print("  characteristic=\(characteristic.uuid.uuidString) properties=0x\(String(characteristic.properties.rawValue, radix: 16))")
            }
            pendingInspections -= 1
            if pendingInspections == 0 {
                finish(.success(selected.map { [$0] } ?? []))
            }
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == targetWriteUUID }) else {
            finish(.failure(ControllerError.characteristicMissing))
            return
        }
        writeCharacteristic = characteristic

        do {
            switch mode {
            case .write(let command, let explicitSerial):
                let savedSerial = StateStore.load().serialHex.flatMap { try? YCProtocol.parseSerial($0) }
                guard let serial = explicitSerial ?? selected?.serial ?? savedSerial else {
                    finish(.failure(ControllerError.noSerial))
                    return
                }
                pendingPackets = try command.packets(serial: serial)
            case .rawWrite(_, _, let packets):
                pendingPackets = packets
            case .list, .inspect:
                return
            }
            let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            writeNext(to: peripheral, characteristic: characteristic, type: type)
            if type == .withoutResponse {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.finish(.success(self?.selected.map { [$0] } ?? []))
                }
            }
        } catch {
            finish(.failure(error))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            finish(.failure(ControllerError.connectionFailed(error.localizedDescription)))
        } else {
            if pendingPackets.isEmpty {
                finish(.success(selected.map { [$0] } ?? []))
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.writeNext(to: peripheral, characteristic: characteristic, type: .withResponse)
                }
            }
        }
    }

    private func writeNext(to peripheral: CBPeripheral, characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        guard !pendingPackets.isEmpty else { return }
        let packet = pendingPackets.removeFirst()
        peripheral.writeValue(packet, for: characteristic, type: type)
        if type == .withoutResponse, !pendingPackets.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.writeNext(to: peripheral, characteristic: characteristic, type: type)
            }
        }
    }

    private func sortedDevices() -> [DiscoveredDevice] {
        devices.values.sorted { $0.rssi > $1.rssi }
    }

    private func finish(_ result: Result<[DiscoveredDevice], Error>) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        scanStop?.cancel()
        central?.stopScan()
        if let selected { central?.cancelPeripheralConnection(selected.peripheral) }
        completion(result)
    }
}
