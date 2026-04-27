import AppKit
import Foundation
import CommonCrypto
import SQLite3
import Security

// MARK: - Formatting

func progressBar(_ pct: Double, width: Int = 10) -> String {
    let n = Int((max(0, min(100, pct)) / 100.0) * Double(width))
    return String(repeating: "█", count: n) + String(repeating: "░", count: width - n)
}

func timeUntil(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = f.date(from: iso) else { return "" }
    let secs = date.timeIntervalSinceNow
    guard secs > 0 else { return "now" }
    let mins = Int(secs / 60)
    if mins < 60 { return "~\(mins)m" }
    let h = mins / 60; let m = mins % 60
    return m > 0 ? "~\(h)h \(m)m" : "~\(h)h"
}

func fmtCost(_ c: Double) -> String { c >= 10 ? String(format:"$%.1f",c) : String(format:"$%.2f",c) }
func fmtTok(_ n: Int) -> String {
    n >= 1_000_000 ? String(format:"%.1fM",Double(n)/1e6) : n >= 1_000 ? "\(n/1000)K" : "\(n)"
}

// MARK: - Cookie decryption

func keychainKey() -> Data? {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                             kSecAttrService as String: "Claude Safe Storage",
                             kSecAttrAccount as String: "Claude Key",
                             kSecReturnData as String: true,
                             kSecMatchLimit as String: kSecMatchLimitOne]
    var res: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &res) == errSecSuccess, let raw = res as? Data
    else { return nil }

    var dk = Data(count: 16)
    let salt = Data("saltysalt".utf8)
    _ = dk.withUnsafeMutableBytes { dkPtr in
        raw.withUnsafeBytes { pwPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwPtr.baseAddress, raw.count,
                                     saltPtr.baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     dkPtr.baseAddress, 16)
            }
        }
    }
    return dk
}

func decryptCookie(_ enc: Data, key: Data) -> Data? {
    guard enc.count > 3, enc.prefix(3) == Data("v10".utf8) else { return enc }
    let payload = enc.dropFirst(3)
    let iv = Data(repeating: 0x20, count: 16)
    let outSize = payload.count + kCCBlockSizeAES128
    var out = Data(count: outSize); var outLen = 0
    let status: CCCryptorStatus = payload.withUnsafeBytes { inPtr in
        key.withUnsafeBytes { kPtr in
            iv.withUnsafeBytes { ivPtr in
                out.withUnsafeMutableBytes { oPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            kPtr.baseAddress, 16, ivPtr.baseAddress,
                            inPtr.baseAddress, payload.count,
                            oPtr.baseAddress, outSize, &outLen)
                }
            }
        }
    }
    return status == kCCSuccess ? out.prefix(outLen) : nil
}

// MARK: - Claude Desktop cookie reader

struct ClaudeCookies {
    let sessionKey: String
    let cfClearance: String
    let cfBm: String
    let orgId: String
}

func readClaudeCookies() -> ClaudeCookies? {
    guard let aesKey = keychainKey() else { return nil }
    let dbPath = AppSettings.shared.claudeDesktopCookiePath
    let tmp = NSTemporaryDirectory() + "cu_cookies_\(arc4random()).db"
    guard (try? FileManager.default.copyItem(atPath: dbPath, toPath: tmp)) != nil else { return nil }
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    var db: OpaquePointer?
    guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT name, encrypted_value FROM cookies WHERE host_key LIKE '%claude%'",
                              -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }

    var raw: [String: Data] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
        let name = String(cString: namePtr)
        let len = Int(sqlite3_column_bytes(stmt, 1))
        if let ptr = sqlite3_column_blob(stmt, 1), len > 0 {
            raw[name] = Data(bytes: ptr, count: len)
        }
    }

    func extract(_ name: String, _ pattern: String) -> String {
        guard let enc = raw[name], let dec = decryptCookie(enc, key: aesKey) else { return "" }
        let str = String(dec.map { ($0 >= 0x20 && $0 <= 0x7e) ? Character(UnicodeScalar($0)) : "?" })
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m  = re.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
              let r  = Range(m.range, in: str) else { return "" }
        return String(str[r])
    }

    let orgId = extract("lastActiveOrg",
                        "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    let sk    = extract("sessionKey",   "sk-ant-sid\\d+-[A-Za-z0-9_\\-]+")
    let cf    = extract("cf_clearance", "[A-Za-z0-9_\\-\\.]{10,}-\\d{13}-[A-Za-z0-9_\\.]+")
    let cfb   = extract("__cf_bm",      "[A-Za-z0-9_\\-]{30,}-\\d+")
    guard !orgId.isEmpty, !sk.isEmpty else { return nil }
    return ClaudeCookies(sessionKey: sk, cfClearance: cf, cfBm: cfb, orgId: orgId)
}

func credentialsFromSettings() -> ClaudeCookies? {
    let s = AppSettings.shared
    if s.authMode == "auto" { return readClaudeCookies() }
    guard s.manualCredentialsSet else { return nil }
    return ClaudeCookies(sessionKey: s.sessionToken, cfClearance: "", cfBm: "", orgId: s.orgId)
}

// MARK: - Claude.ai usage API

struct UsagePeriod { let utilization: Double; let resetsAt: String? }
struct ClaudeAccountUsage { let session: UsagePeriod; let weekly: UsagePeriod; let design: UsagePeriod? }

func fetchAccountUsage(_ cookies: ClaudeCookies) -> ClaudeAccountUsage? {
    guard let url = URL(string: "https://claude.ai/api/organizations/\(cookies.orgId)/usage") else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.setValue("sessionKey=\(cookies.sessionKey); cf_clearance=\(cookies.cfClearance); __cf_bm=\(cookies.cfBm)",
                 forHTTPHeaderField: "Cookie")
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                 forHTTPHeaderField: "User-Agent")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")

    let sem = DispatchSemaphore(value: 0)
    var result: ClaudeAccountUsage?
    URLSession.shared.dataTask(with: req) { data, _, err in
        defer { sem.signal() }
        guard let data, err == nil,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func period(_ k: String) -> UsagePeriod? {
            guard let d = json[k] as? [String: Any] else { return nil }
            return UsagePeriod(utilization: (d["utilization"] as? NSNumber)?.doubleValue ?? 0,
                               resetsAt: d["resets_at"] as? String)
        }
        guard let s = period("five_hour"), let w = period("seven_day") else { return }
        result = ClaudeAccountUsage(session: s, weekly: w, design: period("seven_day_omelette"))
    }.resume()
    sem.wait()
    return result
}

// MARK: - Local cost tracking

private let pricing: [String: (Double, Double, Double, Double)] = [
    "claude-opus":   (15, 75, 18.75, 1.5),
    "claude-sonnet": (3,  15,  3.75, 0.3),
    "claude-haiku":  (0.8, 4,  1.0,  0.08),
]
private func getP(_ m: String) -> (Double,Double,Double,Double) {
    let ml = m.lowercased()
    return pricing.first { ml.contains($0.key) }?.value ?? pricing["claude-sonnet"]!
}
private func calcCost(_ u: [String:Any], _ model: String) -> Double {
    let p = getP(model)
    func d(_ k: String) -> Double { (u[k] as? NSNumber)?.doubleValue ?? 0 }
    return (d("input_tokens")*p.0 + d("output_tokens")*p.1 +
            d("cache_creation_input_tokens")*p.2 + d("cache_read_input_tokens")*p.3) / 1e6
}

struct PeriodStats { var input = 0; var output = 0; var cost = 0.0 }

func loadLocalCosts() -> (today: PeriodStats, week: PeriodStats, month: PeriodStats) {
    var today = PeriodStats(), week = PeriodStats(), month = PeriodStats()
    let cal = Calendar.current; let now = Date()
    let d0 = cal.startOfDay(for: now)
    let w0 = cal.date(from: cal.dateComponents([.yearForWeekOfYear,.weekOfYear], from: now))!
    let m0 = cal.date(from: cal.dateComponents([.year,.month], from: now))!
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    guard let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
        return (today, week, month)
    }
    var seen = Set<String>()
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso2 = ISO8601DateFormatter()
    for dir in dirs {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
        for f in files where f.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = String(line).data(using: .utf8),
                      let obj  = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
                      obj["type"] as? String == "assistant",
                      let msg   = obj["message"] as? [String:Any],
                      let usage = msg["usage"] as? [String:Any],
                      let ts    = obj["timestamp"] as? String,
                      let date  = iso.date(from: ts) ?? iso2.date(from: ts) else { continue }
                let mid = msg["id"] as? String ?? ""
                if !mid.isEmpty { if seen.contains(mid) { continue }; seen.insert(mid) }
                let cost = calcCost(usage, msg["model"] as? String ?? "")
                let inp  = (usage["input_tokens"]  as? NSNumber)?.intValue ?? 0
                let out  = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
                func add(_ s: inout PeriodStats) { s.input += inp; s.output += out; s.cost += cost }
                if date >= d0 { add(&today) }
                if date >= w0 { add(&week) }
                if date >= m0 { add(&month) }
            }
        }
    }
    return (today, week, month)
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var instance: AppDelegate?
    var statusItem: NSStatusItem!
    var refreshTimer: Timer?
    private var cachedCookies: ClaudeCookies?
    private let cookieQueue = DispatchQueue(label: "com.richardli.claudeusage.cookies")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "claude…"
        statusItem.menu = NSMenu()
        rescheduleTimer()
        refresh()
    }

    func rescheduleTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(AppSettings.shared.refreshInterval)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func invalidateCookieCache() { cookieQueue.sync { cachedCookies = nil } }

    private func getCookies() -> ClaudeCookies? {
        cookieQueue.sync {
            if let cached = cachedCookies { return cached }
            let fresh = credentialsFromSettings()
            cachedCookies = fresh
            return fresh
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let s = AppSettings.shared
            let cookies = s.showPlanUsage ? self.getCookies() : nil
            let account: ClaudeAccountUsage? = cookies.flatMap(fetchAccountUsage)
            let costs = s.showCostData ? loadLocalCosts() : nil
            DispatchQueue.main.async { self.applyData(account: account, costs: costs) }
        }
    }

    func applyData(account: ClaudeAccountUsage?, costs: (today: PeriodStats, week: PeriodStats, month: PeriodStats)?) {
        let s = AppSettings.shared

        // Menu bar title
        if let a = account {
            statusItem.button?.title = String(format: "%.0f%%", a.session.utilization)
        } else if let c = costs {
            statusItem.button?.title = fmtCost(c.today.cost)
        } else {
            statusItem.button?.title = "claude"
        }

        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // ── Plan usage ──────────────────────────────────────────
        if s.showPlanUsage {
            if let a = account {
                menu.addItem(sectionHeader("Plan Usage"))
                let sessionReset = a.session.resetsAt.map { "  resets \(timeUntil($0))" } ?? ""
                menu.addItem(usageBar("Session", a.session.utilization, sessionReset))
                let weekReset = a.weekly.resetsAt.map { "  resets \(timeUntil($0))" } ?? ""
                menu.addItem(usageBar("Weekly",  a.weekly.utilization, weekReset))
                if let d = a.design {
                    menu.addItem(usageBar("Design", d.utilization, ""))
                }
            } else {
                let notConfigured = NSMenuItem(title: s.isConfigured ? "Fetching usage…" : "⚙ Configure in Settings", action: nil, keyEquivalent: "")
                notConfigured.isEnabled = false
                menu.addItem(sectionHeader("Plan Usage"))
                menu.addItem(notConfigured)
            }
            menu.addItem(.separator())
        }

        // ── Cost data ───────────────────────────────────────────
        if s.showCostData, let c = costs {
            menu.addItem(sectionHeader("Claude Code Cost"))
            menu.addItem(costRow("Today",      c.today))
            menu.addItem(costRow("This week",  c.week))
            menu.addItem(costRow("This month", c.month))
            menu.addItem(.separator())
        }

        // ── Footer ──────────────────────────────────────────────
        let upd = NSMenuItem(title: "Updated \(Date().formatted(date: .omitted, time: .shortened))", action: nil, keyEquivalent: "")
        upd.isEnabled = false
        menu.addItem(upd)

        let rItem = NSMenuItem(title: "Refresh", action: #selector(onRefresh), keyEquivalent: "r")
        rItem.target = self; menu.addItem(rItem)

        let sItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        sItem.target = self; menu.addItem(sItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeUsage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Menu item builders

    func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    func usageBar(_ label: String, _ pct: Double, _ suffix: String) -> NSMenuItem {
        let bar  = progressBar(pct)
        let text = String(format: "%-8@  %@  %3.0f%%%@", label as CVarArg, bar, pct, suffix)
        let color: NSColor = pct >= 90 ? .systemRed : pct >= 70 ? .systemOrange : .systemBlue
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: attrs)
        let barRange = (text as NSString).range(of: bar)
        if barRange.location != NSNotFound {
            attributed.addAttribute(.foregroundColor, value: color, range: barRange)
        }
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = attributed
        return item
    }

    func costRow(_ label: String, _ s: PeriodStats) -> NSMenuItem {
        let text = String(format: "%-12@  %@   %@ tok",
                          label as CVarArg, fmtCost(s.cost), fmtTok(s.input + s.output))
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ])
        return item
    }

    // MARK: - Actions

    @objc func onRefresh() { invalidateCookieCache(); refresh() }

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }
}

