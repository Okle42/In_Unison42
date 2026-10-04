// ProgramPath.swift — 走「節目音路徑」的獨立量測：
//   calibrate --verify-program   三台喇叭對齊驗證（和 calibrate 不同的訊號、不同的演算法、不同的注入點）
//   calibrate --volume-test      系統音量／靜音是否同時控制三台（聲學量測，只調低不調高，結束還原）
//
// 和 calibrate / --verify 的差別（為什麼算「獨立量尺」）：
//   * 注入點：測試聲不是 engine.playTestSignal 排程進去的，而是另一個行程（/usr/bin/afplay）播放一個 WAV，
//     經 Process Tap → 延遲線 ring[(wp+f-d)&mask] → 增益 → 各喇叭，和使用者平常聽到的節目音完全同一條路徑。
//     （engine 用一般的 config.delayMs，不開監聽模式、不用測試訊號注入。）
//   * 訊號：帶通白雜訊脈衝（300 Hz–7 kHz、80 ms；預設），不是對數掃頻。
//     【2026-09-29】另有合成木琴 C5（`--signal xylo`；523.25 Hz 三個分音＋3 ms 帶通雜訊「喀」，播放 0.6 s，模板取前 300 ms，
//     GCC 改用 SNR 加權；見 XyloParams、PPGcc.weights）。實機驗收未通過，所以**不是預設**：這個房間的雜訊集中在低頻（300–600 Hz 比 4–7 kHz 高約 23 dB），
//     木琴的寬頻能量只有「喀」，GCC 峰值只比安靜段高 0–5 dB；而且這幾台喇叭的到達時間隨頻帶差 0.6–1.3 ms（色散），
//     木琴量到的是 4–7 kHz 的到達、雜訊量到的是全頻帶，兩者本來就不同。`--signal ab` 同一段錄音交錯比對兩種訊號。
//   * 演算法：GCC-PHAT（互功率譜相位白化）找到達時間，不是掃頻 I/Q 包絡互相關。
//   * 時間軸：只用麥克風自己的時間。WAV 裡脈衝間隔固定 P，用主時鐘喇叭（頭尾兩段）的到達時間擬合一條直線
//     （吸收麥克風時鐘漂移），其他喇叭脈衝對這條直線的殘差 = 相對主時鐘喇叭的到達差。完全不用 engine 的 sampleTime
//     換算延遲（engine 時間只用來決定「什麼時候切換 solo」和粗略搜尋窗）。
//   * 每次只讓一台出聲：engine 的診斷 solo（其他輸出增益 0），在脈衝之間的安靜處切換。
//   * 其他 App 的聲音：診斷模式下 engine 另開一個 tap 把 afplay 以外的行程全部靜音，所以量測期間不會混入音樂。
//   * 【v2】只驗證「目前模式下出聲的裝置」（engine.setMode(mode) 後 planEntry.active）；不出聲的輸出不 solo、不量。
//     參考喇叭 = 主時鐘輸出（它不出聲時改用第一台出聲的）。
//   * 【v2】麥克風可指定（--mic，同 calibrate；Continuity 也可以，會警告）；第一個脈衝先用寬搜尋窗找，
//     得到麥克風路徑延遲後所有搜尋窗一起平移（Continuity 延遲上百 ms 也找得到）。
//   * 【v3，2026-09-29】外接輸出（藍牙只輸出路徑）也量：子行程自己開 BluetoothOutManager（只 attach 輸出裝置，絕不開輸入），
//     solo 用 ProgramRing.externalSoloBase + 槽位；藍牙延遲 100–400 ms → 脈衝間隔至少 2 秒，
//     每台藍牙第一個脈衝另用寬窗（到 0.9 × 間隔）找自己的到達位置、搜尋窗各自平移。
//     --pulse 時未量測的藍牙照「未量測、不補償」出聲（Engine.allowUncalibratedExternal，只在這個子行程）才量得到。
import AudioToolbox
import Accelerate
import CoreAudio
import Foundation

enum PPParams {
    static let rate = 48000.0
    static let burstSeconds = 0.080
    static let bandLo = 300.0
    static let bandHi = 7000.0
    static let burstRmsDbFS = -20.0
    static let leadSeconds = 2.0
    static let tailSeconds = 1.0
    static let firTaps = 255
    static let toleranceMs = 1.0
    /// 【2026-09-29】`--verify-program` 對外接輸出（藍牙）的門檻：A2DP 經 codec／重傳，同一次連線量 8 次範圍 2.6 ms（ROADMAP），
    /// 用有線的 1 ms 永遠不會過。藍牙的「到達差」（對任一台出聲裝置）與「單台脈衝離散」都用這個門檻；有線之間維持 toleranceMs
    static let toleranceExternalMs = 3.0
    /// `calibrate --pulse` 寫入設定的條件：每台脈衝間離散要小於這個值
    static let writeMaxSpreadMs = 0.3
    /// 外接輸出（藍牙）用比較寬的條件：A2DP 經過 codec／重傳，到達時間抖動本來就比有線大。
    /// 不合格時只略過它（保留舊值與「需要重新校正」），其他裝置照寫——不會連累有線裝置的新值
    /// 【2026-09-29】1.0 → 1.5 ms：跟著驗證門檻放寬（藍牙 3 ms），取驗證門檻的一半。有線是 0.3／1（30%）；藍牙不照 30%（0.9 ms）
    /// 是因為實機同一次量測裡 A2DP 單一脈衝就偏過 0.65 ms（E2-verify-pilot：413.08／413.08／413.17／413.74），0.9 太貼、容易整台略過
    static let writeMaxSpreadExternalMs = 1.5
    /// 【2026-10-04 Kang 定案】藍牙寬鬆退路：嚴格窗（1.5 ms）湊不到一致群時，改用這個窗寬的最大一致群、取**中位數**寫入。
    /// MK-99 每個脈衝的延遲本來就跳 2–7 ms（不是音量不夠：匹配濾波比安靜段高 37 dB），1.5 ms 永遠過不了 → 一直不出聲；
    /// 音樂模式差幾 ms 聽不出來（聲音走 34 cm 就 1 ms），寧可粗一點也要出聲
    static let writeMaxSpreadExternalLooseMs = 10.0
    /// GCC-PHAT 峰值對「同長度純雜訊段（脈衝之間的安靜處）的 GCC-PHAT 最大值」的比值下限。
    /// 不用「峰值對旁瓣」：內建喇叭在機殼裡，反射造成的旁瓣本來就只低 3～4 dB，那不代表偵測失敗。
    static let minSnrDb = 6.0
    /// 【2026-09-29】`calibrate --pulse` 寫入：每台取「最大一致群」——寬度 writeMaxSpread(External)Ms 的窗裡成員最多的一群
    /// （平手取較早的群＝直達聲），成員要 ≥ writeMinCluster 且 ≥ 一半的脈衝。取代舊的「中位數 ±0.2 ms」
    /// （6 個脈衝 3／3 分成兩群時中位數落在中間 → 0 個被採用 → 整次不寫）。
    static let writeMinCluster = 3
    /// 【2026-10-04】參考喇叭直線擬合：偏離超過這個（ms）的脈衝當離群（反射）剔除後重擬合（ppRobustFit）
    static let refOutlierMs = 1.0
    /// 【2026-10-04】有線裝置反射感知：晚到那組比早到那組晚這個範圍（ms）才當成反射（內建喇叭實測 +3.8 ms）
    static let refReflectionMinMs = 2.0
    static let refReflectionMaxMs = 6.0
    /// 【2026-10-04】換參考喇叭的條件：候選的峰值對旁瓣（中位數）比目前參考好這麼多 dB、最小 SNR ≥ refMinSnrDb、有效脈衝 ≥ 4
    static let refSwitchMarginDb = 3.0
    static let refMinSnrDb = 10.0
    /// 【2026-09-29 第二版】柔和版測試音：粉紅雜訊、只含 1–4 kHz、80 ms、RMS −22 dBFS（原白雜訊 −20）。
    /// 「延遲」定義成 1–4 kHz 的群延遲：GCC-PHAT 只用 1–4 kHz，取**包絡**（解析訊號絕對值）的峰值，不取載波峰——
    /// 1–4 kHz 的載波週期 0.25–1 ms，取載波峰會在相鄰週期間跳（就是以前 0.4–1.4 ms 的雙值）；包絡峰＝這個頻帶的群延遲，
    /// 不受相位響應（喇叭色散）影響
    static let pinkLo = 1000.0
    static let pinkHi = 4000.0
    static let pinkRmsDbFS = -22.0
    /// 校正子行程：音量來源以外的輸出（HDMI／DP、藍牙）用固定增益（不乘系統音量）。−8 dB × RMS −22 → 約 −30 dBFS RMS
    static let calibrationGainDb = -8.0
    /// 校正子行程：外接輸出（藍牙）的固定增益。GLASS5+ 音量 100% 放在 C270 旁時 −8 dB 會讓麥克風削波（0 dBFS）
    /// 【2026-10-04】−24 → −12 dB：藍牙通常放得比較遠，−24 dB 時麥克風只收到 SNR 7–10 dB（門檻 6），常常「量測不穩」。
    /// 削波時 app 自動用 calibrationGainExternalFallbackDb 再量一次（CalibrationRunner；環境變數 btCalGainEnv 傳給子行程）
    static let calibrationGainExternalDb = -12.0
    static let calibrationGainExternalFallbackDb = -24.0
    /// 子行程讀這個環境變數（dB）覆蓋 calibrationGainExternalDb（只給 app 的削波重試用；發行版白名單不必開新參數）
    static let btCalGainEnv = "IN_UNISON42_BT_CAL_GAIN_DB"
    /// 削波時印這行（app 據此決定要不要降低藍牙測試音重試）
    static let micClipMarker = "@@mic-clip"
    /// 校正子行程：外接輸出（藍牙）的 150 Hz pilot（見 BTRenderer.render）。
    /// 【2026-09-29】−40 → −50 dBFS，而且**只在藍牙脈衝前後送**（ppPilotWindows）：之前整段校正都送 −40，耳機裡聽得到嗡聲
    static let bluetoothPilotDb = -50.0
    /// 【2026-09-29 第 C 輪驗收後】短量測（約 7 秒）的 pilot 用 −40 dBFS。實測：節目音先靜止 ≥ 5 秒（空檔、等安靜）再跑的短量測
    /// 7 次都量不到或不一致（累加峰值比安靜段 −3…+8 dB），同一時段音樂中直接跑的 3 次都量到（11.6–13.9 dB）→ 推測 GLASS5+
    /// 靜止一陣子後功放／靜音閘門關上，−50 dBFS 的 pilot 叫不醒（2026-09-29 最早的實測：−40 dBFS pilot 才讓 5 個脈衝都量到）。
    /// 只有短量測這 7 秒用 −40（完整校正仍 −50、只在藍牙脈衝前後送：45 秒一直嗡太吵）
    static let shortPilotDb = -40.0
    /// pilot 在每個藍牙脈衝前多久打開（秒；以「脈衝進入延遲線」的時間為準，pilot 與脈衝走同一個藍牙裝置，裝置延遲相同）
    static let pilotLeadSeconds = 1.0
    /// 每台藍牙第一個脈衝（暖機、丟棄）前 pilot 先送多久（秒）
    static let pilotWarmupSeconds = 3.0
    /// pilot 在脈衝播完後多久關掉（秒；另加補償延遲與外接輸出的固定緩衝）
    static let pilotTailSeconds = 0.2
    /// verify／pulse 每台（參考喇叭以外）的脈衝數：2 輪 × 2
    static let pulsesPerOutputPerRound = 2
    /// 麥克風峰值 ≥ 這個值（dBFS）＝ 削波，整次量測不採用
    static let micClipDb: Double = -1
    /// 沒有藍牙時的最短脈衝間隔（秒）。`--pulse` 量測時補償歸 0，有線裝置就用這個間隔
    static let minPeriodSeconds = 0.8
    /// 【2026-09-29 第 C 輪】藍牙短量測（`--pulse --only <藍牙>` 短校正、`--verify-program --only <藍牙>` 只量藍牙的驗證）：
    /// `--only` 只有一台、已有上次延遲值的藍牙時用。序列 參考×shortRefPulses → 藍牙×shortPulses（不丟暖機脈衝）→ 參考×shortRefPulses；
    /// 藍牙搜尋窗以上次的延遲為中心 ±shortHalfWindowMs（重連延遲跳 35–61 ms、同串流漂移每 30 分鐘約 23 ms 都在窗內），
    /// 藍牙的「安靜段」取脈衝**之前**半個週期（之後半個週期會碰到下一個參考脈衝）；pilot 從藍牙輸出啟動就開（暖機和準備時間重疊）。
    /// 補償一律歸 0（同 --pulse）。窗外（找不到）→ `@@short-miss <uid>`，app 改跑完整校正（`--full`）
    static let shortPulses = 4
    /// 【2026-10-04】短量測前後各幾個參考脈衝：2 → 3。2+2 時參考喇叭撿到反射（+4 ms）的那對分不出哪個是直達
    /// （例：+1.886／−2.252｜+0.309／+0.057），穩健擬合剔不得（剔錯會悄悄寫入偏 2–4 ms 的值）→ 整次失敗、5 分鐘後重試（log 77 次失敗 9 次）。
    /// 3+3：6 點剔 1–2 個仍有 ≥ 4 點互相驗證。每次多約 1.8 秒
    static let shortRefPulses = 3
    static let shortHalfWindowMs = 150.0
    static let shortLeadSeconds = 1.5
    static let shortTailExtraMs = 300.0
    static let shortMinPeriodSeconds = 0.85
}

/// 【第 C 輪】短量測的脈衝間隔：藍牙最晚可能的到達（上次延遲＋麥克風路徑約 60 ms＋窗半寬 150 ms）之後，
/// 下一個參考脈衝的搜尋窗才開始 → 上次延遲 + 0.46 s（取 0.05 s 的倍數），最少 0.85 s。GLASS5+（約 436 ms）→ 0.9 s
func ppShortPeriod(hintMs: Double) -> Double {
    let p = (max(0, hintMs) / 1000 + 0.06 + 0.40)
    return max(PPParams.shortMinPeriodSeconds, (p * 20).rounded(.up) / 20)
}

/// 【第 C 輪】短量測的計畫：hintMs[外接輸出 index] = 上次量到的相對延遲（ms，補償 0 時相對參考喇叭的到達差）
struct PPShortPlan {
    var hintMs: [Int: Double]
    var halfWindowMs = PPParams.shortHalfWindowMs
}

/// 固定種子的粉紅雜訊脈衝（只含 lo–hi Hz：頻域 1/√f 振幅、隨機相位、頻帶邊緣 200 Hz 升餘弦；5 ms 淡入淡出；RMS pinkRmsDbFS）
func ppPinkBurst(rate: Double, lo: Double = PPParams.pinkLo, hi: Double = PPParams.pinkHi) -> [Float] {
    let n = Int(PPParams.burstSeconds * rate)
    var l = 1
    while (1 << l) < n { l += 1 }
    let N = 1 << l
    var s: UInt64 = 0x7019_4B1E_5EED_0001
    func rnd() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
    var re = [Float](repeating: 0, count: N / 2), im = [Float](repeating: 0, count: N / 2)
    let edge = 200.0
    for k in 1..<(N / 2) {
        let f = Double(k) * rate / Double(N)
        var a = 0.0
        if f >= lo - edge && f <= hi + edge {
            a = 1 / sqrt(f)
            if f < lo { a *= 0.5 - 0.5 * cos(Double.pi * (f - (lo - edge)) / edge) }
            if f > hi { a *= 0.5 + 0.5 * cos(Double.pi * (f - hi) / edge) }
        }
        let ph = 2 * Double.pi * rnd()
        re[k] = Float(a * cos(ph)); im[k] = Float(a * sin(ph))
    }
    let setup = vDSP_create_fftsetup(vDSP_Length(l), FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    var y = [Float](repeating: 0, count: N)
    re.withUnsafeMutableBufferPointer { rp in
        im.withUnsafeMutableBufferPointer { ip in
            var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_fft_zrip(setup, &sc, 1, vDSP_Length(l), FFTDirection(kFFTDirection_Inverse))
            y.withUnsafeMutableBytes { raw in vDSP_ztoc(&sc, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(N / 2)) }
        }
    }
    var x = Array(y.prefix(n))
    let fade = Int(0.005 * rate)
    for i in 0..<fade {
        let w = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade)))
        x[i] *= w; x[n - 1 - i] *= w
    }
    var rms: Float = 0
    vDSP_rmsqv(x, 1, &rms, vDSP_Length(n))
    var g = Float(pow(10, PPParams.pinkRmsDbFS / 20)) / max(rms, 1e-12)
    vDSP_vsmul(x, 1, &g, &x, 1, vDSP_Length(n))
    return x
}

// MARK: - 測試音：木琴 C5（預設）／帶通雜訊（--signal noise）

/// 合成木琴中音 C5（2026-09-29 Kang 選定，取代聽起來刺耳的帶通雜訊）。參數照 docs/tone-samples 的 Python 原型：
///   分音 (比例, 振幅, 衰減秒) = (1, 1, 0.45)、(3.93, 0.35, 0.12)、(9.2, 0.12, 0.04)，起音包絡 1 − exp(−t/0.8 ms)；
///   敲擊瞬間疊加 3 ms 帶通雜訊「喀」（300 Hz–7 kHz、指數衰減、峰值 = 音色峰值 × 0.5，固定亂數種子）；整體峰值 −12 dBFS。
///   GCC-PHAT 的模板用前 300 ms（喀＋起音＋前段餘韻）。
///   播放長度 0.6 s：0.45 s 起升餘弦淡出（0.45 s 時已衰減 8.7 dB），脈衝間隔依播放長度加大，前一下的餘韻不會進到下一下的搜尋窗與安靜段。
enum XyloParams {
    static let f0 = 523.25
    static let partials: [(ratio: Double, amp: Double, decay: Double)] = [(1, 1, 0.45), (3.93, 0.35, 0.12), (9.2, 0.12, 0.04)]
    static let attackTau = 0.0008
    static let peakDbFS = -12.0
    static let templateSeconds = 0.300
    static let noteSeconds = 0.600
    static let fadeStartSeconds = 0.450
}

struct PPSignal: Hashable, CustomStringConvertible {
    enum Kind: String { case xylophone, noise, pink }
    var kind: Kind
    /// 木琴「喀」的長度與峰值比（驗收 C：藍牙量不到時加強成 5 ms／0.7）
    var clickSeconds = 0.003
    var clickPeakRatio = 0.5

    static let xylophone = PPSignal(kind: .xylophone)
    static let xylophoneStrongClick = PPSignal(kind: .xylophone, clickSeconds: 0.005, clickPeakRatio: 0.7)
    static let noise = PPSignal(kind: .noise)
    static let pink = PPSignal(kind: .pink)

    /// CLI：xylo｜xylophone｜c5 → 木琴；xylo-strong → 木琴＋加強的喀；noise → 雜訊
    static func parse(_ s: String) -> PPSignal? {
        switch s.lowercased() {
        case "xylo", "xylophone", "c5": return .xylophone
        case "xylo-strong", "xylophone-strong", "c5-strong": return .xylophoneStrongClick
        case "noise", "white": return .noise
        case "pink": return .pink
        default: return nil
        }
    }

    var description: String {
        switch kind {
        case .noise: return "帶通白雜訊脈衝（300 Hz–7 kHz、80 ms；舊版）"
        case .pink: return "粉紅雜訊脈衝（1–4 kHz、80 ms、RMS −22 dBFS；延遲＝1–4 kHz 群延遲）"
        case .xylophone:
            return String(format: "木琴 C5（523.25 Hz、播放 %.1f s、喀 %.0f ms／峰值 ×%.1f）", XyloParams.noteSeconds, clickSeconds * 1000, clickPeakRatio)
        }
    }

    /// 播放（WAV）裡一下的長度：脈衝間隔與 solo 切換餘裕用它算
    var soundSeconds: Double { kind == .xylophone ? XyloParams.noteSeconds : PPParams.burstSeconds }

    /// GCC 用的頻帶與「取包絡峰」：粉紅 = 1–4 kHz、包絡；其他 = 300 Hz–7 kHz、載波峰（舊行為）
    var gccBand: (lo: Double, hi: Double) { kind == .pink ? (PPParams.pinkLo, PPParams.pinkHi) : (PPParams.bandLo, PPParams.bandHi) }
    var gccEnvelope: Bool { kind == .pink }

    /// 播放用的一下
    func playback(rate: Double) -> [Float] {
        switch kind {
        case .noise: return ppBurst(rate: rate)
        case .pink: return ppPinkBurst(rate: rate)
        case .xylophone: return ppXylophone(rate: rate, clickSeconds: clickSeconds, clickPeakRatio: clickPeakRatio)
        }
    }

    /// GCC-PHAT／匹配濾波的參考模板：雜訊 = 整個脈衝；木琴 = 前 300 ms
    func template(rate: Double) -> [Float] {
        let p = playback(rate: rate)
        guard kind == .xylophone else { return p }
        return Array(p.prefix(Int((XyloParams.templateSeconds * rate).rounded())))
    }
}

/// 木琴 C5 一下（播放長度 XyloParams.noteSeconds），峰值 −12 dBFS。固定種子，同一取樣率每次都一樣
func ppXylophone(rate: Double, clickSeconds: Double = 0.003, clickPeakRatio: Double = 0.5) -> [Float] {
    let n = Int((XyloParams.noteSeconds * rate).rounded())
    var y = [Double](repeating: 0, count: n)
    let fadeA = XyloParams.fadeStartSeconds, fadeB = XyloParams.noteSeconds
    for i in 0..<n {
        let t = Double(i) / rate
        var v = 0.0
        for p in XyloParams.partials { v += p.amp * exp(-t / p.decay) * sin(2 * Double.pi * XyloParams.f0 * p.ratio * t) }
        v *= 1 - exp(-t / XyloParams.attackTau)
        if t > fadeA { v *= 0.5 + 0.5 * cos(Double.pi * min(1, (t - fadeA) / (fadeB - fadeA))) }
        y[i] = v
    }
    let tonalPeak = y.map(abs).max() ?? 1
    // 喀：帶通白雜訊（同 ppBurst 的 FIR）× 指數衰減（τ = 長度／4，結尾約 −35 dB），峰值 = 音色峰值 × clickPeakRatio
    let m = Int((clickSeconds * rate).rounded())
    if m > 0 {
        var s: UInt64 = 0x0C5C_1C4B_ADD1_7E57
        func rnd() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53) * 2 - 1
        }
        let h = ppBandpass(rate: rate)
        let white = (0..<(m + h.count)).map { _ in Float(rnd()) }
        var c = [Float](repeating: 0, count: m)
        vDSP_conv(white, 1, h, 1, &c, 1, vDSP_Length(m), vDSP_Length(h.count))
        let tau = clickSeconds / 4
        var cd = (0..<m).map { Double(c[$0]) * exp(-Double($0) / rate / tau) }
        let cp = cd.map(abs).max() ?? 1
        let g = clickPeakRatio * tonalPeak / max(cp, 1e-12)
        for i in 0..<m { cd[i] *= g; y[i] += cd[i] }
    }
    let peak = y.map(abs).max() ?? 1
    let target = pow(10, XyloParams.peakDbFS / 20)
    return y.map { Float($0 / peak * target) }
}

// MARK: - 訊號

/// 固定種子的帶通白雜訊脈衝（300 Hz–7 kHz，5 ms 升餘弦淡入淡出，RMS −20 dBFS）
func ppBurst(rate: Double) -> [Float] {
    let n = Int(PPParams.burstSeconds * rate)
    var s: UInt64 = 0x1234_5678_9abc_def1
    func rnd() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53) * 2 - 1
    }
    let white = (0..<(n + PPParams.firTaps)).map { _ in Float(rnd()) }
    let h = ppBandpass(rate: rate)
    var y = [Float](repeating: 0, count: n)
    vDSP_conv(white, 1, h, 1, &y, 1, vDSP_Length(n), vDSP_Length(h.count))
    let fade = Int(0.005 * rate)
    for i in 0..<fade {
        let w = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade)))
        y[i] *= w
        y[n - 1 - i] *= w
    }
    var rms: Float = 0
    vDSP_rmsqv(y, 1, &rms, vDSP_Length(n))
    let target = Float(pow(10, PPParams.burstRmsDbFS / 20))
    var g = target / max(rms, 1e-9)
    vDSP_vsmul(y, 1, &g, &y, 1, vDSP_Length(n))
    return y
}

/// 視窗化 sinc 帶通 FIR（Blackman）
func ppBandpass(rate: Double) -> [Float] {
    let m = PPParams.firTaps
    let c = Double(m - 1) / 2
    let f1 = PPParams.bandLo / rate, f2 = PPParams.bandHi / rate
    return (0..<m).map { i in
        let x = Double(i) - c
        let ideal = x == 0 ? 2 * (f2 - f1) : (sin(2 * Double.pi * f2 * x) - sin(2 * Double.pi * f1 * x)) / (Double.pi * x)
        let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(m - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(m - 1))
        return Float(ideal * w)
    }
}

/// 16-bit PCM 單聲道 WAV
func ppWriteWav(_ x: [Float], rate: Int, to url: URL) throws {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = UInt32(x.count * 2)
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(bytes)
    for v in x {
        let c = Int16(max(-32767, min(32767, (Double(v) * 32767).rounded())))
        u16(UInt16(bitPattern: c))
    }
    try d.write(to: url, options: .atomic)
}

// MARK: - GCC-PHAT

final class PPGcc {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var tRe: [Float], tIm: [Float]
    /// 模板每個 bin 的功率 |T|²
    private var tPow: [Float]
    private let binLo: Int, binHi: Int
    let templateCount: Int
    let rate: Double
    /// SNR 加權（木琴用）：每個 bin 的雜訊功率（安靜段平均、頻率上平滑）。nil = 純 GCC-PHAT（每個 bin 等權重）
    private(set) var noisePow: [Float]?
    /// true：曲線 = 解析訊號的絕對值（包絡；頻帶的群延遲），不是實數互相關（載波）
    let envelope: Bool

    init(template: [Float], searchLength: Int, rate: Double, band: (lo: Double, hi: Double) = (PPParams.bandLo, PPParams.bandHi),
         envelope: Bool = false) {
        self.envelope = envelope
        self.rate = rate
        var l = 1
        while (1 << l) < searchLength + template.count { l += 1 }
        log2n = vDSP_Length(l)
        n = 1 << l
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        templateCount = template.count
        var padded = template + [Float](repeating: 0, count: n - template.count)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        binLo = max(1, Int(band.lo / rate * Double(n)))
        binHi = min(n / 2 - 1, Int(band.hi / rate * Double(n)))
        PPGcc.forward(&padded, &re, &im, setup, log2n, n)
        tRe = re
        tIm = im
        tPow = (0..<re.count).map { re[$0] * re[$0] + im[$0] * im[$0] }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    private static func forward(_ x: inout [Float], _ re: inout [Float], _ im: inout [Float], _ setup: FFTSetup, _ log2n: vDSP_Length, _ n: Int) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &sc, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    private func spectrum(_ seg: [Float]) -> ([Float], [Float]) {
        var x = seg + [Float](repeating: 0, count: max(0, n - seg.count))
        if x.count > n { x = Array(x.prefix(n)) }
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        PPGcc.forward(&x, &re, &im, setup, log2n, n)
        return (re, im)
    }

    /// 安靜段的平均功率譜（每段長度 m = 2 的次方；回傳 m/2 個 bin 的 |X|² 平均）
    static func noiseSpectrum(_ segs: [[Float]], m: Int) -> [Double] {
        var l = 1
        while (1 << l) < m { l += 1 }
        let setup = vDSP_create_fftsetup(vDSP_Length(l), FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var acc = [Double](repeating: 0, count: m / 2)
        for sg in segs {
            var x = Array(sg.prefix(m)) + [Float](repeating: 0, count: max(0, m - sg.count))
            var re = [Float](repeating: 0, count: m / 2), im = [Float](repeating: 0, count: m / 2)
            forward(&x, &re, &im, setup, vDSP_Length(l), m)
            for k in 0..<(m / 2) { acc[k] += Double(re[k] * re[k] + im[k] * im[k]) }
        }
        return acc.map { $0 / Double(max(segs.count, 1)) }
    }

    /// 啟用 SNR 加權：psd = noiseSpectrum(…, m)（長度 m 的安靜段），換算到這個 FFT 長度 n（頻率內插、功率 × n/m），再 ±16 bin 平滑
    func setNoise(psd: [Double], m: Int) {
        guard !psd.isEmpty else { return }
        let scale = Double(n) / Double(m)
        let raw: [Double] = (0..<(n / 2)).map { k in
            let x = Double(k) * Double(m) / Double(n)
            let i = min(Int(x), psd.count - 1), j = min(i + 1, psd.count - 1)
            let f = x - Double(i)
            return (psd[i] * (1 - f) + psd[j] * f) * scale
        }
        let h = 16
        var pre = [Double](repeating: 0, count: n / 2 + 1)
        for k in 0..<(n / 2) { pre[k + 1] = pre[k] + raw[k] }
        noisePow = (0..<(n / 2)).map { k in
            let a = max(0, k - h), b = min(n / 2, k + h + 1)
            return Float(max((pre[b] - pre[a]) / Double(b - a), 1e-30))
        }
    }

    /// 每個 bin 的權重。PHAT：頻帶內 1。SNR 加權：w = SNR/(1+SNR)，SNR_f = g²·|T_f|²／N_f，
    /// g² = 頻帶內 Σ(|X|² − N) ／ Σ|T|²（這一窗收到的訊號增益）。
    /// 木琴的寬頻能量只有 3 ms 的喀，大部分 bin 是房間雜訊：PHAT 讓它們等權重 → 峰值被雜訊淹沒（2026-09-29 實機 SNR 0–5 dB）。
    /// 加權後只信任「模板在那裡有能量、且高過雜訊」的 bin（分音＋喀），仍保留 PHAT 的相位白化（峰值窄）。
    func weights(for seg: [Float]) -> [Float] {
        var w = [Float](repeating: 0, count: n / 2)
        guard let np = noisePow else {
            for k in binLo...binHi { w[k] = 1 }
            return w
        }
        let (re, im) = spectrum(seg)
        var sx = 0.0, st = 0.0
        for k in binLo...binHi {
            sx += max(0, Double(re[k] * re[k] + im[k] * im[k]) - Double(np[k]))
            st += Double(tPow[k])
        }
        let g2 = sx / max(st, 1e-30)
        for k in binLo...binHi {
            let snr = g2 * Double(tPow[k]) / Double(np[k])
            w[k] = Float(snr / (1 + snr))
        }
        return w
    }

    /// seg（長度 ≤ n）的 GCC 曲線（lag 0..<n）。w = nil：用這一窗自己的權重（weights(for:)）；
    /// 安靜段比較時要傳「脈衝窗的權重」，兩邊才是同一個濾波器
    func curve(_ seg: [Float], weights w0: [Float]? = nil) -> [Float] {
        let w = w0 ?? weights(for: seg)
        var (re, im) = spectrum(seg)
        // G = X · conj(T)，PHAT：G / |G|，再乘權重（頻帶外權重 0）
        for k in 0..<(n / 2) {
            if w[k] == 0 { re[k] = 0; im[k] = 0; continue }
            let a = re[k], b = im[k], c = tRe[k], d = tIm[k]
            let gr = a * c + b * d
            let gi = b * c - a * d
            let mag = sqrt(gr * gr + gi * gi) + 1e-20
            re[k] = w[k] * gr / mag
            im[k] = w[k] * gi / mag
        }
        var r = [Float](repeating: 0, count: n)
        if envelope {
            // 解析訊號：只留正頻率（DC、Nyquist 已在頻帶外＝0），複數反 FFT，取絕對值
            var cr = [Float](repeating: 0, count: n), ci = [Float](repeating: 0, count: n)
            for k in 1..<(n / 2) { cr[k] = re[k]; ci[k] = im[k] }
            cr.withUnsafeMutableBufferPointer { rp in
                ci.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(setup, &sc, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    vDSP_zvabs(&sc, 1, &r, 1, vDSP_Length(n))
                }
            }
            return r
        }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                r.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&sc, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(n / 2))
                }
            }
        }
        return r
    }

    /// seg（長度 ≤ n）裡找模板；回傳 (位置＝模板起點相對 seg[0]、次樣本；峰值對旁瓣 dB)。只搜尋 lag 0..<maxLag
    func locate(_ seg: [Float], maxLag: Int, weights w: [Float]? = nil) -> (pos: Double, peak: Double, psrDb: Double, sideMs: Double) {
        peak(in: curve(seg, weights: w), maxLag: maxLag)
    }

    /// 在 GCC 曲線（可以是多個脈衝的曲線相加）裡找峰值
    func peak(in r: [Float], maxLag: Int) -> (pos: Double, peak: Double, psrDb: Double, sideMs: Double) {
        let L = min(maxLag, n - 1)
        var best = 0
        for i in 0..<L where r[i] > r[best] { best = i }
        var delta = 0.0
        if best > 0 && best < L - 1 {
            let ym = Double(r[best - 1]), y0 = Double(r[best]), yp = Double(r[best + 1])
            let den = ym - 2 * y0 + yp
            if den < 0 { delta = min(0.5, max(-0.5, 0.5 * (ym - yp) / den)) }
        }
        let ex = Int(0.002 * PPParams.rate)
        var side: Float = 1e-20
        var sideAt = best
        for i in 0..<L where abs(i - best) > ex && abs(r[i]) > side { side = abs(r[i]); sideAt = i }
        return (Double(best) + delta, Double(r[best]), 20 * log10(Double(r[best]) / Double(side)),
                Double(sideAt - best) / rate * 1000)
    }
}

// MARK: - 共用流程

struct PPFail: Error { let msg: String; init(_ m: String) { msg = m } }

private struct PPPulse {
    let output: Int          // PPTarget.index（solo 對象）
    let state: Int           // volume-test 的狀態編號（verify 恆為 0）
    var signal: PPSignal = .noise
    /// true = 暖機用、不採用（每台藍牙的第一個脈衝：耳機剛從靜音醒來，第一下可能被吃掉一部分）
    var discard = false
}

/// 量測對象：聚合裝置輸出（solo = engine 輸出 index）＋外接輸出（藍牙；solo = externalSoloBase + 槽位）
struct PPTarget {
    let index: Int
    let solo: Int
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let isClock: Bool
    /// nil = 聚合裝置輸出
    let externalSlot: Int?
    var isExternal: Bool { externalSlot != nil }
}

/// 外接輸出（藍牙）參與時脈衝間隔的下限（秒）：藍牙比其他喇叭慢 100–400 ms，寬搜尋窗與安靜段都要放得下
private let ppExternalMinPeriod = 2.0
/// 外接輸出的延遲（BluetoothOut 的固定緩衝）要算進 solo 切換的餘裕
private let ppExternalGateSeconds = 0.060

/// 脈衝間隔：solo 在延遲線輸入端的半週期切換，延遲最大的那台的脈衝要在切換前播完。
/// soundSeconds = 一下的播放長度（雜訊 80 ms、木琴 600 ms）：木琴的餘韻要在 solo 切換前結束，
/// 下一下的搜尋窗與「半個週期後」的安靜段才不會混到前一下
private func ppPeriod(maxDelayMs: Double, hasExternal: Bool, soundSeconds: Double = PPParams.burstSeconds) -> Double {
    let p = max(PPParams.minPeriodSeconds, 2 * (maxDelayMs / 1000 + soundSeconds + (hasExternal ? ppExternalGateSeconds : 0)) + 0.3)
    return hasExternal ? max(p, ppExternalMinPeriod) : p
}

/// 【2026-09-29】脈衝序列（verify／pulse／離線自測共用）：
///   參考×2 → 各有線×per → 參考×2 → 各有線×per → 參考×2 → 每台藍牙 [暖機 1 個（丟棄）＋ 2·per 個] → 參考×2
/// 藍牙排在後段：pilot 只需要在後段送（ppPilotWindows；最多蓋到藍牙前面那組參考喇叭脈衝，150 Hz 在量測頻帶外）；
/// 每台藍牙前面先送 pilotWarmupSeconds 的 pilot 讓耳機醒來，第一個脈衝不採用。藍牙後面接參考×2，直線擬合是內插不是外插。
/// 沒有藍牙時和舊序列完全一樣。
private func ppSequence(clock: Int, wired: [Int], external: [Int], per: Int, signalOf: (Int) -> PPSignal) -> [PPPulse] {
    func p(_ o: Int, discard: Bool = false) -> PPPulse { PPPulse(output: o, state: 0, signal: signalOf(o), discard: discard) }
    var pulses: [PPPulse] = []
    for _ in 0..<2 {
        pulses += Array(repeating: p(clock), count: 2)
        for o in wired { pulses += Array(repeating: p(o), count: per) }
    }
    pulses += Array(repeating: p(clock), count: 2)
    for o in external {
        pulses.append(p(o, discard: true))
        pulses += Array(repeating: p(o), count: 2 * per)
        pulses += Array(repeating: p(clock), count: 2)
    }
    return pulses
}

/// 【第 C 輪】短量測序列：參考×r → 藍牙×n（不丟暖機：pilot 從藍牙啟動就開著）→ 參考×r（藍牙在中間＝內插）。
/// r = shortRefPulses（2026-10-04 由 2 改 3：直線擬合 6 點，反射可以剔除）
private func ppShortSequence(clock: Int, external: Int, count n: Int = PPParams.shortPulses, signal: PPSignal) -> [PPPulse] {
    func p(_ o: Int) -> PPPulse { PPPulse(output: o, state: 0, signal: signal, discard: false) }
    let r = PPParams.shortRefPulses
    return Array(repeating: p(clock), count: r) + Array(repeating: p(external), count: n) + Array(repeating: p(clock), count: r)
}

/// 麥克風片段 [start, start+n)，keep 之後補 0（GCC 只看 lag 0..<search；遮掉窗尾的其他脈衝，PHAT 白化才不會被它影響）
private func ppMaskedSegment(_ mic: [Float], start: Int, n: Int, keep: Int) -> [Float]? {
    guard start >= 0, start + min(n, keep) <= mic.count else { return nil }
    var s = [Float](repeating: 0, count: n)
    let m = min(keep, n, mic.count - start)
    for i in 0..<m { s[i] = mic[start + i] }
    return s
}

/// 【2026-09-29】pilot 開關時間（秒，相對「第 0 個脈衝進入延遲線」）：每個外接輸出的脈衝 k，
/// 開 = k·P − pilotLeadSeconds（該台的暖機脈衝：− pilotWarmupSeconds），關 = k·P + tailSeconds；重疊的合併。
/// pilot 在藍牙 render 時加進去、脈衝在延遲線進、藍牙 render 出（再加補償＋固定緩衝），兩者都再經過同一個藍牙裝置的延遲，
/// 所以以「脈衝進入延遲線」為基準、提前 1 秒就足夠（實際提前量還多了補償＋固定緩衝）。
func ppPilotWindows(externalPulse: [Bool], discard: [Bool], period: Double, tailSeconds: Double) -> [(on: Double, off: Double)] {
    var w: [(on: Double, off: Double)] = []
    for k in externalPulse.indices where externalPulse[k] {
        let lead = discard[k] ? PPParams.pilotWarmupSeconds : PPParams.pilotLeadSeconds
        let on = Double(k) * period - lead, off = Double(k) * period + tailSeconds
        if let last = w.last, on <= last.off { w[w.count - 1].off = max(last.off, off) } else { w.append((on, off)) }
    }
    return w
}

/// 子行程用：把目前的藍牙輸出（只輸出路徑）註冊進這個 engine。nil = 沒有藍牙或 --no-bluetooth
/// only：非 nil = 只開這些 uid 的藍牙（`--pulse --only` 沒指定藍牙就不開，省下藍牙 IO 啟動時間、也不送 pilot）
private func ppAttachBluetooth(_ engine: Engine, enabled: Bool, only: Set<String>? = nil) -> BluetoothOutManager? {
    guard enabled else { return nil }
    let bts = Devices.bluetoothOutputs().filter { only?.contains($0.uid) ?? true }
    guard !bts.isEmpty else { return nil }
    let m = BluetoothOutManager(engine: engine)
    m.watchDeviceList = false
    for d in bts {
        let ok = m.attach(deviceID: d.id)
        print(ok ? "藍牙「\(d.name)」：只輸出路徑已啟動（不開輸入）" : "✗ 藍牙「\(d.name)」無法啟動：\(m.errors[d.uid] ?? "?")")
    }
    return m
}

private func ppBluetoothStats(_ m: BluetoothOutManager?) {
    guard let m else { return }
    for (_, o) in m.outputs.sorted(by: { $0.key < $1.key }) {
        let rate = CA.f64(o.device.id, kAudioDevicePropertyNominalSampleRate) ?? 0
        print(String(format: "  藍牙「%@」：裝置取樣率 %.0f Hz、固定緩衝 %.0f ms；%@", o.device.name, rate, o.safetyMs ?? 0, o.stats.description))
        if let r = o.reportedLatency { print("    系統回報延遲（attach 時）：\(r)") }
    }
}

private struct PPCapture {
    var mic: [Float]
    var periodSeconds: Double
    var micRate: Double
    var pulseMicGuess: [Double]   // 每個脈衝的粗估麥克風位置（未含裝置延遲）
    var periodFrames: Int
    var names: [String]
    var clock: Int
    var maxDelayMs: Double
    /// 每個脈衝用的訊號（ppLocate 依它選模板）
    var signals: [PPSignal] = []
}

private func ppWait(timeout: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        usleep(2000)
    }
    return cond()
}

/// 播放脈衝序列並錄音。onState(k) 在切換到第 k 個狀態時（脈衝之間的安靜處）在控制執行緒上呼叫。
/// 外接輸出 pilot 的排程：amp = 線性振幅；windows = ppPilotWindows（秒，相對第 0 個脈衝進入延遲線）
struct PPPilotPlan {
    var amp: Float
    var windows: [(on: Double, off: Double)]
}

/// 【2026-09-29】縮短「app 拆 tap → 子行程建 tap」之間原音外漏的空窗：環境變數 IN_UNISON42_HANDOFF=1 時，
/// 子行程先把麥克風、藍牙、WAV、輸出清單都準備好，印 `@@handoff-ready`，等 stdin 一行 `go`（app 拆完自己的 tap 後寫）才啟動 afplay＋engine。
/// 同一時間只有一個 tap（app 拆完才建）。沒設環境變數 = 舊行為（app 先拆、子行程照順序準備）。app 端要配合（見 CalibrationRunner）。
private let ppHandoffDone = LockedValue(false)
/// deadline：最晚要在這之前收到 go（ppRun 傳「afplay 啟動 + leadSeconds − 0.4 秒」：再晚第一個脈衝就會被 app 還在跑的 tap 播出去）。
/// 逾時回傳 false，呼叫端立刻停掉 afplay（脈衝還沒播），不會把測試音送進 app 的 tap
private func ppWaitHandoff(deadline: Date) -> Bool {
    guard !ppHandoffDone.value, ProcessInfo.processInfo.environment["IN_UNISON42_HANDOFF"] == "1" else { return true }
    ppHandoffDone.value = true
    print("@@handoff-ready")
    fflush(stdout)
    let t0 = Date()
    var line = ""
    var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
    while Date() < deadline {
        let ms = Int32(max(1, min(200, deadline.timeIntervalSinceNow * 1000)))
        let r = poll(&pfd, 1, ms)
        if r > 0 {
            var c: UInt8 = 0
            let n = read(0, &c, 1)
            if n <= 0 { break }
            if c == 10 {
                if line.trimmingCharacters(in: .whitespaces) == "go" { print(String(format: "  app 已拆 tap（等待 %.2f 秒）", Date().timeIntervalSince(t0))); return true }
                line = ""
            } else { line.append(Character(UnicodeScalar(c))) }
        }
    }
    print(String(format: "✗ 等 app 拆 tap（stdin「go」）逾時（%.2f 秒）", Date().timeIntervalSince(t0)))
    return false
}

private func ppRun(engine: Engine, mic: AudioDevice, targets: [PPTarget], pulses: [PPPulse], periodSeconds: Double, tailExtraMs: Double = 0,
                   pilot: PPPilotPlan? = nil, leadSeconds: Double = PPParams.leadSeconds, onState: (Int) -> Void) -> Result<PPCapture, PPFail> {
    print("麥克風：\(mic.name)（\(Int(mic.nominalSampleRate)) Hz，只錄第 1 聲道；不改系統預設輸入）")
    if mic.kind == .continuity || mic.name.lowercased().contains("iphone") {
        print("⚠ Continuity（iPhone）麥克風：延遲大且可能抖動；本驗證用整段直線擬合，蜿蜒會直接變成殘差（結果偏保守）")
    }
    let rate = PPParams.rate
    let P = Int((periodSeconds * rate).rounded())
    var sounds: [PPSignal: [Float]] = [:]
    for p in pulses where sounds[p.signal] == nil { sounds[p.signal] = p.signal.playback(rate: rate) }
    let lead = Int(leadSeconds * rate)
    let maxSound = sounds.values.map(\.count).max() ?? 0
    var wav = [Float](repeating: 0, count: lead + pulses.count * P + max(Int(PPParams.tailSeconds * rate), maxSound))
    for k in 0..<pulses.count {
        for (i, v) in sounds[pulses[k].signal]!.enumerated() { wav[lead + k * P + i] = v }
    }
    let wavURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("In_Unison42-programpath-\(getpid()).wav")
    do { try ppWriteWav(wav, rate: Int(rate), to: wavURL) } catch { return .failure(PPFail("寫 WAV 失敗：\(error)")) }
    // 自己產生的暫存檔：直接刪（不是使用者的檔案，不進垃圾桶；以前 moveToTrash 會讓垃圾桶每次校正多一個 WAV）
    defer { try? FileManager.default.removeItem(at: wavURL) }
    let totalSeconds = Double(wav.count) / rate

    let rec = MicRecorder(device: mic, seconds: totalSeconds + 6)
    let ms = rec.start()
    guard ms == noErr else { return .failure(PPFail("麥克風開啟失敗 status=\(ms)")) }
    defer { rec.stop() }
    guard ppWait(timeout: 3, { rec.frames > Int(0.3 * rec.rate) }) else { return .failure(PPFail("麥克風沒有送資料進來")) }

    // afplay：節目音來源（另一個行程，經 tap 進延遲線）。
    // 交接模式下 afplay 在 app 交出 tap「之前」就啟動、先找好 process object（WAV 開頭 leadSeconds 是靜音，這段送到哪裡都聽不到），
    // 收到 go 之後只剩 engine.start → 原音外漏空窗只有拆 tap＋建 tap 的時間
    let playerStarted = Date()
    let player = Process()
    player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    player.arguments = [wavURL.path]
    player.standardOutput = FileHandle.nullDevice
    player.standardError = FileHandle.nullDevice
    do { try player.run() } catch { return .failure(PPFail("無法啟動 afplay：\(error)")) }
    defer { if player.isRunning { player.terminate() } }
    var obj: AudioObjectID = 0
    _ = ppWait(timeout: 1.5) {
        obj = Devices.processObject(pid: player.processIdentifier)
        return obj != 0
    }
    guard obj != 0 else { return .failure(PPFail("找不到 afplay 的 Core Audio process object")) }
    // 第一個脈衝在 afplay 啟動後 leadSeconds 播出；engine 要在那之前（留 0.4 秒建 tap／聚合裝置，實測約 0.1 秒）開始抓，否則 T0 會對到第二個脈衝。
    // 等 go 的上限就是這個時間點：app 太慢 → 逾時、defer 立刻停掉 afplay（脈衝還沒播），不會從 app 還在跑的 tap 播出測試音
    let handoffDeadline = playerStarted.addingTimeInterval(leadSeconds - 0.4)
    guard ppWaitHandoff(deadline: handoffDeadline) else {
        player.terminate()
        return .failure(PPFail(String(format: "app 交出 tap 太慢（afplay 啟動後 %.2f 秒還沒收到），已停止測試音；請再校正一次", Date().timeIntervalSince(playerStarted))))
    }
    let waited = Date().timeIntervalSince(playerStarted)
    guard waited < leadSeconds - 0.4 else {
        return .failure(PPFail(String(format: "app 交出 tap 太慢（afplay 啟動後 %.2f 秒），第一個脈衝可能已播出；請再校正一次", waited)))
    }

    engine.programProcesses = [obj]
    engine.setSolo(targets[pulses[0].output].solo)
    do { try engine.start() } catch { return .failure(PPFail("引擎啟動失敗：\(error)")) }
    // 輸出清單是沒啟動引擎前預測的（ppActiveOutputs）：啟動後依 uid 對回 engine 實際的 index／外接槽位
    var soloOf = targets.map(\.solo)
    let det = engine.outputDetails, ext = engine.externalOutputs
    for (i, t) in targets.enumerated() {
        if t.isExternal {
            guard let e = ext.first(where: { $0.uid == t.uid }) else { return .failure(PPFail("外接輸出「\(t.name)」沒有註冊在 engine")) }
            soloOf[i] = Engine.soloValue(externalSlot: e.slot)
        } else {
            guard let o = det.first(where: { $0.uid == t.uid }) else { return .failure(PPFail("「\(t.name)」不在 engine 的聚合裝置輸出裡（輸出清單在準備期間改變？）")) }
            soloOf[i] = o.index
        }
        if soloOf[i] != t.solo { print("  「\(t.name)」solo \(t.solo) → \(soloOf[i])（依 engine 實際輸出清單）") }
    }
    engine.setSolo(soloOf[pulses[0].output])
    let c0 = engine.ioCycles
    guard ppWait(timeout: 3, { engine.ioCycles > c0 + 4 }) else {
        return .failure(PPFail("引擎 IOProc 沒在跑（系統音訊錄製權限？）"))
    }
    onState(pulses[0].state)   // 引擎已在跑：狀態 0 的增益記錄才讀得到（afplay 開頭有 2 秒靜音，來得及）
    engine.armOnset(threshold: 0.02)
    let e1 = engine.sampleTime, m1 = rec.frames, e2 = engine.sampleTime
    let map = RoughMap(anchorEngine: (e1 + e2) / 2, anchorMic: Double(m1), ratio: rec.rate / engine.sampleRate)
    guard ppWait(timeout: leadSeconds + 3, { engine.onsetSampleTime != nil }), let T0 = engine.onsetSampleTime else {
        return .failure(PPFail("節目音路徑沒有收到 afplay 的脈衝（tap 沒抓到？）"))
    }
    let sr = engine.sampleRate
    let Pe = Int64((periodSeconds * sr).rounded())
    print(String(format: "  第 1 個脈衝進入延遲線：engine t=%lld（afplay 啟動後約 %.2f 秒）", T0, Double(T0 - e1) / sr + 0))
    // 從第一個樣本超過門檻處往前推到脈衝起點（淡入 5 ms 內），誤差只影響粗估搜尋窗
    // 事件（依 engine 時間排序）：solo 切換（脈衝之間的半週期處）＋外接輸出 pilot 開關
    enum Ev { case solo(Int), pilot(Bool) }
    var evs: [(at: Int64, ev: Ev)] = (1..<max(pulses.count, 1)).map { (T0 + Int64($0) * Pe - Pe / 2, .solo($0)) }
    for w in pilot?.windows ?? [] {
        evs.append((T0 + Int64((w.on * sr).rounded()), .pilot(true)))
        evs.append((T0 + Int64((w.off * sr).rounded()), .pilot(false)))
    }
    evs.sort { $0.at < $1.at }
    if let p = pilot, !p.windows.isEmpty {
        if engine.program.extPilot.pointee > 0 {
            print(String(format: "  藍牙 pilot：%.0f dBFS，藍牙輸出啟動時就開（短量測：暖機和準備時間重疊），第 1 個脈衝後 %.1f 秒關", 20 * log10(Double(p.amp)),
                         p.windows.last?.off ?? 0))
        } else {
            print(String(format: "  藍牙 pilot：%.0f dBFS，只在 %d 段送（合計 %.1f 秒；每台藍牙前暖機 %.0f 秒、每個藍牙脈衝前 %.0f 秒）", 20 * log10(Double(p.amp)),
                         p.windows.count, p.windows.reduce(0) { $0 + $1.off - $1.on }, PPParams.pilotWarmupSeconds, PPParams.pilotLeadSeconds))
        }
    }
    var lastState = pulses[0].state
    for e in evs {
        guard ppWait(timeout: max(periodSeconds * 2 + 2, Double(e.at - engine.sampleTime) / sr + 2), { engine.sampleTime >= e.at }) else {
            engine.program.extPilot.pointee = 0
            return .failure(PPFail("等待排程事件逾時"))
        }
        switch e.ev {
        case .solo(let k):
            if pulses[k].state != lastState { onState(pulses[k].state); lastState = pulses[k].state }
            engine.setSolo(soloOf[pulses[k].output])
        case .pilot(let on):
            // 直接寫共用值（Engine.calibrationPilotDb 每次寫都會記 log，一次校正要開關十幾次）；BTRenderer 自己做 100 ms 斜坡，不會喀
            engine.program.extPilot.pointee = on ? (pilot?.amp ?? 0) : 0
        }
    }
    engine.program.extPilot.pointee = 0
    let maxDelayMs = engine.status(resetPeaks: false).outputs.map(\.delayMs).max() ?? 0
    let endAt = T0 + Int64(pulses.count) * Pe + Int64(((maxDelayMs + tailExtraMs) / 1000 + 0.3) * sr)
    _ = ppWait(timeout: periodSeconds * 2 + 3) { engine.sampleTime >= endAt }
    let needMic = Int(map.mic(endAt))
    _ = ppWait(timeout: 2) { rec.frames >= min(needMic, rec.capacity) }
    rec.stop()
    engine.setSolo(-1)
    let names = targets.map(\.name)
    let clock = targets.first { $0.isClock }?.index ?? 0
    let mism = engine.inputMismatchCycles
    engine.stop()
    engine.programProcesses = nil
    // 交接模式：這個子行程之後不再建 tap（ppRun 一次指令只跑一次）→ 通知 app 可以立刻重建自己的 tap（不等分析、寫檔、行程結束）；
    // app 之後在子行程結束時只重讀設定（applyConfig，不重建）
    if ProcessInfo.processInfo.environment["IN_UNISON42_HANDOFF"] == "1" { print("@@tap-released"); fflush(stdout) }
    // 【第 C 輪】WAV 尾巴只剩靜音（我們的 tap 也已經拆了）：不等 afplay 播完（省約 1 秒），直接結束它
    if player.isRunning { player.terminate() }
    player.waitUntilExit()
    if rec.gaps > 0 { return .failure(PPFail("麥克風錄音中斷 \(rec.gaps) 次，結果不可信")) }
    if mism > 0 { return .failure(PPFail("IOProc 輸入 buffer 排列不符預期 \(mism) 次")) }
    let guesses = (0..<pulses.count).map { map.mic(T0 + Int64($0) * Pe) }
    let peakDb = 20 * log10(max(Double(rec.peak), 1e-10))
    print(String(format: "  錄到 %.2f 秒，麥克風峰值 %.1f dBFS", Double(rec.frames) / rec.rate, peakDb))
    // 削波的脈衝波形被截平，GCC 峰位置會偏；校正時外接輸出不再套用使用者的 trim（測試音可能比以前大），所以要擋
    if peakDb >= PPParams.micClipDb {
        print(PPParams.micClipMarker); fflush(stdout)
        return .failure(PPFail(String(format: "麥克風削波（峰值 %.1f dBFS ≥ %.0f）：測試音太大或麥克風離喇叭太近，結果不可信", peakDb, PPParams.micClipDb)))
    }
    return .success(PPCapture(mic: rec.samples(), periodSeconds: periodSeconds, micRate: rec.rate, pulseMicGuess: guesses, periodFrames: P,
                              names: names, clock: clock, maxDelayMs: maxDelayMs, signals: pulses.map(\.signal)))
}

/// 在每個脈衝的搜尋窗裡用 GCC-PHAT 找到達位置（麥克風 frame）
/// snr = 脈衝窗的 GCC-PHAT 峰值 ÷ 半個週期後（安靜處）同樣長度的窗的 GCC-PHAT 峰值（dB）
/// 每個脈衝用自己的訊號模板（cap.signals；木琴 = 前 300 ms、雜訊 = 整個脈衝）。只有 lag 0..<search 有意義，
/// 窗內 search + 模板長度之後的內容（例如下一下）不影響結果。
/// 【第 C 輪】短量測（short 非 nil）：外接輸出的寬窗以 hintMs 為中心 ±halfWindowMs（窗尾補 0），安靜段取脈衝**之前**半個週期；
/// 窗內找不到（峰值貼邊或累加 SNR 不足）→ 這台的脈衝全部回 nil、uid 記在 report.shortMiss
final class PPLocateReport { var shortMiss: Set<Int> = [] }

private func ppLocate(_ cap: PPCapture, pulses: [PPPulse] = [], externals: Set<Int> = [], quiet: Bool = false,
                      short: PPShortPlan? = nil, report: PPLocateReport? = nil) -> [(pos: Double, snr: Double, psr: Double, sideMs: Double)?] {
    let sigs = cap.signals.count == cap.pulseMicGuess.count ? cap.signals : Array(repeating: PPSignal.noise, count: cap.pulseMicGuess.count)
    var tmpls: [PPSignal: [Float]] = [:]
    for s in sigs where tmpls[s] == nil { tmpls[s] = s.template(rate: cap.micRate) }
    let pre = Int(0.030 * cap.micRate)
    let search = Int((0.030 + cap.maxDelayMs / 1000 + 0.150) * cap.micRate)
    // 木琴：SNR 加權的 GCC（見 PPGcc.weights）。雜訊功率譜取每個脈衝「半個週期後」的安靜段（長 8192，約 170 ms；
    // 間隔已依播放長度加大，這段不會有前一下的餘韻或下一下）
    let noiseM = 8192
    var noisePSD: [Double]? = nil
    if sigs.contains(where: { $0.kind == .xylophone }) {
        let segs: [[Float]] = cap.pulseMicGuess.compactMap { g in
            let a = Int(g.rounded()) + cap.periodFrames / 2
            return a >= 0 && a + noiseM <= cap.mic.count ? Array(cap.mic[a..<(a + noiseM)]) : nil
        }
        if !segs.isEmpty { noisePSD = PPGcc.noiseSpectrum(segs, m: noiseM) }
    }
    func makeGcc(_ sg: PPSignal, _ len: Int) -> PPGcc {
        let g = PPGcc(template: tmpls[sg]!, searchLength: len, rate: cap.micRate, band: sg.gccBand, envelope: sg.gccEnvelope)
        if sg.kind == .xylophone, let p = noisePSD { g.setNoise(psd: p, m: noiseM) }
        return g
    }
    var gccs: [PPSignal: PPGcc] = [:]
    for s in tmpls.keys { gccs[s] = makeGcc(s, search) }
    // 自適應：第一個脈衝（參考喇叭）用寬窗找 → 麥克風路徑延遲 → 所有窗平移（保留 100 ms 餘裕）
    var shift = 0.0
    var refDelta = 0.0
    if let g0 = cap.pulseMicGuess.first {
        let wide = Int(min(0.9 * cap.periodSeconds, 1.5) * cap.micRate)
        let ws = Int(g0.rounded()) - pre
        if ws >= 0 {
            let wg = makeGcc(sigs[0], wide)
            if ws + wg.n <= cap.mic.count {
                let r = wg.locate(Array(cap.mic[ws..<(ws + wg.n)]), maxLag: wide)
                let delta = Double(ws) + r.pos - g0
                refDelta = delta
                shift = max(0, delta - 0.100 * cap.micRate)
                if !quiet { print(String(format: "  麥克風路徑延遲約 %.1f ms（搜尋窗平移 %.1f ms）", delta / cap.micRate * 1000, shift / cap.micRate * 1000)) }
            }
        }
    }
    // 外接輸出（藍牙）：延遲比參考喇叭多上百 ms、事先不知道 → 用它自己第一個脈衝的寬窗（到 0.9 × 間隔）找，搜尋窗各自平移
    var extShift: [Int: Double] = [:]
    // 這台所有脈衝的寬窗 GCC-PHAT 曲線依「相對排程的 lag」相加（同相累加：N 個脈衝 SNR 約 +10·log10(N) dB，藍牙小聲也找得到），
    // 對比同樣相加的安靜段（半個週期後）
    for t in externals.sorted() {
        // 暖機脈衝（discard）不參加：耳機剛醒來，第一下可能被吃掉一部分
        guard let k0 = pulses.indices.first(where: { pulses[$0].output == t && !pulses[$0].discard }) else { continue }
        let ks = pulses.indices.filter { pulses[$0].output == t && sigs[$0] == sigs[k0] && !pulses[$0].discard }
        if let sp = short, let hint = sp.hintMs[t] {
            // 短量測：以上次延遲為中心的窄窗（±halfWindowMs），窗尾補 0；安靜段 = 脈衝前半個週期
            let half = Int(sp.halfWindowMs / 1000 * cap.micRate)
            let wide = 2 * half
            let wg = makeGcc(sigs[k0], wide)
            let keep = wide + wg.templateCount
            let base = Int((refDelta + hint / 1000 * cap.micRate).rounded()) - half
            var sum = [Float](repeating: 0, count: wg.n), qsum = [Float](repeating: 0, count: wg.n)
            var used = 0
            for k in ks {
                let ws = Int(cap.pulseMicGuess[k].rounded()) + base
                guard let seg = ppMaskedSegment(cap.mic, start: ws, n: wg.n, keep: keep),
                      let qseg = ppMaskedSegment(cap.mic, start: ws - cap.periodFrames / 2, n: wg.n, keep: keep) else { continue }
                let w = wg.weights(for: seg)
                let c = wg.curve(seg, weights: w), q = wg.curve(qseg, weights: w)
                vDSP_vadd(sum, 1, c, 1, &sum, 1, vDSP_Length(wg.n))
                vDSP_vadd(qsum, 1, q, 1, &qsum, 1, vDSP_Length(wg.n))
                used += 1
            }
            let r = used > 0 ? wg.peak(in: sum, maxLag: wide) : nil
            let qr = used > 0 ? wg.peak(in: qsum, maxLag: wide) : nil
            let snr = r.map { rr in 20 * log10(rr.peak / max(qr?.peak ?? 0, 1e-12)) } ?? -99
            let edge = Double(Int(0.010 * cap.micRate))
            guard let rr = r, rr.pos >= edge, rr.pos <= Double(wide) - edge, snr >= PPParams.minSnrDb else {
                report?.shortMiss.insert(t)
                if !quiet {
                    print(String(format: "⚠ 短量測：「%@」在預期到達（上次延遲 %.1f ms ± %.0f ms）的窗內找不到（%@、累加峰值比安靜段高 %.1f dB）：這台不採用",
                                 cap.names[t], hint, sp.halfWindowMs, r.map { String(format: "峰值在窗內 %.0f ms", $0.pos / cap.micRate * 1000) } ?? "沒有脈衝", snr))
                }
                continue
            }
            let delta = Double(base) + rr.pos
            extShift[t] = max(0, delta - 0.100 * cap.micRate)
            if !quiet {
                print(String(format: "  「%@」（外接，短量測）%d 個脈衝窄窗（上次 %.1f ms ± %.0f ms）同相累加：比排程晚 %.1f ms（參考喇叭約 %.1f ms），累加峰值比安靜段（脈衝前）高 %.1f dB",
                             cap.names[t], used, hint, sp.halfWindowMs, delta / cap.micRate * 1000, refDelta / cap.micRate * 1000, snr))
            }
            continue
        }
        let wide = Int(min(0.45 * cap.periodSeconds, 0.9) * cap.micRate)
        let wg = makeGcc(sigs[k0], wide)
        var sum = [Float](repeating: 0, count: wg.n), qsum = [Float](repeating: 0, count: wg.n)
        var used = 0
        let off = Int((shift).rounded()) - pre
        for k in ks {
            let ws = Int(cap.pulseMicGuess[k].rounded()) + off
            let qs = ws + cap.periodFrames / 2
            guard ws >= 0, qs + wg.n <= cap.mic.count else { continue }
            let seg = Array(cap.mic[ws..<(ws + wg.n)])
            let w = wg.weights(for: seg)
            let c = wg.curve(seg, weights: w), q = wg.curve(Array(cap.mic[qs..<(qs + wg.n)]), weights: w)
            vDSP_vadd(sum, 1, c, 1, &sum, 1, vDSP_Length(wg.n))
            vDSP_vadd(qsum, 1, q, 1, &qsum, 1, vDSP_Length(wg.n))
            used += 1
        }
        guard used > 0 else { continue }
        let r = wg.peak(in: sum, maxLag: wide), qr = wg.peak(in: qsum, maxLag: wide)
        let snr = 20 * log10(r.peak / max(qr.peak, 1e-12))
        let delta = Double(off) + r.pos
        extShift[t] = max(0, delta - 0.100 * cap.micRate)
        if !quiet {
            print(String(format: "  「%@」（外接）%d 個脈衝寬窗（%.0f ms）同相累加：比排程晚 %.1f ms（參考喇叭約 %.1f ms），累加峰值比安靜段高 %.1f dB；搜尋窗平移 %.1f ms",
                         cap.names[t], used, Double(wide) / cap.micRate * 1000, delta / cap.micRate * 1000,
                         (shift + 0.100 * cap.micRate) / cap.micRate * 1000, snr, extShift[t]! / cap.micRate * 1000))
        }
    }
    return cap.pulseMicGuess.enumerated().map { (k, g0) in
        let gcc = gccs[sigs[k]]!
        let tlen = gcc.templateCount
        let out = k < pulses.count ? pulses[k].output : -1
        if report?.shortMiss.contains(out) == true { return nil }
        let own = k < pulses.count ? extShift[out] : nil
        let g = g0 + (own ?? shift)
        let ws = Int(g.rounded()) - pre
        guard ws >= 0, ws + search + tlen <= cap.mic.count else { return nil }
        let seg = Array(cap.mic[ws..<min(cap.mic.count, ws + gcc.n)])
        let w = gcc.weights(for: seg)
        let r = gcc.locate(seg, maxLag: search, weights: w)
        // 短量測的外接輸出：脈衝後半個週期會碰到下一個參考脈衝 → 安靜段取脈衝前半個週期
        let before = short?.hintMs[out] != nil && externals.contains(out)
        let qs = before ? ws - cap.periodFrames / 2 : ws + cap.periodFrames / 2
        guard qs >= 0 else { return (Double(ws) + r.pos, 99.0, r.psrDb, r.sideMs) }
        var snr = 99.0
        if qs + gcc.n <= cap.mic.count {
            let q = gcc.locate(Array(cap.mic[qs..<(qs + gcc.n)]), maxLag: search, weights: w)
            snr = 20 * log10(r.peak / max(q.peak, 1e-12))
        }
        return (Double(ws) + r.pos, snr, r.psrDb, r.sideMs)
    }
}

// MARK: - 錄音存檔／離線重新分析（調參用；--dump <dir>、pp-reanalyze <dir>）

private func ppDump(_ cap: PPCapture, pulses: [PPPulse], externals: Set<Int>, to dir: String) {
    let url = URL(fileURLWithPath: dir)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let raw = cap.mic.withUnsafeBufferPointer { Data(buffer: $0) }
        try raw.write(to: url.appendingPathComponent("mic.f32"))
        let meta: [String: Any] = [
            "periodSeconds": cap.periodSeconds, "micRate": cap.micRate, "pulseMicGuess": cap.pulseMicGuess, "periodFrames": cap.periodFrames,
            "names": cap.names, "clock": cap.clock, "maxDelayMs": cap.maxDelayMs,
            "outputs": pulses.map(\.output),
            "signals": pulses.map { [$0.signal.kind.rawValue, $0.signal.clickSeconds, $0.signal.clickPeakRatio] as [Any] },
            "externals": externals.sorted(),
            "discard": pulses.map(\.discard),
        ]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]).write(to: url.appendingPathComponent("meta.json"))
        print("  錄音已存：\(dir)")
    } catch { print("⚠ 存錄音失敗：\(error)") }
}

/// `pp-reanalyze <dir> [--signal …]`：讀 --dump 存的錄音，用目前的程式重新定位＋直線擬合，印各台殘差（不出聲、不開麥克風）
func runPPReanalyze(_ args: [String]) -> Int32 {
    guard let dir = args.first else { print("用法：pp-reanalyze <dir> [--signal xylo|xylo-strong|noise]"); return 2 }
    let url = URL(fileURLWithPath: dir)
    guard let raw = try? Data(contentsOf: url.appendingPathComponent("mic.f32")),
          let md = try? Data(contentsOf: url.appendingPathComponent("meta.json")),
          let meta = try? JSONSerialization.jsonObject(with: md) as? [String: Any] else { print("✗ 讀不到 \(dir)/mic.f32、meta.json"); return 1 }
    let mic: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let outs = meta["outputs"] as! [Int]
    var sigs: [PPSignal] = (meta["signals"] as! [[Any]]).map {
        PPSignal(kind: PPSignal.Kind(rawValue: $0[0] as! String)!, clickSeconds: ($0[1] as! NSNumber).doubleValue, clickPeakRatio: ($0[2] as! NSNumber).doubleValue)
    }
    if let i = args.firstIndex(of: "--signal"), i + 1 < args.count, let sg = PPSignal.parse(args[i + 1]) { sigs = sigs.map { _ in sg } }
    let cap = PPCapture(mic: mic, periodSeconds: (meta["periodSeconds"] as! NSNumber).doubleValue, micRate: (meta["micRate"] as! NSNumber).doubleValue,
                        pulseMicGuess: (meta["pulseMicGuess"] as! [NSNumber]).map(\.doubleValue), periodFrames: meta["periodFrames"] as! Int,
                        names: meta["names"] as! [String], clock: meta["clock"] as! Int, maxDelayMs: (meta["maxDelayMs"] as! NSNumber).doubleValue,
                        signals: sigs)
    // 2026-09-29 之前的錄音沒有 discard（全部採用）
    let disc = (meta["discard"] as? [Bool]) ?? Array(repeating: false, count: outs.count)
    let pulses = outs.indices.map { PPPulse(output: outs[$0], state: 0, signal: sigs[$0], discard: disc[$0]) }
    let externals = Set(meta["externals"] as! [Int])
    print("測試音：\(Set(sigs).map(\.description).joined(separator: "、"))")
    let locs = ppLocate(cap, pulses: pulses, externals: externals)
    if Set(sigs).count > 1 { return ppABReport(cap, pulses: pulses, locs: locs, clock: cap.clock) ? 0 : 1 }
    let ck = pulses.indices.filter { pulses[$0].output == cap.clock && locs[$0] != nil }
    guard ck.count >= 4 else { print("✗ 參考喇叭脈衝不足"); return 1 }
    let fit = ppRobustFit(ck.map(Double.init), ck.map { locs[$0]!.pos }, tolFrames: PPParams.refOutlierMs / 1000 * cap.micRate)
    var means: [Double] = []
    for o in Set(outs).sorted() {
        let ks = pulses.indices.filter { pulses[$0].output == o && locs[$0] != nil && !pulses[$0].discard }
        let res = ks.map { (locs[$0]!.pos - (fit.a + fit.b * Double($0))) / cap.micRate * 1000 }
        let snr = ks.map { locs[$0]!.snr }
        let m = res.reduce(0, +) / Double(max(res.count, 1))
        means.append(m)
        let ext = externals.contains(o)
        let dropped = pulses.indices.filter { pulses[$0].output == o && pulses[$0].discard }.count
        print(String(format: "  %@  平均 %+.3f  離散 %.3f  殘差 %@  SNR %@  [%@門檻 %.0f ms%@]", cap.names[o], m, (res.max() ?? 0) - (res.min() ?? 0),
                     res.map { String(format: "%+.3f", $0) }.joined(separator: " "), snr.map { String(format: "%.1f", $0) }.joined(separator: " "),
                     ext ? "藍牙" : "有線", ext ? PPParams.toleranceExternalMs : PPParams.toleranceMs, dropped > 0 ? "；暖機丟棄 \(dropped) 個" : ""))
    }
    return 0
}

/// `pp-signal <xylo|xylo-strong|noise> <out.wav>`：把測試音（播放用的一下，48 kHz）寫成 WAV（試聽／離線分析用）
func runPPSignal(_ args: [String]) -> Int32 {
    guard args.count >= 2, let sg = PPSignal.parse(args[0]) else { print("用法：pp-signal <xylo|xylo-strong|noise> <out.wav>"); return 2 }
    do { try ppWriteWav(sg.playback(rate: PPParams.rate), rate: Int(PPParams.rate), to: URL(fileURLWithPath: args[1])) } catch { print("✗ \(error)"); return 1 }
    print("✓ \(sg) → \(args[1])")
    return 0
}

/// A/B 報告：每種測試音各自用「參考喇叭的同種脈衝」擬合直線，列各台相對到達（平均、離散、SNR）與兩種的差。
/// 回傳 true = 每台兩種訊號都量得到（SNR ≥ 門檻的脈衝 ≥ 2 個）且差 ≤ 0.3 ms
private func ppABReport(_ cap: PPCapture, pulses: [PPPulse], locs: [(pos: Double, snr: Double, psr: Double, sideMs: Double)?], clock: Int) -> Bool {
    var kinds: [PPSignal] = []
    for p in pulses where !kinds.contains(p.signal) { kinds.append(p.signal) }
    var means: [PPSignal: [Int: Double]] = [:]
    for sg in kinds {
        let ck = pulses.indices.filter { pulses[$0].output == clock && pulses[$0].signal == sg && locs[$0] != nil && locs[$0]!.snr >= PPParams.minSnrDb }
        print("  [\(sg)]")
        guard ck.count >= 2 else { print("    ✗ 參考喇叭的有效脈衝不足（\(ck.count)）"); continue }
        let fit = ppRobustFit(ck.map(Double.init), ck.map { locs[$0]!.pos }, tolFrames: PPParams.refOutlierMs / 1000 * cap.micRate)
        for o in Set(pulses.map(\.output)).sorted() {
            let ks = pulses.indices.filter { pulses[$0].output == o && pulses[$0].signal == sg && locs[$0] != nil }
            let good = ks.filter { locs[$0]!.snr >= PPParams.minSnrDb }
            let res = good.map { (locs[$0]!.pos - (fit.a + fit.b * Double($0))) / cap.micRate * 1000 }
            let m = res.isEmpty ? Double.nan : res.reduce(0, +) / Double(res.count)
            if res.count >= 2 { means[sg, default: [:]][o] = m }
            print(String(format: "    %@%@：平均 %+.3f ms、離散 %.3f ms（有效 %d/%d）；殘差 %@；SNR %@", cap.names[o], o == clock ? "（參考）" : "", m,
                         (res.max() ?? 0) - (res.min() ?? 0), good.count, ks.count,
                         res.map { String(format: "%+.3f", $0) }.joined(separator: " "),
                         ks.map { String(format: "%.1f", locs[$0]!.snr) }.joined(separator: " ")))
        }
    }
    guard kinds.count == 2 else { return false }
    var ok = true
    print("  A/B 差（\(kinds[0].kind.rawValue) − \(kinds[1].kind.rawValue)，門檻 ≤ 0.3 ms）：")
    for o in Set(pulses.map(\.output)).sorted() where o != clock {
        guard let a = means[kinds[0]]?[o], let b = means[kinds[1]]?[o] else {
            print("    ✗ \(cap.names[o])：\(means[kinds[0]]?[o] == nil ? kinds[0].kind.rawValue : kinds[1].kind.rawValue) 量不到"); ok = false; continue
        }
        let d = a - b
        if abs(d) > 0.3 { ok = false }
        print(String(format: "    %@ %@：%+.3f − %+.3f = %+.3f ms", abs(d) <= 0.3 ? "✓" : "✗", cap.names[o], a, b, d))
    }
    print(ok ? "✓ A/B：每台差 ≤ 0.3 ms" : "✗ A/B：有裝置差 > 0.3 ms 或量不到")
    return ok
}

/// 【2026-10-04】參考喇叭直線擬合的穩健版：最小平方 → 偏離直線超過 tolFrames 的點（多半是撿到反射聲：內建喇叭在機殼裡，
/// 約 +4 ms 的反射和直達一樣強）一次剔除最偏的一個再重擬合，最多剔除到剩 max(4, 一半)。
/// 舊版直接最小平方：10 個參考脈衝裡 1 個偏 +3.9 ms 就把整條線拉歪，其他 9 個好脈衝變成 −0.9→0 ms 的斜坡（離散 0.9 ms > 0.3），
/// 「參考喇叭量測不穩」整次不寫（2026-10-04 實機連兩次；剔除後 9 個離散 0.11 ms）
private func ppRobustFit(_ xs: [Double], _ ys: [Double], tolFrames: Double) -> (a: Double, b: Double) {
    var idx = Array(xs.indices)
    var fit = ppFit(xs, ys)
    let minKeep = max(4, (xs.count + 1) / 2)
    while idx.count > minKeep {
        let worst = idx.max { abs(ys[$0] - (fit.a + fit.b * xs[$0])) < abs(ys[$1] - (fit.a + fit.b * xs[$1])) }!
        guard abs(ys[worst] - (fit.a + fit.b * xs[worst])) > tolFrames else { break }
        idx.removeAll { $0 == worst }
        fit = ppFit(idx.map { xs[$0] }, idx.map { ys[$0] })
    }
    return fit
}

/// 最小平方直線 y = a + b·x
private func ppFit(_ xs: [Double], _ ys: [Double]) -> (a: Double, b: Double) {
    let n = Double(xs.count)
    let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
    var sxy = 0.0, sxx = 0.0
    for (x, y) in zip(xs, ys) { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx) }
    let b = sxx > 0 ? sxy / sxx : 0
    return (my - b * mx, b)
}

/// 呼叫端（cmdCalibrate）已經暫停常駐服務
private func ppPrepare(_ engine: Engine) -> SystemAudioSnapshot {
    let snap = SystemAudioSnapshot.capture()
    print("系統狀態：\(snap)")
    engine.log = { print("  [engine] \($0)") }
    engine.setMonitorMode(muteProgram: false)
    return snap
}

// MARK: - calibrate --verify-program

/// 解析麥克風（同 calibrate 的 --mic 規則）
private func ppMic(_ micQuery: String?, _ engine: Engine) -> AudioDevice? {
    switch resolveCalibrationMic(query: micQuery, config: engine.config) {
    case .success(let d): return d
    case .failure(let e):
        print("✗ \(e.message)")
        for d in e.details { print("  · \(d)") }
        return nil
    }
}

/// 目前模式下出聲的輸出與參考喇叭。
private typealias PPInfo = (outs: [PPTarget], active: [Int], clock: Int, maxDelay: Double, delays: [Int: Double])

/// 【2026-09-29】不再為了查輸出清單啟動引擎（以前 start 一次再 stop：多建一次 tap＋聚合裝置，拉長校正開始時「沒有 tap、原音外漏」的空窗）。
/// 改用和 Engine.startLocked 同一套規則直接算：Devices.physicalOutputs() → ReconnectRules.desired（音量來源排第一）→ 主時鐘 = 內建喇叭；
/// 外接輸出 = 已註冊在 engine 的藍牙（ppAttachBluetooth）；出聲與補償 = plan()（和 Engine.pushConfigLocked 同樣的 PlanDevice）。
/// 預測的 index／solo 在 ppRun 啟動引擎後會依 uid 對回實際值（清單在這段時間改變就失敗，不會 solo 錯台）。
private func ppActiveOutputs(_ engine: Engine, mode: PlayMode) -> PPInfo? {
    engine.setMode(mode)
    let phys = Devices.physicalOutputs()
    let sig = ReconnectRules.desired(physical: phys.map { Devices.rcInfo($0) }, defaultOutput: Devices.defaultOutput().map { Devices.rcInfo($0) })
    guard let srcUID = sig.entries.first?.uid, let src = phys.first(where: { $0.uid == srcUID }) else {
        print("✗ 找不到可用的輸出裝置"); return nil
    }
    let ordered = [src] + phys.filter { $0.uid != src.uid }
    let clockUID = (ordered.first { $0.kind == .builtIn } ?? src).uid
    var outs = ordered.enumerated().map { (i, d) in
        PPTarget(index: i, solo: i, uid: d.uid, name: d.name, isBuiltIn: d.kind == .builtIn, isClock: d.uid == clockUID, externalSlot: nil)
    }
    for e in engine.externalOutputs {
        outs.append(PPTarget(index: outs.count, solo: Engine.soloValue(externalSlot: e.slot), uid: e.uid, name: e.name,
                             isBuiltIn: false, isClock: false, externalSlot: e.slot))
    }
    let cfg = engine.config
    let allowUncal = engine.allowUncalibratedExternal
    let p = plan(devices: outs.map { PlanDevice(uid: $0.uid, name: $0.name, isBuiltIn: $0.isBuiltIn,
                                                requiresMeasurement: $0.isExternal && !allowUncal, config: cfg) },
                 mode: mode, caps: cfg.modeCaps)
    var active: [Int] = []
    for o in outs {
        let e = p[o.uid]
        if e?.active == true { active.append(o.index) } else { print("  略過「\(o.name)」：\(mode.label)模式不出聲（\(e?.reason ?? "不在計畫裡")）") }
    }
    var delays: [Int: Double] = [:]
    for o in active { delays[o] = p[outs[o].uid]?.delayMs ?? 0 }
    let maxDelay = delays.values.max() ?? 0
    let clock = outs.first(where: { $0.isClock })?.index ?? 0
    return (outs, active, clock, maxDelay, delays)
}

/// checkSilent = true：另外把「目前模式不出聲」的輸出也 solo 播脈衝，量它在預期到達處的能量是否≈底噪
/// （證明 active 遮罩真的讓它沒聲音；solo 不會蓋過遮罩）。
/// write = true（`calibrate --pulse`）：量測合格（每台 ≥ 3 個脈衝、SNR 達標、單台離散 < PPParams.writeMaxSpreadMs）時，
/// 用這把尺更新 measuredLatencyMs：新延遲 = 舊延遲 + 相對到達差（到達差已含目前補償，所以「舊延遲＋殘差」就是實際延遲）；
/// 參考喇叭不變、只改出聲的裝置，最後整體平移讓最快的 = 0。寫完用同一條路徑再驗一次由呼叫端做。
/// signal：預設測試音（雜訊；--signal xylo 改木琴 C5——實機驗收未通過，試驗用）。signalFor：個別裝置改用別的測試音（uid 或名稱子字串 → 訊號；
/// 驗收 C：某台量不到木琴時只有那台改用雜訊）。
/// only（`--pulse --only <uid|名稱>`，可多個）：增量校正——只量參考喇叭＋這些裝置，其他裝置沿用既有值（換算到同一基準）。
/// 【2026-09-29】write 時量測期間補償一律歸 0（只在這個子行程的記憶體裡，不寫檔）：到達差 = 實際延遲差，脈衝間隔不必等補償
/// （藍牙量過之後有線裝置補償 400 多 ms，間隔會被拉到 1.3 s；歸 0 後沒有藍牙時 0.8 s）。寫入公式本來就扣掉量測時的補償，照樣成立。
func runVerifyProgramPath(engine: Engine, micQuery: String? = nil, mode: PlayMode? = nil, checkSilent: Bool = false, write: Bool = false,
                          bluetooth: Bool = true, btUncalibrated: Bool = false,
                          signal: PPSignal = .pink, signalFor: [String: PPSignal] = [:], dumpDir: String? = nil,
                          abSignals: [PPSignal]? = nil, calibrationGainDb: Double? = PPParams.calibrationGainDb,
                          only: [String] = [], full: Bool = false) -> Int32 {
    let mode = mode ?? engine.mode
    print("== 節目音路徑對齊驗證（afplay → tap → 延遲線 → 各喇叭；GCC-PHAT；每次只開一台；\(mode.label)模式下出聲的裝置）==")
    print("測試音：\(signal)")
    // --only：先把查詢對到 uid（實體輸出＋藍牙輸出；uid 完全相符，或名稱子字串不分大小寫）
    var onlyUIDs: Set<String>? = nil
    // 【第 C 輪】--verify-program --only <藍牙>：只量藍牙的驗證（短量測、補償歸 0、不寫入）：量到的相對延遲和 app 目前用的（校正值＋延遲修正）比
    let verifyOnly = !write && !only.isEmpty
    if !only.isEmpty {
        guard !checkSilent, abSignals == nil else { print("✗ --only 不能和 --check-silent／--signal ab 一起用"); return 2 }
        let cands = Devices.physicalOutputs() + Devices.bluetoothOutputs()
        var set = Set<String>()
        for q in only {
            let hit = cands.filter { $0.uid == q }.isEmpty ? cands.filter { $0.name.lowercased().contains(q.lowercased()) } : cands.filter { $0.uid == q }
            guard hit.count == 1 else {
                print(hit.isEmpty ? "✗ --only「\(q)」找不到對應的輸出裝置" : "✗ --only「\(q)」對到 \(hit.count) 台（\(hit.map(\.name).joined(separator: "、"))），請用 uid")
                for d in cands { print("  · \(d.name)  uid=\(d.uid)") }
                return 2
            }
            set.insert(hit[0].uid)
        }
        onlyUIDs = set
        if verifyOnly {
            guard set.count == 1, Devices.bluetoothOutputs().contains(where: { set.contains($0.uid) }) else {
                print("✗ --verify-program --only 只支援一台藍牙（只量藍牙的驗證）；有線裝置請用完整的 --verify-program"); return 2
            }
            print("只量藍牙的驗證（--verify-program --only）：只量參考喇叭＋\(cands.filter { set.contains($0.uid) }.map(\.name).joined(separator: "、"))（不寫入）")
        } else {
            print("增量校正（--only）：只量參考喇叭＋\(cands.filter { set.contains($0.uid) }.map(\.name).joined(separator: "、"))；其他裝置沿用既有值")
        }
    }
    guard let mic = ppMic(micQuery, engine) else { return 1 }
    let snap = ppPrepare(engine)
    let cid = Cleanup.register { snap.restore() }
    defer { snap.restore(); Cleanup.unregister(cid) }
    // 藍牙：--pulse 要量未校正的藍牙 → 讓它照「未量測、不補償」出聲（只在這個子行程的 engine；不寫設定）。
    // 驗證（--verify-program）只量已校正而出聲的藍牙；--bt-uncalibrated 是實機測試用開關（預設關）
    if write || btUncalibrated || verifyOnly { engine.allowUncalibratedExternal = true }
    // 量測前的設定（短量測的搜尋窗中心＝上次延遲；只量藍牙的驗證要和它比）
    let origCfg = engine.config
    // 測試音不受系統音量影響：音量來源以外的輸出用固定增益（內建喇叭的硬體音量不動）
    if let db = calibrationGainDb {
        engine.calibrationFixedGain = Float(pow(10, min(db, 0) / 20))
        let envDb = ProcessInfo.processInfo.environment[PPParams.btCalGainEnv].flatMap(Double.init).flatMap { $0.isFinite ? min(0, max(-40, $0)) : nil }
        let edb = min(db, envDb ?? PPParams.calibrationGainExternalDb)
        engine.calibrationFixedGainExternal = Float(pow(10, edb / 20))
        print(String(format: "測試音增益：HDMI／DP 固定 %.1f dB、藍牙 %.1f dB（不乘系統音量、不套面板的音量微調）；內建喇叭照系統音量＋音量微調（不調整）", min(db, 0), edb))
    }
    // 藍牙耳機靜音一陣子會關輸出、吃掉短脈衝 → 藍牙脈衝前後送低音量 150 Hz pilot（在 1–4 kHz 量測頻帶外；排程見 ppPilotWindows）
    engine.program.extPilot.pointee = 0
    defer { engine.program.extPilot.pointee = 0 }
    // --only 沒指定藍牙 → 不開藍牙（它沿用既有值；省下藍牙 IO 啟動時間，也不送 pilot）
    let btOnly = onlyUIDs.map { u in Set(Devices.bluetoothOutputs().map(\.uid).filter { u.contains($0) }) }
    let bt = ppAttachBluetooth(engine, enabled: bluetooth && btOnly?.isEmpty != true, only: btOnly)
    defer { bt?.stop() }
    if write || verifyOnly {
        var z = engine.config
        for (uid, var d) in z.devices where d.measuredLatencyMs != nil { d.measuredLatencyMs = 0; z.devices[uid] = d }
        engine.applyConfig(z)
        print("量測期間補償歸 0（只在這個子行程；寫入時扣回）")
    } else {
        // 第 B 輪：app 的背景監聽套用過延遲修正（執行期、不存檔）→ 驗證要量 app 實際在播的補償：實測延遲 += 修正（同 Engine.correctionOffsets）
        let corr = CalibrationRunner.decodeCorrections(ProcessInfo.processInfo.environment[CalibrationRunner.runtimeCorrectionsEnv])
        if !corr.isEmpty {
            var z = engine.config
            var applied: [String] = []
            for (uid, c) in corr.sorted(by: { $0.key < $1.key }) {
                guard var d = z.devices[uid], let m = d.measuredLatencyMs else { continue }
                d.measuredLatencyMs = m + c; z.devices[uid] = d
                applied.append(String(format: "%@ %+.2f ms", uid, c))
            }
            if !applied.isEmpty {
                engine.applyConfig(z)
                print("套用 app 背景監聽的延遲修正（只在這個子行程）：\(applied.joined(separator: "、"))")
            }
        }
    }

    guard var info = ppActiveOutputs(engine, mode: mode) else { return 1 }
    // 【2026-10-04】參考喇叭：設定裡有偏好（上次完整校正量到反射最少的有線喇叭）而且它在出聲、有延遲值 → 用它；否則主時鐘（內建）
    var refIdx: Int? = info.active.contains(info.clock) ? info.clock : info.active.first
    var usingPrefRef = false
    if let pref = origCfg.calibrationReferenceUID, pref != info.outs[info.clock].uid,
       let o = info.active.first(where: { info.outs[$0].uid == pref && !info.outs[$0].isExternal }),
       origCfg.measuredLatencyMs(pref) != nil, !(onlyUIDs?.contains(pref) ?? false) {
        refIdx = o; usingPrefRef = true
        print("參考喇叭：「\(info.outs[o].name)」（上次完整校正量到它的反射最少；這次量不準就自動退回「\(info.outs[info.clock].name)」）")
    }
    /// 偏好的參考這次量不準：清掉偏好（下次退回內建），讓 app 的重試用內建喇叭
    func refFailed() {
        guard usingPrefRef, let o = refIdx else { return }
        ppDropReferencePref(info.outs[o].name, fallback: info.outs[info.clock].name)
    }
    if let u = onlyUIDs {
        let clk = refIdx
        for q in u where !info.outs.contains(where: { $0.uid == q && info.active.contains($0.index) }) {
            print("✗ --only 指定的「\(info.outs.first { $0.uid == q }?.name ?? q)」不在出聲清單（已關閉、或藍牙沒有啟動）"); return 1
        }
        for o in info.active where o != clk && !u.contains(info.outs[o].uid) { print("  「\(info.outs[o].name)」這次不量：沿用既有值") }
        info.active = info.active.filter { $0 == clk || u.contains(info.outs[$0].uid) }
        info.maxDelay = info.active.compactMap { info.delays[$0] }.max() ?? 0
    }
    let maxDelay = info.maxDelay
    guard info.active.count >= 2 else {
        print(write ? "只有 \(info.active.count) 台出聲，不需要校正" : "\(mode.label)模式下只有 \(info.active.count) 台出聲，不需要驗證"); return 0
    }
    let clock = refIdx.flatMap { info.active.contains($0) ? $0 : nil } ?? info.active[0]
    // app 的漂移模型一律以主時鐘（內建）為基準：參考換成別台時，@@latency-obs 加上「參考 − 主時鐘」的延遲（設定檔的值）換算回去
    let refToClockMs = (origCfg.measuredLatencyMs(info.outs[clock].uid) ?? 0) - (origCfg.measuredLatencyMs(info.outs[info.clock].uid) ?? 0)
    if let u = onlyUIDs, u.contains(info.outs[clock].uid) { print("✗ --only 指定的是參考喇叭「\(info.outs[clock].name)」本身（它的延遲定義為基準，不用量）"); return 2 }
    // 【第 C 輪】短量測：--only 只有一台藍牙、它有上次的延遲值、沒有 --full
    var short: PPShortPlan? = nil
    if let u = onlyUIDs, !full, info.active.count == 2,
       let o = info.active.first(where: { $0 != clock && info.outs[$0].isExternal && u.contains(info.outs[$0].uid) }),
       let m = origCfg.measuredLatencyMs(info.outs[o].uid) {
        short = PPShortPlan(hintMs: [o: m - (origCfg.measuredLatencyMs(info.outs[clock].uid) ?? 0)])
        print(String(format: "短量測：「%@」上次 %.1f ms → 搜尋窗 ±%.0f ms、%d 個脈衝、pilot 暖機和準備重疊（--full 可改回完整量測）",
                     info.outs[o].name, short!.hintMs[o]!, PPParams.shortHalfWindowMs, PPParams.shortPulses))
    }
    if verifyOnly && short == nil { print("✗ 只量藍牙的驗證需要這台藍牙已經校正過（有上次的延遲值）、而且沒有 --full"); return 1 }
    let others = info.active.filter { $0 != clock }
    // 每台的測試音：預設 signal；signalFor 以 uid（完全相符）或名稱子字串（不分大小寫）指定
    let sigOf: [Int: PPSignal] = Dictionary(uniqueKeysWithValues: info.outs.map { o in
        let hit = signalFor.first { $0.key == o.uid } ?? signalFor.first { o.name.lowercased().contains($0.key.lowercased()) }
        return (o.index, hit?.value ?? signal)
    })
    for o in info.outs where sigOf[o.index] != signal { print("  「\(o.name)」改用測試音：\(sigOf[o.index]!)") }
    func pp(_ o: Int) -> PPPulse { PPPulse(output: o, state: 0, signal: sigOf[o]!) }
    var pulses: [PPPulse] = []
    if let ab = abSignals, ab.count == 2, !write {
        // A/B（--signal ab）：同一段錄音裡兩種測試音交錯——參考喇叭每組 [A, B]、其他每組 [A, B, A, B]，各自用自己那種的參考脈衝擬合
        print("A/B 交錯：\(ab[0]) ↔ \(ab[1])")
        func abp(_ o: Int, _ k: Int) -> PPPulse { PPPulse(output: o, state: 0, signal: ab[k % 2]) }
        for _ in 0..<2 {
            pulses += (0..<2).map { abp(clock, $0) }
            for o in others { pulses += (0..<4).map { abp(o, $0) } }
        }
        pulses += (0..<2).map { abp(clock, $0) }
    } else if let sp = short, let o = sp.hintMs.keys.first {
        pulses = ppShortSequence(clock: clock, external: o, signal: sigOf[o]!)
    } else {
        // 每台 2 輪 × PPParams.pulsesPerOutputPerRound（第二版 4 個；舊版 6 個）；參考喇叭每組 2 個（直線擬合要 ≥ 4 個）。
        // 藍牙排在後段、前面暖機、第一個丟棄（ppSequence）
        let per = signal.kind == .pink ? PPParams.pulsesPerOutputPerRound : 3
        pulses = ppSequence(clock: clock, wired: others.filter { !info.outs[$0].isExternal }, external: others.filter { info.outs[$0].isExternal },
                            per: per, signalOf: { sigOf[$0]! })
    }
    let inactive = checkSilent ? info.outs.map(\.index).filter { !info.active.contains($0) } : []
    if !inactive.isEmpty {
        for o in inactive { pulses += Array(repeating: pp(o), count: 3) }
        pulses += Array(repeating: pp(clock), count: 2)
    }
    let externals = Set(info.outs.filter(\.isExternal).map(\.index)).intersection(Set(pulses.map(\.output)))
    let period = short.map { ppShortPeriod(hintMs: $0.hintMs.values.first ?? 0) }
        ?? ppPeriod(maxDelayMs: maxDelay, hasExternal: !externals.isEmpty, soundSeconds: pulses.map(\.signal.soundSeconds).max() ?? PPParams.burstSeconds)
    let leadSec = short == nil ? PPParams.leadSeconds : PPParams.shortLeadSeconds
    let tailExtra = short != nil ? PPParams.shortTailExtraMs : (externals.isEmpty ? 0 : 1000)
    print(String(format: "脈衝 %d 個、間隔 %.2f 秒，約 %.0f 秒。請保持安靜…", pulses.count, period,
                 leadSec + Double(pulses.count) * period + (short != nil ? tailExtra / 1000 + 0.3 : PPParams.tailSeconds)))
    // pilot：只在藍牙脈衝前後（暖機 3 秒、每個脈衝前 1 秒 … 播完後）送
    var pilotPlan: PPPilotPlan? = nil
    if bt != nil, short != nil, let lastExt = pulses.lastIndex(where: { externals.contains($0.output) }) {
        // 短量測：藍牙輸出已經在跑 → pilot 現在就開（暖機和交接／afplay 前導重疊），最後一個藍牙脈衝播完才關
        let amp = Float(pow(10, PPParams.shortPilotDb / 20))
        engine.program.extPilot.pointee = amp
        let tail = PPParams.pilotTailSeconds + (pulses.map(\.signal.soundSeconds).max() ?? PPParams.burstSeconds) + ppExternalGateSeconds
        pilotPlan = PPPilotPlan(amp: amp, windows: [(on: -10, off: Double(lastExt) * period + tail)])
    } else if bt != nil, !externals.isEmpty {
        let extComp = externals.compactMap { info.delays[$0] }.max() ?? 0
        let tail = PPParams.pilotTailSeconds + (pulses.map(\.signal.soundSeconds).max() ?? PPParams.burstSeconds) + ppExternalGateSeconds + extComp / 1000
        pilotPlan = PPPilotPlan(amp: Float(pow(10, PPParams.bluetoothPilotDb / 20)),
                                windows: ppPilotWindows(externalPulse: pulses.map { externals.contains($0.output) }, discard: pulses.map(\.discard),
                                                        period: period, tailSeconds: tail))
    }

    let cap: PPCapture
    switch ppRun(engine: engine, mic: mic, targets: info.outs, pulses: pulses, periodSeconds: period,
                 tailExtraMs: tailExtra, pilot: pilotPlan, leadSeconds: leadSec, onState: { _ in }) {
    case .failure(let e): print("✗ \(e.msg)"); return 1
    case .success(let c): cap = c
    }
    ppBluetoothStats(bt)
    if let d = dumpDir { ppDump(cap, pulses: pulses, externals: externals.subtracting(inactive), to: d) }
    let locRep = PPLocateReport()
    let locs = ppLocate(cap, pulses: pulses, externals: externals.subtracting(inactive), short: short, report: locRep)
    for o in locRep.shortMiss.sorted() { print("@@short-miss \(info.outs[o].uid)") }
    if Set(pulses.map(\.signal)).count > 1 && !write {
        return ppABReport(cap, pulses: pulses, locs: locs, clock: clock) ? 0 : 1
    }
    var bad: [String] = []
    var badTargets = Set<Int>()
    var badByTarget: [Int: [String]] = [:]
    for (k, l) in locs.enumerated() where pulses[k].discard {
        print(String(format: "  第 %d 個脈衝（%@，暖機）不採用：%@", k + 1, cap.names[pulses[k].output], l.map { String(format: "SNR %.1f dB", $0.snr) } ?? "超出錄音範圍"))
    }
    for (k, l) in locs.enumerated() where !inactive.contains(pulses[k].output) && !pulses[k].discard {
        var msg: String?
        if l == nil { msg = "第 \(k + 1) 個脈衝超出錄音範圍" } else if l!.snr < PPParams.minSnrDb {
            msg = String(format: "第 %d 個脈衝（%@）GCC-PHAT 峰值只比安靜段高 %.1f dB（< %.0f dB）", k + 1, cap.names[pulses[k].output], l!.snr, PPParams.minSnrDb)
        }
        if let msg { bad.append(msg); badTargets.insert(pulses[k].output); badByTarget[pulses[k].output, default: []].append(msg) }
    }
    // 【2026-10-04】參考喇叭少數脈衝 SNR 不夠（被音樂／雜訊蓋過）：只剔除那幾個，剩 ≥ max(4, 一半) 就照常（舊版整次作廢：
    // 23:14 實機 10 個裡 1 個 3.4 dB → 失敗，連「下次改用別台當參考」都沒機會記）
    let refAll = pulses.indices.filter { pulses[$0].output == clock && !pulses[$0].discard }
    let refLow = Set(refAll.filter { locs[$0] == nil || locs[$0]!.snr < PPParams.minSnrDb })
    if !refLow.isEmpty, refAll.count - refLow.count >= max(4, (refAll.count + 1) / 2) {
        for b in badByTarget[clock] ?? [] { print("⚠ \(b)（參考喇叭：剔除這個脈衝，其餘 \(refAll.count - refLow.count) 個照用）") }
        let drop = Set(badByTarget[clock] ?? [])
        bad.removeAll { drop.contains($0) }
        badByTarget[clock] = nil
        badTargets.remove(clock)
    }
    // 主時鐘喇叭的脈衝擬合直線（麥克風時間軸：吸收漂移）
    let ck = refAll.filter { locs[$0] != nil && !refLow.contains($0) }
    guard ck.count >= 4 else { print("✗ 參考喇叭的脈衝不足：\(bad)"); refFailed(); return 1 }
    let fit = ppRobustFit(ck.map(Double.init), ck.map { locs[$0]!.pos }, tolFrames: PPParams.refOutlierMs / 1000 * cap.micRate)
    let ppm = (fit.b / Double(cap.periodFrames) * PPParams.rate / cap.micRate - 1) * 1e6
    print(String(format: "  參考喇叭（%@）直線擬合：週期 %.3f 麥克風 frame（名目 %d）→ 麥克風時鐘差 %.1f ppm", cap.names[clock], fit.b, cap.periodFrames, ppm))
    func resMs(_ k: Int) -> Double { (locs[k]!.pos - (fit.a + fit.b * Double(k))) / cap.micRate * 1000 }
    if verifyOnly, let o = short?.hintMs.keys.first {
        // 只量藍牙的驗證：補償歸 0 量到的相對延遲 vs app 目前用的（校正值＋背景監聽／漂移補償的延遲修正）
        guard !badTargets.contains(clock) else {
            for b in badByTarget[clock] ?? [] { print("✗ \(b)") }
            print("✗ 參考喇叭「\(info.outs[clock].name)」有不合格的脈衝，這次量不準"); refFailed(); return 1
        }
        let uid = info.outs[o].uid, refUID = info.outs[clock].uid
        let refRes = ck.map(resMs)
        let refMean = refRes.reduce(0, +) / Double(max(1, refRes.count))
        let good = pulses.indices.filter { pulses[$0].output == o && locs[$0] != nil && locs[$0]!.snr >= PPParams.minSnrDb }.map(resMs)
        let sel = ppExternalCluster(good)
        print("  \(info.outs[o].name)：\(sel.summary)（\(good.count)/\(pulses.filter { $0.output == o }.count) 個脈衝 SNR 合格）")
        guard sel.ok else { print("✗ 藍牙「\(info.outs[o].name)」量不到（一致的脈衝不足）"); return 1 }
        let meas = sel.mean - refMean
        let corr = CalibrationRunner.decodeCorrections(ProcessInfo.processInfo.environment[CalibrationRunner.runtimeCorrectionsEnv])
        let mBT = origCfg.measuredLatencyMs(uid) ?? 0, mRef = origCfg.measuredLatencyMs(refUID) ?? 0
        let assumed = (mBT + (corr[uid] ?? 0)) - (mRef + (corr[refUID] ?? 0))
        let resid = meas - assumed
        let ok = abs(resid) < PPParams.toleranceExternalMs
        print(String(format: "%@ 藍牙「%@」只量藍牙的驗證：量到相對延遲 %+.3f ms；app 目前用 %+.3f ms（校正值 %.3f、延遲修正 %+.3f）→ 殘差 %+.3f ms（正＝藍牙晚到；門檻 %.0f ms）",
                     ok ? "✓" : "✗", info.outs[o].name, meas, assumed, mBT - mRef, (corr[uid] ?? 0) - (corr[refUID] ?? 0), resid, PPParams.toleranceExternalMs))
        print(String(format: "@@latency-obs %@ %.4f %.4f %d verify", uid, meas + refToClockMs, sel.spread, sel.kept.count))
        print(String(format: "@@bt-residual %@ %.4f", uid, resid))
        if ok { print("✓ 只量藍牙的驗證通過（殘差 < \(Int(PPParams.toleranceExternalMs)) ms）") }
        return ok ? 0 : 1
    }

    // 匹配濾波（和脈衝樣板互相關的最大值）：脈衝處 vs 同長度的安靜段（半個週期後）。處理增益約 36 dB
    var tmplOf: [PPSignal: [Float]] = [:]
    for sg in Set(sigOf.values) { tmplOf[sg] = sg.template(rate: cap.micRate) }
    let pre = Int(0.010 * cap.micRate)
    // 木琴模板 300 ms：安靜段（+半個週期）的窗不能伸進下一下
    let maxLagS = max(0.020, cap.periodSeconds / 2 - Double(tmplOf.values.map(\.count).max() ?? 0) / cap.micRate - 0.05)
    func mfDb(_ start: Int, lagSeconds: Double = 0.160, signal sg: PPSignal) -> Double? {
        let tmpl = tmplOf[sg]!
        var tn: Float = 0
        vDSP_svesq(tmpl, 1, &tn, vDSP_Length(tmpl.count))
        let lags = Int(min(lagSeconds, maxLagS) * cap.micRate)
        let n = lags + tmpl.count
        guard start >= 0, start + n <= cap.mic.count else { return nil }
        let seg = Array(cap.mic[start..<(start + n)])
        var out = [Float](repeating: 0, count: lags)
        vDSP_conv(seg, 1, tmpl, 1, &out, 1, vDSP_Length(lags), vDSP_Length(tmpl.count))
        var m: Float = 0
        vDSP_maxmgv(out, 1, &m, vDSP_Length(lags))
        return 20 * log10(max(Double(m) / Double(max(tn.squareRoot(), 1e-12)), 1e-12))
    }
    func mean(_ v: [Double]) -> Double { v.isEmpty ? -200 : v.reduce(0, +) / Double(v.count) }

    var rows: [(String, Double, Double, [Double], Double)] = []
    var means: [Double] = []
    var refQuality: [Int: (psrMed: Double, snrMin: Double, n: Int)] = [:]
    for o in info.active {
        let ks = pulses.indices.filter { pulses[$0].output == o && locs[$0] != nil && !pulses[$0].discard }
        let res = ks.map { (locs[$0]!.pos - (fit.a + fit.b * Double($0))) / cap.micRate * 1000 }
        let mean0 = res.isEmpty ? .nan : res.reduce(0, +) / Double(res.count)
        let spread = (res.max() ?? 0) - (res.min() ?? 0)
        let snr = ks.map { locs[$0]!.snr }.min() ?? 0
        let psr = ks.map { locs[$0]!.psr }.min() ?? 0
        let psrs = ks.map { locs[$0]!.psr }.sorted()
        if !info.outs[o].isExternal, !psrs.isEmpty { refQuality[o] = (psrs[psrs.count / 2], snr, ks.count) }
        rows.append((cap.names[o] + (o == clock ? "（參考）" : ""), mean0, spread, res, snr))
        let sides = ks.map { locs[$0]!.sideMs }.sorted()
        let sideMed = sides.isEmpty ? .nan : sides[sides.count / 2]
        let lv = mean(ks.compactMap { mfDb(Int(locs[$0]!.pos.rounded()) - pre, lagSeconds: 0.020, signal: sigOf[o]!) })
        let nz = mean(ks.compactMap { mfDb(Int(locs[$0]!.pos.rounded()) - pre + cap.periodFrames / 2, lagSeconds: 0.020, signal: sigOf[o]!) })
        print(String(format: "    %@：匹配濾波 solo 脈衝 %.1f dB、安靜段 %.1f dB（高 %.1f dB）；峰值對旁瓣（±2 ms 外、含反射）最小 %.1f dB，最強旁瓣在主峰 %+.2f ms（中位數；僅供參考）",
                     cap.names[o], lv, nz, lv - nz, psr, sideMed))
        means.append(mean0)
    }
    print("  裝置  相對到達(ms)  各脈衝殘差(ms)  離散(ms)  最小 SNR  門檻")
    for (i, r) in rows.enumerated() {
        let ext = info.outs[info.active[i]].isExternal
        print(String(format: "  %@  %+.3f  %@  %.3f  %.1f dB  %@ %.0f ms", r.0, r.1, r.3.map { String(format: "%+.3f", $0) }.joined(separator: " "), r.2, r.4,
                     ext ? "藍牙" : "有線", ext ? PPParams.toleranceExternalMs : PPParams.toleranceMs))
    }
    // --pulse：只有外接輸出（藍牙）的脈衝不合格 → 略過它、照寫其他裝置（見下）；這時不合格的脈衝印成 ⚠（面板不當失敗）
    // --pulse：參考喇叭以外的不合格脈衝只是「不採用」（印 ⚠；那台一致的脈衝不夠就只略過那台），不連累其他裝置
    let softBad = write && !badTargets.contains(clock)
    for t in badByTarget.keys.sorted() { for b in badByTarget[t]! { print("\(softBad ? "⚠" : "✗") \(b)") } }
    // 不出聲的輸出：在參考直線預測的到達處（聚合裝置輸出：前 10 ms … 後 150 ms；藍牙：依實測延遲往後找、窗寬 0.46 s，沒量過就 0.8 s）
    // 做匹配濾波，對比同長度的安靜段與參考喇叭的脈衝。
    var silentOK = true
    if !inactive.isEmpty {
        func at(_ k: Int) -> Int { Int((fit.a + fit.b * Double(k)).rounded()) - pre }
        let refLv = mean(ck.compactMap { mfDb(at($0), signal: sigOf[clock]!) })
        let refNz = mean(ck.compactMap { mfDb(at($0) + cap.periodFrames / 2, signal: sigOf[clock]!) })
        print(String(format: "  不出聲的輸出（匹配濾波；參考喇叭脈衝 %.1f dB、它的安靜段 %.1f dB，差 %.1f dB）：", refLv, refNz, refLv - refNz))
        if refLv - refNz < 10 { print("✗ 參考喇叭的脈衝只比安靜段高 \(String(format: "%.1f", refLv - refNz)) dB，量不出「沒聲音」"); silentOK = false }
        let cfg = engine.config
        for o in inactive {
            var off = 0, lagS = 0.160
            if info.outs[o].isExternal {
                // 預期到達（相對參考喇叭）= 實測延遲差 − 參考喇叭這個模式的補償（不出聲的外接輸出補償為 0）
                if let l = cfg.measuredLatencyMs(info.outs[o].uid) {
                    let lr = cfg.measuredLatencyMs(info.outs[clock].uid) ?? 0
                    let exp = (l - lr - (info.delays[clock] ?? 0)) / 1000
                    off = Int(max(0, exp - 0.150) * cap.micRate); lagS = 0.460
                } else {
                    lagS = min(0.4 * cap.periodSeconds, 0.8)
                }
            }
            let ks = pulses.indices.filter { pulses[$0].output == o }
            lagS = min(lagS, maxLagS)
            let lv = ks.compactMap { mfDb(at($0) + off, lagSeconds: lagS, signal: sigOf[o]!) }, nz = ks.compactMap { mfDb(at($0) + off + cap.periodFrames / 2, lagSeconds: lagS, signal: sigOf[o]!) }
            guard !lv.isEmpty, !nz.isEmpty else { print("✗ \(cap.names[o])：超出錄音範圍"); silentOK = false; continue }
            let l = mean(lv), n = mean(nz)
            let ok = l - n < 3
            if !ok { silentOK = false }
            print(String(format: "  %@ %@：solo 脈衝處 %.1f dB、安靜段 %.1f dB（差 %+.1f dB；參考喇叭比它高 %.1f dB；搜尋 +%.0f…+%.0f ms）",
                         ok ? "✓" : "✗", cap.names[o], l, n, l - n, refLv - l,
                         Double(off - pre) / cap.micRate * 1000, (Double(off - pre) / cap.micRate + lagS) * 1000))
        }
    }
    // 門檻：有線之間 toleranceMs（1 ms）；藍牙對任一台出聲裝置的到達差、藍牙自己的脈衝離散 toleranceExternalMs（3 ms）
    let isExt = info.active.map { info.outs[$0].isExternal }
    let wiredMeans = means.indices.filter { !isExt[$0] }.map { means[$0] }
    let worst = (wiredMeans.max() ?? 0) - (wiredMeans.min() ?? 0)
    let maxSpread = rows.indices.filter { !isExt[$0] }.map { rows[$0].2 }.max() ?? 0
    var extOK = true
    print(String(format: "有線 %d 台到達時間最大差 %.3f ms（門檻 %.0f ms）；單台脈衝間最大離散 %.3f ms（門檻 %.0f ms）",
                 wiredMeans.count, worst, PPParams.toleranceMs, maxSpread, PPParams.toleranceMs))
    for i in means.indices where isExt[i] {
        let dev = means.indices.filter { $0 != i }.map { abs(means[i] - means[$0]) }.max() ?? 0
        let ok = dev.isFinite && dev < PPParams.toleranceExternalMs && rows[i].2 < PPParams.toleranceExternalMs
        if !ok { extOK = false }
        // 寫入模式（量測期間補償歸 0）：到達差本來就不會 < 3 ms，這行只是資訊，不標 ✓／✗（app 的 CalibrationRunner 把行首 ✗ 當失敗）
        print(String(format: "%@ 藍牙「%@」：與其他出聲裝置到達差最大 %.3f ms、脈衝間離散 %.3f ms（藍牙門檻 %.0f ms）", write ? " ·" : (ok ? "✓" : "✗"),
                     info.outs[info.active[i]].name, dev, rows[i].2, PPParams.toleranceExternalMs))
    }
    if !write, !badTargets.contains(clock), let kRef = info.active.firstIndex(of: clock) {
        // 【第 C 輪】機器可讀：藍牙量到的相對延遲（補償扣回：到達差 − (補償_藍牙 − 補償_參考)），app 的漂移模型拿來當一個量測點
        for o in info.active where info.outs[o].isExternal {
            let good = pulses.indices.filter { pulses[$0].output == o && !pulses[$0].discard && locs[$0] != nil && locs[$0]!.snr >= PPParams.minSnrDb }.map(resMs)
            let sel = ppExternalCluster(good)
            guard sel.ok, means[kRef].isFinite else { continue }
            let rel = (sel.mean - means[kRef]) - ((info.delays[o] ?? 0) - (info.delays[clock] ?? 0))
            print(String(format: "@@latency-obs %@ %.4f %.4f %d verify", info.outs[o].uid, rel + refToClockMs, sel.spread, sel.kept.count))
        }
    }
    // 【2026-10-04】完整校正：挑反射最少（峰值對旁瓣中位數最高）的有線喇叭當下次的參考（比目前的好 ≥ 3 dB 才換）
    var refPref: String?? = nil
    if write, onlyUIDs == nil, short == nil, let cur = refQuality[clock] {
        let cands = refQuality.filter { $0.value.n >= 4 && $0.value.snrMin >= PPParams.refMinSnrDb }
        if let best = cands.max(by: { $0.value.psrMed < $1.value.psrMed }), best.key != clock,
           best.value.psrMed >= cur.psrMed + PPParams.refSwitchMarginDb {
            refPref = .some(best.key == info.clock ? nil : info.outs[best.key].uid)
            print(String(format: "參考喇叭：下次改用「%@」（峰值對旁瓣中位數 %.1f dB，目前的「%@」%.1f dB；反射越少越不會量歪）",
                         info.outs[best.key].name, best.value.psrMed, info.outs[clock].name, cur.psrMed))
        }
    }
    if write {
        // 參考喇叭有不合格脈衝 → 整次不寫（直線擬合本身不可信）。其他台：不合格的脈衝不採用，剩下的交給最大一致群判斷；
        // 聽不到的藍牙（全部不合格）＝ 0 個脈衝 → 只略過它（維持未校正＝不出聲）
        guard softBad || bad.isEmpty else {
            print("✗ 參考喇叭「\(info.outs[clock].name)」有不合格的脈衝，設定未修改")
            // 這次失敗也要記住「下次換參考」（不然越差的參考越換不掉）
            if let rp = refPref { var c = Config.load(); c.calibrationReferenceUID = rp; try? c.save() } else { refFailed() }
            return 1
        }
        let good = info.active.map { o in
            pulses.indices.filter { pulses[$0].output == o && !pulses[$0].discard && locs[$0] != nil && locs[$0]!.snr >= PPParams.minSnrDb }
                .map { (locs[$0]!.pos - (fit.a + fit.b * Double($0))) / cap.micRate * 1000 }
        }
        for (k, o) in info.active.enumerated() where o != clock && good[k].isEmpty {
            print("⚠ 麥克風聽不到「\(info.outs[o].name)」（\(badByTarget[o]?.count ?? 0) 個脈衝不合格）：不寫入它的延遲（維持原值\(info.outs[o].isExternal ? "；未校正的藍牙不出聲" : "")）。請把它放近麥克風或調大它本身的音量再校正")
        }
        return ppWriteLatencies(engine: engine, info: info, clock: clock, residuals: good, bad: [], mode: mode,
                                referencePref: refPref, onReferenceFail: refFailed)
    }
    if bad.isEmpty && silentOK && worst < PPParams.toleranceMs && maxSpread < PPParams.toleranceMs && extOK {
        print("✓ 節目音路徑對齊驗證通過（\(mode.label)模式、\(info.active.count) 台出聲）")
        return 0
    }
    print("✗ 節目音路徑對齊驗證未通過")
    return 1
}

/// 最大一致群：values（ms）排序後，找「寬度 < width 的窗」裡成員最多的一群；平手取較早的群（直達聲在前、反射在後）。
/// ok = 成員 ≥ PPParams.writeMinCluster 且 ≥ 一半。取代舊的「中位數 ± 門檻」：6 個脈衝 3／3 分成兩群（0.09／0.67 ms）時
/// 中位數落在兩群中間、0 個被採用 → 整次不寫。
struct PPCluster: Equatable {
    var kept: [Double]
    var total: Int
    var mean: Double
    var spread: Double
    /// 平手：另一群（不重疊、成員一樣多）的平均；nil = 沒有平手
    var tiedOtherMean: Double?
    var ok: Bool
    var summary: String {
        let all = String(format: "採用 %d/%d 個脈衝（最大一致群，窗寬 < %@ ms），平均 %+.3f ms、離散 %.3f ms", kept.count, total,
                         String(format: "%.1f", width), mean, spread)
        let tie = tiedOtherMean.map { String(format: "；⚠ 兩群一樣多（另一群平均 %+.3f ms），取較早的一群", $0) } ?? ""
        let rf = reflectionMeanMs.map { String(format: "；另一組 %+.3f ms（晚 %.2f ms）判定為反射，取早的（直達）", $0, $0 - mean) } ?? ""
        let lz = rf + (loose ? String(format: "；寬鬆退路：%.1f ms 窗湊不到一致群，改用 %.0f ms 窗、取中位數", PPParams.writeMaxSpreadExternalMs, width) : "")
        return all + tie + lz + (ok ? "" : String(format: "；✗ 一致的脈衝不足（要 ≥ %d 個且 ≥ 一半）", PPParams.writeMinCluster))
    }
    var width: Double
    /// 寬鬆退路的結果（mean 是中位數）
    var loose = false
    /// 反射感知（ppWiredCluster）：晚到那組（當成反射）的平均；nil = 沒用到
    var reflectionMeanMs: Double? = nil
}

/// 【2026-10-04】有線裝置的一致群（反射感知）：嚴格窗（writeMaxSpreadMs）不成立時，若脈衝分成兩組都很緊密、
/// 晚的那組正好晚 refReflectionMinMs–refReflectionMaxMs（機殼／牆面反射），就把晚的那組當成早的那組的反射一起算支持數、取早的（直達）。
/// 實例：內建喇叭 −32.438／−28.586／−32.433／−28.605（直達和 +3.85 ms 反射交替，2／2 永遠湊不到 3 個）→ 取 −32.436
func ppWiredCluster(_ values: [Double]) -> PPCluster {
    let strict = ppLargestCluster(values, width: PPParams.writeMaxSpreadMs)
    if strict.ok { return strict }
    let early = strict   // 最大一致群（平手取較早）
    guard early.kept.count >= 2 else { return strict }
    let rest = values.filter { v in !early.kept.contains(v) }
    let late = ppLargestCluster(rest, width: PPParams.writeMaxSpreadMs)
    guard late.kept.count >= 1, late.mean.isFinite else { return strict }
    let gap = late.mean - early.mean
    guard gap >= PPParams.refReflectionMinMs, gap <= PPParams.refReflectionMaxMs else { return strict }
    let support = early.kept.count + late.kept.count
    guard support >= PPParams.writeMinCluster, support * 2 >= values.count else { return strict }
    var r = early
    r.ok = true
    r.tiedOtherMean = nil
    r.reflectionMeanMs = late.mean
    return r
}

/// 外接輸出（藍牙）的一致群：先用嚴格窗 writeMaxSpreadExternalMs；不成立再用 writeMaxSpreadExternalLooseMs、取中位數
func ppExternalCluster(_ values: [Double]) -> PPCluster {
    let strict = ppLargestCluster(values, width: PPParams.writeMaxSpreadExternalMs)
    if strict.ok { return strict }
    var lz = ppLargestCluster(values, width: PPParams.writeMaxSpreadExternalLooseMs)
    guard lz.ok else { return strict }
    let k = lz.kept   // 已排序
    lz.mean = k.count % 2 == 1 ? k[k.count / 2] : (k[k.count / 2 - 1] + k[k.count / 2]) / 2
    lz.loose = true
    return lz
}

func ppLargestCluster(_ values: [Double], width: Double) -> PPCluster {
    let v = values.filter { $0.isFinite }.sorted()
    guard !v.isEmpty else { return PPCluster(kept: [], total: values.count, mean: .nan, spread: 0, tiedOtherMean: nil, ok: false, width: width) }
    // 每個起點 i 的窗 [v[i], v[i] + width)
    var ends: [Int] = []
    var j = 0
    for i in v.indices {
        if j < i { j = i }
        while j + 1 < v.count && v[j + 1] - v[i] < width { j += 1 }
        ends.append(j)
    }
    let counts = v.indices.map { ends[$0] - $0 + 1 }
    let best = counts.max()!
    let bi = counts.firstIndex(of: best)!   // 平手取較早
    let kept = Array(v[bi...ends[bi]])
    // 平手：另一個不重疊、成員一樣多的窗
    let tie = v.indices.first { $0 > ends[bi] && counts[$0] == best }
    let tiedMean = tie.map { t in v[t...ends[t]].reduce(0, +) / Double(best) }
    let mean = kept.reduce(0, +) / Double(kept.count)
    let ok = kept.count >= PPParams.writeMinCluster && kept.count * 2 >= values.count
    return PPCluster(kept: kept, total: values.count, mean: mean, spread: kept.last! - kept.first!, tiedOtherMean: tiedMean, ok: ok, width: width)
}

/// `calibrate --pulse` 的寫入：means[k] = info.active[k] 相對參考喇叭的到達差（ms，量測時各台已套用補償 delays）。
/// 到達差 = (L_i + D_i) − (L_ref + D_ref) → 相對延遲 L_i − L_ref = 到達差 − (D_i − D_ref)。不需要舊的實測值（可以從零校正）；
/// 這次沒出聲的裝置保留舊值（以參考喇叭的舊值換算到同一基準），最後整體平移讓最快的 = 0。
/// residuals[k] = info.active[k] 各脈衝相對參考直線的到達差（ms）。每台取「最大一致群」（ppLargestCluster：寬 writeMaxSpreadMs 的窗裡
/// 成員最多的一群，平手取較早的群）的平均；成員要 ≥ writeMinCluster 且 ≥ 一半，否則**只有那台**不寫（保留舊值）、其他照寫；
/// 參考喇叭不合格才整次不寫。外接輸出（藍牙）窗寬 writeMaxSpreadExternalMs（量到的值含 BluetoothOut 固定緩衝與 A2DP 延遲）。
/// 【2026-10-04】偏好的參考喇叭量不準 → 清掉偏好（下次退回主時鐘＝內建）
private func ppDropReferencePref(_ name: String, fallback: String) {
    var c = Config.load()
    guard c.calibrationReferenceUID != nil else { return }
    c.calibrationReferenceUID = nil
    do { try c.save(); print("⚠ 參考喇叭「\(name)」這次量不準（關了或音量太小？）：下次改回「\(fallback)」當參考") }
    catch { print("⚠ 參考喇叭「\(name)」這次量不準，但清除偏好失敗：\(error)") }
}

/// referencePref：nil = 不改；.some(nil) = 改回主時鐘；.some(uid) = 下次用這台當參考
private func ppWriteLatencies(engine: Engine, info: PPInfo, clock: Int, residuals: [[Double]], bad: [String], mode: PlayMode,
                              referencePref: String?? = nil, onReferenceFail: () -> Void = {}) -> Int32 {
    guard bad.isEmpty else { print("✗ 量測不合格（見上），設定未修改"); return 1 }
    var means: [Double] = []
    var keptActive: [Int] = []
    var skipped: [String] = []
    var clusterOf: [Int: PPCluster] = [:]
    for (k, o) in info.active.enumerated() {
        let ext = info.outs[o].isExternal
        let sel = ext ? ppExternalCluster(residuals[k]) : ppWiredCluster(residuals[k])
        clusterOf[o] = sel
        print("  \(info.outs[o].name)：\(sel.summary)")
        guard sel.ok else {
            if o == clock {
                print("✗ 參考喇叭「\(info.outs[o].name)」量測不穩（\(sel.summary)），設定未修改")
                // 這次失敗也要記住「下次換參考」（2026-10-04 實機：選出電視卻因為這裡失敗沒存）
                if let rp = referencePref { var c = Config.load(); c.calibrationReferenceUID = rp; try? c.save() } else { onReferenceFail() }
                return 1
            }
            print("⚠ 「\(info.outs[o].name)」\(ext ? "（藍牙）" : "")量測不穩：不寫入它的延遲（維持原值），其他裝置照寫")
            skipped.append(info.outs[o].name)
            continue
        }
        means.append(sel.mean)
        keptActive.append(o)
    }
    guard keptActive.count >= 2 else { print("✗ 扣掉量測不穩的裝置後只剩 \(keptActive.count) 台，設定未修改"); return 1 }
    var info = info
    info.active = keptActive
    guard let kRef = info.active.firstIndex(of: clock) else { print("✗ 參考喇叭不在出聲清單"); return 1 }
    let cfg = Config.load()
    let refUID = info.outs[clock].uid
    let dRef = info.delays[clock] ?? 0
    // 以參考喇叭為 0 的相對延遲
    var rel: [String: Double] = [refUID: 0]
    var lines: [String] = []
    for (k, o) in info.active.enumerated() where o != clock {
        let r = (means[k] - means[kRef]) - ((info.delays[o] ?? 0) - dRef)
        rel[info.outs[o].uid] = r
        lines.append(String(format: "%@：到達差 %+.3f ms、量測時補償 %.3f ms（參考 %.3f）→ 相對延遲 %+.3f ms",
                            info.outs[o].name, means[k] - means[kRef], info.delays[o] ?? 0, dRef, r))
    }
    // 沒出聲的裝置：舊值換算到「參考 = 0」的基準（參考沒有舊值就只能保留原樣、不列入）
    let refOld = cfg.measuredLatencyMs(refUID) ?? (info.outs[clock].isBuiltIn ? 0 : nil)
    // 【2026-09-29】不只 info.outs：這次沒開的藍牙（--only 沒指定）、暫時不在的裝置也要換算，
    // 否則下面整體平移（最快 = 0）改變基準時，它們的舊值會跟其他裝置錯開
    for uid in Set(cfg.devices.keys).union(info.outs.map(\.uid)) where rel[uid] == nil {
        if let v = cfg.measuredLatencyMs(uid), let ro = refOld { rel[uid] = v - ro }
    }
    let mn = rel.values.min() ?? 0
    for k in rel.keys { rel[k]! -= mn }
    if let mx = rel.values.max(), mx > Config.maxDelayMs {
        print(String(format: "⚠ 最慢的裝置比最快的慢 %.1f ms，超過延遲線上限 %.0f ms：plan() 會讓它不出聲", mx, Config.maxDelayMs))
    }
    let devs = info.outs.map { (uid: $0.uid, name: $0.name, isBuiltIn: $0.isBuiltIn) }
    var (newCfg, _) = applyCalibrationResult(to: cfg, measuredRel: rel, trims: nil, mode: mode, devices: devs)
    // 這次沒量到（保留舊值換算）的裝置：「需要重新校正」的標記不能被清掉
    let measured = Set(info.active.map { info.outs[$0].uid })
    for (uid, d) in cfg.devices where !measured.contains(uid) && d.needsRecalibration { newCfg.devices[uid]?.needsRecalibration = true }
    newCfg.calibratedAt = Config.nowISO8601()
    if let rp = referencePref { newCfg.calibrationReferenceUID = rp }
    do { try newCfg.save() } catch { print("✗ 寫設定檔失敗：\(error)"); return 1 }
    engine.applyConfig(newCfg)
    print("脈衝＋GCC-PHAT 量尺寫入 measuredLatencyMs（參考：\(info.outs[clock].name)）：")
    for l in lines { print("  \(l)") }
    for o in info.outs {
        let old = cfg.measuredLatencyMs(o.uid).map { String(format: "%.3f", $0) } ?? "未量測"
        print(String(format: "  %@%@：%@ → %.3f ms%@", o.name, o.isExternal ? "（藍牙）" : "", old, newCfg.measuredLatencyMs(o.uid) ?? .nan,
                     measured.contains(o.uid) || o.uid == refUID ? "" : "（這次沒量，沿用）"))
    }
    for uid in rel.keys.sorted() where !info.outs.contains(where: { $0.uid == uid }) {
        print(String(format: "  %@（這次沒開，沿用）：%.3f → %.3f ms", uid, cfg.measuredLatencyMs(uid) ?? .nan, newCfg.measuredLatencyMs(uid) ?? .nan))
    }
    for pm in PlayMode.allCases {
        let p = plan(devices: info.outs.map { PlanDevice(uid: $0.uid, name: $0.name, isBuiltIn: $0.isBuiltIn, requiresMeasurement: $0.isExternal, config: newCfg) },
                     mode: pm, caps: newCfg.modeCaps)
        print("  \(pm.label)：" + info.outs.map { o in "\(o.name) \(p[o.uid].map { $0.active ? String(format: "%.2fms", $0.delayMs) : "✕" } ?? "?")" }.joined(separator: "、"))
    }
    if !skipped.isEmpty { print("⚠ 這次沒有寫入（量測不穩、維持原值）：\(skipped.joined(separator: "、"))") }
    // 機器可讀：這次真的量到並寫入的裝置 uid（含參考喇叭）。app 的自動校正（AutoCalibrator）靠它判斷哪幾台完成
    print("\(autoCalMeasuredPrefix)\(measured.union([refUID]).sorted().joined(separator: ","))")
    // 【第 C 輪】藍牙量到的相對延遲（相對參考喇叭，寫入後的值）：app 的漂移模型拿來當一個量測點
    for o in info.active where info.outs[o].isExternal {
        guard let v = newCfg.measuredLatencyMs(info.outs[o].uid), let sel = clusterOf[o] else { continue }
        // 以主時鐘（內建）為基準（app 的漂移模型用這個；參考換成別台時也一樣）
        print(String(format: "@@latency-obs %@ %.4f %.4f %d calibration", info.outs[o].uid, v - (newCfg.measuredLatencyMs(info.outs[info.clock].uid) ?? 0), sel.spread, sel.kept.count))
    }
    print("✓ 已寫入 \(Config.fileURL.path)；請再跑 `calibrate --verify-program` 確認殘差")
    return 0
}


// MARK: - calibrate --volume-test

/// 狀態：0 = 原音量、1 = 原音量 −Δ（只調低）、2 = 靜音、3 = 原音量（還原後再量一次）
func runVolumeTest(engine: Engine, micQuery: String? = nil, mode: PlayMode? = nil, bluetooth: Bool = true) -> Int32 {
    let mode = mode ?? engine.mode
    print("== 音量／靜音聲學測試（afplay → 節目音路徑；每次只開一台；只調低、不調高；結束還原；\(mode.label)模式下出聲的裝置）==")
    guard let mic = ppMic(micQuery, engine) else { return 1 }
    let snap = ppPrepare(engine)
    let cid = Cleanup.register { snap.restore() }
    defer { snap.restore(); Cleanup.unregister(cid); print("已還原系統狀態：\(SystemAudioSnapshot.capture())") }
    // 音量／靜音一律透過 snap 設在「擷取當下那台預設輸出」上：只准 ≤ 原值 v0；使用者中途自己調低就不再調回去
    guard let src = snap.originalOutput, Devices.defaultOutput()?.uid == src.uid, Devices.hasVolumeDecibels(src.id),
          let v0 = snap.volumeScalar else {
        print("✗ 預設輸出沒有音量控制，無法測"); return 1
    }
    if Devices.isMuted(src.id) { print("✗ 目前是靜音，請先取消靜音"); return 1 }
    let vLow = max(0, v0 - 0.10)
    // 先量兩個音量對應的 dB（設定後讀回，再還原）
    let db0 = Devices.volumeDecibels(src.id) ?? 0
    snap.setVolume(vLow)
    usleep(100_000)
    let dbLow = Devices.volumeDecibels(src.id) ?? 0
    snap.setVolume(v0)
    usleep(100_000)
    print(String(format: "音量來源「%@」：%.0f → %.0f（%.2f → %.2f dB，差 %.2f dB）", src.name, v0 * 100, vLow * 100, db0, dbLow, dbLow - db0))

    let bt = ppAttachBluetooth(engine, enabled: bluetooth)
    defer { bt?.stop() }
    guard let info = ppActiveOutputs(engine, mode: mode) else { return 1 }
    let maxDelay = info.maxDelay
    guard !info.active.isEmpty else { print("✗ \(mode.label)模式下沒有出聲的輸出"); return 1 }
    var pulses: [PPPulse] = []
    for st in 0..<4 {
        for o in info.active { pulses += Array(repeating: PPPulse(output: o, state: st), count: 2) }
    }
    let externals = Set(info.active.filter { info.outs[$0].isExternal })
    let period = ppPeriod(maxDelayMs: maxDelay, hasExternal: !externals.isEmpty)
    var gLog: [String] = []
    let onState: (Int) -> Void = { st in
        switch st {
        // 0／3：回到 v0——只在目前值仍是我們設的 vLow 時；使用者自己調低過就取 min(目前值, v0)（snap.setVolume 保證）
        case 0, 3: snap.setMuted(false); snap.setVolume(v0)
        case 1: snap.setVolume(vLow)
        case 2: snap.setVolume(vLow); snap.setMuted(true)
        default: break
        }
        // 等 engine 輪詢（50 ms）後記下各輸出的目標增益
        usleep(150_000)
        let s = engine.status(resetPeaks: false)
        gLog.append("狀態 \(st)：音量 \(String(format: "%.0f", (Devices.volumeScalar(src.id) ?? 0) * 100)) mute=\(Devices.isMuted(src.id) ? 1 : 0) → "
                    + s.outputs.map { String(format: "%@ g=%.3f", $0.name, $0.targetGain) }.joined(separator: "、"))
    }
    print(String(format: "脈衝 %d 個、間隔 %.2f 秒，約 %.0f 秒。請保持安靜…", pulses.count, period,
                 PPParams.leadSeconds + Double(pulses.count) * period + PPParams.tailSeconds))
    let cap: PPCapture
    switch ppRun(engine: engine, mic: mic, targets: info.outs, pulses: pulses, periodSeconds: period,
                 tailExtraMs: externals.isEmpty ? 0 : 1000, onState: onState) {
    case .failure(let e): print("✗ \(e.msg)"); return 1
    case .success(let c): cap = c
    }
    for d in snap.restore() { print("  還原：\(d)") }
    for l in gLog { print("  \(l)") }

    // 位置：非靜音脈衝用 GCC-PHAT；靜音脈衝用同一台在狀態 0 的平均偏移推算
    let locs = ppLocate(cap, pulses: pulses, externals: externals)
    let h = ppBandpass(rate: cap.micRate)
    var filtered = [Float](repeating: 0, count: max(0, cap.mic.count - h.count))
    vDSP_conv(cap.mic, 1, h, 1, &filtered, 1, vDSP_Length(filtered.count), vDSP_Length(h.count))
    let win = Int((PPParams.burstSeconds + 0.020) * cap.micRate)
    func power(at p: Int) -> Double {
        let a = max(0, p), b = min(filtered.count, p + win)
        guard b > a else { return 0 }
        var s: Float = 0
        filtered.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + a, 1, &s, vDSP_Length(b - a)) }
        return Double(s) / Double(b - a)
    }
    var fail = 0
    print("  裝置                     狀態0(dB)  −Δ(dB)  變化   預期    靜音(dB)  底噪(dB)  還原(dB)")
    for o in info.active {
        let idx = { (st: Int) in pulses.indices.filter { pulses[$0].output == o && pulses[$0].state == st } }
        let off0 = idx(0).compactMap { k in locs[k].map { $0.pos - cap.pulseMicGuess[k] } }
        guard !off0.isEmpty else { print("✗ \(cap.names[o]) 狀態 0 找不到脈衝"); fail += 1; continue }
        let off = off0.reduce(0, +) / Double(off0.count)
        func level(_ st: Int) -> Double {
            let ps = idx(st).map { power(at: Int((cap.pulseMicGuess[$0] + off).rounded()) - Int(h.count / 2)) }
            return 10 * log10(max(ps.reduce(0, +) / Double(max(ps.count, 1)), 1e-20))
        }
        // 底噪：同一台脈衝之間（半個週期後）的安靜段
        let noise = 10 * log10(max(idx(0).map { power(at: Int((cap.pulseMicGuess[$0] + off).rounded()) + cap.periodFrames / 2) }
            .reduce(0, +) / Double(idx(0).count), 1e-20))
        let l0 = level(0), l1 = level(1), l2 = level(2), l3 = level(3)
        let expect = Double(dbLow - db0)
        let okVol = abs((l1 - l0) - expect) < 1.5
        let okMute = l2 - noise < 3
        let okBack = abs(l3 - l0) < 1.0
        if !(okVol && okMute && okBack) { fail += 1 }
        print(String(format: "  %@  %.1f  %.1f  %+.2f  %+.2f  %.1f  %.1f  %.1f  %@", cap.names[o], l0, l1, l1 - l0, expect, l2, noise, l3,
                     okVol && okMute && okBack ? "✓" : "✗\(okVol ? "" : " 音量變化不符")\(okMute ? "" : " 靜音時仍有聲")\(okBack ? "" : " 還原後不一致")"))
    }
    print(fail == 0 ? "✓ 音量／靜音同時控制所有喇叭（聲學量測）" : "✗ \(fail) 台不符")
    return fail == 0 ? 0 : 1
}

// MARK: - 離線自測（calibrate --selftest 會一起跑；不出聲、不開麥克風）

/// 合成錄音用的一台喇叭
private struct PPSimTarget {
    var name: String
    /// 真實延遲（喇叭＋聲學，ms）
    var latMs: Double
    /// 量測時套用的補償（ms）
    var compMs: Double
    /// 到達麥克風的振幅倍率
    var amp: Double
    /// 反射（延遲 s, 倍率）；(0, 1) = 直達聲
    var paths: [(Double, Double)]
    /// 藍牙 A2DP 模擬：8 kHz 低通（線性相位、延遲已扣掉）＋二階全通（3 kHz、r = 0.6）的群延遲扭曲
    var a2dp = false
    var external = false
    /// 喇叭色散模擬：高頻段（> 3 kHz）晚 dispersionMs 到（兩段 FIR 分頻相加），用來重現「低頻峰 vs 高頻峰」
    var dispersionMs = 0.0
}

/// 分數延遲疊加：y(t) += g·x(t − p)，p 為麥克風 frame（次樣本），Blackman 視窗 sinc 內插（±64 taps）
private func ppAddDelayed(_ y: inout [Float], _ x: [Float], at p: Double, gain g: Double) {
    let H = 64
    let i0 = Int(floor(p)), frac = p - Double(i0)
    var k = [Double](repeating: 0, count: 2 * H + 1)
    for d in -H...H {
        let u = Double(d) - frac
        let s = u == 0 ? 1 : sin(Double.pi * u) / (Double.pi * u)
        let w = 0.42 + 0.5 * cos(Double.pi * u / Double(H + 1)) + 0.08 * cos(2 * Double.pi * u / Double(H + 1))
        k[d + H] = s * w * g
    }
    for n in 0..<x.count {
        let xv = Double(x[n])
        if xv == 0 { continue }
        let base = i0 + n - H
        if base < 0 || base + 2 * H >= y.count { continue }
        for j in 0...(2 * H) { y[base + j] += Float(xv * k[j]) }
    }
}

/// 色散模擬：低於 splitHz 的成分照原時間、高於的晚 highLateMs（線性相位 FIR 分頻，延遲已扣）
private func ppDisperse(_ x: [Float], rate: Double, splitHz: Double, highLateMs: Double) -> [Float] {
    let taps = 255, c = (taps - 1) / 2
    let fc = splitHz / rate
    let lp: [Double] = (0..<taps).map { i in
        let u = Double(i - c)
        let ideal = u == 0 ? 2 * fc : sin(2 * Double.pi * fc * u) / (Double.pi * u)
        return ideal * (0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(taps - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(taps - 1)))
    }
    let late = Int((highLateMs / 1000 * rate).rounded())
    let n = x.count + late + taps
    var y = [Float](repeating: 0, count: n)
    for i in 0..<n {
        var lo = 0.0, loLate = 0.0
        for j in 0..<taps {
            let a = i + c - j, b = i - late + c - j
            if a >= 0 && a < x.count { lo += lp[j] * Double(x[a]) }
            if b >= 0 && b < x.count { loLate += lp[j] * Double(x[b]) }
        }
        let xl = (i - late >= 0 && i - late < x.count) ? Double(x[i - late]) : 0
        y[i] = Float(lo + (xl - loLate))   // 低頻原時間 + 高頻（= 全頻 − 低頻）晚 late
    }
    return y
}

/// A2DP 模擬：8 kHz 低通（127 taps 線性相位，延遲扣掉）＋二階全通（群延遲扭曲，3 kHz 附近約 +4 樣本）
private func ppA2dpChain(_ x: [Float], rate: Double) -> [Float] {
    let taps = 127, c = (taps - 1) / 2
    let fc = 8000.0 / rate
    let h: [Double] = (0..<taps).map { i in
        let u = Double(i - c)
        let ideal = u == 0 ? 2 * fc : sin(2 * Double.pi * fc * u) / (Double.pi * u)
        return ideal * (0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(taps - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(taps - 1)))
    }
    let n = x.count + 400
    var lp = [Double](repeating: 0, count: n)
    for i in 0..<n {
        var acc = 0.0
        for j in 0..<taps {
            let idx = i + c - j
            if idx >= 0 && idx < x.count { acc += h[j] * Double(x[idx]) }
        }
        lp[i] = acc
    }
    let r = 0.6, th = 2 * Double.pi * 3000 / rate
    let a1 = -2 * r * cos(th), a2 = r * r
    var y = [Float](repeating: 0, count: n)
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    for i in 0..<n {
        let v = a2 * lp[i] + a1 * x1 + x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = lp[i]; y2 = y1; y1 = v
        y[i] = Float(v)
    }
    return y
}

/// A2DP 模擬全通段的群延遲（樣本），在 300 Hz–7 kHz 平均（GCC-PHAT 對頻帶內每個 bin 等權重）。
/// 這段延遲是通道「真的」延遲（聲音確實晚到），不是量測誤差：真值要加上它
private func ppA2dpGroupDelaySamples(rate: Double, band: (lo: Double, hi: Double) = (PPParams.bandLo, PPParams.bandHi)) -> Double {
    let r = 0.6, th = 2 * Double.pi * 3000 / rate
    var sum = 0.0, n = 0
    var f = band.lo
    while f <= band.hi {
        let w = 2 * Double.pi * f / rate
        for sgn in [1.0, -1.0] { sum += (1 - r * r) / (1 - 2 * r * cos(w - sgn * th) + r * r) }
        n += 1; f += 10
    }
    return sum / Double(n)
}

private struct PPSimResult {
    var errs: [Int: [Double]] = [:]   // 每台各脈衝誤差（ms）
    var snrs: [Int: [Double]] = [:]   // 每台各脈衝 SNR（dB）
    var bad = 0
    /// 【第 C 輪】短量測：在預期窗內找不到的外接輸出
    var shortMiss: Set<Int> = []
    /// 模擬錄音長度（秒，前導＋脈衝＋尾巴）
    var seconds = 0.0
    var maxAbs: Double { errs.values.flatMap { $0 }.map(abs).max() ?? .infinity }
    var meanAbs: Double { let a = errs.values.flatMap { $0 }.map(abs); return a.isEmpty ? .infinity : a.reduce(0, +) / Double(a.count) }
}

/// pilot 模擬（外接輸出）：db = pilot 峰值（dBFS，藍牙輸出端）；gated = 只在 ppPilotWindows 送（false = 整段都送，舊行為）
private struct PPSimPilot {
    var db: Double
    var gated: Bool
}

/// 模擬一次 --verify-program：產生錄音 → ppLocate → 參考喇叭直線擬合 → 各脈衝殘差 vs 真值。
/// 序列用 ppSequence（藍牙在後段、第一個暖機丟棄）；pilot 非 nil 時在外接輸出加 150 Hz pilot（含 100 ms 線性斜坡）
/// shortHintMs 非 nil（【第 C 輪】短量測）：ts = [參考, 一台外接]，序列 ppShortSequence、間隔 ppShortPeriod、窄窗以 shortHintMs 為中心
private func ppSimulate(_ ts: [PPSimTarget], signal: PPSignal, noiseDb: Double, driftPpm: Double, micPathMs: Double, seed: UInt64,
                        pilot: PPSimPilot? = nil, shortHintMs: Double? = nil) -> PPSimResult {
    let rate = 48000.0
    let clock = 0
    let others = Array(1..<ts.count)
    let externals = Set(ts.indices.filter { ts[$0].external })
    let pulses = shortHintMs != nil ? ppShortSequence(clock: clock, external: externals.first ?? 1, signal: signal)
        : ppSequence(clock: clock, wired: others.filter { !ts[$0].external }, external: others.filter { ts[$0].external },
                     per: signal.kind == .pink ? PPParams.pulsesPerOutputPerRound : 3, signalOf: { _ in signal })
    let maxDelay = ts.map(\.compMs).max() ?? 0
    let period = shortHintMs.map { ppShortPeriod(hintMs: $0) } ?? ppPeriod(maxDelayMs: maxDelay, hasExternal: !externals.isEmpty, soundSeconds: signal.soundSeconds)
    let P = Int((period * rate).rounded())
    let lead = shortHintMs != nil ? PPParams.shortLeadSeconds : PPParams.leadSeconds
    let trueRate = rate * (1 + driftPpm * 1e-6)
    let total = Int((lead + Double(pulses.count) * period + 2.0) * trueRate)
    var rec = [Float](repeating: 0, count: total)
    let dry = signal.playback(rate: rate)
    let wet: [[Float]] = ts.map { t in
        var w = t.a2dp ? ppA2dpChain(dry, rate: rate) : dry
        if t.dispersionMs > 0 { w = ppDisperse(w, rate: rate, splitHz: 3000, highLateMs: t.dispersionMs) }
        return w
    }
    let peak = Double(dry.map(abs).max() ?? 1)
    for (k, p) in pulses.enumerated() {
        let t = ts[p.output]
        let t0 = lead + Double(k) * period + (t.latMs + t.compMs + micPathMs) / 1000
        for (dt, g) in t.paths { ppAddDelayed(&rec, wet[p.output], at: (t0 + dt) * trueRate, gain: t.amp * g) }
    }
    // pilot：藍牙輸出端峰值 db dBFS；脈衝在藍牙輸出端 RMS = −22 + calibrationGainExternalDb，模擬裡脈衝 RMS = −22 → pilot 振幅換算 +(−calibrationGainExternalDb)。
    // 時間：pilot 在 render 時加、不經延遲線；和脈衝走同一個藍牙裝置 → 與脈衝同樣平移 latMs＋麥克風路徑（藍牙補償 0）
    if let pl = pilot {
        let a0 = pow(10, (pl.db - PPParams.calibrationGainExternalDb) / 20)
        let tail = PPParams.pilotTailSeconds + signal.soundSeconds + ppExternalGateSeconds
        for (o, t) in ts.enumerated() where t.external {
            let wins: [(on: Double, off: Double)] = pl.gated
                ? ppPilotWindows(externalPulse: pulses.map { $0.output == o }, discard: pulses.map(\.discard), period: period, tailSeconds: tail)
                : [(-lead, Double(pulses.count) * period + 1)]
            let shift = (t.latMs + micPathMs) / 1000
            let ramp = BTParams.pilotRampSeconds
            for w in wins {
                let a = Int(((lead + w.on + shift) * trueRate).rounded()), b = Int(((lead + w.off + shift + ramp) * trueRate).rounded())
                for i in max(0, a)..<min(total, b) {
                    let tt = Double(i) / trueRate - (lead + shift)   // 相對第 0 個脈衝（藍牙端時間）
                    let env = min(1, max(0, (tt - w.on) / ramp), max(0, (w.off + ramp - tt) / ramp))
                    rec[i] += Float(t.amp * a0 * env * sin(2 * Double.pi * 150 * Double(i) / trueRate))
                }
            }
        }
    }
    // 雜訊：比「最小聲那台的直達聲峰值」低 noiseDb
    let sigma = (ts.map(\.amp).min() ?? 1) * peak * pow(10, -noiseDb / 20)
    var s = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    func uni() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
    for i in 0..<total {
        let u = max(uni(), 1e-12), v = uni()
        rec[i] += Float(sigma * sqrt(-2 * log(u)) * cos(2 * Double.pi * v))
    }
    let guesses = (0..<pulses.count).map { (lead + Double($0) * period) * rate }
    let cap = PPCapture(mic: rec, periodSeconds: period, micRate: rate, pulseMicGuess: guesses, periodFrames: P,
                        names: ts.map(\.name), clock: clock, maxDelayMs: maxDelay, signals: pulses.map(\.signal))
    let rep = PPLocateReport()
    let short = shortHintMs.map { h in PPShortPlan(hintMs: Dictionary(uniqueKeysWithValues: externals.map { ($0, h) })) }
    let locs = ppLocate(cap, pulses: pulses, externals: externals, quiet: true, short: short, report: rep)
    var res = PPSimResult()
    res.shortMiss = rep.shortMiss
    res.seconds = lead + Double(pulses.count) * period + (shortHintMs != nil ? PPParams.shortTailExtraMs / 1000 + 0.3 : PPParams.tailSeconds)
    let ck = pulses.indices.filter { pulses[$0].output == clock && locs[$0] != nil }
    guard ck.count >= 4 else { res.bad = pulses.count; return res }
    let fit = ppRobustFit(ck.map(Double.init), ck.map { locs[$0]!.pos }, tolFrames: PPParams.refOutlierMs / 1000 * cap.micRate)
    for (k, p) in pulses.enumerated() where !p.discard && !rep.shortMiss.contains(p.output) {
        guard let l = locs[k] else { res.bad += 1; continue }
        if l.snr < PPParams.minSnrDb { res.bad += 1 }
        res.snrs[p.output, default: []].append(l.snr)
        let got = (l.pos - (fit.a + fit.b * Double(k))) / trueRate * 1000
        let t = ts[p.output], c = ts[clock]
        let gd = { (x: PPSimTarget) in x.a2dp ? ppA2dpGroupDelaySamples(rate: rate, band: signal.gccBand) / rate * 1000 : 0 }
        let truth = (t.latMs + t.compMs + gd(t)) - (c.latMs + c.compMs + gd(c))
        res.errs[p.output, default: []].append(got - truth)
    }
    return res
}

func runProgramPathSelfTest() -> Int32 {
    print("== 節目音路徑量尺自測（木琴 C5／雜訊；合成錄音，不出聲、不開麥克風）==")
    var allOK = true
    func check(_ ok: Bool, _ msg: String) {
        print("  \(ok ? "✓" : "✗") \(msg)")
        if !ok { allOK = false }
    }
    // 0. 訊號本身
    do {
        let x = ppXylophone(rate: 48000)
        let pk = Double(x.map(abs).max() ?? 0)
        let t = PPSignal.xylophone.template(rate: 48000)
        check(abs(20 * log10(pk) - XyloParams.peakDbFS) < 0.01 && x.count == 28800 && t.count == 14400 && x == ppXylophone(rate: 48000)
              && abs(x.last!) < 1e-6,
              String(format: "木琴 C5：峰值 %.2f dBFS、長度 %d（0.6 s，結尾淡出到 0）、模板 %d（300 ms）、固定種子可重現", 20 * log10(pk), x.count, t.count))
        // 喀：前 3 ms 的高頻能量（> 3 kHz 的分音衰減很快，主要來自喀）要明顯
        let strong = ppXylophone(rate: 48000, clickSeconds: 0.005, clickPeakRatio: 0.7)
        check(strong != x && strong.count == x.count, "加強版喀（5 ms、×0.7）與預設不同")
    }
    let refl: [(Double, Double)] = [(0, 1), (0.0041, 0.9)]
    let wired: [PPSimTarget] = [
        PPSimTarget(name: "內建(模擬)", latMs: 0, compMs: 34.71, amp: 1.0, paths: refl),
        PPSimTarget(name: "MSI(模擬)", latMs: 2.157, compMs: 32.553, amp: 0.7, paths: refl),
        PPSimTarget(name: "電視(模擬)", latMs: 34.712, compMs: 0, amp: 0.8, paths: [(0, 1), (0.0041, 0.9), (0.0086, 0.5)]),
    ]
    // 1. C5：直達＋4.1 ms 強反射（0.9 倍）＋ −35 dB 雜訊，10 個種子（漂移、麥克風路徑延遲各不同）
    func batch(_ name: String, _ ts: [PPSimTarget], _ sig: PPSignal, noiseDb: Double = 35, seeds: [UInt64] = Array(1...10)) -> (Double, Double, Int, [Int: Double]) {
        var mx = 0.0, sum = 0.0, n = 0, bad = 0
        var per: [Int: Double] = [:]
        for sd in seeds {
            let r = ppSimulate(ts, signal: sig, noiseDb: noiseDb, driftPpm: [-60.0, -18, 0, 25, 80][Int(sd) % 5],
                               micPathMs: [3.1, 12.7, 45.2][Int(sd) % 3], seed: sd)
            bad += r.bad
            for (o, e) in r.errs {
                let m = e.map(abs).max() ?? .infinity
                per[o] = max(per[o] ?? 0, m)
                mx = max(mx, m); sum += e.map(abs).reduce(0, +); n += e.count
            }
        }
        let mean = n > 0 ? sum / Double(n) : .infinity
        print(String(format: "  · [%@] %@：%d 次 × %d 台，各脈衝誤差 平均 %.4f ms、最大 %.4f ms（各台最大 %@）、不合格脈衝 %d", name, sig.description, seeds.count, ts.count,
                     mean, mx, ts.indices.map { String(format: "%@ %.4f", ts[$0].name, per[$0] ?? .nan) }.joined(separator: "、"), bad))
        return (mean, mx, bad, per)
    }
    let c5 = batch("C5 反射 0.9＋−35 dB", wired, .xylophone)
    check(c5.1 < 0.05 && c5.2 == 0, String(format: "木琴 C5（4.1 ms 強反射、−35 dB 雜訊）最大誤差 %.4f ms < 0.05 ms", c5.1))
    let nz = batch("雜訊 反射 0.9＋−35 dB（對照）", wired, .noise)
    check(nz.1 < 0.05 && nz.2 == 0, String(format: "雜訊脈衝（同條件，對照）最大誤差 %.4f ms < 0.05 ms", nz.1))
    // 2. 藍牙 A2DP 模擬：8 kHz 低通＋全通群延遲扭曲、未校正延遲 187.37 ms（外接寬窗同相累加路徑）、比有線小聲
    var bt = wired
    bt.append(PPSimTarget(name: "藍牙(A2DP 模擬)", latMs: 187.37, compMs: 0, amp: 0.5, paths: refl, a2dp: true, external: true))
    print(String(format: "  · A2DP 模擬通道：8 kHz 低通（線性相位、延遲已扣）＋全通群延遲扭曲（3 kHz 附近 +%.1f 樣本；300 Hz–7 kHz 平均 %.4f ms，計入真值）",
                 (1 + 0.6) / (1 - 0.6), ppA2dpGroupDelaySamples(rate: 48000) / 48))
    let c5bt = batch("C5＋藍牙 A2DP", bt, .xylophone)
    check((c5bt.3[3] ?? .infinity) < 0.1 && c5bt.1 < 0.1 && c5bt.2 == 0,
          String(format: "木琴 C5＋藍牙 A2DP 模擬：藍牙各脈衝最大誤差 %.4f ms < 0.1 ms（有線最大 %.4f ms）", c5bt.3[3] ?? .nan,
                 [0, 1, 2].map { c5bt.3[$0] ?? .infinity }.max()!))
    let nzbt = batch("雜訊＋藍牙 A2DP（對照）", bt, .noise)
    print(String(format: "  · 對照：雜訊脈衝在同樣 A2DP 模擬下藍牙最大誤差 %.4f ms", nzbt.3[3] ?? .nan))
    let strong = batch("加強喀＋藍牙 A2DP", bt, .xylophoneStrongClick, seeds: Array(1...5))
    check(strong.1 < 0.1 && strong.2 == 0, String(format: "加強版喀（5 ms、×0.7）＋藍牙 A2DP：最大誤差 %.4f ms < 0.1 ms", strong.1))

    // 2a. 粉紅雜訊 1–4 kHz（第二版預設）：同樣條件＋藍牙 A2DP＋實機等級雜訊＋喇叭色散（高頻段晚 1.3 ms，重現雙值）
    let pk = batch("粉紅 反射 0.9＋−35 dB", wired, .pink)
    check(pk.1 < 0.05 && pk.2 == 0, String(format: "粉紅 1–4 kHz（4.1 ms 強反射、−35 dB）最大誤差 %.4f ms < 0.05 ms", pk.1))
    let pkbt = batch("粉紅＋藍牙 A2DP", bt, .pink)
    check((pkbt.3[3] ?? .infinity) < 0.1 && pkbt.1 < 0.1 && pkbt.2 == 0,
          String(format: "粉紅＋藍牙 A2DP 模擬：藍牙最大誤差 %.4f ms < 0.1 ms（真值含通道在 1–4 kHz 的平均群延遲 %.4f ms）", pkbt.3[3] ?? .nan,
                 ppA2dpGroupDelaySamples(rate: 48000, band: PPSignal.pink.gccBand) / 48))
    for nd in [20.0, 12.0] {
        let r = batch(String(format: "粉紅 實機雜訊 σ=峰值−%.0f dB", nd), wired, .pink, noiseDb: nd, seeds: Array(1...4))
        check(r.1 < 0.1, String(format: "粉紅在實機等級雜訊（σ = 峰值 −%.0f dB）最大誤差 %.4f ms < 0.1 ms", nd, r.1))
    }
    do {
        var disp = wired
        disp[1].dispersionMs = 1.3; disp[2].dispersionMs = 0.6
        let a = batch("色散：MSI 高頻晚 1.3 ms、電視晚 0.6 ms（粉紅 1–4 kHz 包絡）", disp, .pink, noiseDb: 20, seeds: Array(1...4))
        // 真值定義為「原始延遲」＋ 1–4 kHz 內高頻段（3–4 kHz）的權重貢獻；這裡只要求同一台各脈衝一致（離散）且沒有跳週期
        var worstSpread = 0.0
        for sd in UInt64(1)...4 {
            let r = ppSimulate(disp, signal: .pink, noiseDb: 20, driftPpm: 0, micPathMs: 12.7, seed: sd)
            for (_, e) in r.errs { worstSpread = max(worstSpread, (e.max() ?? 0) - (e.min() ?? 0)) }
        }
        check(worstSpread < 0.1, String(format: "色散下粉紅 1–4 kHz 包絡：同一台各脈衝離散最大 %.4f ms < 0.1 ms（不會在兩個峰之間跳）；相對原始延遲偏 %.3f ms", worstSpread, a.1))
        let b = batch("色散（對照：白雜訊 300 Hz–7 kHz 載波峰）", disp, .noise, noiseDb: 20, seeds: Array(1...4))
        print(String(format: "  · 對照：白雜訊舊量尺在同樣色散下最大偏差 %.3f ms", b.1))
    }

    // 2c.【2026-09-29】藍牙在序列後段＋暖機丟棄＋pilot 只在藍牙脈衝前後送（−50 dBFS）：1–4 kHz 量測不受影響
    do {
        let seq = ppSequence(clock: 0, wired: [1, 2], external: [3], per: PPParams.pulsesPerOutputPerRound, signalOf: { _ in .pink })
        let firstBT = seq.firstIndex { $0.output == 3 }!
        let lastWired = seq.lastIndex { $0.output == 1 || $0.output == 2 }!
        check(seq.filter { $0.discard }.count == 1 && seq[firstBT].discard && firstBT > lastWired && seq.last!.output == 0
              && seq.filter { $0.output == 3 && !$0.discard }.count == 2 * PPParams.pulsesPerOutputPerRound,
              "序列：藍牙在所有有線之後、第一個藍牙脈衝丟棄、之後 \(2 * PPParams.pulsesPerOutputPerRound) 個採用、最後接參考喇叭（共 \(seq.count) 個）")
        let noBT = ppSequence(clock: 0, wired: [1, 2], external: [], per: 2, signalOf: { _ in .pink })
        check(noBT.map(\.output) == [0, 0, 1, 1, 2, 2, 0, 0, 1, 1, 2, 2, 0, 0], "沒有藍牙時序列和舊版相同")
        let P = 2.0
        let wins = ppPilotWindows(externalPulse: seq.map { $0.output == 3 }, discard: seq.map(\.discard), period: P, tailSeconds: 0.39)
        let onTotal = wins.reduce(0) { $0 + $1.off - $1.on }
        let wiredOverlap = seq.indices.filter { seq[$0].output == 1 || seq[$0].output == 2 }.contains { k in
            wins.contains { Double(k) * P + 0.3 > $0.on && Double(k) * P < $0.off } }
        check(wins.count == 1 + 2 * PPParams.pulsesPerOutputPerRound && abs(wins[0].on - (Double(firstBT) * P - PPParams.pilotWarmupSeconds)) < 1e-9
              && !wiredOverlap,
              String(format: "pilot 時窗：%d 段、合計 %.1f 秒（整段 %.1f 秒）；暖機 %.0f 秒；沒有蓋到任何有線（HDMI／DP）脈衝",
                     wins.count, onTotal, Double(seq.count) * P, PPParams.pilotWarmupSeconds))
        var btSim = wired
        btSim.append(PPSimTarget(name: "藍牙(A2DP 模擬)", latMs: 413.6, compMs: 0, amp: 0.5, paths: refl, a2dp: true, external: true))
        func run(_ pl: PPSimPilot?, _ nd: Double) -> (maxBT: Double, maxAll: Double, snrBT: Double, bad: Int, errs: [Double]) {
            var mb = 0.0, ma = 0.0, sn: [Double] = [], bad = 0, es: [Double] = []
            for sd in UInt64(1)...4 {
                let r = ppSimulate(btSim, signal: .pink, noiseDb: nd, driftPpm: [-60.0, -18, 0, 25, 80][Int(sd) % 5],
                                   micPathMs: [3.1, 12.7, 45.2][Int(sd) % 3], seed: sd, pilot: pl)
                bad += r.bad
                mb = max(mb, r.errs[3]?.map(abs).max() ?? .infinity)
                ma = max(ma, r.maxAbs)
                sn += r.snrs[3] ?? []
                es += r.errs.keys.sorted().flatMap { r.errs[$0]! }
            }
            return (mb, ma, sn.isEmpty ? -99 : sn.reduce(0, +) / Double(sn.count), bad, es)
        }
        for nd in [35.0, 20.0] {
            let none = run(nil, nd)
            let gated = run(PPSimPilot(db: PPParams.bluetoothPilotDb, gated: true), nd)
            let cont = run(PPSimPilot(db: -40, gated: false), nd)
            let dErr = zip(gated.errs, none.errs).map { abs($0 - $1) }.max() ?? .infinity
            print(String(format: "  · [pilot，雜訊 峰值−%.0f dB] 藍牙最大誤差：無 pilot %.4f ms／−50 dBFS 只在藍牙脈衝前後 %.4f ms／−40 dBFS 整段（舊） %.4f ms；"
                         + "藍牙平均 SNR %.2f／%.2f／%.2f dB；全部裝置最大誤差 %.4f／%.4f／%.4f ms", nd, none.maxBT, gated.maxBT, cont.maxBT,
                         none.snrBT, gated.snrBT, cont.snrBT, none.maxAll, gated.maxAll, cont.maxAll))
            check(gated.maxBT < 0.1 && gated.bad == none.bad && dErr < 0.005 && abs(gated.snrBT - none.snrBT) < 0.3,
                  String(format: "pilot −50 dBFS 只在藍牙脈衝前後（雜訊 −%.0f dB）：每個脈衝誤差和無 pilot 差 ≤ %.4f ms（< 0.005）、藍牙 SNR 差 %.2f dB（< 0.3）、不合格脈衝 %d（無 pilot %d）",
                         nd, dErr, gated.snrBT - none.snrBT, gated.bad, none.bad))
        }
    }

    // 2d.【第 C 輪】藍牙短量測：參考×2 → 藍牙×4 → 參考×2、間隔 ppShortPeriod、窄窗 ±150 ms（中心＝上次延遲）、安靜段在脈衝前、pilot 整段
    do {
        let bt = PPSimTarget(name: "藍牙(A2DP 模擬)", latMs: 436.148, compMs: 0, amp: 0.5, paths: refl, a2dp: true, external: true)
        let ref = PPSimTarget(name: "內建(模擬)", latMs: 0, compMs: 0, amp: 1.0, paths: refl)
        let seq = ppShortSequence(clock: 0, external: 1, signal: .pink)
        check(seq.map(\.output) == [0, 0, 0, 1, 1, 1, 1, 0, 0, 0] && !seq.contains { $0.discard }, "短量測序列：參考×3、藍牙×4（不丟暖機）、參考×3")
        check(abs(ppShortPeriod(hintMs: 436.148) - 0.9) < 1e-9 && abs(ppShortPeriod(hintMs: 100) - PPParams.shortMinPeriodSeconds) < 1e-9 && ppShortPeriod(hintMs: 600) > 1.0,
              String(format: "間隔依上次延遲：436 ms → %.2f 秒、100 ms → %.2f 秒（下限）、600 ms → %.2f 秒", ppShortPeriod(hintMs: 436.148), ppShortPeriod(hintMs: 100), ppShortPeriod(hintMs: 600)))
        let pl = PPSimPilot(db: PPParams.shortPilotDb, gated: false)
        for (hintOff, nd) in [(0.0, 35.0), (0.0, 20.0), (-61.0, 20.0), (+61.0, 20.0), (-135.0, 20.0), (+135.0, 20.0)] {
            var mx = 0.0, bad = 0, miss = 0, secs = 0.0, snr: [Double] = []
            for sd in UInt64(1)...4 {
                let r = ppSimulate([ref, bt], signal: .pink, noiseDb: nd, driftPpm: [-60.0, -18, 0, 25, 80][Int(sd) % 5],
                                   micPathMs: [3.1, 12.7, 45.2][Int(sd) % 3], seed: sd, pilot: pl, shortHintMs: 436.148 + hintOff)
                mx = max(mx, r.errs[1]?.map(abs).max() ?? .infinity)
                bad += r.bad; miss += r.shortMiss.count; secs = r.seconds
                snr += r.snrs[1] ?? []
            }
            check(miss == 0 && bad == 0 && mx < 0.1,
                  String(format: "短量測（上次延遲和真值差 %+.0f ms、雜訊 −%.0f dB）：藍牙 4 個脈衝都找到、最大誤差 %.4f ms、最小 SNR %.1f dB；錄音 %.1f 秒",
                         hintOff, nd, mx, snr.min() ?? -99, secs))
        }
        // 窗外（上次延遲差 200 ms）→ 找不到（不會亂抓），app 改跑完整量測
        var missFar = 0, badFar = 0
        for sd in UInt64(1)...3 {
            let r = ppSimulate([ref, bt], signal: .pink, noiseDb: 20, driftPpm: 0, micPathMs: 12.7, seed: sd, pilot: pl, shortHintMs: 436.148 - 200)
            missFar += r.shortMiss.count; badFar += r.bad
        }
        check(missFar == 3, "上次延遲差 200 ms（窗外）：3/3 次判「找不到」（@@short-miss → 完整量測），不會抓錯（找不到 \(missFar)／3）")
        let r0 = ppSimulate([ref, bt], signal: .pink, noiseDb: 20, driftPpm: 0, micPathMs: 12.7, seed: 1, pilot: pl, shortHintMs: 436.148)
        check(r0.seconds <= 12, String(format: "短量測錄音長度 %.1f 秒（前導 %.1f＋脈衝 10 × %.2f＋尾巴）≤ 12 秒（2026-10-04 參考 3+3 多約 1.8 秒；加上啟動／交接／分析約 1.7 秒，目標整體 ≤ 14 秒）",
                                         r0.seconds, PPParams.shortLeadSeconds, ppShortPeriod(hintMs: 436.148)))
    }

    // 2b. 實機等級的雜訊（2026-09-29 C270 實測：匹配濾波 solo 脈衝比安靜段高 24–30 dB ⇔ 白雜訊 σ 只比收到的峰值低約 7–10 dB）。
    //     只列出、不判定：木琴在 σ = 峰值 −12／−8 dB 時會跳週期（約 2 ms），雜訊脈衝仍 < 0.003 ms——這就是木琴沒當預設的原因
    print("  · 實機等級雜訊（只列出；木琴在這裡會跳週期，所以預設仍用雜訊脈衝）：")
    for nd in [20.0, 12.0, 8.0] {
        _ = batch(String(format: "實機雜訊 σ=峰值−%.0f dB", nd), wired, .xylophone, noiseDb: nd, seeds: Array(1...4))
        _ = batch(String(format: "實機雜訊 σ=峰值−%.0f dB（對照）", nd), wired, .noise, noiseDb: nd, seeds: Array(1...4))
    }

    // 3. 最大一致群（calibrate --pulse 寫入）
    do {
        let a = ppLargestCluster([0.09, 0.67, 0.10, 0.66, 0.08, 0.68], width: PPParams.writeMaxSpreadMs)
        check(a.ok && a.kept.count == 3 && abs(a.mean - 0.09) < 1e-9 && a.tiedOtherMean.map { abs($0 - 0.67) < 1e-9 } == true,
              "3/3 兩群（0.09／0.67）：取較早的一群 平均 \(String(format: "%.3f", a.mean))、註明平手 → \(a.summary)")
        let b = ppLargestCluster([0.67, 0.09, 0.66, 0.10, 0.68, 0.65], width: PPParams.writeMaxSpreadMs)
        check(b.ok && b.kept.count == 4 && abs(b.mean - 0.665) < 1e-9 && b.tiedOtherMean == nil,
              "4/2：取 4 個的那群 平均 \(String(format: "%.3f", b.mean))（即使較晚）")
        let c = ppLargestCluster([0.0, 0.5, 1.0, 1.5, 2.0, 2.5], width: PPParams.writeMaxSpreadMs)
        check(!c.ok && c.kept.count == 1, "全離散：只有 \(c.kept.count) 個一致 → 該台不寫")
        let d = ppLargestCluster([0.0, 0.1, 0.9, 1.0, 2.0, 2.1], width: PPParams.writeMaxSpreadMs)
        check(!d.ok, "2/2/2：一致的不到 3 個 → 該台不寫")
        let e = ppLargestCluster([0.30, 0.31, 0.29, 0.32, 0.30, 0.31], width: PPParams.writeMaxSpreadMs)
        check(e.ok && e.kept.count == 6 && e.spread < 0.05, "正常：6 個全採用")
        let f = ppLargestCluster([10.0, 10.4, 10.9, 11.3, 10.2, 13.0], width: PPParams.writeMaxSpreadExternalMs)
        check(f.ok && f.kept.count == 5, String(format: "藍牙（窗寬 %.1f ms）：", PPParams.writeMaxSpreadExternalMs) + f.summary)
        // 有線反射感知（2026-10-04 內建喇叭實測：直達與 +3.85 ms 反射交替）
        let wr = ppWiredCluster([-32.438, -28.586, -32.433, -28.605])
        check(wr.ok && abs(wr.mean - (-32.4355)) < 1e-6 && wr.reflectionMeanMs != nil, "有線反射感知：2／2 交替 → 取早的（直達）：" + wr.summary)
        check(!ppWiredCluster([-32.4, -20.0, -32.4, -20.1]).ok, "有線：兩組差 12 ms（不是反射）→ 仍不寫")
        check(!ppWiredCluster([-32.4, -28.6, -25.0, -21.0]).ok, "有線：只有 1 個直達 → 仍不寫")
        // 寬鬆退路（2026-10-04 MK-99 實測型態）：1.5 ms 窗湊不到 → 10 ms 窗、取中位數；超過 10 ms 仍不寫
        let lz = ppExternalCluster([358.520, 361.034, 363.9, 365.7])
        check(lz.ok && lz.loose && abs(lz.mean - (361.034 + 363.9) / 2) < 1e-9, "藍牙寬鬆退路（離散 7.2 ms → 中位數）：" + lz.summary)
        let lz2 = ppExternalCluster([350.0, 356.0, 362.0, 368.0])
        check(!lz2.ok, "藍牙寬鬆退路：離散 18 ms 仍不寫：" + lz2.summary)
        check(!ppExternalCluster([413.174, 413.082, 413.083, 413.736]).loose, "嚴格窗成立時不走寬鬆退路")
        let f2 = ppLargestCluster([413.174, 413.082, 413.083, 413.736], width: PPParams.writeMaxSpreadExternalMs)
        check(f2.ok && f2.kept.count == 4, "藍牙實機 E2-verify-pilot 的 4 個脈衝（離散 0.65 ms）全部採用：\(f2.summary)")
        let g = ppLargestCluster([], width: 0.3)
        check(!g.ok, "沒有脈衝（聽不到）→ 不寫")
    }
    print(allOK ? "✓ 節目音路徑量尺自測全部通過" : "✗ 節目音路徑量尺自測有失敗項目")
    return allOK ? 0 : 1
}
