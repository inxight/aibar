import Foundation

/// 사용량을 제공하는 쪽.
enum Provider: String, Sendable, CaseIterable {
    case claude
    case codex
}

/// Claude 사용량. 전부 「쓴 양」 기준(0 = 안 씀, 100 = 다 씀).
///
/// `/api/oauth/usage` 실측(2026-09-13) 기준으로 값의 출처가 서로 다르다.
///   - 5시간 창 : `five_hour.utilization`
///   - 주간 창   : `seven_day.utilization`
///   - Fable     : `limits[]` 중 `kind == "weekly_scoped"` 이고
///                 `scope.model.display_name == "Fable"` 인 항목의 `percent`
///     (`seven_day_opus` 같은 전용 필드는 null 로 내려온다)
struct ClaudeUsage: Sendable, Equatable {
    var fiveHourUsed: Double?
    var weeklyUsed: Double?
    var fableUsed: Double?
    /// 화면에 붙이는 리셋 시각. 주간 창 기준이다.
    var weeklyResetsAt: Date?
    var subscriptionType: String?
}

/// Codex 사용량. Claude 와 헷갈리지 않게 같은 「쓴 양」 기준으로 담는다.
///
/// `account/rateLimits/read` 실측(2026-09-13) 기준으로 primary 가 항상 5시간 창인 것은 아니다.
/// 계정에 따라 primary 가 주간(windowDurationMins == 10080)이고 secondary 가 null 이므로,
/// 창 종류는 위치가 아니라 `windowDurationMins` 로 판별해야 한다.
struct CodexUsage: Sendable, Equatable {
    var weeklyUsed: Double?
    var weeklyResetsAt: Date?
    var planType: String?
}

/// 한 제공자의 조회 결과. 실패해도 다른 쪽 표시를 막지 않도록 값과 오류를 함께 들고 다닌다.
struct ProviderResult<Value: Sendable & Equatable>: Sendable, Equatable {
    var value: Value?
    var errorMessage: String?

    var isFailed: Bool { value == nil && errorMessage != nil }

    static func success(_ value: Value) -> Self {
        ProviderResult(value: value, errorMessage: nil)
    }

    static func failure(_ message: String) -> Self {
        ProviderResult(value: nil, errorMessage: message)
    }
}

/// 화면에 그릴 한 번의 조회 결과 전체.
struct UsageSnapshot: Sendable, Equatable {
    var claude: ProviderResult<ClaudeUsage>
    var codex: ProviderResult<CodexUsage>
    var updatedAt: Date

    static let empty = UsageSnapshot(
        claude: ProviderResult(value: nil, errorMessage: nil),
        codex: ProviderResult(value: nil, errorMessage: nil),
        updatedAt: .distantPast
    )
}

enum UsageError: Error, LocalizedError, Equatable {
    case credentialsNotFound
    case credentialsUnreadable(String)
    case sessionExpired
    case authenticationFailed
    case httpStatus(Int)
    case invalidResponse(String)
    case executableNotFound(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "로그인 정보를 찾을 수 없습니다."
        case .credentialsUnreadable(let detail):
            return "로그인 정보를 읽지 못했습니다: \(detail)"
        case .sessionExpired:
            return "세션이 만료되었습니다. 다시 로그인하세요."
        case .authenticationFailed:
            return "인증에 실패했습니다."
        case .httpStatus(let code):
            return "서버가 HTTP \(code) 를 반환했습니다."
        case .invalidResponse(let detail):
            return "응답을 해석하지 못했습니다: \(detail)"
        case .executableNotFound(let name):
            return "\(name) 명령을 찾을 수 없습니다."
        case .timedOut(let what):
            return "\(what) 응답이 시간 내에 오지 않았습니다."
        }
    }
}
