// MonitorSelfTest.swift — 背景監聽演算法的離線自測（不出聲、不開麥克風、不碰 CoreAudio）。只編進除錯版（-D IU42_DIAG）。
//
//   In_Unison42 monitor-selftest [--quick] [--trials N] [--trial-offset K] [-v] [--set 參數=值 …]
//       全套（約 17 秒，-O、10 核）／--quick（約 7 秒）：準確度、+3／+4 ms 探測、長音不給錯值、誤報率、時鐘、跳過條件、決策器
//   In_Unison42 monitor-sim [--music beat|vocal|strings|organ] [--plan bt|bt2|pair|all|w2] [--offset 3,4] [--err 1.5 | --errs 0,0,0,1.5]
//                           [--seed 1] [--random] [--noise -25] [--white -10] [--bt-gain 10] [--ppm 40] [--no-clock]
//                           [--mic-rate 48000] [--trial K] [--curves] [--set 參數=值 …]
//       單次模擬、印完整結果；--curves 畫出每條包絡曲線（群集 ±15 ms）；--trial K 重現誤報試驗第 K 次
//
// 模擬：合成「音樂式」節目音（beat：鼓點＋貝斯＋人聲式諧波；vocal：只有人聲；strings：弦樂和弦長音（有顫音）；
//   organ：風琴長音（無顫音、純線譜，最難））→ 四台模擬喇叭（內建、MSI、電視、藍牙；各自的頻率響應、電視色散 ±0.3 ms、
//   4.1 ± 0.3 ms 強反射 0.4–0.7、殘響 RT60 0.3 s、藍牙自己漂 ±0.02 ms/s）→ 麥克風（另一個時鐘 ±50 ppm、時間戳抖動 ±20 µs、
//   戳記偏移 3 ms、訊號 −24 dBFS）＋室內雜訊（−25 dB、以低頻為主的棕噪＋白噪底）。
//   探測偏移照 Engine 的方式（0.5 s 線性斜坡、變速、不淡出）加在到達時間上；呼叫端換算探測內容時的補償誤差 ±6 ms。
//   「真實誤差」= 模擬的純延遲差（EQ 是零相位；電視色散在 1–4 kHz 平均為 0）。
#if IU42_DIAG
import Accelerate
import Foundation

// MARK: - 亂數

struct MonRng {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func uni() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * uni() }
    mutating func gauss() -> Double {
        let u1 = max(uni(), 1e-300), u2 = uni()
        return sqrt(-2 * log(u1)) * cos(2 * Double.pi * u2)
    }
}

// MARK: - 音樂合成

/// beat：鼓＋貝斯＋人聲；vocal：只有人聲；strings：弦樂和弦長音（有顫音）；organ：風琴式長音（完全沒有顫音、純諧波線譜，最難）
enum MonMusic: String, CaseIterable { case beat, vocal, strings, organ }

/// 單聲道、RMS −20 dBFS
func monSynthMusic(_ kind: MonMusic, seconds: Double, rate: Double, seed: UInt64) -> [Float] {
    var rng = MonRng(seed &+ 0x5151)
    let n = Int(seconds * rate)
    var y = [Double](repeating: 0, count: n)
    func addTone(start: Int, count: Int, f0: (Double) -> Double, harmonics: (Int, Double) -> Double, maxHz: Double,
                 env: (Double) -> Double, phase0: Double = 0) {
        // 每個諧波各自累積相位（f0 隨時間變 → 瞬時頻率 k·f0）
        let f0s = f0(0)
        let K = max(1, Int(maxHz / max(f0s, 20)))
        var ph = [Double](repeating: 0, count: K + 1)
        for k in 1...K { ph[k] = phase0 * Double(k) }
        for i in 0..<count where start + i >= 0 && start + i < n {
            let t = Double(i) / rate
            let f = f0(t)
            let e = env(t)
            if e < 1e-5 { for k in 1...K { ph[k] += 2 * Double.pi * Double(k) * f / rate }; continue }
            var v = 0.0
            for k in 1...K {
                let fk = Double(k) * f
                if fk < maxHz { v += harmonics(k, fk) * sin(ph[k]) }
                ph[k] += 2 * Double.pi * fk / rate
            }
            y[start + i] += e * v
        }
    }
    func addNoise(start: Int, count: Int, amp: Double, decay: Double, hp: Int) {
        var prev = 0.0, prev2 = 0.0
        for i in 0..<count where start + i >= 0 && start + i < n {
            let w = rng.gauss()
            var v = w
            if hp >= 1 { v = w - prev }
            if hp >= 2 { v = v - prev2; prev2 = w - prev }
            prev = w
            y[start + i] += amp * v * exp(-Double(i) / rate / decay)
        }
    }
    let formantSets: [[Double]] = [[700, 1220, 2600], [300, 2300, 3000], [500, 1000, 2500], [400, 1700, 2700], [600, 1500, 2800]]
    func vocal(level: Double) {
        var t = rng.range(0, 0.3)
        let base = rng.range(170, 260)
        while t < seconds {
            let dur = rng.range(0.18, 0.6)
            if rng.uni() < 0.15 { t += rng.range(0.1, 0.4); continue }   // 換氣
            let semi = Double(Int(rng.range(-5, 10)))
            let f0 = base * pow(2, semi / 12)
            let vibHz = rng.range(4.8, 6.2), vibDepth = rng.range(0.005, 0.015), vibPh = rng.range(0, 6.28)
            let fm = formantSets[Int(rng.uni() * Double(formantSets.count)) % formantSets.count]
            let s0 = Int(t * rate), cnt = Int((dur + 0.08) * rate)
            addTone(start: s0, count: cnt, f0: { tt in f0 * (1 + vibDepth * sin(2 * Double.pi * vibHz * tt + vibPh) * min(1, tt / 0.15)) },
                    harmonics: { _, fk in
                        var a = 0.04
                        for (j, F) in fm.enumerated() { a += [1.0, 0.6, 0.35][j] * exp(-pow((fk - F) / (0.12 * F + 60), 2)) }
                        return a * level
                    }, maxHz: 5500,
                    env: { tt in min(1, tt / 0.03) * (tt > dur ? max(0, 1 - (tt - dur) / 0.08) : 1) })
            if rng.uni() < 0.5 { addNoise(start: s0, count: Int(0.04 * rate), amp: 0.15 * level, decay: 0.015, hp: 2) }   // 子音
            t += dur + rng.range(0, 0.08)
        }
    }
    switch kind {
    case .beat, .vocal:
        if kind == .beat {
            let beat = 60 / rng.range(90, 130)
            var b = 0
            var t = rng.range(0, 0.2)
            let bassNotes = [41.2, 49.0, 55.0, 61.7, 73.4]
            while t < seconds {
                let s0 = Int(t * rate)
                // 大鼓
                var ph = 0.0
                for i in 0..<Int(0.25 * rate) where s0 + i < n {
                    let tt = Double(i) / rate
                    let f = 50 + 90 * exp(-tt / 0.03)
                    y[s0 + i] += 0.9 * exp(-tt / 0.12) * sin(ph)
                    ph += 2 * Double.pi * f / rate
                }
                addNoise(start: s0, count: Int(0.004 * rate), amp: 0.3, decay: 0.002, hp: 1)
                // 小鼓（2、4 拍）
                if b % 2 == 1 {
                    addNoise(start: s0, count: Int(0.2 * rate), amp: 0.35, decay: 0.07, hp: 1)
                    addTone(start: s0, count: Int(0.15 * rate), f0: { _ in 190 }, harmonics: { k, _ in k == 1 ? 0.3 : 0 }, maxHz: 400,
                            env: { tt in exp(-tt / 0.05) })
                }
                // 鈸（每半拍）
                for h in 0..<2 { addNoise(start: s0 + Int(Double(h) * beat / 2 * rate), count: Int(0.08 * rate), amp: 0.12, decay: 0.025, hp: 2) }
                // 貝斯
                let bf = bassNotes[Int(rng.uni() * Double(bassNotes.count)) % bassNotes.count]
                addTone(start: s0, count: Int(beat * rate), f0: { _ in bf }, harmonics: { k, _ in k == 1 ? 0.35 : (k == 2 ? 0.12 : 0.03) },
                        maxHz: 600, env: { tt in min(1, tt / 0.01) * exp(-tt / 0.4) })
                t += beat; b += 1
            }
        }
        vocal(level: kind == .beat ? 0.5 : 0.8)
    case .strings, .organ:
        var t = 0.0
        let roots = [130.8, 146.8, 164.8, 174.6, 196.0, 220.0]
        while t < seconds {
            let root = roots[Int(rng.uni() * Double(roots.count)) % roots.count]
            let minor = rng.uni() < 0.5
            let chord = [root, root * pow(2, (minor ? 3 : 4) / 12.0), root * pow(2, 7 / 12.0), root * 2]
            let dur = rng.range(3.0, 4.5)
            for f0 in chord {
                let vibHz = rng.range(4.5, 5.5), vibPh = rng.range(0, 6.28), depth = kind == .organ ? 0 : rng.range(0.002, 0.005)
                addTone(start: Int(t * rate), count: Int((dur + 1.2) * rate),
                        f0: { tt in f0 * (1 + depth * sin(2 * Double.pi * vibHz * tt + vibPh)) },
                        harmonics: { k, _ in 0.25 / pow(Double(k), 1.2) }, maxHz: 4500,
                        env: { tt in min(1, tt / 0.8) * (tt > dur ? max(0, 1 - (tt - dur) / 1.2) : 1) },
                        phase0: rng.range(0, 6.28))
            }
            t += dur
        }
    }
    var ms = 0.0
    for v in y { ms += v * v }
    let g = pow(10, -20.0 / 20) / sqrt(max(ms / Double(n), 1e-30))
    return y.map { Float($0 * g) }
}

// MARK: - 房間模擬

struct MonSimDevice {
    var name: String
    /// 到達時間（ms，相對延遲 0 輸出）
    var lagMs: Double
    var gain: Double
    var hpHz: Double
    /// (中心 Hz, dB, 寬度 octave)
    var peaks: [(Double, Double, Double)]
    /// 群延遲在 1–4 kHz 內線性變化 ±dispersionMs（頻帶平均 0，所以 1–4 kHz 的平均到達不變）
    var dispersionMs = 0.0
    var reflGain = 0.5
    var reflMs = 4.1
    var reverbDb = -14.0
    /// 這台自己的延遲漂移（ms／秒；藍牙 V7 實測約 1.4 ms／90 s ≈ 0.016）。以麥克風窗中點為 0（真實誤差 = 中點的值）
    var driftMsPerSec = 0.0
}

struct MonSimConfig {
    var music: [Float]
    var engRate = 48000.0
    var micRate = 48000.0
    var micPpm = 30.0
    var stampOffsetMs = 3.0
    var jitterUs = 20.0
    var withClock = true
    var devices: [MonSimDevice]
    /// 探測（時間 = 到達時刻，秒，相對麥克風開始）
    var probes: [MonitorProbeStep]
    var rampSeconds = 0.5
    /// 呼叫端不知道聲學路徑：換算探測內容時用的補償與真值差（ms，± 這個範圍內隨機）
    var baseDelayErrMs = 6.0
    var noiseDb = -25.0
    /// 另加白噪（相對麥克風訊號 dB；nil = 不加）：1–4 kHz 也有的雜訊（冷氣、人聲…），壓力測試用
    var whiteDb: Double? = nil
    var micStartSeconds = 0.9
    var micSeconds = 10.0
    var seed: UInt64 = 1
    /// 參考裝置（有線三台）
    var referenceDevices: [Int] = [0, 1, 2]
}

func monSimulate(_ c: MonSimConfig) -> MonitorCapture {
    var rng = MonRng(c.seed &+ 77)
    let rate = c.engRate
    let nMusic = c.music.count
    var l = 0
    while (1 << l) < nMusic + Int(1.0 * rate) { l += 1 }
    let N = 1 << l
    let fft = MonFFT(n: N)
    var xr = [Float](repeating: 0, count: N / 2), xi = xr
    c.music.withUnsafeBufferPointer { fft.forward($0.baseAddress!, count: nMusic, re: &xr, im: &xi) }
    // 反 FFT 用的 setup
    let log2n = vDSP_Length(l)
    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    let rs = MonResampler(cutoff: 0.97)
    var sum = [Float](repeating: 0, count: N)
    let df = rate / Double(N)
    for (di, d) in c.devices.enumerated() {
        // 殘響 IR（8 ms 起、RT60 0.3 s）
        let rl = Int(0.4 * rate)
        var rv = [Float](repeating: 0, count: N)
        var e = 0.0
        for i in Int(0.008 * rate)..<rl {
            let v = rng.gauss() * exp(-Double(i) / rate * 6.9 / 0.3)
            rv[i] = Float(v); e += v * v
        }
        let rg = pow(10, d.reverbDb / 20) / sqrt(max(e, 1e-30))
        for i in 0..<rl { rv[i] *= Float(rg) }
        var rr = [Float](repeating: 0, count: N / 2), ri = rr
        rv.withUnsafeBufferPointer { fft.forward($0.baseAddress!, count: rl, re: &rr, im: &ri) }
        var yr = [Float](repeating: 0, count: N / 2), yi = yr
        for k in 1..<(N / 2) {
            let f = Double(k) * df
            var magDb = 0.0
            for (fc, g, w) in d.peaks { magDb += g * exp(-pow(log2(f / fc) / w, 2)) }
            let hp = 1 / sqrt(1 + pow(d.hpHz / f, 4))
            let lp = 1 / sqrt(1 + pow(f / 12000, 4))
            let mag = d.gain * pow(10, magDb / 20) * hp * lp
            // 色散：τg(f) = D·(f − 2500)/1500 → Φ(f) = 2π·D/1500·(f²/2 − 2500 f)
            let D = d.dispersionMs / 1000
            let phi = 2 * Double.pi * D / 1500 * (f * f / 2 - 2500 * f)
            let w = 2 * Double.pi * f
            let tau = d.lagMs / 1000
            // 直達＋反射
            var hr = cos(-w * tau - phi) + d.reflGain * cos(-w * (tau + d.reflMs / 1000) - phi)
            var hi = sin(-w * tau - phi) + d.reflGain * sin(-w * (tau + d.reflMs / 1000) - phi)
            // 殘響（DFT 係數 = zrip / 2）
            let cr = cos(-w * tau), ci = sin(-w * tau)
            let r0 = Double(rr[k]) / 2, i0 = Double(ri[k]) / 2
            hr += r0 * cr - i0 * ci
            hi += r0 * ci + i0 * cr
            hr *= mag; hi *= mag
            let a = Double(xr[k]), b = Double(xi[k])
            yr[k] = Float(a * hr - b * hi)
            yi[k] = Float(a * hi + b * hr)
        }
        yr[0] = 0; yi[0] = 0
        var y = [Float](repeating: 0, count: N)
        yr.withUnsafeMutableBufferPointer { rp in
            yi.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                y.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&sc, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(N / 2))
                }
            }
        }
        var sc = Float(1.0 / Double(2 * N))
        vDSP_vsmul(y, 1, &sc, &y, 1, vDSP_Length(N))
        // 探測：到達時刻 t 的額外延遲 p(t)（樣本），0.5 s 線性斜坡
        let steps = c.probes.filter { $0.device == di }
        if steps.isEmpty && d.driftMsPerSec == 0 {
            vDSP_vadd(sum, 1, y, 1, &sum, 1, vDSP_Length(N))
        } else {
            let R = c.rampSeconds * rate
            let segs = steps.map { s -> (Double, Double, Double) in
                ((c.micStartSeconds + s.startSeconds) * rate, (c.micStartSeconds + s.clearSeconds) * rate, s.offsetMs / 1000 * rate)
            }
            let mid = (c.micStartSeconds + c.micSeconds / 2) * rate
            let dr = d.driftMsPerSec / 1000        // 秒／秒
            y.withUnsafeBufferPointer { yp in
                for t in 0..<N {
                    let tt = Double(t)
                    var p = dr * (tt - mid)
                    for (a0, a1, P) in segs {
                        if tt >= a0 && tt < a0 + R { p += P * (tt - a0) / R }
                        else if tt >= a0 + R && tt < a1 { p += P }
                        else if tt >= a1 && tt < a1 + R { p += P * (1 - (tt - a1) / R) }
                    }
                    sum[t] += p == 0 ? yp[t] : rs.value(yp, at: tt - p)
                }
            }
        }
    }
    // 麥克風：另一個時鐘
    let micN = Int(c.micSeconds * c.micRate)
    let step = rate / c.micRate * (1 + c.micPpm * 1e-6)
    let t0 = c.micStartSeconds * rate
    let rsMic = MonResampler(cutoff: min(1, c.micRate / rate) * 0.97)
    var mic = [Float](repeating: 0, count: micN)
    sum.withUnsafeBufferPointer { sp in
        for i in 0..<micN { mic[i] = rsMic.value(sp, at: t0 + Double(i) * step) }
    }
    // 麥克風增益：訊號 RMS −24 dBFS（實機 C270 在音樂音量下的量級；不削波）
    var ms = 0.0
    for v in mic { ms += Double(v * v) }
    let mg = Float(pow(10, -24.0 / 20) / sqrt(max(ms / Double(micN), 1e-30)))
    for i in 0..<micN { mic[i] *= mg }
    let sigRms = pow(10, -24.0 / 20)
    // 雜訊：棕噪（低頻為主）＋白噪底（−30 dB 相對棕噪）
    var nz = [Double](repeating: 0, count: micN)
    var acc = 0.0, nms = 0.0
    for i in 0..<micN {
        acc = 0.995 * acc + rng.gauss()
        nz[i] = acc + 0.03 * 10 * rng.gauss()
        nms += nz[i] * nz[i]
    }
    let ng = sigRms * pow(10, c.noiseDb / 20) / sqrt(nms / Double(micN))
    for i in 0..<micN { mic[i] += Float(nz[i] * ng) }
    if let w = c.whiteDb {
        let wg = sigRms * pow(10, w / 20)
        for i in 0..<micN { mic[i] += Float(wg * rng.gauss()) }
    }
    // 時間戳
    let hostBase = 12345.678
    var micClock: [MonitorClockPoint] = [], progClock: [MonitorClockPoint] = []
    let programStart: Int64 = 5_000_000
    if c.withClock {
        var i = 0
        while i < micN {
            let h = hostBase + (t0 + Double(i) * step) / rate + c.stampOffsetMs / 1000 + rng.range(-1, 1) * c.jitterUs * 1e-6
            micClock.append(MonitorClockPoint(sample: Double(i), hostSeconds: h))
            i += 512
        }
        var e = 0
        while e < nMusic {
            progClock.append(MonitorClockPoint(sample: Double(programStart + Int64(e)),
                                               hostSeconds: hostBase + Double(e) / rate + rng.range(-1, 1) * c.jitterUs * 1e-6))
            e += 512
        }
    }
    // 探測排程 → 內容（呼叫端只知道補償，不知道聲學路徑：± baseDelayErrMs）
    var probes: [MonitorProbe] = []
    for s in c.probes {
        let d = c.devices[s.device]
        let base = Int(((d.lagMs + rng.range(-1, 1) * c.baseDelayErrMs) / 1000 * rate).rounded())
        probes.append(MonitorProbe.fromOutputTimes(device: s.device, setAt: programStart + Int64((c.micStartSeconds + s.startSeconds) * rate),
                                                   clearAt: programStart + Int64((c.micStartSeconds + s.clearSeconds) * rate),
                                                   offsetMs: s.offsetMs, rampSeconds: c.rampSeconds, engineRate: rate, baseDelayFrames: base))
    }
    return MonitorCapture(mic: mic, micRate: c.micRate, micClock: micClock, program: c.music, programRate: rate,
                          programStart: programStart, programClock: progClock, deviceCount: c.devices.count, probes: probes,
                          referenceDevices: c.referenceDevices)
}

/// 四台：內建、MSI（HDMI）、電視（DP）、藍牙。errMs = 各台相對群集的真實誤差
func monDefaultDevices(errMs: [Double], rng: inout MonRng, randomize: Bool) -> [MonSimDevice] {
    let tau0 = 440.0 + (randomize ? rng.range(-20, 40) : 0)
    func j(_ a: Double) -> Double { randomize ? rng.range(-a, a) : 0 }
    var d = [
        MonSimDevice(name: "內建", lagMs: tau0, gain: 1.0, hpHz: 280, peaks: [(3000, 4, 0.6), (900, -3, 0.5)]),
        MonSimDevice(name: "MSI", lagMs: tau0, gain: 0.8, hpHz: 150, peaks: [(1500, -5, 0.4), (5000, 3, 0.7)]),
        MonSimDevice(name: "電視", lagMs: tau0, gain: 0.9, hpHz: 80, peaks: [(2500, -4, 1.0)], dispersionMs: 0.3),
        MonSimDevice(name: "藍牙", lagMs: tau0, gain: 0.7, hpHz: 200, peaks: [(2500, 6, 0.5), (1000, -2, 0.8)]),
    ]
    for k in d.indices {
        d[k].lagMs += (k < errMs.count ? errMs[k] : 0)
        d[k].gain *= pow(10, j(3) / 20)
        d[k].reflGain = randomize ? rng.range(0.4, 0.7) : 0.6
        d[k].reflMs = 4.1 + j(0.3)
        d[k].peaks = d[k].peaks.map { ($0.0 * (1 + j(0.15)), $0.1 + j(2), $0.2) }
    }
    // 藍牙同串流內單向漂（V7：1.4 ms／90 s）：隨機 ±0.02 ms／秒（10 秒窗內 ±0.1 ms）
    if randomize { d[3].driftMsPerSec = j(0.02) }
    return d
}

// MARK: - 自測

final class MonLockedList<T> {
    private var items: [T?]
    private let lock = NSLock()
    init(_ n: Int) { items = Array(repeating: nil, count: n) }
    func set(_ i: Int, _ v: T) { lock.lock(); items[i] = v; lock.unlock() }
    var all: [T?] { lock.lock(); defer { lock.unlock() }; return items }
}

private let monMusicCache = MonMusicCache()
final class MonMusicCache {
    private var m: [String: [Float]] = [:]
    private let lock = NSLock()
    func get(_ k: MonMusic, seed: UInt64, seconds: Double = 12, rate: Double = 48000) -> [Float] {
        let key = "\(k.rawValue)-\(seed)-\(seconds)-\(rate)"
        lock.lock()
        if let v = m[key] { lock.unlock(); return v }
        lock.unlock()
        let v = monSynthMusic(k, seconds: seconds, rate: rate, seed: seed)
        lock.lock(); m[key] = v; lock.unlock()
        return v
    }
}

struct MonSimArgs {
    var music = MonMusic.beat
    var errMs: [Double] = [0, 0, 0, 1.5]
    var plan = "bt"
    var offsetsMs: [Double] = [3.5]
    var seed: UInt64 = 1
    var noiseDb = -25.0
    var ppm = 30.0
    var withClock = true
    var micRate = 48000.0
    var randomize = false
    var round = 0
    var whiteDb: Double? = nil
    /// 藍牙相對預設增益（dB）：GLASS5+ 放在 C270 旁 → 麥克風聽到的藍牙比有線大聲
    var btGainDb = 0.0
}

func monRunSim(_ a: MonSimArgs, params: MonitorParams = MonitorParams()) -> (MonitorResult, MonitorCapture) {
    var rng = MonRng(a.seed &* 31 &+ 7)
    let music = monMusicCache.get(a.music, seed: a.seed % 6)
    var devs = monDefaultDevices(errMs: a.errMs, rng: &rng, randomize: a.randomize)
    devs[3].gain *= pow(10, a.btGainDb / 20)
    let plan: [MonitorProbeStep]
    switch a.plan {
    case "all": plan = MonitorProbePlan.make(devices: [0, 1, 2, 3], windowSeconds: 10, offsetsMs: a.offsetsMs, round: a.round)
    case "bt2": plan = MonitorProbePlan.bluetooth(3, offsetsMs: a.offsetsMs.count >= 2 ? a.offsetsMs : [3, 4])
    case "pair": plan = MonitorProbePlan.pair(bluetooth: 3, wired: Int(a.seed % 3))
    case "w2": plan = MonitorProbePlan.make(steps: [(Int(a.seed % 3), 3.0), (Int(a.seed % 3), 4.0)])
    default: plan = MonitorProbePlan.make(devices: [3], windowSeconds: 10, offsetsMs: a.offsetsMs, round: a.round)
    }
    var cfg = MonSimConfig(music: music, devices: devs, probes: plan)
    cfg.micPpm = a.ppm
    cfg.withClock = a.withClock
    cfg.noiseDb = a.noiseDb
    cfg.micRate = a.micRate
    cfg.seed = a.seed
    cfg.whiteDb = a.whiteDb
    let cap = monSimulate(cfg)
    return (DriftEstimator.analyze(cap, params: params), cap)
}

/// 調參：--set key=value（可重複）
func monApplySets(_ args: [String], _ prm: inout MonitorParams) {
    var i = 0
    while i < args.count {
        if args[i] == "--set", i + 1 < args.count {
            let kv = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, let v = Double(kv[1]) {
                switch kv[0] {
                case "snrSmoothHz": prm.snrSmoothHz = v
                case "mismatchFraction": prm.mismatchFraction = v
                case "minSnrDb": prm.minSnrDb = v
                case "ambiguityRatio": prm.ambiguityRatio = v
                case "earliestFraction": prm.earliestFraction = v
                case "deviceEarliestFraction": prm.deviceEarliestFraction = v
                case "referenceEarliestFraction": prm.referenceEarliestFraction = v
                case "clusterMatchFraction": prm.clusterMatchFraction = v
                case "laterPeakRatio": prm.laterPeakRatio = v
                case "referenceEarlierRatio": prm.referenceEarlierRatio = v
                case "referenceSumWeights": prm.referenceSumWeights = v != 0
                case "maxHalfDiffMs": prm.maxHalfDiffMs = v
                case "minProbeSeconds": prm.minProbeSeconds = v
                case "welchSeconds": prm.welchSeconds = v
                case "transitionGuardMs": prm.transitionGuardMs = v
                default: print("未知參數 \(kv[0])")
                }
            }
            i += 2
        } else { i += 1 }
    }
}

/// 誤報率試驗第 k 次的參數（monitor-sim --trial k 可單獨重現）
func monFalseAlarmTrial(_ k: Int) -> MonSimArgs {
    var rr = MonRng(20260929 &+ UInt64(k) &* 7919)
    var a = MonSimArgs()
    a.music = MonMusic.allCases[k % MonMusic.allCases.count]
    a.errMs = [0, 0, 0, 0]
    a.seed = 1000 + UInt64(k)
    a.randomize = true
    let pu = rr.uni()
    a.plan = pu < 0.25 ? "bt" : (pu < 0.5 ? "bt2" : (pu < 0.75 ? "pair" : "all"))
    a.offsetsMs = rr.uni() < 0.5 ? [3.0, 4.0] : [4.0, 3.0]
    a.noiseDb = rr.range(-30, -18)
    a.ppm = rr.range(-50, 50)
    return a
}

func cmdMonitorSim(_ args: [String]) -> Int32 {
    var a = MonSimArgs()
    var curves = false
    var i = 0
    func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
    while i < args.count {
        switch args[i] {
        case "--music": if let v = next(), let m = MonMusic(rawValue: v) { a.music = m }
        case "--err": if let v = next(), let x = Double(v) { a.errMs[3] = x }
        case "--errs": if let v = next() { a.errMs = v.split(separator: ",").compactMap { Double($0) } }
        case "--offset": if let v = next() { a.offsetsMs = v.split(separator: ",").compactMap { Double($0) } }
        case "--plan": if let v = next() { a.plan = v }
        case "--seed": if let v = next(), let x = UInt64(v) { a.seed = x }
        case "--noise": if let v = next(), let x = Double(v) { a.noiseDb = x }
        case "--ppm": if let v = next(), let x = Double(v) { a.ppm = x }
        case "--no-clock": a.withClock = false
        case "--white": if let v = next(), let x = Double(v) { a.whiteDb = x }
        case "--bt-gain": if let v = next(), let x = Double(v) { a.btGainDb = x }
        case "--mic-rate": if let v = next(), let x = Double(v) { a.micRate = x }
        case "--random": a.randomize = true
        case "--curves": curves = true
        case "--set": i += 1
        case "--trial": if let v = next(), let k = Int(v) { a = monFalseAlarmTrial(k) }
        default: print("未知參數：\(args[i])"); return 2
        }
        i += 1
    }
    var prm = MonitorParams()
    monApplySets(args, &prm)
    if curves {
        prm.debugSink = { name, env, center, rate in
            // 群集 ±8 ms、每 0.1 ms 一點：相對最大值
            let h = Int(0.015 * rate), st = max(1, Int(0.0002 * rate))
            let mx = env[(center - h)...(center + h)].max() ?? 1
            var line = "  \(name.padding(toLength: 5, withPad: " ", startingAt: 0))"
            var k = center - h
            while k <= center + h { let v = env[k] / mx; line += v > 0.9 ? "█" : v > 0.7 ? "▆" : v > 0.5 ? "▄" : v > 0.3 ? "▂" : v > 0.15 ? "▁" : "·"; k += st }
            print(line)
        }
        print("  曲線：群集 −15 … +15 ms，每格 0.2 ms（█ > 0.9、▆ > 0.7、▄ > 0.5、▂ > 0.3、▁ > 0.15）")
    }
    let (r, _) = monRunSim(a, params: prm)
    print("模擬：\(a.music.rawValue) 真實誤差 \(a.errMs) 探測 \(a.plan) \(a.offsetsMs) ms seed \(a.seed) 雜訊 \(a.noiseDb) dB \(a.ppm) ppm \(a.withClock ? "有" : "無")時間戳 麥克風 \(Int(a.micRate)) Hz")
    print(r.summary)
    return r.skip == nil ? 0 : 1
}

func runMonitorSelfTest(_ args: [String]) -> Int32 {
    let quick = args.contains("--quick")
    let verbose = args.contains("-v")
    var trials = quick ? 40 : 200
    if let k = args.firstIndex(of: "--trials"), k + 1 < args.count, let n = Int(args[k + 1]) { trials = n }
    var fail = 0
    func check(_ ok: Bool, _ msg: String) {
        print("  \(ok ? "✓" : "✗") \(msg)")
        if !ok { fail += 1 }
    }
    let t0 = Date()
    var basePrm = MonitorParams()
    monApplySets(args, &basePrm)
    func par(_ runs: [MonSimArgs], params: MonitorParams? = nil) -> [MonitorResult] {
        let params = params ?? basePrm
        let out = MonLockedList<MonitorResult>(runs.count)
        DispatchQueue.concurrentPerform(iterations: runs.count) { k in out.set(k, monRunSim(runs[k], params: params).0) }
        return out.all.map { $0! }
    }
    func line(_ a: MonSimArgs, _ r: MonitorResult) -> String {
        let bt = r.devices.count > 3 ? r.devices[3] : nil
        return String(format: "%@ seed %llu 探測 %@ %@：藍牙 %@ ms %@", a.music.rawValue, a.seed, a.plan,
                      a.plan == "pair" ? "+3.0/+4.0" : a.offsetsMs.map { String(format: "%+.1f", $0) }.joined(separator: "/"),
                      bt?.errorMs.map { String(format: "%+.3f", $0) } ?? "—",
                      bt.map { $0.trusted ? "可採信" : "不可採信（" + $0.issues.map(\.rawValue).joined(separator: "、") + "）" } ?? (r.skip?.rawValue ?? "?"))
    }

    // ── 1. 鼓點／人聲：藍牙 +1.5 ms，10 秒內 ±0.3 ms；+3 與 +4 ms 探測都要能分離 ──
    print("── 1. 鼓點／人聲類：藍牙誤差 +1.5 ms（±0.3 ms、要可採信）──")
    var runs1: [MonSimArgs] = []
    for m in [MonMusic.beat, .vocal] {
        for off in [3.0, 4.0] {
            for s in UInt64(1)...(quick ? 2 : 4) {
                var a = MonSimArgs(); a.music = m; a.offsetsMs = [off]; a.seed = s; a.randomize = true
                runs1.append(a)
            }
        }
    }
    // 建議排程：藍牙同一輪 +3、+4 各一段
    for m in [MonMusic.beat, .vocal] {
        for s in UInt64(21)...(quick ? 21 : 23) {
            var a = MonSimArgs(); a.music = m; a.plan = "bt2"; a.offsetsMs = [3.0, 4.0]; a.seed = s; a.randomize = true
            runs1.append(a)
        }
    }
    // 藍牙＋一台有線（各 +3、+4）
    for m in [MonMusic.beat, .vocal] {
        for s in UInt64(31)...(quick ? 31 : 33) {
            var a = MonSimArgs(); a.music = m; a.plan = "pair"; a.seed = s; a.randomize = true
            runs1.append(a)
        }
    }
    // 四台輪流（+3/+4 交錯；每台單一偏移、0.8 秒 → 預期全部「探測資料不足」，只驗證不給錯值）
    for m in [MonMusic.beat, .vocal] {
        for s in UInt64(11)...(quick ? 11 : 13) {
            var a = MonSimArgs(); a.music = m; a.plan = "all"; a.offsetsMs = [3.0, 4.0]; a.seed = s; a.randomize = true
            runs1.append(a)
        }
    }
    let res1 = par(runs1)
    var worst1 = 0.0, bad1 = 0, wiredWrong = 0, wiredTrusted = 0, looseN = 0, looseTrusted = 0
    var byOffset: [Double: (ok: Int, n: Int)] = [:]
    for (a, r) in zip(runs1, res1) {
        let bt = r.devices.count > 3 ? r.devices[3] : nil
        // 單台（+3 或 +4）、雙偏移（建議）：要可採信且準；藍牙＋有線、四台輪流（藍牙資料較少）：不可以給錯值
        let strict = a.plan == "bt" || a.plan == "bt2"
        let ok = strict ? (bt?.trusted == true && abs((bt?.errorMs ?? 99) - 1.5) <= 0.3)
                        : (bt?.trusted != true || abs((bt?.errorMs ?? 99) - 1.5) <= 0.3)
        if !strict { looseN += 1; if bt?.trusted == true { looseTrusted += 1 } }
        if let e = bt?.errorMs, bt?.trusted == true { worst1 = max(worst1, abs(e - 1.5)) }
        if !ok { bad1 += 1 }
        if a.plan == "bt" { var v = byOffset[a.offsetsMs[0]] ?? (0, 0); v.n += 1; if ok { v.ok += 1 }; byOffset[a.offsetsMs[0]] = v }
        for d in r.devices.prefix(3) where d.trusted {
            wiredTrusted += 1
            if abs(d.errorMs ?? 99) > 0.3 { wiredWrong += 1 }
        }
        if verbose || !ok { print("    " + line(a, r)) }
        if verbose { print(r.summary.split(separator: "\n").map { "      " + $0 }.joined(separator: "\n")) }
    }
    check(bad1 == 0, "藍牙 \(runs1.count - bad1)/\(runs1.count) 次合格（只探藍牙 +3／+4／+3+4：可採信且在 ±0.3 ms 內；藍牙＋有線、四台輪流：不給錯值，可採信 \(looseTrusted)/\(looseN)）（最大偏差 \(String(format: "%.3f", worst1)) ms）")
    for off in byOffset.keys.sorted() {
        let v = byOffset[off]!
        check(v.ok == v.n, String(format: "探測 +%.0f ms：藍牙分離成功 %d/%d", off, v.ok, v.n))
    }
    check(wiredWrong == 0, "有線裝置（真實誤差 0；藍牙＋有線、四台輪流）：可採信 \(wiredTrusted) 次，其中偏差 > 0.3 ms 的 \(wiredWrong) 次")

    // ── 2. 長音（弦樂）：信心不足要回報不可採信，不可以給錯值 ──
    print("── 2. 平順弦樂長音（有顫音）／風琴長音（無顫音）：可採信的必須正確（±0.3 ms），其餘必須標「不可採信」──")
    var runs2: [MonSimArgs] = []
    for m in [MonMusic.strings, .organ] {
        for s in UInt64(1)...(quick ? 3 : 8) {
            for plan in ["bt", "bt2"] {
                var a = MonSimArgs(); a.music = m; a.plan = plan; a.offsetsMs = plan == "bt" ? [s % 2 == 0 ? 3.0 : 4.0] : [3, 4]
                a.seed = s; a.randomize = true
                runs2.append(a)
            }
        }
    }
    let res2 = par(runs2)
    var wrong2 = 0, trusted2 = 0
    for (a, r) in zip(runs2, res2) {
        let bt = r.devices.count > 3 ? r.devices[3] : nil
        if bt?.trusted == true {
            trusted2 += 1
            if abs((bt?.errorMs ?? 99) - 1.5) > 0.3 { wrong2 += 1; print("    ✗ 錯值：" + line(a, r)) }
        }
        if verbose { print("    " + line(a, r)) }
    }
    check(wrong2 == 0, "長音 \(runs2.count) 次：可採信 \(trusted2) 次、其中錯值 \(wrong2) 次；不可採信／跳過 \(runs2.count - trusted2) 次")
    for m in [MonMusic.strings, .organ] {
        let ix = runs2.indices.filter { runs2[$0].music == m }
        let tr = ix.filter { res2[$0].devices.count > 3 && res2[$0].devices[3].trusted }.count
        print("    （資訊）\(m.rawValue)：藍牙可採信 \(tr)/\(ix.count)")
    }

    // ── 3. 無誤差時不誤報：隨機試驗，任何一台「可採信且 |誤差| ≥ 0.5 ms」= 誤報 ──
    print("── 3. 誤報率（\(trials) 次隨機試驗，真實誤差全 0；音樂類型／種子／增益／反射／雜訊／漂移／探測 +3・+4／輪流或只探藍牙都隨機）──")
    var trialOffset = 0
    if let k = args.firstIndex(of: "--trial-offset"), k + 1 < args.count, let n = Int(args[k + 1]) { trialOffset = n }
    let runs3 = (0..<trials).map { monFalseAlarmTrial($0 + trialOffset) }
    let res3 = par(runs3)
    var fa = 0, trusted3 = 0, skipped3 = 0, devTrusted3 = 0
    var maxAbs3 = 0.0
    for (a, r) in zip(runs3, res3) {
        if r.skip != nil { skipped3 += 1 }
        var any = false, anyFalse = false
        for d in r.devices where d.trusted {
            any = true; devTrusted3 += 1
            maxAbs3 = max(maxAbs3, abs(d.errorMs ?? 0))
            if abs(d.errorMs ?? 0) >= 0.5 { anyFalse = true }
        }
        if any { trusted3 += 1 }
        if anyFalse { fa += 1; print("    ✗ 誤報（monitor-sim --trial \((runs3.firstIndex { $0.seed == a.seed } ?? -1) + trialOffset)）：" + line(a, r)); if verbose { print(r.summary) } }
    }
    let rate3 = Double(fa) / Double(max(trials, 1))
    check(rate3 < 0.01, String(format: "誤報 %d/%d（%.1f%%，要 < 1%%）；有可採信結果的試驗 %d、可採信的裝置估計 %d 個、最大 |誤差| %.3f ms；整輪跳過 %d",
                               fa, trials, rate3 * 100, trusted3, devTrusted3, maxAbs3, skipped3))
    // 各音樂類型在無誤差時的可採信率（資訊）
    for m in MonMusic.allCases {
        let idx = runs3.indices.filter { runs3[$0].music == m }
        let tr = idx.filter { k in res3[k].devices.count > 3 && res3[k].devices[3].trusted }.count
        print(String(format: "    （資訊）%@：藍牙可採信 %d/%d", m.rawValue, tr, idx.count))
    }

    // ── 4. 時鐘：沒有時間戳＋45 ppm；16 kHz 麥克風 ──
    print("── 4. 時鐘與取樣率 ──")
    var a4 = MonSimArgs(); a4.seed = 3; a4.ppm = 45; a4.withClock = false; a4.randomize = true
    var a5 = MonSimArgs(); a5.seed = 4; a5.micRate = 16000; a5.randomize = true
    var a6 = MonSimArgs(); a6.seed = 5; a6.ppm = -50; a6.randomize = true
    let res4 = par([a4, a5, a6])
    for (a, r) in zip([a4, a5, a6], res4) {
        let bt = r.devices.count > 3 ? r.devices[3] : nil
        let ok = bt?.trusted == true && abs((bt?.errorMs ?? 99) - 1.5) <= 0.3
        let what = !a.withClock ? "沒有時間戳、麥克風 +45 ppm（標稱比例＋區塊相位估漂移、頻域拉回）" : (a.micRate != 48000 ? "16 kHz 麥克風（sinc 重取樣）" : "麥克風 −50 ppm（時間戳）")
        check(ok, what + "：" + line(a, r) + String(format: "；比例 %+.1f ppm、頻域拉回的漂移 %@ ppm", r.ratioPpm,
                                                     r.residualDriftPpm.map { String(format: "%+.1f", $0) } ?? "—"))
    }

    // ── 5. 跳過條件、大偏移、分群 ──
    print("── 5. 跳過條件／大偏移／分群 ──")
    do {
        var a = MonSimArgs(); a.seed = 2
        var rng = MonRng(9)
        let music = monMusicCache.get(.beat, seed: 2)
        let devs = monDefaultDevices(errMs: [0, 0, 0, 0], rng: &rng, randomize: false)
        var cfg = MonSimConfig(music: music, devices: devs, probes: MonitorProbePlan.make(devices: [3]))
        // 節目音太小
        var quiet = cfg; quiet.music = music.map { $0 * 0.0001 }
        var capQ = monSimulate(quiet)
        capQ.program = quiet.music
        check(DriftEstimator.analyze(capQ).skip == .programTooQuiet, "節目音 −100 dBFS → 跳過（節目音太小）")
        // 只有低頻（1–4 kHz 能量不足）
        var low = [Float](repeating: 0, count: music.count)
        for i in 0..<low.count { low[i] = Float(0.1 * sin(2 * Double.pi * 80 * Double(i) / 48000)) }
        var capL = monSimulate(cfg); capL.program = low
        check(DriftEstimator.analyze(capL).skip == .bandEnergyTooLow, "節目音只有 80 Hz → 跳過（1–4 kHz 能量不足）")
        // 麥克風聽不到（錄音換成純雜訊）
        var capN = monSimulate(cfg)
        var nr = MonRng(5)
        capN.mic = capN.mic.map { _ in Float(0.01 * nr.gauss()) }
        check(DriftEstimator.analyze(capN).skip == .clusterNotFound, "麥克風只有雜訊 → 跳過（找不到群集）")
        // 削波
        var capC = monSimulate(cfg); capC.mic = capC.mic.map { max(-1, min(1, $0 * 200)) }
        check(DriftEstimator.analyze(capC).skip == .micClipping, "麥克風削波 → 跳過")
        // 無誤差 → 群集單一峰
        cfg.probes = MonitorProbePlan.make(devices: [3])
        let r0 = DriftEstimator.analyze(monSimulate(cfg))
        check(r0.cluster?.single == true && r0.skip == nil, "無誤差：群集單一峰（\(r0.cluster.map { String(format: "%.2f ms", $0.lagMs) } ?? "—")）")
        _ = a
    }
    var aBig = MonSimArgs(); aBig.seed = 6; aBig.errMs = [0, 0, 0, 12]
    var aFar = MonSimArgs(); aFar.seed = 7; aFar.errMs = [0, 0, 0, 25]
    let resB = par([aBig, aFar])
    let bBig = resB[0].devices.count > 3 ? resB[0].devices[3] : nil
    check(bBig?.trusted == true && abs((bBig?.errorMs ?? 0) - 12) <= 0.3, "藍牙 +12 ms：量得到（\(line(aBig, resB[0]))）→ 決策器會標需要重新校正")
    let bFar = resB[1].devices.count > 3 ? resB[1].devices[3] : nil
    check(bFar?.trusted != true, "藍牙 +25 ms（超出 ±15 ms 搜尋窗）：不可採信（\(line(aFar, resB[1]))）")
    check(bFar?.looksMissing == true, "藍牙 +25 ms：歸類為「量不到」（連續幾輪 → 需要重新校正）")

    // ── 6. 決策器 ──
    print("── 6. 決策器（連續 2 次一致才修、大偏移／量不到 → 需要重新校正）──")
    func est(_ e: Double?, trusted: Bool = true, issues: [MonitorDeviceIssue] = []) -> MonitorDeviceEstimate {
        var d = MonitorDeviceEstimate(device: 3); d.probed = true; d.errorMs = e; d.trusted = trusted; d.issues = issues; return d
    }
    var dec = MonitorDecider()
    check(dec.feed(est(1.5)) == .pending(1.5), "第一次 +1.5 → 等確認")
    if case .correct(let by, let ramp) = dec.feed(est(1.6)) {
        check(abs(by - 1.55) < 1e-9 && abs(ramp - 15.5) < 1e-6, String(format: "第二次 +1.6（一致）→ 修正 %+.2f ms、斜坡 %.1f 秒", by, ramp))
    } else { check(false, "第二次一致應該修正") }
    dec.reset()
    _ = dec.feed(est(1.5))
    check(dec.feed(est(2.2)) == .pending(2.2), "不一致（1.5 → 2.2）→ 重新等確認")
    _ = dec.feed(est(nil, trusted: false, issues: [.ambiguous]))
    check(dec.feed(est(2.2)) == .pending(2.2), "中間夾一次不可採信 → 重新計")
    check(dec.feed(est(0.2)) == .none("誤差 +0.20 ms 在容許範圍內"), "0.2 ms → 不修")
    dec.reset()
    check(dec.feed(est(12)) == .pending(12), "+12 ms 第一次 → 等確認")
    if case .needsRecalibration = dec.feed(est(12.3)) { check(true, "+12 ms 第二次 → 需要重新校正（不自行修）") } else { check(false, "+12 ms 第二次應該需要重新校正") }
    dec.reset()
    let miss = est(nil, trusted: false, issues: [.lowSnr])
    _ = dec.feed(miss); _ = dec.feed(miss)
    if case .needsRecalibration = dec.feed(miss) { check(true, "連續 3 輪量不到 → 需要重新校正") } else { check(false, "連續 3 輪量不到應該需要重新校正") }
    check(dec.feed(nil, roundSkipped: true) == .none("本輪跳過"), "整輪跳過 → 不動作")
    dec.reset()
    _ = dec.feed(est(3.1))
    if case .none = dec.feed(est(3.0, trusted: false, issues: [.nearProbeImage])) {} else { check(false, "nearProbeImage 應該是 .none") }
    if case .correct = dec.feed(est(3.2)) { check(true, "中間夾「±探測偏移假峰」不打斷確認（+3.1 → 假峰 → +3.2 → 修正）") }
    else { check(false, "中間夾 nearProbeImage 應該不打斷確認") }
    let plan = MonitorProbePlan.make(devices: [0, 1, 2, 3], windowSeconds: 10, offsetsMs: [3, 4])
    check(plan.count == 4 && plan.map(\.offsetMs) == [3, 4, 3, 4] && abs(plan[0].startSeconds - 1) < 1e-9 && abs(plan[3].clearSeconds - 8.5) < 1e-9,
          "探測排程：四台各 2 秒（含斜坡）、+3/+4 交錯、頭尾各留基準 1 秒")

    print(String(format: "── 耗時 %.1f 秒 ──", Date().timeIntervalSince(t0)))
    print(fail == 0 ? "✓ monitor 自測全部通過" : "✗ \(fail) 項失敗")
    return fail == 0 ? 0 : 1
}
#endif  // IU42_DIAG
