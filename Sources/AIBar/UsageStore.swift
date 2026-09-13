import Foundation
import Observation

/// 사용량을 주기적으로 받아 화면에 넘겨주는 곳.
@MainActor
@Observable
final class UsageStore {
    private(set) var snapshot: UsageSnapshot = .empty
    private(set) var isRefreshing = false

    /// 갱신 주기(초). 기본 5분.
    var refreshInterval: TimeInterval {
        didSet {
            guard refreshInterval != oldValue else { return }
            UserDefaults.standard.set(refreshInterval, forKey: Self.intervalKey)
            restartTimer()
        }
    }

    static let intervalKey = "refreshIntervalSeconds"
    static let defaultInterval: TimeInterval = 300

    private let claudeClient: ClaudeClient
    private let codexClient: CodexClient
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?

    init(
        claudeClient: ClaudeClient = ClaudeClient(),
        codexClient: CodexClient = CodexClient()
    ) {
        self.claudeClient = claudeClient
        self.codexClient = codexClient

        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        refreshInterval = stored > 0 ? stored : Self.defaultInterval
    }

    func start() {
        restartTimer()
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// 지금 바로 한 번 갱신한다. 이미 돌고 있으면 무시한다.
    func refresh() {
        guard refreshTask == nil else { return }

        isRefreshing = true
        refreshTask = Task { [claudeClient, codexClient] in
            // 두 쪽은 서로 독립이므로 같이 기다린다.
            async let claude = claudeClient.fetch()
            async let codex = codexClient.fetch()
            let result = UsageSnapshot(
                claude: await claude,
                codex: await codex,
                updatedAt: Date()
            )

            guard !Task.isCancelled else { return }
            self.snapshot = result
            self.isRefreshing = false
            self.refreshTask = nil
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        // 메뉴를 열어 둔 동안에도 갱신이 멈추지 않게 한다.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
