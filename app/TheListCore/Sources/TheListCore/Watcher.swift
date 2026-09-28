// E4.4: notices outside changes to TODO.md within a second.
//
// Watches the *folder* with FSEvents rather than the file itself: the MCP server replaces
// TODO.md by renaming a temp file over it (so a handle on the old file goes stale), while an
// editor may rewrite it in place. On any event in the folder the file is re-read, and
// `onChange` fires only when its bytes differ from the last read — the lock file, temp files,
// and no-op writes never trigger a reload.
import CoreServices
import Foundation

public final class TodoFileWatcher: @unchecked Sendable {
    private let path: String
    private let latency: TimeInterval
    private let onChange: @Sendable ([UInt8]?) -> Void
    private let queue = DispatchQueue(label: "TheListCore.TodoFileWatcher")
    // Touched only on `queue`.
    private var stream: FSEventStreamRef?
    private var lastBytes: [UInt8]?

    /// `onChange` gets the file's new bytes (nil if it was deleted), on a background queue.
    public init(path: String, latency: TimeInterval = 0.1, onChange: @escaping @Sendable ([UInt8]?) -> Void) {
        self.path = path
        self.latency = latency
        self.onChange = onChange
    }

    /// Starts watching. The folder must exist. Call `stop()` when done: the event stream keeps
    /// this watcher alive until then.
    public func start() {
        queue.sync {
            guard stream == nil else { return }
            lastBytes = readBytes()

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(self).toOpaque(),
                retain: nil,
                release: { info in Unmanaged<TodoFileWatcher>.fromOpaque(info!).release() },
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                Unmanaged<TodoFileWatcher>.fromOpaque(info!).takeUnretainedValue().checkForChange()
            }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard let s = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [folder] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            ) else { return }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
    }

    public func stop() {
        queue.sync {
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s) // releases the context, and with it this watcher
            stream = nil
        }
    }

    private func readBytes() -> [UInt8]? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { [UInt8]($0) }
    }

    private func checkForChange() {
        let bytes = readBytes()
        guard bytes != lastBytes else { return }
        lastBytes = bytes
        onChange(bytes)
    }
}
