import Foundation
import Combine
import AppKit

/// A Claude Code session discovered on disk.
struct ClaudeSession: Identifiable, Equatable {
    /// The session ID (the jsonl file name without extension).
    let id: String

    /// The title Claude Code generated or the user set via /rename, falling back
    /// to the first user prompt.
    let title: String

    /// The most recent working directory of the session, if known. This follows
    /// `cd`s made during the session.
    let cwd: String?

    /// The directory the session was started in. Claude Code stores sessions per
    /// project, so `claude --resume` must run from here.
    let projectDir: String?

    /// Time of the last conversation turn. Claude Code also appends metadata when a
    /// session is merely opened, so this is not the file's modification time.
    let lastActivity: Date

    /// Tokens in the context as of the last assistant turn, if known.
    let contextTokens: Int?

    /// The context window size of the model used by the last assistant turn.
    let contextWindow: Int

    /// The fraction (0...1) of the context window still available.
    var contextRemaining: Double? {
        guard let contextTokens else { return nil }
        return max(0, 1 - Double(contextTokens) / Double(contextWindow))
    }
}

/// Ghostty-only metadata for a Claude session. This never touches Claude's
/// own files; renames here only affect how the sidebar displays the session.
struct ClaudeSessionMetadata: Codable, Equatable {
    var starred: Bool = false
    /// An explicit archive choice. nil means "automatic": archived once the session
    /// has been inactive longer than the auto-archive period.
    var archived: Bool?
    var displayName: String?

    var isEmpty: Bool { !starred && archived == nil && displayName == nil }
}

/// Discovers Claude Code sessions in `~/.claude/projects` (read-only) and stores
/// sidebar-only metadata (star, archive, display name) in Ghostty's application
/// support directory. Shared by every terminal window.
final class ClaudeSessionStore: ObservableObject {
    static let shared = ClaudeSessionStore()

    /// All discovered sessions, newest first.
    @Published private(set) var sessions: [ClaudeSession] = []

    /// Sidebar metadata keyed by session ID.
    @Published private(set) var metadata: [String: ClaudeSessionMetadata] = [:]

    private let projectsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    private let metadataURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("claude-sessions.json")
    }()

    /// Parsing happens on this queue. The cache is only accessed from it.
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.claude-sessions", qos: .utility)
    private var cache: [URL: (modified: Date, size: Int, session: ClaudeSession?)] = [:]
    private var scanInFlight = false
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        loadMetadata()

        // Sessions are appended to while Claude runs, so we poll. Unchanged files
        // are skipped via the mtime/size cache so this is cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    // MARK: Metadata

    /// Archive sessions with no activity for this many days. 0 disables auto-archiving.
    @Published var autoArchiveDays: Int = UserDefaults.standard.object(forKey: autoArchiveDaysKey) as? Int ?? 7 {
        didSet { UserDefaults.standard.set(autoArchiveDays, forKey: Self.autoArchiveDaysKey) }
    }

    private static let autoArchiveDaysKey = "TabSidebarAutoArchiveDays"

    /// Whether a session belongs in the archive. An explicit archive/unarchive always
    /// wins; otherwise inactive sessions are archived, starred or not.
    func isArchived(_ session: ClaudeSession) -> Bool {
        let meta = metadata(for: session.id)
        if let archived = meta.archived { return archived }
        guard autoArchiveDays > 0 else { return false }
        return session.lastActivity < Date().addingTimeInterval(-Double(autoArchiveDays) * 24 * 60 * 60)
    }

    func metadata(for id: String) -> ClaudeSessionMetadata {
        metadata[id] ?? ClaudeSessionMetadata()
    }

    func displayTitle(for session: ClaudeSession) -> String {
        if let name = metadata[session.id]?.displayName, !name.isEmpty { return name }
        return session.title
    }

    func setStarred(_ starred: Bool, for id: String) {
        updateMetadata(for: id) { $0.starred = starred }
    }

    func setArchived(_ archived: Bool, for id: String) {
        updateMetadata(for: id) { $0.archived = archived }
    }

    /// Sets the sidebar-only display name. An empty or nil name resets to the original title.
    func rename(_ id: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        updateMetadata(for: id) { $0.displayName = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    private func updateMetadata(for id: String, _ body: (inout ClaudeSessionMetadata) -> Void) {
        var value = metadata(for: id)
        body(&value)
        if value.isEmpty {
            metadata.removeValue(forKey: id)
        } else {
            metadata[id] = value
        }
        saveMetadata()
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([String: ClaudeSessionMetadata].self, from: data) else { return }
        metadata = decoded
    }

    private func saveMetadata() {
        let snapshot = metadata
        let url = metadataURL
        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                AppDelegate.logger.warning("failed to save claude session metadata: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Scanning

    /// Rescan the Claude projects directory in the background.
    func refresh() {
        queue.async { [weak self] in
            guard let self, !self.scanInFlight else { return }
            self.scanInFlight = true
            let result = self.scan()
            self.scanInFlight = false
            DispatchQueue.main.async {
                if self.sessions != result { self.sessions = result }
            }
        }
    }

    private func scan() -> [ClaudeSession] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let projects = try? fm.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }

        var seen: Set<URL> = []
        var result: [ClaudeSession] = []
        for project in projects {
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate else { continue }
                let size = values.fileSize ?? 0
                seen.insert(file)

                if let cached = cache[file], cached.modified == modified, cached.size == size {
                    if let session = cached.session { result.append(session) }
                    continue
                }

                let session = Self.parse(file: file, modified: modified)
                cache[file] = (modified, size, session)
                if let session { result.append(session) }
            }
        }

        // Drop cache entries for deleted files.
        cache = cache.filter { seen.contains($0.key) }

        return result.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// The number of bytes we read from the start and end of a session file. Session
    /// files can be many megabytes; the fields we need are near the edges.
    private static let chunkSize = 256 * 1024

    private static func parse(file: URL, modified: Date) -> ClaudeSession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)

        var lines: [Substring] = []
        if size <= UInt64(chunkSize * 2) {
            guard let data = try? handle.readToEnd() else { return nil }
            lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        } else {
            let head = (try? handle.read(upToCount: chunkSize)) ?? Data()
            try? handle.seek(toOffset: size - UInt64(chunkSize))
            let tail = (try? handle.readToEnd()) ?? Data()

            // Drop the possibly-partial last line of the head and first line of the tail.
            var headLines = String(decoding: head, as: UTF8.self).split(separator: "\n")
            if !headLines.isEmpty { headLines.removeLast() }
            var tailLines = String(decoding: tail, as: UTF8.self).split(separator: "\n")
            if !tailLines.isEmpty { tailLines.removeFirst() }
            lines = headLines + tailLines
        }

        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        var firstPrompt: String?
        var oneMillion = false

        // cwd and usage lines are frequent and can be large, so we only collect them
        // here and JSON-parse just the few we need afterwards.
        var cwdLines: [Substring] = []
        var usageLines: [Substring] = []

        for line in lines {
            // The 1M context variant is only visible as a "[1m]" model suffix
            // (e.g. in /model output), never in the assistant message itself.
            if !oneMillion && line.contains("[1m]") { oneMillion = true }

            if line.contains("\"cwd\"") { cwdLines.append(line) }
            if line.contains("\"type\":\"assistant\"") && line.contains("\"usage\"") { usageLines.append(line) }

            let isTitle = line.contains("\"custom-title\"") || line.contains("\"ai-title\"") || line.contains("\"type\":\"summary\"")
            let wantsPrompt = firstPrompt == nil && line.contains("\"type\":\"user\"")
            guard isTitle || wantsPrompt, let obj = mainChainObject(line) else { continue }

            switch obj["type"] as? String {
            case "custom-title":
                // Later entries win: the user may rename more than once.
                if let value = obj["customTitle"] as? String, !value.isEmpty { customTitle = value }
            case "ai-title":
                if let value = obj["aiTitle"] as? String, !value.isEmpty { aiTitle = value }
            case "summary":
                if let value = obj["summary"] as? String, !value.isEmpty { summary = value }
            case "user":
                if firstPrompt == nil,
                   obj["isMeta"] as? Bool != true,
                   let message = obj["message"] as? [String: Any] {
                    firstPrompt = promptText(message["content"])
                }
            default:
                break
            }
        }

        let cwdOf: (Substring) -> String? = { line in
            guard let value = mainChainObject(line)?["cwd"] as? String, !value.isEmpty else { return nil }
            return value
        }
        let projectDir = cwdLines.lazy.compactMap(cwdOf).first
        let cwd = cwdLines.reversed().lazy.compactMap(cwdOf).first

        // The latest assistant turn with real usage. Synthetic messages (e.g. API
        // errors) report zero usage.
        var contextTokens: Int?
        var model: String?
        var lastActivity: Date?
        for line in usageLines.reversed() {
            guard let obj = mainChainObject(line),
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
            let total = keys.reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
            guard total > 0 else { continue }
            contextTokens = total
            model = message["model"] as? String
            lastActivity = (obj["timestamp"] as? String).flatMap(parseTimestamp)
            break
        }

        // A session Claude never replied to is just noise (e.g. an aborted start).
        guard contextTokens != nil else { return nil }

        let title = customTitle ?? aiTitle ?? summary ?? firstPrompt ?? "Untitled Session"
        return ClaudeSession(
            id: file.deletingPathExtension().lastPathComponent,
            title: title,
            cwd: cwd,
            projectDir: projectDir,
            lastActivity: lastActivity ?? modified,
            contextTokens: contextTokens,
            contextWindow: contextWindow(model: model, oneMillion: oneMillion, used: contextTokens ?? 0))
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Parses timestamps like "2026-10-27T08:10:23.761Z".
    private static func parseTimestamp(_ string: String) -> Date? {
        timestampFormatter.date(from: string)
    }

    /// Parses a jsonl line, ignoring subagent (sidechain) entries which have
    /// their own context and cwd.
    private static func mainChainObject(_ line: Substring) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["isSidechain"] as? Bool != true else { return nil }
        return obj
    }

    /// Best-effort context window size. Claude 5 family models default to 1M
    /// in Claude Code; older models use 200k unless the 1M variant was selected.
    private static func contextWindow(model: String?, oneMillion: Bool, used: Int) -> Int {
        let large = 1_000_000
        let standard = 200_000
        if oneMillion || used > standard { return large }

        // Model IDs look like "claude-opus-5-5" or "claude-sonnet-4-5-20250929".
        if let model {
            let parts = model.split(separator: "-")
            if parts.count >= 3, let major = Int(parts[2]), major >= 5 { return large }
        }

        return standard
    }

    /// Extracts human-typed text from a user message's content, skipping tool
    /// results and harness-injected blocks (which start with `<`).
    private static func promptText(_ content: Any?) -> String? {
        var text: String?
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        }

        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }

        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        return String(firstLine.prefix(80))
    }
}
