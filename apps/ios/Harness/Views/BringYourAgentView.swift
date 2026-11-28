// "Bring in your agent" (BringYourAgent.kt on Android): what Home shows while nothing has been started, until one of
// Graff, Claude Code or OpenAI Codex is ready on a computer that is online. Harness runs the agent on the computer and
// this app is the remote, so it says what each computer has, what is missing, and, with no computer at all, how to get
// the download link onto one. The rules are in AgentReadiness; the copy is pinned in apps/parity/ux-contract.json.

import SwiftUI

struct BringYourAgentView: View {
    @Environment(AppModel.self) private var model
    @State private var readiness: AgentReadiness?
    @State private var phoneCloudSandboxId: String?
    @State private var phoneCloudRate: String?
    @State private var phoneCloudStatus: String?
    @State private var phoneCloudFailure: String?
    @State private var phoneCloudBusy = false
    @State private var confirmPhoneCloudStart = false
    @State private var openedChat = false

    let onPhoneCloudReady: (String) -> Void
    private let downloadURL = URL(string: AgentReadiness.downloadURL)!

    var body: some View {
        Group {
            let noComputer = readiness?.state == .noComputer
            if (readiness.map { $0.state != .ready } ?? true)
                || phoneCloudSandboxId != nil || phoneCloudBusy || phoneCloudFailure != nil {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if noComputer { getHarness }
                    if noComputer || phoneCloudSandboxId != nil || phoneCloudBusy || phoneCloudFailure != nil {
                        phoneCloudCard
                    }
                    if let readiness, readiness.state != .ready { agentCards(readiness) }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding-agents")
            } else {
                Text("No sessions yet — start one with +")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textFaint)
                    .accessibilityIdentifier("home-empty")
            }
        }
        .alert("Start a cloud sandbox?", isPresented: $confirmPhoneCloudStart) {
            Button("Start a cloud sandbox") { Task { await startPhoneCloud() } }
                .accessibilityIdentifier("onboarding-cloud-confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("onboarding-cloud-cancel")
        } message: {
            Text("\(phoneCloudRate ?? "Rate unavailable") · billed per second until you turn it off in Settings → Cloud sandboxes.")
        }
        .task {
            await refreshPhoneCloudRate()
            while !Task.isCancelled {
                readiness = await model.agentReadiness()
                try? await Task.sleep(for: .seconds(readiness?.state == .ready ? 30 : 4))
            }
        }
    }

    private var phoneCloudCard: some View {
        SheetCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Or start one in the cloud")
                    .font(Theme.sans(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Harness will prepare a private cloud machine and open a Graff chat when it is actually ready.")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let phoneCloudStatus {
                    Label(phoneCloudStatus, systemImage: phoneCloudBusy ? "arrow.triangle.2.circlepath" : "cloud.fill")
                        .font(Theme.sans(13, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .accessibilityIdentifier("onboarding-cloud-status")
                }
                if let phoneCloudFailure {
                    Text(phoneCloudFailure)
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.danger)
                        .accessibilityIdentifier("onboarding-cloud-error")
                }
                HStack {
                    if phoneCloudBusy { ProgressView().controlSize(.small) }
                    Button {
                        if !model.hasPhoneGatewayKey {
                            model.startSignIn()
                        } else if let phoneCloudSandboxId {
                            Task { await waitForPhoneCloud(id: phoneCloudSandboxId) }
                        } else {
                            Task {
                                if await refreshPhoneCloudRate() {
                                    confirmPhoneCloudStart = true
                                } else {
                                    phoneCloudFailure = "CodeGraff has not returned a price yet. No sandbox was started."
                                }
                            }
                        }
                    } label: {
                        Text(cloudButtonTitle)
                            .font(Theme.sans(14, weight: .semibold))
                            .foregroundStyle(Theme.bg)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Theme.text, in: Capsule())
                    }
                    .disabled(phoneCloudBusy || model.signInBusy)
                    .accessibilityIdentifier("onboarding-cloud-start")
                    if model.signInBusy { ProgressView().controlSize(.small) }
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cloudButtonTitle: String {
        if !model.hasPhoneGatewayKey { return model.signInBusy ? "Signing in…" : "Sign in again to get a cloud key" }
        if phoneCloudBusy { return "Preparing cloud sandbox…" }
        if phoneCloudSandboxId != nil { return "Check readiness again" }
        return "Start a cloud sandbox · \(phoneCloudRate ?? "checking rate…")"
    }

    @discardableResult
    private func refreshPhoneCloudRate() async -> Bool {
        guard model.hasPhoneGatewayKey else { return false }
        do {
            let list = try await model.cloudSandboxes(deviceId: model.deviceId)
            guard let price = list?.sizes.first(where: \.isDefault)?.pricePerHourMicroUsd
                ?? list?.sizes.first?.pricePerHourMicroUsd
                ?? list?.sandboxes.first(where: { $0.provider == "fleet" })?.pricePerHourMicroUsd else {
                return false
            }
            phoneCloudRate = CloudSandboxRules.formatRate(price)
            phoneCloudFailure = nil
            return true
        } catch {
            phoneCloudFailure = error.localizedDescription
            return false
        }
    }

    private func startPhoneCloud() async {
        guard !phoneCloudBusy, model.hasPhoneGatewayKey else { return }
        phoneCloudBusy = true
        phoneCloudFailure = nil
        phoneCloudStatus = "Creating or reusing your cloud sandbox…"
        do {
            let id = try await model.startPhoneCloudSandbox(size: nil)
            phoneCloudSandboxId = id
            phoneCloudStatus = "Waiting for Harness and Graff to come online…"
            phoneCloudBusy = false
            await waitForPhoneCloud(id: id)
        } catch {
            phoneCloudFailure = error.localizedDescription
            phoneCloudStatus = nil
        }
        phoneCloudBusy = false
    }

    private func waitForPhoneCloud(id: String) async {
        guard !phoneCloudBusy else { return }
        phoneCloudBusy = true
        phoneCloudFailure = nil
        for _ in 0..<90 {
            switch await model.phoneCloudChatReadiness(sandboxId: id) {
            case .ready(let deviceId):
                phoneCloudStatus = "Graff is ready. Opening your chat…"
                if !openedChat {
                    openedChat = true
                    onPhoneCloudReady(deviceId)
                }
                phoneCloudBusy = false
                return
            case .waitingForDevice:
                phoneCloudStatus = "Waiting for the cloud machine to connect…"
            case .waitingForAgent:
                phoneCloudStatus = "Waiting for Graff to start on the cloud machine…"
            case .waitingForModel:
                phoneCloudStatus = "Checking Graff’s hosted Auto models…"
            }
            try? await Task.sleep(for: .seconds(4))
        }
        phoneCloudBusy = false
        phoneCloudStatus = "The sandbox is running, but its chat setup is not ready yet."
        phoneCloudFailure = "It is safe to check again; this phone will not create another sandbox."
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bring in your agent")
                .font(Theme.sans(22, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Harness runs your agent on your computer, and this app is the remote. Add one of these there, then start a session from here.")
                .font(Theme.sans(14))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// No computer online: the link that gets Harness onto one, ready to AirDrop, message or mail to yourself.
    private var getHarness: some View {
        SheetCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Get Harness on your computer")
                    .font(Theme.sans(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Open the link on your computer, install Harness, and sign in with the same CodeGraff account. Your computer shows up here once it's online.")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    ShareLink(item: downloadURL, message: Text("Get Harness for your computer")) {
                        Label("Send the link to your computer", systemImage: "square.and.arrow.up")
                            .font(Theme.sans(14, weight: .semibold))
                            .foregroundStyle(Theme.bg)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Theme.text, in: Capsule())
                    }
                    .accessibilityIdentifier("onboarding-share-link")
                    Button {
                        UIPasteboard.general.url = downloadURL
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Text("Copy link")
                            .font(Theme.sans(14, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("onboarding-copy-link")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func agentCards(_ readiness: AgentReadiness) -> some View {
        SheetCard {
            ForEach(Array(readiness.rows.enumerated()), id: \.element.agent.id) { index, row in
                if index > 0 { SheetSeparator() }
                agentRow(row, noComputer: readiness.state == .noComputer)
            }
        }
    }

    private func agentRow(_ row: AgentReadiness.Row, noComputer: Bool) -> some View {
        let (headline, hint) = describe(row, noComputer: noComputer)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.status == .ready ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(row.status == .ready ? Theme.text : Theme.textFaint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.agent.name)
                    .font(Theme.sans(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(row.agent.blurb)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(headline)
                    .font(Theme.sans(12.5, weight: .medium))
                    .foregroundStyle(row.status == .ready ? Theme.text : Theme.textMuted)
                    .padding(.top, 2)
                if let hint {
                    Text(hint)
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding-agent-\(row.agent.id)")
        .accessibilityValue(row.status.wireName)
    }

    /// What to say about one agent: where it stands, and the one thing to do about it.
    private func describe(_ row: AgentReadiness.Row, noComputer: Bool) -> (String, String?) {
        if noComputer { return ("Needs a computer", nil) }
        let names = row.deviceIds.map(model.deviceName).joined(separator: ", ")
        func on(_ prefix: String) -> String { "\(prefix) \(names)" }
        switch row.status {
        case .ready:
            return (on("Ready on"), nil)
        case .off:
            return (on("Switched off on"), "Turn it on in Settings → Agents on that computer.")
        case .canInstall:
            return (on("Not installed on"), "Install it from Settings → Agents on that computer.")
        case .missing:
            return (on("Not found on"), "Install it on that computer and it will appear here.")
        }
    }
}
