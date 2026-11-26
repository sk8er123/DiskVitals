// 드라이브 목록(왼쪽)과 선택한 드라이브의 건강 상태·지표·정보 화면(오른쪽)을 그리는 SwiftUI 뷰
import SwiftUI
import AppKit

extension HealthStatus {
    var color: Color {
        switch self {
        case .ok: return Color(red: 0.20, green: 0.70, blue: 0.35)
        case .warning: return Color(red: 0.95, green: 0.62, blue: 0.10)
        case .failing: return Color(red: 0.88, green: 0.22, blue: 0.20)
        case .unknown: return Color.gray
        }
    }
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failing: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

private let sidebarBG = Color(nsColor: .underPageBackgroundColor)
private let panelBG = Color(nsColor: .windowBackgroundColor)
private let cardBG = Color(nsColor: .controlBackgroundColor)
private let lineColor = Color(nsColor: .separatorColor)

struct ContentView: View {
    @EnvironmentObject var store: DriveStore

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Rectangle().fill(lineColor).frame(height: 1)
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: 270)
                Rectangle().fill(lineColor).frame(width: 1)
                Group {
                    if let d = store.selected {
                        DriveDetail(drive: d)
                    } else {
                        EmptyState()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(panelBG)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var store: DriveStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("DiskVitals").font(.system(size: 15, weight: .semibold))
            Text("Drive Health Monitor").font(.system(size: 12)).foregroundColor(.secondary)
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
                Text("Checking drives…").font(.system(size: 12)).foregroundColor(.secondary)
            } else if let t = store.lastUpdated {
                Text("Updated \(t.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(panelBG)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var store: DriveStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SummaryBox()
                .padding(12)
            Text("DEVICES")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.drives) { d in
                        DriveRow(drive: d, selected: d.id == (store.selected?.id ?? ""))
                            .contentShape(Rectangle())
                            .onTapGesture { store.selectedID = d.id }
                    }
                    if store.drives.isEmpty && !store.isLoading {
                        Text("No drives found").foregroundColor(.secondary).padding()
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            if store.smartctlMissing {
                VStack(alignment: .leading, spacing: 4) {
                    Label("smartctl not found", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(HealthStatus.warning.color)
                        .font(.system(size: 12, weight: .semibold))
                    Text("Install smartmontools to read health data:\nbrew install smartmontools")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .padding(12)
            }
        }
        .background(sidebarBG)
    }
}

struct SummaryBox: View {
    @EnvironmentObject var store: DriveStore

    var body: some View {
        let worst = store.drives.map(\.status).max() ?? .unknown
        let counts = Dictionary(grouping: store.drives, by: \.status).mapValues(\.count)
        HStack(spacing: 10) {
            Image(systemName: worst.symbol)
                .font(.system(size: 26))
                .foregroundColor(worst.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(summaryTitle(worst)).font(.system(size: 13, weight: .semibold))
                Text("\(store.drives.count) drive\(store.drives.count == 1 ? "" : "s") · \(counts[.ok] ?? 0) OK · \((counts[.warning] ?? 0) + (counts[.failing] ?? 0)) with issues")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBG))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(lineColor))
    }

    func summaryTitle(_ s: HealthStatus) -> String {
        if store.drives.isEmpty { return store.isLoading ? "Checking…" : "No drives" }
        switch s {
        case .ok: return "All drives are healthy"
        case .warning: return "Some drives need attention"
        case .failing: return "A drive is failing"
        case .unknown: return "Health not available"
        }
    }
}

struct DriveRow: View {
    let drive: Drive
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: drive.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                    .font(.system(size: 24))
                    .foregroundColor(selected ? .white : .secondary)
                    .frame(width: 32, height: 32)
                Circle().fill(drive.status.color)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text("\(Fmt.bytes(drive.capacityBytes)) · \(drive.isInternal ? "Internal" : "External") · \(drive.id)")
                    .font(.system(size: 11))
                    .opacity(0.75)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let h = drive.healthPercent {
                Text("\(Int(h.rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(selected ? .white : drive.status.color)
            }
        }
        .foregroundColor(selected ? .white : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : Color.clear))
    }
}

struct EmptyState: View {
    @EnvironmentObject var store: DriveStore
    var body: some View {
        VStack(spacing: 10) {
            if store.isLoading {
                ProgressView()
                Text("Reading drive health…").foregroundColor(.secondary)
            } else {
                Image(systemName: "internaldrive").font(.system(size: 40)).foregroundColor(.secondary)
                Text("Select a drive").foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Detail

enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case indicators = "Health Indicators"
    case attributes = "S.M.A.R.T. Attributes"
    case logs = "Errors & Self-Tests"
    case scan = "Bad Sector Scan"
    case info = "Info"
    case raw = "Raw Output"
    var id: String { rawValue }
}

struct DriveDetail: View {
    @EnvironmentObject var store: DriveStore
    let drive: Drive
    @State private var tab: DetailTab = .overview

    var tabs: [DetailTab] {
        DetailTab.allCases.filter { $0 != .attributes || !drive.attributes.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(drive: drive)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Picker("", selection: $tab) {
                ForEach(tabs) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            Rectangle().fill(lineColor).frame(height: 1)
            ScrollView {
                Group {
                    switch tab {
                    case .overview: OverviewTab(drive: drive)
                    case .indicators: IndicatorsTab(drive: drive)
                    case .attributes: AttributesTab(drive: drive)
                    case .logs: LogsTab(drive: drive)
                    case .scan: ScanTab(drive: drive)
                    case .info: InfoTab(drive: drive)
                    case .raw: RawTab(drive: drive)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: drive.id) { _ in if !tabs.contains(tab) { tab = .overview } }
        .onChange(of: tab) { t in if t == .raw { store.loadRaw(for: drive.id) } }
    }
}

struct DetailHeader: View {
    let drive: Drive
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: drive.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(drive.model.isEmpty ? drive.name : drive.model)
                    .font(.system(size: 20, weight: .semibold))
                Text([Fmt.bytes(drive.capacityBytes),
                      drive.protocolName.isEmpty ? drive.busProtocol : drive.protocolName,
                      drive.isInternal ? "Internal" : "External",
                      "/dev/\(drive.id)"].filter { !$0.isEmpty && $0 != "—" }.joined(separator: "  ·  "))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            StatusBadge(status: drive.status, large: true)
        }
    }
}

struct StatusBadge: View {
    let status: HealthStatus
    var large = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.symbol)
            Text(status.label)
        }
        .font(.system(size: large ? 14 : 10.5, weight: .bold))
        .foregroundColor(.white)
        .padding(.horizontal, large ? 14 : 8)
        .padding(.vertical, large ? 7 : 3)
        .background(Capsule().fill(status.color))
    }
}

// MARK: Overview

struct OverviewTab: View {
    let drive: Drive

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                RingCard(title: "Overall Health", value: drive.healthPercent, color: drive.status.color,
                         caption: drive.status.label)
                RingCard(title: "Lifetime Remaining", value: drive.lifeLeftPercent,
                         color: (drive.lifeLeftPercent ?? 100) < 10 ? HealthStatus.warning.color : HealthStatus.ok.color,
                         caption: drive.lifeLeftPercent == nil ? "Not reported" : "Rated endurance")
                StatCard(title: "Temperature", symbol: "thermometer.medium",
                         value: drive.temperatureC.map { "\($0) °C" } ?? "—",
                         caption: drive.temperatureC.map { "\(Int((Double($0) * 9 / 5 + 32).rounded())) °F" } ?? "Not reported")
                StatCard(title: "Power On", symbol: "clock",
                         value: drive.powerOnHours.map(Fmt.hours) ?? "—",
                         caption: drive.powerCycles.map { "\(Fmt.int($0)) power cycles" } ?? "")
                StatCard(title: "Data Written", symbol: "square.and.arrow.down",
                         value: drive.bytesWritten.map(Fmt.bytes) ?? "—",
                         caption: drive.bytesRead.map { "Read \(Fmt.bytes($0))" } ?? "")
            }

            SectionTitle(text: "Problems Summary")
            VStack(alignment: .leading, spacing: 8) {
                if drive.problems.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundColor(HealthStatus.ok.color)
                        Text(drive.smartAvailable ? "No problems detected. All health indicators are within normal range."
                                                  : "Health data is not available for this drive.")
                    }
                } else {
                    ForEach(drive.problems, id: \.self) { p in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: drive.status == .failing ? HealthStatus.failing.symbol : HealthStatus.warning.symbol)
                                .foregroundColor(drive.status == .failing ? HealthStatus.failing.color : HealthStatus.warning.color)
                            Text(p).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .font(.system(size: 13))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(cardBG))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(lineColor))

            SectionTitle(text: "Key Indicators")
            IndicatorTable(items: drive.indicators.filter { !$0.informational })
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
    }
}

struct RingCard: View {
    let title: String
    let value: Double?
    let color: Color
    let caption: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundColor(.secondary)
            ZStack {
                Circle().stroke(lineColor, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: CGFloat((value ?? 0) / 100))
                    .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }
            .frame(width: 78, height: 78)
            Text(caption).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(RoundedRectangle(cornerRadius: 10).fill(cardBG))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor))
    }
}

struct StatCard: View {
    let title: String
    let symbol: String
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundColor(.secondary)
            Spacer(minLength: 0)
            Image(systemName: symbol).font(.system(size: 22)).foregroundColor(.accentColor)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            Text(caption).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(RoundedRectangle(cornerRadius: 10).fill(cardBG))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor))
    }
}

// MARK: Indicators

struct IndicatorsTab: View {
    let drive: Drive
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if drive.indicators.isEmpty {
                Text(drive.smartMessage.isEmpty ? "No health indicators reported." : drive.smartMessage)
                    .foregroundColor(.secondary)
            } else {
                SectionTitle(text: "Health Indicators")
                IndicatorTable(items: drive.indicators.filter { !$0.informational })
                SectionTitle(text: "Usage Statistics")
                IndicatorTable(items: drive.indicators.filter { $0.informational })
            }
        }
    }
}

struct IndicatorTable: View {
    let items: [Indicator]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Indicator").frame(maxWidth: .infinity, alignment: .leading)
                Text("Value").frame(width: 150, alignment: .trailing)
                Text("").frame(width: 160)
                Text("Status").frame(width: 90, alignment: .center)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            Rectangle().fill(lineColor).frame(height: 1)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 12.5, weight: .medium))
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.value).font(.system(size: 12.5, design: .monospaced))
                        .frame(width: 150, alignment: .trailing)
                    Group {
                        if let f = item.fraction {
                            Bar(fraction: f, color: item.status.color)
                        } else { Color.clear }
                    }
                    .frame(width: 140, height: 8)
                    .padding(.horizontal, 10)
                    Group {
                        if item.informational {
                            Text("INFO").font(.system(size: 10.5, weight: .bold)).foregroundColor(.secondary)
                        } else {
                            StatusBadge(status: item.status)
                        }
                    }
                    .frame(width: 90)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(i % 2 == 1 ? Color.primary.opacity(0.035) : Color.clear)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBG))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(lineColor))
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(lineColor)
                Capsule().fill(color).frame(width: max(4, g.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
    }
}

// MARK: ATA attributes

struct AttributesTab: View {
    let drive: Drive
    var body: some View {
        let cols: [(String, CGFloat?)] = [("ID", 40), ("Attribute", nil), ("Value", 60), ("Worst", 60), ("Threshold", 75), ("Raw", 150), ("Status", 90)]
        VStack(spacing: 0) {
            HStack {
                ForEach(cols, id: \.0) { c in
                    if let w = c.1 { Text(c.0).frame(width: w, alignment: .leading) }
                    else { Text(c.0).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            Rectangle().fill(lineColor).frame(height: 1)
            ForEach(Array(drive.attributes.enumerated()), id: \.element.id) { i, a in
                HStack {
                    Text("\(a.id)").frame(width: 40, alignment: .leading)
                    HStack(spacing: 4) {
                        Text(a.name)
                        if a.prefailure { Text("PRE-FAIL").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(a.value)").frame(width: 60, alignment: .leading)
                    Text("\(a.worst)").frame(width: 60, alignment: .leading)
                    Text("\(a.threshold)").frame(width: 75, alignment: .leading)
                    Text(a.raw).lineLimit(1).frame(width: 150, alignment: .leading)
                    StatusBadge(status: a.status).frame(width: 90, alignment: .leading)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(i % 2 == 1 ? Color.primary.opacity(0.035) : Color.clear)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBG))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(lineColor))
    }
}

// MARK: Logs

struct LogsTab: View {
    let drive: Drive
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Error Log")
            LogTable(header: drive.errorLogHeader, rows: drive.errorLog,
                     empty: drive.errorCount.map { $0 == 0 ? "No errors logged." : "\($0) errors counted over the drive's life; no entries are currently stored in the log." }
                        ?? "Error log not available.")
            SectionTitle(text: "Self-Test Log")
            LogTable(header: drive.selfTestHeader, rows: drive.selfTests,
                     empty: drive.selfTestSupported == false ? "This drive does not support self-tests." : "No self-tests have been run.")
            if drive.selfTestSupported == true {
                Text("Run a short self-test from Terminal with:  sudo smartctl -t short /dev/\(drive.id)")
                    .font(.system(size: 11.5)).foregroundColor(.secondary).textSelection(.enabled)
            }
        }
    }
}

struct LogTable: View {
    let header: [String]
    let rows: [LogEntry]
    let empty: String
    var body: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                Text(empty).font(.system(size: 12.5)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            } else {
                HStack {
                    ForEach(header, id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
                }
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                Rectangle().fill(lineColor).frame(height: 1)
                ForEach(rows) { r in
                    HStack {
                        ForEach(Array(r.columns.enumerated()), id: \.offset) { Text($0.element).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBG))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(lineColor))
    }
}

// MARK: Info

struct InfoTab: View {
    let drive: Drive
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(drive.info.enumerated()), id: \.offset) { i, row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundColor(.secondary).frame(width: 200, alignment: .leading)
                    Text(row.1).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(i % 2 == 1 ? Color.primary.opacity(0.035) : Color.clear)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBG))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(lineColor))
    }
}

struct RawTab: View {
    @EnvironmentObject var store: DriveStore
    let drive: Drive
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.smartctlPath == nil {
                Text("smartctl is not installed.").foregroundColor(.secondary)
            } else {
                Text(drive.rawText ?? "Loading…")
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { store.loadRaw(for: drive.id) }
        .onChange(of: store.lastUpdated) { _ in store.loadRaw(for: drive.id) }
        .onChange(of: drive.id) { id in store.loadRaw(for: id) }
    }
}
