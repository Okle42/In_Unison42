// Calibrate.swift — 麥克風延遲校正（calibrate [--verify] [--level] [--mic <uid|名稱>] [--mode m] [--selftest]）
//
// 原理：
//   * 引擎開「節目靜音」監聽模式；校正麥克風（預設 config.calibrationMicUID，否則 C270；可選 Continuity iPhone，
//     直接對裝置開輸入 IOProc，不動系統預設輸入）錄一整段；錄音期間依序對每個輸出播一次對數掃頻（chirp），
//     用 engine.sampleTime 排程。
//   * 每一輪以「參考輸出」（主時鐘輸出；它不出聲／未啟用時改用第一台要量的輸出）夾住要量的輸出：
//       標準麥克風（USB/內建）： [參考, 其他…, 參考]
//       高延遲／會抖的麥克風（Continuity、藍牙輸入）：[參考, A, 參考, B, 參考]（交錯：每次量測都被相鄰兩個參考夾住，
//       麥克風時鐘的緩慢漂移／蜿蜒只在 2 個間隔內線性化）
//     夾住它的兩個參考 chirp 到達間隔 ÷ 排程間隔 = 麥克風時鐘／引擎時鐘比例（吸收漂移），相對延遲
//     = (到達位置 − 前一個參考到達位置)／比例 − (排程時間 − 前一個參考排程時間)。
//     麥克風本身的延遲（Continuity 可能上百 ms）與「錄音起點 ↔ 引擎時間」的對應誤差對所有輸出相同，相減後抵消，只取相對值。
//   * 搜尋窗自適應：先在寬窗（最多 0.9 個間隔）找到第一個參考 chirp，得到「麥克風路徑延遲」，
//     之後所有搜尋窗一起平移（保留 100 ms 餘裕），所以麥克風延遲再大也找得到。
//   * 到達位置：I/Q 兩個模板（sin 與 −cos 相位的同一掃頻）各做互相關（vDSP_conv），
//     取包絡 √(I²+Q²) 的峰值再做拋物線內插（次樣本精度）。用包絡而不是原始相關峰，
//     是為了不讓各喇叭不同的相位響應讓峰值跳一個載波週期。
//     【2026-09-29】取「最早到達」而不是最大值：最大峰之前 15 ms 內、不低於最大峰 3 dB 的最早局部峰（直達聲），
//     因為內建喇叭的反射可能比直達聲強（和脈衝＋GCC-PHAT 量尺差 6–8 ms 的根因）。
//   * 標準：3 輪取中位數；SNR < 6 dB 或三輪離散 > 1 ms 就報錯不寫檔。
//     高延遲麥克風：5 輪，先剔除離中位數 > 0.5 ms 的輪（最多剔 2 輪），剩下的離散 > 1 ms 或不到 3 輪就報錯不寫檔。
//   * 寫入：measuredLatencyMs = 相對「這次量到的最快裝置」；delayMs（舊欄位）= plan() 依目前模式算的補償，不再寫死。
//   * --verify：只驗證「目前模式下出聲的裝置」（plan().active），補償照 plan 的 delayMs。
//
// 即時執行緒規則：麥克風 IOProc 只碰 MicShared 裡預先配置的原生指標（不配置、不上鎖、不 print、
// 不呼叫 Core Audio 屬性 API）。
import AudioToolbox
import Accelerate
import CoreAudio
import Foundation

// MARK: - 參數

enum CalParams {
    static let chirpSeconds = 0.200
    static let f0 = 200.0
    static let f1 = 8000.0
    static let peakDbFS = -12.0
    static let fadeSeconds = 0.005
    /// 相鄰 chirp 排程間隔（ms）；--verify 另加上最大補償延遲
    static let intervalMs = 1000.0
    static let maxTrimCutDb = 12.0
    static let tailMs = 1000.0
    static let verifyToleranceMs = 1.0
    /// 算相關雜訊底時，排除峰值 ±25 ms
    static let noiseExcludeMs = 25.0
    /// 響度能量窗：到達後 chirp 長度 + 50 ms
    static let levelExtraMs = 50.0
    /// 最早到達：最大峰之前這段時間內、不低於最大峰 firstArrivalDb 的最早局部峰 = 直達聲（見 detectChirp）
    static let firstArrivalLookbackMs = 15.0
    static let firstArrivalDb = 6.0
    static let firstArrivalNoiseDb = 12.0
    /// 比最大峰早這麼多才算另一個到達（主瓣兩側的起伏不算）
    static let firstArrivalMinSepMs = 2.0
    /// 漂移比例合理範圍（超過代表偵測到錯的峰）
    static let maxDriftPpm = 1000.0

    static var peakAmplitude: Double { pow(10, peakDbFS / 20) }
}

/// 依麥克風種類調整的量測參數
struct CalProfile: Equatable {
    let name: String
    /// 輪數
    let rounds: Int
    /// true：[參考, A, 參考, B, 參考]；false：[參考, A, B, 參考]
    let interleave: Bool
    /// 搜尋窗：（平移後的）粗估到達位置 −pre ～ +post
    let windowPreMs: Double
    let windowPostMs: Double
    /// 第一個參考 chirp 的寬搜尋上限（另外不超過 0.9 個間隔）
    let wideSearchMs: Double
    /// 找到第一個參考 chirp 後，搜尋窗平移量 = max(0, 麥克風路徑延遲 − 這個餘裕)
    let shiftMarginMs: Double
    /// 單台各輪（剔除後）延遲離散上限
    let maxSpreadMs: Double
    /// 離中位數超過這個值的輪剔除；nil = 不剔除
    let outlierMs: Double?
    /// 至少要有幾輪一致
    let minKeep: Int
    let minSnrDb: Double
    /// 錄音開頭到第一個 chirp 的安靜段（也用來估雜訊）
    let preRollMs: Double

    /// USB／內建麥克風（C270 等）：延遲小、時鐘穩
    static let standard = CalProfile(name: "標準", rounds: 3, interleave: false, windowPreMs: 50, windowPostMs: 850,
                                     wideSearchMs: 900, shiftMarginMs: 100, maxSpreadMs: 1.0, outlierMs: nil, minKeep: 3,
                                     minSnrDb: 6, preRollMs: 1000)
    /// Continuity（iPhone）／藍牙輸入：延遲可能上百 ms、傳送有抖動、時鐘會蜿蜒 → 交錯參考、5 輪、剔除離群
    static let highLatency = CalProfile(name: "高延遲麥克風（交錯參考、5 輪剔除離群）", rounds: 5, interleave: true,
                                        windowPreMs: 60, windowPostMs: 850, wideSearchMs: 900, shiftMarginMs: 100,
                                        maxSpreadMs: 1.0, outlierMs: 0.5, minKeep: 3, minSnrDb: 6, preRollMs: 1500)

    static func forMic(kind: DeviceKind, name: String) -> CalProfile {
        if kind == .continuity || kind == .remote || kind.isBluetooth || name.lowercased().contains("iphone") { return .highLatency }
        return .standard
    }

    /// 每輪 chirp 數（m = 要量的輸出數，不含參考）
    func chirpsPerRound(measured m: Int) -> Int { m == 0 ? 2 : (interleave ? 2 * m + 1 : m + 2) }
}

// MARK: - 掃頻

/// 對數掃頻 200 Hz–8 kHz、5 ms 升餘弦淡入淡出。t 秒（0…T），回傳 (同相, 正交)；超出範圍為 0
@inline(__always)
func calChirpValue(_ t: Double) -> (Double, Double) {
    let T = CalParams.chirpSeconds
    guard t >= 0, t <= T else { return (0, 0) }
    let k = log(CalParams.f1 / CalParams.f0)
    let phi = 2 * Double.pi * CalParams.f0 * T / k * (exp(k * t / T) - 1)
    let fd = CalParams.fadeSeconds
    var w = 1.0
    if t < fd { w = 0.5 - 0.5 * cos(Double.pi * t / fd) } else if t > T - fd { w = 0.5 - 0.5 * cos(Double.pi * (T - t) / fd) }
    return (w * sin(phi), -w * cos(phi))
}

struct ChirpTemplate {
    let rate: Double
    let i: [Float]
    let q: [Float]
    var count: Int { i.count }

    init(rate: Double) {
        self.rate = rate
        let n = Int((CalParams.chirpSeconds * rate).rounded()) + 1
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let (s, c) = calChirpValue(Double(k) / rate)
            a[k] = Float(s)
            b[k] = Float(c)
        }
        i = a
        q = b
    }

    /// 播放用：峰值 −12 dBFS 的同相掃頻
    static func playback(rate: Double) -> [Float] {
        ChirpTemplate(rate: rate).i.map { $0 * Float(CalParams.peakAmplitude) }
    }
}

// MARK: - 偵測（純運算，自測與實機共用）

struct ChirpDetection {
    /// 到達位置（麥克風 frame，次樣本；= 掃頻第 0 個樣本所在位置）
    let pos: Double
    /// 相關包絡峰值 vs 窗內其他位置（排除峰值 ±25 ms）包絡平方平均（dB）。
    /// 注意：純雜訊時這個比值也有 ~10 dB（N 個樣本取最大），所以分析改用「峰值 vs 雜訊段峰值」當 SNR，
    /// 這個值只在沒有雜訊段時當備用。
    let snrDb: Double
    /// 相關包絡峰值
    let peak: Float
}

/// 在 rec[ws ..< ws+W+P-1] 內找 template；W = 窗長（候選起點數）
func detectChirp(_ rec: UnsafeBufferPointer<Float>, windowStart: Int, windowLength: Int, template t: ChirpTemplate) -> ChirpDetection? {
    let P = t.count
    let ws = max(0, windowStart)
    let avail = rec.count - ws - (P - 1)
    let W = min(windowLength - (ws - windowStart), avail)
    guard W > 8, let base = rec.baseAddress else { return nil }
    var cI = [Float](repeating: 0, count: W)
    var cQ = [Float](repeating: 0, count: W)
    var env = [Float](repeating: 0, count: W)
    t.i.withUnsafeBufferPointer { f in vDSP_conv(base + ws, 1, f.baseAddress!, 1, &cI, 1, vDSP_Length(W), vDSP_Length(P)) }
    t.q.withUnsafeBufferPointer { f in vDSP_conv(base + ws, 1, f.baseAddress!, 1, &cQ, 1, vDSP_Length(W), vDSP_Length(P)) }
    vDSP_vdist(cI, 1, cQ, 1, &env, 1, vDSP_Length(W))
    var peak: Float = 0
    var idx: vDSP_Length = 0
    vDSP_maxvi(env, 1, &peak, &idx, vDSP_Length(W))
    var n = Int(idx)
    // 雜訊底：排除最大峰 ±25 ms 後的包絡平方平均
    let ex = Int(CalParams.noiseExcludeMs / 1000 * t.rate)
    let lo = max(0, n - ex), hi = min(W, n + ex + 1)
    var total: Float = 0, mid: Float = 0
    vDSP_svesq(env, 1, &total, vDSP_Length(W))
    env.withUnsafeBufferPointer { p in vDSP_svesq(p.baseAddress! + lo, 1, &mid, vDSP_Length(hi - lo)) }
    let cnt = W - (hi - lo)
    let noise = cnt > 0 ? max(Double(total - mid) / Double(cnt), 1e-30) : 1e-30
    let snr = 10 * log10(Double(peak) * Double(peak) / noise)
    // 最早到達：直達聲不一定最強（內建喇叭在機殼裡、麥克風在螢幕上，實測 +4 ms 的反射只比直達聲弱 0.9 dB（GCC-PHAT），
    // chirp 包絡最大值會抓到反射，讓內建喇叭看起來慢 4–8 ms）。在最大峰之前 firstArrivalLookbackMs 內，
    // 找最早一個局部峰：不低於最大峰 firstArrivalDb、且高於雜訊平均 firstArrivalNoiseDb（純雜訊的包絡最大值約高 10 dB），
    // 至少比最大峰早 firstArrivalMinSepMs（主瓣兩側的起伏不算）。
    let back = Int(CalParams.firstArrivalLookbackMs / 1000 * t.rate)
    let thr = max(Double(peak) * pow(10, -CalParams.firstArrivalDb / 20), (noise * pow(10, CalParams.firstArrivalNoiseDb / 10)).squareRoot())
    let minSep = Int(CalParams.firstArrivalMinSepMs / 1000 * t.rate)
    var j = max(1, n - back)
    while j < n - minSep {
        if Double(env[j]) >= thr && env[j] >= env[j - 1] && env[j] >= env[j + 1] { n = j; break }
        j += 1
    }
    var delta = 0.0
    if n > 0 && n < W - 1 {
        let ym = Double(env[n - 1]), y0 = Double(env[n]), yp = Double(env[n + 1])
        let den = ym - 2 * y0 + yp
        if den < 0 { delta = min(0.5, max(-0.5, 0.5 * (ym - yp) / den)) }
    }
    return ChirpDetection(pos: Double(ws + n) + delta, snrDb: snr, peak: peak)
}

/// rec[from ..< from+len] 的平均功率
func meanPower(_ rec: UnsafeBufferPointer<Float>, from: Int, length: Int) -> Double {
    let a = max(0, from), b = min(rec.count, from + length)
    guard b > a, let base = rec.baseAddress else { return 0 }
    var s: Float = 0
    vDSP_svesq(base + a, 1, &s, vDSP_Length(b - a))
    return Double(s) / Double(b - a)
}

// MARK: - 排程與分析

struct PlannedChirp {
    /// ref = 參考輸出（量漂移、延遲定義為 0）；measure = 要量的輸出
    enum Role { case ref, measure }
    let round: Int
    let output: Int
    /// 名目排程時間（引擎 sampleTime）
    let sched: Int64
    /// 實際起點 = sched + startOffset（--verify 時 = 該輸出的補償延遲 frame）
    let startOffset: Int64
    let role: Role
}

/// 引擎 frame → 麥克風 frame 的粗略對應（只用來定搜尋窗）
struct RoughMap {
    var anchorEngine: Int64
    var anchorMic: Double
    var ratio: Double   // 麥克風名目取樣率／引擎取樣率
    func mic(_ s: Int64) -> Double { anchorMic + Double(s - anchorEngine) * ratio }
}

/// 排程：每輪 [ref, measured…, ref]（interleave：[ref, m1, ref, m2, …, ref]）。offsets 以輸出 index 取
func buildPlan(ref: Int, measured: [Int], base: Int64, intervalFrames: Int64, rounds: Int, offsets: [Int64],
               interleave: Bool) -> [PlannedChirp] {
    var plan: [PlannedChirp] = []
    var k: Int64 = 0
    let others = measured.filter { $0 != ref }
    let seq: [Int]
    if others.isEmpty {
        seq = [ref, ref]
    } else if interleave {
        seq = [ref] + others.flatMap { [$0, ref] }
    } else {
        seq = [ref] + others + [ref]
    }
    for r in 0..<rounds {
        for o in seq {
            plan.append(PlannedChirp(round: r, output: o, sched: base + k * intervalFrames, startOffset: offsets[o],
                                     role: o == ref ? .ref : .measure))
            k += 1
        }
    }
    return plan
}

struct CalOutputResult {
    var latMs: [Double] = []     // 每輪：相對參考輸出的到達延遲（ms）
    var keptLatMs: [Double] = [] // 剔除離群後（沒有剔除時 = latMs）
    var snrDb: [Double] = []     // 每個 chirp 的 SNR
    var levelDb: [Double] = []   // 每輪響度（dB，扣掉雜訊）
    var used: [Double] { keptLatMs.isEmpty ? latMs : keptLatMs }
    var medLatMs: Double { median(used) }
    var medLevelDb: Double { median(levelDb) }
    var minSnrDb: Double { snrDb.min() ?? -.infinity }
    var spreadMs: Double { (used.max() ?? 0) - (used.min() ?? 0) }
    var rejected: Int { latMs.count - used.count }
}

struct CalAnalysis {
    var outputs: [CalOutputResult]
    var driftPpm: [Double]
    var noiseDbFS: Double
    var errors: [String]
    /// 第一個參考 chirp 相對粗估位置的延遲（≈ 麥克風路徑延遲＋參考輸出延遲，ms）
    var micPathMs: Double? = nil
    /// 搜尋窗平移量（ms）
    var searchShiftMs: Double = 0
}

func median(_ a: [Double]) -> Double {
    guard !a.isEmpty else { return .nan }
    let s = a.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
}

/// 分析整段錄音。ref = 參考輸出 index；names 只用於錯誤訊息（以輸出 index 取）
func analyzeCalibration(rec: [Float], micRate: Double, engineRate: Double, plan: [PlannedChirp],
                        map: RoughMap, nOutputs: Int, ref: Int, names: [String], profile: CalProfile = .standard) -> CalAnalysis {
    var res = CalAnalysis(outputs: Array(repeating: CalOutputResult(), count: nOutputs), driftPpm: [], noiseDbFS: -200, errors: [])
    guard !plan.isEmpty else { res.errors.append("沒有排程任何 chirp"); return res }
    let tmpl = ChirpTemplate(rate: micRate)
    let pre = Int(profile.windowPreMs / 1000 * micRate)
    let winLen = Int((profile.windowPreMs + profile.windowPostMs) / 1000 * micRate)
    let levelLen = tmpl.count + Int(CalParams.levelExtraMs / 1000 * micRate)

    return rec.withUnsafeBufferPointer { buf -> CalAnalysis in
        let first = plan[0]
        let firstGuess = map.mic(first.sched + first.startOffset)
        // 雜訊功率：第一個 chirp 粗估位置前 500 ms～pre
        do {
            let m = Int(firstGuess)
            let a = m - Int(0.5 * micRate), b = m - pre
            let np = meanPower(buf, from: a, length: b - a)
            res.noiseDbFS = 10 * log10(max(np, 1e-20))
        }
        let noisePow = pow(10, res.noiseDbFS / 10)

        // 雜訊段相關峰值：第一個搜尋窗之前的安靜段（最長同搜尋窗長度）做同樣的互相關，取包絡最大值。
        // SNR = 20·log10(chirp 相關峰值／雜訊段相關峰值)；純雜訊時約 0 dB，所以 6 dB 門檻有意義。
        // （麥克風延遲只會讓 chirp 更晚到，這段仍然安靜）
        var noisePeak: Float = 0
        do {
            let end = Int(firstGuess.rounded()) - pre   // 第一個窗的起點
            let start = max(0, end - (tmpl.count - 1) - winLen)
            if let d = detectChirp(buf, windowStart: start, windowLength: end - (tmpl.count - 1) - start, template: tmpl) {
                noisePeak = d.peak
            }
        }

        // 自適應搜尋窗：寬窗找第一個參考 chirp → 麥克風路徑延遲 → 所有窗一起平移
        var shift = 0.0
        do {
            let intervalMs = plan.count > 1 ? Double(plan[1].sched - plan[0].sched) / engineRate * 1000 : CalParams.intervalMs
            let wideMs = min(profile.wideSearchMs, 0.9 * intervalMs)
            let wlen = Int((profile.windowPreMs + wideMs) / 1000 * micRate)
            if let d = detectChirp(buf, windowStart: Int(firstGuess.rounded()) - pre, windowLength: wlen, template: tmpl) {
                let delta = d.pos - firstGuess
                res.micPathMs = delta / micRate * 1000
                shift = max(0, delta - profile.shiftMarginMs / 1000 * micRate)
            }
        }
        res.searchShiftMs = shift / micRate * 1000

        var dets: [ChirpDetection?] = []
        for c in plan {
            let guess = Int((map.mic(c.sched + c.startOffset) + shift).rounded())
            if let d = detectChirp(buf, windowStart: guess - pre, windowLength: winLen, template: tmpl) {
                let snr = noisePeak > 0 ? 20 * log10(Double(d.peak) / Double(noisePeak)) : d.snrDb
                dets.append(ChirpDetection(pos: d.pos, snrDb: snr, peak: d.peak))
            } else {
                dets.append(nil)
            }
        }
        if noisePeak <= 0 {
            res.errors.append("錄音開頭沒有足夠的安靜段可估雜訊（或雜訊段全為 0），SNR 無法可靠判斷")
        }
        func level(_ d: ChirpDetection) -> Double {
            let p = meanPower(buf, from: Int(d.pos.rounded()), length: levelLen) - noisePow
            return 10 * log10(max(p, 1e-20))
        }
        func ppmOK(_ ratio: Double) -> (Double, Bool) {
            let ppm = (ratio / map.ratio - 1) * 1e6
            return (ppm, abs(ppm) < CalParams.maxDriftPpm)
        }

        let rounds = Set(plan.map(\.round)).sorted()
        for r in rounds {
            let idx = plan.indices.filter { plan[$0].round == r }
            let refIdx = idx.filter { plan[$0].role == .ref }
            guard refIdx.count >= 2 else { continue }
            if let missing = refIdx.first(where: { dets[$0] == nil }) {
                _ = missing
                res.errors.append("第 \(r + 1) 輪：參考輸出「\(names[ref])」的 chirp 超出錄音範圍，找不到")
                continue
            }
            let ds = dets[refIdx.first!]!, de = dets[refIdx.last!]!
            let (ppm, ok) = ppmOK((de.pos - ds.pos) / Double(plan[refIdx.last!].sched - plan[refIdx.first!].sched))
            res.driftPpm.append(ppm)
            if !ok {
                res.errors.append(String(format: "第 %d 輪：參考輸出頭尾 chirp 算出的時鐘比例偏 %.0f ppm，不合理（多半是峰值抓錯：太吵或音量太小）", r + 1, ppm))
                continue
            }
            // 參考輸出：延遲定義為 0，SNR 取全部參考 chirp，響度取平均
            res.outputs[ref].latMs.append(0)
            res.outputs[ref].snrDb.append(contentsOf: refIdx.map { dets[$0]!.snrDb })
            let lin = refIdx.map { pow(10, level(dets[$0]!) / 10) }.reduce(0, +) / Double(refIdx.count)
            res.outputs[ref].levelDb.append(10 * log10(max(lin, 1e-20)))
            for i in idx where plan[i].role == .measure {
                let c = plan[i]
                guard let d = dets[i] else {
                    res.errors.append("第 \(r + 1) 輪：「\(names[c.output])」的 chirp 超出錄音範圍，找不到")
                    continue
                }
                // 夾住它的兩個參考 chirp（交錯時是相鄰的兩個；否則是頭尾）
                guard let a = refIdx.last(where: { $0 < i }), let b = refIdx.first(where: { $0 > i }) else { continue }
                let da = dets[a]!, db = dets[b]!
                let (lppm, lok) = ppmOK((db.pos - da.pos) / Double(plan[b].sched - plan[a].sched))
                guard lok else {
                    res.errors.append(String(format: "第 %d 輪：「%@」前後參考 chirp 的時鐘比例偏 %.0f ppm，不合理", r + 1, names[c.output], lppm))
                    continue
                }
                let ratio = (db.pos - da.pos) / Double(plan[b].sched - plan[a].sched)
                let latFrames = (d.pos - da.pos) / ratio - Double(c.sched - plan[a].sched)
                res.outputs[c.output].latMs.append(latFrames / engineRate * 1000)
                res.outputs[c.output].snrDb.append(d.snrDb)
                res.outputs[c.output].levelDb.append(level(d))
            }
        }
        let involved = Set(plan.map(\.output)).sorted()
        for o in involved {
            var r = res.outputs[o]
            if o != ref, let out = profile.outlierMs, r.latMs.count >= profile.minKeep {
                let med = median(r.latMs)
                r.keptLatMs = r.latMs.filter { abs($0 - med) <= out }
            } else {
                r.keptLatMs = r.latMs
            }
            res.outputs[o] = r
            if r.latMs.count < rounds.count && r.latMs.count < profile.minKeep {
                res.errors.append("「\(names[o])」只量到 \(r.latMs.count)/\(rounds.count) 輪")
            } else if o != ref, r.used.count < profile.minKeep {
                res.errors.append(String(format: "「%@」%d 輪中只有 %d 輪彼此一致（±%.1f ms）：量測不穩定（麥克風抖動、回音或雜訊），請安靜後再試",
                                         names[o], r.latMs.count, r.used.count, profile.outlierMs ?? 0))
            }
            if r.minSnrDb < profile.minSnrDb {
                res.errors.append(String(format: "「%@」SNR 只有 %.1f dB（< %.0f dB）：這台聲音太小或房間太吵。請把該喇叭音量調大（本程式不會替你調高系統音量）或讓環境安靜後再試", names[o], r.minSnrDb, profile.minSnrDb))
            }
            if o != ref, r.used.count >= 2, r.spreadMs > profile.maxSpreadMs {
                res.errors.append(String(format: "「%@」%d 輪延遲離散 %.2f ms（> %.0f ms）：量測不穩定（回音、干擾或雜訊），請安靜後再試",
                                         names[o], r.used.count, r.spreadMs, profile.maxSpreadMs))
            }
        }
        return res
    }
}

/// 延遲補償：delayMs_i = max(lat) − lat_i（音樂模式、全部出聲時的補償；實際補償一律由 plan() 依模式算）
func compensationDelays(_ lat: [Double]) -> [Double] {
    let mx = lat.max() ?? 0
    return lat.map { mx - $0 }
}

/// 響度匹配：只衰減，對齊最小聲的那台，最多 −12 dB
func levelTrims(_ levels: [Double]) -> [Double] {
    let mn = levels.min() ?? 0
    return levels.map { max(-CalParams.maxTrimCutDb, min(0, mn - $0)) }
}

/// 校正結果寫進設定（純函式）：
///   * measuredLatencyMs = measuredRel（相對這次量到的最快裝置，已由呼叫端扣好），取到 0.001 ms
///   * trimDb（--level 時）取到 0.1 dB
///   * delayMs（舊欄位）= plan(devices, mode) 的補償（不出聲 = 0），取到 0.01 ms
/// devices：這次參與 plan 的裝置（通常是聚合裝置全部輸出，含這次沒量的）。回傳新設定與該模式的計畫。
func applyCalibrationResult(to cfg: Config, measuredRel: [String: Double], trims: [String: Double]?, mode: PlayMode,
                            devices: [(uid: String, name: String, isBuiltIn: Bool)]) -> (Config, [String: PlanEntry]) {
    var c = cfg
    for (uid, lat) in measuredRel {
        var d = c.device(uid)
        d.measuredLatencyMs = (max(lat, 0) * 1000).rounded() / 1000
        d.needsRecalibration = false   // 重新量過了（藍牙重連後的提示清掉）
        if let t = trims?[uid] { d.trimDb = (t * 10).rounded() / 10 }
        c.devices[uid] = d
    }
    let p = plan(devices: devices.map { PlanDevice(uid: $0.uid, name: $0.name, isBuiltIn: $0.isBuiltIn, config: c) },
                 mode: mode, caps: c.modeCaps)
    for dev in devices {
        var d = c.device(dev.uid)
        let e = p[dev.uid]
        d.delayMs = e.map { $0.active ? (min($0.delayMs, Config.maxDelayMs) * 100).rounded() / 100 : 0 } ?? 0
        c.devices[dev.uid] = d
    }
    return (c, p)
}

// MARK: - 麥克風錄音（直接對裝置開輸入 IOProc）

/// IOProc 唯一會碰的資料：預先配置的原生指標（值型別）
struct MicShared {
    var buf: UnsafeMutablePointer<Float>
    var cap: Int
    var pos: UnsafeMutablePointer<Int>
    var gaps: UnsafeMutablePointer<Int>
    var nextSampleTime: UnsafeMutablePointer<Double>
    var cycles: UnsafeMutablePointer<Int64>
    var peak: UnsafeMutablePointer<Float>

    /// 即時執行緒：不配置、不上鎖、不 print、不呼叫 Core Audio 屬性 API
    func capture(_ inData: UnsafePointer<AudioBufferList>, _ inTime: UnsafePointer<AudioTimeStamp>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard abl.count > 0, let raw = abl[0].mData else { return }
        let ch = max(1, Int(abl[0].mNumberChannels))
        let n = Int(abl[0].mDataByteSize) / 4 / ch
        guard n > 0 else { return }
        cycles.pointee &+= 1
        if inTime.pointee.mFlags.contains(.sampleTimeValid) {
            let st = inTime.pointee.mSampleTime
            let exp = nextSampleTime.pointee
            if exp >= 0 && abs(st - exp) > 0.5 { gaps.pointee &+= 1 }
            nextSampleTime.pointee = st + Double(n)
        }
        let p = pos.pointee
        let m = min(n, cap - p)
        guard m > 0 else { return }
        let src = raw.assumingMemoryBound(to: Float.self)
        var pk = peak.pointee
        for f in 0..<m {
            let v = src[f * ch]
            buf[p + f] = v
            let a = v < 0 ? -v : v
            if a > pk { pk = a }
        }
        peak.pointee = pk
        OSMemoryBarrier()
        pos.pointee = p + m
    }
}

final class MicRecorder {
    let device: AudioDevice
    let rate: Double
    private var sh: MicShared
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private let lock = NSLock()
    /// 最後一道保險：藍牙輸入絕不開（開了會把藍牙喇叭切到 HFP）；start() 直接回 kAudioHardwareIllegalOperationError
    private let refusedBluetooth: Bool

    init(device: AudioDevice, seconds: Double) {
        self.device = device
        refusedBluetooth = device.kind.isBluetooth
        rate = device.nominalSampleRate > 0 ? device.nominalSampleRate : 48000
        let cap = Int(seconds * rate)
        sh = MicShared(buf: RTShared.alloc(cap, Float(0)), cap: cap, pos: RTShared.alloc(1, 0), gaps: RTShared.alloc(1, 0),
                       nextSampleTime: RTShared.alloc(1, -1.0), cycles: RTShared.alloc(1, Int64(0)), peak: RTShared.alloc(1, Float(0)))
    }

    deinit {
        stop()
        sh.buf.deallocate(); sh.pos.deallocate(); sh.gaps.deallocate()
        sh.nextSampleTime.deallocate(); sh.cycles.deallocate(); sh.peak.deallocate()
    }

    var frames: Int { sh.pos.pointee }
    var gaps: Int { sh.gaps.pointee }
    var cycles: Int64 { sh.cycles.pointee }
    var peak: Float { sh.peak.pointee }
    var capacity: Int { sh.cap }

    func start() -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        if running { return noErr }
        if refusedBluetooth { return kAudioHardwareIllegalOperationError }
        let shared = sh
        var proc: AudioDeviceIOProcID?
        let s = AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, nil) { _, inData, inTime, _, _ in
            shared.capture(inData, inTime)
        }
        guard s == noErr, let proc else { return s }
        let ss = AudioDeviceStart(device.id, proc)
        guard ss == noErr else { AudioDeviceDestroyIOProcID(device.id, proc); return ss }
        procID = proc
        running = true
        return noErr
    }

    /// 可重複呼叫（中斷清理也會叫）
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running, let p = procID else { return }
        AudioDeviceStop(device.id, p)
        AudioDeviceDestroyIOProcID(device.id, p)
        procID = nil
        running = false
    }

    /// 已錄的樣本拷一份
    func samples() -> [Float] {
        let n = frames
        OSMemoryBarrier()
        return Array(UnsafeBufferPointer(start: sh.buf, count: n))
    }
}

// MARK: - 顯示

/// 終端機顯示寬度（CJK 全形算 2）
private func displayWidth(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { w, u in
        let v = u.value
        let wide = (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF) || (v >= 0xAC00 && v <= 0xD7A3)
            || (v >= 0xF900 && v <= 0xFAFF) || (v >= 0xFE30 && v <= 0xFE4F) || (v >= 0xFF00 && v <= 0xFF60) || (v >= 0xFFE0 && v <= 0xFFE6)
        return w + (wide ? 2 : 1)
    }
}

private func pad(_ s: String, _ w: Int) -> String {
    let d = displayWidth(s)
    return d >= w ? s : s + String(repeating: " ", count: w - d)
}

private func printTable(_ header: [String], _ rows: [[String]]) {
    var widths = header.map(displayWidth)
    for r in rows { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], displayWidth(c)) } }
    let line = { (cells: [String]) in cells.enumerated().map { pad($0.element, widths[$0.offset]) }.joined(separator: "  ") }
    print("  " + line(header))
    print("  " + widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
    for r in rows { print("  " + line(r)) }
}

// MARK: - 校正麥克風選擇（面板用；CLI：`In_Unison42 mics`、`calibrate --mic <uid|名稱>`）

/// 可選的校正麥克風
struct CalibrationMic: Identifiable, Equatable {
    let uid: String
    let name: String
    let kind: DeviceKind
    let sampleRate: Double
    let channels: Int
    /// Continuity（iPhone）麥克風：只准用於校正，平常不開
    let isContinuity: Bool
    /// Devices.microphone() 的自動選擇（優先 C270）
    let isAutomaticChoice: Bool
    var id: String { uid }

    /// 藍牙輸入：開它會讓那台藍牙裝置切到 HFP（通話音質）
    var isBluetoothInput: Bool { kind.isBluetooth }

    /// 面板顯示用的種類標籤
    var kindLabel: String {
        if isContinuity { return "iPhone（Continuity）" }
        switch kind {
        case .builtIn: return "內建"
        case .usb: return "USB"
        case .bluetooth, .bluetoothLE: return "藍牙"
        case .thunderbolt: return "Thunderbolt"
        case .hdmi: return "HDMI"
        case .displayPort: return "DisplayPort"
        case .pci: return "PCI"
        case .fireWire: return "FireWire"
        case .avb: return "AVB"
        default: return kind.rawValue
        }
    }

    /// 面板要顯示的注意事項（nil = 沒有）
    var caution: String? {
        if isContinuity { return "只在校正期間開啟；延遲較大且會抖動，會自動改用 5 輪交錯量測" }
        if isBluetoothInput { return "開啟藍牙麥克風會讓該裝置切到 HFP 通話音質（校正期間），建議改用其他麥克風" }
        return nil
    }

    /// 這支麥克風使用的量測參數
    var profile: CalProfile { CalProfile.forMic(kind: kind, name: name) }
}

/// 列出所有可當校正麥克風的輸入裝置：實體輸入（USB、內建…）＋ Continuity（iPhone）麥克風。
/// 排除：自己的聚合裝置、「全部喇叭」、虛擬／聚合裝置、沒在運作的裝置、**藍牙輸入**（開了會切到 HFP）。
/// 注意：列出不會開啟任何麥克風。排序：自動選擇（C270）→ 其他實體 → Continuity。
func availableCalibrationMics() -> [CalibrationMic] {
    let auto = Devices.microphone()?.uid
    let list = Devices.all().filter { d in
        guard d.hasInput, d.isAlive else { return false }
        if Devices.excludedUIDs.contains(d.uid) || d.uid.hasPrefix(Devices.ownAggregatePrefix) { return false }
        if d.kind.isBluetooth { return false }   // 藍牙麥克風一律不列（開了會切到 HFP）
        if d.kind == .continuity || d.name.lowercased().contains("iphone") { return true }
        return d.kind.isPhysical
    }.map { d in
        CalibrationMic(uid: d.uid, name: d.name, kind: d.kind, sampleRate: d.nominalSampleRate, channels: d.inputChannels,
                       isContinuity: d.kind == .continuity || d.name.lowercased().contains("iphone"),
                       isAutomaticChoice: d.uid == auto)
    }
    func rank(_ m: CalibrationMic) -> Int { m.isAutomaticChoice ? 0 : m.isContinuity ? 2 : m.isBluetoothInput ? 3 : 1 }
    return list.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
}

/// 預設的校正麥克風：config.calibrationMicUID（在清單裡時）→ 自動選擇（C270 優先）
func defaultCalibrationMic(config: Config, in mics: [CalibrationMic]? = nil) -> CalibrationMic? {
    let list = mics ?? availableCalibrationMics()
    if let u = config.calibrationMicUID, let m = list.first(where: { $0.uid == u }) { return m }
    return list.first(where: \.isAutomaticChoice)
}

/// 依 UID 或名稱找麥克風（純函式）：UID 完全相符 → 名稱完全相符（不分大小寫）→ 名稱子字串唯一相符
func matchCalibrationMic(_ query: String, in mics: [CalibrationMic]) -> Result<CalibrationMic, CalibrationFailure> {
    if let m = mics.first(where: { $0.uid == query }) { return .success(m) }
    let q = query.lowercased()
    if let m = mics.first(where: { $0.name.lowercased() == q }) { return .success(m) }
    let hits = mics.filter { $0.name.lowercased().contains(q) || $0.uid.lowercased().contains(q) }
    if hits.count == 1 { return .success(hits[0]) }
    if hits.isEmpty {
        return .failure(CalibrationFailure("找不到符合「\(query)」的校正麥克風（`In_Unison42 mics` 列出可選的；iPhone 要在旁邊、已解鎖）",
                                           details: mics.map { "\($0.name) uid=\($0.uid)" }))
    }
    return .failure(CalibrationFailure("「\(query)」同時符合 \(hits.count) 支麥克風，請用 UID 指定",
                                       details: hits.map { "\($0.name) uid=\($0.uid)" }))
}

/// `--mic` 指到藍牙輸入嗎？UID／名稱完全相符 → 是；子字串只在可用清單裡沒有任何相符時才算（避免誤擋）
func bluetoothMicMatching(_ query: String, bluetoothInputs: [AudioDevice], usable: [CalibrationMic]) -> AudioDevice? {
    let q = query.lowercased()
    if let b = bluetoothInputs.first(where: { $0.uid == query || $0.name.lowercased() == q }) { return b }
    if usable.contains(where: { $0.name.lowercased().contains(q) || $0.uid.lowercased().contains(q) }) { return nil }
    return bluetoothInputs.first { $0.name.lowercased().contains(q) || $0.uid.lowercased().contains(q) }
}

func bluetoothMicRefusal(_ name: String) -> String {
    "不可用藍牙麥克風「\(name)」校正：開啟它會把藍牙裝置切到 HFP 通話音質，量到的也不是平常 A2DP 的延遲。請改用 C270 或其他有線／內建麥克風"
}

/// 解析要用的校正麥克風：uid = nil → 自動（Devices.microphone()，不含 Continuity）；
/// 指定 uid → 必須在 availableCalibrationMics() 裡（可以是 Continuity），否則 nil（呼叫端要報錯，不要默默換別支）
func resolveCalibrationMic(uid: String?) -> AudioDevice? {
    guard let uid else { return Devices.microphone() }
    if let d = Devices.device(uid: uid), d.kind.isBluetooth { return nil }
    guard availableCalibrationMics().contains(where: { $0.uid == uid }) else { return nil }
    return Devices.device(uid: uid)
}

/// 解析 `--mic` 參數：
///   * nil → config.calibrationMicUID；設定了但目前不在 → 失敗（不默默換別支：位置不同，相對延遲會差幾 ms）
///   * "auto" → 自動（C270 優先，不含 Continuity）
///   * 其他 → UID 或名稱子字串（matchCalibrationMic）
func resolveCalibrationMic(query: String?, config: Config) -> Result<AudioDevice, CalibrationFailure> {
    let mics = availableCalibrationMics()
    let chosen: CalibrationMic
    // 藍牙輸入一律拒絕（不只警告）：明確指定或設定裡存的是藍牙麥克風 → 失敗
    let btInputs = Devices.all().filter { $0.hasInput && $0.kind.isBluetooth }
    if let q = query, q.lowercased() != "auto", let b = bluetoothMicMatching(q, bluetoothInputs: btInputs, usable: mics) {
        return .failure(CalibrationFailure(bluetoothMicRefusal(b.name)))
    }
    if query == nil, let u = config.calibrationMicUID, let b = btInputs.first(where: { $0.uid == u }) {
        return .failure(CalibrationFailure(bluetoothMicRefusal(b.name) + "（設定裡存的校正麥克風是它；請在面板改選或加 --mic auto）"))
    }
    if let q = query, q.lowercased() != "auto" {
        switch matchCalibrationMic(q, in: mics) {
        case .failure(let e): return .failure(e)
        case .success(let m): chosen = m
        }
    } else if query == nil, let u = config.calibrationMicUID {
        guard let m = mics.first(where: { $0.uid == u }) else {
            return .failure(CalibrationFailure("設定的校正麥克風（uid=\(u)）目前不在（iPhone 不在旁邊或未解鎖？）。"
                + "要改用自動（C270）請加 --mic auto，或在面板改選"))
        }
        chosen = m
    } else {
        guard let d = Devices.microphone() else {
            return .failure(CalibrationFailure("找不到可用的麥克風（C270 未接？自動選擇不含 Continuity／iPhone 麥克風，要用請指定 --mic <uid|名稱>）"))
        }
        return .success(d)
    }
    guard let d = Devices.device(uid: chosen.uid) else {
        return .failure(CalibrationFailure("校正麥克風「\(chosen.name)」剛剛消失了"))
    }
    return .success(d)
}

/// `In_Unison42 mics`：列出可選的校正麥克風
func cmdListMics() -> Int32 {
    let cfg = Config.load()
    let mics = availableCalibrationMics()
    let def = defaultCalibrationMic(config: cfg, in: mics)?.uid
    if mics.isEmpty { print("（沒有可用的輸入裝置）") }
    for m in mics {
        var tags: [String] = [m.kindLabel]
        if m.uid == def { tags.append("預設") }
        if m.isAutomaticChoice { tags.append("自動選擇") }
        if m.uid == cfg.calibrationMicUID { tags.append("設定中") }
        if m.isContinuity { tags.append("只用於校正") }
        if m.isBluetoothInput { tags.append("會切到 HFP") }
        if m.profile != .standard { tags.append(m.profile.name) }
        print("\(m.name) [\(Int(m.sampleRate))Hz \(m.channels)ch uid=\(m.uid)]  <\(tags.joined(separator: ","))>")
    }
    if let u = cfg.calibrationMicUID, !mics.contains(where: { $0.uid == u }) {
        print("⚠ 設定的校正麥克風 uid=\(u) 目前不在；calibrate 會拒絕執行（加 --mic auto 改用自動）")
    }
    return 0
}

// MARK: - 結果型別（CLI 與面板共用）

struct CalibrationFailure: Error, CustomStringConvertible, Equatable {
    let message: String
    var details: [String] = []
    init(_ message: String, details: [String] = []) { self.message = message; self.details = details }
    var description: String { details.isEmpty ? message : message + "\n" + details.map { "  · " + $0 }.joined(separator: "\n") }
}

struct CalibrationOptions: Equatable {
    /// 只驗證、不寫設定（依目前模式下出聲的裝置）
    var verify = false
    /// 同時做響度匹配（寫 trimDb；只衰減）
    var level = false
    /// 目前模式（驗證對象／寫入 delayMs 的依據）；nil = engine 目前的模式
    var mode: PlayMode? = nil
    /// CLI：另外印機器可讀的進度行 `@@progress <0…1> <訊息>`（給以子行程呼叫的一方解析）
    var progressLines = false
    init(verify: Bool = false, level: Bool = false, mode: PlayMode? = nil, progressLines: Bool = false) {
        self.verify = verify; self.level = level; self.mode = mode; self.progressLines = progressLines
    }
}

struct CalibrationDeviceResult: Identifiable, Equatable {
    let uid: String
    let name: String
    /// 參考輸出（延遲定義為 0 的那台）
    let isReference: Bool
    /// 這次有沒有量它
    let measured: Bool
    /// 沒量的原因（已關閉／目前模式不出聲…）
    let note: String?
    /// 校正：寫入的 measuredLatencyMs（相對最快）；驗證：量到的總到達延遲（相對參考，ms）
    let latencyMs: Double?
    /// 各輪量到的值（相對參考，ms）
    let roundsMs: [Double]
    let spreadMs: Double?
    let rejectedRounds: Int
    let minSnrDb: Double?
    let levelDb: Double?
    let trimDb: Double?
    /// 驗證：現有補償；校正：寫入後目前模式的補償（不出聲 = nil）
    let delayMs: Double?
    /// 驗證：相對基準的殘差
    let residualMs: Double?
    var id: String { uid }
}

struct CalibrationReport: Equatable {
    let verify: Bool
    let mode: PlayMode
    let micName: String
    let micUID: String
    let micIsContinuity: Bool
    let profileName: String
    let devices: [CalibrationDeviceResult]
    /// 驗證：通過與否；校正：是否寫入成功（或不需要校正）
    let passed: Bool
    let maxResidualMs: Double?
    let wroteConfig: Bool
    /// 麥克風路徑延遲估計（ms）
    let micPathMs: Double?
    let driftPpm: [Double]
    let noiseDbFS: Double?
    /// 寫入後三種模式的出聲計畫（只有校正寫入時有）
    let plans: [PlayMode: [String: PlanEntry]]
    let notes: [String]
}

// MARK: - 非阻塞 API（面板用）

/// startCalibration 的控制把手
final class CalibrationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    /// 要求中止（下一個等待點生效；已排程的 chirp 會取消，系統狀態會還原）
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
}

/// 同時只能有一個校正（Swift 6：全域可變狀態改用 LockedValue）
private let calibrationRunning = LockedValue(false)

/// 面板用：在背景執行緒跑一次校正（或 options.verify 的驗證），不阻塞呼叫端。
///   * mic：UID 或名稱子字串；nil = config.calibrationMicUID，否則 C270；"auto" = 自動
///   * progress(訊息, 0…1)、done(結果) 都在主執行緒呼叫
///   * **前提**：同一時間只能有一個 tap —— 呼叫前 app 自己的 engine（與 Reconnector）必須已經 stop，
///     done 之後再 reloadConfig()＋重新 start。這個函式會自己建一個 Engine、跑完就 stop。
///   * 同時只能有一個校正；重複呼叫會直接 done(.failure)。
@discardableResult
func startCalibration(mic: String?, options: CalibrationOptions = CalibrationOptions(),
                      progress: @escaping (String, Double) -> Void,
                      done: @escaping (Result<CalibrationReport, CalibrationFailure>) -> Void) -> CalibrationHandle {
    let handle = CalibrationHandle()
    let busy = calibrationRunning.withLock { v -> Bool in
        if v { return true }
        v = true
        return false
    }
    guard !busy else {
        DispatchQueue.main.async { done(.failure(CalibrationFailure("已經有一個校正在進行"))) }
        return handle
    }
    let t = Thread {
        // 兩個 tap 會互相靜音：實例鎖在別人手上、或舊版 LaunchAgent 在跑就不做
        let others = findLegacyRunInstances().map(\.pid) + (InstanceLock.holderPID().map { $0 == getpid() ? [] : [$0] } ?? [])
        guard others.isEmpty else {
            calibrationRunning.value = false
            let msg = "另有 In_Unison42 在跑（pid \(others.map { String($0) }.joined(separator: ", "))），兩個 tap 會互相靜音；請先結束它再校正"
            DispatchQueue.main.async { done(.failure(CalibrationFailure(msg))) }
            return
        }
        let engine = Engine(config: Config.load(), mode: options.mode)
        let session = CalibrationSession(engine: engine, options: options, micQuery: mic, handle: handle)
        session.progress = { msg, f in DispatchQueue.main.async { progress(msg, f) } }
        let r = session.run()
        engine.stop()
        calibrationRunning.value = false
        DispatchQueue.main.async { done(r) }
    }
    t.name = "In_Unison42.calibration"
    t.qualityOfService = .userInitiated
    t.start()
    return handle
}

// MARK: - 進入點（CLI）

/// `In_Unison42 calibrate [--verify|--verify-program|--volume-test] [--level] [--mic <uid|名稱|auto>] [--mode music|movie|game] [--progress-lines] [--selftest]`
/// engine：cmdCalibrate 建立、已載入 config、**尚未 start**；由本函式負責 start 與寫回 config（回去後會 stop）。
func runCalibrate(engine: Engine, args: [String]) -> Int32 {
    var opts = CalibrationOptions()
    var selftest = false, verifyProgram = false, volumeTest = false, checkSilent = false, pulseWrite = false
    var bluetooth = true, btUncalibrated = false
    var micQuery: String? = nil
    // 預設：粉紅雜訊 1–4 kHz（第二版，2026-09-29 Kang 決定：柔和、延遲以 1–4 kHz 為準）。
    // 木琴 C5 實機驗收不過（docs/TESTLOG.zh-TW.md「木琴測試音評估」），保留為 --signal xylo；舊白雜訊 --signal noise
    var signal = PPSignal.pink
    var calGainDb: Double? = PPParams.calibrationGainDb
    var signalFor: [String: PPSignal] = [:]
    var dumpDir: String? = nil
    var abSignals: [PPSignal]? = nil
    var only: [String] = []
    var full = false
    var i = 0
    while i < args.count {
        let a = args[i]
        i += 1
        switch a {
        case "--verify-program": verifyProgram = true
        case "--pulse": verifyProgram = true; pulseWrite = true
        case "--volume-test": volumeTest = true
        case "--check-silent": checkSilent = true
        case "--no-bluetooth": bluetooth = false
        case "--full": full = true   // 【第 C 輪】--only 一台已校正的藍牙時也用完整量測（不用短量測）
        case "--bt-uncalibrated": btUncalibrated = true
        case "--verify": opts.verify = true
        case "--level": opts.level = true
        case "--selftest": selftest = true
        case "--progress-lines": opts.progressLines = true
        case "--signal" where i < args.count && args[i] == "ab":
            abSignals = [.xylophone, .noise]; i += 1
        case "--signal" where i < args.count && args[i] == "ab-strong":
            abSignals = [.xylophoneStrongClick, .noise]; i += 1
        case "--signal" where i < args.count && args[i] == "ab-pink":
            abSignals = [.pink, .noise]; i += 1
        case "--cal-gain-db":
            // 校正時 HDMI／DP／藍牙的固定增益（dB，上限 0）；off = 照系統音量（舊行為）
            guard i < args.count else { print("--cal-gain-db 要接 dB（≤ 0）或 off"); return 2 }
            if args[i] == "off" { calGainDb = nil } else if let v = Double(args[i]) { calGainDb = min(v, 0) } else { print("--cal-gain-db 要接 dB（≤ 0）或 off"); return 2 }
            i += 1
        case "--signal":
            guard i < args.count, let sg = PPSignal.parse(args[i]) else { print("--signal 要接 pink（粉紅雜訊 1–4 kHz，預設）／noise（舊白雜訊）／xylo（木琴 C5，試驗用）／xylo-strong／ab、ab-strong（木琴 vs 白雜訊）／ab-pink（粉紅 vs 白雜訊）"); return 2 }
            signal = sg; i += 1
        case "--signal-for":
            // 個別裝置改用別的測試音：--signal-for <uid|名稱子字串>=<xylo|xylo-strong|noise>（可重複）
            guard i < args.count, let eq = args[i].lastIndex(of: "="), let sg = PPSignal.parse(String(args[i][args[i].index(after: eq)...])),
                  eq != args[i].startIndex else {
                print("--signal-for 要接 <uid|名稱>=<xylo|xylo-strong|noise>，例如 --signal-for GLASS5=noise"); return 2
            }
            signalFor[String(args[i][..<eq])] = sg; i += 1
        case "--only":
            // 增量校正（配 --pulse）：只量參考喇叭＋這些裝置（uid 或名稱子字串；可重複、或逗號分隔），其他沿用既有值
            guard i < args.count, !args[i].hasPrefix("--") else { print("--only 要接輸出裝置 uid（或名稱），例如 --only AA-BB-CC-DD-EE-01:output"); return 2 }
            only += args[i].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            i += 1
        case "--dump":   // 調參用：把錄音與中繼資料存到 <dir>（離線 pp-reanalyze <dir>）
            guard i < args.count else { print("--dump 要接目錄"); return 2 }
            dumpDir = args[i]; i += 1
        case "--mic":
            guard i < args.count else { print("--mic 後面要接麥克風 UID 或名稱（`In_Unison42 mics` 列出；auto = 自動）"); return 2 }
            micQuery = args[i]; i += 1
        case "--mode":
            guard i < args.count, let m = PlayMode(rawValue: args[i]) else { print("--mode 要接 music／movie／game"); return 2 }
            opts.mode = m; i += 1
        default:
            print("未知參數：\(a)（可用：--verify、--verify-program、--pulse、--volume-test、--level、--mic <uid|名稱|auto>、--mode music|movie|game、--progress-lines、--check-silent（配 --verify-program）、--no-bluetooth、--bt-uncalibrated（實機測試：未校正的藍牙也照不補償出聲）、--signal xylo|xylo-strong|noise、--signal-for <uid|名稱>=<訊號>、--only <uid>（配 --pulse：增量校正；配 --verify-program：只量藍牙的驗證）、--full（--only 藍牙也用完整量測）、--selftest）")
            return 2
        }
    }
    if selftest {
        let a = runCalibrationSelfTest()
        let b = runProgramPathSelfTest()
        return a == 0 && b == 0 ? 0 : 1
    }
    let mode = opts.mode ?? engine.mode
    if verifyProgram {
        // --pulse：脈衝＋GCC-PHAT 量尺寫入 measuredLatencyMs（預設音樂模式＝所有啟用的裝置都出聲、都量得到）
        return runVerifyProgramPath(engine: engine, micQuery: micQuery, mode: pulseWrite ? (opts.mode ?? .music) : mode,
                                    checkSilent: checkSilent, write: pulseWrite, bluetooth: bluetooth, btUncalibrated: btUncalibrated,
                                    signal: signal, signalFor: signalFor, dumpDir: dumpDir, abSignals: abSignals, calibrationGainDb: calGainDb,
                                    only: only, full: full)
    }
    if !only.isEmpty { print("--only 只能配 --pulse（增量校正）或 --verify-program（只量藍牙的驗證）"); return 2 }
    if volumeTest { return runVolumeTest(engine: engine, micQuery: micQuery, mode: mode, bluetooth: bluetooth) }
    if opts.verify && opts.level {
        print("--verify 只驗證、不改設定，不能和 --level 一起用")
        return 2
    }
    let session = CalibrationSession(engine: engine, options: opts, micQuery: micQuery, handle: nil)
    switch session.run() {
    case .failure(let e):
        print("✗ \(e.message)")
        for d in e.details { print("  · \(d)") }
        return 1
    case .success(let r):
        return r.passed ? 0 : 1
    }
}

// MARK: - 校正流程

private final class CalibrationSession {
    let engine: Engine
    let options: CalibrationOptions
    let micQuery: String?
    let handle: CalibrationHandle?
    var progress: ((String, Double) -> Void)?
    private var recorder: MicRecorder?
    private var cleanupIDs: [Int] = []
    private var snapshot: SystemAudioSnapshot?
    private var lastFraction = 0.0

    init(engine: Engine, options: CalibrationOptions, micQuery: String?, handle: CalibrationHandle?) {
        self.engine = engine
        self.options = options
        self.micQuery = micQuery
        self.handle = handle
    }

    private var cancelled: Bool { handle?.isCancelled ?? false }

    /// 印一行並回報進度（fraction nil = 沿用上一個）
    private func say(_ msg: String, _ fraction: Double? = nil) {
        if let f = fraction { lastFraction = min(max(f, 0), 1) }
        print(msg)
        if options.progressLines { print(String(format: "@@progress %.3f %@", lastFraction, msg)) }
        progress?(msg, lastFraction)
    }

    /// 等到條件成立或逾時；被取消時立刻回 false
    private func waitUntil(timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cancelled { return false }
            if cond() { return true }
            usleep(10_000)
        }
        return cond()
    }

    private func fail(_ msg: String, _ details: [String] = []) -> Result<CalibrationReport, CalibrationFailure> {
        .failure(CalibrationFailure(cancelled ? "已取消" : msg, details: cancelled ? [] : details))
    }

    func run() -> Result<CalibrationReport, CalibrationFailure> {
        let verify = options.verify, level = options.level
        let targetMode = options.mode ?? engine.mode
        say(verify ? "== 延遲校正：驗證模式（不改設定；\(targetMode.label)模式下出聲的裝置）==" : "== 延遲校正\(level ? "＋響度匹配" : "") ==", 0)

        let mic: AudioDevice
        switch resolveCalibrationMic(query: micQuery, config: engine.config) {
        case .failure(let e): return .failure(e)
        case .success(let d): mic = d
        }
        let isContinuity = mic.kind == .continuity || mic.name.lowercased().contains("iphone")
        let profile = CalProfile.forMic(kind: mic.kind, name: mic.name)
        say("麥克風：\(mic.name)（\(Int(mic.nominalSampleRate)) Hz，\(mic.inputChannels)ch，只錄第 1 聲道；不改系統預設輸入）；量測參數：\(profile.name)", 0.02)
        if isContinuity { say("⚠ 使用 Continuity（iPhone）麥克風：只在這次校正期間開啟；只取相對延遲，麥克風本身的延遲會抵消") }
        if mic.kind.isBluetooth { return .failure(CalibrationFailure(bluetoothMicRefusal(mic.name))) }   // 雙重保險（resolve 已擋）

        // 系統狀態：本流程不改預設輸出／音量／靜音，但照規定先記、最後還原
        let snap = SystemAudioSnapshot.capture()
        snapshot = snap
        print("系統狀態：\(snap)")
        cleanupIDs.append(Cleanup.register { snap.restore() })
        defer { finish() }

        let orig = engine.config
        var meas = orig
        if level {   // 量原始響度：trim 全部歸 0（第 2 版 trim 一律生效）
            for k in meas.devices.keys { meas.devices[k]!.trimDb = 0 }
        }
        engine.log = { print("  [engine] \($0)") }
        engine.applyConfig(meas)
        // 校正：音樂模式（量測與出聲遮罩無關，測試訊號不受遮罩影響）；驗證：目標模式（補償照 plan）
        engine.setMode(verify ? targetMode : .music)
        cleanupIDs.append(Cleanup.register { [engine] in engine.setMonitorMode(muteProgram: false) })
        engine.setMonitorMode(muteProgram: true)
        do { try engine.start() } catch { return fail("引擎啟動失敗：\(error)") }

        let c0 = engine.ioCycles
        guard waitUntil(timeout: 3, { self.engine.ioCycles > c0 + 4 }) else {
            return fail("引擎 IOProc 沒在跑（多半是「系統音訊錄製」權限未授與：系統設定 → 隱私權與安全性 → 螢幕與系統錄音 → 僅系統錄音），無法出聲量測")
        }
        let outs = engine.outputDetails
        let sr = engine.sampleRate
        guard let clock = outs.first(where: { $0.isClock })?.index else { return fail("找不到主時鐘輸出") }

        // 要量的輸出：校正 = 啟用的；驗證 = 目前模式下出聲的
        var notes: [String] = []
        var skipNote: [Int: String] = [:]
        var targets: [Int] = []
        for o in outs {
            if verify {
                let e = engine.planEntry(uid: o.uid)
                if e?.active == true { targets.append(o.index) } else { skipNote[o.index] = "\(targetMode.label)模式不出聲：\(e?.reason ?? "不在計畫裡")" }
            } else {
                if meas.device(o.uid).enabled { targets.append(o.index) } else { skipNote[o.index] = "已關閉，未量測（保留舊值）" }
            }
        }
        let bt = Devices.bluetoothOutputs()
        if !bt.isEmpty { notes.append("藍牙（只輸出路徑）不在 chirp 量尺範圍：請用 `calibrate --pulse`（面板「開始校正」）量 \(bt.map(\.name).joined(separator: "、"))") }
        for (idx, n) in skipNote.sorted(by: { $0.key < $1.key }) { say("  略過「\(outs[idx].name)」：\(n)") }

        guard targets.count >= 2 else {
            let msg = verify ? "\(targetMode.label)模式下只有 \(targets.count) 台出聲，不需要驗證" : "只有 \(targets.count) 台要量的輸出，不需要校正"
            say(msg, 1)
            return .success(CalibrationReport(verify: verify, mode: targetMode, micName: mic.name, micUID: mic.uid, micIsContinuity: isContinuity,
                                              profileName: profile.name, devices: outs.map {
                CalibrationDeviceResult(uid: $0.uid, name: $0.name, isReference: false, measured: false, note: skipNote[$0.index],
                                        latencyMs: nil, roundsMs: [], spreadMs: nil, rejectedRounds: 0, minSnrDb: nil, levelDb: nil,
                                        trimDb: nil, delayMs: nil, residualMs: nil)
            }, passed: true, maxResidualMs: nil, wroteConfig: false, micPathMs: nil, driftPpm: [], noiseDbFS: nil, plans: [:], notes: notes + [msg]))
        }
        let ref = targets.contains(clock) ? clock : targets[0]

        let src = outs[0]
        if Devices.isMuted(src.deviceID) {
            return fail("音量來源「\(src.name)」目前靜音，其他喇叭的測試聲也會是 0。請先取消靜音再校正（本程式不會替你改）")
        }
        let vol = Devices.volumeScalar(src.deviceID)
        say(String(format: "音量來源「%@」音量 %@（不會調高；若量不到請自己調大）", src.name, vol.map { String(format: "%.0f", $0 * 100) } ?? "?"), 0.05)

        // 排程參數
        var offsets = [Int64](repeating: 0, count: outs.count)
        var maxDelayMs = 0.0
        if verify {
            for idx in targets {
                let ms = engine.planEntry(uid: outs[idx].uid)?.delayMs ?? 0
                maxDelayMs = max(maxDelayMs, ms)
                offsets[idx] = Int64(min(max((ms / 1000 * sr).rounded(), 0), (Config.maxDelayMs / 1000 * sr).rounded(.up)))
            }
        }
        let intervalFrames = Int64(((CalParams.intervalMs + maxDelayMs) / 1000 * sr).rounded())
        let measured = targets.filter { $0 != ref }
        let chirpsPerRound = profile.chirpsPerRound(measured: measured.count)
        let totalChirps = chirpsPerRound * profile.rounds
        let planSeconds = profile.preRollMs / 1000 + Double(totalChirps) * Double(intervalFrames) / sr + CalParams.tailMs / 1000
        let rec = MicRecorder(device: mic, seconds: planSeconds + 4)
        recorder = rec
        cleanupIDs.append(Cleanup.register { rec.stop() })
        say(String(format: "量 %d 台（參考：%@）、每輪 %d 個 chirp × %d 輪、間隔 %.0f ms，約 %.1f 秒。請保持安靜…",
                   targets.count, outs[ref].name, chirpsPerRound, profile.rounds, Double(intervalFrames) / sr * 1000, planSeconds), 0.08)

        let ms = rec.start()
        guard ms == noErr else { return fail("麥克風開啟失敗 status=\(ms)（\(CA.fourCC(UInt32(bitPattern: ms)))）") }
        guard waitUntil(timeout: 4, { rec.frames > Int(0.3 * rec.rate) }) else {
            return fail("麥克風沒有送資料進來（裝置忙碌、無權限，或 iPhone 未連上？）")
        }

        // 粗略對應：同一時刻讀兩邊（麥克風延遲與抖動由分析端的自適應搜尋窗吸收）
        let e1 = engine.sampleTime
        let m = rec.frames
        let e2 = engine.sampleTime
        let map = RoughMap(anchorEngine: (e1 + e2) / 2, anchorMic: Double(m), ratio: rec.rate / sr)
        let base = map.anchorEngine + Int64(profile.preRollMs / 1000 * sr)
        let plan = buildPlan(ref: ref, measured: measured, base: base, intervalFrames: intervalFrames,
                             rounds: profile.rounds, offsets: offsets, interleave: profile.interleave)
        let chirp = ChirpTemplate.playback(rate: sr)
        let gen = engine.generation

        for (k, c) in plan.enumerated() {
            let lead = Int64(0.35 * sr)
            // 等到排程前 350 ms 且該輸出上一段已播完
            let ok = waitUntil(timeout: Double(c.sched - engine.sampleTime) / sr + 3) {
                self.engine.sampleTime >= c.sched - lead && !self.engine.isTestSignalActive(output: c.output)
            }
            guard ok, engine.generation == gen, engine.isRunning else {
                engine.cancelTestSignals()
                return fail("排程第 \(k + 1) 個 chirp 時引擎狀態改變（重建或停止），中止")
            }
            guard engine.playTestSignal(chirp, toOutput: c.output, atFrameOffset: Int(c.sched), delayed: verify) else {
                engine.cancelTestSignals()
                return fail("排程第 \(k + 1) 個 chirp 失敗")
            }
            if c.round != (k > 0 ? plan[k - 1].round : -1) {
                say("第 \(c.round + 1)/\(profile.rounds) 輪", 0.1 + 0.75 * Double(k) / Double(plan.count))
            }
        }
        // 等最後一個 chirp 播完＋尾巴
        let last = plan.last!
        let endT = last.sched + last.startOffset + Int64(CalParams.tailMs / 1000 * sr)
        _ = waitUntil(timeout: Double(endT - engine.sampleTime) / sr + 3) { self.engine.sampleTime >= endT }
        if cancelled { engine.cancelTestSignals(); return fail("已取消") }
        // 麥克風路徑延遲（Continuity 可能上百 ms）：多等一點讓尾巴進來
        let needMic = Int(map.mic(endT)) + Int(0.5 * rec.rate)
        _ = waitUntil(timeout: 2.5) { rec.frames >= min(needMic, rec.capacity) }
        rec.stop()
        engine.setMonitorMode(muteProgram: false)
        let samples = rec.samples()
        say(String(format: "錄到 %.2f 秒，麥克風峰值 %.1f dBFS，漏格 %d 次；分析中…", Double(samples.count) / rec.rate,
                   20 * log10(max(Double(rec.peak), 1e-10)), rec.gaps), 0.88)
        let sk = engine.ioSkips
        if sk.events > 0 { print("  引擎輸出 IO 跳號 \(sk.events) 次、共 \(sk.frames) frame（已補進時間軸）") }
        if rec.peak == 0 {
            return fail("麥克風錄到的全是 0：多半是麥克風權限未授與（系統設定 → 隱私權與安全性 → 麥克風）")
        }
        if rec.gaps > 0 {
            return fail("麥克風錄音中斷 \(rec.gaps) 次（時間軸不連續），結果不可信，請重試")
        }

        let names = outs.map(\.name)
        let an = analyzeCalibration(rec: samples, micRate: rec.rate, engineRate: sr, plan: plan, map: map,
                                    nOutputs: outs.count, ref: ref, names: names, profile: profile)
        print(String(format: "環境雜訊 %.1f dBFS；麥克風路徑延遲約 %@ ms（搜尋窗平移 %.0f ms）；麥克風／引擎時鐘差 %@ ppm", an.noiseDbFS,
                     an.micPathMs.map { String(format: "%.1f", $0) } ?? "?", an.searchShiftMs,
                     an.driftPpm.map { String(format: "%.1f", $0) }.joined(separator: "／")))

        let lat = an.outputs.map(\.medLatMs)
        let lv = an.outputs.map(\.medLevelDb)
        let roundsText = { (o: Int) -> String in
            let r = an.outputs[o]
            return r.latMs.map { String(format: "%.2f", $0) }.joined(separator: "/") + (r.rejected > 0 ? "（剔除 \(r.rejected)）" : "")
        }

        if verify {
            // 殘差：以設定補償最小（最慢）的那台為基準；只看出聲的裝置
            let planned = { (idx: Int) in self.engine.planEntry(uid: outs[idx].uid)?.delayMs ?? 0 }
            let anchor = targets.min { planned($0) < planned($1) }!
            var resid: [Int: Double] = [:]
            for idx in targets { resid[idx] = lat[idx] - lat[anchor] }
            printTable(["裝置", "現有補償", "量到總延遲(相對)", "殘差", "各輪", "SNR"], targets.map { idx in
                [outs[idx].name + (idx == anchor ? "（基準）" : ""),
                 String(format: "%.2f ms", planned(idx)),
                 String(format: "%.3f ms", lat[idx]),
                 String(format: "%+.3f ms", resid[idx]!),
                 roundsText(idx),
                 String(format: "%.1f dB", an.outputs[idx].minSnrDb)]
            })
            if !an.errors.isEmpty { return fail("驗證量測不合格（無法判斷對齊）", an.errors) }
            let worst = resid.values.map(abs).max() ?? 0
            let passed = worst < CalParams.verifyToleranceMs
            say(passed ? String(format: "✓ 驗證通過（%@模式、%d 台出聲）：最大殘差 %.3f ms（< %.0f ms）", targetMode.label, targets.count, worst, CalParams.verifyToleranceMs)
                       : String(format: "✗ 驗證未通過：最大殘差 %.3f ms（≥ %.0f ms），請重新 calibrate", worst, CalParams.verifyToleranceMs), 1)
            let devs = outs.map { o -> CalibrationDeviceResult in
                let t = targets.contains(o.index)
                let r = an.outputs[o.index]
                return CalibrationDeviceResult(uid: o.uid, name: o.name, isReference: o.index == ref, measured: t, note: skipNote[o.index],
                                               latencyMs: t ? lat[o.index] : nil, roundsMs: r.latMs, spreadMs: t ? r.spreadMs : nil,
                                               rejectedRounds: r.rejected, minSnrDb: t ? r.minSnrDb : nil, levelDb: nil, trimDb: nil,
                                               delayMs: t ? planned(o.index) : nil, residualMs: resid[o.index])
            }
            return .success(CalibrationReport(verify: true, mode: targetMode, micName: mic.name, micUID: mic.uid, micIsContinuity: isContinuity,
                                              profileName: profile.name, devices: devs, passed: passed, maxResidualMs: worst, wroteConfig: false,
                                              micPathMs: an.micPathMs, driftPpm: an.driftPpm, noiseDbFS: an.noiseDbFS, plans: [:], notes: notes))
        }

        // 校正：相對這次量到的最快裝置
        let minLat = targets.map { lat[$0] }.min() ?? 0
        var rel: [String: Double] = [:]
        for idx in targets { rel[outs[idx].uid] = lat[idx] - minLat }
        let trimsArr = levelTrims(targets.map { lv[$0] })
        var trims: [String: Double] = [:]
        for (k, idx) in targets.enumerated() { trims[outs[idx].uid] = trimsArr[k] }

        var cfg = Config.load()
        let planDevs = outs.map { (uid: $0.uid, name: $0.name, isBuiltIn: $0.kind == .builtIn) }
        let (newCfg, curPlan) = applyCalibrationResult(to: cfg, measuredRel: rel, trims: level ? trims : nil, mode: targetMode, devices: planDevs)
        var header = ["裝置", "量到延遲(相對最快)", "各輪(相對參考)", "SNR", "\(targetMode.label)模式"]
        if level { header += ["響度", "trim"] }
        printTable(header, outs.map { o in
            let t = targets.contains(o.index)
            let r = an.outputs[o.index]
            var row = [o.name + (o.index == ref ? "（參考）" : ""),
                       t ? String(format: "%.3f ms", rel[o.uid]!) : "—",
                       t ? roundsText(o.index) : (skipNote[o.index] ?? "—"),
                       t ? String(format: "%.1f dB", r.minSnrDb) : "—",
                       curPlan[o.uid]?.description ?? "—"]
            if level { row += [t ? String(format: "%.1f dB", lv[o.index]) : "—", t ? String(format: "%.1f dB", trims[o.uid]!) : "—"] }
            return row
        })
        if !an.errors.isEmpty { return fail("量測不合格，設定未修改", an.errors) }
        if level, let mx = targets.map({ lv[$0] }).max(), let mn = targets.map({ lv[$0] }).min(), mx - mn > CalParams.maxTrimCutDb {
            say(String(format: "⚠ 最大聲與最小聲相差 %.1f dB，trim 最多只降 %.0f dB，最小聲的那台建議自己調大", mx - mn, CalParams.maxTrimCutDb))
        }
        if let mx = rel.values.max(), mx > Config.maxDelayMs {
            say(String(format: "⚠ 最慢的裝置比最快的慢 %.1f ms，超過延遲線上限 %.0f ms：plan() 會讓它不出聲", mx, Config.maxDelayMs))
        }
        for idx in skipNote.keys.sorted() where newCfg.measuredLatencyMs(outs[idx].uid) != nil {
            notes.append("「\(outs[idx].name)」這次沒量，保留舊的實測延遲（基準可能不同；重新開啟後建議再校正一次）")
        }
        cfg = newCfg
        if level { cfg.levelMatch = true }
        cfg.calibratedAt = Config.nowISO8601()
        do { try cfg.save() } catch { return fail("寫設定檔失敗：\(error)") }
        engine.applyConfig(cfg)
        var plans: [PlayMode: [String: PlanEntry]] = [:]
        for pm in PlayMode.allCases {
            plans[pm] = In_Unison42.plan(devices: planDevs.map { PlanDevice(uid: $0.uid, name: $0.name, isBuiltIn: $0.isBuiltIn, config: cfg) },
                             mode: pm, caps: cfg.modeCaps)
            let line = outs.map { o in "\(o.name) \(plans[pm]![o.uid].map { $0.active ? String(format: "%.2fms", $0.delayMs) : "✕" } ?? "?")" }
            print("  \(pm.label)：\(line.joined(separator: "、"))")
        }
        for n in notes { say("⚠ \(n)") }
        say("✓ 已寫入 \(Config.fileURL.path) 並套用（delayMs 依\(targetMode.label)模式由 plan() 計算）", 1)
        let devs = outs.map { o -> CalibrationDeviceResult in
            let t = targets.contains(o.index)
            let r = an.outputs[o.index]
            let e = curPlan[o.uid]
            return CalibrationDeviceResult(uid: o.uid, name: o.name, isReference: o.index == ref, measured: t, note: skipNote[o.index],
                                           latencyMs: t ? rel[o.uid] : nil, roundsMs: r.latMs, spreadMs: t ? r.spreadMs : nil,
                                           rejectedRounds: r.rejected, minSnrDb: t ? r.minSnrDb : nil, levelDb: t ? lv[o.index] : nil,
                                           trimDb: t && level ? trims[o.uid] : nil, delayMs: (e?.active ?? false) ? e!.delayMs : nil, residualMs: nil)
        }
        return .success(CalibrationReport(verify: false, mode: targetMode, micName: mic.name, micUID: mic.uid, micIsContinuity: isContinuity,
                                          profileName: profile.name, devices: devs, passed: true, maxResidualMs: nil, wroteConfig: true,
                                          micPathMs: an.micPathMs, driftPpm: an.driftPpm, noiseDbFS: an.noiseDbFS, plans: plans, notes: notes))
    }

    /// 無論成功失敗都會跑：關監聽模式、關麥克風、還原系統狀態
    private func finish() {
        engine.cancelTestSignals()
        engine.setMonitorMode(muteProgram: false)
        recorder?.stop()
        snapshot?.restore()
        for id in cleanupIDs { Cleanup.unregister(id) }
        cleanupIDs.removeAll()
    }
}

// MARK: - 合成訊號自測（不出聲、不開麥克風）

private struct SynthRNG {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
    mutating func gauss() -> Double {
        let u = max(next(), 1e-12), v = next()
        return sqrt(-2 * log(u)) * cos(2 * Double.pi * v)
    }
}

private struct SynthScenario {
    var name: String
    var latMs: [Double]          // 各輸出真實延遲（含聲學）
    var amps: [Double]           // 到達麥克風時的振幅
    var noise: Double            // 白雜訊 σ
    var driftPpm: Double         // 麥克風實際取樣率偏差
    var micLatMs: Double         // 麥克風本身延遲（對所有輸出相同）
    var mapErrMs: Double         // 粗略對應的誤差（傳送抖動造成的錨點誤差）
    var offsetsMs: [Double]      // --verify：套用的補償
    var seed: UInt64
    /// 麥克風時間軸蜿蜒（時鐘緩慢漂移／傳送端重取樣）峰值 ms：w(t) = A·(0.6 sin(2πt/31+0.7) + 0.4 sin(2πt/53+2.1))
    var wanderMs: Double = 0
    /// 每個 chirp 獨立的樣本跳動（均勻 ±slipMs）——模擬傳送端丟／補樣本
    var slipMs: Double = 0
    var micRate: Double = 48000
    var profile: CalProfile = .standard
    var ref: Int = 0
    /// nil = 除了 ref 以外全部
    var measured: [Int]? = nil
    /// 每個輸出自訂反射（延遲秒, 振幅倍率）；nil = 預設兩道弱反射
    var reflections: [Int: [(Double, Double)]] = [:]
}

/// 產生一段合成錄音：每個 chirp 以真實分數延遲解析產生（無內插誤差）＋兩道反射＋白雜訊＋時間軸蜿蜒／跳動
private func synthesize(_ sc: SynthScenario, plan: [PlannedChirp], engineRate: Double, micRate: Double) -> [Float] {
    let trueRate = micRate * (1 + sc.driftPpm * 1e-6)
    let last = plan.last!
    let lenSec = Double(last.sched + last.startOffset) / engineRate + 1.5 + sc.micLatMs / 1000
    let n = Int(lenSec * trueRate)
    var rec = [Float](repeating: 0, count: n)
    var rng = SynthRNG(s: sc.seed)
    for k in 0..<n { rec[k] = Float(sc.noise * rng.gauss()) }
    let refl: [(Double, Double)] = [(0, 1), (3.1e-3, 0.4), (11.7e-3, -0.2)]
    let chirpLen = CalParams.chirpSeconds
    func warp(_ t: Double) -> Double {
        sc.wanderMs / 1000 * (0.6 * sin(2 * Double.pi * t / 31 + 0.7) + 0.4 * sin(2 * Double.pi * t / 53 + 2.1))
    }
    for c in plan {
        let t0 = Double(c.sched + c.startOffset) / engineRate + (sc.latMs[c.output] + sc.micLatMs) / 1000
        let slip = sc.slipMs > 0 ? (rng.next() * 2 - 1) * sc.slipMs / 1000 : 0
        for (dt, g) in sc.reflections[c.output] ?? refl {
            let tt = t0 + dt
            let start = (tt + warp(tt) + slip) * trueRate
            let a = Int(start.rounded(.up)), b = min(n - 1, Int((start + chirpLen * trueRate).rounded(.down)))
            guard a <= b else { continue }
            for k in a...b {
                let (s, _) = calChirpValue((Double(k) - start) / trueRate)
                rec[k] += Float(sc.amps[c.output] * g * s)
            }
        }
    }
    return rec
}

func runCalibrationSelfTest() -> Int32 {
    print("== 校正演算法自測（合成訊號，不出聲、不開麥克風）==")
    let er = 48000.0
    let names = ["內建(模擬)", "HDMI(模擬)", "電視(模擬)"]
    var allOK = true
    func check(_ ok: Bool, _ msg: String) {
        print("  \(ok ? "✓" : "✗") \(msg)")
        if !ok { allOK = false }
    }
    func run(_ sc: SynthScenario) -> (CalAnalysis, Double) {
        let mr = sc.micRate
        let offs = sc.offsetsMs.map { Int64(($0 / 1000 * er).rounded()) }
        let maxOff = sc.offsetsMs.max() ?? 0
        let interval = Int64(((CalParams.intervalMs + maxOff) / 1000 * er).rounded())
        let base = Int64(sc.profile.preRollMs / 1000 * er)
        let measured = sc.measured ?? (0..<sc.latMs.count).filter { $0 != sc.ref }
        let plan = buildPlan(ref: sc.ref, measured: measured, base: base, intervalFrames: interval,
                             rounds: sc.profile.rounds, offsets: offs, interleave: sc.profile.interleave)
        let rec = synthesize(sc, plan: plan, engineRate: er, micRate: mr)
        let map = RoughMap(anchorEngine: 0, anchorMic: sc.mapErrMs / 1000 * mr, ratio: mr / er)
        let t = Date()
        let an = analyzeCalibration(rec: rec, micRate: mr, engineRate: er, plan: plan, map: map,
                                    nOutputs: sc.latMs.count, ref: sc.ref, names: names, profile: sc.profile)
        return (an, Date().timeIntervalSince(t))
    }
    /// 延遲誤差檢查：回傳最大誤差（用中位數＝實際寫入的值，另外列各輪最大誤差）
    func checkLatency(_ sc: SynthScenario, _ an: CalAnalysis, tol: Double, perRound: Bool) -> Double {
        var worst = 0.0
        let measured = sc.measured ?? (0..<sc.latMs.count).filter { $0 != sc.ref }
        for o in [sc.ref] + measured {
            let truth = sc.latMs[o] - sc.latMs[sc.ref]
            let r = an.outputs[o]
            let medErr = abs(r.medLatMs - truth)
            let roundErr = r.used.map { abs($0 - truth) }.max() ?? .infinity
            let err = perRound ? roundErr : medErr
            worst = max(worst, err.isNaN ? .infinity : err)
            check(err < tol, String(format: "%@ 相對延遲 真值 %.4f ms，各輪 %@%@，中位數誤差 %.4f ms，各輪最大誤差 %.4f ms，SNR %.1f dB",
                                    names[o], truth, r.latMs.map { String(format: "%.4f", $0) }.joined(separator: "/"),
                                    r.rejected > 0 ? "（剔除 \(r.rejected)）" : "", medErr, roundErr, r.minSnrDb))
        }
        return worst
    }

    // 1. 延遲量測（標準麥克風）：多組分數延遲、時鐘漂移、粗略對應誤差
    let cases: [SynthScenario] = [
        .init(name: "A 典型", latMs: [12.345, 57.891, 243.217], amps: [0.05, 0.02, 0.1], noise: 0.002,
              driftPpm: 60, micLatMs: 7.3, mapErrMs: 15, offsetsMs: [0, 0, 0], seed: 1),
        .init(name: "B 負漂移＋電視 300ms", latMs: [3.01, 40.52, 300.77], amps: [0.03, 0.01, 0.04], noise: 0.003,
              driftPpm: -95, micLatMs: 21.9, mapErrMs: -30, offsetsMs: [0, 0, 0], seed: 7),
        .init(name: "C 高雜訊", latMs: [9.999, 10.4321, 150.0001], amps: [0.01, 0.006, 0.02], noise: 0.01,
              driftPpm: 20, micLatMs: 2.2, mapErrMs: 5, offsetsMs: [0, 0, 0], seed: 42),
    ]
    var worstErr = 0.0
    for sc in cases {
        let (an, dt) = run(sc)
        print("[\(sc.name)] 分析耗時 \(String(format: "%.2f", dt)) s，漂移估計 \(an.driftPpm.map { String(format: "%.1f", $0) }) ppm（真值 \(sc.driftPpm)）")
        check(an.errors.isEmpty, "無錯誤\(an.errors.isEmpty ? "" : "：\(an.errors)")")
        worstErr = max(worstErr, checkLatency(sc, an, tol: 0.05, perRound: true))
        // 響度：與振幅比一致（±0.5 dB）
        let lv = an.outputs.map(\.medLevelDb)
        for o in 1..<sc.latMs.count {
            let truth = 20 * log10(sc.amps[o] / sc.amps[0])
            let got = lv[o] - lv[0]
            check(abs(got - truth) < 0.5, String(format: "%@ 響度差 真值 %.2f dB，量到 %.2f dB", names[o], truth, got))
        }
        let trims = levelTrims(lv)
        check(trims.allSatisfy { $0 <= 0 && $0 >= -CalParams.maxTrimCutDb } && trims.contains { abs($0) < 1e-9 },
              "trim 只衰減、最小聲那台為 0、最多 −12 dB：\(trims.map { String(format: "%.2f", $0) })")
    }
    check(worstErr < 0.05, String(format: "標準麥克風延遲最大誤差 %.4f ms < 0.05 ms", worstErr))

    // 2. 補償後驗證：把算出的補償套回去，殘差應 < 取樣量化（0.5 樣本 ≈ 0.0104 ms）+ 0.05
    do {
        let lat = [12.345, 57.891, 243.217]
        let comp = compensationDelays(lat.map { $0 - lat[0] })
        let sc = SynthScenario(name: "D 驗證", latMs: lat, amps: [0.05, 0.02, 0.1], noise: 0.002, driftPpm: 60,
                               micLatMs: 7.3, mapErrMs: 15, offsetsMs: comp, seed: 3)
        let (an, _) = run(sc)
        let m = an.outputs.map(\.medLatMs)
        let anchor = comp.firstIndex(of: comp.min()!)!
        let resid = m.map { $0 - m[anchor] }
        check(an.errors.isEmpty && resid.allSatisfy { abs($0) < 0.0104 + 0.05 },
              "[D 驗證] 套用補償 \(comp.map { String(format: "%.2f", $0) }) ms 後殘差 \(resid.map { String(format: "%+.4f", $0) }) ms")
    }

    // 3. 音量太小：必須回報 SNR 不足
    do {
        let sc = SynthScenario(name: "E 太小聲", latMs: [5, 50, 200], amps: [0.05, 0.00001, 0.05], noise: 0.01, driftPpm: 0,
                               micLatMs: 5, mapErrMs: 0, offsetsMs: [0, 0, 0], seed: 9)
        let (an, _) = run(sc)
        let hit = an.errors.contains { $0.contains(names[1]) && $0.contains("SNR") }
        check(hit, "[E 太小聲] 回報 SNR 不足：\(an.errors.first ?? "（沒有錯誤！）")")
    }

    // 4. Continuity（iPhone）模擬：麥克風延遲 150 ms、抖動 ±2 ms，高延遲參數（交錯參考、5 輪、剔除離群）
    //    抖動模型：(a) 傳送抖動 → 粗略對應錨點誤差 ±2 ms；(b) 麥克風時間軸蜿蜒峰值 ±2 ms（週期 31 s／53 s 疊加）
    //    驗收：寫入值（中位數）相對延遲誤差 < 0.1 ms
    var contWorst = 0.0
    let contCases: [SynthScenario] = [
        .init(name: "F Continuity 48k（延遲 150ms、錨點 +2ms、蜿蜒 ±2ms）", latMs: [8.0, 9.26, 42.46], amps: [0.03, 0.02, 0.04],
              noise: 0.003, driftPpm: 180, micLatMs: 150, mapErrMs: 2.0, offsetsMs: [0, 0, 0], seed: 11,
              wanderMs: 2.0, profile: .highLatency),
        .init(name: "G Continuity 24k（延遲 150ms、錨點 −2ms、蜿蜒 ±2ms、漂移 −350ppm）", latMs: [8.0, 9.26, 42.46], amps: [0.03, 0.02, 0.04],
              noise: 0.003, driftPpm: -350, micLatMs: 150, mapErrMs: -2.0, offsetsMs: [0, 0, 0], seed: 12,
              wanderMs: 2.0, micRate: 24000, profile: .highLatency),
        .init(name: "H 麥克風延遲 700ms＋電視 243ms（超過舊搜尋窗 850ms，靠自適應平移）", latMs: [12.345, 57.891, 243.217],
              amps: [0.05, 0.02, 0.1], noise: 0.002, driftPpm: 60, micLatMs: 700, mapErrMs: 1.5, offsetsMs: [0, 0, 0], seed: 13,
              wanderMs: 2.0, profile: .highLatency),
    ]
    for sc in contCases {
        let (an, dt) = run(sc)
        print(String(format: "[%@] 分析耗時 %.2f s，麥克風路徑 %.1f ms、搜尋窗平移 %.1f ms，漂移估計 %@ ppm（真值 %.0f）", sc.name, dt,
                     an.micPathMs ?? .nan, an.searchShiftMs, an.driftPpm.map { String(format: "%.1f", $0) }.joined(separator: "/"), sc.driftPpm))
        check(an.errors.isEmpty, "無錯誤\(an.errors.isEmpty ? "" : "：\(an.errors)")")
        contWorst = max(contWorst, checkLatency(sc, an, tol: 0.1, perRound: false))
    }
    check(contWorst < 0.1, String(format: "Continuity 模擬（150 ms、±2 ms 抖動）相對延遲最大誤差 %.4f ms < 0.1 ms", contWorst))

    // 4b. 對照：同樣的蜿蜒用標準參數（不交錯、3 輪）——只列出，不判定（說明為什麼 Continuity 要換參數）
    do {
        var sc = contCases[0]
        sc.name = "F′ 對照：標準參數"
        sc.profile = .standard
        sc.seed = 21
        let (an, _) = run(sc)
        let e = (1..<3).map { abs(an.outputs[$0].medLatMs - (sc.latMs[$0] - sc.latMs[0])) }.max() ?? .nan
        print(String(format: "  · [F′ 對照] 標準參數在同樣蜿蜒下的最大誤差 %.4f ms（錯誤 %d 項；僅供參考）", e, an.errors.count))
    }

    // 5. 每個 chirp 獨立跳 ±2 ms（丟／補樣本）：不可以寫出錯的值——要嘛報錯，要嘛誤差 < 0.25 ms
    do {
        let sc = SynthScenario(name: "I 逐 chirp 跳動 ±2ms", latMs: [8.0, 9.26, 42.46], amps: [0.03, 0.02, 0.04], noise: 0.003,
                               driftPpm: 100, micLatMs: 150, mapErrMs: 2, offsetsMs: [0, 0, 0], seed: 14,
                               wanderMs: 0, slipMs: 2.0, profile: .highLatency)
        let (an, _) = run(sc)
        let e = (1..<3).map { abs(an.outputs[$0].medLatMs - (sc.latMs[$0] - sc.latMs[0])) }.max() ?? .infinity
        check(!an.errors.isEmpty || e < 0.25,
              String(format: "[I 逐 chirp 跳動] %@（最大誤差 %.3f ms）", an.errors.isEmpty ? "未報錯" : "報錯不寫檔：\(an.errors.first!)", e))
    }

    // 6. 驗證只量出聲的裝置（遊戲模式：電視不出聲）＋參考不是 index 0（主時鐘不出聲時）
    do {
        let lat = [12.345, 13.605, 46.805]
        let sc = SynthScenario(name: "J 只驗證出聲裝置", latMs: lat, amps: [0.05, 0.02, 0.1], noise: 0.002, driftPpm: 40,
                               micLatMs: 150, mapErrMs: 1.0, offsetsMs: [1.26, 0, 0], seed: 15,
                               wanderMs: 1.0, profile: .highLatency, ref: 1, measured: [0])
        let (an, _) = run(sc)
        let resid = an.outputs[0].medLatMs - an.outputs[1].medLatMs
        check(an.errors.isEmpty && an.outputs[2].latMs.isEmpty && abs(resid) < 0.1,
              String(format: "[J] 參考=HDMI、只量內建：殘差 %+.4f ms、電視沒被量（%d 輪）、錯誤 %d 項", resid, an.outputs[2].latMs.count, an.errors.count))
    }

    // 6b. 反射比直達聲強（實機：內建喇叭 +4.1 ms 的反射只比直達聲弱 0.9 dB，chirp 包絡可能更強）→ 要取最早到達
    do {
        let lat = [0.0, 2.16, 34.71]
        let sc = SynthScenario(name: "K 內建反射比直達聲強", latMs: lat, amps: [0.03, 0.02, 0.04], noise: 0.002, driftPpm: -18,
                               micLatMs: 45, mapErrMs: 3, offsetsMs: [0, 0, 0], seed: 16,
                               reflections: [0: [(0, 1), (4.1e-3, 1.25), (8.0e-3, 0.7)]])
        let (an, _) = run(sc)
        let e = (1..<3).map { abs(an.outputs[$0].medLatMs - (lat[$0] - lat[0])) }.max() ?? .infinity
        check(an.errors.isEmpty && e < 0.1, String(format: "[K] 反射 +4.1 ms 比直達聲強 1.9 dB：取最早到達，最大誤差 %.3f ms（錯誤 %d 項）", e, an.errors.count))
    }

    for (k, (g, noise, seed)) in [(1.6, 0.002, UInt64(17)), (1.9, 0.006, UInt64(18))].enumerated() {
        let lat = [0.0, 2.16, 34.71]
        let sc = SynthScenario(name: "K\(k + 2)", latMs: lat, amps: [0.02, 0.01, 0.015], noise: noise, driftPpm: -18,
                               micLatMs: 45, mapErrMs: 3, offsetsMs: [0, 0, 0], seed: seed,
                               reflections: [0: [(0, 1), (4.1e-3, g), (8.0e-3, 0.9)], 2: [(0, 1), (8.6e-3, 0.8)]])
        let (an, _) = run(sc)
        let e = (1..<3).map { abs(an.outputs[$0].medLatMs - (lat[$0] - lat[0])) }.max() ?? .infinity
        check(an.errors.isEmpty && e < 0.1, String(format: "[K%d] 反射 +4.1 ms 是直達聲的 %.1f 倍、雜訊 σ=%.3f：最大誤差 %.3f ms（錯誤 %@）",
                                                   k + 2, g, noise, e, an.errors.description))
    }

    // 7. 純函式
    check(zip(compensationDelays([0, 45.5, 230.9]), [230.9, 185.4, 0]).allSatisfy { abs($0 - $1) < 1e-9 }, "compensationDelays = max − lat")
    check(levelTrims([-20, -26, -45]) == [-12, -12, 0] && levelTrims([-20, -23, -21]) == [-3, 0, -2], "levelTrims 只衰減、夾 −12 dB")
    check(median([3, 1, 2]) == 2, "median")
    do {
        let p1 = buildPlan(ref: 0, measured: [1, 2], base: 0, intervalFrames: 10, rounds: 2, offsets: [0, 0, 0], interleave: false)
        let p2 = buildPlan(ref: 0, measured: [1, 2], base: 0, intervalFrames: 10, rounds: 2, offsets: [0, 0, 0], interleave: true)
        check(p1.map(\.output) == [0, 1, 2, 0, 0, 1, 2, 0] && p2.map(\.output) == [0, 1, 0, 2, 0, 0, 1, 0, 2, 0]
              && CalProfile.standard.chirpsPerRound(measured: 2) == 4 && CalProfile.highLatency.chirpsPerRound(measured: 2) == 5,
              "buildPlan：標準 [ref,A,B,ref]、交錯 [ref,A,ref,B,ref]")
    }
    do {   // 寫入：measuredLatencyMs 相對最快、delayMs 由 plan() 依模式算
        let b = "BuiltInSpeakerDevice", msi = "3669B030-0000-0000-1B21-010380341E78", tv = "40C88240-0000-0000-151D-010380593278"
        let devs = [(uid: b, name: "內建", isBuiltIn: true), (uid: msi, name: "MSI", isBuiltIn: false), (uid: tv, name: "電視", isBuiltIn: false)]
        let rel = [b: 0.0, msi: 1.26, tv: 34.46]
        let (cg, pg) = applyCalibrationResult(to: Config(), measuredRel: rel, trims: nil, mode: .game, devices: devs)
        let (cm, _) = applyCalibrationResult(to: Config(), measuredRel: rel, trims: [msi: -3.04], mode: .music, devices: devs)
        check(cg.devices[tv]?.measuredLatencyMs == 34.46 && cg.devices[msi]?.measuredLatencyMs == 1.26
              && cg.devices[b]?.delayMs == 1.26 && cg.devices[msi]?.delayMs == 0 && cg.devices[tv]?.delayMs == 0 && pg[tv]?.active == false,
              "遊戲模式寫入：內建 1.26／MSI 0／電視 0（不出聲），measuredLatencyMs 照實測")
        check(cm.devices[b]?.delayMs == 34.46 && cm.devices[msi]?.delayMs == 33.2 && cm.devices[tv]?.delayMs == 0
              && cm.devices[msi]?.trimDb == -3.0 && cm.devices[b]?.trimDb == 0,
              "音樂模式寫入：34.46／33.20／0、trim 取到 0.1 dB")
    }
    do {   // 麥克風選擇（純函式）
        let mics = [
            CalibrationMic(uid: "AppleUSBAudioEngine:C270", name: "C270 HD WEBCAM", kind: .usb, sampleRate: 48000, channels: 1, isContinuity: false, isAutomaticChoice: true),
            CalibrationMic(uid: "iPhone-mic-uid", name: "Kang的iPhone 麥克風", kind: .continuity, sampleRate: 48000, channels: 1, isContinuity: true, isAutomaticChoice: false),
            CalibrationMic(uid: "BuiltInMicrophoneDevice", name: "Mac mini 麥克風", kind: .builtIn, sampleRate: 48000, channels: 1, isContinuity: false, isAutomaticChoice: false),
            CalibrationMic(uid: "GLASS5:input", name: "GLASS5+", kind: .bluetooth, sampleRate: 8000, channels: 1, isContinuity: false, isAutomaticChoice: false),
        ]
        func pick(_ q: String) -> String? { if case .success(let m) = matchCalibrationMic(q, in: mics) { return m.uid }; return nil }
        check(pick("iPhone-mic-uid") == "iPhone-mic-uid" && pick("iphone") == "iPhone-mic-uid" && pick("c270") == "AppleUSBAudioEngine:C270"
              && pick("麥克風") == nil && pick("不存在") == nil,
              "matchCalibrationMic：UID、名稱子字串（不分大小寫）、多筆相符與找不到都報錯")
        var cfg = Config()
        check(defaultCalibrationMic(config: cfg, in: mics)?.uid == "AppleUSBAudioEngine:C270", "預設：未設定 → C270（自動選擇）")
        cfg.calibrationMicUID = "iPhone-mic-uid"
        check(defaultCalibrationMic(config: cfg, in: mics)?.uid == "iPhone-mic-uid", "預設：config.calibrationMicUID 優先")
        check(mics[1].profile == .highLatency && mics[3].profile == .highLatency && mics[0].profile == .standard
              && mics[1].caution != nil && mics[3].caution != nil && mics[0].caution == nil && mics[1].kindLabel == "iPhone（Continuity）",
              "Continuity／藍牙輸入 → 高延遲參數＋面板警告；C270 → 標準")
        // 藍牙輸入一律不可用（唯讀：只列裝置屬性，不開任何麥克風）
        let btIn = Devices.all().filter { $0.hasInput && $0.kind.isBluetooth }
        let listed = availableCalibrationMics()
        check(btIn.allSatisfy { !Devices.isUsableMicrophone($0) } && !listed.contains { $0.kind.isBluetooth }
              && !(Devices.microphone()?.kind.isBluetooth ?? false),
              "藍牙麥克風不列入、不會被自動選到（目前 \(btIn.count) 支藍牙輸入：\(btIn.map(\.name).joined(separator: "、"))）")
        var refused = true
        for b in btIn {
            for q in [b.uid, b.name] {
                if case .success = resolveCalibrationMic(query: q, config: Config()) { refused = false }
            }
            var c2 = Config(); c2.calibrationMicUID = b.uid
            if case .success = resolveCalibrationMic(query: nil, config: c2) { refused = false }
            if resolveCalibrationMic(uid: b.uid) != nil { refused = false }
        }
        check(refused, "明確指定藍牙麥克風（UID／名稱／設定值）一律拒絕")
        let onlyC270 = [CalibrationMic(uid: "AppleUSBAudioEngine:C270", name: "C270 HD WEBCAM", kind: .usb, sampleRate: 48000, channels: 1, isContinuity: false, isAutomaticChoice: true)]
        check(bluetoothMicMatching("c270", bluetoothInputs: btIn, usable: onlyC270) == nil, "--mic c270 不會被誤判成藍牙")
    }

    print(allOK ? "✓ 自測全部通過" : "✗ 自測有失敗項目")
    return allOK ? 0 : 1
}
