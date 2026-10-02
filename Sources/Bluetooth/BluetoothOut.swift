// BluetoothOut.swift — 藍牙喇叭只輸出路徑（owner：藍牙）
//
// 為什麼不放進聚合裝置：藍牙裝置（尤其有麥克風的）放進聚合裝置可能打開它的輸入 → 被切到 HFP 通話音質；
// 藍牙時鐘也會拖累整個聚合裝置。Devices.physicalOutputs() 已排除藍牙，改由這裡處理。
//
// 資料流：
//   engine 聚合 IOProc ──寫──▶ engine.program（ProgramRing：原始 tap 節目音、立體聲、附 engine sampleTime）
//   BluetoothOutput 的裝置 IOProc ──讀──▶ 延遲＋自適應重取樣（64 tap sinc；備援 4 點 Hermite）──▶ 藍牙輸出 buffer
//
// 設計重點（實作）：
//   * 只對輸出方向建 IOProc。裝置若同時有輸入 stream：建立 IOProc 後、AudioDeviceStart 前，用
//     kAudioDevicePropertyIOProcStreamUsage（scope input）把這個 IOProc 的所有輸入 stream 設為 0，再讀回驗證；
//     設不成功或讀回不是全 0 → 不 start（寧可不出聲）。從不設為預設輸入、不開 AUHAL。
//     依據：SDK AudioHardware.h 的說明——stream 標為不使用時「IOProc 會看到 NULL buffer，裝置可以不為這個 stream 做 IO」；
//     HFP 是「有 client 把藍牙裝置當輸入開啟」時由系統協商（A2DP 沒有麥克風通道），見回報的依據說明。
//     實測裝置 GLASS5+ 的輸出與輸入是兩個不同的 Core Audio 裝置（…:output 只有輸出 stream），這條路徑根本碰不到 :input。
//     **「只啟動輸出不會觸發 HFP」尚未實機驗證**（要 Kang 用 log stream／麥克風指示燈確認）。
//   * 對時：T = 藍牙 IOProc 輸出 hostTime 換算成 engine 時間（ProgramRing.clock() 的 (sampleTime, hostTime) ＋ engine 取樣率）；
//     要播的節目 frame P = T − extDelayFrames[slot] − safety。safety 在 start 時決定、運轉中固定
//     （= max(30 ms, 藍牙 buffer＋safety offset＋5 ms 取整到 10 ms)）。`calibrate --pulse`／`--verify-program` 會在子行程自己開
//     BluetoothOutManager 量藍牙（ProgramPath.swift），量到的 measuredLatencyMs 含這個 safety 與 A2DP 本身的延遲；
//     沒有 measuredLatencyMs 的藍牙裝置 plan() 一律不出聲（PlanDevice.requiresMeasurement，理由「未校正」）。
//     「固定目標延遲鎖定」：讀取點每個週期都由時間戳重算（P = T − 延遲 − safety），PI／前饋只修重取樣比例與相位，
//     所以延遲不會隨時間累積漂移（誤差 e 被拉回 0）；重連（onReconnect）後才可能改變 → needsRecalibration。
//   * 診斷 solo（ProgramRing.solo）：>= 0 且不等於 externalSoloBase + 自己的槽位 → 目標增益 0（校正時一次只讓一台出聲）。
//     hostTime 無效時退回用 writeEnd 當 T（精度差、只當備援）。
//   * 自適應重取樣：步長 = (engine 取樣率 / 藍牙取樣率) × (1 + corr)，corr 夾在 ±500 ppm；44.1k↔48k 由名目比例處理。
//     corr = 前饋 ff − PI(誤差)：
//       - 前饋 ff：直接用時間戳量兩邊時鐘的實際速率（engine：clock() 的 sampleTime／hostTime 對起點的斜率；
//         藍牙：自己 outputTime 的 sampleTime／hostTime 斜率），ratio = 量到的 engine 速率 ÷ 藍牙速率；累計平均後 EMA（約 11 s）平滑。
//       - PI：誤差 e = 實際讀取位置 − P（engine frame，即「填充量」相對目標的偏差），一階低通後 PI（時間常數約 42 s、臨界阻尼），
//         只修前饋的殘差與相位；很慢，所以時間戳抖動不會變成音高抖動。
//     |e| > 20 ms（例如 engine 重建、HAL 丟週期沒補到）→ 直接重新對時（增益從 0 淡入），計入 resyncs。
//   * 插值：64 tap Kaiser 窗 sinc（512 相位＋相鄰相位線性插值，截止 = 兩邊較低的 Nyquist − 過渡帶一半），
//     依 engine 取樣率預建表（44.1k、48k、start 時的取樣率）；engine 重建成沒預建的取樣率 → 退回 4 點 Hermite（stats 的 hermiteCycles）。
//   * 讀取失敗（ProgramRing.read 回 false：engine 停了／重建中／追太近）→ 整個週期靜音、underruns +1、下個週期重新對時。
//     engine 沒在跑（sampleRate == 0、沒有時鐘）→ 靜音、idleCycles +1（不算欠載）。program.generation 改變也重新對時。
//   * 增益：program.extGain[slot]（已含音量倍率 × trim × plan.active）× (muteProgram == 0)，每週期線性 ramp；
//     延遲（extDelayFrames）改變時：先用舊延遲淡出到 0，下一週期把讀取位置平移到新延遲、再淡入（和 engine 一樣）。
//   * 取樣格式：IOProc 看到的是 stream 的 virtual format；start 時確認所有輸出 stream 都是 32-bit float linear PCM，否則不啟動。
//     聲道對應：全域聲道 0 = L、1 = R、其他 = 0；裝置只有 1 聲道 → (L+R)/2。
//
// BluetoothOutManager 的政策：**使用者關閉（enabled == false）的藍牙裝置仍然建立並註冊**，
//   由 plan() 給 active=false → extGain = 0 → 輸出靜音（淡出）。好處：開關切換不必重開裝置、不爆音、不用等藍牙 IO 啟動；
//   代價：裝置在 app 執行期間一直被開著（輸出靜音）。
//
// 熱插拔：manager 自己監聽 kAudioHardwarePropertyDevices（start() 之後），也提供 attach(deviceID:)／detach(deviceID:)／detach(uid:)／
//   resync() 給 Reconnect／整合者直接驅動（兩者可以並存：重複 attach 同一台是 no-op）。
//   藍牙裝置自己的 nominal sample rate 改變（例如別的 app 開了它的麥克風 → HFP 16 kHz）→ 自動重開這台的 IOProc。
import CoreAudio
import Darwin
import Foundation

// MARK: - 參數

enum BTParams {
    /// 固定緩衝下限（ms）：這條路徑自己的延遲（會被 calibrate --pulse 量進 measuredLatencyMs；未量測的藍牙不出聲）
    static let defaultSafetyMs = 30.0
    /// 重取樣比例微調上限（ppm）
    static let maxPPM = 500.0
    /// PI：比例增益（每 frame 誤差 → 比例修正），時間常數 2/kp = 2,000,000 frame ≈ 42 s @48k；ki = kp²/4（臨界阻尼）。
    /// 漂移主要由前饋（時間戳量兩邊時鐘速率）吸收，PI 只修殘差，所以可以很慢（慢 = 時間戳抖動不會變成音高抖動）
    static let kp = 1.0e-6
    static let ki = kp * kp / 4
    /// 前饋速率量測的最短跨度（秒）：第一次（還沒有前饋值）
    static let ffMinSpan = 0.5
    /// engine 換世代（重建）後重新下錨時的最短跨度（秒）：已經有前饋值，不急著用短跨度的雜訊估計覆蓋它
    /// （錨點時間戳的抖動 δ 會造成 δ/跨度 的速率偏差，0.5 s 跨度時 50 µs 就是 100 ppm）
    static let ffReanchorSpan = 5.0
    /// 前饋 EMA 的時間常數（週期數；512 frame 週期 ≈ 11 ms → 約 11 s）
    static let ffSmoothCycles = 1000
    /// 誤差一階低通（每週期）
    static let errAlpha = 0.01
    /// 誤差超過這個就直接重新對時
    static let resyncMs = 20.0
    /// 藍牙裝置取樣率低於這個 = HFP（通話）模式：暫停輸出（不出聲），等它回到 A2DP 再重開
    static let minA2DPRate = 32000.0
    /// AudioDeviceStop／DestroyIOProcID 失敗（或裝置已死）時，延遲多久才釋放 renderer（IOProc 可能還在跑最後一個週期）
    static let deferredFreeSeconds = 5.0
    /// 每次重取樣處理的最大輸出 frame 數（超過就分段）
    static let maxChunk = 4096
    /// 步長上限（engine 取樣率 / 藍牙取樣率），超過就靜音（例如 96k → 8k 這種不合理的組合）
    static let maxStep = 16.0
    /// 校正 pilot 開／關的線性斜坡長度（秒）。2026-09-29 起 pilot 只在藍牙脈衝前後送、會開關十幾次：
    /// 直接跳變會在 1–4 kHz 量測頻帶產生喀聲；100 ms 斜坡的頻譜洩漏在 1 kHz 以上可忽略（離線自測有驗）
    static let pilotRampSeconds = 0.1

    /// 依裝置的 buffer 與 safety offset 決定固定緩衝（ms，取整到 10 ms，下限 defaultSafetyMs）
    static func safetyMs(bufferFrames: Int, safetyOffset: Int, deviceRate: Double, minimum: Double = defaultSafetyMs) -> Double {
        guard deviceRate > 0 else { return minimum }
        let need = Double(bufferFrames + safetyOffset) / deviceRate * 1000 + 5
        return max(minimum, (need / 10).rounded(.up) * 10)
    }
}

// MARK: - 即時渲染（IOProc 內呼叫；不配置、不上鎖、不 print、不呼叫 Core Audio 屬性 API、不 retain class）

/// 即時狀態：只有 IOProc 寫（統計欄位給非即時執行緒讀，單值讀寫）
struct BTState {
    var synced = false
    var gen = -1
    var engRate = 0.0
    /// 讀取位置（engine frame）= readInt + readFrac（0 ≤ readFrac < 1）
    var readInt: Int64 = 0
    var readFrac = 0.0
    var integ = 0.0
    var errF = 0.0
    var corr = 0.0
    var lastErr = 0.0
    var fill = 0.0
    var curGain: Float = 0
    var curDelay = -1
    var nextDevTime = -1.0
    var ioCycles: Int64 = 0
    var underruns: Int64 = 0
    var resyncs: Int64 = 0
    var bigErrResyncs: Int64 = 0
    var idleCycles: Int64 = 0
    var skipEvents: Int64 = 0
    var peak: Float = 0
    // 前饋：由時間戳直接量兩邊時鐘的實際速率（樣本數 ÷ host 秒），比例 = 量到的 engine 速率 ÷ 藍牙速率
    var engAnchorSt: Int64 = 0
    var engAnchorHt: UInt64 = 0
    var engAnchorValid = false
    var btAnchorSt = 0.0
    var btAnchorHt: UInt64 = 0
    var btAnchorValid = false
    /// 前饋修正（相對名目比例；ffValid 之前為 0）
    var ff = 0.0
    var ffValid = false
    var ffCount: Int64 = 0
    /// 找不到對應 sinc 表、退回 Hermite 的週期數
    var hermiteCycles: Int64 = 0
    /// 同一世代最近一次讀到的 engine 時鐘：clock() 偶爾因 seqlock 碰到寫入中而回 nil 時沿用（不必重新對時、不淡出）
    var lastClkSt: Int64 = 0
    var lastClkHt: UInt64 = 0
    var lastClkGen = -1
    var clockMisses: Int64 = 0
    /// 校正 pilot（ProgramRing.extPilot）的相位
    var pilotPhase = 0.0
    /// 校正 pilot 目前振幅（往 extPilot 線性斜坡）與斜坡基準（最近一次非 0 的目標；關掉時照它的斜率降到 0）
    var pilotAmp: Float = 0
    var pilotRef: Float = 0
    /// 【第 B 輪】額外延遲目前值（engine frame）：探測偏移、延遲修正（往 ProgramRing.extProbeTarget／extCorrTarget 走斜坡）
    var probeCur = 0.0
    var corrCur = 0.0
}

/// 帶限插值表（Kaiser 窗 sinc，64 tap、512 相位＋相鄰相位線性插值）。
/// 截止頻率 = min(engine, 藍牙) 的 Nyquist − 過渡帶一半，依 engine 取樣率各建一張（start 時在非即時執行緒建好）。
/// RT 用目前 engine 取樣率找對應的表；找不到（engine 重建成沒預建的取樣率）→ 退回 4 點 Hermite（stats 看得到）。
struct BTSincTable {
    static let taps = 64
    static let half = taps / 2 - 1          // 第一個 tap 相對 floor(位置) 的位移 = −half
    static let phases = 512
    static let stopbandDb = 80.0
    let count: Int
    let rates: UnsafeMutablePointer<Double>
    let coef: UnsafeMutablePointer<Float>   // [count][(phases+1)][taps]

    static func make(engineRates: [Double], deviceRate: Double) -> BTSincTable {
        let rs = Array(Set(engineRates.filter { $0 > 0 })).sorted()
        let per = (phases + 1) * taps
        let rp = UnsafeMutablePointer<Double>.allocate(capacity: max(rs.count, 1))
        rp.initialize(repeating: 0, count: max(rs.count, 1))
        let cp = UnsafeMutablePointer<Float>.allocate(capacity: max(rs.count, 1) * per)
        cp.initialize(repeating: 0, count: max(rs.count, 1) * per)
        let beta = 0.1102 * (stopbandDb - 8.7)
        func i0(_ x: Double) -> Double {          // 修正 Bessel 函數 I0（級數）
            var sum = 1.0, term = 1.0, k = 1.0
            let q = x * x / 4
            while term > 1e-12 * sum { term *= q / (k * k); sum += term; k += 1 }
            return sum
        }
        let i0b = i0(beta)
        let hw = Double(taps) / 2
        for (ti, r) in rs.enumerated() {
            rp[ti] = r
            let transition = (stopbandDb - 8) / (2.285 * Double(taps)) / (2 * Double.pi) * r   // Hz
            let fc = max(0.05 * r, 0.5 * min(r, deviceRate) - transition / 2)
            let fcn = fc / r                                         // cycles / 輸入 sample
            for ph in 0...phases {
                let t = Double(ph) / Double(phases)
                let row = cp + ti * per + ph * taps
                var sum = 0.0
                var tmp = [Double](repeating: 0, count: taps)
                for i in 0..<taps {
                    let d = Double(i - half) - t
                    let x = 2 * fcn * d
                    let sinc = abs(x) < 1e-12 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                    let u = d / hw
                    let w = abs(u) <= 1 ? i0(beta * (1 - u * u).squareRoot()) / i0b : 0
                    tmp[i] = 2 * fcn * sinc * w
                    sum += tmp[i]
                }
                for i in 0..<taps { row[i] = Float(tmp[i] / sum) }   // 每個相位 DC 增益 = 1
            }
        }
        return BTSincTable(count: rs.count, rates: rp, coef: cp)
    }

    func free() { rates.deallocate(); coef.deallocate() }

    /// RT：找 engine 取樣率對應的表（沒有回 nil）
    @inline(__always)
    func table(for rate: Double) -> UnsafeMutablePointer<Float>? {
        for i in 0..<count where abs(rates[i] - rate) < 0.5 { return coef + i * (Self.phases + 1) * Self.taps }
        return nil
    }
}

/// 值型別、全是預先配置的指標：IOProc closure 直接捕捉
struct BTRenderer {
    let slot: Int
    /// 藍牙裝置取樣率（start 時讀；改變 → 重開 IOProc）
    let btRate: Double
    let safetyMs: Double
    /// host tick → 秒
    let secPerTick: Double
    let st: UnsafeMutablePointer<BTState>
    let scratch: UnsafeMutablePointer<Float>
    let scratchFrames: Int
    let sinc: BTSincTable
    /// false = 一律用 4 點 Hermite（自測比較用）
    let useSinc: Bool

    static func make(slot: Int, btRate: Double, safetyMs: Double, secPerTick: Double,
                     engineRates: [Double] = [44100, 48000], useSinc: Bool = true) -> BTRenderer {
        let sf = Int(Double(BTParams.maxChunk) * BTParams.maxStep) + BTSincTable.taps + 8
        let s = UnsafeMutablePointer<BTState>.allocate(capacity: 1)
        s.initialize(to: BTState())
        let sc = UnsafeMutablePointer<Float>.allocate(capacity: sf * 2)
        sc.initialize(repeating: 0, count: sf * 2)
        return BTRenderer(slot: slot, btRate: btRate, safetyMs: safetyMs, secPerTick: secPerTick, st: s, scratch: sc,
                          scratchFrames: sf, sinc: BTSincTable.make(engineRates: engineRates, deviceRate: btRate), useSinc: useSinc)
    }

    /// 只在 IOProc 已銷毀後呼叫
    func free() {
        st.deinitialize(count: 1); st.deallocate()
        scratch.deallocate()
        sinc.free()
    }

    static func hostSecondsPerTick() -> Double {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1e-9 : Double(tb.numer) / Double(tb.denom) * 1e-9
    }

    @inline(__always)
    static func hermite(_ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float, _ t: Float) -> Float {
        let c1 = 0.5 * (x1 - xm1)
        let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return ((c3 * t + c2) * t + c1) * t + x0
    }

    @inline(__always)
    private static func zero(_ abl: UnsafeMutableAudioBufferListPointer) {
        for b in 0..<abl.count {
            let buf = abl[b]
            if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
        }
    }

    /// 【2026-09-29】校正 pilot：ProgramRing.extPilot > 0 時，在所有聲道加一個 150 Hz 低音量正弦（不論 solo／增益／欠載）。
    /// 原因：GLASS5+ 這類藍牙耳機在靜音一陣子後會關掉輸出（功放省電／靜音閘門），2 秒一次、80 ms 的校正脈衝會被整個吃掉
    /// （實測：沒有 pilot 時 5 個脈衝全部聽不到；加 −40 dBFS 150 Hz pilot 後 5 個都在 415 ms 處量到）。150 Hz 在 1–4 kHz 量測頻帶外。
    /// 只給校正子行程用（Engine.calibrationPilotDb／ppRun 直接寫 extPilot）；平常 extPilot = 0。即時安全：只做算術。
    /// 【2026-09-29】振幅往 extPilot 線性斜坡（BTParams.pilotRampSeconds），開關都不會喀。
    func render(_ outData: UnsafeMutablePointer<AudioBufferList>, _ outTime: UnsafePointer<AudioTimeStamp>, _ ring: ProgramRing) {
        renderProgram(outData, outTime, ring)
        let target = max(0, ring.extPilot.pointee)
        var cur = st.pointee.pilotAmp
        guard (target > 0 || cur > 0), btRate > 0 else { return }
        if target > 0 { st.pointee.pilotRef = target }
        let ref = max(st.pointee.pilotRef, target)
        let stepAmp = ref / Float(max(1, BTParams.pilotRampSeconds * btRate))
        let abl = UnsafeMutableAudioBufferListPointer(outData)
        var n = 0
        for b in 0..<abl.count where abl[b].mNumberChannels > 0 { n = max(n, Int(abl[b].mDataByteSize) / 4 / Int(abl[b].mNumberChannels)) }
        var ph = st.pointee.pilotPhase
        let inc = 2 * Double.pi * 150 / btRate
        for f in 0..<n {
            if cur < target { cur = min(target, cur + stepAmp) } else if cur > target { cur = max(target, cur - stepAmp) }
            let v = cur * Float(sin(ph))
            ph += inc
            if ph > 2 * Double.pi { ph -= 2 * Double.pi }
            for b in 0..<abl.count {
                let nc = Int(abl[b].mNumberChannels)
                if let d = abl[b].mData?.assumingMemoryBound(to: Float.self), Int(abl[b].mDataByteSize) >= (f + 1) * nc * 4 {
                    for c in 0..<nc { d[f * nc + c] += v }
                }
            }
        }
        st.pointee.pilotPhase = ph
        st.pointee.pilotAmp = cur
    }

    private func renderProgram(_ outData: UnsafeMutablePointer<AudioBufferList>, _ outTime: UnsafePointer<AudioTimeStamp>, _ ring: ProgramRing) {
        let abl = UnsafeMutableAudioBufferListPointer(outData)
        var s = st.pointee
        defer { st.pointee = s }
        s.ioCycles &+= 1

        // 先全部清零；frame 數以第一個有資料的 buffer 為準
        var n = 0
        var totalCh = 0
        for b in 0..<abl.count {
            let buf = abl[b]
            let nc = Int(buf.mNumberChannels)
            if let d = buf.mData {
                memset(d, 0, Int(buf.mDataByteSize))
                if n == 0, nc > 0 { n = Int(buf.mDataByteSize) / 4 / nc }
            }
            totalCh += nc
        }
        guard n > 0, totalCh > 0 else { return }

        let engRate = ring.sampleRate.pointee
        let slotOK = slot >= 0 && slot < ProgramRing.maxExternal && ring.extUsed[slot] == 1
        var clkOpt = engRate > 0 && slotOK ? ring.clock() : nil
        if clkOpt == nil, engRate > 0, slotOK, s.synced, s.lastClkGen == ring.generation.pointee, s.lastClkGen == s.gen {
            // seqlock 連續碰到寫入中（寫入端被搶占）：同一世代沿用上一個時鐘（外插誤差只有時鐘比例 × 一個週期，可忽略）
            clkOpt = (s.lastClkSt, s.lastClkHt)
            s.clockMisses &+= 1
        }
        guard engRate > 0, btRate > 0, slotOK, let clk = clkOpt else {
            s.idleCycles &+= 1
            s.synced = false
            s.curGain = 0
            s.nextDevTime = -1
            return
        }
        let gen = ring.generation.pointee
        if gen != s.gen { s.gen = gen; s.synced = false; s.engAnchorValid = false }
        s.lastClkSt = clk.sampleTime; s.lastClkHt = clk.hostTime; s.lastClkGen = gen
        if engRate != s.engRate {
            s.engRate = engRate; s.synced = false
            s.integ = 0; s.errF = 0; s.corr = 0
            s.engAnchorValid = false; s.btAnchorValid = false; s.ff = 0; s.ffValid = false; s.ffCount = 0
        }
        let lim = BTParams.maxPPM * 1e-6
        let nominal = engRate / btRate
        var step = nominal * (1 + s.corr)

        // 藍牙 HAL 丟週期：輸出 sampleTime 跳號 → 讀取位置跟著前進（否則誤差會突然變大）
        let flags = outTime.pointee.mFlags
        if flags.contains(.sampleTimeValid) {
            let dt = outTime.pointee.mSampleTime
            if s.nextDevTime >= 0 {
                let jump = dt - s.nextDevTime
                if jump > 0.5 && jump < 10 * btRate {
                    let np = s.readFrac + jump * step
                    let fl = np.rounded(.down)
                    s.readInt &+= Int64(fl); s.readFrac = np - fl
                    s.skipEvents &+= 1
                }
            }
            s.nextDevTime = dt + Double(n)
        }

        // 前饋：兩邊的 (sampleTime, hostTime) 各自對起點量速率；跨度 ≥ ffMinSpan 秒才採用（之前沿用上一個值）
        let ht0 = outTime.pointee.mHostTime
        if flags.contains(.hostTimeValid), ht0 != 0, clk.hostTime != 0 {
            if !s.engAnchorValid { s.engAnchorSt = clk.sampleTime; s.engAnchorHt = clk.hostTime; s.engAnchorValid = true }
            if flags.contains(.sampleTimeValid), !s.btAnchorValid {
                s.btAnchorSt = outTime.pointee.mSampleTime; s.btAnchorHt = ht0; s.btAnchorValid = true
            }
            if s.btAnchorValid, flags.contains(.sampleTimeValid) {
                let eSpan = Double(Int64(bitPattern: clk.hostTime &- s.engAnchorHt)) * secPerTick
                let bSpan = Double(Int64(bitPattern: ht0 &- s.btAnchorHt)) * secPerTick
                let minSpan = s.ffValid ? max(BTParams.ffMinSpan, BTParams.ffReanchorSpan) : BTParams.ffMinSpan
                if eSpan >= minSpan && bSpan >= BTParams.ffMinSpan {
                    let eRate = Double(clk.sampleTime &- s.engAnchorSt) / eSpan
                    let bRate = (outTime.pointee.mSampleTime - s.btAnchorSt) / bSpan
                    if eRate > 0, bRate > 0 {
                        var f = (eRate / bRate) / nominal - 1
                        if f > lim { f = lim } else if f < -lim { f = -lim }
                        // 平滑：一開始是累計平均（很快有值），之後 EMA（時間常數約 ffSmoothCycles 週期），
                        // 避免每個週期的時間戳抖動直接變成頻率抖動
                        s.ffCount &+= 1
                        let b = max(1 / Double(BTParams.ffSmoothCycles), 1 / Double(s.ffCount))
                        s.ff = s.ffValid ? s.ff + b * (f - s.ff) : f
                        s.ffValid = true
                    }
                }
            }
        }

        // 這個週期第一個輸出 frame 播出時的 engine 時間
        let T: Double
        let ht = outTime.pointee.mHostTime
        if flags.contains(.hostTimeValid), ht != 0, clk.hostTime != 0 {
            let dTicks = Double(Int64(bitPattern: ht &- clk.hostTime))
            T = Double(clk.sampleTime) + dTicks * secPerTick * engRate
        } else {
            T = Double(ring.writeEnd.pointee)
        }

        // 額外延遲（探測偏移＋延遲修正，第 B 輪）：目標由 engine 寫；重新對時時直接採用目標
        let pT = ring.extProbeTarget[slot], cT = ring.extCorrTarget[slot]
        if !s.synced { s.probeCur = pT; s.corrCur = cT }

        // 延遲改變：增益已經是 0 才平移讀取位置（否則這個週期先淡出）；額外延遲也在這時直接跳到目標
        let delay = max(0, ring.extDelayFrames[slot])
        if s.curDelay < 0 { s.curDelay = delay }
        var delayPending = delay != s.curDelay
        if delayPending && s.curGain <= 0 {
            s.readInt &-= Int64(delay - s.curDelay)
            s.curDelay = delay
            let jump = (pT + cT) - (s.probeCur + s.corrCur)
            if jump != 0 {
                let np = s.readFrac - jump
                let fl = np.rounded(.down)
                s.readInt &+= Int64(fl); s.readFrac = np - fl
            }
            s.probeCur = pT; s.corrCur = cT
            delayPending = false
        }

        let P = T - Double(s.curDelay) - safetyMs * 0.001 * engRate - (s.probeCur + s.corrCur)
        guard P.isFinite, abs(P) < 9.0e15 else { s.synced = false; s.curGain = 0; return }
        let pFloor = P.rounded(.down)
        if !s.synced {
            s.readInt = Int64(pFloor); s.readFrac = P - pFloor
            s.errF = 0; s.synced = true; s.curGain = 0
            s.resyncs &+= 1
        }
        var e = Double(s.readInt &- Int64(pFloor)) + (s.readFrac - (P - pFloor))
        if abs(e) > BTParams.resyncMs * 0.001 * engRate {
            s.readInt = Int64(pFloor); s.readFrac = P - pFloor
            e = 0; s.errF = 0; s.curGain = 0
            s.resyncs &+= 1; s.bigErrResyncs &+= 1
        }
        s.lastErr = e
        s.errF += BTParams.errAlpha * (e - s.errF)
        var c = s.ff - (BTParams.kp * s.errF + BTParams.ki * s.integ)
        if c > lim { c = lim } else if c < -lim { c = -lim }
        s.corr = c
        step = nominal * (1 + c)
        // 額外延遲走斜坡：這個週期讀取位置少前進 dE（變速播放，不跳、不淡出）。下個週期的 P 已含新值 → 對時誤差不受影響
        let nEng = Double(n) * step
        let pR = ring.extProbeRate[slot] > 0 ? ring.extProbeRate[slot] : 1
        let cR = ring.extCorrRate[slot] > 0 ? ring.extCorrRate[slot] : 1
        let newP = RTShared.slew(s.probeCur, pT, pR * nEng)
        let newC = RTShared.slew(s.corrCur, cT, cR * nEng)
        let dE = (newP + newC) - (s.probeCur + s.corrCur)
        if dE != 0 { step -= dE / Double(n) }
        guard step > 0, step <= BTParams.maxStep else { s.curGain = 0; return }
        s.probeCur = newP; s.corrCur = newC
        ring.extProbeCur[slot] = newP; ring.extCorrCur[slot] = newC

        // 增益目標
        var target: Float = ring.extGain[slot]
        let so = ring.solo.pointee
        if so >= 0 && so != ProgramRing.externalSoloBase + slot { target = 0 }   // 診斷 solo：只有被 solo 的輸出出聲
        if ring.muteProgram.pointee != 0 || delayPending || !target.isFinite || target < 0 { target = 0 }
        let g0 = s.curGain
        let invN = 1 / Float(n)

        var done = 0
        var pk: Float = 0
        let sc = scratch
        let H = BTSincTable.half
        let NT = BTSincTable.taps
        let L = BTSincTable.phases
        let tab: UnsafeMutablePointer<Float>? = useSinc ? sinc.table(for: engRate) : nil
        if tab == nil { s.hermiteCycles &+= 1 }
        while done < n {
            let m = min(BTParams.maxChunk, n - done)
            let lastPos = s.readFrac + Double(m - 1) * step
            // scratch 從 readInt − H 開始：sinc 需要 [j−H, j+H+1]，Hermite 需要 [j−1, j+2]
            let cnt = Int(lastPos) + NT + 1
            if cnt > scratchFrames || !ring.read(from: s.readInt &- Int64(H), frames: cnt, into: sc) {
                Self.zero(abl)
                s.underruns &+= 1
                s.synced = false
                s.curGain = 0
                return
            }
            for k in 0..<m {
                let p = s.readFrac + Double(k) * step
                let j = Int(p)
                let fr = p - Double(j)
                let gi = g0 + (target - g0) * Float(done + k + 1) * invN
                var l: Float = 0, r: Float = 0
                if let tab {
                    let ft = fr * Double(L)
                    var ph = Int(ft)
                    if ph >= L { ph = L - 1 }
                    let a = Float(ft - Double(ph))
                    let r0 = tab + ph * NT
                    let r1 = r0 + NT
                    var xi = 2 * j                  // scratch 的 sample j（= 位置 j − H）
                    for q in 0..<NT {
                        let c = r0[q] + a * (r1[q] - r0[q])
                        l += c * sc[xi]
                        r += c * sc[xi + 1]
                        xi += 2
                    }
                    l *= gi; r *= gi
                } else {
                    let t = Float(fr)
                    let i = 2 * (j + H - 1)
                    l = Self.hermite(sc[i], sc[i + 2], sc[i + 4], sc[i + 6], t) * gi
                    r = Self.hermite(sc[i + 1], sc[i + 3], sc[i + 5], sc[i + 7], t) * gi
                }
                let al = abs(l), ar = abs(r)
                if al > pk { pk = al }
                if ar > pk { pk = ar }
                let f = done + k
                var ch = 0
                for b in 0..<abl.count {
                    let buf = abl[b]
                    let nc = Int(buf.mNumberChannels)
                    if let d = buf.mData?.assumingMemoryBound(to: Float.self), Int(buf.mDataByteSize) >= (f + 1) * nc * 4 {
                        for cc in 0..<nc {
                            let gc = ch + cc
                            d[f * nc + cc] = totalCh == 1 ? (l + r) * 0.5 : (gc == 0 ? l : (gc == 1 ? r : 0))
                        }
                    }
                    ch += nc
                }
            }
            let np = s.readFrac + Double(m) * step
            let fl = np.rounded(.down)
            s.readInt &+= Int64(fl); s.readFrac = np - fl
            done += m
        }
        // 積分（anti-windup：積分項本身不超過 ±maxPPM）
        s.integ += s.errF * Double(n) * step
        let imax = lim / BTParams.ki
        if s.integ > imax { s.integ = imax } else if s.integ < -imax { s.integ = -imax }
        s.curGain = target
        s.fill = Double(ring.writeEnd.pointee) - (Double(s.readInt) + s.readFrac)
        if pk > s.peak { s.peak = pk }
    }
}

// MARK: - 輸入 stream 關閉（kAudioDevicePropertyIOProcStreamUsage）

enum BTStreamUsage {
    /// struct AudioHardwareIOProcStreamUsage { void* mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[n]; }
    static var headerBytes: Int { MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn) ?? 12 }
    static func byteCount(streams n: Int) -> Int { headerBytes + 4 * max(n, 1) }

    /// 讀這個 IOProc 在某方向的 stream 使用狀態；失敗回 nil
    static func get(device: AudioObjectID, proc: AudioDeviceIOProcID, scope: AudioObjectPropertyScope, streams n: Int) -> [UInt32]? {
        let size = byteCount(streams: n)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size + 8, alignment: 8)
        defer { raw.deallocate() }
        memset(raw, 0, size + 8)
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeRawPointer.self), as: UnsafeRawPointer.self)
        raw.storeBytes(of: UInt32(n), toByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self)
        var a = CA.addr(kAudioDevicePropertyIOProcStreamUsage, scope)
        var sz = UInt32(size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &sz, raw) == noErr else { return nil }
        let got = Int(raw.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self))
        let k = min(got, n)
        return (0..<k).map { raw.load(fromByteOffset: headerBytes + 4 * $0, as: UInt32.self) }
    }

    /// 把這個 IOProc 的所有輸入 stream 關掉並讀回驗證；成功回 nil，失敗回原因
    static func disableInputs(device: AudioObjectID, proc: AudioDeviceIOProcID, streams n: Int) -> String? {
        guard n > 0 else { return nil }
        let size = byteCount(streams: n)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size + 8, alignment: 8)
        defer { raw.deallocate() }
        memset(raw, 0, size + 8)
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeRawPointer.self), as: UnsafeRawPointer.self)
        raw.storeBytes(of: UInt32(n), toByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self)
        // mStreamIsOn 全 0（memset 已清）
        var a = CA.addr(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &a) else { return "裝置沒有 IOProcStreamUsage 屬性" }
        if AudioObjectIsPropertySettable(device, &a, &settable) == noErr, !settable.boolValue { return "IOProcStreamUsage 不可設定" }
        let ss = AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(size), raw)
        guard ss == noErr else { return "設定 IOProcStreamUsage 失敗 status=\(ss)" }
        guard let back = get(device: device, proc: proc, scope: kAudioObjectPropertyScopeInput, streams: n) else {
            return "讀回 IOProcStreamUsage 失敗"
        }
        guard back.count == n, back.allSatisfy({ $0 == 0 }) else { return "讀回的輸入 stream 使用狀態不是全關：\(back)" }
        return nil
    }
}

// MARK: - 單一藍牙輸出

enum BluetoothOutError: Error, CustomStringConvertible {
    case gone
    case badRate(Double)
    case badFormat(String)
    case noSlot
    case ioProc(OSStatus)
    case inputNotDisabled(String)
    case start(OSStatus)

    var description: String {
        switch self {
        case .gone: return "藍牙裝置已不存在或不是可用的藍牙輸出"
        case .badRate(let r): return "藍牙裝置取樣率不合理：\(r) Hz"
        case .badFormat(let s): return "輸出格式不支援：\(s)"
        case .noSlot: return "engine 外接輸出槽已滿或 uid 重複（registerExternalOutput 回 nil）"
        case .ioProc(let s): return "建立藍牙 IOProc 失敗 status=\(s)"
        case .inputNotDisabled(let s): return "無法確認輸入 stream 已關閉（避免 HFP），不啟動：\(s)"
        case .start(let s): return "啟動藍牙輸出失敗 status=\(s)"
        }
    }
}

/// 單一藍牙輸出（只輸出方向）。start/stop 可從任何非即時執行緒呼叫（內部序列化）
final class BluetoothOutput {
    let device: AudioDevice
    private let engine: Engine
    /// engine.registerExternalOutput 給的槽位；nil = 尚未註冊
    var slot: Int? { q.sync { _slot } }
    /// 這次 start 決定的固定緩衝（ms）；未運轉為 nil
    var safetyMs: Double? { q.sync { renderer?.safetyMs } }
    /// 受管理中：IOProc 在跑，或因 HFP 暫停輸出、正在等它回到 A2DP（manager 不需要重建它）
    var isRunning: Bool { q.sync { procID != nil || hfpWaiting } }
    /// IOProc 真的在跑（有出聲的能力）
    var isOutputting: Bool { q.sync { procID != nil } }
    /// 因 HFP（取樣率 < BTParams.minA2DPRate）暫停輸出中
    var isHFPPaused: Bool { q.sync { hfpWaiting } }
    /// 最近一次（重）啟動失敗原因（HFP 暫停時是暫停原因）
    var lastError: String? { q.sync { _lastError } }
    /// 取樣率改變後自動重開／HFP 暫停與恢復的通知（在內部 queue 上呼叫）：
    ///   err = nil → 已重新運轉；latencyMayChange = true → A2DP 串流重新協商過，量到的延遲可能已經不準（要標記需要重新校正）
    var onRestart: ((BluetoothOutput, String?, Bool) -> Void)?
    /// renderer 能不能直接接受這個 engine 取樣率（有預建的 sinc 表；沒有就會退回 Hermite）
    func supportsEngineRate(_ rate: Double) -> Bool { q.sync { renderer?.sinc.table(for: rate) != nil } }

    private let minimumSafetyMs: Double
    private let q: DispatchQueue
    private let listenerQ: DispatchQueue
    private var _slot: Int?
    private var renderer: BTRenderer?
    private var procID: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var _lastError: String?
    private var startedRate: Double = 0
    private var _reportedLatency: String?
    /// 最近一次 attach（start）時系統回報的延遲：kAudioDevicePropertyLatency＋各輸出 stream 的 kAudioStreamPropertyLatency＋safety offset
    /// ＋buffer（frame 與 ms）。用來判斷 app 重開後 A2DP 延遲跳 35 ms 有沒有反映在回報值上
    var reportedLatency: String? { q.sync { _reportedLatency } }
    private var hfpWaiting = false
    /// 已停止但還沒釋放的 renderer 數（延遲釋放中）
    private var deferredFrees = 0
    /// 【第 C 輪】IOProc 成功啟動的次數（取樣率改變重開、HFP 恢復都 +1）：串流識別的一部分（漂移模型在串流重開時歸零）
    private var _startCount = 0
    var startCount: Int { q.sync { _startCount } }

    /// 統計（非即時執行緒讀）
    struct Stats: CustomStringConvertible {
        var ioCycles: Int64 = 0
        var underruns: Int64 = 0
        /// 目前重取樣修正比例（1 + corr）
        var ratio: Double = 1
        /// 低通後的對時誤差（engine frame；正 = 讀得太新）
        var errorFrames: Double = 0
        var resyncs: Int64 = 0
        var idleCycles: Int64 = 0
        var skipEvents: Int64 = 0
        /// writeEnd − 讀取位置（engine frame）
        var fillFrames: Double = 0
        var gain: Float = 0
        var peak: Float = 0
        /// 沒有對應 sinc 表、用 Hermite 的週期數（engine 重建成沒預建的取樣率時 > 0）
        var hermiteCycles: Int64 = 0
        /// engine 時鐘讀取碰到寫入中、沿用上一個時鐘的週期數
        var clockMisses: Int64 = 0

        var description: String {
            String(format: "io=%lld 欠載=%lld 重對時=%lld 閒置=%lld 跳號=%lld 修正=%+.1fppm 誤差=%.2f 填充=%.0f 增益=%.3f 峰值=%.3f%@",
                   ioCycles, underruns, resyncs, idleCycles, skipEvents, (ratio - 1) * 1e6, errorFrames, fillFrames, gain, peak,
                   (hermiteCycles > 0 ? " Hermite週期=\(hermiteCycles)" : "") + (clockMisses > 0 ? " 時鐘沿用=\(clockMisses)" : ""))
        }
    }
    var stats: Stats { q.sync { statsLocked(resetPeak: false) } }
    /// 讀統計並把峰值歸零（面板每秒讀一次用）
    func takeStats() -> Stats { q.sync { statsLocked(resetPeak: true) } }

    init(engine: Engine, device: AudioDevice, minimumSafetyMs: Double = BTParams.defaultSafetyMs) {
        self.engine = engine
        self.device = device
        self.minimumSafetyMs = minimumSafetyMs
        q = DispatchQueue(label: "In_Unison42.bluetooth.\(device.uid)")
        listenerQ = DispatchQueue(label: "In_Unison42.bluetooth.listener.\(device.uid)")
    }

    deinit {
        // 保險：沒呼叫 stop 就被釋放時，照樣清乾淨（q.sync 在 deinit 裡安全：沒有別人持有 self）
        stopLocked()
    }

    private func log(_ s: String) { engine.log("[藍牙 \(device.name)] \(s)") }

    private func statsLocked(resetPeak: Bool) -> Stats {
        guard let r = renderer else { return Stats() }
        let p = r.st
        let s = Stats(ioCycles: p.pointee.ioCycles, underruns: p.pointee.underruns, ratio: 1 + p.pointee.corr,
                      errorFrames: p.pointee.errF, resyncs: p.pointee.resyncs, idleCycles: p.pointee.idleCycles,
                      skipEvents: p.pointee.skipEvents, fillFrames: p.pointee.fill, gain: p.pointee.curGain, peak: p.pointee.peak,
                      hermiteCycles: p.pointee.hermiteCycles, clockMisses: p.pointee.clockMisses)
        if resetPeak { p.pointee.peak = 0 }
        return s
    }

    /// 註冊槽位、建 IOProc（關掉輸入 stream）、配置重取樣 buffer、AudioDeviceStart
    func start() throws {
        try q.sync { try startLocked() }
    }

    /// AudioDeviceStop → DestroyIOProcID → engine.unregisterExternalOutput(slot:) → 釋放 buffer
    func stop() {
        q.sync { stopLocked() }
    }

    private func startLocked() throws {
        guard procID == nil else { return }
        // HFP（通話）模式：不開 IO（開了也只是 8k／16k 單聲道、延遲也跟校正時不同）；保留屬性監聽，回到 A2DP 時自動重開
        let rate = CA.f64(device.id, kAudioDevicePropertyNominalSampleRate) ?? 0
        if rate > 0 && rate < BTParams.minA2DPRate {
            enterHFPWaitLocked(rate: rate)
            return
        }
        hfpWaiting = false
        do {
            try startInner()
            _startCount += 1
            _lastError = nil
        } catch {
            _lastError = "\(error)"
            throw error
        }
    }

    private func startInner() throws {
        let id = device.id
        guard let d = AudioDevice(id: id), d.uid == device.uid, d.isAlive, d.hasOutput, d.kind.isBluetooth else {
            throw BluetoothOutError.gone
        }
        let rate = d.nominalSampleRate
        guard rate >= 4000, rate <= 384_000 else { throw BluetoothOutError.badRate(rate) }
        guard rate >= BTParams.minA2DPRate else { throw BluetoothOutError.badRate(rate) }   // startLocked 已先處理 HFP
        // 輸出 stream 格式：IOProc 看到的是 virtual format，必須是 32-bit float linear PCM
        let outStreams = CA.ids(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        guard !outStreams.isEmpty else { throw BluetoothOutError.badFormat("沒有輸出 stream") }
        for s in outStreams {
            guard let f = CA.get(s, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self) else {
                throw BluetoothOutError.badFormat("讀不到 stream \(s) 的格式")
            }
            let isFloat = f.mFormatID == kAudioFormatLinearPCM && (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && f.mBitsPerChannel == 32
            guard isFloat else {
                throw BluetoothOutError.badFormat("stream \(s)：\(CA.fourCC(f.mFormatID)) flags=\(f.mFormatFlags) \(f.mBitsPerChannel) bit")
            }
        }
        let bufFrames = Int(CA.u32(id, kAudioDevicePropertyBufferFrameSize) ?? 512)
        let safetyOffset = Int(CA.u32(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) ?? 0)
        let safety = BTParams.safetyMs(bufferFrames: bufFrames, safetyOffset: safetyOffset, deviceRate: rate, minimum: minimumSafetyMs)
        let inStreams = CA.ids(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)

        guard let slot = engine.registerExternalOutput(uid: d.uid, name: d.name, isBuiltIn: false) else {
            throw BluetoothOutError.noSlot
        }
        let r = BTRenderer.make(slot: slot, btRate: rate, safetyMs: safety, secPerTick: BTRenderer.hostSecondsPerTick(),
                                engineRates: [44100, 48000, engine.program.sampleRate.pointee])
        let ring = engine.program
        var proc: AudioDeviceIOProcID?
        // 只捕捉值型別（BTRenderer、ProgramRing 都是指標 struct）；不碰 inputData
        let ps = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { _, _, _, outData, outTime in
            r.render(outData, outTime, ring)
        }
        guard ps == noErr, let proc else {
            engine.unregisterExternalOutput(slot: slot); r.free()
            throw BluetoothOutError.ioProc(ps)
        }
        // 絕不開輸入：這個 IOProc 的所有輸入 stream 設為不使用，讀回驗證
        if !inStreams.isEmpty {
            if let why = BTStreamUsage.disableInputs(device: id, proc: proc, streams: inStreams.count) {
                AudioDeviceDestroyIOProcID(id, proc)
                engine.unregisterExternalOutput(slot: slot); r.free()
                throw BluetoothOutError.inputNotDisabled(why)
            }
            log("裝置有 \(inStreams.count) 個輸入 stream：已對本 IOProc 全部關閉並讀回確認")
        }
        let ss = AudioDeviceStart(id, proc)
        guard ss == noErr else {
            AudioDeviceDestroyIOProcID(id, proc)
            engine.unregisterExternalOutput(slot: slot); r.free()
            throw BluetoothOutError.start(ss)
        }
        procID = proc
        renderer = r
        _slot = slot
        startedRate = rate
        addListenersLocked()
        log(String(format: "✓ 只輸出路徑啟動：槽位 %d、%.0f Hz、%d 聲道、buffer %d＋safety offset %d frame → 固定緩衝 %.0f ms",
                   slot, rate, d.outputChannels, bufFrames, safetyOffset, safety))
        // 系統回報的延遲（每次 attach 都記，給「app 重開後延遲跳 35 ms 有沒有反映在回報值上」比對）。只讀屬性，不在 IOProc 裡
        let devLat = Int(CA.u32(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) ?? 0)
        let streamLat = outStreams.map { Int(CA.u32($0, kAudioStreamPropertyLatency) ?? 0) }
        let total = devLat + (streamLat.max() ?? 0) + safetyOffset
        func ms(_ f: Int) -> String { String(format: "%.1f", Double(f) / rate * 1000) }
        let rep = "裝置 latency \(devLat)（\(ms(devLat)) ms）、stream latency \(streamLat.map(String.init).joined(separator: "/"))"
            + "（\(ms(streamLat.max() ?? 0)) ms）、safety offset \(safetyOffset)（\(ms(safetyOffset)) ms）、buffer \(bufFrames)（\(ms(bufFrames)) ms）"
            + " → 裝置＋stream＋safety 合計 \(total) frame（\(ms(total)) ms）@\(Int(rate)) Hz"
        _reportedLatency = rep
        log("系統回報延遲：\(rep)")
    }

    /// keepListeners = true：只停 IO，保留取樣率／存活監聽（取樣率改變重開、HFP 暫停時用）
    private func stopLocked(keepListeners: Bool = false) {
        if !keepListeners { removeListenersLocked(); hfpWaiting = false }
        var deferFree = false
        if let p = procID {
            // 裝置已死（斷線）時 Stop／Destroy 可能直接回錯誤、不等目前的 IO 週期結束 → IOProc 可能還在 render，不能立刻 free
            let alive = (CA.u32(device.id, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
            let s1 = AudioDeviceStop(device.id, p)
            let s2 = AudioDeviceDestroyIOProcID(device.id, p)
            procID = nil
            deferFree = !alive || s1 != noErr || s2 != noErr
            log("已停止（\(statsLocked(resetPeak: false))）" + (deferFree
                ? "；Stop=\(s1) Destroy=\(s2) alive=\(alive) → renderer 延遲 \(Int(BTParams.deferredFreeSeconds)) 秒才釋放" : ""))
        }
        if let s = _slot { engine.unregisterExternalOutput(slot: s); _slot = nil }
        if let r = renderer {
            if deferFree {
                // IOProc 最多還在跑最後一個週期（毫秒級）；幾秒後再釋放。r 是值型別（指標），closure 持有它不會 retain self
                deferredFrees += 1
                q.asyncAfter(deadline: .now() + BTParams.deferredFreeSeconds) { [weak self] in
                    r.free()
                    self?.deferredFrees -= 1
                }
            } else {
                r.free()   // Stop／Destroy 都成功：HAL 已等目前的 IO 週期結束，安全釋放
            }
        }
        renderer = nil
    }

    private func enterHFPWaitLocked(rate: Double) {
        hfpWaiting = true
        startedRate = rate
        _lastError = String(format: "%@ 目前在 HFP 通話模式（%.0f Hz，可能有 app 開了它的麥克風）：暫停輸出、不出聲，回到 A2DP 會自動恢復（之後需要重新校正）",
                            device.name, rate)
        addListenersLocked()
        log("⚠ 取樣率 \(Int(rate)) Hz（HFP）：暫停輸出，等回到 A2DP")
    }

    // MARK: 裝置屬性監聽（取樣率改變 → 重開；裝置消失 → 停止）

    private func addListenersLocked() {
        guard listeners.isEmpty else { return }
        let sels: [AudioObjectPropertySelector] = [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive]
        for sel in sels {
            var a = CA.addr(sel)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // listener queue 只做轉送，不在這裡等任何東西（避免移除 listener 時互等）
                guard let self else { return }
                self.q.async { [weak self] in self?.devicePropertyChanged() }
            }
            if AudioObjectAddPropertyListenerBlock(device.id, &a, listenerQ, block) == noErr {
                listeners.append((a, block))
            }
        }
    }

    private func removeListenersLocked() {
        for (addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(device.id, &a, listenerQ, block)   // 裝置已消失時會失敗，忽略
        }
        listeners = []
    }

    private func devicePropertyChanged() {
        guard procID != nil || hfpWaiting else { return }
        let alive = (CA.u32(device.id, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
        if !alive {
            log("裝置已消失：停止")
            stopLocked()
            onRestart?(self, "裝置已消失", false)   // 重新出現時由 manager 的重連路徑（goneUIDs）標記
            return
        }
        let rate = CA.f64(device.id, kAudioDevicePropertyNominalSampleRate) ?? 0
        if rate > 0 && rate < BTParams.minA2DPRate {
            guard !hfpWaiting else { startedRate = rate; return }
            stopLocked(keepListeners: true)
            enterHFPWaitLocked(rate: rate)
            onRestart?(self, _lastError, true)
            return
        }
        guard hfpWaiting || abs(rate - startedRate) > 0.5 else { return }
        // 取樣率改變（含 HFP → A2DP 恢復）＝A2DP 串流重新協商：固定緩衝可能重算、裝置端延遲可能改變 → 通知需要重新校正
        log(String(format: "取樣率 %.0f → %.0f Hz：重開 IOProc（延遲可能改變，需要重新校正）", startedRate, rate))
        stopLocked(keepListeners: true)
        hfpWaiting = false
        do { try startLocked(); onRestart?(self, nil, true) } catch {
            log("✗ 重開失敗：\(error)")
            onRestart?(self, "\(error)", true)
        }
    }
}

// MARK: - 管理所有藍牙輸出（熱插拔）

final class BluetoothOutManager {
    private let engine: Engine
    private let q = DispatchQueue(label: "In_Unison42.bluetooth.manager")
    private let listenerQ = DispatchQueue(label: "In_Unison42.bluetooth.manager.listener")
    private var _outputs: [String: BluetoothOutput] = [:]
    private var _errors: [String: String] = [:]
    private var permanentFail: [String: AudioObjectID] = [:]
    /// 曾經在跑、後來消失（斷線）或換了 AudioObjectID 的 uid：下次成功 attach 時算「重新連線」
    private var goneUIDs: Set<String> = []
    /// 這個 manager 啟動成功過的 uid（第一次 attach 也要先 hold：藍牙在 app 啟動 30 秒後才第一次連上時，
    /// 不 hold 就會在 AppState 下一次看裝置清單前用舊值出聲最多約 1 秒；2026-09-29 審查）
    private var attachedEver: Set<String> = []
    private var running = false
    private var deviceListener: AudioObjectPropertyListenerBlock?
    /// 【第 C 輪】每次建立 BluetoothOutput 的流水號（streamKeys 用；物件位址可能被重用，所以不用 ObjectIdentifier）
    private var attachSerial = 0
    private var _serials: [String: Int] = [:]

    /// uid → 輸出（快照）
    var outputs: [String: BluetoothOutput] { q.sync { _outputs } }
    /// 【第 C 輪】uid → 目前 A2DP 串流的識別（BluetoothOutput 物件＋它啟動成功的次數）。值變了＝串流重開（重連、app 重開、
    /// 取樣率改變重開、HFP 恢復）→ AppState 把這台的漂移模型歸零。沒有在出聲的不列
    var streamKeys: [String: String] {
        q.sync {
            var d: [String: String] = [:]
            for (uid, o) in _outputs where o.isOutputting { d[uid] = "\(_serials[uid] ?? 0)#\(o.startCount)" }
            return d
        }
    }
    /// uid → 最近一次啟動失敗原因（面板警告 kind .bluetooth 用）；成功啟動後移除
    var errors: [String: String] { q.sync { _errors } }
    /// 輸出清單或錯誤改變時呼叫（主執行緒）
    var onChange: (() -> Void)?
    /// false = 不自己監聽裝置清單，完全由整合者（Reconnect）呼叫 attach/detach/resync
    var watchDeviceList = true
    /// 藍牙裝置斷線後重新連上（同 uid 消失再出現、或 AudioObjectID 換了）並重新啟動成功時呼叫（主執行緒；參數 uid）。
    /// 重連後 A2DP 延遲可能改變 → AppState 標記「需要重新校正」
    var onReconnect: ((String) -> Void)?
    /// 同一次連線中 A2DP 串流重新協商（取樣率改變重開、HFP 暫停／恢復）：延遲可能改變（主執行緒；參數 uid、原因）。
    /// 不經過 goneUIDs，所以不會觸發 onReconnect；AppState 一樣標記「需要重新校正」
    var onLatencyMayChange: ((String, String) -> Void)?
    /// 【第 B 輪，Kang 定案】true：斷線後重新連上的藍牙在重新 start **之前**先請 engine 暫停它出聲（Engine.holdUntilCalibrated），
    /// 之後由 AppState（onReconnect → 自動校正倒數 --only）接手。選單列 app 設 true；校正子行程不設（它不監聽裝置清單）
    var holdOnReconnect = false
    /// holdOnReconnect 時：這個 app 行程**第一次**啟動某台藍牙成功（也先 hold 了）→ 呼叫（主執行緒；參數 uid）。
    /// AppState 決定要不要重校（app 重開 grace 內 → appRelaunch、之後 → 同重連），再把 engine 的暫時 hold 拿掉
    var onFirstConnect: ((String) -> Void)?

    init(engine: Engine) { self.engine = engine }

    /// 所有在跑的藍牙輸出都有這個 engine 取樣率的 sinc 表（engine 換取樣率時不必重開藍牙串流）
    func allSupportEngineRate(_ rate: Double) -> Bool {
        q.sync { _outputs.values.allSatisfy { !$0.isOutputting || $0.supportsEngineRate(rate) } }
    }

    deinit { stopLocked() }

    /// 列舉 Devices.bluetoothOutputs() 建立 BluetoothOutput；監聽裝置清單。主執行緒呼叫，不會卡住（實際工作在背景 queue）
    func start() {
        q.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            if self.watchDeviceList { self.addDeviceListenerLocked() }
            self.resyncLocked()
        }
    }

    /// 停掉全部、移除 listener（同步；app 結束時呼叫）
    func stop() {
        q.sync { stopLocked() }
    }

    /// 依目前裝置清單補建／移除（Reconnect 收到裝置變動時可以直接呼叫）
    func resync() {
        q.async { [weak self] in self?.resyncLocked() }
    }

    /// 指定裝置開始只輸出路徑（必須是 Devices.bluetoothOutputs() 裡的裝置）。已在跑回 true
    @discardableResult
    func attach(deviceID: AudioObjectID) -> Bool {
        q.sync { attachLocked(deviceID: deviceID) }
    }

    /// 停掉指定裝置（依 AudioObjectID）
    func detach(deviceID: AudioObjectID) {
        q.sync {
            for (uid, o) in _outputs where o.device.id == deviceID { detachLocked(uid: uid) }
        }
    }

    /// 停掉指定裝置（依 UID）
    func detach(uid: String) {
        q.sync { detachLocked(uid: uid) }
    }

    /// 模擬斷線重連（ctl／自測用）：停掉這台、當作它消失過，再 attach 同一台 → 走和真的重連一樣的 onReconnect 路徑。
    /// 回傳是否重新啟動成功
    @discardableResult
    func simulateReconnect(uid: String) -> Bool {
        q.sync {
            guard let o = _outputs[uid] else { return false }
            let id = o.device.id
            detachLocked(uid: uid)
            goneUIDs.insert(uid)
            engine.log("藍牙：模擬斷線重連 \(o.device.name)")
            return attachLocked(deviceID: Devices.bluetoothOutputs().first { $0.uid == uid }?.id ?? id)
        }
    }

    /// 全部停掉（不移除裝置清單 listener；之後 resync 會再建回來）
    func detachAll() {
        q.sync { for uid in Array(_outputs.keys) { detachLocked(uid: uid) } }
    }

    // MARK: 內部（都在 q 上）

    private func notify() {
        let cb = onChange
        DispatchQueue.main.async { cb?() }
    }

    private func stopLocked() {
        running = false
        if let b = deviceListener {
            var a = CA.addr(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(CA.system, &a, listenerQ, b)
            deviceListener = nil
        }
        for uid in Array(_outputs.keys) { detachLocked(uid: uid) }
        _errors = [:]
        permanentFail = [:]
    }

    private func addDeviceListenerLocked() {
        guard deviceListener == nil else { return }
        var a = CA.addr(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.q.async { [weak self] in self?.resyncLocked() }
        }
        if AudioObjectAddPropertyListenerBlock(CA.system, &a, listenerQ, block) == noErr {
            deviceListener = block
        } else {
            engine.log("⚠ 藍牙：無法監聽裝置清單（熱插拔要靠 resync()）")
        }
    }

    private func resyncLocked() {
        guard running else { return }
        let want = Devices.bluetoothOutputs()
        var changed = false
        // 消失、或同 uid 換了 AudioObjectID（重新連線）、或已自行停止 → 移除
        for (uid, o) in _outputs {
            let cur = want.first { $0.uid == uid }
            if cur == nil || cur!.id != o.device.id || !o.isRunning {
                if cur == nil || cur!.id != o.device.id { goneUIDs.insert(uid) }
                detachLocked(uid: uid); changed = true
            }
        }
        for d in want where _outputs[d.uid] == nil {
            // 永久性失敗（輸入關不掉、格式不支援）：同一個 AudioObjectID 不再重試，直到裝置重新出現
            if permanentFail[d.uid] == d.id { continue }
            attachLocked(deviceID: d.id)
            changed = true
        }
        // 已不存在的裝置的錯誤訊息清掉
        for uid in _errors.keys where !want.contains(where: { $0.uid == uid }) { _errors[uid] = nil; changed = true }
        for uid in permanentFail.keys where !want.contains(where: { $0.uid == uid }) { permanentFail[uid] = nil }
        if changed { notify() }
    }

    @discardableResult
    private func attachLocked(deviceID: AudioObjectID) -> Bool {
        guard let d = Devices.bluetoothOutputs().first(where: { $0.id == deviceID }) else {
            engine.log("藍牙：裝置 id=\(deviceID) 不是可用的藍牙輸出，不 attach")
            return false
        }
        if let o = _outputs[d.uid] {
            if o.device.id == d.id && o.isRunning { return true }
            detachLocked(uid: d.uid)
        }
        let o = BluetoothOutput(engine: engine, device: d)
        attachSerial += 1
        _serials[d.uid] = attachSerial
        o.onRestart = { [weak self] out, err, latencyMayChange in
            self?.q.async { [weak self] in
                guard let self else { return }
                if let err { self._errors[out.device.uid] = err } else { self._errors[out.device.uid] = nil }
                if latencyMayChange {
                    let cb = self.onLatencyMayChange, uid = out.device.uid
                    let why = err ?? "藍牙取樣率改變、串流重新協商"
                    DispatchQueue.main.async { cb?(uid, why) }
                }
                self.resyncLocked()
                self.notify()
            }
        }
        let firstConnect = !attachedEver.contains(d.uid) && !goneUIDs.contains(d.uid)
        if holdOnReconnect && (goneUIDs.contains(d.uid) || firstConnect) {
            // 重新連線 = A2DP 串流重開，延遲可能差幾十 ms（V8）：先不出聲，等自動重校（AppState.bluetoothReconnected）。
            // 第一次連上（app 啟動 30 秒後才連上）也一樣：先 hold，AppState.bluetoothFirstConnected 決定後才放
            engine.holdUntilCalibrated(uid: d.uid, firstConnect: firstConnect)
        }
        do {
            try o.start()
            _outputs[d.uid] = o
            _errors[d.uid] = o.isHFPPaused ? o.lastError : nil
            attachedEver.insert(d.uid)
            if goneUIDs.remove(d.uid) != nil {
                engine.log("藍牙 \(d.name)：重新連線（id=\(d.id)）")
                let cb = onReconnect, uid = d.uid
                DispatchQueue.main.async { cb?(uid) }
            } else if firstConnect && holdOnReconnect {
                let cb = onFirstConnect, uid = d.uid
                DispatchQueue.main.async { cb?(uid) }
            }
            notify()
            return true
        } catch {
            _errors[d.uid] = "\(error)"
            switch error as? BluetoothOutError {
            case .inputNotDisabled?, .badFormat?: permanentFail[d.uid] = d.id
            default: break
            }
            engine.log("✗ 藍牙 \(d.name)：\(error)")
            notify()
            return false
        }
    }

    private func detachLocked(uid: String) {
        guard let o = _outputs.removeValue(forKey: uid) else { return }
        o.onRestart = nil
        o.stop()
    }
}

// MARK: - 離線自測

/// 離線模擬：engine（寫 ProgramRing）與藍牙裝置（呼叫 BTRenderer.render）兩個獨立時鐘，事件依牆鐘時間交錯
private struct BTSimConfig {
    var name: String
    var engNom = 48000.0
    var engTrue = 48000.0
    var btNom = 48000.0
    var btTrue = 48000.0
    var engBuf = 512
    var btBuf = 512
    var btSafetyOffset = 300          // 藍牙 IOProc 領先輸出的 frame（除了 buffer 以外）
    var engLeadFrames = 512 + 64
    var seconds = 600.0
    var toneHz = 997.0
    var amplitude: Float = 0.5
    var jitterUs = 20.0               // 回報 hostTime 的抖動（±，均勻分佈）
    var delayFrames = 0
    var useSinc = true
    var windows: [Double] = [60, 120, 180, 240, 300, 360, 420, 480, 540, 590]
    var windowSeconds = 1.0
    var convergeAfter = 120.0
    /// 控制事件（在每次藍牙 render 前呼叫：牆鐘秒數、ring）；回傳 false = 這一刻 engine 不寫（停止中）
    var engineRunning: ((Double) -> Bool)? = nil
    /// engine 重新啟動時的行為（模擬真的聚合裝置重建）：
    /// restartSampleTime ≠ nil → 新世代的 sampleTime 從這個值開始（新時間軸；真的聚合裝置重建不會接續舊的 sampleTime）；
    /// startingSeconds：generation／取樣率已設好、但新 IOProc 還沒第一次寫入的時間（聚合裝置啟動期間）；
    /// legacyRestart = true → 照舊版只做 generation +1、設取樣率（不呼叫 ProgramRing.beginGeneration，重現舊問題用）
    var restartSampleTime: Int64? = nil
    var startingSeconds = 0.0
    var legacyRestart = false
    /// 追蹤區間（牆鐘秒）：記錄這段期間 |誤差低通| 最大值與 |修正 − 理論| 最大值
    var trackFrom = -1.0
    var trackTo = -1.0
    var control: ((Double, ProgramRing, BTRenderer) -> Void)? = nil
}

private struct BTSimResult {
    var thdn: [(Double, Double)] = []      // (視窗起點秒, dB)：4 參數（頻率也擬合）
    var thdnFixed: [(Double, Double)] = [] // 3 參數（頻率固定為理論值，最嚴格）
    var maxAbsErrAfter = 0.0              // 收斂後原始誤差最大值（frame）
    var maxAbsErrFAfter = 0.0
    var minFillAfter = Double.infinity
    var maxFillAfter = -Double.infinity
    var meanFillAfter = 0.0
    var finalCorrPPM = 0.0
    var expectedCorrPPM = 0.0
    var underruns: Int64 = 0
    var resyncs: Int64 = 0
    var bigErrResyncs: Int64 = 0
    var idle: Int64 = 0
    var btCycles: Int64 = 0
    var safetyMs = 0.0
    var outputSamplesAfter: [Float] = []  // 選用：保存特定區間輸出（控制測試用）
    var gainTrace: [(Double, Float)] = []
    var curDelayEnd = 0
    var maxAbsErrFTrack = 0.0
    var maxCorrDevTrackPPM = 0.0
}

private func btSimulate(_ cfg: BTSimConfig, keepFrom: Double? = nil, keepSeconds: Double = 0) -> BTSimResult {
    var res = BTSimResult()
    let mute = RTShared.alloc(1, 0)
    let soloP = RTShared.alloc(1, -1)
    let ring = ProgramRing(muteProgram: mute, solo: soloP)
    ring.sampleRate.pointee = cfg.engNom
    ring.generation.pointee = 1
    ring.extUsed[0] = 1
    ring.extGain[0] = 1
    ring.extActive[0] = 1
    ring.extDelayFrames[0] = cfg.delayFrames
    let safety = BTParams.safetyMs(bufferFrames: cfg.btBuf, safetyOffset: cfg.btSafetyOffset, deviceRate: cfg.btNom)
    res.safetyMs = safety
    let r = BTRenderer.make(slot: 0, btRate: cfg.btNom, safetyMs: safety, secPerTick: 1e-9, engineRates: [cfg.engNom], useSinc: cfg.useSinc)
    let ebuf = UnsafeMutablePointer<Float>.allocate(capacity: cfg.engBuf * 2)
    let bbuf = UnsafeMutablePointer<Float>.allocate(capacity: cfg.btBuf * 2)
    defer { ebuf.deallocate(); bbuf.deallocate(); r.free(); ring.free(); mute.deallocate(); soloP.deallocate() }

    var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
    func jitter() -> Double {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return (Double(rng >> 11) / Double(1 << 53) * 2 - 1) * cfg.jitterUs * 1e-6
    }
    let hostBase = 1000.0   // 秒（避免負的 tick）
    func ticks(_ s: Double) -> UInt64 { UInt64(((hostBase + s) * 1e9).rounded()) }

    let hE0 = 0.100, hB0 = 0.150
    let engLead = Double(cfg.engLeadFrames) / cfg.engTrue
    let btLead = Double(cfg.btBuf + cfg.btSafetyOffset) / cfg.btTrue
    var ke = 0, mb = 0
    var es: Int64 = 0                 // engine sampleTime（只有寫入時前進）
    var engWasRunning = true
    var writesResumeAt = -1.0          // 重啟中：到這個牆鐘時間才第一次寫入
    let expectedCorr = (cfg.engTrue / cfg.btTrue) / (cfg.engNom / cfg.btNom) - 1
    let omegaE = 2 * Double.pi * cfg.toneHz / cfg.engTrue

    // THD+N 視窗
    let wLen = Int(cfg.windowSeconds * cfg.btTrue)
    let wStarts: [Int] = cfg.windows.map { Int($0 * cfg.btTrue) }
    var wData: [[Float]] = wStarts.map { _ in [] }
    var errSamples = 0
    var fillSum = 0.0
    let keepStart = keepFrom.map { Int($0 * cfg.btTrue) } ?? -1
    let keepLen = Int(keepSeconds * cfg.btTrue)
    if keepStart >= 0 { res.outputSamplesAfter.reserveCapacity(keepLen) }
    for i in wData.indices { wData[i].reserveCapacity(wLen) }

    while true {
        let hE = hE0 + Double(ke * cfg.engBuf) / cfg.engTrue
        let hB = hB0 + Double(mb * cfg.btBuf) / cfg.btTrue
        let wE = hE - engLead, wB = hB - btLead
        if min(wE, wB) > cfg.seconds { break }
        if wE <= wB {
            let run = cfg.engineRunning?(wE) ?? true
            if run && !engWasRunning {   // engine 重新啟動：換世代（和 Engine.startLocked 一樣先於第一次寫入）
                if cfg.legacyRestart {
                    ring.generation.pointee &+= 1
                    ring.sampleRate.pointee = cfg.engNom
                } else {
                    ring.beginGeneration(sampleRate: cfg.engNom)
                }
                writesResumeAt = wE + cfg.startingSeconds
                if let st = cfg.restartSampleTime { es = st }
            }
            if run && wE < writesResumeAt {
                // 聚合裝置啟動中：還沒有寫入
            } else if run {
                for f in 0..<cfg.engBuf {
                    let v = cfg.amplitude * Float(sin(omegaE * Double(es + Int64(f))))
                    ebuf[2 * f] = v; ebuf[2 * f + 1] = -v
                }
                ring.write(ebuf, inCh: 2, frames: cfg.engBuf, at: es, hostTime: ticks(hE + jitter()))
                es += Int64(cfg.engBuf)
            } else if engWasRunning {
                ring.sampleRate.pointee = 0
            }
            engWasRunning = run
            ke += 1
        } else {
            cfg.control?(wB, ring, r)
            var abl = AudioBufferList(mNumberBuffers: 1,
                                      mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(cfg.btBuf * 8), mData: bbuf))
            var ts = AudioTimeStamp()
            ts.mSampleTime = Double(mb * cfg.btBuf)
            ts.mHostTime = ticks(hB + jitter())
            ts.mRateScalar = 1
            ts.mFlags = [.sampleTimeValid, .hostTimeValid]
            withUnsafeMutablePointer(to: &abl) { ap in
                withUnsafePointer(to: &ts) { tp in r.render(ap, tp, ring) }
            }
            let j0 = mb * cfg.btBuf
            for (wi, ws) in wStarts.enumerated() where j0 + cfg.btBuf > ws && j0 < ws + wLen {
                for f in 0..<cfg.btBuf {
                    let j = j0 + f
                    if j >= ws && j < ws + wLen { wData[wi].append(bbuf[2 * f]) }
                }
            }
            if keepStart >= 0, j0 + cfg.btBuf > keepStart, j0 < keepStart + keepLen {
                for f in 0..<cfg.btBuf where j0 + f >= keepStart && j0 + f < keepStart + keepLen { res.outputSamplesAfter.append(bbuf[2 * f]) }
            }
            res.gainTrace.append((wB, r.st.pointee.curGain))
            if wB >= cfg.trackFrom && wB < cfg.trackTo {
                let s = r.st.pointee
                res.maxAbsErrFTrack = max(res.maxAbsErrFTrack, abs(s.errF))
                res.maxCorrDevTrackPPM = max(res.maxCorrDevTrackPPM, abs(s.corr - expectedCorr) * 1e6)
            }
            if hB > cfg.convergeAfter {
                let s = r.st.pointee
                res.maxAbsErrAfter = max(res.maxAbsErrAfter, abs(s.lastErr))
                res.maxAbsErrFAfter = max(res.maxAbsErrFAfter, abs(s.errF))
                res.minFillAfter = min(res.minFillAfter, s.fill)
                res.maxFillAfter = max(res.maxFillAfter, s.fill)
                fillSum += s.fill; errSamples += 1
            }
            mb += 1
        }
    }
    let s = r.st.pointee
    res.meanFillAfter = errSamples > 0 ? fillSum / Double(errSamples) : .nan
    res.finalCorrPPM = s.corr * 1e6
    res.expectedCorrPPM = ((cfg.engTrue / cfg.btTrue) / (cfg.engNom / cfg.btNom) - 1) * 1e6
    res.underruns = s.underruns
    res.resyncs = s.resyncs
    res.bigErrResyncs = s.bigErrResyncs
    res.idle = s.idleCycles
    res.btCycles = s.ioCycles
    res.curDelayEnd = s.curDelay
    let omegaB = 2 * Double.pi * cfg.toneHz / cfg.btTrue
    for (wi, w) in wData.enumerated() where w.count == wLen {
        res.thdn.append((cfg.windows[wi], btThdN(w, omega: omegaB, freeFrequency: true)))
        res.thdnFixed.append((cfg.windows[wi], btThdN(w, omega: omegaB)))
    }
    return res
}

/// 小型最小平方：解 (XᵀX) c = Xᵀy（高斯消去，部分選主元）
private func btSolve(_ a0: [[Double]], _ b0: [Double]) -> [Double] {
    var m = a0, rhs = b0
    let n = rhs.count
    for c in 0..<n {
        let piv = (c..<n).max { abs(m[$0][c]) < abs(m[$1][c]) }!
        m.swapAt(c, piv); rhs.swapAt(c, piv)
        guard m[c][c] != 0 else { continue }
        for r2 in 0..<n where r2 != c {
            let f = m[r2][c] / m[c][c]
            for k in 0..<n { m[r2][k] -= f * m[c][k] }
            rhs[r2] -= f * rhs[c]
        }
    }
    return (0..<n).map { m[$0][$0] != 0 ? rhs[$0] / m[$0][$0] : 0 }
}

/// THD+N（dB）= 殘差功率 / 擬合正弦功率。
/// freeFrequency = false：3 參數擬合（sin、cos、DC，頻率固定為理論值）——視窗內任何相位漂移都算進 N（最嚴格）。
/// freeFrequency = true：IEEE 1057 4 參數擬合（頻率也擬合）——等同分析儀的陷波器追蹤基頻，視窗內的等速相位漂移不算 N。
private func btThdN(_ y: [Float], omega omega0: Double, freeFrequency: Bool = false) -> Double {
    var omega = omega0
    var coef = [0.0, 0.0, 0.0]
    func fit3() {
        var a = [[Double]](repeating: [0, 0, 0], count: 3), b = [0.0, 0.0, 0.0]
        for (j, v) in y.enumerated() {
            let x = [sin(omega * Double(j)), cos(omega * Double(j)), 1.0]
            for p in 0..<3 { b[p] += x[p] * Double(v); for q in 0..<3 { a[p][q] += x[p] * x[q] } }
        }
        coef = btSolve(a, b)
    }
    fit3()
    if freeFrequency {
        for _ in 0..<8 {
            var a = [[Double]](repeating: [0, 0, 0, 0], count: 4), b = [0.0, 0.0, 0.0, 0.0]
            for (j, v) in y.enumerated() {
                let t = Double(j)
                let sn = sin(omega * t), cs = cos(omega * t)
                let x = [sn, cs, 1.0, t * (coef[0] * cs - coef[1] * sn)]
                for p in 0..<4 { b[p] += x[p] * Double(v); for q in 0..<4 { a[p][q] += x[p] * x[q] } }
            }
            let c4 = btSolve(a, b)
            coef = [c4[0], c4[1], c4[2]]
            omega += c4[3]
            if abs(c4[3]) < 1e-15 { break }
        }
        fit3()
    }
    var sig = 0.0, res = 0.0
    for (j, v) in y.enumerated() {
        let sv = coef[0] * sin(omega * Double(j)) + coef[1] * cos(omega * Double(j))
        sig += sv * sv
        let d = Double(v) - sv - coef[2]
        res += d * d
    }
    return sig > 0 ? 10 * log10(max(res, 1e-30) / sig) : 0
}

/// `In_Unison42 bluetooth-selftest`：重取樣器＋對時的離線測試（不出聲、不開裝置）；最後列出藍牙裝置的唯讀資訊
func runBluetoothSelfTest() -> Int32 {
    var fail = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "　\(detail)")")
        if !ok { fail += 1 }
    }
    let t0 = Date()

    print("── 1. 基本元件 ──")
    do {
        // Catmull-Rom Hermite 對直線精確
        var worst: Float = 0
        for k in 0..<10 {
            let t = Float(k) / 10
            worst = max(worst, abs(BTRenderer.hermite(1, 2, 3, 4, t) - (2 + t)))
        }
        check(worst < 1e-6, "Hermite 插值對直線精確", "最大誤差 \(worst)")
        check(BTStreamUsage.headerBytes == 12 && BTStreamUsage.byteCount(streams: 3) == 24,
              "AudioHardwareIOProcStreamUsage 版面（mStreamIsOn 位移 12、3 個 stream 共 24 byte）",
              "offset=\(BTStreamUsage.headerBytes)")
        check(BTParams.safetyMs(bufferFrames: 512, safetyOffset: 300, deviceRate: 44100) == 30
              && BTParams.safetyMs(bufferFrames: 2048, safetyOffset: 1000, deviceRate: 44100) == 80,
              "固定緩衝：一般 30 ms、大 buffer 取整到 10 ms",
              "\(BTParams.safetyMs(bufferFrames: 2048, safetyOffset: 1000, deviceRate: 44100)) ms")
    }

    func report(_ c: BTSimConfig, _ r: BTSimResult, thdLimit: Double = -60) {
        print(String(format: "  [%@] 固定緩衝 %.0f ms；藍牙週期 %lld；收斂後誤差 max %.2f frame（低通 %.2f）；填充 %.0f…%.0f（平均 %.1f）；修正 %+.2f ppm（理論 %+.2f）；欠載 %lld、重對時 %lld（誤差過大 %lld）、閒置 %lld",
                     c.name, r.safetyMs, r.btCycles, r.maxAbsErrAfter, r.maxAbsErrFAfter, r.minFillAfter, r.maxFillAfter, r.meanFillAfter,
                     r.finalCorrPPM, r.expectedCorrPPM, r.underruns, r.resyncs, r.bigErrResyncs, r.idle))
        print("  THD+N（\(Int(c.toneHz)) Hz，每視窗 \(c.windowSeconds) s，4 參數擬合）：" + r.thdn.map { String(format: "%.0fs %.1f", $0.0, $0.1) }.joined(separator: "、") + " dB")
        print("  參考：頻率固定 3 參數擬合（視窗內相位漂移全算 N）：" + r.thdnFixed.map { String(format: "%.0fs %.1f", $0.0, $0.1) }.joined(separator: "、") + " dB")
    }

    // 2. 兩種時鐘各 10 分鐘等效資料
    let cases: [BTSimConfig] = [
        BTSimConfig(name: "48000 vs 48000×(1+300ppm)", btNom: 48000, btTrue: 48000 * (1 + 300e-6)),
        BTSimConfig(name: "48000 vs 44100", btNom: 44100, btTrue: 44100),
        BTSimConfig(name: "48000(−50ppm) vs 44100(+200ppm)，buffer 1024、延遲 1500 frame", engTrue: 48000 * (1 - 50e-6),
                    btNom: 44100, btTrue: 44100 * (1 + 200e-6), btBuf: 1024, btSafetyOffset: 600, delayFrames: 1500),
    ]
    for (i, c) in cases.enumerated() {
        print("── \(2 + i). 模擬 10 分鐘：\(c.name) ──")
        let r = btSimulate(c)
        report(c, r)
        check(r.underruns == 0, "無欠載", "\(r.underruns)")
        check(r.resyncs == 1 && r.bigErrResyncs == 0, "只在開頭對時一次、沒有誤差過大重對時", "resyncs=\(r.resyncs)")
        check(r.maxAbsErrFAfter < 2 && r.maxAbsErrAfter < 4, "填充量／對時誤差收斂（\(Int(c.convergeAfter)) s 後 |誤差| 低通 < 2、原始 < 4 frame）",
              String(format: "%.2f / %.2f", r.maxAbsErrFAfter, r.maxAbsErrAfter))
        check(r.maxFillAfter - r.minFillAfter < Double(c.engBuf) + 40 && r.minFillAfter > 0,
              "填充量穩定（範圍 < engine 一個週期＋40、始終 > 0）", String(format: "%.0f…%.0f", r.minFillAfter, r.maxFillAfter))
        check(abs(r.finalCorrPPM - r.expectedCorrPPM) < 5, "重取樣修正收斂到時鐘差（誤差 < 5 ppm）",
              String(format: "%+.2f vs %+.2f ppm", r.finalCorrPPM, r.expectedCorrPPM))
        let worst = r.thdn.map(\.1).max() ?? 0
        check(r.thdn.count == c.windows.count && worst < -60, "重取樣後正弦 THD+N < −60 dB（全部視窗）", String(format: "最差 %.1f dB", worst))
    }

    // 5. engine 停 1 秒再重建（generation +1、取樣率 0）：不崩潰、閒置計數、之後重新對時並收斂
    print("── 5. engine 中途停止 1 秒後重建 ──")
    do {
        var c = BTSimConfig(name: "engine 停止/重建", btNom: 44100, btTrue: 44100 * (1 + 100e-6))
        c.seconds = 120; c.windows = [100]; c.convergeAfter = 80
        c.engineRunning = { w in !(w >= 30 && w < 31) }
        let r = btSimulate(c)
        report(c, r)
        check(r.idle > 0, "停止期間輸出靜音並計數閒置", "閒置 \(r.idle) 週期、欠載 \(r.underruns)")
        check(r.resyncs >= 2, "重建後重新對時", "resyncs=\(r.resyncs)")
        check(r.maxAbsErrFAfter < 2 && (r.thdn.first?.1 ?? 0) < -60, "重建後收斂、THD+N < −60 dB",
              String(format: "誤差 %.2f、%.1f dB", r.maxAbsErrFAfter, r.thdn.first?.1 ?? 0))
    }

    // 5b. 真實的重建：新世代 sampleTime 換一條時間軸、聚合裝置啟動 250 ms 才第一次寫入（校正暫停→恢復就是這條路）
    //     舊版（legacyRestart）：藍牙拿舊時鐘外插 → 啟動期間每個週期欠載＋重對時；前饋錨點下在舊時間軸 → 修正偏好幾百 ppm、好幾分鐘才收斂
    print("── 5b. engine 重建（新時間軸＋啟動 250 ms）：修正前 vs 修正後 ──")
    do {
        func run(_ legacy: Bool, newTimeline: Int64) -> BTSimResult {
            var c = BTSimConfig(name: legacy ? "舊版" : "修正後", btNom: 44100, btTrue: 44100 * (1 + 100e-6))
            c.seconds = 200; c.windows = [150]; c.convergeAfter = 150
            c.engineRunning = { w in !(w >= 60 && w < 63) }
            c.restartSampleTime = newTimeline; c.startingSeconds = 0.25; c.legacyRestart = legacy
            c.trackFrom = 64; c.trackTo = 200
            return btSimulate(c)
        }
        // 新時間軸比舊的後面 5 秒（舊 sampleTime ≈ 60 s × 48k；新的從 65 s × 48k 開始）與從 0 開始兩種
        for tl: Int64 in [Int64(65 * 48000), 0] {
            let old = run(true, newTimeline: tl), new = run(false, newTimeline: tl)
            print(String(format: "  新時間軸起點 %lld：舊版 欠載 %lld、重對時 %lld、重建後 |誤差低通| 最大 %.1f frame、|修正−理論| 最大 %.0f ppm；"
                         + "修正後 欠載 %lld、重對時 %lld、閒置 %lld、|誤差低通| 最大 %.2f frame、|修正−理論| 最大 %.1f ppm",
                         tl, old.underruns, old.resyncs, old.maxAbsErrFTrack, old.maxCorrDevTrackPPM,
                         new.underruns, new.resyncs, new.idle, new.maxAbsErrFTrack, new.maxCorrDevTrackPPM))
            check(new.underruns == 0 && new.resyncs == 2 && new.bigErrResyncs == 0,
                  "重建（新時間軸 \(tl)）：啟動期間只算閒置、不欠載，只重新對時一次", "欠載 \(new.underruns)、重對時 \(new.resyncs)")
            check(new.maxAbsErrFTrack < 4 && new.maxCorrDevTrackPPM < 30,
                  "重建後（重建 1 s 後起算）誤差 < 4 frame、修正偏差 < 30 ppm（不會像舊版漂幾百 frame）",
                  String(format: "%.2f frame、%.1f ppm", new.maxAbsErrFTrack, new.maxCorrDevTrackPPM))
        }
    }

    // 6. 增益／靜音／延遲改變（控制端事件）
    print("── 6. 增益 ramp、節目靜音、延遲改變 ──")
    do {
        var c = BTSimConfig(name: "控制事件", btNom: 44100, btTrue: 44100)
        c.seconds = 40; c.windows = [35]; c.convergeAfter = 36
        c.control = { w, ring, _ in
            ring.extGain[0] = (w >= 10 && w < 12) ? 0 : 1           // plan 不出聲 → 淡出
            ring.muteProgram.pointee = (w >= 14 && w < 16) ? 1 : 0  // 校正中節目靜音
            ring.extDelayFrames[0] = w >= 20 ? 2400 : 0             // 延遲改變 0 → 50 ms
            // 診斷 solo：25–27 s solo 聚合裝置輸出 0（藍牙要靜音）；28–30 s solo 自己的槽（照常出聲）
            ring.solo.pointee = (w >= 25 && w < 27) ? 0 : ((w >= 28 && w < 30) ? ProgramRing.externalSoloBase + 0 : -1)
        }
        let r = btSimulate(c, keepFrom: 9.5, keepSeconds: 22)
        let sr = 44100.0
        func peak(_ a: Double, _ b: Double) -> Float {
            let s = r.outputSamplesAfter
            let i0 = max(0, Int((a - 9.5) * sr)), i1 = min(s.count, Int((b - 9.5) * sr))
            return i0 < i1 ? s[i0..<i1].map { abs($0) }.max() ?? 0 : 0
        }
        // 注意：輸出 sample 的時間軸比牆鐘晚約 0.13 s（hB0 − btLead），視窗避開切換點前後
        check(peak(10.2, 11.7) == 0 && peak(12.2, 13.7) > 0.45, "extGain=0 一個週期內淡出到 0、恢復後淡入",
              String(format: "關閉中峰值 %.4f、恢復後 %.3f", peak(10.2, 11.7), peak(12.2, 13.7)))
        check(peak(14.2, 15.7) == 0 && peak(16.2, 17.7) > 0.45, "muteProgram=1 → 靜音、解除後恢復",
              String(format: "%.4f / %.3f", peak(14.2, 15.7), peak(16.2, 17.7)))
        let g = r.gainTrace.filter { $0.0 >= 19.9 && $0.0 < 20.2 }.map(\.1)
        check(g.contains(0) && r.curDelayEnd == 2400 && r.bigErrResyncs == 0, "延遲改變：先淡出到 0 再切換（不算誤差過大重對時）",
              "curDelay=\(r.curDelayEnd) 週期增益 \(g.map { String(format: "%.2f", $0) }.joined(separator: ","))")
        check(r.maxAbsErrFAfter < 2 && (r.thdn.first?.1 ?? 0) < -60, "延遲改變後仍收斂、THD+N < −60 dB",
              String(format: "%.2f frame、%.1f dB", r.maxAbsErrFAfter, r.thdn.first?.1 ?? 0))
        check(peak(25.3, 26.7) == 0 && peak(28.3, 29.7) > 0.45 && peak(30.3, 31.3) > 0.45,
              "solo 別的輸出 → 藍牙靜音；solo 自己的槽（externalSoloBase＋槽位）→ 出聲；解除 solo → 出聲",
              String(format: "%.4f / %.3f / %.3f", peak(25.3, 26.7), peak(28.3, 29.7), peak(30.3, 31.3)))
    }

    // 6b. 【第 B 輪】探測偏移（+3.5 ms、0.5 s 斜坡）與延遲修正（≤ 0.1 ms/秒）：讀取點平滑移動，不淡出、不重對時
    print("── 6b. 探測偏移與延遲修正（讀取點緩慢斜率）──")
    do {
        var c = BTSimConfig(name: "探測＋修正", btNom: 44100, btTrue: 44100 * (1 + 50e-6))
        c.seconds = 70; c.windows = [40, 55, 66]; c.convergeAfter = 60
        c.delayFrames = 4800
        let probe = 168.0                                   // 3.5 ms @48k（engine frame）
        let corr = 96.0                                     // 2 ms
        c.control = { w, ring, _ in
            ring.extProbeRate[0] = probe / (0.5 * 48000)
            ring.extProbeTarget[0] = (w >= 10 && w < 13) ? probe : 0
            ring.extCorrRate[0] = Engine.correctionSlewMsPerSecond / 1000
            ring.extCorrTarget[0] = w >= 30 ? corr : 0
        }
        c.trackFrom = 9; c.trackTo = 70
        let r = btSimulate(c, keepFrom: 9, keepSeconds: 6)
        let y = r.outputSamplesAfter
        var worst: Float = 0
        for i in 1..<y.count { worst = max(worst, abs(y[i] - y[i - 1])) }
        let theo = Float(2 * 0.5 * sin(Double.pi * 997 / 44100))   // 正常播放的理論最大相鄰差
        check(worst <= theo * 1.02, "探測斜坡（9–15 s）相鄰樣本差 ≤ 理論值 × 1.02（沒有跳點、沒有淡出）",
              String(format: "%.4f vs 理論 %.4f", worst, theo))
        let minGain = r.gainTrace.filter { $0.0 >= 9 && $0.0 < 15 }.map(\.1).min() ?? 0
        check(minGain > 0.99, "探測期間增益不變（不是淡出／淡入）", String(format: "最低 %.3f", minGain))
        check(r.bigErrResyncs == 0 && r.resyncs == 1 && r.underruns == 0 && r.maxAbsErrFTrack < 4,
              "讀取點平移計入對時：不重對時、不欠載、誤差 < 4 frame（若沒計入會跳 168 frame）",
              String(format: "重對時 %lld、欠載 %lld、誤差 %.2f", r.resyncs, r.underruns, r.maxAbsErrFTrack))
        let worstThd = r.thdn.map(\.1).max() ?? 0
        check(r.thdn.count == 3 && worstThd < -60, "修正（2 ms、20 秒）期間與之後 THD+N < −60 dB（變速 100 ppm）",
              r.thdn.map { String(format: "%.0fs %.1f", $0.0, $0.1) }.joined(separator: "、"))

        // 真的有移動：125 Hz（週期 8 ms）正弦的相位 → 延遲變化量（沒實作的話相位不會變）
        var c2 = c
        c2.name = "探測＋修正（125 Hz 量相位）"; c2.toneHz = 125; c2.windows = []
        let r2 = btSimulate(c2, keepFrom: 8, keepSeconds: 50)
        let btTrue = 44100 * (1 + 50e-6)
        let omega = 2 * Double.pi * 125 / btTrue
        func phase(_ a: Double, _ b: Double) -> Double {
            let i0 = Int((a - 8) * btTrue), i1 = Int((b - 8) * btTrue)
            var ss = 0.0, sc = 0.0, cc = 0.0, ys = 0.0, yc = 0.0
            for i in i0..<i1 {
                let j = Double(i), v = Double(r2.outputSamplesAfter[i])
                let sn = sin(omega * j), cs = cos(omega * j)
                ss += sn * sn; sc += sn * cs; cc += cs * cs; ys += v * sn; yc += v * cs
            }
            let det = ss * cc - sc * sc
            let A = (ys * cc - yc * sc) / det, B = (yc * ss - ys * sc) / det   // v ≈ A sin + B cos = R sin(ωj + φ)
            return atan2(B, A)
        }
        func wrap(_ x: Double) -> Double { var y = x.truncatingRemainder(dividingBy: 2 * .pi); if y > .pi { y -= 2 * .pi }; if y < -.pi { y += 2 * .pi }; return y }
        let p0 = phase(8.5, 9.5), pHold = phase(11.3, 12.6), pAfter = phase(20, 21), pCorr = phase(55, 56)
        func msOf(_ dphi: Double) -> Double { -wrap(dphi) / (2 * .pi * 125) * 1000 }
        check(abs(msOf(pHold - p0) - 3.5) < 0.05 && abs(msOf(pAfter - p0)) < 0.05,
              "探測期間輸出晚了 3.5 ms、移除後回到原位（125 Hz 相位量）",
              String(format: "探測中 %+.3f ms、之後 %+.3f ms", msOf(pHold - p0), msOf(pAfter - p0)))
        check(abs(msOf(pCorr - p0) - 2.0) < 0.1, "延遲修正 2 ms 套用完成（相位量；藍牙 PI 對時誤差約 ±2 frame ≈ 0.04 ms）", String(format: "%+.3f ms", msOf(pCorr - p0)))
    }

    // 7. 頻率響應／高頻失真：sinc（正式路徑）與 Hermite（備援）各 30 s
    print("── 7. 高頻正弦（48000 → 44100，各 30 s）：sinc（正式）vs Hermite（備援，不計入判定）──")
    for hz in [5000.0, 10000.0, 15000.0, 19000.0] {
        var line = String(format: "  %5.0f Hz：", hz)
        var sincDb = 0.0
        for useSinc in [true, false] {
            var c = BTSimConfig(name: "\(Int(hz)) Hz", btNom: 44100, btTrue: 44100)
            c.seconds = 30; c.toneHz = hz; c.windows = [25]; c.convergeAfter = 20; c.useSinc = useSinc
            let r = btSimulate(c)
            let db = r.thdn.first?.1 ?? 0
            if useSinc { sincDb = db }
            line += String(format: "%@ THD+N %.1f dB　", useSinc ? "sinc" : "Hermite", db)
        }
        print(line)
        if hz <= 15000 { check(sincDb < -60, String(format: "sinc 插值 %.0f Hz THD+N < −60 dB", hz), String(format: "%.1f dB", sincDb)) }
    }
    do {
        var c = BTSimConfig(name: "Hermite 備援 1 kHz", btNom: 44100, btTrue: 44100 * (1 + 300e-6))
        c.seconds = 120; c.windows = [60, 100]; c.convergeAfter = 60; c.useSinc = false
        let r = btSimulate(c)
        print("  參考：Hermite 備援 997 Hz（+300 ppm，120 s）：" + r.thdn.map { String(format: "%.0fs %.1f dB", $0.0, $0.1) }.joined(separator: "、"))
    }

    // 8. 唯讀：目前的藍牙輸出裝置（只讀屬性，不開 IO、不開麥克風）
    print("── 8. 目前的藍牙輸出（唯讀屬性）──")
    let bts = Devices.bluetoothOutputs()
    if bts.isEmpty { print("  （沒有藍牙輸出裝置）") }
    for d in bts {
        let inS = CA.ids(d.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count
        let outS = CA.ids(d.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        let buf = Int(CA.u32(d.id, kAudioDevicePropertyBufferFrameSize) ?? 0)
        let so = Int(CA.u32(d.id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) ?? 0)
        let lat = Int(CA.u32(d.id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) ?? 0)
        let fmts = outS.compactMap { CA.get($0, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self) }
            .map { "\(CA.fourCC($0.mFormatID)) \($0.mBitsPerChannel)bit \($0.mChannelsPerFrame)ch" }
        print(String(format: "  %@：%.0f Hz、輸出 %d stream（%@）、輸入 %d stream%@、buffer %d、safety offset %d、裝置延遲 %d frame → 固定緩衝 %.0f ms",
                     d.name, d.nominalSampleRate, outS.count, fmts.joined(separator: "/"), inS,
                     inS > 0 ? "（啟動時會對本 IOProc 關閉）" : "", buf, so, lat,
                     BTParams.safetyMs(bufferFrames: buf, safetyOffset: so, deviceRate: d.nominalSampleRate)))
    }

    print(String(format: "（耗時 %.1f s）", Date().timeIntervalSince(t0)))
    print(fail == 0 ? "✓ bluetooth 自測全部通過" : "✗ \(fail) 項失敗")
    return fail == 0 ? 0 : 1
}
