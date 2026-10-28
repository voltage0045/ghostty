import AppKit
import Combine
import Foundation

/// Claude subscription rate limit usage, the same data `/usage` shows in Claude Code.
///
/// This reuses Claude Code's OAuth login from the keychain. It never refreshes the
/// token itself: refreshing rotates the refresh token, which would log Claude Code out.
final class ClaudeUsageStore: ObservableObject {
    static let shared = ClaudeUsageStore()

    struct Window: Equatable {
        /// Percent of the window used, 0...100.
        let utilization: Double
        let resetsAt: Date?

        var remaining: Double { max(0, 100 - utilization) }
    }

    enum State: Equatable {
        case loading
        case loaded(fiveHour: Window?, sevenDay: Window?, updated: Date)
        /// A human readable reason usage isn't available.
        case unavailable(String)
    }

    @Published private(set) var state: State = .loading

    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var inFlight = false

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshIfStale() }
            .store(in: &cancellables)

        refresh()
    }

    /// Refresh unless we fetched within the last minute.
    func refreshIfStale() {
        if case .loaded(_, _, let updated) = state, Date().timeIntervalSince(updated) < 60 { return }
        refresh()
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.fetch()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false

                // Keep showing the last good numbers if a background refresh fails.
                if case .unavailable = result, case .loaded = self.state { return }
                self.state = result
            }
        }
    }

    // MARK: Fetching

    private static func fetch() -> State {
        let token: String
        switch accessToken() {
        case .token(let value): token = value
        case .expired: return .unavailable("Login expired, open Claude Code to refresh")
        case .missing: return .unavailable("Not logged in to Claude Code")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let semaphore = DispatchSemaphore(value: 0)
        var result: State = .unavailable("Request failed")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                result = .unavailable("Login expired, open Claude Code to refresh")
                return
            }
            guard status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .unavailable("Request failed (\(status))")
                return
            }

            result = .loaded(
                fiveHour: window(json["five_hour"]),
                sevenDay: window(json["seven_day"]),
                updated: Date())
        }.resume()
        semaphore.wait()
        return result
    }

    private static func window(_ value: Any?) -> Window? {
        guard let dict = value as? [String: Any],
              let utilization = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let resetsAt = (dict["resets_at"] as? String).flatMap(parseDate)
        return Window(utilization: utilization, resetsAt: resetsAt)
    }

    private static func parseDate(_ string: String) -> Date? {
        // e.g. "2026-10-28T07:09:59.813329+00:00"; the formatter wants at most
        // millisecond precision so drop the extra fractional digits.
        let trimmed = string.replacingOccurrences(
            of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed)
    }

    private enum AccessToken {
        case token(String)
        case expired
        case missing
    }

    /// Claude Code's OAuth access token.
    ///
    /// We read through `/usr/bin/security` like Claude Code does: the keychain item
    /// trusts that tool, so Ghostty doesn't trigger a keychain access prompt.
    private static func accessToken() -> AccessToken {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .missing
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return .missing }

        // expiresAt is in milliseconds since the epoch.
        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expiresAt / 1000) < Date() {
            return .expired
        }

        return .token(token)
    }
}
