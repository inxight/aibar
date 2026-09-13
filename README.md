# AIBar

Claude 와 Codex 의 사용량을 macOS 메뉴바 한 줄로 보여주는 앱.

```
✳ 3/97/77 7H   ◎ 0 149H
```

| 자리 | 뜻 |
|---|---|
| `3` | Claude 5시간 창에서 쓴 양 |
| `97` | Claude 주간 창에서 쓴 양 |
| `77` | Claude Fable 모델 주간 쓴 양 |
| `7H` | Claude 주간 창이 리셋되기까지 남은 시간 |
| `0` | Codex 주간 한도에서 쓴 양 |
| `149H` | Codex 주간 창이 리셋되기까지 남은 시간 |

숫자는 전부 **쓴 양**이다. 0 이면 아직 안 썼고 100 이면 다 썼다. `%` 기호는 붙이지 않는다.
리셋까지 한 시간 미만이면 `45M` 처럼 분으로 표시한다.

메뉴바 항목을 누르면 항목별 수치, 리셋 시각, 갱신 주기, 로그인 시 시작 설정이 열린다.

## 설치

`AIBar-*.dmg` 를 열고 `AIBar.app` 을 `Applications` 로 끌어다 놓는다. 실행하면 메뉴바에만 뜬다
(Dock 에는 나타나지 않는다).

**처음 열 때 «확인되지 않은 개발자» 또는 «손상되었기 때문에 열 수 없습니다» 가 나온다.**
Apple 공증을 받지 않은 앱이라 그렇다. 다음 중 하나로 넘긴다.

- **시스템 설정 → 개인정보 보호 및 보안** 으로 가면 아래쪽에 «AIBar 을(를) 열도록 허용» 버튼이 있다. 누르고 다시 연다.
- 또는 터미널에서 격리 표시를 지운다.

  ```bash
  xattr -dr com.apple.quarantine /Applications/AIBar.app
  ```

한 번 허용하면 그 뒤로는 그냥 열린다.

## 요구사항

- macOS 14 이상
- Swift 6 (Xcode 26 에 포함)
- 로그인된 [Claude Code](https://claude.com/claude-code) — 사용량 조회에 쓸 자격증명을 여기서 가져온다
- 설치된 `codex` CLI — Codex 사용량 조회에 쓴다

둘 중 하나가 없어도 나머지는 그대로 표시된다. 없는 쪽은 `로그인 필요` 또는 `미설치` 로 나온다.

## 빌드와 실행

```bash
./scripts/build-app.sh      # build/AIBar.app 생성 (이 기계용)
open build/AIBar.app

swift test                  # 파싱·포맷 로직 테스트
```

개발 중에는 `swift build && swift run` 으로도 뜨지만, 로그인 항목 등록은 번들에서만 제대로 동작한다.

## 배포용 DMG 만들기

```bash
./scripts/make-dmg.sh       # build/AIBar-<버전>.dmg (Apple Silicon + Intel)
```

**Gatekeeper 를 통과시키려면 Developer ID 인증서와 공증이 필요하다.** 둘 다 갖춰져 있으면
위 스크립트가 알아서 서명하고 공증까지 하고, 없으면 ad-hoc 서명 상태로 만든다
(그 경우 받는 쪽이 위 «설치» 의 허용 절차를 한 번 거쳐야 한다).

갖추려면 두 가지가 필요하다. 둘 다 Apple Developer Program 멤버십이 있어야 한다.

1. **Developer ID Application 인증서** — Apple Developer 포털에서 발급받아 키체인에 넣는다.
   App Store 용인 `Apple Distribution` 인증서로는 DMG 직접 배포를 서명할 수 없다.
2. **공증 자격증명** — 앱 암호를 만들어 `aibar` 라는 이름으로 등록해 둔다.

   ```bash
   xcrun notarytool store-credentials aibar \
     --apple-id <Apple ID> --team-id <팀 ID> --password <앱 암호>
   ```

제대로 됐는지는 만들어진 DMG 안의 앱으로 확인한다. `accepted` 가 나와야 한다.

```bash
spctl -a -vv /Volumes/AIBar/AIBar.app
```

## 어디서 값을 가져오는가

별도 로그인이나 API 키가 필요 없다. 이미 기기에 있는 CLI 인증을 그대로 쓴다.

**Claude** — `~/.claude/.credentials.json` → Keychain(`Claude Code-credentials`) → 환경변수
`CLAUDE_CODE_OAUTH_TOKEN` 순서로 OAuth 토큰을 찾아 `GET https://api.anthropic.com/api/oauth/usage`
를 호출한다. 토큰이 만료됐으면 갱신한 뒤 원래 자리에 되돌려 놓는다 (Claude Code 본체와 저장소를
공유하므로 갱신 결과를 적어두지 않으면 서로 만료된 토큰을 주고받게 된다).

**Codex** — `codex -s read-only -a untrusted app-server` 를 띄우고 JSON-RPC 로
`account/rateLimits/read` 를 부른다. 읽기 전용·미신뢰 모드라 이 앱이 파일을 건드리지 않는다.

값은 전부 이 기기에서 제공자에게 직접 간다. 중계 서버도, 수집도 없다.

## 구현에서 주의한 곳

응답 형태를 실제로 호출해 확인한 결과(2026-09-13), 곧이곧대로 읽으면 틀리는 자리가 두 군데 있었다.

**Fable 사용량은 전용 필드에 없다.** `seven_day_opus` 같은 모델별 필드는 전부 `null` 로 내려오고,
Fable 수치는 `limits[]` 배열 안에 `kind: "weekly_scoped"` 이고
`scope.model.display_name == "Fable"` 인 항목의 `percent` 로만 들어 있다.

**Codex 의 `primary` 가 항상 5시간 창인 것은 아니다.** 실측한 계정에서는 `primary` 가
주간(`windowDurationMins: 10080`)이고 `secondary` 는 `null` 이었다. 그래서 위치가 아니라
창 길이로 주간 창을 골라낸다.

## 로고

런타임 SVG 파서를 들고 다니지 않으려고, 원본 SVG 를 미리 Swift 벡터 데이터로 바꿔
`Sources/AIBar/BrandPaths.swift` 에 넣어 두었다. 원본을 바꿨다면 다시 생성한다.

```bash
python3 scripts/svg2swift.py Resources/logos/claude.svg Resources/logos/openai.svg \
  > Sources/AIBar/BrandPaths.swift
```

## 라이선스

MIT. 로고는 [simple-icons](https://github.com/simple-icons/simple-icons) (CC0) 의 SVG 를
위 방식으로 변환해 넣었다.
