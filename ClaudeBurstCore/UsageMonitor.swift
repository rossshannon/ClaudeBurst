import CoreServices
import Foundation

/// Keeps the current usage window up to date while Claude Code writes its logs.
///
/// An FSEvents stream reports changed files at any depth below the projects directory, so new
/// and appended logs are found without walking the whole tree. Refreshes run one at a time on a
/// background queue; requests that arrive while one runs are merged into a single follow-up.
/// The window is delivered to `handler` on the main queue after every refresh.
public final class UsageMonitor {
    public typealias WindowHandler = (UsageWindow?) -> Void

    /// Seconds between walks of the whole tree when FSEvents is not available
    static let fallbackFullScanInterval: TimeInterval = 5 * 60

    private let scanner: UsageLogScanner
    private let eventLatency: TimeInterval
    private let fullScanInterval: TimeInterval
    private let handler: WindowHandler
    private let refreshQueue = DispatchQueue(label: "ClaudeBurst.UsageMonitor.refresh", qos: .utility)
    private let eventQueue = DispatchQueue(label: "ClaudeBurst.UsageMonitor.events", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var refresher: RefreshCoalescer<RefreshRequest>!

    /// Only used on the refresh queue
    private var lastFullScan: Date?
    private var safetyScanInterval: TimeInterval

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
        self.safetyScanInterval = fullScanInterval
        self.handler = handler
        self.refresher = RefreshCoalescer(queue: refreshQueue, merge: { $0.merged(with: $1) }) { [weak self] request in
            self?.performRefresh(request)
        }
    }

    deinit {
        stop()
    }

    /// The projects directory being watched, with symlinks resolved
    public var rootPath: String { scanner.rootPath }

    /// Follow file events, then scan the whole tree once. The stream starts first, so a file
    /// created while the scan runs is reported even if the scan has already passed its folder.
    public func start() {
        let followingEvents = startEventStream()
        if !followingEvents {
            NSLog("ClaudeBurst: could not start an FSEvents stream for %@; walking it every %.0f s instead",
                  scanner.rootPath, Self.fallbackFullScanInterval)
        }
        let interval = followingEvents ? fullScanInterval : min(fullScanInterval, Self.fallbackFullScanInterval)
        // Queued before the first refresh on the same serial queue, so every refresh sees it
        refreshQueue.async { self.safetyScanInterval = interval }
        refresh(fullScan: true)
    }

    public func stop() {
        guard let stream = eventStream else { return }
        eventStream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Ask for a refresh. Cheap unless `fullScan` is set: tracked files are checked with `stat`,
    /// and only appended bytes are read.
    public func refresh(changedPaths: Set<String> = [], fullScan: Bool = false) {
        refresher.submit(RefreshRequest(changedPaths: changedPaths, fullScan: fullScan))
    }

    /// The scanner's counters, read on the refresh queue
    func statisticsForTesting() -> UsageLogScanner.Statistics {
        refreshQueue.sync { scanner.statistics }
    }

    private func performRefresh(_ request: RefreshRequest) {
        let now = Date()
        let safetyScanDue = lastFullScan.map { now.timeIntervalSince($0) >= safetyScanInterval } ?? true
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

    /// Lets the stream reach the monitor without keeping it alive: the stream retains the box,
    /// and the box holds the monitor weakly
    private final class WeakMonitor {
        weak var monitor: UsageMonitor?

        init(_ monitor: UsageMonitor) {
            self.monitor = monitor
        }
    }

    private func startEventStream() -> Bool {
        guard eventStream == nil else { return true }

        let box = WeakMonitor(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info = info else { return nil }
                return UnsafeRawPointer(Unmanaged<WeakMonitor>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info = info else { return }
                Unmanaged<WeakMonitor>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info = info,
                  let monitor = Unmanaged<WeakMonitor>.fromOpaque(info).takeUnretainedValue().monitor else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: eventCount))
            if let request = UsageMonitor.refreshRequest(forEventPaths: paths, flags: flags) {
                if request.fullScan {
                    NSLog("ClaudeBurst: FSEvents asked for a full rescan of %@", monitor.rootPath)
                }
                monitor.refresher.submit(request)
            }
        }

        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        // FSEventStreamCreate retains the box through the context's retain callback; until then
        // the box must stay alive
        let created = withExtendedLifetime(box) {
            FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [scanner.rootPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                eventLatency,
                createFlags
            )
        }
        guard let stream = created else {
            return false
        }

        FSEventStreamSetDispatchQueue(stream, eventQueue)
        guard FSEventStreamStart(stream) else {
            // Scheduled on a queue, so it can and must be invalidated
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        eventStream = stream
        return true
    }

    /// What one batch of FSEvents asks for, or nil when nothing in it concerns a log
    static func refreshRequest(forEventPaths paths: [String], flags: [FSEventStreamEventFlags]) -> RefreshRequest? {
        let mustRescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        )
        let directoryMoved = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)

        var request = RefreshRequest()
        for (path, flag) in zip(paths, flags) {
            if flag & mustRescan != 0 || flag & directoryMoved == directoryMoved {
                // Events were lost, or a folder of logs moved in or out
                request.fullScan = true
            } else if path.hasSuffix(".jsonl") {
                request.changedPaths.insert(path)
            }
        }
        return request.fullScan || !request.changedPaths.isEmpty ? request : nil
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
/// Safe to call from any thread: `pending` and `isRunning` are only touched under `lock`.
final class RefreshCoalescer<Request>: @unchecked Sendable {
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
