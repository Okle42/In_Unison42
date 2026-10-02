// MonitorDecider.swift — 背景監聽的「什麼時候修、修多少」與探測排程（純邏輯，不碰 CoreAudio）。
//
//   * MonitorProbePlan.make：一個監聽窗（預設 10 秒）裡，輪流對哪幾台、什麼時候加多少探測偏移（輸出時刻，相對監聽開始）。
//   * MonitorDecider：每台一個。吃 DriftEstimator 的單台結果 → 動作：
//       .none／.pending（第一次看到、等確認）／.correct(byMs:)（連續 2 次一致才修）／.needsRecalibration（大偏移或連續量不到）。
//     修正以 Engine.adjustLatencyCorrection(uid:byMs:) 套用（Engine 以 ≤ 0.1 ms/秒 的斜率走過去）；
//     斜坡走完前（rampSeconds）不要開始下一輪監聽，否則會量到走到一半的值。
import Foundation

struct MonitorProbeStep: Equatable {
    var device: Int
    /// 輸出時刻（秒，相對監聽開始）：startSeconds 呼叫 setProbeOffset(ms)，clearSeconds 呼叫 setProbeOffset(0)
    var startSeconds: Double
    var clearSeconds: Double
    var offsetMs: Double
}

enum MonitorProbePlan {
    /// 一般形式：steps 依序各探測一段（(裝置, 偏移 ms)，同一台可以出現兩次）。時間平均分給「基準（不探測）」與每段：
    /// n 段 → n+1 等份，基準那份一半放開頭、一半放結尾；每段含前後斜坡（rampSeconds），完全到位 = 份長 − 2 × 斜坡。
    static func make(steps: [(device: Int, offsetMs: Double)], windowSeconds: Double = 10, rampSeconds: Double = 0.5) -> [MonitorProbeStep] {
        guard !steps.isEmpty, windowSeconds > 0 else { return [] }
        let share = windowSeconds / Double(steps.count + 1)
        var t = share / 2
        var out: [MonitorProbeStep] = []
        for st in steps {
            out.append(MonitorProbeStep(device: st.device, startSeconds: t, clearSeconds: t + max(share - rampSeconds, rampSeconds),
                                        offsetMs: st.offsetMs))
            t += share
        }
        return out
    }

    /// 建議的藍牙輪（每 5 分鐘）：同一台先 +3 ms、再 +4 ms（兩種偏移 → 沒有 ±p 假峰；+4 與 4.1 ms 反射重疊時 +3 補上）。
    /// 10 秒窗：基準 1.7 + 探測 3.3 + 3.3（完全到位各約 2.3 秒）+ 基準 1.7
    static func bluetooth(_ device: Int, windowSeconds: Double = 10, offsetsMs: [Double] = [3.0, 4.0]) -> [MonitorProbeStep] {
        make(steps: offsetsMs.map { (device, $0) }, windowSeconds: windowSeconds)
    }

    /// 藍牙＋一台有線一起檢查：藍牙 +3、有線 +3、藍牙 +4、有線 +4（各 2 秒；每台兩種偏移、完全到位合計約 2 秒）
    static func pair(bluetooth bt: Int, wired w: Int, windowSeconds: Double = 10) -> [MonitorProbeStep] {
        make(steps: [(bt, 3.0), (w, 3.0), (bt, 4.0), (w, 4.0)], windowSeconds: windowSeconds)
    }

    /// devices 依序各探測一次；offsetsMs 依序輪用（round 讓同一台下一輪換另一個值）。
    /// ⚠ 一台只探測一次 → 單一偏移：誤差剛好落在 ±p 附近時會標 nearProbeImage（不採信），要靠下一輪換偏移；
    ///   而且探測要 ≥ minProbeSecondsSingleOffset（1.5 秒）才會採信 → 10 秒窗最多兩台
    static func make(devices: [Int], windowSeconds: Double = 10, offsetsMs: [Double] = [3.5], rampSeconds: Double = 0.5,
                     round: Int = 0) -> [MonitorProbeStep] {
        guard !offsetsMs.isEmpty else { return [] }
        return make(steps: devices.enumerated().map { ($0.element, offsetsMs[($0.offset + round) % offsetsMs.count]) },
                    windowSeconds: windowSeconds, rampSeconds: rampSeconds)
    }
}

struct MonitorDecider {
    struct Settings: Equatable {
        /// 誤差小於這個值不修（ms）
        var minCorrectMs = 0.5
        /// 連續兩次估計差在這個範圍內才算一致（ms）
        var confirmToleranceMs = 0.35
        /// 超過這個值不自行修，標記需要重新校正（ms）
        var bigOffsetMs = 10.0
        /// 修正斜率（ms／秒）：與 Engine.correctionSlewMsPerSecond 一致
        var slewMsPerSecond = 0.1
        /// 群集正常、但這台連續幾輪「量不到」→ 需要重新校正
        var missingLimit = 3
    }

    enum Action: Equatable {
        case none(String)
        /// 第一次看到這個誤差（ms），等下一輪確認
        case pending(Double)
        /// 修正：Engine.adjustLatencyCorrection(uid:, byMs:)；正 = 這台比設定晚到。rampSeconds = 以斜率走完的時間
        case correct(byMs: Double, rampSeconds: Double)
        case needsRecalibration(String)
    }

    var settings = Settings()
    private(set) var pendingMs: Double?
    private(set) var pendingBig = false
    private(set) var missing = 0

    init(settings: Settings = Settings()) { self.settings = settings }

    /// 修正已套用、重新校正、或裝置重連後呼叫
    mutating func reset() { pendingMs = nil; pendingBig = false; missing = 0 }

    /// 一輪的結果。skipped = 整輪跳過（節目音不適合、麥克風忙、校正中）：不影響確認狀態以外的計數
    mutating func feed(_ e: MonitorDeviceEstimate?, roundSkipped: Bool = false) -> Action {
        guard !roundSkipped, let e else {
            return .none("本輪跳過")
        }
        guard e.probed else { return .none("本輪沒有探測這台") }
        if !e.trusted {
            // 只因為「剛好在 ±探測偏移附近」而不採信：中性（不打斷確認，下一輪換偏移再量）
            if e.issues.allSatisfy({ $0 == .nearProbeImage }) { return .none("可能是假峰（±探測偏移），等換偏移的那輪") }
            // 「連續 2 次一致」：中間夾一次不可採信就重來
            pendingMs = nil; pendingBig = false
            if e.looksMissing {
                missing += 1
                if missing >= settings.missingLimit {
                    missing = 0
                    return .needsRecalibration("連續 \(settings.missingLimit) 輪量不到這台（偏移可能超過 ±15 ms）")
                }
                return .none("量不到（第 \(missing) 次）")
            }
            return .none("不可採信：" + e.issues.map(\.rawValue).joined(separator: "、"))
        }
        missing = 0
        let err = e.errorMs ?? 0
        if abs(err) > settings.bigOffsetMs {
            if pendingBig, let p = pendingMs, abs(p - err) <= max(settings.confirmToleranceMs, 1.0) {
                reset()
                return .needsRecalibration(String(format: "偏移 %+.1f ms 超過 %.0f ms，不自行修正", err, settings.bigOffsetMs))
            }
            pendingMs = err; pendingBig = true
            return .pending(err)
        }
        if abs(err) < settings.minCorrectMs {
            pendingMs = nil; pendingBig = false
            return .none(String(format: "誤差 %+.2f ms 在容許範圍內", err))
        }
        if !pendingBig, let p = pendingMs, abs(p - err) <= settings.confirmToleranceMs {
            let by = (p + err) / 2
            pendingMs = nil
            return .correct(byMs: by, rampSeconds: abs(by) / max(settings.slewMsPerSecond, 1e-6))
        }
        pendingMs = err; pendingBig = false
        return .pending(err)
    }
}
