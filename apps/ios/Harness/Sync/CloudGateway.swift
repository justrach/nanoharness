import CryptoKit
import Foundation

/// Direct CodeGraff gateway access for this phone. The gateway origin is fixed; only
/// the dedicated CodeGraff API key is sent, never the Harness sync bearer.
struct CloudGateway: Sendable {
    static let baseURL = URL(string: "https://gateway.codegraff.com")!
    static let siteBaseURL = URL(string: "https://codegraff.com")!
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let apiKey: String
    private let transport: Transport

    init(apiKey: String, transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.apiKey = apiKey
        self.transport = transport
    }

    func sandboxes() async throws -> CodegraffSandboxes {
        async let views = get("/v1/sandboxes")
        async let sizes: [PersonalSize] = {
            guard let data = try? await get("/v1/sandboxes/personal-sizes") else { return [] }
            return (try? Self.decodeSizes(data)) ?? []
        }()
        let (viewData, loadedSizes) = try await (views, sizes)
        return CodegraffSandboxes(enabled: true,
                                  sandboxes: try Self.decodeSandboxes(viewData),
                                  sizes: loadedSizes)
    }

    func create(size: PersonalSize?) async throws -> CodegraffSandbox {
        var body: [String: Any] = [
            "provider": "fleet", "persistent": true, "name": "Harness cloud",
            "autoStopMinutes": 30, "keepRunning": true,
        ]
        if let size {
            body["cpu"] = size.cpu
            body["memory"] = size.memoryGiB
            if size.diskGiB > 0 { body["disk"] = size.diskGiB }
        }
        let data = try await request("/v1/sandboxes", method: "POST", body: body, timeout: 90)
        return try Self.decodeSandbox(data)
    }

    func start(_ id: String) async throws {
        let current = try await get("/v1/sandboxes/\(Self.pathID(id))")
        let sandbox = try Self.decodeSandbox(current)
        if sandbox.state != "running" {
            _ = try await request("/v1/sandboxes/\(Self.pathID(id))/start", method: "POST",
                                  body: ["leaseSeconds": 1800, "keepRunning": true], timeout: 90)
        }
        try await attach(id)
    }

    func attach(_ id: String) async throws {
        _ = try await request("/v1/sandboxes/\(Self.pathID(id))/harness", method: "POST",
                              body: ["deviceName": Self.deviceName(for: id)], timeout: 120)
    }

    func stop(_ id: String) async throws {
        _ = try await request("/v1/sandboxes/\(Self.pathID(id))/stop", method: "POST", timeout: 20)
    }

    func delete(_ id: String) async throws {
        _ = try await request("/v1/sandboxes/\(Self.pathID(id))", method: "DELETE", timeout: 20)
    }

    func keepRunning(_ id: String, enabled: Bool) async throws {
        _ = try await request("/v1/sandboxes/\(Self.pathID(id))/keep-running", method: "POST",
                              body: ["enabled": enabled], timeout: 20)
    }

    func artifactFrameURL(_ id: String) async throws -> CodegraffArtifactFrame {
        let data = try await request("/v1/artifacts/\(Self.pathID(id))/frame-url", method: "POST", timeout: 30)
        do { return try JSONDecoder().decode(CodegraffArtifactFrame.self, from: data) }
        catch { throw CloudGatewayError.unavailable("CodeGraff returned an invalid artifact frame response") }
    }

    func setArtifactVisibility(_ id: String, visibility: String) async throws -> CodegraffArtifactMeta {
        let data = try await request("/v1/artifacts/\(Self.pathID(id))", method: "PATCH",
                                     body: ["visibility": visibility], timeout: 30)
        do { return try JSONDecoder().decode(CodegraffArtifactMeta.self, from: data) }
        catch { throw CloudGatewayError.unavailable("CodeGraff returned an invalid artifact update response") }
    }

    func computerOffer() async throws -> CodegraffComputerOffer? {
        guard var components = URLComponents(url: Self.siteBaseURL, resolvingAgainstBaseURL: false) else {
            throw CloudGatewayError.unavailable("Invalid CodeGraff URL")
        }
        components.path = "/api/computer/offer"
        guard let url = components.url else { throw CloudGatewayError.unavailable("Invalid computer status request") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(req)
        guard let http = response as? HTTPURLResponse else {
            throw CloudGatewayError.unavailable("CodeGraff returned an invalid response")
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? String) ?? (($0["error"] as? [String: Any])?["message"] as? String) }
                .map { String($0.prefix(300)) }
            throw CloudGatewayError.http(http.statusCode, message)
        }
        do { return try JSONDecoder().decode(CodegraffComputerOffer.self, from: data) }
        catch { throw CloudGatewayError.unavailable("CodeGraff returned an invalid computer status") }
    }

    static func deviceName(for sandboxID: String) -> String {
        let digest = SHA256.hash(data: Data(sandboxID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Harness phone \(digest.prefix(26))" // gateway limit is 40 legal ASCII characters
    }

    private func get(_ path: String) async throws -> Data {
        try await request(path, method: "GET", timeout: 20)
    }

    private func request(_ path: String, method: String, body: [String: Any]? = nil,
                         timeout: TimeInterval) async throws -> Data {
        guard var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false) else {
            throw CloudGatewayError.unavailable("Invalid CodeGraff gateway URL")
        }
        components.path = path
        guard let url = components.url else { throw CloudGatewayError.unavailable("Invalid gateway request") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudGatewayError.unavailable("CodeGraff returned an invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                .map { String($0.prefix(300)) }
            throw CloudGatewayError.http(http.statusCode, message)
        }
        return data
    }

    private static func pathID(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? ""
    }

    private static func decodeSandboxes(_ data: Data) throws -> [CodegraffSandbox] {
        let root = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rows = array
        } else if let object = root as? [String: Any],
                  let wrapped = (object["sandboxes"] ?? object["data"] ?? object["items"]) as? [[String: Any]] {
            rows = wrapped
        } else {
            throw CloudGatewayError.unavailable("CodeGraff returned an invalid sandbox list")
        }
        return try rows.compactMap { row in
            let state = row["state"] as? String ?? "unknown"
            if state == "destroyed" || state == "terminated" { return nil }
            var normalized = row
            if state == "started" { normalized["state"] = "running" }
            if normalized["harness"] == nil {
                normalized["harness"] = (row["codegraff"] as? [String: Any])?["harness"] as? Bool ?? false
            }
            do { return try JSONDecoder().decode(CodegraffSandbox.self, from: JSONSerialization.data(withJSONObject: normalized)) }
            catch { throw CloudGatewayError.unavailable("CodeGraff returned an invalid sandbox row") }
        }
    }

    private static func decodeSizes(_ data: Data) throws -> [PersonalSize] {
        struct Envelope: Decodable { var sizes: [PersonalSize] }
        do { return try JSONDecoder().decode(Envelope.self, from: data).sizes }
        catch { return [] } // older gateways return 404 or don't offer size choices
    }

    private static func decodeSandbox(_ data: Data) throws -> CodegraffSandbox {
        let root = try JSONSerialization.jsonObject(with: data)
        let object = (root as? [String: Any])?["sandbox"] as? [String: Any] ?? root as? [String: Any]
        guard let object else { throw CloudGatewayError.unavailable("CodeGraff did not identify the sandbox") }
        let normalized = try JSONSerialization.data(withJSONObject: object)
        do {
            var sandbox = try JSONDecoder().decode(CodegraffSandbox.self, from: normalized)
            if sandbox.state == "started" { sandbox.state = "running" }
            return sandbox
        } catch { throw CloudGatewayError.unavailable("CodeGraff returned an invalid sandbox") }
    }
}

enum CloudGatewayError: LocalizedError, Equatable {
    case http(Int, String?)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            if status == 401 || status == 403 { return "Your CodeGraff gateway key was rejected. Sign out and back in to repair it." }
            if let message, !message.isEmpty { return message }
            return "CodeGraff gateway request failed (\(status))."
        case .unavailable(let message): return message
        }
    }
}

/// Account-scoped serial lane shared by Home and Settings. It remembers only a
/// sandbox id and an in-flight create marker in defaults; credentials stay in Keychain.
actor PhoneCloudSandboxCoordinator {
    private let transport: CloudGateway.Transport

    init(transport: @escaping CloudGateway.Transport = { try await URLSession.shared.data(for: $0) }) {
        self.transport = transport
    }

    private func gateway(_ credential: GraffGatewayCredential) -> CloudGateway {
        CloudGateway(apiKey: credential.apiKey, transport: transport)
    }

    private func defaultsKey(_ credential: GraffGatewayCredential) -> String {
        let scope = SHA256.hash(data: Data("\(credential.edgeURL)|\(credential.userId)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "phoneCloudSandbox.v1.\(scope)"
    }

    func list(_ credential: GraffGatewayCredential) async throws -> CodegraffSandboxes {
        try await gateway(credential).sandboxes()
    }

    func provision(_ credential: GraffGatewayCredential, size: String?) async throws -> CodegraffSandbox {
        let gateway = gateway(credential)
        let key = defaultsKey(credential)
        let createMarker = key + ".createPending"
        let list = try await gateway.sandboxes()
        let knownID = UserDefaults.standard.string(forKey: key)
        let candidates = list.sandboxes.filter { $0.provider == "fleet" && $0.harness }
        let existing: CodegraffSandbox?
        if let knownID {
            existing = list.sandboxes.first { $0.id == knownID && $0.provider == "fleet" }
            if existing == nil { UserDefaults.standard.removeObject(forKey: key) }
        } else if candidates.count == 1 {
            existing = candidates.first
        } else if candidates.count > 1 {
            throw CloudGatewayError.unavailable("More than one Harness cloud sandbox exists. Choose one in Settings before starting from Home.")
        } else {
            existing = nil
        }
        if let existing {
            UserDefaults.standard.set(existing.id, forKey: key)
            UserDefaults.standard.removeObject(forKey: createMarker)
            try await gateway.start(existing.id)
            return existing
        }
        guard !UserDefaults.standard.bool(forKey: createMarker) else {
            throw CloudGatewayError.unavailable("A sandbox create may have reached CodeGraff, but its reply was lost. Check Settings → Cloud sandboxes before trying again.")
        }
        UserDefaults.standard.set(true, forKey: createMarker)
        let chosen = CloudSandboxRules.selectedSize(list.sizes, picked: size)
        let created: CodegraffSandbox
        do { created = try await gateway.create(size: chosen) }
        catch { throw error } // Leave marker set: never blindly repeat an ambiguous billable POST.
        guard !created.id.isEmpty, created.provider == "fleet" else {
            throw CloudGatewayError.unavailable("CodeGraff created a sandbox but did not identify a Harness fleet sandbox.")
        }
        UserDefaults.standard.set(created.id, forKey: key)
        UserDefaults.standard.removeObject(forKey: createMarker)
        try await gateway.attach(created.id)
        return created
    }

    func act(_ credential: GraffGatewayCredential, id: String, action: CloudSandboxAction) async throws {
        let gateway = gateway(credential)
        switch action {
        case .start: try await gateway.start(id)
        case .stop: try await gateway.stop(id)
        case .delete:
            try await gateway.delete(id)
            UserDefaults.standard.removeObject(forKey: defaultsKey(credential))
        case .keepRunningOn: try await gateway.keepRunning(id, enabled: true)
        case .keepRunningOff: try await gateway.keepRunning(id, enabled: false)
        }
    }

    func artifactFrameURL(_ credential: GraffGatewayCredential, id: String) async throws -> CodegraffArtifactFrame {
        try await gateway(credential).artifactFrameURL(id)
    }

    func setArtifactVisibility(_ credential: GraffGatewayCredential, id: String,
                               visibility: String) async throws -> CodegraffArtifactMeta {
        try await gateway(credential).setArtifactVisibility(id, visibility: visibility)
    }

    func computerOffer(_ credential: GraffGatewayCredential) async throws -> CodegraffComputerOffer? {
        try await gateway(credential).computerOffer()
    }
}
