// LiveTest.swift — `In_Unison42 engine-live-test`：實機驗證 Engine 第 2 版的執行中 API（會開 tap、出節目音）
//
// 驗：模式切換不重建（generation 不變）、plan 的出聲遮罩與延遲寫進 RT、tap 排除清單直接更新、外接輸出槽、節目音廣播緩衝。
// 不改預設輸出、音量、靜音（開始記原值、結束比對）。同一時間只能有一個 tap：有別的實例在跑就拒絕。
// 要讓 IO 真的跑，請用 app 身分啟動（TCC）：open -W --stdout <log> build/In_Unison42.app --args engine-live-test
import CoreAudio
import Foundation

#if IU42_DIAG  // 實機測試（會開 tap、調音量／切預設輸出）：只編進 debug；發行版沒有這些指令

func runEngineLiveTest() -> Int32 {
    var fail = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !ok { fail += 1 }
    }
    func wait(_ s: Double) { Thread.sleep(forTimeInterval: s) }

    if let why = acquireTapInstance() {
        print("✗ \(why)；先結束它")
        return 3
    }
    let snap = SystemAudioSnapshot.capture()
    print("系統狀態（開始）：\(snap)")
    let engine = Engine(config: Config.load(), mode: .music)
    engine.log = { print("  [engine] \($0)") }
    defer {
        engine.stop()
        let after = SystemAudioSnapshot.capture()
        print("系統狀態（結束）：\(after)")
        if after.description != snap.description { print("⚠ 系統狀態和開始不同（本測試不會改它；可能是使用者自己改的）") }
    }
    do { try engine.start() } catch { print("✗ 引擎啟動失敗：\(error)"); return 1 }
    let c0 = engine.ioCycles
    wait(1.5)
    let io = engine.ioCycles - c0
    check(io > 10, "IO 前進", "1.5 秒 \(io) 個週期")
    let outs = engine.outputDetails
    let g0 = engine.generation
    func st() -> EngineStatus { engine.status(resetPeaks: false) }
    func activeMap() -> [String: Bool] { Dictionary(uniqueKeysWithValues: st().outputs.map { ($0.uid, $0.active) }) }
    func delayMap() -> [String: Double] { Dictionary(uniqueKeysWithValues: st().outputs.map { ($0.uid, $0.delayMs) }) }

    print("── 1. 模式切換（不重建聚合裝置）──")
    let cfg = engine.config
    for m in [PlayMode.game, .movie, .music] {
        engine.setMode(m)
        wait(0.4)
        let devs = outs.map { PlanDevice(uid: $0.uid, name: $0.name, isBuiltIn: $0.kind == .builtIn, config: cfg) }
        let want = plan(devices: devs, mode: m, caps: cfg.modeCaps)
        let a = activeMap(), d = delayMap()
        let sr = engine.sampleRate
        let okActive = outs.allSatisfy { a[$0.uid] == want[$0.uid]?.active }
        let okDelay = outs.allSatisfy { abs((d[$0.uid] ?? -1) - (want[$0.uid]?.delayMs ?? -2)) <= 1000 / sr + 1e-9 }
        check(engine.mode == m && okActive && okDelay && engine.generation == g0,
              "\(m.label)：遮罩與延遲 = plan()，generation 不變",
              outs.map { String(format: "%@ %@ %.2fms", $0.name, a[$0.uid] == true ? "出聲" : "✕", d[$0.uid] ?? -1) }.joined(separator: "、")
                + "；gen \(engine.generation)")
    }
    check(engine.ioCycles > c0 + 50, "切換期間 IO 持續前進")

    print("── 2. tap 排除清單（系統提示音用）──")
    let me = Devices.processObject()
    let procs = CA.ids(CA.system, kAudioHardwarePropertyProcessObjectList).filter { $0 != me }
    if let victim = procs.first {
        let g1 = engine.generation
        let ok = engine.setExtraExcludedProcesses([victim])
        wait(0.3)
        check(ok, "設定排除 process object \(victim)", engine.generation == g1 ? "直接更新 tap，未重建" : "改用重建 gen \(g1)→\(engine.generation)")
        let c1 = engine.ioCycles
        wait(0.5)
        check(engine.ioCycles > c1, "更新後 IO 仍前進")
        let ok2 = engine.setExtraExcludedProcesses([])
        check(ok2 && engine.extraExcludedProcesses.isEmpty, "清空排除清單")
    } else {
        check(false, "找不到其他 process object 可以測")
    }

    print("── 3. 外接輸出槽（藍牙只輸出路徑用）──")
    engine.setMode(.music)
    if let slot = engine.registerExternalOutput(uid: "live-test-ext", name: "測試外接") {
        let pr = engine.program
        wait(0.2)
        let e1 = engine.planEntry(uid: "live-test-ext")
        check(e1?.active == true && pr.extActive[slot] == 1 && pr.extUsed[slot] == 1,
              "音樂模式：未量測的外接輸出出聲、不補償", "\(e1.map(String.init(describing:)) ?? "nil") gain=\(pr.extGain[slot])")
        engine.setMode(.game)
        wait(0.2)
        let e2 = engine.planEntry(uid: "live-test-ext")
        check(e2?.active == false && pr.extActive[slot] == 0 && pr.extGain[slot] == 0, "遊戲模式：未量測 → 不出聲、增益 0",
              "\(e2.map(String.init(describing:)) ?? "nil")")
        check(engine.registerExternalOutput(uid: "live-test-ext", name: "重複") == nil, "同 uid 重複註冊被拒")
        engine.unregisterExternalOutput(slot: slot)
        check(engine.planEntry(uid: "live-test-ext") == nil && pr.extUsed[slot] == 0, "取消註冊後不在計畫裡")
        engine.setMode(.music)
    } else {
        check(false, "註冊外接輸出失敗")
    }

    print("── 4. 節目音廣播緩衝 ──")
    do {
        let pr = engine.program
        let e0 = pr.writeEnd.pointee
        wait(0.3)
        let e1 = pr.writeEnd.pointee
        check(e1 > e0, "writeEnd 前進", "\(e0) → \(e1)")
        let n = 512
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 2 * n)
        defer { buf.deallocate() }
        let ok = pr.read(from: pr.writeEnd.pointee - Int64(n) - 64, frames: n, into: buf)
        var pk: Float = 0
        for i in 0..<(2 * n) { pk = max(pk, abs(buf[i])) }
        check(ok, "讀最近 512 frame 成功", String(format: "峰值 %.3f（0 = 目前沒有節目音）", pk))
        check(!pr.read(from: pr.writeEnd.pointee + 48000, frames: n, into: buf), "讀未來區間失敗")
        let clk = pr.clock()
        check(clk != nil && clk!.hostTime > 0 && pr.sampleRate.pointee == engine.sampleRate, "時鐘有 hostTime、取樣率一致",
              clk.map { "sampleTime \($0.sampleTime) host \($0.hostTime)" } ?? "nil")
    }

    print(fail == 0 ? "✓ engine 實機測試全部通過" : "✗ \(fail) 項失敗")
    return fail == 0 ? 0 : 1
}

/// `In_Unison42 snapshot-live-test`：實機驗證 SystemAudioSnapshot.restore() 的「只往下調、不覆蓋使用者操作」。
/// 會短暫調低音量（最多 −0.08）、切一次靜音、把預設輸出切到另一台再切回；結束時設回測試開始的原值（只會回到原值，不會更高）。
/// 「使用者操作」用直接呼叫 Devices.set…（不經過快照）模擬。
func runSnapshotLiveTest() -> Int32 {
    var fail = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !ok { fail += 1 }
    }
    func wait() { usleep(150_000) }
    let s0 = SystemAudioSnapshot.capture()
    print("系統狀態（開始）：\(s0)")
    guard let out = s0.originalOutput, let v0 = s0.volumeScalar, v0 >= 0.10, !s0.muted else {
        print("✗ 需要：預設輸出有音量、音量 ≥ 10、未靜音"); return 1
    }
    func vol() -> Float { Devices.volumeScalar(out.id) ?? -1 }
    func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.006 }
    defer {
        // 收尾：預設輸出回原值；音量只在 ≤ 原值時設回原值（我們調低的）；靜音回原值
        if let d = s0.defaultOutputUID.flatMap({ Devices.device(uid: $0) }), Devices.defaultOutput()?.uid != d.uid {
            CA.set(CA.system, kAudioHardwarePropertyDefaultOutputDevice, d.id)
        }
        if let d = s0.defaultSystemOutputUID.flatMap({ Devices.device(uid: $0) }), Devices.defaultSystemOutput()?.uid != d.uid {
            CA.set(CA.system, kAudioHardwarePropertyDefaultSystemOutputDevice, d.id)
        }
        if vol() <= v0 + 0.001 { Devices.setVolumeScalar(out.id, v0) }
        if Devices.isMuted(out.id) != s0.muted { Devices.setMuted(out.id, s0.muted) }
        print("系統狀態（結束）：\(SystemAudioSnapshot.capture())")
    }

    print("── A. 流程中使用者自己調低（校正時嫌大聲）→ restore 不可調回去 ──")
    var s = SystemAudioSnapshot.capture()
    Devices.setVolumeScalar(out.id, v0 - 0.08); wait()      // 使用者
    var did = s.restore(); wait()
    check(near(vol(), v0 - 0.08), "音量維持使用者調的值", String(format: "目前 %.0f、原值 %.0f、restore 做了 %@", vol() * 100, v0 * 100, did.description))
    Devices.setVolumeScalar(out.id, v0); wait()

    print("── B. 流程自己調低 → 使用者再調更低 → restore 不可升回原值 ──")
    s = SystemAudioSnapshot.capture()
    s.setVolume(v0 - 0.04); wait()
    Devices.setVolumeScalar(out.id, v0 - 0.08); wait()      // 使用者
    did = s.restore(); wait()
    check(near(vol(), v0 - 0.08), "音量維持使用者調的值", String(format: "目前 %.0f、restore 做了 %@", vol() * 100, did.description))
    Devices.setVolumeScalar(out.id, v0); wait()

    print("── C. 流程自己調低、使用者沒動 → restore 回到原值（只回到原值）──")
    s = SystemAudioSnapshot.capture()
    s.setVolume(v0 - 0.06); wait()
    let r1 = s.setVolume(v0 + 0.20)                          // 要求高於原值 → 只能到原值
    check(r1.map { near($0, v0) } ?? false, "setVolume 要求高於原值時只設到原值", String(format: "%.0f", (r1 ?? -1) * 100))
    s.setVolume(v0 - 0.06); wait()
    did = s.restore(); wait()
    check(near(vol(), v0), "回到原值", String(format: "目前 %.0f、restore 做了 %@", vol() * 100, did.description))

    print("── D. 使用者中途把預設輸出切到別台 → restore 不切回、不把音量套到那台 ──")
    let other = Devices.physicalOutputs().first { $0.uid != out.uid }
    if let other {
        s = SystemAudioSnapshot.capture()
        let otherVol0 = Devices.volumeScalar(other.id)
        Devices.setDefaultOutput(other.id, alsoSystemOutput: false); wait()   // 使用者
        did = s.restore(); wait()
        check(Devices.defaultOutput()?.uid == other.uid, "預設輸出維持使用者選的「\(other.name)」", did.description)
        check(Devices.volumeScalar(other.id) == otherVol0, "那台的音量沒被動", "\(String(describing: otherVol0)) → \(String(describing: Devices.volumeScalar(other.id)))")
        check(near(vol(), v0), "原裝置音量不變")
        CA.set(CA.system, kAudioHardwarePropertyDefaultOutputDevice, out.id); wait()

        print("── E. 流程自己切預設輸出 → restore 切回 ──")
        s = SystemAudioSnapshot.capture()
        Devices.setDefaultOutput(other.id, alsoSystemOutput: false); s.noteSetDefaultOutput(other.uid); wait()
        did = s.restore(); wait()
        check(Devices.defaultOutput()?.uid == out.uid, "預設輸出切回「\(out.name)」", did.description)
    } else {
        print("  （只有一台輸出，略過 D、E）")
    }

    print("── F. 靜音：我們設的會解除；使用者自己按的不解除 ──")
    s = SystemAudioSnapshot.capture()
    s.setMuted(true); wait()
    did = s.restore(); wait()
    check(!Devices.isMuted(out.id), "我們設的靜音已解除", did.description)
    s = SystemAudioSnapshot.capture()
    Devices.setMuted(out.id, true); wait()                   // 使用者
    did = s.restore(); wait()
    check(Devices.isMuted(out.id), "使用者按的靜音維持", did.description)
    Devices.setMuted(out.id, false); wait()

    print(fail == 0 ? "✓ SystemAudioSnapshot 實機測試全部通過" : "✗ \(fail) 項失敗")
    return fail == 0 ? 0 : 1
}
#endif  // IU42_DIAG
