// What the popover shows: groups, badge, due labels, and where a click goes (E4.3, E4.4, E5.2).
// The priority rules mirror mcp/src/priority.ts so the app and `list_todos` agree.
import Foundation

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// Midnight UTC for a real `YYYY-MM-DD` date, or nil. Day arithmetic between two such dates
/// doesn't depend on the user's timezone; only `today()` does, and callers pass that in.
func dayDate(_ s: String) -> Date? {
    let parts = s.split(separator: "-", omittingEmptySubsequences: false)
    guard s.unicodeScalars.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          parts.allSatisfy({ $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }),
          let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), y >= 1,
          let date = utc.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
    let back = utc.dateComponents([.year, .month, .day], from: date)
    return back.year == y && back.month == m && back.day == d ? date : nil
}

/// Whole days from `a` to `b` (negative if `b` is earlier), or nil if either isn't a real date.
func daysBetween(_ a: String, _ b: String) -> Int? {
    guard let da = dayDate(a), let db = dayDate(b) else { return nil }
    return utc.dateComponents([.day], from: da, to: db).day
}

/// A well-formed, real date. Malformed dates are ignored by sorting and overdue checks (spec §2.6).
public func isValidDate(_ s: String) -> Bool { dayDate(s) != nil }

private let order: [Section: Int] = [.p0: 0, .p1: 1, .p2: 2, .p3: 3, .done: 4]

/// PRD §6.3: an open item due today or earlier shows as P0, without the file being rewritten.
public func displayPriority(_ item: ItemView, today: String) -> Section {
    if !item.done, let due = item.meta["due"], isValidDate(due), due <= today { return .p0 }
    return item.priority
}

public func isOverdue(_ item: ItemView, today: String) -> Bool {
    guard !item.done, let due = item.meta["due"], isValidDate(due) else { return false }
    return due < today
}

/// Display priority, then due date (soonest first, undated last), then title.
public func sortByDisplayPriority(_ items: [ItemView], today: String) -> [ItemView] {
    func dueKey(_ i: ItemView) -> String {
        if let due = i.meta["due"], isValidDate(due) { return due }
        return "9999-99-99"
    }
    return items.sorted { a, b in
        let pa = order[displayPriority(a, today: today)]!, pb = order[displayPriority(b, today: today)]!
        if pa != pb { return pa < pb }
        let da = dueKey(a), db = dueKey(b)
        if da != db { return da < db }
        return a.title.localizedCompare(b.title) == .orderedAscending
    }
}

public struct ListGroup: Equatable, Sendable, Identifiable {
    public let priority: Priority
    public let items: [ItemView]
    public var id: Priority { priority }
    public var count: Int { items.count }

    public var title: String {
        switch priority {
        case .p0: "Now"
        case .p1: "This week"
        case .p2: "Soon"
        case .p3: "Someday"
        }
    }
}

public struct Badge: Equatable, Sendable {
    /// Open items showing as P0 or P1.
    public let count: Int
    /// True when anything open is overdue: the menu bar count turns red.
    public let alert: Bool

    public init(count: Int, alert: Bool) {
        self.count = count
        self.alert = alert
    }
}

public struct ListSnapshot: Equatable, Sendable {
    /// Always the four groups, in order, even when empty.
    public let groups: [ListGroup]
    /// Ticked items, in file order (newest first, since completing puts an item at the top of Done).
    public let done: [ItemView]
    public let badge: Badge
    public var isEmpty: Bool { groups.allSatisfy { $0.items.isEmpty } }
}

public func makeSnapshot(_ doc: Document, today: String) -> ListSnapshot {
    let items = deriveViews(doc).items
    let open = items.filter { !$0.done }

    func group(of item: ItemView) -> Priority {
        switch displayPriority(item, today: today) {
        case .p0: .p0
        case .p1: .p1
        case .p3: .p3
        // An open item still sitting under "## Done" was un-ticked by hand. Show it with the
        // default priority rather than hiding it among finished work.
        case .p2, .done: .p2
        }
    }

    let sorted = sortByDisplayPriority(open, today: today)
    let groups = Priority.allCases.map { p in ListGroup(priority: p, items: sorted.filter { group(of: $0) == p }) }
    let urgent = groups[0].count + groups[1].count
    return ListSnapshot(
        groups: groups,
        done: items.filter(\.done),
        badge: Badge(count: urgent, alert: open.contains { isOverdue($0, today: today) })
    )
}

/// "Today", "Tomorrow", a weekday within the next week ("Wed"), "Oct 5" beyond that,
/// "Overdue 2d" in the past. A date that isn't real comes back as typed, so it's never hidden.
public func relativeDueLabel(_ due: String?, today: String, locale: Locale = .current) -> String? {
    guard let due else { return nil }
    guard let dueDay = dayDate(due), let todayDay = dayDate(today) else { return due }
    let days = utc.dateComponents([.day], from: todayDay, to: dueDay).day!

    switch days {
    case ..<0: return "Overdue \(-days)d"
    case 0: return "Today"
    case 1: return "Tomorrow"
    default:
        let f = DateFormatter()
        f.calendar = utc
        f.timeZone = utc.timeZone
        f.locale = locale
        let sameYear = utc.component(.year, from: dueDay) == utc.component(.year, from: todayDay)
        f.setLocalizedDateFormatFromTemplate(days <= 6 ? "EEE" : sameYear ? "MMMd" : "MMMdyyyy")
        return f.string(from: dueDay)
    }
}

/// Where a task's link points (PRD §6.5), so the details view can offer the right buttons.
public enum LinkTarget: Equatable, Sendable {
    /// `http://` or `https://`: opens in the browser.
    case web(URL)
    /// `vscode://file/<path>[:line[:col]]`: opens VS Code; `path` is the file on disk.
    case vscodeFile(URL, path: String)
    /// An absolute or `~/` path: opens with its default app.
    case file(URL)
    /// Any other scheme (`thelist://`, `slack://`, …): handed to macOS as-is.
    case other(URL)
    /// No usable link: TODO.md in VS Code at the item's line.
    case todoLine(URL)

    /// What opening it means.
    public var url: URL {
        switch self {
        case let .web(u), let .vscodeFile(u, _), let .file(u), let .other(u), let .todoLine(u): u
        }
    }

    /// A file on disk that "Show in Finder" can reveal, if the link is to one.
    public var filePath: String? {
        switch self {
        case let .vscodeFile(_, path): path
        case let .file(u): u.path
        case .web, .other, .todoLine: nil
        }
    }
}

public func linkTarget(for item: ItemView, todoPath: String) -> LinkTarget {
    if let link = item.meta["link"].map(jsTrim), !link.isEmpty {
        if link.hasPrefix("/") { return .file(URL(fileURLWithPath: link)) }
        if link.hasPrefix("~/") { return .file(URL(fileURLWithPath: (link as NSString).expandingTildeInPath)) }
        if link.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil,
           let url = URL(string: link) ?? URL(string: link.replacingOccurrences(of: " ", with: "%20")) {
            switch url.scheme?.lowercased() {
            case "http", "https":
                return .web(url)
            case "vscode" where url.host == "file" && !url.path.isEmpty:
                // url.path is percent-decoded; drop VS Code's trailing :line or :line:col.
                let path = url.path.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression)
                return .vscodeFile(url, path: path)
            default:
                return .other(url)
            }
        }
    }
    return .todoLine(todoLineURL(for: item, todoPath: todoPath))
}

/// TODO.md in VS Code at the item's line, whatever its link.
public func todoLineURL(for item: ItemView, todoPath: String) -> URL {
    let encoded = todoPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? todoPath
    return URL(string: "vscode://file\(encoded):\(item.line)")!
}

/// What opening a task goes to: its link, or TODO.md in VS Code at its line.
public func clickTarget(for item: ItemView, todoPath: String) -> URL {
    linkTarget(for: item, todoPath: todoPath).url
}

/// "Sat, Sep 26", with the year added when it isn't `today`'s year. A date that isn't real comes back as typed.
public func formattedDay(_ date: String, today: String, locale: Locale = .current) -> String {
    guard let day = dayDate(date), let todayDay = dayDate(today) else { return date }
    let f = DateFormatter()
    f.calendar = utc
    f.timeZone = utc.timeZone
    f.locale = locale
    let sameYear = utc.component(.year, from: day) == utc.component(.year, from: todayDay)
    f.setLocalizedDateFormatFromTemplate(sameYear ? "EEEMMMd" : "EEEMMMdyyyy")
    return f.string(from: day)
}
