import Foundation
import Combine
import AppKit

/// A Claude Code session discovered on disk.
struct ClaudeSession: Identifiable, Equatable, Codable {
    /// The session ID (the jsonl file name without extension).
    let id: String

    /// The session's jsonl file.
    let file: URL

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

    /// A user-created category the session is filed under.
    var category: String?

    var isEmpty: Bool { !starred && archived == nil && displayName == nil && category == nil }
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
    private var cache: [URL: CacheEntry] = [:]

    private struct CacheEntry: Codable {
        let modified: Date
        let size: Int
        let session: ClaudeSession?
    }

    /// Parsed sessions are cached on disk so launching doesn't rescan every file.
    private let cacheURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("claude-sessions-cache.json")
    }()

    /// Bumped when parsing changes so stale cached results are discarded.
    private static let cacheVersion = 1
    private var cacheLoaded = false

    private struct CacheFile: Codable {
        let version: Int
        let entries: [String: CacheEntry]
    }

    /// Loads the disk cache. Called on `queue`.
    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.version == Self.cacheVersion else { return }
        cache = Dictionary(uniqueKeysWithValues: file.entries.map { (URL(fileURLWithPath: $0.key), $0.value) })
    }

    /// Saves the disk cache. Called on `queue`.
    private func saveCache() {
        let file = CacheFile(
            version: Self.cacheVersion,
            entries: Dictionary(uniqueKeysWithValues: cache.map { ($0.key.path, $0.value) }))
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: cacheURL, options: .atomic)
        } catch {
            AppDelegate.logger.warning("failed to save claude session cache: \(error.localizedDescription)")
        }
    }
    private var scanInFlight = false

    /// Lowercased user prompts per session file, for search. Only accessed on `queue`.
    private var promptCache: [URL: (modified: Date, size: Int, text: String)] = [:]

    /// Incremented per search so stale background results are dropped.
    private var searchGeneration = 0
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
        // Filing a session is a deliberate choice to keep it, so don't auto-archive.
        guard meta.category == nil, autoArchiveDays > 0 else { return false }
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

    // MARK: Categories

    /// User-created categories, in display order.
    @Published private(set) var categories: [String] = UserDefaults.standard.stringArray(forKey: categoriesKey) ?? [] {
        didSet { UserDefaults.standard.set(categories, forKey: Self.categoriesKey) }
    }

    private static let categoriesKey = "SessionSidebarCategories"

    /// Adds a category, returning the name actually used (nil if empty).
    @discardableResult
    func addCategory(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !categories.contains(trimmed) { categories.append(trimmed) }
        return trimmed
    }

    func renameCategory(_ old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old, let index = categories.firstIndex(of: old) else { return }

        // Renaming onto an existing category merges the two.
        if categories.contains(trimmed) {
            categories.remove(at: index)
        } else {
            categories[index] = trimmed
        }
        for (id, meta) in metadata where meta.category == old {
            metadata[id]?.category = trimmed
        }
        saveMetadata()
    }

    /// Deletes a category. Its sessions become uncategorized.
    func deleteCategory(_ name: String) {
        categories.removeAll { $0 == name }
        for (id, meta) in metadata where meta.category == name {
            updateMetadata(for: id) { $0.category = nil }
        }
        saveMetadata()
    }

    func moveCategory(_ name: String, by offset: Int) {
        guard let index = categories.firstIndex(of: name) else { return }
        let target = index + offset
        guard categories.indices.contains(target) else { return }
        categories.swapAt(index, target)
    }

    func setCategory(_ category: String?, for id: String) {
        updateMetadata(for: id) { $0.category = category }
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

        // Keep categories in sync with sessions filed under them.
        for name in Set(decoded.values.compactMap(\.category)) where !categories.contains(name) {
            categories.append(name)
        }
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

    // MARK: Search

    /// IDs of sessions whose prompts contain the current query, or nil when not searching.
    @Published private(set) var contentMatches: Set<String>?
    @Published private(set) var isSearching = false

    /// Search the text of user prompts in the background. Titles and directories are
    /// matched synchronously by the view; this covers the conversation itself.
    func searchContent(_ query: String) {
        searchGeneration += 1
        let generation = searchGeneration
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            contentMatches = nil
            isSearching = false
            return
        }

        isSearching = true
        let sessions = self.sessions
        queue.async { [weak self] in
            guard let self else { return }
            var matches: Set<String> = []
            for session in sessions {
                // A newer search supersedes this one.
                if self.isStale(generation) { return }
                if self.promptText(for: session.file).contains(needle) { matches.insert(session.id) }
            }
            DispatchQueue.main.async {
                guard generation == self.searchGeneration else { return }
                self.contentMatches = matches
                self.isSearching = false
            }
        }
    }

    private func isStale(_ generation: Int) -> Bool {
        DispatchQueue.main.sync { generation != searchGeneration }
    }

    /// Cached lowercased prompt text of a session file. Called on `queue`.
    private func promptText(for file: URL) -> String {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? .distantPast
        let size = values?.fileSize ?? 0
        if let cached = promptCache[file], cached.modified == modified, cached.size == size {
            return cached.text
        }

        var text = ""
        if let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
            // Session files total hundreds of MB, so filter lines at the byte level
            // and only decode the few that are typed prompts.
            Self.forEachLine(in: data, containing: Self.userMarker, excluding: Self.toolResultMarker) { line in
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["isSidechain"] as? Bool != true,
                      obj["isMeta"] as? Bool != true,
                      let message = obj["message"] as? [String: Any] else { return }
                for block in Self.textBlocks(message["content"]) where !block.hasPrefix("<") {
                    text += block.lowercased()
                    text += "\n"
                }
            }
        }

        promptCache[file] = (modified, size, text)
        return text
    }

    private static let userMarker = Array("\"type\":\"user\"".utf8)

    /// Tool results are also "user" messages; this skips them.
    private static let toolResultMarker = Array("\"tool_use_id\"".utf8)

    /// Calls `body` with each newline-delimited line that contains `marker` but not `excluded`.
    private static func forEachLine(
        in data: Data,
        containing marker: [UInt8],
        excluding excluded: [UInt8],
        _ body: (Data) -> Void
    ) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            let count = raw.count
            while start < count {
                let rest = count - start
                let newline = memchr(base + start, 0x0A, rest)
                let end = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                let length = end - start
                if length > 0,
                   memmem(base + start, length, marker, marker.count) != nil,
                   memmem(base + start, length, excluded, excluded.count) == nil {
                    body(Data(bytes: base + start, count: length))
                }
                start = end + 1
            }
        }
    }

    private static func textBlocks(_ content: Any?) -> [String] {
        if let string = content as? String { return [string] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
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
        loadCacheIfNeeded()
        var changed = false
        defer { if changed { saveCache() } }

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
                cache[file] = CacheEntry(modified: modified, size: size, session: session)
                changed = true
                if let session { result.append(session) }
            }
        }

        // Drop cache entries for deleted files.
        let kept = cache.filter { seen.contains($0.key) }
        if kept.count != cache.count { changed = true }
        cache = kept

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

        // Files are scanned as bytes: decoding hundreds of MB into Swift strings
        // just to search them made startup scans take seconds.
        let buffer: Data
        var lines: [Range<Int>]
        if size <= UInt64(chunkSize * 2) {
            guard let data = try? handle.readToEnd() else { return nil }
            buffer = data
            lines = lineRanges(in: buffer)
        } else {
            let head = (try? handle.read(upToCount: chunkSize)) ?? Data()
            try? handle.seek(toOffset: size - UInt64(chunkSize))
            let tail = (try? handle.readToEnd()) ?? Data()
            buffer = head + Data([0x0A]) + tail

            // Drop the possibly-partial last line of the head and first line of the tail.
            var headLines = lineRanges(in: buffer, upTo: head.count)
            if !headLines.isEmpty { headLines.removeLast() }
            var tailLines = lineRanges(in: buffer, from: head.count + 1)
            if !tailLines.isEmpty { tailLines.removeFirst() }
            lines = headLines + tailLines
        }

        let has = { (range: Range<Int>, marker: [UInt8]) -> Bool in
            contains(buffer, range, marker)
        }
        let object = { (range: Range<Int>) -> [String: Any]? in
            mainChainObject(buffer.subdata(in: range))
        }

        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        var firstPrompt: String?
        var oneMillion = false

        // cwd and usage lines are frequent and can be large, so we only note them
        // here and JSON-parse just the few we need afterwards.
        var cwdLines: [Range<Int>] = []
        var usageLines: [(index: Int, line: Range<Int>)] = []
        var lastCompact: (index: Int, line: Range<Int>)?

        for (index, line) in lines.enumerated() {
            // The 1M context variant is only visible as a "[1m]" model suffix
            // (e.g. in /model output), never in the assistant message itself.
            if !oneMillion && has(line, Marker.oneMillion) { oneMillion = true }

            if has(line, Marker.cwd) { cwdLines.append(line) }
            if has(line, Marker.assistant) && has(line, Marker.usage) { usageLines.append((index, line)) }
            if has(line, Marker.compact) { lastCompact = (index, line) }

            let isTitle = has(line, Marker.customTitle) || has(line, Marker.aiTitle) || has(line, Marker.summary)
            let wantsPrompt = firstPrompt == nil && has(line, Marker.user)
            guard isTitle || wantsPrompt, let obj = object(line) else { continue }

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

        let cwdOf: (Range<Int>) -> String? = { line in
            guard let value = object(line)?["cwd"] as? String, !value.isEmpty else { return nil }
            return value
        }
        let projectDir = cwdLines.lazy.compactMap(cwdOf).first
        let cwd = cwdLines.reversed().lazy.compactMap(cwdOf).first

        // The latest assistant turn with real usage. Synthetic messages (e.g. API
        // errors) report zero usage.
        var contextTokens: Int?
        var model: String?
        var lastActivity: Date?
        var usageIndex = -1
        for (index, line) in usageLines.reversed() {
            guard let obj = object(line),
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
            let total = keys.reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
            guard total > 0 else { continue }
            contextTokens = total
            model = message["model"] as? String
            lastActivity = (obj["timestamp"] as? String).flatMap(parseTimestamp)
            usageIndex = index
            break
        }

        // Size the window from the pre-compaction usage, which may exceed 200k.
        let peakTokens = contextTokens ?? 0

        // After /compact the context shrinks, but no assistant turn reports it until
        // the next reply. The compaction record carries the new size.
        if let lastCompact, lastCompact.index > usageIndex,
           let obj = object(lastCompact.line),
           let meta = obj["compactMetadata"] as? [String: Any],
           let post = (meta["postTokens"] as? NSNumber)?.intValue {
            contextTokens = post
        }

        // A session Claude never replied to is just noise (e.g. an aborted start).
        guard contextTokens != nil else { return nil }

        let title = customTitle ?? aiTitle ?? summary ?? firstPrompt ?? "Untitled Session"
        return ClaudeSession(
            id: file.deletingPathExtension().lastPathComponent,
            file: file,
            title: title,
            cwd: cwd,
            projectDir: projectDir,
            lastActivity: lastActivity ?? modified,
            contextTokens: contextTokens,
            contextWindow: contextWindow(model: model, oneMillion: oneMillion, used: peakTokens))
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

    private enum Marker {
        static let oneMillion = Array("[1m]".utf8)
        static let cwd = Array("\"cwd\"".utf8)
        static let assistant = Array("\"type\":\"assistant\"".utf8)
        static let usage = Array("\"usage\"".utf8)
        static let compact = Array("\"compact_boundary\"".utf8)
        static let customTitle = Array("\"custom-title\"".utf8)
        static let aiTitle = Array("\"ai-title\"".utf8)
        static let summary = Array("\"type\":\"summary\"".utf8)
        static let user = Array("\"type\":\"user\"".utf8)
    }

    /// Byte ranges of the newline-delimited lines in `data[from..<upTo]`.
    private static func lineRanges(in data: Data, from start: Int = 0, upTo limit: Int? = nil) -> [Range<Int>] {
        let end = limit ?? data.count
        var result: [Range<Int>] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var position = start
            while position < end {
                let found = memchr(base + position, 0x0A, end - position)
                let lineEnd = found.map { base.distance(to: UnsafeRawPointer($0)) } ?? end
                if lineEnd > position { result.append(position..<lineEnd) }
                position = lineEnd + 1
            }
        }
        return result
    }

    private static func contains(_ data: Data, _ range: Range<Int>, _ marker: [UInt8]) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return false }
            return memmem(base + range.lowerBound, range.count, marker, marker.count) != nil
        }
    }

    private static func mainChainObject(_ line: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
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
