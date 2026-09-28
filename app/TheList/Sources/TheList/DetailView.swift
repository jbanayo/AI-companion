import SwiftUI
import TheListCore

/// Clicking a task shows this in place of the list: its full context, and buttons that fit
/// where its link points (open the link, open in VS Code, show in Finder, or open TODO.md).
struct DetailView: View {
    let item: ItemView
    let today: String
    let actions: PopoverActions
    let back: () -> Void

    private var target: LinkTarget { linkTarget(for: item, todoPath: actions.todoPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
                Text("The List").font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture(perform: back)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Back to the list")
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                titleRow
                context
                facts
                Divider()
                buttons
            }
            .padding(14)
        }
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .contentShape(Rectangle())
                    .onTapGesture { actions.toggle(item) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(item.done ? "Mark not done" : "Mark done")
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .strikethrough(item.done)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.meta["project"] != nil || (item.meta["due"] != nil && !item.done) {
                HStack(spacing: 6) {
                    if let project = item.meta["project"] {
                        Text(project)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                    if !item.done, let label = relativeDueLabel(item.meta["due"], today: today) {
                        Text(label).font(.caption).foregroundStyle(dueColor)
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    /// The note plus any indented lines written under the task in TODO.md.
    @ViewBuilder
    private var context: some View {
        let text = ([item.meta["note"]].compactMap { $0 } + item.body).joined(separator: "\n")
        if text.isEmpty {
            Text("No notes. Add some under the task in TODO.md.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            if !item.done { fact("Priority", priorityText) }
            if let due = item.meta["due"] {
                // Only add the relative label when it says something the date doesn't.
                let relative = relativeDueLabel(due, today: today) ?? ""
                let adds = !item.done && (relative == "Today" || relative == "Tomorrow" || relative.hasPrefix("Overdue"))
                fact("Due", adds ? "\(formattedDay(due, today: today)) (\(relative))" : formattedDay(due, today: today))
            }
            if let added = addedText { fact("Added", added) }
            if item.done, let done = item.meta["done"] { fact("Done", formattedDay(done, today: today)) }
        }
        .font(.caption)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let path = target.filePath
        let exists = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(primaryTitle, systemImage: primaryIcon) { actions.openURL(target.url) }
                    .buttonStyle(.borderedProminent)
                if let path {
                    Button("Show in Finder", systemImage: "folder") { actions.reveal(path) }
                        .disabled(!exists)
                }
            }
            .controlSize(.small)

            Text(caption(path: path, exists: exists))
                .font(.caption)
                .foregroundStyle(path != nil && !exists ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(2)
                .truncationMode(.middle)

            if case .todoLine = target {} else {
                Text("Edit in TODO.md")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.openURL(todoLineURL(for: item, todoPath: actions.todoPath)) }
                    .accessibilityAddTraits(.isLink)
            }
        }
    }

    // MARK: - Copy

    private var primaryTitle: String {
        switch target {
        case .web: "Open link"
        case .vscodeFile: "Open in VS Code"
        case .file, .other: "Open"
        case .todoLine: "Open in TODO.md"
        }
    }

    private var primaryIcon: String {
        switch target {
        case .web: "safari"
        case .vscodeFile, .todoLine: "chevron.left.forwardslash.chevron.right"
        case .file: "doc"
        case .other: "arrow.up.forward.app"
        }
    }

    private func caption(path: String?, exists: Bool) -> String {
        if let path {
            let short = (path as NSString).abbreviatingWithTildeInPath
            return exists ? short : "File not found: \(short)"
        }
        switch target {
        case let .web(url): return (url.host ?? "") + url.path
        case .todoLine: return "No link. This opens the task's line in TODO.md."
        default: return target.url.absoluteString
        }
    }

    private var priorityText: String {
        let filed = groupName(item.priority)
        switch displayPriority(item, today: today) {
        case .p0 where item.priority != .p0:
            let why = isOverdue(item, today: today) ? "overdue" : "due today"
            return "\(filed), showing under Now because it's \(why)"
        default:
            return filed
        }
    }

    private func groupName(_ s: TheListCore.Section) -> String {
        switch s {
        case .p0: "Now (P0)"
        case .p1: "This week (P1)"
        case .p2, .done: "Soon (P2)"
        case .p3: "Someday (P3)"
        }
    }

    private var addedText: String? {
        let by: String? = switch item.meta["src"] {
        case "claude-code": "Claude Code"
        case "claude-desktop": "Claude Desktop"
        case "manual": "you"
        case let other: other
        }
        switch (item.meta["added"], by) {
        case let (added?, by?): return "\(formattedDay(added, today: today)) by \(by)"
        case let (added?, nil): return formattedDay(added, today: today)
        case let (nil, by?): return "by \(by)"
        case (nil, nil): return nil
        }
    }

    private var dueColor: Color {
        if isOverdue(item, today: today) { return .red }
        if item.meta["due"] == today { return .orange }
        return .secondary
    }
}
