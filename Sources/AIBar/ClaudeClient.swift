import Foundation

/// Claude 사용량 조회.
///
/// 엔드포인트와 응답 형태는 2026-09-13 에 실제 호출해 확인했다.
/// 토큰은 읽기만 하고 갱신·저장하지 않는다. 만료되면 Claude Code 를 실행해 갱신하도록 안내한다.
struct ClaudeClient: Sendable {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    var store = ClaudeCredentialStore()
    var session: URLSession = .shared

    func fetch() async -> ProviderResult<ClaudeUsage> {
        do {
            let credentials = try store.load()

            // 만료된 토큰으로는 요청하지 않는다. 갱신은 Claude Code 본체가 한다.
            if credentials.isExpired() {
                throw UsageError.sessionExpired
            }

            let response: ClaudeUsageResponse
            do {
                response = try await requestUsage(accessToken: credentials.accessToken)
            } catch UsageError.authenticationFailed {
                // 만료 시각이 남아 있어도 서버가 거부하면 같은 안내를 보인다.
                throw UsageError.sessionExpired
            }

            return .success(ClaudeUsage(
                fiveHourUsed: response.fiveHour?.utilization,
                weeklyUsed: response.sevenDay?.utilization,
                fableUsed: response.fablePercent,
                weeklyResetsAt: Self.parseDate(response.sevenDay?.resetsAt),
                subscriptionType: credentials.subscriptionType
            ))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(message)
        }
    }

    // MARK: - 사용량

    private func requestUsage(accessToken: String) async throws -> ClaudeUsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AIBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse("HTTP 응답이 아닙니다.")
        }

        switch http.statusCode {
        case 200 ..< 300:
            do {
                return try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            } catch {
                throw UsageError.invalidResponse(String(describing: error))
            }
        case 401, 403:
            throw UsageError.authenticationFailed
        default:
            throw UsageError.httpStatus(http.statusCode)
        }
    }

    // MARK: - 날짜

    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - 응답 형태

struct ClaudeUsageResponse: Decodable, Sendable {
    let fiveHour: ClaudeQuota?
    let sevenDay: ClaudeQuota?
    let limits: [ClaudeLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }

    /// Fable 사용량은 전용 필드가 없다. `limits[]` 에서 모델 이름으로 찾아야 한다.
    /// (`seven_day_opus` 같은 모델별 필드는 실측 시 전부 null 이었다)
    var fablePercent: Double? {
        limits?.first { limit in
            limit.scope?.model?.displayName?.caseInsensitiveCompare("Fable") == .orderedSame
        }?.percent
    }
}

struct ClaudeQuota: Decodable, Sendable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ClaudeLimit: Decodable, Sendable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let scope: ClaudeLimitScope?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, scope
        case resetsAt = "resets_at"
    }
}

struct ClaudeLimitScope: Decodable, Sendable {
    let model: ClaudeLimitModel?
}

struct ClaudeLimitModel: Decodable, Sendable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}
