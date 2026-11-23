import AppKit
import IOKit.pwr_mgt

// LidAwake — `pmset -a disablesleep 1` + display-sleep assertion (как `caffeinate -d`).
// Левый клик — вкл/выкл бессрочно. Правый клик — меню: включить на время, защита, выключить, выйти.
//
// Защита (когда включено и тумблер «Защита» стоит):
//   крышка закрыта → яркость встроенного экрана 0 (без блокировки), открыта → прежняя яркость;
//   крышка закрыта и перегрев (thermalState ≥ serious) →
//     0 с: сирена тачпадом 20→600 Гц раз в секунду ×10, длина 0.2→0.5 с (прекращается, если открыть крышку или остыть);
//     1 мин: Low Power Mode;  3 мин: возвращаем сон и усыпляем Mac.

let steps = [15, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720, 1440] // минуты
let lowPowerAfter: TimeInterval = 60, sleepAfter: TimeInterval = 180, pulses = 10
let sudoCmds = ["-a disablesleep 0", "-a disablesleep 1", "-a lowpowermode 0", "-a lowpowermode 1", "sleepnow"]
    .map { "/usr/bin/pmset \($0)" }

func fmt(_ m: Int) -> String {
    let h = m / 60, mm = m % 60
    return h == 0 ? "\(mm) мин" : mm == 0 ? "\(h) ч" : "\(h) ч \(mm) мин"
}

func pmset(_ args: String...) -> Bool { run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + args) == 0 }

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let defaults = UserDefaults.standard
    var assertion: IOPMAssertionID = 0
    var on = false
    var appearanceObs: NSKeyValueObservation?
    var offAt: Date?
    var offTimer: Timer?
    var tick: Timer?
    lazy var step = defaults.object(forKey: "step") as? Int ?? 3 // индекс в steps, по умолчанию 1 ч
    weak var menu: NSMenu?
    weak var durLabel: NSTextField?
    lazy var clock: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    // Защита
    let lid = Lid()
    lazy var haptic = Haptic()
    lazy var safety = defaults.object(forKey: "safety") as? Bool ?? true
    var escalation: [Timer] = []
    var sudoRulesOK = false
    var safetyNote: String?
    /// Яркость до затемнения; хранится на диске, чтобы восстановить даже после краша.
    var savedBrightness: Float? {
        get { defaults.object(forKey: "savedBrightness") as? Float }
        set { defaults.set(newValue, forKey: "savedBrightness") }
    }
    /// Low Power Mode включили мы (а не пользователь) — значит, нам и выключать.
    var lowPowerBySafety: Bool {
        get { defaults.bool(forKey: "lowPowerBySafety") }
        set { defaults.set(newValue, forKey: "lowPowerBySafety") }
    }

    func applicationDidFinishLaunching(_: Notification) {
        let b = item.button!
        b.target = self
        b.action = #selector(click)
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Синхронизация с реальным состоянием (например, после краша).
        if pmsetSleepDisabled() { holdAssertion(true); on = true }
        appearanceObs = b.observe(\.effectiveAppearance) { [weak self] _, _ in self?.render() }
        lid.onChange = { [weak self] in self?.evaluate() }
        lid.start()
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.evaluate() }
        render()
        evaluate()
    }

    func applicationWillTerminate(_: Notification) {
        stopEscalation()
        undim()
        restoreLowPower()
        if on { _ = set(false) }
    }

    @objc func click() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { turn(!on) }
    }

    /// v — вкл/выкл; minutes — авто-выключение через N минут (nil = бессрочно).
    func turn(_ v: Bool, minutes: Int? = nil) {
        if v != on {
            guard set(v) || (v && installSudoRule() && set(v)) else { NSSound.beep(); return }
            on = v
            if v { safetyNote = nil; if safety { ensureSudoRules() } }
        }
        offTimer?.invalidate(); offTimer = nil; offAt = nil
        if v, let minutes {
            let at = Date().addingTimeInterval(TimeInterval(minutes * 60))
            let t = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in self?.turn(false) }
            t.tolerance = 1 // даём системе объединять пробуждения
            RunLoop.main.add(t, forMode: .common)
            offAt = at; offTimer = t
        }
        render()
        evaluate()
        // Выключили при закрытой крышке (таймер / перегрев) — засыпаем, как и положено с закрытой крышкой.
        if !v && lid.isClosed { sleepNow() }
    }

    // MARK: - Защита

    func evaluate() {
        let active = on && safety, closed = lid.isClosed
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if active && closed { dim() } else { undim() }
        if active && closed && hot { startEscalation() } else { stopEscalation() }
        if !(active && hot) { restoreLowPower() } // крышку открыли, но ещё горячо — энергосбережение держим
    }

    func dim() {
        guard savedBrightness == nil, let id = Brightness.builtin(), let b = Brightness.get(id), b > 0.01 else { return }
        savedBrightness = b
        Brightness.set(id, 0)
    }

    func undim(attempt: Int = 0) {
        guard let b = savedBrightness else { return }
        // После открытия крышки экран появляется не мгновенно — повторяем до ~5 с.
        guard let id = Brightness.builtin(), Brightness.set(id, b) else {
            if attempt < 10 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.undim(attempt: attempt + 1) } }
            return
        }
        savedBrightness = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { // контрольный повтор, если система перебила
            if let id = Brightness.builtin(), Brightness.get(id) ?? 1 < 0.01 { Brightness.set(id, b) }
        }
    }

    func startEscalation() {
        guard escalation.isEmpty else { return }
        var left = pulses
        // Импульс i: сирена 20→600 Гц, длина растёт 0.2 → 0.5 с.
        let pulse = { [weak self] (i: Int) in self?.haptic.buzz(ms: 200 + 300 * Double(i) / Double(pulses - 1)) }
        pulse(0)
        func schedule(_ after: TimeInterval, repeats: Bool, _ block: @escaping (Timer) -> Void) {
            let t = Timer(timeInterval: after, repeats: repeats, block: block)
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            escalation.append(t)
        }
        schedule(1, repeats: true) { t in
            left -= 1
            if left > 0 { pulse(pulses - left) } else { t.invalidate() }
        }
        schedule(lowPowerAfter, repeats: false) { [weak self] _ in self?.enableLowPower() }
        schedule(sleepAfter, repeats: false) { [weak self] _ in
            guard let self else { return }
            safetyNote = "Перегрев: сон включён в \(clock.string(from: Date()))"
            turn(false)
        }
    }

    func stopEscalation() {
        guard !escalation.isEmpty else { return }
        escalation.forEach { $0.invalidate() }
        escalation = []
        haptic.close()
    }

    func enableLowPower() {
        guard #available(macOS 12, *), !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        if pmset("-a", "lowpowermode", "1") { lowPowerBySafety = true }
    }

    func restoreLowPower() {
        guard lowPowerBySafety else { return }
        _ = pmset("-a", "lowpowermode", "0")
        lowPowerBySafety = false
    }

    func sleepNow() {
        if run("/usr/bin/pmset", ["sleepnow"]) != 0 { _ = pmset("sleepnow") }
    }

    @objc func toggleSafety() {
        safety.toggle()
        defaults.set(safety, forKey: "safety")
        if safety && on { ensureSudoRules() }
        evaluate()
    }

    // MARK: - Меню

    func showMenu() {
        let m = NSMenu()
        m.autoenablesItems = false
        func info(_ s: String) { m.addItem(withTitle: s, action: nil, keyEquivalent: "").isEnabled = false }
        if let safetyNote { info("⚠️ " + safetyNote); m.addItem(.separator()) }
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
        let s = m.addItem(withTitle: "Защита от перегрева", action: #selector(toggleSafety), keyEquivalent: "")
        s.target = self
        s.state = safety ? .on : .off
        s.toolTip = "Крышка закрыта → экран гаснет (без блокировки).\n" +
            "Перегрев при закрытой крышке → гул тачпадом, через 1 мин энергосбережение, через 3 мин Mac засыпает."
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
        defaults.set(step, forKey: "step")
    }

    @objc func startTimed() {
        menu?.cancelTracking()
        let mins = steps[step]
        DispatchQueue.main.async { self.turn(true, minutes: mins) } // после закрытия меню (может спросить пароль)
    }

    @objc func turnOff() { turn(false) }

    // MARK: - Права

    /// Одно системное окно с паролем → правило sudo только для нужных команд pmset.
    func installSudoRule() -> Bool {
        let tmp = NSTemporaryDirectory() + "lidawake.sudoers"
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: " + sudoCmds.joined(separator: ", ") + "\n"
        guard (try? rule.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let cmd = "/usr/sbin/visudo -cf '\(tmp)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' /etc/sudoers.d/lidawake"
        // osascript отдельным процессом: AppleScript-фреймворки не грузятся в память приложения.
        let ok = run("/usr/bin/osascript", ["-e", "do shell script \"\(cmd)\" with administrator privileges " +
                                                  "with prompt \"LidAwake: разрешить управлять сном и энергосбережением Mac\""]) == 0
        if ok { sudoRulesOK = true }
        return ok
    }

    /// Старое правило (только disablesleep) → дорасширяем, пока пользователь рядом, а не посреди перегрева.
    func ensureSudoRules() {
        guard !sudoRulesOK else { return }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "-l"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let nopasswd = out.split(separator: "\n").filter { $0.contains("NOPASSWD") }.joined(separator: " ")
        sudoRulesOK = sudoCmds.allSatisfy { nopasswd.contains($0) } || installSudoRule()
    }

    // MARK: - pmset / IOKit

    func set(_ v: Bool) -> Bool {
        guard pmset("-a", "disablesleep", v ? "1" : "0") else { return false }
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

    // MARK: - Иконка

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
                t.tolerance = 1
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
