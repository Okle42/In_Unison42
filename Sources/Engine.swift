// Engine.swift — Process Tap → 私有聚合裝置 → IOProc（延遲線、增益、測試訊號注入）
//
// 執行緒模型：
//   * 所有公開方法都可以從任何非即時執行緒呼叫；內部一律序列化到 engine 自己的 DispatchQueue。
//   * IOProc（即時執行緒）只碰 RTShared 裡預先配置的原生指標；不配置記憶體、不上鎖、不 print、
//     不呼叫任何 Core Audio 屬性 API。跨執行緒的數值是對齊的單一 Int/Float/Int64 讀寫。
import AudioToolbox
import Accelerate
import CoreAudio
import Foundation

// MARK: - 公開型別

/// 聚合裝置裡的一個輸出（index 0 永遠是音量來源）
struct EngineOutput: CustomStringConvertible {
    let index: Int
    let uid: String
    let name: String
    let deviceID: AudioObjectID
    let kind: DeviceKind
    /// 這個輸出是音量來源（index 0，送原音，硬體音量已套用）
    let isVolumeSource: Bool
    /// 這個輸出是聚合裝置的主時鐘（不開漂移校正）
    let isClock: Bool
    /// 在 IOProc 輸出 AudioBufferList 裡佔用的 buffer 範圍
    let bufferStart: Int
    let bufferCount: Int
    let channels: Int
    /// kAudioDevicePropertyClockDomain（0 = 驅動沒回報）
    var clockDomain: UInt32 = 0
    /// 建聚合裝置時這個子裝置有沒有開漂移校正（主時鐘、與主時鐘同 domain 且非 0 → false）
    var driftCompensated: Bool = false

    var description: String {
        "#\(index) \(name) [\(kind.rawValue)\(isVolumeSource ? " 音量來源" : "")\(isClock ? " 主時鐘" : "") buf \(bufferStart)..<\(bufferStart + bufferCount) \(channels)ch clock \(clockDomain)\(driftCompensated ? " 漂移校正" : "")]"
    }
}

enum EngineError: Error, CustomStringConvertible {
    case noOutputs
    case tap(OSStatus)
    case aggregate(OSStatus)
    case ioProc(OSStatus)
    case start(OSStatus)
    case inputLayout(String)

    var description: String {
        switch self {
        case .noOutputs: return "找不到可用的實體輸出裝置"
        case .tap(let s): return "建立 process tap 失敗 status=\(s)（系統音訊錄製權限？）"
        case .aggregate(let s): return "建立聚合裝置失敗 status=\(s)"
        case .ioProc(let s): return "建立 IOProc 失敗 status=\(s)"
        case .start(let s): return "啟動聚合裝置失敗 status=\(s)"
        case .inputLayout(let s): return "聚合裝置輸入 buffer 排列不符預期，拒絕啟動（避免把麥克風當節目音送出）：\(s)"
        }
    }
}

/// 狀態快照（給 log／校正用）
struct EngineStatus {
    struct Output {
        let uid: String
        let name: String
        /// plan 決定這台出聲（false = 模式上限／使用者關閉，增益淡出到 0）
        let active: Bool
        let delayMs: Double
        let targetGain: Float
        let peak: Float
        let testActive: Bool
    }
    let running: Bool
    let generation: Int
    let sampleRate: Double
    let sampleTime: Int64
    let ioCycles: Int64
    let skipEvents: Int64
    let volumeSourceName: String
    let volumeDb: Float?
    let muted: Bool
    /// 非音量來源輸出的音量倍率 10^(dB/20)（靜音為 0，未含 trim）
    let volumeGain: Float
    let programMuted: Bool
    let inputPeak: Float
    let outputs: [Output]
    /// IOProc 收到的輸入 buffer 數與預期不符的累計週期數（>0 表示這些週期節目音被靜音）
    let inputMismatch: Int64
    /// 目前生效的模式
    let mode: PlayMode

    var line: String {
        let db = volumeDb.map { String(format: "%.1f dB", $0) } ?? "無 dB"
        let outs = outputs.map {
            String(format: "%@%@ %.2fms g=%.3f pk=%.3f%@", $0.active ? "" : "✕", $0.name, $0.delayMs, $0.targetGain, $0.peak, $0.testActive ? " 測試中" : "")
        }.joined(separator: " | ")
        return String(format: "[gen %d %@ %@ %.0fHz t=%lld io=%lld skip=%lld%@] 音量來源 %@ %@ mute=%d → 增益 %.3f%@ | 輸入峰值 %.3f | %@",
                      generation, running ? "運轉" : "停止", mode.label, sampleRate, sampleTime, ioCycles, skipEvents,
                      inputMismatch > 0 ? " 輸入錯位=\(inputMismatch)" : "", volumeSourceName, db,
                      muted ? 1 : 0, volumeGain, programMuted ? " 節目靜音" : "", inputPeak, outs)
    }

    /// 「狀態有沒有變」的比較鍵：不含會一直跳動的 t/io/峰值（log 只在它改變時才印）
    var changeKey: String {
        let outs = outputs.map { String(format: "%@|%d|%.2f|%.3f|%d", $0.name, $0.active ? 1 : 0, $0.delayMs, $0.targetGain, $0.testActive ? 1 : 0) }
        return "\(generation)|\(mode.rawValue)|\(running)|\(Int(sampleRate))|\(skipEvents)|\(inputMismatch)|\(volumeSourceName)|"
            + (volumeDb.map { String(format: "%.1f", $0) } ?? "-") + "|\(muted)|\(programMuted)|" + outs.joined(separator: ";")
    }
}

// MARK: - 節目音共享環形緩衝（給藍牙只輸出路徑）

/// 節目音（tap 輸入，未延遲、未乘增益、立體聲交錯）的廣播環形緩衝，附寫入 sampleTime。
/// * 寫入端：只有 engine 的聚合裝置 IOProc（單一寫入者）。每個 IO 週期把 frame [t0, t0+n) 寫在
///   index (sampleTime & mask)，然後發佈 writeEnd = t0+n，並用 seqlock 發佈 (cycleSampleTime, cycleHostTime)。
/// * 讀取端：藍牙輸出 IOProc（可以有多個，各自記自己的讀取位置；讀取不消耗資料）。
///   `read` 先讀 writeEnd、拷貝、再讀一次 writeEnd 確認沒被覆寫（seqlock 式檢查），全程不上鎖、不配置。
/// * 由 Engine 在 init 配置、deinit 釋放，**跨 rebuild 存在**（指標永遠有效，讀取端不必擔心重建）。
///   engine 沒在跑時 writeEnd 停止前進 → 讀取端讀到的區間會「還沒寫入」→ 回傳 false（請輸出靜音）。
/// * sampleTime 與 Engine.sampleTime 同一條時間軸（重建不歸零、HAL 跳號已補）；取樣率見 sampleRate（重建後可能改變）。
/// * 外接輸出槽（ext*）：Engine 依 plan 與音量輪詢寫入，讀取端（BluetoothOut）每個週期讀，自己做 ramp。
struct ProgramRing {
    static let frames = 1 << 17            // 131072 frame ≈ 2.7 s @48k
    static let channels = 2
    static let maxExternal = 4
    /// solo 值 = externalSoloBase + 槽位：只讓這個外接輸出出聲（聚合裝置輸出全部 0）
    static let externalSoloBase = 1000

    let capacity: Int
    let mask: Int
    let data: UnsafeMutablePointer<Float>           // capacity * 2
    /// 已寫入的最後 frame + 1（engine sampleTime）；< 0 = 從未寫入
    let writeEnd: UnsafeMutablePointer<Int64>
    /// 時鐘 seqlock：奇數 = 寫入中
    let seq: UnsafeMutablePointer<Int64>
    /// 最近一個 IO 週期起點的 engine sampleTime 與聚合裝置輸出 mHostTime（這個 frame 在延遲 0 的輸出上播出的時間）
    let cycleSampleTime: UnsafeMutablePointer<Int64>
    let cycleHostTime: UnsafeMutablePointer<UInt64>
    /// 目前聚合裝置取樣率（控制端在 start 時寫；0 = 未運轉）
    let sampleRate: UnsafeMutablePointer<Double>
    /// 每次 start/rebuild +1（讀取端看到變化就重新對時）
    let generation: UnsafeMutablePointer<Int>
    /// 與 Engine 共用：1 = 節目靜音（校正中）。讀取端要自己乘上
    let muteProgram: UnsafeMutablePointer<Int>
    /// 與 Engine 共用（診斷 solo）：-1 = 全部；0..<nOut = 只有該聚合裝置輸出；externalSoloBase + 槽位 = 只有該外接輸出
    let solo: UnsafeMutablePointer<Int>

    // 外接輸出槽 [maxExternal]：控制端寫、讀取端讀
    /// 0 = 空槽、1 = 已註冊
    let extUsed: UnsafeMutablePointer<Int>
    /// 目標增益（音量倍率 × trim × plan.active；未含 muteProgram）
    let extGain: UnsafeMutablePointer<Float>
    /// plan 的補償延遲（frame，engine 取樣率）
    let extDelayFrames: UnsafeMutablePointer<Int>
    /// plan.active（0/1）
    let extActive: UnsafeMutablePointer<Int>
    /// 校正 pilot 振幅（所有外接輸出共用；0 = 關）。只有校正子行程會設（Engine.calibrationPilotDb），見 BTRenderer.render
    let extPilot: UnsafeMutablePointer<Float>
    /// 【2026-09-29 第 B 輪】外接輸出的額外延遲（engine frame，加在 extDelayFrames 上；緩慢斜率，見 RTShared.probe*／corr*）：
    /// 控制端寫 target／rate，讀取端（BTRenderer）自己走斜坡並把目前值寫回 *Cur（給狀態顯示）
    let extProbeTarget: UnsafeMutablePointer<Double>
    let extProbeRate: UnsafeMutablePointer<Double>
    let extProbeCur: UnsafeMutablePointer<Double>
    let extCorrTarget: UnsafeMutablePointer<Double>
    let extCorrRate: UnsafeMutablePointer<Double>
    let extCorrCur: UnsafeMutablePointer<Double>

    init(muteProgram: UnsafeMutablePointer<Int>, solo: UnsafeMutablePointer<Int>) {
        capacity = Self.frames
        mask = Self.frames - 1
        data = RTShared.alloc(Self.frames * Self.channels, Float(0))
        writeEnd = RTShared.alloc(1, Int64(-1))
        seq = RTShared.alloc(1, Int64(0))
        cycleSampleTime = RTShared.alloc(1, Int64(0))
        cycleHostTime = RTShared.alloc(1, UInt64(0))
        sampleRate = RTShared.alloc(1, 0.0)
        generation = RTShared.alloc(1, 0)
        self.muteProgram = muteProgram
        self.solo = solo
        extUsed = RTShared.alloc(Self.maxExternal, 0)
        extGain = RTShared.alloc(Self.maxExternal, Float(0))
        extDelayFrames = RTShared.alloc(Self.maxExternal, 0)
        extActive = RTShared.alloc(Self.maxExternal, 0)
        extPilot = RTShared.alloc(1, Float(0))
        extProbeTarget = RTShared.alloc(Self.maxExternal, 0.0)
        extProbeRate = RTShared.alloc(Self.maxExternal, 1.0)
        extProbeCur = RTShared.alloc(Self.maxExternal, 0.0)
        extCorrTarget = RTShared.alloc(Self.maxExternal, 0.0)
        extCorrRate = RTShared.alloc(Self.maxExternal, 1.0)
        extCorrCur = RTShared.alloc(Self.maxExternal, 0.0)
    }

    /// 控制端：新的 engine 世代開始（聚合裝置重建 → sampleTime 換了一條時間軸）。
    /// 在新 IOProc 開始寫之前呼叫：清掉舊時間軸的 writeEnd 與時鐘（clock() 回 nil、read() 失敗），
    /// 讀取端（藍牙）因此在第一次新寫入前只算「閒置」，不會拿舊時鐘外插、不會把舊時間軸的錨點帶進前饋速率量測，也不會連續欠載。
    /// 呼叫時 engine IOProc 必須已停（沒有寫入端）；讀取端同時在讀是安全的（seqlock／writeEnd 檢查會讓它失敗後重試）。
    func beginGeneration(sampleRate rate: Double) {
        sampleRate.pointee = 0
        OSMemoryBarrier()
        writeEnd.pointee = -1
        seq.pointee = 0
        cycleSampleTime.pointee = 0
        cycleHostTime.pointee = 0
        memset(data, 0, capacity * Self.channels * MemoryLayout<Float>.size)
        OSMemoryBarrier()
        sampleRate.pointee = rate
        generation.pointee &+= 1
    }

    /// 只在 engine deinit（沒有任何 IOProc 還在讀寫）時呼叫
    func free() {
        data.deallocate(); writeEnd.deallocate(); seq.deallocate(); cycleSampleTime.deallocate()
        cycleHostTime.deallocate(); sampleRate.deallocate(); generation.deallocate()
        extUsed.deallocate(); extGain.deallocate(); extDelayFrames.deallocate(); extActive.deallocate(); extPilot.deallocate()
        extProbeTarget.deallocate(); extProbeRate.deallocate(); extProbeCur.deallocate()
        extCorrTarget.deallocate(); extCorrRate.deallocate(); extCorrCur.deallocate()
    }

    // MARK: 寫入（只有 engine IOProc 呼叫；即時安全）

    /// 寫 n 個 frame（src 為 nil = 寫靜音），起點 t0；inCh 為來源聲道數（1 → 複製到兩聲道）
    func write(_ src: UnsafePointer<Float>?, inCh: Int, frames n: Int, at t0: Int64, hostTime: UInt64) {
        let m = mask
        // HAL 跳號（t0 > 上次 writeEnd）：[writeEnd, t0) 這段沒有新資料，槽位裡還是 capacity 之前的舊節目音。
        // 在發佈新的 writeEnd 之前先補 0，否則讀取端（藍牙）掃過空洞時會插播約 2.7 秒前的聲音。
        // 空洞 ≥ capacity（例如喚醒時跳好幾秒）→ 整個 ring 清零。即時安全：只有 memset，不配置、不上鎖。
        let prevEnd = writeEnd.pointee
        if prevEnd >= 0, t0 > prevEnd {
            let gap = t0 - prevEnd
            if gap >= Int64(capacity) {
                memset(data, 0, capacity * Self.channels * MemoryLayout<Float>.size)
            } else {
                let g = Int(gap)
                let start = Int(truncatingIfNeeded: prevEnd) & m
                let first = min(g, capacity - start)
                memset(data + start * 2, 0, first * 2 * MemoryLayout<Float>.size)
                if g > first { memset(data, 0, (g - first) * 2 * MemoryLayout<Float>.size) }
            }
        }
        for f in 0..<n {
            let r = (Int(truncatingIfNeeded: t0 &+ Int64(f)) & m) * 2
            if let ip = src {
                let s = f * inCh
                data[r] = ip[s]
                data[r + 1] = inCh > 1 ? ip[s + 1] : ip[s]
            } else {
                data[r] = 0; data[r + 1] = 0
            }
        }
        OSMemoryBarrier()
        writeEnd.pointee = t0 + Int64(n)
        seq.pointee &+= 1
        OSMemoryBarrier()
        cycleSampleTime.pointee = t0
        cycleHostTime.pointee = hostTime
        OSMemoryBarrier()
        seq.pointee &+= 1
    }

    // MARK: 讀取（讀取端 IOProc 呼叫；即時安全：不配置、不上鎖）

    /// 讀 frame [t, t+n) 到 dst（交錯立體聲，n*2 個 Float）。
    /// 回傳 false（dst 填 0）：區間還沒寫入（讀太前面）、或已被覆寫（讀太後面 / 讀取途中被追過）。
    @discardableResult
    func read(from t: Int64, frames n: Int, into dst: UnsafeMutablePointer<Float>) -> Bool {
        let end0 = writeEnd.pointee
        OSMemoryBarrier()
        let cap = Int64(capacity)
        guard n > 0, n <= capacity, end0 >= 0, t + Int64(n) <= end0, t >= end0 - cap else {
            if n > 0 { memset(dst, 0, n * 2 * MemoryLayout<Float>.size) }
            return false
        }
        let m = mask
        for f in 0..<n {
            let r = (Int(truncatingIfNeeded: t &+ Int64(f)) & m) * 2
            dst[2 * f] = data[r]
            dst[2 * f + 1] = data[r + 1]
        }
        OSMemoryBarrier()
        // 拷貝途中寫入端若已前進超過 t + cap，前段可能被覆寫
        let end1 = writeEnd.pointee
        if t < end1 - cap {
            memset(dst, 0, n * 2 * MemoryLayout<Float>.size)
            return false
        }
        return true
    }

    /// 最近一個週期的 (sampleTime, hostTime)；seqlock 最多試 4 次，一直碰到寫入中回 nil
    func clock() -> (sampleTime: Int64, hostTime: UInt64)? {
        for _ in 0..<4 {
            let s0 = seq.pointee
            if s0 & 1 != 0 { continue }
            OSMemoryBarrier()
            let st = cycleSampleTime.pointee
            let ht = cycleHostTime.pointee
            OSMemoryBarrier()
            if seq.pointee == s0 { return s0 == 0 ? nil : (st, ht) }
        }
        return nil
    }
}

// MARK: - 即時共用區塊

/// 【內部】只給 Engine 與離線 DSP 測試用，Calibrate/Reconnect/Service 不可直接使用。
/// IOProc 唯一會碰的資料：全部是預先配置的原生指標（值型別，closure 捕捉時不會在即時執行緒 retain）
struct RTShared {
    static let ringChannels = 2

    var nOut = 0
    var ringFrames = 0
    var ringMask = 0
    var maxDelayFrames = 0
    var maxCycleFrames = 0
    var testCap = 0
    /// tap 的節目音在 IOProc 輸入 AudioBufferList 的 index（= 子裝置輸入 stream 總數；子裝置輸入在前、tap 在後）
    var tapBufIndex = 0
    /// 預期的輸入 buffer 數（子裝置輸入 stream + tap stream）；IOProc 收到的數量不同就不讀輸入（節目音靜音）
    var expectedInBufs = 1

    var ring: UnsafeMutablePointer<Float>!          // ringFrames * 2（交錯立體聲）
    var writePos: UnsafeMutablePointer<Int>!        // RT 專用
    var bufStart: UnsafeMutablePointer<Int>!        // [nOut] 常數
    var bufCount: UnsafeMutablePointer<Int>!        // [nOut] 常數
    var targetGain: UnsafeMutablePointer<Float>!    // [nOut] 控制端寫、RT 讀
    var curGain: UnsafeMutablePointer<Float>!       // [nOut] RT 專用（ramp 用）
    var delayFrames: UnsafeMutablePointer<Int>!     // [nOut] 控制端寫、RT 讀
    var outPeak: UnsafeMutablePointer<Float>!       // [nOut] RT 寫最大值、控制端讀後歸零
    /// 測試訊號緩衝 [nOut * testCap] 的「指標的指標」：平常 pointee = nil（不占 nOut × 10 秒的記憶體），
    /// 只有校正／測試第一次 playTestSignal 時才在非即時執行緒配置（allocateTestBuffer），配置完才發佈給 IOProc。
    /// IOProc 只在 testState == 1 時讀 pointee；nil 視同沒有測試訊號。控制端在 state==0 時寫內容
    var testBufRef: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>!
    var testLen: UnsafeMutablePointer<Int>!         // [nOut]
    var testStart: UnsafeMutablePointer<Int64>!     // [nOut] 絕對 sampleTime
    var testState: UnsafeMutablePointer<Int>!       // [nOut] 0 閒置、1 已排程/播放中（RT 播完設回 0）
    var nextDevTime: UnsafeMutablePointer<Double>!  // RT 專用：預期下一個輸出 mSampleTime（<0 = 尚未知道）
    var active: UnsafeMutablePointer<Float>!        // [nOut] 控制端寫：plan.active（1 出聲、0 不出聲；經增益 ramp 淡入淡出）
    var curDelay: UnsafeMutablePointer<Int>!        // [nOut] RT 專用：目前實際使用的延遲（delayFrames 改變時先淡出、再切換、再淡入）
    // 【2026-09-29 第 B 輪】額外延遲（加在 plan 延遲上，frame，可有小數）：兩個獨立的「緩慢斜率」量，不淡出、不硬切，
    // 讀取位置每個 frame 最多移動 rate 個 frame（變速播放；位置有小數時用 4 點 Hermite 插值），到目標後停在整數 frame。
    //   probe：背景監聽的探測偏移（例如 +3.5 ms、0.5 s 斜坡）；corr：背景監聽的延遲修正（≤ 0.1 ms/秒）
    var probeTarget: UnsafeMutablePointer<Double>!  // [nOut] 控制端寫（frame）
    var probeRate: UnsafeMutablePointer<Double>!    // [nOut] 控制端寫（每輸出 frame 最多移動幾個 frame，> 0）
    var probeCur: UnsafeMutablePointer<Double>!     // [nOut] RT 專用（控制端只讀，狀態顯示）
    var corrTarget: UnsafeMutablePointer<Double>!   // [nOut] 控制端寫（frame）
    var corrRate: UnsafeMutablePointer<Double>!     // [nOut] 控制端寫
    var corrCur: UnsafeMutablePointer<Double>!      // [nOut] RT 專用

    // 以下由 Engine 擁有、跨重建共用
    var muteProgram: UnsafeMutablePointer<Int>!     // 0 正常、1 節目靜音
    var sampleTime: UnsafeMutablePointer<Int64>!    // 累計已輸出 frame 數（單調遞增，重建不歸零）
    var ioCycles: UnsafeMutablePointer<Int64>!
    var inPeak: UnsafeMutablePointer<Float>!
    var skippedFrames: UnsafeMutablePointer<Int64>!  // 累計被 HAL 跳過的 frame 數（IO 週期被丟掉）
    var skipEvents: UnsafeMutablePointer<Int64>!
    var inMismatch: UnsafeMutablePointer<Int64>!    // 輸入 buffer 數不符預期的週期數
    var solo: UnsafeMutablePointer<Int>!            // 診斷：>= 0 時只有這個輸出出節目音（其他增益 0）；-1 = 全部
    var onsetArm: UnsafeMutablePointer<Int>!        // 診斷：1 = 等待節目音第一個超過門檻的樣本
    var onsetTime: UnsafeMutablePointer<Int64>!     // 診斷：該樣本進入延遲線的 sampleTime（-1 = 尚未）
    var onsetThreshold: UnsafeMutablePointer<Float>!
    /// 節目音廣播緩衝（Engine 擁有、跨重建存在）；nil = 不寫（離線自測）
    var program: ProgramRing?

    static func alloc<T>(_ n: Int, _ v: T) -> UnsafeMutablePointer<T> {
        let p = UnsafeMutablePointer<T>.allocate(capacity: max(n, 1))
        p.initialize(repeating: v, count: max(n, 1))
        return p
    }

    mutating func allocate(nOut: Int, sampleRate: Double, testSeconds: Double) {
        self.nOut = nOut
        maxDelayFrames = Int((Config.maxDelayMs / 1000 * sampleRate).rounded(.up))
        maxCycleFrames = 16384
        var rf = 1
        while rf < maxDelayFrames + maxCycleFrames { rf <<= 1 }
        ringFrames = rf
        ringMask = rf - 1
        testCap = Int(testSeconds * sampleRate)
        ring = Self.alloc(rf * Self.ringChannels, Float(0))
        writePos = Self.alloc(1, 0)
        bufStart = Self.alloc(nOut, 0)
        bufCount = Self.alloc(nOut, 0)
        targetGain = Self.alloc(nOut, Float(0))
        curGain = Self.alloc(nOut, Float(0))
        delayFrames = Self.alloc(nOut, 0)
        outPeak = Self.alloc(nOut, Float(0))
        testBufRef = Self.alloc(1, nil as UnsafeMutablePointer<Float>?)   // 測試緩衝延後到真的要播時才配置
        testLen = Self.alloc(nOut, 0)
        testStart = Self.alloc(nOut, Int64(0))
        testState = Self.alloc(nOut, 0)
        nextDevTime = Self.alloc(1, -1.0)
        active = Self.alloc(nOut, Float(1))
        curDelay = Self.alloc(nOut, -1)          // -1 = 尚未套用：第一個週期直接採用 delayFrames（增益也從 0 淡入）
        probeTarget = Self.alloc(nOut, 0.0); probeRate = Self.alloc(nOut, 1.0); probeCur = Self.alloc(nOut, 0.0)
        corrTarget = Self.alloc(nOut, 0.0); corrRate = Self.alloc(nOut, 1.0); corrCur = Self.alloc(nOut, 0.0)
    }

    /// 只在 IOProc 已銷毀後呼叫
    mutating func free() {
        for p in [probeTarget, probeRate, probeCur, corrTarget, corrRate, corrCur] as [UnsafeMutablePointer<Double>?] { p?.deallocate() }
        probeTarget = nil; probeRate = nil; probeCur = nil; corrTarget = nil; corrRate = nil; corrCur = nil
        for p in [ring, targetGain, curGain, outPeak, active] as [UnsafeMutablePointer<Float>?] { p?.deallocate() }
        for p in [writePos, bufStart, bufCount, delayFrames, testLen, testState, curDelay] as [UnsafeMutablePointer<Int>?] { p?.deallocate() }
        testStart?.deallocate()
        if let ref = testBufRef { ref.pointee?.deallocate(); ref.deallocate() }
        testBufRef = nil
        nextDevTime?.deallocate(); nextDevTime = nil
        ring = nil; writePos = nil; bufStart = nil; bufCount = nil; targetGain = nil; curGain = nil
        delayFrames = nil; outPeak = nil; testLen = nil; testStart = nil; testState = nil
        active = nil; curDelay = nil
        nOut = 0
    }

    /// IOProc 收尾：這個週期開頭讀到的 testState（readState）是 1，而且（播完了、或排程了但緩衝已收回）才清回 0。
    /// 只看開頭讀到的值：開頭讀到 0、控制端在渲染中途寫 1（新排程）→ 不清（下個週期才開始播）。
    /// readState == 1 時控制端不會重新排程（playTestSignal 只在 state == 0 時寫），所以清 0 不會吃掉新的測試訊號。純函式、即時安全
    @inline(__always)
    static func shouldEndTest(readState: Int, hadBuffer: Bool, finished: Bool) -> Bool {
        readState == 1 && (!hadBuffer || finished)
    }

    /// 從 cur 往 target 最多走 maxStep（到了就停在 target）。純函式、即時安全
    @inline(__always)
    static func slew(_ cur: Double, _ target: Double, _ maxStep: Double) -> Double {
        let diff = target - cur
        if abs(diff) <= maxStep { return target }
        return diff > 0 ? cur + maxStep : cur - maxStep
    }

    /// 4 點 Catmull-Rom Hermite（x0 與 x1 之間，t ∈ [0,1)）；t = 0 時精確等於 x0。即時安全
    @inline(__always)
    static func hermite(_ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float, _ t: Float) -> Float {
        let c1 = 0.5 * (x1 - xm1)
        let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return ((c3 * t + c2) * t + c1) * t + x0
    }

    /// 測試訊號緩衝是否已配置
    var hasTestBuffer: Bool { testBufRef?.pointee != nil }

    /// 【非即時執行緒】配置測試訊號緩衝（nOut × testCap，清零）並發佈給 IOProc。已配置就不動。回傳 bytes（0 = 已經有）
    @discardableResult
    func allocateTestBuffer() -> Int {
        guard let ref = testBufRef, ref.pointee == nil, nOut > 0, testCap > 0 else { return 0 }
        let p = Self.alloc(nOut * testCap, Float(0))
        OSMemoryBarrier()          // 內容（0）先寫好，再發佈指標
        ref.pointee = p
        return nOut * testCap * MemoryLayout<Float>.size
    }

    /// 【非即時執行緒】收回測試訊號緩衝：先把所有 testState 設 0、指標設 nil，
    /// 等 IOProc 再跑完兩個週期（確定沒有週期還拿著舊指標）才釋放。IOProc 沒在跑（ioAlive = false）就直接釋放。
    /// 回傳釋放的 bytes（0 = 本來就沒有，或等不到兩個週期而放棄釋放——寧可漏也不 use-after-free）
    @discardableResult
    func releaseTestBuffer(ioAlive: Bool, timeout: TimeInterval = 1) -> Int {
        guard let ref = testBufRef, let p = ref.pointee else { return 0 }
        for o in 0..<nOut { testState[o] = 0 }
        OSMemoryBarrier()
        ref.pointee = nil
        OSMemoryBarrier()
        if ioAlive {
            let c0 = ioCycles.pointee
            let end = Date().addingTimeInterval(timeout)
            while ioCycles.pointee < c0 &+ 2 {
                if Date() > end { ref.pointee = p; return 0 }   // IO 停住：放回去，下次 stop 時 free() 會釋放
                usleep(2000)
            }
        }
        p.deallocate()
        return nOut * testCap * MemoryLayout<Float>.size
    }

    // MARK: 即時渲染（IOProc 內呼叫；不配置、不上鎖、不 print、不呼叫 Core Audio 屬性 API）

    func render(_ inData: UnsafePointer<AudioBufferList>, _ outData: UnsafeMutablePointer<AudioBufferList>,
                _ outTime: UnsafePointer<AudioTimeStamp>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        let nBufs = outs.count
        ioCycles.pointee &+= 1

        // 先全部清零（沒對應到的 buffer 保持靜音）
        for b in 0..<nBufs where outs[b].mData != nil {
            memset(outs[b].mData!, 0, Int(outs[b].mDataByteSize))
        }

        // frame 數：以 tap 輸入為準，沒有輸入就用第一個輸出 buffer。
        // tap 在輸入 buffer 的位置是 tapBufIndex（子裝置的輸入 stream 排在前面）；
        // 數量和預期不同就不讀任何輸入（寧可沒聲音，也不要把麥克風當節目音送到喇叭）
        var inPtr: UnsafePointer<Float>? = nil
        var inCh = 1
        var n = 0
        let ti = tapBufIndex
        if ins.count != expectedInBufs {
            inMismatch.pointee &+= 1
        } else if ti < ins.count, let p = ins[ti].mData, ins[ti].mNumberChannels > 0 {
            inCh = Int(ins[ti].mNumberChannels)
            n = Int(ins[ti].mDataByteSize) / 4 / inCh
            inPtr = UnsafePointer(p.assumingMemoryBound(to: Float.self))
        }
        if n == 0, nBufs > 0 {
            n = Int(outs[0].mDataByteSize) / 4 / max(1, Int(outs[0].mNumberChannels))
            inPtr = nil
        }
        if n <= 0 { return }
        if n > maxCycleFrames { n = maxCycleFrames }

        // HAL 丟掉 IO 週期時（overload／裝置剛啟動），輸出 mSampleTime 會跳號；把跳過的 frame 補進 sampleTime，
        // 讓 sampleTime 始終對應喇叭的實際時間軸（校正排程靠它）
        var t0 = sampleTime.pointee
        if outTime.pointee.mFlags.contains(.sampleTimeValid) {
            let st = outTime.pointee.mSampleTime
            let exp = nextDevTime.pointee
            if exp >= 0 {
                let jump = st - exp
                if jump > 0.5 && jump < 10 * 48000 {
                    let j = Int64(jump.rounded())
                    t0 += j
                    skippedFrames.pointee &+= j
                    skipEvents.pointee &+= 1
                }
            }
            nextDevTime.pointee = st + Double(n)
        }

        // 0. 節目音廣播緩衝（藍牙只輸出路徑讀）：原始 tap 輸入、未延遲、未乘增益
        if let pr = program {
            let ht = outTime.pointee.mFlags.contains(.hostTimeValid) ? outTime.pointee.mHostTime : 0
            pr.write(inPtr, inCh: inCh, frames: n, at: t0, hostTime: ht)
        }

        // 1. 節目音寫進環形緩衝
        let wp = writePos.pointee
        let mask = ringMask
        if let ip = inPtr {
            var pk: Float = 0
            vDSP_maxmgv(ip, 1, &pk, vDSP_Length(n * inCh))
            if pk > inPeak.pointee { inPeak.pointee = pk }
            for f in 0..<n {
                let r = ((wp + f) & mask) * 2
                let s = f * inCh
                ring[r] = ip[s]
                ring[r + 1] = inCh > 1 ? ip[s + 1] : ip[s]
            }
            // 診斷：節目音第一個超過門檻的樣本進入延遲線的時間
            if onsetArm.pointee == 1 {
                let thr = onsetThreshold.pointee
                var f = 0
                while f < n {
                    let v = ip[f * inCh]
                    if v > thr || v < -thr {
                        onsetTime.pointee = t0 + Int64(f)
                        OSMemoryBarrier()
                        onsetArm.pointee = 0
                        break
                    }
                    f += 1
                }
            }
        } else {
            for f in 0..<n {
                let r = ((wp + f) & mask) * 2
                ring[r] = 0
                ring[r + 1] = 0
            }
        }

        let progOn: Float = muteProgram.pointee == 0 ? 1 : 0
        let soloIdx = solo.pointee

        // 2. 每個輸出：延遲讀取 × 增益（ramp）＋測試訊號
        //    延遲改變時不硬切：這個週期用舊延遲淡出到 0，下一個週期（增益已是 0）換成新延遲再淡入（各約一個 IO 週期）
        for o in 0..<nOut {
            var dT = delayFrames[o]
            if dT < 0 { dT = 0 } else if dT > maxDelayFrames { dT = maxDelayFrames }
            let tg = targetGain[o]
            let g0 = curGain[o]
            var g1 = (soloIdx >= 0 && soloIdx != o) ? 0 : tg * progOn * active[o]
            var d = curDelay[o]
            var snap = false
            if d < 0 {
                d = dT; curDelay[o] = dT; snap = true
            } else if d != dT {
                if g0 == 0 { d = dT; curDelay[o] = dT; snap = true } else { g1 = 0 }
            }
            let dg = (g1 - g0) / Float(n)

            // 額外延遲（探測偏移＋修正）：緩慢斜率。plan 延遲剛套用（第一個週期／淡出後換延遲，增益是 0）時直接跳到目標
            let pT = probeTarget[o], cT = corrTarget[o]
            var pC0 = probeCur[o], cC0 = corrCur[o]
            if snap { pC0 = pT; cC0 = cT }
            let pR = probeRate[o] > 0 ? probeRate[o] : 1
            let cR = corrRate[o] > 0 ? corrRate[o] : 1
            let e0 = pC0 + cC0
            let maxTotal = ringFrames - maxCycleFrames - 4       // 讀取點最多落後這麼多（延遲線容量）
            let fast = pC0 == pT && cC0 == cT && e0 == e0.rounded(.down)
            var dFast = d
            if fast {
                dFast = d + Int(e0)
                if dFast < 0 { dFast = 0 } else if dFast > maxTotal { dFast = maxTotal }
            }
            let latestIdx = wp + n - 1                            // 這個週期已寫入的最新 frame（未取 mask）

            // 測試訊號：緩衝是延後配置的（testBufRef.pointee 可能是 nil）→ nil 就當作沒有測試訊號
            // testState 這個週期只讀一次（st）：收尾也用它判斷，不重讀——控制端可能在渲染中途把 0 改成 1（新排程），重讀會把它清掉
            let st = testState[o]
            var tb: UnsafeMutablePointer<Float>? = nil
            if st == 1 {
                OSMemoryBarrier()
                if let base = testBufRef.pointee { tb = base + o * testCap }
            }
            let testOn = tb != nil
            let tStart = testOn ? testStart[o] : 0
            let tLen = testOn ? testLen[o] : 0

            var peak: Float = 0
            let bEnd = bufStart[o] + bufCount[o]
            var bi = bufStart[o]
            while bi < bEnd && bi < nBufs {
                defer { bi += 1 }
                guard let raw = outs[bi].mData else { continue }
                let dp = raw.assumingMemoryBound(to: Float.self)
                let ch = max(1, Int(outs[bi].mNumberChannels))
                let m = min(n, Int(outs[bi].mDataByteSize) / 4 / ch)
                for f in 0..<m {
                    var sL: Float, sR: Float
                    if fast {
                        let r = ((wp + f - dFast) & mask) * 2
                        sL = ring[r]; sR = ring[r + 1]
                    } else {
                        // 變速讀取：這個 frame 的額外延遲 = 從週期起點往目標走 rate × (f+1)（與 buffer 無關，多個 stream 算出來一樣）
                        let pf = RTShared.slew(pC0, pT, pR * Double(f + 1))
                        let cf = RTShared.slew(cC0, cT, cR * Double(f + 1))
                        var dd = Double(d) + pf + cf
                        if dd < 0 { dd = 0 } else if dd > Double(maxTotal) { dd = Double(maxTotal) }
                        let x = Double(wp + f) - dd
                        let kf = x.rounded(.down)
                        let fr = Float(x - kf)
                        let k = Int(kf)
                        let i0 = (min(k - 1, latestIdx) & mask) * 2, i1 = (min(k, latestIdx) & mask) * 2
                        let i2 = (min(k + 1, latestIdx) & mask) * 2, i3 = (min(k + 2, latestIdx) & mask) * 2
                        sL = RTShared.hermite(ring[i0], ring[i1], ring[i2], ring[i3], fr)
                        sR = RTShared.hermite(ring[i0 + 1], ring[i1 + 1], ring[i2 + 1], ring[i3 + 1], fr)
                    }
                    let g = g0 + dg * Float(f)
                    var tv: Float = 0
                    if testOn {
                        let k = Int(t0 + Int64(f) - tStart)
                        if k >= 0 && k < tLen { tv = tb.unsafelyUnwrapped[k] * tg }
                    }
                    let base = f * ch
                    for c in 0..<ch {
                        var v = ((c & 1) == 0 ? sL : sR) * g + tv
                        if v > 1 { v = 1 } else if v < -1 { v = -1 }
                        dp[base + c] = v
                        let a = v < 0 ? -v : v
                        if a > peak { peak = a }
                    }
                }
            }
            curGain[o] = g1
            probeCur[o] = RTShared.slew(pC0, pT, pR * Double(n))
            corrCur[o] = RTShared.slew(cC0, cT, cR * Double(n))
            if peak > outPeak[o] { outPeak[o] = peak }
            if RTShared.shouldEndTest(readState: st, hadBuffer: testOn, finished: testOn && t0 + Int64(n) >= tStart + Int64(tLen)) {
                testState[o] = 0
            }
        }

        writePos.pointee = (wp + n) & mask
        sampleTime.pointee = t0 + Int64(n)
    }
}

// MARK: - Engine

final class Engine {
    /// 測試訊號每個輸出最長秒數（預先配置）
    static let maxTestSignalSeconds: Double = 10
    /// 音量／靜音／取樣率的**備援**輪詢間隔。主要靠 AudioObjectAddPropertyListenerBlock（音量來源的 VolumeDecibels／
    /// VolumeScalar／Mute、聚合裝置的 NominalSampleRate）即時通知；監聽註冊失敗或漏通知時，最慢 1 秒內由這裡補上。
    /// （2026-09-29 以前是 50 ms 純輪詢：每秒約 150 次 Core Audio 屬性 IPC，選單列 app 平常 CPU 的主要來源之一）
    static let volumePollInterval: DispatchTimeInterval = .seconds(1)

    /// log 輸出（預設 print；校正時可換掉）
    var log: (String) -> Void = { print($0) }

    private let queue = DispatchQueue(label: "In_Unison42.engine", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()

    private var _config: Config
    private var _outputs: [EngineOutput] = []
    private var _running = false
    private var _generation = 0
    private var _sampleRate: Double = 0

    private var rt = RTShared()
    private var tapIDs: [AudioObjectID] = []
    /// nil = 正常模式（全域 tap）。診斷用：只把這些行程的聲音當節目音，其餘行程另開一個 tap 靜音掉
    private var _programProcesses: [AudioObjectID]?
    /// 聚合裝置取樣率和建立時不同（例如使用者在「音訊 MIDI 設定」改了主時鐘取樣率）時呼叫一次（在 engine queue 上）
    private var _onFormatChange: ((String) -> Void)?
    private var formatChangeNotified = false
    private var aggID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var pollTimer: DispatchSourceTimer?
    /// 目前註冊中的屬性監聽（stopLocked 移除；block 必須是同一個物件才移得掉）
    private var propertyListeners: [(id: AudioObjectID, addr: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    /// HAL 屬性通知送到這條專用 queue（只做轉送，不等任何東西：移除 listener 時不會和 engine queue 互等）
    private let listenerQueue = DispatchQueue(label: "In_Unison42.engine.listeners", qos: .userInitiated)
    /// 通知合併：一次音量拖曳會連發很多通知 → or 進這個 source，engine queue 上合併成一次 pollVolumeLocked
    private var volumeEvents: DispatchSourceUserDataOr?
    /// 屬性監聽觸發次數（診斷用；status 行不顯示）
    private var _listenerEvents = 0
    private var _pollCount = 0

    // 模式與出聲計畫
    private var _mode: PlayMode
    private var _plan: [String: PlanEntry] = [:]
    private var _onPlanChange: (([String: PlanEntry]) -> Void)?
    /// 外接輸出（藍牙只輸出路徑）：槽位 → PlanDevice 用的資訊
    private var external: [Int: (uid: String, name: String, isBuiltIn: Bool)] = [:]
    private var _allowUncalibratedExternal = false
    private var _calibrationFixedGain: Float? = nil
    private var _calibrationFixedGainExternal: Float? = nil
    /// 節目音廣播緩衝（跨重建存在）
    private let programRing: ProgramRing
    /// 正常模式 tap 額外排除的行程（系統提示音用）
    private var _extraExcluded: [AudioObjectID] = []
    private var _extraExcludedBundleIDs: [String] = []
    /// 【第 B 輪】背景監聽：探測偏移（uid → ms，目標值）與它的斜率（frame／frame）
    private var _probeMs: [String: Double] = [:]
    private var _probeRate: [String: Double] = [:]
    /// 【第 B 輪】延遲修正（uid → ms：這台實際延遲比 measuredLatencyMs 多多少；執行期、不存檔）
    private var _corrections: [String: Double] = [:]
    /// 修正換算成每台輸出的額外延遲（ms）＝ plan(修正後延遲) − plan(原延遲)（只在兩者都出聲時）
    private var _correctionOffsetMs: [String: Double] = [:]
    /// 【第 B 輪】藍牙真的斷線重連：重新 attach「之前」就先暫停出聲（疊在 config.calibrationHolds 上；AppState 接手後 release）
    private var _reconnectHolds: Set<String> = []

    private var lastVolumeDb: Float?
    private var lastMuted = false
    private var lastVolumeGain: Float = 1
    private var startedAt = Date.distantPast
    private var ioWatchdogDone = false
    private var startCycles: Int64 = 0

    /// mode：初始生效模式；nil = config.startupPlayMode（手動模式照用，auto 先用音樂）
    init(config: Config = Config.load(), mode: PlayMode? = nil) {
        _config = config
        _mode = mode ?? config.startupPlayMode
        queue.setSpecific(key: queueKey, value: true)
        rt.muteProgram = RTShared.alloc(1, 0)
        rt.solo = RTShared.alloc(1, -1)
        programRing = ProgramRing(muteProgram: rt.muteProgram, solo: rt.solo)
        rt.program = programRing
        rt.sampleTime = RTShared.alloc(1, Int64(0))
        rt.ioCycles = RTShared.alloc(1, Int64(0))
        rt.inPeak = RTShared.alloc(1, Float(0))
        rt.skippedFrames = RTShared.alloc(1, Int64(0))
        rt.skipEvents = RTShared.alloc(1, Int64(0))
        rt.inMismatch = RTShared.alloc(1, Int64(0))
        rt.onsetArm = RTShared.alloc(1, 0)
        rt.onsetTime = RTShared.alloc(1, Int64(-1))
        rt.onsetThreshold = RTShared.alloc(1, Float(0.01))
        let ev = DispatchSource.makeUserDataOrSource(queue: queue)
        ev.setEventHandler { [weak self] in
            guard let self else { return }
            self._listenerEvents += 1
            self.pollVolumeLocked()
        }
        ev.resume()
        volumeEvents = ev
    }

    deinit {
        volumeEvents?.cancel()
        stopLocked()
        programRing.free()
        rt.muteProgram.deallocate()
        rt.sampleTime.deallocate()
        rt.ioCycles.deallocate()
        rt.inPeak.deallocate()
        rt.skippedFrames.deallocate()
        rt.skipEvents.deallocate()
        rt.inMismatch.deallocate()
        rt.solo.deallocate()
        rt.onsetArm.deallocate()
        rt.onsetTime.deallocate()
        rt.onsetThreshold.deallocate()
    }

    private func sync<T>(_ f: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try f() }
        return try queue.sync(execute: f)
    }

    // MARK: 唯讀狀態

    var isRunning: Bool { sync { _running } }
    /// 每次成功 start/rebuild 加 1
    var generation: Int { sync { _generation } }
    /// 聚合裝置取樣率（未運轉時為 0）
    var sampleRate: Double { sync { _sampleRate } }
    /// IOProc 累計已輸出 frame 數；單調遞增、重建不歸零。任何執行緒可讀（無鎖）
    var sampleTime: Int64 { rt.sampleTime.pointee }
    var config: Config { sync { _config } }
    /// 目前輸出（index 0 = 音量來源）
    var outputs: [(uid: String, name: String)] { sync { _outputs.map { (uid: $0.uid, name: $0.name) } } }
    var outputDetails: [EngineOutput] { sync { _outputs } }
    var isProgramMuted: Bool { rt.muteProgram.pointee != 0 }
    /// IOProc 被呼叫的累計次數（單調遞增，重建不歸零）；start 後不增加 = IO 沒在跑（多半是系統音訊錄製權限未授與）
    var ioCycles: Int64 { rt.ioCycles.pointee }
    /// HAL 跳過 IO 週期的累計次數／frame 數（已補進 sampleTime）
    var ioSkips: (events: Int64, frames: Int64) { (rt.skipEvents.pointee, rt.skippedFrames.pointee) }
    /// 輸入 buffer 數不符預期、節目音被靜音的累計 IO 週期數
    var inputMismatchCycles: Int64 { rt.inMismatch.pointee }

    /// 取樣率變更通知（Reconnector 設定成強制重建）
    var onFormatChange: ((String) -> Void)? {
        get { sync { _onFormatChange } }
        set { sync { _onFormatChange = newValue } }
    }

    // MARK: 模式與出聲計畫

    /// 目前生效的模式（沒有 auto；auto 由 ModeManager 解析後呼叫 setMode）
    var mode: PlayMode { sync { _mode } }

    /// 切換模式：依 plan() 重算每台輸出出聲與否與延遲。運轉中不重建聚合裝置；
    /// 出聲↔不出聲以增益 ramp（約一個 IO 週期）淡入淡出，延遲改變時先淡出、換延遲、再淡入（不會爆音）。
    func setMode(_ m: PlayMode) {
        sync {
            guard m != _mode else { return }
            _mode = m
            log("模式 → \(m.label)")
            pushConfigLocked()
            pollVolumeLocked()
        }
    }

    /// 目前的出聲計畫（key = 裝置 UID；含聚合裝置輸出與已註冊的外接輸出）。未運轉時只含外接輸出
    var plan: [String: PlanEntry] { sync { _plan } }

    /// 單一裝置的計畫；不在計畫裡回 nil
    func planEntry(uid: String) -> PlanEntry? { sync { _plan[uid] } }

    /// 計畫改變時呼叫（在 engine queue 上；不要在裡面做阻塞操作）。模式、設定、輸出組成（rebuild）、外接輸出註冊都會觸發
    var onPlanChange: (([String: PlanEntry]) -> Void)? {
        get { sync { _onPlanChange } }
        set { sync { _onPlanChange = newValue } }
    }

    // MARK: 外接輸出（藍牙只輸出路徑）

    /// 節目音廣播緩衝：藍牙輸出 IOProc 從這裡讀（跨重建存在，指標永遠有效）
    var program: ProgramRing { programRing }

    /// 註冊一個不在聚合裝置裡的輸出（藍牙喇叭），讓它參與 plan（出聲與否、延遲補償）與音量。
    /// 回傳槽位（0..<ProgramRing.maxExternal），之後 IOProc 讀 program.ext*[slot]；槽滿或 uid 重複回 nil
    func registerExternalOutput(uid: String, name: String, isBuiltIn: Bool = false) -> Int? {
        sync {
            guard !external.values.contains(where: { $0.uid == uid }) else { return nil }
            guard let slot = (0..<ProgramRing.maxExternal).first(where: { external[$0] == nil }) else { return nil }
            external[slot] = (uid, name, isBuiltIn)
            programRing.extGain[slot] = 0
            programRing.extActive[slot] = 0
            programRing.extDelayFrames[slot] = 0
            programRing.extProbeTarget[slot] = 0; programRing.extProbeCur[slot] = 0
            programRing.extCorrTarget[slot] = 0; programRing.extCorrCur[slot] = 0
            OSMemoryBarrier()
            programRing.extUsed[slot] = 1
            log("外接輸出註冊：\(name) → 槽 \(slot)")
            pushConfigLocked()
            pollVolumeLocked()
            return slot
        }
    }

    /// 已註冊的外接輸出（槽位順序）
    var externalOutputs: [(slot: Int, uid: String, name: String)] {
        sync { external.keys.sorted().map { (slot: $0, uid: external[$0]!.uid, name: external[$0]!.name) } }
    }

    /// 【只給校正子行程】true = 未量測延遲的外接輸出（藍牙）也照「未量測、不補償」出聲（音樂模式），才量得到它。
    /// 預設 false；不寫進設定檔。選單列 app 平常絕不打開（未補償的藍牙會比其他喇叭慢上百毫秒）
    var allowUncalibratedExternal: Bool {
        get { sync { _allowUncalibratedExternal } }
        set { sync { guard newValue != _allowUncalibratedExternal else { return }
                     _allowUncalibratedExternal = newValue
                     log("未校正外接輸出出聲（校正／測試用）：\(newValue ? "開" : "關")")
                     pushConfigLocked(); pollVolumeLocked() } }
    }

    /// 【只給校正子行程】非 nil：音量來源以外的輸出（HDMI／DP、藍牙）改用這個固定增益 × trim，**不乘系統音量倍率**
    /// （音量 31 ≈ −28 dB 時藍牙測試音太小，麥克風聽不到）。音量來源（內建喇叭，index 0）照舊由硬體音量控制、本程式不動它。
    /// 上限 1（0 dB）。量測期間其他 App 的節目音已被另一個 tap 靜音，所以不會有突然變大聲的節目音。選單列 app 平常絕不設定
    var calibrationFixedGain: Float? {
        get { sync { _calibrationFixedGain } }
        set { sync {
            _calibrationFixedGain = newValue.map { min(max($0, 0), 1) }
            log("校正固定增益（不乘系統音量）：\(_calibrationFixedGain.map { String(format: "%.1f dB", 20 * log10(max($0, 1e-6))) } ?? "關")")
            pollVolumeLocked()
        } }
    }

    /// 【只給校正子行程】外接輸出（藍牙）持續送 150 Hz pilot（dBFS；nil = 關），讓耳機不因靜音關掉輸出而吃掉校正脈衝
    var calibrationPilotDb: Double? {
        get { let a = programRing.extPilot.pointee; return a > 0 ? 20 * log10(Double(a)) : nil }
        set {
            programRing.extPilot.pointee = newValue.map { Float(pow(10, min($0, -20) / 20)) } ?? 0
            log("校正 pilot（外接輸出 150 Hz）：\(newValue.map { String(format: "%.0f dBFS", min($0, -20)) } ?? "關")")
        }
    }

    /// 【只給校正子行程】外接輸出（藍牙）另用的固定增益（nil = 同 calibrationFixedGain）。藍牙耳機音量開大時放在麥克風旁會削波
    var calibrationFixedGainExternal: Float? {
        get { sync { _calibrationFixedGainExternal } }
        set { sync {
            _calibrationFixedGainExternal = newValue.map { min(max($0, 0), 1) }
            log("校正固定增益（外接輸出）：\(_calibrationFixedGainExternal.map { String(format: "%.1f dB", 20 * log10(max($0, 1e-6))) } ?? "同其他輸出")")
            pollVolumeLocked()
        } }
    }

    // MARK: 探測偏移／延遲修正（第 B 輪：背景監聽）

    /// 探測偏移預設斜坡長度（秒）：+3.5 ms 在 0.5 s 內走完 = 播放速度暫時差 0.7%（約 12 cent），來回各一次
    static let probeRampSeconds = 0.5
    /// 探測偏移上限（ms）
    static let maxProbeMs = 20.0
    /// 延遲修正的斜率上限（ms／秒）：0.1 ms/s = 播放速度差 100 ppm（0.17 cent），聽不出來
    static let correctionSlewMsPerSecond = 0.1
    /// 單台累計修正上限（ms）：超過就該重新校正，不再往上加
    static let maxCorrectionMs = 50.0

    /// 在這台輸出的補償延遲上額外加 ms（正 = 更晚出聲）。套用與移除都走緩慢斜率（rampSeconds 內走完，變速播放、不淡出、不硬切）。
    /// 聚合裝置輸出走延遲線、藍牙走 BluetoothOut 讀取點。ms = 0 → 移除。回傳 false = 找不到這台（不在聚合裝置、也沒有註冊外接）。
    /// 實際可套用的量會被夾住：總延遲不能 < 0（最慢的那台不能再提前）、不能超過延遲線容量
    @discardableResult
    func setProbeOffset(uid: String, ms: Double, rampSeconds: Double = Engine.probeRampSeconds) -> Bool {
        sync {
            guard _outputs.contains(where: { $0.uid == uid }) || external.values.contains(where: { $0.uid == uid }) else { return false }
            let v = ms.isFinite ? min(max(ms, -Self.maxProbeMs), Self.maxProbeMs) : 0
            let old = _probeMs[uid] ?? 0
            if abs(v) < 1e-9 { _probeMs[uid] = nil } else { _probeMs[uid] = v }
            _probeRate[uid] = max(abs(v - old), 0.01) / max(rampSeconds, 0.005) / 1000
            writeOffsetsLocked()
            return true
        }
    }

    /// 移除所有探測偏移（同樣走斜坡；rampSeconds = 0 → 下一個週期直接回去，只在要立刻交出 tap 時用）
    func clearProbeOffsets(rampSeconds: Double = Engine.probeRampSeconds) {
        sync {
            guard !_probeMs.isEmpty else { return }
            for (uid, old) in _probeMs { _probeRate[uid] = max(abs(old), 0.01) / max(rampSeconds, 0.005) / 1000 }
            _probeMs = [:]
            writeOffsetsLocked()
        }
    }

    /// 藍牙斷線重連：這台在重新 attach 前先暫停出聲（plan 規則 8，同 app 重開後的藍牙）。只對量過延遲、啟用中的裝置；回傳是否 hold。
    /// BluetoothOutManager 在重新 start 之前（它自己的 queue 上）同步呼叫，所以串流一開始就是靜音，不會用舊值響一下
    @discardableResult
    func holdUntilCalibrated(uid: String, firstConnect: Bool = false) -> Bool {
        sync {
            guard _config.measuredLatencyMs(uid) != nil, _config.device(uid).enabled else { return false }
            guard !_reconnectHolds.contains(uid) else { return true }
            _reconnectHolds.insert(uid)
            log(firstConnect ? "藍牙連線（這個 app 行程第一次看到）：\(uid) 交給自動校正決定前先不出聲"
                             : "藍牙重新連線：\(uid) 重新校正前先不出聲")
            pushConfigLocked()
            return true
        }
    }

    /// AppState 已把它們放進自己的 holds（Config.calibrationHolds）後呼叫：engine 這邊的暫時 hold 拿掉（nil = 全部）
    func releaseReconnectHolds(_ uids: Set<String>? = nil) {
        sync {
            let before = _reconnectHolds
            if let uids { _reconnectHolds.subtract(uids) } else { _reconnectHolds = [] }
            if before != _reconnectHolds { pushConfigLocked() }
        }
    }

    var reconnectHolds: Set<String> { sync { _reconnectHolds } }

    /// 目前的探測偏移目標（uid → ms）
    var probeOffsets: [String: Double] { sync { _probeMs } }

    /// 設定這台的延遲修正（ms，絕對值；正 = 它實際比 measuredLatencyMs 慢）。執行期、不存檔。
    /// 以修正後的延遲重算 plan，差額以 ≤ correctionSlewMsPerSecond 的斜率套到各台輸出（有線走延遲線、藍牙走讀取點）。
    /// 夾在 ±maxCorrectionMs。這台的 measuredLatencyMs 改變（重新校正）時自動清掉
    /// quiet = true：不寫 log（【第 C 輪】藍牙漂移補償每 10 秒更新一次預測值，log 由 AppState 節流）
    func setLatencyCorrection(uid: String, ms: Double, quiet: Bool = false) {
        sync {
            let v = ms.isFinite ? min(max(ms, -Self.maxCorrectionMs), Self.maxCorrectionMs) : 0
            if abs(v) < 1e-9 { _corrections[uid] = nil } else { _corrections[uid] = v }
            if !quiet { log(String(format: "延遲修正：%@ → %+.2f ms（斜率 ≤ %.2f ms/秒）", uid, v, Self.correctionSlewMsPerSecond)) }
            pushConfigLocked()
        }
    }

    /// 在目前的修正上再加 byMs；回傳新的累計值
    @discardableResult
    func adjustLatencyCorrection(uid: String, byMs: Double) -> Double {
        sync {
            let v = (_corrections[uid] ?? 0) + byMs
            setLatencyCorrection(uid: uid, ms: v)
            return _corrections[uid] ?? 0
        }
    }

    /// 目前的延遲修正（uid → ms）
    var latencyCorrections: [String: Double] { sync { _corrections } }

    /// 清掉修正（nil = 全部）；一樣走斜率回去
    func clearLatencyCorrections(_ uids: Set<String>? = nil) {
        sync {
            let before = _corrections
            if let uids { for u in uids { _corrections[u] = nil } } else { _corrections = [:] }
            guard before != _corrections else { return }
            log("延遲修正清除：\((uids.map { Array($0) } ?? Array(before.keys)).sorted())")
            pushConfigLocked()
        }
    }

    /// 每台輸出目前的額外延遲（ms；cur = 實際已走到的值，target = 目標）
    struct DelayOffset: Equatable {
        var probeTargetMs = 0.0, probeMs = 0.0, correctionTargetMs = 0.0, correctionMs = 0.0
        var settled: Bool { abs(probeTargetMs - probeMs) < 1e-6 && abs(correctionTargetMs - correctionMs) < 1e-6 }
    }

    /// uid → 目前的額外延遲（聚合裝置輸出＋外接輸出；engine 沒在跑回空）
    func delayOffsets() -> [String: DelayOffset] {
        sync {
            let sr = _sampleRate
            guard sr > 0 else { return [:] }
            let k = 1000 / sr
            var out: [String: DelayOffset] = [:]
            if rt.nOut > 0 {
                for o in _outputs where o.index < rt.nOut {
                    out[o.uid] = DelayOffset(probeTargetMs: rt.probeTarget[o.index] * k, probeMs: rt.probeCur[o.index] * k,
                                             correctionTargetMs: rt.corrTarget[o.index] * k, correctionMs: rt.corrCur[o.index] * k)
                }
            }
            for (slot, e) in external {
                out[e.uid] = DelayOffset(probeTargetMs: programRing.extProbeTarget[slot] * k, probeMs: programRing.extProbeCur[slot] * k,
                                         correctionTargetMs: programRing.extCorrTarget[slot] * k, correctionMs: programRing.extCorrCur[slot] * k)
            }
            return out
        }
    }

    /// 還有探測偏移或修正在走斜坡（背景監聽等它走完才開始下一輪）
    var isSlewing: Bool { delayOffsets().values.contains { !$0.settled } }

    /// 修正換算成每台輸出的額外延遲：plan(修正後延遲) − plan(原延遲)（兩者都出聲才算；純計算）
    private func correctionOffsetsLocked(devs: [PlanDevice], base p: [String: PlanEntry]) -> [String: Double] {
        Self.correctionOffsets(devices: devs, base: p, corrections: _corrections, mode: _mode, caps: _config.modeCaps)
    }

    /// 純函式（engine-selftest §10）：修正後延遲重算 plan，回傳每台輸出要多加的延遲（ms）
    static func correctionOffsets(devices devs: [PlanDevice], base p: [String: PlanEntry], corrections: [String: Double],
                                  mode: PlayMode, caps: ModeCaps) -> [String: Double] {
        guard !corrections.isEmpty else { return [:] }
        var lat: [String: Double] = [:]
        for d in devs {
            if let v = d.latencyMs, v.isFinite, v >= 0 { lat[d.uid] = v } else if d.isBuiltIn { lat[d.uid] = 0 }
        }
        var any = false
        for (uid, c) in corrections where lat[uid] != nil { lat[uid]! += c; any = true }
        guard any else { return [:] }
        let mn = lat.values.min() ?? 0
        if mn < 0 { for k in lat.keys { lat[k]! -= mn } }
        let devs2 = devs.map { d in
            PlanDevice(uid: d.uid, name: d.name, latencyMs: lat[d.uid], enabled: d.enabled, isBuiltIn: d.isBuiltIn,
                       requiresMeasurement: d.requiresMeasurement, needsRecalibration: d.needsRecalibration,
                       awaitingCalibration: d.awaitingCalibration)
        }
        let pc = In_Unison42.plan(devices: devs2, mode: mode, caps: caps)
        var out: [String: Double] = [:]
        for d in devs {
            guard let a = p[d.uid], let b = pc[d.uid], a.active, b.active else { continue }
            let diff = b.delayMs - a.delayMs
            if abs(diff) > 1e-9 { out[d.uid] = diff }
        }
        return out
    }

    /// 把探測偏移＋修正寫進 RT（聚合裝置輸出）與外接槽的 target／rate（ms → engine frame，取整數 frame：走完後停在整數，不留插值）
    private func writeOffsetsLocked() {
        let sr = _sampleRate
        guard sr > 0 else { return }
        let corrRate = Self.correctionSlewMsPerSecond / 1000
        func frames(_ ms: Double) -> Double { (ms / 1000 * sr).rounded() }
        func clampTotal(base: Int, corr: Double, probe: Double, maxTotal: Int) -> (Double, Double) {
            var c = corr, p = probe
            if Double(base) + c < 0 { c = Double(-base) }
            if Double(base) + c > Double(maxTotal) { c = Double(maxTotal - base) }
            if Double(base) + c + p < 0 { p = -(Double(base) + c) }
            if Double(base) + c + p > Double(maxTotal) { p = Double(maxTotal) - Double(base) - c }
            return (c, p)
        }
        if rt.nOut > 0 {
            let maxTotal = rt.ringFrames - rt.maxCycleFrames - 4
            for o in _outputs where o.index < rt.nOut {
                let (c, p) = clampTotal(base: rt.delayFrames[o.index], corr: frames(_correctionOffsetMs[o.uid] ?? 0),
                                        probe: frames(_probeMs[o.uid] ?? 0), maxTotal: maxTotal)
                rt.corrRate[o.index] = corrRate
                rt.probeRate[o.index] = _probeRate[o.uid] ?? 1
                OSMemoryBarrier()
                rt.corrTarget[o.index] = c
                rt.probeTarget[o.index] = p
            }
        }
        // 外接（藍牙）：讀取點 = T − extDelayFrames − safety − 額外延遲；ProgramRing 容量 2.7 s，延遲上限 1 s，額外量夾在 ±maxDelay 內
        let maxExt = Int((Config.maxDelayMs / 1000 * sr).rounded(.up)) + Int(frames(Self.maxCorrectionMs + Self.maxProbeMs))
        for (slot, e) in external {
            let (c, p) = clampTotal(base: programRing.extDelayFrames[slot], corr: frames(_correctionOffsetMs[e.uid] ?? 0),
                                    probe: frames(_probeMs[e.uid] ?? 0), maxTotal: maxExt)
            programRing.extCorrRate[slot] = corrRate
            programRing.extProbeRate[slot] = _probeRate[e.uid] ?? 1
            OSMemoryBarrier()
            programRing.extCorrTarget[slot] = c
            programRing.extProbeTarget[slot] = p
        }
    }

    /// 取消註冊（先停掉該裝置的 IOProc 再呼叫）
    func unregisterExternalOutput(slot: Int) {
        sync {
            guard let e = external[slot] else { return }
            external[slot] = nil
            programRing.extUsed[slot] = 0
            programRing.extActive[slot] = 0
            programRing.extGain[slot] = 0
            log("外接輸出取消：\(e.name)（槽 \(slot)）")
            pushConfigLocked()
        }
    }

    // MARK: tap 排除清單（系統提示音用）

    /// 正常模式的全域 tap 額外排除這些 Core Audio process object（自己一定排除）。被排除的行程不會被 tap 靜音、
    /// 也不會送到其他喇叭——它照自己的輸出裝置出聲（系統提示音：預設「系統」輸出設成內建喇叭即可只從內建出）。
    /// 運轉中先試著直接改 tap 的描述（kAudioTapPropertyDescription），不行才 rebuild。回傳是否已生效
    @discardableResult
    func setExtraExcludedProcesses(_ objs: [AudioObjectID]) -> Bool {
        sync {
            let uniq = Array(Set(objs.filter { $0 != 0 })).sorted()
            guard uniq != _extraExcluded else { return true }
            _extraExcluded = uniq
            return updateGlobalTapLocked("\(uniq.count) 個額外行程")
        }
    }

    /// 以 bundle id 排除（macOS 26+ CATapDescription.bundleIDs＋processRestoreEnabled）：行程結束後重啟（pid／process object
    /// 都換了）也自動套用，不必等 process list 通知——系統提示音的 systemsoundserverd 閒置會被收掉、下次按需重啟。
    /// macOS 26 以前沒有這個 API：記下但不生效（回傳 false），仍靠 setExtraExcludedProcesses。
    @discardableResult
    func setExtraExcludedBundleIDs(_ ids: [String]) -> Bool {
        sync {
            let uniq = Array(Set(ids.filter { !$0.isEmpty })).sorted()
            guard uniq != _extraExcludedBundleIDs else { return Self.bundleIDTapSupported }
            _extraExcludedBundleIDs = uniq
            guard Self.bundleIDTapSupported else { return false }
            return updateGlobalTapLocked("bundle id \(uniq)")
        }
    }

    static var bundleIDTapSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 正常模式的全域 tap 描述：排除自己＋額外行程；macOS 26+ 另外以 bundle id 排除並開 processRestore
    private func globalTapDescriptionLocked(me: AudioObjectID) -> CATapDescription {
        let td = CATapDescription(stereoGlobalTapButExcludeProcesses: (me == 0 ? [] : [me]) + _extraExcluded)
        if #available(macOS 26.0, *), !_extraExcludedBundleIDs.isEmpty {
            td.bundleIDs = _extraExcludedBundleIDs
            td.isProcessRestoreEnabled = true
        }
        return td
    }

    /// 運轉中更新全域 tap 的排除清單：先試直接改 tap 描述（kAudioTapPropertyDescription），不行才 rebuild
    private func updateGlobalTapLocked(_ what: String) -> Bool {
        guard _running, _programProcesses == nil, let tap = tapIDs.first else { return true }
        let me = Devices.processObject()
        let td = globalTapDescriptionLocked(me: me)
        // 保留原 tap 的 UUID／名稱／私有／靜音行為，只換排除清單
        if let cur: CATapDescription = tapDescriptionLocked(tap) {
            td.uuid = cur.uuid
        }
        td.name = "In_Unison42-tap"
        td.isPrivate = true
        td.muteBehavior = .mutedWhenTapped
        var a = CA.addr(kAudioTapPropertyDescription)
        var ref: CATapDescription? = td
        let st = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(tap, &a, 0, nil, UInt32(MemoryLayout<CATapDescription?>.size), $0)
        }
        if st == noErr {
            log("tap 排除清單更新：\(what)（不重建）")
            return true
        }
        log("⚠ 直接更新 tap 排除清單失敗 status=\(st)，改用重建")
        stopLocked()
        do { try startLocked(); return true } catch { log("✗ 重建失敗：\(error)"); return false }
    }

    var extraExcludedBundleIDs: [String] { sync { _extraExcludedBundleIDs } }

    var extraExcludedProcesses: [AudioObjectID] { sync { _extraExcluded } }

    private func tapDescriptionLocked(_ tap: AudioObjectID) -> CATapDescription? {
        var a = CA.addr(kAudioTapPropertyDescription)
        var ref: Unmanaged<CATapDescription>?
        var sz = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        let st = AudioObjectGetPropertyData(tap, &a, 0, nil, &sz, &ref)
        guard st == noErr, let r = ref else { return nil }
        return r.takeRetainedValue()
    }

    // MARK: 診斷（program-path 驗證用；正常 run 不會呼叫）

    /// 下次 start/rebuild 時只 tap 這些 Core Audio process object 當節目音（其他行程另開 tap 靜音）；nil = 全域 tap
    var programProcesses: [AudioObjectID]? {
        get { sync { _programProcesses } }
        set { sync { _programProcesses = newValue } }
    }

    /// >= 0：只讓這個輸出出節目音；-1：全部（下一個 IO 週期生效，有 ramp）。
    /// ProgramRing.externalSoloBase + 槽位 = 只讓該外接輸出（藍牙）出聲、聚合裝置輸出全部 0（見 soloValue(externalSlot:)）
    func setSolo(_ index: Int) { rt.solo.pointee = index }

    /// 外接輸出（藍牙）槽位的 solo 值
    static func soloValue(externalSlot slot: Int) -> Int { ProgramRing.externalSoloBase + slot }

    /// 開始等待節目音第一個 |樣本| > threshold 的時間（onsetSampleTime 會回傳它進入延遲線的 sampleTime）
    func armOnset(threshold: Float) {
        rt.onsetTime.pointee = -1
        rt.onsetThreshold.pointee = threshold
        OSMemoryBarrier()
        rt.onsetArm.pointee = 1
    }

    /// nil = 還沒偵測到
    var onsetSampleTime: Int64? {
        guard rt.onsetArm.pointee == 0 else { return nil }
        OSMemoryBarrier()
        let t = rt.onsetTime.pointee
        return t >= 0 ? t : nil
    }

    // MARK: 生命週期

    func start() throws {
        try sync {
            if _running { return }
            try startLocked()
        }
    }

    func stop() {
        sync { stopLocked() }
    }

    /// 可重入：銷毀 IOProc／聚合裝置／tap 後依目前裝置狀態重建。未運轉時等同 start()
    func rebuild() throws {
        try sync {
            stopLocked()
            try startLocked()
        }
    }

    // MARK: 設定

    /// 更新延遲／trim；運轉中立即生效（下一個 IO 週期）
    func applyConfig(_ c: Config) {
        sync {
            // 重新校正（measuredLatencyMs 改變）的裝置：舊的延遲修正作廢（新量到的值已經包含它）
            let stale = _corrections.keys.filter { c.measuredLatencyMs($0) != _config.measuredLatencyMs($0) }
            if !stale.isEmpty {
                for u in stale { _corrections[u] = nil }
                log("延遲修正清除（重新校正過）：\(stale.sorted())")
            }
            _config = c
            pushConfigLocked()
            pollVolumeLocked()
        }
    }

    /// 校正時 true：tap 來的節目音靜音（有 ramp），只出測試訊號
    func setMonitorMode(muteProgram: Bool) {
        rt.muteProgram.pointee = muteProgram ? 1 : 0
    }

    // MARK: 測試訊號

    /// 預先把樣本拷進 engine 的緩衝，IOProc 從絕對 sampleTime == atFrameOffset 起在指定輸出混入（單聲道 → 該輸出所有聲道）。
    /// - 增益：與節目音相同的目標增益（index 0 = trim；其他 = 音量倍率 × trim），不受 setMonitorMode 影響。
    /// - delayed: true 時起點再加上該輸出目前的延遲（驗證對齊用）；false 為原始時間（量測延遲用）。
    /// - 若排程時間已過，只播剩下的部分（前段截掉，時間軸不偏移）。
    /// - 回傳 false：未運轉、index 越界、長度超過 maxTestSignalSeconds、或該輸出還有測試訊號在播。
    @discardableResult
    func playTestSignal(_ samples: [Float], toOutput index: Int, atFrameOffset: Int, delayed: Bool = false) -> Bool {
        sync {
            guard _running, index >= 0, index < rt.nOut, !samples.isEmpty, samples.count <= rt.testCap else { return false }
            guard rt.testState[index] == 0 else { return false }
            // 測試緩衝延後配置：app 平常不占用（3 輸出 × 10 秒 × 48 kHz ≈ 5.8 MB），第一次要播才在這裡（engine queue，非即時）配置
            if !rt.hasTestBuffer {
                let bytes = rt.allocateTestBuffer()
                log(String(format: "測試訊號緩衝配置 %.1f MB（%d 輸出 × %.0f 秒）", Double(bytes) / 1_048_576, rt.nOut, Engine.maxTestSignalSeconds))
            }
            guard let base = rt.testBufRef.pointee else { return false }
            let dst = base + index * rt.testCap
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
            rt.testLen[index] = samples.count
            rt.testStart[index] = Int64(atFrameOffset + (delayed ? rt.delayFrames[index] : 0))
            OSMemoryBarrier()
            rt.testState[index] = 1
            return true
        }
    }

    func isTestSignalActive(output index: Int) -> Bool {
        sync { _running && index >= 0 && index < rt.nOut && rt.testState[index] != 0 }
    }

    /// 取消所有排程中的測試訊號（正在播的那個 IO 週期可能還會出一小段）
    func cancelTestSignals() {
        sync {
            for o in 0..<rt.nOut { rt.testState[o] = 0 }
        }
    }

    /// 先把測試訊號緩衝配置好（可選）：playTestSignal 第一次呼叫也會自己配置（約 5.5 MB 清零，幾 ms），
    /// 排程很緊的呼叫端可以在量測開始前先呼叫這個，避免第一個測試訊號的開頭因為配置而過了排程時間。回傳是否已有緩衝
    @discardableResult
    func prepareTestSignalBuffer() -> Bool {
        sync {
            guard rt.nOut > 0 else { return false }
            if !rt.hasTestBuffer {
                let bytes = rt.allocateTestBuffer()
                log(String(format: "測試訊號緩衝配置 %.1f MB（%d 輸出 × %.0f 秒）", Double(bytes) / 1_048_576, rt.nOut, Engine.maxTestSignalSeconds))
            }
            return rt.hasTestBuffer
        }
    }

    /// 測試訊號緩衝目前占用的 bytes（0 = 沒配置；app 平常應為 0）
    var testSignalBufferBytes: Int {
        sync { rt.nOut > 0 && rt.hasTestBuffer ? rt.nOut * rt.testCap * MemoryLayout<Float>.size : 0 }
    }

    /// 校正／測試結束後收回測試訊號緩衝（取消排程中的測試訊號；等 IOProc 跑完兩個週期才釋放，最多等約 1 秒）。
    /// 不呼叫也沒關係：stop()／rebuild() 時一定釋放。回傳釋放的 bytes
    @discardableResult
    func releaseTestSignalBuffer() -> Int {
        sync {
            guard rt.nOut > 0 else { return 0 }
            let b = rt.releaseTestBuffer(ioAlive: _running && procID != nil)
            if b > 0 { log(String(format: "測試訊號緩衝已釋放 %.1f MB", Double(b) / 1_048_576)) }
            return b
        }
    }

    // MARK: 狀態

    func status(resetPeaks: Bool = true) -> EngineStatus {
        sync {
            var outs: [EngineStatus.Output] = []
            for (i, o) in _outputs.enumerated() where i < rt.nOut {
                outs.append(.init(uid: o.uid, name: o.name, active: rt.active[i] > 0,
                                  delayMs: _sampleRate > 0 ? Double(rt.delayFrames[i]) / _sampleRate * 1000 : 0,
                                  targetGain: rt.targetGain[i], peak: rt.outPeak[i], testActive: rt.testState[i] != 0))
                if resetPeaks { rt.outPeak[i] = 0 }
            }
            let s = EngineStatus(running: _running, generation: _generation, sampleRate: _sampleRate,
                                 sampleTime: rt.sampleTime.pointee, ioCycles: rt.ioCycles.pointee, skipEvents: rt.skipEvents.pointee,
                                 volumeSourceName: _outputs.first?.name ?? "-", volumeDb: lastVolumeDb, muted: lastMuted,
                                 volumeGain: lastVolumeGain, programMuted: rt.muteProgram.pointee != 0,
                                 inputPeak: rt.inPeak.pointee, outputs: outs, inputMismatch: rt.inMismatch.pointee, mode: _mode)
            if resetPeaks { rt.inPeak.pointee = 0 }
            return s
        }
    }

    // MARK: - 內部（都在 queue 上）

    /// 音量來源：預設輸出（有 VolumeDecibels、非聚合、可用）否則內建喇叭
    /// 規則只有一份：ReconnectRules.desired（Reconnector 比對期望簽章也用它，兩邊不會不一致）
    private func chooseVolumeSource(_ outs: [AudioDevice]) -> AudioDevice? {
        let info = { (d: AudioDevice, vol: Bool) in
            RCDeviceInfo(uid: d.uid, id: d.id, name: d.name, kind: d.kind, excluded: Devices.isExcluded(d),
                         hasVolumeDb: vol ? Devices.hasVolumeDecibels(d.id) : false)
        }
        let sig = ReconnectRules.desired(physical: outs.map { info($0, false) },
                                         defaultOutput: Devices.defaultOutput().map { info($0, true) })
        guard let src = sig.volumeSource else { return nil }
        return outs.first { $0.uid == src.uid }
    }

    private func startLocked() throws {
        let phys = Devices.physicalOutputs()
        guard let src = chooseVolumeSource(phys) else { throw EngineError.noOutputs }
        let ordered = [src] + phys.filter { $0.uid != src.uid }
        let clock = ordered.first { $0.kind == .builtIn } ?? src
        log("音量來源：\(src.name)　主時鐘：\(clock.name)")
        for d in ordered { log("  輸出 \(d)") }
        for d in Devices.bluetoothOutputs() {
            log("  藍牙 \(d.name)：不放進聚合裝置（只輸出路徑 BluetoothOut 負責，需註冊 registerExternalOutput）")
        }
        for d in Devices.outputsWithInput() {
            log("  略過 \(d.name)：同時有麥克風（放進聚合裝置會打開它的麥克風、輸入 buffer 會排在 tap 前面）")
        }
        if let w = ReconnectRules.volumeKeyWarning(defaultOutput: Devices.defaultOutput().map(Devices.rcInfo), volumeSourceName: src.name, volumeSourceUID: src.uid) {
            log(w)
        }

        // 1. Process Tap：攔截期間原聲靜音。正常模式 = 全系統立體聲、排除自己；
        //    診斷模式 = tap A 只收指定行程（節目音），tap B 收其他所有行程（只為了靜音，內容丟掉）
        let me = Devices.processObject()
        var descs: [CATapDescription] = []
        if let procs = _programProcesses, !procs.isEmpty {
            descs.append(CATapDescription(stereoMixdownOfProcesses: procs))
            descs.append(CATapDescription(stereoGlobalTapButExcludeProcesses: (me == 0 ? [] : [me]) + procs))
        } else {
            descs.append(globalTapDescriptionLocked(me: me))
        }
        var tapUUIDs: [String] = []
        for (k, td) in descs.enumerated() {
            td.name = k == 0 ? "In_Unison42-tap" : "In_Unison42-tap-mute"
            td.isPrivate = true
            td.muteBehavior = .mutedWhenTapped
            var tap: AudioObjectID = 0
            let ts = AudioHardwareCreateProcessTap(td, &tap)
            guard ts == noErr else { destroyTapLocked(); throw EngineError.tap(ts) }
            tapIDs.append(tap)
            tapUUIDs.append(td.uuid.uuidString)
            log("✓ tap 建立 id=\(tap) uuid=\(td.uuid.uuidString)\(k == 0 ? "" : "（只用來靜音其他行程）")")
        }

        // 2. 私有聚合裝置：tap 為輸入；音量來源排第一（buffer 0）。
        //    漂移校正：和主時鐘同一個 clock domain（kAudioDevicePropertyClockDomain 相同且非 0）的子裝置本來就不會漂移 → 關掉
        //    （省掉 HAL 的重取樣器）；不同 domain 或 domain = 0（驅動沒回報、不能保證同源）→ 開
        let clockDomain = Self.clockDomain(clock.id)
        var drift: [String: Bool] = [:]
        for d in ordered {
            drift[d.uid] = Self.needsDriftCompensation(isClock: d.uid == clock.uid, domain: Self.clockDomain(d.id), clockDomain: clockDomain)
        }
        log("  clock domain：" + ordered.map { d in
            "\(d.name)=\(Self.clockDomain(d.id))\(d.uid == clock.uid ? "（主時鐘）" : (drift[d.uid] == true ? "→漂移校正開" : "→同 domain，漂移校正關"))"
        }.joined(separator: "、"))
        let subs: [[String: Any]] = ordered.map {
            [kAudioSubDeviceUIDKey: $0.uid, kAudioSubDeviceDriftCompensationKey: drift[$0.uid] == true ? 1 : 0]
        }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "In_Unison42",
            kAudioAggregateDeviceUIDKey: Devices.ownAggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clock.uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: subs,
            kAudioAggregateDeviceTapListKey: tapUUIDs.map { [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: 1] as [String: Any] },
        ]
        var agg: AudioObjectID = 0
        let asr = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
        guard asr == noErr else { destroyTapLocked(); throw EngineError.aggregate(asr) }
        aggID = agg
        _sampleRate = CA.f64(agg, kAudioDevicePropertyNominalSampleRate) ?? clock.nominalSampleRate
        if _sampleRate <= 0 { _sampleRate = 48000 }
        log("✓ 聚合裝置建立 id=\(agg) \(Int(_sampleRate))Hz")

        // 3. buffer 對應：每個子裝置佔用其輸出 stream 數個 buffer（依子裝置清單順序）
        var mapped: [EngineOutput] = []
        var next = 0
        for (i, d) in ordered.enumerated() {
            let streams = max(1, CA.ids(d.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).count)
            mapped.append(EngineOutput(index: i, uid: d.uid, name: d.name, deviceID: d.id, kind: d.kind,
                                       isVolumeSource: i == 0, isClock: d.uid == clock.uid,
                                       bufferStart: next, bufferCount: streams, channels: d.outputChannels,
                                       clockDomain: Self.clockDomain(d.id), driftCompensated: drift[d.uid] == true))
            next += streams
        }
        let aggStreams = CA.ids(agg, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).count
        if aggStreams != next { log("⚠ 聚合裝置輸出 stream 數 \(aggStreams) ≠ 子裝置合計 \(next)，buffer 對應可能錯位") }

        // 3b. 輸入 buffer 排列：子裝置的輸入 stream 在前、tap 的 stream 在後（每個立體聲 tap 1 個 stream）
        let subIn = ordered.reduce(0) { $0 + CA.ids($1.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count }
        let expectedIn = subIn + descs.count
        let aggIn = CA.ids(agg, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count
        log("  輸入 buffer：子裝置 \(subIn) 個＋tap \(descs.count) 個 → 節目音在 index \(subIn)（聚合裝置回報 \(aggIn) 個輸入 stream）")
        if subIn > 0 && aggIn != expectedIn {
            destroyAggregateLocked(); destroyTapLocked()
            throw EngineError.inputLayout("子裝置輸入 \(subIn)＋tap \(descs.count) = \(expectedIn)，聚合裝置回報 \(aggIn)")
        }
        if aggIn != expectedIn {
            log("⚠ 聚合裝置回報 \(aggIn) 個輸入 stream，預期 \(expectedIn)；IOProc 收到的輸入數不符時會把節目音靜音並計數（狀態行「輸入錯位」）")
        }
        _outputs = mapped
        for o in mapped { log("  \(o)") }

        // 4. 即時共用區塊
        rt.allocate(nOut: mapped.count, sampleRate: _sampleRate, testSeconds: Engine.maxTestSignalSeconds)
        rt.tapBufIndex = subIn
        rt.expectedInBufs = expectedIn
        formatChangeNotified = false
        for o in mapped { rt.bufStart[o.index] = o.bufferStart; rt.bufCount[o.index] = o.bufferCount }
        pushConfigLocked()
        pollVolumeLocked()
        for o in 0..<rt.nOut { rt.curGain[o] = rt.targetGain[o] * rt.active[o] * (rt.muteProgram.pointee == 0 ? 1 : 0) }
        programRing.beginGeneration(sampleRate: _sampleRate)   // 清舊時間軸的時鐘／writeEnd，再設取樣率、generation +1

        // 5. IOProc
        let shared = rt
        var proc: AudioDeviceIOProcID?
        let ps = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, inData, _, outData, outTime in
            shared.render(inData, outData, outTime)
        }
        guard ps == noErr, let proc else {
            destroyAggregateLocked(); destroyTapLocked(); rt.free()
            throw EngineError.ioProc(ps)
        }
        procID = proc
        let ss = AudioDeviceStart(agg, proc)
        guard ss == noErr else {
            AudioDeviceDestroyIOProcID(agg, proc); procID = nil
            destroyAggregateLocked(); destroyTapLocked(); rt.free()
            throw EngineError.start(ss)
        }

        // 6. 音量：屬性監聽（即時）＋ 1 秒備援輪詢
        addPropertyListenersLocked(volumeSource: mapped[0].deviceID, aggregate: agg)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Engine.volumePollInterval, repeating: Engine.volumePollInterval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?._pollCount += 1; self?.pollVolumeLocked() }
        t.resume()
        pollTimer = t

        _running = true
        _generation += 1
        startedAt = Date()
        ioWatchdogDone = false
        startCycles = rt.ioCycles.pointee
        log("✓ 運轉中 gen=\(_generation)，\(mapped.count) 個輸出")
    }

    private func stopLocked() {
        pollTimer?.cancel()
        pollTimer = nil
        removePropertyListenersLocked()
        let wasRunning = _running || aggID != 0 || !tapIDs.isEmpty
        if aggID != 0, let p = procID {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
        }
        procID = nil
        destroyAggregateLocked()
        destroyTapLocked()
        rt.free()   // IOProc 已銷毀，安全釋放
        _outputs = []
        _running = false
        _probeMs = [:]      // 探測偏移是暫時的（背景監聽一輪 10 秒內）：engine 停了就作廢，重新啟動不會帶著它
        programRing.sampleRate.pointee = 0
        if wasRunning { log("已清除 IOProc／聚合裝置／tap") }
    }

    // MARK: 屬性監聽（音量／靜音／取樣率）

    /// 音量來源的 VolumeDecibels／VolumeScalar／Mute（output scope，main 與聲道 1、2 中存在的 element）＋聚合裝置的 NominalSampleRate。
    /// 通知在 engine queue 上執行 pollVolumeLocked（和備援輪詢同一條路徑；一次音量拖曳會連發很多通知，pollVolumeLocked 本身很便宜）
    private func addPropertyListenersLocked(volumeSource src: AudioObjectID, aggregate agg: AudioObjectID) {
        removePropertyListenersLocked()
        var targets: [(AudioObjectID, AudioObjectPropertyAddress)] = []
        for sel in [kAudioDevicePropertyVolumeDecibels, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for el: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] where CA.has(src, sel, kAudioObjectPropertyScopeOutput, el) {
                targets.append((src, CA.addr(sel, kAudioObjectPropertyScopeOutput, el)))
            }
        }
        targets.append((agg, CA.addr(kAudioDevicePropertyNominalSampleRate)))
        var failed: [String] = []
        for (id, a) in targets {
            var addr = a
            let ev = volumeEvents
            let block: AudioObjectPropertyListenerBlock = { _, _ in ev?.or(data: 1) }
            let st = AudioObjectAddPropertyListenerBlock(id, &addr, listenerQueue, block)
            if st == noErr { propertyListeners.append((id, a, block)) } else { failed.append("\(CA.fourCC(a.mSelector))/\(a.mElement) status=\(st)") }
        }
        log("音量監聽：\(propertyListeners.count) 個屬性\(failed.isEmpty ? "" : "（失敗 \(failed.joined(separator: "、"))，靠 1 秒備援輪詢）")")
    }

    private func removePropertyListenersLocked() {
        for l in propertyListeners {
            var a = l.addr
            AudioObjectRemovePropertyListenerBlock(l.id, &a, listenerQueue, l.block)   // 聚合裝置已銷毀時會失敗，忽略
        }
        propertyListeners = []
    }

    /// 監聽／輪詢統計（診斷；ctl 或測試用）
    var volumeUpdateStats: (listeners: Int, listenerEvents: Int, polls: Int) {
        sync { (propertyListeners.count, _listenerEvents, _pollCount) }
    }

    // MARK: clock domain

    /// kAudioDevicePropertyClockDomain（0 = 沒回報）
    static func clockDomain(_ id: AudioObjectID) -> UInt32 {
        CA.u32(id, kAudioDevicePropertyClockDomain) ?? 0
    }

    /// 子裝置要不要開漂移校正（純函式，離線自測用）：主時鐘不開；與主時鐘同 domain 且 domain 非 0 → 不開；其餘一律開
    static func needsDriftCompensation(isClock: Bool, domain: UInt32, clockDomain: UInt32) -> Bool {
        if isClock { return false }
        return !(domain != 0 && domain == clockDomain)
    }

    private func destroyAggregateLocked() {
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
    }

    private func destroyTapLocked() {
        for t in tapIDs { AudioHardwareDestroyProcessTap(t) }
        tapIDs = []
    }

    /// 依 plan()（聚合裝置輸出＋外接輸出、目前模式、設定）重算出聲遮罩與延遲（ms → frame）寫進 RT 與外接槽
    private func pushConfigLocked() {
        var cfg = _config
        if !_reconnectHolds.isEmpty { cfg.calibrationHolds.formUnion(_reconnectHolds) }
        var devs = _outputs.map { PlanDevice(uid: $0.uid, name: $0.name, isBuiltIn: $0.kind == .builtIn, config: cfg) }
        for slot in external.keys.sorted() {
            let e = external[slot]!
            devs.append(PlanDevice(uid: e.uid, name: e.name, isBuiltIn: e.isBuiltIn,
                                   requiresMeasurement: !e.isBuiltIn && !_allowUncalibratedExternal, config: cfg))
        }
        let p = In_Unison42.plan(devices: devs, mode: _mode, caps: _config.modeCaps)
        let changed = p != _plan
        _plan = p
        let sr = _sampleRate
        let maxFrames = sr > 0 ? Int((Config.maxDelayMs / 1000 * sr).rounded(.up)) : 0
        if rt.nOut > 0, sr > 0 {
            for o in _outputs where o.index < rt.nOut {
                let e = p[o.uid]
                let frames = Int(((e?.delayMs ?? 0) / 1000 * sr).rounded())
                rt.delayFrames[o.index] = min(max(frames, 0), rt.maxDelayFrames)
                rt.active[o.index] = (e?.active ?? false) ? 1 : 0
            }
        }
        for (slot, e) in external {
            let pe = p[e.uid]
            let frames = sr > 0 ? Int(((pe?.delayMs ?? 0) / 1000 * sr).rounded()) : 0
            programRing.extDelayFrames[slot] = min(max(frames, 0), maxFrames)
            programRing.extActive[slot] = (pe?.active ?? false) ? 1 : 0
        }
        // 探測偏移／延遲修正（背景監聽）：plan 改變也要重算（修正換算成各台的額外延遲依 plan 而定）
        _correctionOffsetMs = correctionOffsetsLocked(devs: devs, base: p)
        writeOffsetsLocked()
        if changed {
            let desc = devs.map { d in "\(d.name)：\(p[d.uid]?.description ?? "?")" }.joined(separator: "；")
            if !devs.isEmpty { log("出聲計畫（\(_mode.label)）：\(desc)") }
            _onPlanChange?(p)
        }
    }

    /// 讀音量來源的 dB／靜音 → 目標增益（index 0 = trim；其他 = 音量倍率 × trim）
    private func pollVolumeLocked() {
        guard rt.nOut > 0, let src = _outputs.first else {
            for slot in external.keys { programRing.extGain[slot] = 0 }
            return
        }
        let db = Devices.volumeDecibels(src.deviceID)
        let muted = Devices.isMuted(src.deviceID)
        let vg: Float = muted ? 0 : (db.map { powf(10, $0 / 20) } ?? 1)
        if !ioWatchdogDone, _running, Date().timeIntervalSince(startedAt) > 2 {
            ioWatchdogDone = true
            if rt.ioCycles.pointee == startCycles, !SystemSoundsRouter.otherProgramPlaying() {
                log("啟動 2 秒後 IOProc 還沒被呼叫：目前沒有程式在播聲音 → 正常待命（tap 要等有程式開始播，系統才會啟動）")
            } else if rt.ioCycles.pointee == startCycles {
                if startCycles > 0 {
                    // 這個行程之前跑過（ioCycles 重建不歸零）→ 權限沒問題；多半是系統音訊服務暫時沒回應（校正交接、開機後實機見過 20 秒～4.5 分鐘）
                    log("⚠ 啟動 2 秒後 IOProc 仍未被呼叫：這個 app 之前跑過，不是權限問題，多半是系統音訊服務暫時沒回應；重接會先拆掉攔截讓原聲照常出、再重試")
                } else {
                    log("⚠ 啟動 2 秒後 IOProc 仍未被呼叫：多半是「系統音訊錄製」權限未授與（系統設定 → 隱私權與安全性 → 螢幕與系統錄音 → 僅系統錄音），聲音不會送出")
                }
            }
        }
        // 取樣率變了（延遲 frame 數、延遲線都以建立時的取樣率算）→ 通知重建一次
        if _running, !formatChangeNotified, aggID != 0,
           let sr = CA.f64(aggID, kAudioDevicePropertyNominalSampleRate), sr > 0, abs(sr - _sampleRate) > 0.5 {
            formatChangeNotified = true
            let msg = String(format: "聚合裝置取樣率 %.0f → %.0f Hz", _sampleRate, sr)
            log("⚠ \(msg)，需要重建（延遲 frame 數要重算）")
            _onFormatChange?(msg)
        }
        lastVolumeDb = db
        lastMuted = muted
        lastVolumeGain = vg
        // 校正子行程：音量來源以外改用固定增益（見 calibrationFixedGain）；靜音時仍為 0
        let og: Float = muted ? 0 : (_calibrationFixedGain ?? vg)
        // 校正子行程（固定增益）：音量來源以外不套用使用者的 trim —— trim 是聽感偏好，測試音只要麥克風好量
        //（10-02 Kang：GLASS5+ 調小聲 −8 dB，測試音跟著小 8 dB）。音量來源（內建，index 0）照舊套 trim：它是參考、離麥克風最遠，
        // 使用者調大的 trim 剛好幫它；拿掉反而更難量
        let calibrating = _calibrationFixedGain != nil || _calibrationFixedGainExternal != nil
        for o in _outputs where o.index < rt.nOut {
            rt.targetGain[o.index] = Engine.outputGain(isVolumeSource: o.index == 0, volumeGain: og,
                                                       trim: _config.effectiveTrimGain(o.uid), calibrating: calibrating)
        }
        // 外接輸出永遠不是音量來源（音量來源一定在聚合裝置裡）：音量倍率 × trim × active（校正時不套 trim）
        for (slot, e) in external {
            let eg: Float = muted ? 0 : (_calibrationFixedGainExternal ?? og)
            programRing.extGain[slot] = Engine.outputGain(isVolumeSource: false, volumeGain: eg,
                                                          trim: _config.effectiveTrimGain(e.uid), calibrating: calibrating) * Float(programRing.extActive[slot])
        }
    }
}

/// Engine 內部把所有狀態序列化到自己的 queue；即時共用區塊只用無鎖單值讀寫 → 可跨執行緒傳遞
extension Engine: @unchecked Sendable {}

// MARK: - 節目音快照（第 B 輪：背景監聽用；非即時執行緒拷貝 ProgramRing）

/// engine 時間軸上的一個對時點：sampleTime 這個 frame 在延遲 0 的聚合輸出上於 hostTime 播出
struct ProgramClockSample: Equatable {
    let sampleTime: Int64
    let hostTime: UInt64
}

extension Engine {
    /// 目前節目音時鐘（engine 沒在跑／還沒寫入 → nil）。任何非即時執行緒可呼叫（不經 engine queue、不會卡）
    func programClock() -> (clock: ProgramClockSample, sampleRate: Double, generation: Int, writeEnd: Int64)? {
        let ring = program
        let sr = ring.sampleRate.pointee
        let gen = ring.generation.pointee
        guard sr > 0, let c = ring.clock() else { return nil }
        let we = ring.writeEnd.pointee
        guard we >= 0, ring.generation.pointee == gen else { return nil }
        return (ProgramClockSample(sampleTime: c.sampleTime, hostTime: c.hostTime), sr, gen, we)
    }

    /// 拷出節目音 frame [t, t+n)（立體聲交錯，原始 tap 輸入、未延遲、未乘增益）；區間還沒寫入或已被覆寫 → nil。
    /// 非即時執行緒用（會配置記憶體）；ProgramRing 只有約 2.7 秒，長時間請用 ProgramRecorder 邊錄邊拷
    func programSnapshot(from t: Int64, frames n: Int) -> [Float]? {
        guard n > 0, n <= ProgramRing.frames else { return nil }
        var out = [Float](repeating: 0, count: n * 2)
        let ok = out.withUnsafeMutableBufferPointer { program.read(from: t, frames: n, into: $0.baseAddress!) }
        return ok ? out : nil
    }

    /// host tick → 秒
    static var hostSecondsPerTick: Double { BTRenderer.hostSecondsPerTick() }
}

/// 一段錄下來的節目音（單聲道 = (L+R)/2）＋對時點
struct ProgramRecording {
    /// samples[0] 的 engine sampleTime
    let startSampleTime: Int64
    let sampleRate: Double
    let samples: [Float]
    /// 錄音期間每次拷貝時讀到的 (sampleTime, hostTime)；估計 sampleTime ↔ hostTime 直線用
    let clock: [ProgramClockSample]
    let generation: Int
    /// 中途被覆寫（拷太慢）而補 0 的 frame 數（> 0 表示有洞）
    let gapFrames: Int
    /// 中途 engine 換世代（重建）→ 時間軸斷了，這段不能用
    let generationChanged: Bool
    let secondsPerHostTick: Double

    /// hostTime → engine sampleTime（hostTime(forSampleTime:) 的反函數；對時點不足回 nil）
    func sampleTime(forHostTime h: UInt64) -> Double? {
        guard let a = hostTime(forSampleTime: startSampleTime), let b = hostTime(forSampleTime: startSampleTime + Int64(sampleRate)), b != a else { return nil }
        let slope = Double(Int64(sampleRate)) / (b - a)        // frame／tick
        return Double(startSampleTime) + (Double(h) - a) * slope
    }

    /// sampleTime → hostTime（用對時點最小平方直線；少於 2 點回 nil）
    func hostTime(forSampleTime t: Int64) -> Double? {
        guard clock.count >= 2 else { return clock.first.map { Double($0.hostTime) + Double(t - $0.sampleTime) / sampleRate / secondsPerHostTick } }
        let n = Double(clock.count)
        let x0 = Double(clock[0].sampleTime), y0 = Double(clock[0].hostTime)
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for c in clock {
            let x = Double(c.sampleTime) - x0, y = Double(c.hostTime) - y0
            sx += x; sy += y; sxx += x * x; sxy += x * y
        }
        let den = n * sxx - sx * sx
        guard den != 0 else { return nil }
        let a = (n * sxy - sx * sy) / den, b = (sy - a * sx) / n
        return y0 + b + a * (Double(t) - x0)
    }
}

/// 邊錄邊拷節目音（非即時執行緒；每 pollInterval 從 ProgramRing 拷新寫入的 frame）。
/// start 時先往回拷 lookbackSeconds（藍牙比其他喇叭晚約 0.4 秒，到達麥克風的聲音是更早以前的節目音）
final class ProgramRecorder {
    static let pollInterval: TimeInterval = 0.2
    private let ring: ProgramRing
    private let maxFrames: Int
    private let q = DispatchQueue(label: "In_Unison42.program-recorder", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var samples: [Float] = []
    private var clock: [ProgramClockSample] = []
    private var start: Int64 = 0
    private var next: Int64 = 0
    private var gen = 0
    private var rate = 0.0
    private var gaps = 0
    private var genChanged = false
    private var running = false
    private let scratchFrames = 16384
    private let scratch: UnsafeMutablePointer<Float>

    /// maxSeconds：最多錄多少（含往回拷的部分），超過就不再拷
    init(ring: ProgramRing, maxSeconds: Double) {
        self.ring = ring
        let sr = ring.sampleRate.pointee > 0 ? ring.sampleRate.pointee : 48000
        maxFrames = Int(maxSeconds * sr)
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * 2)
    }

    deinit {
        timer?.cancel()
        scratch.deallocate()
    }

    /// 開始：回傳 false = engine 沒在跑／還沒有節目音
    func start(lookbackSeconds: Double) -> Bool {
        q.sync {
            let sr = ring.sampleRate.pointee
            let g = ring.generation.pointee
            let we = ring.writeEnd.pointee
            guard sr > 0, we >= 0, !running else { return false }
            rate = sr; gen = g
            let back = Int64(min(lookbackSeconds, 2.0) * sr)
            start = max(we - back, we - Int64(ring.capacity) + Int64(scratchFrames))
            next = start
            samples = []; samples.reserveCapacity(maxFrames)
            clock = []; gaps = 0; genChanged = false
            running = true
            pollLocked()
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.pollLocked() }
            t.resume()
            timer = t
            return true
        }
    }

    /// 停止並回傳錄到的（沒 start 過回 nil）
    func stop() -> ProgramRecording? {
        q.sync {
            timer?.cancel(); timer = nil
            guard running else { return nil }
            pollLocked()
            running = false
            return ProgramRecording(startSampleTime: start, sampleRate: rate, samples: samples, clock: clock, generation: gen,
                                    gapFrames: gaps, generationChanged: genChanged, secondsPerHostTick: Engine.hostSecondsPerTick)
        }
    }

    private func pollLocked() {
        guard running, !genChanged else { return }
        if ring.generation.pointee != gen || ring.sampleRate.pointee != rate { genChanged = true; return }
        if let c = ring.clock(), c.hostTime != 0, clock.last?.sampleTime != c.sampleTime {
            clock.append(ProgramClockSample(sampleTime: c.sampleTime, hostTime: c.hostTime))
        }
        let we = ring.writeEnd.pointee
        while next < we && samples.count < maxFrames {
            let n = Int(min(Int64(scratchFrames), we - next, Int64(maxFrames - samples.count)))
            if ring.read(from: next, frames: n, into: scratch) {
                for f in 0..<n { samples.append(0.5 * (scratch[2 * f] + scratch[2 * f + 1])) }
            } else {
                // 已被覆寫（拷太慢）或還沒寫：補 0 記洞（不會發生在正常 0.2 秒輪詢；保險）
                samples.append(contentsOf: repeatElement(0, count: n))
                gaps += n
            }
            next += Int64(n)
        }
    }
}

// MARK: - 離線自測（engine-selftest：直接呼叫 RTShared.render，不碰 Core Audio 裝置、不出聲）

extension Engine {
    /// 每台輸出的目標增益（純函式）：音量來源（內建）= trim（系統音量由硬體套）；其他 = 音量倍率 × trim。
    /// 校正子行程（calibrating）時音量來源以外不套 trim（trim 是聽感偏好，測試音只要麥克風好量）；音量來源照套（它是參考、離麥克風遠）
    static func outputGain(isVolumeSource: Bool, volumeGain: Float, trim: Float, calibrating: Bool) -> Float {
        isVolumeSource ? trim : volumeGain * (calibrating ? 1 : trim)
    }
}

func runEngineSelfTest() -> Int32 {
    var fail = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !ok { fail += 1 }
    }
    print("── 增益：校正時外接不套 trim、音量來源照套 ──")
    do {
        let m8 = powf(10, -8 / 20), p6 = powf(10, 6 / 20), fixed = powf(10, -24 / 20)
        check(abs(Engine.outputGain(isVolumeSource: false, volumeGain: 0.3, trim: m8, calibrating: false) - 0.3 * m8) < 1e-6, "平常：外接 = 音量倍率 × trim")
        check(abs(Engine.outputGain(isVolumeSource: false, volumeGain: fixed, trim: m8, calibrating: true) - fixed) < 1e-6,
              "校正：GLASS5+ trim −8 dB 不套，測試音照固定 −24 dB")
        check(abs(Engine.outputGain(isVolumeSource: true, volumeGain: 1, trim: p6, calibrating: true) - p6) < 1e-6, "校正：內建（音量來源）trim +6 dB 照套")
    }
    let n = 256
    func makeRT(nOut: Int, expectedIn: Int, tapIndex: Int) -> RTShared {
        var rt = RTShared()
        rt.muteProgram = RTShared.alloc(1, 0)
        rt.sampleTime = RTShared.alloc(1, Int64(0))
        rt.ioCycles = RTShared.alloc(1, Int64(0))
        rt.inPeak = RTShared.alloc(1, Float(0))
        rt.skippedFrames = RTShared.alloc(1, Int64(0))
        rt.skipEvents = RTShared.alloc(1, Int64(0))
        rt.inMismatch = RTShared.alloc(1, Int64(0))
        rt.solo = RTShared.alloc(1, -1)
        rt.onsetArm = RTShared.alloc(1, 0)
        rt.onsetTime = RTShared.alloc(1, Int64(-1))
        rt.onsetThreshold = RTShared.alloc(1, Float(0.01))
        rt.allocate(nOut: nOut, sampleRate: 48000, testSeconds: 0.1)
        rt.tapBufIndex = tapIndex
        rt.expectedInBufs = expectedIn
        for o in 0..<nOut { rt.bufStart[o] = o; rt.bufCount[o] = 1; rt.targetGain[o] = 1; rt.curGain[o] = 1 }
        return rt
    }
    /// 輸入 buffer：values[k] = 第 k 個 buffer 的常數值（立體聲交錯）；回傳各輸出 buffer 最後一個 frame 的左聲道
    func cycle(_ rt: RTShared, inputs values: [Float], nOut: Int, sampleTime: Double, firstNonZeroAt: Int? = nil) -> [Float] {
        let ins = AudioBufferList.allocate(maximumBuffers: values.count)
        var inMem: [UnsafeMutablePointer<Float>] = []
        for (k, v) in values.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
            for f in 0..<n {
                let x: Float = (firstNonZeroAt.map { f < $0 } ?? false) ? 0 : v
                p[2 * f] = x; p[2 * f + 1] = x
            }
            inMem.append(p)
            ins[k] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 2 * 4), mData: p)
        }
        let outs = AudioBufferList.allocate(maximumBuffers: nOut)
        var outMem: [UnsafeMutablePointer<Float>] = []
        for k in 0..<nOut {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
            p.initialize(repeating: 9, count: n * 2)
            outMem.append(p)
            outs[k] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 2 * 4), mData: p)
        }
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mFlags = .sampleTimeValid
        rt.render(UnsafePointer(ins.unsafePointer), outs.unsafeMutablePointer, &ts)
        let res = outMem.map { $0[2 * (n - 1)] }
        inMem.forEach { $0.deallocate() }
        outMem.forEach { $0.deallocate() }
        free(ins.unsafeMutablePointer)
        free(outs.unsafeMutablePointer)
        return res
    }

    print("── 1. 輸入 buffer 排列：子裝置麥克風在前、tap 在後 ──")
    do {
        var rt = makeRT(nOut: 2, expectedIn: 1, tapIndex: 0)
        var r = cycle(rt, inputs: [0.25], nOut: 2, sampleTime: 0)
        check(r.allSatisfy { abs($0 - 0.25) < 1e-6 }, "只有 tap：輸出 = tap 內容 0.25", "\(r)")
        rt.free()
        rt = makeRT(nOut: 2, expectedIn: 2, tapIndex: 1)
        r = cycle(rt, inputs: [0.5, 0.25], nOut: 2, sampleTime: 0)
        check(r.allSatisfy { abs($0 - 0.25) < 1e-6 }, "麥克風(0.5)＋tap(0.25)、tapIndex=1：輸出 = 0.25（不是麥克風）", "\(r)")
        rt.free()
        rt = makeRT(nOut: 2, expectedIn: 1, tapIndex: 0)
        r = cycle(rt, inputs: [0.5, 0.25], nOut: 2, sampleTime: 0)
        check(r.allSatisfy { $0 == 0 } && rt.inMismatch.pointee == 1, "收到 2 個輸入但預期 1 個：不讀輸入（輸出 0）、錯位計數 +1",
              "out=\(r) mismatch=\(rt.inMismatch.pointee)")
        rt.free()
    }

    print("── 2. solo（診斷）──")
    do {
        var rt = makeRT(nOut: 3, expectedIn: 1, tapIndex: 0)
        rt.solo.pointee = 1
        var r = cycle(rt, inputs: [0.3], nOut: 3, sampleTime: 0)     // 第一個週期 ramp
        r = cycle(rt, inputs: [0.3], nOut: 3, sampleTime: Double(n))
        check(r[0] == 0 && abs(r[1] - 0.3) < 1e-6 && r[2] == 0, "solo=1：只有輸出 1 有聲音", "\(r)")
        rt.solo.pointee = -1
        _ = cycle(rt, inputs: [0.3], nOut: 3, sampleTime: Double(2 * n))
        r = cycle(rt, inputs: [0.3], nOut: 3, sampleTime: Double(3 * n))
        check(r.allSatisfy { abs($0 - 0.3) < 1e-6 }, "solo=-1：全部恢復", "\(r)")
        rt.free()
    }

    print("── 3. onset（診斷）──")
    do {
        var rt = makeRT(nOut: 1, expectedIn: 1, tapIndex: 0)
        rt.onsetThreshold.pointee = 0.05
        rt.onsetArm.pointee = 1
        _ = cycle(rt, inputs: [0], nOut: 1, sampleTime: 0)
        check(rt.onsetArm.pointee == 1, "靜音時不觸發")
        _ = cycle(rt, inputs: [0.2], nOut: 1, sampleTime: Double(n), firstNonZeroAt: 100)
        check(rt.onsetArm.pointee == 0 && rt.onsetTime.pointee == Int64(n + 100), "第 2 個週期第 100 個樣本觸發 → sampleTime \(n + 100)",
              "onset=\(rt.onsetTime.pointee)")
        rt.free()
    }

    print("── 4. 延遲改變：先淡出、換延遲、再淡入（不硬切）──")
    do {
        var rt = makeRT(nOut: 1, expectedIn: 1, tapIndex: 0)
        var r = cycle(rt, inputs: [0.5], nOut: 1, sampleTime: 0)
        check(abs(r[0] - 0.5) < 1e-6 && rt.curDelay[0] == 0, "初始延遲 0：輸出 0.5", "\(r)")
        rt.delayFrames[0] = 10
        r = cycle(rt, inputs: [0.5], nOut: 1, sampleTime: Double(n))
        check(r[0] < 0.01 && rt.curDelay[0] == 0 && rt.curGain[0] == 0, "第 1 個週期：舊延遲淡出到 0", "last=\(r[0]) curDelay=\(rt.curDelay[0])")
        r = cycle(rt, inputs: [0.5], nOut: 1, sampleTime: Double(2 * n))
        check(rt.curDelay[0] == 10 && r[0] > 0.49 && rt.curGain[0] == 1, "第 2 個週期：換成新延遲並淡入", "last=\(r[0]) curDelay=\(rt.curDelay[0])")
        rt.free()
    }

    print("── 5. 出聲遮罩（plan.active）：淡出到 0、再淡入 ──")
    do {
        var rt = makeRT(nOut: 2, expectedIn: 1, tapIndex: 0)
        _ = cycle(rt, inputs: [0.4], nOut: 2, sampleTime: 0)
        rt.active[1] = 0
        var r = cycle(rt, inputs: [0.4], nOut: 2, sampleTime: Double(n))
        check(abs(r[0] - 0.4) < 1e-6 && r[1] < 0.01, "active=0：該輸出一個週期內淡出、其他不受影響", "\(r)")
        r = cycle(rt, inputs: [0.4], nOut: 2, sampleTime: Double(2 * n))
        check(r[1] == 0, "之後保持 0", "\(r)")
        rt.active[1] = 1
        r = cycle(rt, inputs: [0.4], nOut: 2, sampleTime: Double(3 * n))
        check(r[1] > 0.39, "active=1：淡入", "\(r)")
        rt.free()
    }

    print("── 6. 節目音廣播緩衝（ProgramRing）──")
    do {
        var rt = makeRT(nOut: 1, expectedIn: 1, tapIndex: 0)
        let mute = RTShared.alloc(1, 0)
        let soloP = RTShared.alloc(1, -1)
        let pr = ProgramRing(muteProgram: mute, solo: soloP)
        rt.program = pr
        let dst = UnsafeMutablePointer<Float>.allocate(capacity: 2 * n)
        check(!pr.read(from: 0, frames: 16, into: dst) && pr.clock() == nil, "還沒寫入：讀取失敗、沒有時鐘")
        _ = cycle(rt, inputs: [0.25], nOut: 1, sampleTime: 0)
        _ = cycle(rt, inputs: [0.75], nOut: 1, sampleTime: Double(n))
        check(pr.writeEnd.pointee == Int64(2 * n), "writeEnd = 2 個週期", "\(pr.writeEnd.pointee)")
        var ok = pr.read(from: Int64(n - 2), frames: 4, into: dst)
        check(ok && dst[0] == 0.25 && dst[3] == 0.25 && dst[4] == 0.75 && dst[7] == 0.75, "跨週期讀回原始 tap 輸入（未延遲、未乘增益）",
              "\((0..<8).map { dst[$0] })")
        ok = pr.read(from: Int64(2 * n - 2), frames: 4, into: dst)
        check(!ok && dst[0] == 0, "讀到還沒寫的區間：失敗且填 0")
        check(pr.clock()?.sampleTime == Int64(n), "時鐘 = 最近週期起點 sampleTime", "\(String(describing: pr.clock()))")
        // HAL 跳號：[舊 writeEnd, t0) 的槽位要補 0，不能讀到 capacity 之前的舊節目音
        do {
            let t1 = pr.writeEnd.pointee                           // 2n
            let hole = n / 2
            // 空洞的槽位先放「舊節目音」0.5（模擬 capacity 之前留下的值）
            for f in 0..<hole {
                let r = (Int(truncatingIfNeeded: t1 + Int64(f)) & pr.mask) * 2
                pr.data[r] = 0.5; pr.data[r + 1] = 0.5
            }
            let fresh = [Float](repeating: 0.1, count: n)
            fresh.withUnsafeBufferPointer { pr.write($0.baseAddress, inCh: 1, frames: n, at: t1 + Int64(hole), hostTime: 0) }
            let okGap = pr.read(from: t1, frames: hole, into: dst)
            let gapMax = (0..<(2 * hole)).map { abs(dst[$0]) }.max() ?? 1
            check(okGap && gapMax == 0, "跳號空洞讀到 0（不是舊節目音）", "ok=\(okGap) max=\(gapMax)")
            let okNew = pr.read(from: t1 + Int64(hole), frames: 4, into: dst)
            check(okNew && dst[0] == 0.1 && dst[7] == 0.1, "跳號後的新資料照常讀回")
            // 空洞 ≥ 容量（喚醒時跳好幾秒）：整個 ring 清零
            pr.data[0] = 0.9; pr.data[1] = 0.9
            pr.write(nil, inCh: 2, frames: 1, at: pr.writeEnd.pointee + Int64(ProgramRing.frames) * 3, hostTime: 0)
            check((0..<(ProgramRing.frames * 2)).allSatisfy { pr.data[$0] == 0 }, "跳號 ≥ 容量：整個 ring 清零")
        }
        // 寫入超過容量後，最舊的資料不能再讀
        let cap = Int64(ProgramRing.frames)
        pr.write(nil, inCh: 2, frames: 1, at: cap + Int64(2 * n), hostTime: 0)
        check(!pr.read(from: 0, frames: 4, into: dst), "被覆寫的舊區間：讀取失敗")
        dst.deallocate()
        rt.program = nil
        pr.free(); mute.deallocate(); soloP.deallocate()
        rt.free()
    }

    print("── 7. 測試訊號緩衝延後配置（平常不占記憶體）──")
    do {
        var rt = makeRT(nOut: 2, expectedIn: 1, tapIndex: 0)
        check(!rt.hasTestBuffer, "allocate 後沒有測試緩衝（testBufRef.pointee == nil）")
        // 排程了但緩衝不存在（例如已收回）：不崩潰、不出測試音、狀態自己結束
        rt.testLen[0] = 10; rt.testStart[0] = 0; rt.testState[0] = 1
        var r = cycle(rt, inputs: [0], nOut: 2, sampleTime: 0)
        check(r.allSatisfy { $0 == 0 } && rt.testState[0] == 0, "緩衝 nil 時 testState=1：輸出靜音、testState 歸 0", "\(r) state=\(rt.testState[0])")
        let bytes = rt.allocateTestBuffer()
        check(rt.hasTestBuffer && bytes == 2 * rt.testCap * 4, "allocateTestBuffer：配置 nOut × testCap", "\(bytes) bytes")
        check(rt.allocateTestBuffer() == 0, "重複配置不動")
        // 在輸出 1 的 [n, 2n) 放 0.5 的測試訊號（節目音 0）
        let base = rt.testBufRef.pointee!
        for k in 0..<n { base[1 * rt.testCap + k] = 0.5 }
        rt.testLen[1] = n; rt.testStart[1] = Int64(n)
        OSMemoryBarrier(); rt.testState[1] = 1
        r = cycle(rt, inputs: [0], nOut: 2, sampleTime: Double(n))
        check(r[0] == 0 && abs(r[1] - 0.5) < 1e-6 && rt.testState[1] == 0, "測試訊號只出在輸出 1，播完 testState 歸 0", "\(r)")
        // 競態（2026-09-29 審查）：IOProc 開頭讀到 0、控制端在渲染中途寫 1 → 收尾不能把新排程清掉
        check(!RTShared.shouldEndTest(readState: 0, hadBuffer: false, finished: false), "開頭讀到 0、中途被排程：收尾不清（新測試訊號下個週期照播）")
        check(RTShared.shouldEndTest(readState: 1, hadBuffer: false, finished: false), "開頭讀到 1、緩衝已收回：清 0")
        check(RTShared.shouldEndTest(readState: 1, hadBuffer: true, finished: true) && !RTShared.shouldEndTest(readState: 1, hadBuffer: true, finished: false),
              "開頭讀到 1：播完才清、沒播完不清")
        // 端到端：輸出 0 閒置跑一個週期後才排程（模擬中途寫 1 的結果），下一個週期要播得出來
        for k in 0..<n { base[0 * rt.testCap + k] = 0.25 }
        r = cycle(rt, inputs: [0], nOut: 2, sampleTime: Double(2 * n))
        rt.testLen[0] = n; rt.testStart[0] = Int64(3 * n)
        OSMemoryBarrier(); rt.testState[0] = 1
        check(rt.testState[0] == 1, "閒置週期之後排程：state 仍是 1")
        r = cycle(rt, inputs: [0], nOut: 2, sampleTime: Double(3 * n))
        check(abs(r[0] - 0.25) < 1e-6 && r[1] == 0 && rt.testState[0] == 0, "排程後下一個週期播出、播完歸 0", "\(r)")
        let freed = rt.releaseTestBuffer(ioAlive: false)
        check(!rt.hasTestBuffer && freed == bytes, "releaseTestBuffer（IO 未運轉）：直接釋放", "\(freed) bytes")
        _ = rt.allocateTestBuffer()
        let kept = rt.releaseTestBuffer(ioAlive: true, timeout: 0.05)
        check(kept == 0 && rt.hasTestBuffer, "IO 標示運轉但週期不前進：放棄釋放（不 use-after-free）")
        rt.free()   // free 會一起釋放測試緩衝
    }

    print("── 8. 漂移校正：同 clock domain 關閉 ──")
    check(!Engine.needsDriftCompensation(isClock: true, domain: 0, clockDomain: 0), "主時鐘：不開")
    check(!Engine.needsDriftCompensation(isClock: false, domain: 1835100526, clockDomain: 1835100526), "同 domain（非 0）：不開")
    check(Engine.needsDriftCompensation(isClock: false, domain: 7, clockDomain: 1835100526), "不同 domain：開")
    check(Engine.needsDriftCompensation(isClock: false, domain: 0, clockDomain: 0), "domain 0（沒回報）：開")
    check(Engine.needsDriftCompensation(isClock: false, domain: 0, clockDomain: 1835100526), "子裝置 domain 0：開")

    print("── 9. 探測偏移／延遲修正：緩慢斜率（取樣級不連續檢查）──")
    do {
        // 1 kHz 正弦（0.5），每週期 256 frame；輸出逐樣本收集
        let sr = 48000.0, hz = 1000.0, amp = 0.5
        func x(_ t: Int) -> Float { Float(amp * sin(2 * Double.pi * hz * Double(t) / sr)) }
        var rt = makeRT(nOut: 1, expectedIn: 1, tapIndex: 0)
        var t = 0
        var ys: [Float] = []
        let inBuf = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
        let outBuf = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
        defer { inBuf.deallocate(); outBuf.deallocate() }
        func run(_ cycles: Int, _ each: ((Int) -> Void)? = nil) {
            for c in 0..<cycles {
                each?(c)
                for f in 0..<n { let v = x(t + f); inBuf[2 * f] = v; inBuf[2 * f + 1] = v }
                let ins = AudioBufferList.allocate(maximumBuffers: 1)
                ins[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: inBuf)
                let outs = AudioBufferList.allocate(maximumBuffers: 1)
                outs[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: outBuf)
                var ts = AudioTimeStamp(); ts.mSampleTime = Double(t); ts.mFlags = .sampleTimeValid
                rt.render(UnsafePointer(ins.unsafePointer), outs.unsafeMutablePointer, &ts)
                for f in 0..<n { ys.append(outBuf[2 * f]) }
                free(ins.unsafeMutablePointer); free(outs.unsafeMutablePointer)
                t += n
            }
        }
        func maxStep(_ a: ArraySlice<Float>) -> Float {
            var m: Float = 0
            var prev = a.first ?? 0
            for v in a.dropFirst() { m = max(m, abs(v - prev)); prev = v }
            return m
        }
        func matchesDelay(_ from: Int, _ count: Int, _ d: Int) -> Float {
            var worst: Float = 0
            for i in from..<(from + count) { worst = max(worst, abs(ys[i] - x(i - d))) }
            return worst
        }
        let base = 300
        rt.delayFrames[0] = base
        run(40)                                                  // 穩定（第一個週期淡入）
        let steady0 = ys.count
        let bound = maxStep(ys[(10 * n)...])                      // 正常播放的最大相鄰差（≈ 2π·1k/48k·0.5 = 0.065）
        check(matchesDelay(steady0 - 4 * n, 4 * n, base) < 1e-6, "基準：輸出 = 輸入延遲 300 frame（快速路徑，逐樣本精確）")
        // 探測 +3.5 ms（168 frame）、0.5 s 斜坡
        let probe = 168.0
        rt.probeRate[0] = probe / (0.5 * sr); rt.probeTarget[0] = probe
        let s0 = ys.count
        run(Int(0.5 * sr) / n + 30)                                // 斜坡 0.5 s ＋ 維持一小段
        let rampStep = maxStep(ys[(s0 - 1)...])
        check(rampStep <= bound * 1.02, "探測斜坡中：相鄰樣本差 ≤ 正常播放的 1.02 倍（沒有跳點、沒有淡出）",
              String(format: "%.4f vs %.4f", rampStep, bound))
        let minAbs = ys[s0...].map { abs($0) }.max() ?? 0
        check(minAbs > 0.49, "斜坡中不淡出（振幅仍 0.5）", String(format: "峰值 %.3f", minAbs))
        check(rt.probeCur[0] == probe && matchesDelay(ys.count - 4 * n, 4 * n, base + Int(probe)) < 1e-6,
              "斜坡走完：停在整數 frame、輸出 = 輸入延遲 300＋168（逐樣本精確）", "cur=\(rt.probeCur[0])")
        // 移除（同樣斜坡）
        rt.probeTarget[0] = 0
        let s1 = ys.count
        run(Int(0.5 * sr) / n + 30)
        check(maxStep(ys[(s1 - 1)...]) <= bound * 1.02 && rt.probeCur[0] == 0 && matchesDelay(ys.count - 4 * n, 4 * n, base) < 1e-6,
              "移除探測：一樣平滑、回到原延遲", String(format: "%.4f", maxStep(ys[(s1 - 1)...])))
        // 延遲修正：+2 ms（96 frame）≤ 0.1 ms/秒 → 20 秒
        let rate = Engine.correctionSlewMsPerSecond / 1000
        rt.corrRate[0] = rate; rt.corrTarget[0] = 96
        var prevCur = rt.corrCur[0], worstPerCycle = 0.0
        let s2 = ys.count
        run(Int(21 * sr) / n) { _ in
            worstPerCycle = max(worstPerCycle, rt.corrCur[0] - prevCur); prevCur = rt.corrCur[0]
        }
        check(worstPerCycle <= rate * Double(n) + 1e-12, "修正斜率 ≤ 0.1 ms/秒（每週期最多 \(String(format: "%.4f", rate * Double(n))) frame）",
              String(format: "最大 %.5f frame／週期", worstPerCycle))
        check(rt.corrCur[0] == 96 && matchesDelay(ys.count - 4 * n, 4 * n, base + 96) < 1e-6, "21 秒後修正完成：輸出 = 輸入延遲 300＋96")
        let theo = Float(2 * amp * sin(Double.pi * hz / sr))       // 理論最大相鄰差（0.06543）
        check(maxStep(ys[(s2 - 1)...]) <= theo * 1.001, "修正全程相鄰樣本差 ≤ 理論值 × 1.001（變速 100 ppm，沒有跳點）",
              String(format: "%.5f vs 理論 %.5f", maxStep(ys[(s2 - 1)...]), theo))
        // plan 延遲改變（淡出 → 換延遲）時，額外延遲直接跳到目標（增益 0 的那一刻）
        rt.probeTarget[0] = 50; rt.probeRate[0] = 1e-6          // 很慢的斜坡
        rt.delayFrames[0] = base + 10
        run(3)
        check(rt.curDelay[0] == base + 10 && rt.probeCur[0] == 50, "plan 延遲換掉時額外延遲一起跳到目標（增益 0，不慢慢走）",
              "curDelay=\(rt.curDelay[0]) probe=\(rt.probeCur[0])")
        // 總延遲不能 < 0：夾住，不讀未來
        rt.delayFrames[0] = 0; rt.corrTarget[0] = -500; rt.corrRate[0] = 1; rt.probeTarget[0] = 0
        run(6)
        check(matchesDelay(ys.count - 2 * n, 2 * n, 0) < 1e-6, "負的額外延遲超過 plan 延遲：夾在 0（不讀還沒寫入的資料）")
        rt.free()
    }

    print("── 10. 延遲修正換算（plan 重算的差額）──")
    do {
        let devs = [PlanDevice(uid: "b", name: "內建", latencyMs: 0, isBuiltIn: true), PlanDevice(uid: "m", name: "MSI", latencyMs: 0.85),
                    PlanDevice(uid: "t", name: "電視", latencyMs: 34.32), PlanDevice(uid: "bt", name: "GLASS5+", latencyMs: 426, requiresMeasurement: true)]
        let p = In_Unison42.plan(devices: devs, mode: .music)
        var off = Engine.correctionOffsets(devices: devs, base: p, corrections: ["bt": 1.4], mode: .music, caps: ModeCaps())
        check(abs((off["b"] ?? 0) - 1.4) < 1e-9 && abs((off["m"] ?? 0) - 1.4) < 1e-9 && abs((off["t"] ?? 0) - 1.4) < 1e-9 && off["bt"] == nil,
              "藍牙晚了 1.4 ms（它是最慢的）→ 三台有線各多等 1.4 ms，藍牙不動", "\(off)")
        off = Engine.correctionOffsets(devices: devs, base: p, corrections: ["m": -0.3], mode: .music, caps: ModeCaps())
        check(abs((off["m"] ?? 0) - 0.3) < 1e-9 && off.count == 1, "MSI 早到 0.3 ms → 只有 MSI 多等 0.3 ms", "\(off)")
        off = Engine.correctionOffsets(devices: devs, base: p, corrections: ["b": 2], mode: .music, caps: ModeCaps())
        check(abs((off["b"] ?? 0) + 2) < 1e-9 && off.count == 1, "參考喇叭晚 2 ms → 只有它少等 2 ms（基準平移不影響別台）", "\(off)")
        check(Engine.correctionOffsets(devices: devs, base: p, corrections: [:], mode: .music, caps: ModeCaps()).isEmpty, "沒有修正 → 空")
    }

    print("── 10b. 節目音錄音的 sampleTime ↔ hostTime（背景監聽對時）──")
    do {
        // engine 48 kHz、host tick = 1 ns：frame t 在 1e9 + t/48000 秒 × 1e9 tick 播出（+50 ppm 時鐘差、±2 µs 抖動）
        var pts: [ProgramClockSample] = []
        var rng: UInt64 = 12345
        for k in 0..<50 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let jit = (Double(rng >> 11) / Double(1 << 53) * 2 - 1) * 2000
            let t = Int64(k * 9600)
            pts.append(ProgramClockSample(sampleTime: t, hostTime: UInt64(1e9 + Double(t) / 48000 * (1 + 50e-6) * 1e9 + jit)))
        }
        let rec = ProgramRecording(startSampleTime: 0, sampleRate: 48000, samples: [], clock: pts, generation: 1, gapFrames: 0,
                                   generationChanged: false, secondsPerHostTick: 1e-9)
        let h = rec.hostTime(forSampleTime: 240_000) ?? 0
        let want = 1e9 + 5 * (1 + 50e-6) * 1e9
        check(abs(h - want) < 1000, "sampleTime 240000 → hostTime（誤差 < 1 µs）", String(format: "%.0f ns", h - want))
        let back = rec.sampleTime(forHostTime: UInt64(want)) ?? 0
        check(abs(back - 240_000) < 0.1, "hostTime → sampleTime（反函數）", String(format: "%.3f frame", back - 240_000))
    }

    print("── 11. 藍牙重連：重新 attach 前先不出聲（Engine.holdUntilCalibrated；engine 不啟動、不碰裝置）──")
    do {
        var c = Config()
        c.devices["bt"] = DeviceConfig(measuredLatencyMs: 426)
        c.devices["new"] = DeviceConfig()
        let e = Engine(config: c, mode: .music)
        e.log = { _ in }
        _ = e.registerExternalOutput(uid: "bt", name: "GLASS5+")
        _ = e.registerExternalOutput(uid: "new", name: "未校正")
        check(e.planEntry(uid: "bt")?.active == true, "量過延遲的藍牙：平常出聲（只剩它一台有延遲值）")
        check(e.holdUntilCalibrated(uid: "bt") && e.planEntry(uid: "bt")?.active == false
              && e.planEntry(uid: "bt")?.reason == PlanEntry.awaitingCalibrationReason, "hold → 不出聲（理由：等待重新校正）")
        check(!e.holdUntilCalibrated(uid: "new") && e.reconnectHolds == ["bt"], "沒量過延遲的不 hold（本來就不出聲）")
        e.releaseReconnectHolds(["bt"])
        check(e.planEntry(uid: "bt")?.active == true && e.reconnectHolds.isEmpty, "release → 回到設定的 holds（AppState 接手）")
        // 探測偏移／修正：engine 沒在跑時可以設、不會崩潰；stop 後探測作廢
        check(e.setProbeOffset(uid: "bt", ms: 3.5) && e.probeOffsets["bt"] == 3.5, "探測偏移記下（engine 沒在跑）")
        check(!e.setProbeOffset(uid: "nope", ms: 3.5), "不存在的 uid → false")
        e.setLatencyCorrection(uid: "bt", ms: 1.4)
        check(e.latencyCorrections["bt"] == 1.4, "延遲修正記下")
        var c2 = c; c2.devices["bt"]?.measuredLatencyMs = 430
        e.applyConfig(c2)
        check(e.latencyCorrections.isEmpty, "重新校正（measuredLatencyMs 改變）→ 修正自動清掉")
        e.stop()
        check(e.probeOffsets.isEmpty, "engine stop → 探測偏移作廢（重新啟動不會帶著它）")
    }

    print(fail == 0 ? "✓ engine 自測全部通過" : "✗ \(fail) 項失敗")
    return fail == 0 ? 0 : 1
}
