// MonitorEstimatorAdapter.swift — 把 Sources/Monitor 的 DriftEstimator（另一位實作者）接到背景監聽的 DriftEstimating 介面（第 B 輪）
//
// 轉換：
//   * 麥克風對時點 MicAnchor(frame, hostTime) → MonitorClockPoint(sample, hostSeconds)
//   * 節目音 ProgramRecording（單聲道、startSampleTime、(sampleTime, hostTime) 對時點）→ program／programStart／programClock
//   * 探測 DriftProbe（host 時間）→ MonitorProbe.fromOutputTimes（engine sampleTime；用節目音對時直線把 host 時間換成 sampleTime）
//     這台目前的補償 = plan 延遲＋已套用的修正額外延遲＋路徑固定延遲（藍牙 safety）
//   * 結果：skip → 整輪不可採信；每台 trusted → errorMs（正 = 晚到）、信心 1；不可採信 → errorMs nil，
//     「量不到」（looksMissing：偏移太大／沒聲音）才累計到「需要重新校正」，模稜兩可／不一致不累計
// makeDriftEstimator()（MonitorScheduler.swift）回傳這個實作（第 B 輪整合，2026-09-29）。
import Foundation

struct ProgramDriftEstimator: DriftEstimating {
    var params = MonitorParams()

    func estimate(_ input: DriftCaptureInput) -> DriftEstimate {
        let spt = input.secondsPerHostTick
        let rec = input.program
        let rate = rec.sampleRate
        var probes: [MonitorProbe] = []
        for p in input.probes {
            guard let idx = input.devices.firstIndex(where: { $0.uid == p.uid }),
                  let setAt = rec.sampleTime(forHostTime: p.rampStartHost), let clearAt = rec.sampleTime(forHostTime: p.holdEndHost) else { continue }
            let d = input.devices[idx]
            let baseMs = d.planDelayMs + d.appliedExtraDelayMs + d.pathDelayMs
            probes.append(MonitorProbe.fromOutputTimes(device: idx, setAt: Int64(setAt.rounded()), clearAt: Int64(clearAt.rounded()),
                                                       offsetMs: p.offsetMs,
                                                       rampSeconds: Double(p.holdStartHost &- p.rampStartHost) * spt,
                                                       engineRate: rate, baseDelayFrames: Int((baseMs / 1000 * rate).rounded())))
        }
        var prm = params
        prm.bandLo = input.bandLowHz
        prm.bandHi = input.bandHighHz
        let cap = MonitorCapture(mic: input.mic, micRate: input.micRate,
                                 micClock: input.micAnchors.map { MonitorClockPoint(sample: Double($0.frame), hostSeconds: Double($0.hostTime) * spt) },
                                 program: rec.samples, programRate: rate, programStart: rec.startSampleTime,
                                 programClock: rec.clock.map { MonitorClockPoint(sample: Double($0.sampleTime), hostSeconds: Double($0.hostTime) * spt) },
                                 deviceCount: input.devices.count, probes: probes,
                                 // 「準時」的定義 = 有線裝置（同 clock domain、延遲線）：同一輪也探測有線時，有線的參考不含藍牙
                                 referenceDevices: input.devices.indices.filter { !input.devices[$0].isBluetooth })
        let res = DriftEstimator.analyze(cap, params: prm)
        #if IU42_DIAG
        AppLog.line(Self.rampTransientReport(input))
        #endif
        // 分析摘要（只有統計量，沒有錄音內容）寫 log：實機除錯用。裝置編號 → 名稱
        let names = input.devices.enumerated().map { "\($0.offset)=\($0.element.name)" }.joined(separator: " ")
        AppLog.line("背景監聽分析（\(names)）：\n    " + res.summary.replacingOccurrences(of: "\n", with: "\n    "))
        if let k = res.skip { return DriftEstimate(usable: false, reason: k.rawValue, devices: []) }
        let devs: [DriftDeviceEstimate] = res.devices.filter(\.probed).compactMap { e in
            guard e.device >= 0, e.device < input.devices.count else { return nil }
            let uid = input.devices[e.device].uid
            if e.trusted, let err = e.errorMs {
                return DriftDeviceEstimate(uid: uid, errorMs: err, confidence: 1, note: String(format: "SNR %.1f dB", e.snrDb ?? 0))
            }
            return DriftDeviceEstimate(uid: uid, errorMs: nil, confidence: 0, note: e.issues.map(\.rawValue).joined(separator: "、"),
                                       countsAsMissing: e.looksMissing)
        }
        let c = res.cluster.map { String(format: "群集 %.1f ms（SNR %.1f dB）", $0.lagMs, $0.snrDb) } ?? ""
        return DriftEstimate(usable: true, reason: c, devices: devs)
    }

    #if IU42_DIAG
    /// 【除錯版・實機驗收 M3】探測斜坡有沒有造成突波：麥克風一階差分（強調高頻／喀聲）每 5 ms 一塊的峰值，
    /// 斜坡聽到的時段（斜坡開始／結束 + 該台延遲 + 30 ms，前 80 ms、後斜坡長 + 150 ms）最大值 vs 其他時段的 99 百分位（dB）。
    /// 只算統計量、不保留錄音。鼓點本身也有突波，所以看的是「斜坡時段比平常的 1% 最大值還高多少」
    static func rampTransientReport(_ input: DriftCaptureInput) -> String {
        let mic = input.mic, sr = input.micRate, spt = input.secondsPerHostTick
        guard mic.count > 1000, input.micAnchors.count >= 2, let a0 = input.micAnchors.first, let a1 = input.micAnchors.last,
              a1.hostTime > a0.hostTime else { return "M3 突波檢查：資料不足" }
        let fps = Double(a1.frame - a0.frame) / (Double(a1.hostTime - a0.hostTime) * spt)
        func frame(_ h: UInt64) -> Int { a0.frame + Int(((Double(h) - Double(a0.hostTime)) * spt * fps).rounded()) }
        let blk = max(1, Int(0.005 * sr))
        var peaks: [Float] = []
        var i = 1
        while i + blk <= mic.count {
            var m: Float = 0
            for k in i..<(i + blk) { m = max(m, abs(mic[k] - mic[k - 1])) }
            peaks.append(m); i += blk
        }
        var inRamp = [Bool](repeating: false, count: peaks.count)
        var windows = 0
        for p in input.probes {
            let lat = (input.devices.first { $0.uid == p.uid }?.measuredLatencyMs ?? 0) + 30
            for (st, en) in [(p.rampStartHost, p.holdStartHost), (p.holdEndHost, p.rampEndHost)] {
                let f0 = frame(st) + Int((lat - 80) / 1000 * sr), f1 = frame(en) + Int((lat + 150) / 1000 * sr)
                let b0 = max(0, f0 / blk), b1 = min(peaks.count - 1, f1 / blk)
                if b0 <= b1 { for b in b0...b1 { inRamp[b] = true }; windows += 1 }
            }
        }
        let other = peaks.indices.filter { !inRamp[$0] }.map { peaks[$0] }.sorted()
        let ramp = peaks.indices.filter { inRamp[$0] }.map { peaks[$0] }
        guard !other.isEmpty, let rmax = ramp.max() else { return "M3 突波檢查：沒有斜坡時段" }
        let p99 = other[min(other.count - 1, Int(0.99 * Double(other.count)))], omax = other.last!
        func db(_ x: Float) -> Double { 20 * log10(Double(max(x, 1e-9))) }
        return String(format: "M3 突波檢查（麥克風一階差分、5 ms 塊）：斜坡時段 %d 段、最大 %.1f dBFS；其他時段 99 百分位 %.1f dBFS、最大 %.1f dBFS → 斜坡最大比 99 百分位 %+.1f dB",
                      windows, db(rmax), db(p99), db(omax), db(rmax) - db(p99))
    }
    #endif
}
