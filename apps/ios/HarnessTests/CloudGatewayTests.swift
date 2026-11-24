import XCTest
@testable import Harness

final class CloudGatewayTests: XCTestCase {
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        func append(_ request: URLRequest) { lock.lock(); stored.append(request); lock.unlock() }
        var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func response(_ body: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: CloudGateway.baseURL, statusCode: status,
                                         httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func testStablePhoneDeviceNameIsLegalAndCollisionResistant() {
        let first = CloudGateway.deviceName(for: "cnd_0123456789abcdef")
        let second = CloudGateway.deviceName(for: "cnd_1123456789abcdef")
        XCTAssertEqual(first, CloudGateway.deviceName(for: "cnd_0123456789abcdef"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 40)
        XCTAssertTrue(first.hasPrefix("Harness phone "))
        XCTAssertTrue(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || " ._-".contains($0)) })
    }

    func testListNormalizesGatewayStatesAndKeepsSizesOptional() async throws {
        let calls = Requests()
        let gateway = CloudGateway(apiKey: "cg_sk_test", transport: { request in
            calls.append(request)
            if request.url?.path.hasSuffix("personal-sizes") == true {
                return self.response(#"{"sizes":[{"id":"standard","cpu":2,"memoryGiB":4,"diskGiB":40,"pricePerHourMicroUsd":100000,"default":true}]}"#)
            }
            return self.response(#"{"sandboxes":[{"id":"cnd_a","provider":"fleet","state":"started","codegraff":{"harness":true}},{"id":"cnd_gone","provider":"fleet","state":"destroyed"}]}"#)
        })
        let list = try await gateway.sandboxes()
        XCTAssertEqual(list.sandboxes.map(\.id), ["cnd_a"])
        XCTAssertEqual(list.sandboxes.first?.state, "running")
        XCTAssertTrue(list.sandboxes.first?.harness == true)
        XCTAssertEqual(list.sizes.first?.pricePerHourMicroUsd, 100_000)
        XCTAssertTrue(calls.all.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer cg_sk_test" })
    }

    func testPhoneReadinessRequiresExactOnlineDeviceAndLiveGraffCatalogs() {
        let sandboxId = "cnd_0123456789abcdef"
        let expectedName = CloudGateway.deviceName(for: sandboxId)
        let exact = DeviceRow(id: "cloud-device", name: expectedName, platform: "linux")
        let misleading = DeviceRow(id: "wrong-device", name: "Harness phone 0123", platform: "linux")
        XCTAssertNil(PhoneCloudReadinessRules.host(sandboxId: sandboxId, devices: [misleading], online: { _ in true }))
        XCTAssertNil(PhoneCloudReadinessRules.host(sandboxId: sandboxId, devices: [exact], online: { _ in false }))
        XCTAssertNil(PhoneCloudReadinessRules.host(sandboxId: sandboxId, devices: [exact, exact], online: { _ in true }))
        XCTAssertEqual(PhoneCloudReadinessRules.host(sandboxId: sandboxId, devices: [exact], online: { $0 == exact.id })?.id,
                       exact.id)

        let graff = DeviceCatalog(items: [HarnessInfo(id: "graff", label: "Graff")], isLive: true)
        let auto = DeviceCatalog(items: [ModelInfo(id: ChatMode.tiers[0].id, label: "Auto",
                                                   description: nil, reasoningLevels: [])], isLive: true)
        XCTAssertTrue(PhoneCloudReadinessRules.canStartChat(harnesses: graff, models: auto))
        XCTAssertFalse(PhoneCloudReadinessRules.canStartChat(
            harnesses: DeviceCatalog(items: graff.items, isLive: false), models: auto), "cached host catalog")
        XCTAssertFalse(PhoneCloudReadinessRules.canStartChat(
            harnesses: graff, models: DeviceCatalog(items: auto.items, isLive: false)), "cached model catalog")
        XCTAssertFalse(PhoneCloudReadinessRules.canStartChat(
            harnesses: graff, models: DeviceCatalog(items: [], isLive: true)), "no hosted Auto tier")
        XCTAssertFalse(PhoneCloudReadinessRules.canStartChat(
            harnesses: DeviceCatalog(items: [], isLive: true), models: auto), "no Graff")
    }

    func testCreateUsesPersistentFleetShapeAndMapsGatewayErrors() async throws {
        let calls = Requests()
        let gateway = CloudGateway(apiKey: "cg_sk_test", transport: { request in
            calls.append(request)
            return self.response(#"{"id":"cnd_new","provider":"fleet","state":"started"}"#)
        })
        let sandbox = try await gateway.create(size: PersonalSize(id: "standard", cpu: 2, memoryGiB: 4,
                                                                   diskGiB: 40, pricePerHourMicroUsd: 100_000,
                                                                   isDefault: true))
        XCTAssertEqual(sandbox.id, "cnd_new")
        XCTAssertEqual(calls.all.first?.url?.path, "/v1/sandboxes")
        let body = try XCTUnwrap(calls.all.first?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["provider"] as? String, "fleet")
        XCTAssertEqual(object["persistent"] as? Bool, true)
        XCTAssertEqual(object["keepRunning"] as? Bool, true)
        XCTAssertEqual(object["cpu"] as? Int, 2)

        let rejected = CloudGateway(apiKey: "cg_sk_test", transport: { _ in
            self.response(#"{"error":{"type":"insufficient_credits","message":"no credit"}}"#, status: 402)
        })
        do {
            _ = try await rejected.sandboxes()
            XCTFail("expected gateway rejection")
        } catch let error as CloudGatewayError {
            XCTAssertEqual(error.errorDescription, "no credit")
        }
    }

    func testAmbiguousCreateReconcilesBeforeRetryingBillableCreate() async throws {
        let calls = Requests()
        let credential = GraffGatewayCredential(apiKey: "cg_sk_test", email: "test@example.invalid",
                                                 userId: "phone-cloud-\(UUID().uuidString)",
                                                 edgeURL: "https://edge.example")
        let transport: CloudGateway.Transport = { request in
            calls.append(request)
            let path = request.url?.path ?? ""
            if path == "/v1/sandboxes/personal-sizes" { return self.response(#"{"sizes":[]}"#) }
            if path == "/v1/sandboxes", request.httpMethod == "GET" {
                let createAttempted = calls.all.contains {
                    $0.url?.path == "/v1/sandboxes" && $0.httpMethod == "POST"
                }
                let wasDeleted = calls.all.contains {
                    $0.url?.path == "/v1/sandboxes/cnd_ambiguous" && $0.httpMethod == "DELETE"
                }
                let rows = createAttempted && !wasDeleted
                    ? #"{"sandboxes":[{"id":"cnd_ambiguous","provider":"fleet","state":"running","codegraff":{"harness":true}}]}"#
                    : #"{"sandboxes":[]}"#
                return self.response(rows)
            }
            if path == "/v1/sandboxes" && request.httpMethod == "POST" {
                throw URLError(.timedOut) // the gateway created it, but the reply was lost
            }
            if path == "/v1/sandboxes/cnd_ambiguous", request.httpMethod == "GET" {
                return self.response(#"{"id":"cnd_ambiguous","provider":"fleet","state":"running"}"#)
            }
            return self.response(#"{}"#)
        }

        do {
            _ = try await PhoneCloudSandboxCoordinator(transport: transport).provision(credential, size: nil)
            XCTFail("expected an ambiguous create response")
        } catch is URLError {
            // The pending marker prevents an automatic second paid create.
        }

        let coordinator = PhoneCloudSandboxCoordinator(transport: transport)
        let recovered = try await coordinator.provision(credential, size: nil)
        XCTAssertEqual(recovered.id, "cnd_ambiguous")
        try await coordinator.act(credential, id: recovered.id, action: .delete)

        do {
            _ = try await PhoneCloudSandboxCoordinator(transport: transport).provision(credential, size: nil)
            XCTFail("the next explicit start should reach the gateway again")
        } catch is URLError {
            // A new create is allowed after the ambiguous sandbox was reconciled and deleted.
        }
        XCTAssertEqual(calls.all.filter {
            $0.url?.path == "/v1/sandboxes" && $0.httpMethod == "POST"
        }.count, 2)
    }

    func testArtifactFrameUrlVisibilityAndComputerOffer() async throws {
        let calls = Requests()
        let artId = "art-0123456789abcdef01234567"
        let gateway = CloudGateway(apiKey: "cg_sk_art", transport: { request in
            calls.append(request)
            let path = request.url?.path ?? ""
            if path == "/v1/artifacts/\(artId)/frame-url" && request.httpMethod == "POST" {
                return self.response(#"{"id":"art-0123456789abcdef01234567","visibility":"private","url":"https://codegraff.com/a/art-0123456789abcdef01234567","publicUrl":null,"frameUrl":"https://artifact.codegraff.com/art-0123456789abcdef01234567?t=1900000900.sig","frameExpiresAt":1900000900}"#)
            }
            if path == "/v1/artifacts/\(artId)" && request.httpMethod == "PATCH" {
                return self.response(#"{"id":"art-0123456789abcdef01234567","title":"Diagram","format":"html","visibility":"public","url":"https://codegraff.com/a/art-0123456789abcdef01234567","publicUrl":"https://codegraff.com/public/a/art-0123456789abcdef01234567","frameUrl":"https://artifact.codegraff.com/art-0123456789abcdef01234567"}"#)
            }
            if path == "/api/computer/offer" && request.httpMethod == "GET" {
                return self.response(#"{"enabled":true,"onSale":1,"freeSlots":0,"totalSlots":1,"priceMonthlyUsd":50,"spec":{"cpu":4,"memoryGiB":8,"diskGiB":60},"offer":{"state":"active","slot":1},"live":{"phase":"ready","deviceName":"Node D"}}"#)
            }
            return self.response(#"{}"#, status: 404)
        })

        let frame = try await gateway.artifactFrameURL(artId)
        XCTAssertTrue(frame.frameUrl.hasPrefix("https://artifact.codegraff.com/\(artId)?t="))
        XCTAssertEqual(frame.frameExpiresAt, 1900000900)

        let updated = try await gateway.setArtifactVisibility(artId, visibility: "public")
        XCTAssertEqual(updated.visibility, "public")
        XCTAssertEqual(updated.publicUrl, "https://codegraff.com/public/a/\(artId)")

        let computer = try await gateway.computerOffer()
        XCTAssertEqual(computer?.offer?.state, "active")
        XCTAssertEqual(computer?.live.deviceName, "Node D")

        XCTAssertTrue(ArtifactFramePolicy.isAllowedMainFrame(URL(string: frame.frameUrl)!))
        XCTAssertFalse(ArtifactFramePolicy.isAllowedMainFrame(URL(string: "https://evil.example/\(artId)")!))
        XCTAssertFalse(ArtifactFramePolicy.isAllowedMainFrame(URL(string: "https://artifact.codegraff.com/not-an-id")!))

        let disabledGateway = CloudGateway(apiKey: "cg_sk_art", transport: { _ in
            self.response(#"{"enabled":false}"#, status: 404)
        })
        let missingOffer = try await disabledGateway.computerOffer()
        XCTAssertNil(missingOffer)
    }
}
