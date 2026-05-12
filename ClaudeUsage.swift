// ClaudeUsage.swift
// Compile: swiftc ClaudeUsage.swift -o ClaudeUsage -framework Cocoa
// Run:     ./ClaudeUsage

import Cocoa

// ── Config ────────────────────────────────────────────────────────────────────

let configPath = FileManager.default.homeDirectoryForCurrentUser
                     .appendingPathComponent(".claude_usage.conf")

let configTemplate = """
# Claude Usage Monitor — config file
# ------------------------------------
# Paste your claude.ai sessionKey cookie value after the = sign.
# No quotes needed. Save the file — the app picks it up automatically.
#
# How to get it:
#   1. Open https://claude.ai in your browser (logged in)
#   2. Press Option+Cmd+I → Application tab → Cookies → https://claude.ai
#   3. Find the row named "sessionKey" and copy its full Value
#   4. Paste it below and save this file

sessionKey=PASTE_YOUR_COOKIE_HERE
"""

func ensureConfigExists() {
    guard !FileManager.default.fileExists(atPath: configPath.path) else { return }
    try? configTemplate.write(to: configPath, atomically: true, encoding: .utf8)
}

func readSessionKey() -> String {
    guard let text = try? String(contentsOf: configPath, encoding: .utf8) else { return "" }
    for line in text.components(separatedBy: .newlines) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#") else { continue }
        if t.lowercased().hasPrefix("sessionkey=") {
            return String(t.dropFirst("sessionkey=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
    return ""
}

// ── Data model ────────────────────────────────────────────────────────────────

struct UsageResult {
    var fiveHourPct:   Double = 0
    var sevenDayPct:   Double = 0
    var fiveHourReset: String = ""
    var sevenDayReset: String = ""
    var status:        String = ""
}

// ── HTTP ──────────────────────────────────────────────────────────────────────

func apiGet(path: String, cookie: String,
            completion: @escaping (Data?, Int) -> Void) {
    guard let url = URL(string: "https://claude.ai\(path)") else {
        completion(nil, 0); return
    }
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.httpMethod = "GET"
    req.setValue("sessionKey=\(cookie)",             forHTTPHeaderField: "Cookie")
    req.setValue("application/json, */*",            forHTTPHeaderField: "Accept")
    req.setValue("https://claude.ai",                forHTTPHeaderField: "Origin")
    req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
    req.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent")
    req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        completion(data, code)
    }.resume()
}

// ── Org ID extraction — handles all known response shapes ─────────────────────

func extractOrgId(from data: Data) -> String? {
    let raw = String(data: data, encoding: .utf8) ?? ""
    print("[DEBUG] /api/organizations response:", raw.prefix(600))

    // Shape 1: [ { "uuid": "...", "id": 123, ... }, ... ]  ← claude.ai actual format
    if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        for item in arr {
            // Prefer "uuid" (string) over "id" (may be an integer)
            if let uuid = item["uuid"] as? String { return uuid }
            if let id   = item["id"]   as? String { return id   }
            if let org  = item["organization"] as? [String: Any] {
                if let uuid = org["uuid"] as? String { return uuid }
                if let id   = org["id"]   as? String { return id   }
            }
        }
    }

    // Shape 2: { "uuid": "...", ... }
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let uuid = obj["uuid"] as? String { return uuid }
        if let id   = obj["id"]   as? String { return id   }
        if let arr  = obj["organizations"] as? [[String: Any]] {
            if let uuid = arr.first?["uuid"] as? String { return uuid }
            if let id   = arr.first?["id"]   as? String { return id   }
        }
    }

    // Regex fallback — grab any UUID from the response
    let pattern = #""uuid"\s*:\s*"([0-9a-f\-]{36})""#
    if let re = try? NSRegularExpression(pattern: pattern),
       let m  = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
       let r  = Range(m.range(at: 1), in: raw) {
        return String(raw[r])
    }

    return nil
}

// ── Fetch chain ───────────────────────────────────────────────────────────────

func fetchUsage(completion: @escaping (UsageResult) -> Void) {
    let cookie = readSessionKey()
    guard !cookie.isEmpty, cookie != "PASTE_YOUR_COOKIE_HERE" else {
        completion(UsageResult(status: "no_cookie")); return
    }

    apiGet(path: "/api/organizations", cookie: cookie) { data, code in
        if code == 401 || code == 403 {
            completion(UsageResult(status: "invalid_cookie")); return
        }
        guard let data = data else {
            completion(UsageResult(status: "no_data (http \(code))")); return
        }

        guard let orgId = extractOrgId(from: data) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            print("[DEBUG] Could not extract org ID. Full response:", raw)
            completion(UsageResult(status: "org_not_found")); return
        }

        print("[DEBUG] org ID:", orgId)
        fetchOrgUsage(orgId: orgId, cookie: cookie, completion: completion)
    }
}

func fetchOrgUsage(orgId: String, cookie: String,
                   completion: @escaping (UsageResult) -> Void) {
    apiGet(path: "/api/organizations/\(orgId)/usage", cookie: cookie) { data, code in
        if code == 401 || code == 403 {
            completion(UsageResult(status: "invalid_cookie")); return
        }
        guard let data = data else {
            completion(UsageResult(status: "no_data")); return
        }

        let raw = String(data: data, encoding: .utf8) ?? ""
        print("[DEBUG] /usage response:", raw.prefix(800))

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(UsageResult(status: "parse_error")); return
        }

        func pct(_ key: String) -> Double {
            (json[key] as? [String: Any])?["utilization"] as? Double ?? 0
        }
        func resetAt(_ key: String) -> String {
            let s = (json[key] as? [String: Any])?["resets_at"] as? String ?? ""
            return formatReset(s)
        }

        completion(UsageResult(
            fiveHourPct:   pct("five_hour"),
            sevenDayPct:   pct("seven_day"),
            fiveHourReset: resetAt("five_hour"),
            sevenDayReset: resetAt("seven_day"),
            status: "ok"
        ))
    }
}

// ── Date helpers ──────────────────────────────────────────────────────────────

func formatReset(_ iso: String) -> String {
    guard !iso.isEmpty else { return "—" }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) { return timeUntil(d) }
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: iso) { return timeUntil(d) }
    return "—"
}

func timeUntil(_ date: Date) -> String {
    let secs = date.timeIntervalSinceNow
    guard secs > 0 else { return "now" }
    let h = Int(secs) / 3600
    let m = (Int(secs) % 3600) / 60
    if h >= 24 { return "in \(h/24)d \(h%24)h" }
    if h > 0   { return "in \(h)h \(m)m" }
    return "in \(m)m"
}

// ── UI helpers ────────────────────────────────────────────────────────────────

func dot(_ pct: Double) -> String { pct < 50 ? "🟢" : pct < 80 ? "🟡" : "🔴" }

func bar(_ pct: Double) -> String {
    let f = min(10, Int(pct / 10))
    return String(repeating: "█", count: f) + String(repeating: "░", count: 10 - f)
}

func nowStr() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
}

// ── App Delegate ──────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var timer: Timer?
    var result      = UsageResult()
    var lastUpdated = "--:--:--"

    func applicationDidFinishLaunching(_ n: Notification) {
        ensureConfigExists()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚪️ …"
        buildMenu()
        doFetch()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.doFetch()
        }
    }

    func doFetch() {
        fetchUsage { [weak self] r in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.result      = r
                self.lastUpdated = nowStr()
                switch r.status {
                case "ok":
                    let p = Int(r.fiveHourPct)
                    self.statusItem.button?.title = "\(dot(r.fiveHourPct)) \(p)%"
                case "invalid_cookie":
                    self.statusItem.button?.title = "🔑 Bad cookie"
                case "no_cookie":
                    self.statusItem.button?.title = "⚪️ Setup needed"
                default:
                    self.statusItem.button?.title = "⚠️ \(r.status)"
                }
                self.buildMenu()
            }
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        func info(_ s: String) -> NSMenuItem {
            let it = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            it.isEnabled = false; return it
        }
        func act(_ s: String, _ sel: Selector) -> NSMenuItem {
            let it = NSMenuItem(title: s, action: sel, keyEquivalent: "")
            it.target = self; return it
        }

        menu.addItem(info("Claude  ·  Usage Monitor"))
        menu.addItem(.separator())

        switch result.status {
        case "ok":
            menu.addItem(info("  5-hour window"))
            menu.addItem(info("  [\(bar(result.fiveHourPct))]  \(Int(result.fiveHourPct))%"))
            menu.addItem(info("  Resets \(result.fiveHourReset)"))
            menu.addItem(.separator())
            menu.addItem(info("  7-day window"))
            menu.addItem(info("  [\(bar(result.sevenDayPct))]  \(Int(result.sevenDayPct))%"))
            menu.addItem(info("  Resets \(result.sevenDayReset)"))
            menu.addItem(.separator())
            menu.addItem(info("  🕐 Updated: \(lastUpdated)"))
            menu.addItem(info("  ↻ Auto-refreshes every 10s"))
        case "no_cookie":
            menu.addItem(info("  ⚠️  No cookie set in config file"))
            menu.addItem(act("      Open Config File…", #selector(openConfig)))
        case "invalid_cookie":
            menu.addItem(info("  🔑  Cookie expired — update config file"))
            menu.addItem(act("      Open Config File…", #selector(openConfig)))
        default:
            menu.addItem(info("  ⚠️  \(result.status)"))
            menu.addItem(info("  Check terminal for [DEBUG] output"))
            menu.addItem(info("  Last tried: \(lastUpdated)"))
        }

        menu.addItem(.separator())
        menu.addItem(act("↻  Refresh Now",        #selector(refreshNow)))
        menu.addItem(act("📊  Open Usage Page",   #selector(openPage)))
        menu.addItem(act("📝  Open Config File",  #selector(openConfig)))
        menu.addItem(act("❓  How to get cookie", #selector(showHelp)))
        menu.addItem(.separator())
        menu.addItem(act("Quit",                  #selector(quit)))

        statusItem.menu = menu
    }

    @objc func refreshNow() { doFetch() }
    @objc func openPage()   { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    @objc func openConfig() { NSWorkspace.shared.open(configPath) }
    @objc func quit()       { NSApplication.shared.terminate(nil) }

    @objc func showHelp() {
        let a = NSAlert()
        a.messageText = "How to get your session cookie"
        a.informativeText = """
1. Open https://claude.ai in your browser (logged in)
2. Press Option + Cmd + I → Application tab → Cookies → https://claude.ai
   (Firefox: Storage tab)
3. Find "sessionKey" → copy its full Value
4. Click "Open Config File", paste after  sessionKey=  and save.

The app re-reads the config on every 10s refresh — no restart needed.
"""
        a.addButton(withTitle: "Open Config File")
        a.addButton(withTitle: "Close")
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(configPath) }
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

let app      = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
