// MonitorCapture.swift — 背景監聽用的 app 行程內麥克風擷取（第 B 輪；不經校正子行程）
//
// 做法沿用 Calibrate.swift 的 MicRecorder：直接對校正麥克風（C270）開**輸入** IOProc、預先配置緩衝、只錄第 1 聲道；
// 另外每個 IO 週期記一筆 (frame, hostTime)，讓監聽演算法把麥克風時間對到 engine 的節目音時間。
//   * 錄音只在記憶體（MonitorMicCapture 釋放就沒了），不寫檔、不存 WAV。
//   * 絕不開藍牙麥克風（會把藍牙喇叭切到 HFP）：藍牙裝置 start() 直接回 kAudioHardwareIllegalOperationError。
//   * 麥克風被其他行程占用（DeviceIsRunningSomewhere，且不是我們自己開的）→ 呼叫端先用 isRunningSomewhere 檢查、跳過本輪。
//   * 開著期間系統選單列會亮橘色麥克風燈（Kang 定案接受）；10 秒後關閉。
// 即時規則：IOProc 內不配置、不上鎖、不 print、不呼叫 Core Audio 屬性 API；只碰預先配置的指標。
import CoreAudio
import Foundation

/// 一個 IO 週期的對時點：mic 樣本 frame 這一格在 hostTime 被擷取（inTime.mHostTime）
struct MicAnchor: Equatable {
    let frame: Int
    let hostTime: UInt64
}

/// IOProc 唯一會碰的資料（值型別、全是預先配置的指標）
struct MonitorMicShared {
    let buf: UnsafeMutablePointer<Float>
    let cap: Int
    let pos: UnsafeMutablePointer<Int>
    let anchorFrame: UnsafeMutablePointer<Int>
    let anchorHost: UnsafeMutablePointer<UInt64>
    let anchorCap: Int
    let anchorCount: UnsafeMutablePointer<Int>
    let gaps: UnsafeMutablePointer<Int>
    let nextSampleTime: UnsafeMutablePointer<Double>
    let cycles: UnsafeMutablePointer<Int64>
    let peak: UnsafeMutablePointer<Float>

    static func make(frames: Int, anchors: Int) -> MonitorMicShared {
        MonitorMicShared(buf: RTShared.alloc(frames, Float(0)), cap: frames, pos: RTShared.alloc(1, 0),
                         anchorFrame: RTShared.alloc(anchors, 0), anchorHost: RTShared.alloc(anchors, UInt64(0)), anchorCap: anchors,
                         anchorCount: RTShared.alloc(1, 0), gaps: RTShared.alloc(1, 0), nextSampleTime: RTShared.alloc(1, -1.0),
                         cycles: RTShared.alloc(1, Int64(0)), peak: RTShared.alloc(1, Float(0)))
    }

    /// 只在 IOProc 已銷毀後呼叫
    func free() {
        buf.deallocate(); pos.deallocate(); anchorFrame.deallocate(); anchorHost.deallocate(); anchorCount.deallocate()
        gaps.deallocate(); nextSampleTime.deallocate(); cycles.deallocate(); peak.deallocate()
    }

    /// 即時執行緒：不配置、不上鎖、不 print、不呼叫 Core Audio 屬性 API
    func capture(_ inData: UnsafePointer<AudioBufferList>, _ inTime: UnsafePointer<AudioTimeStamp>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard abl.count > 0, let raw = abl[0].mData else { return }
        let ch = max(1, Int(abl[0].mNumberChannels))
        let n = Int(abl[0].mDataByteSize) / 4 / ch
        guard n > 0 else { return }
        cycles.pointee &+= 1
        let flags = inTime.pointee.mFlags
        if flags.contains(.sampleTimeValid) {
            let st = inTime.pointee.mSampleTime
            let exp = nextSampleTime.pointee
            if exp >= 0 && abs(st - exp) > 0.5 { gaps.pointee &+= 1 }
            nextSampleTime.pointee = st + Double(n)
        }
        let p = pos.pointee
        let m = min(n, cap - p)
        guard m > 0 else { return }
        if flags.contains(.hostTimeValid), inTime.pointee.mHostTime != 0 {
            let k = anchorCount.pointee
            if k < anchorCap {
                anchorFrame[k] = p
                anchorHost[k] = inTime.pointee.mHostTime
                OSMemoryBarrier()
                anchorCount.pointee = k + 1
            }
        }
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

/// 擷取結果（全部在記憶體）
struct MicCaptureResult {
    let samples: [Float]
    let sampleRate: Double
    let anchors: [MicAnchor]
    /// 輸入 sampleTime 跳號次數（HAL 丟週期）
    let gaps: Int
    let peak: Float
    let deviceName: String
}

/// app 行程內的麥克風擷取（背景監聽一輪 10 秒）
final class MonitorMicCapture {
    let device: AudioDevice
    let rate: Double
    private let sh: MonitorMicShared
    private var procID: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var stopped = false
    /// Stop／Destroy 失敗或裝置已消失（拔掉）：IOProc 可能還在跑最後一個週期 → 緩衝延後釋放（同 BluetoothOut 的做法）
    private var deferFree = false

    init(device: AudioDevice, seconds: Double) {
        self.device = device
        rate = device.nominalSampleRate > 0 ? device.nominalSampleRate : 48000
        let frames = max(1, Int(seconds * rate))
        // 每個 IO 週期一筆對時點：最小 buffer 約 32 frame 也夠用
        sh = MonitorMicShared.make(frames: frames, anchors: frames / 32 + 64)
    }

    deinit {
        stop()
        if deferFree {
            let shared = sh
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { shared.free() }
        } else {
            sh.free()
        }
    }

    /// 這支麥克風有沒有任何行程在用（kAudioDevicePropertyDeviceIsRunningSomewhere）。
    /// 我們平常不開麥克風，所以開始擷取前是 true = 被其他 App 占用
    static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        (CA.get(id, kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 0) != 0
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return procID != nil }
    var frames: Int { sh.pos.pointee }

    /// 開始擷取；藍牙裝置一律拒絕（kAudioHardwareIllegalOperationError）
    func start() -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard procID == nil, !stopped else { return procID == nil ? kAudioHardwareIllegalOperationError : noErr }
        if device.kind.isBluetooth { return kAudioHardwareIllegalOperationError }
        let shared = sh
        var proc: AudioDeviceIOProcID?
        let s = AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, nil) { _, inData, inTime, _, _ in
            shared.capture(inData, inTime)
        }
        guard s == noErr, let proc else { return s }
        let ss = AudioDeviceStart(device.id, proc)
        guard ss == noErr else { AudioDeviceDestroyIOProcID(device.id, proc); return ss }
        procID = proc
        return noErr
    }

    /// 可重複呼叫；停了就不能再 start（一個物件一輪）
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        guard let p = procID else { return }
        let alive = (CA.u32(device.id, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
        let s1 = AudioDeviceStop(device.id, p)
        let s2 = AudioDeviceDestroyIOProcID(device.id, p)
        procID = nil
        if !alive || s1 != noErr || s2 != noErr { deferFree = true }
    }

    /// 已錄的樣本與對時點拷一份（停了之後呼叫）
    func result() -> MicCaptureResult {
        let n = sh.pos.pointee
        let k = sh.anchorCount.pointee
        OSMemoryBarrier()
        let samples = Array(UnsafeBufferPointer(start: sh.buf, count: n))
        let anchors = (0..<k).map { MicAnchor(frame: sh.anchorFrame[$0], hostTime: sh.anchorHost[$0]) }
        return MicCaptureResult(samples: samples, sampleRate: rate, anchors: anchors, gaps: sh.gaps.pointee, peak: sh.peak.pointee,
                                deviceName: device.name)
    }
}
