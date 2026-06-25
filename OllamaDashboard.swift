// OllamaDashboard.swift
//
// A single-file SwiftUI macOS *menu-bar* dashboard for Ollama.
//
// It lives in the menu bar (no Dock icon). Click the icon for the dashboard
// popover; hit the pin button to detach it into a floating window that stays
// on top of every other app's windows and follows you across Spaces.
//
// What it shows:
//   • Connection status + Ollama version
//   • Total memory (RAM + VRAM) currently held by loaded models
//   • Models currently loaded / doing work, with per-model memory, GPU/CPU
//     split, and how long until they unload
//   • All installed models (size + last modified)
//
// How to run (no Xcode project needed):
//   swiftc -O -parse-as-library OllamaDashboard.swift -o OllamaDashboard
//   ./OllamaDashboard
//
// Or drop this file into a "macOS App" target in Xcode (delete the template's
// App/ContentView files) and hit Run.
//
// Requires Ollama running locally (default host http://127.0.0.1:11434).
// Override with:  OLLAMA_HOST=http://192.168.1.10:11434 ./OllamaDashboard

import SwiftUI

// MARK: - Configuration

enum Config {
    /// Base URL of the Ollama server. Honors the OLLAMA_HOST env var.
    static var baseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["OLLAMA_HOST"],
           let url = normalize(raw) {
            return url
        }
        return URL(string: "http://127.0.0.1:11434")!
    }

    /// How often (seconds) to refresh the dashboard.
    static let pollInterval: TimeInterval = 2.0

    /// Ollama's request log. The macOS app writes here; override with
    /// OLLAMA_LOGFILE if you redirected `ollama serve` somewhere else.
    static var logURL: URL {
        if let raw = ProcessInfo.processInfo.environment["OLLAMA_LOGFILE"], !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ollama/logs/server.log")
    }

    /// How many recent requests to keep in the feed.
    static let maxRequests = 40

    private static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "http://" + s }
        return URL(string: s)
    }
}

// MARK: - API Models

/// GET /api/version
struct VersionResponse: Decodable {
    let version: String
}

/// GET /api/ps  — models currently loaded in memory.
struct RunningResponse: Decodable {
    let models: [RunningModel]
}

struct RunningModel: Decodable, Identifiable {
    let name: String
    let model: String
    let size: Int64           // total bytes resident (RAM + VRAM)
    let sizeVRAM: Int64       // bytes resident in VRAM
    let expiresAt: Date?
    let details: ModelDetails?

    var id: String { name }

    /// Fraction of the model living on the GPU (0...1).
    var gpuFraction: Double {
        guard size > 0 else { return 0 }
        return min(1.0, Double(sizeVRAM) / Double(size))
    }

    /// Human label for where the model is running.
    var placement: String {
        let g = gpuFraction
        if g >= 0.999 { return "100% GPU" }
        if g <= 0.001 { return "100% CPU" }
        return "\(Int((g * 100).rounded()))% GPU"
    }

    enum CodingKeys: String, CodingKey {
        case name, model, size, details
        case sizeVRAM = "size_vram"
        case expiresAt = "expires_at"
    }
}

/// GET /api/tags — installed models on disk.
struct TagsResponse: Decodable {
    let models: [InstalledModel]
}

struct InstalledModel: Decodable, Identifiable {
    let name: String
    let size: Int64
    let modifiedAt: Date?
    let details: ModelDetails?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, size, details
        case modifiedAt = "modified_at"
    }
}

struct ModelDetails: Decodable {
    let parameterSize: String?
    let quantizationLevel: String?
    let family: String?

    enum CodingKeys: String, CodingKey {
        case family
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }
}

// MARK: - Networking

enum OllamaError: LocalizedError {
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let why): return why
        }
    }
}

struct OllamaClient {
    let base: URL

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        // Ollama timestamps are RFC3339 with fractional seconds, e.g.
        // "2024-05-30T11:22:33.123456789-07:00". .iso8601 chokes on
        // nanosecond precision, so parse leniently.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { dec in
            let raw = try dec.singleValueContainer().decode(String.self)
            if let dt = fmt.date(from: raw) ?? plain.date(from: raw) { return dt }
            // Trim sub-second digits beyond what the formatter accepts.
            if let range = raw.range(of: #"\.\d+"#, options: .regularExpression) {
                let trimmed = raw.replacingCharacters(in: range, with: "")
                if let dt = plain.date(from: trimmed) { return dt }
            }
            throw DecodingError.dataCorruptedError(
                in: try dec.singleValueContainer(),
                debugDescription: "Unrecognized date: \(raw)")
        }
        return d
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let url = base.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                throw OllamaError.unreachable("HTTP \(code) from \(path)")
            }
            return try decoder.decode(T.self, from: data)
        } catch let e as OllamaError {
            throw e
        } catch {
            throw OllamaError.unreachable(error.localizedDescription)
        }
    }

    func version() async throws -> VersionResponse {
        try await get("/api/version", as: VersionResponse.self)
    }

    func running() async throws -> RunningResponse {
        try await get("/api/ps", as: RunningResponse.self)
    }

    func installed() async throws -> TagsResponse {
        try await get("/api/tags", as: TagsResponse.self)
    }
}

// MARK: - Request log

/// One parsed line from Ollama's GIN access log.
struct RequestLogEntry: Identifiable {
    let id = UUID()
    let date: Date?
    let method: String
    let path: String
    let status: Int
    let latency: String     // raw GIN latency token, e.g. "1.23s", "12ms", "980µs"
    let client: String

    /// Short endpoint label: "chat", "generate", "embeddings", "v1/chat"…
    var endpoint: String {
        var p = path
        for prefix in ["/api/", "/"] where p.hasPrefix(prefix) {
            p = String(p.dropFirst(prefix.count)); break
        }
        return p.isEmpty ? path : p
    }

    var ok: Bool { (200..<400).contains(status) }
}

/// Reads the tail of Ollama's log file and extracts inference requests.
///
/// We deliberately keep only the endpoints that represent real work —
/// chat / generate / embeddings / OpenAI-compat — so the dashboard's own
/// /api/ps, /api/tags and /api/version polling doesn't drown out the feed.
enum LogReader {
    /// GIN line, e.g.:
    /// [GIN] 2024/06/22 - 12:04:31 | 200 |   1.234s | 127.0.0.1 | POST "/api/chat"
    private static let line = try! NSRegularExpression(
        pattern: #"\[GIN\]\s+([\d/]+ - [\d:]+)\s+\|\s+(\d+)\s+\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*(\w+)\s+"([^"]+)""#)

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd - HH:mm:ss"
        return f
    }()

    private static let interesting = ["/api/chat", "/api/generate",
                                      "/api/embed", "/api/embeddings", "/v1/"]

    /// Returns the most recent inference requests (newest first), or throws if
    /// the log file can't be read.
    static func recent(from url: URL, limit: Int) throws -> [RequestLogEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Read only the last chunk — logs can be huge.
        let size = try handle.seekToEnd()
        let window: UInt64 = 256 * 1024
        try handle.seek(toOffset: size > window ? size - window : 0)
        let data = handle.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return [] }

        var out: [RequestLogEntry] = []
        for var text in raw.split(separator: "\n") {
            // Strip ANSI color codes GIN may emit.
            let clean = stripANSI(String(text))
            text = Substring(clean)
            let range = NSRange(clean.startIndex..., in: clean)
            guard let m = line.firstMatch(in: clean, range: range) else { continue }

            func cap(_ i: Int) -> String {
                guard let r = Range(m.range(at: i), in: clean) else { return "" }
                return String(clean[r])
            }
            let path = cap(6)
            guard interesting.contains(where: { path.hasPrefix($0) }) else { continue }

            out.append(RequestLogEntry(
                date: stamp.date(from: cap(1)),
                method: cap(5),
                path: path,
                status: Int(cap(2)) ?? 0,
                latency: cap(3).trimmingCharacters(in: .whitespaces),
                client: cap(4).trimmingCharacters(in: .whitespaces)))
        }
        return Array(out.suffix(limit).reversed())
    }

    private static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}

// MARK: - View Model

@MainActor
final class DashboardModel: ObservableObject {
    /// Shared instance so the menu-bar window and the pinned floating panel
    /// render the same live data from a single poller.
    static let shared = DashboardModel()

    @Published var online = false
    @Published var version: String?
    @Published var running: [RunningModel] = []
    @Published var installed: [InstalledModel] = []
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    @Published var pinned = false   // reflects the floating-panel state
    @Published var requests: [RequestLogEntry] = []
    @Published var logAvailable = true

    private var timer: Timer?
    private var client = OllamaClient(base: Config.baseURL)

    var totalResidentBytes: Int64 { running.reduce(0) { $0 + $1.size } }
    var totalVRAMBytes: Int64 { running.reduce(0) { $0 + $1.sizeVRAM } }

    /// Idempotent — safe to call from multiple views; only one timer runs.
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Config.pollInterval,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task { @MainActor in
            do {
                async let v = client.version()
                async let r = client.running()
                async let i = client.installed()
                let (ver, run, inst) = try await (v, r, i)
                self.version = ver.version
                self.running = run.models.sorted { $0.size > $1.size }
                self.installed = inst.models.sorted { ($0.name) < ($1.name) }
                self.online = true
                self.lastError = nil
                self.lastUpdated = Date()
            } catch {
                self.online = false
                self.lastError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.running = []
                self.lastUpdated = Date()
            }
            self.reloadRequests()
        }
    }

    private func reloadRequests() {
        do {
            requests = try LogReader.recent(from: Config.logURL,
                                            limit: Config.maxRequests)
            logAvailable = true
        } catch {
            requests = []
            logAvailable = false
        }
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useGB, .useMB]
        bcf.countStyle = .memory
        return bcf.string(fromByteCount: b)
    }

    static func relativeFuture(_ date: Date?) -> String {
        guard let date else { return "—" }
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return "expiring…" }
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86_400 { return String(format: "%.1fh", secs / 3600) }
        return "keep-alive"
    }

    static func relativePast(_ date: Date?) -> String {
        guard let date else { return "—" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Views

@main
struct OllamaDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .frame(width: 420, height: 600)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)   // rich view dropdown, not a plain menu
    }
}

/// The status item shown in the menu bar: an icon that reflects connection
/// state, plus the live memory figure when models are loaded.
struct MenuBarLabel: View {
    @ObservedObject private var model = DashboardModel.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if model.online, model.totalResidentBytes > 0 {
                Text(Fmt.bytes(model.totalResidentBytes))
            }
        }
    }

    private var symbol: String {
        if !model.online { return "exclamationmark.triangle.fill" }
        return model.running.isEmpty ? "brain" : "brain.head.profile"
    }
}

// MARK: - App lifecycle + floating "always on top" panel

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Static handle so the SwiftUI pin button can reach the delegate without
    /// a fragile `NSApp.delegate as? AppDelegate` cast.
    static private(set) weak var shared: AppDelegate?

    private var panel: FloatingPanel?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        DashboardModel.shared.start()
    }

    /// Toggle the detached, always-on-top dashboard window.
    @MainActor func togglePin() {
        if let panel {
            panel.close()
            self.panel = nil
            DashboardModel.shared.pinned = false
            return
        }
        // Defer to the next run-loop tick: clicking the button inside the
        // MenuBarExtra popover dismisses that window, and creating/showing the
        // panel in the same tick gets swallowed by the dismissal.
        DispatchQueue.main.async {
            let p = FloatingPanel()
            p.title = "Ollama"
            p.contentView = NSHostingView(rootView: DashboardView().frame(width: 420))
            p.setContentSize(NSSize(width: 420, height: 600))
            p.center()
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
            p.orderFrontRegardless()
            self.panel = p
            DashboardModel.shared.pinned = true
        }
    }
}

/// A panel that floats above other apps' windows and follows you across
/// Spaces, without stealing focus from whatever you're working in.
final class FloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled, .closable, .resizable,
                        .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        level = .floating                       // above normal windows
        isFloatingPanel = true
        hidesOnDeactivate = false               // stay visible when app loses focus
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }    // allow scrolling / button clicks
}

struct DashboardView: View {
    @ObservedObject private var model = DashboardModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !model.online {
                    offlineBanner
                }
                memorySummary
                runningSection
                requestsSection
                installedSection
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.start() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(model.online ? Color.green : Color.red)
                .frame(width: 12, height: 12)
                .shadow(color: (model.online ? Color.green : Color.red).opacity(0.6),
                        radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ollama")
                    .font(.title2.bold())
                HStack(spacing: 6) {
                    Text(model.online ? "Online" : "Offline")
                        .foregroundStyle(model.online ? .green : .red)
                    if let v = model.version {
                        Text("· v\(v)").foregroundStyle(.secondary)
                    }
                    if let u = model.lastUpdated {
                        Text("· updated \(Fmt.relativePast(u))")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")
            .buttonStyle(.borderless)

            Button {
                AppDelegate.shared?.togglePin()
            } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
            }
            .help(model.pinned ? "Unpin floating window"
                               : "Pin as a floating window, always on top")
            .buttonStyle(.borderless)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit")
            .buttonStyle(.borderless)
        }
    }

    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Can't reach Ollama at \(Config.baseURL.absoluteString)")
                    .font(.callout.weight(.medium))
                if let e = model.lastError {
                    Text(e).font(.caption).foregroundStyle(.secondary)
                }
                Text("Is `ollama serve` running?")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Memory summary

    private var memorySummary: some View {
        HStack(spacing: 12) {
            StatCard(title: "Loaded Models",
                     value: "\(model.running.count)",
                     icon: "shippingbox.fill",
                     tint: .blue)
            StatCard(title: "Memory In Use",
                     value: Fmt.bytes(model.totalResidentBytes),
                     icon: "memorychip.fill",
                     tint: .purple)
            StatCard(title: "On GPU (VRAM)",
                     value: Fmt.bytes(model.totalVRAMBytes),
                     icon: "cpu.fill",
                     tint: .pink)
        }
    }

    // MARK: Running models ("current work")

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Active Now",
                          subtitle: "Models loaded in memory",
                          systemImage: "bolt.fill")
            if model.running.isEmpty {
                EmptyRow(text: model.online
                         ? "Idle — no models loaded. Run a prompt and it'll appear here."
                         : "—")
            } else {
                ForEach(model.running) { m in
                    RunningRow(model: m)
                }
            }
        }
    }

    // MARK: Recent queries (from the request log)

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recent Queries",
                          subtitle: "Inference requests from the server log",
                          systemImage: "list.bullet.rectangle")
            if !model.logAvailable {
                EmptyRow(text: "Log not found at \(Config.logURL.path). "
                         + "If you run `ollama serve` yourself, set OLLAMA_LOGFILE.")
            } else if model.requests.isEmpty {
                EmptyRow(text: "No chat/generate/embeddings requests yet.")
            } else {
                ForEach(model.requests) { r in
                    RequestRow(entry: r)
                }
            }
        }
    }

    // MARK: Installed models

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Installed",
                          subtitle: "\(model.installed.count) model\(model.installed.count == 1 ? "" : "s") on disk",
                          systemImage: "internaldrive.fill")
            if model.installed.isEmpty {
                EmptyRow(text: model.online ? "No models pulled yet." : "—")
            } else {
                ForEach(model.installed) { m in
                    InstalledRow(model: m)
                }
            }
        }
    }
}

// MARK: - Reusable components

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct RunningRow: View {
    let model: RunningModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.name)
                    .font(.body.weight(.semibold))
                if let p = model.details?.parameterSize {
                    Tag(text: p)
                }
                if let q = model.details?.quantizationLevel {
                    Tag(text: q)
                }
                Spacer()
                Label(Fmt.relativeFuture(model.expiresAt),
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Time until the model unloads from memory")
            }

            // GPU/CPU placement bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.orange.opacity(0.35)) // CPU portion
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.green.opacity(0.7))    // GPU portion
                        .frame(width: max(0, geo.size.width * model.gpuFraction))
                }
            }
            .frame(height: 6)

            HStack(spacing: 12) {
                Label(Fmt.bytes(model.size), systemImage: "memorychip")
                Label(model.placement, systemImage: "cpu")
                if model.sizeVRAM > 0 {
                    Label("\(Fmt.bytes(model.sizeVRAM)) VRAM", systemImage: "cpu.fill")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct InstalledRow: View {
    let model: InstalledModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.body)
                HStack(spacing: 8) {
                    if let p = model.details?.parameterSize { Text(p) }
                    if let q = model.details?.quantizationLevel { Text("· \(q)") }
                    if let f = model.details?.family { Text("· \(f)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.bytes(model.size))
                    .font(.callout.monospacedDigit())
                Text(Fmt.relativePast(model.modifiedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct RequestRow: View {
    let entry: RequestLogEntry

    private var timeText: String {
        guard let d = entry.date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(entry.ok ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(timeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(entry.endpoint)
                .font(.callout.weight(.medium))
            Spacer()
            Text(entry.latency)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(entry.status)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(entry.ok ? .green : .orange)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
    }
}

struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
