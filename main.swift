import AppKit
import IOKit.pwr_mgt
import ServiceManagement

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
    let hs = t("h", "ч"), ms = t("min", "мин")
    return h == 0 ? "\(mm) \(ms)" : mm == 0 ? "\(h) \(hs)" : "\(h) \(hs) \(mm) \(ms)"
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
    weak var untilLabel: NSTextField?
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
            let at = clock.string(from: Date())
            safetyNote = t("Overheated: sleep re-enabled at \(at)", "Перегрев: сон включён в \(at)")
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

    @objc func switchSafety(_ sw: NSSwitch) {
        safety = sw.state == .on
        defaults.set(safety, forKey: "safety")
        if safety && on { ensureSudoRules() }
        evaluate()
    }

    // MARK: - Меню

    let menuWidth: CGFloat = 272, rightInset: CGFloat = 11
    /// Колонки иконок и заголовков стандартных пунктов (замерено на macOS 26) — по ним выравниваем свои view.
    /// Иконки у пунктов — с macOS 26. В macOS 27 система прячет по умолчанию только символьные иконки,
    /// наши (символ, перерисованный в картинку 16×16) остаются видны — так и задумано.
    var showIcons: Bool { if #available(macOS 26, *) { return true } else { return false } }
    var iconX: CGFloat { 16 }
    var titleX: CGFloat {
        if showIcons { return 36 }
        if #available(macOS 26, *) { return 14 } // меню без иконок, замер на 26 (основа меню та же в 27)
        return 21
    }

    /// Иконка в колонке иконок стандартных пунктов.
    func iconView(_ name: String, rowHeight h: CGFloat, top: CGFloat? = nil) -> NSImageView? {
        guard let img = symbol(name) else { return nil }
        let iv = NSImageView(image: img)
        iv.contentTintColor = .labelColor
        iv.imageScaling = .scaleProportionallyDown
        iv.frame = NSRect(x: iconX, y: top.map { $0 - 16 } ?? (h - 16) / 2, width: 16, height: 16)
        return iv
    }

    /// Иконки у пунктов, как в системных меню macOS 26. На старых macOS меню без иконок.
    /// Символ вписан в единый квадрат 16×16: ширина колонки иконок (а значит, и отступ текста)
    /// не зависит от того, какие пункты сейчас в меню.
    func symbol(_ name: String) -> NSImage? {
        guard showIcons, let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        else { return nil }
        let side: CGFloat = 16
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let k = min(1, side / max(sym.size.width, sym.size.height))
            let w = sym.size.width * k, h = sym.size.height * k
            sym.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            return true
        }
        img.isTemplate = true
        return img
    }

    func showMenu() {
        let m = NSMenu()
        m.autoenablesItems = false
        func add(_ title: String, _ icon: String, _ action: Selector? = nil, key: String = "") {
            let i = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            i.target = self
            i.image = symbol(icon)
            i.isEnabled = action != nil
        }
        func custom(_ v: NSView) { let i = NSMenuItem(); i.view = v; m.addItem(i) }

        if let safetyNote { add(safetyNote, "exclamationmark.triangle"); m.addItem(.separator()) }
        // Набор пунктов всегда один и тот же (HIG): меняются только подписи.
        if !on {
            add(t("Off — normal sleep", "Выключено — обычный сон"), "moon.zzz")
        } else if let offAt {
            let left = max(1, Int((offAt.timeIntervalSinceNow / 60).rounded(.up)))
            let at = clock.string(from: offAt), inT = fmt(left)
            add(t("Turns off at \(at) (in \(inT))", "Выключится в \(at) (через \(inT))"), "timer")
        } else {
            add(t("On until you turn it off", "Включено, пока не выключите"), "infinity")
        }
        add(on ? t("Turn Off", "Выключить") : t("Turn On", "Включить"), "power", #selector(toggleFromMenu))
        m.addItem(.separator())
        custom(timerView())
        m.addItem(.separator())
        custom(safetyView())
        if let v = loginView() { custom(v) }
        m.addItem(.separator())
        add(t("Quit LidAwake", "Выйти"), "xmark", #selector(quit), key: "q")
        menu = m
        item.menu = m
        item.button!.performClick(nil) // блокирует, пока меню открыто
        item.menu = nil
    }

    /// Ползунок длительности (как в Пункте управления): «⏲ 2 ч ··· до 16:40», ползунок, Старт.
    func timerView() -> NSView {
        let x = titleX, h: CGFloat = 92, inner = menuWidth - x - rightInset
        let v = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: h))
        v.autoresizingMask = .width
        if let iv = iconView("timer", rowHeight: 24, top: h - 4) { v.addSubview(iv) }
        let dur = NSTextField(labelWithString: "")
        dur.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        dur.frame = NSRect(x: x, y: h - 20, width: inner / 2, height: 16)
        dur.autoresizingMask = .width
        let until = NSTextField(labelWithString: "")
        until.font = .menuFont(ofSize: 0)
        until.textColor = .secondaryLabelColor
        until.alignment = .right
        until.frame = NSRect(x: x + inner / 2, y: h - 20, width: inner / 2, height: 16)
        until.autoresizingMask = [.width, .minXMargin]
        let s = NSSlider(value: Double(step), minValue: 0, maxValue: Double(steps.count - 1),
                         target: self, action: #selector(slid(_:)))
        s.numberOfTickMarks = steps.count
        s.allowsTickMarkValuesOnly = true
        s.isContinuous = true
        s.frame = NSRect(x: x - 2, y: 38, width: inner + 4, height: 24) // трек внутри на 2pt уже рамки
        s.autoresizingMask = .width
        let b = NSButton(title: t("Start", "Старт"), target: self, action: #selector(startTimed))
        b.bezelStyle = .rounded
        b.keyEquivalent = "\r"
        b.frame = NSRect(x: x, y: 6, width: inner, height: 28)
        b.autoresizingMask = .width
        [dur, until, s, b].forEach(v.addSubview)
        durLabel = dur
        untilLabel = until
        updateTimerLabels()
        return v
    }

    func updateTimerLabels() {
        let mins = steps[step], end = Date().addingTimeInterval(TimeInterval(mins * 60))
        let at = clock.string(from: end)
        durLabel?.stringValue = fmt(mins)
        untilLabel?.stringValue = Calendar.current.isDateInToday(end)
            ? t("until \(at)", "до \(at)") : t("until tomorrow \(at)", "до завтра \(at)")
    }

    @objc func slid(_ s: NSSlider) {
        step = Int(s.doubleValue.rounded())
        defaults.set(step, forKey: "step")
        updateTimerLabels()
    }

    /// Строка с переключателем справа, как Wi-Fi/Bluetooth в системных меню.
    func switchRow(_ title: String, icon: String, isOn: Bool, action: Selector, tip: String) -> NSView {
        let h: CGFloat = 28
        let v = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: h))
        v.autoresizingMask = .width
        if let iv = iconView(icon, rowHeight: h) { v.addSubview(iv) }
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.state = isOn ? .on : .off
        sw.target = self
        sw.action = action
        sw.sizeToFit()
        sw.frame.origin = NSPoint(x: menuWidth - rightInset + 3 - sw.frame.width, y: (h - sw.frame.height) / 2) // у NSSwitch 3pt полей
        sw.autoresizingMask = .minXMargin
        let l = NSTextField(labelWithString: title)
        l.font = .menuFont(ofSize: 0)
        l.frame = NSRect(x: titleX, y: (h - 16) / 2, width: sw.frame.minX - titleX - 8, height: 16)
        l.autoresizingMask = .width
        [l, sw].forEach(v.addSubview)
        v.toolTip = tip
        return v
    }

    func safetyView() -> NSView {
        switchRow(t("Overheat Protection", "Защита от перегрева"), icon: "thermometer.medium", isOn: safety,
                  action: #selector(switchSafety(_:)),
                  tip: t("Lid closed → screen goes dark (not locked).\n" +
                         "Overheating with the lid closed → trackpad siren, Low Power Mode after 1 min, sleep after 3 min.",
                         "Крышка закрыта → экран гаснет (без блокировки).\n" +
                         "Перегрев при закрытой крышке → гул тачпадом, через 1 мин энергосбережение, через 3 мин Mac засыпает."))
    }

    /// «Открывать при входе» через SMAppService (macOS 13+); на 11–12 строки нет.
    func loginView() -> NSView? {
        guard #available(macOS 13, *) else { return nil }
        return switchRow(t("Open at Login", "Открывать при входе"), icon: "sunrise",
                         isOn: SMAppService.mainApp.status == .enabled, action: #selector(switchLogin(_:)),
                         tip: t("Start LidAwake automatically when you log in.", "Запускать LidAwake автоматически при входе в систему."))
    }

    @objc func switchLogin(_ sw: NSSwitch) {
        guard #available(macOS 13, *) else { return }
        let app = SMAppService.mainApp
        do {
            if sw.state == .on { try app.register() } else { try app.unregister() }
        } catch {
            NSSound.beep()
        }
        // Пользователь раньше выключил LidAwake в «Объектах входа» — включить можно только там.
        if app.status == .requiresApproval {
            menu?.cancelTracking()
            SMAppService.openSystemSettingsLoginItems()
        }
        sw.state = app.status == .enabled ? .on : .off
    }

    @objc func startTimed() {
        menu?.cancelTracking()
        let mins = steps[step]
        DispatchQueue.main.async { self.turn(true, minutes: mins) } // после закрытия меню (может спросить пароль)
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleFromMenu() { turn(!on) }

    // MARK: - Права

    /// Одно системное окно с паролем → правило sudo только для нужных команд pmset.
    func installSudoRule() -> Bool {
        let tmp = NSTemporaryDirectory() + "lidawake.sudoers"
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: " + sudoCmds.joined(separator: ", ") + "\n"
        guard (try? rule.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let cmd = "/usr/sbin/visudo -cf '\(tmp)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' /etc/sudoers.d/lidawake"
        // osascript отдельным процессом: AppleScript-фреймворки не грузятся в память приложения.
        let prompt = t("LidAwake wants to manage sleep and Low Power Mode on this Mac.",
                       "LidAwake: разрешить управлять сном и энергосбережением Mac")
        let ok = run("/usr/bin/osascript", ["-e", "do shell script \"\(cmd)\" with administrator privileges " +
                                                  "with prompt \"\(prompt)\""]) == 0
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
        b.setAccessibilityLabel(on ? t("LidAwake: on, Mac won't sleep", "LidAwake: включено, Mac не спит")
                                   : t("LidAwake: off", "LidAwake: выключено"))
        b.toolTip = !on ? "LidAwake: OFF"
            : offAt.map { let at = clock.string(from: $0); return t("LidAwake: awake until \(at)", "LidAwake: не спит до \(at)") }
            ?? t("LidAwake: ON — Mac won't sleep", "LidAwake: ON — Mac не спит")
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
