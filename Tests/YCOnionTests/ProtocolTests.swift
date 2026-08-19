import Foundation
import XCTest
@testable import YCOnion

final class ProtocolTests: XCTestCase {
    func testSerialParsing() throws {
        XCTAssertEqual(try YCProtocol.parseSerial("01:23:45:67:89:ab:cd:ef").hex, "0123456789ABCDEF")
        XCTAssertThrowsError(try YCProtocol.parseSerial("1234")) { error in
            XCTAssertTrue(error is ControllerError)
        }
    }

    func testManufacturerSerialExtraction() {
        let data = Data([0x04, 0x05, 0xAA, 0xBB, 1, 2, 3, 4, 5, 6, 7, 8, 0xCC])
        XCTAssertEqual(YCProtocol.serial(fromManufacturerData: data)?.hex, "0102030405060708")
    }

    func testMiniManufacturerSerialExtraction() {
        let data = Data([0x04, 0x05, 0x01, 0x19, 0x42])
        XCTAssertEqual(YCProtocol.serial(fromManufacturerData: data)?.hex, "4200000000000000")
    }

    func testBrightnessPacketShapeAndCRC() throws {
        let serial = try YCProtocol.parseSerial("0102030405060708")
        let packet = try YCProtocol.brightness(serial: serial, value: 100)
        XCTAssertEqual(packet.count, 19)
        XCTAssertEqual(packet.prefix(3).hex, "005A02")
        XCTAssertEqual(packet.dropLast(2).suffix(2).hex, "0564")
        let crc = YCProtocol.crc16(packet.dropFirst().dropLast(2))
        XCTAssertEqual(packet.suffix(2), Data([UInt8(crc >> 8), UInt8(crc & 0xFF)]))
    }
}
