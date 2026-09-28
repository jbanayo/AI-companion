import AppKit
import Foundation
import Observation
import os
import TheListCore

private let log = Logger(subsystem: "com.jbanayo.thelist", category: "store")

/// Holds what the popover and menu bar icon show, kept in sync with TODO.md (E4.4),
/// and runs the popover's actions (E5).
@MainActor
@Observable
final class ListStore {
    let todoPath: String
    private(set) var snapshot: ListSnapshot
    private(set) var today: String
    /// A short note shown in the footer, e.g. when a write fails. Clears itself.
    private(set) var message: String?

    @ObservationIgnored private var bytes: [UInt8]?
    @ObservationIgnored private var watcher: TodoFileWatcher?
    @ObservationIgnored private var dayTimer: Timer?
    /// Where items ticked in this session came from, so unticking puts them back there.
    @ObservationIgnored private var tickedFrom: [String: Priority] = [:]

    init(todoPath: String) {
        self.todoPath = todoPath
        let today = TheListCore.today()
        self.today = today
        self.snapshot = makeSnapshot(parseDocument([]), today: today)
    }

    func start() {
        guard watcher == nil else { return }
        let folder = URL(fileURLWithPath: todoPath).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        archive()
        reload()
        let watcher = TodoFileWatcher(path: todoPath) { [weak self] bytes in
            Task { @MainActor in self?.apply(bytes) }
        }
        watcher.start()
        self.watcher = watcher

        // "Due today" becomes "overdue" at midnight without the file changing.
        dayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDay() }
        }
    }

    // MARK: - Actions (E5)

    /// E5.1: tick an open item, or untick a done one.
    func toggle(_ item: ItemView) {
        let ref = ItemRef(item)
        let path = todoPath, today = today
        if item.done {
            // Back where it was ticked from in this session, else the heading it sits under, else P2.
            let priority = item.id.flatMap { tickedFrom[$0] } ?? Priority(rawValue: item.priority.rawValue) ?? .p2
            write { try reopenItem(todoPath: path, ref, priority: priority) }
        } else {
            if let id = item.id, let from = Priority(rawValue: item.priority.rawValue) { tickedFrom[id] = from }
            write { try completeItem(todoPath: path, ref, today: today) }
        }
    }

    /// E5.3
    func move(_ item: ItemView, to priority: Priority) {
        let ref = ItemRef(item), path = todoPath
        write { try setPriority(todoPath: path, ref, priority) }
    }

    /// E5.4. Calls `done(true)` once the item is in the file.
    func add(_ title: String, done: @escaping @MainActor (Bool) -> Void) {
        let path = todoPath, today = today
        Task.detached {
            do {
                let id = try quickAdd(todoPath: path, title: title, today: today)
                await MainActor.run {
                    self.reload()
                    done(id != nil)
                }
            } catch {
                await MainActor.run {
                    self.show("Couldn't add: \(error)")
                    done(false)
                }
            }
        }
    }

    /// E5.2: open the item's link, or TODO.md at its line.
    func open(_ item: ItemView) {
        let url = clickTarget(for: item, todoPath: todoPath)
        if !NSWorkspace.shared.open(url) { show("Couldn't open \(url.absoluteString)") }
    }

    /// Runs a write off the main thread (the lock can wait up to 3 s), then refreshes right away
    /// rather than waiting for the watcher.
    private func write(_ action: @escaping @Sendable () throws -> ActionResult) {
        Task.detached {
            let outcome: Result<ActionResult, Error> = Result { try action() }
            await MainActor.run {
                self.reload()
                switch outcome {
                case .success(.done): break
                case .success(.listChanged): self.show("The list changed underneath. Try again.")
                case let .failure(error): self.show("Couldn't save: \(error)")
                }
            }
        }
    }

    private func show(_ text: String) {
        log.error("\(text, privacy: .public)")
        message = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.message == text { self?.message = nil }
        }
    }

    // MARK: - Loading

    private func reload() {
        apply((try? Data(contentsOf: URL(fileURLWithPath: todoPath))).map { [UInt8]($0) })
    }

    private func apply(_ bytes: [UInt8]?) {
        guard bytes != self.bytes || self.bytes == nil else { return }
        self.bytes = bytes
        snapshot = makeSnapshot(parseDocument(bytes ?? []), today: today)
        let open = snapshot.groups.reduce(0) { $0 + $1.count }
        log.info("reloaded: \(open) open, badge \(self.snapshot.badge.count), alert \(self.snapshot.badge.alert)")
    }

    private func checkDay() {
        let now = TheListCore.today()
        guard now != today else { return }
        today = now
        archive() // once a day; the watcher picks up the rewrite
        snapshot = makeSnapshot(parseDocument(bytes ?? []), today: today)
    }

    /// E7.2: move Done items older than 14 days into data/archive/ (spec §3.6).
    private func archive() {
        let archiveDir = URL(fileURLWithPath: todoPath).deletingLastPathComponent().appendingPathComponent("archive").path
        do {
            let result = try archiveOldDone(todoPath: todoPath, archiveDir: archiveDir, today: today)
            if !result.movedIds.isEmpty { log.info("archived \(result.movedIds.count) done items") }
        } catch {
            log.error("archive failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Info.plist's TheListTodoPath (set by build-app.sh), overridable with THE_LIST_TODO_PATH.
    /// Running unbundled (`swift run`) falls back to the repo's data folder.
    static func defaultTodoPath() -> String {
        if let path = ProcessInfo.processInfo.environment["THE_LIST_TODO_PATH"] { return path }
        if let path = Bundle.main.object(forInfoDictionaryKey: "TheListTodoPath") as? String, !path.hasPrefix("__") {
            return path
        }
        return URL(fileURLWithPath: #filePath) // app/TheList/Sources/TheList/ListStore.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/TODO.md").path
    }
}
