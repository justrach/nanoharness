import XCTest
@testable import Harness

final class AuthGatewayKeyTests: XCTestCase {
    func testOlderEdgeExchangeWithoutGatewayKeyStillDecodes() throws {
        let data = Data(#"{"user":{"id":"user-1","email":"person@example.test"},"accessToken":"edge-access","refreshToken":"edge-refresh"}"#.utf8)
        let response = try JSONDecoder().decode(AuthExchangeResponse.self, from: data)
        XCTAssertEqual(response.user.id, "user-1")
        XCTAssertNil(response.graffKey)
    }

    func testGatewayCredentialIsAcceptedOnlyWithExpectedKeyAndEmailShape() throws {
        let valid = Data(#"{"user":{"id":"user-1"},"accessToken":"a","refreshToken":"r","graffKey":{"apiKey":"cg_sk_abcdefghijklmnop","email":"person@example.test"}}"#.utf8)
        let key = try XCTUnwrap(JSONDecoder().decode(AuthExchangeResponse.self, from: valid).graffKey)
        XCTAssertTrue(key.isUsable)

        let malformed = Data(#"{"user":{"id":"user-1"},"accessToken":"a","refreshToken":"r","graffKey":{"apiKey":"not-a-key","email":"person@example.test"}}"#.utf8)
        XCTAssertFalse(try XCTUnwrap(JSONDecoder().decode(AuthExchangeResponse.self, from: malformed).graffKey).isUsable)
    }
}
