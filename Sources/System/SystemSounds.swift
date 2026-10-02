// SystemSounds.swift — 系統提示音只從內建喇叭出（owner：系統）
//
// 規格：系統提示音（錯誤音、通知音、音量鍵回饋音…）不被 tap 靜音、不送到其他喇叭，只從內建喇叭出。
//
// 查證（2026-09-28，macOS 27 / Darwin 27.0.0，Mac mini M4；只讀、不出聲）：
//   1. 播放行程 = /usr/sbin/systemsoundserverd（root，LaunchDaemon com.apple.audio.systemsoundserverd，
//      MachService com.apple.audio.SystemSoundServer-OSX）。
//      * `log show --predicate 'process == "systemsoundserverd"'`：三天內 157 次 "Incoming Request"，客戶端是
//        NotificationCenter(124)、Finder(15)、screencapture(5)、UserNotificationCenter(2)、System Settings(2)、Notes(2)、
//        ControlCenter(2)、Safari、loginwindow、BambuStudio → 通知音、Finder 丟垃圾桶音、截圖快門音、alert/NSBeep 都走它。
//        NotificationCenter／usernoted 本身沒有 Core Audio process object（只透過 XPC 叫 systemsoundserverd 播）。
//      * 同一段 log："setPlayState Started Output {BuiltInSpeakerDevice, …}" 119 次、{<藍牙 MAC>:output}（藍牙）3 次、
//        {使用者自建的多重輸出裝置} 1 次 → 它照「系統（提示音）輸出」出聲。
//      * coreaudiod log：`HALS_Client::AddMuter: Process systemsoundserverd (42464) muted by In_Unison42-tap (43035)`
//        → 目前的全域 tap 確實把它靜音（所以提示音會被送進節目音、從所有喇叭出）。排除後這行不該再出現（驗證方法）。
//   2. Core Audio process object：kAudioProcessPropertyBundleID = "systemsoundserverd"（不是 com.apple.…），
//      proc_pidpath = /usr/sbin/systemsoundserverd。兩個都比對。
//   3. **它是按需啟動、閒置就被 jetsam 收掉**（launchctl print：runs = 25、last exit reason = JETSAM_REASON_MEMORY_IDLE_EXIT；
//      log 三天內出現 11 個不同 pid）→ process object 常常換。所以監聽 kAudioHardwarePropertyProcessObjectList，變了就重設排除清單。
//      已知競賽：它剛被叫起來的第一個聲音，在我們更新排除清單之前可能已被 tap 靜音／送進節目音（未實測有多長）。
//      根治：macOS 26+ CATapDescription.bundleIDs＋processRestoreEnabled 可以用 bundle id 排除、行程重啟自動套用
//      → 已實作（Engine.setExtraExcludedBundleIDs，start 時設 SystemSoundsRouter.bundleIDs）；process object 排除仍保留。
//   4. launchd plist 有 feature flag：`CoreAudioServices/sss_in_audiomxd` 開啟時 SystemSoundServer 改由 audiomxd 提供。
//      本機 /System/Library/FeatureFlags/Domain/CoreAudioServices.plist 沒有這個 key（＝關閉），實際也是 systemsoundserverd 在跑。
//      未來版本若打開，提示音會變成 audiomxd 播放：本檔會在 log 提示「找不到 systemsoundserverd」，不會自動排除 audiomxd
//      （audiomxd 還負責其他路由，排除它的影響未查證）。
//
// 做法：
//   1. 系統「提示音」輸出裝置（kAudioHardwarePropertyDefaultSystemOutputDevice）設成內建喇叭；start 前記原值，stop 時還原
//      （只在目前值仍是我們設的時候還原；絕不動音量／靜音）。
//   2. systemsoundserverd 的 process object → engine.setExtraExcludedProcesses：不被 tap 靜音、不進節目音 → 只從系統輸出（內建）出。
//   3. 監聽 kAudioHardwarePropertyProcessObjectList：變了就重設（在自己的序列 queue 上，不卡主執行緒）。
//   4. 監聽 kAudioHardwarePropertyDefaultSystemOutputDevice：系統「跟隨預設輸出」把它帶到別台（新值 == 預設輸出）時拉回內建；
//      使用者在系統設定明確選了別台（新值 ≠ 預設輸出）就尊重，只記 log。
import CoreAudio
import Darwin
import Foundation

struct SoundProcess: Equatable, CustomStringConvertible {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let path: String?
    let isRunningOutput: Bool
    var description: String {
        "object=\(object) pid=\(pid) bundle=\(bundleID ?? "-") runningOutput=\(isRunningOutput) \(path ?? "")"
    }
}

final class SystemSoundsRouter {
    /// Core Audio process object 的 bundle id（實測 macOS 27）；給 Engine 用 CATapDescription.bundleIDs 排除時用
    static let bundleIDs = ["systemsoundserverd"]
    static let executablePath = "/usr/sbin/systemsoundserverd"

    private let engine: Engine
    /// start 前的系統提示音輸出 UID（stop 時還原）
    private(set) var originalSystemOutputUID: String?
    /// 我們設定的系統提示音輸出 UID（stop 時只在目前仍是這個才還原）
    private(set) var appliedSystemOutputUID: String?
    private(set) var excluded: [AudioObjectID] = []
    var log: (String) -> Void = { AppLog.line($0) }

    private let queue = DispatchQueue(label: "In_Unison42.systemSounds", qos: .utility)
    private var procListener: AudioObjectPropertyListenerBlock?
    private var sysOutListener: AudioObjectPropertyListenerBlock?
    private var started = false

    init(engine: Engine) { self.engine = engine }

    /// 設定系統提示音輸出 = 內建、排除系統提示音行程、監聽 process list 與系統輸出（主執行緒呼叫，實際工作在自己的 queue）
    func start() {
        guard !started else { return }
        started = true
        queue.async { [self] in
            routeSystemOutputToBuiltIn(initial: true)
            // macOS 26+：以 bundle id 排除＋processRestoreEnabled（systemsoundserverd 重啟換 pid 也自動排除，沒有空窗）；
            // process object 排除照做（舊系統、以及保險）
            if engine.setExtraExcludedBundleIDs(Self.bundleIDs) {
                log("系統提示音：tap 以 bundle id 排除 \(Self.bundleIDs)（processRestoreEnabled）")
            } else {
                log("系統提示音：這版 macOS 沒有 CATapDescription.bundleIDs，只能用 process object 排除（重啟後第一聲可能被 tap 吃掉）")
            }
            refreshExcluded(reason: "啟動")
        }
        let pl: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshExcluded(reason: "行程清單變更") }
        let sl: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.systemOutputChanged() }
        var a1 = CA.addr(kAudioHardwarePropertyProcessObjectList)
        var a2 = CA.addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
        if AudioObjectAddPropertyListenerBlock(CA.system, &a1, queue, pl) == noErr { procListener = pl }
        if AudioObjectAddPropertyListenerBlock(CA.system, &a2, queue, sl) == noErr { sysOutListener = sl }
    }

    /// 還原系統提示音輸出、engine.setExtraExcludedProcesses([])、移除 listener
    func stop() {
        guard started else { return }
        started = false
        if let l = procListener {
            var a = CA.addr(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(CA.system, &a, queue, l)
        }
        if let l = sysOutListener {
            var a = CA.addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectRemovePropertyListenerBlock(CA.system, &a, queue, l)
        }
        procListener = nil; sysOutListener = nil
        queue.sync {
            if !excluded.isEmpty {
                engine.setExtraExcludedProcesses([])
                excluded = []
            }
            engine.setExtraExcludedBundleIDs([])
            restoreSystemOutput()
        }
    }

    // MARK: 行程

    /// 所有 Core Audio process object（唯讀）
    static func allProcesses() -> [SoundProcess] {
        CA.ids(CA.system, kAudioHardwarePropertyProcessObjectList).map { obj in
            let pid = CA.get(obj, kAudioProcessPropertyPID, as: pid_t.self) ?? -1
            return SoundProcess(object: obj, pid: pid, bundleID: CA.string(obj, kAudioProcessPropertyBundleID),
                                path: pid > 0 ? processExecutablePath(pid) : nil,
                                isRunningOutput: (CA.u32(obj, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0)
        }
    }

    static func isSystemSoundProcess(_ p: SoundProcess) -> Bool {
        if let b = p.bundleID, bundleIDs.contains(where: { $0.caseInsensitiveCompare(b) == .orderedSame }) { return true }
        if p.path == executablePath { return true }
        return false
    }

    static func systemSoundProcesses() -> [SoundProcess] { allProcesses().filter(isSystemSoundProcess) }

    /// 有沒有別的程式正在輸出聲音（自己、系統提示音除外）。
    /// 10-02 實測：tap 的 IO 是 autostart —— 建好之後要等有被攔截的程式開始播，IOProc 才會第一次被呼叫（之後就一直跑）。
    /// 所以「IOProc 沒前進」＋「沒有程式在播」＝ 正常待命，不是停住（09-30 開機後 4.5 分鐘、校正後 20–35 秒都是這樣，當下沒在播）
    static func otherProgramPlaying() -> Bool {
        let me = getpid()
        return allProcesses().contains { $0.isRunningOutput && $0.pid != me && !isSystemSoundProcess($0) }
    }

    /// 播放系統提示音的行程的 process object（找不到回 []；systemsoundserverd 閒置時會被收掉，這時也是 []）
    static func systemSoundProcessObjects() -> [AudioObjectID] { systemSoundProcesses().map(\.object).sorted() }

    private func refreshExcluded(reason: String) {
        guard started else { return }
        let objs = Self.systemSoundProcessObjects()
        guard objs != excluded else { return }
        excluded = objs
        let ok = engine.setExtraExcludedProcesses(objs)
        log(objs.isEmpty
            ? "系統提示音：systemsoundserverd 目前沒在跑（閒置被收掉；下次播放時會再出現）（\(reason)）"
            : "系統提示音：tap 排除 systemsoundserverd process object \(objs)（\(reason)）\(ok ? "" : " ⚠ engine 回報未生效")")
    }

    // MARK: 系統提示音輸出

    private func routeSystemOutputToBuiltIn(initial: Bool) {
        guard let builtIn = Devices.builtInOutput() else {
            log("⚠ 系統提示音：找不到內建喇叭，系統提示音輸出維持不變"); return
        }
        let cur = Devices.defaultSystemOutput()
        if initial { originalSystemOutputUID = cur?.uid }
        if cur?.uid == builtIn.uid { appliedSystemOutputUID = builtIn.uid; return }
        if CA.set(CA.system, kAudioHardwarePropertyDefaultSystemOutputDevice, builtIn.id) == noErr {
            appliedSystemOutputUID = builtIn.uid
            log("系統提示音輸出：\(cur?.name ?? "?") → \(builtIn.name)")
        } else {
            log("⚠ 系統提示音輸出設成 \(builtIn.name) 失敗")
        }
    }

    private func systemOutputChanged() {
        guard started, let applied = appliedSystemOutputUID else { return }
        let sys = Devices.defaultSystemOutput()
        guard let sys, sys.uid != applied else { return }
        if Devices.defaultOutput()?.uid == sys.uid {
            // macOS「跟隨預設輸出」把提示音帶走了 → 拉回內建
            log("系統提示音輸出跟著預設輸出變成 \(sys.name)，拉回內建")
            routeSystemOutputToBuiltIn(initial: false)
        } else {
            log("系統提示音輸出被改成 \(sys.name)（使用者選的，保留）")
            appliedSystemOutputUID = nil
        }
    }

    private func restoreSystemOutput() {
        defer { appliedSystemOutputUID = nil }
        guard let orig = originalSystemOutputUID, let applied = appliedSystemOutputUID, orig != applied else { return }
        guard Devices.defaultSystemOutput()?.uid == applied, let d = Devices.device(uid: orig) else { return }
        if CA.set(CA.system, kAudioHardwarePropertyDefaultSystemOutputDevice, d.id) == noErr {
            log("系統提示音輸出還原成 \(d.name)")
        }
    }
}

/// `In_Unison42 system-sounds [list|all]`：列出找到的系統提示音行程（process object、pid、bundle id），不出聲、不改設定
func cmdSystemSounds(_ args: [String]) -> Int32 {
    let sub = args.first ?? "list"
    switch sub {
    case "list", "all":
        let all = SystemSoundsRouter.allProcesses()
        if sub == "all" {
            print("Core Audio process object（\(all.count) 個）：")
            for p in all { print("  \(SystemSoundsRouter.isSystemSoundProcess(p) ? "★" : " ") \(p)") }
        }
        let found = all.filter(SystemSoundsRouter.isSystemSoundProcess)
        print("系統提示音輸出：\(Devices.defaultSystemOutput().map(\.description) ?? "?")")
        print("預設輸出：\(Devices.defaultOutput().map(\.description) ?? "?")")
        print("內建喇叭：\(Devices.builtInOutput().map(\.description) ?? "找不到")")
        if found.isEmpty {
            print("systemsoundserverd 目前沒有 process object（閒置時會被 jetsam 收掉，下次播放提示音時才會再啟動）")
        } else {
            print("系統提示音行程（tap 要排除）：")
            for p in found { print("  \(p)") }
        }
        print("systemSoundProcessObjects() = \(SystemSoundsRouter.systemSoundProcessObjects())")
        return 0
    default:
        print("用法：In_Unison42 system-sounds [list|all]")
        return 2
    }
}
