import CoreServices
import XCTest
@testable import ClaudeBurstCore

final class RefreshCoalescerTests: XCTestCase {

    func testRequestsDuringARunAreMergedIntoOneFollowUpRun() {
        let queue = DispatchQueue(label: "RefreshCoalescerTests.serial")
        let firstRunStarted = DispatchSemaphore(value: 0)
        let releaseFirstRun = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var runs: [Set<Int>] = []
        let twoRuns = expectation(description: "first run and one merged follow-up")
        twoRuns.expectedFulfillmentCount = 2

        let coalescer = RefreshCoalescer<Set<Int>>(queue: queue, merge: { $0.union($1) }) { request in
            lock.lock()
            runs.append(request)
            let isFirstRun = runs.count == 1
            lock.unlock()

            if isFirstRun {
                firstRunStarted.signal()
                releaseFirstRun.wait()
            }
            twoRuns.fulfill()
        }

        coalescer.submit([0])
        firstRunStarted.wait()
        for request in 1...5 {
            coalescer.submit([request])
        }
        releaseFirstRun.signal()

        wait(for: [twoRuns], timeout: 5)
        queue.sync {}

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(runs, [[0], [1, 2, 3, 4, 5]])
    }

    func testConcurrentSubmissionsRunOneAtATimeAndLoseNothing() {
        // A concurrent queue, so only the coalescer keeps runs from overlapping
        let queue = DispatchQueue(label: "RefreshCoalescerTests.concurrent", attributes: .concurrent)
        let lock = NSLock()
        var activeRuns = 0
        var maxActiveRuns = 0
        var seen = Set<Int>()

        let coalescer = RefreshCoalescer<Set<Int>>(queue: queue, merge: { $0.union($1) }) { request in
            lock.lock()
            activeRuns += 1
            maxActiveRuns = max(maxActiveRuns, activeRuns)
            lock.unlock()

            Thread.sleep(forTimeInterval: 0.001)

            lock.lock()
            activeRuns -= 1
            seen.formUnion(request)
            lock.unlock()
        }

        DispatchQueue.concurrentPerform(iterations: 200) { coalescer.submit([$0]) }

        let allSeen = expectation(for: NSPredicate { _, _ in
            lock.lock()
            defer { lock.unlock() }
            return seen.count == 200
        }, evaluatedWith: nil)
        wait(for: [allSeen], timeout: 5)

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(seen, Set(0..<200))
        XCTAssertEqual(maxActiveRuns, 1)
    }

    func testRefreshRequestsMergeChangedPathsAndFullScan() {
        let first = RefreshRequest(changedPaths: ["/a.jsonl"], fullScan: false)
        let second = RefreshRequest(changedPaths: ["/b.jsonl"], fullScan: true)

        XCTAssertEqual(first.merged(with: second), RefreshRequest(changedPaths: ["/a.jsonl", "/b.jsonl"], fullScan: true))
    }
}

final class UsageMonitorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: UsageLogScanner.canonicalPath(temporary.path), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testNewLogIsFoundThroughFileEventsWithoutAnotherFullScan() throws {
        let initialScan = expectation(description: "initial scan of an empty directory")
        let windowFromEvent = expectation(description: "window after a log appears")
        windowFromEvent.assertForOverFulfill = false
        var deliveries = 0

        let monitor = UsageMonitor(rootDirectory: root, eventLatency: 0.1, fullScanInterval: 3600) { window in
            deliveries += 1
            if deliveries == 1 {
                XCTAssertNil(window)
                initialScan.fulfill()
            } else if window != nil {
                windowFromEvent.fulfill()
            }
        }
        defer { monitor.stop() }
        monitor.start()
        wait(for: [initialScan], timeout: 10)

        // Only an FSEvents report can find this file: the next safety scan is an hour away
        let log = root.appendingPathComponent("project/session.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "{\"timestamp\": \"\(formatter.string(from: Date()))\", \"type\": \"user\"}\n"
        try Data(line.utf8).write(to: log)

        wait(for: [windowFromEvent], timeout: 10)
        XCTAssertEqual(monitor.statisticsForTesting().fullScans, 1, "the event alone must find the file, without walking the tree")
    }

    // MARK: - Event batches

    private func flags(_ values: Int...) -> FSEventStreamEventFlags {
        FSEventStreamEventFlags(values.reduce(0, |))
    }

    func testModifiedLogBecomesAChangedPath() {
        let request = UsageMonitor.refreshRequest(
            forEventPaths: ["/root/project/a.jsonl"],
            flags: [flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified)]
        )
        XCTAssertEqual(request, RefreshRequest(changedPaths: ["/root/project/a.jsonl"], fullScan: false))
    }

    func testRenamedLogFileIsAChangedPathNotAFullScan() {
        let request = UsageMonitor.refreshRequest(
            forEventPaths: ["/root/project/a.jsonl"],
            flags: [flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemRenamed)]
        )
        XCTAssertEqual(request, RefreshRequest(changedPaths: ["/root/project/a.jsonl"], fullScan: false))
    }

    func testEventsForOtherFilesAskForNothing() {
        let request = UsageMonitor.refreshRequest(
            forEventPaths: ["/root/project/tool-output.txt", "/root/project/new-folder"],
            flags: [
                flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified),
                flags(kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)
            ]
        )
        XCTAssertNil(request)
    }

    func testLostEventsAndMovedFoldersAskForAFullScan() {
        let rescanFlags = [
            flags(kFSEventStreamEventFlagMustScanSubDirs),
            flags(kFSEventStreamEventFlagUserDropped),
            flags(kFSEventStreamEventFlagKernelDropped),
            flags(kFSEventStreamEventFlagRootChanged),
            flags(kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemRenamed)
        ]
        for flag in rescanFlags {
            let request = UsageMonitor.refreshRequest(forEventPaths: ["/root/project"], flags: [flag])
            XCTAssertEqual(request?.fullScan, true, "flags \(flag)")
        }
    }
}
