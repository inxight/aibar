import Foundation
import ServiceManagement

/// 로그인 시 자동 실행 등록.
///
/// `SMAppService.mainApp` 은 앱 번들 기준으로 동작한다. 번들 없이 실행 파일만 돌리는
/// 개발 중에는 등록이 실패할 수 있어, 실패를 조용히 삼키고 현재 상태를 되읽게 해 둔다.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[AIBar] 로그인 항목 변경 실패: \(error.localizedDescription)")
            }
        }
    }
}
