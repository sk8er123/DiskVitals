// 배드 섹터 검사 탭: 시작/중지 버튼, 진행률, 검사 지도, 찾은 배드 섹터 목록을 보여주는 화면
import SwiftUI
import AppKit

private let cardBG = Color(nsColor: .controlBackgroundColor)
private let lineColor = Color(nsColor: .separatorColor)
private let unreadColor = Color.gray.opacity(0.25)
private let slowColor = HealthStatus.warning.color

struct ScanTab: View {
    @EnvironmentObject var scanner: SurfaceScanner
    let drive: Drive

    var body: some View {
        let s = scanner.display(for: drive.id)
        let here = scanner.isBusy && scanner.driveID == drive.id
        let elsewhere = scanner.isBusy && scanner.driveID != drive.id

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Bad Sector Scan").font(.system(size: 15, weight: .semibold))
                    Text("Reads every sector of this drive to find unreadable (bad) sectors and unusually slow areas. The scan is read-only: nothing on the drive is changed or repaired. An administrator password is required.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Size \(Fmt.bytes(drive.capacityBytes)) · estimated time \(estimate)")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                }
                Spacer(minLength: 10)
                if here {
                    Button { scanner.cancel() } label: { Label("Stop Scan", systemImage: "stop.fill") }
                        .controlSize(.large)
                } else {
                    Button { scanner.start(drive: drive) } label: {
                        Label(s == nil ? "Start Scan" : "Scan Again", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(elsewhere || drive.capacityBytes == 0)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(cardBG))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor))

            if elsewhere {
                Note(symbol: "hourglass", text: "A scan is already running on \(scanner.driveID ?? "another drive"). Only one drive can be scanned at a time.")
            }
            if scanner.phase == .authorizing && here {
                Note(symbol: "lock.fill", text: "Waiting for administrator authorization…")
            }
            if !scanner.notice.isEmpty && scanner.driveID == drive.id && !here {
                Note(symbol: "exclamationmark.triangle.fill", text: scanner.notice)
            }

            if let s {
                ResultBanner(status: s, running: here)
                ProgressSection(status: s, running: here)
            }

            Text("Scan Map").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ScanMap(cells: s?.cells ?? [])
                    .aspectRatio(60.0 / 20.0, contentMode: .fit)
                HStack(spacing: 16) {
                    Legend(color: unreadColor, text: "Not scanned")
                    Legend(color: HealthStatus.ok.color, text: "Readable")
                    Legend(color: slowColor, text: "Slow")
                    Legend(color: HealthStatus.failing.color, text: "Bad sector")
                    Spacer()
                    Text("Each square ≈ \(Fmt.bytes(max(1, drive.capacityBytes / Int64(scanCellCount))))")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(cardBG))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor))

            if let s, s.badCount > 0 {
                BadList(status: s)
            }
        }
    }

    var estimate: String {
        let rate: Double = drive.isSolidState ? 1_000_000_000 : 120_000_000
        return Dur.text(Double(drive.capacityBytes) / rate)
    }
}

private struct Note: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundColor(.secondary)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ResultBanner: View {
    let status: ScanStatus
    let running: Bool

    var body: some View {
        let (color, symbol, title): (Color, String, String) = {
            if running { return (.accentColor, "magnifyingglass", "Scanning… \(Int(status.fraction * 100))%") }
            switch status.state {
            case "done":
                return status.badCount == 0
                    ? (HealthStatus.ok.color, "checkmark.seal.fill", "No bad sectors found")
                    : (HealthStatus.failing.color, "xmark.octagon.fill", "\(Fmt.int(status.badCount)) bad sector\(status.badCount == 1 ? "" : "s") found")
            case "cancelled": return (Color.gray, "stop.circle.fill", "Scan stopped at \(Int(status.fraction * 100))%")
            default: return (HealthStatus.warning.color, "exclamationmark.triangle.fill", "Scan could not finish")
            }
        }()
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundColor(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if !running {
                    Text(detail).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.5)))
    }

    var detail: String {
        if status.state == "done" {
            if status.badCount > 0 {
                return "Some sectors could not be read. Back up this drive soon and consider replacing it."
            }
            return status.slowCount > 0
                ? "Every sector was readable. \(Fmt.int(status.slowCount)) area(s) were slower than usual, which is often caused by other activity on the drive."
                : "Every sector was read without errors."
        }
        return status.message
    }
}

private struct ProgressSection: View {
    let status: ScanStatus
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: status.fraction)
            HStack(spacing: 12) {
                Stat(title: "Scanned", value: "\(Fmt.bytes(status.done)) of \(Fmt.bytes(status.total))")
                Stat(title: "Speed", value: status.speed > 0 ? "\(Int(status.speed / 1_000_000)) MB/s" : "—")
                Stat(title: running ? "Remaining" : "Time", value: running ? remaining : Dur.text(status.elapsed))
                Stat(title: "Bad Sectors", value: Fmt.int(status.badCount),
                     color: status.badCount > 0 ? HealthStatus.failing.color : HealthStatus.ok.color)
                Stat(title: "Slow Areas", value: Fmt.int(status.slowCount),
                     color: status.slowCount > 0 ? slowColor : .primary)
            }
        }
    }

    var remaining: String {
        guard status.speed > 0 else { return "—" }
        return Dur.text(Double(status.total - status.done) / status.speed)
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBG))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(lineColor))
    }
}

struct ScanMap: View {
    let cells: [UInt8]
    var body: some View {
        Canvas { ctx, size in
            let cols = 60, rows = scanCellCount / 60
            let gap: CGFloat = 2
            let w = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let h = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            for i in 0..<scanCellCount {
                let v = i < cells.count ? cells[i] : 0
                let color: Color = v == 3 ? HealthStatus.failing.color : v == 2 ? slowColor : v == 1 ? HealthStatus.ok.color : unreadColor
                let r = CGRect(x: CGFloat(i % cols) * (w + gap), y: CGFloat(i / cols) * (h + gap), width: w, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(color))
            }
        }
    }
}

private struct Legend: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}

private struct BadList: View {
    let status: ScanStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bad Sectors (LBA)").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
            let shown = status.bad.prefix(300)
            Text(shown.map { "\($0)" }.joined(separator: ", ") + (status.badCount > shown.count ? " … and \(Fmt.int(status.badCount - shown.count)) more" : ""))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(cardBG))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(lineColor))
            Text("Sector size \(status.blockSize) bytes. Copy these numbers if you need to report them.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}

enum Dur {
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(1, s)) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }
}
