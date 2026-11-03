import XCTest
@testable import ClaudeBurstCore

final class UsageLogScannerTests: XCTestCase {

    private var root: URL!

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    override func setUpWithError() throws {
        // Canonical path, as FSEvents reports it (/private/var/..., not /var/...)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageLogScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("project"), withIntermediateDirectories: true)
        root = URL(fileURLWithPath: UsageLogScanner.canonicalPath(temporary.path), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func line(minutesAgo: Double, outputTokens: Int = 1) -> String {
        let timestamp = isoFormatter.string(from: Date().addingTimeInterval(-minutesAgo * 60))
        return "{\"timestamp\": \"\(timestamp)\", \"type\": \"assistant\", \"message\": {\"usage\": {\"input_tokens\": 1, \"output_tokens\": \(outputTokens)}}}\n"
    }

    private func logURL(_ name: String = "session.jsonl") -> URL {
        root.appendingPathComponent("project").appendingPathComponent(name)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func append(_ text: String, to url: URL) throws {
        try append(Data(text.utf8), to: url)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Replace a file's contents without changing its inode
    private func rewriteInPlace(_ text: String, at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func inode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? Int)
    }

    // MARK: - Full scan

    func testFullScanParsesEveryLogInTheWindow() throws {
        try write(line(minutesAgo: 30) + line(minutesAgo: 20), to: logURL("a.jsonl"))
        try write(line(minutesAgo: 10), to: logURL("b.jsonl"))

        let scanner = UsageLogScanner(rootDirectory: root)
        let window = scanner.refresh(fullScan: true)

        XCTAssertNotNil(window)
        XCTAssertEqual(scanner.entries.count, 3)
        XCTAssertEqual(scanner.trackedFileCount, 2)
        XCTAssertEqual(scanner.statistics.fullScans, 1)
    }

    func testRootGivenThroughASymlinkMatchesEventPaths() throws {
        // /var is a symlink to /private/var; FSEvents always reports the /private form
        let aliasPath = root.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        try XCTSkipIf(aliasPath == root.path, "temporary directory is not under /private/var")
        try write(line(minutesAgo: 10), to: logURL())

        let scanner = UsageLogScanner(rootDirectory: URL(fileURLWithPath: aliasPath, isDirectory: true))
        scanner.refresh(fullScan: true)
        try append(line(minutesAgo: 1), to: logURL())
        scanner.refresh(changedPaths: [logURL().path])

        XCTAssertEqual(scanner.rootPath, root.path)
        XCTAssertEqual(scanner.trackedFileCount, 1)
        XCTAssertEqual(scanner.entries.count, 2)
    }

    // MARK: - Incremental reads

    func testUnchangedFilesAreNotOpenedAgain() throws {
        try write(line(minutesAgo: 10), to: logURL())
        let scanner = UsageLogScanner(rootDirectory: root)
        scanner.refresh(fullScan: true)
        let before = scanner.statistics

        scanner.refresh()
        scanner.refresh(changedPaths: [logURL().path])

        XCTAssertEqual(scanner.statistics.filesOpened, before.filesOpened)
        XCTAssertEqual(scanner.statistics.bytesRead, before.bytesRead)
        XCTAssertEqual(scanner.entries.count, 1)
    }

    func testAppendReadsOnlyTheNewBytes() throws {
        let initial = (0..<200).map { line(minutesAgo: Double(200 - $0) / 10) }.joined()
        try write(initial, to: logURL())
        let scanner = UsageLogScanner(rootDirectory: root)
        scanner.refresh(fullScan: true)
        XCTAssertEqual(scanner.statistics.bytesRead, initial.utf8.count)

        let appended = line(minutesAgo: 0)
        try append(appended, to: logURL())
        let before = scanner.statistics
        scanner.refresh()

        // The appended line, plus the short fingerprint read that checks the file was not rewritten
        XCTAssertEqual(scanner.statistics.bytesRead - before.bytesRead,
                       appended.utf8.count + UsageLogScanner.fingerprintLength)
        XCTAssertEqual(scanner.statistics.filesOpened - before.filesOpened, 1)
        XCTAssertEqual(scanner.entries.count, 201)
    }

    func testWindowFollowsNewActivity() throws {
        // A block that started 6 hours ago has ended; a new entry now must start a new one
        try write(line(minutesAgo: 6 * 60), to: logURL())
        let scanner = UsageLogScanner(rootDirectory: root)
        let oldWindow = try XCTUnwrap(scanner.refresh(fullScan: true))
        XCTAssertLessThan(oldWindow.end, Date())
        XCTAssertEqual(scanner.refresh(), oldWindow)

        try append(line(minutesAgo: 0), to: logURL())
        let newWindow = try XCTUnwrap(scanner.refresh())
        XCTAssertGreaterThan(newWindow.end, Date())
    }

    func testPartialLastLineWaitsForItsNewline() throws {
        let complete = line(minutesAgo: 5)
        let next = line(minutesAgo: 1)
        let split = next.index(next.startIndex, offsetBy: 40)
        try write(complete + String(next[..<split]), to: logURL())

        let scanner = UsageLogScanner(rootDirectory: root)
        scanner.refresh(fullScan: true)
        XCTAssertEqual(scanner.entries.count, 1)

        try append(String(next[split...]), to: logURL())
        scanner.refresh()
        XCTAssertEqual(scanner.entries.count, 2)
    }

    func testCompleteLastLineWithoutNewlineIsCountedOnce() throws {
        // parseEntries counts a final line with no newline, so the scanner must too, without
        // counting it a second time once its newline arrives
        try write(String(line(minutesAgo: 5).dropLast()), to: logURL())
        let scanner = UsageLogScanner(rootDirectory: root)
        scanner.refresh(fullScan: true)
        XCTAssertEqual(scanner.entries.count, 1)

        try append("\n" + line(minutesAgo: 1), to: logURL())
        scanner.refresh()
        XCTAssertEqual(scanner.entries.count, 2)
    }

    func testLinesSplitAcrossReadChunksAreParsed() throws {
        let text = (0..<50).map { line(minutesAgo: Double($0)) }.joined()
        try write(text, to: logURL())

        let scanner = UsageLogScanner(rootDirectory: root, readChunkSize: 7)
        scanner.refresh(fullScan: true)

        XCTAssertEqual(scanner.entries.count, 50)
        XCTAssertEqual(scanner.statistics.bytesRead, text.utf8.count)
    }

    func testIncrementalEntriesMatchParsingTheWholeFile() throws {
        var text = ""
        for index in 0..<40 {
            text += line(minutesAgo: Double(40 - index), outputTokens: index)
            if index % 9 == 0 { text += "not json\n" }
            if index % 13 == 0 { text += "\n" }
        }
        let data = Data(text.utf8)
        try write("", to: logURL())

        let scanner = UsageLogScanner(rootDirectory: root, readChunkSize: 13)
        scanner.refresh(fullScan: true)

        // Append in uneven pieces that end mid-line, refreshing after each one
        let pieceSizes = [1, 50, 333, 7, 1_000, 90, 2]
        var offset = 0
        var piece = 0
        while offset < data.count {
            let count = min(pieceSizes[piece % pieceSizes.count], data.count - offset)
            try append(data.subdata(in: offset..<(offset + count)), to: logURL())
            offset += count
            piece += 1
            scanner.refresh()
        }

        let expected = JSONLUsageParser.parseEntries(from: data)
        XCTAssertEqual(expected.count, 40)
        XCTAssertEqual(scanner.entries.map(\.timestamp), expected.map(\.timestamp))
        XCTAssertEqual(scanner.entries.map(\.outputTokens), expected.map(\.outputTokens))
    }

    // MARK: - Truncated, replaced and rewritten files

    func testTruncatedFileIsParsedAgain() throws {
        try write(line(minutesAgo: 5) + line(minutesAgo: 4) + line(minutesAgo: 3), to: logURL())
        let scanner = UsageLogScanner(rootDirectory: root)
        scanner.refresh(fullScan: true)
        XCTAssertEqual(scanner.entries.count, 3)

        try rewriteInPlace(line(minutesAgo: 1, outputTokens: 7), at: logURL())
        scanner.refresh()

        XCTAssertEqual(scanner.entries.map(\.outputTokens), [7])
    }

    func testReplacedFileIsParsedAgain() throws {
        try write(line(minutesAgo: 5), to: logURL())
        let scanner = UsageLogScanner(rootDirectory: root)
        scanner.refresh(fullScan: true)
        let inodeBefore = try inode(of: logURL())

        // An atomic write renames a new file over the old one, so the inode changes
        let replacement = line(minutesAgo: 4, outputTokens: 2) + line(minutesAgo: 3, outputTokens: 2)
        try Data(replacement.utf8).write(to: logURL(), options: .atomic)
        XCTAssertNotEqual(try inode(of: logURL()), inodeBefore)
        scanner.refresh()

        XCTAssertEqual(scanner.entries.map(\.outputTokens), [2, 2])
    }

    func testFileRewrittenInPlaceIsParsedAgain() throws {
        // Same inode, and longer than before by the time the scanner looks again, so neither the
        // inode nor the size shows the change; the fingerprint does
        try write(line(minutesAgo: 5) + line(minutesAgo: 4), to: logURL())
        let scanner = UsageLogScanner(rootDirectory: root)
        scanner.refresh(fullScan: true)
        let inodeBefore = try inode(of: logURL())

        let rewritten = line(minutesAgo: 3, outputTokens: 9) + line(minutesAgo: 2, outputTokens: 9)
            + line(minutesAgo: 1, outputTokens: 9)
        try rewriteInPlace(rewritten, at: logURL())
        XCTAssertEqual(try inode(of: logURL()), inodeBefore)
        scanner.refresh()

        XCTAssertEqual(scanner.entries.map(\.outputTokens), [9, 9, 9])
    }

    // MARK: - The lookback window

    func testFileLeavingTheWindowIsDroppedWithoutOpeningIt() throws {
        try write(line(minutesAgo: 30), to: logURL())
        let scanner = UsageLogScanner(rootDirectory: root)
        XCTAssertNotNil(scanner.refresh(fullScan: true))
        let openedBefore = scanner.statistics.filesOpened

        let later = Date().addingTimeInterval(scanner.lookbackDuration + 60)
        let window = scanner.refresh(now: later)

        XCTAssertNil(window)
        XCTAssertEqual(scanner.trackedFileCount, 0)
        XCTAssertEqual(scanner.statistics.filesOpened, openedBefore)
    }

    func testFileOutsideTheWindowIsNeverOpened() throws {
        try write(line(minutesAgo: 9 * 60), to: logURL())
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9 * 60 * 60)],
                                              ofItemAtPath: logURL().path)

        let scanner = UsageLogScanner(rootDirectory: root)
        scanner.refresh(changedPaths: [logURL().path], fullScan: true)

        XCTAssertEqual(scanner.trackedFileCount, 0)
        XCTAssertEqual(scanner.statistics.filesOpened, 0)
    }

    func testDeletedFileIsDropped() throws {
        try write(line(minutesAgo: 10), to: logURL())
        let scanner = UsageLogScanner(rootDirectory: root)
        scanner.refresh(fullScan: true)
        XCTAssertEqual(scanner.trackedFileCount, 1)

        try FileManager.default.removeItem(at: logURL())
        let window = scanner.refresh()

        XCTAssertNil(window)
        XCTAssertEqual(scanner.trackedFileCount, 0)
        XCTAssertTrue(scanner.entries.isEmpty)
    }

    // MARK: - Finding new files

    func testNewFileIsFoundFromAChangedPathWithoutAFullScan() throws {
        try write(line(minutesAgo: 10), to: logURL("a.jsonl"))
        let scanner = UsageLogScanner(rootDirectory: root)
        scanner.refresh(fullScan: true)

        let subagentLog = root.appendingPathComponent("project/session-2/subagents/agent-1.jsonl")
        try FileManager.default.createDirectory(at: subagentLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(line(minutesAgo: 1), to: subagentLog)

        scanner.refresh()
        XCTAssertEqual(scanner.trackedFileCount, 1, "without a changed path or a full scan, new files are not looked for")

        scanner.refresh(changedPaths: [subagentLog.path])
        XCTAssertEqual(scanner.trackedFileCount, 2)
        XCTAssertEqual(scanner.entries.count, 2)
        XCTAssertEqual(scanner.statistics.fullScans, 1)
    }

    func testChangedPathsThatAreNotLogsUnderTheRootAreIgnored() throws {
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString).jsonl")
        try write(line(minutesAgo: 1), to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try write(line(minutesAgo: 1), to: logURL("notes.txt"))
        try write(line(minutesAgo: 1), to: logURL(".hidden.jsonl"))

        let scanner = UsageLogScanner(rootDirectory: root)
        scanner.refresh(changedPaths: [
            UsageLogScanner.canonicalPath(elsewhere.path),
            logURL("notes.txt").path,
            logURL(".hidden.jsonl").path
        ])

        XCTAssertEqual(scanner.trackedFileCount, 0)
        XCTAssertEqual(scanner.statistics.filesOpened, 0)
    }
}
