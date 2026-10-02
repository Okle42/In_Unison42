// MonitorScheduler.swift — 背景監聽（播音樂時自動修正落拍）：排程狀態機＋一輪的擷取流程（第 B 輪，Kang 定案）
//
// 規則（docs/API.md §13）：
//   * 音樂模式、節目音夠大、非校正中、功能開啟（Config.monitorEnabled，預設開）時，每 monitorIntervalSec（300 秒）一輪：
//     用校正麥克風（C270）聽 monitorCaptureSec（10 秒），錄音只在記憶體計算、不存檔（會亮橘色麥克風燈）。
//   * 一輪裡輪流對單一裝置加探測偏移（每台 +3 ms、+4 ms 各一段、0.5 s 斜坡）讓它的峰從群集分離出來，由監聽演算法
//     （ProgramDriftEstimator → Sources/Monitor/DriftEstimator）算出每台相對有線裝置的誤差。先藍牙；每 3 輪再含一台有線（輪替）。
//     一輪最多 2 台（藍牙＋1 台有線：藍牙 +3、有線 +3、藍牙 +4、有線 +4，各 2 秒）——兩種偏移才沒有 ±p 假峰，3 台以上每台到位時間不夠。
//   * 確認才修：同一台連續 2 次一致（第二次在 30 秒後的確認輪量）且 0.5 ms ≤ |誤差| ≤ 10 ms → 以 ≤ 0.1 ms/秒的斜率修正並記 log。
//     確認輪整輪不可採信 → 等確認作廢、回到 5 分鐘；確認輪被跳過或不一致 → 最多 2 個確認輪，之後放棄（麥克風不會每 30 秒一直開）。
//     麥克風輸入 sampleTime 跳號（HAL 丟週期）→ 整輪不可信（同校正路徑）。單台累計修正上限 = Engine.maxCorrectionMs（50 ms）。
//     |誤差| > 10 ms（連續 2 次）或連續 3 次量不到 → 不自己修，標記「需要重新校正」（面板＋選單列圖示提示）。
//   * 麥克風被其他 App 占用、節目音太小或 1–4 kHz 能量不足、校正中（含自動校正倒數）→ 跳過本輪（狀態保持「到期」，條件恢復就跑）。
// 這個檔只有純邏輯（MonitorScheduler）與 IO 流程（MonitorRound）；AppState 接線、面板顯示在 AppState.swift／Panel.swift。
import CoreAudio
import Foundation

// MARK: - 監聽演算法介面（實作在 Sources/Monitor/，另一位實作者）

/// 一台參與同步的輸出（給演算法看）
struct DriftDevice: Equatable {
    let uid: String
    let name: String
    let isBluetooth: Bool
    /// 參考喇叭（音量來源／內建；延遲基準，不探測）
    let isReference: Bool
    /// 目前 plan 的補償延遲（ms；不含探測偏移與修正）
    let planDelayMs: Double
    /// 目前已套用的延遲修正（ms；Engine.latencyCorrections，正 = 當作它比 measuredLatencyMs 慢這麼多）
    let correctionMs: Double
    let measuredLatencyMs: Double?
    /// 這條輸出路徑自己的固定延遲（ms）：藍牙 = BluetoothOut 的 safety（讀取點 = T − 補償 − safety）；聚合裝置輸出 = 0
    var pathDelayMs: Double = 0
    /// 目前實際加在這台輸出上的額外延遲（ms；延遲修正換算到這台的量，Engine.delayOffsets().correctionMs，不含探測）
    var appliedExtraDelayMs: Double = 0
}

/// 一段探測：uid 這台在 [holdStartHost, holdEndHost] 期間比平常晚 offsetMs 出聲；
/// [rampStartHost, holdStartHost] 與 [holdEndHost, rampEndHost] 是線性斜坡（變速），其餘時間偏移 0。host 時間 = mach_absolute_time
struct DriftProbe: Equatable {
    let uid: String
    let offsetMs: Double
    let rampStartHost: UInt64
    let holdStartHost: UInt64
    let holdEndHost: UInt64
    let rampEndHost: UInt64
}

/// 一輪的全部資料（全在記憶體）
struct DriftCaptureInput {
    /// 麥克風（單聲道）與對時點（frame → hostTime）
    let mic: [Float]
    let micRate: Double
    let micAnchors: [MicAnchor]
    /// 節目音（單聲道，engine 時間軸）＋ sampleTime↔hostTime 對時點；延遲 0 的聚合輸出在 hostTime(t) 播出 frame t
    let program: ProgramRecording
    let devices: [DriftDevice]
    let probes: [DriftProbe]
    let secondsPerHostTick: Double
    /// 量測頻帶（Hz）：校正同一把尺（群延遲 1–4 kHz）
    var bandLowHz = 1000.0
    var bandHighHz = 4000.0
}

/// 單台結果。errorMs 的正負：**正 = 這台比應有的時間晚到**（修正方式：它的延遲修正 +errorMs）
struct DriftDeviceEstimate: Equatable {
    let uid: String
    /// nil = 量不到
    let errorMs: Double?
    /// 0…1（< MonitorScheduler.Params.minConfidence 視為量不到）
    let confidence: Double
    let note: String
    /// errorMs == nil（或信心不足）時：true = 「量不到」（可能偏太多／這台沒聲音，累計到 missLimit → 需要重新校正）；
    /// false = 只是這輪不可採信（節目音頻譜太窄、兩半不一致…），不累計
    var countsAsMissing = true
}

struct DriftEstimate: Equatable {
    /// false = 這一輪整體不可採信（麥克風聽不到、節目音不夠…）：不算任何裝置的「量不到」
    let usable: Bool
    let reason: String
    let devices: [DriftDeviceEstimate]
}

protocol DriftEstimating {
    func estimate(_ input: DriftCaptureInput) -> DriftEstimate
}

/// 預設實作：一律「不可採信」（Sources/Monitor/ 的演算法接上之前讓排程、擷取、面板都能跑，但絕不修正）
struct UntrustedDriftEstimator: DriftEstimating {
    func estimate(_ input: DriftCaptureInput) -> DriftEstimate {
        DriftEstimate(usable: false, reason: "監聽演算法尚未接上（預設實作，不修正）", devices: [])
    }
}

/// 【整合點】背景監聽用哪個演算法：Sources/Monitor 的 DriftEstimator（經 MonitorEstimatorAdapter.swift 轉換介面）
func makeDriftEstimator() -> DriftEstimating { ProgramDriftEstimator() }

// MARK: - 排程狀態機（純邏輯，`autocal-selftest` 第 11 節）

/// 可探測的一台
struct MonitorTarget: Equatable {
    let uid: String
    let name: String
    let isBluetooth: Bool
    /// plan 出聲中（不出聲的不探測）
    let active: Bool
    let isReference: Bool
    /// 藍牙且由漂移模型管（AppState 把確認結果當模型的量測點，不疊修正）→ 不累計修正、不套累計上限
    var driftManaged = false
}

/// 這一刻的環境（AppState 每秒量；需要時才讀 Core Audio）
struct MonitorEnvironment: Equatable {
    var enabled = true
    var engineRunning = true
    var musicMode = true
    /// 校正子行程在跑、自動校正倒數／等待／執行中
    var calibrating = false
    var micAvailable = true
    /// 校正麥克風被其他 App 占用（不含我們自己的擷取）
    var micBusy = false
    /// 節目音連續在播 ≥ 20 秒，且峰值 × 音量倍率夠大（最近幾秒）
    var programLoud = true
    /// 探測偏移或修正還在走斜坡
    var slewing = false
    var targets: [MonitorTarget] = []
}

enum MonitorSkipReason: String, Equatable {
    case disabled, engine, notMusic, calibrating, noMic, micBusy, quiet, lowBand, slewing, noTargets, invalid, estimator, aborted

    var text: String {
        switch self {
        case .disabled: return "背景監聽已關閉"
        case .engine: return "同步播放沒有在跑"
        case .notMusic: return "不是音樂模式"
        case .calibrating: return "校正中"
        case .noMic: return "找不到校正麥克風"
        case .micBusy: return "麥克風正被其他 App 使用"
        case .quiet: return "沒有持續播放或節目音太小"
        case .lowBand: return "節目音 1–4 kHz 能量不足"
        case .slewing: return "上一次的修正還在套用"
        case .noTargets: return "沒有可檢查的喇叭"
        case .invalid: return "錄音不完整"
        case .estimator: return "結果不可採信"
        case .aborted: return "中途停止"
        }
    }
}

/// 一輪要做什麼
struct MonitorRoundPlan: Equatable {
    struct Slot: Equatable {
        let target: MonitorTarget
        /// 從擷取開始算：startSeconds 呼叫 setProbeOffset(+offsetMs)（斜坡開始），clearSeconds 呼叫 setProbeOffset(0)
        let startSeconds: Double
        let clearSeconds: Double
        let offsetMs: Double
    }
    let round: Int
    /// 確認輪（只量上一輪超過門檻的裝置）
    let confirm: Bool
    let includesWired: Bool
    let slots: [Slot]
    let captureSeconds: Double
    let rampSeconds: Double
    /// 這輪探測的裝置（每台只一次，依第一次出現的順序；同一台有 +3、+4 兩段 slot）
    var targets: [MonitorTarget] {
        var seen = Set<String>()
        return slots.compactMap { seen.insert($0.target.uid).inserted ? $0.target : nil }
    }
}

enum MonitorAction: Equatable {
    case start(MonitorRoundPlan)
    /// 到期但條件不符（只在原因改變時送一次，AppState 寫 log）
    case skipped(MonitorSkipReason)
    /// 修正：延遲修正 += deltaMs（累計 totalMs）
    case correct(uid: String, name: String, deltaMs: Double, totalMs: Double)
    /// 不自己修：標記需要重新校正
    case flagCalibration(uid: String, name: String, reason: String)
    case log(String)
}

/// 面板顯示：最近一次監聽
struct MonitorDeviceResult: Equatable {
    let uid: String
    let name: String
    let errorMs: Double?
    let confidence: Double
    /// 這一輪套用的修正（ms；nil = 沒修）
    let correctedMs: Double?
    /// 狀態文字（「一致，已修正」「等確認」「在容許範圍內」「量不到」…）
    let note: String
}

struct MonitorRoundSummary: Equatable {
    let at: Date
    let round: Int
    let confirm: Bool
    let skipped: MonitorSkipReason?
    let message: String
    let devices: [MonitorDeviceResult]
}

/// 面板用的整體狀態
struct MonitorStatus: Equatable {
    var enabled = true
    /// 正在聽（麥克風開著）
    var listening = false
    var nextDue: Date?
    /// 到期但被跳過的原因（條件恢復就跑）
    var waitingReason: MonitorSkipReason?
    var last: MonitorRoundSummary?
    /// 累計修正（uid → ms）
    var totals: [String: Double] = [:]
    var intervalSeconds = 300.0
}

final class MonitorScheduler {
    struct Params: Equatable {
        var intervalSeconds = 300.0
        var captureSeconds = 10.0
        /// 第一次量到超過門檻後，多久做確認輪
        var confirmDelaySeconds = 30.0
        /// 每幾輪含有線裝置
        var wiredEvery = 3
        /// 探測偏移（ms）：依輪次與順序輪用（+3／+4：避開固定反射剛好落在同一個偏移上；Sources/Monitor 的建議）
        var probeOffsetsMs = [3.0, 4.0]
        var rampSeconds = Engine.probeRampSeconds
        /// 每台完全到位（斜坡以外，兩種偏移合計）至少幾秒（演算法兩種偏移的下限 0.7 秒；留餘裕）
        var minHoldSeconds = 1.5
        var minConfidence = 0.5
        /// |誤差| 小於這個就算對齊（不修）
        var minCorrectMs = 0.5
        /// |誤差| 大於這個不自己修 → 需要重新校正
        var maxCorrectMs = 10.0
        /// 兩次一致：|e2 − e1| ≤ max(consistencyMs, consistencyFrac × max(|e1|, |e2|))
        var consistencyMs = 1.0
        var consistencyFrac = 0.25
        /// 連續幾次量不到 → 需要重新校正
        var missLimit = 3
        /// 單台累計修正上限（ms）：再修就超過 → 需要重新校正。
        /// 【2026-09-29 審查】原本 20 ms：藍牙同串流內若照 V7 的速度（1.4 ms／1.5 分鐘）單向漂，約 20–25 分鐘就碰到上限、
        /// 被標記後整台不再監聽，這個功能主要對付的「長時間漂移」只撐 20 多分鐘。改成 engine 能套用的實際上限
        /// （Engine.maxCorrectionMs，超過會被夾住、修正不再生效）。漂移是否線性不收斂實機還沒量到（ROADMAP 待決定）
        var maxTotalCorrectionMs = Engine.maxCorrectionMs
        /// 連續幾個確認輪（等確認 → 再量）還沒有結論就放棄這次等確認、回到每 intervalSeconds 一輪
        /// （聽不清楚的環境不能每 30 秒開 10 秒麥克風；2026-09-29 審查）
        var maxConfirmRounds = 2
    }

    var params: Params
    private(set) var nextDue: Date
    private(set) var roundCount = 0
    private(set) var inRound = false
    private(set) var lastSkip: MonitorSkipReason?
    private(set) var last: MonitorRoundSummary?
    /// 第一次量到、等確認的（uid → 誤差 ms）
    private(set) var pending: [String: Double] = [:]
    /// 這次等確認已經跑了幾個確認輪（含被跳過的）；pending 清空時歸零
    private(set) var confirmRounds = 0
    private(set) var misses: [String: Int] = [:]
    /// 累計已修正（uid → ms）
    private(set) var totals: [String: Double] = [:]
    /// 已標記需要重新校正（重新校正前不再重複標記、不再修它）
    private(set) var flagged: Set<String> = []
    /// 【2026-09-29 整合實測】重新校正（或重連、app 重開）後至少可採信地量到過一次的裝置。
    /// 「量不到」只對這些累計：從來沒量到過 = 麥克風本來就聽不清楚它（音量小、離麥克風遠、節目音不適合），
    /// 不是「偏移變大」的證據——否則在聽不清楚的環境每 15 分鐘就會標一次「需要重新校正」，而重新校正也量不到
    private(set) var measuredOnce: Set<String> = []

    init(now: Date, params: Params = Params()) {
        self.params = params
        nextDue = now.addingTimeInterval(params.intervalSeconds)
    }

    /// 最多幾台擠得進一輪：n 台 × m 種偏移 = n·m 段 → 擷取時間分 n·m+1 等份（未探測的基準一半在開頭、一半在結尾）；
    /// 每段完全到位 = 份長 − 2 × 斜坡，每台 m 段合計要 ≥ minHoldSeconds。10 秒、+3／+4 → 最多 2 台
    var maxProbesPerRound: Int {
        let m = Double(max(1, params.probeOffsetsMs.count))
        func fits(_ n: Int) -> Bool {
            let share = params.captureSeconds / (Double(n) * m + 1)
            return m * (share - 2 * params.rampSeconds) >= params.minHoldSeconds
        }
        var n = 1
        while n < 8 && fits(n + 1) { n += 1 }
        return n
    }

    /// 探測排程（同 Sources/Monitor 的 MonitorProbePlan.pair／bluetooth）：每台每種偏移各一段，依偏移分組輪流
    /// （藍牙 +3、有線 +3、藍牙 +4、有線 +4）；n·m+1 等份、基準一半放頭一半放尾
    func slots(for picks: [MonitorTarget], round: Int) -> [MonitorRoundPlan.Slot] {
        guard !picks.isEmpty else { return [] }
        let offs = params.probeOffsetsMs.isEmpty ? [3.0, 4.0] : params.probeOffsetsMs
        let steps: [(MonitorTarget, Double)] = offs.flatMap { o in picks.map { ($0, o) } }
        let share = params.captureSeconds / Double(steps.count + 1)
        return steps.enumerated().map { k, st in
            let start = share / 2 + Double(k) * share
            return .init(target: st.0, startSeconds: start, clearSeconds: start + max(share - params.rampSeconds, params.rampSeconds),
                         offsetMs: st.1)
        }
    }

    /// 重新開始計時（功能打開、app 啟動）
    func reschedule(now: Date) {
        nextDue = now.addingTimeInterval(params.intervalSeconds)
        lastSkip = nil
    }

    /// 重新校正過：這幾台的等確認／量不到／累計修正／標記全部歸零
    func resetDevices(_ uids: Set<String>) {
        for u in uids { pending[u] = nil; misses[u] = nil; totals[u] = nil; flagged.remove(u); measuredOnce.remove(u) }
        if pending.isEmpty { confirmRounds = 0 }
    }

    /// 確認輪結束（量完、不可採信或被跳過）：累計次數；到上限還沒結論 → 放棄等確認（回傳 log 文字）
    private func confirmRoundEnded(_ plan: MonitorRoundPlan, why: String) -> String? {
        guard plan.confirm else { return nil }
        confirmRounds += 1
        guard !pending.isEmpty, confirmRounds >= params.maxConfirmRounds else { return nil }
        let names = plan.targets.filter { pending[$0.uid] != nil }.map(\.name)
        pending = [:]
        confirmRounds = 0
        return "背景監聽：連續 \(params.maxConfirmRounds) 個確認輪\(why)，放棄這次等確認（\(names.joined(separator: "、"))），"
            + String(format: "%.0f 秒後照常再量", params.intervalSeconds)
    }

    /// 這一輪結束後的下一次：還有等確認 → confirmDelaySeconds，否則 intervalSeconds
    private func scheduleNext(_ now: Date) {
        if pending.isEmpty { confirmRounds = 0 }
        nextDue = now.addingTimeInterval(pending.isEmpty ? params.intervalSeconds : params.confirmDelaySeconds)
    }

    func tick(now: Date, env: MonitorEnvironment) -> [MonitorAction] {
        guard !inRound, now >= nextDue else { return [] }
        guard env.enabled else { return [] }
        let reason: MonitorSkipReason?
        // 校正中先判（校正交接時 engine 也是停的：原因要寫「校正中」而不是「同步播放沒有在跑」）
        if env.calibrating { reason = .calibrating }
        else if !env.engineRunning { reason = .engine }
        else if !env.musicMode { reason = .notMusic }
        else if !env.micAvailable { reason = .noMic }
        else if env.micBusy { reason = .micBusy }
        else if !env.programLoud { reason = .quiet }
        else if env.slewing { reason = .slewing }
        else { reason = nil }
        if let r = reason {
            guard r != lastSkip else { return [] }
            lastSkip = r
            return [.skipped(r)]
        }
        let live = env.targets.filter { $0.active && !$0.isReference && !flagged.contains($0.uid) }
        // 確認輪：只量等確認的（還在、還出聲）
        let confirmTargets = live.filter { pending[$0.uid] != nil }
        let confirm = !confirmTargets.isEmpty
        let includeWired = confirm ? confirmTargets.contains { !$0.isBluetooth } : ((roundCount + 1) % max(1, params.wiredEvery) == 0)
        var picks: [MonitorTarget]
        if confirm {
            picks = confirmTargets
        } else {
            picks = live.filter { $0.isBluetooth } + (includeWired ? live.filter { !$0.isBluetooth } : [])
        }
        // 探測不到的等確認項目（裝置不在了／不出聲了）丟掉
        for u in pending.keys where !live.contains(where: { $0.uid == u }) { pending[u] = nil }
        guard !picks.isEmpty else {
            // 這一輪沒有藍牙、又不是有線輪：算一輪（有線輪會輪到），不開麥克風
            roundCount += 1
            nextDue = now.addingTimeInterval(params.intervalSeconds)
            if lastSkip != .noTargets { lastSkip = .noTargets; return [.skipped(.noTargets)] }
            return []
        }
        // 藍牙優先；一輪放不下就先量前面的（下一個有線輪輪替：roundCount 決定起點）
        if picks.count > maxProbesPerRound {
            let bt = picks.filter(\.isBluetooth), wired = picks.filter { !$0.isBluetooth }
            let room = max(0, maxProbesPerRound - bt.count)
            let rot = wired.isEmpty ? 0 : (roundCount / max(1, params.wiredEvery)) % wired.count
            let rotated = Array(wired[rot...] + wired[..<rot])
            picks = Array((bt + rotated.prefix(room)).prefix(maxProbesPerRound))
        }
        let plan = MonitorRoundPlan(round: roundCount + 1, confirm: confirm, includesWired: includeWired,
                                    slots: slots(for: picks, round: roundCount), captureSeconds: params.captureSeconds,
                                    rampSeconds: params.rampSeconds)
        inRound = true
        lastSkip = nil
        return [.start(plan)]
    }

    /// 一輪沒跑完（校正開始、engine 重建、app 結束）或擷取前就跳過（麥克風被占用、1–4 kHz 能量不足…）
    func roundSkipped(_ plan: MonitorRoundPlan, reason: MonitorSkipReason, message: String, now: Date) -> [MonitorAction] {
        inRound = false
        // 確認輪被跳過：等一下再確認（最多 maxConfirmRounds 個確認輪，之後放棄等確認）；一般輪：照常 5 分鐘後
        if !plan.confirm { roundCount += 1 }
        let giveUp = confirmRoundEnded(plan, why: "都沒量成")
        scheduleNext(now)
        last = MonitorRoundSummary(at: now, round: plan.round, confirm: plan.confirm, skipped: reason,
                                   message: message.isEmpty ? reason.text : message, devices: [])
        var acts: [MonitorAction] = [.log("背景監聽第 \(plan.round) 輪\(plan.confirm ? "（確認）" : "")跳過：\(message.isEmpty ? reason.text : message)")]
        if let g = giveUp { acts.append(.log(g)) }
        return acts
    }

    /// 一輪完成：依演算法結果決定修正／標記
    func roundFinished(_ plan: MonitorRoundPlan, estimate: DriftEstimate, now: Date) -> [MonitorAction] {
        inRound = false
        if !plan.confirm { roundCount += 1 }   // 確認輪不算進「每 3 輪含有線」的節奏
        guard estimate.usable else {
            // 「連續 2 次一致」：中間夾一次整輪不可採信就重來（等確認作廢，回到每 intervalSeconds 一輪；2026-09-29 審查：
            // 原本留著 pending、30 秒後再確認，聽不清楚的環境會每 30 秒開 10 秒麥克風、沒有上限）
            let dropped = plan.targets.filter { pending[$0.uid] != nil }.map(\.name)
            pending = [:]
            scheduleNext(now)
            last = MonitorRoundSummary(at: now, round: plan.round, confirm: plan.confirm, skipped: .estimator,
                                       message: estimate.reason, devices: [])
            return [.log("背景監聽第 \(plan.round) 輪\(plan.confirm ? "（確認）" : "")：不可採信（\(estimate.reason)），不修正"
                         + (dropped.isEmpty ? "" : "；等確認作廢（\(dropped.joined(separator: "、"))），重來"))]
        }
        var acts: [MonitorAction] = []
        var rows: [MonitorDeviceResult] = []
        for t in plan.targets {
            let est = estimate.devices.first { $0.uid == t.uid }
            guard let est, let e = est.errorMs, e.isFinite, est.confidence >= params.minConfidence else {
                pending[t.uid] = nil          // 「連續 2 次一致」：中間夾一次量不到／不可採信就重來
                if let est, !est.countsAsMissing {
                    rows.append(MonitorDeviceResult(uid: t.uid, name: t.name, errorMs: est.errorMs, confidence: est.confidence, correctedMs: nil,
                                                    note: "不可採信" + (est.note.isEmpty ? "" : "（\(est.note)）")))
                    continue
                }
                guard measuredOnce.contains(t.uid) else {
                    rows.append(MonitorDeviceResult(uid: t.uid, name: t.name, errorMs: est?.errorMs, confidence: est?.confidence ?? 0, correctedMs: nil,
                                                    note: "量不到" + ((est?.note).map { $0.isEmpty ? "" : "（\($0)）" } ?? "") + "；校正後還沒量到過它，不累計"))
                    continue
                }
                let m = (misses[t.uid] ?? 0) + 1
                misses[t.uid] = m
                var note = "量不到（連續 \(m) 次）"
                if m >= params.missLimit, !flagged.contains(t.uid) {
                    flagged.insert(t.uid)
                    acts.append(.flagCalibration(uid: t.uid, name: t.name, reason: "背景監聽連續 \(m) 次量不到它（偏移可能超過 ±15 ms，或麥克風聽不到）"))
                    note += "，需要重新校正"
                }
                rows.append(MonitorDeviceResult(uid: t.uid, name: t.name, errorMs: est?.errorMs, confidence: est?.confidence ?? 0,
                                                correctedMs: nil, note: note))
                continue
            }
            misses[t.uid] = 0
            measuredOnce.insert(t.uid)
            if abs(e) < params.minCorrectMs {
                pending[t.uid] = nil
                rows.append(MonitorDeviceResult(uid: t.uid, name: t.name, errorMs: e, confidence: est.confidence, correctedMs: nil, note: "對齊"))
                continue
            }
            guard let prev = pending[t.uid] else {
                pending[t.uid] = e
                rows.append(MonitorDeviceResult(uid: t.uid, name: t.name, errorMs: e, confidence: est.confidence, correctedMs: nil,
                                                note: String(format: "等確認（%.0f 秒後再量一次）", params.confirmDelaySeconds)))
                continue
            }
            let tol = max(params.consistencyMs, params.consistencyFrac * max(abs(prev), abs(e)))
            guard abs(e - prev) <= tol, (e > 0) == (prev > 0) else {
                pending[t.uid] = e
                rows.append(MonitorDeviceResult(uid: t.uid, name: t.name, errorMs: e, confidence: est.confidence, correctedMs: nil,
                                                note: String(format: "和上次（%+.2f ms）不一致，再確認", prev)))
                continue
            }
            pending[t.uid] = nil
            let total = (totals[t.uid] ?? 0) + e
            if abs(e) > params.maxCorrectMs {
                flagged.insert(t.uid)
                acts.append(.flagCalibration(uid: t.uid, name: t.name,
                                             reason: String(format: "背景監聽連續 2 次量到偏 %+.1f ms（超過 %.0f ms，不自動修）", e, params.maxCorrectMs)))
                rows.append(MonitorDeviceResult(uid: t.uid, name: t.name, errorMs: e, confidence: est.confidence, correctedMs: nil,
                                                note: "偏移太大，需要重新校正"))
            } else if t.driftManaged {
                // 修正由漂移模型做（下一輪量到的誤差是相對新基準點），這裡累計會重複加總（09-30 寫成「累計 +13.46」，實際 0）
                acts.append(.correct(uid: t.uid, name: t.name, deltaMs: e, totalMs: e))
                rows.append(MonitorDeviceResult(uid: t.uid, name: t.name, errorMs: e, confidence: est.confidence, correctedMs: e,
                                                note: "連續 2 次一致，交給漂移模型當新基準點"))
            } else if abs(total) > params.maxTotalCorrectionMs {
                flagged.insert(t.uid)
                acts.append(.flagCalibration(uid: t.uid, name: t.name,
                                             reason: String(format: "背景監聽累計修正 %+.1f ms 超過 %.0f ms，需要重新校正", total, params.maxTotalCorrectionMs)))
                rows.append(MonitorDeviceResult(uid: t.uid, name: t.name, errorMs: e, confidence: est.confidence, correctedMs: nil,
                                                note: "累計修正太多，需要重新校正"))
            } else {
                totals[t.uid] = total
                acts.append(.correct(uid: t.uid, name: t.name, deltaMs: e, totalMs: total))
                rows.append(MonitorDeviceResult(uid: t.uid, name: t.name, errorMs: e, confidence: est.confidence, correctedMs: e,
                                                note: String(format: "連續 2 次一致，已修正（累計 %+.2f ms）", total)))
            }
        }
        if !plan.confirm { confirmRounds = 0 }   // 一般輪量到新的等確認：從 0 開始數確認輪
        let giveUp = confirmRoundEnded(plan, why: "都沒有一致的結果")
        if let g = giveUp { acts.append(.log(g)) }
        scheduleNext(now)
        last = MonitorRoundSummary(at: now, round: plan.round, confirm: plan.confirm, skipped: nil, message: estimate.reason, devices: rows)
        let desc = rows.map { r in "\(r.name) " + (r.errorMs.map { String(format: "%+.2f ms", $0) } ?? "—") + "（\(r.note)）" }.joined(separator: "；")
        acts.insert(.log("背景監聽第 \(plan.round) 輪\(plan.confirm ? "（確認）" : "")：\(desc)"), at: 0)
        return acts
    }

    func status(enabled: Bool, listening: Bool) -> MonitorStatus {
        MonitorStatus(enabled: enabled, listening: listening, nextDue: enabled ? nextDue : nil, waitingReason: lastSkip, last: last, totals: totals,
                      intervalSeconds: params.intervalSeconds)
    }
}

// MARK: - 節目音 1–4 kHz 能量（跳過判斷用；RBJ 二階高通＋低通）

enum MonitorSignal {
    /// 頻帶內 RMS（dBFS）；樣本太少回 -infinity
    static func bandRMSdB(_ x: [Float], rate: Double, lo: Double = 1000, hi: Double = 4000) -> Double {
        guard x.count > 64, rate > 0 else { return -.infinity }
        func biquad(_ input: [Double], highpass: Bool, f0: Double) -> [Double] {
            let w = 2 * Double.pi * f0 / rate, q = 0.7071
            let alpha = sin(w) / (2 * q), cw = cos(w)
            let b0 = highpass ? (1 + cw) / 2 : (1 - cw) / 2
            let b1 = highpass ? -(1 + cw) : 1 - cw
            let b2 = b0, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha
            var y = [Double](repeating: 0, count: input.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in input.indices {
                let v = (b0 * input[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1; x1 = input[i]; y2 = y1; y1 = v; y[i] = v
            }
            return y
        }
        let y = biquad(biquad(x.map(Double.init), highpass: true, f0: lo), highpass: false, f0: hi)
        let skip = min(y.count / 10, Int(rate * 0.05))   // 濾波器暫態
        let tail = y[skip...]
        let ms = tail.reduce(0) { $0 + $1 * $1 } / Double(max(1, tail.count))
        return ms > 0 ? 10 * log10(ms) : -.infinity
    }
}

// MARK: - 一輪的 IO 流程（麥克風擷取＋節目音錄製＋探測偏移排程；自己的背景 queue）

enum MonitorRoundOutcome {
    case completed(DriftEstimate)
    case skipped(MonitorSkipReason, String)
}

final class MonitorRound {
    /// 1–4 kHz 節目音 RMS 低於這個 → 能量不足，跳過
    static let minBandDb = -50.0
    /// 往回錄的節目音（秒）：藍牙比其他喇叭晚約 0.43 秒，麥克風聽到的是更早的節目音
    static let programLookbackSeconds = 1.5

    let plan: MonitorRoundPlan
    private let engine: Engine
    private let mic: AudioDevice
    private let devices: [DriftDevice]
    private let estimator: DriftEstimating
    private let q = DispatchQueue(label: "In_Unison42.monitor.round", qos: .utility)
    private var capture: MonitorMicCapture?
    private var recorder: ProgramRecorder?
    private var probes: [DriftProbe] = []
    private var active: [String: (rampStart: UInt64, holdStart: UInt64, offsetMs: Double)] = [:]
    private var done = false
    private var generation = 0
    /// 結束時呼叫（主執行緒）
    var onFinish: ((MonitorRoundOutcome) -> Void)?
    /// 麥克風開著（面板顯示「聆聽中」；主執行緒讀、round queue 寫 → 有鎖）
    private let listeningFlag = LockedValue(false)
    var listening: Bool { listeningFlag.value }

    init(plan: MonitorRoundPlan, engine: Engine, mic: AudioDevice, devices: [DriftDevice], estimator: DriftEstimating) {
        self.plan = plan; self.engine = engine; self.mic = mic; self.devices = devices; self.estimator = estimator
    }

    func start() { q.async { self.startLocked() } }

    /// 中止（校正要開始、app 結束…）：探測偏移立刻拿掉、關麥克風。可從任何執行緒呼叫
    func abort(_ why: String) { q.async { self.finishSkipped(.aborted, why) } }

    private static func hostNow() -> UInt64 { mach_absolute_time() }

    private func startLocked() {
        guard !done else { return }
        if MonitorMicCapture.isRunningSomewhere(mic.id) { finishSkipped(.micBusy, ""); return }
        guard let clk = engine.programClock() else { finishSkipped(.engine, ""); return }
        generation = clk.generation
        let rec = ProgramRecorder(ring: engine.program, maxSeconds: plan.captureSeconds + Self.programLookbackSeconds + 1.5)
        guard rec.start(lookbackSeconds: Self.programLookbackSeconds) else { finishSkipped(.engine, ""); return }
        recorder = rec
        let cap = MonitorMicCapture(device: mic, seconds: plan.captureSeconds + 0.5)
        let st = cap.start()
        guard st == noErr else { finishSkipped(.noMic, "開啟麥克風「\(mic.name)」失敗 status=\(st)"); return }
        capture = cap
        listeningFlag.value = true
        let tps = 1 / Engine.hostSecondsPerTick
        for s in plan.slots {
            let uid = s.target.uid
            let off = s.offsetMs
            q.asyncAfter(deadline: .now() + s.startSeconds) { [weak self] in
                guard let self, !self.done else { return }
                let t0 = Self.hostNow()
                guard self.engine.setProbeOffset(uid: uid, ms: off, rampSeconds: self.plan.rampSeconds) else { return }
                self.active[uid] = (t0, t0 + UInt64(self.plan.rampSeconds * tps), off)
            }
            q.asyncAfter(deadline: .now() + s.clearSeconds) { [weak self] in
                guard let self, !self.done, let a = self.active[uid] else { return }
                let t1 = Self.hostNow()
                self.engine.setProbeOffset(uid: uid, ms: 0, rampSeconds: self.plan.rampSeconds)
                self.active[uid] = nil
                self.probes.append(DriftProbe(uid: uid, offsetMs: a.offsetMs, rampStartHost: a.rampStart, holdStartHost: a.holdStart,
                                              holdEndHost: t1, rampEndHost: t1 + UInt64(self.plan.rampSeconds * tps)))
            }
        }
        q.asyncAfter(deadline: .now() + plan.captureSeconds) { [weak self] in self?.finishCapture() }
    }

    private func stopIO() {
        capture?.stop()
        // 正常結束時最後一個探測早已走完斜坡（no-op）；中止時還在的探測用 0.2 秒斜坡拿掉（不硬切）
        engine.clearProbeOffsets(rampSeconds: 0.2)
        active = [:]
        listeningFlag.value = false
    }

    private func finishCapture() {
        guard !done else { return }
        done = true
        stopIO()
        guard let cap = capture, let rec = recorder?.stop() else { deliver(.skipped(.invalid, "")); return }
        let micRes = cap.result()
        capture = nil; recorder = nil
        if rec.generationChanged || engine.programClock()?.generation != generation {
            deliver(.skipped(.invalid, "錄音期間同步播放重建過")); return
        }
        let wantMic = Int(plan.captureSeconds * micRes.sampleRate * 0.9)
        if micRes.samples.count < wantMic || micRes.anchors.count < 2 {
            deliver(.skipped(.invalid, "麥克風只錄到 \(String(format: "%.1f", Double(micRes.samples.count) / micRes.sampleRate)) 秒")); return
        }
        // 輸入 sampleTime 跳號（HAL 丟了輸入週期：USB 過載、睡眠／喚醒）：buf 是各週期連續寫入的，跳號後半段在 index 上整段挪了
        // 一個週期；估計器用一條直線對時會把台階攤平成數 ms 的偏差 → 和校正路徑（Calibrate／ProgramPath）一樣整輪不可信
        if micRes.gaps > 0 { deliver(.skipped(.invalid, "麥克風錄音中斷 \(micRes.gaps) 次")); return }
        if micRes.peak <= 0 { deliver(.skipped(.invalid, "麥克風「\(micRes.deviceName)」沒有訊號（麥克風權限？）")); return }
        if rec.gapFrames > 0 { deliver(.skipped(.invalid, "節目音錄製有 \(rec.gapFrames) frame 的洞")); return }
        let band = MonitorSignal.bandRMSdB(rec.samples, rate: rec.sampleRate)
        if band < Self.minBandDb {
            deliver(.skipped(.lowBand, String(format: "節目音 1–4 kHz 只有 %.0f dBFS", band))); return
        }
        let input = DriftCaptureInput(mic: micRes.samples, micRate: micRes.sampleRate, micAnchors: micRes.anchors, program: rec,
                                      devices: devices, probes: probes, secondsPerHostTick: Engine.hostSecondsPerTick)
        deliver(.completed(estimator.estimate(input)))
    }

    private func finishSkipped(_ r: MonitorSkipReason, _ msg: String) {
        guard !done else { return }
        done = true
        stopIO()
        _ = recorder?.stop()
        capture = nil; recorder = nil
        deliver(.skipped(r, msg))
    }

    private func deliver(_ o: MonitorRoundOutcome) {
        let cb = onFinish
        DispatchQueue.main.async { cb?(o) }
    }
}

// MARK: - 離線自測（autocal-selftest 呼叫；純邏輯，不開麥克風、不出聲）

func runMonitorSchedulerSelfTest(check: (Bool, String, String) -> Void) {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    let bt = MonitorTarget(uid: "bt", name: "GLASS5+", isBluetooth: true, active: true, isReference: false)
    let msi = MonitorTarget(uid: "msi", name: "MSI", isBluetooth: false, active: true, isReference: false)
    let tv = MonitorTarget(uid: "tv", name: "電視", isBluetooth: false, active: true, isReference: false)
    let builtin = MonitorTarget(uid: "BuiltInSpeakerDevice", name: "內建", isBluetooth: false, active: true, isReference: true)
    var env = MonitorEnvironment(); env.targets = [builtin, msi, tv, bt]
    func plans(_ a: [MonitorAction]) -> [MonitorRoundPlan] { a.compactMap { if case .start(let p) = $0 { return p } else { return nil } } }
    func skips(_ a: [MonitorAction]) -> [MonitorSkipReason] { a.compactMap { if case .skipped(let r) = $0 { return r } else { return nil } } }
    func corrections(_ a: [MonitorAction]) -> [String: Double] {
        var d: [String: Double] = [:]
        for x in a { if case .correct(let u, _, let delta, _) = x { d[u] = delta } }
        return d
    }
    func flags(_ a: [MonitorAction]) -> [String] { a.compactMap { if case .flagCalibration(let u, _, _) = $0 { return u } else { return nil } } }
    func est(_ pairs: [(String, Double?)], conf: Double = 0.9, usable: Bool = true) -> DriftEstimate {
        DriftEstimate(usable: usable, reason: "test", devices: pairs.map { DriftDeviceEstimate(uid: $0.0, errorMs: $0.1, confidence: conf, note: "") })
    }

    print("── 11. 背景監聽排程（MonitorScheduler） ──")
    do {
        let s = MonitorScheduler(now: t0)
        check(s.tick(now: at(10), env: env).isEmpty, "還沒到 5 分鐘：不動", "")
        var a = s.tick(now: at(300), env: env)
        let p1 = plans(a).first
        check(p1 != nil && p1!.targets.map(\.uid) == ["bt"] && p1!.slots.map(\.offsetMs) == [3, 4] && !p1!.confirm && !p1!.includesWired, "第 1 輪：只探測藍牙", "\(a)")
        check(s.tick(now: at(301), env: env).isEmpty, "一輪進行中：不會再開", "")
        a = s.roundFinished(p1!, estimate: est([("bt", 0.2)]), now: at(311))
        check(corrections(a).isEmpty && s.pending.isEmpty && s.nextDue == at(611), "誤差 0.2 ms < 0.5：不修、5 分鐘後再來", "\(s.nextDue)")
        // 第 2 輪量到 +3 ms → 等確認（30 秒後）
        a = s.tick(now: at(611), env: env)
        let p2 = plans(a).first!
        a = s.roundFinished(p2, estimate: est([("bt", 3.0)]), now: at(621))
        check(corrections(a).isEmpty && s.pending["bt"] == 3.0 && s.nextDue == at(651), "第一次 +3 ms：不修，30 秒後確認", "\(a)")
        a = s.tick(now: at(651), env: env)
        let p3 = plans(a).first!
        check(p3.confirm && p3.targets.map(\.uid) == ["bt"], "確認輪只量藍牙", "")
        a = s.roundFinished(p3, estimate: est([("bt", 3.3)]), now: at(661))
        check(corrections(a) == ["bt": 3.3] && s.totals["bt"] == 3.3 && s.pending.isEmpty, "連續 2 次一致（3.0／3.3）→ 修正 +3.3 ms", "\(a)")
        // 第 3 個一般輪（roundCount 3 → 第 4 輪）…每 3 輪含有線
        var sawWired = false
        var now = 661.0
        for _ in 0..<4 {
            now = s.nextDue.timeIntervalSince(t0)
            a = s.tick(now: at(now), env: env)
            guard let p = plans(a).first else { break }
            if p.includesWired { let u = p.targets.map(\.uid); sawWired = u.count == 2 && u[0] == "bt" && ["msi", "tv"].contains(u[1]) }
            _ = s.roundFinished(p, estimate: est(p.slots.map { ($0.target.uid, 0.1) }), now: at(now + 10))
        }
        check(sawWired, "每 3 輪含有線（藍牙在前、一台有線、參考喇叭不探測）", "")
    }
    do {
        print("  漂移模型管的藍牙：")
        // 09-30 12:32 實機：連續 2 次一致 +7.91、+5.55 → 寫成「累計 +13.46」，但修正由漂移模型做，不該累加
        var e = env
        e.targets = [builtin, msi, tv, MonitorTarget(uid: "bt", name: "GLASS5+", isBluetooth: true, active: true, isReference: false, driftManaged: true)]
        let s = MonitorScheduler(now: t0)
        var a = s.tick(now: at(300), env: e); var p = plans(a)[0]
        _ = s.roundFinished(p, estimate: est([("bt", 7.9)]), now: at(310))
        a = s.tick(now: at(340), env: e); p = plans(a)[0]
        a = s.roundFinished(p, estimate: est([("bt", 8.4)]), now: at(350))
        check(corrections(a) == ["bt": 8.4] && s.totals["bt"] == nil && (s.last?.devices.first?.note.contains("新基準點") ?? false),
              "連續 2 次一致 → 交給漂移模型（不累計、說明不寫「已修正（累計）」）", "\(a)、\(s.last?.devices.first?.note ?? "")")
        a = s.tick(now: at(650), env: e); p = plans(a)[0]
        _ = s.roundFinished(p, estimate: est([("bt", 5.5)]), now: at(660))
        a = s.tick(now: at(690), env: e); p = plans(a)[0]
        a = s.roundFinished(p, estimate: est([("bt", 5.6)]), now: at(700))
        check(corrections(a) == ["bt": 5.6] && flags(a).isEmpty && s.totals["bt"] == nil, "再一次一致：照樣交給模型、不因「累計超過上限」標記", "\(a)")
    }
    do {
        print("  跳過條件：")
        let s = MonitorScheduler(now: t0)
        var e = env; e.micBusy = true
        var a = s.tick(now: at(300), env: e)
        check(skips(a) == [.micBusy] && plans(a).isEmpty, "麥克風被其他 App 占用 → 跳過", "\(a)")
        check(s.tick(now: at(301), env: e).isEmpty, "同一個原因不重複送", "")
        e = env; e.programLoud = false
        a = s.tick(now: at(302), env: e)
        check(skips(a) == [.quiet], "節目音太小 → 跳過", "\(a)")
        e = env; e.calibrating = true; e.engineRunning = false
        a = s.tick(now: at(303), env: e)
        check(skips(a) == [.calibrating], "校正中（交接時 engine 也停了）→ 跳過，原因寫「校正中」", "\(a)")
        e = env; e.musicMode = false
        check(skips(s.tick(now: at(304), env: e)) == [.notMusic], "不是音樂模式 → 跳過", "")
        e = env; e.slewing = true
        check(skips(s.tick(now: at(305), env: e)) == [.slewing], "修正還在套用 → 跳過", "")
        e = env; e.enabled = false
        check(s.tick(now: at(306), env: e).isEmpty, "功能關閉 → 什麼都不做", "")
        a = s.tick(now: at(307), env: env)
        check(plans(a).count == 1, "條件恢復 → 立刻開始（到期狀態保留）", "\(a)")
        // 擷取時才發現 1–4 kHz 能量不足
        let p = plans(a)[0]
        a = s.roundSkipped(p, reason: .lowBand, message: "", now: at(317))
        check(s.nextDue == at(617) && s.last?.skipped == .lowBand, "1–4 kHz 能量不足 → 本輪跳過、5 分鐘後再來", "")
    }
    do {
        print("  確認與標記：")
        let s = MonitorScheduler(now: t0)
        var a = s.tick(now: at(300), env: env)
        var p = plans(a)[0]
        _ = s.roundFinished(p, estimate: est([("bt", 3.0)]), now: at(310))
        a = s.tick(now: at(340), env: env); p = plans(a)[0]
        a = s.roundFinished(p, estimate: est([("bt", -2.0)]), now: at(350))
        check(corrections(a).isEmpty && s.pending["bt"] == -2.0, "兩次不一致（+3／−2）→ 不修、再確認", "\(a)")
        a = s.tick(now: at(380), env: env); p = plans(a)[0]
        a = s.roundFinished(p, estimate: est([("bt", -2.2)]), now: at(390))
        check(corrections(a) == ["bt": -2.2], "再下一次一致（−2.0／−2.2）→ 修正 −2.2", "\(a)")
        // 低信心 = 量不到；確認輪也不算一致
        let s2 = MonitorScheduler(now: t0)
        a = s2.tick(now: at(300), env: env); p = plans(a)[0]
        _ = s2.roundFinished(p, estimate: est([("bt", 4.0)]), now: at(310))
        a = s2.tick(now: at(340), env: env); p = plans(a)[0]
        a = s2.roundFinished(p, estimate: est([("bt", 4.0)], conf: 0.2), now: at(350))
        check(corrections(a).isEmpty && s2.misses["bt"] == 1 && s2.pending.isEmpty, "信心不足 → 量不到、不修", "\(a)")
        // 不可採信（節目音不適合）≠ 量不到：不累計
        let sI = MonitorScheduler(now: t0)
        a = sI.tick(now: at(300), env: env); p = plans(a)[0]
        a = sI.roundFinished(p, estimate: DriftEstimate(usable: true, reason: "", devices: [
            DriftDeviceEstimate(uid: "bt", errorMs: nil, confidence: 0, note: "多峰模稜兩可", countsAsMissing: false)]), now: at(310))
        check((sI.misses["bt"] ?? 0) == 0 && flags(a).isEmpty && sI.last?.devices.first?.note.hasPrefix("不可採信") == true,
              "不可採信（多峰）不算量不到", "\(a)")
        // 大偏移：連續 2 次 > 10 ms → 標記需要重新校正、不修
        let s3 = MonitorScheduler(now: t0)
        a = s3.tick(now: at(300), env: env); p = plans(a)[0]
        _ = s3.roundFinished(p, estimate: est([("bt", 35.0)]), now: at(310))
        a = s3.tick(now: at(340), env: env); p = plans(a)[0]
        a = s3.roundFinished(p, estimate: est([("bt", 38.0)]), now: at(350))
        check(flags(a) == ["bt"] && corrections(a).isEmpty && s3.flagged.contains("bt"), "連續 2 次 > 10 ms → 需要重新校正，不自動修", "\(a)")
        a = s3.tick(now: at(650), env: env)
        check(plans(a).isEmpty || !plans(a)[0].slots.contains { $0.target.uid == "bt" }, "已標記的不再探測（等重新校正）", "\(a)")
        s3.resetDevices(["bt"])
        check(!s3.flagged.contains("bt"), "重新校正後解除", "")
        // 量不到 3 次 → 標記（先可採信地量到過一次：0.1 ms；從來沒量到過的不累計，見下）
        let s4 = MonitorScheduler(now: t0)
        var now = 300.0
        var flagged: [String] = []
        if let pp = plans(s4.tick(now: at(now), env: env)).first { _ = s4.roundFinished(pp, estimate: est([("bt", 0.1)]), now: at(now + 10)) }
        now = s4.nextDue.timeIntervalSince(t0)
        for _ in 0..<3 {
            a = s4.tick(now: at(now), env: env)
            guard let pp = plans(a).first else { break }
            flagged += flags(s4.roundFinished(pp, estimate: est([("bt", nil)]), now: at(now + 10)))
            now = s4.nextDue.timeIntervalSince(t0)
        }
        check(flagged == ["bt"], "量到過之後連續 3 次量不到 → 需要重新校正", "\(flagged)")
        // 校正後從來沒量到過（麥克風本來就聽不清楚它）：量不到再多次也不標記（2026-09-29 實測 GLASS5+ 音量小時每輪都「峰值不夠高」）
        let s4b = MonitorScheduler(now: t0)
        var nb = 300.0
        var flaggedB: [String] = []
        for _ in 0..<5 {
            guard let pp = plans(s4b.tick(now: at(nb), env: env)).first else { break }
            flaggedB += flags(s4b.roundFinished(pp, estimate: est([("bt", nil)]), now: at(nb + 10)))
            nb = s4b.nextDue.timeIntervalSince(t0)
        }
        check(flaggedB.isEmpty && (s4b.misses["bt"] ?? 0) == 0 && s4b.last?.devices.first?.note.contains("不累計") == true,
              "校正後從沒量到過的裝置：連續 5 次量不到也不標記（不累計）", "\(flaggedB)")
        // 整輪不可採信：不算量不到、不修（預設演算法）
        let s5 = MonitorScheduler(now: t0)
        a = s5.tick(now: at(300), env: env); p = plans(a)[0]
        a = s5.roundFinished(p, estimate: UntrustedDriftEstimator().estimate(DriftCaptureInput(
            mic: [], micRate: 48000, micAnchors: [], program: ProgramRecording(startSampleTime: 0, sampleRate: 48000, samples: [], clock: [],
                                                                              generation: 0, gapFrames: 0, generationChanged: false, secondsPerHostTick: 1e-9),
            devices: [], probes: [], secondsPerHostTick: 1e-9)), now: at(310))
        check(corrections(a).isEmpty && flags(a).isEmpty && (s5.misses["bt"] ?? 0) == 0 && s5.last?.skipped == .estimator,
              "預設演算法（不可採信）：不修、不算量不到", "\(a)")
        // 【2026-09-29 審查】等確認之後整輪不可採信 → 等確認作廢、回到 5 分鐘（不可以每 30 秒一直開麥克風）
        let sC = MonitorScheduler(now: t0)
        a = sC.tick(now: at(300), env: env); p = plans(a)[0]
        _ = sC.roundFinished(p, estimate: est([("bt", 3.0)]), now: at(310))
        check(sC.pending["bt"] == 3.0 && sC.nextDue == at(340), "前提：第一次 +3 ms → 30 秒後確認", "\(sC.nextDue)")
        var tC = 340.0
        var confirmRuns = 0
        for _ in 0..<4 {
            guard let pp = plans(sC.tick(now: at(tC), env: env)).first else { break }
            if pp.confirm { confirmRuns += 1 }
            _ = sC.roundFinished(pp, estimate: est([], usable: false), now: at(tC + 10))
            tC = sC.nextDue.timeIntervalSince(t0)
        }
        check(confirmRuns == 1 && sC.pending.isEmpty && sC.confirmRounds == 0,
              "等確認後整輪不可採信 → 等確認作廢（只跑了 1 個確認輪），之後都是一般輪", "確認輪 \(confirmRuns)、pending \(sC.pending)")
        let sC2 = MonitorScheduler(now: t0)
        a = sC2.tick(now: at(300), env: env); p = plans(a)[0]
        _ = sC2.roundFinished(p, estimate: est([("bt", 3.0)]), now: at(310))
        a = sC2.tick(now: at(340), env: env); p = plans(a)[0]
        a = sC2.roundFinished(p, estimate: est([], usable: false), now: at(350))
        check(sC2.pending.isEmpty && sC2.nextDue == at(650), "確認輪不可採信 → nextDue 回到 300 秒、pending 清空", "\(sC2.nextDue)")
        // 確認輪被跳過（1–4 kHz 能量不足／麥克風被占用…）：最多 maxConfirmRounds 個確認輪，之後放棄
        let sC3 = MonitorScheduler(now: t0)
        a = sC3.tick(now: at(300), env: env); p = plans(a)[0]
        _ = sC3.roundFinished(p, estimate: est([("bt", 3.0)]), now: at(310))
        var micOpens = 0
        var tS = 340.0
        for _ in 0..<6 {
            guard let pp = plans(sC3.tick(now: at(tS), env: env)).first else { break }
            if pp.confirm { micOpens += 1 }
            _ = sC3.roundSkipped(pp, reason: .lowBand, message: "", now: at(tS + 10))
            tS = sC3.nextDue.timeIntervalSince(t0)
            if !pp.confirm { break }
        }
        check(micOpens == 2 && sC3.pending.isEmpty, "確認輪連續被跳過：2 個確認輪後放棄等確認、回到 5 分鐘", "確認輪 \(micOpens)")
        // 確認輪一直不一致：同樣最多 2 個確認輪
        let sC4 = MonitorScheduler(now: t0)
        a = sC4.tick(now: at(300), env: env); p = plans(a)[0]
        _ = sC4.roundFinished(p, estimate: est([("bt", 3.0)]), now: at(310))
        var tI = 340.0
        var confirmsI = 0
        for e in [-2.0, 5.0, -3.0, 6.0] {
            guard let pp = plans(sC4.tick(now: at(tI), env: env)).first, pp.confirm else { break }
            confirmsI += 1
            a = sC4.roundFinished(pp, estimate: est([("bt", e)]), now: at(tI + 10))
            tI = sC4.nextDue.timeIntervalSince(t0)
        }
        check(confirmsI == 2 && sC4.pending.isEmpty && corrections(a).isEmpty && sC4.nextDue == at(390 + 300),
              "確認輪一直不一致：2 個確認輪後放棄、不修、回到 5 分鐘", "確認輪 \(confirmsI)、\(sC4.nextDue.timeIntervalSince(t0))")
        // 預設累計上限 = engine 能套用的上限（50 ms）：照 V7 速度每 5 分鐘修約 4.7 ms，連續 6 次（約 30 分鐘、28 ms）也不標記
        let sT = MonitorScheduler(now: t0)
        var flagsT: [String] = []
        var nT = 0
        for _ in 0..<12 {
            let tn = sT.nextDue.timeIntervalSince(t0)
            guard let pp = plans(sT.tick(now: at(tn), env: env)).first else { break }
            let acts = sT.roundFinished(pp, estimate: est([("bt", 4.7)]), now: at(tn + 10))
            flagsT += flags(acts); nT += corrections(acts).count
            if nT >= 6 { break }
        }
        check(sT.params.maxTotalCorrectionMs == Engine.maxCorrectionMs && nT == 6 && flagsT.isEmpty && abs((sT.totals["bt"] ?? 0) - 28.2) < 1e-9,
              "預設累計上限 = Engine.maxCorrectionMs（50 ms）：藍牙長時間漂移修 6 次（28.2 ms）仍照常修", "修 \(nT) 次、標記 \(flagsT)")
        // 累計修正上限
        var pr = MonitorScheduler.Params(); pr.maxTotalCorrectionMs = 5
        let s6 = MonitorScheduler(now: t0, params: pr)
        for (i, e) in [3.0, 3.1, 3.0, 3.2].enumerated() {
            let tNow = s6.nextDue.timeIntervalSince(t0)
            a = s6.tick(now: at(tNow), env: env)
            guard let pp = plans(a).first else { break }
            a = s6.roundFinished(pp, estimate: est([("bt", e)]), now: at(tNow + 10))
            if i == 3 { check(flags(a) == ["bt"] && corrections(a).isEmpty, "累計修正超過上限 → 需要重新校正", "\(a)") }
        }
        // 1–4 kHz 能量量測
        let sr = 48000.0
        let tone2k = (0..<24000).map { Float(0.1 * sin(2 * Double.pi * 2000 * Double($0) / sr)) }
        let tone100 = (0..<24000).map { Float(0.1 * sin(2 * Double.pi * 100 * Double($0) / sr)) }
        let b2k = MonitorSignal.bandRMSdB(tone2k, rate: sr), b100 = MonitorSignal.bandRMSdB(tone100, rate: sr)
        check(abs(b2k - (-23.0)) < 1.5 && b100 < MonitorRound.minBandDb, "1–4 kHz 能量：2 kHz −23 dBFS 通過、100 Hz 被濾掉",
              String(format: "2k %.1f dB、100 Hz %.1f dB", b2k, b100))
    }
    do {
        let s = MonitorScheduler(now: t0)
        check(s.maxProbesPerRound == 2, "10 秒一輪最多探測 2 台（每台 +3／+4 兩段：5 等份各 2 秒，每台到位合計 2 秒 ≥ 1.5）", "\(s.maxProbesPerRound)")
        let sl = s.slots(for: [bt, msi], round: 0)
        check(sl.map(\.target.uid) == ["bt", "msi", "bt", "msi"] && sl.map(\.startSeconds) == [1, 3, 5, 7] && sl.map(\.clearSeconds) == [2.5, 4.5, 6.5, 8.5]
              && sl.map(\.offsetMs) == [3, 3, 4, 4],
              "藍牙＋有線：藍牙 +3、有線 +3、藍牙 +4、有線 +4（同 MonitorProbePlan.pair）", "\(sl.map { ($0.target.uid, $0.startSeconds, $0.clearSeconds, $0.offsetMs) })")
        let one = s.slots(for: [bt], round: 1)
        let ref = MonitorProbePlan.bluetooth(0)
        check(one.count == 2 && zip(one, ref).allSatisfy { abs($0.startSeconds - $1.startSeconds) < 1e-9 && abs($0.clearSeconds - $1.clearSeconds) < 1e-9 && $0.offsetMs == $1.offsetMs },
              "只有藍牙：+3、+4 各一段（同 MonitorProbePlan.bluetooth）", "\(one.map { ($0.startSeconds, $0.clearSeconds, $0.offsetMs) })")
        check(sl.allSatisfy { $0.clearSeconds + 0.5 <= 10 } && one.allSatisfy { $0.clearSeconds + 0.5 <= 10 }, "最後一個探測的斜坡在擷取結束前走完", "")
        // 有線輪輪替：第 3 輪 MSI、第 6 輪電視（一輪只放得下藍牙＋1 台有線）
        let s3 = MonitorScheduler(now: t0)
        var wiredSeen: [String] = []
        for _ in 0..<6 {
            let tn = s3.nextDue.timeIntervalSince(t0)
            guard let p = plans(s3.tick(now: at(tn), env: env)).first else { break }
            check(Set(p.slots.map(\.target.uid)).count <= 2, "一輪最多 2 台（第 \(p.round) 輪）", "\(p.slots.map(\.target.uid))")
            wiredSeen += p.slots.map(\.target.uid).filter { $0 != "bt" }.prefix(1)
            _ = s3.roundFinished(p, estimate: est(p.slots.map { ($0.target.uid, 0.1) }), now: at(tn + 10))
        }
        check(wiredSeen == ["msi", "tv"], "有線輪輪替 MSI → 電視", "\(wiredSeen)")
    }
}
