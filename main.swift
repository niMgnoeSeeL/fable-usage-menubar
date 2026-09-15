import Cocoa
import ServiceManagement
import UserNotifications

// MARK: - Config

/// Fallback weekly reset when plan limits can't be fetched (claude.ai → Settings → Usage). Weekday 1 = Sunday.
let resetWeekday = 1
let resetHour = 6
let refreshInterval: TimeInterval = 60
let limitsInterval: TimeInterval = 300
let maxRows = 15
/// Notify once per weekly window when the Fable limit reaches this percent.
let alertThreshold = 80.0

let home = FileManager.default.homeDirectoryForCurrentUser
let projectsDir = home.appendingPathComponent(".claude/projects").standardizedFileURL
let registryDir = home.appendingPathComponent(".claude/sessions")

func fallbackWeekStart(for now: Date) -> Date {
    var c = DateComponents()
    c.weekday = resetWeekday; c.hour = resetHour; c.minute = 0; c.second = 0
    return Calendar.current.nextDate(after: now, matching: c, matchingPolicy: .nextTime, direction: .backward)
        ?? now.addingTimeInterval(-7 * 86400)
}

// MARK: - Model

struct Usage {
    var input = 0.0, output = 0.0, cacheWrite = 0.0, cacheRead = 0.0
    var calls = 0
    /// Input-token equivalents: in 1, out 5, cache write 1.25 (5m) / 2 (1h), cache read 0.1.
    var weighted = 0.0
    var subagentWeighted = 0.0
}

struct SessionStat {
    let id: String
    let project: String
    var cwd: String?
    var title: String?
    var prompt: String?
    var usage = Usage()
    var last: Date?

    var displayName: String {
        if let t = title, !t.isEmpty { return t }
        if let p = prompt, !p.isEmpty { return p }
        return String(id.prefix(8))
    }
    var folder: String { cwd.map { ($0 as NSString).lastPathComponent } ?? project }
    var avgContext: Double {
        usage.calls == 0 ? 0 : (usage.input + usage.cacheWrite + usage.cacheRead) / Double(usage.calls)
    }
}

struct LiveSession { let status: String? }

struct Snapshot {
    var weekStart: Date
    var nextReset: Date
    var sessions: [SessionStat]
    var total: Double
    var live: [String: LiveSession]
}

// MARK: - Plan limits (same endpoint Claude Code's /usage uses)

struct LimitItem {
    let kind: String
    let label: String
    let percent: Double
    let severity: String
    let resetsAt: Date?
    let isFable: Bool
}

struct PlanLimits {
    let items: [LimitItem]
    let breakdown: [(name: String, percent: Double)]
    let fetchedAt: Date

    var fable: LimitItem? { items.first { $0.isFable } }

    /// Start of the current weekly window, derived from the server's reset time.
    func weekStart(now: Date = Date()) -> Date? {
        guard let reset = (fable ?? items.first { $0.kind == "weekly_all" })?.resetsAt, reset > now else { return nil }
        let start = reset.timeIntervalSince1970 - 7 * 86400
        return Date(timeIntervalSince1970: (start / 60).rounded(.down) * 60)
    }
}

struct LimitsError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func parseAPIDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let noFraction = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: noFraction)
}

enum PlanLimitsClient {
    static func fetch(completion: @escaping (Result<PlanLimits, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let token: String
            do { token = try readToken() } catch { return completion(.failure(error)) }

            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 20)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            URLSession.shared.dataTask(with: req) { data, resp, error in
                if let error { return completion(.failure(error)) }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data else {
                    let hint = status == 401 ? " (토큰 만료: Claude Code를 실행하면 갱신돼요)" : ""
                    return completion(.failure(LimitsError("HTTP \(status)\(hint)")))
                }
                completion(Result { try parse(data) })
            }.resume()
        }
    }

    /// Reads the OAuth access token Claude Code stores in the login keychain. Never refreshes or writes it.
    private static func readToken() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw LimitsError("키체인에서 Claude Code 로그인 정보를 찾지 못했어요")
        }
        return token
    }

    static func parse(_ data: Data) throws -> PlanLimits {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LimitsError("응답 형식을 읽지 못했어요")
        }
        let items: [LimitItem] = ((obj["limits"] as? [[String: Any]]) ?? []).compactMap { l in
            guard let percent = (l["percent"] as? NSNumber)?.doubleValue else { return nil }
            let kind = l["kind"] as? String ?? ""
            let scope = l["scope"] as? [String: Any]
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
            let label: String
            switch kind {
            case "session": label = "현재 세션 (5시간)"
            case "weekly_all": label = "주간 · 모든 모델"
            default: label = "주간 · \(model ?? surface ?? kind)"
            }
            return LimitItem(kind: kind, label: label, percent: percent,
                             severity: l["severity"] as? String ?? "normal",
                             resetsAt: parseAPIDate(l["resets_at"] as? String),
                             isFable: model?.localizedCaseInsensitiveContains("fable") == true)
        }
        guard !items.isEmpty else { throw LimitsError("응답에 한도 정보가 없어요") }
        let rows = ((obj["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]]) ?? []
        let breakdown = rows.compactMap { r -> (name: String, percent: Double)? in
            guard let name = r["display_name"] as? String, let p = (r["percent"] as? NSNumber)?.doubleValue else { return nil }
            return (name, p)
        }
        return PlanLimits(items: items, breakdown: breakdown, fetchedAt: Date())
    }
}

// MARK: - Transcript scanner (incremental: remembers byte offsets per file)

final class Scanner {
    private var weekStart = Date.distantPast
    private var offsets: [String: UInt64] = [:]
    private var seen = Set<String>()
    private var stats: [String: SessionStat] = [:]

    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    private static let fableMarker = Data("\"claude-fable".utf8)
    private static let titleMarker = Data("\"custom-title\"".utf8)
    private static let userMarker = Data("\"type\":\"user\"".utf8)
    private static let cwdMarker = Data("\"cwd\"".utf8)

    func scan(weekStart ws: Date) -> Snapshot {
        if ws != weekStart {
            weekStart = ws; offsets = [:]; seen = []; stats = [:]
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let rootDepth = projectsDir.pathComponents.count
        if let en = FileManager.default.enumerator(at: projectsDir, includingPropertiesForKeys: keys) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let mtime = v.contentModificationDate, mtime >= ws,
                      let size = v.fileSize else { continue }
                // <project>/<session>.jsonl, or <project>/<session>/subagents/...jsonl
                let parts = Array(url.standardizedFileURL.pathComponents.dropFirst(rootDepth))
                guard parts.count >= 2 else { continue }
                let sid = (parts[1] as NSString).deletingPathExtension
                read(url: url, size: UInt64(size), project: parts[0], sid: sid, isSub: parts.count > 2)
            }
        }
        let list = stats.values.filter { $0.usage.calls > 0 }.sorted { $0.usage.weighted > $1.usage.weighted }
        return Snapshot(
            weekStart: ws,
            nextReset: ws.addingTimeInterval(7 * 86400),
            sessions: list,
            total: list.reduce(0) { $0 + $1.usage.weighted },
            live: liveSessions())
    }

    private func read(url: URL, size: UInt64, project: String, sid: String, isSub: Bool) {
        var offset = offsets[url.path] ?? 0
        if size < offset { offset = 0 }
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil else { return }

        var stat = stats[sid] ?? SessionStat(id: sid, project: project)
        var carry = Data()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty {
            carry.append(chunk)
            guard let nl = carry.lastIndex(of: 0x0A) else { continue }
            for line in carry[carry.startIndex..<nl].split(separator: 0x0A) {
                handle(line: line, stat: &stat, isSub: isSub)
            }
            offset += UInt64(nl - carry.startIndex + 1)
            carry = Data(carry[(nl + 1)...])
        }
        // A trailing partial line stays unread until it is completed.
        offsets[url.path] = offset
        stats[sid] = stat
    }

    private func handle(line: Data, stat: inout SessionStat, isSub: Bool) {
        let isFable = line.range(of: Self.fableMarker) != nil
        let isTitle = !isSub && line.range(of: Self.titleMarker) != nil
        let wantPrompt = !isSub && stat.prompt == nil && line.range(of: Self.userMarker) != nil
        let wantCwd = stat.cwd == nil && line.range(of: Self.cwdMarker) != nil
        guard isFable || isTitle || wantPrompt || wantCwd,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }

        let type = obj["type"] as? String
        if stat.cwd == nil, let cwd = obj["cwd"] as? String { stat.cwd = cwd }
        if isTitle, type == "custom-title", let t = obj["customTitle"] as? String { stat.title = t }
        if wantPrompt, type == "user", obj["isMeta"] as? Bool != true,
           let text = promptText(obj), !text.hasPrefix("<") {
            stat.prompt = text
        }

        guard isFable, type == "assistant",
              let msg = obj["message"] as? [String: Any],
              let model = msg["model"] as? String, model.contains("fable"),
              let u = msg["usage"] as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let date = isoFrac.date(from: ts) ?? iso.date(from: ts), date >= weekStart else { return }
        // Streaming writes the same message several times; subagent files can repeat it too.
        let key = "\(msg["id"] as? String ?? "")|\(obj["requestId"] as? String ?? "")"
        guard seen.insert(key).inserted else { return }

        let input = num(u, "input_tokens"), output = num(u, "output_tokens")
        let cw = num(u, "cache_creation_input_tokens"), cr = num(u, "cache_read_input_tokens")
        var w5m = cw, w1h = 0.0
        if let cc = u["cache_creation"] as? [String: Any] {
            w5m = num(cc, "ephemeral_5m_input_tokens"); w1h = num(cc, "ephemeral_1h_input_tokens")
        }
        let w = input + 5 * output + 1.25 * w5m + 2 * w1h + 0.1 * cr

        stat.usage.input += input; stat.usage.output += output
        stat.usage.cacheWrite += cw; stat.usage.cacheRead += cr
        stat.usage.calls += 1
        stat.usage.weighted += w
        if isSub { stat.usage.subagentWeighted += w }
        stat.last = max(stat.last ?? date, date)
    }

    private func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }

    private func promptText(_ obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        var text = msg["content"] as? String
        if text == nil, let parts = msg["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.replacingOccurrences(of: "\n", with: " ").prefix(80))
    }

    private func liveSessions() -> [String: LiveSession] {
        var out: [String: LiveSession] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: registryDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  let sid = obj["sessionId"] as? String,
                  kill(pid, 0) == 0 || errno == EPERM else { continue }
            out[sid] = LiveSession(status: obj["status"] as? String)
        }
        return out
    }
}

// MARK: - Formatting

func fmt(_ x: Double) -> String {
    if x >= 1e6 { return String(format: "%.1fM", x / 1e6) }
    if x >= 1e3 { return String(format: "%.0fK", x / 1e3) }
    return String(format: "%.0f", x)
}

func pct(_ a: Double, _ b: Double) -> String { b > 0 ? String(format: "%.0f%%", a / b * 100) : "–" }

func truncate(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

func relative(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
}

func shortDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "EEE M/d HH:mm"
    return f.string(from: d)
}

func bar(_ percent: Double, width: Int = 10) -> String {
    let filled = max(0, min(width, Int((percent / 100 * Double(width)).rounded())))
    return String(repeating: "■", count: filled) + String(repeating: "□", count: width - filled)
}

func severityColor(_ severity: String) -> NSColor? {
    switch severity {
    case "normal": return nil
    case "warning": return .systemOrange
    default: return .systemRed
    }
}

// MARK: - Menu bar UI

func postNotification(id: String, title: String, body: String, completion: ((Error?) -> Void)? = nil) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) {
        if let error = $0 { NSLog("FableUsage notification: \(error)") }
        completion?($0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let scanner = Scanner()
    private let queue = DispatchQueue(label: "fable-usage.scan", qos: .utility)
    private var snapshot: Snapshot?
    private var limits: PlanLimits?
    private var limitsError: String?
    private var fetching = false
    private var timers: [Timer] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Fable usage")
            button.imagePosition = .imageLeading
            button.title = " …"
        }
        menu.delegate = self
        statusItem.menu = menu
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        fetchLimits()
        refresh()
        timers = [
            Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.refresh() },
            Timer.scheduledTimer(withTimeInterval: limitsInterval, repeats: true) { [weak self] _ in self?.fetchLimits() },
        ]
    }

    private var weekStart: Date { limits?.weekStart() ?? fallbackWeekStart(for: Date()) }

    private func refresh() {
        let ws = weekStart
        queue.async { [scanner] in
            let snap = scanner.scan(weekStart: ws)
            DispatchQueue.main.async { self.apply(snap) }
        }
    }

    private func fetchLimits() {
        guard !fetching else { return }
        fetching = true
        PlanLimitsClient.fetch { result in
            DispatchQueue.main.async {
                self.fetching = false
                switch result {
                case .success(let l): self.limits = l; self.limitsError = nil; self.alertIfNeeded(l)
                case .failure(let e): self.limitsError = e.localizedDescription
                }
                self.updateTitle()
            }
        }
    }

    private func alertIfNeeded(_ l: PlanLimits) {
        guard let f = l.fable, f.percent >= alertThreshold else { return }
        // One alert per weekly window, remembered across relaunches.
        let window = f.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "unknown"
        let key = "alertedFableWindow"
        guard UserDefaults.standard.string(forKey: key) != window else { return }

        var body = "초기화: \(f.resetsAt.map(shortDate) ?? "-")"
        if let s = snapshot, let top = s.sessions.first {
            body += "\n가장 많이 쓴 세션: \(truncate(top.displayName, 40)) (\(top.folder), \(pct(top.usage.weighted, s.total)))"
        }
        postNotification(id: "fable-\(window)", title: String(format: "Fable 주간 한도 %.0f%% 사용", f.percent), body: body) { error in
            if error == nil { DispatchQueue.main.async { UserDefaults.standard.set(window, forKey: key) } }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func apply(_ snap: Snapshot) {
        snapshot = snap
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let title = " " + (limits?.fable.map { String(format: "%.0f%%", $0.percent) } ?? (limitsError == nil ? "…" : "–"))
        if let color = limits?.fable.flatMap({ severityColor($0.severity) }) {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: color, .font: NSFont.menuBarFont(ofSize: 0),
            ])
        } else {
            button.title = title
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        let ws = weekStart
        apply(queue.sync { scanner.scan(weekStart: ws) })
        if Date().timeIntervalSince(limits?.fetchedAt ?? .distantPast) > 60 { fetchLimits() }
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(info("플랜 한도 (claude.ai)", bold: true))
        if let l = limits {
            for item in l.items { menu.addItem(limitItem(item)) }
            let used = l.breakdown.filter { $0.percent > 0 }.map { "\($0.name) \(Int($0.percent))%" }
            if !used.isEmpty { menu.addItem(info("이번 주 사용처: " + used.joined(separator: " · "))) }
            menu.addItem(info("갱신 \(relative(l.fetchedAt))" + (limitsError.map { " · 최근 갱신 실패: \($0)" } ?? "")))
        } else {
            menu.addItem(info(limitsError.map { "불러오기 실패: \($0)" } ?? "불러오는 중…"))
        }
        menu.addItem(.separator())

        guard let s = snapshot else { return }
        menu.addItem(info("이번 주 Fable 사용량  \(fmt(s.total)) (가중 토큰, 이 Mac의 Claude Code)", bold: true))
        menu.addItem(info("\(shortDate(s.weekStart)) 부터 · 초기화 \(shortDate(s.nextReset)) (\(relative(s.nextReset)))"))
        menu.addItem(.separator())

        if s.sessions.isEmpty { menu.addItem(info("이번 주 Fable 사용 기록 없음")) }
        for st in s.sessions.prefix(maxRows) { menu.addItem(sessionItem(st, in: s)) }
        if s.sessions.count > maxRows {
            let rest = s.sessions.dropFirst(maxRows).reduce(0) { $0 + $1.usage.weighted }
            menu.addItem(info("외 \(s.sessions.count - maxRows)개 세션 · \(pct(rest, s.total))"))
        }

        menu.addItem(.separator())
        menu.addItem(info("●  실행 중(작업)   ●  실행 중(대기)   ○  종료됨"))
        menu.addItem(.separator())
        menu.addItem(action("claude.ai 사용량 페이지 열기", #selector(openUsagePage), key: "u"))
        menu.addItem(action("새로고침", #selector(refreshNow), key: "r"))
        let login = action("로그인 시 자동 실행", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func limitItem(_ l: LimitItem) -> NSMenuItem {
        let para = NSMutableParagraphStyle()
        para.tabStops = [
            NSTextTab(textAlignment: .left, location: 130),
            NSTextTab(textAlignment: .right, location: 172),
            NSTextTab(textAlignment: .left, location: 184),
            NSTextTab(textAlignment: .left, location: 300),
        ]
        let color = severityColor(l.severity) ?? .labelColor
        let t = NSMutableAttributedString()
        func add(_ str: String, _ attrs: [NSAttributedString.Key: Any]) {
            var a = attrs
            a[.paragraphStyle] = para
            t.append(NSAttributedString(string: str, attributes: a))
        }
        let weight: NSFont.Weight = l.isFable ? .semibold : .regular
        add(l.label, [.font: NSFont.systemFont(ofSize: 13, weight: weight), .foregroundColor: NSColor.labelColor])
        add(String(format: "\t%.0f%%", l.percent), [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: color])
        add("\t" + bar(l.percent), [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: color])
        if let r = l.resetsAt {
            add("\t초기화 \(shortDate(r))", [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        }
        let item = NSMenuItem()
        item.attributedTitle = t
        return item
    }

    private func sessionItem(_ st: SessionStat, in s: Snapshot) -> NSMenuItem {
        let live = s.live[st.id]
        let dotColor: NSColor = live == nil ? .tertiaryLabelColor
            : (live?.status == "busy" ? .systemGreen : .systemBlue)

        let para = NSMutableParagraphStyle()
        para.tabStops = [
            NSTextTab(textAlignment: .right, location: 52),
            NSTextTab(textAlignment: .right, location: 104),
            NSTextTab(textAlignment: .left, location: 118),
        ]
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let t = NSMutableAttributedString()
        func add(_ str: String, _ attrs: [NSAttributedString.Key: Any]) {
            var a = attrs
            a[.paragraphStyle] = para
            t.append(NSAttributedString(string: str, attributes: a))
        }
        add(live == nil ? "○" : "●", [.foregroundColor: dotColor, .font: NSFont.menuFont(ofSize: 13)])
        add("\t\(pct(st.usage.weighted, s.total))\t\(fmt(st.usage.weighted))", [.font: digits])
        add("\t" + truncate(st.displayName, 44), [.font: NSFont.menuFont(ofSize: 13)])
        var detail = "\(st.folder) · \(st.usage.calls)회 · 평균 컨텍스트 \(fmt(st.avgContext))"
        if let last = st.last { detail += " · " + relative(last) }
        add("\n\t\t\t" + detail, [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])

        let item = NSMenuItem()
        item.attributedTitle = t

        let sub = NSMenu()
        sub.addItem(info("세션 ID: \(st.id)"))
        if let cwd = st.cwd { sub.addItem(info(cwd)) }
        if let title = st.title { sub.addItem(info("제목: \(title)")) }
        if let p = st.prompt { sub.addItem(info("첫 프롬프트: \(truncate(p, 70))")) }
        sub.addItem(info("출력 \(fmt(st.usage.output)) · 캐시 쓰기 \(fmt(st.usage.cacheWrite)) · 캐시 읽기 \(fmt(st.usage.cacheRead))"))
        if st.usage.subagentWeighted > 0 {
            sub.addItem(info("서브에이전트 비중 \(pct(st.usage.subagentWeighted, st.usage.weighted))"))
        }
        if let live { sub.addItem(info("실행 중 (\(live.status ?? "상태 모름"))")) }
        sub.addItem(.separator())
        if let cwd = st.cwd {
            let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
            sub.addItem(action("재개 명령어 복사", #selector(copyText(_:)), rep: "cd \(quoted) && claude --resume \(st.id)"))
        }
        sub.addItem(action("세션 ID 복사", #selector(copyText(_:)), rep: st.id))
        if let cwd = st.cwd { sub.addItem(action("Finder에서 폴더 열기", #selector(openFolder(_:)), rep: cwd)) }
        item.submenu = sub
        return item
    }

    private func info(_ s: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        if bold { item.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]) }
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ sel: Selector, key: String = "", rep: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        item.representedObject = rep
        return item
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func refreshNow() {
        fetchLimits()
        refresh()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("FableUsage login item: \(error)")
            NSSound.beep()
        }
    }
}

// `FableUsage --login on|off` toggles launch at login (same as the menu item), then exits.
if let i = CommandLine.arguments.firstIndex(of: "--login") {
    let enable = CommandLine.arguments.dropFirst(i + 1).first != "off"
    do {
        if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
        print("login item error: \(error)")
    }
    let names: [SMAppService.Status: String] = [.enabled: "enabled", .notRegistered: "notRegistered",
                                                .requiresApproval: "requiresApproval", .notFound: "notFound"]
    print("launch at login: \(names[SMAppService.mainApp.status] ?? "unknown")")
    exit(0)
}

// `FableUsage --test-alert` sends a sample notification and prints the notification permission state.
if CommandLine.arguments.contains("--test-alert") {
    let done = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        let names: [UNAuthorizationStatus: String] = [.authorized: "authorized", .denied: "denied",
                                                      .notDetermined: "notDetermined", .provisional: "provisional"]
        print("notification permission: \(names[settings.authorizationStatus] ?? "unknown")")
        postNotification(id: "fable-test", title: "Fable 주간 한도 알림 테스트",
                         body: "한도가 \(Int(alertThreshold))%를 넘으면 이렇게 알려드려요.") { error in
            print(error.map { "notification error: \($0)" } ?? "notification sent")
            done.signal()
        }
    }
    _ = done.wait(timeout: .now() + 10)
    exit(0)
}

// `FableUsage --dump` prints the current limits and snapshot instead of starting the menu bar app.
if CommandLine.arguments.contains("--dump") {
    let done = DispatchSemaphore(value: 0)
    var limits: PlanLimits?
    PlanLimitsClient.fetch { result in
        switch result {
        case .success(let l): limits = l
        case .failure(let e): print("limits error: \(e.localizedDescription)")
        }
        done.signal()
    }
    done.wait()
    for l in limits?.items ?? [] {
        print("limit\t\(l.label)\t\(Int(l.percent))%\t\(l.severity)\treset \(l.resetsAt.map(shortDate) ?? "-")\(l.isFable ? "\t[fable]" : "")")
    }
    let s = Scanner().scan(weekStart: limits?.weekStart() ?? fallbackWeekStart(for: Date()))
    print("since \(s.weekStart) · resets \(s.nextReset) · total \(fmt(s.total))")
    for st in s.sessions {
        let live = s.live[st.id].map { " [live: \($0.status ?? "?")]" } ?? ""
        print("\(pct(st.usage.weighted, s.total))\t\(fmt(st.usage.weighted))\t\(st.usage.calls) calls\t\(st.id)\t\(st.folder)\t\(st.displayName)\(live)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
