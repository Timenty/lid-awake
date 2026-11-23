import AppKit
import IOKit

// Защита: крышка (событие IOKit), яркость встроенного экрана (DisplayServices),
// гул тачпадом (MultitouchSupport, как в github.com/os6/nospeaker).
// Приватные фреймворки грузятся через dlopen только при первом использовании.

@discardableResult
func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - Крышка

final class Lid {
    private let root = IOServiceGetMatchingService(0, IOServiceMatching("IOPMrootDomain"))
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    var onChange: (() -> Void)?

    var isClosed: Bool {
        (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }

    /// Подписка на kIOPMMessageClamshellStateChange — без опроса.
    func start() {
        port = IONotificationPortCreate(0)
        IONotificationPortSetDispatchQueue(port, .main)
        IOServiceAddInterestNotification(port, root, "IOGeneralInterest", { refcon, _, type, _ in
            guard type == 0xE003_4100, let refcon else { return } // iokit_family_msg(sub_iokit_powermanagement, 0x100)
            Unmanaged<Lid>.fromOpaque(refcon).takeUnretainedValue().onChange?()
        }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
    }
}

// MARK: - Яркость встроенного экрана

enum Brightness {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn = lib.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let setFn = lib.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }

    static func builtin() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get(_ id: CGDirectDisplayID) -> Float? {
        var v: Float = 0
        return getFn?(id, &v) == 0 ? v : nil
    }

    @discardableResult
    static func set(_ id: CGDirectDisplayID, _ v: Float) -> Bool { setFn?(id, v) == 0 }
}

// MARK: - Гул тачпадом

final class Haptic {
    private typealias DevList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias DevID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias DevBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias ActCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias ActOpenClose = @convention(c) (CFTypeRef) -> Int32
    private typealias ShapeCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
    private typealias ShapePlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

    private let q = DispatchQueue(label: "lidawake.haptic")
    private var actuator: CFTypeRef?
    private var shapeCreate: ShapeCreate?
    private var shapePlay: ShapePlay?
    private var closeFn: ActOpenClose?

    private func open() -> Bool {
        if actuator != nil { return true }
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        else { return false }
        func sym<T>(_ n: String, _: T.Type) -> T? { dlsym(lib, n).map { unsafeBitCast($0, to: T.self) } }
        guard let list = sym("MTDeviceCreateList", DevList.self), let devID = sym("MTDeviceGetDeviceID", DevID.self),
              let create = sym("MTActuatorCreateFromDeviceID", ActCreate.self),
              let openFn = sym("MTActuatorOpen", ActOpenClose.self) else { return false }
        let builtIn = sym("MTDeviceIsBuiltIn", DevBuiltIn.self)
        shapeCreate = sym("MTActuationCreateFromDictionary", ShapeCreate.self)
        shapePlay = sym("MTActuationActuate", ShapePlay.self)
        closeFn = sym("MTActuatorClose", ActOpenClose.self)
        guard shapeCreate != nil, shapePlay != nil, let arr = list()?.takeRetainedValue() else { return false }
        let devs = (0..<CFArrayGetCount(arr)).compactMap { CFArrayGetValueAtIndex(arr, $0).map(UnsafeMutableRawPointer.init(mutating:)) }
            .sorted { (builtIn?($0) ?? false) && !(builtIn?($1) ?? false) }
        for d in devs {
            var id: UInt64 = 0
            guard devID(d, &id) == 0, let ref = create(id)?.takeRetainedValue(), openFn(ref) == 0 else { continue }
            actuator = ref
            return true
        }
        return false
    }

    /// Нарастающий гул (сирена): синус от `from` до `to` Гц за `ms`. Подъём (в октавах) ∝ t²:
    /// первая половина — нижняя четверть диапазона, вторая — разгон к верху.
    /// Мотор перезапускается кусками ~5 мс (на низах — один период), в каждом целое число периодов:
    /// частота обновляется почти каждый период, стыки без щелчков, драйвер не захлёбывается.
    func buzz(ms: Double = 200, from: Double = 20, to: Double = 600) {
        q.async { [self] in
            guard open(), let actuator, let shapeCreate, let shapePlay else { return }
            let motor = Unmanaged.passUnretained(actuator).toOpaque()
            let total = ms / 1000, start = DispatchTime.now().uptimeNanoseconds
            var t = 0.0
            while t < total {
                let p = t / total
                let hz = from * pow(to / from, p * p) // медленно на низах, разгон к концу
                let seg = max(1, (0.005 * hz).rounded()) / hz // сек
                let shape: [String: Any] = [
                    "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": seg * 1000],
                    "Tones": [["Type": "Sine", "Amplitude": 1.0, "DurationMS": seg * 1000, "DelayMS": 0.0,
                               "FrequencykHz": hz / 1000]],
                ]
                if let a = shapeCreate(shape as CFDictionary, 0) { _ = shapePlay(a, motor, 0, 1, 0) }
                t += seg
                let due = start + UInt64(t * 1e9), now = DispatchTime.now().uptimeNanoseconds
                if due > now { usleep(UInt32((due - now) / 1000)) } // без накопления задержки
            }
        }
    }

    func close() {
        q.async { [self] in
            if let actuator { _ = closeFn?(actuator) }
            actuator = nil
        }
    }
}
