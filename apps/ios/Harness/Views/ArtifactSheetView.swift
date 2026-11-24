import SwiftUI
import UIKit
import WebKit

nonisolated enum ArtifactFramePolicy {
    static let sandboxHost = "artifact.codegraff.com"
    static let canonicalOrigin = "https://codegraff.com/a/"
    static let publicOrigin = "https://codegraff.com/public/a/"

    static func isValidId(_ id: String) -> Bool {
        guard id.count == 28, id.hasPrefix("art-") else { return false }
        return id.dropFirst(4).unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    static func isAllowedMainFrame(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == sandboxHost else { return false }
        let path = url.path
        guard path.hasPrefix("/") else { return false }
        let id = String(path.dropFirst())
        return isValidId(id)
    }

    static func shareURL(artifactId: String, visibility: String, fallback: String) -> URL? {
        if visibility == "public" {
            return URL(string: "\(publicOrigin)\(artifactId)")
        }
        return URL(string: fallback) ?? URL(string: "\(canonicalOrigin)\(artifactId)")
    }
}

struct ArtifactCardView: View {
    let artifact: ArtifactPresentation
    let onOpen: () -> Void

    private var formatLabel: String {
        switch artifact.format {
        case "html": return "HTML"
        case "svg": return "SVG"
        case "markdown": return "Markdown"
        default: return "Artifact"
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(Theme.sans(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(formatLabel)
                        Text("·")
                        Text(artifact.visibility == "public" ? "Public" : "Private")
                    }
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hosted-artifact-card-\(artifact.artifactId)")
    }
}

struct ArtifactSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let artifact: ArtifactPresentation
    let hostDeviceId: String?

    @State private var visibility: String
    @State private var frameURL: URL?
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var updatingVisibility = false
    @State private var reloadToken = UUID()

    init(artifact: ArtifactPresentation, hostDeviceId: String?) {
        self.artifact = artifact
        self.hostDeviceId = hostDeviceId
        _visibility = State(initialValue: artifact.visibility)
    }

    private var shareURL: URL? {
        ArtifactFramePolicy.shareURL(artifactId: artifact.artifactId, visibility: visibility,
                                     fallback: artifact.url)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let frameURL {
                    EphemeralArtifactWebView(url: frameURL, reloadToken: reloadToken)
                        .ignoresSafeArea(edges: .bottom)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't open artifact", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { Task { await loadFrameURL() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView("Preparing sandbox…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(artifact.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await toggleVisibility() }
                    } label: {
                        Label(visibility == "public" ? "Public" : "Private",
                              systemImage: visibility == "public" ? "globe" : "lock")
                    }
                    .disabled(updatingVisibility)
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    Button {
                        if frameURL != nil {
                            reloadToken = UUID()
                        } else {
                            Task { await loadFrameURL() }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            }
        }
        .task(id: artifact.artifactId) {
            await loadFrameURL()
        }
        .harnessAppearance()
    }

    private func loadFrameURL() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let reply = try await model.artifactFrameURL(artifactId: artifact.artifactId,
                                                         hostDeviceId: hostDeviceId)
            visibility = reply.visibility
            guard let url = URL(string: reply.frameUrl),
                  ArtifactFramePolicy.isAllowedMainFrame(url) else {
                errorMessage = "Received an invalid sandbox URL for this artifact."
                return
            }
            frameURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleVisibility() async {
        guard !updatingVisibility else { return }
        let next = visibility == "public" ? "private" : "public"
        updatingVisibility = true
        defer { updatingVisibility = false }
        do {
            let updated = try await model.setArtifactVisibility(artifactId: artifact.artifactId,
                                                                visibility: next,
                                                                hostDeviceId: hostDeviceId)
            visibility = updated.visibility
            if let raw = updated.frameUrl, let url = URL(string: raw),
               ArtifactFramePolicy.isAllowedMainFrame(url) {
                frameURL = url
            } else {
                await loadFrameURL()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EphemeralArtifactWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.loadedURL = url
        context.coordinator.reloadToken = reloadToken
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url || context.coordinator.reloadToken != reloadToken {
            context.coordinator.loadedURL = url
            context.coordinator.reloadToken = reloadToken
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var reloadToken: UUID?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let isMain = navigationAction.targetFrame?.isMainFrame ?? true
            if isMain {
                if ArtifactFramePolicy.isAllowedMainFrame(target) {
                    decisionHandler(.allow)
                } else {
                    if target.scheme?.lowercased() == "https" || target.scheme?.lowercased() == "http" {
                        UIApplication.shared.open(target)
                    }
                    decisionHandler(.cancel)
                }
                return
            }
            if target.scheme?.lowercased() == "https" || target == URL(string: "about:blank") {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
