import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let sleepGuard = SleepGuard()
    private let watcher = ProcessWatcher()
    private let updater = Updater()
    private let menu = NSMenu()
    private let headerItem = NSMenuItem()
    private let defaults = UserDefaults.standard

    /// Turned on from the menu (깨우기) or a timed preset.
    private var manualOn = false
    private var deadline: Date?
    /// Choosing 재우기 while auto-detect holds the Mac awake snoozes it until the detected work finishes.
    private var autoSnoozed = false
    private var lidOn = false

    private var face: OwlFace?
    private var wasAwake = false
    private var animationID = 0
    private var blinkTimer: Timer?
    private var tickTimer: Timer?

    private var autoDetect: Bool {
        get { defaults.bool(forKey: "autoDetect") }
        set { defaults.set(newValue, forKey: "autoDetect") }
    }

    private var keepDisplayOn: Bool {
        get { defaults.bool(forKey: "keepDisplayOn") }
        set { defaults.set(newValue, forKey: "keepDisplayOn") }
    }

    private var watchNames: [String] {
        get { defaults.stringArray(forKey: "watchNames") ?? ProcessWatcher.defaultNames }
        set {
            defaults.set(newValue, forKey: "watchNames")
            watcher.names = newValue
        }
    }

    private var autoAwake: Bool { autoDetect && !autoSnoozed && !watcher.found.isEmpty }
    private var isAwake: Bool { manualOn || lidOn || autoAwake }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["autoDetect": true, "autoUpdateCheck": true, "autoUpdateInstall": true])

        // A menu attached to the status item opens on left and right click alike, like other menu bar apps.
        menu.delegate = self
        statusItem.menu = menu
        headerItem.isEnabled = false

        watcher.names = watchNames
        watcher.onChange = { [weak self] in
            guard let self else { return }
            if self.watcher.found.isEmpty { self.autoSnoozed = false }
            self.refresh()
        }
        if autoDetect { watcher.start() }

        MainActor.assumeIsolated {  // AppKit calls this on the main thread; Updater is main-actor isolated
            updater.onAutoFound = { [weak self] release in self?.handleAutoFound(release) }
            updater.scheduleAutoCheck()
        }
        announceUpdateIfJustInstalled()

        lidOn = LidGuard.isEnabled
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepGuard.release()
        if lidOn { LidGuard.setEnabled(false) }
    }

    // MARK: Menu opening

    /// Rebuilds the menu right before it shows so the header and check marks reflect the current state.
    func menuWillOpen(_ menu: NSMenu) {
        buildMenu()
    }

    @objc private func toggle() {
        if isAwake {
            manualOn = false
            deadline = nil
            if autoAwake { autoSnoozed = true }
            if lidOn { setLid(false) }
        } else {
            manualOn = true
        }
        refresh()
    }

    @objc private func startTimed(_ sender: NSMenuItem) {
        manualOn = true
        deadline = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        refresh()
    }

    @objc private func toggleAutoDetect() {
        autoDetect.toggle()
        autoSnoozed = false
        if autoDetect { watcher.start() } else { watcher.stop() }
        refresh()
    }

    @objc private func toggleKeepDisplayOn() {
        keepDisplayOn.toggle()
        refresh()
    }

    @objc private func toggleLid() {
        if !lidOn {
            let alert = NSAlert()
            alert.messageText = "뚜껑을 닫아도 깨어 있게 할까요?"
            alert.informativeText = """
            충전기 없이 뚜껑을 닫아도 맥이 잠들지 않아요.

            • 가방에 넣지 마세요. 뚜껑을 닫은 채 일하면 뜨거워져요.
            • 배터리가 다 되면 그냥 꺼져요. 긴 작업이면 충전기를 꽂아 두세요.
            • 부엉이를 재우거나 OwlMac을 끄면 원래대로 돌아가요. 이때 비밀번호를 한 번 더 물어요.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "켜기")
            alert.addButton(withTitle: "취소")
            activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        setLid(!lidOn)
    }

    private func setLid(_ on: Bool) {
        LidGuard.setEnabled(on)
        lidOn = LidGuard.isEnabled
        refresh()
    }

    @objc private func editWatchNames() {
        let alert = NSAlert()
        alert.messageText = "어떤 명령이 돌 때 깨어 있을까요?"
        alert.informativeText = "실행 파일 이름을 쉼표로 구분해서 적어 주세요. 대소문자를 구분해요.\n예: claude, npm, pnpm, cargo"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = watchNames.joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "기본값으로")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        activate()

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            watchNames = field.stringValue
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map(String.init)
        case .alertSecondButtonReturn:
            defaults.removeObject(forKey: "watchNames")
            watcher.names = ProcessWatcher.defaultNames
        default:
            return
        }
        if autoDetect { watcher.scan() }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "로그인 항목을 바꾸지 못했어요"
            alert.informativeText = "\(error.localizedDescription)\n\nOwlMac이 응용 프로그램 폴더에 있는지 확인해 주세요."
            activate()
            alert.runModal()
        }
    }

    private func activate() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: Updates

    @MainActor @objc private func checkForUpdates() {
        Task {
            do {
                switch try await updater.check() {
                case .newer(let release):
                    promptUpdate(release)
                case .upToDate(let version):
                    notice("최신 버전이에요", "지금 쓰는 v\(version)이 가장 새 버전이에요.")
                case .unversioned:
                    notice("소스 빌드예요", "버전 정보가 없어서 업데이트를 확인하지 않아요. 설치 명령으로 받은 OwlMac에서만 확인해요.")
                }
            } catch {
                notice("업데이트를 확인하지 못했어요",
                       "\(error.localizedDescription)\n\n잠시 뒤 다시 해 보거나 릴리스 페이지를 열어 보세요.\nhttps://github.com/semiaurum/owlmac/releases")
            }
        }
    }

    @MainActor @objc private func installAvailableUpdate() {
        if let release = updater.available { promptUpdate(release) }
    }

    @MainActor @objc private func toggleAutoUpdateCheck() {
        updater.autoCheck.toggle()
    }

    @MainActor @objc private func toggleAutoUpdateInstall() {
        updater.autoInstall.toggle()
        installPendingUpdateIfAllowed()
    }

    /// Automatic check found a newer version. With auto-install on, swap now if nothing is kept awake,
    /// otherwise wait for the owl to fall asleep (see refresh). With it off, ask once per version.
    @MainActor private func handleAutoFound(_ release: Updater.Release) {
        if updater.autoInstall {
            installPendingUpdateIfAllowed()
            return
        }
        guard defaults.string(forKey: "offeredUpdateVersion") != release.version.text else { return }
        defaults.set(release.version.text, forKey: "offeredUpdateVersion")
        promptUpdate(release)
    }

    private func installPendingUpdateIfAllowed() {
        guard !isAwake else { return }
        MainActor.assumeIsolated {
            guard updater.autoInstall, let release = updater.available else { return }
            startUpdate(release)
        }
    }

    /// Shows what happened after an update swapped the app and relaunched it.
    private func announceUpdateIfJustInstalled() {
        guard let from = defaults.string(forKey: "updatedFromVersion") else { return }
        defaults.removeObject(forKey: "updatedFromVersion")
        guard let now = Updater.currentVersion?.text, now != from else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.notice("v\(now)으로 업데이트했어요", "v\(from)에서 올라왔어요. 설정은 그대로예요.")
        }
    }

    @MainActor private func promptUpdate(_ release: Updater.Release) {
        let alert = NSAlert()
        alert.messageText = "새 버전 v\(release.version)이 있어요"
        alert.informativeText = """
        지금은 v\(Updater.currentVersion?.text ?? "?")이에요.

        업데이트하면 OwlMac이 잠깐 종료됐다가 새 버전으로 다시 실행돼요. 깨어 있던 상태는 다시 켜야 해요.
        """
        alert.addButton(withTitle: "업데이트")
        alert.addButton(withTitle: "릴리스 노트 보기")
        alert.addButton(withTitle: "나중에")
        activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: startUpdate(release)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.pageURL)
        default: break
        }
    }

    @MainActor private func startUpdate(_ release: Updater.Release) {
        Task {
            do {
                try await updater.install(release)
                defaults.set(Updater.currentVersion?.text, forKey: "updatedFromVersion")
                NSApp.terminate(nil)  // the swap script waits for this process to exit, then relaunches
            } catch {
                notice("업데이트하지 못했어요",
                       "\(error.localizedDescription)\n\n설치 명령을 다시 실행해도 돼요.\ncurl -fsSL https://raw.githubusercontent.com/semiaurum/owlmac/main/install.sh | bash")
            }
        }
    }

    @MainActor private func notice(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        activate()
        alert.runModal()
    }

    // MARK: State → UI

    private func refresh() {
        let awake = isAwake
        if awake {
            sleepGuard.hold(reason: assertionReason, keepDisplayOn: keepDisplayOn)
        } else {
            sleepGuard.release()
        }

        if awake && !wasAwake {
            animate([.blink, .watching, .awake], step: 0.09)  // eyes pop open
        } else {
            show(awake ? .awake : (autoDetect ? .watching : .asleep))
        }
        if wasAwake && !awake { installPendingUpdateIfAllowed() }  // the owl just went to sleep: safe to swap the app
        wasAwake = awake

        scheduleBlink()
        updateTickTimer()
        updateLabels()
    }

    private func show(_ newFace: OwlFace) {
        animationID += 1
        setFace(newFace)
    }

    private func setFace(_ newFace: OwlFace) {
        guard newFace != face else { return }
        face = newFace
        statusItem.button?.image = OwlIcon.statusImage(newFace)
    }

    private func animate(_ frames: [OwlFace], step: TimeInterval, then done: (() -> Void)? = nil) {
        animationID += 1
        let id = animationID
        for (i, frame) in frames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) { [weak self] in
                guard let self, self.animationID == id else { return }
                self.setFace(frame)
                if i == frames.count - 1 { done?() }
            }
        }
    }

    private func scheduleBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard isAwake else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 3.5...8), repeats: false) { [weak self] _ in
            guard let self, self.isAwake else { return }
            let frames: [OwlFace] = Int.random(in: 0..<4) == 0
                ? [.blink, .awake, .blink, .awake]  // the occasional double blink
                : [.blink, .awake]
            self.animate(frames, step: 0.12) { [weak self] in self?.scheduleBlink() }
        }
    }

    private func updateTickTimer() {
        guard deadline != nil else {
            tickTimer?.invalidate()
            tickTimer = nil
            return
        }
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)  // keep counting while the menu is open
        tickTimer = timer
    }

    private func tick() {
        if let deadline, deadline <= Date() {
            manualOn = false
            self.deadline = nil
            refresh()
        } else {
            updateLabels()
        }
    }

    private func updateLabels() {
        headerItem.title = statusText
        statusItem.button?.toolTip = "OwlMac — \(statusText)"
    }

    private var statusText: String {
        if lidOn { return "깨어 있음 · 뚜껑을 닫아도 안 자요" }
        if manualOn {
            guard let deadline else { return "깨어 있음 · 끌 때까지" }
            return "깨어 있음 · \(format(deadline.timeIntervalSinceNow)) 남음"
        }
        if autoAwake { return "깨어 있음 · \(watcher.found.joined(separator: ", ")) 실행 중" }
        if autoDetect {
            return autoSnoozed ? "잠깐 쉬는 중 · 지금 작업이 끝나면 다시 지켜봐요" : "지켜보는 중 · 감지된 작업 없음"
        }
        return "잠자는 중"
    }

    private var assertionReason: String {
        if manualOn || lidOn { return "OwlMac (manual)" }
        return "OwlMac (\(watcher.found.joined(separator: ", ")))"
    }

    private func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Menu

    private func buildMenu() {
        lidOn = LidGuard.isEnabled  // could have been changed from Terminal
        updateLabels()
        menu.removeAllItems()

        menu.addItem(headerItem)
        menu.addItem(.separator())

        if let release = MainActor.assumeIsolated({ updater.available }) {
            menu.addItem(item("새 버전 v\(release.version) 업데이트…", #selector(installAvailableUpdate)))
            menu.addItem(.separator())
        }

        menu.addItem(item(isAwake ? "재우기" : "깨우기", #selector(toggle)))
        let timed = NSMenuItem(title: "시간 정해 깨우기", action: nil, keyEquivalent: "")
        let presets = NSMenu()
        for (title, minutes) in [("30분", 30), ("1시간", 60), ("2시간", 120), ("4시간", 240), ("8시간", 480)] {
            let preset = item(title, #selector(startTimed(_:)))
            preset.tag = minutes
            presets.addItem(preset)
        }
        timed.submenu = presets
        menu.addItem(timed)
        menu.addItem(.separator())

        let auto = item("개발 작업이 돌면 알아서 깨어 있기", #selector(toggleAutoDetect))
        auto.state = autoDetect ? .on : .off
        auto.toolTip = "감지 대상: " + watchNames.joined(separator: ", ")
        menu.addItem(auto)
        menu.addItem(item("감지할 명령 편집…", #selector(editWatchNames)))
        menu.addItem(.separator())

        let display = item("화면도 켜 두기", #selector(toggleKeepDisplayOn))
        display.state = keepDisplayOn ? .on : .off
        menu.addItem(display)
        let lid = item("뚜껑 닫아도 깨어 있기 (관리자 권한)", #selector(toggleLid))
        lid.state = lidOn ? .on : .off
        menu.addItem(lid)
        menu.addItem(.separator())

        let login = item("로그인할 때 실행", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let autoUpdate = item("업데이트 자동 확인", #selector(toggleAutoUpdateCheck))
        autoUpdate.state = MainActor.assumeIsolated({ updater.autoCheck }) ? .on : .off
        menu.addItem(autoUpdate)
        let autoInstall = item("업데이트 자동 설치", #selector(toggleAutoUpdateInstall))
        autoInstall.state = MainActor.assumeIsolated({ updater.autoInstall }) ? .on : .off
        autoInstall.toolTip = "새 버전이 있으면 부엉이가 자는 동안 알아서 바꾸고 다시 실행해요"
        menu.addItem(autoInstall)
        menu.addItem(item("업데이트 확인…", #selector(checkForUpdates)))
        menu.addItem(NSMenuItem(title: "OwlMac 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
