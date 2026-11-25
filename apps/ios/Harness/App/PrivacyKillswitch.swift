import Foundation

/// Product-telemetry, crash-upload, and background-network killswitches.
/// Rules live in `protocol/privacy-killswitch.json`.
enum PrivacyKillswitch {
    struct Decision: Equatable {
        var doNotTrack: Bool
        var offline: Bool
        var productTelemetry: Bool
        var crashUpload: Bool
        var backgroundNetwork: Bool
        var createTelemetryId: Bool
    }

    static func flagOn(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": return true
        default: return false
        }
    }

    static func decide(consent: Bool, crashConsent: Bool,
                       env: [String: String] = ProcessInfo.processInfo.environment) -> Decision {
        let doNotTrack = flagOn(env["DO_NOT_TRACK"])
        let offline = flagOn(env["HARNESS_OFFLINE"])
        let blocked = doNotTrack || offline
        return Decision(
            doNotTrack: doNotTrack,
            offline: offline,
            productTelemetry: consent && !blocked,
            crashUpload: crashConsent && !blocked,
            backgroundNetwork: !blocked,
            createTelemetryId: consent && !blocked
        )
    }
}
