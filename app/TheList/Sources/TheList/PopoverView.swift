import SwiftUI
import TheListCore

/// What the popover's controls do. The defaults do nothing, for `--render`.
struct PopoverActions {
    var toggle: @MainActor (ItemView) -> Void = { _ in }
    var open: @MainActor (ItemView) -> Void = { _ in }
    var move: @MainActor (ItemView, Priority) -> Void = { _, _ in }
    var add: @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void = { _, done in done(false) }
    var quit: @MainActor () -> Void = {}
    var message: String?
}

/// The popover: quick-add (E5.4), the four priority groups (E4.3), and a collapsible Done section (E5.1).
struct PopoverView: View {
    let snapshot: ListSnapshot
    let today: String
    var actions = PopoverActions()
    /// Off for `--render`: ImageRenderer doesn't draw ScrollView content.
    var scrollable = true

    @State var showDone = false
    @State private var draft = ""
    @State private var adding = false
    @State private var contentHeight: CGFloat = 0
    private let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            quickAdd
            Divider()
            if scrollable {
                ScrollView {
                    list.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(max(contentHeight, 1), maxListHeight))
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("The List").font(.headline)
            Spacer()
            let open = snapshot.groups.reduce(0) { $0 + $1.count }
            Text(open == 1 ? "1 open" : "\(open) open")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
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
                    GroupSection(group: group, today: today, actions: actions)
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
                    ItemRow(item: item, today: today, actions: actions)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let message = actions.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
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
    let today: String
    let actions: PopoverActions

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
                ItemRow(item: item, today: today, actions: actions)
            }
        }
    }
}

private struct ItemRow: View {
    let item: ItemView
    let today: String
    let actions: PopoverActions
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
            .onTapGesture { actions.open(item) }
            .accessibilityAddTraits(.isLink)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.secondary.opacity(0.12) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
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
