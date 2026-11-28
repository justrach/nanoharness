import Foundation

/// Readiness for the first reply, not merely a successful sandbox create or `/harness` call.
enum PhoneCloudReadiness: Equatable {
    case waitingForDevice
    case waitingForAgent
    case waitingForModel
    case ready(String)
}

enum PhoneCloudReadinessRules {
    static func matchingDevices(sandboxId: String, devices: [DeviceRow]) -> [DeviceRow] {
        let expected = CloudGateway.deviceName(for: sandboxId)
        return devices.filter { $0.platform != "ios" && $0.name == expected }
    }

    static func host(sandboxId: String, devices: [DeviceRow], online: (String) -> Bool) -> DeviceRow? {
        let matches = matchingDevices(sandboxId: sandboxId, devices: devices)
        guard matches.count == 1, let device = matches.first, online(device.id) else { return nil }
        return device
    }

    static func canStartChat(harnesses: DeviceCatalog<HarnessInfo>, models: DeviceCatalog<ModelInfo>) -> Bool {
        harnesses.isLive && harnesses.items.contains { $0.id == ChatMode.harness }
            && models.isLive && !ChatMode.models(from: models.items).isEmpty
    }
}
