import AppKit
import Combine
import SwiftUI

/// The state for the Claude session sidebar of a single terminal window.
final class SessionSidebarModel: ObservableObject {
    /// Claude session IDs that are open in some tab, across all windows.
    @Published private(set) var openSessionIDs: Set<String> = []

    private weak var controller: TerminalController?
    private var cancellables: Set<AnyCancellable> = []
    private var refreshScheduled = false

    init(controller: TerminalController) {
        self.controller = controller

        // Tabs opening or closing can change which sessions are open.
        let center = NotificationCenter.default
        Publishers.MergeMany(
            center.publisher(for: NSWindow.didBecomeKeyNotification),
            center.publisher(for: NSWindow.willCloseNotification)
        )
        .sink { [weak self] _ in self?.scheduleRefresh() }
        .store(in: &cancellables)
    }

    /// Coalesce bursts of notifications into one refresh on the next runloop turn.
    /// This also lets AppKit settle window state (e.g. after a window closes).
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        let open = Set(TerminalController.all.compactMap { $0.window != nil ? $0.claudeSessionID : nil })
        if open != openSessionIDs { openSessionIDs = open }
    }

    /// The last path component of a directory, or "~" for the home directory.
    static func directoryName(_ path: String) -> String {
        if path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        return (path as NSString).lastPathComponent
    }

    /// Focuses the tab already running this session, or opens a new tab that
    /// resumes it in the session's original working directory.
    func open(_ session: ClaudeSession) {
        if let existing = TerminalController.all.first(where: { $0.claudeSessionID == session.id }),
           let existingWindow = existing.window {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        guard let controller else { return }

        var config = Ghostty.SurfaceConfiguration()
        if let cwd = session.projectDir ?? session.cwd, FileManager.default.fileExists(atPath: cwd) {
            config.workingDirectory = cwd
        } else {
            config.workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        }

        // Sent through the user's shell so their PATH (and claude install) applies.
        config.initialInput = "claude --resume \(Ghostty.Shell.quote(session.id))\n"

        let newController = TerminalController.newTab(
            controller.ghostty,
            from: controller.window,
            withBaseConfig: config)
        newController?.claudeSessionID = session.id
        newController?.claudeSessionDir = session.projectDir ?? session.cwd
        scheduleRefresh()
    }
}

// MARK: - Views

struct SessionSidebarView: View {
    /// The fixed sidebar width. Shared by all windows so switching tabs doesn't jump.
    static let width: CGFloat = 260

    /// The width of the strip left when the sidebar is collapsed.
    static let collapsedWidth: CGFloat = 36

    /// Collapsed state is shared by all windows and persisted.
    private static let collapsedKey = "SessionSidebarCollapsed"

    /// The width the sidebar currently takes, for sizing new windows.
    static var currentWidth: CGFloat {
        UserDefaults.standard.bool(forKey: collapsedKey) ? collapsedWidth : width
    }

    @ObservedObject var model: SessionSidebarModel
    @ObservedObject var sessions: ClaudeSessionStore = .shared
    @ObservedObject var ghostty: Ghostty.App

    @AppStorage(collapsedKey) private var collapsed = false
    @State private var archivedExpanded = false
    @State private var renamingSessionID: String?
    @State private var renameText = ""

    private var background: Color {
        Color(nsColor: NSColor(ghostty.config.backgroundColor).blended(withFraction: 0.06, of: .white)
            ?? .windowBackgroundColor)
    }

    private var colorScheme: ColorScheme {
        NSColor(ghostty.config.backgroundColor).isLightColor ? .light : .dark
    }

    var body: some View {
        Group {
            if collapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .frame(width: collapsed ? Self.collapsedWidth : Self.width)
        .frame(maxHeight: .infinity)
        .background(background.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .environment(\.colorScheme, colorScheme)
        .onAppear {
            model.refresh()
            sessions.refresh()
        }
    }

    private func toggleCollapsed() {
        withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
    }

    private var collapsedBody: some View {
        VStack {
            Button(action: toggleCollapsed) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show Sidebar")
            .padding(.top, 12)

            Spacer()
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        // Sessions open in a tab are in use, so never hide them in the archive.
        let isArchived = { (s: ClaudeSession) in
            !model.openSessionIDs.contains(s.id) && sessions.isArchived(s)
        }
        // In both lists starred sessions are pinned to the top; otherwise newest first.
        let starredFirst = { (list: [ClaudeSession]) in
            list.filter { sessions.metadata(for: $0.id).starred }
                + list.filter { !sessions.metadata(for: $0.id).starred }
        }
        let pinned = starredFirst(sessions.sessions.filter { !isArchived($0) })
        let archived = starredFirst(sessions.sessions.filter(isArchived))

        VStack(spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    SectionHeader(title: "Claude Sessions") {
                        HStack(spacing: 10) {
                            Button(action: { sessions.refresh() }) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("Refresh")

                            Button(action: toggleCollapsed) {
                                Image(systemName: "sidebar.left")
                            }
                            .help("Hide Sidebar")
                        }
                        .buttonStyle(.plain)
                    }

                    if pinned.isEmpty {
                        Text("No sessions")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }

                    ForEach(pinned) { sessionRow($0) }

                    if !archived.isEmpty {
                        Button {
                            archivedExpanded.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: archivedExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("Archived (\(archived.count))")
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 4)

                        if archivedExpanded {
                            ForEach(archived) { sessionRow($0) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            Divider().opacity(0.5)
            SidebarFooter(sessions: sessions)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: ClaudeSession) -> some View {
        SessionRow(
            session: session,
            title: sessions.displayTitle(for: session),
            metadata: sessions.metadata(for: session.id),
            isArchived: sessions.isArchived(session),
            isOpen: model.openSessionIDs.contains(session.id),
            isRenaming: renamingSessionID == session.id,
            renameText: $renameText,
            onOpen: { model.open(session) },
            onStar: { sessions.setStarred(!sessions.metadata(for: session.id).starred, for: session.id) },
            onArchive: { sessions.setArchived(!sessions.isArchived(session), for: session.id) },
            onBeginRename: {
                renameText = sessions.displayTitle(for: session)
                renamingSessionID = session.id
            },
            onCommitRename: {
                sessions.rename(session.id, to: renameText)
                renamingSessionID = nil
            },
            onCancelRename: { renamingSessionID = nil },
            onResetName: { sessions.rename(session.id, to: nil) })
    }
}

/// The bottom-left settings menu.
private struct SidebarFooter: View {
    @ObservedObject var sessions: ClaudeSessionStore
    @ObservedObject var usage: ClaudeUsageStore = .shared

    private static let autoArchiveChoices = [1, 3, 7, 14, 30, 0]

    private static func label(days: Int) -> String {
        switch days {
        case 0: return "Never"
        case 1: return "After 1 Day"
        default: return "After \(days) Days"
        }
    }

    @ViewBuilder
    private var usageItems: some View {
        switch usage.state {
        case .loading:
            Text("Loading…")
        case .unavailable(let reason):
            Text(reason)
        case .loaded(let fiveHour, let sevenDay, let updated):
            Text(Self.label("5h Window", fiveHour))
            Text(Self.label("7d Window", sevenDay))
            Text("Updated \(Self.timeFormatter.string(from: updated))")
        }
        Button("Refresh Usage") { usage.refresh() }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd HH:mm")
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    /// e.g. "5h Window: 95% left · resets 15:09 (in 2h 27m)"
    private static func label(_ name: String, _ window: ClaudeUsageStore.Window?) -> String {
        guard let window else { return "\(name): unavailable" }
        var text = "\(name): \(Int(window.remaining.rounded()))% left"
        if let resetsAt = window.resetsAt {
            let sameDay = Calendar.current.isDateInToday(resetsAt)
            let time = (sameDay ? timeFormatter : dateTimeFormatter).string(from: resetsAt)
            text += " · resets \(time)"
            if let remaining = durationFormatter.string(from: max(60, resetsAt.timeIntervalSinceNow)) {
                text += " (in \(remaining))"
            }
        }
        return text
    }

    var body: some View {
        HStack {
            Menu {
                Section("Claude Usage") {
                    usageItems
                }

                Picker("Auto-Archive Inactive Sessions", selection: $sessions.autoArchiveDays) {
                    ForEach(Self.autoArchiveChoices, id: \.self) { days in
                        Text(Self.label(days: days)).tag(days)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Button("Open Ghostty Config…") {
                    (NSApp.delegate as? AppDelegate)?.openConfig(nil)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sidebar Settings")
            // Menus don't report opening, so refresh when the pointer approaches.
            .onHover { if $0 { usage.refreshIfStale() } }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct SectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            accessory
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// Shared row chrome: rounded hover/selection background.
private struct SidebarRowBackground: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isSelected ? 0.12 : (isHovered ? 0.06 : 0))))
            .contentShape(Rectangle())
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let title: String
    let metadata: ClaudeSessionMetadata
    let isArchived: Bool
    let isOpen: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let onOpen: () -> Void
    let onStar: () -> Void
    let onArchive: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onResetName: () -> Void

    @State private var isHovered = false
    @FocusState private var renameFocused: Bool

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var tooltip: String {
        let time = Self.relativeFormatter.localizedString(for: session.lastActivity, relativeTo: Date())
        return [session.cwd ?? session.id, time].joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($renameFocused)
                        .onSubmit(onCommitRename)
                        .onExitCommand(perform: onCancelRename)
                        .onAppear { renameFocused = true }
                } else {
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                SessionDetailLine(session: session)
            }

            Spacer(minLength: 4)

            if isOpen {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .help("Open in a tab")
            }

            if isHovered || metadata.starred {
                Button(action: onStar) {
                    Image(systemName: metadata.starred ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(metadata.starred ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(metadata.starred ? "Unstar" : "Star")
            }
        }
        .padding(.vertical, 4)
        .modifier(SidebarRowBackground(isSelected: false, isHovered: isHovered))
        .onHover { isHovered = $0 }
        .onTapGesture { if !isRenaming { onOpen() } }
        .help(tooltip)
        .contextMenu {
            Button("Open") { onOpen() }
            Divider()
            Button(metadata.starred ? "Unstar" : "Star", action: onStar)
            Button(isArchived ? "Unarchive" : "Archive", action: onArchive)
            Button("Rename…", action: onBeginRename)
            if metadata.displayName != nil {
                Button("Reset Name", action: onResetName)
            }
            Divider()
            if let cwd = session.cwd {
                Button("Reveal Directory in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                }
            }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
        }
    }
}

/// The second line of a session: current directory and remaining context,
/// e.g. "ghostty · 192k · 余 81% ▮▮░░░░".
private struct SessionDetailLine: View {
    let session: ClaudeSession

    private var directory: String? {
        session.cwd.map(SessionSidebarModel.directoryName)
    }

    private static func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1000 { return "\(tokens / 1000)k" }
        return "\(tokens)"
    }

    var body: some View {
        HStack(spacing: 4) {
            if let directory {
                Text(directory)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let tokens = session.contextTokens, let remaining = session.contextRemaining {
                if directory != nil { Text("·") }
                Text("\(Self.formatTokens(tokens)) · 余 \(Int((remaining * 100).rounded()))%")
                    .lineLimit(1)
                    .fixedSize()
                ContextBar(used: 1 - remaining)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.tertiary)
    }
}

/// A small bar showing how much of the context window is used.
private struct ContextBar: View {
    /// Fraction of the context window used, 0...1.
    let used: Double

    private var fill: Color {
        switch used {
        case 0.9...: return .red
        case 0.75...: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.12))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fill)
                    .frame(width: geo.size.width * min(max(used, 0), 1))
            }
        }
        .frame(width: 24, height: 5)
    }
}
