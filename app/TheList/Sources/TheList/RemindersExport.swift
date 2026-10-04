import EventKit
import Foundation
import TheListCore

/// E8.4: copies tasks into Apple Reminders, one way. TODO.md stays the source of truth.
///
/// - Every open task goes in, in a list per group ("The List · BYC"); the mapping is `reminderDraft`.
/// - `data/reminders-map.json` remembers which reminder each task became, so exporting again updates
///   those reminders instead of adding new ones. A reminder deleted in Reminders comes back.
/// - A task ticked in The List ticks its reminder. Nothing is ever unticked: a reminder ticked
///   on the phone stays ticked.
/// - Nothing in Reminders is deleted, and nothing in Reminders comes back into TODO.md.
enum RemindersExport {
    struct Outcome: Sendable {
        var created = 0
        var updated = 0

        var summary: String {
            let total = created + updated
            let tasks = total == 1 ? "1 task" : "\(total) tasks"
            return created > 0 && updated > 0
                ? "Exported \(tasks) to Reminders (\(created) new)"
                : "Exported \(tasks) to Reminders"
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case denied
        case noSource

        var description: String {
            switch self {
            case .denied: "Allow The List in System Settings → Privacy & Security → Reminders"
            case .noSource: "Reminders has no account to add lists to"
            }
        }
    }

    static func mapPath(forTodoPath todoPath: String) -> String {
        URL(fileURLWithPath: todoPath).deletingLastPathComponent().appendingPathComponent("reminders-map.json").path
    }

    static func run(todoPath: String, groups: [TaskGroup], today: String) async throws -> Outcome {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw Failure.denied }

        // Through withTodoFile so a hand-typed task gets its id first: the id is what matches it next time.
        let items = try withTodoFile(at: todoPath) { deriveViews($0).items }
        let mapPath = mapPath(forTodoPath: todoPath)
        var map = readMap(mapPath)

        var lists: [String: EKCalendar] = [:]
        for calendar in store.calendars(for: .reminder) where lists[calendar.title] == nil {
            lists[calendar.title] = calendar
        }
        func list(named name: String) throws -> EKCalendar {
            if let existing = lists[name] { return existing }
            guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .local }) else { throw Failure.noSource }
            let calendar = EKCalendar(for: .reminder, eventStore: store)
            calendar.title = name
            calendar.source = source
            try store.saveCalendar(calendar, commit: true)
            lists[name] = calendar
            return calendar
        }

        var outcome = Outcome()
        var saved: [(String, EKReminder)] = []
        for item in items {
            guard let draft = reminderDraft(for: item, groups: groups, today: today) else { continue }
            let existing = map[draft.taskId].flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
            // A done task is only exported to tick a reminder made earlier.
            if draft.completed && existing == nil { continue }

            let reminder = existing ?? EKReminder(eventStore: store)
            reminder.title = draft.title
            reminder.calendar = try list(named: draft.listName)
            reminder.priority = draft.priority
            reminder.dueDateComponents = draft.due
            reminder.url = draft.url
            reminder.notes = draft.notes
            if draft.completed && !reminder.isCompleted { reminder.isCompleted = true }

            try store.save(reminder, commit: false)
            saved.append((draft.taskId, reminder))
            if existing == nil { outcome.created += 1 } else { outcome.updated += 1 }
        }
        try store.commit()

        for (id, reminder) in saved { map[id] = reminder.calendarItemIdentifier }
        try writeMap(map, to: mapPath)
        return outcome
    }

    private static func readMap(_ path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return map
    }

    private static func writeMap(_ map: [String: String], to path: String) throws {
        var data = try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try writeFileAtomic(path, [UInt8](data))
    }
}
