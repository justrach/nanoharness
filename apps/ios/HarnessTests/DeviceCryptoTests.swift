import CryptoKit
import XCTest
@testable import Harness

final class DeviceCryptoTests: XCTestCase {
    func testSignedRoundTripAndRejectTamper() throws {
        let key = Curve25519.Signing.PrivateKey()
        let inner = Data("loro-update-bytes".utf8)
        let wrapped = try DeviceCrypto.seal(inner: inner, deviceId: "phone", key: key)
        XCTAssertTrue(DeviceCrypto.looksSigned(wrapped))
        let opened = try DeviceCrypto.open(bytes: wrapped, key: key, expectedDevice: "phone")
        XCTAssertEqual(opened.deviceId, "phone")
        XCTAssertEqual(opened.inner, inner)

        var bad = wrapped
        bad[bad.count - 1] ^= 1
        XCTAssertThrowsError(try DeviceCrypto.open(bytes: bad, key: key, expectedDevice: nil))
        XCTAssertFalse(DeviceCrypto.looksSigned(Data("plain loro".utf8)))
    }

    func testUnsignedLegacyRowsStayReadable() {
        XCTAssertFalse(DeviceCrypto.looksSigned(Data("plain loro".utf8)))
    }
}
