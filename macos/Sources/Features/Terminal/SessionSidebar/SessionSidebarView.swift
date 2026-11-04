import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The state for the Claude session sidebar of a single terminal window.
@MainActor
final class SessionSidebarModel: ObservableObject {
    /// Claude session IDs that are running anywhere (in any terminal).
    @Published private(set) var openSessionIDs: Set<String> = []

    private weak var controller: TerminalController?
    private var cancellables: Set<AnyCancellable> = []

    init(controller: TerminalController) {
        self.controller = controller

        ClaudeLiveSessions.shared.$running
            .map { Set($0.keys) }
            .removeDuplicates()
            .sink { [weak self] in self?.openSessionIDs = $0 }
            .store(in: &cancellables)
    }

    func refresh() {
        ClaudeLiveSessions.shared.refresh()
    }

    /// The last path component of a directory, or "~" for the home directory.
    static func directoryName(_ path: String) -> String {
        if path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        return (path as NSString).lastPathComponent
    }

    /// The Ghostty tab running or opened for this session, if any.
    private func tab(for session: ClaudeSession) -> TerminalController? {
        ClaudeLiveSessions.shared.controller(for: session.id)
            ?? ClaudeLiveSessions.shared.openControllers.first { $0.claudeSessionID == session.id }
    }

    /// Focuses the tab already running this session, or opens a new tab that
    /// resumes it in the session's original working directory.
    func open(_ session: ClaudeSession) {
        if let existing = tab(for: session), let window = existing.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let controller else { return }
        Self.resume(sessionID: session.id, in: session.projectDir ?? session.cwd, from: controller)
    }

    /// Opens a new tab that resumes a session.
    static func resume(sessionID: String, in directory: String?, from controller: TerminalController) {
        let newController = newTab(
            from: controller,
            in: directory,
            command: "claude --resume \(Ghostty.Shell.quote(sessionID))")
        newController?.claudeSessionID = sessionID
        newController?.claudeSessionDir = directory
    }

    /// Whether the session runs in another terminal app, where we can't restart it.
    func isRunningOutsideGhostty(_ session: ClaudeSession) -> Bool {
        openSessionIDs.contains(session.id) && ClaudeLiveSessions.shared.controller(for: session.id) == nil
    }

    /// Quits and resumes the session in its tab, or opens it if it isn't open.
    func restart(_ session: ClaudeSession) {
        guard !isRunningOutsideGhostty(session) else { return NSSound.beep() }
        guard let existing = tab(for: session) else { return open(session) }
        existing.window?.makeKeyAndOrderFront(nil)
        existing.restartClaudeSession()
    }

    /// Starts an ihk workflow for a requirement in a new tab.
    func startRequirement(_ requirementID: String, workflow: String) {
        newTab(
            in: NewRequirement.directory,
            command: "ihk flow run \(Ghostty.Shell.quote(workflow)) --ddp \(Ghostty.Shell.quote(requirementID))")
    }

    /// Opens a tab in `directory` (home if missing) and types `command` into its shell,
    /// so the user's PATH and shell setup apply.
    @discardableResult
    private func newTab(in directory: String?, command: String) -> TerminalController? {
        guard let controller else { return nil }
        return Self.newTab(from: controller, in: directory, command: command)
    }

    @discardableResult
    static func newTab(from controller: TerminalController, in directory: String?, command: String) -> TerminalController? {
        var config = Ghostty.SurfaceConfiguration()
        if let directory, FileManager.default.fileExists(atPath: directory) {
            config.workingDirectory = directory
        } else {
            config.workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        }
        config.initialInput = command + "\n"

        return TerminalController.newTab(controller.ghostty, from: controller.window, withBaseConfig: config)
    }
}

/// Starting a new requirement with `ihk flow run`.
enum NewRequirement {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("pax-api").path

    /// Used when `ihk flow list` can't be read (e.g. the directory isn't initialized).
    static let fallbackWorkflows = ["mobility-tech-flow-v2", "mobility-tech-flow-v3", "mobility-tech-flow"]

    /// The workflow selected by default.
    static let defaultWorkflow = "mobility-tech-flow-v2"

    /// Asks for a requirement ID and workflow. This is an AppKit alert rather than a
    /// SwiftUI popover: in the popover, ⌘V never reached the text field.
    static func prompt(_ onStart: @escaping (_ id: String, _ workflow: String) -> Void) {
        loadWorkflows { workflows in
            let alert = NSAlert()
            alert.messageText = "New Requirement"
            alert.informativeText = "Runs ihk flow run in \((directory as NSString).abbreviatingWithTildeInPath)"
            alert.addButton(withTitle: "Start")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 32, width: 280, height: 24))
            field.placeholderString = "Task ID, e.g. T-IBT-614650"
            // Prefill from the clipboard when it holds an ID, the usual way IDs arrive.
            if let clip = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
               isValidID(clip) {
                field.stringValue = clip
            }

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
            popup.addItems(withTitles: workflows)
            if workflows.contains(defaultWorkflow) {
                popup.selectItem(withTitle: defaultWorkflow)
            }

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
            container.addSubview(field)
            container.addSubview(popup)
            alert.accessoryView = container
            alert.window.initialFirstResponder = field

            while alert.runModal() == .alertFirstButtonReturn {
                let id = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard isValidID(id), let workflow = popup.titleOfSelectedItem else {
                    NSSound.beep()
                    alert.informativeText = "Enter a task ID like T-IBT-614650."
                    continue
                }
                onStart(id, workflow)
                return
            }
        }
    }

    /// Requirement IDs look like "T-IBT-614650".
    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[A-Z]+-[A-Z]+-\d+$"#, options: .regularExpression) != nil
    }

    /// Lists available workflows via `ihk flow list`, falling back to known names.
    static func loadWorkflows(_ completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            // A login shell, so PATH matches what the user's terminal has.
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            process.arguments = ["-lc", "ihk flow list"]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            var names: [String] = []
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                // Lines look like "  mobility-tech-flow-v2 [agent]".
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    let parts = line.split(separator: " ")
                    if parts.count == 2, parts[1].hasPrefix("["), line.hasPrefix("  ") {
                        names.append(String(parts[0]))
                    }
                }
            }

            DispatchQueue.main.async { completion(names.isEmpty ? fallbackWorkflows : names) }
        }
    }
}

// MARK: - Views

struct SessionSidebarView: View {
    /// The fixed sidebar width. Shared by all windows so switching tabs doesn't jump.
    static let width: CGFloat = 260

    /// Collapsed state is shared by all windows and persisted. The toggle lives in
    /// the titlebar (see TerminalController) so nothing is left when collapsed.
    static let collapsedKey = "SessionSidebarCollapsed"

    static func toggleCollapsed() {
        let defaults = UserDefaults.standard
        withAnimation(.easeInOut(duration: 0.15)) {
            defaults.set(!defaults.bool(forKey: collapsedKey), forKey: collapsedKey)
        }
    }

    /// The width the sidebar currently takes, for sizing new windows.
    static var currentWidth: CGFloat {
        UserDefaults.standard.bool(forKey: collapsedKey) ? 0 : width
    }

    @ObservedObject var model: SessionSidebarModel
    @ObservedObject var sessions: ClaudeSessionStore = .shared
    @ObservedObject var ghostty: Ghostty.App

    @AppStorage(collapsedKey) private var collapsed = false
    @State private var archivedExpanded = false
    @State private var renamingSessionID: String?
    @State private var renameText = ""
    @State private var searchText = ""

    private var background: Color {
        Color(nsColor: NSColor(ghostty.config.backgroundColor).blended(withFraction: 0.06, of: .white)
            ?? .windowBackgroundColor)
    }

    private var colorScheme: ColorScheme {
        NSColor(ghostty.config.backgroundColor).isLightColor ? .light : .dark
    }

    var body: some View {
        if !collapsed {
            sidebar
        }
    }

    private var sidebar: some View {
        expandedBody
        .frame(width: Self.width)
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
            sessions.refreshIfStale()
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
        let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        // While searching, archived sessions are included so they can be found.
        let pinned = searching
            ? starredFirst(sessions.sessions.filter(matchesSearch))
            : starredFirst(sessions.sessions.filter { !isArchived($0) })
        let archived = searching ? [] : starredFirst(sessions.sessions.filter(isArchived))

        // Filed sessions show under their category; the rest follow the categories.
        let categoryOf = { (s: ClaudeSession) -> String? in
            guard let name = sessions.metadata(for: s.id).category, sessions.categories.contains(name) else { return nil }
            return name
        }
        let unfiled = searching ? pinned : pinned.filter { categoryOf($0) == nil }

        VStack(spacing: 0) {
            toolbar

            ScrollView(.vertical) {
                // Not lazy: a session moving between sections keeps its ID, and a
                // LazyVStack would reuse the stale row at its old position. There are
                // only tens of rows, so laziness buys nothing.
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(title: "Claude Sessions") {
                        HStack(spacing: 10) {
                            Button(action: newCategory) {
                                Image(systemName: "folder.badge.plus")
                            }
                            .help("New Category")

                            Button(action: { sessions.refresh() }) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("Refresh")

                            Button(action: Self.toggleCollapsed) {
                                Image(systemName: "sidebar.left")
                            }
                            .help("Hide Sidebar")
                        }
                        .buttonStyle(.plain)
                    }
                    // Dropping a session on the header takes it out of its category.
                    .onDrop(of: [.plainText], isTargeted: nil) { providers in
                        dropSession(providers, into: nil)
                    }

                    if !searching {
                        ForEach(sessions.categories, id: \.self) { name in
                            categorySection(name, sessions: pinned.filter { categoryOf($0) == name })
                        }
                    }

                    if pinned.isEmpty {
                        Text(searching ? (sessions.isSearching ? "Searching…" : "No matches") : "No sessions")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }

                    ForEach(unfiled) { sessionRow($0) }

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
        // Debounce content search while typing.
        .task(id: searchText) {
            // Also runs when the view appears (every tab switch); nothing to do then.
            guard !searchText.isEmpty || sessions.contentMatches != nil else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            sessions.searchContent(searchText)
        }
    }

    // MARK: Categories

    @AppStorage("SessionSidebarCollapsedCategories") private var collapsedCategoriesRaw = ""

    private var collapsedCategories: Set<String> {
        Set(collapsedCategoriesRaw.split(separator: "\n").map(String.init))
    }

    private func toggleCategory(_ name: String) {
        var set = collapsedCategories
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
        collapsedCategoriesRaw = set.sorted().joined(separator: "\n")
    }

    @ViewBuilder
    private func categorySection(_ name: String, sessions filed: [ClaudeSession]) -> some View {
        let collapsed = collapsedCategories.contains(name)

        Button { toggleCategory(name) } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Image(systemName: "folder")
                Text(name)
                    .lineLimit(1)
                Spacer()
                Text("\(filed.count)")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            dropSession(providers, into: name)
        }
        .contextMenu {
            Button("Rename Category…") {
                if let new = Self.promptForName(title: "Rename Category", initial: name) {
                    sessions.renameCategory(name, to: new)
                }
            }
            Button("Move Up") { sessions.moveCategory(name, by: -1) }
                .disabled(sessions.categories.first == name)
            Button("Move Down") { sessions.moveCategory(name, by: 1) }
                .disabled(sessions.categories.last == name)
            Divider()
            Button("Delete Category") { sessions.deleteCategory(name) }
        }

        if !collapsed {
            ForEach(filed) { sessionRow($0, indented: true).id("\(name)/\($0.id)") }
        }
    }

    private func newCategory() {
        if let name = Self.promptForName(title: "New Category", initial: "") {
            sessions.addCategory(name)
        }
    }

    /// Asks for a category for the session, creating it, then files the session.
    private func fileInNewCategory(_ session: ClaudeSession) {
        guard let name = Self.promptForName(title: "New Category", initial: ""),
              let added = sessions.addCategory(name) else { return }
        sessions.setCategory(added, for: session.id)
    }

    private func dropSession(_ providers: [NSItemProvider], into category: String?) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            DispatchQueue.main.async { sessions.setCategory(category, for: id) }
        }
        return true
    }

    /// A simple modal text prompt.
    static func promptForName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Titles, names, and directories match immediately; prompt text matches once
    /// the background content search finishes.
    private func matchesSearch(_ session: ClaudeSession) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let fields = [
            sessions.displayTitle(for: session), session.title,
            session.cwd ?? "", session.projectDir ?? "", session.id,
        ]
        if fields.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        return sessions.contentMatches?.contains(session.id) ?? false
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            Button {
                NewRequirement.prompt { id, workflow in
                    model.startRequirement(id, workflow: workflow)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                    Text("New Requirement…")
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sessions", text: $searchText)
                    .textFieldStyle(.plain)
                    .onExitCommand { searchText = "" }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    @ViewBuilder
    private func sessionRow(_ session: ClaudeSession, indented: Bool = false) -> some View {
        SessionRow(
            session: session,
            indented: indented,
            title: sessions.displayTitle(for: session),
            metadata: sessions.metadata(for: session.id),
            isArchived: sessions.isArchived(session),
            isOpen: model.openSessionIDs.contains(session.id),
            isRenaming: renamingSessionID == session.id,
            renameText: $renameText,
            onOpen: { model.open(session) },
            categories: sessions.categories,
            onSetCategory: { sessions.setCategory($0, for: session.id) },
            onNewCategory: { fileInNewCategory(session) },
            canRestart: !model.isRunningOutsideGhostty(session),
            onRestart: { model.restart(session) },
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
        .equatable()
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

private struct SessionRow: View, Equatable {
    /// Closures are recreated on every render, so compare only the displayed data.
    /// This lets SwiftUI skip rows that didn't change when the list re-renders.
    static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.session == rhs.session && lhs.indented == rhs.indented && lhs.title == rhs.title
            && lhs.metadata == rhs.metadata && lhs.isArchived == rhs.isArchived
            && lhs.isOpen == rhs.isOpen && lhs.isRenaming == rhs.isRenaming
            && lhs.categories == rhs.categories && lhs.canRestart == rhs.canRestart
    }

    let session: ClaudeSession

    /// Rows inside a category are indented. This is part of the row (rather than a
    /// modifier on the ForEach) so lazily reused rows always get it.
    let indented: Bool
    let title: String
    let metadata: ClaudeSessionMetadata
    let isArchived: Bool
    let isOpen: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let onOpen: () -> Void
    let categories: [String]
    let onSetCategory: (String?) -> Void
    let onNewCategory: () -> Void
    let canRestart: Bool
    let onRestart: () -> Void
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
                    .help("Running")
            }

            if isHovered && canRestart {
                Button(action: onRestart) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Restart Session" : "Open Session")
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
        .padding(.leading, indented ? 12 : 0)
        .onHover { isHovered = $0 }
        .onTapGesture { if !isRenaming { onOpen() } }
        .onDrag { NSItemProvider(object: session.id as NSString) }
        .help(tooltip)
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Restart Session", action: onRestart)
                .disabled(!canRestart)
            Divider()
            Button(metadata.starred ? "Unstar" : "Star", action: onStar)
            Menu("Move to Category") {
                ForEach(categories, id: \.self) { name in
                    Button {
                        onSetCategory(name)
                    } label: {
                        if metadata.category == name {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                if !categories.isEmpty { Divider() }
                Button("New Category…", action: onNewCategory)
                if metadata.category != nil {
                    Button("Remove from Category") { onSetCategory(nil) }
                }
            }
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

    private static let width: CGFloat = 24

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.primary.opacity(0.12))
            RoundedRectangle(cornerRadius: 1.5)
                .fill(fill)
                .frame(width: Self.width * min(max(used, 0), 1))
        }
        .frame(width: Self.width, height: 5)
    }
}
