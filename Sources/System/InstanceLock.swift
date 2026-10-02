// InstanceLock.swift — 「同一時間只能有一個 tap 實例」的鎖（flock）
//
// 兩個全域 tap 會互相靜音，所以選單列 app、CLI run、獨立跑的 calibrate／engine-live-test 開 tap 前都要拿這把鎖：
//   ~/Library/Application Support/In_Unison42/instance.lock（flock LOCK_EX|LOCK_NB；檔案內容 = 持有者 pid，只給人看／給子行程判斷）
// flock 由核心保證互斥，行程結束（含 kill -9、當掉）時自動釋放 → 沒有 TOCTOU、沒有殘留鎖。
// 例外：app 呼叫的校正子行程（IN_UNISON42_CALIBRATE_PARENT = app pid）不拿鎖——app 已暫停自己的引擎、鎖仍由 app 持有，
//   子行程只確認「持有者就是 parent」。
// 舊版（沒有這把鎖的）執行檔：只剩舊 LaunchAgent 的 bin/In_Unison42 可能還在跑，另外用 findLegacyRunInstances() 看。
import Darwin
import Foundation

enum InstanceLock {
    static var url: URL { Config.directory.appendingPathComponent("instance.lock") }

    private static let guardLock = NSLock()
    private static var fd: Int32 = -1

    /// 本行程是否持有鎖
    static var isHeld: Bool { guardLock.lock(); defer { guardLock.unlock() }; return fd >= 0 }

    /// 非阻塞取得鎖。成功（或本來就持有）回 true，並把自己的 pid 寫進檔案
    @discardableResult
    static func tryAcquire() -> Bool {
        guardLock.lock(); defer { guardLock.unlock() }
        if fd >= 0 { return true }
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let f = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard f >= 0 else { return false }
        guard flock(f, LOCK_EX | LOCK_NB) == 0 else { close(f); return false }
        let s = "\(getpid())\n"
        _ = ftruncate(f, 0)
        _ = s.withCString { pwrite(f, $0, strlen($0), 0) }
        fd = f
        return true
    }

    /// 釋放（行程結束時核心也會自動釋放）
    static func release() {
        guardLock.lock(); defer { guardLock.unlock() }
        guard fd >= 0 else { return }
        _ = ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// 目前持有鎖的 pid（沒人持有 → nil；本行程持有 → getpid()）。
    /// 用另一個 open file description 試鎖：拿得到 = 沒人持有（立刻放掉）
    static func holderPID() -> pid_t? {
        if isHeld { return getpid() }
        let f = open(url.path, O_RDONLY | O_CLOEXEC)
        guard f >= 0 else { return nil }
        defer { close(f) }
        if flock(f, LOCK_SH | LOCK_NB) == 0 { flock(f, LOCK_UN); return nil }
        var buf = [UInt8](repeating: 0, count: 32)
        let n = pread(f, &buf, buf.count, 0)
        guard n > 0 else { return -1 }   // 有人持有但還沒寫 pid
        let s = String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(s) ?? -1
    }
}

/// 沒有 InstanceLock 的舊版 run（舊 LaunchAgent 的 ~/Library/Application Support/In_Unison42/bin/In_Unison42，
/// 或 launchd 還載入著的舊服務）。新版執行檔一律用 InstanceLock 判斷，不再比對行程清單。
func findLegacyRunInstances() -> [RunInstance] {
    let legacyBin = ServicePaths.installedBinary.resolvingSymlinksInPath().path
    let launchdPid = launchdState().pid
    return findRunInstances().filter { inst in
        if let p = launchdPid, inst.pid == p { return true }
        guard let path = processExecutablePath(inst.pid) else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == legacyBin
    }
}

/// 開 tap 前的檢查（CLI run／calibrate／live test 用）：拿鎖＋沒有舊版在跑。回傳 nil = 可以開；否則回傳原因
func acquireTapInstance() -> String? {
    let legacy = findLegacyRunInstances()
    if !legacy.isEmpty {
        return "舊版 LaunchAgent 的 In_Unison42 在跑（pid \(legacy.map { String($0.pid) }.joined(separator: ", "))），兩個 tap 會互相靜音"
    }
    if !InstanceLock.tryAcquire() {
        let h = InstanceLock.holderPID()
        return "另一個 In_Unison42 持有實例鎖（pid \(h.map(String.init) ?? "?")，\(InstanceLock.url.path)），兩個 tap 會互相靜音"
    }
    return nil
}
