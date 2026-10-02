// DefaultOutputGuard.swift — 預設輸出被切到沒有音量的裝置時提示＋一鍵切回音量來源（owner：系統）
//
// 規格：
//   * 預設輸出不是音量來源（HDMI／DP 沒有音量、「全部喇叭」、藍牙喇叭、iPhone…）時，音量鍵／選單列滑桿調不到
//     音量來源 → 所有喇叭的總音量等於鎖住。面板要顯示警告＋按鈕「切回 <音量來源>」。
//   * 不自動切換（使用者可能是故意的）；只有使用者按按鈕才切。
//   * 按鈕 → restore()：DefaultOutputDevice = 音量來源；DefaultSystemOutputDevice = 內建喇叭（系統提示音只從內建出，
//     和 SystemSoundsRouter 一致；沒有內建才用音量來源）。絕不改音量、靜音。
//   * 音量來源：engine 在跑 → engine.outputDetails 的 isVolumeSource；沒在跑（CLI）→ 用和 Engine 同一條規則
//     （ReconnectRules.desired）從目前裝置現算。
// 監聽：kAudioHardwarePropertyDefaultOutputDevice、kAudioHardwarePropertyDevices（音量來源被拔掉）。
//   事件在自己的序列 queue 上 evaluate（engine.outputDetails 可能等 engine queue，不能卡主執行緒），結果變了才在主執行緒 onChange。
//   預設輸出改變時 Reconnector 可能重建 engine（音量來源會跟著換），所以 0.3 s、1.5 s 後各再評估一次。
// 【第 C 輪 2026-09-29，Kang 同意】唯一的自動切換例外：macOS 在藍牙（重新）連上時會把系統預設輸出切到它（第 B 輪實測兩次）。
//   只對「本程式在出聲的藍牙（不在排除清單、沒關掉）出現後 10 秒內」發生的預設輸出變更自動切回音量來源
//   （BluetoothOutputRestorePolicy；「出現」以 Core Audio 全部藍牙輸出判斷，含排除清單；同一次連上最多 3 次），
//   log＋面板記一筆（onAutoRestore）；之後使用者手動切到藍牙 → 尊重，照舊只警告。面板開關 Config.restoreDefaultOutputOnBluetoothConnect（預設開）。
//   只改預設輸出（＋系統提示音輸出回內建，同按鈕），絕不改音量、靜音。
import CoreAudio
import Foundation

struct OutputWarning: Equatable {
    let defaultOutputName: String
    let volumeSourceName: String
    let volumeSourceUID: String
    let message: String
}

final class DefaultOutputGuard {
    private let engine: Engine
    /// 警告出現／消失時呼叫（主執行緒）
    var onChange: ((OutputWarning?) -> Void)?
    /// 最近一次 evaluate 的結果（面板讀；主執行緒更新）
    private(set) var currentWarning: OutputWarning?
    var log: (String) -> Void = { AppLog.line($0) }

    private let queue = DispatchQueue(label: "In_Unison42.outputGuard", qos: .utility)
    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var lastPosted: OutputWarning??   // nil = 還沒送過
    /// 【第 C 輪】藍牙連上 10 秒內 macOS 搶預設輸出 → 自動切回（面板開關；主執行緒寫、guard queue 讀）
    let autoRestoreEnabled = LockedValue(true)
    /// 自動切回（或尊重）時呼叫（主執行緒）：(訊息, 是否真的切回)
    var onAutoRestore: ((String, Bool) -> Void)?
    /// 只在 queue 上用
    private var btPolicy = BluetoothOutputRestorePolicy()
    private var lastDefaultUID: String?

    init(engine: Engine) { self.engine = engine }

    /// 監聽預設輸出變更；先 evaluate 一次（主執行緒呼叫）
    func start() {
        guard listeners.isEmpty else { return }
        for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            let isDefault = sel == kAudioHardwarePropertyDefaultOutputDevice
            let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                if isDefault { self.defaultOutputChangedLocked() } else { self.devicesChangedLocked() }
                self.scheduleEvaluate()
            }
            var a = CA.addr(sel)
            if AudioObjectAddPropertyListenerBlock(CA.system, &a, queue, l) == noErr {
                listeners.append((sel, l))
            } else {
                log("⚠ 預設輸出監聽失敗（selector \(CA.fourCC(sel))）")
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.btPolicy.bluetoothOutputsChanged(Self.allBluetoothOutputUIDs(), now: Date())   // 啟動時已連著的不算「剛連上」
            self.lastDefaultUID = Devices.defaultOutput()?.uid
            self.evaluateAndPost()
        }
    }

    /// 裝置清單變了（queue 上）：記下剛出現的藍牙輸出
    private func devicesChangedLocked() {
        btPolicy.bluetoothOutputsChanged(Self.allBluetoothOutputUIDs(), now: Date())
    }

    /// 【第 C 輪審查】所有活著的藍牙輸出（含排除清單裡的）：「剛連上」要以 Core Audio 的完整清單判斷，
    /// 不然早就連著、但被排除的藍牙（AirPods…）被手動選成預設輸出時會被當成剛連上
    static func allBluetoothOutputUIDs() -> Set<String> {
        Set(Devices.all().filter { $0.hasOutput && $0.isAlive && $0.kind.isBluetooth }.map(\.uid))
    }

    /// 本程式在出聲的藍牙（不在排除清單、設定裡沒被關掉）：只有這種才自動切回
    private func isManagedBluetooth(_ d: AudioDevice) -> Bool {
        !Devices.isExcluded(d) && engine.config.device(d.uid).enabled
    }

    /// 預設輸出變了（queue 上）：剛連上 10 秒內的藍牙搶走 → 切回音量來源
    private func defaultOutputChangedLocked() {
        guard let def = Devices.defaultOutput() else { return }
        guard def.uid != lastDefaultUID else { return }
        lastDefaultUID = def.uid
        let decision = btPolicy.defaultOutputChanged(to: def.uid, isBluetooth: def.kind.isBluetooth, managed: isManagedBluetooth(def),
                                                    enabled: autoRestoreEnabled.value, now: Date())
        switch decision {
        case .none:
            return
        case .respect(_, let why):
            let msg = "預設輸出切到藍牙「\(def.name)」：不自動切回（\(why)），照舊提示"
            log(msg)
            let cb = onAutoRestore
            DispatchQueue.main.async { cb?(msg, false) }
        case .restore(_, let dt):
            let ok = Self.restore(engine: engine, log: log)
            let src = Self.volumeSource(engine: engine)?.name ?? "音量來源"
            let msg = ok ? String(format: "藍牙「%@」連上後 %.1f 秒 macOS 把預設輸出切到它 → 已自動切回「%@」（只改預設輸出，不動音量）", def.name, dt, src)
                         : "藍牙「\(def.name)」連上後 macOS 把預設輸出切到它 → 自動切回「\(src)」失敗（面板有「切回」按鈕）"
            log(msg)
            lastDefaultUID = Devices.defaultOutput()?.uid
            let cb = onAutoRestore
            DispatchQueue.main.async { cb?(msg, ok) }
        }
    }

    /// 移除 listener
    func stop() {
        for (sel, l) in listeners {
            var a = CA.addr(sel)
            AudioObjectRemovePropertyListenerBlock(CA.system, &a, queue, l)
        }
        listeners = []
    }

    private func scheduleEvaluate() {
        evaluateAndPost()
        for d in [0.3, 1.5] {
            queue.asyncAfter(deadline: .now() + d) { [weak self] in self?.evaluateAndPost() }
        }
    }

    /// 在 queue 上：評估，和上次不同才回主執行緒通知
    private func evaluateAndPost() {
        let w = evaluate()
        let prev = lastPosted
        if let last = prev, last == w { return }
        lastPosted = .some(w)
        if let w { log(w.message) } else if prev != nil { log("預設輸出與音量來源一致") }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentWarning = w
            self.onChange?(w)
        }
    }

    /// 純判斷：預設輸出 ≠ 音量來源 → 警告；沒問題 → nil
    func evaluate() -> OutputWarning? { Self.evaluate(engine: engine) }

    /// 同上（任何非即時執行緒可呼叫；AppState 在背景 queue 用它）。engine 沒在跑 → 照目前裝置現算音量來源
    static func evaluate(engine: Engine?) -> OutputWarning? {
        guard let src = volumeSource(engine: engine) else { return nil }
        guard let def = Devices.defaultOutput() else { return nil }
        guard let msg = ReconnectRules.volumeKeyWarning(defaultOutput: Devices.rcInfo(def),
                                                        volumeSourceName: src.name, volumeSourceUID: src.uid) else { return nil }
        return OutputWarning(defaultOutputName: def.name, volumeSourceName: src.name, volumeSourceUID: src.uid, message: msg)
    }

    /// 音量來源（uid, name）：engine 在跑用它的；否則照 ReconnectRules.desired 現算（和 Engine.chooseVolumeSource 同規則）
    static func volumeSource(engine: Engine?) -> (uid: String, name: String)? {
        if let e = engine, let s = e.outputDetails.first(where: \.isVolumeSource) { return (s.uid, s.name) }
        let phys = Devices.physicalOutputs().map(Devices.rcInfo)
        let sig = ReconnectRules.desired(physical: phys, defaultOutput: Devices.defaultOutput().map(Devices.rcInfo))
        guard let first = sig.entries.first else { return nil }
        return (first.uid, first.name)
    }

    /// 要做什麼（純判斷，dry-run 與 CLI 用）
    struct RestorePlan: CustomStringConvertible {
        let output: AudioDevice?          // nil = 已經是音量來源，不用動
        let systemOutput: AudioDevice?    // nil = 不用動
        let volumeSourceName: String
        var isNoop: Bool { output == nil && systemOutput == nil }
        var description: String {
            "預設輸出 → \(output?.name ?? "（不變）")；系統提示音輸出 → \(systemOutput?.name ?? "（不變）")（音量來源 \(volumeSourceName)）"
        }
    }

    static func restorePlan(engine: Engine?) -> RestorePlan? {
        guard let src = volumeSource(engine: engine), let dev = Devices.device(uid: src.uid) else { return nil }
        let out = Devices.defaultOutput()?.uid == dev.uid ? nil : dev
        let sysTarget = Devices.builtInOutput() ?? dev
        let sys = Devices.defaultSystemOutput()?.uid == sysTarget.uid ? nil : sysTarget
        return RestorePlan(output: out, systemOutput: sys, volumeSourceName: src.name)
    }

    /// 把預設輸出設回音量來源、系統提示音輸出設回內建（不動音量、靜音）。回傳是否成功（已經正確也算成功）
    @discardableResult
    static func restore(engine: Engine?, log: (String) -> Void = { print($0) }) -> Bool {
        guard let p = restorePlan(engine: engine) else { log("✗ 找不到音量來源裝置"); return false }
        if p.isNoop { return true }
        var ok = true
        if let d = p.output {
            let st = CA.set(CA.system, kAudioHardwarePropertyDefaultOutputDevice, d.id)
            ok = ok && st == noErr
            log(st == noErr ? "預設輸出 → \(d.name)" : "✗ 預設輸出設成 \(d.name) 失敗 status=\(st)")
        }
        if let d = p.systemOutput {
            let st = CA.set(CA.system, kAudioHardwarePropertyDefaultSystemOutputDevice, d.id)
            ok = ok && st == noErr
            log(st == noErr ? "系統提示音輸出 → \(d.name)" : "✗ 系統提示音輸出設成 \(d.name) 失敗 status=\(st)")
        }
        return ok
    }

    /// 面板按鈕：切回音量來源。在自己的 queue 上做（engine.outputDetails 可能等 engine queue——重建中、
    /// 第一次等授權對話框時會很久——不能卡主執行緒）；做完 completion（主執行緒）帶是否成功，並重新評估警告
    func restore(completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let ok = Self.restore(engine: self.engine, log: self.log)
            self.scheduleEvaluate()
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    /// AppState.switchDefaultOutputToVolumeSource 呼叫：非同步送出，回傳 true = 已排入（結果看 onChange／log）
    @discardableResult
    func switchBackToVolumeSource() -> Bool { restore(); return true }
}

/// `In_Unison42 output-guard [check|switch --dry-run|switch --yes]`
///   check（預設）：印出目前預設輸出是否該警告（不改任何設定）
///   switch --dry-run：印出 restore 會做什麼（不改）
///   switch --yes：真的切（先記 SystemAudioSnapshot、切換、驗證；--keep 不還原，否則 3 秒後還原原值）
func cmdOutputGuard(_ args: [String]) -> Int32 {
    let sub = args.first ?? "check"
    let rest = Array(args.dropFirst())
    switch sub {
    case "check":
        print("預設輸出：\(Devices.defaultOutput().map(\.description) ?? "?")")
        print("系統提示音輸出：\(Devices.defaultSystemOutput().map(\.description) ?? "?")")
        if let s = DefaultOutputGuard.volumeSource(engine: nil) { print("音量來源（現算）：\(s.name) [\(s.uid)]") }
        if let w = DefaultOutputGuard.evaluate(engine: nil) {
            print(w.message)
        } else {
            print("✓ 預設輸出就是音量來源，不需要警告")
        }
        if let p = DefaultOutputGuard.restorePlan(engine: nil) { print("restore() 會做：\(p)") }
        return 0
    case "switch":
        guard let p = DefaultOutputGuard.restorePlan(engine: nil) else { print("✗ 找不到音量來源"); return 1 }
        print("restore() 會做：\(p)")
        if rest.contains("--dry-run") || !rest.contains("--yes") {
            if !rest.contains("--dry-run") { print("（沒有 --yes：只印出，不切換）") }
            return 0
        }
        let snap = SystemAudioSnapshot.capture()
        print("原值：\(snap)")
        let ok = DefaultOutputGuard.restore(engine: nil)
        let after = SystemAudioSnapshot.capture()
        // 讓 snap.restore() 知道哪些是我們切的（使用者 3 秒內自己切走就不還原）
        if after.defaultOutputUID != snap.defaultOutputUID { snap.noteSetDefaultOutput(after.defaultOutputUID) }
        if after.defaultSystemOutputUID != snap.defaultSystemOutputUID { snap.noteSetSystemOutput(after.defaultSystemOutputUID) }
        print("切換後：\(after)")
        let volOK = (snap.volumeScalar == nil) || after.volumeScalar == nil || (after.volumeScalar! <= snap.volumeScalar! + 0.001)
        print(volOK ? "✓ 音量沒有被調高" : "✗ 音量變高了")
        let warnGone = DefaultOutputGuard.evaluate(engine: nil) == nil
        print(warnGone ? "✓ 警告已消失" : "✗ 警告仍在")
        if !rest.contains("--keep") {
            Thread.sleep(forTimeInterval: 3)
            snap.restore()
            print("已還原：\(SystemAudioSnapshot.capture())")
        }
        return ok && volOK && warnGone ? 0 : 1
    case "set":
        // 測試用：把預設輸出（只有「預設輸出」，不動系統提示音輸出、不動音量）切到指定裝置，用來觸發警告
        guard let q = rest.first, !q.hasPrefix("-") else { print("用法：In_Unison42 output-guard set <uid|名稱子字串> --yes"); return 2 }
        let outs = Devices.all().filter { $0.hasOutput && !Devices.isExcluded($0) }
        let hits = outs.filter { $0.uid == q } + outs.filter { $0.uid != q && $0.name.lowercased().contains(q.lowercased()) }
        guard hits.count == 1, let d = hits.first else { print("✗ 找不到唯一的輸出裝置：\(q)（符合 \(hits.map(\.name))）"); return 1 }
        guard rest.contains("--yes") else { print("會把預設輸出切到「\(d.name)」（加 --yes 才執行）"); return 0 }
        let before = SystemAudioSnapshot.capture()
        print("原值：\(before)")
        let ok = Devices.setDefaultOutput(d.id, alsoSystemOutput: false)
        let after = SystemAudioSnapshot.capture()
        print("\(ok ? "✓" : "✗") 預設輸出 → \(d.name)；目前：\(after)")
        return ok ? 0 : 1
    default:
        print("用法：In_Unison42 output-guard [check | switch --dry-run | switch --yes [--keep] | set <uid|名稱> --yes]")
        return 2
    }
}
