// E8.4: what a task looks like as an Apple Reminder. Pure, so fixture-check can test it;
// the EventKit side is app/TheList/Sources/TheList/RemindersExport.swift.
import Foundation

public struct ReminderDraft: Equatable, Sendable {
    public let taskId: String
    public let title: String
    /// The Reminders list it goes in: "The List · <group>", or "The List" when ungrouped.
    public let listName: String
    /// EventKit's scale: 1 high, 5 medium, 9 low, 0 none.
    public let priority: Int
    /// All-day due date, only for a real `YYYY-MM-DD` date.
    public let due: DateComponents?
    public let url: URL?
    public let notes: String
    public let completed: Bool

    public init(taskId: String, title: String, listName: String, priority: Int, due: DateComponents?,
                url: URL?, notes: String, completed: Bool) {
        self.taskId = taskId
        self.title = title
        self.listName = listName
        self.priority = priority
        self.due = due
        self.url = url
        self.notes = notes
        self.completed = completed
    }
}

public let remindersListPrefix = "The List"

public func remindersListName(for group: TaskGroup?) -> String {
    group.map { "\(remindersListPrefix) · \($0.name)" } ?? remindersListPrefix
}

/// Nil for an item without an id: there's nothing to match it by on the next export.
public func reminderDraft(for item: ItemView, groups: [TaskGroup], today: String) -> ReminderDraft? {
    guard let id = item.id else { return nil }

    let priority: Int = switch displayPriority(item, today: today) {
    case .p0: 1
    case .p1: 5
    case .p2: 9
    case .p3, .done: 0
    }

    var due: DateComponents?
    if let d = item.meta["due"], isValidDate(d) {
        let parts = d.split(separator: "-").compactMap { Int($0) }
        due = DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    var url: URL?
    if let link = item.meta["link"].map(jsTrim), !link.isEmpty {
        if link.hasPrefix("/") || link.hasPrefix("~/") {
            url = URL(fileURLWithPath: (link as NSString).expandingTildeInPath)
        } else {
            url = URL(string: link) ?? URL(string: link.replacingOccurrences(of: " ", with: "%20"))
        }
    }

    var notes: [String] = []
    if let note = item.meta["note"], !note.isEmpty { notes.append(note) }
    if !item.body.isEmpty { notes.append(item.body.joined(separator: "\n")) }
    notes.append("\(remindersListPrefix) · \(id)")

    return ReminderDraft(
        taskId: id,
        title: item.title,
        listName: remindersListName(for: effectiveGroup(item, groups: groups)),
        priority: priority,
        due: due,
        url: url,
        notes: notes.joined(separator: "\n\n"),
        completed: item.done
    )
}
