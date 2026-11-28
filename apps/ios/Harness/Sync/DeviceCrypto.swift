import CryptoKit
import Foundation
import Security

/// Per-device Ed25519 envelopes for chat2 rows (`H2S1`), matching
/// `crates/sync/src/device_crypto.rs`. Unsigned legacy rows stay readable;
/// sealing (`H2E1` / XChaCha20-Poly1305) is not yet on iOS.
enum DeviceCrypto {
    static let signedMagic = Data("H2S1".utf8)
    static let e2eeMagic = Data("H2E1".utf8)

    struct Envelope: Codable, Equatable {
        var deviceId: String
        var ts: Int64
        var nonce: String
        var sig: String
        var body: String
    }

    static func looksSigned(_ bytes: Data) -> Bool {
        bytes.starts(with: signedMagic) || bytes.starts(with: e2eeMagic)
    }

    static func seal(
        inner: Data,
        deviceId: String,
        key: Curve25519.Signing.PrivateKey,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> Data {
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard status == errSecSuccess else { throw EnvelopeError.badEnvelope }
        let nonce = b64(Data(nonceBytes))
        let body = b64(inner)
        let msg = signMessage(deviceId: deviceId, ts: nowMs, nonce: nonce, body: inner)
        let sig = try key.signature(for: msg)
        let env = Envelope(
            deviceId: deviceId,
            ts: nowMs,
            nonce: nonce,
            sig: b64(sig),
            body: body
        )
        var out = signedMagic
        out.append(try JSONEncoder().encode(env))
        return out
    }

    static func open(
        bytes: Data,
        key: Curve25519.Signing.PrivateKey,
        expectedDevice: String?
    ) throws -> (deviceId: String, inner: Data) {
        guard looksSigned(bytes), bytes.count > 4 else {
            throw EnvelopeError.badEnvelope
        }
        let json = bytes.dropFirst(4)
        let env = try JSONDecoder().decode(Envelope.self, from: json)
        if let expectedDevice, expectedDevice != env.deviceId {
            throw EnvelopeError.deviceMismatch
        }
        guard let body = unb64(env.body), let sig = unb64(env.sig) else {
            throw EnvelopeError.badEnvelope
        }
        let msg = signMessage(deviceId: env.deviceId, ts: env.ts, nonce: env.nonce, body: body)
        guard key.publicKey.isValidSignature(sig, for: msg) else {
            throw EnvelopeError.badSignature
        }
        return (env.deviceId, body)
    }

    private static func signMessage(deviceId: String, ts: Int64, nonce: String, body: Data) -> Data {
        let digest = SHA256.hash(data: body)
        var msg = Data(deviceId.utf8)
        msg.append(contentsOf: [UInt8(ascii: "|")])
        msg.append(contentsOf: String(ts).utf8)
        msg.append(contentsOf: [UInt8(ascii: "|")])
        msg.append(contentsOf: nonce.utf8)
        msg.append(contentsOf: [UInt8(ascii: "|")])
        msg.append(contentsOf: digest)
        return msg
    }

    private static func b64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func unb64(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: pad)
        return Data(base64Encoded: s)
    }

    enum EnvelopeError: Error {
        case badEnvelope
        case badSignature
        case deviceMismatch
    }
}
