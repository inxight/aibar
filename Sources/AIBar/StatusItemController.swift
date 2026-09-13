import AppKit
import SwiftUI

/// 메뉴바 항목을 만들고 갱신한다.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: UsageStore
    private var observationTask: Task<Void, Never>?
    /// 리셋까지 남은 시간은 값이 안 바뀌어도 계속 줄어들므로 따로 다시 그린다.
    private var tickTimer: Timer?

    /// 메뉴바 글자 크기. 숫자가 많아 기본보다 조금 작게 쓴다.
    private let fontSize: CGFloat = 11
    private var iconSize: CGFloat { fontSize + 2 }

    init(store: UsageStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView(store: store)
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .noImage
        }

        startObserving()
        render()
    }

    /// deinit 은 메인 액터 밖에서 돌아 타이머를 건드릴 수 없으므로 종료 시 직접 부른다.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - 갱신

    private func startObserving() {
        // 값이 바뀔 때마다 다시 그린다.
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                withObservationTracking {
                    _ = self.store.snapshot
                } onChange: {
                    Task { @MainActor [weak self] in
                        self?.render()
                    }
                }
                // onChange 는 한 번만 불린다. 다음 변화를 기다리기 위해 잠깐 쉰다.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.render()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func render() {
        statusItem.button?.attributedTitle = makeTitle(from: store.snapshot)
    }

    /// 메뉴바에 찍을 한 줄을 만든다.
    ///
    ///     [Claude 로고] 5시간/주간/Fable 리셋   [OpenAI 로고] 남은양 리셋
    func makeTitle(from snapshot: UsageSnapshot, now: Date = Date()) -> NSAttributedString {
        let line = NSMutableAttributedString()

        line.append(iconAttachment(for: .claude, color: BrandIcon.claudeOrange))
        line.append(text(" "))
        if let message = snapshot.claude.errorMessage, snapshot.claude.value == nil {
            line.append(text(shortError(message), color: .secondaryLabelColor))
        } else {
            let usage = snapshot.claude.value
            line.append(text(UsageFormatter.claudeNumbers(usage)))
            line.append(text(" "))
            line.append(text(
                UsageFormatter.remaining(until: usage?.weeklyResetsAt, now: now),
                color: .secondaryLabelColor
            ))
        }

        // 두 제공자 사이는 두 칸 띄운다.
        line.append(text("  "))

        line.append(iconAttachment(for: .codex, color: .labelColor))
        line.append(text(" "))
        if let message = snapshot.codex.errorMessage, snapshot.codex.value == nil {
            line.append(text(shortError(message), color: .secondaryLabelColor))
        } else {
            let usage = snapshot.codex.value
            line.append(text(UsageFormatter.codexNumber(usage)))
            line.append(text(" "))
            line.append(text(
                UsageFormatter.remaining(until: usage?.weeklyResetsAt, now: now),
                color: .secondaryLabelColor
            ))
        }

        return line
    }

    // MARK: - 조각 만들기

    private func text(_ string: String, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: color,
        ])
    }

    private func iconAttachment(for provider: Provider, color: NSColor) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = BrandIcon.image(for: provider, size: iconSize, color: color)
        // 글자 기준선에 맞춰 살짝 내린다.
        attachment.bounds = CGRect(x: 0, y: -2, width: iconSize, height: iconSize)
        return NSAttributedString(attachment: attachment)
    }

    /// 메뉴바에는 짧게만 적고 자세한 내용은 팝오버에서 보여준다.
    private func shortError(_ message: String) -> String {
        if message.contains("만료") {
            return "토큰 만료"
        }
        if message.contains("로그인") || message.contains("인증") {
            return "로그인 필요"
        }
        if message.contains("찾을 수 없") {
            return "미설치"
        }
        return "오류"
    }

    // MARK: - 팝오버

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
