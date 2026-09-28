// Mirrors mcp/src/io.ts. The lock protocol must stay identical to the TypeScript server's:
// both sides take `TODO.md.lock` with an exclusive create, so neither overwrites the other (spec §3.5).
import Foundation

public enum TodoFileError: Error, CustomStringConvertible {
    case lockTimeout(String)
    case io(String, Int32)

    public var description: String {
        switch self {
        case let .lockTimeout(path): "Timed out waiting for lock: \(path)"
        case let .io(what, code): "\(what) failed: \(String(cString: strerror(code)))"
        }
    }
}

let lockStaleSeconds = 5.0
let lockTimeoutSeconds = 3.0

private func acquireLock(_ lockPath: String) throws {
    let start = Date()
    while true {
        let fd = open(lockPath, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd >= 0 {
            close(fd)
            return
        }
        guard errno == EEXIST else { throw TodoFileError.io("open \(lockPath)", errno) }

        var st = stat()
        if stat(lockPath, &st) == 0 {
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            if Date().timeIntervalSince1970 - mtime > lockStaleSeconds {
                unlink(lockPath) // left by a crashed process
                continue
            }
        } else {
            continue // lock vanished between the failed open and this stat; retry
        }

        if Date().timeIntervalSince(start) > lockTimeoutSeconds { throw TodoFileError.lockTimeout(lockPath) }
        usleep(useconds_t(10_000 + Int.random(in: 0..<25_000)))
    }
}

private func releaseLock(_ lockPath: String) {
    unlink(lockPath)
}

/// Write to a temp file in the same folder, fsync, then rename over the target (spec §3.5).
public func writeFileAtomic(_ path: String, _ bytes: [UInt8]) throws {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent().path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let tmp = "\(dir)/.\(url.lastPathComponent).tmp-\(getpid())-\(Int(Date().timeIntervalSince1970 * 1000))-\(UInt32.random(in: .min ... .max))"

    let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { throw TodoFileError.io("open \(tmp)", errno) }
    var ok = false
    defer {
        if !ok { unlink(tmp) }
    }
    var written = 0
    try bytes.withUnsafeBytes { buf in
        while written < buf.count {
            let n = write(fd, buf.baseAddress! + written, buf.count - written)
            guard n > 0 else {
                let code = errno
                close(fd)
                throw TodoFileError.io("write \(tmp)", code)
            }
            written += n
        }
    }
    guard fsync(fd) == 0 else {
        let code = errno
        close(fd)
        throw TodoFileError.io("fsync \(tmp)", code)
    }
    close(fd)
    guard rename(tmp, path) == 0 else { throw TodoFileError.io("rename \(tmp)", errno) }
    ok = true
}

/// The file's bytes, or nil if it doesn't exist yet (treated as an empty file).
private func readRaw(_ path: String) throws -> [UInt8]? {
    do {
        return try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return nil
    }
}

/// Reads the file under the lock, hands a fresh parse to `mutate`, and writes the result back.
/// Skips the write when nothing changed, so a query doesn't touch the file or its mtime.
@discardableResult
public func withTodoFile<T>(at path: String, _ mutate: (Document) throws -> T) throws -> T {
    let lockPath = "\(path).lock"
    try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try acquireLock(lockPath)
    defer { releaseLock(lockPath) }

    let raw = try readRaw(path)
    let doc = parseDocument(raw ?? [])
    assignMissingIds(doc) // spec §3.2: every operation runs this first
    let result = try mutate(doc)
    let bytes = serialize(doc)
    if raw == nil || raw! != bytes {
        try writeFileAtomic(path, bytes)
    }
    return result
}

/// Read-only view; no lock needed since nothing is written.
public func readTodoFile(at path: String) throws -> Document {
    parseDocument(try readRaw(path) ?? [])
}
