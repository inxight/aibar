import XCTest
@testable import AIBar

final class UsageFormatterTests: XCTestCase {
    func testPercentageDropsFraction() {
        XCTAssertEqual(UsageFormatter.percentage(97.9), "97")
        XCTAssertEqual(UsageFormatter.percentage(0), "0")
        XCTAssertEqual(UsageFormatter.percentage(100), "100")
    }

    func testPercentageWithoutValue() {
        XCTAssertEqual(UsageFormatter.percentage(nil), "-")
    }

    func testRemainingUsesHoursAboveOneHour() {
        let now = Date()
        let target = now.addingTimeInterval(9.6 * 3600)
        XCTAssertEqual(UsageFormatter.remaining(until: target, now: now), "9H")
    }

    func testRemainingUsesMinutesBelowOneHour() {
        let now = Date()
        let target = now.addingTimeInterval(45 * 60)
        XCTAssertEqual(UsageFormatter.remaining(until: target, now: now), "45M")
    }

    func testRemainingForPastDate() {
        let now = Date()
        XCTAssertEqual(UsageFormatter.remaining(until: now.addingTimeInterval(-60), now: now), "0M")
    }

    func testClaudeNumbersJoinsThreeValues() {
        let usage = ClaudeUsage(
            fiveHourUsed: 1,
            weeklyUsed: 97,
            fableUsed: 77,
            weeklyResetsAt: nil,
            subscriptionType: "max"
        )
        XCTAssertEqual(UsageFormatter.claudeNumbers(usage), "1/97/77")
    }

    func testClaudeNumbersWithMissingValues() {
        let usage = ClaudeUsage(
            fiveHourUsed: 5,
            weeklyUsed: nil,
            fableUsed: nil,
            weeklyResetsAt: nil,
            subscriptionType: nil
        )
        XCTAssertEqual(UsageFormatter.claudeNumbers(usage), "5/-/-")
    }
}

final class ClaudeResponseTests: XCTestCase {
    /// 2026-09-13 에 실제로 받은 응답을 줄인 것.
    /// Fable 수치는 전용 필드가 아니라 limits[] 안에만 있다는 점이 핵심이다.
    private let sample = """
    {
      "five_hour": { "utilization": 1.0, "resets_at": "2026-09-13T18:40:00.086487+00:00" },
      "seven_day": { "utilization": 97.0, "resets_at": "2026-09-13T22:00:00.086507+00:00" },
      "seven_day_opus": null,
      "limits": [
        { "kind": "session", "group": "session", "percent": 1, "resets_at": "2026-09-13T18:40:00.086487+00:00" },
        { "kind": "weekly_all", "group": "weekly", "percent": 97, "resets_at": "2026-09-13T22:00:00.086507+00:00" },
        { "kind": "weekly_scoped", "group": "weekly", "percent": 77,
          "resets_at": "2026-09-13T22:00:00.086706+00:00",
          "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null } }
      ]
    }
    """

    func testDecodesTopLevelWindows() throws {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(sample.utf8))
        XCTAssertEqual(response.fiveHour?.utilization, 1.0)
        XCTAssertEqual(response.sevenDay?.utilization, 97.0)
    }

    func testFindsFableInsideLimitsArray() throws {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(sample.utf8))
        XCTAssertEqual(response.fablePercent, 77)
    }

    func testFableLookupIsCaseInsensitive() throws {
        let json = """
        { "limits": [ { "kind": "weekly_scoped", "percent": 42,
          "scope": { "model": { "display_name": "fable" } } } ] }
        """
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.fablePercent, 42)
    }

    func testFableMissingWhenNoScopedLimit() throws {
        let json = """
        { "limits": [ { "kind": "weekly_all", "percent": 50 } ] }
        """
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.fablePercent)
    }

    func testParsesFractionalSecondDates() {
        let date = ClaudeClient.parseDate("2026-09-13T22:00:00.086507+00:00")
        XCTAssertNotNil(date)
    }

    func testParsesDatesWithoutFractionalSeconds() {
        let date = ClaudeClient.parseDate("2026-09-13T22:00:00Z")
        XCTAssertNotNil(date)
    }
}

final class ClaudeCredentialParsingTests: XCTestCase {
    func testParsesKeychainShape() throws {
        let json = """
        { "claudeAiOauth": { "accessToken": "token-value", "refreshToken": "refresh-value",
          "expiresAt": 1789336157946, "subscriptionType": "max" },
          "mcpOAuth": {} }
        """
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let credentials = try XCTUnwrap(ClaudeCredentialStore.parse(root: root, source: .keychain))

        XCTAssertEqual(credentials.accessToken, "token-value")
        XCTAssertEqual(credentials.expiresAtMilliseconds, 1789336157946)
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertEqual(credentials.source, .keychain)
    }

    func testRejectsPayloadWithoutToken() throws {
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(#"{"claudeAiOauth":{}}"#.utf8)) as? [String: Any]
        )
        XCTAssertNil(ClaudeCredentialStore.parse(root: root, source: .file))
    }

    func testExpiredOnlyAfterExpiryTime() {
        let now = Date()
        let past = ClaudeCredentials(
            accessToken: "t",
            expiresAtMilliseconds: (now.timeIntervalSince1970 - 1) * 1000,
            subscriptionType: nil, source: .keychain
        )
        XCTAssertTrue(past.isExpired(now: now))

        // 갱신을 하지 않으므로 만료 직전이라도 아직 유효하면 그대로 쓴다.
        let soon = ClaudeCredentials(
            accessToken: "t",
            expiresAtMilliseconds: (now.timeIntervalSince1970 + 60) * 1000,
            subscriptionType: nil, source: .keychain
        )
        XCTAssertFalse(soon.isExpired(now: now))
    }

    /// 만료된 토큰이면 서버에 보내지 않고, 갱신도 하지 않고, 파일도 건드리지 않아야 한다.
    func testExpiredTokenIsNeitherSentNorRewritten() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-test-\(UUID().uuidString)")
        let file = home.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let expiredAt = (Date().timeIntervalSince1970 - 3600) * 1000
        let original = Data("""
        {"claudeAiOauth":{"accessToken":"expired-token","refreshToken":"refresh-token","expiresAt":\(expiredAt)}}
        """.utf8)
        try original.write(to: file)

        // 요청이 나가면 바로 드러나도록 모든 네트워크를 막은 세션을 쓴다.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RejectAllRequests.self]
        let client = ClaudeClient(
            store: ClaudeCredentialStore(homeDirectory: home, environment: [:]),
            session: URLSession(configuration: configuration)
        )

        let result = await client.fetch()

        XCTAssertNil(result.value)
        XCTAssertEqual(result.errorMessage, UsageError.sessionExpired.errorDescription)
        XCTAssertFalse(RejectAllRequests.wasCalled, "만료된 토큰으로 요청이 나갔다")
        XCTAssertEqual(try Data(contentsOf: file), original, "자격증명 파일이 바뀌었다")
    }

    func testUnknownExpiryIsTriedAnyway() {
        let credentials = ClaudeCredentials(
            accessToken: "t", expiresAtMilliseconds: nil,
            subscriptionType: nil, source: .environment
        )
        XCTAssertFalse(credentials.isExpired())
    }
}

final class CodexResponseTests: XCTestCase {
    /// 2026-09-13 실측: primary 가 주간(10080분)이고 secondary 는 null 이었다.
    /// primary 를 5시간 창으로 가정하면 이 계정에서 틀린 값을 읽게 된다.
    func testPicksWeeklyWindowWhenItIsPrimary() throws {
        let json = """
        { "id": 2, "result": { "rateLimits": {
          "primary": { "usedPercent": 0, "windowDurationMins": 10080, "resetsAt": 1789849811 },
          "secondary": null, "planType": "pro" } } }
        """
        let response = try JSONDecoder().decode(CodexRPCResponse.self, from: Data(json.utf8))
        let weekly = try XCTUnwrap(response.result?.rateLimits?.weeklyWindow)

        XCTAssertEqual(weekly.windowDurationMins, 10080)
        XCTAssertEqual(weekly.usedPercent, 0)
        XCTAssertEqual(response.result?.rateLimits?.planType, "pro")
    }

    func testPicksWeeklyWindowWhenItIsSecondary() throws {
        let json = """
        { "id": 2, "result": { "rateLimits": {
          "primary": { "usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1789326493 },
          "secondary": { "usedPercent": 34, "windowDurationMins": 10080, "resetsAt": 1789913293 },
          "planType": "pro" } } }
        """
        let response = try JSONDecoder().decode(CodexRPCResponse.self, from: Data(json.utf8))
        let weekly = try XCTUnwrap(response.result?.rateLimits?.weeklyWindow)

        XCTAssertEqual(weekly.usedPercent, 34)
    }

    func testFallsBackToLongestWindow() throws {
        let json = """
        { "id": 2, "result": { "rateLimits": {
          "primary": { "usedPercent": 12, "windowDurationMins": 300 },
          "secondary": { "usedPercent": 34, "windowDurationMins": 1440 } } } }
        """
        let response = try JSONDecoder().decode(CodexRPCResponse.self, from: Data(json.utf8))
        let weekly = try XCTUnwrap(response.result?.rateLimits?.weeklyWindow)

        XCTAssertEqual(weekly.windowDurationMins, 1440)
    }

    func testDecodesErrorResponse() throws {
        let json = #"{ "id": 2, "error": { "code": -32601, "message": "method not found" } }"#
        let response = try JSONDecoder().decode(CodexRPCResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.error?.message, "method not found")
    }

    /// Claude 와 같은 기준(쓴 양)이므로 응답의 usedPercent 를 그대로 쓴다.
    func testUsedPercentIsShownAsIs() {
        XCTAssertEqual(0.0.clampedToPercentage, 0)
        XCTAssertEqual(34.0.clampedToPercentage, 34)
        // 서버가 범위를 벗어난 값을 주더라도 표시는 0~100 안에 둔다.
        XCTAssertEqual(130.0.clampedToPercentage, 100)
        XCTAssertEqual((-5.0).clampedToPercentage, 0)
    }

    func testCodexNumberUsesWeeklyUsed() {
        let usage = CodexUsage(weeklyUsed: 34, weeklyResetsAt: nil, planType: "pro")
        XCTAssertEqual(UsageFormatter.codexNumber(usage), "34")
    }
}

final class BrandPathTests: XCTestCase {
    func testPathsAreNotEmpty() {
        XCTAssertFalse(BrandPaths.claude.isEmpty)
        XCTAssertFalse(BrandPaths.openai.isEmpty)
    }

    /// 변환된 좌표가 원본 viewBox(0~24) 밖으로 크게 벗어나지 않아야 한다.
    func testPathsStayWithinViewBox() {
        for element in BrandPaths.claude + BrandPaths.openai {
            for value in element.coordinates {
                XCTAssertGreaterThanOrEqual(value, -0.5, "좌표가 viewBox 아래로 벗어남")
                XCTAssertLessThanOrEqual(value, BrandPaths.viewBox + 0.5, "좌표가 viewBox 위로 벗어남")
            }
        }
    }
}

/// 모든 요청을 가로채 실패시키고, 호출됐는지만 기록한다.
final class RejectAllRequests: URLProtocol {
    nonisolated(unsafe) static var wasCalled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.wasCalled = true
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

private extension BrandPathElement {
    var coordinates: [CGFloat] {
        switch self {
        case .move(let x, let y), .line(let x, let y):
            return [x, y]
        case .curve(let c1x, let c1y, let c2x, let c2y, let x, let y):
            return [c1x, c1y, c2x, c2y, x, y]
        case .close:
            return []
        }
    }
}
