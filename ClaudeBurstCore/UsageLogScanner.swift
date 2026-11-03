import Foundation

/// Keeps the usage entries of every Claude Code log modified within the lookback window.
///
/// Each log is read incrementally: the scanner remembers how far it has parsed each file and,
/// on the next refresh, reads only the bytes appended since then. Files that left the window are
/// dropped from their metadata alone, without being opened. So after the first full scan, a
/// refresh costs one `stat` per tracked file plus the parsing of new bytes.
///
/// Claude Code only appends to its logs. A file that is truncated or replaced (new inode) is
/// parsed again from the start, and so is one rewritten in place whose first or last parsed
/// bytes changed. A rewrite that keeps both is not detected.
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

    /// How many bytes at the start of a file, and just before the parse position, are compared
    /// on each read to detect a file that was rewritten in place
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

        // Rebuilt only when some file's entries changed. Each file's timestamps are mostly in
        // order already, so the sort merges a few long runs rather than sorting from scratch.
        let timestamps = sortedTimestamps ?? trackedFiles.values.flatMap { $0.timestamps + $0.tailTimestamps }.sorted()
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
        /// Modification time when the file was last read
        var modificationDate: Date?
        /// Bytes parsed so far; always 0 or just after a newline
        var parsedOffset: UInt64 = 0
        /// File size when the file was last read
        var readSize: UInt64 = 0
        /// The first bytes of the file, up to `fingerprintLength`, from the parsed region
        var headFingerprint = Data()
        /// The last bytes before `parsedOffset`
        var tailFingerprint = Data()
        /// Entries from complete, newline-terminated lines, and their timestamps
        var entries: [JSONLUsageEntry] = []
        var timestamps: [Date] = []
        /// Entries from a last line with no newline yet; parsed again on every read
        var tailEntries: [JSONLUsageEntry] = []
        var tailTimestamps: [Date] = []

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
        } else if size == file.readSize, modified == file.modificationDate {
            return
        }

        guard read(path: path, into: &file, upTo: size) else { return }
        file.modificationDate = modified
        trackedFiles[path] = file
        sortedTimestamps = nil
    }

    private func stopTracking(_ path: String) {
        if trackedFiles.removeValue(forKey: path) != nil {
            sortedTimestamps = nil
        }
    }

    /// Read the bytes from `parsedOffset` to `size` and parse every complete line among them.
    /// Returns false if the file could not be opened, leaving `file` unchanged.
    private func read(path: String, into file: inout TrackedFile, upTo size: UInt64) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer { try? handle.close() }
        statistics.filesOpened += 1

        do {
            if try !fingerprintsMatch(file, in: handle) {
                // Rewritten in place: the parsed bytes are gone, so start again
                file = TrackedFile(identity: file.identity)
            }

            // Cleared first, so a read that fails partway cannot leave a stale provisional entry
            file.tailEntries = []
            file.tailTimestamps = []

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
                let parsed = JSONLUsageParser.parseEntries(from: complete)
                file.entries.append(contentsOf: parsed)
                file.timestamps.append(contentsOf: parsed.map(\.timestamp))
                file.parsedOffset += UInt64(complete.count)
                Self.extendFingerprints(of: &file, with: complete)
                unparsed = Data(unparsed[lineEnd...])
            }

            // A last line without a newline is either still being written (invalid JSON, so no
            // entry) or complete; either way it is parsed again, not consumed, on the next read
            file.tailEntries = JSONLUsageParser.parseEntries(from: unparsed)
            file.tailTimestamps = file.tailEntries.map(\.timestamp)
            file.readSize = position
        } catch {
            // Unreadable right now: keep what was parsed and try again on the next refresh
        }
        return true
    }

    /// Whether the first bytes of the file, and the bytes just before `parsedOffset`, are still
    /// the ones that were parsed
    private func fingerprintsMatch(_ file: TrackedFile, in handle: FileHandle) throws -> Bool {
        guard file.parsedOffset > 0 else { return true }

        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: file.headFingerprint.count) ?? Data()
        try handle.seek(toOffset: file.parsedOffset - UInt64(file.tailFingerprint.count))
        let tail = try handle.read(upToCount: file.tailFingerprint.count) ?? Data()
        statistics.bytesRead += head.count + tail.count

        return head == file.headFingerprint && tail == file.tailFingerprint
    }

    private static func extendFingerprints(of file: inout TrackedFile, with complete: Data) {
        if file.headFingerprint.count < fingerprintLength {
            file.headFingerprint.append(complete.prefix(fingerprintLength - file.headFingerprint.count))
        }
        if complete.count >= fingerprintLength {
            file.tailFingerprint = Data(complete.suffix(fingerprintLength))
        } else {
            file.tailFingerprint = Data((file.tailFingerprint + complete).suffix(fingerprintLength))
        }
    }

    // MARK: - Paths

    private func isLogPathInsideRoot(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl"), path.hasPrefix(rootPath + "/") else { return false }
        // Match findJSONLFiles, which skips hidden files and folders
        let relativePath = path.dropFirst(rootPath.count + 1)
        return !relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Resolve symlinks the way FSEvents does, so /var/... and /private/var/... name the same file
    public static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
