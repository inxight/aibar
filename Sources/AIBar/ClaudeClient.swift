import Foundation

/// Claude 사용량 조회.
///
/// 엔드포인트와 응답 형태는 2026-09-13 에 실제 호출해 확인했다.
struct ClaudeClient: Sendable {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code 가 쓰는 공개 OAuth 클라이언트 식별자.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    var store = ClaudeCredentialStore()
    var session: URLSession = .shared

    func fetch() async -> ProviderResult<ClaudeUsage> {
        do {
            var credentials = try store.load()

            if credentials.needsRefresh() {
                credentials = try await refreshed(credentials)
            }

            var response: ClaudeUsageResponse
            do {
                response = try await requestUsage(accessToken: credentials.accessToken)
            } catch UsageError.authenticationFailed {
                // 만료 시각이 어긋난 경우가 있어 한 번은 갱신 후 재시도한다.
                credentials = try await refreshed(credentials)
                response = try await requestUsage(accessToken: credentials.accessToken)
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

    // MARK: - 토큰 갱신

    private func refreshed(_ credentials: ClaudeCredentials) async throws -> ClaudeCredentials {
        // 환경변수로 받은 토큰은 갱신 경로가 없다. 있는 그대로 쓴다.
        if credentials.source == .environment {
            return credentials
        }
        guard let refreshToken = credentials.refreshToken else {
            throw UsageError.sessionExpired
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": "user:profile user:inference user:sessions:claude_code",
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse("토큰 갱신 응답이 HTTP 가 아닙니다.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw UsageError.sessionExpired
        }

        let payload = try JSONDecoder().decode(ClaudeTokenResponse.self, from: data)
        guard
            let accessToken = payload.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            !accessToken.isEmpty
        else {
            throw UsageError.invalidResponse("갱신 응답에 access token 이 없습니다.")
        }

        var updated = credentials
        updated.accessToken = accessToken
        if let refreshToken = payload.refreshToken {
            updated.refreshToken = refreshToken
        }
        if let expiresIn = payload.expiresIn {
            updated.expiresAtMilliseconds = Date().timeIntervalSince1970 * 1000 + Double(expiresIn) * 1000
        }
        store.save(updated)
        return updated
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

struct ClaudeTokenResponse: Decodable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
