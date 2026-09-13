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

## 요구사항

- macOS 14 이상
- Swift 6 (Xcode 26 에 포함)
- 로그인된 [Claude Code](https://claude.com/claude-code) — 사용량 조회에 쓸 자격증명을 여기서 가져온다
- 설치된 `codex` CLI — Codex 사용량 조회에 쓴다

둘 중 하나가 없어도 나머지는 그대로 표시된다. 없는 쪽은 `로그인 필요` 또는 `미설치` 로 나온다.

## 빌드와 실행

```bash
./scripts/build-app.sh      # build/AIBar.app 생성
open build/AIBar.app
```

개발 중에는 `swift build && swift run` 으로도 뜨지만, 로그인 항목 등록은 번들에서만 제대로 동작한다.

```bash
swift test                  # 파싱·포맷 로직 테스트
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
