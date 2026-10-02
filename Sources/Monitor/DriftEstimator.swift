// DriftEstimator.swift — 背景監聽（第 B 輪）的純運算核心：用「節目音」當參考，從校正麥克風的錄音估出每台喇叭的相對到達誤差。
//
// 不碰 CoreAudio、不開麥克風、不存檔：輸入是呼叫端已經在記憶體裡的樣本與時間戳，輸出是數字。見 Sources/Monitor/README.md。
//
// 方法（為什麼這樣做；每一條都有對應的自測，見 MonitorSelfTest.swift）：
//   * 參考訊號 = ProgramRing 的節目音（未延遲、未乘增益；立體聲請先混成單聲道）。每台喇叭放的都是同一個節目音，
//     麥克風收到的是「各台脈衝響應 × 節目音」的和。
//   * 時鐘：麥克風與引擎是不同的時鐘（10 秒內差數十 ppm）。兩邊的 (sample, hostTime) 各擬合一條直線，
//     合成「節目音樣本 e → 麥克風 index」= A + B·e，用窗化 sinc 把節目音重取樣到麥克風的取樣格上（取樣率不同也適用）。
//     剩下的線性漂移（沒有時間戳、或藍牙自己在漂）用「未探測」的約 1 秒區塊互比相位估出來，在頻域逐段拉回。
//   * 粗定位：1–4 kHz GCC-PHAT（包絡）在寬範圍（預設 −50…1200 ms）找「群集」（所有喇叭合起來）的到達時間 τc。
//   * 細分析（Welch）：參考與麥克風（延後 τc）各取 170 ms、Hann、50% 重疊，每段算互功率譜 C = M·conj(X)、P = |X|²，
//     依該段節目音內容落在哪個「探測狀態」分組（斜坡與前後 guard 內的段不用）。
//   * 分離各台（探測差分法）：呼叫端輪流對單一裝置加小的探測偏移 p（+3／+4 ms、0.5 s 斜坡）。每個頻率 bin 的模型
//         C_s ≈ P_s · (R + Σ_k A_k · e^{−jω·p_{k,s}})
//     A_k = 被探測那台的轉移函數（含延遲），R = 其他裝置合起來。每個 bin 解小的加權最小平方（Σ_s P_s φ*φᵀ θ = Σ_s φ* C_s），
//     同時得到共變異 M⁻¹ → 每個 bin 的 SNR（另加「模型失配」項，壓住 e^{−jωp} − 1 ≈ 0 附近被放大的殘差）。
//     差分把群集抵消掉：R、群集的反射（4.1 ms 那種）在各狀態都一樣，只剩被探測那台。
//     每台用自己的子模型：未知數 = 這台（＋它是參考裝置時，同一輪也被探測的非參考裝置，例如藍牙）＋ R；
//     其他參考裝置正在探測的段不用。
//   * 曲線：SNR 加權的 PHAT（只留相位 × SNR/(1+SNR)，頻帶邊緣升餘弦）→ 解析訊號反 FFT → 包絡（1–4 kHz 群延遲，
//     與 calibrate --pulse 的「到達時間」同一個定義）。峰值取「最早到達」：≥ 0.6 × 最大值的第一個局部峰（反射比直達晚）。
//     參考曲線（R）改用「全部的和」的權重，而且只接受「和」也有峰的位置（R 自己的權重是梳子 → ±p 假峰）。
//   * 誤差 = 這台的到達 − 參考（R）的到達（ms；正 = 這台晚到）。
//   * 可採信（trusted）＝ issues 為空：探測資料夠（兩種偏移 ≥ 0.7 秒；單一偏移 ≥ 1.5 秒）、兩條曲線峰值比早到區（純雜訊）
//     高 ≥ 10 dB、沒有「更早的峰」或「後面更高的峰」（長音類節目音的曲線是多峰）、奇偶兩半誤差差 ≤ 0.25 ms、
//     不在 ±15 ms 搜尋窗邊緣、單一偏移時不剛好落在 ±p／±2p（假峰位置）。任何一條不成立就回報「不可採信」與原因，不給錯值。
import Accelerate
import Foundation

// MARK: - 輸入

/// 一個時鐘對應點：sample（該時鐘的樣本位置）↔ hostSeconds（mach host time 換成秒；兩邊要用同一種換算）
struct MonitorClockPoint: Equatable {
    var sample: Double
    var hostSeconds: Double
}

/// 探測偏移排程的一段（以「節目音內容」表示，engine sampleTime）：
/// 內容 [fullStart, fullEnd) 這段被 device 以「補償 + offsetMs」播出（偏移已完全到位）；
/// 前後各有 rampMs 的斜坡（內容上約等長），斜坡與 guard 範圍內的段不採用。
/// 用 `MonitorProbe.fromOutputTimes` 由 Engine.setProbeOffset 的呼叫時刻換算。
struct MonitorProbe: Equatable {
    var device: Int
    var fullStart: Int64
    var fullEnd: Int64
    var offsetMs: Double
    var rampMs: Double = 500

    /// 由「輸出時刻」換算：setAt = 呼叫 setProbeOffset(ms) 時的 engine sampleTime（斜坡開始），
    /// clearAt = 呼叫 setProbeOffset(0)（或 clearProbeOffsets）時的 engine sampleTime；
    /// baseDelayFrames = 這台目前的補償延遲（plan 的 delay，engine frame；藍牙另加 BluetoothOut 的 safety）。
    /// 輸出時刻 T 播的內容 = T − 補償 − 探測。誤差幾 ms 沒關係（guard 會吸收）。
    static func fromOutputTimes(device: Int, setAt: Int64, clearAt: Int64, offsetMs: Double, rampSeconds: Double,
                                engineRate: Double, baseDelayFrames: Int) -> MonitorProbe {
        let off = Int64((offsetMs / 1000 * engineRate).rounded())
        let ramp = Int64((rampSeconds * engineRate).rounded())
        return MonitorProbe(device: device, fullStart: setAt + ramp - Int64(baseDelayFrames) - off,
                            fullEnd: clearAt - Int64(baseDelayFrames) - off, offsetMs: offsetMs,
                            rampMs: rampSeconds * 1000 + abs(offsetMs))
    }
}

/// 一次監聽的全部輸入（都在記憶體裡；呼叫端算完就丟）
struct MonitorCapture {
    /// 麥克風錄音（單聲道；多聲道請先平均）
    var mic: [Float]
    var micRate: Double
    /// 麥克風時鐘：sample = mic 陣列的 index（第 0 個樣本 = 0），hostSeconds = 該樣本的擷取時刻（input IOProc 的 inputTime）。
    /// 每個 IO buffer 記一點就好（10 秒約 1000 點）；空 = 沒有時間戳（退回標稱比例＋漂移估計）
    var micClock: [MonitorClockPoint]
    /// 節目音（ProgramRing 的 L+R 平均，單聲道），program[0] 的 engine sampleTime = programStart。
    /// 範圍要涵蓋 [麥克風開始 − 最大到達延遲（藍牙約 0.5 s）− 0.2 s, 麥克風結束]（ProgramRing 只留 2.7 秒，呼叫端要每 ≤ 1 秒搬一次）
    var program: [Float]
    var programRate: Double
    var programStart: Int64
    /// 引擎時鐘：sample = engine sampleTime，hostSeconds = 該 frame 在延遲 0 的輸出播出的時刻（ProgramRing.clock()）
    var programClock: [MonitorClockPoint]
    /// 裝置數（device index 0..<deviceCount；只有出現在 probes 裡的會被個別估計）
    var deviceCount: Int
    var probes: [MonitorProbe]
    /// 「準時」的定義：誤差 = 這台 − 這些裝置（被探測的才分得出來；沒被探測的裝置一律算在參考裡）。
    /// 建議填有線裝置（同一個聚合裝置、同一個時鐘，彼此不漂）；空 = 其他全部裝置。
    /// 例：同一輪也探測了藍牙時，有線裝置的參考就不含藍牙（藍牙若差 1.5 ms 不會把有線裝置拖成 −1.5）
    var referenceDevices: [Int] = []
}

// MARK: - 參數

struct MonitorParams {
    var bandLo = 1000.0
    var bandHi = 4000.0
    /// 頻帶邊緣升餘弦寬度（Hz）
    var bandTaperHz = 150.0
    /// 粗定位的段長（秒；取 2 的次方個樣本，48 kHz → 4096）
    var segmentSeconds = 0.085
    /// 粗定位的延遲搜尋範圍（ms，相對「延遲 0 輸出」的時刻；藍牙補償約 430 ms → 群集約在 430＋麥克風延遲）
    var lagMinMs = -50.0
    var lagMaxMs = 1200.0
    /// 粗定位最多用幾段（平均分佈）；只是找群集，不需要全部
    var coarseMaxSegments = 40
    /// 細分析（Welch）窗長（秒；取 2 的次方個樣本，48 kHz → 8192 ≈ 170 ms），50% 重疊
    var welchSeconds = 0.17
    /// 模型失配（各探測狀態之間群集不完全相同：節目內容、藍牙自己的漂移…）占群集的比例。
    /// 當作額外雜訊（κ²·|群集|²·|X|²）放進每個 bin 的 SNR：e^{−jωp} − 1 接近 0 的 bin 會把失配放大成 ±p 的假峰，這裡把它們壓下去
    var mismatchFraction = 0.25
    /// 每台的到達時間只在群集 ± searchMs 內找；超過就是「量不到」（大偏移 → 需要重新校正）
    var searchMs = 15.0
    /// 早到區（群集 − Welch 半窗 … 群集 − noiseGapMs）當作雜訊參考：物理上不可能有聲音比群集早 20 ms 以上到
    var noiseGapMs = 20.0
    /// 探測斜坡前後再多排除的內容（ms）：涵蓋呼叫端換算誤差、engine 套用延遲的一個 IO 週期
    var transitionGuardMs = 50.0
    var minSnrDb = 10.0
    var coarseMinSnrDb = 8.0
    /// 搜尋窗內「比採用的峰早」的局部峰 ≥ 這個比例 × 採用的峰 → 模稜兩可（不採信）。
    /// 比它晚的峰不算（反射）；長音類節目音的曲線是週期性多峰，早的那側一樣會有高峰
    var ambiguityRatio = 0.6
    /// 「最早到達」：≥ 這個比例 × 最大值的第一個局部峰（群集＝全部的和）
    var earliestFraction = 0.6
    /// 被探測那台的曲線
    var deviceEarliestFraction = 0.6
    /// 參考曲線；候選峰另外必須也是「全部的和」的峰（≥ clusterMatchFraction × 和的最大值、±clusterMatchMs 內）
    var referenceEarliestFraction = 0.6
    /// 被探測那台：採用的峰 < 這個比例 × 窗內最大值 → 模稜兩可
    var laterPeakRatio = 0.85
    /// 參考曲線：比採用的峰早（且在和裡）的峰 ≥ 這個比例 → 模稜兩可
    var referenceEarlierRatio = 0.4
    /// 參考曲線用「全部的和」的 SNR 權重（見 DriftSolution.envelope）
    var referenceSumWeights = true
    var clusterMatchFraction = 0.2
    var clusterMatchMs = 0.25
    /// 只用單一探測偏移 p 時，誤差落在 ±p、±2p 的這個範圍內 → 不採信（假峰）
    var probeImageToleranceMs = 0.6
    /// 奇數段／偶數段各自估的誤差差上限（ms）
    var maxHalfDiffMs = 0.25
    /// 每台探測資料（完全到位、扣掉 guard 的段）至少幾秒
    var minProbeSeconds = 0.7
    /// 同一輪只用一種偏移時的下限（秒）
    var minProbeSecondsSingleOffset = 1.5
    /// 節目音整體 RMS 下限（dBFS）
    var minProgramDbFS = -60.0
    /// 節目音 1–4 kHz RMS 下限（dBFS）
    var minBandDbFS = -58.0
    /// 1–4 kHz 占整體功率的下限（dB）
    var minBandFractionDb = -35.0
    /// 麥克風 |x| ≥ 0.99 的樣本比例上限
    var maxClipFraction = 0.001
    /// SNR（每 bin）在頻率上平滑的半寬（Hz）
    var snrSmoothHz = 30.0
    /// 除錯：每條包絡曲線（名稱、曲線、群集在曲線上的 index、麥克風取樣率）；nil = 不輸出
    var debugSink: ((String, [Float], Int, Double) -> Void)? = nil
}

// MARK: - 輸出

enum MonitorSkip: String {
    case tooShort = "錄音或節目音太短"
    case programTooQuiet = "節目音太小"
    case bandEnergyTooLow = "節目音 1–4 kHz 能量不足"
    case micSilent = "麥克風沒有訊號"
    case micClipping = "麥克風削波"
    case noOverlap = "節目音與錄音時間對不上"
    case clusterNotFound = "麥克風聽不到節目音（找不到群集）"
}

enum MonitorDeviceIssue: String {
    case notProbed = "這輪沒有探測"
    case probeTooShort = "探測資料不足"
    case lowSnr = "量不到（峰值不夠高）"
    case referenceLowSnr = "其他裝置的參考峰不夠高"
    case ambiguous = "多峰模稜兩可（節目音頻譜太窄？）"
    case weakerThanLater = "採用的峰比後面的峰低很多"
    case referenceAmbiguous = "參考曲線有更早的峰（反射比直達高？）"
    case inconsistent = "奇偶兩半不一致"
    case atSearchEdge = "峰在搜尋窗邊緣（偏移太大？）"
    case clockUnknown = "沒有時間戳且估不出漂移"
    case nearProbeImage = "誤差剛好在 ±探測偏移附近（可能是假峰）"
}

struct MonitorDeviceEstimate: Equatable {
    var device: Int
    var probed = false
    /// 這台完全到位的探測資料（秒）；各段的探測偏移（ms，去重）
    var probeSeconds = 0.0
    var probeOffsetsMs: [Double] = []
    /// 到達時間（ms，相對「延遲 0 輸出」時刻，麥克風時間）：這台、以及參考（R：沒被探測的＋referenceDevices 裡的其他台）
    var arrivalMs: Double?
    var referenceMs: Double?
    /// 相對到達誤差（ms）= arrival − reference；正 = 這台晚到（Engine.adjustLatencyCorrection(byMs: +errorMs)）
    var errorMs: Double?
    /// 峰值比早到區最大值（dB）：這台／參考
    var snrDb: Double?
    var referenceSnrDb: Double?
    /// 採用的峰對「比它早」的最大局部峰（dB；參考與這台取較小者）
    var psrDb: Double?
    /// 奇數段／偶數段的誤差差（ms）
    var halfDiffMs: Double?
    var trusted = false
    var issues: [MonitorDeviceIssue] = []

    /// 「量不到」類（可能偏移太大或這台沒聲音）：用來累計「需要重新校正」；模稜兩可／不一致是節目音不適合，不算
    var looksMissing: Bool { probed && (issues.contains(.lowSnr) || issues.contains(.atSearchEdge)) && !issues.contains(.referenceLowSnr) }
}

struct MonitorPeak: Equatable {
    var offsetMs: Double    // 相對主峰
    var relative: Double    // 相對主峰高度
}

struct MonitorCluster: Equatable {
    /// 群集到達時間（ms，相對延遲 0 輸出；「全部裝置的和」、未探測狀態）
    var lagMs = 0.0
    var snrDb = 0.0
    /// 主峰 ± searchMs 內 ≥ 0.4 倍的局部峰
    var peaks: [MonitorPeak] = []
    /// 單一峰：主峰前 searchMs 到後 2.5 ms 內（反射通常更晚）沒有 ≥ 0.5 倍的其他峰
    var single = true
}

struct MonitorResult {
    var skip: MonitorSkip?
    var cluster: MonitorCluster?
    var devices: [MonitorDeviceEstimate] = []
    /// 節目音整體／1–4 kHz RMS（dBFS）、1–4 kHz 有效頻寬（Hz，功率譜的參與比）
    var programDbFS = -200.0
    var programBandDbFS = -200.0
    var programBandwidthHz = 0.0
    var micDbFS = -200.0
    var micClipFraction = 0.0
    /// 有時間戳：true
    var usedClock = false
    /// 採用的比例（麥克風 sample ／ 節目音 sample）與相對標稱的 ppm
    var ratio = 1.0
    var ratioPpm = 0.0
    /// 未探測區塊估到、並已在頻域拉回的群集漂移（ppm；時間戳正確時應接近 0，藍牙本身漂移也會算進來）。nil = 未探測區塊不夠、沒有估
    var residualDriftPpm: Double?
    var segmentsUsed = 0
    var segmentsExcluded = 0
    var computeSeconds = 0.0

    var summary: String {
        var s: [String] = []
        if let k = skip { s.append("跳過：\(k.rawValue)") }
        s.append(String(format: "節目音 %.1f dBFS（1–4 kHz %.1f dBFS、有效頻寬 %.0f Hz）麥克風 %.1f dBFS", programDbFS, programBandDbFS,
                        programBandwidthHz, micDbFS))
        s.append(String(format: "時鐘：%@ 比例 %+.1f ppm%@；段 %d（排除 %d）；%.2f 秒", usedClock ? "時間戳" : "標稱", ratioPpm,
                        residualDriftPpm.map { String(format: "，頻域拉回漂移 %+.1f ppm", $0) } ?? "", segmentsUsed, segmentsExcluded, computeSeconds))
        if let c = cluster {
            s.append(String(format: "群集 %.2f ms（SNR %.1f dB）%@：", c.lagMs, c.snrDb, c.single ? "單一峰" : "多峰")
                     + c.peaks.map { String(format: "%+.2fms×%.2f", $0.offsetMs, $0.relative) }.joined(separator: " "))
        }
        for d in devices where d.probed {
            s.append(String(format: "  裝置 %d：誤差 %@ ms  SNR %@/%@ dB  PSR %@ dB  奇偶差 %@ ms  探測 %.1f 秒 %@ → %@", d.device,
                            d.errorMs.map { String(format: "%+.3f", $0) } ?? "—",
                            d.snrDb.map { String(format: "%.1f", $0) } ?? "—", d.referenceSnrDb.map { String(format: "%.1f", $0) } ?? "—",
                            d.psrDb.map { String(format: "%.1f", $0) } ?? "—", d.halfDiffMs.map { String(format: "%.3f", $0) } ?? "—",
                            d.probeSeconds, d.probeOffsetsMs.map { String(format: "%+.1f", $0) }.joined(separator: "/"),
                            d.trusted ? "可採信" : "不可採信（" + d.issues.map(\.rawValue).joined(separator: "、") + "）"))
        }
        return s.joined(separator: "\n")
    }
}

// MARK: - 估計器

enum DriftEstimator {

    static func analyze(_ cap: MonitorCapture, params prm: MonitorParams = MonitorParams()) -> MonitorResult {
        let t0 = Date()
        var res = MonitorResult()
        let rate = cap.micRate
        guard rate > 0, cap.programRate > 0, cap.mic.count >= Int(3 * rate), cap.program.count >= Int(3 * cap.programRate) else {
            res.skip = .tooShort
            return res
        }
        // 麥克風位準／削波
        var clip = 0
        var ms = 0.0
        for v in cap.mic { let a = abs(v); if a >= 0.99 { clip += 1 }; ms += Double(v * v) }
        res.micClipFraction = Double(clip) / Double(cap.mic.count)
        res.micDbFS = 10 * log10(max(ms / Double(cap.mic.count), 1e-20))
        // 節目音位準
        let lv = bandLevels(cap.program, rate: cap.programRate, lo: prm.bandLo, hi: prm.bandHi)
        res.programDbFS = lv.totalDb
        res.programBandDbFS = lv.bandDb
        res.programBandwidthHz = lv.effBandwidthHz
        if res.programDbFS < prm.minProgramDbFS { res.skip = .programTooQuiet; return res }
        if res.programBandDbFS < prm.minBandDbFS || res.programBandDbFS - res.programDbFS < prm.minBandFractionDb {
            res.skip = .bandEnergyTooLow; return res
        }
        if res.micDbFS < -90 { res.skip = .micSilent; return res }
        if res.micClipFraction > prm.maxClipFraction { res.skip = .micClipping; return res }

        // 時鐘對應：mic index = A + B · (program index)
        let nominal = rate / cap.programRate
        var A = 0.0, B = nominal
        if let fm = fitLine(cap.micClock), let fp = fitLine(cap.programClock), fm.b > 0, fp.b > 0 {
            // mic = am + bm·h；eng = ap + bp·h → h = (eng − ap)/bp；eng = programStart + p
            B = fm.b / fp.b
            A = fm.a + fm.b * (Double(cap.programStart) - fp.a) / fp.b
            res.usedClock = true
        }
        var lagMin = prm.lagMinMs, lagMax = prm.lagMaxMs
        if !res.usedClock { lagMin = -1500; lagMax = 1500 }

        res.ratio = B
        res.ratioPpm = (B / nominal - 1) * 1e6
        analyzeMapped(cap, A: A, B: B, lagMinMs: lagMin, lagMaxMs: lagMax, prm: prm, res: &res)
        res.computeSeconds = Date().timeIntervalSince(t0)
        return res
    }

    /// 失敗時 res.skip 已設
    private static func analyzeMapped(_ cap: MonitorCapture, A: Double, B: Double, lagMinMs: Double, lagMaxMs: Double,
                                      prm: MonitorParams, res: inout MonitorResult) {
        let rate = cap.micRate
        let L = nextPow2(max(256, Int(prm.segmentSeconds * rate)))
        // 參考格：mic index i 的節目音 = program((i − A)/B)。只在 sinc 支撐完整的範圍
        let half = MonResampler.halfTaps
        let iFirst = Int(ceil(A + B * Double(half + 1)))
        let iLast = Int(floor(A + B * Double(cap.program.count - half - 2)))
        guard iLast - iFirst > 4 * L else { res.skip = .noOverlap; return }
        let rs = MonResampler(cutoff: min(1, B) * 0.97)
        var ref = [Float](repeating: 0, count: iLast - iFirst)
        cap.program.withUnsafeBufferPointer { pp in
            for j in 0..<ref.count {
                ref[j] = rs.value(pp, at: (Double(iFirst + j) - A) / B)
            }
        }
        // 段：參考 [i0, i0+L)（i0 = iFirst + s·L）
        let lagLoC = Int((lagMinMs / 1000 * rate).rounded(.down))
        let lagHiC = Int((lagMaxMs / 1000 * rate).rounded(.up))
        let spanC = lagHiC - lagLoC
        var segs: [Int] = []
        var i0 = iFirst
        while i0 + L <= iLast { segs.append(i0); i0 += L }

        // ── 粗定位：群集 ──
        let nC = nextPow2(L + spanC)
        let fftC = MonFFT(n: nC)
        let coarseSegs = segs.filter { $0 + lagLoC >= 0 && $0 + lagLoC + L + spanC <= cap.mic.count }
        guard coarseSegs.count >= 8 else { res.skip = .noOverlap; return }
        let stepC = max(1, coarseSegs.count / prm.coarseMaxSegments)
        let bandC = BandBins(n: nC, rate: rate, lo: prm.bandLo, hi: prm.bandHi, taperHz: prm.bandTaperHz)
        var accRe = [Double](repeating: 0, count: bandC.count), accIm = accRe
        var xr = [Float](repeating: 0, count: nC / 2), xi = xr, mr = xr, mi = xr
        var used = 0
        for (k, s) in coarseSegs.enumerated() where k % stepC == 0 {
            ref.withUnsafeBufferPointer { rp in fftC.forward(rp.baseAddress! + (s - iFirst), count: L, re: &xr, im: &xi) }
            cap.mic.withUnsafeBufferPointer { mp in fftC.forward(mp.baseAddress! + (s + lagLoC), count: L + spanC, re: &mr, im: &mi) }
            for b in 0..<bandC.count {
                let q = bandC.lo + b
                let a = Double(mr[q]), bb = Double(mi[q]), c = Double(xr[q]), d = Double(xi[q])
                accRe[b] += a * c + bb * d
                accIm[b] += bb * c - a * d
            }
            used += 1
        }
        // PHAT（合併後）
        var yr = [Double](repeating: 0, count: bandC.count), yi = yr
        for b in 0..<bandC.count {
            let m = hypot(accRe[b], accIm[b]) + 1e-30
            yr[b] = accRe[b] / m * bandC.taper[b]
            yi[b] = accIm[b] / m * bandC.taper[b]
        }
        let envC = fftC.analyticEnvelope(re: yr, im: yi, binLo: bandC.lo)
        var best = 0
        for l in 0...spanC where envC[l] > envC[best] { best = l }
        // 雜訊：離主峰 > 100 ms 的 20 ms 小塊最大值的 90 百分位
        let chunk = max(1, Int(0.020 * rate)), far = Int(0.100 * rate)
        var chunkMax: [Float] = []
        var c0 = 0
        while c0 + chunk <= spanC + 1 {
            if abs(c0 + chunk / 2 - best) > far { chunkMax.append(envC[c0..<(c0 + chunk)].max()!) }
            c0 += chunk
        }
        chunkMax.sort()
        let noiseC = chunkMax.isEmpty ? 1e-30 : Double(chunkMax[min(chunkMax.count - 1, Int(0.9 * Double(chunkMax.count)))])
        let snrC = 20 * log10(Double(envC[best]) / max(noiseC, 1e-30))
        guard snrC >= prm.coarseMinSnrDb else {
            res.skip = .clusterNotFound
            res.cluster = MonitorCluster(lagMs: Double(lagLoC + best) / rate * 1000, snrDb: snrC, peaks: [], single: false)
            return
        }
        let tauC = lagLoC + best

        // ── 細分析（Welch）：參考與麥克風各取同長度、Hann 窗、50% 重疊，麥克風窗整體延後 τc（群集）。
        //    兩邊等長 → 互功率譜 / 自功率譜是轉移函數的一致估計；
        //    不用「參考段補零 × 較長的麥克風窗」：那樣麥克風窗裡鄰近的節目音（和參考段相關，尤其長音）會依內容偏差，
        //    而各探測狀態的內容不同 → 偏差不同 → 差分抵消不掉，變成 ±p 的假峰。
        let Lw = nextPow2(max(512, Int(prm.welchSeconds * rate)))
        let hop = Lw / 2
        let nF = Lw
        let fftF = MonFFT(n: nF)
        let band = BandBins(n: nF, rate: rate, lo: prm.bandLo, hi: prm.bandHi, taperHz: prm.bandTaperHz)
        let nb = band.count
        var win = [Float](repeating: 0, count: Lw)
        vDSP_hann_window(&win, vDSP_Length(Lw), Int32(vDSP_HANN_DENORM))
        var wx = [Float](repeating: 0, count: Lw), wm = wx
        // 被探測的裝置（依 index 排序）→ 未知數 u（最後一個是「其他」R）
        let probed = Array(Set(cap.probes.map(\.device))).filter { $0 >= 0 && $0 < cap.deviceCount }.sorted()
        let guardP = prm.transitionGuardMs / 1000 * cap.programRate
        struct Seg { var state: [Double]; var order: Int; var t: Double; var cr: [Double]; var ci: [Double]; var p: [Double]; var q: [Double] }
        var fine: [Seg] = []
        var excluded = 0
        var probeSec = [Double](repeating: 0, count: probed.count)
        var offsetsSeen = [Set<Double>](repeating: [], count: probed.count)
        var order = -1
        var s = iFirst - hop
        while true {
            s += hop
            guard s + Lw <= iLast else { break }
            guard s + tauC >= 0, s + tauC + Lw <= cap.mic.count else { continue }
            order += 1
            // 段內容（engine sampleTime）
            let cA = Double(cap.programStart) + (Double(s) - A) / B
            let cB = Double(cap.programStart) + (Double(s + Lw) - A) / B
            var st = [Double](repeating: 0, count: probed.count)
            var bad = false
            for pr in cap.probes {
                guard let u = probed.firstIndex(of: pr.device) else { continue }
                let ramp = pr.rampMs / 1000 * cap.programRate
                let outerA = Double(pr.fullStart) - ramp - guardP, outerB = Double(pr.fullEnd) + ramp + guardP
                let innerA = Double(pr.fullStart) + guardP, innerB = Double(pr.fullEnd) - guardP
                if cB <= outerA || cA >= outerB { continue }            // 完全在外
                if cA >= innerA && cB <= innerB && st[u] == 0 { st[u] = pr.offsetMs; continue }   // 完全在內
                bad = true
            }
            if bad { excluded += 1; continue }
            ref.withUnsafeBufferPointer { rp in vDSP_vmul(rp.baseAddress! + (s - iFirst), 1, win, 1, &wx, 1, vDSP_Length(Lw)) }
            cap.mic.withUnsafeBufferPointer { mp in vDSP_vmul(mp.baseAddress! + (s + tauC), 1, win, 1, &wm, 1, vDSP_Length(Lw)) }
            wx.withUnsafeBufferPointer { fftF.forward($0.baseAddress!, count: Lw, re: &xr, im: &xi) }
            wm.withUnsafeBufferPointer { fftF.forward($0.baseAddress!, count: Lw, re: &mr, im: &mi) }
            var cr = [Double](repeating: 0, count: nb), ci = cr, p = cr, q = cr
            for b in 0..<nb {
                let k = band.lo + b
                let a = Double(mr[k]), bb = Double(mi[k]), c = Double(xr[k]), d = Double(xi[k])
                cr[b] = a * c + bb * d
                ci[b] = bb * c - a * d
                p[b] = c * c + d * d
                q[b] = a * a + bb * bb
            }
            for u in 0..<probed.count where st[u] != 0 {
                probeSec[u] += Double(hop) / rate
                offsetsSeen[u].insert(st[u])
            }
            fine.append(Seg(state: st, order: order, t: Double(s + Lw / 2), cr: cr, ci: ci, p: p, q: q))
        }
        res.segmentsUsed = fine.count
        res.segmentsExcluded = excluded
        guard fine.count >= 8 else { res.skip = .noOverlap; return }

        // ── 群集的時間漂移：差分法要求「群集」在各探測狀態完全一樣。群集延遲若在 10 秒內線性走了 Δ，
        //    基準段（頭尾）與探測段（中間）的群集就對不齊：4 kHz 時 0.05 ms 就差 0.07 週期，殘差會被當成被探測那台 →
        //    所以先用「未探測」的區塊（約 1 秒一塊）各自對合併的基準互功率譜估相對延遲（相位＝ −ωδ），擬合一條直線，
        //    再把每段的互功率譜乘 e^{+jω·ε·(t − t̄)} 拉回。時間戳正確時 ε ≈ 0；沒有時間戳時這就是麥克風與引擎的剩餘比例差。
        let tMean = fine.map(\.t).reduce(0, +) / Double(fine.count)
        var epsTotal = 0.0
        for _ in 0..<2 {
            guard let eps = estimateDrift(fine.map { ($0.state.allSatisfy { $0 == 0 }, $0.order, $0.t, $0.cr, $0.ci) },
                                          band: band, rate: rate, blockSegments: max(4, Int((1.0 * rate / Double(hop)).rounded()))) else { break }
            epsTotal += eps
            for g in fine.indices {
                let dt = eps * (fine[g].t - tMean)
                for b in 0..<nb {
                    let ph = 2 * Double.pi * band.freqs[b] / rate * dt
                    let c = cos(ph), sn = sin(ph)
                    let r = fine[g].cr[b], i = fine[g].ci[b]
                    fine[g].cr[b] = r * c - i * sn
                    fine[g].ci[b] = r * sn + i * c
                }
            }
            if abs(eps) < 0.5e-6 { break }
        }
        res.residualDriftPpm = epsTotal * 1e6

        // 每個子集合解一次：回傳各估計量的包絡曲線
        let smoothBins = max(1, Int(prm.snrSmoothHz / (rate / Double(nF))))
        /// idx 的段、未知數 = unknowns（probed 的 index）＋ R。段的狀態只取 unknowns 那幾台
        /// （呼叫端要先把「其他台在探測」的段排除，否則它們的偏移會被算進 R）
        func solve(_ idx: [Int], unknowns: [Int]) -> DriftSolution {
            // 依狀態合併
            var keys: [[Double]] = []
            var sC: [[Double]] = [], sCi: [[Double]] = [], sP: [[Double]] = []
            var qSum = [Double](repeating: 0, count: nb)
            for i in idx {
                let g = fine[i]
                let key = unknowns.map { g.state[$0] }
                var si = keys.firstIndex(of: key) ?? -1
                if si < 0 {
                    keys.append(key); si = keys.count - 1
                    sC.append([Double](repeating: 0, count: nb)); sCi.append(sC[si]); sP.append(sC[si])
                }
                for b in 0..<nb { sC[si][b] += g.cr[b]; sCi[si][b] += g.ci[b]; sP[si][b] += g.p[b]; qSum[b] += g.q[b] }
            }
            return DriftSolution.solve(keys: keys, cRe: sC, cIm: sCi, p: sP, qSum: qSum, nSeg: idx.count, U: unknowns.count + 1, band: band,
                                       rate: rate, n: nF, smoothBins: smoothBins, fft: fftF, rotate: nF / 2, mismatch: prm.mismatchFraction)
        }
        let all = Array(fine.indices)
        // 奇偶兩半：以「兩段一組」交錯（50% 重疊，相鄰段有一半是同一段聲音；兩段一組只在組界重疊）
        let allUnknowns = Array(probed.indices)
        let solAll = solve(all, unknowns: allUnknowns)

        // 曲線（circular lag）轉成以群集為中心：index center = lag τc
        let center = nF / 2
        let lagLoF = tauC - center
        let sw = Int((prm.searchMs / 1000 * rate).rounded())
        let lo = max(1, center - sw), hi = min(nF - 2, center + sw)
        let noiseHi = center - Int((prm.noiseGapMs / 1000 * rate).rounded())
        let excl = Int(0.0006 * rate)
        let edge = Int(0.0005 * rate)
        func lagMs(_ pos: Double) -> Double { (Double(lagLoF) + pos) / rate * 1000 }
        func noiseMax(_ env: [Float]) -> Double {
            guard noiseHi > 2 else { return 1e-30 }
            return Double(env[1..<noiseHi].max() ?? 1e-30)
        }

        // 群集（全部裝置的和、未探測狀態 = u 全部 1）
        let sumU = [Double](repeating: 1, count: allUnknowns.count + 1)
        let envSum = solAll.envelope(sumU)
        prm.debugSink?("sum", envSum, center, rate)
        if let pk = pickPeak(envSum, lo: lo, hi: hi, frac: prm.earliestFraction, exclude: excl) {
            var cl = MonitorCluster()
            cl.lagMs = lagMs(pk.pos)
            cl.snrDb = 20 * log10(pk.value / max(noiseMax(envSum), 1e-30))
            let main = Int(pk.pos.rounded())
            let maxV = Double(envSum[lo...hi].max()!)
            for i in lo...hi where i > lo && i < hi && envSum[i] >= envSum[i - 1] && envSum[i] > envSum[i + 1] {
                let rel = Double(envSum[i]) / maxV
                if rel >= 0.4 { cl.peaks.append(MonitorPeak(offsetMs: Double(i - main) / rate * 1000, relative: rel)) }
                if abs(i - main) > excl && rel >= 0.5 && i - main <= Int(0.0025 * rate) { cl.single = false }
            }
            res.cluster = cl
        }

        // 參考曲線（R）的峰只能落在「全部的和」也有峰的地方：R 與被探測那台在 e^{−jωp} = 1 的頻率分不開，
        // R 的權重也是梳子 → R 在 ±p（及疊在 4.1 ms 反射上）有假峰，可以比直達還高；「和」沒有這個問題
        var sumPeaks: [Int] = []
        let sumMax = envSum[lo...hi].max() ?? 0
        for i in lo...hi where envSum[i] >= envSum[i - 1] && envSum[i] > envSum[i + 1] && Double(envSum[i]) >= prm.clusterMatchFraction * Double(sumMax) {
            sumPeaks.append(i)
        }
        let matchW = Int(prm.clusterMatchMs / 1000 * rate)
        let inCluster: (Int) -> Bool = { i in sumPeaks.contains { abs($0 - i) <= matchW } }

        // 每台被探測的裝置
        var ests: [MonitorDeviceEstimate] = (0..<cap.deviceCount).map { MonitorDeviceEstimate(device: $0, issues: [.notProbed]) }
        let minPsr = 20 * log10(1 / prm.ambiguityRatio)
        for (u, dev) in probed.enumerated() {
            var e = MonitorDeviceEstimate(device: dev)
            e.probed = true
            e.probeSeconds = probeSec[u]
            e.probeOffsetsMs = offsetsSeen[u].sorted()
            // 這台自己的模型：未知數 = 這台 ＋（它是參考裝置時）被探測的非參考裝置（藍牙）＋ R。
            // 其他參考裝置在探測的段不用（它們的偏移若放進 R 會污染參考；全部一起解則每個分量的 ±p 假峰會加進參考）。
            // 參考 = R（＋這台不是參考裝置時：被探測的參考裝置，但那些段已排除，所以就是 R）
            let isRef = cap.referenceDevices.isEmpty || cap.referenceDevices.contains(dev)
            var unk = [u]
            if isRef && !cap.referenceDevices.isEmpty {
                unk += probed.indices.filter { $0 != u && !cap.referenceDevices.contains(probed[$0]) }
            }
            let idxK = all.filter { i in probed.indices.allSatisfy { v in unk.contains(v) || fine[i].state[v] == 0 } }
            let evenK = idxK.filter { (fine[$0].order / 2) % 2 == 0 }, oddK = idxK.filter { (fine[$0].order / 2) % 2 == 1 }
            let solK = solve(idxK, unknowns: unk)
            let solEven = solve(evenK, unknowns: unk), solOdd = solve(oddK, unknowns: unk)
            let UK = unk.count + 1
            var only = [Double](repeating: 0, count: UK); only[0] = 1
            let allOnes = [Double](repeating: 1, count: UK)
            var others = [Double](repeating: 0, count: UK); others[UK - 1] = 1
            func est(_ sol: DriftSolution) -> (err: Double, dev: PeakPick, ref: PeakPick, nDev: Double, nRef: Double)? {
                let ed = sol.envelope(only), er = prm.referenceSumWeights ? sol.envelope(others, weightU: allOnes) : sol.envelope(others)
                guard let pd = pickPeak(ed, lo: lo, hi: hi, frac: prm.deviceEarliestFraction, exclude: excl),
                      let pr = pickPeak(er, lo: lo, hi: hi, frac: prm.referenceEarliestFraction, exclude: excl, allowed: inCluster)
                else { return nil }
                return ((pd.pos - pr.pos) / rate * 1000, pd, pr, noiseMax(ed), noiseMax(er))
            }
            // 單一偏移的短探測：LS 的 ±p 假峰（見 nearProbeImage）也會出現在參考曲線（R）上，資料少時足以蓋過直達峰
            // → 要比較多資料；兩種偏移時假峰散開，minProbeSeconds 就夠
            let needSec = e.probeOffsetsMs.count >= 2 ? prm.minProbeSeconds : prm.minProbeSecondsSingleOffset
            if e.probeSeconds < needSec { e.issues.append(.probeTooShort) }
            if let sink = prm.debugSink {
                sink("dev\(dev)", solK.envelope(only), center, rate)
                sink("ref\(dev)", prm.referenceSumWeights ? solK.envelope(others, weightU: allOnes) : solK.envelope(others), center, rate)
            }
            if let r = est(solK) {
                e.arrivalMs = lagMs(r.dev.pos)
                e.referenceMs = lagMs(r.ref.pos)
                e.errorMs = r.err
                e.snrDb = 20 * log10(r.dev.value / max(r.nDev, 1e-30))
                e.referenceSnrDb = 20 * log10(r.ref.value / max(r.nRef, 1e-30))
                e.psrDb = min(20 * log10(r.dev.value / max(r.dev.other, 1e-30)), 20 * log10(r.ref.value / max(r.ref.other, 1e-30)))
                if e.snrDb! < prm.minSnrDb { e.issues.append(.lowSnr) }
                if e.referenceSnrDb! < prm.minSnrDb { e.issues.append(.referenceLowSnr) }
                if e.psrDb! < minPsr { e.issues.append(.ambiguous) }
                // 採用的（最早的）峰比窗內最大值低很多：可能是早到的假峰（長音類），也可能是比直達高的反射 → 都不採信
                if r.dev.value < prm.laterPeakRatio * r.dev.windowMax { e.issues.append(.weakerThanLater) }
                // 參考：比它早、也在「和」裡的峰 ≥ referenceEarlierRatio × 它 → 採用的可能是反射（兩台直達相消時反射可以比直達高）
                if r.ref.other >= prm.referenceEarlierRatio * r.ref.value { e.issues.append(.referenceAmbiguous) }
                if r.dev.pos - Double(lo) < Double(edge) || Double(hi) - r.dev.pos < Double(edge) { e.issues.append(.atSearchEdge) }
                if let a = est(solEven), let b = est(solOdd) {
                    e.halfDiffMs = abs(a.err - b.err)
                    if e.halfDiffMs! > prm.maxHalfDiffMs { e.issues.append(.inconsistent) }
                } else {
                    e.issues.append(.inconsistent)
                }
            } else {
                // 哪條曲線找不到峰：這台自己 → 量不到；參考（有線被藍牙蓋過、或參考峰不在群集上）→ 參考不足（不算「量不到」）
                let devOK = pickPeak(solK.envelope(only), lo: lo, hi: hi, frac: prm.deviceEarliestFraction, exclude: excl) != nil
                e.issues.append(devOK ? .referenceLowSnr : .lowSnr)
            }
            if !res.usedClock && res.residualDriftPpm == nil { e.issues.append(.clockUnknown) }
            // 只用一種探測偏移 p 時，e^{−jωp} − 1 的零點是等間隔的梳子 → SNR 權重也是梳子 → 曲線在 ±p、±2p 有假峰（群集的鏡像）。
            // 誤差剛好落在那裡就不採信（真的差 3–4 ms 時，換另一個偏移的那輪會量到；同一輪用兩種偏移就沒有這個問題）
            if let err = e.errorMs, e.probeOffsetsMs.count == 1, let p = e.probeOffsetsMs.first,
               [p, -p, 2 * p, -2 * p].contains(where: { abs(err - $0) < prm.probeImageToleranceMs }) {
                e.issues.append(.nearProbeImage)
            }
            e.trusted = e.issues.isEmpty
            ests[dev] = e
        }
        res.devices = ests
    }

    /// 未探測區塊的相對延遲 → 直線斜率 ε（麥克風 sample／sample）。
    /// 相鄰兩塊（時間順序）互比：G = C_b·conj(C_a)（PHAT），先用 |Σ G e^{jωδ}|（包絡）在 ±1.5 ms 找大概位置，
    /// 再用實部（載波）在 ±0.15 ms 內精修；逐對累加成每塊相對第一塊的延遲，最小平方擬合直線。
    /// 不跟「合併的基準」比：漂移時合併的基準本身是兩個錯開的群集相加，4 kHz 的相位會互相抵消。
    /// 區塊 ≥ 2、時間跨度 ≥ 3 秒才估；擬合殘差 RMS > 0.03 ms 視為不可靠 → nil
    static func estimateDrift(_ segs: [(base: Bool, order: Int, t: Double, cr: [Double], ci: [Double])], band: BandBins, rate: Double,
                              blockSegments: Int) -> Double? {
        let nb = band.count
        var blocks: [(t: Double, r: [Double], i: [Double])] = []
        var groups: [Int: [Int]] = [:]
        for (k, g) in segs.enumerated() where g.base { groups[g.order / blockSegments, default: []].append(k) }
        for key in groups.keys.sorted() {
            let ix = groups[key]!
            guard ix.count * 2 >= blockSegments else { continue }
            var r = [Double](repeating: 0, count: nb), i = r
            for k in ix { for b in 0..<nb { r[b] += segs[k].cr[b]; i[b] += segs[k].ci[b] } }
            blocks.append((ix.map { segs[$0].t }.reduce(0, +) / Double(ix.count), r, i))
        }
        guard blocks.count >= 2, let t0 = blocks.first?.t, let t1 = blocks.last?.t, t1 - t0 >= 3 * rate else { return nil }
        let step = 5e-6
        let nSteps = Int(0.0015 / step)
        let fine = Int(0.00015 / step)
        func shift(_ a: (t: Double, r: [Double], i: [Double]), _ b: (t: Double, r: [Double], i: [Double])) -> Double? {
            var gr = [Double](repeating: 0, count: nb), gi = gr
            for k in 0..<nb {
                let x = b.r[k], y = b.i[k], u = a.r[k], v = -a.i[k]
                let re = x * u - y * v, im = x * v + y * u
                let m = hypot(re, im)
                if m > 0 { gr[k] = re / m * band.taper[k]; gi[k] = im / m * band.taper[k] }
            }
            var env = [Double](repeating: 0, count: 2 * nSteps + 1), real = env
            for j in 0...(2 * nSteps) {
                let d = Double(j - nSteps) * step
                var ar = 0.0, ai = 0.0
                for k in 0..<nb {
                    let w = 2 * Double.pi * band.freqs[k] * d
                    let c = cos(w), sn = sin(w)
                    ar += gr[k] * c - gi[k] * sn
                    ai += gr[k] * sn + gi[k] * c
                }
                env[j] = hypot(ar, ai); real[j] = ar
            }
            var e = 0
            for j in env.indices where env[j] > env[e] { e = j }
            var best = e
            for j in max(1, e - fine)...min(real.count - 2, e + fine) where real[j] > real[best] { best = j }
            guard best > 0 && best < real.count - 1 else { return nil }
            let ym = real[best - 1], y0 = real[best], yp = real[best + 1]
            let den = ym - 2 * y0 + yp
            let f = den < 0 ? 0.5 * (ym - yp) / den : 0
            // G 的相位 = −ω·(τ_b − τ_a) → Re Σ G e^{jωδ} 在 δ = τ_b − τ_a 最大
            return (Double(best - nSteps) + f) * step * rate
        }
        var ts = [blocks[0].t], ds = [0.0]
        for k in 1..<blocks.count {
            guard let d = shift(blocks[k - 1], blocks[k]) else { return nil }
            ts.append(blocks[k].t); ds.append(ds[k - 1] + d)
        }
        let tm = ts.reduce(0, +) / Double(ts.count), dm = ds.reduce(0, +) / Double(ds.count)
        var sxx = 0.0, sxy = 0.0
        for k in ts.indices { sxx += (ts[k] - tm) * (ts[k] - tm); sxy += (ts[k] - tm) * (ds[k] - dm) }
        guard sxx > 0 else { return nil }
        let eps = sxy / sxx
        var rss = 0.0
        for k in ts.indices { let r = ds[k] - dm - eps * (ts[k] - tm); rss += r * r }
        if ts.count >= 3, sqrt(rss / Double(ts.count)) / rate > 0.00003 { return nil }
        return eps
    }

    // MARK: 峰值

    struct PeakPick { var pos: Double; var value: Double; var other: Double; var windowMax: Double = 0 }

    /// [lo, hi] 內：最大值 G；≥ frac·G 的第一個局部峰（最早到達）；other = 比它早 > exclude 的最大局部峰；拋物線內插。
    /// allowed：只考慮這些位置的局部峰（nil = 全部）；最大值 G 仍取整個窗
    static func pickPeak(_ env: [Float], lo: Int, hi: Int, frac: Double, exclude: Int, allowed: ((Int) -> Bool)? = nil,
                         mirrorTol: Int = 14) -> PeakPick? {
        guard lo >= 1, hi < env.count - 1, hi > lo else { return nil }
        var g: Float = 0
        for i in lo...hi where env[i] > g { g = env[i] }
        guard g > 0 else { return nil }
        var peaks: [Int] = []
        for i in lo...hi where env[i] >= env[i - 1] && env[i] > env[i + 1] && (allowed?(i) ?? true) { peaks.append(i) }
        guard let c = peaks.first(where: { Double(env[$0]) >= frac * Double(g) }) else { return nil }
        // 模稜兩可只看「比它早」的峰：物理上直達聲之前不該有東西；比它晚的是反射（群集的 4.1 ms 反射經 PHAT 後可以跟直達一樣高）
        // PHAT 把強反射（+Δ）也鏡射到 −Δ（1/|1 + r·e^{−jωΔ}| 是對稱的餘弦級數）：比它早、但在 +Δ 有更高的峰對應的，是鏡像，不算
        var allPeaks: [Int] = []
        for i in lo...hi where env[i] >= env[i - 1] && env[i] > env[i + 1] { allPeaks.append(i) }
        var other = 0.0
        for i in peaks where c - i > exclude {
            let mirror = 2 * c - i
            if allPeaks.contains(where: { abs($0 - mirror) <= mirrorTol && env[$0] >= env[i] }) { continue }
            other = max(other, Double(env[i]))
        }
        let ym = Double(env[c - 1]), y0 = Double(env[c]), yp = Double(env[c + 1])
        let den = ym - 2 * y0 + yp
        var d = 0.0
        if den < 0 { d = min(0.5, max(-0.5, 0.5 * (ym - yp) / den)) }
        return PeakPick(pos: Double(c) + d, value: y0 - 0.25 * (ym - yp) * d, other: other, windowMax: Double(g))
    }

    // MARK: 位準

    static func bandLevels(_ x: [Float], rate: Double, lo: Double, hi: Double) -> (totalDb: Double, bandDb: Double, effBandwidthHz: Double) {
        let n = 4096
        guard x.count >= n else { return (-200, -200, 0) }
        let fft = MonFFT(n: n)
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var sw2: Float = 0
        vDSP_svesq(w, 1, &sw2, vDSP_Length(n))
        let kLo = max(1, Int(lo / rate * Double(n))), kHi = min(n / 2 - 1, Int(hi / rate * Double(n)))
        var psd = [Double](repeating: 0, count: n / 2)
        var re = [Float](repeating: 0, count: n / 2), im = re
        var buf = [Float](repeating: 0, count: n)
        var blocks = 0
        var s = 0
        while s + n <= x.count {
            x.withUnsafeBufferPointer { xp in vDSP_vmul(xp.baseAddress! + s, 1, w, 1, &buf, 1, vDSP_Length(n)) }
            buf.withUnsafeBufferPointer { fft.forward($0.baseAddress!, count: n, re: &re, im: &im) }
            for k in 1..<(n / 2) { psd[k] += Double(re[k] * re[k] + im[k] * im[k]) / 4 }   // vDSP zrip = 2 × DFT
            blocks += 1
            s += n
        }
        let norm = 2 / (Double(n) * Double(sw2) * Double(blocks))
        let total = psd.reduce(0, +) * norm
        var band = 0.0, sq = 0.0
        for k in kLo...kHi { band += psd[k]; sq += psd[k] * psd[k] }
        let eff = sq > 0 ? band * band / sq * rate / Double(n) : 0
        return (10 * log10(max(total, 1e-20)), 10 * log10(max(band * norm, 1e-20)), eff)
    }

    // MARK: 時鐘擬合

    /// sample = a + b · hostSeconds（最小平方；host 先置中避免精度問題）；點數 < 2 或跨度 < 0.5 秒 → nil
    static func fitLine(_ pts: [MonitorClockPoint]) -> (a: Double, b: Double)? {
        guard pts.count >= 2 else { return nil }
        let hm = pts.map(\.hostSeconds).reduce(0, +) / Double(pts.count)
        let sm = pts.map(\.sample).reduce(0, +) / Double(pts.count)
        var sxx = 0.0, sxy = 0.0, hMin = Double.infinity, hMax = -Double.infinity
        for p in pts {
            let dx = p.hostSeconds - hm
            sxx += dx * dx; sxy += dx * (p.sample - sm)
            hMin = min(hMin, p.hostSeconds); hMax = max(hMax, p.hostSeconds)
        }
        guard hMax - hMin >= 0.5, sxx > 0 else { return nil }
        let b = sxy / sxx
        return (sm - b * hm, b)
    }

    static func nextPow2(_ v: Int) -> Int { var n = 1; while n < v { n <<= 1 }; return n }
}

// MARK: - 每個 bin 的最小平方解與曲線

struct BandBins {
    let lo: Int, count: Int
    let taper: [Double]
    let freqs: [Double]
    init(n: Int, rate: Double, lo fLo: Double, hi fHi: Double, taperHz: Double) {
        let df = rate / Double(n)
        let a = max(1, Int(((fLo - taperHz / 2) / df).rounded(.down)))
        let b = min(n / 2 - 1, Int(((fHi + taperHz / 2) / df).rounded(.up)))
        lo = a
        count = b - a + 1
        freqs = (0..<(b - a + 1)).map { Double(a + $0) * df }
        taper = freqs.map { f in
            if f < fLo - taperHz / 2 || f > fHi + taperHz / 2 { return 0 }
            if f < fLo + taperHz / 2 { return 0.5 - 0.5 * cos(Double.pi * (f - (fLo - taperHz / 2)) / taperHz) }
            if f > fHi - taperHz / 2 { return 0.5 - 0.5 * cos(Double.pi * ((fHi + taperHz / 2) - f) / taperHz) }
            return 1
        }
    }
}

/// 每個 bin：θ（U 個複數：探測裝置 A_k…、其他 R）、M⁻¹（U×U）、雜訊功率 σ²
struct DriftSolution {
    let U: Int, nb: Int
    var thRe: [Double], thIm: [Double]          // [b*U + u]
    var invRe: [Double], invIm: [Double]        // [b*U*U + i*U + j]
    var sigma2: [Double]
    let band: BandBins
    let smoothBins: Int
    let fft: MonFFT
    /// 曲線旋轉：輸出 index j = lag (j − rotate)（circular）
    let rotate: Int

    /// 估計量 uᵀθ（u 實數向量）的包絡曲線：SNR 加權 PHAT → 解析訊號 → |·|
    /// weightU：SNR 權重改用這個估計量的（nil = 用 u 自己的）。參考曲線用「全部的和」的權重：
    /// 參考（R）在 e^{−jωp} = 1 附近跟被探測那台分不開，自己的權重會是梳子 → ±p 假峰；和的權重平滑，那些 bin 只是比較吵
    func envelope(_ u: [Double], weightU: [Double]? = nil) -> [Float] {
        var er = [Double](repeating: 0, count: nb), ei = er, sn = er, va = er
        let wu = weightU ?? u
        for b in 0..<nb {
            var r = 0.0, i = 0.0
            for k in 0..<U where u[k] != 0 { r += u[k] * thRe[b * U + k]; i += u[k] * thIm[b * U + k] }
            var wr = r, wi = i
            if weightU != nil {
                wr = 0; wi = 0
                for k in 0..<U where wu[k] != 0 { wr += wu[k] * thRe[b * U + k]; wi += wu[k] * thIm[b * U + k] }
            }
            var v = 0.0
            let base = b * U * U
            for p in 0..<U where wu[p] != 0 {
                for q in 0..<U where wu[q] != 0 { v += wu[p] * wu[q] * invRe[base + p * U + q] }   // uᵀM⁻¹u（Hermitian → 實部）
            }
            er[b] = r; ei[b] = i
            sn[b] = wr * wr + wi * wi
            va[b] = max(v, 0) * sigma2[b]
        }
        // 頻率上平滑（分子、分母各自）
        let s1 = boxSmooth(sn, smoothBins), s2 = boxSmooth(va, smoothBins)
        var yr = [Double](repeating: 0, count: nb), yi = yr
        for b in 0..<nb {
            let snr = s1[b] / max(s2[b], 1e-300)
            let w = snr / (1 + snr) * band.taper[b]
            let m = hypot(er[b], ei[b])
            if m > 0 { yr[b] = er[b] / m * w; yi[b] = ei[b] / m * w }
        }
        let e = fft.analyticEnvelope(re: yr, im: yi, binLo: band.lo)
        guard rotate != 0 else { return e }
        let n = e.count
        return (0..<n).map { e[(($0 - rotate) % n + n) % n] }
    }
}


extension DriftSolution {
    static func solve(keys: [[Double]], cRe: [[Double]], cIm: [[Double]], p: [[Double]], qSum: [Double], nSeg: Int, U: Int,
                      band: BandBins, rate: Double, n: Int, smoothBins: Int, fft: MonFFT, rotate: Int = 0,
                      mismatch: Double = 0) -> DriftSolution {
        let nb = band.count
        var thRe = [Double](repeating: 0, count: nb * U), thIm = thRe
        var invRe = [Double](repeating: 0, count: nb * U * U), invIm = invRe
        var sigma2 = [Double](repeating: 0, count: nb)
        let S = keys.count
        var mRe = [Double](repeating: 0, count: U * U), mIm = mRe
        var bRe = [Double](repeating: 0, count: U), bIm = bRe
        var phRe = [Double](repeating: 1, count: U), phIm = [Double](repeating: 0, count: U)
        var explained = [Double](repeating: 0, count: nb)
        for b in 0..<nb {
            let w = 2 * Double.pi * band.freqs[b]
            for i in 0..<(U * U) { mRe[i] = 0; mIm[i] = 0 }
            for i in 0..<U { bRe[i] = 0; bIm[i] = 0 }
            var pTot = 0.0
            var expl = 0.0
            for s in 0..<S {
                let ps = p[s][b]
                guard ps > 0 else { continue }
                pTot += ps
                for u in 0..<(U - 1) {
                    let ph = -w * keys[s][u] / 1000
                    phRe[u] = cos(ph); phIm[u] = sin(ph)
                }
                phRe[U - 1] = 1; phIm[U - 1] = 0
                // M += P_s · conj(φ) φᵀ；b += conj(φ) C_s
                for i in 0..<U {
                    let ar = phRe[i], ai = -phIm[i]
                    for j in 0..<U {
                        let br = phRe[j], bi = phIm[j]
                        mRe[i * U + j] += ps * (ar * br - ai * bi)
                        mIm[i * U + j] += ps * (ar * bi + ai * br)
                    }
                    let cr = cRe[s][b], ci = cIm[s][b]
                    bRe[i] += ar * cr - ai * ci
                    bIm[i] += ar * ci + ai * cr
                }
                expl += (cRe[s][b] * cRe[s][b] + cIm[s][b] * cIm[s][b]) / ps
            }
            explained[b] = expl
            // 極小的 ridge（數值穩定；不是正則化，無法分辨的方向由 SNR 權重處理）
            for i in 0..<U { mRe[i * U + i] += 1e-9 * max(pTot, 1e-30) }
            guard let inv = complexInverse(mRe, mIm, U) else { continue }
            for i in 0..<U {
                var r = 0.0, im = 0.0
                for j in 0..<U {
                    let a = inv.re[i * U + j], c = inv.im[i * U + j]
                    r += a * bRe[j] - c * bIm[j]
                    im += a * bIm[j] + c * bRe[j]
                }
                thRe[b * U + i] = r; thIm[b * U + i] = im
            }
            for i in 0..<(U * U) { invRe[b * U * U + i] = inv.re[i]; invIm[b * U * U + i] = inv.im[i] }
        }
        // 雜訊功率（每段）：麥克風窗功率 − 已解釋的部分，下限 2%；頻率上平滑
        let n0 = Double(max(nSeg, 1))
        for b in 0..<nb { sigma2[b] = max(qSum[b] - explained[b], 0.02 * qSum[b]) / n0 }
        var smoothed = boxSmooth(sigma2, max(1, smoothBins * 2))
        // 模型失配：κ²·|群集|²·(每段平均 |X|²)
        if mismatch > 0 {
            var mm = [Double](repeating: 0, count: nb)
            for b in 0..<nb {
                var sr = 0.0, si = 0.0
                for u in 0..<U { sr += thRe[b * U + u]; si += thIm[b * U + u] }
                var pt = 0.0
                for s in 0..<S { pt += p[s][b] }
                mm[b] = mismatch * mismatch * (sr * sr + si * si) * pt / n0
            }
            let ms = boxSmooth(mm, max(1, smoothBins * 2))
            for b in 0..<nb { smoothed[b] += ms[b] }
        }
        // 每段的雜訊 → M 是 Σ P（跨段累加），θ 的共變異 = σ²_seg · M⁻¹
        return DriftSolution(U: U, nb: nb, thRe: thRe, thIm: thIm, invRe: invRe, invIm: invIm,
                             sigma2: smoothed.map { max($0, 1e-300) }, band: band, smoothBins: smoothBins, fft: fft, rotate: rotate)
    }

    /// U×U 複數矩陣求反（Gauss-Jordan，部分主元）
    static func complexInverse(_ aRe: [Double], _ aIm: [Double], _ n: Int) -> (re: [Double], im: [Double])? {
        var r = aRe, i = aIm
        var vr = [Double](repeating: 0, count: n * n), vi = vr
        for k in 0..<n { vr[k * n + k] = 1 }
        for c in 0..<n {
            var piv = c
            var best = hypot(r[c * n + c], i[c * n + c])
            for rr in c..<n where rr > c {
                let m = hypot(r[rr * n + c], i[rr * n + c])
                if m > best { best = m; piv = rr }
            }
            guard best > 0 else { return nil }
            if piv != c {
                for k in 0..<n {
                    r.swapAt(c * n + k, piv * n + k); i.swapAt(c * n + k, piv * n + k)
                    vr.swapAt(c * n + k, piv * n + k); vi.swapAt(c * n + k, piv * n + k)
                }
            }
            // 1 / pivot
            let pr = r[c * n + c], pi = i[c * n + c]
            let d = pr * pr + pi * pi
            let qr = pr / d, qi = -pi / d
            for k in 0..<n {
                let a = r[c * n + k], b = i[c * n + k]
                r[c * n + k] = a * qr - b * qi; i[c * n + k] = a * qi + b * qr
                let e = vr[c * n + k], f = vi[c * n + k]
                vr[c * n + k] = e * qr - f * qi; vi[c * n + k] = e * qi + f * qr
            }
            for rr in 0..<n where rr != c {
                let fr = r[rr * n + c], fi = i[rr * n + c]
                if fr == 0 && fi == 0 { continue }
                for k in 0..<n {
                    let a = r[c * n + k], b = i[c * n + k]
                    r[rr * n + k] -= fr * a - fi * b; i[rr * n + k] -= fr * b + fi * a
                    let e = vr[c * n + k], f = vi[c * n + k]
                    vr[rr * n + k] -= fr * e - fi * f; vi[rr * n + k] -= fr * f + fi * e
                }
            }
        }
        return (vr, vi)
    }
}

/// 滑動平均（半寬 h，邊界縮窗）
func boxSmooth(_ x: [Double], _ h: Int) -> [Double] {
    let n = x.count
    guard n > 0, h > 0 else { return x }
    var pre = [Double](repeating: 0, count: n + 1)
    for k in 0..<n { pre[k + 1] = pre[k] + x[k] }
    return (0..<n).map { k in
        let a = max(0, k - h), b = min(n, k + h + 1)
        return (pre[b] - pre[a]) / Double(b - a)
    }
}

// MARK: - FFT

final class MonFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var pad: [Float]
    private var cr: [Float], ci: [Float]

    init(n: Int) {
        var l = 0
        while (1 << l) < n { l += 1 }
        self.n = 1 << l
        log2n = vDSP_Length(l)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        pad = [Float](repeating: 0, count: 1 << l)
        cr = pad; ci = pad
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// 實數 x[0..<count]（不足補 0）→ packed 頻譜 re/im（n/2；bin 0 的 im = Nyquist；數值 = 2 × DFT）
    func forward(_ x: UnsafePointer<Float>, count: Int, re: inout [Float], im: inout [Float]) {
        let c = min(count, n)
        pad.withUnsafeMutableBufferPointer { p in
            p.baseAddress!.update(from: x, count: c)
            if c < n { (p.baseAddress! + c).update(repeating: 0, count: n - c) }
        }
        if re.count != n / 2 { re = [Float](repeating: 0, count: n / 2) }
        if im.count != n / 2 { im = [Float](repeating: 0, count: n / 2) }
        let half = n / 2
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                pad.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &sc, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    /// 只有正頻率 bin [binLo, binLo+count) 的頻譜 → 複數反 FFT（長度 n）→ |·|（解析訊號包絡，lag 0..<n）
    func analyticEnvelope(re: [Double], im: [Double], binLo: Int) -> [Float] {
        for k in 0..<n { cr[k] = 0; ci[k] = 0 }
        for b in 0..<re.count where binLo + b < n / 2 {
            cr[binLo + b] = Float(re[b]); ci[binLo + b] = Float(im[b])
        }
        var out = [Float](repeating: 0, count: n)
        cr.withUnsafeMutableBufferPointer { rp in
            ci.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(setup, &sc, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                vDSP_zvabs(&sc, 1, &out, 1, vDSP_Length(n))
            }
        }
        return out
    }
}

// MARK: - 窗化 sinc 重取樣

struct MonResampler {
    static let halfTaps = 16
    static let phases = 512
    let table: [Float]          // [phase * 2h + tap]，tap t 對應樣本 floor(u) − h + 1 + t

    init(cutoff fc: Double) {
        let h = Self.halfTaps, P = Self.phases
        var t = [Float](repeating: 0, count: (P + 1) * 2 * h)
        for ph in 0...P {
            let frac = Double(ph) / Double(P)
            var sum = 0.0
            var row = [Double](repeating: 0, count: 2 * h)
            for k in 0..<(2 * h) {
                let x = frac - Double(k - h + 1)            // u − n
                let s = abs(x) < 1e-12 ? 1.0 : sin(Double.pi * fc * x) / (Double.pi * fc * x)
                let wx = x / Double(h)
                let win = abs(wx) >= 1 ? 0 : 0.42 + 0.5 * cos(Double.pi * wx) + 0.08 * cos(2 * Double.pi * wx)   // Blackman
                row[k] = fc * s * win
                sum += row[k]
            }
            for k in 0..<(2 * h) { t[ph * 2 * h + k] = Float(row[k] / sum) }   // 直流增益 1
        }
        table = t
    }

    /// x 在（非整數）位置 u 的值；支撐不足的部分當 0
    func value(_ x: UnsafeBufferPointer<Float>, at u: Double) -> Float {
        let h = Self.halfTaps
        let fl = u.rounded(.down)
        let base = Int(fl) - h + 1
        let ph = Int(((u - fl) * Double(Self.phases)).rounded())
        let row = ph * 2 * h
        var acc: Float = 0
        if base >= 0 && base + 2 * h <= x.count {
            table.withUnsafeBufferPointer { tp in
                vDSP_dotpr(x.baseAddress! + base, 1, tp.baseAddress! + row, 1, &acc, vDSP_Length(2 * h))
            }
        } else {
            for k in 0..<(2 * h) where base + k >= 0 && base + k < x.count { acc += x[base + k] * table[row + k] }
        }
        return acc
    }
}
