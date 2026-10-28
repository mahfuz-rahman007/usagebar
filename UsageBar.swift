import Cocoa

// UsageBar — single-file macOS menu bar app. Providers: Claude, Codex, Cursor + local/VPS agents.
// To add a provider: write a func returning Section and add it to the list in refresh() and --print.

struct Line { let label: String; let pct: Double?; let note: String; var url: String? = nil; var red = false }
struct Section { var name: String; var lines: [Line]; var submenu = false }

func sh(_ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    // Drain stdout before waiting: a child that fills the 64 KB pipe would otherwise block forever.
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// curl subprocess instead of URLSession keeps CFNetwork out of the process (~8 MB RSS saved).
func get(_ url: String, headers: [String: String], body: [String: Any]? = nil) -> [String: Any]? {
    var args = ["/usr/bin/curl", "-s", "-m", "20", url]
    headers.forEach { args += ["-H", "\($0): \($1)"] }
    if let b = body, let d = try? JSONSerialization.data(withJSONObject: b) {
        args += ["-H", "Content-Type: application/json", "--data-binary", String(decoding: d, as: UTF8.self)]
    }
    return try? JSONSerialization.jsonObject(with: Data(sh(args).utf8)) as? [String: Any]
}

func parseDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]; return f.date(from: s)
}

func resetsIn(_ d: Date?) -> String {
    guard let d = d else { return "" }
    let s = Int(d.timeIntervalSinceNow); if s <= 0 { return "resets now" }
    let dd = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    return "resets in " + (dd > 0 ? "\(dd)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m")
}

// MARK: Claude (Claude Code / Claude.app share the same account)
func claude() -> Section {
    var s = Section(name: "Claude", lines: [])
    let raw = sh(["/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"])
    guard let j = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
          let tok = (j["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String else {
        s.lines = [Line(label: "Not logged in (run `claude`)", pct: nil, note: "")]; return s
    }
    guard let u = get("https://api.anthropic.com/api/oauth/usage",
                      headers: ["Authorization": "Bearer \(tok)", "anthropic-beta": "oauth-2025-04-20"]) else {
        s.lines = [Line(label: "Token expired or offline — open `claude` once to refresh", pct: nil, note: "", red: true)]; return s
    }
    for l in u["limits"] as? [[String: Any]] ?? [] {
        let kind = l["kind"] as? String ?? "?"
        let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        let label: String
        switch kind {
        case "session": label = "5-hour session"
        case "weekly_all": label = "Weekly (all models)"
        case "weekly_scoped": label = "Weekly \(model ?? "scoped")"
        default: label = kind
        }
        s.lines.append(Line(label: label, pct: l["percent"] as? Double, note: resetsIn(parseDate(l["resets_at"] as? String ?? ""))))
    }
    // Dollar-capped allowances (cloud sessions / extra usage etc.) come as top-level objects with limit_dollars.
    for (_, v) in u {
        guard let d = v as? [String: Any], let lim = d["limit_dollars"] as? Double, let used = d["used_dollars"] as? Double else { continue }
        s.lines.append(Line(label: "Cloud session credit", pct: d["utilization"] as? Double,
                            note: String(format: "$%.0f / $%.0f · ", used, lim) + resetsIn(parseDate(d["resets_at"] as? String ?? ""))))
    }
    if let e = u["extra_usage"] as? [String: Any], e["is_enabled"] as? Bool == true {
        s.lines.append(Line(label: "Extra usage", pct: e["utilization"] as? Double, note: "\(e["used_credits"] ?? 0) / \(e["monthly_limit"] ?? 0)"))
    }
    if let b = (u["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]] {
        let parts = b.compactMap { r -> String? in
            guard let p = r["percent"] as? Double, p > 0 else { return nil }
            return "\(r["display_name"] ?? "") \(Int(p))%" }
        if !parts.isEmpty { s.lines.append(Line(label: "Weekly split", pct: nil, note: parts.joined(separator: ", "))) }
    }
    return s
}

// MARK: Codex (ChatGPT account)
func codex() -> Section {
    var s = Section(name: "Codex", lines: [])
    let path = NSHomeDirectory() + "/.codex/auth.json"
    guard let d = FileManager.default.contents(atPath: path),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let t = j["tokens"] as? [String: Any], let tok = t["access_token"] as? String else {
        s.lines = [Line(label: "Not logged in (run `codex login`)", pct: nil, note: "")]; return s
    }
    guard let u = get("https://chatgpt.com/backend-api/wham/usage",
                      headers: ["Authorization": "Bearer \(tok)", "ChatGPT-Account-Id": t["account_id"] as? String ?? "", "User-Agent": "codex-cli"]),
          let rl = u["rate_limit"] as? [String: Any] else {
        s.lines = [Line(label: "Token expired or offline — run `codex` once to refresh", pct: nil, note: "", red: true)]; return s
    }
    s.name = "Codex (\(u["plan_type"] as? String ?? "?"))"
    for key in ["primary_window", "secondary_window"] {
        guard let w = rl[key] as? [String: Any] else { continue }
        let secs = w["limit_window_seconds"] as? Int ?? 0
        let label = secs >= 604800 ? "Weekly" : secs >= 18000 ? "5-hour" : "\(secs / 3600)h window"
        let reset = Date(timeIntervalSinceNow: TimeInterval(w["reset_after_seconds"] as? Int ?? 0))
        s.lines.append(Line(label: label, pct: w["used_percent"] as? Double, note: resetsIn(reset)))
    }
    if let c = u["credits"] as? [String: Any], let bal = c["balance"] as? String, let b = Double(bal) {
        s.lines.append(Line(label: "Credits balance", pct: nil, note: String(format: "%.0f", b)))
    }
    return s
}

// MARK: Cursor
func cursor() -> Section {
    var s = Section(name: "Cursor", lines: [])
    let db = NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    let tok = sh(["/usr/bin/sqlite3", db, "select value from ItemTable where key='cursorAuth/accessToken'"])
    guard tok.contains("."), let payload = tok.split(separator: ".").dropFirst().first else {
        s.lines = [Line(label: "Not logged in to Cursor", pct: nil, note: "")]; return s
    }
    var b64 = String(payload).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
    guard let pd = Data(base64Encoded: b64), let pj = try? JSONSerialization.jsonObject(with: pd) as? [String: Any],
          let sub = pj["sub"] as? String else { s.lines = [Line(label: "Bad token", pct: nil, note: "")]; return s }
    let uid = String(sub.split(separator: "|").last!)
    let cookie = "WorkosCursorSessionToken=" + (uid + "::" + tok).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    guard let u = get("https://cursor.com/api/usage-summary", headers: ["Cookie": cookie, "User-Agent": "Mozilla/5.0"]),
          let plan = (u["individualUsage"] as? [String: Any])?["plan"] as? [String: Any] else {
        s.lines = [Line(label: "Fetch failed — re-login in Cursor or check network", pct: nil, note: "", red: true)]; return s
    }
    s.name = "Cursor (\(u["membershipType"] as? String ?? "?"))"
    let used = plan["used"] as? Double ?? 0, lim = plan["limit"] as? Double ?? 0
    let reset = resetsIn(parseDate(u["billingCycleEnd"] as? String ?? ""))
    s.lines.append(Line(label: "Included usage", pct: plan["totalPercentUsed"] as? Double,
                        note: String(format: "$%.2f / $%.0f · ", used / 100, lim / 100) + reset))
    // Grok 4.x, Composer and Auto all draw from the "auto" pool; other named models from the "api" pool.
    s.lines.append(Line(label: "Cursor models pool (Auto, Composer, Grok)", pct: plan["autoPercentUsed"] as? Double, note: reset))
    s.lines.append(Line(label: "Other models pool (API)", pct: plan["apiPercentUsed"] as? Double, note: reset))
    if let od = (u["individualUsage"] as? [String: Any])?["onDemand"] as? [String: Any], od["enabled"] as? Bool == true {
        s.lines.append(Line(label: "On-demand", pct: nil, note: String(format: "$%.2f used", (od["used"] as? Double ?? 0) / 100)))
    }
    // Per-model requests this billing cycle (Grok etc. have no exposed quota; this is the closest the API gives).
    // Reads the latest 100 events only.
    if let start = parseDate(u["billingCycleStart"] as? String ?? ""),
       let ev = get("https://cursor.com/api/dashboard/get-filtered-usage-events",
                    headers: ["Cookie": cookie, "User-Agent": "Mozilla/5.0", "Origin": "https://cursor.com"],
                    body: ["teamId": 0, "startDate": Int(start.timeIntervalSince1970 * 1000), "endDate": Int(Date().timeIntervalSince1970 * 1000), "page": 1, "pageSize": 100]) {
        var count: [String: Int] = [:], cents: [String: Double] = [:]
        for e in ev["usageEventsDisplay"] as? [[String: Any]] ?? [] {
            let m = e["model"] as? String ?? "?"
            count[m, default: 0] += 1
            cents[m, default: 0] += (e["tokenUsage"] as? [String: Any])?["totalCents"] as? Double ?? 0
        }
        for (m, n) in count.sorted(by: { $0.key < $1.key }) {
            s.lines.append(Line(label: m, pct: nil, note: "\(n) requests · $\(String(format: "%.2f", cents[m]! / 100)) this cycle"))
        }
    }
    return s
}

// MARK: Agents — local Claude/Codex processes, herdr agents on a VPS.
let home = NSHomeDirectory()
// Optional ~/.config/usagebar.json: {"vpsHost": "my-vps", "herdrPath": "herdr", "ghPath": ghPath, "refreshSeconds": 300, "workingSeconds": 120, "maxChars": 72}
let config: [String: Any] = FileManager.default.contents(atPath: home + "/.config/usagebar.json")
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
let vpsHost = config["vpsHost"] as? String ?? ""
let herdrPath = config["herdrPath"] as? String ?? "herdr"
let refreshSeconds = config["refreshSeconds"] as? Double ?? 300
let workingSeconds = config["workingSeconds"] as? Double ?? 120
let maxChars = config["maxChars"] as? Int ?? 72

func ago(_ d: Date) -> String {
    let s = Int(-d.timeIntervalSinceNow); return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h \((s % 3600) / 60)m"
}

func localAgents() -> Section {
    var s = Section(name: "Local agents", lines: [])
    for prog in ["claude", "codex"] {
        for pid in sh(["/usr/bin/pgrep", "-a", "-x", prog]).split(separator: "\n") {
            let args = sh(["/bin/ps", "-o", "args=", "-p", String(pid)])
            if args.contains("app-server") { continue } // codex helper daemons, not sessions
            let cwd = sh(["/usr/sbin/lsof", "-a", "-p", String(pid), "-d", "cwd", "-Fn"]).split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) } ?? "?"
            let proj = (cwd as NSString).lastPathComponent
            let branch = sh(["/usr/bin/git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"])
            var state = "idle", prompt = "", age = ""
            if prog == "claude" {
                // session = newest log in the project dir; "working" = log written within workingSeconds.
                let dir = home + "/.claude/projects/" + cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
                let resumed = args.range(of: "--resume ").map { String(args[$0.upperBound...]).split(separator: " ").first.map(String.init) ?? "" }
                let logs = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") }
                    .map { dir + "/" + $0 }
                    .sorted { (mtime($0) ?? .distantPast) > (mtime($1) ?? .distantPast) }
                if let log = (resumed.flatMap { r in logs.first { $0.contains(r) } } ?? logs.first), let m = mtime(log) {
                    state = -m.timeIntervalSinceNow < workingSeconds ? "working" : "idle"; age = ago(m)
                    prompt = lastPrompt(log)
                }
            }
            let dot = state == "working" ? "●" : "○"
            s.lines.append(Line(label: "\(dot) \(prog) · \(proj)" + (branch.isEmpty ? "" : " @ \(branch)"), pct: nil,
                                note: (prompt.isEmpty ? state : "“\(prompt)”") + (age.isEmpty ? "" : " · \(age) ago")))
        }
    }
    if s.lines.isEmpty { s.lines = [Line(label: "none running", pct: nil, note: "")] }
    return s
}

func mtime(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }

func lastPrompt(_ log: String) -> String {
    guard let h = FileHandle(forReadingAtPath: log) else { return "" }
    let size = (try? h.seekToEnd()) ?? 0; try? h.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
    let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("\"type\":\"user\""), let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let c = (j["message"] as? [String: Any])?["content"] as? String, !c.hasPrefix("<") else { continue }
        return String(c.replacingOccurrences(of: "\n", with: " ").prefix(70))
    }
    return ""
}

func vpsAgents() -> [Section] {
    guard !vpsHost.isEmpty else { return [] }
    var s = Section(name: "VPS agents (\(vpsHost))", lines: [])
    let out = sh(["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", vpsHost,
                  "\(herdrPath) agent list 2>/dev/null; pgrep -f 'claude remote-control' >/dev/null && echo RC_UP"])
    guard !out.isEmpty else { s.lines = [Line(label: "unreachable", pct: nil, note: "", red: true)]; return [s] }
    if let j = out.split(separator: "\n").first.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }),
       let agents = (j["result"] as? [String: Any])?["agents"] as? [[String: Any]] {
        for a in agents {
            let st = a["state"] as? String ?? "?"
            s.lines.append(Line(label: "\(st == "working" ? "●" : st == "blocked" ? "⚠" : "○") \(a["name"] ?? a["agent"] ?? "agent")",
                                pct: nil, note: "\(st) · \((a["title"] as? String ?? "").prefix(60))", red: st == "blocked"))
        }
    }
    s.lines.append(Line(label: out.contains("RC_UP") ? "● claude remote-control" : "○ claude remote-control", pct: nil, note: out.contains("RC_UP") ? "running" : "down"))
    return [s]
}


class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "AI usage")
        item.button?.image?.isTemplate = true; menu.autoenablesItems = false; menu.delegate = self; item.menu = menu
        refresh()
        Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { _ in self.refresh() }
    }

    @objc func refresh() {
        DispatchQueue.global().async {
            let sections = [claude(), codex(), cursor(), localAgents()] + vpsAgents()
            DispatchQueue.main.async { self.render(sections) }
        }
    }

    var cached: [Section] = []
    func menuWillOpen(_ m: NSMenu) { // cheap local refresh so agent states are live when you look
        if let i = cached.firstIndex(where: { $0.name == "Local agents" }) { cached[i] = localAgents(); render(cached) }
    }
    @objc func openURL(_ mi: NSMenuItem) { if let u = mi.representedObject as? String, let url = URL(string: u) { NSWorkspace.shared.open(url) } }

    func render(_ sections: [Section]) {
        cached = sections
        menu.removeAllItems()
        for s in sections {
            let h = NSMenuItem(title: s.name, action: nil, keyEquivalent: "")
            h.attributedTitle = NSAttributedString(string: s.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            menu.addItem(h)
            let target = s.submenu ? NSMenu() : menu
            if s.submenu { h.submenu = target; target.autoenablesItems = false }
            for l in s.lines {
                let pct = l.pct.map { "\(Int($0.rounded()))% used  " } ?? ""
                var text = "   \(pct)\(l.label)" + (l.note.isEmpty ? "" : "  —  \(l.note)")
                if text.count > maxChars { text = String(text.prefix(maxChars - 1)) + "…" } // fixed menu width
                let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                if let p = l.pct, p >= 90 || l.red { mi.attributedTitle = NSAttributedString(string: mi.title, attributes: [.foregroundColor: NSColor.systemRed]) }
                if l.red && l.pct == nil { mi.attributedTitle = NSAttributedString(string: mi.title, attributes: [.foregroundColor: NSColor.systemRed]) }
                if let u = l.url { mi.action = #selector(openURL(_:)); mi.target = self; mi.representedObject = u }
                target.addItem(mi)
            }
            if !s.submenu { menu.addItem(.separator()) }
        }
        menu.addItem(NSMenuItem(title: "Updated \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))", action: nil, keyEquivalent: ""))
        let r = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"); r.target = self; menu.addItem(r)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

if CommandLine.arguments.contains("--print") { // self-check: ./UsageBar.app/Contents/MacOS/UsageBar --print
    for s in [claude(), codex(), cursor(), localAgents()] + vpsAgents() { print(s.name); s.lines.forEach { print("  \($0.pct.map { "\(Int($0.rounded()))%" } ?? "  ") \($0.label)  \($0.note)") } }
    exit(0)
}
let app = NSApplication.shared; let d = App(); app.delegate = d
app.setActivationPolicy(.accessory); app.run()
