// Devices.swift — Core Audio 裝置列舉／屬性工具（非即時執行緒專用，IOProc 內不可呼叫）
import CoreAudio
import Foundation

// MARK: - 低階屬性工具

/// Core Audio 屬性存取的薄包裝。全部是同步呼叫，只能在非即時執行緒用。
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ s: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: element)
    }

    static func has(_ id: AudioObjectID, _ s: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    _ element: UInt32 = kAudioObjectPropertyElementMain) -> Bool {
        var a = addr(s, scope, element)
        return AudioObjectHasProperty(id, &a)
    }

    static func isSettable(_ id: AudioObjectID, _ s: AudioObjectPropertySelector,
                           _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                           _ element: UInt32 = kAudioObjectPropertyElementMain) -> Bool {
        var a = addr(s, scope, element)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &a),
              AudioObjectIsPropertySettable(id, &a, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func get<T>(_ id: AudioObjectID, _ s: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       _ element: UInt32 = kAudioObjectPropertyElementMain, as _: T.Type) -> T? {
        var a = addr(s, scope, element)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var sz = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, p) == noErr else { return nil }
        return p.load(as: T.self)
    }

    @discardableResult
    static func set<T>(_ id: AudioObjectID, _ s: AudioObjectPropertySelector, _ value: T,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       _ element: UInt32 = kAudioObjectPropertyElementMain) -> OSStatus {
        var a = addr(s, scope, element)
        return withUnsafeBytes(of: value) { raw in
            AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(raw.count), raw.baseAddress!)
        }
    }

    static func u32(_ id: AudioObjectID, _ s: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    _ element: UInt32 = kAudioObjectPropertyElementMain) -> UInt32? {
        get(id, s, scope, element, as: UInt32.self)
    }

    static func f32(_ id: AudioObjectID, _ s: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    _ element: UInt32 = kAudioObjectPropertyElementMain) -> Float32? {
        get(id, s, scope, element, as: Float32.self)
    }

    static func f64(_ id: AudioObjectID, _ s: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    _ element: UInt32 = kAudioObjectPropertyElementMain) -> Float64? {
        get(id, s, scope, element, as: Float64.self)
    }

    static func string(_ id: AudioObjectID, _ s: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var a = addr(s, scope)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: Unmanaged<CFString>?
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
    }

    /// 讀可變長度的 AudioObjectID 陣列（裝置清單、stream 清單等）
    static func ids(_ id: AudioObjectID, _ s: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = addr(s, scope)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &out) == noErr else { return [] }
        return Array(out.prefix(Int(sz) / MemoryLayout<AudioObjectID>.size))
    }

    /// 某 scope 的總聲道數（kAudioDevicePropertyStreamConfiguration）
    static func channelCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func fourCC(_ v: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(bytes: bytes, encoding: .ascii) ?? "\(v)" }
        return "\(v)"
    }
}

// MARK: - 裝置模型

/// 依 transport 分類
enum DeviceKind: String {
    case builtIn, hdmi, displayPort, usb, bluetooth, bluetoothLE, airPlay, thunderbolt, pci, fireWire, avb
    case aggregate, autoAggregate, virtual, continuity, remote, unknown

    init(transport t: UInt32) {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        case kAudioDeviceTransportTypeAVB: self = .avb
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeAutoAggregate: self = .autoAggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case 0x63637764 /* 'ccwd' */, 0x6363776C /* 'ccwl' */, 0x63636170 /* 'ccap' */: self = .continuity
        case 0x72736372 /* 'rscr' */, 0x72737472 /* 'rstr' */: self = .remote
        default: self = .unknown
        }
    }

    /// 實體裝置（可以放進我們的聚合裝置／拿來量測）
    var isPhysical: Bool {
        switch self {
        case .aggregate, .autoAggregate, .virtual, .continuity, .remote, .unknown, .airPlay: return false
        default: return true
        }
    }

    /// 藍牙（含 LE）：走只輸出路徑（BluetoothOut），不放進聚合裝置
    var isBluetooth: Bool { self == .bluetooth || self == .bluetoothLE }
}

struct AudioDevice: Equatable, CustomStringConvertible {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let kind: DeviceKind
    let outputChannels: Int
    let inputChannels: Int
    let nominalSampleRate: Double
    let isAlive: Bool

    var hasOutput: Bool { outputChannels > 0 }
    var hasInput: Bool { inputChannels > 0 }

    init?(id: AudioObjectID) {
        guard let uid = CA.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        self.id = id
        self.uid = uid
        self.name = CA.string(id, kAudioObjectPropertyName) ?? "?"
        self.transport = CA.u32(id, kAudioDevicePropertyTransportType) ?? 0
        self.kind = DeviceKind(transport: transport)
        self.outputChannels = CA.channelCount(id, kAudioObjectPropertyScopeOutput)
        self.inputChannels = CA.channelCount(id, kAudioObjectPropertyScopeInput)
        self.nominalSampleRate = CA.f64(id, kAudioDevicePropertyNominalSampleRate) ?? 0
        self.isAlive = (CA.u32(id, kAudioDevicePropertyDeviceIsAlive) ?? 1) != 0
    }

    var description: String {
        "\(name) [\(kind.rawValue) id=\(id) out=\(outputChannels)ch in=\(inputChannels)ch \(Int(nominalSampleRate))Hz uid=\(uid)]"
    }
}

// MARK: - 裝置查詢

enum Devices {
    /// 額外永遠排除的 UID。使用者自建的多重輸出／聚合裝置（例如「全部喇叭」）已由 kind 非實體排除，
    /// 這裡留給特殊裝置用（預設空）
    static let excludedUIDs: Set<String> = []

    /// 我們自己建立的聚合裝置 UID 前綴（列舉時排除）
    static let ownAggregatePrefix = "In_Unison42-"

    static func all() -> [AudioDevice] {
        CA.ids(CA.system, kAudioHardwarePropertyDevices).compactMap { AudioDevice(id: $0) }
    }

    static func device(id: AudioObjectID) -> AudioDevice? { AudioDevice(id: id) }
    static func device(uid: String) -> AudioDevice? { all().first { $0.uid == uid } }

    /// 是否禁止使用（排除清單、Continuity、iPhone 名稱、我們自己的聚合裝置、非實體）
    static func isExcluded(_ d: AudioDevice) -> Bool {
        if excludedUIDs.contains(d.uid) { return true }
        if d.uid.hasPrefix(ownAggregatePrefix) { return true }
        if d.kind == .continuity { return true }
        if d.name.lowercased().contains("iphone") { return true }
        return !d.kind.isPhysical
    }

    /// 可放進聚合裝置的實體輸出，依 AudioObjectID 排序（穩定）。
    /// 同時有輸入（麥克風）的輸出裝置不放：聚合裝置會把它的輸入 stream 排在 tap 前面、而且會打開它的麥克風
    /// （AirPods 會被切到 HFP 低音質、麥克風指示燈亮）。這類裝置見 outputsWithInput()。
    /// 藍牙輸出（第 2 版起）也不放：一律走只輸出路徑（bluetoothOutputs() → BluetoothOut），
    /// 避免聚合裝置被藍牙時鐘拖累、也避免任何開到藍牙麥克風（HFP）的可能。
    static func physicalOutputs() -> [AudioDevice] {
        all().filter { $0.hasOutput && $0.isAlive && !isExcluded($0) && !$0.hasInput && !$0.kind.isBluetooth }
            .sorted { $0.id < $1.id }
    }

    /// 藍牙輸出（含同時有麥克風的藍牙喇叭／耳機）：只准開輸出方向（BluetoothOut），絕不開輸入。依 id 排序
    static func bluetoothOutputs() -> [AudioDevice] {
        all().filter { $0.hasOutput && $0.isAlive && !isExcluded($0) && $0.kind.isBluetooth }.sorted { $0.id < $1.id }
    }

    /// 有輸出、也有麥克風的非藍牙實體裝置（USB 耳麥、會議喇叭…）：不會被放進聚合裝置、目前也不出聲
    /// （藍牙的見 bluetoothOutputs()，走只輸出路徑）
    static func outputsWithInput() -> [AudioDevice] {
        all().filter { $0.hasOutput && $0.isAlive && !isExcluded($0) && $0.hasInput && !$0.kind.isBluetooth }.sorted { $0.id < $1.id }
    }

    static func builtInOutput() -> AudioDevice? {
        physicalOutputs().first { $0.kind == .builtIn }
    }

    private static func defaultDevice(_ s: AudioObjectPropertySelector) -> AudioDevice? {
        guard let id = CA.u32(CA.system, s), id != 0 else { return nil }
        return AudioDevice(id: id)
    }
    static func defaultOutput() -> AudioDevice? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    static func defaultSystemOutput() -> AudioDevice? { defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice) }
    static func defaultInput() -> AudioDevice? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    /// 可用的量測麥克風：實體輸入、非 Continuity/iPhone、非聚合/虛擬、**非藍牙**
    /// （開藍牙麥克風會把該裝置切到 HFP 通話音質，藍牙喇叭同時在出聲時量到的也是 HFP 的延遲——一律不用）
    static func isUsableMicrophone(_ d: AudioDevice) -> Bool {
        d.hasInput && d.isAlive && !isExcluded(d) && !d.kind.isBluetooth
    }

    /// 校正用麥克風：優先名稱含 C270 → 預設輸入（若可用）→ 任一 USB 輸入 → 任一可用輸入。
    /// 藍牙輸入永遠不會被選到（isUsableMicrophone 排除；預設輸入是藍牙麥克風時也跳過）
    static func microphone() -> AudioDevice? {
        let mics = all().filter(isUsableMicrophone)
        if let c = mics.first(where: { $0.name.uppercased().contains("C270") }) { return c }
        if let d = defaultInput(), isUsableMicrophone(d) { return d }
        if let u = mics.first(where: { $0.kind == .usb }) { return u }
        return mics.first
    }

    // MARK: 音量／靜音（輸出 scope）

    /// 有音量控制的 element：先試 main(0)，再試 1
    static func volumeElement(_ id: AudioObjectID) -> UInt32? {
        for el: UInt32 in [kAudioObjectPropertyElementMain, 1] where
            CA.has(id, kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput, el) {
            return el
        }
        return nil
    }

    static func hasVolumeDecibels(_ id: AudioObjectID) -> Bool {
        guard let el = volumeElement(id) else { return false }
        return CA.f32(id, kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput, el) != nil
    }

    static func volumeDecibels(_ id: AudioObjectID) -> Float? {
        guard let el = volumeElement(id) else { return nil }
        return CA.f32(id, kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput, el)
    }

    /// 0...1，對應選單列滑桿／osascript 的 output volume/100
    static func volumeScalar(_ id: AudioObjectID) -> Float? {
        for el: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            if let v = CA.f32(id, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, el) { return v }
        }
        return nil
    }

    /// 設定音量 scalar；有 main element 就設 main，否則設 1、2 兩聲道。回傳是否成功
    @discardableResult
    static func setVolumeScalar(_ id: AudioObjectID, _ v: Float) -> Bool {
        let v = max(0, min(1, v))
        if CA.isSettable(id, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput) {
            return CA.set(id, kAudioDevicePropertyVolumeScalar, v, kAudioObjectPropertyScopeOutput) == noErr
        }
        var ok = false
        for el: UInt32 in [1, 2] where CA.isSettable(id, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, el) {
            ok = (CA.set(id, kAudioDevicePropertyVolumeScalar, v, kAudioObjectPropertyScopeOutput, el) == noErr) || ok
        }
        return ok
    }

    /// 靜音：先讀 main element，沒有再讀 element 1（有些裝置只在聲道 element 上有 mute）
    static func isMuted(_ id: AudioObjectID) -> Bool {
        for el: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            if let v = CA.u32(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, el) { return v != 0 }
        }
        return false
    }

    /// 設定靜音；main 可設就設 main，否則設 element 1、2
    @discardableResult
    static func setMuted(_ id: AudioObjectID, _ m: Bool) -> Bool {
        let v = UInt32(m ? 1 : 0)
        if CA.isSettable(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput) {
            return CA.set(id, kAudioDevicePropertyMute, v, kAudioObjectPropertyScopeOutput) == noErr
        }
        var ok = false
        for el: UInt32 in [1, 2] where CA.isSettable(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, el) {
            ok = (CA.set(id, kAudioDevicePropertyMute, v, kAudioObjectPropertyScopeOutput, el) == noErr) || ok
        }
        return ok
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioObjectID, alsoSystemOutput: Bool = true) -> Bool {
        var ok = CA.set(CA.system, kAudioHardwarePropertyDefaultOutputDevice, id) == noErr
        if alsoSystemOutput {
            ok = (CA.set(CA.system, kAudioHardwarePropertyDefaultSystemOutputDevice, id) == noErr) && ok
        }
        return ok
    }

    /// 本行程的 Core Audio process object（給 tap 排除自己用）
    static func processObject(pid: pid_t = getpid()) -> AudioObjectID {
        var a = CA.addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var p = pid
        var obj: AudioObjectID = 0
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(CA.system, &a, UInt32(MemoryLayout<pid_t>.size), &p, &sz, &obj)
        return obj
    }
}

// MARK: - 系統音訊狀態快照（動系統設定前記原值、結束時還原）

/// 動系統設定前記原值，結束時還原。規則（絕不調高使用者的音量、不覆蓋使用者中途的操作）：
///   * 音量／靜音一律套在「擷取當下的那台預設輸出」（defaultOutputUID）上，不是還原時的預設輸出。
///   * 音量：目前值 > 原值 → 降回原值；目前值 < 原值 → 只有在目前值仍是「我們自己最後設的值」（我們調低、使用者沒動過）
///     時才升回原值；使用者自己調低過就不動（取 min）。
///   * 靜音：原本靜音、現在沒靜音 → 設回靜音（只會更小聲）；原本沒靜音、現在靜音 → 只有靜音是我們設的才解除。
///   * 預設輸出／系統提示音輸出：只有「目前值仍等於我們自己設的值」才還原（沒設過就不動）；使用者中途切走就尊重。
/// 要改音量／靜音／輸出的流程請透過 setVolume／setMuted／noteSet… 讓快照知道「哪些是我們設的」。
final class SystemAudioSnapshot: CustomStringConvertible {
    let defaultOutputUID: String?
    let defaultSystemOutputUID: String?
    let volumeScalar: Float?
    let muted: Bool

    private let lock = NSLock()
    private var appliedDefaultOutputUID: String?
    private var appliedSystemOutputUID: String?
    private var appliedVolume: Float?
    private var appliedMute: Bool?

    init(defaultOutputUID: String?, defaultSystemOutputUID: String?, volumeScalar: Float?, muted: Bool) {
        self.defaultOutputUID = defaultOutputUID
        self.defaultSystemOutputUID = defaultSystemOutputUID
        self.volumeScalar = volumeScalar
        self.muted = muted
    }

    static func capture() -> SystemAudioSnapshot {
        let out = Devices.defaultOutput()
        return SystemAudioSnapshot(
            defaultOutputUID: out?.uid,
            defaultSystemOutputUID: Devices.defaultSystemOutput()?.uid,
            volumeScalar: out.flatMap { Devices.volumeScalar($0.id) },
            muted: out.map { Devices.isMuted($0.id) } ?? false)
    }

    /// 擷取當下的預設輸出裝置（音量／靜音都套在它上面）
    var originalOutput: AudioDevice? { defaultOutputUID.flatMap { Devices.device(uid: $0) } }

    func noteSetDefaultOutput(_ uid: String?) { lock.lock(); appliedDefaultOutputUID = uid; lock.unlock() }
    func noteSetSystemOutput(_ uid: String?) { lock.lock(); appliedSystemOutputUID = uid; lock.unlock() }

    /// 音量目標的上限：使用者在我們最後一次設定後自己調過（目前值 ≠ 我們設的值）→ 不高於目前值
    func allowedVolume(_ want: Float, device id: AudioObjectID) -> Float {
        guard let cur = Devices.volumeScalar(id) else { return want }
        lock.lock(); let applied = appliedVolume; lock.unlock()
        if let a = applied, abs(cur - a) < 0.005 { return want }   // 還是我們設的值：可以回到 want（want 不會高於原值，見呼叫端）
        return min(cur, want)
    }

    /// 在原本那台輸出上設音量（只准 ≤ 原值；使用者自己調低過就不高於目前值）。回傳實際設的值（nil = 沒設）
    @discardableResult
    func setVolume(_ v: Float) -> Float? {
        guard let d = originalOutput else { return nil }
        let cap = volumeScalar.map { min(v, $0) } ?? v
        let target = allowedVolume(cap, device: d.id)
        if let cur = Devices.volumeScalar(d.id), abs(cur - target) <= 0.001 {
            lock.lock(); appliedVolume = cur; lock.unlock()
            return cur
        }
        guard Devices.setVolumeScalar(d.id, target) else { return nil }
        let readBack = Devices.volumeScalar(d.id) ?? target
        lock.lock(); appliedVolume = readBack; lock.unlock()
        return readBack
    }

    /// 在原本那台輸出上設靜音並記下（解除靜音只在靜音是我們設的時候）
    @discardableResult
    func setMuted(_ m: Bool) -> Bool {
        guard let d = originalOutput else { return false }
        let cur = Devices.isMuted(d.id)
        if cur == m { return true }
        if !m {
            lock.lock(); let ours = appliedMute == true; lock.unlock()
            guard ours else { return false }
        }
        let ok = Devices.setMuted(d.id, m)
        if ok { lock.lock(); appliedMute = m ? true : nil; lock.unlock() }
        return ok
    }

    /// 還原（規則見型別說明）。回傳做了什麼（給 log）
    @discardableResult
    func restore() -> [String] {
        lock.lock()
        let aOut = appliedDefaultOutputUID, aSys = appliedSystemOutputUID, aMute = appliedMute
        lock.unlock()
        var did: [String] = []
        if let orig = defaultOutputUID, let applied = aOut, applied != orig,
           Devices.defaultOutput()?.uid == applied, let d = Devices.device(uid: orig) {
            if CA.set(CA.system, kAudioHardwarePropertyDefaultOutputDevice, d.id) == noErr { did.append("預設輸出 → \(d.name)") }
        }
        if let orig = defaultSystemOutputUID, let applied = aSys, applied != orig,
           Devices.defaultSystemOutput()?.uid == applied, let d = Devices.device(uid: orig) {
            if CA.set(CA.system, kAudioHardwarePropertyDefaultSystemOutputDevice, d.id) == noErr { did.append("系統提示音輸出 → \(d.name)") }
        }
        noteSetDefaultOutput(nil); noteSetSystemOutput(nil)
        guard let out = originalOutput else { return did }
        if let v = volumeScalar, let cur = Devices.volumeScalar(out.id) {
            let target = allowedVolume(v, device: out.id)
            if abs(cur - target) > 0.001 {
                Devices.setVolumeScalar(out.id, target)
                did.append(String(format: "音量 %.0f → %.0f（%@）", cur * 100, target * 100, out.name))
            }
        }
        let curMuted = Devices.isMuted(out.id)
        if muted && !curMuted {
            Devices.setMuted(out.id, true); did.append("靜音 → 開（原值）")
        } else if !muted && curMuted && aMute == true {
            Devices.setMuted(out.id, false); did.append("靜音 → 關（是我們設的）")
        }
        lock.lock(); appliedVolume = nil; appliedMute = nil; lock.unlock()
        return did
    }

    var description: String {
        let v = volumeScalar.map { String(format: "%.0f", $0 * 100) } ?? "?"
        return "預設輸出=\(defaultOutputUID ?? "?") 系統輸出=\(defaultSystemOutputUID ?? "?") 音量=\(v) 靜音=\(muted)"
    }
}
