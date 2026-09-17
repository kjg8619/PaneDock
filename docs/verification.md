# PaneDock 검증 기록

이 문서는 실제로 실행한 검증만 기록한다. 실행하지 않았거나 출력을 직접 보지 못한 항목은
통과로 적지 않고 "미실시" 또는 "미검증"으로 남긴다.

**기존 기록 보존 규칙:** 새 검증은 문서 끝에 절을 추가한다. 이전 절의 내용을 지우거나
수정하지 않는다. 정정이 필요하면 새 절에서 정정 사실을 밝힌다.

---

## 증거 등급 정의

이 문서에서 "성공"이라고 쓸 때는 반드시 어느 등급인지 함께 적는다. 세 등급은 서로 다르다.

| 등급 | 이름 | 의미 | 무엇을 증명하는가 |
| --- | --- | --- | --- |
| **E1** | 빌드 성공 | 컴파일·링크가 오류 없이 끝났다 | 코드가 문법·타입 수준에서 성립한다. **동작은 전혀 증명하지 않는다.** |
| **E2** | 가짜 입력 테스트 성공 | 스텁 서버나 합성 데이터로 코드 경로를 돌렸다 | 상태 규칙(순서 역전, 캐시, 오류 분류)이 설계대로 동작한다. **실제 herdr가 같은 신호를 준다는 보장은 없다.** |
| **E3** | 실제 pane 추적 성공 | 실행 중인 herdr와 실제 pane을 상대로 읽었다 | 실제 환경에서 값이 맞는다. **사용자 조작 시나리오(포커스 이동 등)는 여전히 별개다.** |
| E4 | 사용자 조작 필요 | 사람이 포커스를 옮기거나 `cd` 해야 재현된다 | (미실시) |
| E5 | 미검증 | 확인하지 않았다 | — |

---

## V1. 2026-09-16 — 포커스·경로 진단 프로토타입 (기획서 "검증 단계")

- 대상 커밋: `b254341 docs: add initial PaneDock product plan` (작업 트리 변경 없음)
- 검증 환경: macOS 27.0 (Build 26A428) arm64 / Swift 6.3.3 / SDK 26.5 /
  herdr `0.9.0-preview.2026-09-09-5a244caa60b0` (protocol 22, preview 채널) / Ghostty 1.3.1
- 검증자: 자동 검증은 구현 에이전트, 사용자 조작 검증은 미실시

### V1.1 변경한 파일

기존 파일은 **하나도 수정하지 않았다.** `docs/`의 기획서 3종, 루트 `.gitignore`,
`.omp/`는 그대로다. 생성한 파일만 적는다.

| 파일 | 목적 |
| --- | --- |
| `prototypes/focus-probe/Package.swift` | SwiftPM 실행 파일 정의 (검증용. 제품 앱 타깃과 분리) |
| `prototypes/focus-probe/.gitignore` | 프로토타입 안에서 `.build/`만 무시. 루트 `.gitignore`는 건드리지 않음 |
| `prototypes/focus-probe/README.md` | 실행·검증 절차, 강제 규칙 R1~R9, 알려진 한계 |
| `prototypes/focus-probe/Sources/FocusProbeCore/CurrentWorkInfo.swift` | 식별·경로·신선도·유효성 묶음, 상태 enum(`focusStatus`/`pathStatus`/`connectionStatus`), 경로 검증 프로토콜 |
| `prototypes/focus-probe/Sources/FocusProbeCore/HerdrWire.swift` | NDJSON 요청/응답 DTO, 이벤트 프레임 파싱, 이벤트 이름 정규화 |
| `prototypes/focus-probe/Sources/FocusProbeCore/HerdrSocketClient.swift` | 유닉스 소켓 연결, errno 분류, 요청 1건당 연결 1개, 전용 구독 연결 |
| `prototypes/focus-probe/Sources/FocusProbeCore/HerdrAdapter.swift` | `session.snapshot`/`pane.get` → `CurrentWorkInfo`, 경로 정규화, protocol 검사 |
| `prototypes/focus-probe/Sources/FocusProbeCore/FocusResolver.swift` | `focusGeneration` 관리, 늦은 응답 폐기 판정 |
| `prototypes/focus-probe/Sources/FocusProbeCore/ContextStore.swift` | 표시 묶음, 비활성 pane 캐시, 연결/경로 상태 전이 |
| `prototypes/focus-probe/Sources/FocusProbeCore/DiagnosticsReport.swift` | 진단 문자열, 변경 감지 키, JSON 출력 |
| `prototypes/focus-probe/Sources/FocusProbeCore/SelfTest.swift` | 결정적 검사 22건 (XCTest 대체) |
| `prototypes/focus-probe/Sources/FocusProbeCLI/main.swift` | CLI 진입점 (`--once`/`--watch`/`--self-test`) |
| `docs/verification.md` | 이 문서 |

일회용 검증 도구(스텁 서버 2개, 이벤트 관찰기 2개, 임시 SwiftPM 패키지 3개, 임시 소켓 파일)는
검증 후 전부 삭제했다. 저장소에 남기지 않았다.

### V1.2 실행한 명령과 결과

#### (a) 조사 — 읽기 전용

| 명령 | 결과 |
| --- | --- |
| `git status --short --branch` | `## main...origin/main` / 미추적 `?? .omp/` |
| `git log --oneline` | 커밋 1개: `b254341` |
| `sw_vers` | macOS 27.0, Build 26A428 |
| `xcode-select -p` | `/Library/Developer/CommandLineTools` (Xcode 미설치) |
| `swift --version` | Apple Swift 6.3.3, target `arm64-apple-macosx28.0` |
| `xcrun --show-sdk-path` / `--show-sdk-version` | `MacOSX.sdk` / `26.5` |
| `xcodebuild -version` | 오류: `requires Xcode` |
| `swift test` (임시 패키지) | 오류: **`no such module 'XCTest'`** → XCTest 사용 불가 |
| `ghostty --version` | Ghostty 1.3.1 |
| `cmux --version` / `cmux capabilities` | 0.64.22 / 오류: `Socket not found` (cmux 미실행) |
| `herdr --version` | `0.9.0-preview.2026-09-09-5a244caa60b0` |
| `herdr status` | server running, protocol 22, socket `~/.config/herdr/herdr.sock` |
| `herdr session list` | `default` 1개 |
| `herdr machine list` | `No saved SSH machines` |
| `herdr pane list` | pane 23개 / workspace 12개, `focused:true` 정확히 1개 |
| `herdr pane current` | **호출 pane** 반환 (`w3D:p6`, `focused:false`) |
| `env -u HERDR_PANE_ID herdr pane current` | **포커스 pane** 반환 (`w38:p7`, `focused:true`) |
| `herdr pane process-info` | `shell_pid`, `foreground_process_group_id`, `foreground_processes[].cwd` |
| `herdr api schema --json` | 378,462 bytes, `schema_version: 1`, `protocol: 22` |
| `lsappinfo front` / `launchctl managername` | `loginwindow` / `Aqua` |
| `who` | console + `ttys021`(100.75.126.105, SSH) |
| `sqlite3 ~/Library/.../TCC.db` | 오류: 접근 거부 (Full Disk Access 없음) |

수집·출력하지 않은 것: API 키, 인증 파일, 셸 이력, 전체 환경변수, `cmux.json`(소켓 비밀번호 포함 가능), 터미널 화면 내용.

#### (b) herdr 소켓 직접 확인 — 읽기 전용

| 확인 | 결과 |
| --- | --- |
| `ping` over NDJSON | `{"result":{"type":"pong","protocol":22,"capabilities":{...}}}` |
| `session.snapshot` | `focused_pane_id`, `focused_tab_id`, `focused_workspace_id`, `panes` 포함. 26,604 bytes |
| `events.subscribe` | `{"result":{"type":"subscription_started"}}` 수신 후 연결 유지 |
| 같은 연결에 두 번째 요청 | 서버가 연결을 닫는다(E2 설계 근거) |
| `env -i`(HERDR_* 전부 제거) 프로세스에서 `pane.list` | 성공 — **herdr 밖 프로세스도 읽을 수 있다** |
| `pane.list` / `pane.get` / `snapshot` 크기 | 15,804 / 690 / 26,604 bytes |
| CLI 20회 연속 실행 | 0.32초 (≈16ms/회) |

#### (c) Ghostty AppleScript 프로브 — 사용자 승인 후 실행 (읽기만)

| 명령 | 결과 |
| --- | --- |
| `osascript -e 'tell application "Ghostty" to get version'` | `1.3.1` (승인 대화상자 없이 즉시 응답 → TCC 자동화 **이미 승인됨**) |
| `... get id of every terminal` | 터미널 2개 |
| `... get working directory of every terminal` | **둘 다 `/Users/kangjingoo`** |
| `... get frontmost` | `false` |
| 대조: herdr 클라이언트/서버 프로세스 cwd | `/Users/kangjingoo` |
| 대조: herdr가 보고하는 pane 경로 | `~/Workspace/tool/pi` 등 실제 프로젝트 |

→ **Ghostty의 `working directory`는 바깥 터미널 프로세스의 cwd이며 herdr pane의 작업 경로가 아니다.**
pane 경로 소스로 쓸 수 없다.

#### (d) 빌드

| 명령 | 결과 |
| --- | --- |
| `rm -rf .build && swift build` | **`Build complete! (17.01s)`**, 오류·경고 0 |
| `swift build` (재실행) | `Build complete!` |

#### (e) 실행

| 명령 | 결과 |
| --- | --- |
| `focus-probe --self-test` | `22/22 checks passed`, exit 0 |
| `focus-probe --once` (실소켓) | `w38:p7` → `w38:p1` → `w3D:p6` (시각별), 매번 `herdr pane list`의 `focused`와 일치 |
| `focus-probe --once --json` | JSON 스냅샷 출력, 종료 코드 0 |
| `HERDR_PANE_ID=wZZ:p99 focus-probe --once --caller` | 목표 pane 불변(`w38:p7`), `caller wZZ:p99`만 표시 |
| `focus-probe --once --socket /tmp/pd-nonexistent.sock` | `connection unavailable`, exit 1 |
| `focus-probe --once --socket /tmp/pd-refused.sock` | `connection refused`, exit 1 |
| `focus-probe --once --socket /tmp/pd-stub.sock` (protocol 99) | `connection incompatible`, exit 1 |
| `focus-probe --watch` (실소켓, 12초) | 렌더 1회, 이후 무출력(변화 없음) |

### V1.3 자동 테스트 결과

#### E1 — 빌드 성공

| 검증 | 결과 |
| --- | --- |
| 깨끗한 빌드 | 통과. 오류·경고 0 |

**E1은 동작을 증명하지 않는다.** 아래 E2·E3와 분리해서 읽는다.

#### E2 — 가짜 입력(스텁/합성) 테스트 성공

**(1) 결정적 자체 검사 `--self-test` — 22건 전부 통과**

| 항목 | 내용 |
| --- | --- |
| D | 이전 세대 응답 폐기 |
| D | 목표 pane 변경 직후 도착한 이전 응답 폐기 |
| E | 전환 직후 `pending`, 이전 경로를 새 경로로 승격하지 않음 |
| B | 같은 pane 경로 갱신 → `tracked` |
| C | 비활성 pane은 캐시만 갱신, 표시 묶음 불변 |
| F | 재연결 시 세대 증가 + 이전 연결 응답 폐기 |
| F | ENOENT/ECONNREFUSED/EACCES → `unavailable`/`refused`/`denied` |
| F | 연결 오류와 추적 상태 분리(경로를 추측으로 채우지 않음) |
| — | 경로 판정: 유효 / 사라짐 / 미제공 구분 |
| — | 경로 정규화 5건 |
| — | 이벤트 파싱 3건 + 이름 표기 정규화 3건 |

**(2) 스텁 서버 + 실제 소켓으로 끝까지 돈 시나리오 (13초)**

| 시각 | 자극 | 관측 결과 |
| --- | --- | --- |
| t=0 | 초기 포커스 `wX:p1` (`/tmp`) | `focus tracked`, `path /tmp`, `validity valid` |
| t+3 | `pane_focused` 이벤트, 포커스 `wX:p2` (`/var/tmp`) | `pane wX:p2`, `previous /tmp (이전 위치. pane wX:p1)` — A·E |
| t+6 | 대상 pane에 `pane_updated`, 경로 `/var/tmp/sub` | 같은 pane, `path /var/tmp/sub`, `validity missing` — B |
| t+9 | 비활성 pane `wX:p9`에 `pane_updated` | **출력 변화 없음** — C |
| 13초 | 1초 간격 안전 폴링 12회 | 렌더 총 **3회**. 시각만 바뀐 재출력 0 |
| 종료 | 스텁 강제 종료 | `connection unavailable`, `focus unknown`, 이전 경로는 `missing`으로 남고 `observed`가 과거 시각 유지 — F |

**(3) 스텁 protocol 99** → `incompatible`, pane 데이터 미해석, 경로 미채움, exit 1.

**E2의 한계:** 스텁은 내가 정의한 신호를 준다. 실제 herdr가 같은 이벤트를 같은 시점에 준다는
보장이 아니다. 그래서 실제 herdr 상대 확인(E3)을 따로 했다.

#### E3 — 실제 pane 추적 성공 (요약, 상세는 V1.4)

| 검증 | 결과 |
| --- | --- |
| 프로브가 보고한 pane == herdr 자체 `focused` 플래그 | **일치** (여러 시점에서 확인) |
| 호출 pane과 분리 | **분리됨** (호출 `w3D:p6` ≠ 보고 `w38:p7`/`w38:p1`) |
| `HERDR_PANE_ID` 위조 내성 | 목표 불변 |
| 실제 이벤트 수신 | `pane_updated` 프레임을 실제로 수신 |
| 오류 상태 구분 | `unavailable` / `refused` / `incompatible` 서로 구분 |

### V1.4 실기기에서 확인한 동작

이 macOS에서 실행 중인 실제 herdr·Ghostty를 상대로 직접 관측한 것이다.

| # | 확인한 것 | 증거 |
| --- | --- | --- |
| 1 | 실제 포커스 pane을 읽는다 | 포커스가 `w38:p7` → `w38:p1` → `w3D:p6`로 바뀌는 동안 프로브가 매번 같은 pane을 보고 |
| 2 | herdr 자체 판정과 일치한다 | `herdr pane list`의 `focused` 플래그, `herdr api snapshot`의 `focused_pane_id`, 프로브 출력 3자가 동일 |
| 3 | 호출 pane을 목표로 삼지 않는다 | 호출 pane `w3D:p6`인 상태에서 보고 pane이 `w38:p7`/`w38:p1`이었다 |
| 4 | `HERDR_PANE_ID` 위조에도 목표가 흔들리지 않는다 | `wZZ:p99`를 주입해도 보고 pane 불변, `caller` 줄만 변함 |
| 5 | 실제 pane 경로를 읽는다 | `~/Workspace/tool/pi`, `~/Workspace/tool/PaneDock`, `~/Workspace/tool` (디렉터리 존재 확인까지 통과) |
| 6 | 실제 이벤트가 흐른다 | `{"event":"pane_updated","data":{"type":"pane_updated","pane":{...cwd, foreground_cwd, revision...}}}` 를 실제로 수신 |
| 7 | 바깥 터미널 경로가 pane 경로가 아니다 | Ghostty `working directory` = `/Users/kangjingoo` vs pane 경로 `~/Workspace/tool/pi` |
| 8 | 소켓 밖 프로세스도 읽을 수 있다 | `env -i` 프로세스에서 `pane.list`·`events.subscribe` 성공 |
| 9 | 연결 실패가 서로 구분된다 | ENOENT → `unavailable`, 리스너 없음 → `refused`, protocol 99 → `incompatible` (각각 exit 1) |
| 10 | 실제 환경 추적이 안정적이다 | 실제 소켓에 `--watch` 12초 실행 시 렌더 1회, 오류·중복 출력 없음 |

**구현 중 발견해 고친 결함 2건 (E2가 잡은 것)**

1. 전환 직후 경로 상태가 `unsupported`로 잘못 표시됐다 → `pendingWorkInfo`를 분리해
   "아직 못 받음(`pending`)"과 "제공하지 않음(`unsupported`)"을 구분.
2. **구독 요청은 점 표기(`pane.updated`)인데 실제 발행 프레임은 밑줄 표기(`pane_updated`)** 였다.
   이름 정규화가 없으면 이벤트가 하나도 매칭되지 않아 안전 폴링에만 의존하게 된다.
   실제 프레임을 관측해서 발견했고(E3 영역), 자체 검사에 회귀 항목을 추가했다(E2 영역).

### V1.5 아직 확인하지 못한 동작과 그 이유

| # | 미확인 항목 | 이유 | 등급 |
| --- | --- | --- | --- |
| 1 | pane A→B 포커스를 **사람이** 옮겼을 때의 표시 변화 | 사용자 조작이 필요하다. 에이전트가 임의로 사용자 포커스를 바꾸면 작업을 방해한다 | E4 |
| 2 | 같은 pane에서 `cd` 했을 때의 경로 갱신 지연 | 위와 같음. 로컬 스텁에서는 1ms 수준이었으나 실제 `cd` 지연은 미측정 | E4 |
| 3 | 비활성 pane에서 `cd` 했을 때 표시 불변 | 위와 같음(스텁으로는 확인함 = E2) | E4 |
| 4 | 빠른 연속 전환 시 최종 포커스 일치 | 위와 같음 | E4 |
| 5 | 다중 attached client에서 "포커스된 pane"의 의미 | herdr에 **클라이언트를 열거하는 API가 없다**. 공식 문서도 "each can view its own workspace and tab"이라고만 설명. 두 번째 클라이언트를 붙이는 것도 사용자 조작이다 | E5 |
| 6 | 클라이언트가 하나도 붙어 있지 않을 때의 포커스 의미 | herdr는 "nobody attached"를 정상 상태로 설계했다. 그때 무엇을 보여줄지는 미결정 | E5 |
| 7 | 최전면 앱 판정을 "터미널을 보고 있는가"로 쓸 수 있는지 | 조사 시점에 `loginwindow`가 최전면이었다. 화면 잠금 때문인지 다른 원인인지 구분하지 못했다 | E5 |
| 8 | PTY를 TUI/에이전트가 점유할 때 `cwd`와 `foreground_cwd`가 갈라지는 사례 | 관측 시점에는 두 값이 같았다 | E5 |
| 9 | 이벤트 이름 표기가 herdr 버전에 따라 바뀔지 | preview 채널이다. 정규화로 점/밑줄은 흡수하지만 제3의 표기는 놓친다 | E5 |
| 10 | 원격 pane(`herdr --remote`, named session) 경로 | 저장된 SSH machine이 없고 범위 밖으로 두었다 | E5 |
| 11 | cmux·Terminal.app·tmux 연동 | cmux 미실행. Terminal.app sdef에 cwd 속성이 없음을 확인만 했고 결합 방식은 미검증 | E5 |
| 12 | Xcode 없이 유지보수 가능한 테스트 규모 | CLT에 XCTest가 없어 `swift test` 자체가 불가 | E5 |

### V1.6 다음에 실행할 명령 / 수동 검증 절차

#### (1) 자동 검증 재현 (사용자 확인용)

```bash
cd /Users/kangjingoo/Workspace/tool/PaneDock/prototypes/focus-probe

swift build                    # E1: 빌드 성공
swift run focus-probe --self-test    # E2: 22건 (기대: "22/22 checks passed", exit 0)
swift run focus-probe --once         # E3: 현재 포커스 pane 1회 조회
swift run focus-probe --once --json  # E3: 기계 판독용
```

교차 확인 — 프로브가 보고한 pane과 herdr 자체 판정이 같아야 한다:

```bash
swift run focus-probe --once | sed -n '1p'
herdr pane list | jq -r '[.result.panes[]|select(.focused)|.pane_id]|join(",")'
```

오류 상태 (기대: 각각 다른 connection 값 + exit 1):

```bash
swift run focus-probe --once --socket /tmp/nope.sock      # unavailable
```

#### (2) 수동 검증 — 추적 (U1~U4)

별도 터미널에서 추적을 켜 둔다:

```bash
cd /Users/kangjingoo/Workspace/tool/PaneDock/prototypes/focus-probe
swift run focus-probe --watch
```

| ID | 사용자가 할 조작 | 기대 결과 |
| --- | --- | --- |
| U1 | herdr에서 pane A → pane B로 포커스 이동 | 새 블록이 출력되고 `pane`이 B로 바뀐다. `previous`에 A의 경로가 "이전 위치"로 남는다 |
| U2 | 그 pane에서 `cd /tmp` 실행 | `pane`은 그대로, `path`와 `observed`만 바뀐다 |
| U3 | **비활성** pane에서 `cd` 실행 | **새 블록이 출력되지 않는다** |
| U4 | pane을 5회 이상 빠르게 연속 전환 | 마지막 블록의 `pane` = 마지막 포커스. 중간 pane 값이 남지 않는다. `focusGeneration`이 증가한다 |

#### (3) 수동 검증 — 오류·연결 (U5)

```bash
# herdr 클라이언트를 분리한다 (pane과 에이전트는 계속 살아 있다)
#   herdr TUI에서 ctrl+b q
```
기대: `connection unavailable`, `focus unknown`, 이전 경로는 남되 `validity missing`으로 표시되고
`observed`가 과거 시각으로 유지된다. 유효한 것처럼 보이면 실패다.

주의: `herdr server stop`은 실행 중인 pane 프로세스까지 멈춘다. 검증 목적이 아니면 쓰지 않는다.

#### (4) 수동 검증 — 환경 신호 (U6~U7)

| ID | 절차 | 기대 |
| --- | --- | --- |
| U6 | 화면 잠금을 해제한 상태에서 `lsappinfo front` | 바깥 터미널(Ghostty)이 최전면으로 나오는지. 조사 시점에는 `loginwindow`였다 |
| U7 | 두 번째 herdr 클라이언트를 붙이고 그쪽에서 다른 tab을 연 뒤 `focus-probe --once` | 서버 전역 포커스가 튀는지 관찰. 튄다면 다중 클라이언트 전제(1개)를 재검토해야 한다 |

#### (5) 기록 방법

수동 검증을 마치면 이 문서 끝에 `## V2` 절을 추가하고, 각 항목에 **관측한 출력 원문**과
E등급을 적는다. 수행하지 않은 항목은 통과로 적지 않는다.

---

## V2. 2026-09-16 — 사용자 조작 검증(U1~U4) 보고 + U6 해소 + U5 절차 정정

### V2.1 수동 검증 U1~U4 — 사용자 직접 수행, 통과 보고

| ID | 절차 | 결과 | 등급 |
| --- | --- | --- | --- |
| U1 | pane A → pane B 포커스 이동 | **통과 보고** | E4 |
| U2 | 같은 pane에서 `cd` | **통과 보고** | E4 |
| U3 | 비활성 pane에서 `cd` → 표시 불변 | **통과 보고** | E4 |
| U4 | 빠른 연속 전환 → 최종 포커스 일치 | **통과 보고** | E4 |

**기록 범위를 분명히 한다.** 위 4건은 **사용자가 수행하고 통과를 보고**한 것이며,
에이전트는 그때의 출력 원문을 직접 보지 못했다. 따라서 이 항목들은
"에이전트가 관측한 증거(E3)"가 아니라 "사용자 보고"로 분류한다.
출력 원문을 남기려면 `--watch` 로그를 이 절에 붙이면 된다.

이로써 기획서 검증 시나리오 **A(pane A→B), B(같은 pane `cd`), C(비활성 pane `cd`), D(빠른 전환)** 가
실제 pane 조작으로 확인됐다. E(경로 미확인 시 이전 경로 미승격)는 V1의 E2 항목이 덮는다.

### V2.2 U6 해소 — 최전면 앱 신호 측정

조사 시점에는 최전면 앱이 `loginwindow`로 나왔으나, 화면 잠금을 해제한 상태에서 다시 측정했다.

| 명령 | 결과 |
| --- | --- |
| `lsappinfo front` | `"Ghostty" ... (in front)` |
| `osascript -e 'tell application "Ghostty" to get frontmost'` | `true` |
| `herdr pane list` (동시) | `focused` = `w3D:p6` (변화 없음) |

**해소:** 최전면 앱을 권한 없이 읽을 수 있고(`lsappinfo`, `NSWorkspace`), 값이 실제 상태와 맞는다.
조사 시점의 `loginwindow`는 화면 잠금 때문이었다.

의미: herdr의 포커스는 사용자가 브라우저로 옮겨가도 **바뀌지 않는다.** 그래서 지금 프로토타입은
"추적 중"과 "유지 중"(기획서 §5)을 구분하지 못한다. 최전면 앱 신호가 그 구분의 입력이 된다.
이번 프로토타입은 이 신호를 **구현하지 않았다**(0.1 F07 범위). 가용성만 확인했다.

### V2.3 U5 절차 정정 — 클라이언트 분리는 연결 오류가 아니다

V1.6에 적은 U5 절차("`ctrl+b q` → `connection unavailable`")는 **기대가 틀렸다.**

- herdr 공식 문서(concepts): "Detach the client with `ctrl+b q`. **The server and agents continue running.**"
- 따라서 클라이언트를 분리해도 서버와 소켓은 살아 있고, 프로브는 계속 `connected`로
  마지막 포커스 pane을 보고한다.

**정정된 이해:**

| 상황 | 소켓 | 프로브 표시 | 의미 |
| --- | --- | --- | --- |
| 클라이언트 분리(`ctrl+b q`) | 살아 있음 | `connected`, 마지막 포커스 유지 | 오류가 아니라 기획서 §5의 **"유지 중"** 상황 |
| 서버 종료 | 닫힘 | `unavailable`, `focus unknown` | 진짜 연결 오류 |

연결 오류 경로 자체는 이미 자동 검증으로 덮여 있다(V1의 E2/E3: 없는 소켓 `unavailable`,
리스너 없음 `refused`, protocol 불일치 `incompatible`, 스텁 강제 종료 시 이전 경로가
`missing`으로만 남음).

**남은 수동 확인은 선택 사항이다.** 실제 서버를 세워 두고 종료하는 유일한 방법은
`herdr server stop`인데 **실행 중인 pane 프로세스까지 멈추므로**, 에이전트 pane이 하나도
없는 시점에 사용자가 직접 판단해서 실행해야 한다. 권장하지 않는다.

### V2.4 아직 남은 수동 검증

| ID | 항목 | 왜 필요한가 | 등급 |
| --- | --- | --- | --- |
| U5 | (선택) 실제 서버 종료 시 표시 | 자동 검증으로 이미 덮여 있음. 실제 서버 종료는 pane을 죽인다 | E5(선택) |
| U7 | 두 번째 클라이언트를 붙였을 때 포커스 귀속 | herdr에 클라이언트 열거 API가 없다. 잘못된 대상으로 전환되는 버그는 출시 차단 항목 | E4/E5 |

U7 절차: 다른 터미널 창에서 herdr를 실행해 두 번째 클라이언트로 붙인 뒤, 그쪽에서 다른
tab/workspace를 선택하고 `focus-probe --once`를 실행한다. 첫 번째 클라이언트(원래 작업하던 곳)의
포커스가 아니라 **두 번째 클라이언트가 본 pane으로 값이 바뀐다면**, 서버 전역
`focused_pane_id`는 "내가 보고 있는 pane"이 아니라는 뜻이므로 "attached client 1개" 전제를
재검토해야 한다.

---

## V3. 2026-09-16 — U7 실행 결과: 다중 클라이언트 전제가 깨졌다

### V3.1 사용자가 실행한 것과 관측된 값

사용자가 두 번째 herdr 클라이언트를 붙인 뒤 같은 터미널에서 연속 3회 실행한 결과:

| 회차 | 보고된 pane | workspace |
| --- | --- | --- |
| 1 | `w3D:p7` | w3D (PaneDock) |
| 2 | `w3D:p7` | w3D (PaneDock) |
| 3 | `w2P:p1` | w2P (idle-game) |

에이전트가 추가로 읽기 전용 샘플링한 값:

| 시각 | 보고된 pane | 비고 |
| --- | --- | --- |
| 17:08:33 | `w3D:p6` | (에이전트 확인) |
| 17:09:07 | `w2P:p4` | 1초 간격 샘플 |
| 17:09:08 ~ 17:09:17 | `w2P:p1` | 10초간 고정 |

**읽기는 포커스를 바꾸지 않는다**(herdr 문서: "explicit focus commands mark the target seen, while reads do not").
그런데도 연속 조회 사이에 값이 바뀌었다 → **다른 클라이언트가 포커스를 바꾸고 있다.**

### V3.2 클라이언트가 2개 붙어 있다 (프로세스 증거)

| 클라이언트 | 계보 | 해석 |
| --- | --- | --- |
| `herdr` pid 8977 | ← zsh 8417 | 로컬 (이 herdr 서버를 띄운 클라이언트) |
| `herdr` pid 23630 | ← zsh 20312 ← zsh 20288 ← **`sshd-session` 14422** | **SSH 원격 클라이언트** |

원격 접속은 V1 조사에서 `who`로 확인한 `ttys021 100.75.126.105`(Tailscale)와 일치한다.

### V3.3 API로는 어느 클라이언트인지 알 수 없다 (스키마 확인)

| 확인 | 결과 |
| --- | --- |
| `pane.list` 파라미터 | `{"workspace_id": string\|null}` — **클라이언트를 지정할 수 없다** |
| `pane.current` 파라미터 | `{"caller_pane_id": string\|null}` — 호출 pane 또는 전역 포커스뿐 |
| `client.*` 메서드 | `client.window_title.set/clear`, `client.shell_surface.set` — **쓰기 전용. 클라이언트 포커스 조회 없음** |
| 구독 이벤트 | `pane.focused`/`tab.focused`/`workspace.focused` — 클라이언트별 변형 없음 |
| 클라이언트 열거 | 스키마에 없음 (§6.2-1에서 이미 지적) |

### V3.4 결론

1. `focused_pane_id`는 **서버 전역 단일 값**이며, **마지막으로 포커스를 바꾼 클라이언트**의 것을 반영한다.
2. 어떤 클라이언트의 것인지 **API로 구분할 수 없다.**
3. 따라서 원격 클라이언트가 붙어 있는 동안 이 Mac의 Dock은 **사용자가 보고 있지 않은 위치로
   바뀔 수 있다.** (관측: 로컬 PaneDock pane `w3D:p6` 대신 idle-game `w2P:p1`을 보고했다.)
4. 기획서 §10의 "**잘못된 대상으로 실행되는 오류는 출시 차단 항목**"에 해당한다.

**"attached client 1개" 전제는 유지할 수 없다.** 코드·문서의 해당 가정을 다시 설계해야 한다.

### V3.5 선택지 (미결정 — 사용자가 판단)

| 안 | 내용 | 남은 미검증 |
| --- | --- | --- |
| A | 단일 클라이언트를 지원 조건으로 명시하고, 다중일 때 "확인 중/미지원"으로 표시 | **다중 클라이언트를 감지할 방법이 아직 없다.** 별도 조사 필요 |
| B | 바깥 창 신호(최전면 앱/창)와 교차 검증 | herdr 클라이언트 ↔ Ghostty surface 매핑을 **읽는** API가 없다 |
| C | herdr 쪽에 클라이언트별 포커스 조회 또는 클라이언트 식별 노출 요청 | upstream 응답 여부 |
| D | 이 Mac에서 시작된 pane/워크스페이스로 대상을 제한 | 서버가 로컬 클라이언트 컨텍스트를 노출하는지 미검증 |

U1~U4가 통과했더라도 그것이 "정확한 클라이언트를 따라간다"는 증거는 아니다.
그 시점에도 클라이언트가 2개였을 수 있다.

### V3.6 사용자 확인 — 확정 (로컬 화면 불변, 원격 클라이언트를 따라감)

사용자가 **로컬 Ghostty의 새 탭**에서 측정하고, 동시에 **회사 PC(원격 SSH 클라이언트)** 에서
workspace를 옮겨다니며 실행한 결과:

| 회차 | 보고된 pane | workspace | 로컬 화면 |
| --- | --- | --- | --- |
| 1 | `w3D:p6` | w3D (PaneDock) | PaneDock |
| 2 | `w2N:p1` | w2N (Demon-Inc) | **변화 없음** |
| 3 | `w2W:p1` | w2W (egde-nochi) | **변화 없음** |

**로컬 화면이 그대로인데 값만 원격 클라이언트를 따라갔다.** V3.4의 추정이 아니라 확정이다.

클라이언트 소속을 TTY로 분리해 확인했다:

| 클라이언트 | TTY | 해석 |
| --- | --- | --- |
| `herdr` pid 8977 (← zsh 8417) | **`ttys000`** | 로컬 콘솔 (Sep 15 15:09 로그인) |
| `herdr` pid 23630 (← zsh 20312 ← `sshd-session`) | **`ttys021`** | 원격 `100.75.126.105` (회사 PC) |

### V3.7 다중 클라이언트 감지 가능성 — **가능하다 (검증됨)**

서버는 클라이언트 전용 소켓 `~/.config/herdr/herdr-client.sock`을 열고, 붙은 클라이언트마다
연결을 하나씩 유지한다(API 소켓 `herdr.sock`과 다르다).

```bash
netstat -an -f unix | awk '/herdr-client\.sock/ && $6 != 0 {c++} END {print c+0}'
# -> 2   (listener 제외, established 연결 수)
```

프로세스·TTY 증거(클라이언트 2개)와 정확히 일치했다.

| 방법 | 결과 | 비고 |
| --- | --- | --- |
| `netstat -an -f unix` 에서 `herdr-client.sock` established 개수 | **2** | API가 아닌 OS 관측. herdr 내부 소켓 이름에 의존 |
| `lsof -U` 로 서버(8978)가 물고 있는 `herdr-client.sock` FD | 클라이언트 2 + listener 1 | 같은 결론. 권한 불필요 |

**단, 이것은 API가 아니라 구현 세부에 의존하는 우회 수단이다.** herdr가 소켓 구조를 바꾸면 깨진다.

### V3.8 그래서 안 A는 실효성이 낮다

감지는 되지만, 감지해서 무엇을 할지가 문제다. 다중 클라이언트일 때 "미지원"으로 내리면,
원격 클라이언트를 상시 붙여 두는 이 사용 환경에서는 **PaneDock이 거의 항상 미지원 상태가 된다.**

근본 질문은 이것이다:

> 이 Dock은 **누구를** 따라야 하는가?

macOS 화면에 Dock을 띄우는 제품이라면 **그 Mac 앞에 앉은 사람**을 따라야 한다.
그러려면 "로컬에서 시작된 클라이언트의 시점"을 읽어야 하는데, 그 API가 없다(V3.3에서 확인).

---

## V4. 2026-09-16 — 범위 변경(Herdr 제외) + Ghostty 첫 지원 조합 검증

### V4.1 범위 결정

사용자 결정으로 **Herdr 내부 pane 자동 추적을 지원 범위에서 제외**했다.
결정 전문과 근거는 `docs/scope-decisions.md` D1에 있다. 요약:

- 원격 SSH 클라이언트가 전역 `focused_pane_id`를 끌고 가는 문제(V3)를 **Herdr 수정 없이는**
  해결할 수 없다.
- 지원 원칙: 대상 앱의 소스 수정·패치 바이너리·별도 포크를 요구하지 않는다.
  공식 API·CLI·문서화된 연동만 쓴다. 셸 설정 변경·별도 설치는 사전 승인을 받는다.
- C1(클라이언트 측 상태 발행)은 **미구현 · 진행 취소**. 기획서 원본은 수정하지 않았다.

### V4.2 기존 코드의 공통/전용 분리

| 구분 | 파일 | 처리 |
| --- | --- | --- |
| 공통 | `CurrentWorkInfo.swift`(상태·식별·경로), `FocusResolver.swift`(늦은 응답 폐기), `ContextStore.swift`(표시 묶음·캐시·상태 전이), `DiagnosticsReport.swift`, `SelfTest.swift` | **보존.** Adapter 의존만 `WorkInfoFactory`로 분리 |
| 공통(신규) | `WorkInfoFactory.swift` | `PaneRecord`(소스 중립 레코드)와 변환 규칙. HerdrAdapter에 있던 `pendingWorkInfo`/`currentWorkInfo`를 **동작 그대로** 옮김 |
| 전용(신규 정상 경로) | `GhosttyAdapter.swift` | 공식 AppleScript 조회 + 파싱 + 오류 분류 + 스냅샷 반영 |
| 전용(실험 보존) | `HerdrWire.swift`, `HerdrSocketClient.swift`, `HerdrAdapter.swift`, `HerdrProbes.swift` | **보존.** `--adapter herdr`로만 도달. 정상 실행 경로 아님 |
| CLI | `main.swift`(분기), `GhosttyProbes.swift`, `ProbeSupport.swift` | 기본 adapter = ghostty |

Herdr 코드는 삭제하지 않았다. 자체 검사의 Herdr 항목 22건도 그대로 통과한다.

### V4.3 실행한 명령과 결과

| 명령 | 결과 |
| --- | --- |
| `rm -rf .build && swift build` | **E1: `Build complete! (16.61s)`, 오류·경고 0** |
| `focus-probe --self-test` | **E2: 35/35 checks passed**, exit 0 |
| `focus-probe --once` (기본=ghostty) | **E3: 아래 V4.5** |
| `osascript <원문 스크립트>` | E3 교차 확인용 원문 조회 |
| `lsof -a -p <셸pid> -d cwd` | E3 교차 확인용 실제 셸 cwd |
| `focus-probe --adapter herdr --once` | **E3: 실험 경로 보존 확인**(읽기 전용 1회). `pane w38:pB`, 정상 동작, stderr에 실험 경고 |
| `focus-probe --adapter herdr --once --socket /tmp/nope.sock` | E3: `pane -`, 실험 경로 오류 처리 유지 |

### V4.4 자동 테스트 결과 (E2, 35건)

기존 22건(Herdr 시절 규칙)은 **그대로 통과**한다. 추가 13건은 Ghostty 정상 경로를 덮는다.

| 검증 기준 | 항목 | 결과 |
| --- | --- | --- |
| **A** | pane 전환 시 새 식별자와 새 경로, 이전 경로는 `previous`로만 | PASS |
| **B** | 같은 pane에서 경로만 갱신(pane ID·generation 유지) | PASS |
| **C** | 비활성 pane 갱신은 대상을 바꾸지 않음(배경 목록만 갱신) | PASS |
| **D** | 늦은 응답 폐기(Ghostty 레코드에서도) | PASS |
| **E** | 경로 미제공/사라짐을 정상 추적과 구분 | PASS |
| — | 최전면 아님 + 유효 경로 → `held` | PASS |
| — | 오류 분류 4종(-600/-1743/-1708/-1728) → `unavailable`/`denied`/`incompatible`/`connected` | PASS |
| — | 파싱: focused terminal이 대상이 된다 | PASS |
| — | 파싱: `notRunning` 응답 거부 | PASS |
| — | 버전 게이트 1.3.0+ | PASS |

**E2의 한계:** 합성 AppleScript 출력이다. 실제 Ghostty가 같은 출력을 준다는 보장은 E3에서 따로 확인했다.

### V4.5 실기기에서 확인한 동작 (E3)

`focus-probe --once` 실제 출력(정상 경로):

```
pane        5D31DDD8-E629-4FE4-89CE-7FD3730CE132   workspace tab-group-7593416440   tab tab-7594a0f000   terminal 5D31DDD8-...
title       …/PaneDock/prototypes/focus-probe
focus       held                     (focusGeneration 1)
path        /Users/kangjingoo/Workspace/tool/PaneDock/prototypes/focus-probe
cwdSource   ghostty:terminal.workingDirectory
validity    valid              (디렉터리 확인됨)
connection  connected          AppleScript (ghostty 1.3.1)
host        ghostty / ghostty 1.3.1
frontmost   false              (최전면 아님 — 마지막 위치 유지로 표시)
background  54DBC13A-...   /Users/kangjingoo   (valid)   Kangui-MacBookPro.local: Demon
background  ABEDF5F1-...   /Users/kangjingoo/Workspace/tool/PaneDock/prototypes/focus-probe   (valid)   swift run focus-probe --watch
nesting     unknown            (중첩 TUI 내부 경로는 공식 조회로 알 수 없음)
```

| # | 확인한 것 | 증거 |
| --- | --- | --- |
| 1 | 대상 terminal을 공식 API로 얻는다 | 프로브의 pane ID == 원문 스크립트의 `focusedTerminal` |
| 2 | 그 terminal의 보고 경로를 얻는다 | 프로브의 path == 원문 `focusedWD` |
| 3 | **보고 경로가 실제 셸 cwd와 일치한다** | 프로브 path == `lsof`로 본 셸(pid 1371, ttys013) cwd. ttys024도 동일 |
| 4 | 창/탭/terminal 구조를 정확히 읽는다 | Ghostty 창 1개 / 탭 2개 / terminal 3개(`tab-7594a0f000`은 분할 2개) |
| 5 | 최전면 여부를 읽고 상태에 반영한다 | `frontmost=false` → `focus held` |
| 6 | 비활성 pane을 별도로 보여준다 | herdr 탭(`54DBC13A`, `/Users/kangjingoo`)이 background로 표시 |
| 7 | Ghostty 버전 게이트 | `version=1.3.1` → 지원 |
| 8 | Herdr 실험 경로 보존 | `--adapter herdr --once` 정상 동작, 실험 경고 출력 |
| 9 | 자동화 권한 | 승인 대화상자 없이 조회 성공(이미 승인됨) |

부수 확인(V4에서 새로 얻은 사실):

- `working directory`는 surface의 **live pwd**다(`ScriptTerminal.workingDirectory` → `surfaceView.pwd`).
- Ghostty 설정은 `shell-integration = detect`, features에 `path` 포함(기본값) → 경로 갱신이 켜져 있다.
- AppleScript 작성 시 **`st`는 예약어**이고 **`tab`은 Ghostty 사전의 클래스명과 충돌**해
  구분자로 쓸 수 없다(`ASCII character 9` 사용). 두 번의 문법 오류로 확인했다.

### V4.6 아직 확인하지 못한 동작

| # | 항목 | 이유 | 등급 |
| --- | --- | --- | --- |
| 1 | **A** 실제 pane/탭 전환 시 표시 변화 | 사용자 GUI 조작이 필요하다. 에이전트가 창을 만들거나 전환하지 않았다 | E4 |
| 2 | **B** 실제 `cd` 후 경로 갱신 | 위와 같음. 합성으로는 검증했고, 보고 경로 == 실제 셸 cwd는 확인했다 | E4 |
| 3 | **C** 실제 비활성 pane의 경로 변경 | 위와 같음 | E4 |
| 4 | Ghostty 미실행 시 동작 | 확인하려면 사용자의 Ghostty를 종료해야 한다. 하지 않았다 | E5 |
| 5 | 자동화 권한 거부 시 동작 | TCC를 되돌리는 것은 시스템 설정 변경이다. 하지 않았다 | E5 |
| 6 | 다중 창에서 "최전면 창" 선택이 사용자 기대와 맞는지 | 창이 1개뿐이었다 | E5 |
| 7 | 중첩 TUI가 대상일 때의 표시 | 자동 감지를 하지 않기로 했다(공식 조회로 판별 불가). 미검증으로 남긴다 | E5 |
| 8 | Ghostty 1.3.0 미만에서의 거부 동작 | 설치본이 1.3.1뿐이다 | E5 |

### V4.7 사용자가 할 절차 (A·B·C 확인)

```bash
cd /Users/kangjingoo/Workspace/tool/PaneDock/prototypes/focus-probe
swift run focus-probe --watch
```

| 순서 | 사용자가 할 조작 | 기대 |
| --- | --- | --- |
| A | Ghostty에서 다른 탭 또는 분할 pane으로 포커스 이동 | 새 블록의 `pane`이 그 terminal ID로 바뀌고 `path`가 그 셸의 경로가 된다. 이전 경로는 `previous`에 남는다 |
| B | 대상 셸에서 `cd /tmp` | `pane`은 그대로, `path`와 `observed`만 바뀐다 |
| C | **대상이 아닌** pane에서 `cd` | `background` 줄만 바뀌고 `pane`/`path`(대상)는 그대로다 |
| D | 위 조작을 빠르게 반복 | 마지막 블록이 마지막 포커스와 일치한다 |
| E | (선택) 대상 셸에서 존재하지 않는 디렉터리로 이동 | `validity missing`, `focus unknown`으로 표시되고 정상 추적과 구분된다 |

**기록 원칙:** 에이전트가 관측하지 않은 항목은 통과로 적지 않는다. 위 A~E는 사용자가 수행한 뒤
출력 원문과 함께 이 문서에 `V5`로 추가한다.

---

## V5. 2026-09-16 — 사용자 조작 검증 보고 (Ghostty 경로)

### V5.1 사용자 보고

사용자가 `focus-probe --watch`로 **직접 조작 검증을 수행했고 정상 동작을 보고**했다
("잘 되는거 같군", "해봤어").

- **증거 등급: E4 (사용자 관찰).** 에이전트가 직접 본 증거(E3)와 섞지 않는다.
- **기록 수준:** 항목별 출력 원문은 남기지 않았다. A/B/C를 각각 분리해 확인했는지,
  어떤 값을 보았는지는 이 기록에 담기지 않았다. 따라서 **항목별 통과를 개별 증거로 주장하지 않는다.**

| 항목 | 내용 | 상태 |
| --- | --- | --- |
| **A** | 다른 탭/분할 pane으로 전환 시 대상이 바뀌는지 | 사용자 보고 범위에 포함(항목별 원문 미기록) |
| **B** | 대상 셸에서 `cd` 시 `path`만 갱신되는지 | 사용자 보고 범위에 포함(항목별 원문 미기록) |
| **C** | 비활성 pane의 `cd`가 대상을 바꾸지 않는지 | 사용자 보고 범위에 포함(항목별 원문 미기록) |
| **D** | 늦은 응답이 현재 상태를 덮어쓰지 않는지 | **E2에서 합성 검증 완료**(자체 검사 D). 실사용 조작은 이 보고 범위에 포함되지 않음 |
| **E** | 경로 없음/조회 실패를 정상 추적과 구분하는지 | **E2에서 합성 검증 완료**(자체 검사 E, 오류 분류 4종) |

이로써 기획서 검증 시나리오 A·B·C가 **사용자 관찰 수준에서** 확인되었다.
에이전트 관측 수준의 증거는 V4.5(대상 ID·경로가 공식 AppleScript 원문 및 실제 셸 cwd와 일치)까지다.

### V5.2 이 절이 주장하지 않는 것

- 항목별(A/B/C) 통과를 개별 증거로 주장하지 않는다.
- **중첩 TUI 환경에서의 정확도는 여전히 미검증**이다. 자동 감지하지 않으며, 직접 셸 환경 전용이다
  (`docs/scope-decisions.md` D1, V4.6-7).
- 다중 창에서 "최전면 창" 기준이 사용자 기대와 맞는지는 미검증이다(V4.6-6).

### V5.3 기록을 강화하려면

`--watch` 출력 원문을 이 절에 붙이면 A/B/C를 항목별로 분리해 근거와 함께 남긴다.

---

## V6. 2026-09-16 — 0.1a: Ghostty 전용 최소 Dock UI

### V6.1 범위

- **포함:** Ghostty 한 창의 직접 pane과 로컬 셸. 현재 경로 표시, 상태 구분, 폴더 열기, 경로 복사, 잠금/해제, 창 숨김·재표시·종료.
- **제외(주장하지 않음):** 다중 창, 중첩 멀티플렉서(herdr·tmux) 내부 경로, SSH 내부 경로, 전역 단축키, 테마, 위젯, 프로젝트 편집기, 아이콘 확대, 모든 Spaces·전체화면 대응.
- **Herdr:** 범위 밖 유지(`docs/scope-decisions.md` D1). Herdr 수정·재조사·우회 구현으로 돌아가지 않았다.
- 기존 CLI 진단 도구는 **유지**한다. 추적 로직은 복제하지 않고 `FocusProbeCore`를 양쪽이 공유한다.

### V6.2 변경·생성 파일

| 파일 | 목적 |
| --- | --- |
| `prototypes/focus-probe/Sources/FocusProbeCore/DockState.swift` (신규) | 화면 상태 파생(`추적/유지/잠금/확인/오류`), `DockLock`, 클릭 시점 실행 계획(`DockActionPlanner`). UI 문자열이 아니라 값만 다룬다 |
| `prototypes/focus-probe/Sources/FocusProbeCore/GhosttyProbe.swift` (신규, CLI에서 이동) | 조회→상태 반영→진단 묶음. CLI와 GUI가 **같은 코드**를 쓴다 |
| `prototypes/focus-probe/Sources/FocusProbeCore/WorkInfoFactory.swift` | `unresolvedWorkInfo` 추가(자리 표시자를 코어로 이동) |
| `prototypes/focus-probe/Sources/FocusProbeCore/SelfTest.swift` | 신규 검사 14건 추가(총 49건) |
| `prototypes/focus-probe/Package.swift` | `FocusProbeCore`를 라이브러리 product로 노출 |
| `prototypes/focus-probe/Sources/FocusProbeCLI/GhosttyProbes.swift` | 코어로 옮긴 뒤 CLI 폴링 루프만 남김 |
| `prototypes/focus-probe/Sources/FocusProbeCLI/ProbeSupport.swift` | 자리 표시자를 코어 팩토리에 위임 |
| `app/PaneDock/Package.swift` (신규) | 앱 패키지. 검증 패키지에 **경로 의존**해 코어를 재사용 |
| `app/PaneDock/Sources/PaneDockApp/main.swift` (신규) | 진입점, `--self-check` |
| `app/PaneDock/Sources/PaneDockApp/LaunchOptions.swift` (신규) | 옵션 파싱, 가짜/실제 adapter 분기 |
| `app/PaneDock/Sources/PaneDockApp/AppDelegate.swift` (신규) | **NSPanel(nonactivating)** + **NSHostingView** + 메뉴 막대 항목. `NSApp.activate`를 호출하지 않는다 |
| `app/PaneDock/Sources/PaneDockApp/DockModel.swift` (신규) | 상태 소유. 조회는 직렬 백그라운드 큐, 결과만 메인으로 |
| `app/PaneDock/Sources/PaneDockApp/DockView.swift` (신규) | SwiftUI 단일 화면 |
| `app/PaneDock/Sources/PaneDockApp/FakeProbe.swift` (신규) | 가짜 입력 모드(스텁 러너) |
| `app/PaneDock/Sources/PaneDockApp/StateLog.swift` (신규) | `--state-log` 진단용 상태 기록(화면을 읽지 않고 동작 확인) |
| `app/PaneDock/make-app.sh` (신규) | Xcode 없이 `.app` 번들 생성 + ad-hoc 서명 |
| `app/PaneDock/.gitignore` (신규) | `.build/`, `dist/` 무시 |

기존 파일 중 **삭제한 것은 없다.** Herdr 실험 코드도 그대로다.

### V6.3 빌드·실행 명령과 결과

| 명령 | 결과 |
| --- | --- |
| `cd prototypes/focus-probe && swift build` | `Build complete!`, 경고 0 |
| `focus-probe --self-test` | **49/49 checks passed** |
| `cd app/PaneDock && swift build` | `Build complete!`, 경고 0 |
| `PaneDock --self-check --fake steady` | `display tracked`, `/tmp`, open/copy 계획 생성, exit 0 |
| `PaneDock --self-check --fake missing` | `display error`, `detail 연동이 작업 경로를 제공하지 않았습니다`, 두 계획 모두 **reject**, exit 1 |
| `PaneDock --self-check` (실제 Ghostty) | `display tracked`, `/tmp`, pane `AB6006DD-…` (CLI와 동일), exit 0 |
| `bash make-app.sh` | release 빌드 + `dist/PaneDock.app` 생성 + ad-hoc 서명 성공 |
| `open dist/PaneDock.app --args --fake steady` | 프로세스 실행, **화면에 창 존재**, Ghostty 최전면 유지 |
| `PaneDock --fake toggle --interval 700 --state-log …` | 9초 동안 13회 갱신, 대상 전환 반영(아래) |

앱 상태 로그(가짜 toggle — 3회마다 대상 전환):

```
19:18:24 refresh=1  display=tracked folder=tmp        path=/tmp                pane=term-A
19:18:26 refresh=3  display=tracked folder=tmp        path=/tmp                pane=term-A
19:18:26 refresh=4  display=tracked folder=kangjingoo path=/Users/kangjingoo   pane=term-B
19:18:28 refresh=7  display=tracked folder=tmp        path=/tmp                pane=term-A
19:18:31 refresh=10 display=tracked folder=kangjingoo path=/Users/kangjingoo   pane=term-B
```

→ 앱이 **실제로 주기 조회하고 상태를 갱신**한다. 창 내용을 읽지 않고 확인한 것이다.

### V6.4 검사 결과

**기존 35건 회귀: 전부 통과.** 추가 14건:

| 항목 | 내용 |
| --- | --- |
| 화면 상태 파생 5종 | 추적 중 / 유지 중 / 확인 중 / 오류(경로 없음) / 오류(연결 끊김) |
| 연결 끊김 시 | 마지막 경로를 유효한 대상으로 표시하지 않음 |
| 유지 중 | 이전 위치를 별도로 표시 |
| **F** | 잠금 중에는 새 후보로 바뀌지 않음 |
| **G** | 잠금 해제 시 현재 대상이 반영됨 |
| 잠긴 대상 무효화 | 경로가 사라지면 잠금이라도 오류로 표시 |
| 실행 계획 | 유효 경로는 URL/문자열로만 만든다(셸 문자열 조합 없음) |
| **H** | 없는 경로·대상 없음은 실행을 거부 |
| 클릭 시점 고정 | 클릭 순간 값으로 만든 계획은 이후 갱신에 흔들리지 않음 |
| 폴더 이름 추출 | 경로 끝 구성요소, nil 처리 |

### V6.5 실제로 확인한 것 (에이전트 관측)

| # | 확인한 것 | 방법 | 등급 |
| --- | --- | --- | --- |
| 1 | 코어·CLI·앱 빌드 | `swift build` (경고 0) | E1 |
| 2 | 앱 UI 없이 상태·실행 계획이 옳다 | `--self-check` (가짜 2종 + 실제) | E2/E3 |
| 3 | 앱이 주기 조회하고 상태를 갱신한다 | `--state-log` 13줄, 대상 전환 반영 | E2 |
| 4 | **GUI 프로세스가 뜨고 화면에 창이 존재한다** | `CGWindowListCopyWindowInfo` → `owner=PaneDock layer=3 alpha=1.0 bounds=360×215` | E3 |
| 5 | **PaneDock이 활성화를 빼앗지 않는다** | 실행 전후 `lsappinfo front`가 계속 `Ghostty` | E3 |
| 6 | 창이 기존 Dock과 겹치지 않는 위치 | `visibleFrame` 안쪽 좌하단(x:24, y:608) | E3 |

**확인하지 않은 것:** 창의 **화면 내용(레이아웃·문구·버튼 배치)은 보지 않았다.** 픽셀을 읽지 않는다.
따라서 "GUI 실행 성공"은 **프로세스 실행 + 창 생성**까지를 뜻하며, 시각적 확인은 하지 않았다.

### V6.6 사용자 조작이 필요해 미실시

| # | 항목 | 이유 |
| --- | --- | --- |
| 1 | **실제 모드 GUI 실행** | 번들 앱이 Ghostty를 자동화하려면 TCC 승인이 필요할 수 있다. **권한 승인은 별도 확인 사항**이라 실행하지 않았다 |
| 2 | 버튼 클릭(폴더 열기/경로 복사) | 클릭이 필요하다 |
| 3 | 잠금/해제 클릭 | 클릭이 필요하다 |
| 4 | 창 숨김·재표시 | 클릭이 필요하다 |
| 5 | A·B·C·D·E 시나리오 | pane 전환·`cd`·앱 전환 등 GUI 조작이 필요하다 |
| 6 | 다중 창 기준 | Ghostty 창이 1개뿐이다 |

### V6.7 권한과 실행 방법

**CLI에서 승인된 권한을 GUI에 그대로 가정하지 않는다.** 실행 주체가 다르다.

- CLI(`focus-probe`)는 셸에서 실행되고 `/usr/bin/osascript`를 띄운다. 승인 주체는 그 셸/터미널 계보다.
- GUI(`PaneDock.app`)는 **번들 앱 자신**이 자동화 요청의 주체가 된다. 그래서 별도 승인이 필요할 수 있다.
- 대비책으로 번들 `Info.plist`에 `NSAppleEventsUsageDescription`(사용 목적 설명)을 넣고,
  ad-hoc 서명으로 번들 단위 권한 기억이 가능하게 했다.
- **접근성 권한·화면 기록·전체 디스크 접근은 요구하지 않는다.** TCC 초기화도 하지 않는다.
- 승인 대화상자가 뜨면 **허용**하면 되고, 거부하면 앱은 `denied` 상태로 오류를 표시한다(임의로 우회하지 않는다).

실행:

```bash
cd /Users/kangjingoo/Workspace/tool/PaneDock/app/PaneDock

# 1) 가짜 데이터 모드 (권한 불필요, UI 확인용)
bash make-app.sh
open dist/PaneDock.app --args --fake steady
#    창을 클릭해 레이아웃과 버튼을 확인한다. 좌하단 [FAKE] 배너가 보여야 한다.
#    종료: 메뉴 막대 PaneDock → "PaneDock 종료"

# 2) 실제 Ghostty 연결 모드 (자동화 승인이 필요할 수 있다)
open dist/PaneDock.app
#    승인 대화상자가 뜨면 "허용". 거부하면 창에 오류가 표시된다.
```

### V6.8 남은 제한

- **중첩 TUI:** 대상 terminal에서 herdr·tmux·에이전트 TUI가 돌면 보고 경로는 바깥 프로세스의 cwd다.
  중첩 여부를 공식 조회로 확실히 판별할 수 없어 **자동 감지하지 않는다.** 직접 셸 환경 전용이다.
- **다중 창:** 대상은 `front window` 기준이다. 창이 여러 개일 때 기대와 맞는지는 미검증이다.
- **Herdr 환경:** 지원 범위 밖이다.
- **폴링:** Ghostty에 구독 API가 없어 기본 1초 주기 조회다. 화면 반영 지연 목표(기획서 §10의 700ms)는 미측정이다.
- **설정 저장 없음:** 창 위치·잠금·주기를 저장하지 않는다(F08은 범위 밖).
- **Spaces·전체화면:** 대응하지 않는다. 창이 다른 Space로 따라가지 않는다.
- **시각적 확인:** 레이아웃과 클릭 동작은 사용자가 확인해야 한다.

### V6.9 사용자 검증 절차 (A~H)

준비: 실제 모드로 실행해 두고, Ghostty에서 pane을 2개로 분할한다(왼쪽 = A, 오른쪽 = B).

```bash
cd /Users/kangjingoo/Workspace/tool/PaneDock/app/PaneDock
bash make-app.sh && open dist/PaneDock.app
```

| ID | 절차 | 기대 |
| --- | --- | --- |
| **A** | A → B로 포커스 이동 | 창의 폴더 이름·전체 경로가 B의 것으로 함께 바뀐다. 버튼 대상도 B다 |
| **B** | 대상 pane에서 `cd /tmp` | 폴더 이름·경로만 갱신된다(상태는 추적 중 유지) |
| **C** | 아래 별도 절차 | 대상이 바뀌지 않는다 |
| **D** | 브라우저 등 다른 앱으로 이동 | 상태가 **유지 중**으로 바뀌고 경로는 그대로다 |
| **E** | 폴더 열기 / 경로 복사 클릭 | 클릭 시점 폴더가 열리거나 경로가 복사된다. 이후 대상을 바꿔도 실행 결과는 클릭 시점 기준이다 |
| **F** | 잠금 클릭 후 pane 전환 | 상태가 **잠금**이고 대상이 고정된다 |
| **G** | 잠금 해제 클릭 | 현재 포커스를 다시 확인해 반영한다. Ghostty가 비활성이면 **유지 중**, 활성이면 **추적 중**으로 구분된다 |
| **H** | 오류 상태 만들기 → 폴더 열기 클릭 | 창에 오류가 표시되고 버튼이 거부 사유를 보여준다. 잘못된 대상으로 열리지 않는다 |

**C 절차 — 비활성 상태에서 일어나는 변경 (지연 실행 예약)**

B pane에서 아래를 **입력해 실행을 예약한 뒤, 즉시 A pane을 클릭해 포커스를 A로 옮긴다.**

```bash
sleep 10; cd /tmp
```

`sleep`이 끝나고 `cd`가 실행되는 시점에 **B는 실제로 비활성**이다.

- 기대: PaneDock 창의 폴더/경로가 **바뀌지 않는다**.
- 확인: 창에 변화가 없는 것을 본 뒤 B pane을 클릭해 보면 그 셸이 `/tmp`에 있다.
- 주의: 대상 pane에서 직접 `cd`한 것은 C가 아니라 **B** 절차다. 혼동하지 않는다.

**H 절차 — 경로 없음 (합성 또는 임시 경로)**

1. **합성(가장 안전):** `open dist/PaneDock.app --args --fake missing`
   → 상태 **오류**, 사유 "연동이 작업 경로를 제공하지 않았습니다", 두 버튼 모두 거부.
2. **실제 임시 경로:** 대상 pane에서
   ```bash
   mkdir -p /tmp/pd-ephemeral && cd /tmp/pd-ephemeral
   ```
   그리고 다른 셸에서 `rmdir /tmp/pd-ephemeral` (cwd여도 삭제된다 — 확인함).
   → 창이 **오류**(`보고된 경로가 파일 시스템에 없습니다`)로 바뀌고, 폴더 열기가 거부된다.

수행한 항목은 관측한 화면 내용과 함께 `V7`로 추가한다.

---

## V7. 2026-09-17 — 실제 모드 GUI 검증 및 결함 수정

### V7.1 실행 모드와 빌드 식별 정보

| 항목 | 값 |
| --- | --- |
| 검증 대상 | `app/PaneDock` (Ghostty 전용 최소 Dock, 0.1a) |
| 코어 | `prototypes/focus-probe` (CLI와 공유) |
| 수정 전 번들 바이너리 SHA-256 앞 16자리 | `4bdbb6bf39ef1977` (2026-09-16 19:22) |
| **수정 후 번들 바이너리 SHA-256 앞 16자리** | `6c4ebe6ca3b1bcc3` |
| 자체 검사 | **50/50** (기존 49 + 결함 회귀 1) |
| 실행 중이던 인스턴스 | pid 73525, 2026-09-16 19:22:45 시작, **인자 없음 = 실제 모드** |

V6에서 확인한 것과 **아직 확인하지 않은 것**을 구분한다.

| 구분 | 내용 |
| --- | --- |
| V6에서 확인됨 | 빌드, 자체 검사 49건, UI 없는 실제 Ghostty self-check, 가짜 모드 창 생성·상태 갱신 |
| **V6에서 확인되지 않음** | 실제 모드 번들 앱의 권한 승인, 실제 조회 성공, 버튼 클릭 동작, 시각적 레이아웃 |

### V7.2 에이전트가 확인한 것 (이번 작업)

| # | 확인한 것 | 방법 | 등급 |
| --- | --- | --- | --- |
| 1 | 코어·CLI·앱 빌드 재확인 | `swift build` 경고 0 | E1 |
| 2 | 기존 49건 회귀 | `focus-probe --self-test` | E2 |
| 3 | 실행 중 인스턴스가 **실제 모드**다 | 창 제목이 `PaneDock`(`[FAKE]` 아님), 실행 인자에 `--fake` 없음 | E3 |
| 4 | 실제 모드가 **폴링하고 있다** | 100ms 간격 30회 샘플에서 `osascript` 자식 8회 관측, **매번 다른 PID**(≈1초마다 새 호출) | E3 |
| 5 | 권한 대기로 멈춰 있지 않다 | 위 4번. 승인 대화상자가 떠 있었다면 같은 PID가 계속 살아 있었을 것 | E3 |
| 6 | 화면에 창이 존재한다 | `CGWindowList` → `owner=PaneDock layer=3 360×209` | E3 |
| 7 | 수정 후 self-check 회귀 | 실제/가짜 모두 정상 (`tracked /tmp`, `error` + 사유) | E2/E3 |

**확인하지 않은 것:** 실제 모드 조회가 **성공**했는지(권한 허용 여부)는 창 내용을 보지 않고는 확정할 수 없다.
4·5번은 "멈춰 있지 않다"까지만 말한다. 성공/거부 판정은 사용자 화면 확인이 필요하다.

### V7.3 발견한 결함 1건 (수정 완료)

**재현 조건(수정 전):** 연결이 끊겼거나 경로가 사라진 상태에서, 마지막으로 알던 경로 문자열이 남아 있으면
`DockState.canOpenFolder`/`canCopyPath`가 **true**가 되고, 버튼이 **활성화된 채로 눌렸다.**

- 원인: `DockStateBuilder.make`가 버튼 활성화를 `path?.isEmpty == false`만으로 정했다.
  표시 상태(`.error`/`.pending`)와 무관했다.
- 결과: 표시는 "오류"인데 버튼은 눌리고, 폴더 열기는 항상 거부되거나(경로 없음)
  연결이 끊긴 상태에서 낡은 경로로 실행을 시도했다.

**수정:** 버튼 활성화를 **표시 상태에서 파생**시켰다. 실행 가능한 것은
`추적 중`/`유지 중`/`잠금` 세 상태뿐이고, `확인 중`/`오류`에서는 두 버튼 모두 막는다.
거부 사유는 이미 `detail` 줄에 표시된다.

**추가로 함께 반영:** 버튼이 참조하는 대상을 **화면에 마지막으로 반영한 값**(`actionInfo`)으로
고정했다. 조회 결과와 화면 반영 사이에 어긋나는 순간이 생겨도 실행 대상이 흔들리지 않는다.

**회귀 검사:** `버튼 활성화가 표시 상태와 일치한다`
→ `tracked: open=true copy=true | held: open=true copy=true | pending: open=false copy=false | error/no-path: open=false copy=false | error/lost-connection: open=false copy=false | locked: open=true copy=true`

**수정 파일:** `FocusProbeCore/DockState.swift`, `app/PaneDock/…/DockModel.swift`, `SelfTest.swift`
기존 동작의 대규모 재작성 없음. CLI·코어 재사용 구조 유지.

### V7.4 사용자 GUI 검증 (미실시)

아래는 사용자 조작이 필요하므로 **미실시**다. V6의 가짜 모드·CLI 결과를 실제 GUI 성공으로 대체하지 않는다.

| ID | 항목 | 상태 |
| --- | --- | --- |
| A | pane A/B 전환 → 표시·실행 대상 동시 변경 | **완료** (V7.5) |
| B | 같은 pane에서 `cd` → 경로 갱신 | **완료** (V7.5) |
| C | 실제 비활성 pane의 지연 `cd` → 대상 유지 | **완료** (V7.7, 사용자 보고 + 로그 35초 무변화) |
| D | 브라우저 이동 → 마지막 경로 유지·상태 구분 | **완료** (V7.7, 유지 중 59초 관측) |
| E | 폴더 열기/경로 복사 → 표시 당시 대상과 일치 | **복사 완료**(V7.5) · **폴더 열기 완료**(V7.6, 사용자 보고) |
| F | 잠금 후 pane 전환 → 대상 고정 | **완료** (V7.6) |
| G | 잠금 해제 → 현재 포커스 재확인 | **완료** (V7.6) |
| H | 오류 상태 → 잘못된 대상으로 실행하지 않음 | **완료(임시 경로 방식)** — 실제 권한 거부·연결 오류는 **미실시** (V7.7) |
| 추가 | 숨김·재표시·종료, 화면 문구·버튼 배치 | **완료(사용자 보고)** — 문구 원문·스크린샷은 **미확보** (V7.7) |

**알려진 위험(확인 필요):** PaneDock 창을 클릭했을 때 `Ghostty.frontmost`가 false로 바뀌면,
상태가 "추적 중"에서 "유지 중"으로 잘못 전환될 수 있다. 창은 non-activating panel이고
`NSApp.activate`를 호출하지 않지만, **클릭 이후는 아직 관측하지 않았다.**
사용자 검증 묶음 1에 이 항목을 넣었다.

### V7.5 검증 묶음 1 결과 (2026-09-17 09:02~09:04)

**실행 모드/빌드:** 실제 모드(인자 없음 + `--state-log /tmp/pd-v7.log`),
번들 해시 `6c4ebe6ca3b1bcc3`(**수정 후 빌드**), pid 65258, 시작 2026-09-17 09:02:26.

**증거 등급 표기**

| 표기 | 뜻 |
| --- | --- |
| **사용자 보고** | 사용자가 화면을 보고 판단한 것. 에이전트는 화면을 보지 않았다 |
| **앱 자체 로그** | 앱이 `rebuildState()`에서 남긴 상태 기록을 에이전트가 파일로 확인. **화면 픽셀이 아니라 앱이 계산한 상태**다 |
| **에이전트 관측** | 에이전트가 직접 명령으로 확인 |
| 합성 검사 | 가짜 입력/자체 검사 |

| # | 조작 순서 | 기대 결과 | 관측 | 등급 |
| --- | --- | --- | --- | --- |
| 1 | 실제 모드 실행 후 창 확인 | 추적 중 배지, 폴더명·전체 경로, 버튼 3개 | "잘 되는거 같아" (구체 문구·배치는 원문 미확보) | 사용자 보고 |
| 2 | **A** pane A→B 전환 | 대상 pane과 경로가 **함께** 변경 | 로그에서 14회의 pane 전환. 예: `refresh=1` `54DBC13A`/`/Users/kangjingoo` → `refresh=4` `AB6006DD`/`/tmp` (pane과 경로 동시 변경) | 앱 자체 로그 |
| 3 | **B** 같은 pane에서 `cd` | pane ID 유지, 경로만 갱신 | pane `AB6006DD` 고정 상태에서 경로가 `/tmp` → `.../prototypes/focus-probe` → `/Users/kangjingoo` → `/tmp` 로 3회 갱신(09:03:17·19·22) | 앱 자체 로그 |
| 4 | **E(복사)** "경로 복사" 클릭 | 클립보드에 표시 중인 경로 | 클립보드에 디렉터리 경로가 있음(basename `focus-probe`) — 같은 시각 표시 대상의 폴더명과 일치. 내용 전문은 출력하지 않았다 | 에이전트 관측 |
| 5 | 위 클릭 후 상태 | "유지 중"으로 잘못 바뀌지 않고 "추적 중" 유지 | 로그 119줄 **전부 `display=tracked`**. `held`·`error` 전이 **0회** | 앱 자체 로그 |

**PaneDock 클릭 위험(V7.4의 미확인 항목) 판정:** 로그 전체에서 `display=held`가 한 번도 없었다.
`display=tracked`는 `hostFrontmost != false`일 때만 나오므로, **관측 구간(약 2분) 동안 Ghostty가
최전면에서 밀려난 적이 없다.** 따라서 클릭이 작업 위치 이동으로 해석되지 않았다.
(단, 사용자가 실제로 버튼을 몇 번 클릭했는지는 로그에 없으므로 클릭 시점과 1:1 대응은 아니다.)

**아직 남은 것:** 화면 문구·버튼 배치의 **시각적 확인 원문**은 없다. 폴더 열기·잠금·해제는 미실시다.

### V7.6 검증 묶음 2 결과 (2026-09-17 09:05~09:07)

**실행 모드/빌드:** 동일 인스턴스(실제 모드, `--state-log`, 번들 `6c4ebe6ca3b1bcc3`, pid 65258).
로그 301줄. `display` 분포: `tracked` 228 · `held` 64 · `locked` 9. **`error` 0회.**

| # | 조작 | 기대 | 관측 (앱 자체 로그) | 등급 |
| --- | --- | --- | --- | --- |
| **E-1** | "폴더 열기" 클릭 | Finder가 열리고 상태가 **유지 중**으로 바뀜. Ghostty로 돌아오면 추적 중 복귀 | `09:05:17 refresh=172 display=held` (folder=tmp) → `09:05:37 refresh=192 display=tracked`. **유지 중 20초 지속 후 복귀** | 앱 자체 로그 + 사용자 보고 |
| **E-2** | 표시 당시 대상과 실제 결과 일치 | 클릭 시점에 보이던 폴더가 열림 | 클릭 시점 표시 대상은 `AB6006DD`/`tmp`였고 그대로 유지됨. **Finder가 실제로 어느 폴더를 열었는지는 확인하지 않았다**(Finder 자동화 권한이 필요해 조회하지 않음) | 사용자 보고 |
| **F** | 잠금 후 pane 전환 → 대상 고정 | 표시가 잠긴 대상에 고정 | `09:06:58 refresh=267 display=locked pane=5D31DDD8 locked=true` → 4초간 표시 불변 → `09:07:02 refresh=272 display=tracked pane=AB6006DD`. **해제 직후 다른 pane이 나타났다 = 잠금 중 실제 포커스는 이미 AB6006DD로 이동해 있었다** | 앱 자체 로그(추론 포함) |
| **G** | 잠금 해제 → 현재 포커스 재확인 | 즉시 현재 포커스 반영 | 위 해제에서 잠긴 값(`5D31DDD8`)이 아니라 **현재 값(`AB6006DD`)으로 바뀜**. 2회차도 동일(`09:07:09` 잠금 `AB6006DD` → `09:07:11` 해제 후 `5D31DDD8`) | 앱 자체 로그 |

**F 판정의 근거를 분명히 한다.** 로그는 잠금 중 **표시된(pane) 값**만 기록하므로,
잠금 중 실제 포커스가 움직였는지는 로그에 직접 남지 않는다. 다만 **해제 직후 표시가 잠긴 값과
다른 pane으로 바뀌었다**는 사실은, 잠금 기간에 실제 포커스가 그 다른 pane으로 이동해 있었음을 뜻한다.
즉 잠금이 표시를 고정하는 동안 실제 포커스는 움직였고, 해제 시점에 그 값이 반영됐다. F와 G가 함께 성립한다.

**관측된 부수 현상:** `09:06:07 held → 09:06:09 tracked → 09:06:11 held` 로 2초 동안 상태가 진동했다.
앱 전환(Alt-Tab) 중 실제 최전면 변화가 1초 폴링에 잡힌 것으로 보이나,
**로그만으로는 "실제 포커스 이동"과 "일시적 전환"을 구분할 수 없다.** 결함으로 단정하지 않고 관측만 남긴다.

**아직 남은 것:** 폴더 열기의 실제 결과 경로(E-2), 화면 문구·버튼 배치 원문, 숨김·재표시·종료, C·D·H.

### V7.7 검증 묶음 3 결과 (2026-09-17 09:07~09:11) 및 V7 결론

**실행 모드/빌드:** 동일 인스턴스(실제 모드, `--state-log`, 번들 `6c4ebe6ca3b1bcc3`, pid 65258).
로그 505줄. `display` 분포: `tracked` 335 · `held` 126 · `error` 35 · `locked` 9.

| # | 조작 | 기대 | 관측 (앱 자체 로그) | 등급 |
| --- | --- | --- | --- | --- |
| **C** | B pane에서 `sleep 10; cd /tmp` 예약 후 즉시 A로 포커스 이동 | 대상이 바뀌지 않음 | `09:07:11`~`09:07:46` **35초 동안 전이 0회**(표시 `5D31DDD8`/focus-probe 고정). 이후 사용자가 B를 선택한 `09:08:56`에만 `AB6006DD`/`tmp`로 변경 | 사용자 보고 + 앱 자체 로그 |
| **D** | 브라우저 등 다른 앱으로 이동 | 마지막 경로 유지, **유지 중**으로 구분 | `09:07:46 display=held` → `09:08:45 display=tracked` (**59초 유지 후 복귀**), 경로는 그대로 | 앱 자체 로그 + 사용자 보고 |
| **H** | 임시 경로 삭제(`rmdir /tmp/pd-ephemeral`) | 오류 표시, 잘못된 대상으로 실행 안 함 | `09:10:09 tracked folder=pd-ephemeral` → `09:10:15 display=error folder=pd-ephemeral` **경로 소멸을 감지해 오류로 전환**, 이후 35줄 연속 오류 유지 | 앱 자체 로그 |
| **추가** | 숨김·재표시·종료, 화면 문구·버튼 배치 | 정상 동작 | "다 잘된다"(사용자 보고). **문구 원문·스크린샷은 미확보** | 사용자 보고 |

**C 판정의 근거와 한계.** 로그는 **표시된 대상**만 기록하고 배경 pane의 경로는 기록하지 않는다.
따라서 "배경 pane에서 실제로 `cd`가 일어났다"는 부분은 **추론**이다(이후 B를 선택했을 때 `/tmp`였다는 사실에서).
로그가 직접 보여주는 것은 **예약 실행이 일어날 시점을 포함한 35초 동안 대상이 전혀 움직이지 않았다**는 점이다.

**H 판정의 범위.** 확인한 것은 **경로 소멸(임시 디렉터리 삭제)로 인한 오류**다.
**실제 자동화 권한 거부나 Ghostty 종료로 인한 연결 오류는 확인하지 않았다.**
버튼 비활성 여부는 화면으로 확인하지 않았고, 회귀 검사(`버튼 활성화가 표시 상태와 일치한다`)와 사용자 보고에 근거한다.

**V7 결론**

| 항목 | 결과 |
| --- | --- |
| 발견·수정한 결함 | **1건** — 오류/확인 중 상태에서도 실행 버튼이 활성화되던 문제. 표시 상태에서 파생하도록 수정 |
| 회귀 검사 | 49 → **50건**, 전부 통과 |
| 실제 GUI 검증 A~H | **전부 완료**(H는 임시 경로 방식, 실제 권한 거부·연결 오류는 미실시) |
| 추가 항목 | 숨김·재표시·종료 및 배치 = 사용자 보고 완료. **문구 원문 미확보** |
| CLI·코어 재사용 구조 | 유지. 대규모 재작성 없음 |
| 범위 확장 | **없음.** Herdr 제외·C1 취소 유지, 새 Adapter·프로젝트 도구 묶음·설정 저장 추가하지 않음 |

**V7에서 확보하지 못한 것(정직하게 남긴다)**

1. 화면 문구·버튼 배치의 **원문 또는 스크린샷**.
2. 실제 **자동화 권한 거부** 시의 화면(권한을 되돌리는 것은 시스템 설정 변경이라 하지 않았다).
3. **Ghostty 종료**로 인한 연결 오류 상태.
4. `E-2`에서 **Finder가 실제로 연 폴더 경로**(Finder 자동화 권한이 필요해 조회하지 않았다).
5. 로그가 `display=held`↔`tracked`로 2초간 진동한 구간의 원인(1초 폴링 해상도로는 구분 불가).

---

## V8. 2026-09-17 — 0.1b: 키보드 접근과 최소 설정 저장

### V8.1 빌드 식별 정보

| 항목 | 0.1b 이전 | **0.1b 이후** |
| --- | --- | --- |
| 코어/CLI (`focus-probe` debug) SHA-256 앞 16자리 | `3a99569e7553e691` | `8572a25415a7da9e` |
| 앱 번들 (`PaneDock.app`) SHA-256 앞 16자리 | `6c4ebe6ca3b1bcc3` | `c7d915c942fa49f1` |
| 자체 검사 | 50/50 | **58/58** |
| Git | `b254341` (추적 파일 변경 없음) | 동일. 새 파일은 모두 미추적 |

`~/Library/Application Support/PaneDock/`는 **생성되지 않았다**(아래 V8.4 참조).

### V8.2 구현 내용과 변경 파일

| 파일 | 내용 |
| --- | --- |
| `FocusProbeCore/Settings.swift` **(신규)** | 설정 스키마 v1, 로드 결과 4종, 원자적 저장, 손상 백업, 미래 버전 보호, `WindowPlacement`(순수 좌표 보정) |
| `FocusProbeCore/SelfTest.swift` | 설정·좌표 보정 회귀 8건 추가 |
| `app/…/HotKey.swift` **(신규)** | Carbon `RegisterEventHotKey` 전역 단축키. **접근성 권한 불필요**, 키 감시 없음 |
| `app/…/ScreenGeometry.swift` **(신규)** | `NSScreen` → 코어 보정 입력 |
| `app/…/WindowDragHandle.swift` **(신규)** | 헤더 전용 드래그 영역 |
| `app/…/AppDelegate.swift` | 설정 로드/저장, 위치 복원·저장·초기화 메뉴, 단축키 등록, 키보드 모니터, 중복 인스턴스 감지, 시작 로그 |
| `app/…/DockModel.swift` | `perform(_:)` 단일 실행 경로(마우스·키보드 공용), 호출 중 최전면 값 동결, 키보드 포커스 |
| `app/…/DockView.swift` | 드래그 영역, 포커스 표시, 설정 안내, 키 안내 문구 |
| `app/…/LaunchOptions.swift` | `--settings-path`, `--move-to`(진단) |

**설정 스키마 v1** (`~/Library/Application Support/PaneDock/settings.json`)

```json
{ "schemaVersion": 1, "hotKey": "controlOptionCommandD", "hotKeyEnabled": true,
  "windowOrigin": { "x": 300, "y": 300 } }
```

**저장하지 않는 것:** 현재 pane ID, 실시간 경로, 잠금 상태. 회귀 검사로 스키마에 그런 키가 없음을 확인한다.

### V8.3 자동 검사 결과 (58/58)

기존 50건 회귀: **전부 통과.** 추가 8건:

| 항목 | 결과 |
| --- | --- |
| 설정: 파일 없음 → 기본값(파일도 만들지 않음) | PASS |
| 설정: 저장 후 재로드 시 값·스키마 버전 유지 | PASS |
| 설정: 손상 파일은 원본을 백업으로 보존(바이트 동일)하고 기본값 | PASS |
| 설정: **지원하지 않는 버전은 로드·저장 모두에서 덮어쓰지 않음** | PASS |
| 설정: 메모리 전용 모드는 파일을 만들지 않음 | PASS |
| 설정 스키마에 pane ID·경로·잠금 상태가 없음 | PASS |
| 창 좌표: 화면 안은 유지, 화면 밖·연결 끊김·화면 없음은 보이는 위치로 보정 | PASS |
| 창 좌표: 기본 위치가 기준 화면 안쪽 | PASS |

### V8.4 실제 GUI에서 에이전트가 확인한 것 (E3)

가짜 모드 + 전용 설정 파일(`--settings-path`, 임시 경로)로 실행했다.
**실제 사용자 설정 경로는 만들지 않았다**(`~/Library/Application Support/PaneDock/` 없음).

| # | 시나리오 | 명령 | 관측 |
| --- | --- | --- | --- |
| T1 | 설정 파일 없음 | `--fake steady --settings-path /tmp/pd-t1/…` | 창 `x=24 y=608`, **설정 파일 생성 안 됨**(이동이 없었으므로) |
| T2 | 저장 좌표 (400,200) 복원 | 동일 + 미리 작성한 설정 | 창 Cocoa `(400,200)` → 화면 좌표 `x=400 y=522` (화면 높이 반영) |
| T3 | **화면 밖 좌표 (90000,90000)** | 동일 | 창이 `x=1152 y=33`로 **보정됨**. 보정값이 설정에 저장됨(`1152,689`) |
| T4 | **손상 설정** | 동일 | 앱 정상 시작. `settings=corrupt(backup=/tmp/pd-t4/settings.corrupt-….json)`. 원본 바이트가 백업에 보존, **새 설정 파일은 만들지 않음** |
| T5 | **미래 버전(9)** | 동일 | 앱 정상 시작. `settings=unsupportedVersion(9)`, **파일 해시 불변**, 백업도 만들지 않음 |
| T6 | 단축키 등록 | 시작 로그 | `hotKey=⌃⌥⌘D hotKeyStatus=등록됨` |
| T6b | **중복 인스턴스** | 두 번째 인스턴스 실행 | `notice=다른 PaneDock 인스턴스 1개가 실행 중입니다. 호출 단축키는 한쪽에서만 동작합니다.` |
| T7 | **이동 → 종료 → 재실행 복원** | `--move-to 300,300` 후 재실행 | 이동 직후 설정에 `(300,300)` 저장. 재실행 시 창 `(300,300)` |

시작 로그 예(진단용, stderr 한 줄):

```
PaneDock startup: mode=fake settings=loaded file=/tmp/pd-t7/settings.json
origin=(300,300) size=360x260 hotKey=⌃⌥⌘D hotKeyStatus=등록됨 notice=-
```

### V8.5 구현 중 발견해 고친 것

1. **보정한 좌표가 저장되지 않던 문제.** 화면 밖 좌표를 보정해 창은 보이게 했지만, 설정에는 원래의
   잘못된 값이 남았다(창 이동 알림을 받기 전에 위치를 정했기 때문). 보정이 일어난 경우에만
   보정값을 저장하도록 고쳤다. 손상·미래 버전처럼 저장된 좌표가 없는 경우에는 아무것도 쓰지 않는다.
2. **단축키 충돌을 OS가 알려주지 않는 문제(실측).** Carbon `RegisterEventHotKey`는 같은 조합을
   **다른 프로세스가** 등록해도 오류를 주지 않는다. 두 인스턴스가 모두 "등록됨"으로 보고됐다.
   → 같은 번들 ID의 다른 인스턴스를 직접 감지해 안내하도록 보완했다.

### V8.6 사용자 확인이 필요한 항목 (미실시)

에이전트가 대신 수행하지 않았다. 가짜 모드/CLI 결과를 실제 GUI 성공으로 대체하지 않는다.

| # | 항목 | 상태 |
| --- | --- | --- |
| 1 | 드래그로 창 이동 → 정상 종료 → 재실행 복원 | 저장·복원 경로는 **에이전트 관측**(V8.4 T7). **실제 드래그는 사용자 보고**("괜찮은거 같아"), 로그 근거 없음 |
| 2 | 메뉴 "창 위치 초기화" | **사용자 보고** |
| 3 | **단축키 호출 → 키보드 선택·실행 → 닫기** | **완료** — 계측 로그로 확인 (V8.8) |
| 4 | 키보드 실행 결과가 표시 대상과 일치 | **완료** — 로그 + 클립보드 (V8.8) |
| 5 | **호출·닫기가 현재 작업 대상을 바꾸지 않음** | **완료** — 호출~닫기 구간 `held` 0회 (V8.8). 동결 로직의 필요성 자체는 미입증 |
| 6 | 오류/확인 중에 마우스·키보드 모두 차단 | 마우스는 V7에서 일부 확인. **키보드는 실사용 미실시**(차단 로직은 자체 검사로 확인) |
| 7 | 폴더 열기 A/B 대조(표시 경로 = 실제 열린 폴더) | V7에서 미기록, **이번에도 미실시** |
| 8 | 버튼 클릭과 창 드래그가 충돌하지 않음 | **사용자 보고** |

**미확인으로 남기는 것:** 실제 자동화 권한 거부, Ghostty 종료 시 연결 오류(사용자 작업 중단을 요구하므로).

### V8.7 사용자 실행 세션 관측 (2026-09-17 10:09~10:11) 및 계측 보강

사용자가 `--state-log /tmp/pd-v8.log`로 실제 모드 세션을 실행했다(로그 109줄).

**로그가 실제로 보여준 것(에이전트 관측)**

| 관측 | 내용 |
| --- | --- |
| 창이 실제 Ghostty를 추적했다 | pane과 경로가 **함께** 바뀌는 전이 9회. 예: `10:09:39 54DBC13A`/`~` → `10:09:56 AB6006DD`/`~` → `10:10:22 5D31DDD8`/`…/focus-probe` |
| 상태 분포 | **`tracked` 109 · `held` 0 · `locked` 0 · `error` 0** |
| 잠금 사용 | `locked=true` 0회 |
| 현재 시점 | Ghostty가 최전면 → 패널은 닫혀 있는 상태 |

**로그가 보여주지 못한 것 — 정직하게 남긴다.**
이 세션의 로그에는 **단축키 호출·키보드 이동·실행 이벤트가 계측되어 있지 않았다.**
따라서 "Dock을 실제로 호출했는지"조차 로그로 구분할 수 없고,
**검증 항목 3~7은 여전히 "사용자 보고"다.** `held`가 0회였다는 사실은
"호출이 대상을 바꾸지 않았다"의 증거로 쓸 수 없다(호출 자체가 없었을 수도 있다).

또한 이 날짜의 V8.4 이전 빌드에는 `EVENT` 기록이 없었다.

**계측 보강(빌드 변경)**

번들 SHA-256 앞 16자리: `c7d915c942fa49f1` → **`ddcdb3eb10b96c01`**

`StateLog`에 사건 기록(`EVENT`)을 추가하고 다음을 남기게 했다.

| 기록 | 내용 |
| --- | --- |
| `EVENT invoke` | 호출 시각, 동결한 최전면 값, 초기 포커스, 그 시점 대상 |
| `EVENT close` | 닫기 시각, 그 시점 대상 |
| `EVENT focus=` | 키보드 포커스 이동 결과 |
| `EVENT activate control=… source=keyboard` | 키보드 실행 시도 |
| `EVENT action=… source=mouse\|keyboard result=allowed\|blocked\|rejected target=…` | **마우스와 키보드가 같은 검증 경로를 쓰는지** 확인 |

이로써 다음 실행부터는 검증 항목 3~7을 사용자 보고가 아니라 **앱 로그로 확인**할 수 있다.

**보강 후 회귀:** 자체 검사 58/58 통과, 가짜 모드 시작 로그·상태 로그 정상
(`settings=fresh file=(메모리 전용)` — 가짜 모드가 실제 설정을 건드리지 않음을 재확인).

### V8.8 계측 빌드로 재검증 (2026-09-17 10:16~10:17) — 항목 3·4·5 승격

**실행 모드/빌드:** 실제 모드, `--state-log /tmp/pd-v8b.log`, 번들 `ddcdb3eb10b96c01`
(**계측 추가 후 빌드**), 로그 61줄.

로그 원문(호출~닫기 구간):

```
10:17:04.673 EVENT invoke frozenFrontmost=true focus=openFolder target=/Users/kangjingoo
10:17:04.674 refresh=6 display=tracked folder=kangjingoo path=/Users/kangjingoo pane=AB6006DD-… locked=false
10:17:05.132 EVENT focus=copyPath
10:17:05.364 EVENT activate control=copyPath source=keyboard
10:17:05.364 EVENT action=copyPath source=keyboard result=allowed target=/Users/kangjingoo pane=AB6006DD-…
10:17:05.574 refresh=7 display=tracked folder=kangjingoo path=/Users/kangjingoo pane=AB6006DD-… locked=false
10:17:06.567 EVENT close target=/Users/kangjingoo
10:17:06.568 refresh=7 display=tracked …
10:17:10.618 refresh=12 display=tracked folder=focus-probe pane=5D31DDD8-…   ← 이후 평소 작업 재개
```

| # | 조작 | 기대 | 관측 | 등급 |
| --- | --- | --- | --- | --- |
| 3 | `⌃⌥⌘D` 호출 → Tab → Enter → Esc | 호출·이동·실행·닫기 | `EVENT invoke` → `EVENT focus=copyPath` → `EVENT activate … source=keyboard` → `EVENT close`. **네 단계 모두 기록됨** | **앱 자체 로그** |
| 4 | 키보드 실행 결과 = 표시 대상 | 표시된 경로가 복사됨 | 로그의 실행 대상 `target=/Users/kangjingoo`(pane `AB6006DD…`)가 호출 직전 표시값과 동일. **클립보드에도 `/Users/kangjingoo`** 가 들어 있음 | **앱 자체 로그 + 에이전트 관측(클립보드)** |
| 5 | 호출·닫기가 작업 대상을 바꾸지 않음 | 대상 불변 | 호출~닫기 구간(10:17:04~06)의 상태 5줄이 **전부 `tracked`**, `held` 0회. 닫은 뒤에도 대상 불변 | **앱 자체 로그** |
| — | 마우스·키보드가 같은 검증 경로 | 동일 `perform` 사용 | 로그 형식 `action=… source=mouse|keyboard result=allowed`가 같은 필드를 쓴다. 키보드 경로가 `result=allowed`로 통과 | 앱 자체 로그 |

**동결(freeze)이 실제로 개입했는지는 구분하지 못한다.** `frozenFrontmost=true`로 무장됐지만
호출 구간에 Ghostty의 `frontmost`가 false로 바뀌지 않았기 때문에,
"동결이 막았다"와 "바뀔 일이 없었다"가 같은 결과(`tracked`)를 낳는다. **결과는 요구를 만족하나
동결 로직 자체의 필요성은 이 로그로 입증되지 않았다.**

**여전히 미실시:** 폴더 열기 A/B 대조, 오류·확인 중에서의 키보드 차단(차단 로직은 자체 검사와
V7의 마우스 관측으로만 확인), 실제 권한 거부, Ghostty 종료.

**실제 사용자 설정 파일이 생성되었다**(에이전트 관측). 사용자가 `--settings-path` 없이 실행한
실제 모드 세션에서 `~/Library/Application Support/PaneDock/settings.json`이 만들어졌다(10:10).

```json
{ "hotKey": "controlOptionCommandD", "hotKeyEnabled": true, "schemaVersion": 1,
  "windowOrigin": { "x": 24, "y": 90 } }
```

- 스키마 v1 형식이 그대로이고, **pane ID·경로·잠금 키가 없다**(설계대로).
- `windowOrigin`이 기록되었다는 것은 **실제 앱에서 위치 저장 경로가 동작했다**는 뜻이다.
  창을 옮겼거나 메뉴의 "창 위치 초기화"를 쓴 결과일 수 있으나, **로그에 그 사건이 남아 있지 않아
  어느 쪽인지는 구분하지 않는다**(V8.4의 `--move-to` 진단은 가짜 모드에서 수행했다).

---

## V9. 2026-09-17 — 0.1b 기준선 커밋 + 프로젝트별 웹 링크(0.1c 최소)

### V9.1 기준선 정리

**로컬 커밋 `64704c9`** — `feat: 포커스 추적 진단 도구와 Ghostty 전용 최소 Dock (0.1a~0.1b)`
(36 파일, 6,906줄 추가. 푸시·태그·이력 변경 없음.)

| 항목 | 내용 |
| --- | --- |
| 커밋 범위 | `docs/` 3건 + `app/PaneDock/` + `prototypes/focus-probe/` |
| 제외 | `.omp/`(OMP 하네스 개인 설정) — 미추적 상태 유지, `.gitignore`도 건드리지 않음 |
| 빌드 산출물 | 각 디렉터리의 `.gitignore`(`.build/`, `dist/`)로 이미 제외되어 후보에 0건 |
| 인증·비밀 파일 | 해당 파일 없음(이름만 확인, 내용은 열지 않음) |
| `git add .` | 사용하지 않음. 경로를 명시해 추가 |

**빌드 식별 정보 갱신** (V8.1의 코어 해시는 그 뒤 `SettingsLoadOutcome.label` 추가로 바뀌었다)

| 항목 | V8.1 기록 | 기준선 커밋 시점 | 0.1c 후 |
| --- | --- | --- | --- |
| 코어 CLI | `8572a25415a7da9e` | `aadd4fce0f61ed52` | **`4f3f40b61ad56d6a`** |
| 앱 번들 | `c7d915c942fa49f1` | `ddcdb3eb10b96c01` (V8.8과 동일) | **`ff868aeb4bcb45dd`** |

기존 58건 회귀: **58/58 통과** (커밋 전후 동일).

### V9.2 남은 실행 검증 (사용자, 미실시)

V7·V8에서 미실시로 남은 두 항목을 묶음으로 안내했다. **에이전트가 대신 수행하지 않았다.**

| ID | 항목 | 상태 |
| --- | --- | --- |
| A | 서로 다른 폴더 A/B에서 표시 경로 ↔ 실제 열린 폴더 대조 (Finder 자동화 권한 추가 없이) | 미실시 |
| B | 오류·확인 중에서 키보드로 실행을 우회할 수 없는지 | 미실시 (합성 상태 GUI 검증. **실제 권한 거부와는 구분**) |

### V9.3 새 기능: 프로젝트별 웹 링크

지원 환경은 그대로 **Ghostty 직접 pane + 로컬 셸**이다. 추가한 것은 "현재 작업 경로에 해당하는
프로젝트 이름과 웹 링크를 표시하고, 사용자가 선택하면 그 링크를 여는" 기능뿐이다.

| 파일 | 내용 |
| --- | --- |
| `FocusProbeCore/Projects.swift` **(신규)** | 카탈로그 스키마 v1, 로더(안전 규칙 동일·**읽기 전용**), 경로 비교, 매칭, 링크 실행 계획 |
| `FocusProbeCore/DockState.swift` | `isActionable` 추가, `hostFrontmostOverride`(동결) 추가 |
| `FocusProbeCore/SelfTest.swift` | 프로젝트 검사 16건 추가 |
| `app/…/DockModel.swift` | 프로젝트 판정, 포커스 항목(`FocusItem`), `openLink(at:source:)` |
| `app/…/DockView.swift` | 프로젝트 이름·기준 폴더·링크 행 |
| `app/…/AppDelegate.swift` | 카탈로그 로드·안내, 시작 로그에 카탈로그 상태 |
| `app/…/LaunchOptions.swift` | `--projects-path` |
| `app/PaneDock/projects.sample.json` **(신규)** | 예시 + `_how_to_use`(복사·수정 방법) |

**설정 파일** — `~/Library/Application Support/PaneDock/projects.json` (스키마 v1)

```json
{ "schemaVersion": 1,
  "projects": [ { "id": "shop", "name": "Shop", "root": "/Users/me/work/shop",
                  "links": [ { "id": "repo", "name": "저장소", "url": "https://…" } ] } ] }
```

- 기존 `settings.json`(위치·단축키)은 **그대로** 두고 별도 파일로 분리했다.
- 프로젝트 기준 폴더는 **사용자가 명시한 정적 설정**이며, 실시간 pane ID·CWD·잠금과 구분된다.
- **앱은 이 파일을 읽기만 한다.** 덮어쓰지 않는다. 샘플도 자동 복사하지 않는다.

**매칭 규칙(구현·검사 완료)**

| 규칙 | 구현 |
| --- | --- |
| 폴더 경계 비교 | 경로 구성요소 접두 비교. `/work/shop-old`는 `/work/shop`의 하위가 아니다 |
| 가장 구체적인 경로 우선 | 구성요소가 가장 많은 기준 폴더 선택 |
| 중복 기준 폴더 | `.ambiguous`로 **고르지 않고** 안내 |
| 대소문자 | 그대로 비교한다(임의 소문자화 없음) |
| **심볼릭 링크** | **비교할 때는 해석한다**(`/tmp`↔`/private/tmp` 같은 경우를 같은 폴더로 본다). **표시에는 원본 문자열을 그대로** 쓴다 |
| 미등록 경로·파일 없음 | 프로젝트 판정 없음 → 기존 기본 Dock으로 동작 |
| 설정 오류 | 조용히 무시하지 않고 진단·안내. 원본 파일은 건드리지 않음 |
| URL | `http`/`https`만. 그 외는 목록에서 제외하고 안내 |

### V9.4 자동 검사 결과 (74/74)

기존 58건 회귀: **전부 통과.** 추가 16건:

| 항목 | 결과 |
| --- | --- |
| 경로에 맞는 이름·링크 구성 (A/B) | PASS |
| 여러 기준 폴더가 맞으면 가장 구체적인 것 | PASS |
| 기준 폴더 자신도 매칭 | PASS |
| **폴더 경계** — `shop-old`/`shopping`은 `shop`이 아님 | PASS |
| 미등록 경로 → 기본 Dock | PASS |
| **중복 기준 폴더는 모호로 안내하고 고르지 않음** | PASS |
| http/https 외 링크는 제외 + 진단 | PASS |
| 중복 id(프로젝트·링크) 진단 | PASS |
| 대소문자를 임의로 소문자화하지 않음 | PASS |
| **심볼릭 링크를 해석해 같은 폴더로 판정**(실제 심볼릭 링크로 검증) | PASS |
| 카탈로그 없음/손상/미래버전 안전 처리 | PASS |
| 유효 링크는 URL로 연다(셸 문자열 없음) | PASS |
| **오류·확인 중에는 링크 실행을 막는다** | PASS |
| **프로젝트가 바뀌거나 링크가 사라지면 거부** | PASS |
| **호출 중 동결은 최전면 판정만 덮고 오류·경로 무효화는 드러낸다** | PASS |
| 동결로 유지 중이 된 경우에는 실행 가능 | PASS |

### V9.5 실제 GUI에서 에이전트가 확인한 것 (E3, 가짜 모드 + 임시 설정)

| 시나리오 | 관측 |
| --- | --- |
| 카탈로그 없음 | `catalog=fresh projects=0 diagnostics=0`, 안내 없음 → 기본 Dock |
| 정상 카탈로그 2개 | `catalog=loaded projects=2 diagnostics=0` |
| **프로젝트 전환** | `folder=tmp → project=tmparea(2)` → `folder=kangjingoo → project=home(1)` → 되돌아오면 `tmparea(2)` |
| 잘못된 카탈로그 | `diagnostics=2`, 안내: `기준 폴더가 중복 등록되었습니다: /tmp → x, y` / `허용되지 않는 링크입니다(http/https만): ftp://…` |

### V9.6 발견해 고친 결함 — 동결이 의도대로 동작하지 않았다

**재현 조건:** 호출 중 바깥 앱이 최전면에서 밀려난 상태(또는 그렇게 관측된 상태).
**증상:** `hostFrontmostOverride`가 `hostFrontmost` 필드만 덮어서 `focusStatus`는 `.held`로 남았다.
즉 **호출 중에는 창이 "유지 중"으로 표시됐어야 했는데, 동결이 그 판정을 되돌리지 못했다.**

**수정:** 덮어쓸 때 경로가 유효하면 `focusStatus`도 다시 계산한다(`tracked`/`held`).
경로가 무효하거나 확인 중이면 손대지 않아 **오류·확인 중이 동결로 가려지지 않는다.**

**검증:** 새 검사 2건(`동결은 최전면 판정만 덮고 오류·경로 무효화는 그대로 드러낸다`,
`동결로 유지 중이 된 경우에는 실행 가능하다`)이 이 동작을 고정한다.

**V8.8과의 관계:** V8.8 로그에서 호출 구간이 `tracked`로 유지된 것은 **Ghostty가 최전면을 잃지 않았기
때문**이며, 동결 로직이 개입해서가 아니었다. 그 로그만으로는 이 결함이 드러나지 않았다.

### V9.7 사용자 확인 필요 항목

| # | 항목 | 상태 |
| --- | --- | --- |
| A | 폴더 A/B 대조(표시 경로 ↔ 실제 열린 폴더) | 미실시 |
| B | 오류·확인 중 키보드 실행 차단 | 미실시(합성 상태 GUI) |
| C | 프로젝트 2개로 pane 전환 → 해당 링크가 열리는 흐름 | 미실시 |
| — | 실제 자동화 권한 거부, Ghostty 종료 | 미실시(유지) |

**미확인을 완료로 옮기지 않았다.** V8.6의 미실시 항목 중 3·4·5만 V8.8에서 승격됐고, 나머지는 그대로다.

### V9.8 남은 한계

- 프로젝트 편집 UI 없음(파일 직접 편집). 링크 자동 실행 없음 — 항상 사용자가 선택한다.
- 프로젝트 카탈로그는 시작 시 1회 읽는다. 실행 중 파일을 바꾸면 재시작이 필요하다.
- 심볼릭 링크는 해석해 비교하므로, 같은 폴더를 가리키는 서로 다른 경로가 **중복 등록으로 진단**될 수 있다.
- Ghostty 미지원 환경, 중첩 TUI, 다중 창, 원격 경로는 V6~V8과 동일하게 범위 밖이다.

### V9.9 사용자 실행 세션 관측 (2026-09-17 11:43~11:47)

**실행 모드/빌드:** 실제 모드, `--state-log /tmp/pd-v9.log`, 번들 `ff868aeb4bcb45dd`(0.1c 빌드), 로그 271줄.

| 관측 | 내용 | 등급 |
| --- | --- | --- |
| **A — 폴더 열기** | `action=openFolder source=mouse result=allowed` 3회. 대상은 `…/prototypes/focus-probe`(pane `ABEDF5F1`) → `…/prototypes/focus-probe`(pane `5D31DDD8`) → `/Users/kangjingoo`(pane `AB6006DD`) | 앱 자체 로그 |
| **A — 독립 확인** | 같은 시각 화면에 열려 있는 Finder 창 이름이 `focus-probe`, `kangjingoo` — 로그의 표시 경로 마지막 구성요소와 **일치** | 에이전트 관측(CGWindowList) |
| **B — 오류 상태 키보드 차단** | **이 로그에서 확인되지 않음.** `display=error`는 시작 직후 1회뿐이고, `--fake missing` 실행 흔적이 없다 | 미실시(사용자 확인 필요) |
| **C — 프로젝트 링크** | `~/Library/Application Support/PaneDock/projects.json` **없음**, 로그 전체 `catalog projects=0` → **프로젝트 기능이 실제 데이터로 실행되지 않았다** | 미실시 |
| 키보드 조작 | `invoke → focus=copyPath → activate → action=copyPath source=keyboard result=allowed` 2회. Tab 순회(`focus=lock→hide→quit→hide`)와 `activate control=hide → close`도 기록됨 | 앱 자체 로그 |
| **동결 + 유지 중 실행** | 11:43:40 호출에서 `frozenFrontmost=false`. 호출 구간 내내 `display=held`였고, **그 상태에서 키보드 실행이 허용**됐다(유지 중 = 유효한 대상이므로 정상) | 앱 자체 로그 |
| 상태 분포 | `tracked` 125 · `held` 123 · `error` 1(시작 직후) · `locked` 0 | 앱 자체 로그 |

**A의 한계:** Finder 창 **이름**은 마지막 구성요소만 준다. 서로 다른 경로가 같은 폴더 이름을 가질 수 있으므로,
이름 일치만으로 "표시된 전체 경로가 그대로 열렸다"가 증명되지는 않는다. 로그의 전체 경로 + 사용자 보고와
합쳐서 판단한 것이다. Finder 자동화 권한은 추가로 요구하지 않았다.

**C 미실시 이유:** 샘플 파일은 제공했지만 사용자가 자기 URL로 등록하지 않았다. 추측한 URL을 넣지 않았다.

### V9.10 B·C 사용자 검증 결과 (2026-09-17 11:54~11:56)

**실행 모드/빌드:** 앱 번들 `ff868aeb4bcb45dd`(0.1c 빌드).
`/tmp/pd-v9c.log`(111줄, 실제 모드 + 실제 카탈로그 2개), `/tmp/pd-v9b.log`(102줄, `--fake missing`).

#### C — 프로젝트 링크 (실제 카탈로그)

| # | 조작 | 관측 (앱 자체 로그) | 등급 |
| --- | --- | --- | --- |
| C0 | 시작 | `catalog projects=2 diagnostics=0` | 앱 자체 로그 |
| C1 | pane A를 `…/mac-tool-pack/egde-nochi`로 | `project=egde-nochi(2)` 58줄 | 앱 자체 로그 |
| C2 | pane B를 `…/markdown-viewer`로 | `project=markdown-viewer(0)` 3줄 — **링크 0개** | 앱 자체 로그 |
| C3 | A로 복귀 | `project=egde-nochi(2)` 재개 | 앱 자체 로그 |
| C4 | `⌃⌥⌘D` → Tab으로 링크 이동 → Enter | `EVENT link=repo project=egde-nochi source=keyboard result=allowed url=https://github.com/kjg8619/egde-nochi` | 앱 자체 로그 |
| **C4 독립 확인** | — | **브라우저(Aside) 창 제목이 `kjg8619/egde-nochi: EdgeNotch —…`** — 열린 URL의 경로와 일치 | **에이전트 관측(CGWindowList)** |
| C5 | 경로 복사(키보드) | `action=copyPath source=keyboard result=allowed target=…/mac-tool-pack/egde-nochi` — **폴더/복사는 현재 CWD 대상 유지** | 앱 자체 로그 |
| — | 닫기 | `EVENT close target=…/egde-nochi`, 이후에도 `project=egde-nochi(2)` 유지 | 앱 자체 로그 |

링크 포커스 이동도 기록됨: `focus=link:0 → link:1 → link:0 → link:1 → link:0`.

#### B — 오류 상태 키보드 차단 (합성 상태)

| 항목 | 관측 | 등급 |
| --- | --- | --- |
| 상태 | `display=error` 22줄 (`--fake missing`) | 앱 자체 로그 |
| 초기 포커스 | `invoke focus=lock target=-` (유효 대상 없음 → 잠금으로 시작) | 앱 자체 로그 |
| **차단** | `result=blocked` **28회**, `result=allowed` **0회** | 앱 자체 로그 |
| 사유 | `폴더 열기를 할 수 없습니다: 연동이 작업 경로를 제공하지 않았습니다` / `경로 복사를 할 수 없습니다: …` | 앱 자체 로그 |

→ **오류 상태에서 키보드로 실행을 우회할 수 없었다.** Tab으로 모든 항목을 순회하며 Enter를 눌렀지만
실행은 0건이었다.

**B의 범위:** 이것은 **합성 오류 상태**(`--fake missing`)의 GUI 검증이다.
**실제 자동화 권한 거부나 Ghostty 종료로 인한 오류는 여전히 미실시**다. 두 가지를 같은 것으로 기록하지 않는다.

#### V9.10에서 확보하지 못한 것

- **링크 마우스 클릭**(C4는 키보드로 수행). 두 경로가 같은 `openLink`를 쓰지만 마우스 클릭 자체는 미관측.
- C 로그에 `display=held`가 없다. 링크 열기가 호출 중(동결 구간)에 일어났고, 닫은 뒤에도 Ghostty가 최전면을
  유지했기 때문이다(브라우저가 뒤로 열린 것으로 보인다). **동결이 링크 열기의 최전면 변화를 가린 것인지,
  실제로 변화가 없었는지는 구분하지 않는다.**

**이로써 V9에서 계획한 검증이 모두 끝났다.** 남은 미실시 항목은 V9.7·V8.6에 그대로 둔다.

---

## V10. 2026-09-17 — 프로젝트 설정 수동 재로딩

### V10.1 빌드 식별 정보

| 항목 | 0.1c(V9 검증) | **0.1d(V10)** |
| --- | --- | --- |
| 앱 번들 SHA-256 앞 16자리 | `ff868aeb4bcb45dd` | **`d3dd3291e447f006`** |
| 코어 CLI SHA-256 앞 16자리 | `4f3f40b61ad56d6a` | **`190f86ae42a4a134`** |
| 자동 검사 | 74/74 | **86/86** |
| Git | `9fd9d82` (푸시 완료, 작업 트리 깨끗) | 동일 — **V10 변경은 미커밋** |

V9 검증 시점의 앱 번들과 이번 기준선은 일치했다. V10 작업으로 번들이 바뀌었다.

### V10.2 구현: 메뉴 "프로젝트 설정 다시 읽기"

| 파일 | 내용 |
| --- | --- |
| `FocusProbeCore/Projects.swift` | `ProjectCatalogStore.reload()`·`isUsable`, `ProjectCatalogApplier`(적용 판단), `ProjectSelection`(선택 유지 판정), `ProjectLinkPrivacy`(로그용 URL 축약) |
| `FocusProbeCore/SelfTest.swift` | 검사 12건 추가 |
| `app/…/AppDelegate.swift` | 메뉴 항목, `applyCatalog`, `--reload-after`(진단) |
| `app/…/DockModel.swift` | 재로딩 시 링크 선택 취소, `catalogNotice`, nil 포커스는 무실행 |
| `app/…/DockView.swift` | 프로젝트 설정 안내 표시 |
| `app/PaneDock/projects.sample.json` | 재로딩·실패 안내 방법 추가 |

**적용 규칙 준수**

| 규칙 | 구현 |
| --- | --- |
| 1. 하나의 일관된 구성으로 반영 | `ProjectCatalogApplier.apply`가 카탈로그·경고·안내를 한 값으로 확정하고, 모델이 그것만 반영 |
| 2. 정상 로딩 시 현재 CWD 기준 재계산 | `updateCatalog` → `rebuildState` → `ProjectResolver.resolve(cwd:)` |
| 3. 파일 없음 → 기본 Dock | `fresh` → 빈 카탈로그 적용, 링크 없음 |
| 4. 치명적 실패와 경고 구분 | `corrupt`/`unsupportedVersion`은 적용하지 않음. 중복 근본·잘못된 URL은 **경고로 안내**하고 나머지는 적용 |
| 5. 실패 시 이전 구성 유지 + 명시 | `appliedCatalog` 유지, 창에 `설정 읽기 실패 — 이전 설정 사용 중 (corrupt)` 표시 |
| 6. 안전 정책 유지 | 잘못된 URL은 목록 제외+안내, 중복 근본은 모호 처리(기존 그대로) |
| 7. 원본 자동 수정 금지 | **아래 V10.3 참조** |
| 자동 감시·주기 재로딩 없음 | 메뉴 호출 시에만 읽는다 |
| settings.json 불변 | 창 위치·단축키 설정 코드를 건드리지 않았다 |

**선택과 실행의 일치**

- 재로딩으로 **프로젝트가 바뀌거나 링크 목록(개수·순서·ID·URL)이 달라지면 진행 중인 링크 선택을 취소**한다.
  목록이 완전히 같으면 선택을 유지한다(`ProjectSelection.selectionSurvives`).
- 재로딩은 링크를 실행하지 않는다(실행 경로를 호출하지 않는다).
- `activateFocusedItem`에서 **포커스가 없을 때 아무것도 실행하지 않도록** 바꿨다.
  이전에는 `nil`이면 폴더 열기를 실행했는데, 재로딩으로 선택이 취소된 직후 Enter가 **다른 동작**을
  실행할 수 있었다. 이제 안내만 표시한다.
- 마우스·키보드는 계속 같은 `perform`/`openLink` 검증 경로를 쓴다. 폴더 열기·경로 복사는 현재 CWD 대상이다.

### V10.3 정책 변경 — 손상된 프로젝트 파일을 더 이상 옮기지 않는다

V9의 카탈로그 로더는 **손상된 파일을 `*.corrupt-<시각>.json`으로 옮겼다.**
이는 V10 규칙 7("어떤 경우에도 사용자 설정 원본을 자동 수정·복구하지 않는다")을 위반한다.

**변경:** 이제 손상·스키마 불일치 시 **파일을 전혀 건드리지 않고** 읽기 실패만 보고한다.
`ProjectCatalogLoadOutcome.corrupt`에서 백업 경로 필드도 제거했다(파일을 건드리지 않았다는 사실을 타입으로 표현).

**V9 기록과의 관계:** V9의 검사 항목 `프로젝트 카탈로그: 없음/손상/미래버전을 안전하게 처리`는
"손상백업=true"를 기대했다. 이번에 그 기대를 **"원본 보존 + 백업을 만들지 않음"**으로 바꿨다.
V9의 관측 자체(당시 동작)는 지우지 않고 여기에 변경 사실을 남긴다.

**settings.json은 그대로다.** 그쪽은 V8에서 검증·승인된 "손상 시 백업으로 보존 + 안내" 정책을 유지한다.
두 파일의 정책이 다르므로, 통일할지는 별도 결정이 필요하다(V10.8).

### V10.4 자동 검사 결과 (86/86)

기존 74건 회귀: **전부 통과.** 추가 12건:

| 항목 | 결과 |
| --- | --- |
| 카탈로그: 없음/손상/미래버전을 처리하고 **원본을 고치지 않는다**(백업도 만들지 않음) | PASS |
| 재로딩: 정상 변경을 반영하고 **사용자 파일은 건드리지 않는다** | PASS |
| 재로딩: 파일 없음 → 기본 Dock, 손상·미래버전 → 적용 불가로 구분 | PASS |
| 재로딩: 실패 후 정상 설정으로 복구 | PASS |
| 재로딩: 링크 목록이 그대로면 선택 유지, 순서·URL 변경·삭제·프로젝트 변경이면 취소 | PASS |
| 재로딩: 선택 중 목록이 바뀌면 이전 선택이 실행되지 않는다 | PASS |
| 다시 읽기: 정상 로딩은 새 구성 적용 + 결과 안내 | PASS |
| 다시 읽기: 손상·미래버전이면 이전 구성 유지 + `설정 읽기 실패 — 이전 설정 사용 중` | PASS |
| 다시 읽기: 파일이 없으면 기본 Dock으로 복귀 | PASS |
| 다시 읽기: 로더 경고를 조용히 무시하지 않고 안내에 포함 | PASS |
| 다시 읽기: 시작 시 정상 로딩은 불필요한 안내를 띄우지 않는다 | PASS |
| 로그용 URL은 쿼리·프래그먼트·사용자정보를 제거한다 | PASS |

### V10.5 앱 수준에서 에이전트가 확인한 것 (E3)

진단 훅(`--reload-after`, 메뉴와 **같은 동작**)과 임시 설정 파일로 확인했다.

| 시나리오 | 관측 |
| --- | --- |
| 실제 카탈로그 로드 | `catalog=loaded projects=2 diagnostics=0` |
| **재로딩 성공** | 실행 중 파일을 1링크→2링크로 수정 → `EVENT catalog … notice=프로젝트 설정을 다시 읽었습니다 — 프로젝트 1개`, 상태가 `project=tmparea(1)` → **`tmparea(2)`로 반영**(재시작 없음). 링크 실행 이벤트 없음 |
| **재로딩 실패** | 실행 중 파일을 손상시킴 → `notice=설정 읽기 실패 — 이전 설정 사용 중 (corrupt)`, **`project=tmparea(1)` 유지** |
| **원본 보존** | 손상 후에도 파일 해시 동일, 백업 파일 생성 없음 |
| 시작 시 손상 | `catalog=corrupt`, 원본 해시 동일 |
| 로그 URL 축약 | 실행 로그에 `url=https://github.com/kjg8619/egde-nochi`(쿼리 없음)만 남는다 |

### V10.6 프라이버시: 로그에 URL 원문을 남기지 않는다

실제 링크에 토큰·서명 쿼리가 붙을 수 있으므로 실행 로그는 **스킴·호스트·경로만** 남긴다
(`ProjectLinkPrivacy.redactedForLog`). 사용자 정보·쿼리·프래그먼트는 제거된다.

**창 표시는 사용자가 등록한 원본 URL을 그대로 쓴다**(자기 화면에서 자기 링크를 확인하는 것이 목적).
토큰이 포함된 URL을 등록하면 화면에는 그대로 보인다는 점은 남은 제약이다.

### V10.7 사용자 확인 필요 항목

| # | 항목 | 상태 |
| --- | --- | --- |
| A | 프로젝트 A/B를 오가며 **각 프로젝트의 다른 링크** 실행 | **미실시** — 두 번째 프로젝트에 링크가 없다(V10.9) |
| B | 키보드·마우스 링크 실행 **각각** | 키보드는 V9.10에서 확인, **마우스 클릭은 미실시** |
| C | 설정 파일 수정 → **메뉴로 다시 읽기** → 재시작 없이 반영 | **미실시**(앱 수준에서는 진단 훅으로 확인) |
| D | 링크 실행 후 **브라우저 표시·작업 복귀 경험** | **미실시** |

**기존 검증은 그대로 유지한다.** V9.10의 합성 오류 GUI 차단, 실제 프로젝트 링크 성공(브라우저 창 제목 확인)은
완료 상태다. 다음은 이번에도 하지 않았으므로 **미실시로 유지**한다:

- 실제 자동화 권한 거부·Ghostty 종료
- 확인 중(`pending`) 상태의 별도 GUI 키보드 검사
- Finder 창 이름보다 강한 **전체 경로** 대조

### V10.8 남은 제약

- 프로젝트 편집 UI 없음(파일 직접 편집). 자동 파일 감시·주기 재로딩 없음(의도).
- 카탈로그는 메뉴를 누를 때만 다시 읽는다. 창의 링크 목록이 바뀌어도 **이전 선택은 취소**되므로 다시 골라야 한다.
- `settings.json`(손상 시 백업)과 `projects.json`(손상 시 원본 유지)의 정책이 다르다. 통일 여부 미결정.
- 링크 실행이 브라우저를 앞으로 올리는지는 앱이 제어하지 않는다(`NSWorkspace.open`). 실제 동작은 사용자 확인 필요.

### V10.9 두 번째 프로젝트의 링크

`markdown-viewer`는 git 저장소도 `package.json`의 `repository`/`homepage`도 없어 **URL 출처가 없다.**
추측하지 않고 링크를 비워 두었다. 테스트 A(프로젝트별 **다른 링크** 실행)를 하려면
두 번째 프로젝트와 사용할 URL을 사용자가 알려줘야 한다.

---

## 정정 이력

- **2026-09-16 (V2.3)**: V1.6의 U5 절차 기대값이 틀렸다. herdr 클라이언트 분리(`ctrl+b q`)는
  서버를 유지하므로 연결 오류가 아니다. V1.6 본문은 보존하고 이 정정을 추가한다.
  `prototypes/focus-probe/README.md`의 U5~U7 절차 표는 정정된 내용으로 갱신했다.
- **2026-09-16 (V6.9)**: V4.7의 "존재하지 않는 디렉터리로 이동" 절차를 **경로 없음 검증으로
  재사용하지 않는다.** 그 절차는 대상 pane을 조작하는 방식이라 안전한 재현이 아니다.
  V6.9의 두 가지(합성 `--fake missing`, 별도 임시 경로 삭제)를 쓴다. V4.7 본문은 보존한다.
- **2026-09-17 (V10.3)**: 프로젝트 카탈로그의 **손상 파일 처리 정책을 바꿨다.**
  V9에서는 손상 시 `*.corrupt-<시각>.json`으로 옮겼으나(그리고 그 동작을 검사로 고정했으나),
  V10 규칙 7("어떤 경우에도 사용자 설정 원본을 자동 수정·복구하지 않는다")에 따라
  **이제 파일을 전혀 건드리지 않는다.** V9의 관측 기록은 보존하고 여기에 변경 사실을 남긴다.
  `settings.json`(손상 시 백업 보존)은 V8에서 승인된 정책이라 그대로 두었다. 통일 여부는 미결정이다.
