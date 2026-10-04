// BluetoothDrift.swift — 【第 C 輪 2026-09-29，Kang 同意】藍牙同串流內延遲漂移：預測補償＋短校正排程＋藍牙連上後預設輸出自動切回
// （純邏輯，不碰 Core Audio／UI／子行程；AppState 驅動；`drift-selftest` 離線自測）
//
// 背景（第 B 輪實測）：GLASS5+ 在同一個 A2DP 串流內延遲單向漂移約 −0.78 ms／分鐘（約 13 ppm；BluetoothOut 的重取樣只看到 −3.6 ppm
// → 是喇叭自己的 DAC 時鐘／A2DP 緩衝，程式端的時鐘吸收不到）。背景監聽在這個房間幾乎量不到，不能依賴。藍牙門檻 3 ms。
//
// 1. 漂移模型（BluetoothDriftModel，每台藍牙一個）：
//    * 量測點 = 同一個串流內這台「相對參考喇叭的真實延遲」L（config 單位：measuredLatencyMs(藍牙) − measuredLatencyMs(參考)）：
//      只量藍牙的校正（寫入值）、完整校正、`--verify-program`（含只量藍牙的驗證）＝精確點（σ 0.3 ms）；
//      背景監聽可採信的結果（L = 校正值 + 當時的修正 + 誤差）＝σ 2 ms，只參與回歸，不能單獨決定修正、也不能單獨撐出速度。
//    * 速度：加權線性回歸（權重 1/σ²，近期加權 τ 15 分鐘）；精確點 ≥ 2 個、跨度 ≥ 2 分鐘才估。
//    * 【第 C 輪驗收後】預測 = 錨點（最新一個精確點的實測值）+ 速度 ×（t − 錨點）：剛量完 = 實測值（舊版用回歸直線，差 1.2–1.55 ms）。
//    * 預估誤差 σ(t)² = σ錨點² + (t − 錨點)²·Var(r) + (½·a·Δ²)²（a = 0.08 ms／分鐘²：速度本身會變；Δ = 距錨點的分鐘數）；
//      還沒有速度時 σ² = σ錨點² + (0.8 ms／分鐘 × Δ)²。2σ 超過 4 ms（約錨點後 7 分鐘）→ 停止外推，修正停在那一刻。
//    * 【第 C 輪驗收後】預測失準：精確點和加入前的預測差 > 3 ms（藍牙門檻；固定值，不跟著 σ 放大）→ 記下來、面板顯示；
//      有速度時代表速度變了 → 丟掉上一個錨點之前的點（用最近兩個精確點重估速度）。連續 2 次失準 → 「漂移不規則」：
//      不外推（修正停在最新實測）、標記需要重新校正；之後一個沒失準的精確點 → 恢復。
//    * 合理範圍：|r| ≤ 3 ms／分鐘；還沒有速度時新點和錨點差 > 3 ms／分鐘 × Δ + 2.5 ms、或背景監聽點偏離預測 > max(2.5, 3σ)＝矛盾。
//      超出範圍或矛盾 → 不外推（修正停在最新精確點）、標記需要重新校正；之後來一個校正點 → 以它重新開始。
//    * 串流重開（重連、app 重開、取樣率改變重開、HFP…）→ 整個重置，engine 裡這台的修正也清掉。
//    * AppState 每 10 秒把 修正 = L̂(now) − (校正值 − 參考校正值) 交給 Engine.setLatencyCorrection（Engine 以 ≤ 0.1 ms/秒 的斜率走過去）。
//    * 實測（第 C 輪驗收）：GLASS5+ 同一串流 38 分鐘內速度 +0.2 → −1.1 ms／分鐘，量測間隔 10–18 分鐘時任何外推都超過 3 ms；
//      補償要成立，靠的是約 5 分鐘一次的量測（下面的排程），模型只負責量測之間那幾分鐘。
// 2. 短校正排程（ShortCalScheduler）：量測點不夠時自己排「只量藍牙的短校正」（約 10 秒，`--pulse --only <藍牙>` 自動走短量測）：
//    * 第 1 點之後約 3 分鐘做第 2 點（取得漂移速度；2026-10-04 由 5 分鐘提早）；之後 2σ 預估誤差 > 2 ms（照目前參數約每 5 分鐘）或距上一點 30 分鐘，擇早。
//    * 【2026-10-04】校正後追蹤量測：串流的精確點 ≤ settleFollowUps（2）個時，到期就直接跑（不等空檔、不倒數）——剛串流時延遲一直長大。
//    * 到期後優先挑「節目音靜止」的空檔直接跑（不中斷音樂、不倒數）：tap 輸入連續 5 秒 < −60 dBFS、靜止前連續播了 ≥ 20 秒、
//      系統沒靜音且音量 > −40 dB；到期後連續播放 30 分鐘都沒有空檔，才走 AutoCalibrator 的倒數 3 秒（通知沒授權、面板關著 → needsConsent）。
//    * 沒量到 → 5 分鐘後再試；連續 3 次沒量到 → 標記需要重新校正、停止自動短校正（按「需要校正」量到後恢復）。
// 3. 藍牙連上後的預設輸出（BluetoothOutputRestorePolicy）：macOS 在藍牙（重新）連上時會把系統預設輸出切到它。
//    只對「本程式在出聲的藍牙（不在排除清單、沒關掉）出現後 10 秒內」發生的預設輸出變更自動切回音量來源（內建）；
//    「出現」以 Core Audio 全部藍牙輸出（含排除清單）判斷；之後使用者手動切到藍牙、或排除清單裡的藍牙 → 尊重，照舊只警告。
import Foundation

// MARK: - 量測點

enum DriftSource: String, Equatable, CaseIterable {
    case calibration, verify, monitor
    /// 背景監聽連續 2 次一致（兩輪平均）：當精確點用（可當錨點、可讓「矛盾」後重新開始）。
    /// 09-30 12:27 實機：喇叭自己跳 +12 ms，模型判矛盾後只認校正點 → 背景監聽確認了也修不到，要等下次校正
    case monitorConfirmed

    /// 這種量測的標準差（ms）：脈衝校正／驗證的 4 個脈衝離散約 0.1 ms，A2DP 抖動另算 → 0.3；背景監聽每輪誤差約 2–4 ms
    var sigmaMs: Double {
        switch self {
        case .calibration, .verify: return 0.3
        case .monitor: return 2.0
        case .monitorConfirmed: return 1.0
        }
    }

    /// 和模型矛盾時可以「以它重新開始」的來源（驗證點只是抽查、單輪背景監聽太吵，不行）
    var restartsModel: Bool { self == .calibration || self == .monitorConfirmed }

    var label: String {
        switch self {
        case .calibration: return "校正"
        case .verify: return "驗證"
        case .monitor: return "背景監聽"
        case .monitorConfirmed: return "背景監聽確認"
        }
    }
}

struct DriftPoint: Equatable {
    let at: Date
    /// 相對參考喇叭的真實延遲（ms，config 單位）
    let latencyMs: Double
    let sigmaMs: Double
    let source: DriftSource

    init(at: Date, latencyMs: Double, source: DriftSource, sigmaMs: Double? = nil) {
        self.at = at
        self.latencyMs = latencyMs
        self.source = source
        self.sigmaMs = sigmaMs ?? source.sigmaMs
    }
}

struct DriftModelParams: Equatable {
    /// 漂移速度合理範圍（ms／分鐘）
    var maxRateMsPerMin = 3.0
    /// 漂移速度本身會變（預估誤差用）：速度以這個加速度（ms／分鐘²）隨機走 → 距錨點（最新一個精確量測點）Δ 分鐘多 ½·a·Δ² 的誤差。
    /// 【2026-09-29 D2 實測】GLASS5+ 的速度 20 分鐘內從 −0.73 變到 +0.8 ms／分鐘 ≈ 0.08 ms／分鐘²；
    /// 【2026-09-29 第 C 輪驗收】同一串流 38 分鐘內 +0.23 → −0.74 → −1.1 ms／分鐘（0.04–0.07 ms／分鐘²）。
    /// 注意：這一項只跟「距錨點多久」有關，點再多也不會變小 → 2σ > 2 ms 約在錨點後 5 分鐘（＝實際的量測頻率）
    var rateWanderMsPerMin2 = 0.08
    /// 【第 C 輪驗收後】還沒估出速度（只有 1 個精確點）時，預估誤差以這個速度（ms／分鐘）隨時間長大（實測 |速度| 0.2–1.1）
    var priorRateMsPerMin = 0.8
    /// 【第 C 輪驗收後】預測失準：精確點（校正／驗證）和「加入前的預測」差超過這個（ms；＝藍牙門檻）＝補償已經超出門檻。
    /// 不跟著 σ 放大（稀疏資料時 σ 很大，舊版 3σ 容許量會把偏 9–12 ms 的點照收、面板還顯示「正常」）
    var missMs = 3.0
    /// 連續幾次預測失準 → 漂移不規則（不外推、標記需要重新校正）
    var erraticMisses = 2
    /// 背景監聽點的矛盾判定：|新點 − 預測| > max(contradictionMinMs, contradictionSigmas × √(σ預測² + σ點²))
    var contradictionMinMs = 2.5
    var contradictionSigmas = 3.0
    /// 精確點（校正／驗證）的時間跨度至少這麼長才估漂移速度（兩點太近 → 速度誤差很大）；背景監聽點不算（只參與回歸）
    var minSpanSeconds = 120.0
    var maxPoints = 40
    /// 【2026-09-29 D2 實測後】近期加權：權重再乘 exp(−(最新一點 − t)／τ)（分鐘；0 = 不加權）。
    /// GLASS5+ 的漂移速度不是常數（D2：前 10 分鐘 −0.73、之後 −0.3、20 分鐘後轉成 +0.8 ms／分鐘），速度要跟著最近的點
    var recencyTauMinutes = 15.0
    /// 【2026-09-29 D2 實測後】預估誤差 2σ 超過這個（ms）就停止外推（修正停在那一刻的預測值，不再沿著舊速度走）。
    /// 約在錨點後 7 分鐘；排程在 2σ > 2 ms（約 5 分鐘）時就要求量測，這裡是「一直等不到量測」時的上限
    var holdAtTwoSigmaMs = 4.0
}

enum DriftModelHealth: Equatable {
    case ok
    /// 新的量測和模型對不上（原因）
    case contradiction(String)
    /// 漂移速度超出合理範圍（ms／分鐘）
    case rateOutOfRange(Double)
    /// 【第 C 輪驗收後】連續幾次預測失準（> 3 ms）：漂移不規則，外推跟不上
    case erratic(String)

    var extrapolates: Bool { self == .ok }

    var text: String {
        switch self {
        case .ok: return "正常"
        case .contradiction(let m): return "量測彼此矛盾（\(m)）"
        case .rateOutOfRange(let r): return String(format: "漂移速度 %+.2f ms／分鐘超出合理範圍", r)
        case .erratic(let m): return "漂移不規則（\(m)）"
        }
    }

    var isErratic: Bool { if case .erratic = self { return true } else { return false } }
}

struct DriftPrediction: Equatable {
    /// 預測的相對延遲（ms）
    let ms: Double
    /// 預估誤差（1σ，ms）
    let sigmaMs: Double
    /// 漂移速度（ms／分鐘）；nil = 還沒估（精確點不夠或跨度太短）或不外推
    let rateMsPerMin: Double?
    /// true = 預估誤差 2σ 已超過 holdAtTwoSigmaMs：停在超過那一刻的預測值（不再外推）
    var held = false
}

/// 【第 C 輪驗收後】一次預測失準（精確點和加入前的預測差 > missMs）
struct DriftMiss: Equatable {
    let at: Date
    /// 實測 − 預測（ms）
    let residualMs: Double
    let source: DriftSource
}

final class BluetoothDriftModel {
    let uid: String
    var params: DriftModelParams
    private(set) var points: [DriftPoint] = []
    private(set) var health: DriftModelHealth = .ok
    /// 目前串流的識別（BluetoothOutManager.streamKeys）；變了 = 串流重開 → reset
    private(set) var streamKey: String?
    private(set) var streamStartedAt: Date?
    /// 最近一次預測失準、連續失準次數、這個串流內失準總數
    private(set) var lastMiss: DriftMiss?
    private(set) var consecutiveMisses = 0
    private(set) var missCount = 0

    init(uid: String, params: DriftModelParams = DriftModelParams()) {
        self.uid = uid
        self.params = params
    }

    /// 串流重開（或第一次看到）：全部歸零
    func reset(streamKey: String?, at: Date) {
        points = []
        health = .ok
        lastMiss = nil
        consecutiveMisses = 0
        missCount = 0
        self.streamKey = streamKey
        streamStartedAt = at
    }

    /// 量測點比串流識別先到（模型建立時還不知道串流識別）：補上，不清點
    func adopt(streamKey key: String) {
        if streamKey == nil { streamKey = key }
    }

    struct Fit: Equatable {
        let tRef: Date
        /// tRef 時的值（ms）
        let a: Double
        /// ms／秒
        let rate: Double
        let varA: Double
        let varRate: Double
    }

    /// 錨點：最新一個精確點（校正／驗證）。預測 = 錨點的實測值 + 速度 × 距錨點的時間（不是回歸直線本身：
    /// 剛量完就要等於實測值；背景監聽點 σ 2–4 ms，不能單獨決定修正）。只有背景監聽點時 → 它們的加權平均
    var anchor: DriftPoint? {
        if let p = points.last(where: { $0.source != .monitor }) { return p }
        guard !points.isEmpty else { return nil }
        let w = points.map { 1 / max($0.sigmaMs * $0.sigmaMs, 1e-6) }
        let W = w.reduce(0, +)
        let v = zip(w, points).reduce(0) { $0 + $1.0 * $1.1.latencyMs } / W
        return DriftPoint(at: points.last!.at, latencyMs: v, source: .monitor, sigmaMs: (1 / W).squareRoot())
    }

    /// 加權最小平方直線：精確點 ≥ 2、精確點的時間跨度 ≥ minSpanSeconds 才有（背景監聽點只參與回歸，不能單獨撐出速度）
    func fit() -> Fit? {
        let precise = points.filter { $0.source != .monitor }
        guard precise.count >= 2, let p0 = precise.first, let p1 = precise.last, p1.at.timeIntervalSince(p0.at) >= params.minSpanSeconds else { return nil }
        return Self.fit(points, minSpan: params.minSpanSeconds, recencyTauMinutes: params.recencyTauMinutes)
    }

    static func fit(_ pts: [DriftPoint], minSpan: Double, recencyTauMinutes: Double = 0) -> Fit? {
        guard pts.count >= 2, let t0 = pts.map(\.at).min(), let t1 = pts.map(\.at).max(), t1.timeIntervalSince(t0) >= minSpan else { return nil }
        let tau = recencyTauMinutes * 60
        let w = pts.map { p in 1 / max(p.sigmaMs * p.sigmaMs, 1e-6) * (tau > 0 ? exp(-t1.timeIntervalSince(p.at) / tau) : 1) }
        let W = w.reduce(0, +)
        let xs = pts.map { $0.at.timeIntervalSince(t0) }
        let xm = zip(w, xs).reduce(0) { $0 + $1.0 * $1.1 } / W
        let a = zip(w, pts).reduce(0) { $0 + $1.0 * $1.1.latencyMs } / W
        var sxx = 0.0, sxy = 0.0
        for i in pts.indices {
            let dx = xs[i] - xm
            sxx += w[i] * dx * dx
            sxy += w[i] * dx * (pts[i].latencyMs - a)
        }
        guard sxx > 0 else { return nil }
        let r = sxy / sxx
        var chi2 = 0.0
        for i in pts.indices {
            let e = pts[i].latencyMs - a - r * (xs[i] - xm)
            chi2 += w[i] * e * e
        }
        // 點的實際散布比標稱 σ 大 → 按比例放大不確定度（不縮小）
        let s = pts.count > 2 ? max(1, chi2 / Double(pts.count - 2)) : 1
        return Fit(tRef: t0.addingTimeInterval(xm), a: a, rate: r, varA: s / W, varRate: s / sxx)
    }

    /// 預測 t 時的相對延遲。沒有點 → nil。
    /// 外推（健康、有速度）：錨點 + 速度 ×（t − 錨點）；預估誤差 2σ 超過 holdAtTwoSigmaMs → 停在剛超過的那一刻。
    /// 不外推（還沒估速度、矛盾、不規則、速度超出範圍）：錨點（最新一個精確點）的值，預估誤差隨時間長大
    func predict(at t: Date) -> DriftPrediction? {
        guard let anc = anchor else { return nil }
        if health.extrapolates, let f = fit() {
            let v = Self.variance(f, anchor: anc, at: t, accel: params.rateWanderMsPerMin2)
            let h = params.holdAtTwoSigmaMs / 2
            if params.holdAtTwoSigmaMs > 0, t > anc.at, v > h * h {
                // σ(u) 對 u = 距錨點的時間單調遞增 → 二分法找剛超過的那一刻；錨點當下就超過 → 停在錨點（實測值）
                var lo = anc.at, hi = t
                if Self.variance(f, anchor: anc, at: lo, accel: params.rateWanderMsPerMin2) < h * h {
                    for _ in 0..<40 {
                        let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                        if Self.variance(f, anchor: anc, at: mid, accel: params.rateWanderMsPerMin2) > h * h { hi = mid } else { lo = mid }
                    }
                } else { hi = anc.at }
                return DriftPrediction(ms: anc.latencyMs + f.rate * hi.timeIntervalSince(anc.at), sigmaMs: v.squareRoot(), rateMsPerMin: f.rate * 60, held: true)
            }
            return DriftPrediction(ms: anc.latencyMs + f.rate * t.timeIntervalSince(anc.at), sigmaMs: v.squareRoot(), rateMsPerMin: f.rate * 60)
        }
        let dMin = abs(t.timeIntervalSince(anc.at)) / 60
        let prior = params.priorRateMsPerMin * dMin
        return DriftPrediction(ms: anc.latencyMs, sigmaMs: (anc.sigmaMs * anc.sigmaMs + prior * prior).squareRoot(), rateMsPerMin: nil)
    }

    /// 預估誤差²（外推時）：σ錨點² + (t − 錨點)²·Var(r) + (½·a·Δ²)²（Δ = 距錨點的分鐘數）
    static func variance(_ f: Fit, anchor: DriftPoint, at t: Date, accel: Double) -> Double {
        let dt = t.timeIntervalSince(anchor.at)
        let since = abs(dt) / 60
        let w = 0.5 * accel * since * since
        return anchor.sigmaMs * anchor.sigmaMs + dt * dt * f.varRate + w * w
    }

    enum AddResult: Equatable {
        case accepted
        /// 精確點和加入前的預測差 > missMs（補償已超出門檻）：記下來；有速度時丟掉舊的點（速度變了），只留上一個錨點起的點
        case missed(Double)
        /// 連續 erraticMisses 次預測失準 → 不外推、需要重新校正
        case erratic(String)
        /// 校正點和舊模型矛盾（或模型本來就矛盾／速度超出範圍）→ 以它重新開始
        case restarted(String)
        /// 驗證／背景監聽的點和模型矛盾 → 不外推、需要重新校正
        case contradiction(String)
        /// 加進去之後漂移速度超出範圍 → 不外推、需要重新校正
        case rateOutOfRange(Double)
    }

    func add(_ p: DriftPoint) -> AddResult {
        let precise = p.source != .monitor
        let before = predict(at: p.at)
        let hadFit = health.extrapolates && fit() != nil
        // 1. 預測失準（只看精確點；背景監聽每輪誤差 2–4 ms，不算）
        var resid: Double?
        if precise, let b = before {
            let r = p.latencyMs - b.ms
            if abs(r) > params.missMs {
                resid = r
                consecutiveMisses += 1
                missCount += 1
                lastMiss = DriftMiss(at: p.at, residualMs: r, source: p.source)
            } else {
                consecutiveMisses = 0
            }
        }
        // 有速度（或已判不規則）時失準 = 速度變了：舊的點不再代表現在，只留上一個錨點起的點（上一個錨點＋這一點 → 新速度）
        if resid != nil, hadFit || health.isErratic, let a = anchor, a.source != .monitor {
            points.removeAll { $0.at < a.at }
        }
        // 2. 已經矛盾／速度超出範圍：校正點 → 重新開始；其他點只記下來（不外推）
        switch health {
        case .contradiction, .rateOutOfRange:
            if p.source.restartsModel {
                let why = "模型\(health.text)後\(p.source == .calibration ? "重新校正" : "背景監聽連續 2 次一致")"
                points = [p]
                health = .ok
                consecutiveMisses = 0
                return .restarted(why)
            }
            append(p)
            return health.isRate ? .rateOutOfRange(health.rate) : .contradiction(health.text)
        case .ok, .erratic:
            break
        }
        // 3. 明顯矛盾：還沒有速度 → 和錨點比（容許合理範圍內的漂移）；背景監聽點有速度時 → 和預測比（σ）
        var why: String?
        if health.extrapolates, fit() != nil {
            if !precise, let pr = before {
                let d = p.latencyMs - pr.ms
                let tol = max(params.contradictionMinMs, params.contradictionSigmas * (pr.sigmaMs * pr.sigmaMs + p.sigmaMs * p.sigmaMs).squareRoot())
                if abs(d) > tol { why = String(format: "%@量到 %.2f ms、模型預測 %.2f ms，差 %+.2f ms（容許 %.2f）", p.source.label, p.latencyMs, pr.ms, d, tol) }
            }
        } else if let last = anchor {
            let dtMin = abs(p.at.timeIntervalSince(last.at)) / 60
            let bound = params.maxRateMsPerMin * dtMin
                + max(params.contradictionMinMs, params.contradictionSigmas * (last.sigmaMs * last.sigmaMs + p.sigmaMs * p.sigmaMs).squareRoot())
            let d = p.latencyMs - last.latencyMs
            if abs(d) > bound { why = String(format: "%.1f 分鐘內差 %+.2f ms（上限 %.2f）", dtMin, d, bound) }
        }
        if let why {
            if p.source.restartsModel {
                points = [p]
                health = .ok
                // 重新開始＝舊的失準紀錄一起作廢；不歸零的話下一個背景監聽點就因「連續 2 次失準」又判不規則、永遠不外推
                //（09-30 04:38 校正 413.18 後 16 分鐘 5 個監聽點全被判「最近 −97.8 ms：補償跟不上」、修正一直 +0.00）
                consecutiveMisses = 0
                return .restarted(why)
            }
            append(p)
            health = .contradiction(why)
            return .contradiction(why)
        }
        append(p)
        // 4. 連續失準 → 不規則；不規則之後來一個沒失準的精確點 → 恢復
        if consecutiveMisses >= params.erraticMisses {
            let t = erraticText()
            health = .erratic(t)
            return .erratic(t)
        }
        if health.isErratic, precise { health = .ok }
        if health.extrapolates, let f = fit(), abs(f.rate * 60) > params.maxRateMsPerMin {
            health = .rateOutOfRange(f.rate * 60)
            return .rateOutOfRange(f.rate * 60)
        }
        if let r = resid { return .missed(r) }
        return .accepted
    }

    private func erraticText() -> String {
        String(format: "連續 %d 次預測偏差超過 %.0f ms，最近 %+.1f ms：補償跟不上", consecutiveMisses, params.missMs, lastMiss?.residualMs ?? 0)
    }

    private func append(_ p: DriftPoint) {
        points.append(p)
        points.sort { $0.at < $1.at }
        if points.count > params.maxPoints { points.removeFirst(points.count - params.maxPoints) }
    }
}

private extension DriftModelHealth {
    var isRate: Bool { if case .rateOutOfRange = self { return true } else { return false } }
    var rate: Double { if case .rateOutOfRange(let r) = self { return r } else { return 0 } }
}

// MARK: - 子行程輸出（機器可讀行）

/// `@@latency-obs <uid> <相對延遲 ms> <離散 ms> <採用數> <calibration|verify>`（ProgramPath：寫入、驗證、只量藍牙的驗證）
struct LatencyObservation: Equatable {
    let uid: String
    let latencyMs: Double
    let spreadMs: Double
    let count: Int
    let source: DriftSource
}

func parseLatencyObservations(_ lines: [String]) -> [LatencyObservation] {
    lines.compactMap { l in
        guard let rg = l.range(of: "@@latency-obs ") else { return nil }
        let t = String(l[rg.lowerBound...]).trimmingCharacters(in: .whitespaces)
        let f = t.split(separator: " ").map(String.init)
        guard f.count >= 6, let v = Double(f[2]), let sp = Double(f[3]), let n = Int(f[4]), let src = DriftSource(rawValue: f[5]), v.isFinite else { return nil }
        return LatencyObservation(uid: f[1], latencyMs: v, spreadMs: sp, count: n, source: src)
    }
}

/// `@@short-miss <uid>`：短量測在預期的窗內找不到這台
func parseShortMissUIDs(_ lines: [String]) -> Set<String> {
    Set(lines.compactMap { l in
        guard let rg = l.range(of: "@@short-miss ") else { return nil }
        let t = String(l[rg.lowerBound...]).trimmingCharacters(in: .whitespaces)
        let u = String(t.dropFirst("@@short-miss ".count)).trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? nil : u
    })
}

/// `@@bt-residual <uid> <ms>`：只量藍牙的驗證的殘差（log 用）
func parseBluetoothResiduals(_ lines: [String]) -> [(String, Double)] {
    lines.compactMap { l in
        guard let rg = l.range(of: "@@bt-residual ") else { return nil }
        let t = String(l[rg.lowerBound...]).trimmingCharacters(in: .whitespaces)
        let f = t.split(separator: " ").map(String.init)
        guard f.count >= 3, let v = Double(f[2]) else { return nil }
        return (f[1], v)
    }
}

// MARK: - 短校正排程

struct ShortCalParams: Equatable {
    /// 第 1 點之後多久做第 2 點（估漂移速度）。【2026-10-04】300 → 180：實測校正後 5 分鐘 GLASS5+ 已晚 73 ms、MK-99 晚 32 ms
    var secondPointAfter: TimeInterval = 180
    /// 【2026-10-04 Kang 定案】校正後追蹤量測：每個串流的前這麼多次短校正，到期就直接跑——
    /// 不等節目音空檔、不倒數（藍牙剛開始串流時延遲會一直長大，等 30 分鐘空檔期間早就不同步）。之後恢復空檔優先的規則
    var settleFollowUps = 2
    /// 距上一點最久（即使預估誤差還小）。【第 C 輪驗收後】照目前的預估誤差參數（速度會變 0.08 ms／分鐘²）
    /// 2σ > 2 ms 約在錨點後 5 分鐘就到期，這個上限只有「速度很穩的喇叭（rateWanderMsPerMin2 很小）」才會用到
    var maxInterval: TimeInterval = 1800
    /// 2σ 預估誤差超過這個（ms）就該量了
    var uncertaintyLimitMs = 2.0
    /// 節目音連續靜止多久算「空檔」
    var silenceSeconds: TimeInterval = 5
    /// 靜止超過這麼久就不算「聽音樂中間的空檔」（不聽了：半夜、離開座位）→ 不跑（不在安靜的房間裡一直放測試音）
    var maxGapSilence: TimeInterval = 600
    /// 【第 C 輪審查】空檔之前節目音至少連續播了這麼久才算「聽音樂中間的空檔」（剛開 app、長段靜音開頭不算）
    var minPlayingBeforeGap: TimeInterval = 20
    /// 【第 C 輪審查】系統音量增益低於這個（或靜音）→ 使用者要安靜：不跑空檔短校正、也不倒數（−40 dB）
    var minVolumeGain: Float = 0.01
    /// 到期後連續播放這麼久都沒空檔 → 倒數 3 秒（Kang 定案 30 分鐘；代價見 README「藍牙漂移補償」：凍結期間誤差會累積）
    var maxWaitForGap: TimeInterval = 1800
    /// 一次沒量到，多久後再試
    var retrySeconds: TimeInterval = 300
    /// 【2026-10-04】出聲中但這個串流還沒量過（app 重開後沿用上次的延遲）：節目音連續播了這麼久（＝有人在聽）就直接短校正
    var firstPointPlayingSeconds: TimeInterval = 5
    /// 連續幾次沒量到 → 標記需要重新校正，**停止自動短校正**（等使用者按「需要校正」、或下一次量到／串流重開）
    var maxFailures = 3
    /// 找「預估誤差超過門檻」的時間點的步長（秒）
    var searchStep: TimeInterval = 10
}

struct ShortCalTarget: Equatable {
    let uid: String
    let name: String
    /// 出聲中（音樂模式、沒有暫停出聲等校正）
    let active: Bool
}

struct ShortCalEnvironment: Equatable {
    var enabled = true
    /// 可以開始（engine 在跑、沒有校正／自動校正／背景監聽在跑、不是另一個實例）
    var canStart = true
    /// tap 輸入（節目音）連續靜止了幾秒（< −60 dBFS）；0 = 正在播
    var programSilentSeconds: TimeInterval = 0
    /// 這段靜止之前，節目音連續播了幾秒（0 = 不知道／app 啟動後一直沒播）
    var playedBeforeSilence: TimeInterval = .infinity
    /// 距離上一次「可用的空檔」（連續靜止 ≥ silenceSeconds）結束幾秒 ＝ 已經連續播放多久（沒有空檔過）；很大 = app 啟動以來都沒有
    var secondsSinceLastGap: TimeInterval = .infinity
    /// 節目音目前連續播了幾秒（0 = 沒在播）
    var programPlayingSeconds: TimeInterval = 0
    /// 系統音量增益（0 = 靜音）
    var volumeGain: Float = 1
    /// AutoCalibrator 已經為它延後（needsConsent／取消）：不再倒數（空檔照樣可以跑）
    var countdownBlocked: Set<String> = []
    var targets: [ShortCalTarget] = []
}

enum ShortCalAction: Equatable {
    /// 開始短校正：gap = true 空檔直接跑（不倒數）；false = 連續播放太久，走倒數 3 秒
    case start(uid: String, name: String, gap: Bool, reason: String)
    /// 連續幾次沒量到 → 需要重新校正
    case flag(uid: String, name: String, reason: String)
    case log(String)
}

final class ShortCalScheduler {
    var params: ShortCalParams
    /// 到期的時間（到期後一直沒跑 → 用來算「連續播放多久沒空檔」）
    private(set) var dueSince: [String: Date] = [:]
    private(set) var lastAttempt: [String: Date] = [:]
    private(set) var failures: [String: Int] = [:]
    /// 最近一次開始的是哪台、空檔還是倒數（ctl／面板顯示）
    private(set) var lastStart: (uid: String, at: Date, gap: Bool)?
    /// 【2026-10-04】校正後追蹤量測：每台「這個串流」已經跑了幾次（串流換了就歸零）。
    /// 以次數計、不看精確點數：MK-99 每 3 分鐘跳 ±25 ms，模型每次「以新校正點重新開始」→ 點數一直是 1，
    /// 用點數判斷會每 3 分鐘中斷一次音樂（實機 22:47–22:57 連跑 4 次）
    private(set) var followUps: [String: (stream: String?, count: Int)] = [:]

    init(params: ShortCalParams = ShortCalParams()) { self.params = params }

    func reset(uid: String) {
        dueSince[uid] = nil; lastAttempt[uid] = nil; failures[uid] = nil; followUps[uid] = nil
    }

    /// 連續沒量到已達上限：停止自動短校正（等使用者、下一次量到或串流重開）
    func stopped(_ uid: String) -> Bool { (failures[uid] ?? 0) >= params.maxFailures }

    /// 什麼時候該量下一點（nil = 沒有量測點：交給自動校正）；reason 給 log／面板
    func dueAt(_ m: BluetoothDriftModel) -> (at: Date, reason: String)? {
        guard let first = m.points.first, let last = m.points.last, let anc = m.anchor else { return nil }
        if !m.health.extrapolates { return (last.at, "漂移模型\(m.health.text)") }
        guard let f = m.fit() else {
            return (first.at.addingTimeInterval(params.secondPointAfter), "取得第 2 個量測點（估漂移速度）")
        }
        let cap = anc.at.addingTimeInterval(params.maxInterval)
        let limit = params.uncertaintyLimitMs / 2
        var t = anc.at
        while t < cap {
            if BluetoothDriftModel.variance(f, anchor: anc, at: t, accel: m.params.rateWanderMsPerMin2) > limit * limit {
                return (t, String(format: "預估誤差 2σ 將超過 %.0f ms", params.uncertaintyLimitMs))
            }
            t = t.addingTimeInterval(params.searchStep)
        }
        return (cap, String(format: "距上一個量測點 %.0f 分鐘", params.maxInterval / 60))
    }

    func tick(now: Date, env: ShortCalEnvironment, models: [String: BluetoothDriftModel]) -> [ShortCalAction] {
        guard env.enabled else { dueSince = [:]; return [] }
        for t in env.targets {
            // 【2026-10-04】出聲中、這個串流還沒有量測點（app 重開後沿用上次的延遲）：有人在聽就直接短校正（不倒數）。
            // 「有人在聽」= 節目音連續播了 ≥ firstPointPlayingSeconds，或聽音樂中間的空檔——不在登入時、安靜的房間裡放測試音
            if t.active, models[t.uid]?.points.isEmpty ?? true {
                dueSince[t.uid] = nil
                guard env.canStart, !stopped(t.uid), env.volumeGain >= params.minVolumeGain else { continue }
                if let la = lastAttempt[t.uid], now.timeIntervalSince(la) < params.retrySeconds { continue }
                let listening = env.programPlayingSeconds >= params.firstPointPlayingSeconds
                    || (env.programSilentSeconds >= params.silenceSeconds && env.programSilentSeconds <= params.maxGapSilence
                        && env.playedBeforeSilence >= params.minPlayingBeforeGap)
                guard listening else { continue }
                lastAttempt[t.uid] = now
                lastStart = (t.uid, now, true)
                return [.start(uid: t.uid, name: t.name, gap: true,
                               reason: "這個串流還沒量過（沿用上次的延遲出聲中）；有人在聽音樂 → 直接短校正（不倒數）")]
            }
            guard t.active, let m = models[t.uid], let due = dueAt(m) else { dueSince[t.uid] = nil; continue }
            guard now >= due.at else { dueSince[t.uid] = nil; continue }
            let since = dueSince[t.uid] ?? due.at
            dueSince[t.uid] = since
            guard env.canStart, !stopped(t.uid) else { continue }
            // 系統靜音／音量很小：使用者要安靜 → 不放測試音（空檔、倒數都不跑）
            guard env.volumeGain >= params.minVolumeGain else { continue }
            if let la = lastAttempt[t.uid], now.timeIntervalSince(la) < params.retrySeconds { continue }
            let gap: Bool
            // 連續播放多久（到期之後、而且上一次空檔之後）
            let playingFor = min(now.timeIntervalSince(since), env.secondsSinceLastGap)
            var fu = followUps[t.uid] ?? (m.streamKey, 0)
            if fu.stream != m.streamKey { fu = (m.streamKey, 0) }
            if fu.count < params.settleFollowUps {
                fu.count += 1
                followUps[t.uid] = fu
                lastAttempt[t.uid] = now
                lastStart = (t.uid, now, true)
                return [.start(uid: t.uid, name: t.name, gap: true,
                               reason: "\(due.reason)；校正後追蹤量測（這個串流第 \(fu.count)／\(params.settleFollowUps) 次：藍牙剛開始串流延遲會一直變，不等空檔、不倒數）")]
            }
            if env.programSilentSeconds >= params.silenceSeconds {
                // 空檔：靜止太久（不聽了）、或靜止之前沒有在播（剛開、長段靜音開頭）就不跑
                guard env.programSilentSeconds <= params.maxGapSilence, env.playedBeforeSilence >= params.minPlayingBeforeGap else { continue }
                gap = true
            } else if playingFor >= params.maxWaitForGap, !env.countdownBlocked.contains(t.uid) {
                gap = false
            } else {
                continue
            }
            lastAttempt[t.uid] = now
            lastStart = (t.uid, now, gap)
            let why = gap ? String(format: "節目音靜止 %.0f 秒（空檔，不倒數）", env.programSilentSeconds)
                          : String(format: "到期後連續播放 %.0f 分鐘都沒有空檔（倒數 3 秒）", playingFor / 60)
            return [.start(uid: t.uid, name: t.name, gap: gap, reason: "\(due.reason)；\(why)")]
        }
        return []
    }

    /// 這次短校正（或任何量到這台的量測）結束
    func attemptFinished(uid: String, name: String, measured: Bool, now: Date) -> [ShortCalAction] {
        if measured {
            failures[uid] = 0
            dueSince[uid] = nil
            // 「5 分鐘後再試」只給沒量到的情況；量到了就照 dueAt 排（2026-10-04：校正後追蹤量測的第 2 點約 4 分鐘後到期，舊版會被擋到 5 分鐘）
            lastAttempt[uid] = nil
            return []
        }
        let f = (failures[uid] ?? 0) + 1
        failures[uid] = f
        // 「5 分鐘後再試」從這次結束算起：倒數等使用者同意可能拖很久（09-29 22:55 倒數、23:21 才跑），
        // 只記開始時間的話失敗後 retrySeconds 早就過了 → 1 秒後又放一次測試音（23:22:02 失敗、23:22:06 再跑）
        lastAttempt[uid] = now
        if f >= params.maxFailures {
            return [.log("漂移補償：「\(name)」短校正連續 \(f) 次沒有量到 → 停止自動短校正（按「需要校正」或下一次量到才恢復）"),
                    .flag(uid: uid, name: name, reason: "藍牙短校正連續 \(f) 次沒有量到，漂移補償可能不準")]
        }
        return [.log("漂移補償：「\(name)」短校正沒有量到（連續 \(f) 次），\(Int(params.retrySeconds / 60)) 分鐘後再試")]
    }
}

// MARK: - 藍牙連上後預設輸出自動切回

struct BluetoothOutputRestorePolicy: Equatable {
    /// 藍牙出現後多久內的預設輸出變更算「macOS 自動搶的」
    static let window: TimeInterval = 10
    /// 同一次連上最多自動切回幾次（macOS 若一直搶就不跟它打架）
    var maxRestoresPerConnect = 3
    /// 目前在的藍牙輸出（**全部**，含排除清單裡的；nil = 還沒看過清單：app 剛啟動時已經連著的不算「剛連上」）。
    /// 【第 C 輪審查】以前只記本程式管理的（Devices.bluetoothOutputs() 濾掉排除清單）→ 早就連著、但被排除的 AirPods
    /// 一小時後被手動選成預設輸出時「不在清單裡」→ 被當成剛連上而切回
    private(set) var known: Set<String>?
    private(set) var connectedAt: [String: Date] = [:]
    private(set) var restores: [String: Int] = [:]

    enum Decision: Equatable {
        case none
        /// 自動切回（藍牙出現後幾秒）
        case restore(uid: String, secondsAfterConnect: Double)
        /// 尊重（超過 10 秒、功能關閉、切太多次、不是本程式出聲的藍牙）：照舊只警告
        case respect(uid: String, why: String)
    }

    /// uids = 目前 Core Audio 裡**所有**活著的藍牙輸出（含排除清單）
    mutating func bluetoothOutputsChanged(_ uids: Set<String>, now: Date) {
        if let k = known {
            for u in uids.subtracting(k) { connectedAt[u] = now; restores[u] = 0 }
            for u in k.subtracting(uids) { connectedAt[u] = nil; restores[u] = nil }
        }
        known = uids
    }

    /// managed = 這台是本程式在出聲的藍牙喇叭（不在排除清單、沒被使用者關掉）；不是 → 一律尊重（不管剛連上與否）
    mutating func defaultOutputChanged(to uid: String?, isBluetooth: Bool, managed: Bool, enabled: Bool, now: Date) -> Decision {
        guard let uid, isBluetooth else { return .none }
        // 預設輸出的通知比裝置清單先到：這台還沒在（全部藍牙的）清單裡 → 就是現在連上的
        if connectedAt[uid] == nil, var k = known, !k.contains(uid) {
            connectedAt[uid] = now; restores[uid] = 0
            k.insert(uid); known = k
        }
        guard managed else { return .respect(uid: uid, why: "不是本程式出聲的藍牙（排除清單或已關閉）") }
        guard let t = connectedAt[uid] else { return .respect(uid: uid, why: "不是剛連上的藍牙") }
        let dt = now.timeIntervalSince(t)
        guard dt <= Self.window else { return .respect(uid: uid, why: String(format: "藍牙連上已 %.0f 秒（> %.0f 秒，視為使用者自己選的）", dt, Self.window)) }
        guard enabled else { return .respect(uid: uid, why: "自動切回已關閉") }
        let n = restores[uid] ?? 0
        guard n < maxRestoresPerConnect else { return .respect(uid: uid, why: "這次連上已自動切回 \(n) 次") }
        restores[uid] = n + 1
        return .restore(uid: uid, secondsAfterConnect: dt)
    }
}

// MARK: - 離線自測（`In_Unison42 drift-selftest`；純邏輯，不出聲、不開麥克風）

func runDriftSelfTest() -> Int32 {
    var fail = 0, pass = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if ok { pass += 1 } else { fail += 1 }
    }
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    func at(_ min: Double) -> Date { t0.addingTimeInterval(min * 60) }
    let rate = -0.78   // ms／分鐘（第 B 輪 GLASS5+ 實測）
    func truth(_ min: Double) -> Double { 436.148 + rate * min }
    // 固定種子的量測雜訊
    var seed: UInt64 = 0x5EED_D21F
    func noise(_ s: Double) -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let u1 = max(Double(seed >> 11) / Double(1 << 53), 1e-12)
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let u2 = Double(seed >> 11) / Double(1 << 53)
        return s * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    print("── 1. 漂移模型：加權線性回歸 ──")
    do {
        let m = BluetoothDriftModel(uid: "bt")
        m.reset(streamKey: "s1", at: at(0))
        check(m.predict(at: at(1)) == nil, "沒有點：不預測")
        _ = m.add(DriftPoint(at: at(0), latencyMs: truth(0), source: .calibration))
        let p1 = m.predict(at: at(3))!
        check(p1.rateMsPerMin == nil && abs(p1.ms - truth(0)) < 1e-9, "只有 1 點：不外推（停在那一點）", String(format: "%.3f", p1.ms))
        _ = m.add(DriftPoint(at: at(1), latencyMs: truth(1), source: .verify))
        check(m.fit() == nil, "兩點只差 1 分鐘（< 2 分鐘）：還不估速度")
        _ = m.add(DriftPoint(at: at(5), latencyMs: truth(5), source: .calibration))
        let f = m.fit()
        check(f != nil && abs(f!.rate * 60 - rate) < 1e-6, "無雜訊 3 點：速度 = −0.78 ms／分鐘", String(format: "%.4f", (f?.rate ?? 0) * 60))
        let p = m.predict(at: at(10))!
        check(abs(p.ms - truth(10)) < 1e-6 && p.sigmaMs > 0, "外推 5 分鐘：誤差 < 1e-6 ms、有預估誤差", String(format: "預測 %.3f、σ %.3f", p.ms, p.sigmaMs))
        // 權重：背景監聽（σ 2 ms）偏 +3 ms 的點幾乎不影響
        let m2 = BluetoothDriftModel(uid: "bt")
        m2.reset(streamKey: "s", at: at(0))
        for (tm, src) in [(0.0, DriftSource.calibration), (5, .calibration), (10, .verify)] { _ = m2.add(DriftPoint(at: at(tm), latencyMs: truth(tm), source: src)) }
        _ = m2.add(DriftPoint(at: at(12), latencyMs: truth(12) + 3, source: .monitor))
        check(abs(m2.fit()!.rate * 60 - rate) < 0.03, "背景監聽（σ 2 ms）偏 3 ms：速度只變 < 0.03 ms／分鐘", String(format: "%.4f", m2.fit()!.rate * 60))
        // 雜訊下（σ 0.3 ms）：6 點（0,5,13,25,40,55 分）估速度（這裡只測回歸：關掉「停止外推」）
        let m3 = BluetoothDriftModel(uid: "bt", params: { var p = DriftModelParams(); p.holdAtTwoSigmaMs = 0; return p }())
        m3.reset(streamKey: "s", at: at(0))
        var worst = 0.0
        for tm in [0.0, 5, 13, 25, 40, 55] {
            if m3.fit() != nil, let pr = m3.predict(at: at(tm)) { worst = max(worst, abs(pr.ms - truth(tm))) }
            _ = m3.add(DriftPoint(at: at(tm), latencyMs: truth(tm) + noise(0.3), source: .calibration))
        }
        check(worst < 1.5 && abs(m3.fit()!.rate * 60 - rate) < 0.05, "量測雜訊 0.3 ms：每一點的事前預測誤差 < 1.5 ms、速度誤差 < 0.05 ms／分鐘",
              String(format: "最大事前誤差 %.3f ms、速度 %.4f", worst, m3.fit()!.rate * 60))
    }

    print("── 2. 重置、合理範圍、矛盾 ──")
    do {
        let m = BluetoothDriftModel(uid: "bt")
        m.reset(streamKey: "s1", at: at(0))
        _ = m.add(DriftPoint(at: at(0), latencyMs: 436, source: .calibration))
        _ = m.add(DriftPoint(at: at(5), latencyMs: 432, source: .verify))
        m.reset(streamKey: "s2", at: at(6))
        check(m.points.isEmpty && m.health == .ok && m.streamKey == "s2", "串流重開：點全部清掉")
        // 速度超出範圍：5 分鐘內變 20 ms（4 ms／分）→ 第二點就判矛盾（和上一點比，容許 3 ms／分 × 5 + 2.5）
        let r = BluetoothDriftModel(uid: "bt")
        r.reset(streamKey: "s", at: at(0))
        _ = r.add(DriftPoint(at: at(0), latencyMs: 436, source: .calibration))
        let a1 = r.add(DriftPoint(at: at(5), latencyMs: 416, source: .verify))
        check({ if case .contradiction = a1 { return true } else { return false } }() && !r.health.extrapolates,
              "5 分鐘變 20 ms（驗證點）：矛盾 → 不外推", "\(a1)")
        let pr = r.predict(at: at(20))!
        check(pr.rateMsPerMin == nil && pr.ms == 416, "不外推：修正停在最新一個量測點（416）", String(format: "%.1f", pr.ms))
        let a2 = r.add(DriftPoint(at: at(21), latencyMs: 405, source: .calibration))
        check({ if case .restarted = a2 { return true } else { return false } }() && r.points.count == 1 && r.health == .ok,
              "之後來一個校正點：以它重新開始", "\(a2)")
        // 不規則之後，校正點差很大 → 重新開始：失準次數要歸零，之後的背景監聽點不可以再判不規則（09-30 04:38 實機）
        let eR = BluetoothDriftModel(uid: "bt")
        eR.reset(streamKey: "s", at: at(0))
        for tm in [0.0, 5, 12] { _ = eR.add(DriftPoint(at: at(tm), latencyMs: truth(tm), source: .calibration)) }
        _ = eR.add(DriftPoint(at: at(17), latencyMs: truth(17) + 6, source: .verify))
        _ = eR.add(DriftPoint(at: at(22), latencyMs: truth(17) - 2, source: .verify))
        check(eR.health.isErratic, "（前置）連續 2 次失準 → 不規則")
        let eR1 = eR.add(DriftPoint(at: at(40), latencyMs: truth(17) - 98, source: .calibration))
        check({ if case .restarted = eR1 { return true } else { return false } }() && eR.consecutiveMisses == 0 && eR.health == .ok,
              "不規則後校正點差 −98 ms：重新開始、失準次數歸零", "\(eR1)、失準 \(eR.consecutiveMisses)")
        let eR2 = eR.add(DriftPoint(at: at(42.5), latencyMs: truth(17) - 98 - 2.9, source: .monitor))
        check(!eR.health.isErratic && eR2 != .erratic(""), "重新開始後的背景監聽點：不再判不規則", "\(eR2)")
        // 矛盾之後：背景監聽連續 2 次一致的點 → 以它重新開始，修正跟上（09-30 12:27 喇叭自己跳 +12 ms 實機）
        let mc2 = BluetoothDriftModel(uid: "bt")
        mc2.reset(streamKey: "s", at: at(0))
        for tm in [0.0, 5, 12] { _ = mc2.add(DriftPoint(at: at(tm), latencyMs: truth(tm), source: .calibration)) }
        _ = mc2.add(DriftPoint(at: at(18), latencyMs: truth(18) + 12, source: .monitor))
        let held = mc2.predict(at: at(18))!.ms
        check(!mc2.health.extrapolates && abs(held - truth(12)) < 1e-9, "（前置）有速度後單輪背景監聽 +12 ms → 矛盾、修正停在最後校正值", "\(mc2.health)")
        let r2 = mc2.add(DriftPoint(at: at(19), latencyMs: truth(19) + 10, source: .monitorConfirmed))
        check({ if case .restarted = r2 { return true } else { return false } }() && mc2.health == .ok && abs(mc2.predict(at: at(19))!.ms - (truth(19) + 10)) < 1e-9,
              "背景監聽確認點（+10 ms）：以它重新開始、修正跟上", "\(r2)")
        _ = mc2.add(DriftPoint(at: at(20), latencyMs: truth(20) + 7, source: .monitor))
        check(abs(mc2.predict(at: at(20))!.ms - (truth(19) + 10)) < 1e-9, "之後單輪背景監聽：錨點仍是確認點（單輪不能單獨決定修正）")
        // 沒有矛盾時：確認點也是精確點 → 錨點移過去
        let mc4 = BluetoothDriftModel(uid: "bt")
        mc4.reset(streamKey: "s", at: at(0))
        _ = mc4.add(DriftPoint(at: at(0), latencyMs: 403.9, source: .calibration))
        _ = mc4.add(DriftPoint(at: at(6), latencyMs: 409.0, source: .monitorConfirmed))
        check(abs(mc4.predict(at: at(6))!.ms - 409.0) < 1e-9, "健康時的確認點：修正直接跟到它", String(format: "%.2f", mc4.predict(at: at(6))!.ms))
        // 驗證點不能讓矛盾重新開始（只是抽查）
        let mc3 = BluetoothDriftModel(uid: "bt")
        mc3.reset(streamKey: "s", at: at(0))
        _ = mc3.add(DriftPoint(at: at(0), latencyMs: 436, source: .calibration))
        _ = mc3.add(DriftPoint(at: at(5), latencyMs: 416, source: .verify))
        check({ if case .contradiction = mc3.add(DriftPoint(at: at(7), latencyMs: 415, source: .verify)) { return true } else { return false } }(),
              "矛盾後再來驗證點：還是矛盾（只有校正／背景監聽確認能重新開始）")
        // 雜訊內的漂移（每 5 分鐘 −2.9 ms = −0.58 ms／分）不是矛盾
        let q = BluetoothDriftModel(uid: "bt")
        q.reset(streamKey: "s", at: at(0))
        _ = q.add(DriftPoint(at: at(0), latencyMs: 436, source: .calibration))
        check(q.add(DriftPoint(at: at(5), latencyMs: 433.1, source: .calibration)) == .accepted, "正常漂移不是矛盾")
        // 有速度之後：新點偏離預測 6 ms → 矛盾（驗證點）
        let c = BluetoothDriftModel(uid: "bt")
        c.reset(streamKey: "s", at: at(0))
        for tm in [0.0, 5, 12] { _ = c.add(DriftPoint(at: at(tm), latencyMs: truth(tm), source: .calibration)) }
        let a3 = c.add(DriftPoint(at: at(17), latencyMs: truth(17) + 6, source: .verify))
        check({ if case .missed = a3 { return true } else { return false } }() && c.health == .ok && c.points.count == 2 && c.consecutiveMisses == 1,
              "有速度後驗證點偏離預測 6 ms（> 3 ms）：記一次預測失準、舊的點丟掉（只留上一個錨點＋這一點）", "\(a3)、\(c.points.count) 點")
        check(abs(c.predict(at: at(17))!.ms - (truth(17) + 6)) < 1e-9, "失準後修正立刻以最新實測為準（不是回歸直線）")
        let a3b = c.add(DriftPoint(at: at(22), latencyMs: truth(17) + 6 - 8, source: .verify))
        check({ if case .erratic = a3b { return true } else { return false } }() && !c.health.extrapolates,
              "再一次失準（連續 2 次）：漂移不規則 → 不外推、需要重新校正", "\(a3b)")
        check(abs(c.predict(at: at(30))!.ms - (truth(17) - 2)) < 1e-9 && c.predict(at: at(30))!.rateMsPerMin == nil,
              "不規則：修正停在最新實測值（不外推）")
        let a3c = c.add(DriftPoint(at: at(27), latencyMs: truth(17) - 2 + 1, source: .calibration))
        check(a3c == .accepted && c.health == .ok && c.consecutiveMisses == 0, "之後一點沒有失準（差 1 ms）：恢復正常", "\(a3c)")
        let c2 = BluetoothDriftModel(uid: "bt")
        c2.reset(streamKey: "s", at: at(0))
        for tm in [0.0, 5, 12] { _ = c2.add(DriftPoint(at: at(tm), latencyMs: truth(tm), source: .calibration)) }
        check(c2.add(DriftPoint(at: at(17), latencyMs: truth(17) + 1.0, source: .verify)) == .accepted, "偏 1 ms：在容許範圍內（接受）")
        let a4 = c2.add(DriftPoint(at: at(20), latencyMs: truth(20) + 8, source: .calibration))
        check({ if case .missed = a4 { return true } else { return false } }() && c2.points.count == 2 && c2.predict(at: at(20))!.ms == truth(20) + 8,
              "校正點偏離預測 8 ms：預測失準、以它為錨點（只留上一個錨點起的點）", "\(a4)")
        // 背景監聽點不能單獨決定修正：校正後 90 秒來一個偏 +6 ms 的背景監聽點 → 修正仍以校正點為準、也不會因兩點撐出 4 ms／分的速度
        let mo = BluetoothDriftModel(uid: "bt")
        mo.reset(streamKey: "s", at: at(0))
        _ = mo.add(DriftPoint(at: at(0), latencyMs: 436, source: .calibration))
        let ao = mo.add(DriftPoint(at: at(1.5), latencyMs: 442, source: .monitor))
        check(ao == .accepted && mo.predict(at: at(2))!.ms == 436, "背景監聽（σ 2 ms）偏 +6 ms：修正仍以校正點為準", "\(ao)")
        _ = mo.add(DriftPoint(at: at(3), latencyMs: 442.5, source: .monitor))
        check(mo.fit() == nil && mo.health == .ok && mo.predict(at: at(3.5))!.ms == 436, "只有背景監聽點撐出的跨度：不估速度（不會判速度超出範圍）")
        // 速度剛好在範圍邊緣之外（兩點 10 分鐘 −35 ms = −3.5 ms／分；和上一點比容許 3×10+2.5 = 32.5 → 矛盾）
        let e = BluetoothDriftModel(uid: "bt")
        e.reset(streamKey: "s", at: at(0))
        _ = e.add(DriftPoint(at: at(0), latencyMs: 436, source: .calibration))
        let a5 = e.add(DriftPoint(at: at(10), latencyMs: 401, source: .verify))
        check(!e.health.extrapolates, "10 分鐘 −35 ms（−3.5 ms／分）：超出合理範圍 → 不外推", "\(a5)")
        // 多點回歸後速度超出範圍（點都在各自容許內，但整體斜率 > 3）→ rateOutOfRange
        let g = BluetoothDriftModel(uid: "bt", params: { var p = DriftModelParams(); p.maxRateMsPerMin = 1.0; return p }())
        g.reset(streamKey: "s", at: at(0))
        _ = g.add(DriftPoint(at: at(0), latencyMs: 436, source: .calibration))
        _ = g.add(DriftPoint(at: at(3), latencyMs: 436 - 3.6, source: .calibration))
        check({ if case .rateOutOfRange = g.health { return true } else { return false } }(), "回歸速度 −1.2 ms／分 > 上限 1.0（參數）→ rateOutOfRange", "\(g.health)")
    }

    do {
        // 停止外推：兩點（0、5 分，−0.78 ms／分）之後一直沒有量測 → 2σ > 4 ms 那一刻之後預測不再變
        let h = BluetoothDriftModel(uid: "bt")
        h.reset(streamKey: "s", at: at(0))
        _ = h.add(DriftPoint(at: at(0), latencyMs: truth(0), source: .calibration))
        _ = h.add(DriftPoint(at: at(5), latencyMs: truth(5), source: .calibration))
        let p8 = h.predict(at: at(8))!, p20 = h.predict(at: at(20))!, p40 = h.predict(at: at(40))!
        check(!p8.held && p20.held && p40.held && abs(p20.ms - p40.ms) < 1e-9 && p20.ms > truth(20),
              "一直等不到量測：2σ > 4 ms 之後停止外推（修正停住，不沿舊速度一直走）",
              String(format: "8 分 %.2f、20 分 %.2f（停）、40 分 %.2f（停）", p8.ms, p20.ms, p40.ms))
    }

    // 第 4 段測「空檔優先／倒數」狀態機本身：用舊規則（第 2 點 5 分鐘、不做校正後追蹤量測）；追蹤量測另見 4c
    let legacyGapParams: ShortCalParams = { var p = ShortCalParams(); p.secondPointAfter = 300; p.settleFollowUps = 0; return p }()
    print("── 3. 預估誤差與短校正排程（第 2 點 3 分鐘、2σ > 2 ms 或 30 分鐘擇早） ──")
    do {
        let s = ShortCalScheduler()
        let m = BluetoothDriftModel(uid: "bt")
        m.reset(streamKey: "s", at: at(0))
        check(s.dueAt(m) == nil, "沒有量測點：不排（交給自動校正）")
        _ = m.add(DriftPoint(at: at(0), latencyMs: truth(0), source: .calibration))
        let d1 = s.dueAt(m)!
        check(d1.at == at(3), "第 1 點後 3 分鐘做第 2 點", d1.reason)
        _ = m.add(DriftPoint(at: at(5), latencyMs: truth(5), source: .calibration))
        let d2 = s.dueAt(m)!
        let mins2 = d2.at.timeIntervalSince(at(5)) / 60
        check(mins2 > 3 && mins2 < 30 && d2.reason.contains("2σ"), "兩點（5 分鐘）後：預估誤差 2σ 超過 2 ms 的時間點", String(format: "第 2 點後 %.1f 分鐘", mins2))
        _ = m.add(DriftPoint(at: d2.at, latencyMs: truth(d2.at.timeIntervalSince(t0) / 60), source: .calibration))
        let d3 = s.dueAt(m)!
        let gap3 = d3.at.timeIntervalSince(m.points.last!.at) / 60
        check(gap3 >= mins2 - 0.2 && gap3 < 7, "下次間隔主要由「速度會變」決定：點再多也約 5 分鐘一次（不會拉長到 30 分鐘）", String(format: "%.1f → %.1f 分鐘", mins2, gap3))
        // 很多點之後：受 30 分鐘上限
        let m4 = BluetoothDriftModel(uid: "bt")
        m4.reset(streamKey: "s", at: at(0))
        for tm in stride(from: 0.0, through: 60, by: 5) { _ = m4.add(DriftPoint(at: at(tm), latencyMs: truth(tm), source: .calibration)) }
        let d4 = s.dueAt(m4)!
        check(abs(d4.at.timeIntervalSince(at(60)) - 1800) < 1 || d4.at.timeIntervalSince(at(60)) < 1800,
              "13 點、跨度 60 分鐘：下次 ≤ 30 分鐘", String(format: "%.1f 分鐘（%@）", d4.at.timeIntervalSince(at(60)) / 60, d4.reason))
        let m5 = BluetoothDriftModel(uid: "bt", params: { var p = DriftModelParams(); p.rateWanderMsPerMin2 = 0; return p }())
        m5.reset(streamKey: "s", at: at(0))
        for tm in stride(from: 0.0, through: 120, by: 2) { _ = m5.add(DriftPoint(at: at(tm), latencyMs: truth(tm), source: .calibration)) }
        let d5 = s.dueAt(m5)!
        check(abs(d5.at.timeIntervalSince(at(120)) - 1800) < 1 && d5.reason.contains("30"), "預估誤差一直很小：30 分鐘上限", d5.reason)
        // 矛盾 → 立刻到期
        let mc = BluetoothDriftModel(uid: "bt")
        mc.reset(streamKey: "s", at: at(0))
        _ = mc.add(DriftPoint(at: at(0), latencyMs: 436, source: .calibration))
        _ = mc.add(DriftPoint(at: at(5), latencyMs: 400, source: .verify))
        check(s.dueAt(mc)?.at == at(5), "模型矛盾：立刻到期", s.dueAt(mc)?.reason ?? "")
    }

    print("── 4. 短校正排程狀態機：空檔優先、30 分鐘上限走倒數、needsConsent 不重複倒數、失敗重試與標記 ──")
    do {
        let m = BluetoothDriftModel(uid: "bt")
        m.reset(streamKey: "s", at: at(0))
        _ = m.add(DriftPoint(at: at(0), latencyMs: truth(0), source: .calibration))
        let models = ["bt": m]
        let tgt = ShortCalTarget(uid: "bt", name: "GLASS5+", active: true)
        var env = ShortCalEnvironment(); env.targets = [tgt]
        func starts(_ a: [ShortCalAction]) -> [(Bool)] { a.compactMap { if case .start(_, _, let g, _) = $0 { return g } else { return nil } } }
        let s = ShortCalScheduler(params: legacyGapParams)
        check(s.tick(now: at(4), env: env, models: models).isEmpty, "還沒到 5 分鐘：不動")
        env.programSilentSeconds = 0
        check(s.tick(now: at(6), env: env, models: models).isEmpty && s.dueSince["bt"] == at(5), "到期但正在播音樂：等空檔（不中斷）")
        env.programSilentSeconds = 6
        var a = s.tick(now: at(9), env: env, models: models)
        check(starts(a) == [true], "節目音靜止 6 秒：空檔直接跑（不倒數）", "\(a)")
        check(s.tick(now: at(9.5), env: env, models: models).isEmpty, "剛試過：5 分鐘內不重跑")
        _ = s.attemptFinished(uid: "bt", name: "GLASS5+", measured: true, now: at(9.2))
        _ = m.add(DriftPoint(at: at(9.2), latencyMs: truth(9.2), source: .calibration))
        // 連續播放 30 分鐘沒有空檔 → 倒數
        let s2 = ShortCalScheduler(params: legacyGapParams)
        env.programSilentSeconds = 0
        let m2 = BluetoothDriftModel(uid: "bt")
        m2.reset(streamKey: "s", at: at(0))
        _ = m2.add(DriftPoint(at: at(0), latencyMs: truth(0), source: .calibration))
        var countdownAt: Double?
        for tm in stride(from: 5.0, through: 40, by: 0.5) {
            if starts(s2.tick(now: at(tm), env: env, models: ["bt": m2])) == [false] { countdownAt = tm; break }
        }
        check(countdownAt == 35, "到期（5 分）後連續播放 30 分鐘都沒空檔 → 35 分走倒數 3 秒", "\(countdownAt ?? -1)")
        // 倒數被延後（needsConsent）：AutoCalibrator 已有延後項目 → 不重複倒數，但空檔照樣跑
        env.countdownBlocked = ["bt"]
        check(s2.tick(now: at(41), env: env, models: ["bt": m2]).isEmpty, "needsConsent 延後中：不重複倒數")
        env.programSilentSeconds = 8
        a = s2.tick(now: at(41.5), env: env, models: ["bt": m2])
        check(starts(a) == [true], "延後中遇到空檔：直接跑", "\(a)")
        // 靜止太久（> 10 分鐘，不聽了）：不跑；音樂剛恢復：不會因為「到期很久」就立刻倒數（連續播放要重新累計 30 分鐘）
        let sL = ShortCalScheduler(params: legacyGapParams)
        var envL = env; envL.countdownBlocked = []; envL.programSilentSeconds = 11 * 60
        check(sL.tick(now: at(50), env: envL, models: ["bt": m2]).isEmpty, "靜止 11 分鐘（不聽了、半夜）：不在安靜的房間放測試音")
        envL.programSilentSeconds = 0; envL.secondsSinceLastGap = 60
        check(sL.tick(now: at(51), env: envL, models: ["bt": m2]).isEmpty, "音樂剛恢復 1 分鐘：不因為早就到期而立刻倒數")
        envL.secondsSinceLastGap = 30 * 60
        check(starts(sL.tick(now: at(80), env: envL, models: ["bt": m2])) == [false], "恢復後連續播放 30 分鐘沒空檔 → 倒數")
        // 忙碌（校正中／背景監聽）→ 不動
        let s3 = ShortCalScheduler(params: legacyGapParams)
        env.canStart = false
        check(s3.tick(now: at(6), env: env, models: ["bt": m2]).isEmpty, "有校正／監聽在跑：不動")
        env.canStart = true
        // 失敗：5 分鐘後再試；連續 3 次 → 標記
        let s4 = ShortCalScheduler(params: legacyGapParams)
        env.countdownBlocked = []
        var flags = 0, tries = 0
        var tm = 5.0
        while tm < 40 {
            let acts = s4.tick(now: at(tm), env: env, models: ["bt": m2])
            if !starts(acts).isEmpty {
                tries += 1
                for x in s4.attemptFinished(uid: "bt", name: "GLASS5+", measured: false, now: at(tm + 0.2)) { if case .flag = x { flags += 1 } }
            }
            tm += 0.25
        }
        check(tries == 3 && flags == 1 && s4.stopped("bt"), "沒量到：每 5 分鐘再試；連續 3 次 → 標記一次、停止自動短校正（不會每 5 分鐘一直放測試音）", "試 \(tries) 次、標記 \(flags) 次")
        // 倒數拖很久才真的跑、然後失敗：要從結束算 5 分鐘，不可以馬上再放一次（09-29 23:22 實機）
        let sRetry = ShortCalScheduler(params: legacyGapParams)
        check(starts(sRetry.tick(now: at(6), env: env, models: ["bt": m2])).count == 1, "到期 → 開始")
        _ = sRetry.attemptFinished(uid: "bt", name: "GLASS5+", measured: false, now: at(32))
        check(starts(sRetry.tick(now: at(32.1), env: env, models: ["bt": m2])).isEmpty && starts(sRetry.tick(now: at(36.9), env: env, models: ["bt": m2])).isEmpty,
              "倒數拖 26 分鐘才跑完失敗：5 分鐘內不再試（從結束算）")
        check(starts(sRetry.tick(now: at(37.1), env: env, models: ["bt": m2])).count == 1, "結束 5 分鐘後再試")
        _ = s4.attemptFinished(uid: "bt", name: "GLASS5+", measured: true, now: at(41))
        check(!s4.stopped("bt") && starts(s4.tick(now: at(47), env: env, models: ["bt": m2])) == [true], "使用者按「需要校正」量到之後：恢復自動短校正")
        // 系統靜音／音量很小：不跑（空檔、倒數都不跑）
        let s6 = ShortCalScheduler(params: legacyGapParams)
        var envM = env; envM.volumeGain = 0; envM.programSilentSeconds = 8
        check(s6.tick(now: at(10), env: envM, models: ["bt": m2]).isEmpty, "系統靜音（Kang 暫停音樂、靜音去接電話）：空檔也不放測試音")
        envM.volumeGain = 0.2; envM.playedBeforeSilence = 5
        check(s6.tick(now: at(10), env: envM, models: ["bt": m2]).isEmpty, "靜止之前只播了 5 秒（剛開、長段靜音開頭）：不算聽音樂中間的空檔")
        envM.playedBeforeSilence = 180
        check(starts(s6.tick(now: at(10), env: envM, models: ["bt": m2])) == [true], "播了 3 分鐘後靜止 8 秒、音量正常：空檔短校正")
        // 功能關閉 / 不出聲 → 不排
        let s5 = ShortCalScheduler(params: legacyGapParams)
        env.enabled = false
        check(s5.tick(now: at(10), env: env, models: ["bt": m2]).isEmpty, "漂移補償關閉：不排")
        env.enabled = true
        env.targets = [ShortCalTarget(uid: "bt", name: "GLASS5+", active: false)]
        check(s5.tick(now: at(10), env: env, models: ["bt": m2]).isEmpty, "藍牙不出聲（影片／遊戲模式、暫停出聲）：不排")
    }

    print("── 4c. 校正後追蹤量測（2026-10-04）：精確點 ≤ 2 個時到期就直接跑（不等空檔、不倒數），之後恢復空檔優先 ──")
    do {
        let m = BluetoothDriftModel(uid: "bt")
        m.reset(streamKey: "s", at: at(0))
        _ = m.add(DriftPoint(at: at(0), latencyMs: truth(0), source: .calibration))
        var env = ShortCalEnvironment(); env.targets = [ShortCalTarget(uid: "bt", name: "GLASS5+", active: true)]
        env.programSilentSeconds = 0; env.secondsSinceLastGap = 0       // 音樂一直在播、沒有空檔
        func gaps(_ a: [ShortCalAction]) -> [Bool] { a.compactMap { if case .start(_, _, let g, _) = $0 { return g } else { return nil } } }
        let s = ShortCalScheduler()
        check(s.tick(now: at(2.5), env: env, models: ["bt": m]).isEmpty, "校正後 2.5 分鐘：還沒到期")
        let a1 = s.tick(now: at(3), env: env, models: ["bt": m])
        check(gaps(a1) == [true] && "\(a1)".contains("追蹤量測"), "校正後 3 分鐘、音樂播放中：直接追蹤量測（不等空檔、不倒數）", "\(a1)")
        _ = s.attemptFinished(uid: "bt", name: "GLASS5+", measured: true, now: at(3.2))
        _ = m.add(DriftPoint(at: at(3.2), latencyMs: truth(3.2), source: .calibration))
        let d2 = s.dueAt(m)!
        let a2 = s.tick(now: d2.at, env: env, models: ["bt": m])
        check(gaps(a2) == [true], "第 2 個追蹤量測（2σ 到期）也直接跑", String(format: "%.1f 分 %@", d2.at.timeIntervalSince(t0) / 60, "\(a2)"))
        _ = s.attemptFinished(uid: "bt", name: "GLASS5+", measured: true, now: d2.at)
        _ = m.add(DriftPoint(at: d2.at, latencyMs: truth(d2.at.timeIntervalSince(t0) / 60), source: .calibration))
        let d3 = s.dueAt(m)!
        check(s.tick(now: d3.at.addingTimeInterval(60), env: env, models: ["bt": m]).isEmpty, "已有 3 個精確點：恢復空檔優先（音樂播放中不跑）")
        // 模型一直「以新校正點重新開始」（MK-99 每 3 分鐘跳 ±25 ms，點數一直是 1）：同一串流也只追蹤 2 次
        let mj = BluetoothDriftModel(uid: "bt"); mj.reset(streamKey: "s", at: at(0))
        _ = mj.add(DriftPoint(at: at(0), latencyMs: 373, source: .calibration))
        let sj = ShortCalScheduler()
        var runs = 0
        var tm = 0.0
        for jump in [397.0, 379, 354, 337, 360] {
            tm += 3.2
            if !gaps(sj.tick(now: at(tm), env: env, models: ["bt": mj])).isEmpty {
                runs += 1
                _ = sj.attemptFinished(uid: "bt", name: "MK-99", measured: true, now: at(tm + 0.2))
                _ = mj.add(DriftPoint(at: at(tm + 0.2), latencyMs: jump, source: .calibration))
            }
        }
        check(runs == 2, "延遲一直跳、模型一直重新開始：同一串流也只追蹤 2 次（不會每 3 分鐘中斷音樂）", "追蹤 \(runs) 次、點數 \(mj.points.count)")
        // 串流重開 → 重新追蹤
        mj.reset(streamKey: "s2", at: at(30))
        _ = mj.add(DriftPoint(at: at(30), latencyMs: 380, source: .calibration))
        check(gaps(sj.tick(now: at(33.5), env: env, models: ["bt": mj])) == [true], "串流重開：重新追蹤")
        // 系統靜音：追蹤量測也不放測試音
        let mq = BluetoothDriftModel(uid: "bt"); mq.reset(streamKey: "s", at: at(0))
        _ = mq.add(DriftPoint(at: at(0), latencyMs: truth(0), source: .calibration))
        var envQ = env; envQ.volumeGain = 0
        check(ShortCalScheduler().tick(now: at(4), env: envQ, models: ["bt": mq]).isEmpty, "系統靜音：追蹤量測也不跑")
        var envB = env; envB.canStart = false
        check(ShortCalScheduler().tick(now: at(4), env: envB, models: ["bt": mq]).isEmpty, "正在校正／背景監聽：追蹤量測等一下")
    }

    print("── 4d. 還沒量過的串流（app 重開後沿用上次延遲出聲）：有人在聽才短校正 ──")
    do {
        var env = ShortCalEnvironment(); env.targets = [ShortCalTarget(uid: "bt", name: "GLASS5+", active: true)]
        func gaps(_ a: [ShortCalAction]) -> [Bool] { a.compactMap { if case .start(_, _, let g, _) = $0 { return g } else { return nil } } }
        let s = ShortCalScheduler()
        env.programSilentSeconds = 30; env.playedBeforeSilence = 0; env.programPlayingSeconds = 0
        check(s.tick(now: at(1), env: env, models: [:]).isEmpty, "登入後沒在播音樂：不放測試音")
        env.programSilentSeconds = 0; env.programPlayingSeconds = 3
        check(s.tick(now: at(2), env: env, models: [:]).isEmpty, "音樂才播 3 秒：再等等")
        env.programPlayingSeconds = 6
        let a = s.tick(now: at(3), env: env, models: [:])
        check(gaps(a) == [true], "音樂連續播 6 秒（有人在聽）：直接短校正（不倒數）", "\(a)")
        check(s.tick(now: at(4), env: env, models: [:]).isEmpty, "剛試過：5 分鐘內不重跑")
        var envQ = env; envQ.volumeGain = 0
        check(ShortCalScheduler().tick(now: at(3), env: envQ, models: [:]).isEmpty, "系統靜音：不跑")
        var envOff = env; envOff.targets = [ShortCalTarget(uid: "bt", name: "GLASS5+", active: false)]
        check(ShortCalScheduler().tick(now: at(3), env: envOff, models: [:]).isEmpty, "沒在出聲（暫停／關掉）：不跑")
    }

    print("── 5. 模擬：−0.78 ms／分鐘 60 分鐘，排程＋預測補償下的殘差 ──")
    do {
        // 藍牙每次短校正量到 真值 + N(0, 0.3)；補償 = 模型預測。第 2 點（5 分）之後每秒的殘差 |真值 − 預測| 都要 < 3 ms
        let m = BluetoothDriftModel(uid: "bt")
        m.reset(streamKey: "s", at: at(0))
        _ = m.add(DriftPoint(at: at(0), latencyMs: truth(0) + noise(0.3), source: .calibration))
        let s = ShortCalScheduler()
        var env = ShortCalEnvironment(); env.targets = [ShortCalTarget(uid: "bt", name: "GLASS5+", active: true)]
        env.programSilentSeconds = 10   // 一直有空檔
        var worstAfter2 = 0.0, cals = 0
        var tsec = 0.0
        var lastPred = truth(0)
        while tsec <= 3600 {
            let now = t0.addingTimeInterval(tsec)
            for a in s.tick(now: now, env: env, models: ["bt": m]) {
                if case .start = a {
                    cals += 1
                    _ = m.add(DriftPoint(at: now, latencyMs: truth(tsec / 60) + noise(0.3), source: .calibration))
                    _ = s.attemptFinished(uid: "bt", name: "GLASS5+", measured: true, now: now)
                }
            }
            if let p = m.predict(at: now) { lastPred = p.ms }
            if m.points.count >= 2 { worstAfter2 = max(worstAfter2, abs(truth(tsec / 60) - lastPred)) }
            tsec += 1
        }
        check(worstAfter2 < 3 && cals <= 14, "60 分鐘：第 2 點之後殘差最大 < 3 ms、短校正 ≤ 14 次（速度會變的預估誤差 → 約每 5 分鐘一次）",
              String(format: "最大 %.2f ms、短校正 %d 次", worstAfter2, cals))
        print(String(format: "  · 對照：沒有補償時 60 分鐘累積 %.1f ms", abs(rate * 60)))
    }

    print("── 5b. 實機資料重播（2026-09-29 D2：GLASS5+ 19:41–20:22，同一個串流） ──")
    do {
        // 餵進模型的點（分鐘、ms、來源）：短校正、4 次只量藍牙的驗證（每 5 分鐘）、2 次背景監聽；之後 20 分鐘沒有量測（音樂一直在播、沒有空檔）
        let fed: [(Double, Double, DriftSource)] = [(0, 421.421, .calibration), (5.18, 417.685, .verify), (10.18, 414.146, .verify), (15.18, 412.579, .verify),
                                                   (20.18, 410.793, .verify), (20.68, 410.784, .monitor), (21.37, 410.525, .monitor)]
        // 沒餵的實測（驗收用）：35、40 分只量藍牙的驗證（各 2 個一致脈衝）、41 分完整 --verify-program（3 個一致脈衝）→ 速度反轉、延遲回到 418–421
        let later: [(Double, Double)] = [(35.18, 419.406), (40.18, 420.901), (41.2, 417.8125)]
        func replay(_ p: DriftModelParams) -> (early: [Double], late: [Double]) {
            let m = BluetoothDriftModel(uid: "bt", params: p)
            m.reset(streamKey: "s", at: at(0))
            var early: [Double] = []
            for (i, f) in fed.enumerated() {
                if i >= 2, let pr = m.predict(at: at(f.0)) { early.append(f.1 - pr.ms) }
                _ = m.add(DriftPoint(at: at(f.0), latencyMs: f.1, source: f.2))
            }
            return (early, later.map { $0.1 - (m.predict(at: at($0.0))?.ms ?? .nan) })
        }
        var lin = DriftModelParams(); lin.recencyTauMinutes = 0; lin.holdAtTwoSigmaMs = 0
        let a = replay(DriftModelParams()), b = replay(lin)
        func fmt(_ v: [Double]) -> String { v.map { String(format: "%+.2f", $0) }.joined(separator: " ") }
        print("  · 事前預測誤差（實測 − 預測，ms）：目前參數 第 3–7 點 \(fmt(a.early))；20 分鐘沒量測後 \(fmt(a.late))")
        print("  · 對照（純線性、不加權、一直外推）：第 3–7 點 \(fmt(b.early))；20 分鐘沒量測後 \(fmt(b.late))")
        check(a.early.allSatisfy { abs($0) < 3 }, "有量測（每 5 分鐘）時：第 2 點之後每一點的事前預測誤差 < 3 ms", fmt(a.early))
        check((a.late.map(abs).max() ?? 99) < (b.late.map(abs).max() ?? 0),
              "量測停了 20 分鐘、速度反轉：停止外推比一直沿舊速度外推的誤差小（但仍 > 3 ms：沒有量測就追不上反轉）",
              String(format: "最大 %.1f vs %.1f ms", a.late.map(abs).max() ?? 0, b.late.map(abs).max() ?? 0))
    }

    print("── 5c. 實機資料重播（2026-09-29 第 C 輪驗收：GLASS5+ 20:58–21:36，同一個串流，量測間隔 10–18 分鐘） ──")
    do {
        // 20:58:02 校正 450.777；之後沒有空檔、第 2 點一直沒量；驗收的 3 次只量藍牙的驗證 21:15:51 454.854、21:26:10 447.231、21:36:27 435.955
        let fed: [(Double, Double, DriftSource)] = [(0, 450.777, .calibration), (17.82, 454.854, .verify), (28.13, 447.231, .verify), (38.41, 435.955, .verify)]
        let m = BluetoothDriftModel(uid: "bt")
        m.reset(streamKey: "s", at: at(0))
        var res: [Double] = []
        var results: [BluetoothDriftModel.AddResult] = []
        for f in fed {
            if let pr = m.predict(at: at(f.0)) { res.append(f.1 - pr.ms) }
            results.append(m.add(DriftPoint(at: at(f.0), latencyMs: f.1, source: f.2)))
        }
        func fmt(_ v: [Double]) -> String { v.map { String(format: "%+.2f", $0) }.joined(separator: " ") }
        print("  · 事前預測誤差（實測 − 加入前的預測，ms）：\(fmt(res))；結果 \(results.map { "\($0)" }.joined(separator: "、"))")
        check({ if case .erratic = results[2] { return true } else { return false } }() && !m.health.extrapolates,
              "18 分鐘後偏 +4.1、再 10 分鐘偏 −9.2（連續 2 次 > 3 ms）：判「漂移不規則」、不外推、標記需要重新校正（舊版一直顯示「模型正常」）")
        check(m.predict(at: at(38.5))!.ms == 435.955, "不外推時修正停在最新實測（435.955），不是回歸直線（舊版停在 437.503）")
        check(res.dropFirst().allSatisfy { abs($0) > 3 },
              "誠實：量測間隔 10–18 分鐘、速度 +0.2 → −1.1 ms／分鐘時，任何外推都超過 3 ms（要靠約 5 分鐘一次的量測）", fmt(res))
    }

    print("── 6a. 子行程輸出解析 ──")
    do {
        let lines = ["[校正] @@latency-obs AA-BB-CC-DD-EE-01:output 436.1480 0.1150 4 calibration", "  @@latency-obs x 1.0 0.1 3 verify",
                     "@@latency-obs bad nan 0 0 verify", "@@short-miss AA-BB-CC-DD-EE-01:output", "@@bt-residual AA-BB-CC-DD-EE-01:output -1.25", "✓ 已寫入"]
        let o = parseLatencyObservations(lines)
        check(o.count == 2 && o[0].uid == "AA-BB-CC-DD-EE-01:output" && abs(o[0].latencyMs - 436.148) < 1e-9 && o[0].source == .calibration && o[1].source == .verify,
              "@@latency-obs：uid（含冒號）、值、來源；nan 丟掉", "\(o)")
        check(parseShortMissUIDs(lines) == ["AA-BB-CC-DD-EE-01:output"], "@@short-miss")
        check(parseBluetoothResiduals(lines).first.map { $0.0 == "AA-BB-CC-DD-EE-01:output" && $0.1 == -1.25 } == true, "@@bt-residual")
    }

    print("── 6. 藍牙連上後預設輸出自動切回（10 秒窗、之後尊重使用者） ──")
    do {
        var p = BluetoothOutputRestorePolicy()
        p.bluetoothOutputsChanged(["glass"], now: at(0))
        check(p.defaultOutputChanged(to: "glass", isBluetooth: true, managed: true, enabled: true, now: at(0.1)) == .respect(uid: "glass", why: "不是剛連上的藍牙"),
              "app 啟動時就連著的藍牙：不算剛連上（尊重）")
        p.bluetoothOutputsChanged([], now: at(1))
        p.bluetoothOutputsChanged(["glass"], now: at(2))
        let d = p.defaultOutputChanged(to: "glass", isBluetooth: true, managed: true, enabled: true, now: at(2).addingTimeInterval(3))
        check(d == .restore(uid: "glass", secondsAfterConnect: 3), "重新連上 3 秒後 macOS 搶預設輸出 → 自動切回", "\(d)")
        check(p.defaultOutputChanged(to: "builtin", isBluetooth: false, managed: true, enabled: true, now: at(2).addingTimeInterval(3.1)) == .none, "切回內建（我們自己）：不動")
        let late = p.defaultOutputChanged(to: "glass", isBluetooth: true, managed: true, enabled: true, now: at(2).addingTimeInterval(15))
        check({ if case .respect = late { return true } else { return false } }(), "連上 15 秒後使用者手動切到藍牙：尊重（照舊警告）", "\(late)")
        // 預設輸出通知比裝置清單先到
        var q = BluetoothOutputRestorePolicy()
        q.bluetoothOutputsChanged(["builtin-only-bt-none"], now: at(0))
        let e = q.defaultOutputChanged(to: "newbt", isBluetooth: true, managed: true, enabled: true, now: at(1))
        check(e == .restore(uid: "newbt", secondsAfterConnect: 0), "預設輸出通知先到（清單還沒有這台）：當作剛連上 → 切回", "\(e)")
        q.bluetoothOutputsChanged(["builtin-only-bt-none", "newbt"], now: at(1).addingTimeInterval(0.5))
        check(q.connectedAt["newbt"] == at(1), "之後清單才看到它：連上時間不變")
        // 關閉
        var r = BluetoothOutputRestorePolicy()
        r.bluetoothOutputsChanged([], now: at(0))
        r.bluetoothOutputsChanged(["glass"], now: at(1))
        let off = r.defaultOutputChanged(to: "glass", isBluetooth: true, managed: true, enabled: false, now: at(1).addingTimeInterval(2))
        check({ if case .respect(_, let w) = off { return w.contains("關閉") } else { return false } }(), "面板關掉自動切回：尊重", "\(off)")
        // 一直搶：最多 3 次
        var s = BluetoothOutputRestorePolicy()
        s.bluetoothOutputsChanged([], now: at(0))
        s.bluetoothOutputsChanged(["glass"], now: at(1))
        var n = 0
        for k in 0..<5 {
            if case .restore = s.defaultOutputChanged(to: "glass", isBluetooth: true, managed: true, enabled: true, now: at(1).addingTimeInterval(Double(k) + 0.5)) { n += 1 }
        }
        check(n == 3, "10 秒內 macOS 一直搶：最多自動切回 3 次（不打架）", "\(n)")
        // 有線（非藍牙）不管
        check(s.defaultOutputChanged(to: "hdmi", isBluetooth: false, managed: true, enabled: true, now: at(1.1)) == .none, "切到 HDMI 等非藍牙：不在這個規則（照舊警告）")
        // 【第 C 輪審查】排除清單裡、早就連著的 AirPods：一小時後被手動選成預設輸出 → 尊重（known 含全部藍牙）
        var x = BluetoothOutputRestorePolicy()
        x.bluetoothOutputsChanged(["glass", "airpods"], now: at(0))
        check({ if case .respect = x.defaultOutputChanged(to: "airpods", isBluetooth: true, managed: false, enabled: true, now: at(60)) { return true } else { return false } }(),
              "排除清單裡、早就連著的藍牙被手動選成預設輸出：尊重（不當成剛連上）")
        // 剛連上、但不是本程式出聲的藍牙（排除／關閉）：也尊重
        x.bluetoothOutputsChanged(["glass", "airpods", "phones"], now: at(61))
        check({ if case .respect(_, let w) = x.defaultOutputChanged(to: "phones", isBluetooth: true, managed: false, enabled: true, now: at(61).addingTimeInterval(1)) { return w.contains("不是本程式") } else { return false } }(),
              "剛連上、但不是本程式出聲的藍牙（排除清單／關閉）：不自動切回")
        // 斷線再連上：重新計時
        s.bluetoothOutputsChanged([], now: at(3))
        s.bluetoothOutputsChanged(["glass"], now: at(4))
        check(s.defaultOutputChanged(to: "glass", isBluetooth: true, managed: true, enabled: true, now: at(4).addingTimeInterval(1)) == .restore(uid: "glass", secondsAfterConnect: 1),
              "斷線再連上：重新計時、次數歸零")
    }

    print(fail == 0 ? "drift-selftest：全部通過 ✓\(pass) ✗0" : "drift-selftest：✓\(pass) ✗\(fail)")
    return fail == 0 ? 0 : 1
}
