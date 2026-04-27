import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    Label("Today    \(store.todayCost)  (\(store.todayTok) tok)", systemImage: "sun.max")
                    Label("Week     \(store.weekCost)  (\(store.weekTok) tok)",   systemImage: "calendar")
                    Label("Month    \(store.monthCost)  (\(store.monthTok) tok)", systemImage: "chart.bar")
                }
                .font(.system(.body, design: .monospaced))

                Divider()

                if !store.topModels.isEmpty {
                    ForEach(store.topModels, id: \.name) { m in
                        Text("  \(m.name.replacingOccurrences(of: "claude-", with: ""))  \(m.cost)")
                            .font(.caption)
                    }
                    Divider()
                }

                Button("Refresh") { store.load() }
                    .keyboardShortcut("r")
                if !store.updatedAt.isEmpty {
                    Text("Updated \(store.updatedAt)").font(.caption2).foregroundColor(.secondary)
                }
                Divider()
                Button("Quit", role: .destructive) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(8)
        } label: {
            Text(store.menuTitle)
        }
    }
}

// MARK: - Store

@MainActor
class UsageStore: ObservableObject {
    @Published var menuTitle  = "claude…"
    @Published var todayCost  = "…"
    @Published var todayTok   = "…"
    @Published var weekCost   = "…"
    @Published var weekTok    = "…"
    @Published var monthCost  = "…"
    @Published var monthTok   = "…"
    @Published var topModels: [ModelStat] = []
    @Published var updatedAt  = ""

    struct ModelStat { let name: String; let cost: String }

    init() { load() }

    func load() {
        Task.detached(priority: .utility) {
            let (d, w, m) = loadUsage()
            await MainActor.run {
                self.menuTitle = fmtCost(d.cost)
                self.todayCost = fmtCost(d.cost); self.todayTok = fmtTokens(d.input + d.output)
                self.weekCost  = fmtCost(w.cost); self.weekTok  = fmtTokens(w.input + w.output)
                self.monthCost = fmtCost(m.cost); self.monthTok = fmtTokens(m.input + m.output)
                self.topModels = m.byModel
                    .sorted { $0.value > $1.value }.prefix(5)
                    .map { ModelStat(name: $0.key, cost: fmtCost($0.value)) }
                let f = DateFormatter(); f.timeStyle = .medium; f.dateStyle = .none
                self.updatedAt = f.string(from: Date())
            }
        }
    }
}

// MARK: - Data

struct Stats { var input = 0; var output = 0; var cost = 0.0; var byModel: [String: Double] = [:] }

let pricing: [String: (Double, Double, Double, Double)] = [
    "claude-opus":   (15,  75,  18.75, 1.5),
    "claude-sonnet": (3,   15,   3.75, 0.3),
    "claude-haiku":  (0.8,  4,   1.0,  0.08),
]
func getP(_ m: String) -> (Double,Double,Double,Double) {
    let ml = m.lowercased()
    return pricing.first(where: { ml.contains($0.key) })?.value ?? pricing["claude-sonnet"]!
}
func calcCost(_ u: [String:Any], _ model: String) -> Double {
    let p = getP(model)
    func d(_ k: String) -> Double { (u[k] as? NSNumber)?.doubleValue ?? 0 }
    return (d("input_tokens")*p.0 + d("output_tokens")*p.1 +
            d("cache_creation_input_tokens")*p.2 + d("cache_read_input_tokens")*p.3) / 1e6
}
func fmtCost(_ c: Double) -> String { c >= 10 ? String(format:"$%.1f",c) : String(format:"$%.2f",c) }
func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format:"%.1fM", Double(n)/1e6) }
    if n >= 1_000     { return "\(n/1000)K" }
    return "\(n)"
}

func loadUsage() -> (Stats, Stats, Stats) {
    var today = Stats(), week = Stats(), month = Stats()
    let cal = Calendar.current; let now = Date()
    let d0 = cal.startOfDay(for: now)
    let w0 = cal.date(from: cal.dateComponents([.yearForWeekOfYear,.weekOfYear], from: now))!
    let m0 = cal.date(from: cal.dateComponents([.year,.month], from: now))!
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    guard let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
    else { return (today, week, month) }

    var seen = Set<String>()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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
                      let date  = iso.date(from: ts) ?? iso2.date(from: ts)
                else { continue }
                let mid = msg["id"] as? String ?? ""
                if !mid.isEmpty { if seen.contains(mid) { continue }; seen.insert(mid) }
                let model = msg["model"] as? String ?? ""
                let cost  = calcCost(usage, model)
                let inp   = (usage["input_tokens"]  as? NSNumber)?.intValue ?? 0
                let out   = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0

                func add(_ s: inout Stats) {
                    s.input += inp; s.output += out; s.cost += cost
                    s.byModel[model, default: 0] += cost
                }
                if date >= d0 { add(&today) }
                if date >= w0 { add(&week) }
                if date >= m0 { add(&month) }
            }
        }
    }
    return (today, week, month)
}
