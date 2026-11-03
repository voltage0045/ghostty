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

        center.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.isTerminating = true }
            .store(in: &cancellables)

        refresh()
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

        // Attach sessions to the tabs running them.
        guard !isTerminating else { return }
        for controller in TerminalController.all {
            let live = controller.surfaceTree.lazy
                .compactMap { $0.surfaceModel?.foregroundPID }
                .compactMap { sessionByPid[pid_t(truncatingIfNeeded: $0)] }
                .first
            controller.claudeSessionObserved(live)
        }
    }

    /// The Ghostty tab currently running a session, if any.
    func controller(for sessionID: String) -> TerminalController? {
        guard let pid = running[sessionID] else { return nil }
        return TerminalController.all.first { controller in
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
