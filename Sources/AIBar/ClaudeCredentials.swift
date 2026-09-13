import Foundation

/// Claude Code 가 저장해 둔 OAuth 자격증명.
struct ClaudeCredentials: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    /// epoch 밀리초. Claude Code 가 그 단위로 적는다.
    var expiresAtMilliseconds: Double?
    var subscriptionType: String?
    var source: Source

    enum Source: Sendable, Equatable {
        case file
        case keychain
        /// `CLAUDE_CODE_OAUTH_TOKEN` 으로 넘어온 토큰. 갱신 경로가 없다.
        case environment
    }

    /// 만료 5분 전부터 갱신 대상으로 본다.
    func needsRefresh(now: Date = Date()) -> Bool {
        guard let expiresAtMilliseconds else { return true }
        let buffer: Double = 5 * 60 * 1000
        return now.timeIntervalSince1970 * 1000 + buffer >= expiresAtMilliseconds
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
            if normalized.contains("could not be found") || normalized.contains("item could not be found") {
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
            refreshToken: nil,
            expiresAtMilliseconds: nil,
            subscriptionType: nil,
            source: .environment
        )
    }

    // MARK: - 파싱 · 저장

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
            refreshToken: trimmed(oauth["refreshToken"]),
            expiresAtMilliseconds: number(oauth["expiresAt"]),
            subscriptionType: trimmed(oauth["subscriptionType"]),
            source: source
        )
    }

    /// 갱신된 토큰을 원래 있던 자리에 되돌려 놓는다.
    ///
    /// Claude Code 본체와 같은 저장소를 공유하므로, 갱신 결과를 적어두지 않으면
    /// 양쪽이 서로 만료된 토큰을 주고받게 된다.
    func save(_ credentials: ClaudeCredentials) {
        switch credentials.source {
        case .environment:
            return
        case .file:
            saveToFile(credentials)
        case .keychain:
            saveToKeychain(credentials)
        }
    }

    private func existingRoot(for source: ClaudeCredentials.Source) -> [String: Any] {
        switch source {
        case .file:
            guard
                let data = try? Data(contentsOf: credentialsFileURL),
                let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return [:] }
            return root
        case .keychain:
            guard
                let output = try? ProcessRunner.runSync(
                    executable: "/usr/bin/security",
                    arguments: ["find-generic-password", "-s", Self.keychainService, "-w"]
                ),
                let data = output.data(using: .utf8),
                let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return [:] }
            return root
        case .environment:
            return [:]
        }
    }

    /// 기존 항목의 다른 키(`mcpOAuth` 등)를 지우지 않도록 병합한다.
    private func merged(_ credentials: ClaudeCredentials) -> [String: Any] {
        var root = existingRoot(for: credentials.source)
        var oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = credentials.accessToken
        if let refreshToken = credentials.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt = credentials.expiresAtMilliseconds {
            oauth["expiresAt"] = expiresAt
        }
        if let subscriptionType = credentials.subscriptionType {
            oauth["subscriptionType"] = subscriptionType
        }
        root["claudeAiOauth"] = oauth
        return root
    }

    private func saveToFile(_ credentials: ClaudeCredentials) {
        let root = merged(credentials)
        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: credentialsFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: credentialsFileURL, options: .atomic)
    }

    private func saveToKeychain(_ credentials: ClaudeCredentials) {
        let root = merged(credentials)
        guard
            let data = try? JSONSerialization.data(withJSONObject: root),
            let json = String(data: data, encoding: .utf8)
        else { return }

        // security 에는 덮어쓰기가 없어 지우고 다시 넣는다.
        _ = try? ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["delete-generic-password", "-s", Self.keychainService]
        )
        _ = try? ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["add-generic-password", "-s", Self.keychainService, "-w", json]
        )
    }

    // MARK: - 작은 도구들

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
