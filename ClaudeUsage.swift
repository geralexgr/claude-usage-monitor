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

// Cached org ID — resolved once at startup, reused on every refresh.
// Only cleared if the server returns 401/403 so we re-resolve after a cookie change.
var cachedOrgId: String? = nil

func fetchUsage(completion: @escaping (UsageResult) -> Void) {
    let cookie = readSessionKey()
    guard !cookie.isEmpty, cookie != "PASTE_YOUR_COOKIE_HERE" else {
        completion(UsageResult(status: "no_cookie")); return
    }

    // If we already have the org ID, skip the first API call entirely
    if let orgId = cachedOrgId {
        fetchOrgUsage(orgId: orgId, cookie: cookie, completion: completion)
        return
    }

    // First run (or after cookie change): resolve and cache the org ID
    apiGet(path: "/api/organizations", cookie: cookie) { data, code in
        if code == 401 || code == 403 {
            cachedOrgId = nil
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

        cachedOrgId = orgId  // cache it — never look it up again unless needed
        print("[DEBUG] org ID resolved and cached:", orgId)
        fetchOrgUsage(orgId: orgId, cookie: cookie, completion: completion)
    }
}


func fetchOrgUsage(orgId: String, cookie: String,
                   completion: @escaping (UsageResult) -> Void) {
    apiGet(path: "/api/organizations/\(orgId)/usage", cookie: cookie) { data, code in
        if code == 401 || code == 403 {
            cachedOrgId = nil  // force re-resolve after cookie is updated
            completion(UsageResult(status: "invalid_cookie")); return
        }
        guard let data = data else {
            // Network hiccup — don't clear cache, just skip this tick
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

let menuWidth: CGFloat = 300

func tint(_ pct: Double) -> NSColor {
    pct < 50 ? .systemGreen : pct < 80 ? .systemOrange : .systemRed
}

func nowStr() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
}

func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

// Colors are resolved at draw time, so the image follows light/dark mode
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { r in
        image.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        return true
    }
}

// Menu bar icon: a circular gauge, colored by how much of the window is used
func ringImage(_ pct: Double?) -> NSImage {
    NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        let lw: CGFloat = 2.5
        let r = rect.insetBy(dx: lw / 2 + 0.5, dy: lw / 2 + 0.5)
        let track = NSBezierPath(ovalIn: r)
        track.lineWidth = lw
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        track.stroke()

        guard let pct = pct, pct > 0 else { return true }
        let frac = CGFloat(min(100, pct) / 100)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: r.width / 2,
                      startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
        arc.lineWidth = lw
        arc.lineCapStyle = .round
        tint(pct).setStroke()
        arc.stroke()
        return true
    }
}

// ── Menu views ────────────────────────────────────────────────────────────────

// Rounded "platter" behind each block, like Control Center modules
func drawCard(_ rect: NSRect) {
    NSColor.labelColor.withAlphaComponent(0.06).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
}

class HeaderView: NSView {
    var subtitle = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    init() { super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 46)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let x: CGFloat = 18
        ("Claude Usage" as NSString).draw(at: NSPoint(x: x, y: 7), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor])
        (subtitle as NSString).draw(at: NSPoint(x: x, y: 27), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor])
    }
}

class UsageCardView: NSView {
    let title: String
    var pct:   Double = 0
    var reset: String = "—"
    override var isFlipped: Bool { true }

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 78))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }

    var resetText: String {
        reset == "—" && pct == 0 ? "Not started yet" : "Resets \(reset)"
    }

    func update(pct: Double, reset: String) {
        self.pct = pct; self.reset = reset
        setAccessibilityLabel("\(title), \(Int(pct)) percent used, \(resetText)")
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let card  = bounds.insetBy(dx: 8, dy: 3)
        let inner = card.insetBy(dx: 10, dy: 10)
        drawCard(card)

        (title as NSString).draw(at: inner.origin, withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor])

        let pctStr = "\(Int(pct))%" as NSString
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor]
        let pw = pctStr.size(withAttributes: pctAttrs).width
        pctStr.draw(at: NSPoint(x: inner.maxX - pw, y: inner.minY), withAttributes: pctAttrs)

        // Capsule progress bar
        let bar = NSRect(x: inner.minX, y: inner.minY + 24, width: inner.width, height: 6)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        if pct > 0 {
            var fill = bar
            fill.size.width = max(bar.height, bar.width * CGFloat(min(100, pct) / 100))
            tint(pct).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }

        (resetText as NSString).draw(at: NSPoint(x: inner.minX, y: inner.minY + 38), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor])
    }
}

class MessageView: NSView {
    let icon:   NSImage?
    let title:  String
    let detail: String
    override var isFlipped: Bool { true }

    static let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.labelColor]
    static let detailAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor]

    // Card inset 8 + padding 10, icon column 28
    static let textX: CGFloat = 18 + 28
    static var textWidth: CGFloat { menuWidth - textX - 18 }

    init(symbol name: String, color: NSColor, title: String, detail: String) {
        self.icon   = symbol(name, size: 16, weight: .medium).map { tinted($0, color) }
        self.title  = title
        self.detail = detail
        let dh = (detail as NSString).boundingRect(
            with: NSSize(width: MessageView.textWidth, height: 1000),
            options: [.usesLineFragmentOrigin], attributes: MessageView.detailAttrs).height
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: ceil(dh) + 52))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(title). \(detail)")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let card  = bounds.insetBy(dx: 8, dy: 3)
        let inner = card.insetBy(dx: 10, dy: 10)
        drawCard(card)

        if let icon = icon {
            let s = icon.size
            icon.draw(in: NSRect(x: inner.minX + (20 - s.width) / 2, y: inner.minY + (18 - s.height) / 2,
                                 width: s.width, height: s.height),
                      from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
        let x = MessageView.textX
        (title as NSString).draw(at: NSPoint(x: x, y: inner.minY), withAttributes: MessageView.titleAttrs)
        (detail as NSString).draw(
            with: NSRect(x: x, y: inner.minY + 20, width: MessageView.textWidth, height: bounds.height),
            options: [.usesLineFragmentOrigin], attributes: MessageView.detailAttrs)
    }
}

func viewItem(_ v: NSView) -> NSMenuItem {
    let it = NSMenuItem()
    it.view = v
    return it
}

// ── App Delegate ──────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var timer: Timer?
    var result      = UsageResult()
    var lastUpdated = "--:--:--"

    let menu         = NSMenu()
    let header       = HeaderView()
    let fiveHourCard = UsageCardView(title: "5-hour window")
    let sevenDayCard = UsageCardView(title: "7-day window")
    var shownStatus: String? = nil

    func applicationDidFinishLaunching(_ n: Notification) {
        ensureConfigExists()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.menu = menu
        render()
        doFetch()
        // .common mode keeps the menu updating while it is open
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.doFetch() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func doFetch() {
        fetchUsage { [weak self] r in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.result      = r
                self.lastUpdated = nowStr()
                self.render()
            }
        }
    }

    func render() {
        let b = statusItem.button
        switch result.status {
        case "":
            b?.image = ringImage(nil);                     b?.title = "…"
        case "ok":
            b?.image = ringImage(result.fiveHourPct);      b?.title = "\(Int(result.fiveHourPct))%"
        case "invalid_cookie":
            b?.image = symbol("key.fill");                 b?.title = "Bad cookie"
        case "no_cookie":
            b?.image = symbol("gearshape");                b?.title = "Setup needed"
        default:
            b?.image = symbol("exclamationmark.triangle"); b?.title = result.status
        }
        b?.image?.isTemplate = !["", "ok"].contains(result.status)

        switch result.status {
        case "":   header.subtitle = "Loading…"
        case "ok": header.subtitle = "Updated \(lastUpdated)  ·  refreshes every 10s"
        default:   header.subtitle = "Last checked \(lastUpdated)"
        }
        fiveHourCard.update(pct: result.fiveHourPct, reset: result.fiveHourReset)
        sevenDayCard.update(pct: result.sevenDayPct, reset: result.sevenDayReset)

        // Views update in place; the item list only changes when the state does
        if result.status != shownStatus {
            shownStatus = result.status
            buildMenu()
        }
    }

    func buildMenu() {
        menu.removeAllItems()
        func act(_ s: String, _ icon: String, _ key: String, _ sel: Selector) -> NSMenuItem {
            let it = NSMenuItem(title: s, action: sel, keyEquivalent: key)
            it.image = symbol(icon)
            it.target = self; return it
        }

        menu.addItem(viewItem(header))

        switch result.status {
        case "":
            menu.addItem(viewItem(MessageView(
                symbol: "hourglass", color: .secondaryLabelColor,
                title: "Loading usage…", detail: "Contacting claude.ai")))
        case "ok":
            menu.addItem(viewItem(fiveHourCard))
            menu.addItem(viewItem(sevenDayCard))
        case "no_cookie":
            menu.addItem(viewItem(MessageView(
                symbol: "key.fill", color: .systemOrange, title: "Setup needed",
                detail: "Paste your claude.ai sessionKey cookie into the config file.")))
        case "invalid_cookie":
            menu.addItem(viewItem(MessageView(
                symbol: "key.fill", color: .systemRed, title: "Cookie expired",
                detail: "Update the sessionKey value in the config file.")))
        default:
            menu.addItem(viewItem(MessageView(
                symbol: "exclamationmark.triangle.fill", color: .systemOrange,
                title: "Couldn't load usage",
                detail: "\(result.status) — check terminal for [DEBUG] output.")))
        }

        menu.addItem(.separator())
        menu.addItem(act("Refresh Now",        "arrow.clockwise",     "r", #selector(refreshNow)))
        menu.addItem(act("Open Usage Page",    "chart.bar.xaxis",     "",  #selector(openPage)))
        menu.addItem(act("Open Config File",   "doc.text",            ",", #selector(openConfig)))
        menu.addItem(act("How to Get Cookie…", "questionmark.circle", "",  #selector(showHelp)))
        menu.addItem(.separator())
        menu.addItem(act("Quit",               "power",               "q", #selector(quit)))
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
        a.icon = symbol("key.fill", size: 32)
        a.addButton(withTitle: "Open Config File")
        a.addButton(withTitle: "Close")
        // Accessory apps aren't frontmost by default; bring the alert forward
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(configPath) }
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

let app      = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
