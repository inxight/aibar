import Foundation

/// Codex 사용량 조회.
///
/// Codex 는 HTTP 엔드포인트 대신 `codex app-server` 를 띄워 JSON-RPC 로 물어본다.
/// 읽기 전용·미신뢰 모드로 실행해 이 앱이 파일을 건드리지 않게 한다.
struct CodexClient: Sendable {
    /// 7일 창의 길이(분). 응답의 `windowDurationMins` 와 맞춰 쓴다.
    static let weeklyWindowMinutes = 10080
    var timeout: TimeInterval = 20

    func fetch() async -> ProviderResult<CodexUsage> {
        do {
            let limits = try await requestRateLimits()

            guard let weekly = limits.weeklyWindow, let usedPercent = weekly.usedPercent else {
                return .failure("주간 한도 정보가 응답에 없습니다.")
            }
            return .success(CodexUsage(
                // Claude 와 같은 기준(쓴 양)으로 맞춘다.
                weeklyUsed: usedPercent.clampedToPercentage,
                weeklyResetsAt: weekly.resetsAt.map(Date.init(timeIntervalSince1970:)),
                planType: limits.planType
            ))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(message)
        }
    }

    private func requestRateLimits() async throws -> CodexRateLimitsPayload {
        guard let executable = ProcessRunner.which("codex") else {
            throw UsageError.executableNotFound("codex")
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessRunner.environment()
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        try process.run()

        // 응답이 오지 않을 때 영원히 매달리지 않도록, 제한 시간이 지나면 프로세스를 끊는다.
        // 그러면 stdout 이 닫히고 아래 읽기 루프가 오류로 빠져나온다.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
        }

        // 응답 줄은 하나의 순열로 읽어야 한다. 매번 새로 만들면 앞서 읽은 줄을 잃는다.
        var lines = stdout.fileHandleForReading.bytes.lines.makeAsyncIterator()
        let writer = stdin.fileHandleForWriting

        try Self.writeLine(CodexRequest.initialize, to: writer)
        _ = try await Self.readResponse(id: 1, from: &lines)

        try Self.writeLine(CodexRequest.initialized, to: writer)
        try Self.writeLine(CodexRequest.rateLimits, to: writer)

        let response = try await Self.readResponse(id: 2, from: &lines)
        guard let rateLimits = response.result?.rateLimits else {
            throw UsageError.invalidResponse("result.rateLimits 가 없습니다.")
        }
        return rateLimits
    }

    // MARK: - JSON-RPC 입출력

    static func writeLine(_ json: String, to handle: FileHandle) throws {
        handle.write(Data(json.utf8))
        handle.write(Data([0x0A]))
    }

    /// 지정한 id 의 응답이 나올 때까지 줄을 읽는다. 알림이나 다른 id 는 건너뛴다.
    static func readResponse<I: AsyncIteratorProtocol>(
        id: Int,
        from iterator: inout I
    ) async throws -> CodexRPCResponse where I.Element == String {
        while let line = try await iterator.next() {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            guard let response = try? JSONDecoder().decode(CodexRPCResponse.self, from: data) else {
                continue
            }
            guard response.id == id else { continue }

            if let error = response.error {
                throw UsageError.invalidResponse(error.message ?? "알 수 없는 오류")
            }
            return response
        }
        throw UsageError.invalidResponse("app-server 가 응답 \(id) 전에 종료했습니다.")
    }
}

/// 보낼 요청은 고정이라 문자열로 둔다.
private enum CodexRequest {
    static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"aibar","version":"0.1.0"}}}"#
    static let initialized = #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#
    static let rateLimits = #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#
}

// MARK: - 응답 형태

struct CodexRPCResponse: Decodable, Sendable {
    let id: Int?
    let result: CodexRPCResult?
    let error: CodexRPCError?
}

struct CodexRPCResult: Decodable, Sendable {
    let rateLimits: CodexRateLimitsPayload?
}

struct CodexRPCError: Decodable, Sendable {
    let code: Int?
    let message: String?
}

struct CodexRateLimitsPayload: Decodable, Sendable, Equatable {
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let planType: String?

    /// 주간 창을 고른다.
    ///
    /// primary 가 항상 5시간 창인 것은 아니다. 실측한 계정에서는 primary 가 주간(10080분)이고
    /// secondary 가 null 이었다. 그래서 위치가 아니라 창 길이로 판별한다.
    var weeklyWindow: CodexWindow? {
        let windows = [primary, secondary].compactMap { $0 }
        if let exact = windows.first(where: { $0.windowDurationMins == CodexClient.weeklyWindowMinutes }) {
            return exact
        }
        // 정확히 10080 이 없으면 가장 긴 창을 주간으로 본다.
        return windows.max { ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0) }
    }
}

struct CodexWindow: Decodable, Sendable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    /// epoch 초.
    let resetsAt: Double?
}

extension Double {
    /// 표시용으로 0~100 밖으로 나가지 않게 자른다.
    var clampedToPercentage: Double {
        Swift.min(100, Swift.max(0, self))
    }
}
