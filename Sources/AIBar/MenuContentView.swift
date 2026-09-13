import AppKit
import SwiftUI

/// 메뉴바 항목을 눌렀을 때 열리는 내용.
struct MenuContentView: View {
    @Bindable var store: UsageStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private static let intervalChoices: [(String, TimeInterval)] = [
        ("1분", 60), ("5분", 300), ("10분", 600), ("30분", 1800),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            providerSection(
                provider: .claude,
                title: "Claude",
                detail: store.snapshot.claude.value?.subscriptionType.map(planName),
                error: store.snapshot.claude.errorMessage,
                rows: claudeRows,
                resetsAt: store.snapshot.claude.value?.weeklyResetsAt
            )

            Divider()

            providerSection(
                provider: .codex,
                title: "Codex",
                detail: store.snapshot.codex.value?.planType.map(planName),
                error: store.snapshot.codex.errorMessage,
                rows: codexRows,
                resetsAt: store.snapshot.codex.value?.weeklyResetsAt
            )

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: - 제공자 한 덩어리

    @ViewBuilder
    private func providerSection(
        provider: Provider,
        title: String,
        detail: String?,
        error: String?,
        rows: [(String, String)],
        resetsAt: Date?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: BrandIcon.image(
                    for: provider,
                    size: 13,
                    color: provider == .claude ? BrandIcon.claudeOrange : .labelColor
                ))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let error, rows.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(rows, id: \.0) { label, value in
                    HStack {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(value)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                }
                if let resetsAt {
                    HStack {
                        Text("리셋")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(UsageFormatter.remaining(until: resetsAt)) 후 · \(Self.clockFormatter.string(from: resetsAt))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Claude 는 쓴 양으로 보여준다.
    private var claudeRows: [(String, String)] {
        guard let usage = store.snapshot.claude.value else { return [] }
        return [
            ("5시간 사용", UsageFormatter.percentage(usage.fiveHourUsed)),
            ("주간 사용", UsageFormatter.percentage(usage.weeklyUsed)),
            ("Fable 사용", UsageFormatter.percentage(usage.fableUsed)),
        ]
    }

    /// Codex 도 Claude 와 같은 기준(쓴 양)으로 보여준다.
    private var codexRows: [(String, String)] {
        guard let usage = store.snapshot.codex.value else { return [] }
        return [("주간 사용", UsageFormatter.percentage(usage.weeklyUsed))]
    }

    // MARK: - 아래쪽 조작부

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lastUpdatedText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(store.isRefreshing ? "갱신 중…" : "새로고침") {
                    store.refresh()
                }
                .disabled(store.isRefreshing)
                .controlSize(.small)
            }

            HStack {
                Text("갱신 주기")
                    .font(.system(size: 11))
                Spacer()
                Picker("", selection: $store.refreshInterval) {
                    ForEach(Self.intervalChoices, id: \.1) { name, seconds in
                        Text(name).tag(seconds)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 90)
            }

            Toggle("로그인 시 시작", isOn: $launchAtLogin)
                .font(.system(size: 11))
                .controlSize(.small)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.isEnabled = newValue
                    // 등록이 거부될 수 있으므로 실제 상태를 되읽는다.
                    launchAtLogin = LaunchAtLogin.isEnabled
                }

            HStack {
                Spacer()
                Button("종료") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
        }
    }

    private var lastUpdatedText: String {
        guard store.snapshot.updatedAt != .distantPast else { return "아직 조회 전" }
        return "갱신 \(Self.clockFormatter.string(from: store.snapshot.updatedAt))"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    private func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "claude_max", "max": return "Max"
        case "claude_pro", "pro": return "Pro"
        case "api", "claude_api": return "API"
        default: return raw
        }
    }
}
