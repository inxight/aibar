import Foundation

/// 외부 명령을 찾고 실행한다.
///
/// GUI 로 실행된 앱은 로그인 셸의 PATH 를 물려받지 못한다. 터미널에서는 보이는 `codex` 가
/// 앱에서는 안 보이는 일이 생기므로, 흔한 설치 경로를 직접 뒤진다.
enum ProcessRunner {
    /// 로그인 셸 PATH 를 못 받는 경우를 대비해 덧붙이는 경로들.
    static let extraPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
    }()

    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let current = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var merged = current
        for path in extraPaths where !merged.contains(path) {
            merged.append(path)
        }
        environment["PATH"] = merged.joined(separator: ":")
        return environment
    }

    /// 실행 파일의 절대 경로를 찾는다. 없으면 nil.
    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }

        let searchPaths = (environment()["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// 명령을 실행하고 표준출력을 돌려준다. 동기 호출이므로 백그라운드에서 쓴다.
    @discardableResult
    static func runSync(
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = 10
    ) throws -> String {
        guard let path = which(executable) else {
            throw UsageError.executableNotFound(executable)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = environment()
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        try process.run()

        // 파이프가 가득 차 프로세스가 멈추지 않도록 먼저 읽는다.
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                usleep(20_000)
            }
            if process.isRunning {
                process.terminate()
                throw UsageError.timedOut(executable)
            }
        } else {
            process.waitUntilExit()
        }

        let output = String(decoding: outputData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UsageError.invalidResponse(message.isEmpty ? output : message)
        }
        return output
    }
}
