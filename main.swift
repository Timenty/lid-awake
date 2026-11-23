import AppKit
import IOKit.pwr_mgt

// LidAwake — `pmset -a disablesleep 1` + display-sleep assertion (как `caffeinate -d`).
// Левый клик — вкл/выкл бессрочно. Правый клик — меню: включить на время, выключить, выйти.

let steps = [15, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720, 1440] // минуты

func fmt(_ m: Int) -> String {
    let h = m / 60, mm = m % 60
    return h == 0 ? "\(mm) мин" : mm == 0 ? "\(h) ч" : "\(h) ч \(mm) мин"
}

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var assertion: IOPMAssertionID = 0
    var on = false
    var appearanceObs: NSKeyValueObservation?
    var offAt: Date?
    var offTimer: Timer?
    var tick: Timer?
    var step = UserDefaults.standard.object(forKey: "step") as? Int ?? 3 // индекс в steps, по умолчанию 1 ч
    weak var menu: NSMenu?
    weak var durLabel: NSTextField?
    let clock: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    func applicationDidFinishLaunching(_: Notification) {
        let b = item.button!
        b.target = self
        b.action = #selector(click)
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Синхронизация с реальным состоянием (например, после краша).
        if pmsetSleepDisabled() { holdAssertion(true); on = true }
        appearanceObs = b.observe(\.effectiveAppearance) { [weak self] _, _ in self?.render() }
        render()
    }

    func applicationWillTerminate(_: Notification) { if on { _ = set(false) } }

    @objc func click() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { turn(!on) }
    }

    /// v — вкл/выкл; minutes — авто-выключение через N минут (nil = бессрочно).
    func turn(_ v: Bool, minutes: Int? = nil) {
        if v != on {
            guard set(v) || (v && installSudoRule() && set(v)) else { NSSound.beep(); return }
            on = v
        }
        offTimer?.invalidate(); offTimer = nil; offAt = nil
        if v, let minutes {
            let at = Date().addingTimeInterval(TimeInterval(minutes * 60))
            let t = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in self?.turn(false) }
            RunLoop.main.add(t, forMode: .common)
            offAt = at; offTimer = t
        }
        render()
    }

    func showMenu() {
        let m = NSMenu()
        m.autoenablesItems = false
        func info(_ s: String) { m.addItem(withTitle: s, action: nil, keyEquivalent: "").isEnabled = false }
        if on {
            if let offAt {
                let left = max(1, Int((offAt.timeIntervalSinceNow / 60).rounded(.up)))
                info("Выключится в \(clock.string(from: offAt)) (через \(fmt(left)))")
            } else {
                info("Включено, пока не выключите")
            }
            m.addItem(withTitle: "Выключить", action: #selector(turnOff), keyEquivalent: "").target = self
            m.addItem(.separator())
        }
        info("Включить на время:")
        let row = NSMenuItem()
        row.view = timerRow()
        m.addItem(row)
        m.addItem(.separator())
        m.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu = m
        item.menu = m
        item.button!.performClick(nil) // блокирует, пока меню открыто
        item.menu = nil
    }

    func timerRow() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let label = NSTextField(labelWithString: fmt(steps[step]))
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 20, y: 7, width: 100, height: 18)
        let st = NSStepper(frame: NSRect(x: 122, y: 4, width: 19, height: 24))
        st.minValue = 0; st.maxValue = Double(steps.count - 1); st.increment = 1
        st.integerValue = step
        st.target = self; st.action = #selector(stepped(_:))
        let b = NSButton(title: "Старт", target: self, action: #selector(startTimed))
        b.bezelStyle = .rounded
        b.keyEquivalent = "\r"
        b.frame = NSRect(x: 150, y: 2, width: 80, height: 28)
        [label, st, b].forEach(v.addSubview)
        durLabel = label
        return v
    }

    @objc func stepped(_ s: NSStepper) {
        step = s.integerValue
        durLabel?.stringValue = fmt(steps[step])
        UserDefaults.standard.set(step, forKey: "step")
    }

    @objc func startTimed() {
        menu?.cancelTracking()
        let mins = steps[step]
        DispatchQueue.main.async { self.turn(true, minutes: mins) } // после закрытия меню (может спросить пароль)
    }

    @objc func turnOff() { turn(false) }

    // Первый запуск: одно системное окно с паролем → правило sudo только для pmset disablesleep 0/1.
    func installSudoRule() -> Bool {
        let tmp = NSTemporaryDirectory() + "lidawake.sudoers"
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        guard (try? rule.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let cmd = "/usr/sbin/visudo -cf '\(tmp)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' /etc/sudoers.d/lidawake"
        let script = NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges " +
                                   "with prompt \"LidAwake: разрешить отключать сон Mac\"")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        return err == nil
    }

    func set(_ v: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", v ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        holdAssertion(v)
        return true
    }

    func holdAssertion(_ v: Bool) {
        if v, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "LidAwake" as CFString, &assertion)
        } else if !v, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    func pmsetSleepDisabled() -> Bool {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: "\n").contains {
            $0.contains("SleepDisabled") && $0.split(whereSeparator: \.isWhitespace).last == "1"
        }
    }

    func render() {
        let b = item.button!
        if on {
            let dark = b.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            b.image = mugImage(fg: dark ? .white : .black,
                               coffee: dark ? NSColor(srgbRed: 0.78, green: 0.52, blue: 0.30, alpha: 1)
                                            : NSColor(srgbRed: 0.55, green: 0.33, blue: 0.16, alpha: 1))
        } else {
            b.image = mugImage(fg: .black, coffee: nil)
        }
        // Оставшееся время рядом с кружкой. Перерисовка ровно в момент смены минуты — без поминутного опроса.
        tick?.invalidate(); tick = nil
        if on, let offAt {
            let left = max(1, Int((offAt.timeIntervalSinceNow / 60).rounded(.up)))
            b.title = String(format: " %d:%02d", left / 60, left % 60)
            b.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            b.imagePosition = .imageLeft
            item.length = NSStatusItem.variableLength
            if left > 1 {
                let t = Timer(fire: offAt.addingTimeInterval(-Double(left - 1) * 60 + 0.1), interval: 0,
                              repeats: false) { [weak self] _ in self?.render() }
                RunLoop.main.add(t, forMode: .common)
                tick = t
            }
        } else {
            b.title = ""
            b.imagePosition = .imageOnly
            item.length = NSStatusItem.squareLength
        }
        b.toolTip = !on ? "LidAwake: OFF"
            : offAt.map { "LidAwake: не спит до \(clock.string(from: $0))" } ?? "LidAwake: ON — Mac не спит"
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
