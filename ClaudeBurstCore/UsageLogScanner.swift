import Foundation

/// Keeps the usage entries of every Claude Code log modified within the lookback window.
///
/// Each log is read incrementally: the scanner remembers how far it has parsed each file and,
/// on the next refresh, reads only the bytes appended since then. Files that left the window are
/// dropped from their metadata alone, without being opened. So after the first full scan, a
/// refresh costs one `stat` per tracked file plus the parsing of new bytes.
///
/// Not thread-safe: use each instance from one serial queue.
public final class UsageLogScanner {
    /// How much work the scanner has done, for tests and diagnostics
    public struct Statistics: Equatable {
        public var fullScans = 0
        public var filesOpened = 0
        public var bytesRead = 0
    }

    /// The projects directory, with symlinks resolved so paths match the ones FSEvents reports
    public let rootPath: String
    public let lookbackDuration: TimeInterval
    public private(set) var statistics = Statistics()

    private let readChunkSize: Int
    private var trackedFiles: [String: TrackedFile] = [:]
    /// Timestamps of all entries in ascending order; nil after any file's entries change
    private var sortedTimestamps: [Date]?

    /// How many bytes before the parse position are compared on each read, to detect a file
    /// that was rewritten in place to at least its previous length
    static let fingerprintLength = 64

    public init(
        rootDirectory: URL,
        lookbackDuration: TimeInterval = JSONLUsageParser.lookbackDuration,
        readChunkSize: Int = 1 << 20
    ) {
        self.rootPath = Self.canonicalPath(rootDirectory.path)
        self.lookbackDuration = lookbackDuration
        self.readChunkSize = max(1, readChunkSize)
    }

    /// Number of log files currently inside the lookback window
    public var trackedFileCount: Int { trackedFiles.count }

    /// Entries from every tracked file, in no particular order
    public var entries: [JSONLUsageEntry] {
        var all: [JSONLUsageEntry] = []
        for file in trackedFiles.values {
            all.append(contentsOf: file.entries)
            all.append(contentsOf: file.tailEntries)
        }
        return all
    }

    /// Bring the tracked files up to date and return the current usage window.
    /// - Parameters:
    ///   - changedPaths: Paths reported as changed, such as FSEvents paths; finds new files without a full scan
    ///   - fullScan: Walk the whole directory tree to find files; costs time in proportion to the number of files
    ///   - now: The current time, which sets the lookback window
    @discardableResult
    public func refresh(changedPaths: Set<String> = [], fullScan: Bool = false, now: Date = Date()) -> UsageWindow? {
        let cutoff = now.addingTimeInterval(-lookbackDuration)
        var candidates = Set(trackedFiles.keys)

        if fullScan {
            statistics.fullScans += 1
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            for url in JSONLUsageParser.findJSONLFiles(in: rootURL, since: cutoff) {
                candidates.insert(url.path)
            }
        }

        candidates.formUnion(changedPaths.filter(isLogPathInsideRoot))

        for path in candidates {
            update(path: path, cutoff: cutoff)
        }

        // Sorting every entry is the costliest step left once nothing new was read, so do it
        // only when some file's entries changed
        let timestamps = sortedTimestamps ?? entries.map(\.timestamp).sorted()
        sortedTimestamps = timestamps
        return JSONLUsageParser.calculateCurrentWindow(sortedTimestamps: timestamps, now: now)
    }

    // MARK: - Per-file state

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct TrackedFile {
        let identity: FileIdentity
        /// Bytes parsed so far; always 0 or just after a newline
        var parsedOffset: UInt64 = 0
        /// File size when the file was last read
        var readSize: UInt64 = 0
        /// The last bytes before `parsedOffset`
        var fingerprint = Data()
        /// Entries from complete, newline-terminated lines
        var entries: [JSONLUsageEntry] = []
        /// Entries from a last line with no newline yet; parsed again on every read
        var tailEntries: [JSONLUsageEntry] = []

        init(identity: FileIdentity) {
            self.identity = identity
        }
    }

    private func update(path: String, cutoff: Date) {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            stopTracking(path)
            return
        }

        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        guard modified >= cutoff else {
            // Left the window (or never entered it): drop without opening
            stopTracking(path)
            return
        }

        let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
        let size = UInt64(info.st_size)
        var file = trackedFiles[path] ?? TrackedFile(identity: identity)

        if file.identity != identity || size < file.parsedOffset {
            // Replaced by another file, or truncated: start again from the beginning
            file = TrackedFile(identity: identity)
        } else if size == file.readSize, trackedFiles[path] != nil {
            return
        }

        read(path: path, into: &file, upTo: size)
        trackedFiles[path] = file
        sortedTimestamps = nil
    }

    private func stopTracking(_ path: String) {
        if trackedFiles.removeValue(forKey: path) != nil {
            sortedTimestamps = nil
        }
    }

    /// Read the bytes from `parsedOffset` to `size` and parse every complete line among them
    private func read(path: String, into file: inout TrackedFile, upTo size: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return
        }
        defer { try? handle.close() }
        statistics.filesOpened += 1

        do {
            if !file.fingerprint.isEmpty {
                try handle.seek(toOffset: file.parsedOffset - UInt64(file.fingerprint.count))
                let current = try handle.read(upToCount: file.fingerprint.count) ?? Data()
                statistics.bytesRead += current.count
                if current != file.fingerprint {
                    // Rewritten in place: the parsed bytes are gone, so start again
                    file = TrackedFile(identity: file.identity)
                }
            }

            try handle.seek(toOffset: file.parsedOffset)
            var position = file.parsedOffset
            var unparsed = Data()

            while position < size {
                let count = Int(min(UInt64(readChunkSize), size - position))
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                position += UInt64(chunk.count)
                statistics.bytesRead += chunk.count
                unparsed.append(chunk)

                // Only the new chunk can hold a newline, so a long line is not searched again per chunk
                guard chunk.contains(JSONLUsageParser.newline),
                      let lastNewline = unparsed.lastIndex(of: JSONLUsageParser.newline) else { continue }
                let lineEnd = unparsed.index(after: lastNewline)
                let complete = unparsed[..<lineEnd]
                file.entries.append(contentsOf: JSONLUsageParser.parseEntries(from: complete))
                file.parsedOffset += UInt64(complete.count)
                file.fingerprint = Self.fingerprint(previous: file.fingerprint, appending: complete)
                unparsed = Data(unparsed[lineEnd...])
            }

            // A last line without a newline is either still being written (invalid JSON, so no
            // entry) or complete; either way it is parsed again, not consumed, on the next read
            file.tailEntries = JSONLUsageParser.parseEntries(from: unparsed)
            file.readSize = position
        } catch {
            // Unreadable right now: keep what was parsed and try again on the next refresh
        }
    }

    private static func fingerprint(previous: Data, appending complete: Data) -> Data {
        if complete.count >= fingerprintLength {
            return Data(complete.suffix(fingerprintLength))
        }
        return Data((previous + complete).suffix(fingerprintLength))
    }

    // MARK: - Paths

    private func isLogPathInsideRoot(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl"), path.hasPrefix(rootPath + "/") else { return false }
        // Match findJSONLFiles, which skips hidden files and folders
        let relativePath = path.dropFirst(rootPath.count + 1)
        return !relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Resolve symlinks the way FSEvents does, so /var/... and /private/var/... name the same file
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
