import Foundation

/// Claude Code 가 저장해 둔 OAuth 자격증명.
///
/// 이 앱은 읽기만 한다. 갱신하거나 다시 저장하지 않는다.
/// Anthropic 문서는 제3자 도구가 Claude 세션 토큰을 저장·중계하는 것을 허용하지 않으므로
/// (https://code.claude.com/docs/en/legal-and-compliance), 토큰 관리는 Claude Code 본체에 맡긴다.
struct ClaudeCredentials: Sendable, Equatable {
    var accessToken: String
    /// epoch 밀리초. Claude Code 가 그 단위로 적는다.
    var expiresAtMilliseconds: Double?
    var subscriptionType: String?
    var source: Source

    enum Source: Sendable, Equatable {
        case file
        case keychain
        /// `CLAUDE_CODE_OAUTH_TOKEN` 으로 넘어온 토큰.
        case environment
    }

    /// 만료 시각이 지났는지. 만료 시각을 모르면 일단 써 보고 서버 응답으로 판단한다.
    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAtMilliseconds else { return false }
        return now.timeIntervalSince1970 * 1000 >= expiresAtMilliseconds
    }
}

/// 자격증명을 파일 → Keychain → 환경변수 순으로 찾는다.
///
/// 실측(2026-09-13): 이 기기에는 `~/.claude/.credentials.json` 이 없고 Keychain 항목만 있다.
/// 두 경로 모두 최상위 키는 `claudeAiOauth` 다.
struct ClaudeCredentialStore {
    static let keychainService = "Claude Code-credentials"

    private let homeDirectory: URL
    private let environment: [String: String]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    private var credentialsFileURL: URL {
        homeDirectory.appendingPathComponent(".claude/.credentials.json")
    }

    func load() throws -> ClaudeCredentials {
        if let fromFile = loadFromFile() {
            return fromFile
        }
        if let fromKeychain = try loadFromKeychain() {
            return fromKeychain
        }
        if let fromEnvironment = loadFromEnvironment() {
            return fromEnvironment
        }
        throw UsageError.credentialsNotFound
    }

    // MARK: - 개별 경로

    private func loadFromFile() -> ClaudeCredentials? {
        guard
            let data = try? Data(contentsOf: credentialsFileURL),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        return Self.parse(root: root, source: .file)
    }

    private func loadFromKeychain() throws -> ClaudeCredentials? {
        let output: String
        do {
            output = try ProcessRunner.runSync(
                executable: "/usr/bin/security",
                arguments: ["find-generic-password", "-s", Self.keychainService, "-w"]
            )
        } catch UsageError.invalidResponse(let message) {
            let normalized = message.lowercased()
            // 항목이 없는 것은 오류가 아니다. 다음 경로로 넘어간다.
            if normalized.contains("could not be found") {
                return nil
            }
            if normalized.contains("user interaction is not allowed")
                || normalized.contains("denied")
                || normalized.contains("cancel") {
                throw UsageError.credentialsUnreadable("Keychain 접근이 거부되었습니다.")
            }
            throw UsageError.credentialsUnreadable(message)
        }

        guard
            let data = output.data(using: .utf8),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        return Self.parse(root: root, source: .keychain)
    }

    private func loadFromEnvironment() -> ClaudeCredentials? {
        guard
            let raw = environment["CLAUDE_CODE_OAUTH_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        return ClaudeCredentials(
            accessToken: raw,
            expiresAtMilliseconds: nil,
            subscriptionType: nil,
            source: .environment
        )
    }

    // MARK: - 파싱

    static func parse(root: [String: Any], source: ClaudeCredentials.Source) -> ClaudeCredentials? {
        guard
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let rawToken = oauth["accessToken"] as? String
        else {
            return nil
        }
        let accessToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else { return nil }

        return ClaudeCredentials(
            accessToken: accessToken,
            expiresAtMilliseconds: number(oauth["expiresAt"]),
            subscriptionType: trimmed(oauth["subscriptionType"]),
            source: source
        )
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }
}
