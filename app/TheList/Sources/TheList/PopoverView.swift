import SwiftUI
import TheListCore

/// What the popover's controls do. The defaults do nothing, for `--render`.
struct PopoverActions {
    var toggle: @MainActor (ItemView) -> Void = { _ in }
    var open: @MainActor (ItemView) -> Void = { _ in }
    var move: @MainActor (ItemView, Priority) -> Void = { _, _ in }
    var add: @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void = { _, done in done(false) }
    /// E8.2–E8.3: show a group, put a task in one (nil takes its `group` key off), make a new one.
    var selectFilter: @MainActor (GroupFilter) -> Void = { _ in }
    var setGroup: @MainActor (ItemView, String?) -> Void = { _, _ in }
    var addGroup: @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void = { _, done in done(false) }
    /// E8.4
    var exportReminders: @MainActor () -> Void = {}
    var exporting = false
    /// E9: keep the Mac awake for Claude Code and Codex. `agentLid` is the lid-closed part.
    var agentOn = false
    var agentLid = false
    var agentBusy = false
    var setAgent: @MainActor (Bool) -> Void = { _ in }
    var quit: @MainActor () -> Void = {}
    var openURL: @MainActor (URL) -> Void = { _ in }
    var reveal: @MainActor (String) -> Void = { _ in }
    var todoPath = ""
    var message: String?
    var messageIsError = true
}

/// The popover: a group picker (E8.2), quick-add (E5.4), the four priority groups (E4.3), a
/// collapsible Done section (E5.1), and a task's details when one is clicked.
struct PopoverView: View {
    let snapshot: ListSnapshot
    let today: String
    var actions = PopoverActions()
    /// Off for `--render`: ImageRenderer doesn't draw ScrollView content.
    var scrollable = true

    @State var showDone = false
    /// The task whose details are showing, by `key(_:)`; nil shows the list.
    @State var selected: String?
    @State private var draft = ""
    @State private var adding = false
    /// Naming a new group in the header (E8.3).
    @State private var naming = false
    @State private var groupDraft = ""
    @FocusState private var groupFieldFocused: Bool
    @State private var contentHeight: CGFloat = 0
    /// The whole popover's height, for `WindowFitter`.
    @State private var popoverHeight: CGFloat = 0
    private let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = selectedItem {
                fitting {
                    DetailView(item: item, today: today, group: snapshot.group(of: item), actions: actions) { selected = nil }
                }
            } else {
                header
                quickAdd
                Divider()
                fitting { list }
            }
            Divider()
            agentRow
            Divider()
            footer
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { popoverHeight = $0 }
        .background { if scrollable { WindowFitter(height: popoverHeight) } }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    static func key(_ item: ItemView) -> String { item.id ?? "title:\(item.title)" }

    /// Looked up fresh each time, so the details follow the task through edits and moves.
    private var selectedItem: ItemView? {
        guard let selected else { return nil }
        return (snapshot.groups.flatMap(\.items) + snapshot.done).first { Self.key($0) == selected }
    }

    private func select(_ item: ItemView) { selected = Self.key(item) }

    /// Scrolls once the content is taller than `maxListHeight`; otherwise sizes to fit.
    @ViewBuilder
    private func fitting<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if scrollable {
            ScrollView {
                content().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 1), maxListHeight))
        } else {
            content()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if naming {
                TextField("New group name", text: $groupDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($groupFieldFocused)
                    .onSubmit(saveGroup)
                    .onExitCommand { naming = false }
                Text("Cancel")
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { naming = false }
                    .accessibilityAddTraits(.isButton)
            } else {
                groupPicker
                Spacer()
                let open = snapshot.openCount
                Text(open == 1 ? "1 open" : "\(open) open")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// "The List ⌄" when showing everything, else the group's name.
    private var groupPicker: some View {
        Menu {
            filterButton(.all, "All")
            if !snapshot.taskGroups.isEmpty { Divider() }
            ForEach(snapshot.taskGroups) { group in filterButton(.group(group.id), group.name) }
            if (snapshot.openCounts[.ungrouped] ?? 0) > 0 || snapshot.filter == .ungrouped {
                filterButton(.ungrouped, "Ungrouped")
            }
            Divider()
            Button("New Group…") {
                groupDraft = ""
                naming = true
                groupFieldFocused = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(snapshot.filter == .all ? "The List" : snapshot.filterName).font(.headline)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Group: \(snapshot.filterName)")
    }

    private func filterButton(_ filter: GroupFilter, _ name: String) -> some View {
        let title = "\(name) (\(snapshot.openCounts[filter] ?? 0))"
        return Button {
            actions.selectFilter(filter)
        } label: {
            if snapshot.filter == filter { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func saveGroup() {
        guard !groupDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.addGroup(groupDraft) { added in if added { naming = false } }
    }

    private var quickAdd: some View {
        TextField("Add a task", text: $draft)
            .textFieldStyle(.roundedBorder)
            .disabled(adding)
            .onSubmit {
                guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                adding = true
                actions.add(draft) { added in
                    if added { draft = "" }
                    adding = false
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.isEmpty && snapshot.done.isEmpty {
                Text("Nothing on the list.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(snapshot.groups) { group in
                    GroupSection(group: group, snapshot: snapshot, today: today, actions: actions, select: select)
                }
                if !snapshot.done.isEmpty { doneSection }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: showDone ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 10)
                Text("Done").font(.subheadline.weight(.semibold))
                Text("\(snapshot.done.count)").font(.subheadline.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture { showDone.toggle() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(showDone ? "Hide done items" : "Show \(snapshot.done.count) done items")

            if showDone {
                ForEach(snapshot.done, id: \.line) { item in
                    ItemRow(item: item, snapshot: snapshot, today: today, actions: actions, select: select)
                }
            }
        }
    }

    /// E9: one switch for keeping agents running. Shown under the list and the details alike.
    private var agentRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(actions.agentOn ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent mode")
                Text(agentSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if actions.agentBusy {
                ProgressView().controlSize(.small)
            } else {
                Toggle("Agent mode", isOn: Binding(get: { actions.agentOn }, set: { actions.setAgent($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .help("Keeps the Mac awake so Claude Code and Codex keep working. Turning it on asks for your password to stay awake with the lid closed. With the lid closed the Mac can get hot, so don't put it in a bag.")
    }

    private var agentSubtitle: String {
        if actions.agentBusy { return "Waiting for your password…" }
        if !actions.agentOn { return "Mac sleeps as usual" }
        return actions.agentLid ? "Awake, even with the lid closed" : "Awake while the screen is off"
    }

    private var footer: some View {
        HStack {
            if let message = actions.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(actions.messageIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer()
            if actions.exporting {
                ProgressView().controlSize(.small)
            } else if actions.message == nil {
                Text("Export to Reminders")
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.exportReminders() }
                    .accessibilityAddTraits(.isButton)
                    .help("Copy open tasks into Apple Reminders, one list per group. Running it again updates them.")
            }
            Text("Quit")
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture { actions.quit() }
                .accessibilityAddTraits(.isButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct GroupSection: View {
    let group: ListGroup
    let snapshot: ListSnapshot
    let today: String
    let actions: PopoverActions
    let select: (ItemView) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(group.priority == .p0 && group.count > 0 ? Color.red : Color.primary)
                Text("\(group.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
            .opacity(group.count == 0 ? 0.45 : 1)
            ForEach(group.items, id: \.line) { item in
                ItemRow(item: item, snapshot: snapshot, today: today, actions: actions, select: select)
            }
        }
    }
}

private struct ItemRow: View {
    let item: ItemView
    let snapshot: ListSnapshot
    let today: String
    let actions: PopoverActions
    let select: (ItemView) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .contentShape(Rectangle())
                .onTapGesture { actions.toggle(item) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(item.done ? "Mark \(item.title) not done" : "Mark \(item.title) done")

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.done, item.meta["project"] != nil || item.meta["due"] != nil {
                    HStack(spacing: 6) {
                        if let project = item.meta["project"] {
                            Text(project)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                        }
                        if let label = relativeDueLabel(item.meta["due"], today: today) {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(dueColor)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { select(item) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows details")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.secondary.opacity(0.12) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show Details") { select(item) }
            Button("Open") { actions.open(item) }
            if !item.done {
                Divider()
                ForEach(Priority.allCases, id: \.self) { priority in
                    let current = item.priority.rawValue == priority.rawValue
                    Button {
                        actions.move(item, priority)
                    } label: {
                        if current { Label(menuTitle(priority), systemImage: "checkmark") } else { Text(menuTitle(priority)) }
                    }
                    .disabled(current)
                }
            }
            if !snapshot.taskGroups.isEmpty {
                Divider()
                Menu("Move to Group") {
                    let current = snapshot.group(of: item)?.id
                    ForEach(snapshot.taskGroups) { group in
                        Button {
                            actions.setGroup(item, group.id)
                        } label: {
                            if group.id == current { Label(group.name, systemImage: "checkmark") } else { Text(group.name) }
                        }
                        .disabled(group.id == current && item.meta["group"] != nil)
                    }
                    if item.meta["group"] != nil {
                        Divider()
                        Button("Remove from Group") { actions.setGroup(item, nil) }
                    }
                }
            }
        }
    }

    private func menuTitle(_ p: Priority) -> String {
        switch p {
        case .p0: "Move to Now (P0)"
        case .p1: "Move to This week (P1)"
        case .p2: "Move to Soon (P2)"
        case .p3: "Move to Someday (P3)"
        }
    }

    private var dueColor: Color {
        if isOverdue(item, today: today) { return .red }
        if item.meta["due"] == today { return .orange }
        return .secondary
    }
}
