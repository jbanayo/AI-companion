import SwiftUI
import TheListCore

/// E5.6: the details form. It opens from the "Add details" note after a quick-add, or from Edit in
/// a task's details. It has the same fields Claude fills in, and Save writes only what changed.
struct EditView: View {
    let item: ItemView
    let today: String
    let snapshot: ListSnapshot
    let heading: String
    let actions: PopoverActions
    let close: () -> Void

    /// The form's values. `initial` is what they were when it opened, so Save can tell what changed.
    private struct Values: Equatable {
        var title: String
        var priority: Priority
        var due: String?
        var group: String?
        var project: String
        var link: String
        var note: String
    }

    private let initial: Values
    @State private var values: Values
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    init(item: ItemView, today: String, snapshot: ListSnapshot, heading: String, actions: PopoverActions,
         close: @escaping () -> Void) {
        self.item = item
        self.today = today
        self.snapshot = snapshot
        self.heading = heading
        self.actions = actions
        self.close = close
        // A group key spelled differently from the group's id ("Personal" for "personal") still
        // selects it, and doesn't count as a change.
        let group = item.meta["group"].map { key in
            snapshot.taskGroups.first { $0.id.lowercased() == key.lowercased() }?.id ?? key
        }
        let initial = Values(
            title: item.title,
            priority: Priority(rawValue: item.priority.rawValue) ?? .p2,
            due: item.meta["due"],
            group: group,
            project: item.meta["project"] ?? "",
            link: item.meta["link"] ?? "",
            note: item.meta["note"] ?? ""
        )
        self.initial = initial
        _values = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                row("Task") {
                    TextField("What needs doing", text: $values.title)
                        .textFieldStyle(.roundedBorder)
                        .focused($titleFocused)
                        .onSubmit(save)
                }
                if !item.done {
                    row("Priority") {
                        Picker("Priority", selection: $values.priority) {
                            Text("Now").tag(Priority.p0)
                            Text("Week").tag(Priority.p1)
                            Text("Soon").tag(Priority.p2)
                            Text("Someday").tag(Priority.p3)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .help("Now (P0), This week (P1), Soon (P2), Someday (P3)")
                    }
                }
                row("Due") { dueField }
                row("Group") { groupField }
                row("Project") { projectField }
                row("Link") {
                    TextField("https://, vscode://file/…, or a path", text: $values.link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                }
                row("Note") {
                    TextField("One line", text: $values.note)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                }
            }
            .font(.callout)
            .padding(14)

            if !item.body.isEmpty {
                Text("Lines written under this task in TODO.md stay as they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .onExitCommand(perform: close)
        .onAppear { titleFocused = true }
    }

    private var topBar: some View {
        HStack {
            Text("Cancel")
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityAddTraits(.isButton)
            Spacer()
            Text(heading).font(.subheadline.weight(.semibold))
            Spacer()
            if saving {
                ProgressView().controlSize(.small)
            } else {
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed(values.title) == nil)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content()
        }
    }

    // MARK: - Due

    private var dueField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                chip("Today", today)
                chip("Tomorrow", shiftDay(today, by: 1))
                chip("Next Mon", nextWeekday(2, after: today))
            }
            HStack(spacing: 6) {
                if let due = values.due {
                    if localDate(due) != nil {
                        DatePicker("Due", selection: Binding(
                            get: { localDate(values.due ?? today) ?? Date() },
                            set: { values.due = TheListCore.today($0) }
                        ), displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                    } else {
                        // Not a real date (typed by hand). Shown as-is so it can be cleared.
                        Text(due).foregroundStyle(.red)
                    }
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                        .onTapGesture { values.due = nil }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("No due date")
                        .help("No due date")
                } else {
                    Text("No due date").foregroundStyle(.secondary)
                    Text("Pick…")
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                        .onTapGesture { values.due = shiftDay(today, by: 7) ?? today }
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ label: String, _ day: String?) -> some View {
        if let day {
            let on = values.due == day
            Text(label)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(on ? Color.white : Color.primary)
                .contentShape(Capsule())
                .onTapGesture { values.due = on ? nil : day }
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .help(formattedDay(day, today: today))
        }
    }

    // MARK: - Group and project

    /// Without a group key, a task shows under its project's group, so "None" says which.
    private var noneLabel: String {
        guard let project = trimmed(values.project)?.lowercased(),
              let auto = snapshot.taskGroups.first(where: { $0.projects.contains { $0.lowercased() == project } })
        else { return "None" }
        return "Auto: \(auto.name) (from project)"
    }

    private var groupField: some View {
        Picker("Group", selection: $values.group) {
            Text(noneLabel).tag(String?.none)
            if !snapshot.taskGroups.isEmpty { Divider() }
            ForEach(snapshot.taskGroups) { group in
                Text(group.name).tag(Optional(group.id))
            }
            // A group key naming no group is kept, not silently dropped.
            if let key = initial.group, !snapshot.taskGroups.contains(where: { $0.id == key }) {
                Text("\(key) (not a group)").tag(Optional(key))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    /// Every group's projects, plus the ones already on tasks, without case duplicates.
    private var projectSuggestions: [String] {
        let all = snapshot.taskGroups.flatMap(\.projects)
            + (snapshot.groups.flatMap(\.items) + snapshot.done).compactMap { $0.meta["project"] }
        var seen = Set<String>()
        return all.filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var projectField: some View {
        HStack(spacing: 4) {
            TextField("e.g. prismo", text: $values.project)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            let suggestions = projectSuggestions
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { project in
                        Button(project) { values.project = project }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Pick a project")
            }
        }
    }

    // MARK: - Save

    private func trimmed(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private func change(_ from: String?, _ to: String?) -> FieldChange {
        let from = trimmed(from), to = trimmed(to)
        if from == to { return .keep }
        return to.map(FieldChange.set) ?? .remove
    }

    private func save() {
        guard !saving, let title = trimmed(values.title) else { return }
        var fields = UpdateFields()
        if title != initial.title { fields.title = title }
        if !item.done, values.priority != initial.priority { fields.priority = values.priority }
        fields.due = change(initial.due, values.due)
        fields.group = change(initial.group, values.group)
        fields.project = change(initial.project, values.project)
        fields.link = change(initial.link, values.link)
        fields.note = change(initial.note, values.note)

        let changes = [fields.due, fields.group, fields.project, fields.link, fields.note]
        guard fields.title != nil || fields.priority != nil || changes.contains(where: { $0 != .keep }) else {
            close()
            return
        }
        saving = true
        actions.update(item, fields) { saved in
            saving = false
            if saved { close() }
        }
    }
}
