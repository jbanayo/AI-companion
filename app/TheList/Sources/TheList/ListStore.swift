import Foundation
import Observation
import os
import TheListCore

private let log = Logger(subsystem: "com.jbanayo.thelist", category: "store")

/// Holds what the popover and menu bar icon show, kept in sync with TODO.md (E4.4).
@MainActor
@Observable
final class ListStore {
    let todoPath: String
    private(set) var snapshot: ListSnapshot
    private(set) var today: String

    @ObservationIgnored private var bytes: [UInt8]?
    @ObservationIgnored private var watcher: TodoFileWatcher?
    @ObservationIgnored private var dayTimer: Timer?

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
        apply((try? Data(contentsOf: URL(fileURLWithPath: todoPath))).map { [UInt8]($0) })
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

    private func apply(_ bytes: [UInt8]?) {
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
        apply(bytes)
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
