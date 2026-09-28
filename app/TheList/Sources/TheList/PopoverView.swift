import SwiftUI
import TheListCore

/// The popover (E4.3): four priority groups with counts, then a footer.
struct PopoverView: View {
    let snapshot: ListSnapshot
    let today: String
    /// Off for `--render`: ImageRenderer doesn't draw ScrollView content.
    var scrollable = true

    @State private var contentHeight: CGFloat = 0
    private let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
        .padding(.vertical, 10)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.isEmpty {
                Text("Nothing on the list.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(snapshot.groups) { group in
                    GroupSection(group: group, today: today)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct GroupSection: View {
    let group: ListGroup
    let today: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(group.priority == .p0 && group.count > 0 ? Color.red : Color.primary)
                Text("\(group.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .opacity(group.count == 0 ? 0.45 : 1)
            ForEach(group.items, id: \.line) { item in
                ItemRow(item: item, today: today)
            }
        }
    }
}

private struct ItemRow: View {
    let item: ItemView
    let today: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if item.meta["project"] != nil || item.meta["due"] != nil {
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
            Spacer(minLength: 0)
        }
    }

    private var dueColor: Color {
        if isOverdue(item, today: today) { return .red }
        if item.meta["due"] == today { return .orange }
        return .secondary
    }
}
