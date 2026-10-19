import AppKit
import Carbon
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement

@main
enum CoffeeApp {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var assertionID: IOPMAssertionID = 0
    private var assertionHeld = false
    private var hotKeyRef: EventHotKeyRef?
    private var powerSource: CFRunLoopSource?
    private var codeAppTimer: Timer?

    private var manualOn = false
    private var pausedWhileCodeAppsRun = false
    private var followCodeApps: Bool {
        get {
            if UserDefaults.standard.object(forKey: "followCodeApps") != nil {
                return UserDefaults.standard.bool(forKey: "followCodeApps")
            }
            return UserDefaults.standard.object(forKey: "followCursor") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "followCodeApps") }
    }
    private var acOnly: Bool {
        get { UserDefaults.standard.object(forKey: "acOnly") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "acOnly") }
    }

    private let toggleItem = NSMenuItem()
    private let cursorItem = NSMenuItem()
    private let acItem = NSMenuItem()
    private let loginItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        toggleItem.title = "Hold Macen våken"
        toggleItem.action = #selector(toggleManual)
        toggleItem.target = self
        toggleItem.keyEquivalent = "k"
        toggleItem.keyEquivalentModifierMask = [.option, .command]

        cursorItem.title = "Når en agent jobber"
        cursorItem.action = #selector(toggleFollowCodeApps)
        cursorItem.target = self

        acItem.title = "Bare på strøm"
        acItem.action = #selector(toggleACOnly)
        acItem.target = self

        loginItem.title = "Start med macOS"
        loginItem.action = #selector(toggleLogin)
        loginItem.target = self

        let quit = NSMenuItem(
            title: "Avslutt Coffee",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        menu = NSMenu()
        menu.addItem(toggleItem)
        menu.addItem(cursorItem)
        menu.addItem(acItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(quit)

        enableLoginOnFirstLaunch()
        registerHotKey()
        watchCodeApps()
        watchPower()
        syncAssertion()
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseAssertion()
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        codeAppTimer?.invalidate()
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            updateUI()
            if let button = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
            }
        } else {
            toggleManual()
        }
    }

    @objc func hotKeyPressed() {
        toggleManual()
    }

    @objc private func toggleManual() {
        if desiredAwake {
            manualOn = false
            if followCodeApps && CodeApps.isRunning {
                pausedWhileCodeAppsRun = true
            }
        } else {
            pausedWhileCodeAppsRun = false
            if !(followCodeApps && CodeApps.isRunning) {
                manualOn = true
            }
        }
        syncAssertion()
    }

    @objc private func toggleFollowCodeApps() {
        followCodeApps.toggle()
        pausedWhileCodeAppsRun = false
        syncAssertion()
    }

    @objc private func toggleACOnly() {
        acOnly.toggle()
        syncAssertion()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showAlert("Klarte ikke å endre start med macOS.", detail: error.localizedDescription)
        }
        updateUI()
    }

    private var batteryOK: Bool {
        let power = PowerInfo.current()
        if !power.onAC, let percent = power.percent, percent < 20 { return false }
        return true
    }

    private var powerOK: Bool {
        let power = PowerInfo.current()
        if acOnly && !power.onAC { return false }
        return batteryOK
    }

    private var desiredAwake: Bool {
        if followCodeApps && CodeApps.isRunning && !pausedWhileCodeAppsRun {
            return batteryOK
        }
        guard powerOK else { return false }
        return manualOn
    }

    private func syncAssertion() {
        if desiredAwake {
            takeAssertion()
        } else {
            releaseAssertion()
        }
        updateUI()
    }

    private func takeAssertion() {
        guard !assertionHeld else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Coffee" as CFString,
            &assertionID
        )
        assertionHeld = result == kIOReturnSuccess
        if !assertionHeld {
            showAlert("Klarte ikke å hindre dvale.", detail: nil)
        }
    }

    private func releaseAssertion() {
        guard assertionHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        assertionHeld = false
    }

    private func updateUI() {
        toggleItem.state = desiredAwake ? .on : .off
        cursorItem.state = followCodeApps ? .on : .off
        acItem.state = acOnly ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let symbol = assertionHeld ? "cup.and.saucer.fill" : "cup.and.saucer"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Coffee")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = tooltip()
    }

    private func tooltip() -> String {
        if assertionHeld {
            if followCodeApps && CodeApps.isRunning && !manualOn {
                return "Coffee — våken mens en agent jobber"
            }
            return "Coffee — Macen holdes våken"
        }
        if acOnly && !PowerInfo.current().onAC && !CodeApps.isRunning {
            return "Coffee — av (krever strøm)"
        }
        if !PowerInfo.current().onAC, let percent = PowerInfo.current().percent, percent < 20 {
            return "Coffee — av (batteri under 20 %)"
        }
        return "Coffee — av · venstreklikk på, høyreklikk meny"
    }

    private func watchCodeApps() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, CodeApps.matches(app) else { return }
            self.pausedWhileCodeAppsRun = false
            self.syncAssertion()
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, CodeApps.matches(app) else { return }
            self.pausedWhileCodeAppsRun = false
            self.syncAssertion()
        }
        codeAppTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.syncAssertion()
        }
        codeAppTimer?.tolerance = 5
    }

    private func watchPower() {
        let callback: IOPowerSourceCallbackType = { _ in
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.syncAssertion()
            }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncAssertion()
        }
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.hotKeyPressed()
            }
            return noErr
        }, 1, &spec, nil, nil)

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x434F4645, id: 1) // 'COFE'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_K),
            UInt32(cmdKey | optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        hotKeyRef = ref
    }

    private func enableLoginOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "didSetLoginItem") == nil else { return }
        defaults.set(true, forKey: "didSetLoginItem")
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    private func showAlert(_ message: String, detail: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Coffee"
        alert.informativeText = detail.map { "\(message)\n\n\($0)" } ?? message
        alert.runModal()
    }
}

private enum PowerInfo {
    static func current() -> (onAC: Bool, percent: Int?) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return (true, nil) }

        var onAC = false
        var percent: Int?
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue {
                onAC = true
            }
            if let cur = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = Int((Double(cur) / Double(max) * 100).rounded())
            }
        }
        if list.isEmpty { onAC = true }
        return (onAC, percent)
    }
}

private enum CodeApps {
    static var isRunning: Bool {
        if NSWorkspace.shared.runningApplications.contains(where: matches) { return true }
        return cliRunning()
    }

    static func matches(_ app: NSRunningApplication) -> Bool {
        let id = (app.bundleIdentifier ?? "").lowercased()
        if bundleIDs.contains(id) { return true }
        let name = app.localizedName ?? ""
        if names.contains(where: { name.caseInsensitiveCompare($0) == .orderedSame }) { return true }
        if let path = app.bundleURL?.path.lowercased() {
            if path.contains("cursor.app") { return true }
            if path.contains("claudecode.app") || path.contains("codex.app") { return true }
        }
        return false
    }

    private static let bundleIDs: Set<String> = [
        "com.todesktop.230313mzl4w4u92",
        "com.openai.codex",
        "com.openai.chat",
        "com.anthropic.claudefordesktop",
        "com.anthropic.claude-code",
        "com.exafunction.windsurf"
    ]

    private static let names: Set<String> = [
        "Cursor", "ChatGPT", "Codex", "Claude", "Claude Code", "Windsurf", "Devin"
    ]

    private static let cliNames: Set<String> = [
        "claude", "claude.exe", "codex", "gemini", "aider", "opencode", "cursor-agent"
    ]

    private static func cliRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "comm=,command="]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n") {
            let lower = line.lowercased()
            let comm = lower.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if cliNames.contains(comm) { return true }
            if lower.contains("cursor-agent") { return true }
            if lower.contains(".local/share/claude") { return true }
            if lower.contains("claude/versions") { return true }
            if lower.contains("@anthropic-ai/claude-code") { return true }
            if lower.contains("@openai/codex") { return true }
        }
        return false
    }
}
