import Cocoa
import AVFoundation
import UserNotifications
import ClaudeBurstCore

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {

    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var soundDropdown: NSPopUpButton?
    var audioPlayer: AVAudioPlayer?
    var sessionTimer: Timer?
    var soundDirectoryMonitor: DispatchSourceFileSystemObject?
    var soundDirectoryFileDescriptor: CInt?
    var currentSessionWindow: UsageWindow?
    var lastNotifiedPeriodEnd: Date?
    var usageDirectoryMonitor: DispatchSourceFileSystemObject?
    var usageDirectoryFileDescriptor: CInt?
    var usagePollTimer: Timer?
    var usageDirectoryPath: String?
    var resolvedProjectsDirectoryURL: URL?
    var hasCompletedInitialLoad = false

    // Bon mots for notifications
    var bonMots: [String] = []
    var lastBonMotIndex: Int?

    // User defaults keys
    let selectedSoundKey = "selectedSound"
    let hideFromDockKey = "hideFromDock"
    let supportedSoundExtensions = ["mp3", "wav", "m4a", "mp4"]
    let appSupportFolderName = "ClaudeBurst"

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Set default for hideFromDock to true (menubar-only by default)
        UserDefaults.standard.register(defaults: [hideFromDockKey: true])

        // Load bon mots for notifications
        loadBonMots()

        // Request notification permissions
        requestNotificationPermission()

        // Setup menubar immediately (shows "Loading…" state)
        setupMenuBar()

        // Start session timer
        startSessionTimer()

        // Apply dock visibility setting
        applyDockVisibility()

        // Ensure external sounds folder exists for user-managed sounds
        prepareSoundDirectory()

        // Load session data async and start watchers
        startUsageMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopSoundDirectoryMonitor()
        stopUsageMonitoring()
    }

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let image = loadMenuBarIcon() {
                button.image = image
            } else if let image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "ClaudeBurst") {
                image.isTemplate = true
                button.image = image
            } else {
                // Fallback if SF Symbol not available
                button.title = "🔔"
            }
        }

        let menu = NSMenu()
        menu.delegate = self

        // Current session info (will be updated dynamically)
        let currentSessionItem = NSMenuItem(title: getCurrentSessionInfo(), action: nil, keyEquivalent: "")
        currentSessionItem.tag = 100
        currentSessionItem.isEnabled = false
        menu.addItem(currentSessionItem)

        // Next session info
        let nextSessionItem = NSMenuItem(title: getNextSessionInfo(), action: nil, keyEquivalent: "")
        nextSessionItem.tag = 101
        nextSessionItem.isEnabled = false
        menu.addItem(nextSessionItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Test Notification", action: #selector(testNotification), keyEquivalent: "t"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func getCurrentSessionInfo() -> String {
        if !hasCompletedInitialLoad {
            return "Current: Loading…"
        }
        guard let window = currentSessionWindow else {
            if resolveProjectsDirectoryURL() == nil {
                return "Current: Claude data not found"
            }
            return "Current: No recent activity"
        }
        return SessionFormatter.currentSessionDescription(window: window)
    }

    func getNextSessionInfo() -> String {
        if !hasCompletedInitialLoad {
            return "Next: Loading…"
        }
        guard currentSessionWindow != nil else {
            if resolveProjectsDirectoryURL() == nil {
                return "Next: Start Claude Code"
            }
            return "Next: Start a session"
        }

        return SessionFormatter.nextSessionDescription(window: currentSessionWindow)
    }

    func loadMenuBarIcon() -> NSImage? {
        guard let image = NSImage(named: "MenuBarIcon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    // NSMenuDelegate - update session info when menu opens
    func menuWillOpen(_ menu: NSMenu) {
        if let currentItem = menu.item(withTag: 100) {
            currentItem.title = getCurrentSessionInfo()
        }
        if let nextItem = menu.item(withTag: 101) {
            nextItem.title = getNextSessionInfo()
        }
    }

    func startUsageMonitoring() {
        readUsageAndUpdate(triggerIfRolledOver: false)
        startUsageDirectoryMonitor()
        startUsagePolling()
    }

    func stopUsageMonitoring() {
        stopUsageDirectoryMonitor()
        stopUsagePolling()
    }

    func startSessionTimer() {
        // Check every 20 seconds for timely session boundary notifications
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.checkSessionRollover()
        }
        sessionTimer?.tolerance = 10  // Max 30s delay from boundary
    }

    func checkSessionRollover() {
        guard let window = currentSessionWindow else {
            readUsageAndUpdate(triggerIfRolledOver: false)
            return
        }

        let now = Date()
        if now >= window.end {
            // Notify at session boundary if we haven't already
            if lastNotifiedPeriodEnd != window.end {
                lastNotifiedPeriodEnd = window.end
                let estimatedWindow = SessionFormatter.estimatedNextWindow(from: now)
                triggerSessionNotification(subtitle: estimatedWindow)
            }
            // Also check for new activity
            readUsageAndUpdate(triggerIfRolledOver: false)
        }
    }

    func readUsageAndUpdate(triggerIfRolledOver: Bool) {
        Task {
            await readUsageAndUpdateAsync(triggerIfRolledOver: triggerIfRolledOver)
        }
    }

    @MainActor
    private func readUsageAndUpdateAsync(triggerIfRolledOver: Bool) async {
        let window = await JSONLUsageParser.loadCurrentWindowAsync()

        let previousEnd = currentSessionWindow?.end
        currentSessionWindow = window
        hasCompletedInitialLoad = true

        guard let window = window, let previousEnd = previousEnd else { return }

        if window.end > previousEnd {
            let shouldNotify = triggerIfRolledOver || Date() >= previousEnd
            if shouldNotify && lastNotifiedPeriodEnd != previousEnd {
                lastNotifiedPeriodEnd = previousEnd
                triggerSessionNotification(subtitle: SessionFormatter.formatSessionRange(start: window.start, end: window.end))
            }
        }

        refreshUsageDirectoryMonitor()
    }

    func resolveProjectsDirectoryURL() -> URL? {
        if let cachedURL = resolvedProjectsDirectoryURL,
           FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        if let projectsDir = JSONLUsageParser.projectsDirectoryURL() {
            resolvedProjectsDirectoryURL = projectsDir
            return projectsDir
        }

        resolvedProjectsDirectoryURL = nil
        return nil
    }

    func startUsageDirectoryMonitor() {
        guard usageDirectoryMonitor == nil else { return }

        guard let directoryURL = resolveProjectsDirectoryURL() else { return }
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor != -1 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.readUsageAndUpdate(triggerIfRolledOver: true)
        }

        source.setCancelHandler {
            close(descriptor)
        }

        usageDirectoryFileDescriptor = descriptor
        usageDirectoryPath = directoryURL.path
        usageDirectoryMonitor = source
        source.resume()
    }

    func refreshUsageDirectoryMonitor() {
        guard let directoryURL = resolveProjectsDirectoryURL() else {
            stopUsageDirectoryMonitor()
            return
        }

        if usageDirectoryMonitor == nil {
            startUsageDirectoryMonitor()
            return
        }

        if usageDirectoryPath != directoryURL.path {
            restartUsageDirectoryMonitor()
        }
    }

    func restartUsageDirectoryMonitor() {
        stopUsageDirectoryMonitor()
        startUsageDirectoryMonitor()
    }

    func stopUsageDirectoryMonitor() {
        usageDirectoryMonitor?.cancel()
        usageDirectoryMonitor = nil
        usageDirectoryFileDescriptor = nil
        usageDirectoryPath = nil
    }

    func startUsagePolling() {
        usagePollTimer?.invalidate()
        usagePollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.readUsageAndUpdate(triggerIfRolledOver: false)
        }
        usagePollTimer?.tolerance = 10
    }

    func stopUsagePolling() {
        usagePollTimer?.invalidate()
        usagePollTimer = nil
    }

    func triggerSessionNotification(subtitle: String) {
        // Play sound
        playSelectedSound()

        // Send notification
        sendNotification(subtitle: subtitle)
    }

    func getAvailableSounds() -> [String] {
        return soundCatalog().keys.sorted()
    }

    func playSelectedSound() {
        let catalog = soundCatalog()
        guard !catalog.isEmpty else { return }

        let selectedSound = UserDefaults.standard.string(forKey: selectedSoundKey) ?? ""
        let availableNames = catalog.keys.sorted()
        let resolvedName = catalog.keys.contains(selectedSound) ? selectedSound : availableNames.first ?? ""

        guard !resolvedName.isEmpty else { return }

        if resolvedName != selectedSound {
            UserDefaults.standard.set(resolvedName, forKey: selectedSoundKey)
        }

        guard let url = catalog[resolvedName] else {
            print("Sound file not found: \(selectedSound)")
            return
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
        } catch {
            print("Error playing sound: \(error)")
        }
    }

    func sendNotification(subtitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "A new Claude Code session has begun!"
        content.subtitle = subtitle
        if let bonMot = getRandomBonMot() {
            content.body = bonMot
        }
        content.sound = nil // We play our own sound

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Notification error: \(error)")
            }
        }
    }

    func loadBonMots() {
        guard let url = Bundle.main.url(forResource: "bonmots", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }

        bonMots = contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func getRandomBonMot() -> String? {
        guard !bonMots.isEmpty else { return nil }

        var index = Int.random(in: 0..<bonMots.count)

        // Avoid repeating the same bon mot if we have more than one
        if bonMots.count > 1, let lastIndex = lastBonMotIndex, index == lastIndex {
            index = (index + 1) % bonMots.count
        }

        lastBonMotIndex = index
        return bonMots[index]
    }

    @objc func testNotification() {
        if let window = currentSessionWindow {
            triggerSessionNotification(subtitle: SessionFormatter.formatSessionRange(start: window.start, end: window.end))
        } else {
            triggerSessionNotification(subtitle: "Session")
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            createSettingsWindow()
        }
        refreshSoundDropdown()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func createSettingsWindow() {
        let windowWidth: CGFloat = 420
        let windowHeight: CGFloat = 240
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClaudeBurst Settings"
        window.center()
        window.isReleasedWhenClosed = false

        // Create vibrancy effect view as the base
        let visualEffectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active

        // Layout constants
        let padding: CGFloat = 16
        let sectionSpacing: CGFloat = 12
        let itemSpacing: CGFloat = 8
        let buttonGap: CGFloat = 8
        let sectionPadding: CGFloat = 12
        let headerHeight: CGFloat = 20
        let controlHeight: CGFloat = 26
        let buttonHeight: CGFloat = 28

        // Calculate section dimensions
        let sectionWidth = windowWidth - (padding * 2)
        let soundSectionHeight: CGFloat = 110
        let appearanceSectionHeight: CGFloat = 60

        // Sound section box
        let soundSectionY = windowHeight - padding - soundSectionHeight
        let soundSection = createSectionBox(
            frame: NSRect(x: padding, y: soundSectionY, width: sectionWidth, height: soundSectionHeight),
            title: "Notification Sound",
            iconName: "speaker.wave.2"
        )
        visualEffectView.addSubview(soundSection)

        // Sound dropdown
        let dropdownY = soundSectionHeight - headerHeight - sectionPadding - controlHeight
        let dropdownWidth = sectionWidth - (sectionPadding * 2)
        let dropdown = NSPopUpButton(frame: NSRect(x: sectionPadding, y: dropdownY, width: dropdownWidth, height: controlHeight))
        dropdown.target = self
        dropdown.action = #selector(soundSelectionChanged(_:))
        soundSection.addSubview(dropdown)
        soundDropdown = dropdown

        // Buttons row (Preview and Open Folder side by side)
        let buttonsY = dropdownY - buttonHeight - itemSpacing
        let buttonWidth = (dropdownWidth - buttonGap) / 2

        // Preview button with icon
        let previewButton = NSButton(frame: NSRect(x: sectionPadding, y: buttonsY, width: buttonWidth, height: buttonHeight))
        previewButton.title = "Preview"
        previewButton.bezelStyle = .rounded
        previewButton.target = self
        previewButton.action = #selector(previewSound)
        if let playIcon = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play") {
            previewButton.image = playIcon
            previewButton.imagePosition = .imageLeading
        }
        soundSection.addSubview(previewButton)

        // Open sounds folder button with icon
        let openSoundsButton = NSButton(frame: NSRect(x: sectionPadding + buttonWidth + buttonGap, y: buttonsY, width: buttonWidth, height: buttonHeight))
        openSoundsButton.title = "Open Folder"
        openSoundsButton.bezelStyle = .rounded
        openSoundsButton.target = self
        openSoundsButton.action = #selector(openSoundsFolder)
        if let folderIcon = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder") {
            openSoundsButton.image = folderIcon
            openSoundsButton.imagePosition = .imageLeading
        }
        if let soundsURL = ensureSoundDirectory() {
            openSoundsButton.toolTip = soundsURL.path
        }
        soundSection.addSubview(openSoundsButton)

        // Appearance section box
        let appearanceSectionY = soundSectionY - sectionSpacing - appearanceSectionHeight
        let appearanceSection = createSectionBox(
            frame: NSRect(x: padding, y: appearanceSectionY, width: sectionWidth, height: appearanceSectionHeight),
            title: "Appearance",
            iconName: "dock.rectangle"
        )
        visualEffectView.addSubview(appearanceSection)

        // Hide from dock checkbox
        let checkboxY = appearanceSectionHeight - headerHeight - sectionPadding - 20
        let dockCheckbox = NSButton(checkboxWithTitle: "Hide from Dock", target: self, action: #selector(dockVisibilityChanged(_:)))
        dockCheckbox.frame = NSRect(x: sectionPadding, y: checkboxY, width: 200, height: 20)
        dockCheckbox.state = UserDefaults.standard.bool(forKey: hideFromDockKey) ? .on : .off
        appearanceSection.addSubview(dockCheckbox)

        window.contentView = visualEffectView
        settingsWindow = window

        refreshSoundDropdown()
    }

    func createSectionBox(frame: NSRect, title: String, iconName: String) -> NSBox {
        let box = NSBox(frame: frame)
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 0
        box.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.3)
        box.contentViewMargins = .zero

        // Create header with icon and title
        let headerView = NSView(frame: NSRect(x: 0, y: frame.height - 28, width: frame.width, height: 28))

        // Icon
        if let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: title) {
            let iconView = NSImageView(frame: NSRect(x: 12, y: 4, width: 16, height: 16))
            iconView.image = icon
            iconView.contentTintColor = .secondaryLabelColor
            headerView.addSubview(iconView)
        }

        // Title label
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.frame = NSRect(x: 32, y: 4, width: frame.width - 44, height: 16)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        headerView.addSubview(titleLabel)

        box.addSubview(headerView)

        return box
    }

    @objc func soundSelectionChanged(_ sender: NSPopUpButton) {
        if let selectedTitle = sender.selectedItem?.title {
            UserDefaults.standard.set(selectedTitle, forKey: selectedSoundKey)
        }
    }

    @objc func previewSound() {
        playSelectedSound()
    }

    @objc func dockVisibilityChanged(_ sender: NSButton) {
        let hideFromDock = sender.state == .on
        UserDefaults.standard.set(hideFromDock, forKey: hideFromDockKey)
        applyDockVisibility()
    }

    func applyDockVisibility() {
        let hideFromDock = UserDefaults.standard.bool(forKey: hideFromDockKey)
        if hideFromDock {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // UNUserNotificationCenterDelegate - show notifications even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func prepareSoundDirectory() {
        _ = ensureSoundDirectory()
        startSoundDirectoryMonitor()
    }

    func ensureSoundDirectory() -> URL? {
        return soundDirectoryURL(appName: appSupportFolderName, createIfMissing: true)
    }

    func startSoundDirectoryMonitor() {
        guard soundDirectoryMonitor == nil else { return }
        guard let soundsURL = ensureSoundDirectory() else { return }

        let fd = open(soundsURL.path, O_EVTONLY)
        if fd == -1 {
            print("Error opening sounds directory for monitoring: \(soundsURL.path)")
            return
        }

        soundDirectoryFileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self, weak source] in
            guard let self = self, let source = source else { return }
            let data = source.data
            if data.contains(.rename) || data.contains(.delete) {
                self.restartSoundDirectoryMonitor()
            }
            self.refreshSoundDropdown()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if let fd = self.soundDirectoryFileDescriptor {
                close(fd)
                self.soundDirectoryFileDescriptor = nil
            }
        }

        soundDirectoryMonitor = source
        source.resume()
    }

    func restartSoundDirectoryMonitor() {
        stopSoundDirectoryMonitor()
        _ = ensureSoundDirectory()
        startSoundDirectoryMonitor()
    }

    func stopSoundDirectoryMonitor() {
        soundDirectoryMonitor?.cancel()
        soundDirectoryMonitor = nil
    }

    func soundDirectoryURL(appName: String, createIfMissing: Bool) -> URL? {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let soundsURL = appSupportURL
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)

        if !createIfMissing {
            return FileManager.default.fileExists(atPath: soundsURL.path) ? soundsURL : nil
        }

        do {
            try FileManager.default.createDirectory(at: soundsURL, withIntermediateDirectories: true)
            return soundsURL
        } catch {
            print("Error creating sounds directory: \(error)")
            return nil
        }
    }

    func bundledSoundFiles() -> [URL] {
        guard let resourceURL = Bundle.main.resourceURL else { return [] }
        let candidateURLs = [
            resourceURL,
            resourceURL.appendingPathComponent("Sounds", isDirectory: true),
            resourceURL.appendingPathComponent("sounds", isDirectory: true),
            resourceURL.appendingPathComponent("BakedSounds", isDirectory: true)
        ]
        let supported = Set(supportedSoundExtensions)
        var results: [URL] = []

        for candidate in candidateURLs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for fileURL in files where supported.contains(fileURL.pathExtension.lowercased()) {
                results.append(fileURL)
            }
        }

        return Array(Set(results)).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func soundFileURL(for soundName: String) -> URL? {
        return soundCatalog()[soundName]
    }

    func soundCatalog() -> [String: URL] {
        var catalog: [String: URL] = [:]

        for fileURL in bundledSoundFiles() {
            let name = fileURL.deletingPathExtension().lastPathComponent
            catalog[name] = fileURL
        }

        for fileURL in validatedExternalSoundFiles() {
            let name = fileURL.deletingPathExtension().lastPathComponent
            // External files override bundled files with the same name.
            catalog[name] = fileURL
        }

        return catalog
    }

    func validatedExternalSoundFiles() -> [URL] {
        guard let soundsURL = ensureSoundDirectory() else { return [] }
        let fileManager = FileManager.default
        let supported = Set(supportedSoundExtensions)

        do {
            let files = try fileManager.contentsOfDirectory(at: soundsURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            let validated = files.filter { fileURL in
                let ext = fileURL.pathExtension.lowercased()
                guard supported.contains(ext) else { return false }
                return validateExternalSoundFile(fileURL)
            }
            return validated.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            print("Error reading sounds: \(error)")
            return []
        }
    }

    func validateExternalSoundFile(_ fileURL: URL) -> Bool {
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize > 0 else {
                print("Skipping empty sound file: \(fileURL.lastPathComponent)")
                return false
            }
        } catch {
            print("Skipping unreadable sound file: \(fileURL.lastPathComponent) (\(error))")
            return false
        }

        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            return player.duration > 0
        } catch {
            print("Skipping invalid sound file: \(fileURL.lastPathComponent) (\(error))")
            return false
        }
    }

    func refreshSoundDropdown() {
        guard let dropdown = soundDropdown else { return }
        let sounds = getAvailableSounds()
        dropdown.removeAllItems()
        dropdown.addItems(withTitles: sounds)

        let currentSound = UserDefaults.standard.string(forKey: selectedSoundKey) ?? sounds.first ?? ""
        if let index = sounds.firstIndex(of: currentSound) {
            dropdown.selectItem(at: index)
        } else if let first = sounds.first {
            dropdown.selectItem(at: 0)
            UserDefaults.standard.set(first, forKey: selectedSoundKey)
        }

        dropdown.isEnabled = !sounds.isEmpty
    }

    @objc func openSoundsFolder() {
        guard let soundsURL = ensureSoundDirectory() else { return }
        NSWorkspace.shared.open(soundsURL)
    }
}
