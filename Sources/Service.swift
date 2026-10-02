// Service.swift — LaunchAgent 常駐服務管理：install / uninstall / stop / status
//
// 規則：
// - 使用者的檔案（plist、安裝的執行檔…）不刪，一律 mv 到 ~/.Trash/（檔名加時間戳避免撞名）。
//   例外：自己產生的暫存檔與舊 log（只保留 1 份 .old）直接 FileManager.removeItem，不塞垃圾桶。
// - stop 一律送 SIGTERM（bootout 由 launchd 送 SIGTERM），讓 engine 乾淨清除 tap／聚合裝置；不送 SIGKILL。
// - 每個指令都支援 --dry-run：只印出會做的事，不複製、不寫 LaunchAgents、不呼叫 launchctl bootstrap/bootout、不送訊號。
//   install --dry-run --plist-out <路徑>：把會寫出的 plist 內容寫到指定路徑（給 plutil -lint 檢查）。
import Foundation

// MARK: - 路徑與常數

enum ServicePaths {
    static let label = "com.kang.In-Unison42"
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// ~/Library/Application Support/In_Unison42
    static var supportDir: URL { Config.directory }
    static var binDir: URL { supportDir.appendingPathComponent("bin", isDirectory: true) }
    /// 安裝後的執行檔（LaunchAgent 跑這份，不跑 build/ 那份，避免重編時跑到一半被換掉）
    static var installedBinary: URL { binDir.appendingPathComponent("In_Unison42") }
    static var pidFile: URL { supportDir.appendingPathComponent("run.pid") }
    static var launchAgentsDir: URL { home.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }
    static var plist: URL { launchAgentsDir.appendingPathComponent("\(label).plist") }
    static var logFile: URL { home.appendingPathComponent("Library/Logs/In_Unison42.log") }
    static var trashDir: URL { home.appendingPathComponent(".Trash", isDirectory: true) }
    /// log 超過這個大小時輪替成 .old（更舊的 .old 直接刪，只保留 1 份）
    static let logRotateBytes: UInt64 = 20 * 1024 * 1024

    static var uid: uid_t { getuid() }
    static var domain: String { "gui/\(uid)" }
    static var serviceTarget: String { "\(domain)/\(label)" }
}

// MARK: - 進入點

/// cmd ∈ install / uninstall / stop / status
func runService(_ cmd: String, args: [String]) -> Int32 {
    var opts = ServiceOptions()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--dry-run", "-n": opts.dryRun = true
        case "--force", "-f": opts.force = true
        case "--plist-out":
            guard i + 1 < args.count else { print("✗ --plist-out 需要一個路徑"); return 2 }
            opts.plistOut = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
            i += 1
        case "-h", "--help":
            print(serviceUsage); return 0
        default:
            print("✗ 不認得的參數：\(args[i])\n\(serviceUsage)"); return 2
        }
        i += 1
    }
    switch cmd {
    case "install":
        // 第 2 版起執行檔在 In_Unison42.app 裡（Info.plist 不再內嵌進執行檔），單獨複製出去跑 LaunchAgent 會拿不到
        // 系統音訊錄製的用途說明與固定簽章身分 → 停用；登入自動啟動改由 LoginItem（SMAppService.mainApp）負責
        print("✗ LaunchAgent 安裝已停用：第一期改用選單列 app＋登入項目（`In_Unison42 login-item on`，實作中）")
        print("  舊服務仍可用 stop／status／uninstall 管理")
        return 2
    case "uninstall": return serviceUninstall(opts)
    case "stop": return serviceStop(opts)
    case "status": return serviceStatus(opts)
    default:
        print("未知的服務指令：\(cmd)")
        return 2
    }
}

struct ServiceOptions {
    var dryRun = false
    var force = false
    var plistOut: URL? = nil
}

let serviceUsage = """
服務指令：
  install   [--dry-run] [--plist-out <路徑>] [--force]
            複製執行檔到 \(ServicePaths.installedBinary.path)
            寫 \(ServicePaths.plist.path) 並載入（登入時自動啟動、當掉自動重啟）
            --force：前景已有 In_Unison42 run 在跑也照樣安裝（兩個 tap 會互相靜音，不建議）
  uninstall [--dry-run]   停止服務，plist 與安裝的執行檔移到垃圾桶
  stop      [--dry-run]   停止服務（launchctl bootout，不刪檔；下次登入會再啟動）＋SIGTERM 手動跑的 run
  status                  launchd 狀態、pid、log 最後 10 行、設定摘要
"""

// MARK: - pid 檔（run 模式用；需要 main.swift 的 cmdRun 呼叫）

/// 在 run 模式開始時呼叫：把自己的 pid 寫到 ~/Library/Application Support/In_Unison42/run.pid。
/// 結束時（SIGINT/SIGTERM 走 Cleanup.runAll）把檔案內容清空；不刪檔。
/// 只給 status 顯示用；判斷「有沒有 run 在跑」一律用 findRunInstances()（真實執行檔路徑），不信任 pid 檔。
func writePidFile() {
    let url = ServicePaths.pidFile
    let me = getpid()
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(me)\n".write(to: url, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write("⚠ 無法寫 pid 檔 \(url.path)：\(error)\n".data(using: .utf8)!)
        return
    }
    Cleanup.register {
        // 只在內容仍是自己的 pid 時清空（避免清掉新實例寫的）
        if readPidFile() == me { try? "".write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// 讀 pid 檔；不存在／空／壞掉回 nil（不驗證行程是否存在）
func readPidFile() -> pid_t? {
    guard let s = try? String(contentsOf: ServicePaths.pidFile, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let v = Int32(t), v > 1 else { return nil }
    return v
}

// MARK: - 外部指令

struct ShellResult { let status: Int32; let out: String; let err: String }

@discardableResult
func shell(_ launchPath: String, _ args: [String]) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let o = Pipe(), e = Pipe()
    p.standardOutput = o
    p.standardError = e
    do { try p.run() } catch {
        return ShellResult(status: -1, out: "", err: "\(error)")
    }
    // 先讀完再 wait，避免輸出塞滿 pipe 卡死
    let od = o.fileHandleForReading.readDataToEndOfFile()
    let ed = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ShellResult(status: p.terminationStatus,
                       out: String(decoding: od, as: UTF8.self),
                       err: String(decoding: ed, as: UTF8.self))
}

// MARK: - launchd

struct LaunchdState {
    var loaded = false
    var state: String? = nil        // running / not running / …
    var pid: pid_t? = nil
    var lastExit: String? = nil     // "0"、"(never exited)"、"Terminated: 15" …
    var runs: String? = nil
    var program: String? = nil
}

/// launchctl print gui/<uid>/<label>；未載入回 loaded=false（rc 113）
func launchdState() -> LaunchdState {
    let r = shell("/bin/launchctl", ["print", ServicePaths.serviceTarget])
    var s = LaunchdState()
    guard r.status == 0 else { return s }
    s.loaded = true
    s = parseLaunchctlPrint(r.out, into: s)
    return s
}

/// 解析 launchctl print 輸出中頂層的幾個欄位（純字串處理，可單獨測）
func parseLaunchctlPrint(_ text: String, into base: LaunchdState = LaunchdState()) -> LaunchdState {
    var s = base
    s.loaded = true
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
        // 頂層欄位縮排一個 tab；巢狀區塊（如 environment）更深，跳過
        guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t") else { continue }
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let eq = line.range(of: " = ") else { continue }
        let k = String(line[..<eq.lowerBound])
        let v = String(line[eq.upperBound...])
        switch k {
        case "state": s.state = v
        case "pid": s.pid = Int32(v)
        case "last exit code": s.lastExit = v
        case "runs": s.runs = v
        case "program": s.program = v
        default: break
        }
    }
    return s
}

/// bootout 並等到 launchd 真的把它卸掉（最多約 timeout 秒）
@discardableResult
func launchdBootout(timeout: Double = 25) -> Bool {
    let r = shell("/bin/launchctl", ["bootout", ServicePaths.serviceTarget])
    if r.status != 0, !launchdState().loaded { return true }   // 本來就沒載入
    if r.status != 0 {
        print("⚠ launchctl bootout 回傳 \(r.status)：\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !launchdState().loaded { return true }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return !launchdState().loaded
}

/// bootstrap；剛 bootout 完偶爾會回 5（Input/output error），重試幾次
func launchdBootstrap() -> ShellResult {
    var last = ShellResult(status: -1, out: "", err: "")
    for attempt in 0..<5 {
        last = shell("/bin/launchctl", ["bootstrap", ServicePaths.domain, ServicePaths.plist.path])
        if last.status == 0 { return last }
        if attempt < 4 { Thread.sleep(forTimeInterval: 0.6) }
    }
    return last
}

// MARK: - 行程偵測

struct RunInstance { let pid: pid_t; let args: String }

/// 行程的真實執行檔路徑（proc_pidpath；不看命令列，所以 `lldb build/In_Unison42`、`vim …/In_Unison42` 不會被誤認）
func processExecutablePath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return nil }
    return String(cString: buf)
}

/// 行程的 argv（sysctl KERN_PROCARGS2：argc、exec 路徑、補零、argv…）；讀不到回 nil
func processArguments(_ pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    var argmax: Int32 = 0
    var sz = MemoryLayout<Int32>.size
    guard sysctl(&mib, 2, &argmax, &sz, nil, 0) == 0, argmax > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: Int(argmax))
    mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var len = buf.count
    guard sysctl(&mib, 3, &buf, &len, nil, 0) == 0, len > MemoryLayout<Int32>.size else { return nil }
    let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
    var i = MemoryLayout<Int32>.size
    while i < len && buf[i] != 0 { i += 1 }        // exec 路徑
    while i < len && buf[i] == 0 { i += 1 }        // 補零
    var args: [String] = []
    while args.count < Int(argc) && i < len {
        var j = i
        while j < len && buf[j] != 0 { j += 1 }
        args.append(String(decoding: buf[i..<j], as: UTF8.self))
        i = j + 1
    }
    return args
}

/// 純判斷（可單獨測）：真實執行檔 basename 是 In_Unison42，且 argv[1] 是 run、或沒有參數／以 "-" 開頭
/// （= 選單列 app 模式，LaunchServices 可能帶 -psn_…／-NS… 參數；app 也會開 tap）
func isRunInstance(executablePath: String, argv: [String]) -> Bool {
    guard (executablePath as NSString).lastPathComponent == "In_Unison42" else { return false }
    return argv.count < 2 || argv[1] == "run" || argv[1].hasPrefix("-")
}

/// 找出所有 In_Unison42 run 行程（不含自己）。
/// 以 proc_pidpath 的真實執行檔路徑判斷，不信任命令列字串、也不信任 pid 檔：
/// 舊 pid 檔（停電、kill -9 後）指到被重用的系統 daemon，或別的程式的參數剛好是 …/In_Unison42，都不會被當成 run。
func findRunInstances() -> [RunInstance] {
    let me = getpid()
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard got > 0 else { return [] }
    var found: [RunInstance] = []
    for pid in pids.prefix(Int(got)) where pid > 0 && pid != me {
        guard let path = processExecutablePath(pid), (path as NSString).lastPathComponent == "In_Unison42" else { continue }
        let argv = processArguments(pid) ?? [path]
        if isRunInstance(executablePath: path, argv: argv) {
            found.append(RunInstance(pid: pid, args: argv.joined(separator: " ")))
        }
    }
    return found.sorted { $0.pid < $1.pid }
}

/// `In_Unison42 service-selftest`：行程辨識自測（純函式＋實際開幾個會被舊邏輯誤判的行程）
func runServiceSelfTest() -> Int32 {
    var fail = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !ok { fail += 1 }
    }
    print("── 純判斷 isRunInstance ──")
    let bin = "/Users/x/Library/Application Support/In_Unison42/bin/In_Unison42"
    check(isRunInstance(executablePath: bin, argv: [bin, "run"]), "安裝版 run")
    check(isRunInstance(executablePath: bin, argv: [bin]), "沒參數（預設 run）")
    check(!isRunInstance(executablePath: bin, argv: [bin, "status"]), "status 不是 run")
    check(!isRunInstance(executablePath: "/usr/bin/lldb", argv: ["lldb", "build/In_Unison42"]), "lldb build/In_Unison42 不是")
    check(!isRunInstance(executablePath: "/usr/bin/vim", argv: ["vim", "/x/build/In_Unison42"]), "vim …/In_Unison42 不是")
    check(!isRunInstance(executablePath: "/usr/libexec/somedaemon", argv: ["/usr/libexec/somedaemon"]), "沒參數的系統 daemon（舊 pid 檔重用）不是")

    print("── 實際行程 ──")
    func spawn(_ exe: String, _ args: [String]) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = Pipe()
        do { try p.run() } catch { print("  （無法啟動 \(exe)：\(error)）"); return nil }
        return p
    }
    // 1. 命令列以 …/In_Unison42 結尾的別的程式（舊邏輯會判成 run）
    let fake = spawn("/bin/sh", ["-c", "sleep 20; :", "/tmp/build/In_Unison42"])
    // 2. 沒有參數的行程（模擬舊 pid 檔指到被重用的 daemon；舊邏輯 allowAnyName 會判成 run）
    let bare = spawn("/bin/cat", [])
    Thread.sleep(forTimeInterval: 0.3)
    let found = findRunInstances()
    if let f = fake {
        let argv = processArguments(f.processIdentifier) ?? []
        check(!found.contains { $0.pid == f.processIdentifier }, "sh -c … /tmp/build/In_Unison42 不算",
              "pid \(f.processIdentifier) argv=\(argv) path=\(processExecutablePath(f.processIdentifier) ?? "?")")
    } else { fail += 1 }
    if let c = bare {
        check(!found.contains { $0.pid == c.processIdentifier }, "沒參數的 /bin/cat 不算（即使 pid 檔指到它也一樣：pid 檔不再被信任）",
              "pid \(c.processIdentifier)")
    } else { fail += 1 }
    let st = launchdState()
    if let sp = st.pid {
        check(found.contains { $0.pid == sp }, "常駐服務 pid \(sp) 有被認出", found.map { "\($0.pid) \($0.args)" }.joined(separator: "; "))
    } else {
        print("  （常駐服務沒在跑，略過「認得出真的 run」這項）")
    }
    for p in [fake, bare].compactMap({ $0 }) { p.terminate(); p.waitUntilExit() }
    print(fail == 0 ? "✓ 全部通過" : "✗ \(fail) 項失敗")
    return fail == 0 ? 0 : 1
}

// MARK: - log 輪替（run 模式；stdout 是一般檔案時）

/// stdout 目前寫的檔案（fcntl F_GETPATH）；不是一般檔案（終端機、pipe）回 nil
func stdoutFilePath() -> String? {
    var st = stat()
    guard fstat(STDOUT_FILENO, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(STDOUT_FILENO, F_GETPATH, &buf) != -1 else { return nil }
    return String(cString: buf)
}

/// 輪替門檻：預設 ServicePaths.logRotateBytes；環境變數 IN_UNISON42_LOG_ROTATE_BYTES 可覆寫（測試用）
var logRotateThreshold: UInt64 {
    if let v = ProcessInfo.processInfo.environment["IN_UNISON42_LOG_ROTATE_BYTES"], let n = UInt64(v), n > 0 { return n }
    return ServicePaths.logRotateBytes
}

/// stdout 是一般檔案且超過門檻 → 刪掉更舊的 .old（自己產生的 log，直接 FileManager.removeItem、不丟垃圾桶）、
/// 目前的檔 mv 成 .old、stdout/stderr 重開到原路徑（新檔）。只保留 1 份 .old。回傳是否有輪替。
@discardableResult
func rotateStdoutLogIfNeeded(threshold: UInt64 = logRotateThreshold) -> Bool {
    guard let path = stdoutFilePath() else { return false }
    var st = stat()
    guard stat(path, &st) == 0, UInt64(st.st_size) > threshold else { return false }
    fflush(stdout); fflush(stderr)
    guard let old = rotateLogFile(path: path) else { return false }
    guard freopen(path, "a", stdout) != nil else { return false }
    setvbuf(stdout, nil, _IOLBF, 0)
    dup2(STDOUT_FILENO, STDERR_FILENO)
    print("log 輪替：上一段 \(st.st_size / 1024) KB 已移到 \(old.path)（只保留這 1 份，更舊的已刪；門檻 \(threshold / 1024) KB）")
    return true
}

/// 檔案層級的輪替：刪掉更舊的 <path>.old（自己產生的 log，FileManager.removeItem、不丟垃圾桶），再把 <path> rename 成 <path>.old。
/// 回傳 .old 的 URL；rename 失敗回 nil。不動 stdout（呼叫端負責重開）
func rotateLogFile(path: String) -> URL? {
    let fm = FileManager.default
    let old = URL(fileURLWithPath: path).appendingPathExtension("old")
    if fm.fileExists(atPath: old.path) {
        do { try fm.removeItem(at: old) } catch { print("⚠ log 輪替：刪不掉舊的 \(old.path)（\(error)）；rename 會直接取代它") }
    }
    return rename(path, old.path) == 0 ? old : nil
}

/// `In_Unison42 log-rotate-selftest`：輪替只留 1 份 .old、更舊的直接刪（不進垃圾桶）；只動暫存資料夾
func runLogRotateSelfTest() -> Int32 {
    var fail = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !ok { fail += 1 }
    }
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("In_Unison42-logrotate-selftest-\(getpid())", isDirectory: true)
    defer { try? fm.removeItem(at: dir) }
    try? fm.removeItem(at: dir)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("In_Unison42.log")
    let trashBefore = (try? fm.contentsOfDirectory(atPath: ServicePaths.trashDir.path)).map(Set.init)
    func read(_ u: URL) -> String? { (try? Data(contentsOf: u)).flatMap { String(data: $0, encoding: .utf8) } }
    try? Data("第一段".utf8).write(to: log)
    let o1 = rotateLogFile(path: log.path)
    check(o1 != nil && read(o1!) == "第一段" && !fm.fileExists(atPath: log.path), "第一次：log → .old")
    try? Data("第二段".utf8).write(to: log)
    let o2 = rotateLogFile(path: log.path)
    check(o2 != nil && read(o2!) == "第二段", "第二次：.old 換成第二段")
    let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    check(files == ["In_Unison42.log.old"], "資料夾裡只剩 1 份 .old", files.joined(separator: ","))
    if let before = trashBefore, let after = (try? fm.contentsOfDirectory(atPath: ServicePaths.trashDir.path)).map(Set.init) {
        check(after.subtracting(before).filter { $0.hasPrefix("In_Unison42.log") }.isEmpty, "沒有丟進垃圾桶")
    } else {
        print("  – 讀不到 ~/.Trash（沒有完整磁碟取用權限），略過「沒有丟進垃圾桶」這項")
    }
    check(rotateLogFile(path: dir.appendingPathComponent("不存在.log").path) == nil, "來源不存在 → nil")
    print(fail == 0 ? "✓ log 輪替自測全部通過" : "✗ \(fail) 項失敗")
    return fail == 0 ? 0 : 1
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

// MARK: - 檔案小工具（不刪檔：一律移到垃圾桶）

private func timestamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}

/// mv 到 ~/.Trash/<名字>-<時間戳>[-n]；回傳目的地
@discardableResult
func moveToTrash(_ url: URL, dryRun: Bool) -> URL? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil else { return nil }
    let ext = url.pathExtension
    let base = url.deletingPathExtension().lastPathComponent
    var dest: URL
    var n = 0
    repeat {
        let suffix = "-\(timestamp())" + (n == 0 ? "" : "-\(n)")
        dest = ServicePaths.trashDir.appendingPathComponent(base + suffix + (ext.isEmpty ? "" : ".\(ext)"))
        n += 1
    } while fm.fileExists(atPath: dest.path)
    if dryRun {
        print("  [dry-run] mv \(url.path) → \(dest.path)")
        return dest
    }
    do {
        try fm.createDirectory(at: ServicePaths.trashDir, withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: dest)
        print("  已移到垃圾桶：\(url.path) → \(dest.path)")
        return dest
    } catch {
        print("⚠ 無法移到垃圾桶：\(url.path)（\(error)）")
        return nil
    }
}

/// 目前執行中的執行檔（解析 symlink）
func currentExecutable() -> URL? {
    if let u = Bundle.main.executableURL { return u.resolvingSymlinksInPath() }
    let a0 = CommandLine.arguments.first ?? ""
    guard !a0.isEmpty else { return nil }
    return URL(fileURLWithPath: a0).standardizedFileURL.resolvingSymlinksInPath()
}

private func filesEqual(_ a: URL, _ b: URL) -> Bool {
    guard let da = try? Data(contentsOf: a, options: .mappedIfSafe),
          let db = try? Data(contentsOf: b, options: .mappedIfSafe) else { return false }
    return da == db
}

// MARK: - plist

/// LaunchAgent plist 內容（純函式，可單獨測）
func launchAgentPlist(binary: String, logPath: String) -> [String: Any] {
    [
        "Label": ServicePaths.label,
        "ProgramArguments": [binary, "run"],
        "RunAtLoad": true,
        // 只有非 0 結束（當掉）才重啟；SIGTERM → main 乾淨 exit(0) 不會被拉起
        "KeepAlive": ["SuccessfulExit": false],
        "ThrottleInterval": 5,
        "StandardOutPath": logPath,
        "StandardErrorPath": logPath,
        "ProcessType": "Interactive",
    ]
}

func launchAgentPlistData(binary: String, logPath: String) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: launchAgentPlist(binary: binary, logPath: logPath),
                                       format: .xml, options: 0)
}

// MARK: - install

func serviceInstall(_ o: ServiceOptions) -> Int32 {
    let fm = FileManager.default
    let dry = o.dryRun
    let target = ServicePaths.installedBinary
    print("安裝 In_Unison42 常駐服務\(dry ? "（dry-run：不會改任何東西）" : "")")

    // 1. 前景實例檢查（同時兩個 tap 會互相靜音）
    let st0 = launchdState()
    let manual = findRunInstances().filter { $0.pid != st0.pid }
    if !manual.isEmpty {
        print("⚠ 偵測到手動執行中的 In_Unison42 run（兩個 tap 同時存在會互相靜音）：")
        for m in manual { print("    pid \(m.pid)  \(m.args)") }
        if !o.force {
            print("  請先結束它（Ctrl-C 或 `In_Unison42 stop`），或加 --force 照樣安裝。")
            return 1
        }
        print("  --force：照樣安裝")
    }

    // 2. 來源執行檔
    guard let src = currentExecutable(), fm.isExecutableFile(atPath: src.path) else {
        print("✗ 找不到目前的執行檔路徑")
        return 1
    }
    print("來源執行檔：\(src.path)")

    // 3. plist 內容
    let plistData: Data
    do {
        plistData = try launchAgentPlistData(binary: target.path, logPath: ServicePaths.logFile.path)
    } catch {
        print("✗ 產生 plist 失敗：\(error)")
        return 1
    }

    if dry {
        if let out = o.plistOut {
            do {
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try plistData.write(to: out, options: .atomic)
                print("  [dry-run] plist 內容已寫到 \(out.path)（不是 LaunchAgents）")
            } catch {
                print("✗ 寫 \(out.path) 失敗：\(error)")
                return 1
            }
        } else {
            print("  [dry-run] plist 內容：")
            print(String(decoding: plistData, as: UTF8.self))
        }
    }

    // 4. 已載入 → 先 bootout（執行檔可能正被它使用）
    if st0.loaded {
        if dry {
            print("  [dry-run] launchctl bootout \(ServicePaths.serviceTarget)（目前已載入，pid \(st0.pid.map(String.init) ?? "無")）")
        } else {
            print("服務已載入，先卸載…")
            guard launchdBootout() else {
                print("✗ bootout 後服務仍在，放棄安裝")
                return 1
            }
        }
    }

    // 5. 複製執行檔
    var binaryChanged = true
    if src.standardizedFileURL.path == target.standardizedFileURL.path {
        print("目前就是從安裝位置執行，不複製")
        binaryChanged = false
    } else if fm.fileExists(atPath: target.path), filesEqual(src, target) {
        print("安裝位置的執行檔內容相同，不複製（系統錄音授權不受影響）")
        binaryChanged = false
    } else {
        if dry {
            print("  [dry-run] mkdir -p \(ServicePaths.binDir.path)")
        } else {
            do { try fm.createDirectory(at: ServicePaths.binDir, withIntermediateDirectories: true) } catch {
                print("✗ 建立 \(ServicePaths.binDir.path) 失敗：\(error)"); return 1
            }
        }
        if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            guard moveToTrash(target, dryRun: dry) != nil else { return 1 }
        }
        if dry {
            print("  [dry-run] cp \(src.path) → \(target.path)")
        } else {
            do {
                try fm.copyItem(at: src, to: target)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                print("已複製執行檔 → \(target.path)")
            } catch {
                print("✗ 複製執行檔失敗：\(error)"); return 1
            }
        }
    }

    // 6. log 輪替（太大時）
    if let size = (try? fm.attributesOfItem(atPath: ServicePaths.logFile.path))?[.size] as? UInt64,
       size > ServicePaths.logRotateBytes {
        let old = ServicePaths.logFile.appendingPathExtension("old")
        // 更舊的 .old 是自己產生的 log：直接刪（只保留 1 份 .old），不丟垃圾桶
        if fm.fileExists(atPath: old.path) {
            if dry { print("  [dry-run] 刪除舊 log \(old.path)") } else { try? fm.removeItem(at: old) }
        }
        if dry {
            print("  [dry-run] mv \(ServicePaths.logFile.path) → \(old.path)（\(size / 1024 / 1024) MB）")
        } else {
            try? fm.moveItem(at: ServicePaths.logFile, to: old)
        }
    }

    // 7. 寫 plist
    if dry {
        print("  [dry-run] 寫 \(ServicePaths.plist.path)")
        print("  [dry-run] launchctl bootstrap \(ServicePaths.domain) \(ServicePaths.plist.path)")
    } else {
        do {
            try fm.createDirectory(at: ServicePaths.launchAgentsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: ServicePaths.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plistData.write(to: ServicePaths.plist, options: .atomic)
            print("已寫入 \(ServicePaths.plist.path)")
        } catch {
            print("✗ 寫 plist 失敗：\(error)"); return 1
        }
        let lint = shell("/usr/bin/plutil", ["-lint", ServicePaths.plist.path])
        if lint.status != 0 {
            print("✗ plist 檢查失敗：\(lint.out)\(lint.err)"); return 1
        }
        // 8. 載入
        let r = launchdBootstrap()
        if r.status != 0 {
            print("✗ launchctl bootstrap 失敗（\(r.status)）：\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
            print("  可以看 log：\(ServicePaths.logFile.path)")
            return 1
        }
        Thread.sleep(forTimeInterval: 1.0)
        let st = launchdState()
        print("✓ 已載入 \(ServicePaths.serviceTarget)：state=\(st.state ?? "?") pid=\(st.pid.map(String.init) ?? "無")")
    }

    // 9. 權限提醒
    print("""

    ── 權限提醒 ──
    首次啟動時 macOS 會要求「系統音訊錄製」權限，名稱是 In_Unison42。
    若沒跳出來或聲音沒出去：系統設定 → 隱私權與安全性 → 螢幕與系統錄音 → 僅系統錄音 → 允許 In_Unison42。
    \(binaryChanged ? "這次執行檔有更新（ad-hoc 簽章 cdhash 會變），可能需要重新授權一次。\n" : "")未授權時 log 會出現「IOProc 沒被呼叫」的警告：\(ServicePaths.logFile.path)
    查看狀態：In_Unison42 status
    """)
    return 0
}

// MARK: - uninstall

func serviceUninstall(_ o: ServiceOptions) -> Int32 {
    let dry = o.dryRun
    print("移除 In_Unison42 常駐服務\(dry ? "（dry-run：不會改任何東西）" : "")")
    var rc: Int32 = 0
    let st = launchdState()
    if st.loaded {
        if dry {
            print("  [dry-run] launchctl bootout \(ServicePaths.serviceTarget)（pid \(st.pid.map(String.init) ?? "無")）")
        } else if launchdBootout() {
            print("已卸載 \(ServicePaths.serviceTarget)")
        } else {
            print("✗ bootout 後服務仍在"); rc = 1
        }
    } else {
        print("服務未載入")
    }
    let fm = FileManager.default
    if fm.fileExists(atPath: ServicePaths.plist.path) {
        if moveToTrash(ServicePaths.plist, dryRun: dry) == nil { rc = 1 }
    } else {
        print("沒有 plist：\(ServicePaths.plist.path)")
    }
    if fm.fileExists(atPath: ServicePaths.installedBinary.path) {
        if moveToTrash(ServicePaths.installedBinary, dryRun: dry) == nil { rc = 1 }
    } else {
        print("沒有安裝的執行檔：\(ServicePaths.installedBinary.path)")
    }
    print("設定檔保留：\(Config.fileURL.path)；log 保留：\(ServicePaths.logFile.path)")
    let manual = findRunInstances().filter { $0.pid != st.pid }
    if !manual.isEmpty {
        print("⚠ 還有手動執行中的 In_Unison42 run：\(manual.map { String($0.pid) }.joined(separator: ", "))（用 `In_Unison42 stop` 結束）")
    }
    if rc == 0 { print(dry ? "（dry-run 完成）" : "✓ 已移除") }
    return rc
}

// MARK: - stop

func serviceStop(_ o: ServiceOptions) -> Int32 {
    let dry = o.dryRun
    var rc: Int32 = 0
    var didSomething = false
    let st = launchdState()
    if st.loaded {
        didSomething = true
        if dry {
            print("  [dry-run] launchctl bootout \(ServicePaths.serviceTarget)（pid \(st.pid.map(String.init) ?? "無")）")
        } else if launchdBootout() {
            print("✓ 已停止 LaunchAgent（plist 保留；下次登入會再啟動，現在要再開請執行 In_Unison42 start）")
        } else {
            print("✗ bootout 後服務仍在"); rc = 1
        }
    }
    let manual = findRunInstances().filter { $0.pid != st.pid }
    for m in manual {
        didSomething = true
        if dry {
            print("  [dry-run] kill -TERM \(m.pid)  (\(m.args))")
            continue
        }
        if kill(m.pid, SIGTERM) != 0 {
            print("✗ 無法送 SIGTERM 給 \(m.pid)：\(String(cString: strerror(errno)))"); rc = 1
            continue
        }
        // 等它自己清乾淨結束（engine.stop 會銷毀 tap／聚合裝置）
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, kill(m.pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.1) }
        if kill(m.pid, 0) == 0 {
            print("⚠ pid \(m.pid) 送出 SIGTERM 10 秒後仍在（不會強制 kill；要強制請自行 kill -9）"); rc = 1
        } else {
            print("✓ 已結束手動執行的 pid \(m.pid)")
        }
    }
    if !didSomething { print("沒有執行中的 In_Unison42（launchd 未載入、也沒有手動跑的 run）") }
    return rc
}

// MARK: - status

/// 讀檔案最後 n 行（只讀尾端 64KB）
func tailLines(_ url: URL, _ n: Int) -> [String]? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    let chunk: UInt64 = 64 * 1024
    let start = size > chunk ? size - chunk : 0
    try? h.seek(toOffset: start)
    let data = (try? h.readToEnd()) ?? Data()
    var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    if start > 0, !lines.isEmpty { lines.removeFirst() }     // 第一行可能被切半
    while let l = lines.last, l.isEmpty { lines.removeLast() }
    return Array(lines.suffix(n))
}

func serviceStatus(_ o: ServiceOptions) -> Int32 {
    let fm = FileManager.default
    let st = launchdState()
    print("── LaunchAgent \(ServicePaths.label) ──")
    print("plist：\(fm.fileExists(atPath: ServicePaths.plist.path) ? ServicePaths.plist.path : "未安裝")")
    print("執行檔：\(fm.fileExists(atPath: ServicePaths.installedBinary.path) ? ServicePaths.installedBinary.path : "未安裝")")
    if st.loaded {
        print("launchd：已載入　state=\(st.state ?? "?")　pid=\(st.pid.map(String.init) ?? "無")　runs=\(st.runs ?? "?")　last exit=\(st.lastExit ?? "?")")
    } else {
        print("launchd：未載入")
    }
    let manual = findRunInstances().filter { $0.pid != st.pid }
    if manual.isEmpty {
        print("手動執行的 run：無")
    } else {
        for m in manual { print("手動執行的 run：pid \(m.pid)  \(m.args)") }
        if st.pid != nil { print("⚠ LaunchAgent 與手動實例同時在跑，兩個 tap 會互相靜音") }
    }
    if let p = readPidFile() {
        let who = isAlive(p) ? (processExecutablePath(p).map { ($0 as NSString).lastPathComponent == "In_Unison42" } ?? false
                                ? "（存活）" : "（pid 已被別的行程重用，殘留）") : "（已不存在，殘留）"
        print("pid 檔：\(p)\(who)")
    }

    print("\n── log 最後 10 行（\(ServicePaths.logFile.path)）──")
    if let lines = tailLines(ServicePaths.logFile, 10) {
        if lines.isEmpty { print("（空）") } else { lines.forEach { print($0) } }
    } else {
        print("（沒有 log 檔）")
    }

    print("\n── 設定（\(Config.fileURL.path)）──")
    if !fm.fileExists(atPath: Config.fileURL.path) { print("（沒有設定檔，全部用預設：延遲 0、trim 0）") }
    let cfg = Config.load()
    print("calibratedAt：\(cfg.calibratedAt ?? "未校正")　模式：\(cfg.mode.label)\(cfg.manualLock ? "（手動鎖定）" : "")　校正麥克風：\(cfg.calibrationMicUID ?? "自動")")
    let outs = Devices.physicalOutputs() + Devices.bluetoothOutputs()
    var shown = Set<String>()
    for d in outs {
        shown.insert(d.uid)
        let dc = cfg.device(d.uid)
        let set = cfg.devices[d.uid] != nil
        print(String(format: "  %@%@  實測延遲=%@  trimDb=%+.2f%@%@",
                     d.name, d.kind.isBluetooth ? "（藍牙）" : "",
                     dc.measuredLatencyMs.map { String(format: "%.2fms", $0) } ?? "未量測", dc.trimDb,
                     dc.enabled ? "" : "（已關閉）", set ? "" : "（未設定）"))
    }
    for (uid, dc) in cfg.devices.sorted(by: { $0.key < $1.key }) where !shown.contains(uid) {
        let name = Devices.device(uid: uid)?.name ?? "（目前未連接）"
        print(String(format: "  %@ [%@]  實測延遲=%@  trimDb=%+.2f", name, uid,
                     dc.measuredLatencyMs.map { String(format: "%.2fms", $0) } ?? "未量測", dc.trimDb))
    }
    let devs = outs.map { PlanDevice(uid: $0.uid, name: $0.name, isBuiltIn: $0.kind == .builtIn, requiresMeasurement: $0.kind.isBluetooth, config: cfg) }
    for m in PlayMode.allCases {
        let p = plan(devices: devs, mode: m, caps: cfg.modeCaps)
        print("  \(m.label)模式：" + devs.map { d in
            guard let e = p[d.uid] else { return d.name }
            return e.active ? String(format: "%@ %.2fms", d.name, e.delayMs) : "✕\(d.name)"
        }.joined(separator: "、"))
    }
    if let st = AppRuntimeState.load() {
        print("\n── 選單列 app 狀態（\(AppRuntimeState.fileURL.path)）──")
        print(st.summary)
    }
    return 0
}
