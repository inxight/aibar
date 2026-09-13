import Foundation

/// 메뉴바에 찍는 문자열을 만든다. % 기호는 붙이지 않고 숫자만 쓴다.
enum UsageFormatter {
    static let missing = "-"

    /// 0~100 값을 정수 문자열로. 소수점은 버린다(97.6 → 97).
    static func percentage(_ value: Double?) -> String {
        guard let value, value.isFinite else { return missing }
        return String(Int(value.rounded(.down)))
    }

    /// 리셋까지 남은 시간. 1시간 이상은 `9H`, 미만은 `45M`, 지났거나 모르면 `-`.
    static func remaining(until date: Date?, now: Date = Date()) -> String {
        guard let date else { return missing }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "0M" }

        let hours = interval / 3600
        if hours >= 1 {
            return "\(Int(hours.rounded(.down)))H"
        }
        let minutes = interval / 60
        return "\(max(1, Int(minutes.rounded(.down))))M"
    }

    /// Claude 쪽 숫자 묶음: 5시간/주간/Fable.
    static func claudeNumbers(_ usage: ClaudeUsage?) -> String {
        guard let usage else { return "\(missing)/\(missing)/\(missing)" }
        return [
            percentage(usage.fiveHourUsed),
            percentage(usage.weeklyUsed),
            percentage(usage.fableUsed),
        ].joined(separator: "/")
    }

    /// Codex 쪽 숫자: 주간 쓴 양 하나.
    static func codexNumber(_ usage: CodexUsage?) -> String {
        percentage(usage?.weeklyUsed)
    }
}
