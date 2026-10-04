// AutoCalibration.swift — 自動校正的狀態機（純邏輯，不碰 Core Audio／UI／子行程；AppState 驅動）
//
// Kang 2026-09-29 定案：
//   1. 新的輸出裝置接上（從未校正過、沒有 measuredLatencyMs）→ 使用者通知＋面板「3 秒後校正〈裝置名〉」倒數，可按取消
//      （取消 → 延後，面板留「需要校正」按鈕）；倒數結束自動跑 `calibrate --pulse --only <uid>`。
//      校正麥克風正被其他 app 占用（DeviceIsRunningSomewhere，且不是我們）→ 延後並提示；麥克風空下來後自動再倒數。
//   2. 已有延遲紀錄的**有線**裝置重新接上 → 直接用舊值出聲，不播測試音。
//      【第 B 輪 2026-09-29 Kang 定案】藍牙真的斷線重連（A2DP 串流重開，延遲可能差 35–61 ms）→ 比照 app 重開：
//      先不出聲（BluetoothOutManager.holdOnReconnect 在重新 start 前就 hold）、倒數 3 秒、`--only` 重校；通知沒授權 → needsConsent。
//      Config.recalibrateBluetoothOnReconnect = false 可退回舊政策（沿用舊值）。
//   3. 例外：app 重開（或登入啟動）後，已校正過的藍牙 → 同樣倒數 3 秒自動重校（只量藍牙：--only）；
//      校正完成前藍牙先不出聲（holds → Config.calibrationHolds → plan() 不出聲）。實測 app 重開後藍牙延遲會差 35 ms。
//   4. 同一時間最多一個校正；多台同時出現 → 排隊合併成一次 `--only a,b`。
//
// 實作上的判斷（文件 docs/API.md §12）：
//   * 「接上」＝上一次觀察不在、這一次在。第一次觀察（app 剛啟動）時已經在的未校正裝置不算接上：只列「需要校正」按鈕、不自動播測試音
//     （避免每次登入都對一台麥克風聽不到的裝置播測試音）。
//   * 「app 重開」＝藍牙在 app 啟動後 launchGrace（30 秒）內第一次出現（登入時藍牙常晚幾秒才連上）。之後才第一次出現的算「重新接上」→ 舊值。
//   * 自動校正取消的裝置不自動重試；【2026-10-04】失敗（沒量到）的 1／3／10 分鐘後各自動重試一次（不倒數），3 次都沒量到才只留「需要校正」。
//   * 參考喇叭（音量來源／內建）與使用者關掉的裝置不自動校正。
import Foundation

/// 觀察到的一台輸出（AppState 從 engine 輸出＋藍牙清單組）
struct AutoCalDevice: Equatable {
    let uid: String
    let name: String
    let isBluetooth: Bool
    /// 設定裡有 measuredLatencyMs
    let hasLatency: Bool
    let enabled: Bool
    /// 參考喇叭（音量來源／內建）：延遲定義為基準，不用量
    let isReference: Bool
}

/// 這次環境（AppState 每次 tick 量一次；只在需要時才讀 Core Audio）
struct AutoCalEnvironment: Equatable {
    /// 校正麥克風存在（resolveCalibrationMic）
    var micAvailable = true
    /// 校正麥克風正被別的 app 使用（kAudioDevicePropertyDeviceIsRunningSomewhere；我們平常不開麥克風）
    var micBusy = false
    var micName = "麥克風"
    /// 可以開始校正：engine 在跑、不是另一個實例、沒有其他校正在跑
    var canRun = true
    /// 使用者看得到倒數（面板開著，或通知權限是「允許」／「暫時允許」）。看不到就不自動倒數（2026-09-29 審查：
    /// 通知沒授權時選單列面板平常是關著的，3 秒後直接播測試音、開麥克風，使用者完全沒被告知）
    var userCanSee = true
}

enum AutoCalWhy: String, Equatable {
    case newDevice       // 從未校正過的裝置接上
    case appRelaunch     // app 重開後的藍牙（校正完成前不出聲）
    case manual          // 使用者按「需要校正」
    case reconnect       // 【第 B 輪】藍牙真的斷線重連（校正完成前不出聲）
    case monitor         // 【第 B 輪】背景監聽發現偏太多／量不到（只標記，不自動校正）
    case drift           // 【第 C 輪】藍牙漂移補償的短校正（空檔直接跑／連續播放太久才倒數）；失敗不留「需要校正」、不發完成通知
}

enum AutoCalDeferral: Equatable {
    case cancelled                 // 倒數中按取消、或校正中按停止
    case micBusy                   // 麥克風被別的 app 占用（空下來後自動再倒數）
    case noMic                     // 找不到校正麥克風（接上後自動再倒數）
    case failed(String)            // 校正沒量到它（聽不到、不穩）
    case notCalibratedAtLaunch     // app 啟動時就在、從未校正（不自動，只給按鈕）；也用於「關掉時接上、之後才打開」的未校正裝置
    case heldAwaitingCalibration   // 暫停出聲中（app 重開後的藍牙）被使用者關掉又打開：不自動播測試音，給按鈕
    case needsConsent              // 使用者看不到倒數（面板關著、通知沒授權）：面板打開或通知允許後自動再倒數
    case driftDetected(String)     // 【第 B 輪】背景監聽：偏移 > 10 ms 或多次量不到 → 需要重新校正（不自動校正，給按鈕）

    var text: String {
        switch self {
        case .cancelled: return "已取消自動校正"
        case .micBusy: return "麥克風正被其他 App 使用，空下來後自動校正"
        case .noMic: return "找不到校正麥克風，接上後自動校正"
        case .failed(let m): return m.isEmpty ? "自動校正沒有量到" : m
        case .notCalibratedAtLaunch: return "尚未校正"
        case .heldAwaitingCalibration: return "校正完成前先不出聲"
        case .needsConsent: return "通知沒有開啟：打開這個面板時才倒數校正"
        case .driftDetected(let m): return m.isEmpty ? "背景監聽發現落拍，需要重新校正" : m
        }
    }
    /// 條件解除後自動再倒數
    var retriesAutomatically: Bool { self == .micBusy || self == .noMic || self == .needsConsent }
}

struct AutoCalItem: Equatable {
    let uid: String
    var name: String
    var why: AutoCalWhy
}

enum AutoCalAction: Equatable {
    /// 發使用者通知＋面板開始倒數
    case countdownStarted(names: [String], seconds: Int)
    /// 延後（通知＋面板「需要校正」）
    case deferred(names: [String], reason: AutoCalDeferral)
    /// 啟動 `calibrate --pulse --only <uids 以逗號連接>`
    case startCalibration(uids: [String])
    /// 暫停出聲的藍牙清單變了（AppState 要把 Config.calibrationHolds 重新交給 engine）
    case holdsChanged(Set<String>)
    /// 自動校正結束（通知）
    case finished(ok: [String], failed: [String], cancelled: Bool)
    case log(String)
}

/// 面板要顯示的自動校正狀態（值型別）
struct AutoCalibrationStatus: Equatable {
    struct Pending: Equatable, Identifiable {
        let uid: String
        let name: String
        let message: String
        var id: String { uid }
    }
    /// 倒數中的裝置名稱（空 = 沒有倒數）
    var countdownNames: [String] = []
    /// 倒數剩幾秒（向上取整）
    var secondsLeft: Int = 0
    /// 倒數到了但還不能開始（引擎還沒好、別的校正在跑）
    var waitingMessage: String?
    /// 自動校正執行中的裝置名稱
    var runningNames: [String] = []
    /// 需要校正（面板留按鈕）
    var pending: [Pending] = []
    /// 校正完成前不出聲的藍牙名稱
    var heldNames: [String] = []

    var isEmpty: Bool { countdownNames.isEmpty && waitingMessage == nil && runningNames.isEmpty && pending.isEmpty && heldNames.isEmpty }
}

/// calibrate 子行程輸出裡「這次量到並寫入的 uid」那一行（ProgramPath.ppWriteLatencies 印）
let autoCalMeasuredPrefix = "@@measured "

/// 從子行程全部輸出找出量到的 uid
func parseMeasuredUIDs(_ lines: [String]) -> Set<String> {
    var s = Set<String>()
    for l in lines {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(autoCalMeasuredPrefix) else { continue }
        for u in t.dropFirst(autoCalMeasuredPrefix.count).split(separator: ",") where !u.isEmpty { s.insert(String(u)) }
    }
    return s
}

final class AutoCalibrator {
    static let countdownSeconds: TimeInterval = 3
    static let launchGrace: TimeInterval = 30

    enum Phase: Equatable {
        case idle
        case countdown(deadline: Date)
        /// 倒數到了、等 canRun
        case waiting
        /// 自動校正子行程在跑（batch 裡的裝置）
        case running
        /// 別人（面板「開始校正」、ctl）啟動的校正在跑；batch 留著，結束後再看
        case external
    }

    let startedAt: Date
    private(set) var phase: Phase = .idle
    /// 倒數／執行中的這一批
    private(set) var batch: [AutoCalItem] = []
    /// 執行中又冒出來的，下一批
    private(set) var queue: [AutoCalItem] = []
    /// 延後的（面板「需要校正」）：uid → (item, 原因)
    private(set) var deferred: [String: (item: AutoCalItem, reason: AutoCalDeferral)] = [:]
    /// 【2026-10-04】校正失敗（沒量到）後的自動重試：每台已重試幾次、下次什麼時候。量到／斷線／取消就清掉
    private(set) var failRetry: [String: (count: Int, at: Date)] = [:]
    /// 失敗後第 1、2、3 次重試的等待時間（之後不再自動，留「需要校正」按鈕）
    static let failRetryDelays: [TimeInterval] = [60, 180, 600]
    /// 校正完成前不出聲的藍牙
    private(set) var holds: Set<String> = []
    /// 上一次觀察到的裝置（nil = 還沒觀察過）
    private var present: [String: AutoCalDevice]?
    /// 這個 app 行程裡看過的 uid
    private var seenEver: Set<String> = []

    /// app 重開後的藍牙要不要先不出聲（預設 Config.holdBluetoothOnRelaunch；自測可以指定舊政策）
    let holdOnRelaunch: Bool
    init(startedAt: Date = Date(), holdOnRelaunch: Bool = Config.holdBluetoothOnRelaunch) {
        self.startedAt = startedAt
        self.holdOnRelaunch = holdOnRelaunch
    }

    var isBusy: Bool { phase == .running || phase == .external }

    /// 目前有沒有需要 AppState 量環境（麥克風）的狀態：倒數、等待、或有「麥克風空下來就重試」的延後項目
    var needsEnvironment: Bool {
        switch phase {
        case .countdown, .waiting: return true
        case .running, .external: return false
        case .idle: return deferred.values.contains { $0.reason.retriesAutomatically }
        }
    }

    // MARK: 輸入

    /// app 啟動、engine 開始之前：已校正的藍牙先暫停出聲（不等第一次觀察，避免 attach 後用舊值響一下）。
    /// 之後 observe 看到它們時會排進倒數
    func primeLaunchHolds(_ uids: [String]) {
        holds.formUnion(uids)
    }

    /// 一次完整的裝置觀察（AppState 完整刷新時、engine 有輸出時呼叫）
    func observe(_ devices: [AutoCalDevice], now: Date) -> [AutoCalAction] {
        var acts: [AutoCalAction] = []
        let byUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        let first = present == nil
        let prev = present ?? [:]
        let inGrace = now.timeIntervalSince(startedAt) < Self.launchGrace
        let holdsBefore = holds
        var toEnqueue: [AutoCalItem] = []

        for d in devices where prev[d.uid] == nil {
            defer { seenEver.insert(d.uid) }
            guard d.enabled, !d.isReference else { continue }
            let relaunch = inGrace && !seenEver.contains(d.uid)
            if d.isBluetooth && d.hasLatency && relaunch && !holdOnRelaunch && !holds.contains(d.uid) {
                // 【2026-10-04】app 重開後：沿用上次的延遲出聲，不倒數；有人在聽時由漂移補償的短校正量第一點
                acts.append(.log("自動校正：app 重新啟動後的藍牙「\(d.name)」→ 沿用上次的延遲出聲（有人在聽音樂時自動短校正）"))
            } else if d.isBluetooth && d.hasLatency && (relaunch || holds.contains(d.uid) || Config.recalibrateBluetoothOnReconnect) {
                // app 重開（或登入啟動）後第一次看到已校正的藍牙；暫停出聲中又重新接上；
                // 【第 B 輪】藍牙真的斷線重連（或啟動 30 秒後才第一次連上）→ 一樣先不出聲、倒數重校
                holds.insert(d.uid)
                // 已在這批／排隊；或 onFirstConnect／onReconnect 先到、已經倒數後延後（needsConsent…）→ 不重複排
                //（2026-09-29 實機：啟動時 onFirstConnect 先排、延後，接著第一次觀察又排一次 → log／通知重複）
                if batch.contains(where: { $0.uid == d.uid }) || queue.contains(where: { $0.uid == d.uid }) || deferred[d.uid] != nil { continue }
                toEnqueue.append(AutoCalItem(uid: d.uid, name: d.name, why: relaunch ? .appRelaunch : .reconnect))
                acts.append(.log(relaunch ? "自動校正：app 重新啟動後的藍牙「\(d.name)」→ 校正完成前不出聲、倒數重新校正"
                                          : "自動校正：藍牙「\(d.name)」重新連線 → 校正完成前不出聲、倒數重新校正（串流重開後延遲可能改變）"))
            } else if !d.hasLatency {
                if first {
                    deferred[d.uid] = (AutoCalItem(uid: d.uid, name: d.name, why: .newDevice), .notCalibratedAtLaunch)
                    acts.append(.log("自動校正：啟動時「\(d.name)」尚未校正（不自動播測試音，面板留「需要校正」）"))
                } else {
                    toEnqueue.append(AutoCalItem(uid: d.uid, name: d.name, why: .newDevice))
                    acts.append(.log("自動校正：新裝置「\(d.name)」接上（從未校正）"))
                }
            } else if !first {
                acts.append(.log("自動校正：「\(d.name)」重新接上，沿用舊的延遲值（不播測試音）"))
            }
        }
        // 消失的裝置：從倒數／排隊／延後拿掉（holds 保留：它再接上時還是要先校正才出聲）
        for uid in prev.keys where byUID[uid] == nil {
            batch.removeAll { $0.uid == uid && !isBusy }
            queue.removeAll { $0.uid == uid }
            failRetry[uid] = nil
            if deferred.removeValue(forKey: uid) != nil { acts.append(.log("自動校正：「\(prev[uid]!.name)」已斷線，取消待校正")) }
        }
        // 名稱更新；使用者把裝置關掉 → 不再排它
        for (uid, d) in byUID where !d.enabled {
            if !isBusy { batch.removeAll { $0.uid == uid } }
            queue.removeAll { $0.uid == uid }
            deferred.removeValue(forKey: uid)
        }
        // 使用者把關掉的裝置又打開（一直都在，上面的「接上」不會觸發）：
        //   暫停出聲中的藍牙（holds）→ 放回「需要校正」（不然它永遠不出聲、面板也沒有按鈕；2026-09-29 審查）；
        //   關著時接上、從未校正的 → 「尚未校正」按鈕。都不自動播測試音（使用者剛按開關，不是剛接上）
        for (uid, d) in byUID where d.enabled && !d.isReference {
            guard let p = prev[uid], !p.enabled else { continue }
            guard !batch.contains(where: { $0.uid == uid }), !queue.contains(where: { $0.uid == uid }), deferred[uid] == nil else { continue }
            if holds.contains(uid) {
                deferred[uid] = (AutoCalItem(uid: uid, name: d.name, why: .appRelaunch), .heldAwaitingCalibration)
                acts.append(.log("自動校正：「\(d.name)」重新打開（暫停出聲中）→ 面板「需要校正」"))
            } else if !d.hasLatency {
                deferred[uid] = (AutoCalItem(uid: uid, name: d.name, why: .newDevice), .notCalibratedAtLaunch)
                acts.append(.log("自動校正：「\(d.name)」打開了但尚未校正 → 面板「需要校正」"))
            }
        }
        // 「需要校正」清單裡的新裝置，後來有了延遲值（外部校正、ctl reload-config 讀回好的設定檔）→ 拿掉，不再顯示「尚未校正」
        for (uid, d) in byUID where d.hasLatency {
            if let e = deferred[uid], e.item.why == .newDevice {
                deferred.removeValue(forKey: uid)
                acts.append(.log("自動校正：「\(d.name)」已經有延遲值，從「需要校正」拿掉"))
            }
        }
        present = byUID
        if case .countdown = phase, batch.isEmpty { phase = .idle }
        if phase == .waiting, batch.isEmpty { phase = .idle }
        acts += enqueue(toEnqueue, now: now)
        if holds != holdsBefore { acts.append(.holdsChanged(holds)) }
        return acts
    }

    /// 定時呼叫（倒數中 0.25 秒一次；平常跟著 AppState 每秒 tick）
    func tick(now: Date, env: AutoCalEnvironment) -> [AutoCalAction] {
        var acts: [AutoCalAction] = []
        switch phase {
        case .countdown(let deadline):
            if !env.userCanSee { return deferBatch(.needsConsent) }
            if let r = micProblem(env) { return deferBatch(r) }
            if now >= deadline { acts += startIfPossible(env) }
        case .waiting:
            if let r = micProblem(env) { return deferBatch(r) }
            acts += startIfPossible(env)
        case .idle:
            // 【2026-10-04】失敗的自動重試：時間到、麥克風可用 → 直接跑（不倒數）
            if micProblem(env) == nil {
                let due = deferred.values.filter { e in
                    if case .failed = e.reason, let r = failRetry[e.item.uid], r.at <= now, present?[e.item.uid] != nil { return true }
                    return false
                }.map(\.item)
                if !due.isEmpty {
                    for it in due { deferred.removeValue(forKey: it.uid) }
                    batch = due
                    phase = .waiting
                    acts.append(.log("自動校正：自動重試 \(names(due).joined(separator: "、"))（第 \(due.compactMap { failRetry[$0.uid]?.count }.max() ?? 1) 次，不倒數）"))
                    return acts
                }
            }
            // 麥克風空下來／接上了、使用者看得到倒數了 → 自動再倒數（取消的不自動重試；失敗的走上面的重試）
            if micProblem(env) == nil && env.userCanSee {
                let retry = deferred.values.filter { $0.reason.retriesAutomatically }.map(\.item)
                if !retry.isEmpty {
                    for it in retry { deferred.removeValue(forKey: it.uid) }
                    acts.append(.log("自動校正：麥克風可以用、使用者看得到倒數，重新倒數"))
                    acts += enqueue(retry, now: now)
                }
            }
        case .running, .external:
            break
        }
        return acts
    }

    /// 使用者在倒數中按取消（校正中的停止由 CalibrationRunner 處理，結束時 finished(cancelled: true)）
    func cancel() -> [AutoCalAction] {
        switch phase {
        case .countdown, .waiting:
            return deferBatch(.cancelled)
        default:
            return []
        }
    }

    /// 使用者按「需要校正」：延後的全部（或指定的 uid）立刻排進來，不倒數（仍會檢查麥克風）
    func requestNow(uids: [String]? = nil, now: Date) -> [AutoCalAction] {
        let pick = deferred.values.map(\.item).filter { uids == nil || uids!.contains($0.uid) }
            .sorted { $0.name < $1.name }
        guard !pick.isEmpty else { return [] }
        for it in pick { deferred.removeValue(forKey: it.uid) }
        var items = pick
        for i in items.indices where items[i].why != .appRelaunch { items[i].why = .manual }
        if isBusy {
            for it in items where !queue.contains(where: { $0.uid == it.uid }) { queue.append(it) }
            return [.log("自動校正：已排隊（目前有校正在跑）")]
        }
        for it in items where !batch.contains(where: { $0.uid == it.uid }) { batch.append(it) }
        phase = .waiting
        return [.log("自動校正：使用者要求立即校正 \(names(batch).joined(separator: "、"))")]
    }

    /// 【第 B 輪】藍牙真的斷線重連（BluetoothOutManager.onReconnect；裝置清單可能沒來得及看到它消失）：
    /// 量過延遲、啟用中 → 暫停出聲＋倒數 `--only` 重校（和 app 重開一樣；通知沒授權 → needsConsent）。已在這批／排隊就不重複
    func bluetoothReconnected(uid: String, name: String, hasLatency: Bool, enabled: Bool, now: Date) -> [AutoCalAction] {
        guard Config.recalibrateBluetoothOnReconnect, hasLatency, enabled else { return [] }
        return holdAndEnqueue(uid: uid, name: name, why: .reconnect, now: now)
    }

    /// 【2026-09-29 審查】這個 app 行程第一次連上某台藍牙（BluetoothOutManager.onFirstConnect；engine 已先 hold）：
    /// 啟動 launchGrace 內 = app 重開（appRelaunch）；之後 = 串流重開（同重連）。都是量過延遲、啟用中才暫停出聲＋倒數；
    /// 已經因為 app 重開排過（primeLaunchHolds／observe 先看到）就不重複
    func bluetoothFirstConnected(uid: String, name: String, hasLatency: Bool, enabled: Bool, now: Date) -> [AutoCalAction] {
        guard hasLatency, enabled else { return [] }
        let inGrace = now.timeIntervalSince(startedAt) < Self.launchGrace
        guard inGrace || Config.recalibrateBluetoothOnReconnect else { return [] }
        // 【2026-10-04】app 重開：沿用上次的延遲出聲（不 hold、不倒數）
        if inGrace && !holdOnRelaunch && !holds.contains(uid) { return [] }
        // 裝置清單觀察先到、已經排過又延後（needsConsent…）：只確保 holds，不重複排
        if deferred[uid] != nil && holds.contains(uid) { return [] }
        return holdAndEnqueue(uid: uid, name: name, why: inGrace ? .appRelaunch : .reconnect, now: now)
    }

    private func holdAndEnqueue(uid: String, name: String, why: AutoCalWhy, now: Date) -> [AutoCalAction] {
        var acts: [AutoCalAction] = []
        let before = holds
        holds.insert(uid)
        deferred.removeValue(forKey: uid)
        if !batch.contains(where: { $0.uid == uid }) && !queue.contains(where: { $0.uid == uid }) {
            acts.append(.log(why == .appRelaunch
                ? "自動校正：app 重新啟動後的藍牙「\(name)」→ 校正完成前不出聲、倒數重新校正"
                : "自動校正：藍牙「\(name)」重新連線 → 校正完成前不出聲、倒數重新校正（串流重開後延遲可能改變）"))
            acts += enqueue([AutoCalItem(uid: uid, name: name, why: why)], now: now)
        }
        if holds != before { acts.append(.holdsChanged(holds)) }
        return acts
    }

    /// 【第 C 輪】藍牙漂移補償的短校正（ShortCalScheduler）：
    ///   countdown = false（節目音靜止的空檔）：不倒數，直接排進來（仍會先看麥克風、canRun）；
    ///   countdown = true（到期後連續播放 30 分鐘都沒空檔）：照一般規則倒數 3 秒（看不到倒數 → needsConsent）。
    /// 有其他校正在倒數／執行、或這台已在這批／排隊 → 不動（排程之後再試）
    func requestDriftCalibration(uid: String, name: String, countdown: Bool, now: Date) -> [AutoCalAction] {
        guard phase == .idle, !batch.contains(where: { $0.uid == uid }), !queue.contains(where: { $0.uid == uid }) else { return [] }
        let item = AutoCalItem(uid: uid, name: name, why: .drift)
        // 【第 C 輪審查】只拿掉漂移補償自己的延後項目（上一次倒數的 needsConsent…）；其他原因的「需要校正」
        // （背景監聽連續量不到、漂移不規則、校正失敗、使用者取消）要留著——短校正沒量到時不會放回去，面板／選單列提示點會悄悄消失。
        // 量到了 → finished(measured:) 會把這台的延後項目全部拿掉（真的校正過了）
        if deferred[uid]?.item.why == .drift { deferred.removeValue(forKey: uid) }
        if countdown {
            return [.log("自動校正：藍牙漂移補償「\(name)」到期、連續播放太久沒有空檔 → 倒數短校正")] + enqueue([item], now: now)
        }
        batch = [item]
        phase = .waiting
        return [.log("自動校正：藍牙漂移補償「\(name)」→ 節目音靜止的空檔直接短校正（不倒數）")]
    }

    /// 這一批全是漂移補償的短校正（不發完成通知）
    var batchIsDriftOnly: Bool { !batch.isEmpty && batch.allSatisfy { $0.why == .drift } }

    /// 【第 B 輪】背景監聽判定需要重新校正（偏移 > 10 ms 或多次量不到）：不自動校正（沒有使用者同意不播測試音），
    /// 放進「需要校正」（面板＋選單列圖示提示），按了才校正。倒數／執行中／排隊中的不動
    func flagNeedsCalibration(uid: String, name: String, reason: String) -> [AutoCalAction] {
        if batch.contains(where: { $0.uid == uid }) || queue.contains(where: { $0.uid == uid }) { return [] }
        if let e = deferred[uid], e.reason == .driftDetected(reason) { return [] }
        // 【第 C 輪】已經有「需要校正」（背景監聽／漂移補償）：只更新原因，不再發通知（漂移不規則每次量測都會再判一次，原因文字含數字）
        if let e = deferred[uid], case .driftDetected = e.reason {
            deferred[uid] = (e.item, .driftDetected(reason))
            return [.log("自動校正：\(reason)（已在「需要校正」，只更新原因）")]
        }
        deferred[uid] = (AutoCalItem(uid: uid, name: name, why: .monitor), .driftDetected(reason))
        return [.deferred(names: [name], reason: .driftDetected(reason)), .log("自動校正：\(reason) → 面板「需要校正」")]
    }

    /// 需要使用者處理（選單列圖示提示）：有「需要校正」的裝置，或暫停出聲等校正的藍牙
    var needsAttention: Bool { !deferred.isEmpty || !holds.isEmpty }

    /// 別人啟動的校正（面板「開始校正」、ctl calibrate）開始了：倒數中的這批先擱著（不算取消）
    func externalRunStarted() {
        switch phase {
        case .countdown, .waiting:
            queue = batch + queue.filter { q in !batch.contains { $0.uid == q.uid } }
            batch = []
            phase = .external
        case .idle:
            phase = .external
        case .running, .external:
            break
        }
    }

    /// 我們發出的 startCalibration 真的開始了（AppState 呼叫 CalibrationRunner.start 之後）
    /// —— startIfPossible 已經把 phase 設成 running；這個只給「啟動失敗」時回退用
    func startFailed(_ message: String) -> [AutoCalAction] {
        guard phase == .running else { return [] }
        return finished(measured: [], cancelled: false, message: message, now: Date())
    }

    /// 校正（我們的或別人的）結束。measured = 子行程 `@@measured` 那行的 uid（成功寫入的）
    func finished(measured: Set<String>, cancelled: Bool, message: String, now: Date) -> [AutoCalAction] {
        var acts: [AutoCalAction] = []
        let holdsBefore = holds
        let wasOurs = phase == .running
        // 量到的：不管是哪一批，都解除暫停出聲、拿掉延後／排隊
        holds.subtract(measured)
        for u in measured { deferred.removeValue(forKey: u); failRetry[u] = nil }
        queue.removeAll { measured.contains($0.uid) }
        if wasOurs {
            var ok: [String] = [], bad: [String] = []
            let driftOnly = batchIsDriftOnly
            for it in batch {
                if measured.contains(it.uid) { ok.append(it.name); continue }
                bad.append(it.name)
                // 漂移補償的短校正沒量到：不留「需要校正」（排程 5 分鐘後再試，連續 3 次才標記）；使用者按停止 → 照舊留按鈕
                if it.why == .drift && !cancelled { continue }
                deferred[it.uid] = (it, cancelled ? .cancelled : .failed(Self.failureText(message, bluetoothHeld: holds.contains(it.uid))))
                // 【2026-10-04】沒量到（不是使用者停止）→ 1／3／10 分鐘後自動重試（直接跑，不再倒數：第一次已經倒數／同意過）。
                // 實機：參考喇叭偶爾撿到反射就整次失敗，舊版只留按鈕 → 藍牙一直不出聲到有人按
                if cancelled { failRetry[it.uid] = nil; continue }
                let n = failRetry[it.uid]?.count ?? 0
                if n < Self.failRetryDelays.count {
                    failRetry[it.uid] = (n + 1, now.addingTimeInterval(Self.failRetryDelays[n]))
                    acts.append(.log(String(format: "自動校正：「%@」沒量到 → %.0f 分鐘後自動重試（第 %d／%d 次）", it.name,
                                            Self.failRetryDelays[n] / 60, n + 1, Self.failRetryDelays.count)))
                } else {
                    failRetry[it.uid] = (n, .distantFuture)   // 用完：不再排（count 留著，量到／斷線才清）
                    acts.append(.log("自動校正：「\(it.name)」已自動重試 \(Self.failRetryDelays.count) 次都沒量到 → 停止自動重試（面板「需要校正」）"))
                }
            }
            batch = []
            if !driftOnly || cancelled { acts.append(.finished(ok: ok, failed: bad, cancelled: cancelled)) }
            acts.append(.log("自動校正結束：完成 \(ok.joined(separator: "、"))\(bad.isEmpty ? "" : "；未完成 \(bad.joined(separator: "、"))\(cancelled ? "（已停止）" : "")")"))
        }
        phase = .idle
        if holds != holdsBefore { acts.append(.holdsChanged(holds)) }
        // 下一批（排隊的；只剩還在的裝置）
        let next = queue.filter { present?[$0.uid] != nil }
        queue = []
        if !next.isEmpty { acts += enqueue(next, now: now) }
        return acts
    }

    // MARK: 顯示

    func status(now: Date) -> AutoCalibrationStatus {
        var s = AutoCalibrationStatus()
        switch phase {
        case .countdown(let deadline):
            s.countdownNames = names(batch)
            s.secondsLeft = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        case .waiting:
            s.countdownNames = names(batch)
            s.waitingMessage = "等目前的工作結束後開始校正"
        case .running:
            s.runningNames = names(batch)
        case .external, .idle:
            break
        }
        s.pending = deferred.values.sorted { $0.item.name < $1.item.name }
            .map { AutoCalibrationStatus.Pending(uid: $0.item.uid, name: $0.item.name, message: $0.reason.text) }
        s.heldNames = holds.compactMap { present?[$0]?.name }.sorted()
        return s
    }

    // MARK: 內部

    private func names(_ items: [AutoCalItem]) -> [String] { items.map(\.name) }

    private func micProblem(_ env: AutoCalEnvironment) -> AutoCalDeferral? {
        if !env.micAvailable { return .noMic }
        if env.micBusy { return .micBusy }
        return nil
    }

    /// 加進這一批：idle → 開始倒數；倒數中 → 合併並重新倒數 3 秒；執行中 → 排隊
    private func enqueue(_ items: [AutoCalItem], now: Date) -> [AutoCalAction] {
        let items = items.filter { it in !batch.contains { $0.uid == it.uid } }
        guard !items.isEmpty else { return [] }
        for it in items { deferred.removeValue(forKey: it.uid) }
        switch phase {
        case .running, .external:
            for it in items where !queue.contains(where: { $0.uid == it.uid }) { queue.append(it) }
            return [.log("自動校正：\(names(items).joined(separator: "、")) 排隊（目前有校正在跑，結束後合併成一次）")]
        case .idle, .countdown, .waiting:
            batch += items
            phase = .countdown(deadline: now.addingTimeInterval(Self.countdownSeconds))
            return [.countdownStarted(names: names(batch), seconds: Int(Self.countdownSeconds))]
        }
    }

    private func startIfPossible(_ env: AutoCalEnvironment) -> [AutoCalAction] {
        let live = batch.filter { present?[$0.uid] != nil }
        batch = live
        guard !live.isEmpty else { phase = .idle; return [] }
        guard env.canRun else {
            if phase != .waiting { phase = .waiting; return [.log("自動校正：倒數結束，等引擎／其他校正結束後開始")] }
            return []
        }
        phase = .running
        return [.startCalibration(uids: live.map(\.uid))]
    }

    private func deferBatch(_ r: AutoCalDeferral) -> [AutoCalAction] {
        var items = batch
        batch = []
        phase = .idle
        // 漂移補償的短校正碰到麥克風被占用／找不到：直接放掉（排程之後再試；不要變成「麥克風空下來就自動倒數」）
        if r == .micBusy || r == .noMic {
            let drop = items.filter { $0.why == .drift }
            items.removeAll { $0.why == .drift }
            if items.isEmpty { return drop.isEmpty ? [] : [.log("自動校正：漂移補償短校正先不跑（\(r.text)），之後再試")] }
        }
        guard !items.isEmpty else { return [] }
        for it in items { deferred[it.uid] = (it, r) }
        return [.deferred(names: names(items), reason: r)]
    }

    private static func failureText(_ message: String, bluetoothHeld: Bool) -> String {
        let m = message.trimmingCharacters(in: .whitespaces)
        let base = m.isEmpty ? "自動校正沒有量到" : "自動校正沒有量到：\(m)"
        return bluetoothHeld ? base + "（校正完成前先不出聲）" : base
    }
}

// MARK: - 離線自測（`In_Unison42 autocal-selftest`）

func runAutoCalibrationSelfTest() -> Int32 {
    var fail = 0, pass = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if ok { pass += 1 } else { fail += 1 }
    }
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    let builtin = AutoCalDevice(uid: "BuiltInSpeakerDevice", name: "Mac mini的揚聲器", isBluetooth: false, hasLatency: true, enabled: true, isReference: true)
    let msi = AutoCalDevice(uid: "msi", name: "MSI MP242C", isBluetooth: false, hasLatency: true, enabled: true, isReference: false)
    let tv = AutoCalDevice(uid: "tv", name: "40PFH4082/96", isBluetooth: false, hasLatency: true, enabled: true, isReference: false)
    let bt = AutoCalDevice(uid: "AA-BB-CC-DD-EE-01:output", name: "GLASS5+", isBluetooth: true, hasLatency: true, enabled: true, isReference: false)
    func fresh(_ d: AutoCalDevice) -> AutoCalDevice {
        AutoCalDevice(uid: d.uid, name: d.name, isBluetooth: d.isBluetooth, hasLatency: false, enabled: d.enabled, isReference: d.isReference)
    }
    let usb = fresh(AutoCalDevice(uid: "usb", name: "USB 喇叭", isBluetooth: false, hasLatency: false, enabled: true, isReference: false))
    let usb2 = fresh(AutoCalDevice(uid: "usb2", name: "第二台 USB", isBluetooth: false, hasLatency: false, enabled: true, isReference: false))
    let ok = AutoCalEnvironment()
    func starts(_ a: [AutoCalAction]) -> [[String]] { a.compactMap { if case .startCalibration(let u) = $0 { return u } else { return nil } } }
    func countdowns(_ a: [AutoCalAction]) -> [[String]] { a.compactMap { if case .countdownStarted(let n, _) = $0 { return n } else { return nil } } }
    func deferrals(_ a: [AutoCalAction]) -> [AutoCalDeferral] { a.compactMap { if case .deferred(_, let r) = $0 { return r } else { return nil } } }
    func holdsOf(_ a: [AutoCalAction]) -> Set<String>? { a.reversed().compactMap { if case .holdsChanged(let h) = $0 { return h } else { return nil } }.first }

    print("── 1. 新裝置（從未校正）接上：通知＋倒數 3 秒 → calibrate --pulse --only <uid> ──")
    do {
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        var r = a.observe([builtin, msi, tv], now: at(1))
        check(starts(r).isEmpty && countdowns(r).isEmpty, "啟動時三台都校正過：沒有動作")
        r = a.observe([builtin, msi, tv, usb], now: at(100))
        check(countdowns(r) == [["USB 喇叭"]], "接上 USB 喇叭 → 倒數", "\(r)")
        check(a.status(now: at(100)).countdownNames == ["USB 喇叭"] && a.status(now: at(100)).secondsLeft == 3, "面板：3 秒後校正〈USB 喇叭〉")
        check(a.status(now: at(101.2)).secondsLeft == 2, "倒數到 2 秒")
        r = a.tick(now: at(102.9), env: ok)
        check(starts(r).isEmpty, "還沒到 3 秒不開始")
        r = a.tick(now: at(103.0), env: ok)
        check(starts(r) == [["usb"]], "3 秒到 → --only usb", "\(r)")
        check(a.phase == .running && a.status(now: at(103)).runningNames == ["USB 喇叭"], "執行中")
        r = a.finished(measured: ["BuiltInSpeakerDevice", "usb"], cancelled: false, message: "", now: at(120))
        check(a.phase == .idle && a.deferred.isEmpty && r.contains(.finished(ok: ["USB 喇叭"], failed: [], cancelled: false)), "量到 → 完成、沒有待校正")
    }

    print("── 2. 已有延遲紀錄的有線裝置重新接上：沿用舊值，不播測試音（藍牙見第 12 節） ──")
    do {
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = a.observe([builtin, msi, tv], now: at(1))
        _ = a.observe([builtin, tv], now: at(50))               // MSI 拔掉
        var r = a.observe([builtin, msi, tv], now: at(60))       // 插回
        check(starts(r).isEmpty && countdowns(r).isEmpty && a.phase == .idle, "MSI 插回：沒有倒數", "\(r)")
        _ = a.observe([builtin, msi], now: at(100))             // 電視拔掉再插回
        r = a.observe([builtin, msi, tv], now: at(110))
        check(countdowns(r).isEmpty && a.holds.isEmpty && holdsOf(r) == nil, "電視插回：沿用舊值、不暫停出聲")
        for _ in 0..<5 { r = a.tick(now: at(120), env: ok); check(starts(r).isEmpty, "之後 tick 也不會自己開始") }
    }

    print("── 3. app 重開（登入啟動）：已校正的藍牙 → 暫停出聲＋倒數 → 只量藍牙 ──")
    do {
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        var r = a.observe([builtin, msi, tv, bt], now: at(2))
        check(holdsOf(r) == [bt.uid] && a.holds == [bt.uid], "啟動時藍牙已連：暫停出聲（holds）", "\(r)")
        check(countdowns(r) == [["GLASS5+"]], "倒數 3 秒")
        check(a.status(now: at(2)).heldNames == ["GLASS5+"], "面板列出暫停出聲的藍牙")
        r = a.tick(now: at(5), env: ok)
        check(starts(r) == [[bt.uid]], "只量藍牙（--only 藍牙 uid）", "\(r)")
        r = a.finished(measured: ["BuiltInSpeakerDevice", bt.uid], cancelled: false, message: "", now: at(40))
        check(holdsOf(r) == [] && a.holds.isEmpty, "量到 → 解除暫停出聲")
        // 登入時藍牙晚幾秒才連（30 秒內）：一樣算 app 重開
        let b = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = b.observe([builtin, msi, tv], now: at(1))
        r = b.observe([builtin, msi, tv, bt], now: at(12))
        check(b.holds == [bt.uid] && countdowns(r) == [["GLASS5+"]], "啟動後 12 秒才連上的藍牙：也暫停出聲並重校")
        // 量不到（麥克風聽不到）→ 仍暫停出聲、面板留「需要校正」、不自動重試
        _ = b.tick(now: at(15), env: ok)
        r = b.finished(measured: [], cancelled: false, message: "麥克風聽不到 GLASS5+", now: at(50))
        check(b.holds == [bt.uid] && b.deferred[bt.uid] != nil && r.contains(.finished(ok: [], failed: ["GLASS5+"], cancelled: false)),
              "量不到：仍不出聲＋需要校正", b.status(now: at(50)).pending.first?.message ?? "")
        r = b.tick(now: at(60), env: ok)
        check(starts(r).isEmpty && countdowns(r).isEmpty, "失敗不自動重試（不會一直播測試音）")
        // 暫停出聲中斷線再接上 → 還是要先校正（不能用舊值）
        _ = b.observe([builtin, msi, tv], now: at(100))
        r = b.observe([builtin, msi, tv, bt], now: at(110))
        check(countdowns(r) == [["GLASS5+"]] && b.holds == [bt.uid], "暫停出聲中重新接上：再倒數一次")
        // engine 開始前就先暫停出聲（primeLaunchHolds），第一次觀察才倒數
        let p = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        p.primeLaunchHolds([bt.uid])
        check(p.holds == [bt.uid] && p.phase == .idle, "engine 開始前：已校正的藍牙先暫停出聲（還沒倒數）")
        r = p.observe([builtin, msi, tv, bt], now: at(3))
        check(countdowns(r) == [["GLASS5+"]] && holdsOf(r) == nil, "第一次觀察 → 倒數（holds 沒變，不必重送 engine）")
        // 未校正過的藍牙在啟動時已連：不暫停（本來就不出聲）、不自動
        let c = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        r = c.observe([builtin, fresh(bt)], now: at(1))
        check(c.holds.isEmpty && countdowns(r).isEmpty && c.deferred[bt.uid]?.reason == .notCalibratedAtLaunch,
              "啟動時就在的未校正裝置：不自動播測試音，只留「需要校正」")
        // 之後設定檔有了延遲值（ctl reload-config／外部校正）→ 從「需要校正」拿掉，不觸發校正
        r = c.observe([builtin, bt], now: at(20))
        check(c.deferred[bt.uid] == nil && countdowns(r).isEmpty && c.holds.isEmpty, "有了延遲值 → 從「需要校正」拿掉（不倒數、不暫停出聲）")
    }

    print("── 4. 取消：延後、面板留「需要校正」；按了才校正 ──")
    do {
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = a.observe([builtin, msi], now: at(100))
        _ = a.observe([builtin, msi, usb], now: at(200))
        var r = a.tick(now: at(201), env: ok)
        r = a.cancel()
        check(deferrals(r) == [.cancelled] && a.phase == .idle, "倒數中取消 → 延後", "\(r)")
        let st = a.status(now: at(202))
        check(st.countdownNames.isEmpty && st.pending.map(\.name) == ["USB 喇叭"] && st.pending[0].message == "已取消自動校正", "面板：需要校正〈USB 喇叭〉")
        r = a.tick(now: at(210), env: ok)
        check(starts(r).isEmpty, "取消後不自己開始")
        r = a.requestNow(now: at(220))
        r += a.tick(now: at(220), env: ok)
        check(starts(r) == [["usb"]], "按「需要校正」→ 立刻校正（不倒數）", "\(r)")
        r = a.finished(measured: [], cancelled: true, message: "", now: at(230))
        check(a.deferred["usb"]?.reason == .cancelled && r.contains(.finished(ok: [], failed: ["USB 喇叭"], cancelled: true)), "校正中按停止 → 再延後")
    }

    print("── 5. 麥克風被其他 App 占用：延後並提示；空下來自動再倒數 ──")
    do {
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = a.observe([builtin], now: at(100))
        _ = a.observe([builtin, usb], now: at(200))
        var busy = ok; busy.micBusy = true
        check(a.needsEnvironment, "倒數中要量麥克風狀態")
        var r = a.tick(now: at(201), env: busy)
        check(deferrals(r) == [.micBusy] && starts(r).isEmpty, "倒數中發現麥克風被占用 → 延後", "\(r)")
        check(a.status(now: at(201)).pending.first?.message.contains("其他 App") == true, "面板提示")
        check(a.needsEnvironment, "延後（麥克風）時繼續看麥克風")
        r = a.tick(now: at(210), env: busy)
        check(r.isEmpty, "還被占用：不動")
        r = a.tick(now: at(220), env: ok)
        check(countdowns(r) == [["USB 喇叭"]], "空下來 → 重新倒數", "\(r)")
        r = a.tick(now: at(222), env: busy)
        check(deferrals(r) == [.micBusy], "倒數最後一刻又被占用 → 再延後（不開麥克風）")
        r = a.tick(now: at(230), env: ok); r += a.tick(now: at(233), env: ok)
        check(starts(r) == [["usb"]], "空下來、倒數完 → 開始")
        var noMic = ok; noMic.micAvailable = false
        let b = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = b.observe([builtin], now: at(100)); _ = b.observe([builtin, usb], now: at(200))
        r = b.tick(now: at(201), env: noMic)
        check(deferrals(r) == [.noMic], "找不到校正麥克風 → 延後")
    }

    print("── 6. 同一時間最多一個校正；多台同時出現 → 合併成一次 --only a,b ──")
    do {
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = a.observe([builtin], now: at(100))
        var r = a.observe([builtin, usb, usb2], now: at(200))
        check(countdowns(r) == [["USB 喇叭", "第二台 USB"]], "同一次觀察兩台 → 一次倒數")
        _ = a.tick(now: at(201), env: ok)
        r = a.tick(now: at(203), env: ok)
        check(starts(r) == [["usb", "usb2"]], "--only usb,usb2", "\(r)")
        // 倒數中又來一台 → 合併、重新倒數 3 秒
        let b = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = b.observe([builtin], now: at(100))
        _ = b.observe([builtin, usb], now: at(200))
        r = b.observe([builtin, usb, usb2], now: at(202))
        check(countdowns(r) == [["USB 喇叭", "第二台 USB"]], "倒數中第二台接上 → 合併、重新倒數")
        r = b.tick(now: at(204), env: ok)
        check(starts(r).isEmpty, "重新倒數：原本的 3 秒到了也不開始")
        r = b.tick(now: at(205), env: ok)
        check(starts(r) == [["usb", "usb2"]], "合併成一次")
        // 執行中又來一台 → 排隊，結束後再一次
        let c = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = c.observe([builtin], now: at(100))
        _ = c.observe([builtin, usb], now: at(200)); _ = c.tick(now: at(203), env: ok)
        check(c.phase == .running, "第一批執行中")
        r = c.observe([builtin, usb, usb2], now: at(210))
        check(starts(r).isEmpty && countdowns(r).isEmpty && c.queue.map(\.uid) == ["usb2"], "執行中接上第二台 → 排隊")
        r = c.tick(now: at(215), env: ok)
        check(starts(r).isEmpty, "執行中不會再開第二個")
        r = c.finished(measured: ["BuiltInSpeakerDevice", "usb"], cancelled: false, message: "", now: at(230))
        check(countdowns(r) == [["第二台 USB"]], "第一批結束 → 排隊的開始倒數")
        r = c.tick(now: at(233), env: ok)
        check(starts(r) == [["usb2"]], "第二批 --only usb2")
        // 使用者自己按「開始校正」（全部量）：倒數中的先擱著，量到就不用再量
        let d = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = d.observe([builtin], now: at(100)); _ = d.observe([builtin, usb], now: at(200))
        d.externalRunStarted()
        r = d.tick(now: at(210), env: ok)
        check(starts(r).isEmpty && d.phase == .external, "別的校正在跑：不開始")
        r = d.finished(measured: ["BuiltInSpeakerDevice", "usb"], cancelled: false, message: "", now: at(230))
        check(countdowns(r).isEmpty && d.phase == .idle && d.queue.isEmpty, "全部校正量到它 → 不用再自動校正")
        // canRun = false（引擎還沒好）→ 等
        let e = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = e.observe([builtin], now: at(100)); _ = e.observe([builtin, usb], now: at(200))
        var notReady = ok; notReady.canRun = false
        r = e.tick(now: at(203), env: notReady)
        check(starts(r).isEmpty && e.phase == .waiting && e.status(now: at(203)).waitingMessage != nil, "倒數完但引擎沒好 → 等")
        r = e.tick(now: at(204), env: ok)
        check(starts(r) == [["usb"]], "引擎好了 → 開始")
    }

    print("── 7. 不自動校正的：參考喇叭、使用者關掉的、倒數中拔掉的 ──")
    do {
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = a.observe([], now: at(100))
        let refFresh = fresh(builtin)
        let off = AutoCalDevice(uid: "off", name: "關掉的", isBluetooth: false, hasLatency: false, enabled: false, isReference: false)
        var r = a.observe([refFresh, off], now: at(200))
        check(countdowns(r).isEmpty && a.deferred.isEmpty, "參考喇叭（未量測也視為 0）、使用者關掉的裝置：不校正")
        r = a.observe([refFresh, off, usb], now: at(300))
        check(countdowns(r) == [["USB 喇叭"]], "倒數")
        r = a.observe([refFresh, off], now: at(301))
        check(a.phase == .idle && a.batch.isEmpty, "倒數中拔掉 → 取消倒數")
        r = a.tick(now: at(305), env: ok)
        check(starts(r).isEmpty, "不會對不在的裝置開始校正")
    }

    print("── 8. 子行程輸出解析（@@measured） ──")
    check(parseMeasuredUIDs(["x", "@@measured BuiltInSpeakerDevice,AA-BB-CC-DD-EE-01:output", "✓ 已寫入"]) == ["BuiltInSpeakerDevice", "AA-BB-CC-DD-EE-01:output"],
          "解析量到的 uid")
    check(parseMeasuredUIDs(["✗ 量測不合格（見上），設定未修改"]).isEmpty, "失敗時沒有 @@measured → 空集合")

    print("── 9. 暫停出聲中被使用者關掉再打開：放回「需要校正」（2026-09-29 審查） ──")
    do {
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = a.observe([builtin, msi, tv, bt], now: at(2))
        _ = a.tick(now: at(5), env: ok)
        _ = a.finished(measured: [], cancelled: true, message: "", now: at(20))
        check(a.holds == [bt.uid] && a.deferred[bt.uid] != nil, "前提：自動校正被停止 → 仍暫停出聲＋需要校正")
        let btOff = AutoCalDevice(uid: bt.uid, name: bt.name, isBluetooth: true, hasLatency: true, enabled: false, isReference: false)
        var r = a.observe([builtin, msi, tv, btOff], now: at(40))
        check(a.deferred[bt.uid] == nil && a.holds == [bt.uid], "關掉 → 從「需要校正」拿掉，holds 保留")
        r = a.observe([builtin, msi, tv, bt], now: at(60))
        check(a.deferred[bt.uid]?.reason == .heldAwaitingCalibration && countdowns(r).isEmpty && starts(r).isEmpty,
              "再打開 → 面板「需要校正」（不自動播測試音）", "\(r)")
        check(a.status(now: at(60)).pending.map(\.uid) == [bt.uid] && a.status(now: at(60)).heldNames == ["GLASS5+"], "面板：暫停出聲＋需要校正按鈕")
        _ = a.tick(now: at(70), env: ok)
        check(a.phase == .idle, "不自動重試")
        r = a.requestNow(now: at(80))
        r += a.tick(now: at(80), env: ok)
        check(starts(r) == [[bt.uid]], "按「需要校正」→ 只量它", "\(r)")
        r = a.finished(measured: [bt.uid], cancelled: false, message: "", now: at(100))
        check(a.holds.isEmpty && a.deferred.isEmpty, "量到 → 解除暫停出聲")
        // 關著時接上的未校正裝置，之後打開 → 「尚未校正」
        let b = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = b.observe([builtin], now: at(1))
        let usbOff = AutoCalDevice(uid: usb.uid, name: usb.name, isBluetooth: false, hasLatency: false, enabled: false, isReference: false)
        _ = b.observe([builtin, usbOff], now: at(100))
        check(b.deferred.isEmpty && b.phase == .idle, "關著接上：不校正")
        r = b.observe([builtin, usb], now: at(110))
        check(b.deferred[usb.uid]?.reason == .notCalibratedAtLaunch && countdowns(r).isEmpty, "打開 → 面板「尚未校正」按鈕、不自動")
    }

    print("── 10. 使用者看不到倒數（面板關著、通知沒授權）：不自動播測試音（2026-09-29 審查） ──")
    do {
        var blind = AutoCalEnvironment(); blind.userCanSee = false
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        var r = a.observe([builtin, msi, tv, bt], now: at(2))
        check(countdowns(r) == [["GLASS5+"]], "app 重開：狀態機照常進倒數")
        r = a.tick(now: at(2.25), env: blind)
        check(deferrals(r) == [.needsConsent] && a.phase == .idle && a.holds == [bt.uid], "看不到 → 立刻延後（needsConsent）、藍牙仍不出聲", "\(r)")
        r = a.tick(now: at(10), env: blind)
        check(starts(r).isEmpty && countdowns(r).isEmpty, "還是看不到：不倒數、不校正")
        check(a.status(now: at(10)).pending.first?.message == AutoCalDeferral.needsConsent.text, "面板「需要校正」說明原因")
        r = a.tick(now: at(20), env: ok)
        check(countdowns(r) == [["GLASS5+"]], "面板打開／通知允許 → 自動再倒數（看得到才倒數）", "\(r)")
        r = a.tick(now: at(23), env: ok)
        check(starts(r) == [[bt.uid]], "倒數完開始")
        // 使用者自己按（ctl autocal now／面板按鈕）：不需要通知權限
        let b = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = b.observe([builtin], now: at(1))
        _ = b.observe([builtin, usb], now: at(100))
        _ = b.tick(now: at(100.25), env: blind)
        r = b.requestNow(now: at(101))
        r += b.tick(now: at(101), env: blind)
        check(starts(r) == [[usb.uid]], "使用者明確要求：看不到通知也照做", "\(r)")
    }

    runMonitorSchedulerSelfTest(check: check)

    print("── 12. 藍牙真的斷線重連（第 B 輪 Kang 定案）：比照 app 重開——先不出聲、倒數 3 秒、--only 重校 ──")
    do {
        check(Config.recalibrateBluetoothOnReconnect, "政策開關：重連要重校")
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = a.observe([builtin, msi, tv], now: at(1))
        // 啟動 30 秒後才第一次連上（登入後很久才連）→ 也當成串流重開：先不出聲、重校
        var r = a.observe([builtin, msi, tv, bt], now: at(200))
        check(holdsOf(r) == [bt.uid] && countdowns(r) == [["GLASS5+"]], "啟動 30 秒後才連上的藍牙：暫停出聲＋倒數", "\(r)")
        r = a.tick(now: at(203), env: ok)
        check(starts(r) == [[bt.uid]], "--only 藍牙", "\(r)")
        r = a.finished(measured: ["BuiltInSpeakerDevice", bt.uid], cancelled: false, message: "", now: at(220))
        check(a.holds.isEmpty, "量到 → 恢復出聲")
        // 真的斷線再連上（裝置清單看到它消失又出現）
        _ = a.observe([builtin, msi, tv], now: at(300))
        r = a.observe([builtin, msi, tv, bt], now: at(310))
        check(holdsOf(r) == [bt.uid] && countdowns(r) == [["GLASS5+"]], "斷線再連上：暫停出聲＋倒數", "\(r)")
        // 同一次重連，onReconnect 也送來 → 不重複排
        r = a.bluetoothReconnected(uid: bt.uid, name: bt.name, hasLatency: true, enabled: true, now: at(310.5))
        check(countdowns(r).isEmpty && holdsOf(r) == nil && a.batch.count == 1, "onReconnect 重複通知：不重複排、不重設倒數", "\(r)")
        // 通知沒授權、面板關著 → needsConsent（面板打開才倒數）
        var blind = AutoCalEnvironment(); blind.userCanSee = false
        r = a.tick(now: at(311), env: blind)
        check(deferrals(r) == [.needsConsent] && a.holds == [bt.uid], "看不到倒數 → needsConsent、仍不出聲", "\(r)")
        r = a.tick(now: at(330), env: ok)
        check(countdowns(r) == [["GLASS5+"]], "面板打開 → 倒數", "\(r)")
        _ = a.tick(now: at(333), env: ok)
        _ = a.finished(measured: [bt.uid], cancelled: false, message: "", now: at(350))
        // 只有 onReconnect（simulate-reconnect／清單沒來得及看到它消失）
        r = a.bluetoothReconnected(uid: bt.uid, name: bt.name, hasLatency: true, enabled: true, now: at(400))
        check(holdsOf(r) == [bt.uid] && countdowns(r) == [["GLASS5+"]], "只有 onReconnect：一樣暫停出聲＋倒數", "\(r)")
        // 校正執行中又重連 → 排隊（不會同時兩個校正）
        _ = a.tick(now: at(403), env: ok)
        check(a.phase == .running, "執行中")
        r = a.bluetoothReconnected(uid: "bt2", name: "第二台藍牙", hasLatency: true, enabled: true, now: at(405))
        check(a.queue.map(\.uid) == ["bt2"] && starts(r).isEmpty, "執行中又有一台重連 → 排隊", "\(r)")
        // 沒量過延遲／關掉的：不動（本來就不出聲）
        let b = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        check(b.bluetoothReconnected(uid: "x", name: "x", hasLatency: false, enabled: true, now: at(100)).isEmpty
              && b.bluetoothReconnected(uid: "y", name: "y", hasLatency: true, enabled: false, now: at(100)).isEmpty && b.holds.isEmpty,
              "沒量過延遲／使用者關掉的藍牙：不暫停、不校正")
        // 【2026-09-29 審查】啟動 30 秒後才「第一次」連上（BluetoothOutManager.onFirstConnect，engine 已先 hold）：
        // 在裝置清單觀察之前就暫停出聲＋倒數；之後的 observe 不重複排
        let f = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = f.observe([builtin, msi, tv], now: at(1))
        r = f.bluetoothFirstConnected(uid: bt.uid, name: bt.name, hasLatency: true, enabled: true, now: at(200))
        check(holdsOf(r) == [bt.uid] && countdowns(r) == [["GLASS5+"]] && f.batch.first?.why == .reconnect,
              "啟動 30 秒後第一次連上（onFirstConnect 先到）：暫停出聲＋倒數（同重連）", "\(r)")
        r = f.observe([builtin, msi, tv, bt], now: at(200.8))
        check(countdowns(r).isEmpty && holdsOf(r) == nil && f.batch.count == 1, "之後裝置清單才看到它：不重複排", "\(r)")
        let g = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        g.primeLaunchHolds([bt.uid])
        r = g.bluetoothFirstConnected(uid: bt.uid, name: bt.name, hasLatency: true, enabled: true, now: at(2))
        check(countdowns(r) == [["GLASS5+"]] && g.batch.first?.why == .appRelaunch && holdsOf(r) == nil,
              "啟動 30 秒內第一次連上：當作 app 重開（appRelaunch），holds 已由 primeLaunchHolds 設好", "\(r)")
        r = g.observe([builtin, msi, tv, bt], now: at(2.5))
        check(countdowns(r).isEmpty && g.batch.count == 1, "第一次觀察：不重複排", "\(r)")
        // 2026-09-29 實機：通知沒授權 → onFirstConnect 先排、立刻延後（needsConsent），接著第一次觀察不可以再排一次
        let n = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        n.primeLaunchHolds([bt.uid])
        var blindN = AutoCalEnvironment(); blindN.userCanSee = false
        _ = n.bluetoothFirstConnected(uid: bt.uid, name: bt.name, hasLatency: true, enabled: true, now: at(1))
        r = n.tick(now: at(1.01), env: blindN)
        check(deferrals(r) == [.needsConsent] && n.batch.isEmpty, "前提：看不到倒數 → needsConsent", "\(r)")
        r = n.observe([builtin, msi, tv, bt], now: at(1.02))
        r += n.tick(now: at(1.03), env: blindN)
        check(countdowns(r).isEmpty && deferrals(r).isEmpty && !r.contains { if case .log = $0 { return true } else { return false } } && n.holds == [bt.uid],
              "之後第一次觀察：不重複排、不重複延後（沒有重複 log）", "\(r)")
        // 反過來：觀察先到、已延後，onFirstConnect 才到 → 不重複
        let m = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        m.primeLaunchHolds([bt.uid])
        _ = m.observe([builtin, msi, tv, bt], now: at(1))
        _ = m.tick(now: at(1.01), env: blindN)
        r = m.bluetoothFirstConnected(uid: bt.uid, name: bt.name, hasLatency: true, enabled: true, now: at(1.02))
        check(r.isEmpty && m.deferred[bt.uid] != nil && m.holds == [bt.uid], "觀察先到已延後、onFirstConnect 後到：不重複", "\(r)")
        let h = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        check(h.bluetoothFirstConnected(uid: "x", name: "x", hasLatency: false, enabled: true, now: at(200)).isEmpty
              && h.bluetoothFirstConnected(uid: "y", name: "y", hasLatency: true, enabled: false, now: at(200)).isEmpty && h.holds.isEmpty,
              "第一次連上但沒量過／關掉：不暫停（AppState 直接放掉 engine 的暫時 hold）")
    }

    print("── 13. 背景監聽標記需要重新校正＋選單列提示 ──")
    do {
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = a.observe([builtin, msi, tv], now: at(1))
        check(!a.needsAttention, "平常：不提示")
        var r = a.flagNeedsCalibration(uid: "tv", name: "電視", reason: "背景監聽連續 2 次量到「電視」偏 +12.0 ms")
        check(deferrals(r).count == 1 && a.needsAttention && a.status(now: at(2)).pending.first?.message.contains("12.0") == true,
              "標記 → 面板「需要校正」、選單列提示", "\(r)")
        r = a.flagNeedsCalibration(uid: "tv", name: "電視", reason: "背景監聽連續 2 次量到「電視」偏 +12.0 ms")
        check(r.isEmpty, "同一個原因不重複通知")
        r = a.tick(now: at(10), env: ok)
        check(starts(r).isEmpty && countdowns(r).isEmpty, "不自動校正（要使用者按）")
        r = a.requestNow(now: at(20)) + a.tick(now: at(20), env: ok)
        check(starts(r) == [["tv"]], "按「立即校正」→ --only 電視", "\(r)")
        _ = a.finished(measured: ["tv"], cancelled: false, message: "", now: at(40))
        check(!a.needsAttention, "量到 → 提示消失")
        let b = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = b.observe([builtin, bt], now: at(1))
        check(b.needsAttention, "暫停出聲等校正的藍牙（倒數中）也提示")
    }

    print("── 14. 【第 C 輪】藍牙漂移補償的短校正：空檔不倒數、連續播放太久才倒數（看不到 → needsConsent）、失敗不留按鈕、不發完成通知 ──")
    do {
        func finishedActs(_ a: [AutoCalAction]) -> Int { a.filter { if case .finished = $0 { return true } else { return false } }.count }
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = a.observe([builtin, msi, tv, bt], now: at(1))
        _ = a.tick(now: at(4), env: ok)
        _ = a.finished(measured: [bt.uid], cancelled: false, message: "", now: at(40))   // 啟動重校完成
        var r = a.requestDriftCalibration(uid: bt.uid, name: bt.name, countdown: false, now: at(400))
        check(countdowns(r).isEmpty && a.phase == .waiting, "空檔：不倒數、直接等可以開始", "\(r)")
        r = a.tick(now: at(400.3), env: ok)
        check(starts(r) == [[bt.uid]], "空檔：下一個 tick 就開始 --only 藍牙", "\(r)")
        check(a.requestDriftCalibration(uid: bt.uid, name: bt.name, countdown: false, now: at(401)).isEmpty, "執行中：不重複排")
        r = a.finished(measured: [bt.uid, builtin.uid], cancelled: false, message: "", now: at(410))
        check(finishedActs(r) == 0 && a.deferred.isEmpty && a.phase == .idle, "量到：不發完成通知、沒有「需要校正」", "\(r)")
        // 失敗 → 不留按鈕、不通知
        _ = a.requestDriftCalibration(uid: bt.uid, name: bt.name, countdown: false, now: at(700))
        _ = a.tick(now: at(700.3), env: ok)
        r = a.finished(measured: [builtin.uid], cancelled: false, message: "藍牙沒量到", now: at(710))
        check(finishedActs(r) == 0 && a.deferred[bt.uid] == nil, "短校正沒量到：不留「需要校正」、不通知（排程之後再試）", "\(r)")
        // 倒數：看不到 → needsConsent（面板打開才倒數）
        r = a.requestDriftCalibration(uid: bt.uid, name: bt.name, countdown: true, now: at(2000))
        check(countdowns(r) == [["GLASS5+"]], "連續播放太久：倒數 3 秒", "\(r)")
        var blind = AutoCalEnvironment(); blind.userCanSee = false
        r = a.tick(now: at(2000.5), env: blind)
        check(deferrals(r) == [.needsConsent] && a.deferred[bt.uid]?.reason == .needsConsent, "通知沒授權、面板關著 → needsConsent", "\(r)")
        r = a.tick(now: at(2010), env: ok)
        check(countdowns(r) == [["GLASS5+"]], "面板打開 → 倒數", "\(r)")
        // 麥克風被占用：空檔的短校正直接放掉（不變成「空下來自動倒數」）
        let b = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = b.observe([builtin, msi, tv, bt], now: at(1))
        _ = b.tick(now: at(4), env: ok)
        _ = b.finished(measured: [bt.uid], cancelled: false, message: "", now: at(40))
        _ = b.requestDriftCalibration(uid: bt.uid, name: bt.name, countdown: false, now: at(400))
        var busy = AutoCalEnvironment(); busy.micBusy = true
        r = b.tick(now: at(400.3), env: busy)
        check(deferrals(r).isEmpty && b.deferred.isEmpty && b.phase == .idle, "麥克風被占用：空檔短校正放掉（之後再試）", "\(r)")
        // 使用者按「需要校正」→ 一般（manual）項目，不是漂移補償的（會發完成通知、失敗留按鈕）
        _ = b.flagNeedsCalibration(uid: bt.uid, name: bt.name, reason: "藍牙短校正連續 3 次沒有量到")
        _ = b.requestNow(now: at(500))
        check(!b.batchIsDriftOnly && b.batch.first?.why == .manual, "按「需要校正」：一般項目（不是漂移補償的短校正）")
        // 【第 C 輪審查】「需要校正」（背景監聽連續量不到、漂移不規則…）不能被空檔短校正悄悄抹掉
        let d = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = d.observe([builtin, msi, tv, bt], now: at(1))
        _ = d.tick(now: at(4), env: ok)
        _ = d.finished(measured: [bt.uid], cancelled: false, message: "", now: at(40))
        r = d.flagNeedsCalibration(uid: bt.uid, name: bt.name, reason: "背景監聽連續 3 次量不到")
        check(deferrals(r) == [.driftDetected("背景監聽連續 3 次量不到")] && d.needsAttention, "背景監聽標記：需要校正（通知一次）")
        _ = d.requestDriftCalibration(uid: bt.uid, name: bt.name, countdown: false, now: at(400))
        check(d.deferred[bt.uid] != nil && d.needsAttention, "空檔短校正開始：「需要校正」還在（面板／選單列提示點不消失）")
        _ = d.tick(now: at(400.3), env: ok)
        _ = d.finished(measured: [builtin.uid], cancelled: false, message: "藍牙沒量到", now: at(410))
        check(d.deferred[bt.uid]?.reason == .driftDetected("背景監聽連續 3 次量不到"), "短校正沒量到：原本的「需要校正」保留")
        r = d.flagNeedsCalibration(uid: bt.uid, name: bt.name, reason: "藍牙漂移補償：漂移不規則（…）")
        check(deferrals(r).isEmpty && d.deferred[bt.uid]?.reason == .driftDetected("藍牙漂移補償：漂移不規則（…）"), "已經在「需要校正」：只更新原因、不再發通知", "\(r)")
        _ = d.requestDriftCalibration(uid: bt.uid, name: bt.name, countdown: false, now: at(700))
        _ = d.tick(now: at(700.3), env: ok)
        _ = d.finished(measured: [bt.uid, builtin.uid], cancelled: false, message: "", now: at(710))
        check(d.deferred[bt.uid] == nil && !d.needsAttention, "短校正量到（真的校正過了）：「需要校正」解除")
        // 其他校正在倒數中：不插隊
        let c = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = c.observe([builtin, msi, tv], now: at(1))
        _ = c.observe([builtin, msi, tv, usb], now: at(5))
        check(c.requestDriftCalibration(uid: bt.uid, name: bt.name, countdown: false, now: at(5.5)).isEmpty, "有其他校正在倒數：不插隊")
    }

    print("── 2026-10-04 自動校正失敗：1／3／10 分鐘後自動重試（不倒數），3 次後停；取消不重試；量到就清掉 ──")
    do {
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = a.observe([builtin, msi, tv, bt], now: at(1))
        _ = a.tick(now: at(4), env: ok)                     // 倒數結束 → 開始
        var r = a.finished(measured: [], cancelled: false, message: "參考喇叭量測不穩", now: at(40))
        check(a.failRetry[bt.uid]?.count == 1 && a.deferred[bt.uid] != nil && a.holds.contains(bt.uid), "失敗：留「需要校正」、排第 1 次重試、仍暫停出聲", "\(r)")
        check(a.tick(now: at(90), env: ok).isEmpty, "還不到 1 分鐘：不重試")
        r = a.tick(now: at(101), env: ok)
        check(a.phase == .waiting && a.batch.map(\.uid) == [bt.uid] && countdowns(r).isEmpty, "1 分鐘到：直接重試（不倒數）", "\(r)")
        r = a.tick(now: at(101.5), env: ok)
        check(starts(r) == [[bt.uid]], "重試開始 --only 藍牙", "\(r)")
        _ = a.finished(measured: [], cancelled: false, message: "", now: at(110))
        check(a.failRetry[bt.uid]?.count == 2, "第 2 次失敗：排 3 分鐘後")
        _ = a.tick(now: at(291), env: ok); _ = a.tick(now: at(291.5), env: ok)
        _ = a.finished(measured: [], cancelled: false, message: "", now: at(300))
        _ = a.tick(now: at(901), env: ok); _ = a.tick(now: at(901.5), env: ok)
        r = a.finished(measured: [], cancelled: false, message: "", now: at(910))
        check(a.failRetry[bt.uid]?.count == 3 && "\(r)".contains("停止自動重試"), "重試 3 次都沒量到：停止自動重試", "\(r)")
        check(a.tick(now: at(5000), env: ok).isEmpty && a.deferred[bt.uid] != nil, "之後不再自動跑，只留「需要校正」")
        // 重試中量到 → 清掉
        let b = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = b.observe([builtin, msi, tv, bt], now: at(1))
        _ = b.tick(now: at(4), env: ok)
        _ = b.finished(measured: [], cancelled: false, message: "", now: at(40))
        _ = b.tick(now: at(101), env: ok); _ = b.tick(now: at(101.5), env: ok)
        _ = b.finished(measured: [bt.uid, builtin.uid], cancelled: false, message: "", now: at(110))
        check(b.failRetry[bt.uid] == nil && b.deferred[bt.uid] == nil && !b.holds.contains(bt.uid), "重試量到：解除暫停、清掉重試與「需要校正」")
        // 使用者停止 → 不重試
        let c = AutoCalibrator(startedAt: t0, holdOnRelaunch: true)
        _ = c.observe([builtin, msi, tv, bt], now: at(1))
        _ = c.tick(now: at(4), env: ok)
        _ = c.finished(measured: [], cancelled: true, message: "", now: at(20))
        check(c.failRetry[bt.uid] == nil && c.tick(now: at(1000), env: ok).isEmpty, "使用者按停止：不自動重試")
    }

    print("── 2026-10-04 app 重開後的藍牙：沿用上次的延遲出聲（不暫停、不倒數；有人在聽時由漂移補償短校正量第一點） ──")
    do {
        let a = AutoCalibrator(startedAt: t0, holdOnRelaunch: false)
        let r = a.observe([builtin, msi, tv, bt], now: at(1))
        check(a.holds.isEmpty && countdowns(r).isEmpty && a.batch.isEmpty && a.deferred.isEmpty, "啟動時藍牙已連：不暫停出聲、不倒數", "\(r)")
        check(a.bluetoothFirstConnected(uid: bt.uid, name: bt.name, hasLatency: true, enabled: true, now: at(2)).isEmpty && a.holds.isEmpty,
              "第一次連上（啟動 30 秒內）：一樣不暫停")
        // 啟動 30 秒後才第一次連上 = 串流重開：照舊暫停＋倒數
        let b = AutoCalibrator(startedAt: t0, holdOnRelaunch: false)
        _ = b.observe([builtin, msi, tv], now: at(1))
        let r2 = b.bluetoothFirstConnected(uid: bt.uid, name: bt.name, hasLatency: true, enabled: true, now: at(60))
        check(b.holds.contains(bt.uid) && !countdowns(r2).isEmpty, "啟動 30 秒後才連上（串流重開）：照舊暫停出聲＋倒數", "\(r2)")
        // 真的斷線重連：照舊
        let c = AutoCalibrator(startedAt: t0, holdOnRelaunch: false)
        _ = c.observe([builtin, msi, tv, bt], now: at(1))
        _ = c.bluetoothReconnected(uid: bt.uid, name: bt.name, hasLatency: true, enabled: true, now: at(100))
        check(c.holds.contains(bt.uid), "真的斷線重連：照舊暫停出聲")
    }

    print(fail == 0 ? "autocal-selftest：全部通過 ✓\(pass) ✗0" : "autocal-selftest：✓\(pass) ✗\(fail)")
    return fail == 0 ? 0 : 1
}
