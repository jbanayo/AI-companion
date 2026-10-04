// E8.1: `data/settings.json` and task groups. Mirrors mcp/src/settings.ts and mcp/src/groups.ts.
import Foundation

public struct TaskGroup: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Project tags that belong to this group when a task has no `group` key.
    public let projects: [String]

    public init(id: String, name: String, projects: [String] = []) {
        self.id = id
        self.name = name
        self.projects = projects
    }
}

public struct Settings: Equatable, Sendable {
    public var proactive: Bool
    public var groups: [TaskGroup]

    public init(proactive: Bool = true, groups: [TaskGroup] = []) {
        self.proactive = proactive
        self.groups = groups
    }
}

/// Keeps well-formed groups and drops the rest, so one bad entry doesn't hide every group.
func parseGroups(_ value: Any?) -> [TaskGroup] {
    guard let list = value as? [Any] else { return [] }
    var seen = Set<String>()
    var groups: [TaskGroup] = []
    for entry in list {
        guard let g = entry as? [String: Any], let id = g["id"] as? String,
              !jsTrim(id).isEmpty, seen.insert(id.lowercased()).inserted else { continue }
        let name = (g["name"] as? String).flatMap { jsTrim($0).isEmpty ? nil : $0 } ?? id
        let projects = (g["projects"] as? [Any])?.compactMap { $0 as? String } ?? []
        groups.append(TaskGroup(id: id, name: name, projects: projects))
    }
    return groups
}

/// A missing or unreadable file gives the defaults (suggestions on, no groups) rather than an error.
public func readSettings(path: String) -> Settings {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Settings() }
    return Settings(proactive: json["proactive"] as? Bool ?? true, groups: parseGroups(json["groups"]))
}

/// `settings.json` next to TODO.md.
public func settingsPath(forTodoPath todoPath: String) -> String {
    URL(fileURLWithPath: todoPath).deletingLastPathComponent().appendingPathComponent("settings.json").path
}

/// The group a task shows under (spec §2.8): its `group` key if that names a defined group,
/// else the first group listing its `project`, else nil. Case-insensitive. Display only.
public func effectiveGroup(_ item: ItemView, groups: [TaskGroup]) -> TaskGroup? {
    if let explicit = item.meta["group"]?.lowercased(), let match = groups.first(where: { $0.id.lowercased() == explicit }) {
        return match
    }
    guard let project = item.meta["project"]?.lowercased() else { return nil }
    return groups.first { $0.projects.contains { $0.lowercased() == project } }
}

public enum SettingsError: Error, CustomStringConvertible {
    case unreadable(String)
    case blankName

    public var description: String {
        switch self {
        case let .unreadable(path): "\(path) isn't valid JSON, so it was left alone"
        case .blankName: "A group needs a name"
        }
    }
}

/// A group id from its name: "Health & Fitness" -> "health-fitness".
public func groupSlug(_ name: String) -> String {
    let lowered = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
    let joined = String(lowered).split(separator: "-").joined(separator: "-")
    return joined.isEmpty ? "group" : joined
}

/// Adds a group named `name` to settings.json and returns it. A group with that name already
/// returns as-is. Every other key in the file is kept. A file that isn't valid JSON is never
/// overwritten, so a hand edit in progress can't be lost.
@discardableResult
public func addGroup(name: String, settingsPath path: String) throws -> TaskGroup {
    let name = jsTrim(sanitizeText(name))
    guard !name.isEmpty else { throw SettingsError.blankName }

    var json: [String: Any] = [:]
    if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsError.unreadable(path)
        }
        json = parsed
    }
    let existing = parseGroups(json["groups"])
    if let same = existing.first(where: { $0.name.lowercased() == name.lowercased() }) { return same }

    let base = groupSlug(name)
    var id = base
    var n = 2
    while existing.contains(where: { $0.id.lowercased() == id }) {
        id = "\(base)-\(n)"
        n += 1
    }

    var list = json["groups"] as? [Any] ?? []
    list.append(["id": id, "name": name, "projects": [String]()] as [String: Any])
    json["groups"] = list
    if json["proactive"] == nil { json["proactive"] = true }

    var data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    try writeFileAtomic(path, [UInt8](data))
    return TaskGroup(id: id, name: name)
}
