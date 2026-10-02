// BTToneTest.swift — `In_Unison42 bt-tone-test <raw|raw-tap|btout> [--amp a] [--seconds s]`（診斷用）
//   找「BluetoothOut 渲染有峰值、但藍牙喇叭沒聲音」的根因：同一個行程裡依序試
//     raw      直接對藍牙輸出裝置建 IOProc 播 1 kHz 正弦（不開 tap、不開 engine）
//     raw-tap  先啟動 Engine（正常模式全域 tap、排除自己），再同上
//     btout    Engine＋BluetoothOutManager（只輸出路徑）＋solo 藍牙；afplay 播 1 kHz 正弦經 tap → ring → 藍牙
//   同時用校正麥克風（C270）錄音，回報 1 kHz 窄頻能量比播放前高幾 dB。
//   要用 app 身分跑（麥克風／系統音訊錄製權限），且選單列 app 不能在跑（兩個 tap 會互相靜音）。
//   不改音量、不改預設輸出、不開藍牙輸入。
import AudioToolbox
import CoreAudio
import Foundation

#if IU42_DIAG  // 診斷用：只編進 debug；發行版沒有這個指令

private final class ToneState: @unchecked Sendable {
    var phase = 0.0
    let amp: Double
    let inc: Double
    var on = false
    init(amp: Double, rate: Double) { self.amp = amp; inc = 2 * Double.pi * 1000 / rate }
}

func cmdBTToneTest(_ args: [String]) -> Int32 {
    if args.first == "gate" { return btGateTest(Array(args.dropFirst())) }
    guard let mode = args.first, ["raw", "raw-tap", "btout"].contains(mode) else {
        print("用法：bt-tone-test <raw|raw-tap|btout> [--amp a] [--seconds s]"); return 2
    }
    var amp = 0.1, secs = 2.0
    var i = 1
    while i + 1 < args.count {
        if args[i] == "--amp", let v = Double(args[i + 1]) { amp = min(max(v, 0), 0.3) }
        if args[i] == "--seconds", let v = Double(args[i + 1]) { secs = min(max(v, 0.5), 5) }
        i += 2
    }
    guard let bt = Devices.bluetoothOutputs().first else { print("✗ 沒有藍牙輸出"); return 1 }
    let snap = SystemAudioSnapshot.capture()
    print("系統：\(snap)；藍牙：\(bt.name) id=\(bt.id) \(Int(bt.nominalSampleRate)) Hz；me process object=\(Devices.processObject())")
    guard case .success(let mic) = resolveCalibrationMic(query: "auto", config: Config.load()) else { print("✗ 找不到麥克風"); return 1 }
    let rec = MicRecorder(device: mic, seconds: secs + 6)
    guard rec.start() == noErr else { print("✗ 麥克風開啟失敗"); return 1 }
    defer { rec.stop() }
    let t0 = Date()
    while rec.frames < Int(0.5 * rec.rate), Date().timeIntervalSince(t0) < 3 { usleep(5000) }

    var engine: Engine? = nil
    var mgr: BluetoothOutManager? = nil
    var proc: AudioDeviceIOProcID?
    var player: Process? = nil
    var wavURL: URL? = nil
    let st = ToneState(amp: amp, rate: bt.nominalSampleRate)
    defer {
        if let p = proc { AudioDeviceStop(bt.id, p); AudioDeviceDestroyIOProcID(bt.id, p) }
        mgr?.stop()
        engine?.stop()
        if let p = player, p.isRunning { p.terminate() }
        if let u = wavURL { try? FileManager.default.removeItem(at: u) }   // 自己產生的暫存 WAV：直接刪
        snap.restore()
    }
    if mode != "raw" {
        let e = Engine(config: Config.load(), mode: .music)
        e.log = { print("  [engine] \($0)") }
        if mode == "btout" {
            e.allowUncalibratedExternal = true
            e.calibrationFixedGain = 1
            let m = BluetoothOutManager(engine: e)
            m.watchDeviceList = false
            print(m.attach(deviceID: bt.id) ? "BluetoothOut attach ✓" : "✗ BluetoothOut attach 失敗：\(m.errors)")
            mgr = m
        }
        do { try e.start() } catch { print("✗ engine 啟動失敗：\(error)"); return 1 }
        engine = e
        let c0 = e.ioCycles
        while e.ioCycles < c0 + 10, Date().timeIntervalSince(t0) < 6 { usleep(5000) }
        print("engine 運轉 io=\(e.ioCycles)；tap 外排除：me=\(Devices.processObject())")
    }
    if mode == "raw" || mode == "raw-tap" {
        let s = AudioDeviceCreateIOProcIDWithBlock(&proc, bt.id, nil) { _, _, _, outData, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outData)
            var n = 0
            for b in 0..<abl.count where abl[b].mNumberChannels > 0 { n = max(n, Int(abl[b].mDataByteSize) / 4 / Int(abl[b].mNumberChannels)) }
            for f in 0..<n {
                let v = st.on ? Float(st.amp * sin(st.phase)) : 0
                st.phase += st.inc
                for b in 0..<abl.count {
                    let nc = Int(abl[b].mNumberChannels)
                    if let d = abl[b].mData?.assumingMemoryBound(to: Float.self), Int(abl[b].mDataByteSize) >= (f + 1) * nc * 4 {
                        for c in 0..<nc { d[f * nc + c] = v }
                    }
                }
            }
        }
        guard s == noErr, let p = proc else { print("✗ IOProc 建立失敗 \(s)"); return 1 }
        print("IOProc 建立 ✓；AudioDeviceStart=\(AudioDeviceStart(bt.id, p))；buffers=\(CA.ids(bt.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).count) stream")
    }
    while Date().timeIntervalSince(t0) < 2.0 { usleep(5000) }
    let onFrame = rec.frames
    if mode == "btout" {
        engine?.setSolo(Engine.soloValue(externalSlot: 0))
        let rate = 48000.0
        let n = Int(secs * rate)
        let w = (0..<n).map { k -> Float in
            let fade = min(1.0, Double(min(k, n - 1 - k)) / (0.01 * rate))
            return Float(amp * fade * sin(2 * Double.pi * 1000 * Double(k) / rate))
        }
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("In_Unison42-bttone-\(getpid()).wav")
        try? ppWriteWav(w, rate: Int(rate), to: u)
        wavURL = u
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); p.arguments = [u.path]
        try? p.run(); player = p
    } else {
        st.on = true
    }
    while Date().timeIntervalSince(t0) < 2.0 + secs + (mode == "btout" ? 1.0 : 0) { usleep(5000) }
    st.on = false
    let offFrame = rec.frames
    usleep(300_000)
    if let m = mgr { for (_, o) in m.outputs { print("  BluetoothOut：\(o.stats.description)") } }
    let x = rec.samples()
    let r = rec.rate
    // 1 kHz 窄頻（Goertzel，50 ms 窗）
    func tone(_ a: Int, _ b: Int) -> Double {
        guard b > a, a >= 0, b <= x.count else { return -200 }
        let w = 2 * Double.pi * 1000 / r
        var best = -200.0
        var k = a
        let win = Int(0.05 * r)
        while k + win <= b {
            var s1 = 0.0, s2 = 0.0
            for j in k..<(k + win) { let s0 = Double(x[j]) + 2 * cos(w) * s1 - s2; s2 = s1; s1 = s0 }
            let p = s1 * s1 + s2 * s2 - 2 * cos(w) * s1 * s2
            best = max(best, 10 * log10(max(p / Double(win * win), 1e-20)))
            k += win
        }
        return best
    }
    let pre = tone(Int(0.6 * r), onFrame)
    let dur = tone(onFrame, min(x.count, offFrame))
    print(String(format: "RESULT mode=%@ amp=%.2f：1 kHz 窄頻 播放前最大 %.1f dB、播放中最大 %.1f dB → 高 %.1f dB", mode, amp, pre, dur, dur - pre))
    return 0
}

/// `bt-tone-test gate [--pilot db]`：直接對藍牙裝置建 IOProc，每 2 秒播一個 80 ms 粉紅脈衝（×5，其他時間靜音或只有低頻 pilot），
/// 用麥克風量每個脈衝在 1–4 kHz 的匹配濾波比安靜段高幾 dB——檢查耳機是不是「靜音一陣子就關功放、短脈衝被吃掉」
private final class GateState: @unchecked Sendable {
    var pos = 0
    var pilotPhase = 0.0
    var pilotAmp: Double = 0
    var burst: [Float] = []
    var period = 0
    var count = 0
    var startAt = -1
}

private func btGateTest(_ args: [String]) -> Int32 {
    var pilotDb: Double? = nil
    if let i = args.firstIndex(of: "--pilot"), i + 1 < args.count { pilotDb = Double(args[i + 1]) }
    guard let bt = Devices.bluetoothOutputs().first else { print("✗ 沒有藍牙輸出"); return 1 }
    let snap = SystemAudioSnapshot.capture()
    defer { snap.restore() }
    guard case .success(let mic) = resolveCalibrationMic(query: "auto", config: Config.load()) else { print("✗ 找不到麥克風"); return 1 }
    let rate = bt.nominalSampleRate
    let g = GateState()
    g.burst = ppPinkBurst(rate: rate).map { $0 * Float(pow(10, -8.0 / 20)) }   // 同校正：RMS −22 dBFS × −8 dB
    g.period = Int(2 * rate); g.count = 5
    g.pilotAmp = pilotDb.map { pow(10, $0 / 20) } ?? 0
    let rec = MicRecorder(device: mic, seconds: 16)
    guard rec.start() == noErr else { print("✗ 麥克風開啟失敗"); return 1 }
    defer { rec.stop() }
    var proc: AudioDeviceIOProcID?
    let inc = 2 * Double.pi * 150 / rate
    let s = AudioDeviceCreateIOProcIDWithBlock(&proc, bt.id, nil) { _, _, _, outData, _ in
        let abl = UnsafeMutableAudioBufferListPointer(outData)
        var n = 0
        for b in 0..<abl.count where abl[b].mNumberChannels > 0 { n = max(n, Int(abl[b].mDataByteSize) / 4 / Int(abl[b].mNumberChannels)) }
        for f in 0..<n {
            var v = Float(g.pilotAmp * sin(g.pilotPhase)); g.pilotPhase += inc
            if g.startAt >= 0 {
                let t = g.pos - g.startAt
                if t >= 0 && t < g.period * g.count { let k = t % g.period; if k < g.burst.count { v += g.burst[k] } }
            }
            g.pos += 1
            for b in 0..<abl.count {
                let nc = Int(abl[b].mNumberChannels)
                if let d = abl[b].mData?.assumingMemoryBound(to: Float.self), Int(abl[b].mDataByteSize) >= (f + 1) * nc * 4 { for c in 0..<nc { d[f * nc + c] = v } }
            }
        }
    }
    guard s == noErr, let p = proc else { print("✗ IOProc 失敗"); return 1 }
    AudioDeviceStart(bt.id, p)
    defer { AudioDeviceStop(bt.id, p); AudioDeviceDestroyIOProcID(bt.id, p) }
    print("gate 測試：pilot \(pilotDb.map { String(format: "150 Hz %.0f dBFS", $0) } ?? "無")；先 3 秒只有 pilot／靜音，再每 2 秒一個 80 ms 脈衝 ×5")
    usleep(3_000_000)
    let micAt = rec.frames
    g.startAt = g.pos
    usleep(11_000_000)
    let x = rec.samples()
    let r = rec.rate
    let tmpl = ppPinkBurst(rate: r)
    let gcc = PPGcc(template: tmpl, searchLength: Int(1.0 * r), rate: r, band: (PPParams.pinkLo, PPParams.pinkHi), envelope: true)
    var line: [String] = []
    for k in 0..<5 {
        let a = micAt + Int(Double(k) * 2 * r)
        guard a + gcc.n + Int(r) <= x.count else { break }
        let seg = Array(x[a..<(a + gcc.n)]), q = Array(x[(a + Int(r))..<(a + Int(r) + gcc.n)])
        let w = gcc.weights(for: seg)
        let pk = gcc.locate(seg, maxLag: Int(0.9 * r), weights: w), qk = gcc.locate(q, maxLag: Int(0.9 * r), weights: w)
        line.append(String(format: "#%d %.1f dB @%.0f ms", k + 1, 20 * log10(pk.peak / max(qk.peak, 1e-12)), pk.pos / r * 1000))
    }
    print("RESULT gate pilot=\(pilotDb.map { String($0) } ?? "none")：" + line.joined(separator: "、"))
    return 0
}
#endif  // IU42_DIAG
