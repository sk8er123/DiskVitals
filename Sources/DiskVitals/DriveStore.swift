// 연결된 물리 드라이브를 찾고 smartctl로 S.M.A.R.T./NVMe 건강 정보를 읽어 정리하는 데이터 계층
import Foundation

enum HealthStatus: Int, Comparable {
    case ok = 0, unknown = 1, warning = 2, failing = 3

    static func < (a: HealthStatus, b: HealthStatus) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .ok: return "OK"
        case .warning: return "WARNING"
        case .failing: return "FAILING"
        case .unknown: return "UNKNOWN"
        }
    }
}

struct Indicator: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let detail: String
    let status: HealthStatus
    /// 0...1 bar fill (nil → no bar)
    let fraction: Double?
    let informational: Bool
}

struct AtaAttribute: Identifiable {
    let id: Int
    let name: String
    let value: Int
    let worst: Int
    let threshold: Int
    let raw: String
    let prefailure: Bool
    let whenFailed: String
    var status: HealthStatus {
        if !whenFailed.isEmpty && whenFailed != "-" { return .failing }
        if threshold > 0 && value <= threshold { return .failing }
        return .ok
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let columns: [String]
}

struct Drive: Identifiable {
    let id: String            // e.g. disk0
    var name: String
    var model: String = ""
    var serial: String = ""
    var firmware: String = ""
    var capacityBytes: Int64 = 0
    var blockSize: Int = 512
    var busProtocol: String = ""
    var isInternal = true
    var isSolidState = true
    var protocolName: String = ""   // NVMe / ATA / SCSI

    var smartAvailable = false
    var smartMessage: String = ""
    var status: HealthStatus = .unknown
    var healthPercent: Double?      // overall health 0...100
    var lifeLeftPercent: Double?    // endurance remaining
    var temperatureC: Int?
    var powerOnHours: Int?
    var powerCycles: Int?
    var bytesRead: Int64?
    var bytesWritten: Int64?

    var indicators: [Indicator] = []
    var attributes: [AtaAttribute] = []
    var info: [(String, String)] = []
    var errorLogHeader: [String] = []
    var errorLog: [LogEntry] = []
    var errorCount: Int?
    var selfTestHeader: [String] = []
    var selfTests: [LogEntry] = []
    var selfTestSupported: Bool?
    var problems: [String] = []
    var rawText: String?
}

final class DriveStore: ObservableObject {
    @Published var drives: [Drive] = []
    @Published var selectedID: String?
    @Published var isLoading = false
    @Published var smartctlMissing = false
    @Published var lastUpdated: Date?

    let smartctlPath: String? = {
        let candidates = ["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl", "/usr/local/sbin/smartctl",
                          "/opt/homebrew/sbin/smartctl", "/usr/sbin/smartctl", "/opt/local/sbin/smartctl"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    var selected: Drive? { drives.first { $0.id == selectedID } ?? drives.first }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let path = smartctlPath
        DispatchQueue.global(qos: .userInitiated).async {
            let found = DriveScanner.physicalDisks()
            let result = found.map { DriveScanner.load(disk: $0, smartctl: path) }
            DispatchQueue.main.async {
                self.drives = result
                self.smartctlMissing = (path == nil)
                if self.selectedID == nil || !self.drives.contains(where: { $0.id == self.selectedID }) {
                    self.selectedID = self.drives.first?.id
                }
                self.lastUpdated = Date()
                self.isLoading = false
            }
        }
    }

    func loadRaw(for id: String) {
        guard let path = smartctlPath, let idx = drives.firstIndex(where: { $0.id == id }), drives[idx].rawText == nil else { return }
        drives[idx].rawText = "Loading…"
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Shell.run(path, ["-x", "/dev/\(id)"]) ?? "No output."
            DispatchQueue.main.async {
                if let i = self.drives.firstIndex(where: { $0.id == id }) { self.drives[i].rawText = text }
            }
        }
    }
}

// MARK: - Process helper

enum Shell {
    static func run(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    static func runData(_ launchPath: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}

// MARK: - Scanner

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func obj(_ k: String) -> JSON? { self[k] as? JSON }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        return nil
    }
    func dbl(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func bool(_ k: String) -> Bool? { (self[k] as? NSNumber)?.boolValue }
    func arr(_ k: String) -> [JSON]? { self[k] as? [JSON] }
}

enum DriveScanner {
    static func physicalDisks() -> [String] {
        guard let data = Shell.runData("/usr/sbin/diskutil", ["list", "-plist", "physical"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? JSON,
              let whole = plist["WholeDisks"] as? [String] else { return [] }
        return whole
    }

    static func load(disk: String, smartctl: String?) -> Drive {
        var d = Drive(id: disk, name: disk)

        // diskutil: 이름, 용량, 연결 방식
        if let data = Shell.runData("/usr/sbin/diskutil", ["info", "-plist", disk]),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? JSON {
            d.name = info.str("MediaName") ?? disk
            d.capacityBytes = Int64(info.int("TotalSize") ?? info.int("Size") ?? 0)
            d.busProtocol = info.str("BusProtocol") ?? ""
            d.isInternal = info.bool("Internal") ?? true
            d.isSolidState = info.bool("SolidState") ?? false
            d.blockSize = info.int("DeviceBlockSize") ?? 512
        }
        if d.name.trimmingCharacters(in: .whitespaces).isEmpty { d.name = disk }

        guard let smartctl else {
            d.smartMessage = "smartctl (smartmontools) is not installed. Install it with: brew install smartmontools"
            d.problems = [d.smartMessage]
            return d
        }

        // 종료 코드는 비트마스크라 JSON이 있으면 항상 해석한다
        var json: JSON?
        for extra in [[], ["-d", "sat"]] {
            if let data = Shell.runData(smartctl, ["-j", "-a"] + extra + ["/dev/\(disk)"]),
               let j = try? JSONSerialization.jsonObject(with: data) as? JSON,
               j["model_name"] != nil || j["smart_status"] != nil {
                json = j
                break
            }
        }
        guard let j = json else {
            d.smartMessage = "This device does not report S.M.A.R.T. data (it may be behind a USB bridge that hides it)."
            d.problems = [d.smartMessage]
            d.info = baseInfo(d)
            return d
        }
        parse(j, into: &d)
        return d
    }

    static func baseInfo(_ d: Drive) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Device", "/dev/\(d.id)"),
            ("Media Name", d.name),
            ("Capacity", Fmt.bytes(d.capacityBytes)),
            ("Connection", d.busProtocol.isEmpty ? "—" : d.busProtocol),
            ("Location", d.isInternal ? "Internal" : "External"),
            ("Media Type", d.isSolidState ? "Solid State" : "Rotational"),
        ]
        if !d.model.isEmpty { rows.insert(("Model", d.model), at: 1) }
        return rows
    }

    static func parse(_ j: JSON, into d: inout Drive) {
        d.smartAvailable = true
        d.model = j.str("model_name") ?? d.name
        d.serial = j.str("serial_number") ?? ""
        d.firmware = j.str("firmware_version") ?? ""
        d.protocolName = j.obj("device")?.str("protocol") ?? ""
        if d.capacityBytes == 0 {
            d.capacityBytes = Int64(j.int("nvme_total_capacity") ?? j.obj("user_capacity")?.int("bytes") ?? 0)
        }
        d.temperatureC = j.obj("temperature")?.int("current")
        d.powerOnHours = j.obj("power_on_time")?.int("hours")
        d.powerCycles = j.int("power_cycle_count")

        let passed = j.obj("smart_status")?.bool("passed")

        if let log = j.obj("nvme_smart_health_information_log") {
            parseNVMe(j, log: log, passed: passed, into: &d)
        } else {
            parseATA(j, passed: passed, into: &d)
        }

        // 공통 정보 표
        var info = baseInfo(d)
        if !d.serial.isEmpty { info.append(("Serial Number", d.serial)) }
        if !d.firmware.isEmpty { info.append(("Firmware", d.firmware)) }
        if !d.protocolName.isEmpty { info.append(("Protocol", d.protocolName)) }
        if let v = j.obj("nvme_version")?.str("string") { info.append(("NVMe Version", v)) }
        if let n = j.int("nvme_number_of_namespaces") { info.append(("Namespaces", "\(n)")) }
        if let pci = j.obj("nvme_pci_vendor")?.int("id") { info.append(("PCI Vendor ID", String(format: "0x%04X", pci))) }
        if let rpm = j.int("rotation_rate"), rpm > 0 { info.append(("Rotation Rate", "\(rpm) rpm")) }
        if let ff = j.obj("form_factor")?.str("name") { info.append(("Form Factor", ff)) }
        if let ata = j.obj("ata_version")?.str("string") { info.append(("ATA Version", ata)) }
        if let sata = j.obj("interface_speed")?.obj("current")?.str("string") { info.append(("Interface Speed", sata)) }
        if let s = j.obj("smart_support") {
            info.append(("S.M.A.R.T. Supported", (s.bool("available") ?? false) ? "Yes" : "No"))
            info.append(("S.M.A.R.T. Enabled", (s.bool("enabled") ?? false) ? "Yes" : "No"))
        }
        if let ver = j.obj("smartctl")?["version"] as? [NSNumber] {
            info.append(("Data Source", "smartctl " + ver.map { $0.stringValue }.joined(separator: ".")))
        }
        d.info = info

        if d.problems.isEmpty && d.status == .ok {
            d.problems = []
        }
    }

    static func parseNVMe(_ j: JSON, log: JSON, passed: Bool?, into d: inout Drive) {
        var ind: [Indicator] = []
        var problems: [String] = []

        let crit = log.int("critical_warning") ?? 0
        ind.append(Indicator(name: "Critical Warning", value: crit == 0 ? "None" : String(format: "0x%02X", crit),
                             detail: crit == 0 ? "No critical warnings reported by the controller" : criticalWarningText(crit),
                             status: crit == 0 ? .ok : .failing, fraction: nil, informational: false))
        if crit != 0 { problems.append("Controller reports critical warning: \(criticalWarningText(crit))") }

        let spare = log.int("available_spare")
        let spareT = log.int("available_spare_threshold") ?? 10
        if let spare {
            let st: HealthStatus = spare < spareT ? .failing : (spare < min(100, spareT + 10) ? .warning : .ok)
            ind.append(Indicator(name: "Available Spare", value: "\(spare)%", detail: "Threshold \(spareT)%",
                                 status: st, fraction: Double(spare) / 100, informational: false))
            if st == .failing { problems.append("Available spare (\(spare)%) is below threshold (\(spareT)%)") }
        }

        if let used = log.int("percentage_used") {
            let left = max(0, 100 - used)
            d.lifeLeftPercent = Double(left)
            let st: HealthStatus = left <= 0 ? .failing : (left < 10 ? .warning : .ok)
            ind.append(Indicator(name: "Lifetime Remaining", value: "\(left)%", detail: "Endurance used \(used)%",
                                 status: st, fraction: Double(left) / 100, informational: false))
            if st != .ok { problems.append("Rated endurance is almost used up (\(used)% used)") }
        }

        let warnT = j.obj("nvme_composite_temperature_threshold")?.int("warning")
        let critT = j.obj("nvme_composite_temperature_threshold")?.int("critical")
        if let t = log.int("temperature") {
            let w = warnT ?? 70, c = critT ?? 80
            let st: HealthStatus = t >= c ? .failing : (t >= w ? .warning : .ok)
            ind.append(Indicator(name: "Temperature", value: "\(t) °C", detail: "Warning \(w) °C · Critical \(c) °C",
                                 status: st, fraction: min(1, Double(t) / Double(c)), informational: false))
            if st != .ok { problems.append("Drive temperature is high (\(t) °C)") }
        }

        let media = log.int("media_errors") ?? 0
        ind.append(Indicator(name: "Media and Data Integrity Errors", value: "\(media)", detail: "Unrecovered data integrity errors",
                             status: media == 0 ? .ok : .warning, fraction: nil, informational: false))
        if media > 0 { problems.append("\(media) media / data integrity errors detected") }

        let errs = log.int("num_err_log_entries") ?? 0
        d.errorCount = errs
        ind.append(Indicator(name: "Error Information Log Entries", value: Fmt.int(errs), detail: "Lifetime error log entries",
                             status: .ok, fraction: nil, informational: true))

        if let w = log.int("warning_temp_time") {
            ind.append(Indicator(name: "Warning Temperature Time", value: "\(w) min", detail: "Time above warning temperature",
                                 status: w > 60 ? .warning : .ok, fraction: nil, informational: w <= 60))
            if w > 60 { problems.append("Drive spent \(w) minutes above its warning temperature") }
        }
        if let c = log.int("critical_comp_time") {
            ind.append(Indicator(name: "Critical Temperature Time", value: "\(c) min", detail: "Time above critical temperature",
                                 status: c > 0 ? .warning : .ok, fraction: nil, informational: c == 0))
            if c > 0 { problems.append("Drive spent \(c) minutes above its critical temperature") }
        }

        let unsafe = log.int("unsafe_shutdowns") ?? 0
        ind.append(Indicator(name: "Unsafe Shutdowns", value: Fmt.int(unsafe), detail: "Power lost without a clean shutdown",
                             status: .ok, fraction: nil, informational: true))
        if let pc = log.int("power_cycles") {
            d.powerCycles = pc
            ind.append(Indicator(name: "Power Cycles", value: Fmt.int(pc), detail: "", status: .ok, fraction: nil, informational: true))
        }
        if let h = log.int("power_on_hours") {
            d.powerOnHours = h
            ind.append(Indicator(name: "Power On Hours", value: Fmt.hours(h), detail: "\(Fmt.int(h)) hours", status: .ok, fraction: nil, informational: true))
        }
        if let r = log.dbl("data_units_read") {
            d.bytesRead = Int64(r * 512_000)
            ind.append(Indicator(name: "Data Read", value: Fmt.bytes(d.bytesRead!), detail: "\(Fmt.int(Int(r))) data units",
                                 status: .ok, fraction: nil, informational: true))
        }
        if let w = log.dbl("data_units_written") {
            d.bytesWritten = Int64(w * 512_000)
            ind.append(Indicator(name: "Data Written", value: Fmt.bytes(d.bytesWritten!), detail: "\(Fmt.int(Int(w))) data units",
                                 status: .ok, fraction: nil, informational: true))
        }
        if let hr = log.int("host_reads") {
            ind.append(Indicator(name: "Host Read Commands", value: Fmt.int(hr), detail: "", status: .ok, fraction: nil, informational: true))
        }
        if let hw = log.int("host_writes") {
            ind.append(Indicator(name: "Host Write Commands", value: Fmt.int(hw), detail: "", status: .ok, fraction: nil, informational: true))
        }
        if let busy = log.int("controller_busy_time") {
            ind.append(Indicator(name: "Controller Busy Time", value: "\(Fmt.int(busy)) min", detail: "", status: .ok, fraction: nil, informational: true))
        }

        if passed == false { problems.insert("Drive reports overall health self-assessment: FAILED", at: 0) }

        // 오류 로그
        d.errorLogHeader = ["#", "Error Count", "SQ ID", "Cmd ID", "Status", "LBA"]
        d.errorLog = (j.obj("nvme_error_information_log")?.arr("table") ?? []).enumerated().map { i, e in
            LogEntry(columns: ["\(i)", e.str("error_count") ?? "—", e.str("submission_queue_id") ?? "—",
                               e.str("command_id") ?? "—", e.obj("status_field")?.str("string") ?? e.str("status_field") ?? "—",
                               e.obj("lba")?.str("value") ?? "—"])
        }
        d.selfTestSupported = j.obj("nvme_optional_admin_commands")?.bool("self_test")
        d.selfTestHeader = ["#", "Test", "Result", "Power On Hours"]
        d.selfTests = (j.obj("nvme_self_test_log")?.arr("table") ?? []).enumerated().map { i, e in
            LogEntry(columns: ["\(i)", e.obj("self_test_code")?.str("string") ?? "—",
                               e.obj("self_test_result")?.str("string") ?? "—", e.str("power_on_hours") ?? "—"])
        }

        d.indicators = ind
        d.problems = problems
        d.status = overall(ind: ind, passed: passed)
        d.healthPercent = healthScore(lifeLeft: d.lifeLeftPercent, spare: spare.map(Double.init), status: d.status)
    }

    static func parseATA(_ j: JSON, passed: Bool?, into d: inout Drive) {
        var ind: [Indicator] = []
        var problems: [String] = []
        let table = j.obj("ata_smart_attributes")?.arr("table") ?? []
        d.attributes = table.compactMap { a in
            guard let id = a.int("id") else { return nil }
            return AtaAttribute(id: id, name: (a.str("name") ?? "Unknown").replacingOccurrences(of: "_", with: " "),
                                value: a.int("value") ?? 0, worst: a.int("worst") ?? 0, threshold: a.int("thresh") ?? 0,
                                raw: a.obj("raw")?.str("string") ?? a.obj("raw")?.str("value") ?? "",
                                prefailure: a.obj("flags")?.bool("prefailure") ?? false, whenFailed: a.str("when_failed") ?? "")
        }
        func rawInt(_ id: Int) -> Int? {
            table.first { $0.int("id") == id }?.obj("raw")?.int("value")
        }

        ind.append(Indicator(name: "Overall Self-Assessment", value: passed == nil ? "Unknown" : (passed! ? "PASSED" : "FAILED"),
                             detail: "Drive's own health verdict", status: passed == nil ? .unknown : (passed! ? .ok : .failing),
                             fraction: nil, informational: false))
        if passed == false { problems.append("Drive reports overall health self-assessment: FAILED") }

        for (id, name) in [(5, "Reallocated Sectors"), (197, "Current Pending Sectors"), (198, "Offline Uncorrectable Sectors"),
                           (187, "Reported Uncorrectable Errors"), (10, "Spin Retry Count"), (199, "UDMA CRC Errors")] {
            guard let v = rawInt(id) else { continue }
            let st: HealthStatus = v == 0 ? .ok : (id == 199 ? .ok : .warning)
            ind.append(Indicator(name: name, value: Fmt.int(v), detail: "Attribute \(id)", status: st, fraction: nil, informational: id == 199))
            if st == .warning { problems.append("\(name): \(v)") }
        }
        for a in d.attributes where a.status == .failing {
            problems.append("Attribute \(a.id) \(a.name) is at or below its failure threshold")
        }

        // SSD 수명 속성
        for wearID in [231, 233, 177, 202, 169] {
            if let a = d.attributes.first(where: { $0.id == wearID }), a.value <= 100 {
                d.lifeLeftPercent = Double(a.value)
                let st: HealthStatus = a.value <= 10 ? .warning : .ok
                ind.append(Indicator(name: "Lifetime Remaining", value: "\(a.value)%", detail: a.name, status: st,
                                     fraction: Double(a.value) / 100, informational: false))
                break
            }
        }
        if let t = d.temperatureC {
            let st: HealthStatus = t >= 60 ? .warning : .ok
            ind.append(Indicator(name: "Temperature", value: "\(t) °C", detail: "Warning 60 °C", status: st,
                                 fraction: min(1, Double(t) / 70), informational: false))
            if st != .ok { problems.append("Drive temperature is high (\(t) °C)") }
        }
        if let h = d.powerOnHours {
            ind.append(Indicator(name: "Power On Hours", value: Fmt.hours(h), detail: "\(Fmt.int(h)) hours", status: .ok, fraction: nil, informational: true))
        }
        if let c = d.powerCycles {
            ind.append(Indicator(name: "Power Cycles", value: Fmt.int(c), detail: "", status: .ok, fraction: nil, informational: true))
        }
        let sector = Int64(j.int("logical_block_size") ?? 512)
        if let w = rawInt(241) { d.bytesWritten = Int64(w) * sector }
        if let r = rawInt(242) { d.bytesRead = Int64(r) * sector }
        if let w = d.bytesWritten {
            ind.append(Indicator(name: "Data Written", value: Fmt.bytes(w), detail: "", status: .ok, fraction: nil, informational: true))
        }

        if let summary = j.obj("ata_smart_error_log")?.obj("summary") {
            d.errorCount = summary.int("count") ?? 0
            d.errorLogHeader = ["#", "Power On Hours", "Error"]
            d.errorLog = (summary.arr("table") ?? []).map { e in
                LogEntry(columns: [e.str("error_number") ?? "—", e.str("lifetime_hours") ?? "—",
                                   e.obj("error_description")?.str("string") ?? e.str("error_description") ?? "—"])
            }
        }
        d.selfTestSupported = j.obj("ata_smart_data")?.obj("capabilities")?.bool("self_tests_supported")
        d.selfTestHeader = ["#", "Test", "Result", "Power On Hours"]
        d.selfTests = (j.obj("ata_smart_self_test_log")?.obj("standard")?.arr("table") ?? []).enumerated().map { i, e in
            LogEntry(columns: ["\(i + 1)", e.obj("type")?.str("string") ?? "—",
                               e.obj("status")?.str("string") ?? "—", e.str("lifetime_hours") ?? "—"])
        }

        d.indicators = ind
        d.problems = problems
        d.status = overall(ind: ind, passed: passed)
        if d.attributes.contains(where: { $0.status == .failing }) { d.status = .failing }
        d.healthPercent = healthScore(lifeLeft: d.lifeLeftPercent, spare: nil, status: d.status)
    }

    static func overall(ind: [Indicator], passed: Bool?) -> HealthStatus {
        if passed == false { return .failing }
        let worst = ind.filter { !$0.informational }.map(\.status).filter { $0 != .unknown }.max() ?? .ok
        if passed == nil && worst == .ok { return .unknown }
        return worst
    }

    /// 수명·여유 공간과 경고를 합쳐 0~100 건강 점수를 추정한다
    static func healthScore(lifeLeft: Double?, spare: Double?, status: HealthStatus) -> Double {
        var score = min(lifeLeft ?? 100, spare ?? 100)
        switch status {
        case .failing: score = min(score, 10)
        case .warning: score = min(score, 60)
        default: break
        }
        return max(0, score)
    }

    static func criticalWarningText(_ v: Int) -> String {
        var parts: [String] = []
        if v & 0x01 != 0 { parts.append("spare below threshold") }
        if v & 0x02 != 0 { parts.append("temperature out of range") }
        if v & 0x04 != 0 { parts.append("reliability degraded") }
        if v & 0x08 != 0 { parts.append("read-only mode") }
        if v & 0x10 != 0 { parts.append("volatile backup failed") }
        return parts.isEmpty ? "unknown" : parts.joined(separator: ", ")
    }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        guard b > 0 else { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowedUnits = [.useGB, .useTB, .useMB]
        return f.string(fromByteCount: b)
    }
    static func int(_ v: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    static func hours(_ h: Int) -> String {
        let days = h / 24
        if days >= 365 {
            let y = Double(days) / 365.0
            return String(format: "%.1f years", y)
        }
        if days > 0 { return "\(days) days \(h % 24) h" }
        return "\(h) h"
    }
}
