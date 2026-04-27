import AppKit
import SwiftUI

// MARK: - Settings Model

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let ud = UserDefaults.standard

    @Published var authMode: String       { didSet { ud.set(authMode,       forKey: "authMode") } }
    @Published var sessionToken: String   { didSet { ud.set(sessionToken,   forKey: "sessionToken") } }
    @Published var orgId: String          { didSet { ud.set(orgId,          forKey: "orgId") } }
    @Published var refreshInterval: Int   { didSet { ud.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var showPlanUsage: Bool    { didSet { ud.set(showPlanUsage,  forKey: "showPlanUsage") } }
    @Published var showCostData: Bool     { didSet { ud.set(showCostData,   forKey: "showCostData") } }

    init() {
        authMode        = ud.string(forKey: "authMode")  ?? "auto"
        sessionToken    = ud.string(forKey: "sessionToken") ?? ""
        orgId           = ud.string(forKey: "orgId")     ?? ""
        let ri          = ud.integer(forKey: "refreshInterval")
        refreshInterval = ri > 0 ? ri : 300
        showPlanUsage   = ud.object(forKey: "showPlanUsage") as? Bool ?? true
        showCostData    = ud.object(forKey: "showCostData")  as? Bool ?? true
    }

    var claudeDesktopCookiePath: String {
        NSString("~/Library/Application Support/Claude/Cookies").expandingTildeInPath
    }
    var claudeDesktopPresent: Bool {
        FileManager.default.fileExists(atPath: claudeDesktopCookiePath)
    }
    var manualCredentialsSet: Bool {
        authMode == "manual" && !sessionToken.isEmpty && !orgId.isEmpty
    }
    var isConfigured: Bool {
        (authMode == "auto" && claudeDesktopPresent) || manualCredentialsSet
    }
}

// MARK: - Settings Window

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let win = NSPanel(contentViewController: hosting)
        win.title = "ClaudeUsage Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 460, height: 430))
        win.isMovableByWindowBackground = true
        super.init(window: win)
        win.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window?.isVisible != true { window?.center() }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppDelegate.instance?.invalidateCookieCache()
        AppDelegate.instance?.rescheduleTimer()
        AppDelegate.instance?.refresh()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var statusMsg = ""
    @State private var testing   = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // ── Authentication ──────────────────────────────
                Section {
                    Picker("Source", selection: $s.authMode) {
                        Text("Claude Desktop (automatic)").tag("auto")
                        Text("Manual token").tag("manual")
                    }
                    .pickerStyle(.radioGroup)

                    if s.authMode == "auto" {
                        Label(
                            s.claudeDesktopPresent
                                ? "Claude Desktop detected"
                                : "Claude Desktop not found — use Manual token",
                            systemImage: s.claudeDesktopPresent
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .foregroundColor(s.claudeDesktopPresent ? .green : .orange)
                        .font(.callout)
                    } else {
                        LabeledContent("Session Token") {
                            TextField("sk-ant-sid02-…", text: $s.sessionToken)
                                .font(.system(.body, design: .monospaced))
                        }
                        LabeledContent("Organization ID") {
                            TextField("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: $s.orgId)
                                .font(.system(.body, design: .monospaced))
                        }
                        Text("In your browser, go to claude.ai → DevTools (F12) → Application → Cookies → https://claude.ai.\nCopy **sessionKey** and **lastActiveOrg**.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Text("Authentication") }

                // ── Refresh ─────────────────────────────────────
                Section {
                    Picker("Refresh every", selection: $s.refreshInterval) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("30 minutes").tag(1800)
                    }
                    .pickerStyle(.menu)
                } header: { Text("Refresh") }

                // ── Display ──────────────────────────────────────
                Section {
                    Toggle("Show plan usage limits (from claude.ai)", isOn: $s.showPlanUsage)
                    Toggle("Show Claude Code cost data (local files)",  isOn: $s.showCostData)
                } header: { Text("Display") }
            }
            .formStyle(.grouped)

            // ── Footer ───────────────────────────────────────────
            Divider()
            HStack {
                if !statusMsg.isEmpty {
                    Text(statusMsg).font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                Button(testing ? "Testing…" : "Test Connection") {
                    testing = true; statusMsg = "Connecting…"
                    Task.detached(priority: .userInitiated) {
                        let msg = await testConnection()
                        await MainActor.run { statusMsg = msg; testing = false }
                    }
                }
                .disabled(testing || !s.isConfigured)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 460)
    }
}

@MainActor
private func testConnection() async -> String {
    let cookies: ClaudeCookies? = await Task.detached(priority: .userInitiated) {
        AppSettings.shared.authMode == "auto"
            ? readClaudeCookies()
            : {
                let s = AppSettings.shared
                return ClaudeCookies(sessionKey: s.sessionToken, cfClearance: "", cfBm: "", orgId: s.orgId)
              }()
    }.value

    guard let c = cookies else { return "✗ Could not read credentials" }

    let usage: ClaudeAccountUsage? = await Task.detached(priority: .userInitiated) {
        fetchAccountUsage(c)
    }.value

    guard let u = usage else { return "✗ API request failed — check token" }
    return String(format: "✓ OK — session %.0f%%  weekly %.0f%%",
                  u.session.utilization, u.weekly.utilization)
}
