import Foundation

// Демо сирены LidAwake: та же сирена, что играет защита при перегреве с закрытой крышкой.
//   ./demo/siren.sh         — ждёт закрытия крышки, играет, пока крышка закрыта
//   ./demo/siren.sh --now   — играет сразу

setvbuf(stdout, nil, _IOLBF, 0)
let now = CommandLine.arguments.contains("--now")
let lid = Lid(), haptic = Haptic()
let pulses = 10

if !now {
    if !sleepDisabled() {
        print("⚠️  Mac уснёт при закрытии крышки. Включите LidAwake (полная кружка) и запустите снова.")
        exit(1)
    }
    print("☕ Закройте крышку — сирена начнётся через секунду. Откройте — остановится.")
    while !lid.isClosed { usleep(100_000) }
    print("🔒 Крышка закрыта")
    sleep(1)
}

for i in 0..<pulses {
    if !now && !lid.isClosed { print("🔓 Крышка открыта — стоп"); break }
    let ms = 200 + 300 * Double(i) / Double(pulses - 1)
    print("🔊 \(i + 1)/\(pulses)  20→600 Гц, \(Int(ms)) мс")
    haptic.buzz(ms: ms)
    Thread.sleep(forTimeInterval: 1)
}
haptic.close()
Thread.sleep(forTimeInterval: 0.2)
print("✅ Готово")

func sleepDisabled() -> Bool {
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
