// E5: what the popover's buttons do. Each call is one locked read-modify-write of TODO.md.

/// Points at an item the UI is showing. A hand-typed item has no id until the file is next
/// written, so it's found by line and title instead, and only if both still match.
public struct ItemRef: Equatable, Sendable {
    public let id: String?
    public let line: Int
    public let title: String

    public init(_ item: ItemView) {
        id = item.id
        line = item.line
        title = item.title
    }
}

public enum ActionResult: Equatable, Sendable {
    case done
    /// The item isn't where the UI saw it any more (the file changed underneath), so it was left
    /// alone. Missing ids may still have been assigned, as on every write (spec §3.2).
    case listChanged
}

/// The item's id in a fresh document. Ids are assigned before this runs (withTodoFile does it
/// first), and assigning ids never moves lines, so a ref taken before the write still lines up.
private func resolve(_ ref: ItemRef, in doc: Document) -> String? {
    let items = deriveViews(doc).items
    if let id = ref.id { return items.contains { $0.id == id } ? id : nil }
    return items.first { $0.line == ref.line && $0.title == ref.title }?.id
}

private func act(_ todoPath: String, _ ref: ItemRef, _ body: (Document, String) -> Void) throws -> ActionResult {
    try withTodoFile(at: todoPath) { doc in
        guard let id = resolve(ref, in: doc) else { return .listChanged }
        body(doc, id)
        return .done
    }
}

/// E5.1: tick. Moves the item to the top of Done with `done:<today>`.
@discardableResult
public func completeItem(todoPath: String, _ ref: ItemRef, today: String = today()) throws -> ActionResult {
    try act(todoPath, ref) { doc, id in completeTodo(doc, id: id, date: today) }
}

/// E5.1: un-tick. Moves the item back to `priority` (P2 unless the caller knows better).
@discardableResult
public func reopenItem(todoPath: String, _ ref: ItemRef, priority: Priority = .p2) throws -> ActionResult {
    try act(todoPath, ref) { doc, id in reopenTodo(doc, id: id, priority: priority) }
}

/// E5.3: move to another priority heading.
@discardableResult
public func setPriority(todoPath: String, _ ref: ItemRef, _ priority: Priority) throws -> ActionResult {
    try act(todoPath, ref) { doc, id in updateTodo(doc, id: id, UpdateFields(priority: priority)) }
}

/// E5.4: quick-add as P2 with `src:manual`. No duplicate check: a hand-typed add is deliberate.
/// Returns the new id, or nil if the title is blank.
@discardableResult
public func quickAdd(todoPath: String, title: String, today: String = today()) throws -> String? {
    let title = sanitizeText(title)
    guard !title.isEmpty else { return nil }
    return try withTodoFile(at: todoPath) { doc in
        addTodo(doc, AddInput(title: title, priority: .p2, src: "manual", added: today)).fields.id
    }
}
