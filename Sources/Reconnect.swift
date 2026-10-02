// Reconnect.swift — 裝置熱插拔／預設輸出變更／睡眠喚醒後自動 engine.rebuild()
//
// 結構：
//   * 純邏輯元件（RCDebouncer / RCBackoff / RCRateLimiter / OutputSignature / ReconnectRules / RCHealthMonitor）
//     全部是值型別、以「秒（單調時鐘）」為時間參數，不碰 Core Audio，可用虛擬時間單元測試。
//   * ReconnectCore：狀態機（去抖動 → 比較簽章 → 重建／退避重試／速率限制／健康檢查），
//     透過 ReconnectEnvironment 取得裝置與 engine 狀態；同步、單執行緒使用（由 Reconnector 的 serial queue 驅動）。
//   * Reconnector：真實外殼。Core Audio listener（system 的 Devices／DefaultOutputDevice、各子裝置 IsAlive）、
//     DispatchSourceTimer（去抖動到期／重試、每 10 秒健康檢查），全部在自己的 serial queue 上。
//   * runReconnectSelfTest()：純邏輯＋虛擬時間整合模擬自測（不需要實機、不出聲、不動系統設定）。
//
// 防自我觸發：engine.rebuild() 會建立／銷毀私有聚合裝置（UID 前綴 In_Unison42-），會觸發 Devices 事件。
//   1) Devices 事件先和快取的裝置表 diff，變化只有自己的聚合裝置 → 直接忽略；
//   2) 去抖動後一律比較「期望簽章」與「engine 正在用的簽章」，相同就不重建；
//   3) 最後防線：60 秒內最多重建 6 次，超過就冷卻。
//
// 本檔不在即時執行緒上執行任何東西；Engine 的公開方法都可從任何非即時執行緒呼叫。
import CoreAudio
import Foundation

// MARK: - 純邏輯：去抖動

/// 尾端去抖動：最後一次事件後 delay 秒觸發；事件連續不斷時，自第一個事件起最多 maxWait 秒一定觸發一次。
struct RCDebouncer {
    let delay: Double
    let maxWait: Double
    private(set) var firstAt: Double?
    private(set) var lastAt: Double?

    init(delay: Double = 0.5, maxWait: Double = 3.0) {
        self.delay = delay
        self.maxWait = maxWait
    }

    var deadline: Double? {
        guard let f = firstAt, let l = lastAt else { return nil }
        return min(l + delay, f + maxWait)
    }

    mutating func poke(_ now: Double) {
        if firstAt == nil { firstAt = now }
        lastAt = now
    }

    /// 到期就回 true 並清除
    mutating func fireIfDue(_ now: Double) -> Bool {
        guard let d = deadline, now >= d - 1e-9 else { return false }
        firstAt = nil
        lastAt = nil
        return true
    }

    mutating func cancel() { firstAt = nil; lastAt = nil }
}

// MARK: - 純邏輯：指數退避

/// 1, 2, 4, 8 … 上限 cap 秒
struct RCBackoff {
    let base: Double
    let cap: Double
    private(set) var attempt = 0

    init(base: Double = 1, cap: Double = 30) {
        self.base = base
        self.cap = cap
    }

    mutating func next() -> Double {
        let d = min(base * pow(2, Double(min(attempt, 30))), cap)
        attempt += 1
        return d
    }

    mutating func reset() { attempt = 0 }
}

// MARK: - 純邏輯：速率限制（防無窮重建迴圈的最後防線）

struct RCRateLimiter {
    let window: Double
    let limit: Int
    private(set) var stamps: [Double] = []

    init(window: Double = 60, limit: Int = 6) {
        self.window = window
        self.limit = limit
    }

    /// nil = 現在可以；否則回傳最早可以的時間
    mutating func blockedUntil(_ now: Double) -> Double? {
        stamps.removeAll { $0 <= now - window }
        guard stamps.count >= limit else { return nil }
        return stamps[stamps.count - limit] + window
    }

    mutating func record(_ now: Double) { stamps.append(now) }
}

// MARK: - 純邏輯：輸出簽章

/// engine 的輸出組成：entries[0] = 音量來源，其餘順序不重要。比較只看 (uid, AudioObjectID)，不看名稱。
/// AudioObjectID 也要比：同一台裝置拔插後 UID 不變但 ID 會變，engine 手上的舊 ID 讀音量會失效。
struct OutputSignature: Equatable, CustomStringConvertible {
    struct Entry: Hashable {
        let uid: String
        let id: AudioObjectID
        let name: String

        static func == (a: Entry, b: Entry) -> Bool { a.uid == b.uid && a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(uid); h.combine(id) }
    }

    let entries: [Entry]

    var volumeSource: Entry? { entries.first }
    var isEmpty: Bool { entries.isEmpty }

    static func == (a: OutputSignature, b: OutputSignature) -> Bool {
        a.entries.count == b.entries.count
            && a.entries.first == b.entries.first
            && Set(a.entries.dropFirst()) == Set(b.entries.dropFirst())
    }

    /// 例：[Mac mini的揚聲器★, MSI MP242C, 40PFH4082/96]（★＝音量來源）
    var description: String {
        if entries.isEmpty { return "[無]" }
        return "[" + entries.enumerated().map { $0.offset == 0 ? "\($0.element.name)★" : $0.element.name }
            .joined(separator: ", ") + "]"
    }
}

/// 規則計算用的裝置摘要（從 AudioDevice 取，或測試時手造）
struct RCDeviceInfo {
    let uid: String
    let id: AudioObjectID
    let name: String
    let kind: DeviceKind
    let excluded: Bool
    let hasVolumeDb: Bool

    var entry: OutputSignature.Entry { .init(uid: uid, id: id, name: name) }
}

/// 快取的裝置表項目（Devices 事件 diff 用）；uid 讀不到時為空字串
struct RCSeenDevice: Equatable {
    let uid: String
    let name: String
}

enum ReconnectRules {
    /// 期望簽章：Engine.chooseVolumeSource 也呼叫這裡（規則唯一來源）。
    /// physical = Devices.physicalOutputs()（已排除自己的聚合／「全部喇叭」／Continuity／非實體，依 id 排序）。
    /// 音量來源 = 預設輸出（未排除、非聚合、有 VolumeDecibels、在 physical 裡）否則內建喇叭、否則第一個。
    static func desired(physical: [RCDeviceInfo], defaultOutput: RCDeviceInfo?) -> OutputSignature {
        var src: RCDeviceInfo?
        if let d = defaultOutput, !d.excluded, d.kind != .aggregate, d.kind != .autoAggregate,
           d.hasVolumeDb, physical.contains(where: { $0.uid == d.uid }) {
            src = d
        } else {
            src = physical.first { $0.kind == .builtIn } ?? physical.first
        }
        guard let s = src else { return OutputSignature(entries: []) }
        return OutputSignature(entries: [s.entry] + physical.filter { $0.uid != s.uid }.map(\.entry))
    }

    static func isOwn(_ uid: String) -> Bool { uid.hasPrefix(Devices.ownAggregatePrefix) }

    /// 預設輸出不是音量來源時（HDMI／DP 沒有音量、或是「全部喇叭」這類被排除的裝置），macOS 的音量鍵與選單列滑桿
    /// 控制的是預設輸出，調不到音量來源 → 總音量等於鎖死。回傳要印的警告；沒問題回 nil。本程式不會自動改預設輸出。
    static func volumeKeyWarning(defaultOutput d: RCDeviceInfo?, volumeSourceName: String, volumeSourceUID: String) -> String? {
        guard let d, d.uid != volumeSourceUID else { return nil }
        let why: String
        if d.excluded { why = "是本程式不使用的裝置" } else if !d.hasVolumeDb { why = "沒有音量控制" } else { why = "不能當音量來源" }
        return "⚠ 預設輸出是「\(d.name)」（\(why)）：音量鍵／選單列滑桿現在調不到「\(volumeSourceName)」，所有喇叭的總音量等於鎖住。"
            + "請到 系統設定 → 聲音 → 輸出 把預設輸出設回「\(volumeSourceName)」（除了藍牙剛連上 10 秒內會自動切回，本程式不會自動改）"
    }

    /// Devices 事件的 diff：只有自己的聚合裝置增減 → relevant=false。讀不到 UID 的新裝置保守視為 relevant。
    static func deviceChange(old: [AudioObjectID: RCSeenDevice],
                             new: [AudioObjectID: RCSeenDevice]) -> (relevant: Bool, summary: String) {
        var parts: [String] = []
        var relevant = false
        for id in new.keys.sorted() where old[id] == nil {
            let d = new[id]!
            if isOwn(d.uid) { continue }
            relevant = true
            parts.append("+\(d.uid.isEmpty ? "id \(id)" : d.name)")
        }
        for id in old.keys.sorted() where new[id] == nil {
            let d = old[id]!
            if isOwn(d.uid) { continue }
            relevant = true
            parts.append("-\(d.name)")
        }
        for id in new.keys.sorted() {
            if let o = old[id], let n = new[id], o.uid != n.uid, !(isOwn(o.uid) && isOwn(n.uid)) {
                relevant = true
                parts.append("~\(n.name)")
            }
        }
        return (relevant, parts.isEmpty ? "只有自己的聚合裝置變動" : parts.joined(separator: " "))
    }
}

// MARK: - 純邏輯：健康檢查（IOProc 是否還在跑、聚合裝置是否還在）

struct RCHealthMonitor {
    enum Verdict: Equatable {
        case baseline               // 新 generation／剛失效，只記基準
        case ok                     // sampleTime 有前進
        case waiting(Double)        // 停住了但還沒到該重建的時間（秒）
        case stalled(Double)        // 停住夠久 → 該重建（秒）
        case idle                   // 沒前進，但沒有程式在播聲音：tap 的 IO 是 autostart，這是正常待命（不重建、不計停住）
        case aggregateGone          // 基準時看得到自己的聚合裝置，現在看不到
    }

    /// 第一次停住多久就重建（秒）；之後每次加倍
    let firstStall: Double
    let maxWait: Double
    private(set) var stallRebuilds = 0      // 連續因停住而重建的次數（前進就歸零）→ 退避用
    private(set) var everAdvanced = false
    private var baseGen: Int?
    private var baseSample: Int64 = 0
    private var baseAggVisible = false
    private var lastObserve: Double = 0
    private var stallSince: Double?

    init(firstStall: Double = 2, maxWait: Double = 300) {
        self.firstStall = firstStall
        self.maxWait = maxWait
    }

    /// 停住多久就判定停住：固定 firstStall（停住時 tap 把原聲靜音了 → 要快點拆掉）。退避改在拆掉之後等多久再重建（fallbackGap）
    var requiredStall: Double { firstStall }

    /// 這個行程之前跑過的話，前 fastRetries 次停住只等 fastGap 秒就重建（09-30／10-02 實機：校正交接、開機後
    /// 系統音訊服務 20 秒～4.5 分鐘不呼叫 IOProc，權限其實有；舊版 2→4→8…加倍讓恢復後還要多等好幾分鐘）
    static let fastRetries = 10
    static let fastGap: Double = 3

    /// 第 stallRebuilds 次停住後，拆掉攔截（原聲照常出）等多久再重建：之前跑過 → 前 10 次 3 秒；
    /// 從沒跑過（多半是權限）→ firstStall × 2^(n−1) 加倍，上限 maxWait（不會每幾秒就重建一次）
    func fallbackGap(everRan: Bool) -> Double {
        let n = max(stallRebuilds, 1)
        if everRan && n <= Self.fastRetries { return Self.fastGap }
        let k = everRan ? n - Self.fastRetries : n - 1
        return min(firstStall * pow(2, Double(min(max(k, 0), 20))), maxWait)
    }

    mutating func invalidate() { baseGen = nil; stallSince = nil }

    mutating func observe(now: Double, generation: Int, sampleTime: Int64, aggVisible: Bool, audioActive: () -> Bool = { true }) -> Verdict {
        defer { lastObserve = now }
        if baseGen != generation {
            baseGen = generation
            baseSample = sampleTime
            baseAggVisible = aggVisible
            stallSince = nil
            return .baseline
        }
        if baseAggVisible && !aggVisible { return .aggregateGone }
        if aggVisible { baseAggVisible = true }
        if sampleTime != baseSample {
            baseSample = sampleTime
            stallSince = nil
            stallRebuilds = 0
            everAdvanced = true
            return .ok
        }
        // 沒有程式在播：IOProc 本來就還沒被系統啟動（autostart），不算停住；有程式開始播才從那一刻起算
        if !audioActive() { stallSince = nil; return .idle }
        if stallSince == nil { stallSince = lastObserve }
        let dur = now - stallSince!
        if dur >= requiredStall - 1e-6 {
            stallRebuilds += 1
            stallSince = nil
            return .stalled(dur)
        }
        return .waiting(dur)
    }
}

// MARK: - 狀態機

protocol ReconnectEnvironment: AnyObject {
    var engineRunning: Bool { get }
    var engineGeneration: Int { get }
    var engineSampleTime: Int64 { get }
    /// 這個行程裡 engine 曾經真的跑過（IOProc 被呼叫過；重建不歸零）→ 停住不是權限問題
    var engineEverRan: Bool { get }
    /// 有沒有別的程式正在輸出聲音（沒有 → IOProc 沒前進是正常待命）
    var programAudioActive: Bool { get }
    /// IOProc 停住時先拆掉 IOProc／聚合裝置／tap：tap 會把原聲靜音，拆掉後節目音照常從預設輸出出來，等一下再重建
    func stopEngineForFallback()
    /// engine 正在用的輸出（index 0 = 音量來源）
    func engineSignature() -> OutputSignature
    /// 依目前裝置狀態算出的期望輸出
    func desiredSignature() -> OutputSignature
    /// 目前看得到自己的私有聚合裝置嗎
    func ownAggregateVisible() -> Bool
    func rebuildEngine() throws
    func log(_ s: String)
}

/// 單執行緒狀態機；時間參數一律是單調時鐘秒數（真實環境 = uptime，睡眠時不前進）
final class ReconnectCore {
    let env: ReconnectEnvironment
    private(set) var debouncer = RCDebouncer(delay: 0.5, maxWait: 3.0)
    private(set) var backoff = RCBackoff(base: 1, cap: 30)
    private(set) var rate = RCRateLimiter(window: 60, limit: 6)
    private(set) var health = RCHealthMonitor(firstStall: 2, maxWait: 300)
    /// 定期比對裝置組成的間隔（健康檢查每秒一次，但比對簽章要列舉所有裝置，10 秒一次就夠）
    let periodicCheckInterval: Double = 10
    private var lastPeriodicCheck: Double = -.infinity
    /// 睡眠喚醒後：這個時間點 sampleTime 還沒前進就立刻強制重建
    private(set) var postWakeCheckAt: Double?
    private var postWakeBase: Int64 = 0
    private(set) var retryAt: Double?
    private var retryReason: String?
    private var forcePending = false
    private var pendingReasons: [String] = []
    private var knownDevices: [AudioObjectID: RCSeenDevice] = [:]
    private var rateWarned = false
    private var noIOWarned = false
    private(set) var stopped = false

    // 統計（自測／log 用）
    private(set) var evaluations = 0
    private(set) var attempts = 0
    private(set) var successes = 0
    private(set) var failures = 0

    init(env: ReconnectEnvironment) { self.env = env }

    func stop() {
        stopped = true
        debouncer.cancel()
        retryAt = nil
    }

    // MARK: 輸入

    func seedDevices(_ m: [AudioObjectID: RCSeenDevice]) { knownDevices = m }

    /// Devices 清單變了（傳入整份目前清單）
    func devicesChanged(_ m: [AudioObjectID: RCSeenDevice], now: Double) {
        let c = ReconnectRules.deviceChange(old: knownDevices, new: m)
        knownDevices = m
        if c.relevant { noteEvent("裝置清單變動 \(c.summary)", now: now) }
    }

    /// 任何需要重新比對的事件（預設輸出變更、裝置失效、睡眠喚醒…）→ 去抖動
    func noteEvent(_ reason: String, now: Double) {
        guard !stopped else { return }
        if !pendingReasons.contains(reason) {
            if pendingReasons.count < 6 { pendingReasons.append(reason) } else { pendingReasons[5] = "…" }
        }
        debouncer.poke(now)
    }

    /// 手動要求重建（SIGUSR1；診斷／量測重建耗時用）
    func forceRebuild(reason: String, now: Double) {
        guard !stopped else { return }
        attempt(reason: reason, now: now, force: true)
    }

    /// 睡眠喚醒：裝置組成走一般去抖動比對；另外 1 秒後檢查 IO 有沒有前進，沒有就立刻強制重建（不等停住門檻）
    func sleepDetected(gap: Double, now: Double) {
        health.invalidate()
        postWakeCheckAt = now + 1.0
        postWakeBase = env.engineSampleTime
        noteEvent(String(format: "睡眠喚醒（約 %.0f 秒）", gap), now: now)
    }

    /// 下一次需要 wake 的時間（去抖動到期或重試）
    func nextDeadline() -> Double? {
        guard !stopped else { return nil }
        return [debouncer.deadline, retryAt].compactMap { $0 }.min()
    }

    func wake(now: Double) {
        guard !stopped else { return }
        if debouncer.fireIfDue(now) {
            let r = pendingReasons.joined(separator: "；")
            pendingReasons = []
            evaluate(reason: r.isEmpty ? "事件" : r, now: now, force: false)
        }
        if let t = retryAt, now >= t - 1e-9 {
            retryAt = nil
            let f = forcePending
            forcePending = false
            evaluate(reason: "重試：" + (retryReason ?? "?"), now: now, force: f)
        }
    }

    /// 每 1 秒
    func healthTick(now: Double) {
        guard !stopped else { return }
        if let t = postWakeCheckAt, now >= t - 1e-6 {
            postWakeCheckAt = nil
            if env.engineRunning && env.engineSampleTime == postWakeBase && env.programAudioActive {
                attempt(reason: "睡眠喚醒後 1 秒 IOProc 沒有前進", now: now, force: true)
                return
            }
        }
        guard env.engineRunning else {
            health.invalidate()
            if retryAt == nil && debouncer.deadline == nil {
                evaluate(reason: "健康檢查：engine 未運轉", now: now, force: false)
            }
            return
        }
        let v = health.observe(now: now, generation: env.engineGeneration,
                               sampleTime: env.engineSampleTime, aggVisible: env.ownAggregateVisible(),
                               audioActive: { env.programAudioActive })
        switch v {
        case .baseline, .waiting, .idle:
            break
        case .ok:
            // 保險：漏接事件時靠這裡補（簽章相同就什麼都不做）；10 秒一次
            if debouncer.deadline == nil && retryAt == nil && now - lastPeriodicCheck >= periodicCheckInterval - 1e-6 {
                lastPeriodicCheck = now
                evaluate(reason: "定期檢查：裝置組成不符", now: now, force: false)
            }
        case .stalled(let d):
            let everRan = health.everAdvanced || env.engineEverRan
            if !everRan && !noIOWarned {
                noIOWarned = true
                env.log("⚠ IOProc 從未前進：多半是「系統音訊錄製」權限未授與；之後每次重建間隔加倍（上限 \(Int(health.maxWait)) 秒），授權後會自動恢復")
            }
            let gap = health.fallbackGap(everRan: everRan)
            env.stopEngineForFallback()
            health.invalidate()
            retryAt = now + gap
            retryReason = String(format: "IOProc 停住 %.0f 秒", d)
            forcePending = true
            env.log(String(format: "⚠ IOProc 停住 %.0f 秒（%@）→ 先拆掉攔截（節目音照常從預設輸出出來），%.0f 秒後重建（連續第 %d 次）",
                           d, everRan ? "這個 app 之前跑過，不是權限問題，多半是系統音訊服務暫時沒回應" : "從沒跑過，多半是權限",
                           gap, health.stallRebuilds))
        case .aggregateGone:
            attempt(reason: "私有聚合裝置消失", now: now, force: true)
        }
    }

    // MARK: 內部

    private func evaluate(reason: String, now: Double, force: Bool) {
        evaluations += 1
        if force || !env.engineRunning {
            attempt(reason: env.engineRunning ? reason : reason + "（engine 未運轉）", now: now, force: force)
            return
        }
        if env.engineSignature() == env.desiredSignature() {
            if !reason.hasPrefix("定期檢查") {
                env.log("事件（\(reason)）：輸出組成不變 \(env.engineSignature())，不需重建")
            }
            // 已一致：之前排的重試不需要了
            if retryAt != nil && !forcePending { retryAt = nil; retryReason = nil }
            backoff.reset()
            return
        }
        attempt(reason: reason, now: now, force: false)
    }

    private func attempt(reason: String, now: Double, force: Bool) {
        if let until = rate.blockedUntil(now) {
            retryAt = max(retryAt ?? until, until)
            retryReason = reason
            if force { forcePending = true }
            if !rateWarned {
                rateWarned = true
                env.log(String(format: "⚠ %.0f 秒內已重建 %d 次，暫停 %.1f 秒（防止重建迴圈）；原因：%@",
                               rate.window, rate.limit, until - now, reason))
            }
            return
        }
        rateWarned = false
        rate.record(now)
        attempts += 1
        let before = env.engineSignature()
        let genBefore = env.engineGeneration
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            try env.rebuildEngine()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            successes += 1
            backoff.reset()
            retryAt = nil
            retryReason = nil
            forcePending = false
            health.invalidate()
            env.log(String(format: "↻ 重建 gen %d→%d（%@）：%@ → %@，耗時 %.0f ms",
                           genBefore, env.engineGeneration, reason, before.description,
                           env.engineSignature().description, ms))
        } catch {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            failures += 1
            let d = backoff.next()
            retryAt = now + d
            retryReason = reason
            if force { forcePending = true }
            env.log(String(format: "✗ 重建失敗（%@）：%@；%@ → 失敗，耗時 %.0f ms；%.0f 秒後重試（連續第 %d 次失敗）",
                           reason, "\(error)", before.description, ms, d, backoff.attempt))
        }
    }
}

// MARK: - 真實環境

private final class LiveReconnectEnv: ReconnectEnvironment {
    let engine: Engine
    var logger: (String) -> Void = { print($0) }

    init(engine: Engine) { self.engine = engine }

    var engineRunning: Bool { engine.isRunning }
    var engineGeneration: Int { engine.generation }
    var engineSampleTime: Int64 { engine.sampleTime }
    var engineEverRan: Bool { engine.ioCycles > 0 }
    var programAudioActive: Bool { SystemSoundsRouter.otherProgramPlaying() }
    func stopEngineForFallback() { engine.stop() }

    func engineSignature() -> OutputSignature {
        OutputSignature(entries: engine.outputDetails.map { .init(uid: $0.uid, id: $0.deviceID, name: $0.name) })
    }

    static func info(_ d: AudioDevice, withVolume: Bool) -> RCDeviceInfo {
        RCDeviceInfo(uid: d.uid, id: d.id, name: d.name, kind: d.kind, excluded: Devices.isExcluded(d),
                     hasVolumeDb: withVolume ? Devices.hasVolumeDecibels(d.id) : false)
    }

    func desiredSignature() -> OutputSignature {
        let phys = Devices.physicalOutputs().map { Self.info($0, withVolume: false) }
        let def = Devices.defaultOutput().map { Self.info($0, withVolume: true) }
        return ReconnectRules.desired(physical: phys, defaultOutput: def)
    }

    func ownAggregateVisible() -> Bool {
        CA.ids(CA.system, kAudioHardwarePropertyDevices).contains {
            ReconnectRules.isOwn(CA.string($0, kAudioDevicePropertyDeviceUID) ?? "")
        }
    }

    func rebuildEngine() throws { try engine.rebuild() }

    func log(_ s: String) { logger(s) }

    /// 目前裝置表（只讀 UID 與名稱，便宜）
    static func deviceTable() -> [AudioObjectID: RCSeenDevice] {
        var m: [AudioObjectID: RCSeenDevice] = [:]
        for id in CA.ids(CA.system, kAudioHardwarePropertyDevices) {
            m[id] = RCSeenDevice(uid: CA.string(id, kAudioDevicePropertyDeviceUID) ?? "",
                                 name: CA.string(id, kAudioObjectPropertyName) ?? "?")
        }
        return m
    }
}

// MARK: - Reconnector（main.swift 用：Reconnector(engine:).start()）

extension Devices {
    /// 規則計算用摘要（含 VolumeDecibels）
    static func rcInfo(_ d: AudioDevice) -> RCDeviceInfo {
        RCDeviceInfo(uid: d.uid, id: d.id, name: d.name, kind: d.kind, excluded: Devices.isExcluded(d),
                     hasVolumeDb: Devices.hasVolumeDecibels(d.id))
    }
}

final class Reconnector {
    /// 健康檢查間隔：1 秒（睡眠喚醒靠牆鐘／單調時鐘差偵測，間隔越短越快發現；每次只讀幾個數值，很便宜）
    static let healthInterval: Double = 1
    /// 牆鐘比單調時鐘多走這麼多秒 → 視為剛睡醒
    static let sleepGapThreshold: Double = 3

    private let engine: Engine
    private let env: LiveReconnectEnv
    private let core: ReconnectCore
    private let queue = DispatchQueue(label: "In_Unison42.reconnect", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()

    private var wakeTimer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var aliveListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var started = false
    private var cleanupID: Int?
    private var lastWall = Date()
    private var lastUp = Reconnector.uptime()

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init(engine: Engine) {
        self.engine = engine
        env = LiveReconnectEnv(engine: engine)
        core = ReconnectCore(env: env)
        env.logger = { s in print("[重接 \(Reconnector.tsFormatter.string(from: Date()))] \(s)") }
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    /// 單調時鐘（秒，不含睡眠）
    static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    private func onQueue(_ f: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { f() } else { queue.sync(execute: f) }
    }

    func start() {
        onQueue {
            guard !started else { return }
            started = true
            core.seedDevices(LiveReconnectEnv.deviceTable())
            lastWall = Date()
            lastUp = Self.uptime()

            // system listeners
            for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
                var a = CA.addr(sel)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onSystemChange(sel) }
                let st = AudioObjectAddPropertyListenerBlock(CA.system, &a, queue, block)
                if st == noErr {
                    systemListeners.append((a, block))
                } else {
                    env.log("⚠ 無法監聽 \(CA.fourCC(sel))：status=\(st)（只靠每 \(Int(Self.healthInterval)) 秒的定期檢查）")
                }
            }

            // 去抖動／重試計時器
            let w = DispatchSource.makeTimerSource(queue: queue)
            w.schedule(deadline: .distantFuture)
            w.setEventHandler { [weak self] in
                guard let self else { return }
                self.core.wake(now: Self.uptime())
                self.afterCoreWork()
            }
            w.resume()
            wakeTimer = w

            // 健康檢查
            let h = DispatchSource.makeTimerSource(queue: queue)
            h.schedule(deadline: .now() + Self.healthInterval, repeating: Self.healthInterval, leeway: .milliseconds(200))
            h.setEventHandler { [weak self] in self?.onHealthTick() }
            h.resume()
            healthTimer = h

            refreshAliveListeners()
            engine.onFormatChange = { [weak self] msg in self?.requestRebuild(msg) }
            cleanupID = Cleanup.register { [weak self] in self?.stop() }
            env.log("啟動：監聽裝置清單／預設輸出／子裝置存活，去抖動 \(Int(core.debouncer.delay * 1000)) ms，每 \(Int(Self.healthInterval)) 秒健康檢查；目前輸出 \(env.engineSignature())")
        }
    }

    /// 立即強制重建一次（main 的 SIGUSR1 處理用）
    func requestRebuild(_ reason: String) {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.core.forceRebuild(reason: reason, now: Self.uptime())
            self.afterCoreWork()
        }
    }

    /// 停止監聽（SIGINT/SIGTERM 時 Cleanup 會先呼叫，避免 engine.stop() 之後又被重建）
    func stop() {
        onQueue {
            guard started else { return }
            started = false
            core.stop()
            wakeTimer?.cancel(); wakeTimer = nil
            healthTimer?.cancel(); healthTimer = nil
            for (addr, block) in systemListeners {
                var a = addr
                AudioObjectRemovePropertyListenerBlock(CA.system, &a, queue, block)
            }
            systemListeners = []
            removeAliveListeners(except: [])
            engine.onFormatChange = nil
            if let id = cleanupID { Cleanup.unregister(id); cleanupID = nil }
        }
    }

    // MARK: 事件處理（都在 queue 上）

    private func onSystemChange(_ sel: AudioObjectPropertySelector) {
        guard started else { return }
        let now = Self.uptime()
        if sel == kAudioHardwarePropertyDevices {
            core.devicesChanged(LiveReconnectEnv.deviceTable(), now: now)
        } else {
            let def = Devices.defaultOutput()
            core.noteEvent("預設輸出變更 → \(def?.name ?? "無")", now: now)
            // 事件當下就提醒（不等重建）：新的預設輸出若不是音量來源，音量鍵會調不到
            let want = env.desiredSignature().volumeSource
            if let v = want, let w = ReconnectRules.volumeKeyWarning(defaultOutput: def.map(Devices.rcInfo),
                                                                   volumeSourceName: v.name, volumeSourceUID: v.uid) {
                env.log(w)
            }
        }
        afterCoreWork()
    }

    private func onHealthTick() {
        guard started else { return }
        let now = Self.uptime()
        let wall = Date()
        let gap = wall.timeIntervalSince(lastWall) - (now - lastUp)
        lastWall = wall
        lastUp = now
        if gap > Self.sleepGapThreshold { core.sleepDetected(gap: gap, now: now) }
        core.healthTick(now: now)
        afterCoreWork()
    }

    private func afterCoreWork() {
        guard started else { return }
        refreshAliveListeners()
        guard let w = wakeTimer else { return }
        if let d = core.nextDeadline() {
            let delta = max(0, d - Self.uptime())
            w.schedule(deadline: .now() + delta, repeating: .never, leeway: .milliseconds(20))
        } else {
            w.schedule(deadline: .distantFuture)
        }
    }

    /// engine 目前子裝置的 IsAlive listener 與 outputDetails 同步
    private func refreshAliveListeners() {
        let want = Dictionary(engine.outputDetails.map { ($0.deviceID, $0.name) }, uniquingKeysWith: { a, _ in a })
        removeAliveListeners(except: Set(want.keys))
        for (id, name) in want where aliveListeners[id] == nil {
            var a = CA.addr(kAudioDevicePropertyDeviceIsAlive)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.started else { return }
                let alive = (CA.u32(id, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
                self.core.noteEvent("\(name) \(alive ? "恢復" : "失效")", now: Self.uptime())
                self.afterCoreWork()
            }
            if AudioObjectAddPropertyListenerBlock(id, &a, queue, block) == noErr {
                aliveListeners[id] = block
            }
        }
    }

    private func removeAliveListeners(except keep: Set<AudioObjectID>) {
        for (id, block) in aliveListeners where !keep.contains(id) {
            var a = CA.addr(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)   // 裝置已消失時會失敗，忽略
            aliveListeners[id] = nil
        }
    }
}

// MARK: - 自測（純邏輯＋虛擬時間模擬；不碰 Core Audio 寫入、不出聲）

private final class RCFakeEnv: ReconnectEnvironment {
    var physical: [RCDeviceInfo]
    var defaultOut: RCDeviceInfo?
    var running = true
    var gen = 1
    var sample: Int64 = 0
    var ioAlive = true
    var aggVisible = true
    var sig: OutputSignature
    var failRemaining = 0
    var failForever = false
    var now: Double = 0
    var rebuildTimes: [Double] = []
    var onRebuild: (() -> Void)?
    var logs: [String] = []
    var echo = false

    init(physical: [RCDeviceInfo], defaultOut: RCDeviceInfo?) {
        self.physical = physical
        self.defaultOut = defaultOut
        sig = ReconnectRules.desired(physical: physical, defaultOutput: defaultOut)
    }

    var engineRunning: Bool { running }
    var engineGeneration: Int { gen }
    var engineSampleTime: Int64 { sample }
    var everRan = false
    var engineEverRan: Bool { everRan }
    var audioActive = true
    var programAudioActive: Bool { audioActive }
    var fallbackStops: [Double] = []
    func stopEngineForFallback() { fallbackStops.append(now); running = false; sig = OutputSignature(entries: []) }
    func engineSignature() -> OutputSignature { running ? sig : OutputSignature(entries: []) }
    func desiredSignature() -> OutputSignature { ReconnectRules.desired(physical: physical, defaultOutput: defaultOut) }
    func ownAggregateVisible() -> Bool { running && aggVisible }
    func rebuildEngine() throws {
        rebuildTimes.append(now)
        if failForever || failRemaining > 0 {
            failRemaining -= 1
            running = false
            sig = OutputSignature(entries: [])
            throw EngineError.noOutputs
        }
        sig = desiredSignature()
        running = true
        gen += 1
        aggVisible = true
        onRebuild?()
    }
    func log(_ s: String) {
        let line = String(format: "    [t=%7.2f] ", now) + s
        logs.append(line)
        if echo { print(line) }
    }
}

/// 虛擬時間模擬器：10 ms 一步、每 1 秒健康檢查；engine 在跑且 ioAlive 時 sampleTime 前進 480 frame／步（48 kHz）
private final class RCSim {
    let env: RCFakeEnv
    let core: ReconnectCore
    private(set) var tick = 0
    private var actions: [(tick: Int, f: () -> Void)] = []
    static let dt = 0.01

    init(env: RCFakeEnv, devices: [AudioObjectID: RCSeenDevice]) {
        self.env = env
        core = ReconnectCore(env: env)
        core.seedDevices(devices)
    }

    var now: Double { Double(tick) * Self.dt }

    func at(_ t: Double, _ f: @escaping () -> Void) {
        actions.append((Int((t / Self.dt).rounded()), f))
    }

    func run(until t: Double) {
        let end = Int((t / Self.dt).rounded())
        while tick < end {
            tick += 1
            env.now = now
            if env.running && env.ioAlive { env.sample += 480; env.everRan = true }
            let due = actions.filter { $0.tick == tick }
            actions.removeAll { $0.tick <= tick }
            for a in due { a.f() }
            if let d = core.nextDeadline(), d <= now + 1e-9 { core.wake(now: now) }
            if tick % 100 == 0 { core.healthTick(now: now) }   // 每 1 秒
        }
    }
}

/// 回傳 0＝全部通過
func runReconnectSelfTest(verbose: Bool = false) -> Int32 {
    var pass = 0
    var fail = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        if ok { pass += 1; print("  ✓ \(name)\(detail.isEmpty ? "" : "（\(detail)）")") }
        else { fail += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "（\(detail)）")") }
    }
    func near(_ a: Double, _ b: Double, _ tol: Double = 0.02) -> Bool { abs(a - b) <= tol }
    func fmt(_ xs: [Double]) -> String { "[" + xs.map { String(format: "%.2f", $0) }.joined(separator: ", ") + "]" }

    // 測試用裝置
    let B = RCDeviceInfo(uid: "BuiltInSpeakerDevice", id: 50, name: "Mac mini的揚聲器", kind: .builtIn, excluded: false, hasVolumeDb: true)
    let H = RCDeviceInfo(uid: "3669B030-HDMI", id: 60, name: "MSI MP242C", kind: .hdmi, excluded: false, hasVolumeDb: false)
    let H2 = RCDeviceInfo(uid: "3669B030-HDMI", id: 61, name: "MSI MP242C", kind: .hdmi, excluded: false, hasVolumeDb: false)
    let D = RCDeviceInfo(uid: "40C88240-DP", id: 70, name: "40PFH4082/96", kind: .displayPort, excluded: false, hasVolumeDb: false)
    let U = RCDeviceInfo(uid: "USB-SPK", id: 90, name: "USB 喇叭", kind: .usb, excluded: false, hasVolumeDb: true)
    let ALL = RCDeviceInfo(uid: "com.example.multioutput.all", id: 100, name: "全部喇叭", kind: .aggregate, excluded: true, hasVolumeDb: true)
    func seen(_ ds: [RCDeviceInfo], own: [AudioObjectID] = []) -> [AudioObjectID: RCSeenDevice] {
        var m: [AudioObjectID: RCSeenDevice] = [:]
        for d in ds { m[d.id] = RCSeenDevice(uid: d.uid, name: d.name) }
        m[80] = RCSeenDevice(uid: "C270-MIC", name: "C270 HD WEBCAM")
        m[100] = RCSeenDevice(uid: ALL.uid, name: ALL.name)
        for o in own { m[o] = RCSeenDevice(uid: Devices.ownAggregatePrefix + "\(o)", name: "In_Unison42") }
        return m
    }

    print("── 1. 去抖動 RCDebouncer ──")
    do {
        var db = RCDebouncer(delay: 0.5, maxWait: 3)
        db.poke(0); db.poke(0.2); db.poke(0.4)
        check(near(db.deadline ?? -1, 0.9, 1e-9), "三個事件 0/0.2/0.4 → 0.9 觸發", "deadline=\(db.deadline ?? -1)")
        check(!db.fireIfDue(0.85), "0.85 未到期")
        check(db.fireIfDue(0.9), "0.9 到期觸發")
        check(db.deadline == nil, "觸發後清空")
        var db2 = RCDebouncer(delay: 0.5, maxWait: 3)
        var fired: [Double] = []
        for i in 0...1000 {
            let t = Double(i) * 0.01
            if i % 30 == 0 { db2.poke(t) }          // 每 0.3 秒一個事件，永不停
            if db2.fireIfDue(t) { fired.append(t) }
        }
        check(!fired.isEmpty && near(fired[0], 3.0, 0.011), "事件不停也在 maxWait=3 秒觸發", "觸發於 \(fmt(fired))")
    }

    print("── 2. 退避 RCBackoff ──")
    do {
        var b = RCBackoff(base: 1, cap: 30)
        let seq = (0..<8).map { _ in b.next() }
        check(seq == [1, 2, 4, 8, 16, 30, 30, 30], "1,2,4,8,16,30,30,30", "\(seq)")
        b.reset()
        check(b.next() == 1, "reset 後回到 1")
    }

    print("── 3. 速率限制 RCRateLimiter ──")
    do {
        var r = RCRateLimiter(window: 60, limit: 6)
        for t in [0.0, 1, 2, 3, 4, 5] { _ = r.blockedUntil(t); r.record(t) }
        check(r.blockedUntil(10) == 60, "60 秒內第 7 次被擋到 t=60", "\(r.blockedUntil(10) ?? -1)")
        check(r.blockedUntil(60.01) == nil, "t=60.01 放行")
    }

    print("── 4. 簽章比較與期望規則 ──")
    do {
        let s1 = OutputSignature(entries: [B.entry, H.entry, D.entry])
        let s2 = OutputSignature(entries: [B.entry, D.entry, H.entry])
        check(s1 == s2, "非音量來源順序不同 → 相等")
        let s3 = OutputSignature(entries: [H.entry, B.entry, D.entry])
        check(s1 != s3, "音量來源不同 → 不等")
        let s4 = OutputSignature(entries: [B.entry, H2.entry, D.entry])
        check(s1 != s4, "同 UID 但 AudioObjectID 變了（重插）→ 不等")
        let s5 = OutputSignature(entries: [B.entry, H.entry])
        check(s1 != s5, "少一台 → 不等")
        let renamed = OutputSignature(entries: [B.entry, .init(uid: H.uid, id: H.id, name: "改名"), D.entry])
        check(s1 == renamed, "只有名稱不同 → 相等")
        let phys = [B, H, D]
        check(ReconnectRules.desired(physical: phys, defaultOutput: B).volumeSource?.uid == B.uid, "預設=內建 → 內建是音量來源")
        check(ReconnectRules.desired(physical: phys, defaultOutput: H).volumeSource?.uid == B.uid, "預設=HDMI（無音量）→ 仍是內建")
        check(ReconnectRules.desired(physical: phys, defaultOutput: ALL).volumeSource?.uid == B.uid, "預設=「全部喇叭」（排除）→ 內建")
        check(ReconnectRules.desired(physical: phys, defaultOutput: nil) == s1, "無預設 → [內建★, HDMI, DP]")
        check(ReconnectRules.desired(physical: phys + [U], defaultOutput: U).volumeSource?.uid == U.uid, "預設=有音量的 USB 喇叭 → USB 是音量來源")
        check(ReconnectRules.desired(physical: [H, D], defaultOutput: H).volumeSource?.uid == H.uid, "沒有內建 → 第一個實體輸出")
        check(ReconnectRules.desired(physical: [], defaultOutput: B).isEmpty, "沒有實體輸出 → 空簽章")
        check(!ReconnectRules.desired(physical: phys, defaultOutput: nil).entries.contains { $0.uid == ALL.uid }, "「全部喇叭」不會成為子裝置（physical 已排除）")
    }

    print("── 5. 裝置清單 diff（自己的聚合裝置不算）──")
    do {
        let base = seen([B, H, D], own: [200])
        let c1 = ReconnectRules.deviceChange(old: base, new: seen([B, H, D], own: [201]))
        check(!c1.relevant, "自己的聚合 200→201 → 忽略", c1.summary)
        let c2 = ReconnectRules.deviceChange(old: base, new: seen([B, D], own: [200]))
        check(c2.relevant, "HDMI 拔掉 → 相關", c2.summary)
        let c3 = ReconnectRules.deviceChange(old: base, new: seen([B, H2, D], own: [201]))
        check(c3.relevant, "HDMI 重插（新 id）＋聚合替換 → 相關", c3.summary)
        var withUnknown = base
        withUnknown[300] = RCSeenDevice(uid: "", name: "?")
        check(ReconnectRules.deviceChange(old: base, new: withUnknown).relevant, "讀不到 UID 的新裝置 → 保守視為相關")
        check(!ReconnectRules.deviceChange(old: base, new: base).relevant, "沒變 → 忽略")
    }

    print("── 6. 健康檢查 RCHealthMonitor（每秒一次，停 2 秒就判定停住）──")
    do {
        var h = RCHealthMonitor(firstStall: 2, maxWait: 300)
        check(h.observe(now: 0, generation: 1, sampleTime: 0, aggVisible: true) == .baseline, "第一次 → 基準")
        check(h.observe(now: 1, generation: 1, sampleTime: 48_000, aggVisible: true) == .ok, "前進 → ok")
        check(h.observe(now: 2, generation: 1, sampleTime: 48_000, aggVisible: true) == .waiting(1), "停 1 秒 → 等")
        check(h.observe(now: 3, generation: 1, sampleTime: 48_000, aggVisible: true) == .stalled(2), "停 2 秒 → 重建")
        check(h.observe(now: 4, generation: 2, sampleTime: 48_000, aggVisible: true) == .baseline, "新 generation → 重設基準")
        // 停住判定固定 2 秒（停住時 tap 靜音了原聲，要快拆）；加倍改在「拆掉後等多久再重建」（fallbackGap）
        check(h.observe(now: 6, generation: 2, sampleTime: 48_000, aggVisible: true) == .stalled(2), "再停：一樣 2 秒就判定")
        check(h.stallRebuilds == 2 && h.fallbackGap(everRan: true) == 3 && h.fallbackGap(everRan: false) == 4,
              "第 2 次：之前跑過等 3 秒；從沒跑過等 4 秒（加倍）", "\(h.fallbackGap(everRan: true))／\(h.fallbackGap(everRan: false))")
        check(h.observe(now: 9, generation: 3, sampleTime: 48_000, aggVisible: true) == .baseline, "gen 3 基準")
        check(h.observe(now: 10, generation: 3, sampleTime: 96_000, aggVisible: true) == .ok && h.stallRebuilds == 0, "恢復前進 → 停住次數歸零")
        check(h.observe(now: 11, generation: 3, sampleTime: 144_000, aggVisible: false) == .aggregateGone, "聚合裝置消失 → aggregateGone")
        var h2 = RCHealthMonitor(firstStall: 2, maxWait: 300)
        _ = h2.observe(now: 0, generation: 1, sampleTime: 0, aggVisible: false)
        check(h2.observe(now: 1, generation: 1, sampleTime: 48_000, aggVisible: false) == .ok, "基準就看不到聚合（私有裝置不列出時）→ 不誤判消失")
        var h3 = RCHealthMonitor(firstStall: 2, maxWait: 60)
        _ = h3.observe(now: 0, generation: 1, sampleTime: 0, aggVisible: true)
        for k in 1...400 { _ = h3.observe(now: Double(k), generation: 1, sampleTime: 0, aggVisible: true) }
        check(h3.requiredStall == 2 && h3.fallbackGap(everRan: false) == 60 && h3.fallbackGap(everRan: true) == 60,
              "一直停：等待封頂 maxWait（之前跑過的也在快速 10 次後加倍到封頂）", "\(h3.fallbackGap(everRan: false))")
    }

    let phys0 = [B, H, D]

    print("── 7. 模擬：HDMI 拔掉 → 重建一次；重建引起的自己聚合裝置事件不會再觸發 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        var agg: AudioObjectID = 200
        env.onRebuild = { [unowned sim, unowned env] in
            agg += 1
            let a = agg
            sim.at(env.now + 0.05) { sim.core.devicesChanged(seen(env.physical, own: [a]), now: sim.now) }
        }
        sim.at(5) { env.physical = [B, D]; sim.core.devicesChanged(seen(env.physical, own: [agg]), now: sim.now) }
        sim.run(until: 120)
        check(env.rebuildTimes.count == 1 && near(env.rebuildTimes[0], 5.5), "只重建 1 次，於 5.5 秒", fmt(env.rebuildTimes))
        check(env.sig == OutputSignature(entries: [B.entry, D.entry]), "重建後 = [內建★, DP]", env.sig.description)
        check(env.logs.contains { $0.contains("↻ 重建") && $0.contains("MSI MP242C") && $0.contains("耗時") }, "log 含原因、前後名單、耗時",
              env.logs.first { $0.contains("↻") }?.trimmingCharacters(in: .whitespaces) ?? "無")
    }

    print("── 8. 模擬：就算自我事件沒被過濾（直接 poke），簽章相同也不會重建（無窮迴圈防護 2）──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        env.onRebuild = { [unowned sim, unowned env] in
            sim.at(env.now + 0.05) { sim.core.noteEvent("假自我事件", now: sim.now) }
            sim.at(env.now + 0.30) { sim.core.noteEvent("假自我事件 2", now: sim.now) }
        }
        sim.at(5) { env.physical = [B, D]; sim.core.noteEvent("HDMI 拔掉", now: sim.now) }
        sim.run(until: 120)
        check(env.rebuildTimes.count == 1, "只重建 1 次", fmt(env.rebuildTimes))
        check(sim.core.evaluations >= 2, "自我事件確實被評估過但跳過", "evaluations=\(sim.core.evaluations)")
    }

    print("── 9. 模擬：熱插拔抖動（0.1 秒一次、共 10 次）→ 最後一次後 0.5 秒只重建 1 次 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        for k in 0..<10 {
            let t = 5 + Double(k) * 0.1
            let plugged = k % 2 == 1          // 最後一次（k=9）是插上，而且是新 id 61
            sim.at(t) {
                env.physical = plugged ? [B, H2, D] : [B, D]
                sim.core.devicesChanged(seen(env.physical, own: [200]), now: sim.now)
            }
        }
        sim.run(until: 60)
        check(env.rebuildTimes.count == 1 && near(env.rebuildTimes[0], 5.9 + 0.5), "只重建 1 次，於 6.40 秒", fmt(env.rebuildTimes))
        check(env.sig.entries.contains { $0.id == 61 }, "用的是新 id 61 的 HDMI", env.sig.description)
    }

    print("── 10. 模擬：預設輸出變更 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        sim.at(5) { env.defaultOut = H; sim.core.noteEvent("預設輸出 → HDMI", now: sim.now) }
        sim.run(until: 10)
        check(env.rebuildTimes.isEmpty, "預設切到 HDMI（無音量）→ 音量來源仍是內建，不重建")
        sim.at(15) { env.defaultOut = ALL; sim.core.noteEvent("預設輸出 → 全部喇叭", now: sim.now) }
        sim.run(until: 20)
        check(env.rebuildTimes.isEmpty, "預設切到「全部喇叭」→ 不重建")
        sim.at(25) { env.physical = [B, H, D, U]; sim.core.devicesChanged(seen(env.physical, own: [200]), now: sim.now) }
        sim.at(30) { env.defaultOut = U; sim.core.noteEvent("預設輸出 → USB", now: sim.now) }
        sim.run(until: 40)
        check(env.rebuildTimes.count == 2 && env.sig.volumeSource?.uid == U.uid, "插 USB 喇叭（重建）→ 設為預設（再重建，音量來源 = USB）",
              "\(fmt(env.rebuildTimes)) \(env.sig)")
        sim.at(45) { env.defaultOut = B; sim.core.noteEvent("預設輸出 → 內建", now: sim.now) }
        sim.run(until: 50)
        check(env.rebuildTimes.count == 3 && env.sig.volumeSource?.uid == B.uid, "切回內建 → 再重建一次", env.sig.description)
    }

    print("── 11. 模擬：重建失敗 5 次 → 退避 1,2,4,8,16 秒後成功 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        env.failRemaining = 5
        sim.at(5) { env.physical = [B, D]; sim.core.noteEvent("HDMI 拔掉", now: sim.now) }
        sim.run(until: 120)
        let gaps = zip(env.rebuildTimes.dropFirst(), env.rebuildTimes).map { $0 - $1 }
        check(env.rebuildTimes.count == 6, "共嘗試 6 次", fmt(env.rebuildTimes))
        check(gaps.count == 5 && zip(gaps, [1.0, 2, 4, 8, 16]).allSatisfy { near($0, $1) }, "間隔 1,2,4,8,16", fmt(gaps))
        check(env.running && env.sig == OutputSignature(entries: [B.entry, D.entry]), "最後成功、engine 運轉")
        check(sim.core.backoff.attempt == 0, "成功後退避歸零")
    }

    print("── 12. 模擬：一直失敗 10 分鐘 → 不當掉、間隔封頂 30 秒 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        env.failForever = true
        sim.at(5) { env.physical = [B, D]; sim.core.noteEvent("HDMI 拔掉", now: sim.now) }
        sim.run(until: 600)
        let gaps = zip(env.rebuildTimes.dropFirst(), env.rebuildTimes).map { $0 - $1 }
        check((gaps.max() ?? 0) <= 30.02, "最大間隔 ≤ 30 秒", String(format: "max=%.2f, 次數=%d", gaps.max() ?? 0, env.rebuildTimes.count))
        check(gaps.suffix(5).allSatisfy { near($0, 30) }, "穩態每 30 秒一次", fmt(Array(gaps.suffix(5))))
        env.failForever = false
        sim.run(until: 640)
        check(env.running, "恢復後下一次重試成功")
    }

    print("── 13. 模擬：IOProc 停住（之前跑過：睡醒／校正交接後 IO 不動）→ 2 秒內先拆掉攔截讓原聲照常出，3 秒後重建 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        var runningDuringGap: [Bool] = []
        sim.at(25) { env.ioAlive = false }
        sim.at(28.5) { runningDuringGap.append(env.running) }
        sim.run(until: 45)
        let stops = env.fallbackStops, rebuilds = env.rebuildTimes
        check(!stops.isEmpty && stops[0] <= 27.01, "停住 ≤ 2 秒就拆掉攔截", fmt(stops))
        check(runningDuringGap == [false], "等重建期間 engine 是停的（tap 拆掉 → 原聲照常從預設輸出出來）")
        check(zip(rebuilds, stops).allSatisfy { near($0 - $1, 3) }, "每次都是拆掉後 3 秒重建（不加倍）", "停 \(fmt(stops)) 建 \(fmt(rebuilds))")
        check(env.logs.contains { $0.contains("不是權限問題") } && !env.logs.contains { $0.contains("多半是「系統音訊錄製」權限") },
              "之前跑過：log 說不是權限問題")
        env.ioAlive = true
        let n = rebuilds.count
        sim.run(until: 400)
        check(env.running && env.rebuildTimes.count <= n + 1 && env.fallbackStops.count == stops.count, "恢復後不再拆／重建", fmt(env.rebuildTimes))
        check(sim.core.health.stallRebuilds == 0, "前進後停住次數歸零")
    }

    print("── 13b. 模擬：之前跑過但一直停住 → 前 10 次每 3 秒重試，之後才加倍（不會整晚每 5 秒拆一次）──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        sim.at(25) { env.ioAlive = false }
        sim.run(until: 3600)
        let gaps = zip(env.rebuildTimes, env.fallbackStops).map { $0 - $1 }
        check(gaps.count > 12 && gaps.prefix(10).allSatisfy { $0 < 3.5 + 60 } && (gaps.max() ?? 0) > 60, "先快後慢", fmt(Array(gaps.prefix(14))))
        check(env.rebuildTimes.count <= 40, "一小時內重建 ≤ 40 次", "\(env.rebuildTimes.count) 次")
    }

    print("── 13c. 模擬：沒有程式在播（tap 的 IO 是 autostart，還沒被啟動）→ 正常待命：不拆、不重建、不說權限 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        env.ioAlive = false
        env.audioActive = false
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        sim.run(until: 600)
        check(env.fallbackStops.isEmpty && env.rebuildTimes.isEmpty && env.running, "10 分鐘沒聲音：攔截保留、不重建", "停 \(fmt(env.fallbackStops)) 建 \(fmt(env.rebuildTimes))")
        check(!env.logs.contains { $0.contains("權限") || $0.contains("停住") }, "不說權限、不說停住")
        // 開始播 → 系統啟動 IO（autostart）→ 正常
        env.audioActive = true; env.ioAlive = true
        sim.run(until: 700)
        check(env.fallbackStops.isEmpty && env.rebuildTimes.isEmpty, "開始播、IO 跟著啟動：什麼都不用做")
        // 播放中 IO 卻真的不動 → 才算停住
        env.ioAlive = false
        sim.run(until: 705)
        check(env.fallbackStops.count == 1, "有在播、IO 卻不動：2 秒內才判定停住、拆攔截", fmt(env.fallbackStops))
        var h = RCHealthMonitor(firstStall: 2, maxWait: 300)
        _ = h.observe(now: 0, generation: 1, sampleTime: 0, aggVisible: true)
        check(h.observe(now: 5, generation: 1, sampleTime: 0, aggVisible: true, audioActive: { false }) == .idle && h.stallRebuilds == 0, "健康檢查：沒在播 → idle，不計停住")
    }

    print("── 14. 模擬：權限未授與（IO 從未前進）→ 不會每 2 秒重建，間隔逐步加倍封頂 300 秒 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        env.ioAlive = false
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        sim.run(until: 3600)
        let gaps = zip(env.rebuildTimes.dropFirst(), env.rebuildTimes).map { $0 - $1 }
        check(env.rebuildTimes.count <= 20, "一小時內重建 ≤ 20 次", "\(env.rebuildTimes.count) 次 \(fmt(Array(env.rebuildTimes.prefix(8))))…")
        check((gaps.max() ?? 0) <= 304, "最大間隔約 300 秒封頂（停住判定 2 秒＋等 300 秒）", String(format: "%.0f", gaps.max() ?? 0))
        check(!env.logs.contains { $0.contains("不是權限問題") }, "從沒跑過：不說「不是權限問題」")
        check(env.logs.contains { $0.contains("系統音訊錄製") }, "有提示權限")
    }

    print("── 15. 模擬：私有聚合裝置消失 → 下一次健康檢查（1 秒內）重建 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        sim.at(35.5) { env.aggVisible = false }
        sim.run(until: 100)
        check(env.rebuildTimes.count == 1 && near(env.rebuildTimes[0], 36), "於 36 秒重建", fmt(env.rebuildTimes))
    }

    print("── 16a. 模擬：睡眠喚醒、IO 自己恢復 → 不重建，只記一行 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        // 睡眠時單調時鐘不走：喚醒後第一個 tick 就看到牆鐘差 → sleepDetected
        sim.at(31) { sim.core.sleepDetected(gap: 3600, now: sim.now) }
        sim.run(until: 100)
        check(env.rebuildTimes.isEmpty, "不重建", fmt(env.rebuildTimes))
        check(env.logs.count == 1 && env.logs[0].contains("不需重建"), "只記一行「輸出組成不變，不需重建」", "\(env.logs.count) 行")
    }

    print("── 16b. 模擬：睡眠喚醒後 IO 沒恢復（裝置還在）→ 喚醒偵測後 1 秒內強制重建 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        env.onRebuild = { env.ioAlive = true }
        sim.at(31) { env.ioAlive = false; sim.core.sleepDetected(gap: 3600, now: sim.now) }
        sim.run(until: 100)
        check(env.rebuildTimes.count == 1 && near(env.rebuildTimes[0], 32), "於 32 秒（喚醒後 1 秒）重建 1 次", fmt(env.rebuildTimes))
        check(env.logs.contains { $0.contains("睡眠喚醒後") }, "log 有原因")
    }

    print("── 16c. 規則：預設輸出不是音量來源 → 音量鍵警告 ──")
    do {
        check(ReconnectRules.volumeKeyWarning(defaultOutput: B, volumeSourceName: B.name, volumeSourceUID: B.uid) == nil, "預設=內建（音量來源）→ 不警告")
        let wH = ReconnectRules.volumeKeyWarning(defaultOutput: H, volumeSourceName: B.name, volumeSourceUID: B.uid)
        check(wH?.contains("沒有音量控制") == true, "預設=HDMI → 警告沒有音量控制", wH ?? "nil")
        let wA = ReconnectRules.volumeKeyWarning(defaultOutput: ALL, volumeSourceName: B.name, volumeSourceUID: B.uid)
        check(wA?.contains("不使用") == true, "預設=「全部喇叭」→ 警告", wA ?? "nil")
        check(ReconnectRules.volumeKeyWarning(defaultOutput: nil, volumeSourceName: B.name, volumeSourceUID: B.uid) == nil, "沒有預設輸出 → 不警告")
    }

    print("── 17. 模擬：病態自我迴圈（每次重建都讓期望集合改變）→ 速率限制擋在 60 秒 6 次 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        env.echo = verbose
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        var nextID: AudioObjectID = 61
        env.onRebuild = { [unowned sim, unowned env] in
            let h = RCDeviceInfo(uid: H.uid, id: nextID, name: H.name, kind: .hdmi, excluded: false, hasVolumeDb: false)
            nextID += 1
            sim.at(env.now + 0.05) {
                env.physical = [B, h, D]
                sim.core.devicesChanged(seen(env.physical, own: []), now: sim.now)
            }
        }
        sim.at(5) { env.physical = [B, D]; sim.core.noteEvent("起火", now: sim.now) }
        sim.run(until: 185)
        let inFirst60 = env.rebuildTimes.filter { $0 < 65 }.count
        var maxInWindow = 0
        for t in env.rebuildTimes { maxInWindow = max(maxInWindow, env.rebuildTimes.filter { $0 >= t && $0 < t + 60 }.count) }
        check(inFirst60 <= 6 && maxInWindow <= 6, "任 60 秒內 ≤ 6 次", "前 60 秒 \(inFirst60) 次，任窗最多 \(maxInWindow)，總 \(env.rebuildTimes.count)")
        check(env.logs.contains { $0.contains("防止重建迴圈") }, "有速率限制警告")
    }

    print("── 18. 停止後不再動作 ──")
    do {
        let env = RCFakeEnv(physical: phys0, defaultOut: B)
        let sim = RCSim(env: env, devices: seen(phys0, own: [200]))
        sim.at(5) { sim.core.stop(); env.physical = [B, D]; sim.core.noteEvent("HDMI 拔掉", now: sim.now) }
        sim.at(10) { env.running = false }
        sim.run(until: 60)
        check(env.rebuildTimes.isEmpty && sim.core.nextDeadline() == nil, "stop 後不重建（engine.stop 後也不會被拉起）")
    }

    print("\n自測結果：\(pass) 通過，\(fail) 失敗")
    return fail == 0 ? 0 : 1
}
