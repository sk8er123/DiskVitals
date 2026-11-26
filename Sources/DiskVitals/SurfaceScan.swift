// 드라이브의 모든 섹터를 읽기 전용으로 읽어 배드 섹터와 느린 구간을 찾는 표면 검사(관리자 권한 작업자 + 앱 쪽 진행 관리)
import Foundation
import AppKit

let scanCellCount = 1200

// MARK: - Status shared between worker and app

struct ScanStatus {
    var state: String = "starting"     // starting / running / done / cancelled / error
    var message: String = ""
    var total: Int64 = 0
    var done: Int64 = 0
    var blockSize: Int = 512
    var badCount: Int = 0
    var bad: [Int64] = []
    var slowCount: Int = 0
    var cells: [UInt8] = []
    var elapsed: Double = 0
    var speed: Double = 0

    var isFinished: Bool { ["done", "cancelled", "error"].contains(state) }
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    func json() -> Data {
        let obj: [String: Any] = [
            "state": state, "message": message, "total": total, "done": done, "blockSize": blockSize,
            "badCount": badCount, "bad": bad, "slowCount": slowCount,
            "cells": String(cells.map { Character(String($0)) }), "elapsed": elapsed, "speed": speed,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    static func parse(_ data: Data) -> ScanStatus? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var s = ScanStatus()
        s.state = j["state"] as? String ?? "running"
        s.message = j["message"] as? String ?? ""
        s.total = (j["total"] as? NSNumber)?.int64Value ?? 0
        s.done = (j["done"] as? NSNumber)?.int64Value ?? 0
        s.blockSize = (j["blockSize"] as? NSNumber)?.intValue ?? 512
        s.badCount = (j["badCount"] as? NSNumber)?.intValue ?? 0
        s.bad = (j["bad"] as? [NSNumber])?.map { $0.int64Value } ?? []
        s.slowCount = (j["slowCount"] as? NSNumber)?.intValue ?? 0
        s.cells = (j["cells"] as? String ?? "").compactMap { $0.wholeNumberValue.map(UInt8.init) }
        s.elapsed = (j["elapsed"] as? NSNumber)?.doubleValue ?? 0
        s.speed = (j["speed"] as? NSNumber)?.doubleValue ?? 0
        return s
    }
}

// MARK: - Worker (runs as root, started with --scan-worker)

enum ScanWorker {
    /// args: device sizeBytes blockSize statusPath cancelPath parentPid
    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 6 else {
            FileHandle.standardError.write("usage: --scan-worker device size blockSize status cancel pid\n".data(using: .utf8)!)
            return 2
        }
        let device = args[0]
        var total = Int64(args[1]) ?? 0
        let blockSize = max(512, Int(args[2]) ?? 512)
        let statusPath = args[3], cancelPath = args[4]
        let parentPid = pid_t(args[5]) ?? 0

        var st = ScanStatus()
        st.blockSize = blockSize
        st.cells = Array(repeating: 0, count: scanCellCount)

        func write(_ s: ScanStatus) {
            let tmp = statusPath + ".tmp"
            FileManager.default.createFile(atPath: tmp, contents: s.json(), attributes: [.posixPermissions: 0o644])
            rename(tmp, statusPath)
        }
        func fail(_ msg: String) -> Int32 {
            st.state = "error"; st.message = msg; write(st); return 1
        }

        write(st)   // 시작 상태를 바로 알린다

        // 읽기 전용으로만 연다
        let fd = open(device, O_RDONLY)
        if fd < 0 {
            let e = errno
            return fail(e == EACCES || e == EPERM
                ? "Permission denied while opening \(device). Administrator access is needed."
                : "Could not open \(device): \(String(cString: strerror(e))).")
        }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var sb = stat()
        if fstat(fd, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFREG { total = Int64(sb.st_size) }
        total -= total % Int64(blockSize)
        guard total > 0 else { return fail("The drive size is unknown, so it cannot be scanned.") }
        st.total = total

        let chunk = max(blockSize, (1 << 20) / blockSize * blockSize)
        var raw: UnsafeMutableRawPointer?
        guard posix_memalign(&raw, 16384, chunk) == 0, let buf = raw else { return fail("Out of memory.") }
        defer { free(buf) }

        let start = Date()
        var lastWrite = Date.distantPast
        var offset: Int64 = 0
        // 1 MiB를 읽는 데 이 시간보다 오래 걸리면 느린 구간으로 표시(추정 기준, 참고용)
        let slowSecondsPerMiB = 0.25

        func mark(_ from: Int64, _ to: Int64, _ v: UInt8) {
            let a = Int(Double(from) / Double(total) * Double(scanCellCount))
            let b = Int(Double(max(from, to - 1)) / Double(total) * Double(scanCellCount))
            for i in max(0, a)...min(scanCellCount - 1, b) where st.cells[i] < v { st.cells[i] = v }
        }

        func shouldStop() -> String? {
            if FileManager.default.fileExists(atPath: cancelPath) { return "Scan was cancelled." }
            if parentPid > 0 && kill(parentPid, 0) != 0 && errno == ESRCH { return "The app was closed, so the scan stopped." }
            return nil
        }

        st.state = "running"
        while offset < total {
            if let why = shouldStop() {
                st.state = "cancelled"; st.message = why; break
            }
            let len = Int(min(Int64(chunk), total - offset))
            let t0 = Date()
            let n = pread(fd, buf, len, off_t(offset))
            let dt = Date().timeIntervalSince(t0)

            if n == len {
                let slow = dt > slowSecondsPerMiB * Double(len) / Double(1 << 20)
                if slow { st.slowCount += 1 }
                mark(offset, offset + Int64(len), slow ? 2 : 1)
            } else if n == 0 {
                // 장치가 예상보다 작다: 여기서 끝낸다
                st.total = offset
                break
            } else if n < 0 && errno != EIO {
                let e = errno
                st.state = "error"
                st.message = "Reading stopped at \(Fmt.bytes(offset)): \(String(cString: strerror(e))). The drive may have been disconnected."
                break
            } else {
                // 읽기 오류(EIO) 또는 일부만 읽힘: 블록 단위로 다시 읽어 배드 섹터를 찾는다
                var b: Int64 = 0
                var aborted = false
                while b < Int64(len) {
                    let r = pread(fd, buf, blockSize, off_t(offset + b))
                    if r == blockSize {
                        mark(offset + b, offset + b + Int64(blockSize), 1)
                    } else if r < 0 && errno == EIO {
                        st.badCount += 1
                        if st.bad.count < 1000 { st.bad.append((offset + b) / Int64(blockSize)) }
                        mark(offset + b, offset + b + Int64(blockSize), 3)
                    } else {
                        let e = r < 0 ? errno : EIO
                        st.state = "error"
                        st.message = "Reading stopped at \(Fmt.bytes(offset + b)): \(String(cString: strerror(e)))."
                        aborted = true
                        break
                    }
                    b += Int64(blockSize)
                }
                if aborted { break }
            }

            offset += Int64(len)
            st.done = offset
            st.elapsed = Date().timeIntervalSince(start)
            st.speed = st.elapsed > 0 ? Double(offset) / st.elapsed : 0
            if Date().timeIntervalSince(lastWrite) > 0.3 {
                write(st)
                lastWrite = Date()
            }
        }

        st.elapsed = Date().timeIntervalSince(start)
        st.speed = st.elapsed > 0 ? Double(st.done) / st.elapsed : 0
        if st.state == "running" {
            st.state = "done"
            st.message = st.badCount == 0 ? "No bad sectors found." : "\(st.badCount) bad sector\(st.badCount == 1 ? "" : "s") found."
        }
        write(st)
        return st.state == "error" ? 1 : 0
    }
}

// MARK: - App side

final class SurfaceScanner: ObservableObject {
    enum Phase { case idle, authorizing, running }

    @Published var phase: Phase = .idle
    @Published var driveID: String?
    @Published var status: ScanStatus?
    @Published var notice: String = ""
    /// 드라이브별 마지막 검사 결과
    @Published var results: [String: ScanStatus] = [:]

    private var dir: URL?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var launchedAt: Date?

    var isBusy: Bool { phase != .idle }

    func start(drive: Drive) {
        guard phase == .idle else { return }
        guard drive.capacityBytes > 0 else { notice = "The drive size is unknown, so it cannot be scanned."; return }
        guard let exe = Bundle.main.executablePath else { notice = "Could not find the app's own program."; return }

        let d = FileManager.default.temporaryDirectory.appendingPathComponent("DiskVitalsScan-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dir = d
        let statusURL = d.appendingPathComponent("status.json")
        let cancelURL = d.appendingPathComponent("cancel")
        let device = "/dev/r\(drive.id)"

        driveID = drive.id
        launchedAt = nil
        status = nil
        notice = ""
        phase = .authorizing
        results[drive.id] = nil

        let workerArgs = [exe, "--scan-worker", device, "\(drive.capacityBytes)", "\(drive.blockSize)",
                          statusURL.path, cancelURL.path, "\(ProcessInfo.processInfo.processIdentifier)"]
        let needsAdmin = access(device, R_OK) != 0

        // osascript로 작업자를 백그라운드에 띄우고 바로 돌아온다
        let script = """
        on run argv
            set cmd to ""
            repeat with a in argv
                set cmd to cmd & quoted form of (a as text) & " "
            end repeat
            do shell script cmd & "> /dev/null 2>&1 &"\(needsAdmin ? " with administrator privileges" : "")
        end run
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script] + workerArgs
        p.standardOutput = Pipe()
        let errPipe = Pipe()
        p.standardError = errPipe
        p.terminationHandler = { proc in
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 { self.launchedAt = Date() }
                if proc.terminationStatus != 0 && self.phase == .authorizing {
                    self.phase = .idle
                    self.notice = err.contains("-128") ? "Scan not started: administrator authorization was cancelled."
                                                       : "Scan could not start. \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
                    self.cleanup()
                }
            }
        }
        do { try p.run() } catch {
            phase = .idle
            notice = "Scan could not start: \(error.localizedDescription)"
            return
        }

        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Drive surface scan")
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll(statusURL) }
    }

    private func poll(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let s = ScanStatus.parse(data) else {
            // 작업자가 시작됐는데 상태가 오지 않으면 멈춘 것으로 본다
            if phase == .authorizing, let t = launchedAt, Date().timeIntervalSince(t) > 15 {
                phase = .idle
                notice = "The scan did not start. Please try again."
                cleanup()
            }
            return
        }
        if phase == .authorizing { phase = .running }
        status = s
        if s.isFinished, let id = driveID {
            results[id] = s
            phase = .idle
            cleanup()
        }
    }

    func cancel() {
        guard let dir else { return }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("cancel").path, contents: Data())
        if phase == .authorizing { notice = "Cancelling…" }
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
    }

    /// 화면에 보여줄 상태: 진행 중이면 현재 상태, 아니면 마지막 결과
    func display(for id: String) -> ScanStatus? {
        if driveID == id, phase != .idle { return status }
        return results[id]
    }
}
