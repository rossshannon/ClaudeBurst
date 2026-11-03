import CoreServices
import Foundation

/// Keeps the current usage window up to date while Claude Code writes its logs.
///
/// An FSEvents stream reports changed files at any depth below the projects directory, so new
/// and appended logs are found without walking the whole tree. Refreshes run one at a time on a
/// background queue; requests that arrive while one runs are merged into a single follow-up.
/// The window is delivered to `handler` on the main queue after every refresh.
///
/// Keep the monitor alive while it is started, and call `stop()` before releasing it.
public final class UsageMonitor {
    public typealias WindowHandler = (UsageWindow?) -> Void

    private let scanner: UsageLogScanner
    private let eventLatency: TimeInterval
    private let fullScanInterval: TimeInterval
    private let handler: WindowHandler
    private let eventQueue = DispatchQueue(label: "ClaudeBurst.UsageMonitor.events", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var refresher: RefreshCoalescer<RefreshRequest>!

    /// Only used on the refresh queue
    private var lastFullScan: Date?

    /// - Parameters:
    ///   - rootDirectory: The Claude Code projects directory
    ///   - eventLatency: Seconds FSEvents waits to collect changes into one batch
    ///   - fullScanInterval: Seconds between safety-net walks of the whole tree, in case an event was missed
    ///   - handler: Receives the window after each refresh, on the main queue
    public init(
        rootDirectory: URL,
        eventLatency: TimeInterval = 5,
        fullScanInterval: TimeInterval = 30 * 60,
        handler: @escaping WindowHandler
    ) {
        self.scanner = UsageLogScanner(rootDirectory: rootDirectory)
        self.eventLatency = eventLatency
        self.fullScanInterval = fullScanInterval
        self.handler = handler

        let refreshQueue = DispatchQueue(label: "ClaudeBurst.UsageMonitor.refresh", qos: .utility)
        self.refresher = RefreshCoalescer(queue: refreshQueue, merge: { $0.merged(with: $1) }) { [weak self] request in
            self?.performRefresh(request)
        }
    }

    deinit {
        stop()
    }

    /// Scan the whole tree once, then follow file events
    public func start() {
        refresh(fullScan: true)
        startEventStream()
    }

    public func stop() {
        guard let stream = eventStream else { return }
        eventStream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Let a callback that was already running finish before the monitor can be released
        eventQueue.sync {}
    }

    /// Ask for a refresh. Cheap unless `fullScan` is set: tracked files are checked with `stat`,
    /// and only appended bytes are read.
    public func refresh(changedPaths: Set<String> = [], fullScan: Bool = false) {
        refresher.submit(RefreshRequest(changedPaths: changedPaths, fullScan: fullScan))
    }

    private func performRefresh(_ request: RefreshRequest) {
        let now = Date()
        let safetyScanDue = lastFullScan.map { now.timeIntervalSince($0) >= fullScanInterval } ?? true
        let fullScan = request.fullScan || safetyScanDue
        if fullScan {
            lastFullScan = now
        }

        let window = scanner.refresh(changedPaths: request.changedPaths, fullScan: fullScan, now: now)
        let handler = self.handler
        DispatchQueue.main.async {
            handler(window)
        }
    }

    // MARK: - FSEvents

    private func startEventStream() {
        guard eventStream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info = info else { return }
            let monitor = Unmanaged<UsageMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: eventCount))
            monitor.handleEvents(paths: paths, flags: flags)
        }

        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [scanner.rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            eventLatency,
            createFlags
        ) else {
            // No events: the periodic safety scan on each refresh still finds new files
            return
        }

        FSEventStreamSetDispatchQueue(stream, eventQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        eventStream = stream
    }

    private func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        let mustRescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        )
        let directoryMoved = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)

        var changedPaths = Set<String>()
        var fullScan = false
        for (path, flag) in zip(paths, flags) {
            if flag & mustRescan != 0 || flag & directoryMoved == directoryMoved {
                // Events were lost, or a folder of logs moved in or out
                fullScan = true
            } else if path.hasSuffix(".jsonl") {
                changedPaths.insert(path)
            }
        }

        if fullScan || !changedPaths.isEmpty {
            refresh(changedPaths: changedPaths, fullScan: fullScan)
        }
    }
}

/// What a refresh should look at beyond the files already tracked
struct RefreshRequest: Equatable {
    var changedPaths: Set<String> = []
    var fullScan = false

    func merged(with other: RefreshRequest) -> RefreshRequest {
        RefreshRequest(changedPaths: changedPaths.union(other.changedPaths), fullScan: fullScan || other.fullScan)
    }
}

/// Runs work on a queue at most one request at a time. Requests submitted while a run is in
/// progress are merged, and the merged request runs once when the current run ends.
final class RefreshCoalescer<Request> {
    private let queue: DispatchQueue
    private let merge: (Request, Request) -> Request
    private let perform: (Request) -> Void

    private let lock = NSLock()
    private var pending: Request?
    private var isRunning = false

    init(queue: DispatchQueue, merge: @escaping (Request, Request) -> Request, perform: @escaping (Request) -> Void) {
        self.queue = queue
        self.merge = merge
        self.perform = perform
    }

    func submit(_ request: Request) {
        lock.lock()
        pending = pending.map { merge($0, request) } ?? request
        let shouldStart = !isRunning
        isRunning = true
        lock.unlock()

        if shouldStart {
            queue.async { self.drain() }
        }
    }

    private func drain() {
        while let request = takePending() {
            perform(request)
        }
    }

    private func takePending() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        guard let request = pending else {
            isRunning = false
            return nil
        }
        pending = nil
        return request
    }
}
