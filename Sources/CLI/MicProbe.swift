// MicProbe.swift — `In_Unison42 mic-probe`：錄麥克風，在第 1 秒觸發一個聲音，回報比底噪高幾 dB（驗收用）
//
//   --burst（預設）：afplay 播 0.08 s 帶通雜訊脈衝 ×3（一般行程 → 走預設輸出；若 In_Unison42 在跑則經 tap 送到所有出聲的喇叭）
//   --beep：osascript -e 'beep'（系統提示音：systemsoundserverd 播放，走「系統提示音輸出」）
//   --none：只錄底噪
//   --mic <uid|名稱|auto>、--seconds <s>（預設 4）
// 診斷用：只編進 debug（-D IU42_DIAG）；發行版沒有這個指令。
// 不改音量、不改預設輸出。需要麥克風權限：用 app 身分跑（open -W -n --stdout f build/In_Unison42.app --args mic-probe …）。
import Accelerate
import Foundation

#if IU42_DIAG

func cmdMicProbe(_ args: [String]) -> Int32 {
    var micQuery: String? = nil
    var seconds = 4.0
    var trigger = "burst"
    var i = 0
    while i < args.count {
        let a = args[i]; i += 1
        switch a {
        case "--mic": guard i < args.count else { return 2 }; micQuery = args[i]; i += 1
        case "--seconds": guard i < args.count, let s = Double(args[i]) else { return 2 }; seconds = max(2, s); i += 1
        case "--burst": trigger = "burst"
        case "--beep": trigger = "beep"
        case "--none": trigger = "none"
        default: print("用法：In_Unison42 mic-probe [--mic q] [--seconds s] [--burst|--beep|--none]"); return 2
        }
    }
    let mic: AudioDevice
    switch resolveCalibrationMic(query: micQuery, config: Config.load()) {
    case .success(let d): mic = d
    case .failure(let e): print("✗ \(e.message)"); return 1
    }
    print("麥克風：\(mic.name)；觸發：\(trigger)；系統：\(SystemAudioSnapshot.capture())")
    let rec = MicRecorder(device: mic, seconds: seconds + 2)
    let st = rec.start()
    guard st == noErr else { print("✗ 麥克風開啟失敗 status=\(st)（麥克風權限？）"); return 1 }
    let t0 = Date()
    while rec.frames < Int(0.3 * rec.rate), Date().timeIntervalSince(t0) < 3 { usleep(5000) }
    guard rec.frames > 0 else { rec.stop(); print("✗ 麥克風沒有送資料進來（權限未授與？）"); return 1 }
    while Date().timeIntervalSince(t0) < 1.0 { usleep(5000) }
    let trigFrame = rec.frames
    var wavURL: URL?
    switch trigger {
    case "burst":
        let rate = 48000.0
        let b = ppBurst(rate: rate)
        var w = [Float](repeating: 0, count: Int(0.2 * rate))
        for k in 0..<3 { w += b; w += [Float](repeating: 0, count: Int(0.4 * rate)); _ = k }
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("In_Unison42-probe-\(getpid()).wav")
        do { try ppWriteWav(w, rate: Int(rate), to: u) } catch { print("✗ 寫 WAV 失敗"); rec.stop(); return 1 }
        wavURL = u
        _ = shell("/usr/bin/afplay", [u.path])
    case "beep":
        _ = shell("/usr/bin/osascript", ["-e", "beep"])
    default: break
    }
    while Date().timeIntervalSince(t0) < seconds { usleep(5000) }
    rec.stop()
    // 自己產生的暫存 WAV：直接刪（不塞垃圾桶）
    if let u = wavURL { try? FileManager.default.removeItem(at: u) }
    let x = rec.samples()
    let rate = rec.rate
    let win = Int(0.05 * rate)
    func rmsDb(_ a: Int, _ b: Int) -> Double {
        guard b > a else { return -200 }
        var e = 0.0
        for k in a..<b { e += Double(x[k]) * Double(x[k]) }
        return 10 * log10(max(e / Double(b - a), 1e-20))
    }
    let noiseStart = Int(0.3 * rate)
    let noise = rmsDb(noiseStart, min(trigFrame, x.count))
    var best = -200.0, bestAt = 0
    var k = trigFrame
    while k + win <= x.count {
        let v = rmsDb(k, k + win)
        if v > best { best = v; bestAt = k }
        k += win / 2
    }
    print(String(format: "底噪（觸發前）%.1f dBFS；觸發後最大 50 ms 窗 %.1f dBFS（觸發後 %.2f 秒）→ 比底噪高 %.1f dB；錄到 %.2f 秒、漏格 %d",
                 noise, best, Double(bestAt - trigFrame) / rate, best - noise, Double(x.count) / rate, rec.gaps))
    print("PROBE_DB_ABOVE_NOISE=\(String(format: "%.1f", best - noise))")
    if trigger == "burst" {
        // 匹配濾波（和脈衝樣板互相關）：音樂等不相關的聲音被壓掉約 36 dB，房間有音樂也分得出脈衝
        let tmpl = ppBurst(rate: rate)
        var tn: Float = 0
        vDSP_svesq(tmpl, 1, &tn, vDSP_Length(tmpl.count))
        func mf(_ a: Int, _ b: Int) -> Double {
            let lags = b - a - tmpl.count
            guard a >= 0, b <= x.count, lags > 0 else { return -200 }
            var out = [Float](repeating: 0, count: lags)
            vDSP_conv(Array(x[a..<b]), 1, tmpl, 1, &out, 1, vDSP_Length(lags), vDSP_Length(tmpl.count))
            var m: Float = 0
            vDSP_maxmgv(out, 1, &m, vDSP_Length(lags))
            return 20 * log10(max(Double(m) / Double(max(tn.squareRoot(), 1e-12)), 1e-12))
        }
        let pre = mf(Int(0.2 * rate), trigFrame)
        let post = mf(trigFrame, min(x.count, trigFrame + Int(2.5 * rate)))
        print(String(format: "匹配濾波：觸發前 %.1f dB、觸發後 %.1f dB → 差 %.1f dB", pre, post, post - pre))
        print("PROBE_MF_DB=\(String(format: "%.1f", post - pre))")
    }
    return 0
}
#endif  // IU42_DIAG
