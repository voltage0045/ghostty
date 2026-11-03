import AppKit
import Combine
import Foundation

/// Tracks which Claude Code sessions are actually running, and in which Ghostty tab.
///
/// Claude Code registers every running process in `~/.claude/sessions/<pid>.json`
/// with its current session ID. A tab runs a session when its terminal's foreground
/// process group is one of those processes.
@MainActor
final class ClaudeLiveSessions: ObservableObject {
    static let shared = ClaudeLiveSessions()

    /// Running session IDs mapped to their Claude process ID, anywhere on the system.
    @Published private(set) var running: [String: pid_t] = [:]

    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)

    private var cancellables: Set<AnyCancellable> = []

    /// Set once the app starts quitting. Claude exits along with its terminal then,
    /// which must not detach sessions from tabs before window state is saved.
    private var isTerminating = false

    /// Closed windows linger in NSApp.windows. Their Claude exits with the terminal,
    /// which must not look like the user quitting Claude (and erase the session).
    private var closedWindows: Set<ObjectIdentifier> = []

    /// Terminal tabs that are open. A closed window counts again if it's shown again
    /// (e.g. undoing a close).
    var openControllers: [TerminalController] {
        TerminalController.all.filter { controller in
            guard let window = controller.window else { return false }
            return !closedWindows.contains(ObjectIdentifier(window)) || window.isVisible
        }
    }

    private init() {
        // Cheap: a handful of tiny files plus a syscall per terminal.
        let center = NotificationCenter.default
        Publishers.MergeMany(
            Timer.publish(every: 2, on: .main, in: .common).autoconnect().map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: NSWindow.didBecomeKeyNotification).map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: NSWindow.willCloseNotification).map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: NSApplication.didBecomeActiveNotification).map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.refresh() }
        .store(in: &cancellables)

        center.publisher(for: NSWindow.willCloseNotification)
            .compactMap { $0.object as? NSWindow }
            .sink { [weak self] in self?.closedWindows.insert(ObjectIdentifier($0)) }
            .store(in: &cancellables)

        center.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.isTerminating = true }
            .store(in: &cancellables)

        refresh()

        // Window restoration only brings tabs back after ⌘Q; closing the window
        // first discards them. Reopen whatever sessions were open last time once
        // restoration has had a chance to run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.reopenLastSessions()
        }
    }

    // MARK: Reopening

    private struct OpenSession: Codable, Equatable {
        let id: String
        let directory: String?
    }

    private let openSessionsURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("claude-open-sessions.json")
    }()

    private var lastSavedOpenSessions: [OpenSession]?

    /// Whether any tab was open at the last refresh, to notice the first window
    /// opened after all were closed (the app keeps running on macOS).
    private var hadOpenTabs = true

    /// Don't record until we've reopened, or an early save would wipe the list.
    private var reopened = false

    /// Records the sessions open in tabs. When the last window closes the list is
    /// kept rather than cleared, so it can be reopened next launch.
    private func saveOpenSessions() {
        guard reopened, !isTerminating else { return }
        let controllers = openControllers
        guard !controllers.isEmpty else { return }

        let open = controllers.compactMap { c in
            c.claudeSessionID.map { OpenSession(id: $0, directory: c.claudeSessionDir) }
        }
        guard open != lastSavedOpenSessions else { return }
        lastSavedOpenSessions = open

        do {
            try FileManager.default.createDirectory(
                at: openSessionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(open).write(to: openSessionsURL, options: .atomic)
        } catch {
            AppDelegate.logger.warning("failed to save open claude sessions: \(error.localizedDescription)")
        }
    }

    private func reopenLastSessions() {
        defer { reopened = true }

        guard let data = try? Data(contentsOf: openSessionsURL),
              let sessions = try? JSONDecoder().decode([OpenSession].self, from: data),
              let parent = TerminalController.preferredParent ?? openControllers.first else { return }

        // Restored tabs already resume their sessions; only open the rest.
        let present = Set(openControllers.compactMap(\.claudeSessionID)).union(running.keys)
        for session in sessions where !present.contains(session.id) {
            SessionSidebarModel.resume(sessionID: session.id, in: session.directory, from: parent)
        }
    }

    func refresh() {
        var newRunning: [String: pid_t] = [:]
        var sessionByPid: [pid_t: String] = [:]

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  let sessionID = json["sessionId"] as? String,
                  Self.isAlive(pid) else { continue }
            newRunning[sessionID] = pid
            sessionByPid[pid] = sessionID
        }

        if newRunning != running { running = newRunning }

        guard !isTerminating else { return }

        // All windows were closed and a new one opened (e.g. from the Dock): bring
        // back the sessions that were open, like on launch.
        let hasOpenTabs = !openControllers.isEmpty
        defer { hadOpenTabs = hasOpenTabs }
        if reopened, hasOpenTabs, !hadOpenTabs {
            reopenLastSessions()
            return
        }

        // Attach sessions to the tabs running them.
        for controller in openControllers {
            let live = controller.surfaceTree.lazy
                .compactMap { $0.surfaceModel?.foregroundPID }
                .compactMap { sessionByPid[pid_t(truncatingIfNeeded: $0)] }
                .first
            controller.claudeSessionObserved(live)
        }

        saveOpenSessions()
    }

    /// The Ghostty tab currently running a session, if any.
    func controller(for sessionID: String) -> TerminalController? {
        guard let pid = running[sessionID] else { return nil }
        return openControllers.first { controller in
            controller.surfaceTree.contains { surface in
                guard let foreground = surface.surfaceModel?.foregroundPID else { return false }
                return pid_t(truncatingIfNeeded: foreground) == pid
            }
        }
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
