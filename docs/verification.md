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

### V10.10 사용자 검증 세션 관측 (2026-09-17 13:17~13:20)

**실행 모드/빌드:** 실제 모드, `--state-log /tmp/pd-v10.log`, 번들 `d3dd3291e447f006`(V10 빌드), 로그 219줄.

| # | 항목 | 관측 | 등급 |
| --- | --- | --- | --- |
| A | 프로젝트 전환 | `project=egde-nochi(2)` 40줄 ↔ `project=markdown-viewer(0)` 6줄 | 앱 자체 로그 |
| A | 프로젝트별 링크 | egde-nochi에서 링크 2개 표시, markdown-viewer에서 0개 | 앱 자체 로그 |
| **B(마우스)** | 링크 클릭 | `link=repo source=mouse result=allowed`, `link=issues source=mouse result=allowed` | 앱 자체 로그 |
| **B 독립 확인** | 클릭한 링크가 실제로 열림 | 브라우저(Aside) 창 제목이 **`Issues · kjg8619/egde-nochi`** — 마지막으로 클릭한 `…/issues`와 일치 | **에이전트 관측**(CGWindowList) |
| B(키보드) | 링크 실행 | 이번 세션에는 없음. **V9.10에서 이미 확인**(`link=repo … source=keyboard result=allowed`) | V9.10 |
| — | 키보드 폴더 열기 | `activate control=openFolder source=keyboard result=allowed target=…/egde-nochi` | 앱 자체 로그 |
| — | 키보드 포커스 이동 | `invoke focus=link:0` → `focus=link:1` → `focus=openFolder` | 앱 자체 로그 |
| — | 경로 복사(마우스) | `action=copyPath target=…/make-games/CodeMose` — 현재 CWD 대상 유지 | 앱 자체 로그 |
| — | **로그 URL 축약** | 기록된 URL에 쿼리·사용자정보가 없다: `url=https://github.com/kjg8619/egde-nochi`, `…/issues` | 앱 자체 로그 |
| **C** | 메뉴 "프로젝트 설정 다시 읽기" | **이번 세션에 실행되지 않았다**(`reload catalog` 이벤트 0건). 앱 수준 동작은 V10.5의 진단 훅으로 확인했다 | 미실시(사용자) |
| **D** | 링크 실행 후 브라우저 표시 | 브라우저 창이 열려 있는 것은 확인했다. **전면 표시·작업 복귀 경험은 앱 로그로 판단하지 않는다** | 사용자 확인 필요 |

**B 판정:** 키보드 링크 실행(V9.10)과 마우스 링크 실행(V10.10)을 **각각 다른 세션에서** 확인했고,
둘 다 같은 `openLink` 경로를 탄다. 이로써 "마우스 클릭 미관측" 항목은 해소됐다.

**여전히 미실시로 유지:** 실제 자동화 권한 거부·Ghostty 종료, 확인 중 상태의 별도 GUI 키보드 검사,
Finder 창 이름보다 강한 전체 경로 대조, 그리고 **C(메뉴 재로딩)의 사용자 실행**.

### V10.11 에이전트가 직접 수행한 추가 검증 (2026-09-17 13:27~)

사용자가 "직접 테스트할 수 있는지"를 물어, **권한이 필요 없는 범위에서 에이전트가 추가로 확인**했다.

**C — 메뉴 배선까지 확인 (물리적 클릭 제외)**

진단 훅(`--reload-after`)을 **메뉴 항목을 직접 호출하지 않고, 상태바 메뉴에서 항목을 찾아
그 항목의 `target/action`을 그대로 호출**(`NSApp.sendAction`)하도록 바꿔 검증했다.
이는 실제 클릭과 달리 마우스 이벤트만 없을 뿐, **메뉴 배선(항목 존재·target·selector)을 그대로 지난다.**

| 관측 | 값 |
| --- | --- |
| 메뉴 구성(시작 로그) | `Dock 호출/닫기 \| 잠금/해제 \| 창 위치 초기화 \| 프로젝트 설정 다시 읽기 \| 호출 단축키 \| PaneDock 종료` — **항목이 존재하고 활성 상태**(비활성 표시 없음) |
| 메뉴 호출 | `EVENT menu-invoke title=프로젝트 설정 다시 읽기 result=true` |
| 결과 | `EVENT reload catalog outcome=loaded projects=1 diagnostics=0`, `notice=프로젝트 설정을 다시 읽었습니다 — 프로젝트 1개` |
| 반영 | 실행 중 파일을 링크 1개→2개로 수정 → 상태가 `project=tmparea(1)` → **`tmparea(2)`** |
| 부작용 없음 | 재로딩 구간에 링크 실행 이벤트 **0건** |

**남은 미확인:** 실제 **마우스 클릭 이벤트가 그 항목에 전달되는지**. AppKit이 유효한 target/action을 가진
활성 항목에 대해 보장하는 부분이라 위험은 낮지만, **관측은 하지 않았다.**

**D — 브라우저 전면 동작 측정 (일회용 도구, 앱과 무관)**

| 측정 | 결과 |
| --- | --- |
| `NSWorkspace.shared.open(https://example.com/)` | `true`, 브라우저(Aside)가 **앞으로 온다**(직후 `lsappinfo front` = Aside, 브라우저 창 존재) |
| 전환 시점 | 첫 측정에서 `+2.0s`에는 `NSWorkspace.frontmostApplication`이 아직 Ghostty를 가리켰고 그 직후 `lsappinfo`는 Aside였다. **정확한 지연은 측정이 엇갈려 단정하지 않는다** |
| `OpenConfiguration.activates = false` | **측정 불가(결론 없음).** 측정 시작 시점에 브라우저가 이미 최전면이라 "앞으로 오는지"를 구분할 수 없었다. 제대로 재려면 **Ghostty가 최전면인 상태**에서 시작해야 하며, 이는 사용자 조작이 필요하다 |

**해석:** 링크를 열면 브라우저가 앞으로 오고, 그동안 Dock은 **유지 중**으로 표시된다(정상).
Ghostty로 돌아오면 **추적 중**으로 복귀한다(V9.9에서 `held → tracked` 전이 확인).
즉 "뒤로 열려서 사용자가 혼란스러운" 상황은 **이 환경에서 재현되지 않았다.**

**부수 효과:** 측정 과정에서 브라우저에 `example.com` 탭이 3개 열렸다(에이전트가 연 것). 앱 동작과 무관하다.

**빌드:** 이 검증으로 앱 번들이 `d3dd3291e447f006` → **`01253e68c91a1496`** 으로 바뀌었다
(진단 훅이 메뉴 배선을 지나가게 하고, 메뉴 구성을 로그에 남기도록 수정).

**두 번째 프로젝트 교체:** V10.9~V10.10에서 `markdown-viewer`를 두 번째 프로젝트로 썼으나
**URL 출처가 없어 링크가 0개**였다. 사용자가 `CodeMose`를 두 번째 프로젝트로 지정해 교체했다.

| 프로젝트 | 기준 폴더 | 링크 |
| --- | --- | --- |
| Edge Notch | `~/Workspace/mac-tool-pack/egde-nochi` | 저장소, 이슈 (2개) |
| CodeMose | `~/Workspace/make-games/CodeMose` | 저장소, 이슈 (2개) |

두 URL 모두 각 저장소의 **git origin에서 읽은 실제 값**이다(`git remote get-url origin`, 자격증명 제거).
`markdown-viewer` 항목은 제거했다.

| 확인 | 결과 |
| --- | --- |
| 카탈로그 로드 (GUI) | `catalog=loaded projects=2 diagnostics=0`, `EVENT catalog projects=2` |
| 비프로젝트 경로 판정 | 현재 포커스 pane `/Users/kangjingoo` → `project - (기본 Dock) catalog=loaded projects=2` |
| 두 프로젝트 경로 존재 | 둘 다 디렉터리 존재 확인 |
| 앱 번들(재빌드) | `2d9bd1f9fef97fc1` |

**미확인:** 실제 pane이 **두 프로젝트 폴더에 있을 때**의 판정. 현재 포커스 pane은 홈이고,
`egde-nochi`에는 Ghostty pane이 있으나 **포커스를 옮기는 것은 사용자 조작**이라 에이전트가 하지 않았다.
(V10.9의 A/B 전환 관측은 `markdown-viewer` 기준이므로 CodeMose 기준으로 다시 확인이 필요하다.)

### V10.12 사용자 확인 — CodeMose 기준 프로젝트 판정 (2026-09-17)

위 항목을 사용자가 직접 확인하고 **"잘 잡혀"** 라고 보고했다. 즉 두 프로젝트가 각각의 기준 폴더에서
**의도한 프로젝트로 판정됨**을 사용자가 관측했다.

**등급: 사용자 보고.** 에이전트는 이 확인을 **재실행으로 재확인하지 않았다**(보고를 사실로 기록).
이번 확인에는 **상태 로그를 수집하지 않았으므로**, 판정의 세부(양방향 여부·하위 폴더 매칭·링크 실행)는
보고에 포함되지 않아 **미확인으로 남긴다.**

**여전히 미확인:** 하위 폴더 매칭 · 링크 실행까지의 왕복 · 메뉴 항목의 실제 마우스 클릭 ·
자동화 권한 거부 · Ghostty 종료 · 확인 중 상태의 별도 키보드 검사 · Finder 창 이름보다 강한 전체 경로 대조.

### V10.13 에이전트 직접 검증 — 실제 마우스 클릭과 하위 폴더 (2026-09-17 13:45~13:46)

위 V10.12에 남긴 미확인 항목 중 **하위 폴더 매칭, 메뉴 실제 클릭, 링크 실제 클릭**을 에이전트가 직접 수행했다.

**방법:** 저장소에 남기지 않는 **일회용 Swift 도구**(`CGEvent` 마우스 이벤트 + `AXUIElement`)로
PaneDock 프로세스에 **실제 마우스 클릭**을 보냈다. 사전 확인: `AXIsProcessTrusted=true` —
**새 권한을 요청하거나 부여받지 않았고, 시스템 설정을 변경하지 않았다.**

| # | 대상 | 클릭 지점 | 결과 |
| --- | --- | --- | --- |
| 1 | 상태바 항목 `PaneDock` | `(872,4) 84x24` | 메뉴 열림 → 항목 **`프로젝트 설정 다시 읽기`** `(868,111) 203x24` 클릭 |
| 1 | 재로딩 결과 | — | `EVENT reload catalog outcome=loaded projects=2 diagnostics=0`, `notice=프로젝트 설정을 다시 읽었습니다 — 프로젝트 2개` |
| 2 | 하위 폴더 매칭 | — | 실제 pane `…/make-games/CodeMose/docs` + 실제 카탈로그 → `project CodeMose (codemose) links=2` |
| 3 | Dock 링크 `저장소` | `(73,832) 50x20` | `EVENT link=repo project=codemose source=mouse result=allowed url=https://github.com/kjg8619/CodeMose` |
| 3 | Dock 링크 `이슈` | `(73,860) 41x20` | `EVENT link=issues project=codemose source=mouse result=allowed url=https://github.com/kjg8619/CodeMose/issues` |

**독립 확인 (앱 로그 밖):**

| 항목 | 값 |
| --- | --- |
| 브라우저 창 제목 | `kjg8619/CodeMose`, `Issues · kjg8619/CodeMose` |
| Dock이 포커스를 뺏지 않았는지 | 클릭 직후 최전면 앱 = **`Aside`**(브라우저). PaneDock이 아님 |
| 상위 폴더 경로 일치 | terminal working directory = `…/make-games/CodeMose/docs`, 앱이 보고한 `path`와 동일 |

**작은 발견:** SwiftUI 버튼은 `AXTitle`이 비어 있지만 **`AXDescription`에 라벨이 들어 있다.**
이번에 관측된 Dock 버튼 라벨: `저장소`, `이슈`, `폴더 열기`, `경로 복사`, `잠금`, `숨기기`, `종료`.
(보조 기술로 Dock을 조작할 때 이 라벨이 쓰인다. 코드에 별도 `accessibilityLabel`을 붙이지 않은 버튼도
라벨이 노출된다는 뜻이다.)

**이로써 해소된 미확인:** 메뉴 항목의 실제 마우스 클릭 · 하위 폴더 매칭 · 링크 실행 왕복(마우스).

**여전히 미확인:** 자동화 권한 거부 · Ghostty 종료 · 확인 중(`pending`) 상태의 별도 키보드 검사 ·
Finder 창 이름보다 강한 전체 경로 대조 · `activates=false` 재측정(Ghostty가 최전면일 때만 가능).

**빌드:** 코드 변경 없음(`2d9bd1f9fef97fc1`). 검증용 도구는 저장소에 추가하지 않았다.

## V11. 2026-09-17 — 0.1d 기준선 정리 + cmux 읽기 전용 추적 실험

### V11.1 기준선 (V11 변경 전 측정)

**V10.1의 "미커밋" 기록은 현재 사실이 아니다.** V10의 변경은 `d6aa0f8`·`01f27b0`·`ca4b994`로
커밋·푸시됐고, V11 착수 시점의 작업 트리는 **깨끗했다**.

| 항목 | V11 착수 시점 | V11 최종 |
| --- | --- | --- |
| HEAD | `ca4b994` (원격과 동일) | 미커밋 (V11.10) |
| 작업 트리 | 소스 변경 없음. 미추적은 `.omp/`뿐 | 아래 커밋 후보 참조 |
| 자동 검사 | **86/86** | **98/98** |
| 앱 번들 SHA-256 앞 16자리 | `2d9bd1f9fef97fc1` (V10.13과 동일) | **`4f79ce4e034167e6`** |
| 코어 CLI SHA-256 앞 16자리 | `1d7e43aee4865fad` | **`048eb0badbeeff67`** |

**해시에 대해 확인한 것:** 같은 소스로 두 번 빌드하면 **같은 해시**가 나온다(변경 없이 `touch` 후 재빌드 2회).
**확인하지 못한 것:** V10.13이 기록한 CLI 해시 `190f86ae42a4a134`와 V11 착수 시점의 측정값
`1d7e43aee4865fad`가 다르다. 두 시점 사이에 `prototypes/focus-probe` 소스는 바뀌지 않았다.
**원인을 규명하지 못했다.** 따라서 이 기록에서 해시는 **같은 세션 안에서 비교할 때만** 근거로 쓴다.

### V11.2 cmux 설치·실행 상태

| 항목 | 값 | 근거 |
| --- | --- | --- |
| CLI 버전 | `cmux 0.64.22 (102) [ddd4a01bc]` | `cmux --version` |
| 앱 버전 | `0.64.22` | `Info.plist` `CFBundleShortVersionString` |
| 실행 파일 | `/Applications/cmux.app`, `/opt/homebrew/bin/cmux`(심볼릭) | `ls -l` |
| **착수 시 실행 상태** | **실행 중이 아님** | `pgrep -lf cmux.app` 결과 없음 |
| 남아 있던 소켓 | `~/Library/Application Support/cmux/cmux.sock` (`May 27`, `srw-------`) — **stale** | `ls -l` |
| **V11.5 실관측 시점** | **실행 중** (pid 86842). **사용자 승인 후 에이전트가 실행** | `pgrep` |

V1의 "미실행" 결론을 재사용하지 않고 다시 측정했다.

### V11.3 공식 연동 조사 — 두 경로를 모두 실측했고 결론이 뒤집혔다

#### (a) 소켓 — **이 기기에서는 열려 있다** (설정을 바꾸지 않았다)

공식 문서(`https://cmux.com/docs/api`)는 세 모드(Off/cmuxOnly/allowAll)와
"cmux processes only가 기본"을 설명한다. 그러나 **실제로 확인한 값은 `automation`**이다.

| 확인 | 값 | 근거 |
| --- | --- | --- |
| 접근 모드 | **`automation`** | `cmux capabilities` → `access_mode` |
| 모드의 공식성 | 공식 스키마 enum 값 (`off`,`cmuxOnly`,`automation`,`password`,`allowAll`,`openAccess`,`fullOpenAccess`,`notifications`,`full`) | `web/data/cmux.schema.json` `properties.automation.socketControlMode` (스키마의 `default`는 `cmuxOnly`) |
| 이 기기의 설정 | `socketControlMode = automation` | `defaults read com.cmuxterm.app` |
| **바깥 프로세스에서 접속** | **성공** — `cmux ping` → `PONG` | 에이전트 셸(외부 프로세스)에서 실행 |
| 소켓 경로 | `~/.local/state/cmux/cmux.sock` | `capabilities.socket_path` |

**설정을 변경하지 않았고, 제한을 완화하지도 않았고, 인증을 우회하지도 않았다.**
이미 허용된 공식 모드를 그대로 썼다. (모드를 기본값 `cmuxOnly`로 되돌리면 바깥 프로세스는
연결할 수 없다 — 그 사실 자체가 이 연동의 전제 조건이다.)

#### (b) AppleScript — **사전은 있지만 쓸 수 없다** (V11.3 초안의 결론을 뒤집음)

cmux는 스크립팅 사전을 포함하고 스크립트 가능으로 선언돼 있다:

| 근거 | 값 |
| --- | --- |
| 사전 | `/Applications/cmux.app/Contents/Resources/cmux.sdef` |
| 선언 | `Info.plist`: `NSAppleScriptEnabled=true`, `OSAScriptingDefinition=cmux.sdef` |
| 사전이 노출하는 읽기 속성 | `application.frontmost`·`front window`·`version`, `window.id`·`name`·`selected tab`, `tab.id`·`name`·`index`·`selected`·`focused terminal`, `terminal.id`·`name`·`working directory` |

**그런데 객체 모델이 응답하지 않는다.** 한 줄씩 최소 단위로 실행한 결과(각 6초 상한):

| AppleScript | 결과 |
| --- | --- |
| `get version` | `0.64.22` (즉시) |
| `get frontmost` | `true` (즉시) |
| `exists front window` | `true` (즉시) |
| `count of windows` | **타임아웃(응답 없음)** |
| `id of front window` / `name of front window` | **타임아웃** |
| `selected tab of front window` / `count of tabs of front window` | **타임아웃** |
| `count of terminals` / `count of terminals of front window` | **타임아웃** |
| `working directory of terminal 1` | **타임아웃** |

전체 Adapter 스크립트를 실행했을 때는 **34초 동안 응답이 없어** 중단했다(해당 `osascript`는 종료).
**권한 대화상자가 떠 있었던 것은 아니다** — 화면의 창 목록에 보안 대화상자가 없었다.

→ **창·workspace·panel·경로를 AppleScript로 읽을 수 없다.** AppleScript 경로는 폐기했다.

#### (c) 소켓이 실제로 주는 것 (읽기 전용)

`cmux identify --json --id-format uuids`:

```json
"focused": { "window_id": "502A2510-…", "workspace_id": "6D10FF4A-…",
             "pane_id": "5CEA7EBC-…", "surface_id": "43007C41-…", "tab_id": "43007C41-…",
             "surface_type": "terminal", "is_browser_surface": false },
"caller": null
```

`cmux sidebar-state --workspace <id>`:

```
cwd=/Users/kangjingoo            ← workspace 요약
focused_cwd=/Users/kangjingoo    ← 포커스된 panel의 경로
focused_panel=43007C41-…         ← 그 경로가 어느 panel의 것인지
```

| 확인 | 결과 |
| --- | --- |
| `focused_panel`과 선택된 surface의 일치 | `focused_panel`(43007C41-…) == `identify.focused.surface_id`(43007C41-…) **일치** |
| workspace·창 식별자 일치 | `list-workspaces`의 `6D10FF4A-…`(선택)·`list-windows`의 `502A2510-…`와 각각 일치 |
| 표시 이름/제목 | `list-pane-surfaces`에 `title`이 있다(경로 추측에는 쓰지 않는다) |
| **비활성 panel의 경로** | **읽는 공식 방법을 확인하지 못했다.** `sidebar-state`는 포커스된 panel 것만 준다 |
| **앱 최전면 여부** | **소켓이 알려주지 않는다**(`app.focus_override.set`·`app.simulate_active`는 테스트용 쓰기) → **OS에서 읽는다** |

### V11.4 구현 (CLI 실험 경로만)

**GUI 파일(`app/PaneDock/Sources/PaneDockApp/*`)은 한 줄도 수정하지 않았다.**

| 파일 | 변경 |
| --- | --- |
| `FocusProbeCore/CmuxAdapter.swift` | **신규.** `identify` + `sidebar-state` 두 읽기 명령만 실행하는 소켓 CLI 연동 |
| `FocusProbeCore/FrontmostAppChecker.swift` | **신규.** OS(`NSWorkspace`)로 최전면 판정(소켓이 제공하지 않음) |
| `FocusProbeCore/GhosttyAdapter.swift` | 공통 조각을 앱 중립으로 일반화: `TerminalHostSnapshot`·`TerminalHostTerminal`·`TerminalHostSnapshotApplier`·`TerminalHostMapping`·`TerminalHostAdapter`·`TerminalHostPayload.parse`·`TerminalHostQueryFailure`, `focusedPanelIsTerminal` 필드 |
| `FocusProbeCore/GhosttyProbe.swift` | `TerminalHostAdapter`를 받도록 일반화(이름은 GUI 호환을 위해 유지), 버전 게이트 위임, 오류는 `TerminalHostQueryFailure`로 |
| `FocusProbeCore/CurrentWorkInfo.swift` | `CWDSource.cmuxFocusedCWD = "cmux:sidebar-state.focused_cwd"` |
| `FocusProbeCore/FocusResolver.swift` | `clearTarget()` — 대상이 사라질 때 세대를 올려 늦은 응답 무효화 |
| `FocusProbeCore/ContextStore.swift` | `markTargetUnknown()` — 이전 대상을 현재 대상처럼 남기지 않는다 |
| `FocusProbeCore/DiagnosticsReport.swift` | 연결 줄에 **전송 수단**을 표시(`cmux socket CLI` / `AppleScript`) |
| `FocusProbeCLI/main.swift` | `--adapter cmux`, 사용법·한계, 실험 경고 |
| `FocusProbeCLI/GhosttyProbes.swift` | `GhosttyWatchProbe` → `WatchProbe`(probe 주입) |
| `FocusProbeCore/SelfTest.swift` | cmux 검사(소켓 합성) |

**경로를 추측하지 않기 위한 규칙 두 개(코드로 강제)**

1. **workspace 요약 `cwd`를 surface 경로로 쓰지 않는다.** 경로는 `focused_cwd`에서만 온다.
2. `focused_cwd`는 `focused_panel`이 **선택된 surface와 같을 때만** 인정한다. 다르면 `unsupported`다.

**식별자 매핑** — cmux는 `window → workspace → pane → surface` 4단계, 공통 스키마는 3단계다:

| cmux | 공통 스키마 |
| --- | --- |
| `window_id` | `workspaceID` 슬롯(창) |
| `workspace_id` | `tabID` 슬롯(창 안의 탭 역할) |
| `surface_id` | `paneID`·`terminalID`(표시 대상 panel) |
| `pane_id`(분할 컨테이너), 별도 `tab_id` | 이 최소 진단에서는 표시하지 않음 |

**실행 방법**

```
focus-probe --adapter cmux              # 한 번 조회
focus-probe --adapter cmux --watch      # 폴링(기본 1000ms)
focus-probe --adapter cmux --json       # 기계 판독
focus-probe --self-test                 # 98건
```

**하지 않는 것:** workspace·pane·surface 생성/이동/포커스 변경, 입력 전송, 앱 활성화.
조회 명령은 `identify`와 `sidebar-state` **둘뿐**이다. 프로세스는 무한 대기를 피하려 상한(4초)을 둔다.

### V11.5 검증

#### 합성 검사 — 98/98 (기존 86 + cmux). **실제 관측이 아니다.**

| 검사 | 확인 내용 | 결과 |
| --- | --- | --- |
| cmux A | workspace 전환 → 새 식별자·새 경로, `cwdSource=cmux:sidebar-state.focused_cwd`, `adapterID=cmux` | PASS |
| cmux B | 같은 surface에서 cd → 식별자·세대 유지, 경로만 갱신, `previous` 없음 | PASS |
| cmux 요약 함정 | workspace 요약 `cwd`가 달라도 표시 경로는 `focused_cwd`를 따른다 | PASS |
| cmux C | 비활성 panel을 **조회하지 않는다**(배경 경로가 표시를 바꿀 수 없다) | PASS |
| cmux D | 전환 전 surface의 늦은 응답 → `discardedStale` | PASS |
| cmux E | 최전면 아님 → `held`, 경로 유지 | PASS |
| cmux F | 터미널이 아닌 panel → 이전 경로를 현재 대상처럼 남기지 않음(`previous`로만) | PASS |
| cmux F | 터미널이 아닌 panel 뒤 늦은 응답이 되살아나지 않음 | PASS |
| cmux F | `focused_panel`이 선택된 surface와 다르면 경로를 인정하지 않음 | PASS |
| cmux F | 연결 실패 → 경로 없이 구분, **사유에 cmux라고 표시** | PASS |
| cmux | 해석할 수 없는 응답·빈 값을 경로로 만들지 않음 | PASS |
| 회귀 | Ghostty는 대상이 없어도 새 규칙으로 대상을 지우지 않는다 | PASS |

#### 실제 관측 — cmux 실행 중 (에이전트 수행, 14:28)

| 관측 | 결과 |
| --- | --- |
| `--adapter cmux` | `connection connected cmux socket CLI (identify + sidebar-state)`, `focus tracked`, `path /Users/kangjingoo`, `cwdSource cmux:sidebar-state.focused_cwd`, `validity valid`, exit=0 |
| 식별자 | `pane 43007C41-…` / `workspace 502A2510-…` / `tab 6D10FF4A-…` / `terminal 43007C41-…` — `identify`·`list-workspaces`·`list-windows`·`sidebar-state.focused_panel` 값과 **모두 일치** |
| `--watch` | 같은 상태를 반복 보고 |
| 최전면 | `frontmost true` — OS의 최전면 앱(`lsappinfo front` = cmux)과 **일치** |
| **변경 없음** | 조회가 workspace·pane·surface·포커스를 바꾸지 않았다(조회 후 `list-workspaces`의 선택 그대로) |

#### 실제 관측 — AppleScript 차단 (에이전트 수행)

V11.3(b)의 표. `osascript`가 34초 응답 없이 멈춘 것을 확인하고 해당 프로세스를 종료했다.

#### 실제 관측 — Ghostty 회귀 (에이전트 수행)

| 관측 | 결과 |
| --- | --- |
| 앱 `--self-check` | `display held`(cmux가 최전면이므로 유지 중 — 정상), `…/CodeMose/docs`, `project CodeMose (codemose) links=2` |
| GUI 스모크(가짜 모드) | 시작 로그·메뉴 구성이 V10.13과 동일 |
| CLI 기본 경로 | `cwdSource ghostty:terminal.workingDirectory`, `path …/CodeMose/docs` |

#### 사용자 보고

없음. 이번 검증에서 사용자는 아무것도 확인하지 않았다.

#### 미검증 → **사용자 세션에서 관측됨 (V11.11)**

| # | 항목 | 상태 |
| --- | --- | --- |
| 1 | `focused_cwd`가 **live pwd**인지(cd 갱신) | **관측됨** — 같은 surface에서 경로 변경(V11.11) |
| 2 | 터미널이 아닌 panel이 포커스될 때의 동작 | **미검증 유지** — 브라우저 panel이 만들어지지 않았다 |
| 3 | workspace A → B 전환(A) | **관측됨** — 식별자·경로 동시 변경 6회(V11.11) |
| 4 | 최전면이 아닐 때의 `held`(E) | **관측됨**(양방향) — 단 아래 판정 결함 참조 |
| 5 | 중첩 TUI·원격 경로 | 이번 범위 밖(Ghostty와 같은 한계) |

합성 검사는 **우리 코드**만 검증한다. 위 관측은 실제 cmux에서 얻었다.

### V11.6 기존 앱을 수정하지 않고 연동할 수 있는가

- **가능하다.** GUI 파일은 수정하지 않았고, cmux 조회는 `--adapter cmux`로만 도달한다.
- 앱의 Ghostty 경로는 공유를 위한 일반화만 거쳤고 동작이 같음을 self-check·스모크로 확인했다.
- **전제 조건:** 이 기기의 소켓 접근 모드가 `automation`이어야 한다(현재 그렇다).
  기본값 `cmuxOnly`로 되돌리면 바깥 프로세스는 연결할 수 없다. 이 연동은 **설정을 바꾸지 않는다.**
- 앱을 cmux에 연결하려면 Adapter 선택 경로만 추가하면 된다. 조회·반영·표시 코드는 이미 공유된다.

### V11.7 다음 GUI 연결에 필요한 최소 작업

1. 앱에서 Adapter를 **명시 선택**하는 최소 경로(실행 인자 또는 설정 1개). 자동 전환·메뉴 확장 없음.
2. V11.5의 미검증 1~4를 실제 cmux에서 관측한 뒤 연결. 특히 #2를 확인하기 전에는
   cmux 경로를 "지원"으로 표시하지 않는다.
3. cmux 미실행·터미널 아닌 panel일 때의 표시 문구 검토(현재는 영문 사유 한 줄).
4. Ghostty와 cmux **동시 지원·자동 전환**은 이번 범위 밖이다.

### V11.8 이번 단계에서 하지 않은 것

- cmux 소켓 접근 **설정 변경**(`automation`은 이 기기의 기존 값이다), 인증 우회, cmux 수정·패치·포크
- **AppleScript로 우회 구현** — 객체 모델이 응답하지 않는다는 사실을 확인하고 경로 자체를 폐기했다
- GUI의 cmux 메뉴, 자동 전환 엔진, 프로젝트 편집 UI·위젯·새 실행 기능, Herdr 재조사, 타 터미널 Adapter
- cmux 실행은 **사용자 승인 후에만** 했다(V11.2). 기존 작업 중인 pane은 건드리지 않았다.

### V11.9 정정 — 이 절의 초안이 틀렸던 지점

이 절을 처음 쓸 때 나는 **공식 문서의 기본값만 보고** 두 가지를 추론했다. 실측이 둘 다 뒤집었다.

| 초안의 주장 | 실제 측정 | 뒤집힌 근거 |
| --- | --- | --- |
| "소켓은 바깥 프로세스에 닫혀 있다(기본 모드 cmuxOnly)" | **이 기기는 `automation` 모드이고 바깥 프로세스가 연결된다** | `capabilities.access_mode` = `automation`, `defaults read` = `automation`, `cmux ping` → `PONG` |
| "AppleScript가 유일한 공식 경로다" | **AppleScript는 객체 모델이 응답하지 않아 쓸 수 없다** | `count of windows` 등 6초 타임아웃, 전체 스크립트 34초 무응답 |

교훈을 기록한다: **접근 가능성과 지원 여부는 문서의 기본값으로 판단하지 말고 설치본에서 측정한다.**
`NSAppleScriptEnabled=true`와 사전 파일의 존재는 "동작한다"는 증거가 아니었다.

### V11.11 실제 사용자 세션 관측 (2026-09-17 14:35~14:47)

**cmux는 에이전트가 승인받아 실행**했고, 창 조작은 사용자가 했다.
기록은 `focus-probe --adapter cmux --watch --interval 1000`(hub 경유)로 남겼다.

| # | 시각 | 관측 | 등급 |
| --- | --- | --- | --- |
| B | 14:28 → 14:35 | **같은 surface**(`43007C41-…`, 세대 1 그대로)에서 경로가 `/Users/kangjingoo` → `…/Workspace/tool/PaneDock`로 바뀌었다 | 앱 자체 로그 |
| A | 14:42:38~14:42:51 | 포커스가 `BC4B2F4C-…`(tab `3F33A568`, `~/Workspace/Project_Ops_Copilot`) ↔ `EC998255-…`(tab `FAB34041`, 같은 경로) ↔ `43007C41-…`(tab `6D10FF4A`, `…/tool/PaneDock`) 사이를 **6회 전환**. 매 전환마다 **surface·tab 식별자와 경로가 함께 바뀌고 이전 값은 `previous`로 이동**했다 | 앱 자체 로그 |
| 규칙 2 | 14:42:58 | workspace 안에 새 surface `B36DA838-…`가 포커스됐다. `identify`는 새 surface를 알려주는데 `sidebar-state.focused_panel`은 **아직 이전 panel**을 가리켰다 → 연동이 **경로를 인정하지 않고** `unsupported`/`unknown`으로 표시했다. 2초 뒤(14:43:00) 새 panel이 반영되자 `valid`로 채워졌다 | 앱 자체 로그 |
| E | 세션 전반 | `frontmost false` + `focus held` + 경로 유지 | 앱 자체 로그 |
| E | 14:45~ | cmux가 최전면일 때 셸 실행에서 `frontmost true` + `tracked`, `lsappinfo front` = cmux와 **일치** | 에이전트 관측 |
| F | — | **브라우저 panel은 만들어지지 않았다**(3개 workspace 모두 `type=terminal`). 터미널이 아닌 panel은 실제 cmux에서 **미확인 유지** | 미확인 |

**규칙 2가 실제로 작동한 사례**가 이 세션에서 나왔다. `identify`와 `sidebar-state`가 서로 다른 시점의
panel을 가리키는 순간이 실제로 존재하고, 그때 이전 panel의 경로를 새 panel의 경로로 쓰지 않았다.

**B의 원인:** 경로 변경 자체는 관측됐지만 **`cd`를 누가 했는지는 사용자 확인을 받지 않았다.**
같은 surface·같은 세대이므로 그 pane의 cwd가 바뀐 것이고, 셸 제목도 새 경로를 담고 있었다.

#### 발견한 결함과 수정 (검사 99/99)

감시 프로세스를 TTY 없이 분리 실행한 문맥에서 `frontmost`가 `false`로 기록되는 구간이 있었다.
같은 시각 셸에서 실행한 조회는 `true`였고 `lsappinfo front`도 cmux를 가리켰다.
**원인을 규명하지 못했다** — 수정 후 재실행에서는 두 경로가 일치했고, 지금은 불일치가 없다.

다만 그와 별개로 `NSWorkspace.frontmostApplication`이 **nil일 때 `false`로 단정하던 코드는 명백히 틀렸다.**
nil은 "최전면이 아니다"가 아니라 "판정할 수 없다"인데, 그대로 두면 창이 **거짓으로 "유지 중"**이 된다.

수정: `FrontmostAppChecking.isFrontmost`가 `Bool?`을 돌려주고, 판정 불가면 `nil`로 두어
`focusStatus`가 `tracked`로 남게 했다(검사 1건 추가 — "최전면을 판정할 수 없으면 유지 중으로 단정하지 않는다").

#### 사용자 보고

> "cmux를 열었는데 PaneDock가 유지 중으로 되어 있어"

**설계대로다.** 현재 GUI는 Ghostty만 추적한다(V11.6). cmux가 최전면이면 Ghostty는 최전면이 아니므로
마지막으로 확인한 경로를 **"유지 중"**으로 표시한다. cmux 연동이 GUI에 붙으면 이 자리에 cmux 대상이 들어온다.

### V11.10 커밋 후보

| 구분 | 파일 |
| --- | --- |
| 커밋 대상 | `FocusProbeCore/*`, `FocusProbeCLI/*`, `docs/verification.md` |
| 제외 | `.omp/`(개인 설정), `.build/`·`dist/`(빌드 산출물, gitignore) |
| 포함하지 않는 것 | 자격증명, 셸 이력, 전체 환경변수, 진단 로그, cmux 설정 파일 |

## V12. 2026-09-17 — Ghostty와 cmux 둘 다 따라가기 (자동 선택)

### V12.1 배경과 결정

V11까지 GUI는 **Ghostty 전용**이었고 cmux는 CLI 실험 경로뿐이었다. 사용자가
"둘 다 잡을 수 있게"를 방향으로 확정했고, 선택 방식은 **auto(최전면 앱을 따라간다)** 로 정했다.

| 결정 | 내용 |
| --- | --- |
| 선택 규칙 | 최전면 앱이 목록의 호스트면 그 호스트 → 아니면 **마지막 호스트** → 아직 없으면 **기본 호스트(Ghostty)** |
| 둘 다 뒤에 있을 때 | 마지막 대상이 **"유지 중"**으로 남는다(새 규칙을 만들지 않고 기존 `held`를 그대로 쓴다) |
| 판정 불가 | 최전면을 **알 수 없으면**(nil) "최전면 아님"으로 단정하지 않고 위 2·3 규칙으로 내려간다 |
| 명시 선택 | `--adapter ghostty` / `--adapter cmux`로 고정할 수 있다(자동 전환 없음) |
| 조회 비용 | **고른 호스트 하나만** 조회한다. 다른 호스트가 꺼져 있어도 추적에 영향이 없다 |
| 실패 처리 | 고른 호스트의 조회 실패는 **그대로 보고**한다. 조용히 다른 호스트로 갈아타지 않는다 |

### V12.2 구현

| 파일 | 변경 |
| --- | --- |
| `FocusProbeCore/TerminalHostRouter.swift` | **신규.** 호스트 목록·최전면 판정·마지막 선택 기억. `TerminalHostAdapter`를 구현해 **프로브·반영·표시 코드를 그대로 재사용**한다 |
| `FocusProbeCore/CmuxAdapter.swift` | `FrontmostAppChecking`을 `frontmostBundleIdentifier()`로 확장(판정 불가 = nil), `isFrontmost`는 확장 메서드로 |
| `FocusProbeCore/GhosttyAdapter.swift` | `GhosttyAdapter.bundleIdentifier` 추가. `TerminalHostMapping`이 `factory`를 갖도록 이동 |
| `FocusProbeCore/ContextStore.swift` | `useFactory(_:)` — 표시 묶음을 **관측을 만든 Adapter의 factory**로 변환 |
| `FocusProbeCore/GhosttyAdapter.swift` (`SnapshotApplier`) | `apply` 시작에서 factory를 맞춘다(대상·사유 판정 전) |
| `FocusProbeCore/DockState.swift` | `hostAppID` 추가 |
| `PaneDockApp/LaunchOptions.swift` | `--adapter auto\|ghostty\|cmux`(기본 auto), `makeHostAdapter`(가짜 모드는 라우팅하지 않음) |
| `PaneDockApp/DockView.swift` | 헤더에 **현재 호스트** 표시, 상태 줄의 하드코딩된 "Ghostty 최전면" 제거 |
| `PaneDockApp/AppDelegate.swift` · `main.swift` | 시작 로그에 `adapter=`, self-check에 `adapter`/`host`/`cwdSource` 줄 |

**설계 요점:** 라우터는 **Adapter 하나처럼 동작**한다. `snapshot()`이 고른 호스트를 기억하고
이후 위임(`focusedRecord`·`records`·`noTargetReason`·`factory`·오류 문구)이 모두 그 호스트로 간다.
스냅샷과 레코드 변환이 다른 호스트에서 나오면 **다른 pane의 경로를 현재 대상으로 표시**하게 되므로,
`apply`가 매 관측마다 factory를 맞춰 신원(`adapterID`·`hostAppID`)과 경로 출처를 함께 바꾼다.

```
PaneDock --adapter auto      # 기본: 최전면 앱을 따라간다
PaneDock --adapter ghostty   # Ghostty만
PaneDock --adapter cmux      # cmux만
```

### V12.3 검증

#### 합성 검사 — 104/104 (기존 99 + 라우터 5)

| 검사 | 확인 내용 | 결과 |
| --- | --- | --- |
| 라우터 | 최전면 호스트를 따르고 **고른 호스트만** 조회한다(조회 횟수로 확인) | PASS |
| 라우터 | 둘 다 최전면이 아니면 **마지막 호스트를 유지**한다 | PASS |
| 라우터 | 최전면을 **판정할 수 없으면** 기본으로 시작하고 이후에는 마지막을 유지한다 | PASS |
| 라우터 | 고른 호스트의 실패를 숨기지 않고 **다른 호스트로 갈아타지 않는다** | PASS |
| 라우터 | 호스트가 바뀌면 **신원과 경로 출처가 함께** 바뀐다(`ghostty:terminal.workingDirectory` → `cmux:sidebar-state.focused_cwd`) | PASS |

#### 실제 관측 — 최전면이 cmux일 때 (에이전트 수행, 14:56)

| 모드 | display | host | cwdSource | 경로 | pane |
| --- | --- | --- | --- | --- | --- |
| **auto** | tracked | **cmux** | `cmux:sidebar-state.focused_cwd` | `…/tool/PaneDock` | `43007C41-…`(cmux surface) |
| `--adapter ghostty` | held | ghostty | `ghostty:terminal.workingDirectory` | `/Users/kangjingoo` | `54DBC13A-…`(Ghostty terminal) |
| `--adapter cmux` | tracked | cmux | `cmux:sidebar-state.focused_cwd` | `…/tool/PaneDock` | `43007C41-…` |

→ **auto가 최전면 앱(cmux)을 골랐고**, 호스트가 바뀌면 신원·경로 출처·대상이 함께 바뀐다.
`ghostty` 강제 모드가 `held`인 것은 Ghostty가 최전면이 아니기 때문이다(정상).

#### 실제 관측 — GUI (에이전트 수행, AX로 창에 그려진 텍스트 확인)

```
PaneDock startup: mode=live adapter=auto … catalog=loaded projects=2
EVENT refresh=1 display=tracked folder=PaneDock path=…/tool/PaneDock pane=43007C41-… project=-
화면:  상태: 추적 중   추적 소스: cmux   43007C41 · cmux 최전면
```

`metaText`에 **하드코딩된 "Ghostty 최전면"** 이 있어 cmux를 따라가면서도 Ghostty라고 표시됐다.
이번에 호스트 이름을 실제 값으로 바꿨다(위 화면은 수정 후 관측).

#### 미확인

| # | 항목 | 왜 |
| --- | --- | --- |
| 1 | **auto가 Ghostty를 고르는 실측** | 최전면이 Ghostty여야 하는데, 에이전트는 앱을 강제로 활성화하지 않는다. 규칙 자체는 합성 검사로 확인 |
| 2 | 터미널이 아닌 panel(F) | V11과 동일 — 실제 cmux에 브라우저 panel이 없었다 |
| 3 | 중첩 TUI·원격 경로 | 범위 밖 |

### V12.4 범위와 남은 것

- **메뉴로 런타임 전환은 넣지 않았다.** 소스는 실행 인자로만 고른다(재시작 필요). 필요해지면 별도 단계.
- **두 호스트를 동시에 조회하지 않는다.** 고른 하나만 조회하므로 비용이 늘지 않는다.
- V11의 미확인 2번(터미널이 아닌 panel)은 그대로 남는다.

## V13. 2026-09-17 — 자동 전환 실제 검증과 판정 불가 처리 보완

### V13.1 기준선 (V13 착수 시 실제 측정)

V12 기록의 해시를 그대로 옮기지 않고 이 시점에 다시 측정했다.

| 항목 | V12 최종(기록값) | **V13 착수 실측** | V13 최종 |
| --- | --- | --- | --- |
| HEAD | `f5a998a` | `f5a998a` (원격과 동일) | 미커밋 (V13.8) |
| 작업 트리 | — | 소스 변경 없음. 미추적은 `.omp/`뿐 | 아래 참조 |
| 자동 검사 | 104/104 | **104/104** | **110/110** |
| 코어 CLI | `3c12c18717a251eb` | **`0cff76874d0fd388`** | **`5509e7104cd01c72`** |
| 앱 번들 | `04e69d52ec6212c6` | **`04e69d52ec6212c6`** | **`b1407acf7499fba9`** |

앱 번들 해시는 V12 기록값과 일치했고(V13 착수 시 재빌드해 확인), 코어 CLI는 달랐다.
빌드마다 값이 달라질 수 있으므로 **해시는 같은 세션 안에서 비교할 때만** 근거로 쓴다(V11.1과 같은 결론).

### V13.2 [1] 판정 불가 처리 — 결함 1건을 찾아 고쳤다

**결함:** `hostFrontmost == nil`(최전면 판정 불가)이 `focusStatus = .tracked`로 매핑됐다.
즉 **포커스를 확인하지 못했는데 "추적 중"(확인 완료)으로 표시**했다.

V11.11은 `nil → false`(거짓 "유지 중")만 막았고, `nil → true`(거짓 "추적 중")는 남아 있었다.
지시하신 "nil을 최전면 확인 성공으로 취급해서도 안 된다"가 이 지점이다.

| 구분해야 하는 것 | 실현 수단 | 판정 불가일 때 |
| --- | --- | --- |
| **조회할 호스트 후보 선택** | `TerminalHostRouter`(최전면 → 마지막 → 기본) | 후보 선택은 정상 동작 — 마지막/기본 호스트를 조회한다 |
| **사용자가 보고 있는 호스트 확인** | `FrontmostAppChecking.frontmostBundleIdentifier()` | **nil을 확인으로 바꾸지 않는다** |
| **해당 대상의 경로 유효성** | `PathValidating` + `PathStatus` | 경로가 실제로 있으면 `.valid` 그대로 (포커스 불명과 무관) |

**수정(최소):**

| 파일 | 변경 |
| --- | --- |
| `WorkInfoFactory.currentWorkInfo` | 경로가 유효할 때 `hostFrontmost`가 nil이면 `.unknown`(기존 `FocusStatus` 값) — `tracked`로 승격하지 않는다 |
| `DockStateBuilder.make` | 경로 유효 + `.unknown` → 표시는 `held`, `detail`에 "포커스 확인 불가 — 마지막으로 확인한 대상을 표시 중입니다". 경로 유효성은 건드리지 않아 `missing`/`error`로 **오분류하지 않는다** |
| `DockView.metaText` | `"(호스트) 포커스 확인 불가"` — "비활성"이라고 단정하지 않는다 |

**기존 검사 3건이 `nil → tracked`를 가정하고 있었다.** 그 검사들의 관심사는 **전환·경로 승격 규칙**이므로
포커스를 명시(`hostFrontmost: true`)해 원래 의도를 유지하고, nil의 의미는 별도 검사로 분리했다.
검사 이름·기대값을 새 동작에 끼워 맞춘 것이 아니라 **관심사를 나눈 것**이다.

`.unknown`은 기존 `FocusStatus` 값이고 표시도 기존 `held`를 쓰므로 **상태 모델을 늘리지 않았다.**

### V13.3 [2] 호스트 경계 — 정보 혼합을 두 곳에서 막았다

**(a) 응답에 호스트를 붙인다.** `TerminalHostSnapshot.sourceIndex`(라우터가 설정)를 추가하고,
라우터의 위임(`focusedRecord`·`records`·`noTargetReason`)이 **스냅샷에 붙은 값을 먼저** 보게 했다.
응답을 받은 뒤 라우터 선택이 바뀌어도 그 응답은 원래 호스트로 변환된다.

**(b) 출처가 바뀌면 다른 대상이다.** `ContextStore.alignTarget(to:sourceID:)` + `currentSourceID`.
두 Adapter가 **같은 형태의 pane ID**를 줄 수 있으므로, 출처가 다르면 `FocusResolver.invalidateForSourceChange()`로
세대를 올려 **이전 출처의 늦은 응답을 폐기**하고 새 대상은 `pending`으로 시작한다.

**최전면 판정 출처 단일화:** 라우터가 스냅샷의 `frontmost`를 자기 판정으로 덮는다.
호스트 Adapter가 따로 판정하면 두 값이 어긋나 "확인된 포커스"와 "확인 불가"가 섞인다.

**유지한 규칙:** cmux `identify`와 `sidebar-state.focused_panel`이 어긋나면 **경로를 인정하지 않는다.**
workspace 요약 `cwd`나 이전 surface 경로로 대신 채우지 않는다(로그 `15:16:38`에서 `cwdSource=-`로 확인).

### V13.4 [3] 실제 auto 왕복 — A~G (사용자 조작, 에이전트가 상태 로그로 분석)

**하나의 PaneDock 프로세스**를 `--adapter auto --state-log`로 실행하고 사용자가 조작했다(로그 193줄).
아래는 그 로그의 전이와 사건이다.

| # | 요구 | 관측 (로그) | 판정 |
| --- | --- | --- | --- |
| **A** | Ghostty에서 프로젝트 A | `15:17:15 tracked host=ghostty cwdSource=ghostty:terminal.workingDirectory path=…/mac-tool-pack/egde-nochi pane=5D31DDD8 project=egde-nochi(2)` — 출처·terminal·CWD·프로젝트 일치 | ✓ |
| **B** | cmux에서 프로젝트 B | `15:17:14 tracked host=cmux cwdSource=cmux:sidebar-state.focused_cwd path=…/make-games/CodeMose pane=B36DA838 project=codemose(2)` — surface·focused_cwd·프로젝트 일치 | ✓ |
| **C** | Ghostty의 A로 복귀 | `15:17:27/29 tracked host=ghostty …egde-nochi pane=5D31DDD8 project=egde-nochi(2)` — **cmux·CodeMose 정보가 남지 않았다**(경로·pane·프로젝트 모두 Ghostty 것) | ✓ |
| (보너스) | 빠른 왕복 | `15:17:15`~`15:17:30` 사이 A↔B를 6회 오갔고 **매번 host·pane·경로·프로젝트가 함께** 바뀌었다 | ✓ |
| **D** | 각 호스트에서 링크 실행 | `15:17:40 EVENT link=repo project=codemose … url=https://github.com/kjg8619/CodeMose` (cmux) / `15:17:45·48 EVENT link=repo project=egde-nochi … url=https://github.com/kjg8619/egde-nochi` (Ghostty) — **표시 당시 프로젝트의 링크**가 열렸다 | ✓ |
| **E** | 외부 브라우저로 이동 | 링크 직후 `display=held`가 되었고 **pane과 경로가 그대로**였다(예: `15:17:49 held host=ghostty pane=5D31DDD8 path=…/egde-nochi`). 배경의 다른 대상으로 바뀌지 않았다 | ✓ |
| **F** | cmux 비터미널 panel | `15:18:09`~`15:18:14` 여섯 번의 조회 동안 `display=pending host=cmux path=- pane=- cwdSource=-` — **이전 터미널 경로를 붙이지 않았고**, 같은 구간에 `host=ghostty`로 바뀌지 않았다(**대체 없음**). 이 구간에 실행 이벤트 **0건**. `15:18:15` 터미널로 돌아오자 `tracked … CodeMose`로 **복구** | ✓ |
| **G** | 호출·잠금 중 호스트 전환 | `15:18:20 EVENT invoke frozenFrontmost=true focus=link:0 target=…/CodeMose` → `15:18:24 activate control=lock` → `display=locked host=cmux path=…/CodeMose locked=true` → (잠금 중 Ghostty로 전환됨) → `15:18:29 activate control=lock`(해제) → `display=tracked host=ghostty …egde-nochi` — **잠금 중 대상이 고정**되고, **해제 후 현재 포커스를 다시 확인**했다 | ✓ |

**A~G 전부 실제 조작으로 확인했다.** 관측하지 못한 항목은 없다.

### V13.5 [4] 자체 검사 — 110/110 (V12 104 + V13 6)

| 검사 | 확인 내용 | 결과 |
| --- | --- | --- |
| V13 | 최전면 판정 불가 + 최초 실행 → 기본 호스트를 **후보로만** 삼고 추적 중으로 표시하지 않는다(display `held`, detail 사유, 경로는 `.valid`) | PASS |
| V13 | 추적 중 판정 불가로 바뀜 → 경로 유지, 포커스만 확인 불가로 내린다 | PASS |
| V13 | **pane ID가 같아도** 호스트가 바뀌면 세대를 올려 이전 호스트의 응답을 폐기한다 | PASS |
| V13 | 비터미널 panel → 멈추고 다른 호스트로 대체하지 않으며, 터미널 복귀 시 복구한다(대체 호스트 조회 0회) | PASS |
| V13 | 다른 앱을 보는 동안 마지막 작업 대상을 유지한다(pane·경로 불변, 실행 가능) | PASS |
| V13 | 선택 중 호스트가 바뀌어도 실행 대상은 선택 시점 값을 유지한다 | PASS |

이 6건은 **합성 입력**이다. V13.4의 실제 관측과 등급을 섞지 않는다.
운영 앱 종료·TCC 초기화로 오류를 강제로 만들지 않았다.

### V13.6 요구된 결론

1. **두 호스트의 auto 왕복을 실제로 확인했는가?** — **예.** A(ghostty)·B(cmux)·C(복귀)를 한 프로세스에서
   순서대로 확인했고, 6회 빠른 왕복에서도 섞이지 않았다.
2. **판정 불가를 정상 추적으로 잘못 표시하는가?** — **수정 전에는 그랬다**(nil → `tracked`).
   수정 후에는 `unknown` + 표시 `held` + 사유 문구다. 합성 검사로 고정했다.
   실제 nil 상황은 실행 문맥에 따라 발생하며(V11.11), 이번 세션의 로그에서는 발생하지 않았다.
3. **비터미널 panel에서 안전하게 멈추고 복구하는가?** — **예.** 6초간 `pending`으로 멈추고
   경로를 채우지 않았으며, 다른 호스트로 대체하지 않았고(조회 0회), 실행도 0건이었고, 복귀가 정상이었다.
4. **표시 대상과 실제 실행 대상이 일치하는가?** — **예.** 링크 3회가 모두 표시 당시 프로젝트의 URL로 열렸고,
   잠금 중 호스트 전환에서도 실행 대상이 흔들리지 않았다.

### V13.7 남은 제약

- **cmux 연동 전제:** 이 기기의 `socketControlMode = automation`에서만 확인됐다.
  기본값(`cmuxOnly`)이면 바깥 프로세스는 연결할 수 없다. **다른 설치본에서도 그렇다고 표시하지 않는다.**
- **중첩 TUI·원격 경로**는 지원하지 않는다(V6 이후 동일).
- **여러 cmux 창/workspace 동시 운용**에서의 전환은 별도로 검증하지 않았다(단일 선택 대상만 확인).
- 상태 로그에 `detail` 문자열을 넣지 않아, 경로 미제공 순간의 **사유 문구**는 로그만으로 확정할 수 없다.
  (V13.4의 `15:16:38`은 `cwdSource=-`로 경로를 채우지 않은 것은 확인되지만, 사유는 추론이다.)
- 메뉴로 추적 소스를 바꾸는 런타임 전환은 없다(실행 인자만).
- 프로젝트 편집 UI·위젯·테마·새 Adapter는 이번에도 추가하지 않았다.

### V13.8 커밋 후보 (승인 대기)

| 구분 | 파일 |
| --- | --- |
| 커밋 대상 | `FocusProbeCore/{WorkInfoFactory,DockState,FocusResolver,ContextStore,GhosttyAdapter,TerminalHostRouter,SelfTest}.swift`, `PaneDockApp/{DockView,DockModel,StateLog}.swift`, `docs/verification.md` |
| 제외 | `.omp/`(개인 설정), `.build/`·`dist/`(빌드 산출물), `/tmp/pd-v13.log`(진단 로그) |

## V14. 2026-09-17 — 가로형 Dock UI 전환과 진단 화면 분리

### V14.1 기준선 (V14 착수 시 실제 측정)

V13의 기록값을 복사하지 않고 다시 측정했다.

| 항목 | V13 최종(기록값) | **V14 착수 실측** | V14 최종 |
| --- | --- | --- | --- |
| HEAD | `9a653f4` | `9a653f4` (원격과 동일) | 미커밋 (V14.6) |
| 작업 트리 | — | 소스 변경 없음. 미추적은 `.omp/`뿐 | 아래 참조 |
| 자동 검사 | 110/110 | **110/110** | **115/115** |
| 코어 CLI | `5509e7104cd01c72` | **`5509e7104cd01c72`** | **`0f4841b8e96d9a4a`** |
| 앱 번들 | `b1407acf7499fba9` | **`b1407acf7499fba9`** | **`bdc918d31ae463d9`** |
| 화면 | — | 1512×982, `visibleFrame` (0,90,1512,859) — 아래 90px가 macOS Dock, 위 33px가 메뉴 막대 | 동일 |

**스크린샷 권한:** `screencapture`가 **이미 허용돼 있었다**(새 권한 요청 없음). 창 단위 캡처(`-l <windowID>`)와
전체 화면 캡처를 모두 사용했다. `-R`(영역 지정)은 이 환경에서 `could not create image from rect`로 실패했다.

### V14.2 구현

**변경 범위(짧게):** ① 판정 불가일 때 **후보 경로를 실행 대상으로 승격하지 않도록** 코어 규칙 1건 보완,
② `DockView`를 가로형 바 + 상세 보기로 재작성, ③ 창 크기를 내용에 맞추는 계산(AppDelegate·ScreenGeometry),
④ 그리기 규칙(바 높이·너비·인라인 링크 수)을 코어 `DockBarLayout`으로 분리해 검사 가능하게.
**항목 편집·드래그 정렬·새 실행 기능은 넣지 않았다.**

| 파일 | 변경 |
| --- | --- |
| `FocusProbeCore/DockBarLayout.swift` | **신규.** 바 높이(76pt)·최소/최대 너비·칩 너비·인라인 링크 예산·창 높이 계산(순수 함수) |
| `FocusProbeCore/ContextStore.swift` | `hasConfirmedCurrentTarget` — 현재 대상이 **포커스 확인(true)을 받은 적 있는지** |
| `FocusProbeCore/DockState.swift` | 후보 경로 처리(아래)·진단 필드(`adapterID`·`cwdSource`·`connectionStatus`) |
| `FocusProbeCore/SelfTest.swift` | V14 검사 5건 추가 |
| `PaneDockApp/DockView.swift` | **재작성.** 가로형 바 + 상세 보기, 공통 칩 컴포넌트 |
| `PaneDockApp/DockModel.swift` | 상세 보기 상태·`hoveredItem`·이동 항목·레이아웃 알림 |
| `PaneDockApp/AppDelegate.swift` | 내용에 맞춘 창 크기, Esc가 상세 보기를 먼저 닫음, `--details`(진단) |
| `PaneDockApp/ScreenGeometry.swift` | 바 크기 계산 |

**화면 구성(요청한 순서 그대로)**
`[상태 배지] [프로젝트/폴더 이름 + 소스·짧은 상태] | [프로젝트 링크…] [+N] | [열기] [복사] | [잠금] [더보기]`
바 높이 76pt, 둥근 모서리 18pt, 반투명(`ultraThinMaterial`), 1pt 테두리, 그림자.
상세 보기는 **바 위로** 펼쳐지고 창은 아래쪽 좌표를 유지한다.

**설계 결정 2건 (이 환경의 제약과 결함)**
1. **SwiftUI `@State`를 쓸 수 없다.** 이 빌드 환경은 Command Line Tools만이라 `SwiftUIMacros` 플러그인이 없어
   `@State`/`@Binding`이 컴파일되지 않는다. hover 상태는 `focusedItem`과 같은 방식으로 **모델**이 들고 있는다.
2. **칩 라벨이 압축돼 사라지는 결함을 스크린샷에서 발견해 고쳤다.** 이름이 아주 길고 링크가 많을 때
   칩이 압축돼 아이콘만 남았다(조용한 잘림). 칩을 `fixedSize`로 고정하고, 이름 영역이 먼저 줄어들게 했으며,
   칩 폭 예산을 92 → 104pt로 **보수적으로** 잡아 인라인 수를 계산한다.

### V14.3 검증

#### 자동 검사 — 115/115 (V13 110 + V14 5)

| 검사 | 확인 내용 | 결과 |
| --- | --- | --- |
| V14 | 확인한 적 없는 **후보 경로**는 `pending`으로 두고 열기·복사 **불가**(경로는 `.valid` 유지) | PASS |
| V14 | 한 번 **확인된** 대상은 판정 불가가 되어도 `held`로 남고 실행 가능 | PASS |
| V14 | 링크가 많으면 인라인 수를 줄이고 **숨긴 개수를 알린다**(조용히 자르지 않음) | PASS |
| V14 | 바 너비가 화면 범위 안에 머문다(좁은 화면에서도 최소 너비 보장) | PASS |
| V14 | 항목이 없어도 주요 조작 영역이 뭉개지지 않는다(높이 계산 포함) | PASS |

#### 실제 화면 확인 (실행 앱 창 캡처 + 비전 모델 판독)

이미지는 `/tmp/pd-shots/`에 남겼다(저장소에 커밋하지 않는다). 실제 경로가 이미지에 그대로 보이므로
공유용으로 쓰지 않는다.

| 파일 | 상황 | 판독 결과 |
| --- | --- | --- |
| `S1-project.png` | 실연동 · Ghostty · 프로젝트 **Edge Notch** | `⏸ 유지 중` 배지 → `Edge Notch` / `ghostty · egde-nochi` → `저장소`·`이슈` → `열기`·`복사`·`잠금`·`더보기`. 겹침·잘림 없음. 제목 표시줄이 본문과 겹치지 않음 |
| `S2-details.png` | 같은 상태 + 상세 보기 | 상세 패널이 바 위에 펼쳐짐: `전체 경로` / `호스트·Adapter·연결` / `pane·포커스·확인` / `경로 출처` / `프로젝트 Edge Notch · 링크 2개` + 두 링크와 URL / `기준 폴더` / `숨기기`·`종료`. 잘림·겹침 없음 |
| `S3-fake-error.png` | **가짜 모드** 오류 | 붉은 `⚠ 오류` 배지, 제목 `대상 확인 중`, **`열기`·`복사`가 흐리게(비활성)**, `잠금`·`더보기`는 활성 |
| `S4-fake-many.png` | 가짜 + 임시 카탈로그(12링크) | 링크 5개 + 오버플로 칩, 오른쪽 4버튼 전부 보임, 화면 밖으로 나간 요소 없음 |
| `S5-long-name.png` / `S7-long-fixed.png` | 83자 이름 | 제목이 **중간 줄임**(`Company Internal Platf…ll Regional Teams 2026`), 부제 `ghostty · tmp · [FAKE]` |
| `S7-chips` 영역 판독 | 수정 후 | 5개 링크 라벨(저장소·이슈·문서·보드·디자인) + **`+7`** + `열기`·`복사`·`잠금`·`더보기` — **모든 칩에 라벨이 보인다** |
| `S6-fullscreen.png` | 전체 화면 | macOS Dock이 그대로 보이고 그 **위**에 바가 놓임. 바 내용이 Dock에 가려지지 않음. 바가 화면 밖으로 나가지 않음 |

**가짜 모드 구분:** 바 안의 붉은 `FAKE` 알약 + 부제의 `[FAKE]`로 구분한다.
(V13까지 있던 상단 빨간 배너는 바 디자인에서 제거했고, V14.7에서 창 제목 표시줄도 없어져
표시 수단이 바 안의 알약으로 옮겨졌다. 표시 자체는 유지한다.)

#### 창 배치·크기 (기하 실측)

| 확인 | 값 |
| --- | --- |
| 저장 위치 보존 | `settings.json` `windowOrigin = {x: 211, y: 159}` — 상세 보기 토글 **전후 동일** |
| 크기 변경 시 바 위치 | 바만: 창 y=728 h=95 (하단 823) → 상세: y=447 h=376 (하단 **823**) — **바가 제자리에서 위로 펼쳐진다** |
| 내용에 맞춘 너비 | 링크 0개 562pt → 링크 3개 **874pt**(= 372+190+3×104, 계산값과 일치) |
| 기본 위치(저장값 없음) | 화면 하단 왼쪽 +24pt(가짜 모드에서 확인: x=24, 하단이 macOS Dock 위) |
| 단축키 | `hotKey=⌃⌥⌘D hotKeyStatus=등록됨` |
| 화면 밖 보정 | 크기가 바뀌어도 `WindowPlacement.clamp`가 보이는 영역으로 되돌린다(기존 로직 유지) |

### V14.4 기존 동작 회귀

| 항목 | 상태 |
| --- | --- |
| Adapter·Router·경로 감지 | **변경 없음**(UI 때문에 복제하지 않았다) |
| `DockModel` 실행 검증 경로 | **변경 없음** — 바와 상세 보기의 모든 버튼이 `perform`/`openLink`를 그대로 쓴다 |
| 아이콘·라벨·실행 대상 일치 | 같은 `FocusItem`을 쓰고, 클릭 시점 값으로 계획을 만든다(기존 규칙) |
| 잠금·해제 | 그대로(`잠금` 칩 + 상세 보기) |
| 숨김·재표시·종료 | 상세 보기와 기존 메뉴 양쪽에서 접근 가능. 숨김은 여전히 다른 앱을 활성화하지 않는다 |
| 확인 불가·오류 표시 | 바에 즉시 보이고(아이콘+한글), 상세 보기에서 사유를 볼 수 있다. 애니메이션·동결로 숨기지 않는다 |
| Esc | 상세 보기가 열려 있으면 **그것부터** 닫는다(코드 경로 확인) |
| 마우스·키보드 | 같은 검증 경로(`source`만 다름) |

**에이전트가 하지 못한 것:** 마우스 클릭·키보드 입력으로 링크/폴더/복사를 실제 실행하는 것과
호스트를 오가며 프로젝트 영역이 바뀌는 장면은 **사용자 조작이 필요**해 이번 세션에서 실시하지 않았다.
GUI 자동 조작(합성 클릭)은 이번 범위에서 승인받지 않아 하지 않았다.

### V14.5 남은 제약

- **AX로 SwiftUI 내용이 노출되지 않는다.** 창·메뉴만 보이고 본문 텍스트가 AX 트리에 없어,
  화면 확인은 **스크린샷 + 비전 모델 판독**으로 했다(`V14.3`). 라벨 문자열 확인을 AX에 의존하지 않는다.
- **사용자 확인 필요:** 마우스·키보드 실행(기존 기능), 호스트 왕복 시 프로젝트 영역 변경,
  Esc로 상세 먼저 닫기, 잠금 중 전환. → 미실시로 남긴다.
- **항목 편집·드래그 정렬·앱 런처·위젯은 없다.** 없는 기능을 암시하는 버튼도 두지 않았다.
- **설정 파일 형식은 그대로다.** `settings.json`·`projects.json`에 새 키를 추가하지 않았다
  (`--details`는 실행 인자일 뿐 저장되지 않는다).
- cmux 연동 전제(`automation` 모드)와 중첩 TUI·원격 미지원은 V13과 같다.
- 스크린샷은 `/tmp/pd-shots/`에만 있고 **저장소에 커밋하지 않았다**(개인 경로가 그대로 찍혀 있다).

### V14.7 사용자 보고로 찾은 결함 — 창 크기 기준이 어긋나 바가 밀렸다

**사용자 보고:** "왕복하거나 더보기 후 닫기 하면 Dock가 자꾸 밑으로 내려가네"

**원인(실측):** 창을 `contentRect:`로 만들 때 `.titled` 때문에 **프레임이 19pt 더 컸다**
(요청 76 / 실제 95 = 76 + 제목 표시줄 19). 그런데 `applyPanelSize`는 **내용 크기(76)** 를
**프레임 크기(95)** 와 비교했으므로 **레이아웃이 일어날 때마다 매번 크기 변경이 발생**했고
(`layout want=1082x76 frame=562x95` → `resized`), 그 과정의 창 이동이 `windowDidMove`를 거쳐
**위치로 저장**됐다. 호스트 왕복·상세 토글은 모두 링크 수/높이 변화 → 레이아웃 호출이라 매번 반복됐다.

**수정(최소):**

| # | 변경 |
| --- | --- |
| 1 | 패널을 **테두리 없는 패널**(`.nonactivatingPanel, .borderless`)로 → 프레임 크기 == 내용 크기. 창 이동은 기존 드래그 영역이 담당한다 |
| 2 | 크기 비교·설정을 **프레임 기준 하나로 통일**하고, 크기 변경 시 **좌하단 좌표를 명시적으로 복원**한다 |
| 3 | **프로그램이 크기를 맞추며 생긴 이동은 저장하지 않는다**(`isApplyingLayout` + 0.75초 억제) |
| 4 | `layout` 이벤트를 상태 로그에 남겨 눈이 아니라 로그로 확인할 수 있게 했다 |
| 5 | 창 제목 표시줄이 없어져 가짜 모드 표시를 **바 안의 붉은 `FAKE` 알약**으로 옮겼다(부제의 `[FAKE]`도 유지) |

**재현 실험 (실제 앱에서 카탈로그 재로딩으로 링크 수 0 → 12 변경)**

| 상태 | 로그 | 창 | 하단 좌표 |
| --- | --- | --- | --- |
| 수정 전 | `want=1082x76 frame=562x95` → `resized frame=1082x76` | 95 → 76 (매 레이아웃마다 변경) | 775 |
| **수정 후** | `want=1082x76 frame=562x76` → `resized frame=1082x76` | 76 유지 | 775 → **775** |

**상세 토글(수정 후):** 바 `y=699 h=76`(하단 775) → 상세 `y=399 h=376`(하단 **775**).
**바가 제자리에 있고 상세 보기만 위로 펼쳐진다.** 시작 시에도 창 높이가 요청값과 같다(76, 제목 표시줄 없음).

**화면 확인:** `S8-bar-borderless.png`(제목 표시줄 없음·잘림 없음), `S9-details-borderless.png`,
`S11-fake-marker2.png`(흰 글씨 `FAKE` 알약이 온전히 보임). 모두 비전 모델 판독으로 확인했다.
`S8`은 **실연동 화면**이다(cmux · CodeMose — auto가 cmux를 골랐다).

**남은 확인:** 사용자가 같은 조작(왕복·상세 닫기)을 다시 해서 바가 밀리지 않는지 보는 것.
에이전트는 칩 클릭·호스트 전환을 직접 할 수 없어(합성 클릭 미승인) 재현은 링크 수 변경으로 했다.

### V14.6 커밋 후보 (승인 대기)

| 구분 | 파일 |
| --- | --- |
| 커밋 대상 | `FocusProbeCore/{DockBarLayout(신규),ContextStore,DockState,SelfTest}.swift`, `PaneDockApp/{DockView,DockModel,AppDelegate,ScreenGeometry,LaunchOptions}.swift`, `docs/verification.md` |
| 제외 | `.omp/`, `.build/`·`dist/`, `/tmp/pd-shots/`(스크린샷), `/tmp/pd-*.log` |

## V15. 2026-09-17 — Dock 항목 편집과 공통·프로젝트 구성

### V15.1 기준선 (V15 착수 시 실제 측정)

| 항목 | V14.7 최종(기록값) | **V15 착수 실측** | V15 최종 |
| --- | --- | --- | --- |
| HEAD | `2a25bd8` | `2a25bd8` (원격과 동일) | 미커밋 (V15.6) |
| 자동 검사 | 115/115 | **115/115** | **123/123** |
| 코어 CLI | — | `0f4841b8e96d9a4a` | (V15.6) |
| 앱 번들 | — | `fe33d92d63faa5a3` | (V15.6) |
| `projects.json` | — | **v1**, 프로젝트 2개 × 링크 2개 | 사용자 파일 무변경 |

### V15.2 구현 (변경 범위)

**코어** (`FocusProbeCore`)

| 파일 | 내용 |
| --- | --- |
| `DockItem.swift` (신규) | 항목 종류(app/folder/link)·`DockItem`·`ItemScope`·표시/실행용 `DockItemTarget`·형식 검증 |
| `Projects.swift` | 카탈로그 **v2**(`common` + `projects[].items`), **v1(`links`) 읽기 호환**, 항목 기준 검증·`fatalProblems` |
| `Projects.swift` (`save`) | **원자적 저장**(임시 파일→교체) + **원본 백업** + **내용 지문으로 외부 변경 충돌 감지** + 손상·미래버전 위 저장 거부 |
| `ProjectCatalogDraft.swift` (신규) | 초안 편집(추가·수정·삭제·드래그/키보드 정렬·프로젝트 추가), **범위 고정** |
| `Projects.swift` (해석·실행) | `ProjectResolution`이 **공통+프로젝트 항목**을 담는다(프로젝트가 없어도 생성) · `DockItemActionPlanner` |

**앱** (`PaneDockApp`)

| 파일 | 내용 |
| --- | --- |
| `ItemEditorView.swift` (신규) | **별도 편집창**: 범위 선택(공통/프로젝트), 항목 목록(드래그·↑↓·편집·삭제), 입력 폼(종류·이름·대상·파일 선택), 저장/취소 |
| `DockModel.swift` | 항목 기준 표시·실행(`performItem`), 편집 초안·폼·선택 상태, 저장 요청 위임 |
| `DockView.swift` | **공통 항목 | 프로젝트 항목 | 기본 조작** 순서, 앱은 실제 앱 아이콘, 구분선 |
| `AppDelegate.swift` | 편집창 창, 메뉴 "Dock 편집…", 저장 결과 반영(기존 재로딩 경로), 진단 플래그 |
| `LaunchOptions.swift` | `--editor`(편집창 열고 시작), `--editor-selftest <ms>`(초안 편집→저장 실증, 진단용) |

**넣지 않은 것:** 앱별 프로젝트 열기·터미널 명령 전송, 위젯, 테마, 새 Adapter, Herdr, 셸 명령 실행,
Dock 바 직접 드래그, Finder 외부 드롭, 프로젝트 삭제 UI.

### V15.3 검증

#### 자동 검사 — 123/123 (V14 115 + V15 8)

| 검사 | 결과 |
| --- | --- |
| 항목 추가·수정·삭제·정렬(키보드·드래그)이 초안에서 동작하고 범위가 섞이지 않는다 | PASS |
| 저장하면 재시작 후에도 복원되고, **저장 전·취소에는 원본이 그대로**다 | PASS |
| v1 파일을 읽고, 첫 저장에서 v2로 바꾸며 **원본을 백업**한다 | PASS |
| 손상·외부 변경·검증 실패에는 **저장하지 않는다**(외부 내용 보존) | PASS |
| 편집 중 포커스가 바뀌어도 **편집 대상은 고정**, 사용자가 고를 때만 바뀐다 | PASS |
| **공통 항목은 추적 상태와 독립적으로 실행**되고, 프로젝트 항목은 기존 규칙을 따른다 | PASS |
| 대상이 바뀐 항목은 거부하고, 순서만 바뀐 항목은 **같은 항목으로 실행**된다 | PASS |
| 항목 형식 검증(종류별 대상·빈 이름) | PASS |

#### 실제 앱 흐름 (임시 카탈로그에서, 에이전트 수행)

`--projects-path /tmp/pd-v15.json`(v1, CodeMose) + `--editor-selftest 4000`:

```
EVENT editor=open scope=common
EVENT layout want=666x76 frame=562x76 origin=(218,207)   ← 항목이 늘어 바가 넓어졌다
EVENT layout result=resized frame=666x76 origin=(218,207)
EVENT editor=save result=ok
```

| 확인 | 결과 |
| --- | --- |
| 파일 형식 | `schemaVersion 1 → 2` |
| 보존 | 프로젝트 이름·기준 폴더 유지, `links` → `items`(repo·issues, `.link`) **손실 없음** |
| 백업 | `pd-v15.json.bak-2026-09-17T07-27-10Z` 생성 |
| 즉시 반영 | Dock이 562 → 666pt로 넓어짐(항목 1개 추가) |
| **V14.7 보존** | 창 좌하단 `origin=(218,207)` 불변, 하단 775 고정 — 누적 이동 없음 |

#### 실제 화면 (창 캡처 + 비전 판독)

| 파일 | 판독 결과 |
| --- | --- |
| `V15-window-1.png` (편집창) | 제목 `Dock 편집`, **`편집 중: 공통 (모든 프로젝트)`**, 좌측 범위 목록(공통 1 / CodeMose 2), 새 프로젝트(이름·기준 폴더·추가), 항목 목록(드래그 핸들 + 폴더 아이콘 + `스크래치`), 하단 `저장`·`취소`. 잘림·겹침 없음 |
| `V15-dock-final.png` (Dock) | 배지 **`추적 중`(잘림 없음)** → `egde-nochi` / `cmux · egde-nochi` → 구분선 → `스크래치` → 구분선 → `열기`·`복사`·`잠금`·`더보기`. 잘림·겹침 없음 |

#### 화면에서 찾아 고친 결함 (V15)

1. **상태 배지가 압축돼 `유지...`로 잘렸다.** 배지에 `fixedSize`를 주고, 새 고정 영역(항목 칩·가짜 표시)에 맞춰
   `DockBarLayout.fixedWidth`를 372 → **448**로 올렸다. 수정 후 `추적 중`이 온전히 보인다.
2. 편집창은 정상이었지만, 저장 실패 시 결과 문구가 **라벨 없는 튜플**이라 컴파일되지 않아 라벨을 붙였다(구현 중 수정).

### V15.4 사용자 확인이 필요한 항목 (에이전트가 하지 않은 것)

GUI 자동 조작(합성 클릭·드래그·타이핑)은 이번에 승인받지 않아 **수행하지 않았다.**
그래서 아래는 **미실시**로 남긴다. 앱 내부 흐름은 진단 플래그로 실증했지만, **클릭·드래그 자체는 관찰하지 않았다.**

1. 편집창에서 마우스로 항목 추가·편집·삭제, 목록 드래그 정렬, ↑↓ 이동
2. `파일 선택…` 대화상자로 실제 앱(.app)·폴더 고르기
3. **저장** 후 Dock에 즉시 반영되는지, 앱 재시작 후 구성이 복원되는지
4. **취소**가 아무것도 바꾸지 않는지
5. 편집 중 외부에서 파일을 바꿨을 때 **충돌 안내**가 뜨고 덮어쓰지 않는지
6. 편집창에서 텍스트를 입력할 때 Dock의 Enter/Esc 처리가 **가로채지 않는지**
7. Slack·Finder 등 실제 앱 항목을 등록해 실행되는지

### V15.5 남은 제약

- **프로젝트 삭제 UI는 없다**(추가·이름/기준 폴더 수정만). 복잡한 프로젝트 관리는 만들지 않았다.
- **Dock 바에서 직접 드래그하거나 Finder에서 끌어놓는 것은 지원하지 않는다**(편집창 목록 안에서만).
- 저장은 **사용자가 저장을 누를 때만** 일어난다. 자동 검사는 임시 파일에서만 진행했다(실제 설정 변경 없음).
- 실시간 값(pane ID·CWD·추적 잠금)은 항목 설정에 **저장하지 않는다**.
- 항목 id는 UUID라 순서를 바꿔도 유지된다. v1 파일은 계속 읽을 수 있고, 첫 저장에서 v2로 바뀐다.
- cmux 연동 전제(`automation` 모드)와 중첩 TUI·원격 미지원은 V13과 같다.

### V15.7 사용자 보고로 찾은 결함 — 항목 id 중복 판정이 너무 넓었다

**사용자 보고:** "저장하면 항목 id가 중복이 된다고 하네."

**원인:** `ProjectCatalogValidator.fatalProblems`가 항목 id를 **카탈로그 전체에서** 고유하다고 요구했다.
그런데 실제 `projects.json`은 두 프로젝트가 **같은 링크 id(`repo`·`issues`)를 각각** 갖고 있었다.
v1의 `links`는 **프로젝트별로만** 고유하면 됐고(기존 로더도 그렇게 검사했다), V15에서 그 규칙을 바꾼 것이 결함이다.
표시·실행은 `(범위, id)`로 찾으므로 **범위 안에서만 고유하면 충분하다.**

**수정(최소):** `fatalProblems`를 **범위별 고유**로 바꿨다.

| 범위 | 규칙 |
| --- | --- |
| 공통 | 공통 안에서 고유 |
| 각 프로젝트 | **그 프로젝트 안에서만** 고유(다른 프로젝트와 같은 id 허용) |

`diagnostics`(경고)는 처음부터 범위별이었고, `fatalProblems`(저장 차단)만 넓었다.

**검사 추가(124/124):** "항목 id는 범위 안에서만 고유하면 된다(프로젝트가 다르면 같은 id 허용)" —
다른 프로젝트의 같은 id는 **허용**, 같은 프로젝트 안 중복은 **차단**을 함께 확인한다.

**실제 파일 내용으로 저장 검증(사본에서만):**

| 항목 | 결과 |
| --- | --- |
| 사용자 파일 사본(`/tmp/pd-real-copy.json`) | `editor=save result=ok` |
| 형식 | v1 → **v2** |
| 보존 | `egde-nochi: [repo, issues]`, `codemose: [repo, issues]` — **같은 id가 프로젝트별로 그대로 남았다** |
| 추가 항목 | `common`에 `스크래치`(folder) 1개 |
| 백업 | `pd-real-copy.json.bak-2026-09-17T07-37-11Z` |
| **원본 불변** | 사용자 실제 파일 해시 `6890ea939dcb4225` — 전/후 동일 |

### V15.6 커밋 후보 (승인 대기)

| 구분 | 파일 |
| --- | --- |
| 커밋 대상 | `FocusProbeCore/{DockItem(신규),ProjectCatalogDraft(신규),Projects,DockBarLayout,SelfTest}.swift`, `PaneDockApp/{ItemEditorView(신규),DockModel,DockView,AppDelegate,LaunchOptions,main}.swift`, `docs/verification.md` |
| 제외 | `.omp/`, `.build/`·`dist/`, `/tmp/pd-shots/`, `/tmp/pd-v15*.json*`(진단용 임시 파일) |

## V15.8. 2026-09-17 — 편집 사용 흐름 완결 (추가→정렬→저장→실행→재시작 복원)

### V15.8.1 기준선 (실측)

| 항목 | 값 |
| --- | --- |
| HEAD | `ebaa338` (원격과 동일), 작업 트리 깨끗(미추적 `.omp/`만) |
| 실행 중이던 앱 번들 | `5ce514a83139e579` — **V15.7의 범위별 id 수정을 포함**한 빌드였다(빌드 시점 확인) |
| **사용자 `projects.json`** | **v2**, `egde-nochi`/`codemose` 각 2항목 — **사용자가 직접 저장한 결과**이며 에이전트는 건드리지 않았다 |
| V15.8 최종 검사 | **128/128 checks passed** |
| V15.8 최종 코어 CLI | `c1ec699c5acc05f5` |
| V15.8 최종 앱 번들 | `5c97d8898ae0b1b7` |

### V15.8.2 추가한 자동 검사 (124 → 128)

| 검사 | 확인 내용 | 결과 |
| --- | --- | --- |
| V15.8 | 정렬·추가·삭제를 거쳐도 **기존 항목 id는 그대로**(새 UUID로 갈아치우지 않음) | PASS |
| V15.8 | **같은 id라도 범위가 다르면 실행하지 않고**, (범위·id)가 맞으면 실행한다 | PASS |
| V15.8 | 외부 변경 충돌은 알리고 덮어쓰지 않으며, 다시 읽은 뒤 재시도하면 **초안이 저장된다** | PASS |
| V15.8 | **두 프로젝트가 같은 id(`repo`·`issues`)를 써도 저장되고 양쪽이 보존된다** | PASS |

**검사 기대를 두 번 고쳤다(제품 결함이 아니라 검사의 잘못):**
① 지운 항목의 id까지 남아야 한다고 썼고, ② 충돌 후 재시도가 **병합**이라고 가정했다.
재시도는 초안을 그대로 저장하는 것이 맞고(그렇게 안내 문구를 명확히 했다), 지운 항목은 빠지는 것이 맞다.

### V15.8.3 실제 편집 사용 흐름 (임시 카탈로그에서, 진단 메서드 호출)

`--projects-path /tmp/pd-v158.json`(v1, 프로젝트 1개)로 실행하며 `--editor-selftest`로
**편집창과 같은 메서드 경로**(초안 열기 → 항목 추가 → 순서 변경 → 저장)를 호출했다.
**실제 클릭·드래그가 아니라 모델 메서드 호출임을 구분한다.**

| 단계 | 결과 |
| --- | --- |
| 항목 추가 | 앱(`터미널`)·폴더(`스크래치`)·링크(`예시`) 3개 추가 |
| 순서 변경 | 마지막 링크를 한 칸 위로 → 저장된 순서 `터미널, 예시, 스크래치` |
| 저장 | `editor=save result=ok`, 파일 **v1 → v2**, 프로젝트 항목(`저장소`) 보존 |
| Dock 즉시 반영 | `layout want=950x76` — 항목 3개로 바가 넓어짐(하단 고정 유지) |
| **재시작 복원** | 같은 임시 카탈로그로 다시 실행 → 창 `950x76`(같은 구성·순서) |
| **취소** | `editor=close result=cancelled` + 파일 해시 `eece68190b985548` **전/후 동일** |
| **V14.7 보존** | 추가·저장 구간에서 `origin` 불변(누적 이동 없음) |

### V15.8.4 화면 확인

| 파일 | 판독 결과 |
| --- | --- |
| `V15-window-1.png` | 편집창(제목·편집 중 대상·범위 목록·새 프로젝트·항목 목록·저장/취소) — V15에서 캡처 |
| `V158-dock-icon.png` / `V158-icon-zoom.png` | Dock 바: 배지 `추적 중` → 프로젝트 → 구분선 → **`터미널`(실제 Terminal 앱 아이콘: 어두운 사각형 + `>_`)** · `예시`(링크) · `스크래치`(폴더) → 구분선 → 기본 조작. 잘림·겹침 없음 |

**거짓 결함 하나를 스스로 잡았다:** 처음 캡처에서 앱 아이콘이 **일반 문서 글리프**로 보였다.
원인은 코드가 아니라 **테스트 데이터의 경로**였다 — `/Applications/Utilities/Terminal.app`는 이 macOS에
없고 실제 경로는 `/System/Applications/Utilities/Terminal.app`다. `icon(forFile:)`이 없는 경로에 대해
일반 아이콘을 돌려준 것이었다. **경로를 바로잡자 실제 Terminal 아이콘이 표시됐다.**
(재발 방지를 위해 아이콘 이미지를 템플릿으로 쓰지 않도록 `isTemplate = false`를 명시했다.)

### V15.8.5 아직 확인하지 못한 것 (에이전트가 하지 않은 것)

**GUI 자동 조작(합성 클릭·드래그·타이핑)은 승인받지 않아 하지 않았다.** 아래는 **미실시**다.

1. 편집창에서 **마우스로** 항목 추가·편집·삭제·**드래그 정렬**(메서드 경로는 실증했지만 드래그 제스처 자체는 미관측)
2. **파일 선택 대화상자**로 앱·폴더 고르기
3. 등록한 **앱 항목을 실제로 눌러 그 앱이 열리는지**(링크·폴더 실행도 같은 경로)
4. **한글 입력 조합 중 Enter**가 저장·실행으로 이어지지 않는지
5. 편집창 텍스트 입력이 Dock의 Enter/Esc 처리에 **가로채이지 않는지** — 코드 경로로는
   키 감시가 `panel.isKeyWindow == true`일 때만 동작하므로 편집창이 키 창이면 개입하지 않는다(설계 확인, 관측 아님)
6. 드래그 직후 항목이 실행되지 않는지(코드상 드래그는 `editorDrop`만 호출하고 실행 경로를 부르지 않는다 — 설계 확인, 관측 아님)

### V15.9 사용자 승인 후 실제 GUI 조작 (에이전트 수행, 2026-09-17 17:03~17:04)

사용자가 "너가 조작해봐"로 승인해, **임시 카탈로그**(`/tmp/pd-gui-test.json`, 공통 3항목 + 프로젝트 1항목)와
**임시 테스트 창**에서만 실제 마우스 이벤트를 보냈다. 실제 사용자 설정 파일은 건드리지 않았다.

| # | 조작 | 결과 | 등급 |
| --- | --- | --- | --- |
| 1 | Dock의 **앱 항목**(Finder)을 실제 클릭 | `EVENT item=a2 kind=app scope=common source=mouse result=allowed` + **최전면 앱이 Finder로 바뀜**(`lsappinfo front`) | **실제 클릭 관측** |
| 2 | 편집창 **저장** 버튼 실제 클릭 | `EVENT editor=save result=ok` + 백업 파일 생성 | **실제 클릭 관측** |
| 3 | 편집창에서 **3번째 항목을 1번째 자리로 드래그** | **순서가 바뀌지 않았다**(파일 순서 `a1, a2, a3` 그대로) | **실패(미확인)** |

**1번의 부수 확인:** Finder가 최전면이 된 뒤에도 Dock의 **공통 항목은 그대로 클릭돼 실행**됐다 —
공통 항목이 터미널 추적 상태와 독립적으로 동작한다는 V15의 규칙이 실제 조작에서도 확인됐다.

**3번은 실패로 남긴다.** 합성 마우스 이벤트(마우스다운 → 12단계 드래그 → 업)로는 순서 변경이 일어나지 않았다.
원인을 **확정하지 못했다** — 후보는 ① 내 좌표 추정이 행에서 벗어났을 가능성(행 위치를 AX로 얻지 못해
레이아웃 계산으로 추정했다) ② SwiftUI `onDrag`/`onDrop`이 합성 이벤트로는 시작되지 않는 가능성이다.
**"드래그가 제품에서 동작한다"고 기록하지 않는다.** 사용자가 실제 마우스로 확인해야 한다.

**정정(사용자 보고, 2026-09-17):** 사용자가 실제 마우스로 드래그해 **순서가 바뀌는 것을 확인**했다
("드래그 정렬 잘 되는데"). 따라서 위 3번의 실패는 **합성 이벤트 도구의 한계**이지 제품 결함이 아니다.
`onDrag`/`onDrop` 구현은 **실제 마우스에서 동작한다.**

등급을 구분해 남긴다: **제품 동작은 사용자 보고로 확인됐고**, 에이전트는 여전히 **직접 관측하지 못했다**
(합성 마우스 이벤트로는 SwiftUI 드래그 세션을 시작시키지 못했다). 도구를 더 파고들지 않고 여기서 멈춘다.
순서를 바꾸는 **다른 경로(↑↓ 버튼)**는 진단 메서드 호출로는 실증했지만, 그것도 클릭 관측은 아니다.

### V15.8.6 남은 제약

- 항목 id는 범위 안에서만 고유하면 된다(전역 고유를 요구하지 않는다).
- 프로젝트 삭제 UI·Dock 바 직접 드래그·Finder 드롭·앱 인자·프로젝트 자동 열기는 **없다**.
- 충돌 후 재시도는 **초안으로 덮어쓴다**(병합하지 않는다). 안내 문구에 그 사실을 명시했다.
- 실제 사용자 설정 변경은 **사용자의 저장 동작으로만** 일어난다. 자동 검사는 임시 파일에서만 했다.

## V15.10. 2026-09-17 — 편집창 정렬의 실제 동작 완결

### V15.10.1 V15.9의 검증 방법을 먼저 점검했다

V15.9는 **"드래그 후 파일 순서가 그대로"**를 실패 근거로 적었다. 그런데 이 앱은 **저장 전에는 초안만** 바꾼다.
당시 실제로 관측한 것을 다시 확인했다.

| 관측 항목 | V15.9에서 했는가 |
| --- | --- |
| 드래그 직후 **화면의 행 순서** | **하지 않았다** |
| 드래그 직후 **초안의 항목 ID 순서** | **하지 않았다**(초안을 볼 진단이 없었다) |
| 드래그 이후 **저장 버튼을 눌렀는가** | 눌렀다(실제 클릭, `editor=save result=ok`) |
| 저장 후 **파일의 항목 ID 순서** | 했다(그대로였다) |

즉 **중간 단계를 보지 않고 파일 결과만으로 실패를 단정**했다. 그 판단은 근거가 약했다.

### V15.10.2 원인 — 테스트 좌표가 행 사이를 찍었다

추측 좌표를 반복하지 않기 위해 **최소 진단 2개**를 먼저 추가했다.

| 추가 | 내용 |
| --- | --- |
| 편집창 행 AX 라벨 | `.accessibilityLabel("항목 N 종류 이름")` — 행 위치를 AX로 정확히 얻고, 보조기술에도 노출 |
| 드래그·이동 로그 | `editor=drag` / `editor=drop` / `editor=move` — **범위·항목 ID·변경 전후 순서만**(이름·URL 없음) |

그 결과 실제 행 좌표는 `y=250 / 274 / 298`이었고, V15.9에서 쓴 `y=291`은 **행 사이**였다.
→ **V15.9의 실패는 테스트 좌표 문제이며 제품 결함이 아니다.** (사용자 보고 "드래그 정렬 잘 되는데"와 일치한다.)

제품 코드는 **고치지 않았다**. 진단(라벨·로그)만 추가했다.

### V15.10.3 실제 조작 결과 (임시 카탈로그 A/B/C, 실제 마우스 이벤트)

| # | 조작 | 화면 순서 | 초안 순서 | 저장 파일 순서 | 재시작 결과 |
| --- | --- | --- | --- | --- | --- |
| ① | **C를 1행으로 드래그** | **씨/에이/비** | `before=A,B,C after=C,A,B` | **A,B,C**(저장 전이므로 정상) | — |
| ② | **저장 버튼 클릭** | 씨/에이/비 | (반영됨) | **C,A,B** | — |
| ③ | 같은 설정으로 **재실행** | 씨/에이/비 | — | C,A,B | **C,A,B 복원** |
| ④ | **↓ 버튼 실제 클릭** | **비/에이/씨** | `before=A,B,C after=B,A,C` | **B,A,C** | **B,A,C 복원** |
| ⑤ | **취소**(저장 안 함) | (편집 반영) | — | **해시 불변**(`417ac92048c95671`) · 순서 C,A,B 유지 | — |

**정렬 중 항목 실행 이벤트: 0건**(①④ 모두). 정렬은 순서만 바꾸고 실행하지 않는다.

**Dock 위치:** 정렬·저장·재실행을 거치는 동안 창이 `w=950 h=76 하단=826`으로 **변동 없음**(누적 이동 없음).

### V15.10.4 이번에 확인된 정렬 방법

| 방법 | 상태 | 근거 |
| --- | --- | --- |
| **드래그** | 실제 마우스로 동작 | ①드래그 로그 `before→after` + 화면 순서 변화 |
| **↑↓ 버튼** | 실제 클릭으로 동작 | ④`editor=move` 로그 + 화면·파일·재시작 일치 |
| 키보드(선택 후) | ④와 같은 경로 | 동일 함수(`editorMove`) |

### V15.10.5 검사·빌드

| 항목 | 값 |
| --- | --- |
| 자체 검사 | **128/128**(변동 없음 — 제품 로직을 바꾸지 않았다) |
| 변경 | 편집창 행 AX 라벨 · 드래그/이동 로그(진단)만 |
| 사용자 설정 | 무변경(`projects.json` v2 유지) |

### V15.10.6 사용자 확인 (2026-09-17)

사용자가 나머지 두 항목을 직접 확인해 **"2개 다 잘돼"** 라고 보고했다.

| 항목 | 상태 | 등급 |
| --- | --- | --- |
| **파일 선택 대화상자**로 앱·폴더 고르기 | **동작함** | 사용자 보고 |
| **한글 조합 중 Enter**가 저장·실행으로 새지 않음 | **동작함** | 사용자 보고 |

**에이전트는 이 둘을 직접 관측하지 않았다**(파일 선택 대화상자는 GUI 자동 조작 범위 밖, 한글 입력은 관측 수단 없음).
제품 동작은 사용자 보고로 확인됐고, 그 등급을 구분해 남긴다.

이로써 V15의 편집 사용 흐름(추가 → 정렬 → 저장 → 실행 → 재시작 복원 → 취소)에서
**사용자가 확인하지 않은 항목은 남지 않았다.**

새 Adapter·위젯·테마·Dock 바 직접 드래그는 추가하지 않았다.

## V16. 2026-09-17 — Dock 외형 커스터마이징 (크기·항목 표시·색상 모드)

### V16.1 기준선 (실측)

| 항목 | 값 |
| --- | --- |
| HEAD | `b895940` (원격과 동일) |
| 자체 검사(착수) | **128/128** |
| 자체 검사(V16 최종) | **131/131** |
| 앱 번들(최종) | `a0fbb8de32011c1b` |
| 사용자 설정 | `projects.json` v2(3+2항목, 사용자 편집분) · `settings.json` v1 — **둘 다 보존** |

### V16.2 구현

| 파일 | 내용 |
| --- | --- |
| `DockAppearance.swift` (신규) | 크기(작게 64 / 기본 76 / 크게 92pt) · 항목 표시(아이콘+이름 / 아이콘 중심) · 색상 모드(시스템/밝게/어둡게). **기본값이 지금까지의 외형** |
| `Settings.swift` | 스키마 **v2**에 `appearance` 추가. **커스텀 디코더**로 없는 필드는 기본값 |
| `DockModel.swift` | 저장된 외형 + **미리보기 외형**(`effectiveAppearance`), 저장/미리보기/버리기, `saveAll()` |
| `DockView.swift` | 바 높이·칩 여백을 외형에서, **아이콘 중심은 등록 항목의 라벨만** 줄인다(툴팁·접근성 이름 유지, 동작 버튼·상태 배지·프로젝트 이름은 그대로) |
| `ItemEditorView.swift` | **"모양" 영역**(항목 편집과 구분) 3개 선택기 + 미리보기 안내. 저장 버튼은 `saveAll()` |
| `AppDelegate.swift` | 패널 크기·**색상 모드(패널 외형)** 반영, 외형 저장 배선, 닫을 때 미리보기 버림 |

**미리보기·저장 규칙:** 설정을 바꾸면 **Dock에 즉시** 보이고 디스크에는 쓰지 않는다.
저장을 눌러야 `settings.json`에 기록되고, 취소하거나 창을 닫으면 **저장된 외형으로 돌아간다.**
`projects.json`(항목·순서·프로젝트)은 외형 변경으로 **전혀 수정되지 않는다.**

### V16.3 사용자 설정 파일을 손상시킨 결함 (발견·복구·수정)

**증상:** V16 구현 중 `appearance`를 `PaneDockSettings`에 추가했더니, **합성 디코더**가
없는 필드를 만나 **디코딩 실패** → 앱이 사용자의 `settings.json`을 **손상으로 판단해 백업으로 옮겼다**
(`settings.corrupt-2026-09-17T08-37-41Z.json`). 사용자 파일이 사라진 상태가 됐다.

**복구:** 백업 파일을 `settings.json`으로 **되돌렸다**(원래 값 `windowOrigin {279,156}`·단축키 그대로).
이후 실행에서 **새 손상 백업이 생기지 않았고** `settings=loaded`로 읽혔다.

**수정:** `PaneDockSettings`에 **커스텀 디코더**를 넣어 모든 필드를 `decodeIfPresent` + 기본값으로 읽는다.
이전 설정 파일에 새 필드가 없어도 **기존 모습으로 실행**된다. 이 수정이 자체 검사 2건(하위 호환·미래 버전 처리)을
동시에 통과시켰다(128 → **131/131**).

**교훈:** 설정 스키마에 필드를 추가할 때 합성 디코더를 쓰면 **기존 파일이 손상으로 보인다.**
이 앱의 "손상 시 백업" 정책과 결합하면 **사용자 파일이 사라지는** 결과가 된다.

### V16.4 검증

#### 자동 검사 (131/131 — V16 3건 추가)

| 검사 | 결과 |
| --- | --- |
| 외형 필드가 없던 설정은 **기본 외형**으로 실행된다(창 위치 보존) | PASS |
| 외형 저장은 **다른 설정(창 위치·단축키)을 덮어쓰지 않는다** | PASS |
| 세 크기가 서로 다르고(64/76/92), 아이콘 중심은 **라벨만** 줄인다 | PASS |

#### 실제 앱 화면 (임시 카탈로그 + 임시 설정 파일, 에이전트 수행)

| 파일 | 설정 | 창 크기 | 내용 |
| --- | --- | --- | --- |
| `V16-default.png` | 저장된 설정(기본) | `950×76` | 아이콘+이름, 기본 크기 |
| `V16-icononly-large.png` | 임시 설정 `size=large, labelMode=iconOnly` | `950×92` | **높이 92pt 반영**, 등록 항목 라벨 숨김(동작 버튼·상태·프로젝트 이름 유지) |

**미리보기는 저장하지 않는다:** 위 두 번째 실행은 `--settings-path`로 **임시 설정 파일**을 쓴 것이며,
사용자의 `settings.json`은 **변경되지 않았다**.

### V16.5 보존 확인

| 규칙 | 상태 |
| --- | --- |
| V14.7 프레임 기준 크기·프로그램 이동 미저장 | 유지(외형 변경도 같은 `applyPanelSize` 경로) |
| 항목의 범위·ID·대상 | 외형 변경과 무관(검사로 유지) |
| 추적·잠금·실행 검증·키보드 | 변경 없음 |
| 창 위치·단축키 | 외형 저장이 덮어쓰지 않음(검사) |

### V16.7 아이콘 중심 모드의 마우스 오버 설명 (사용자 요청 반영)

사용자 요청: **"아이콘 중심 모드에서는 아이콘만 나오게 하고 마우스 오버 시 설명"** — 크기·색상은 그대로 유지.

| 구현 | 내용 |
| --- | --- |
| 아이콘만 | 아이콘 중심 모드에서 등록 항목 칩이 **아이콘만** 그린다(실측 `34×34`, `33×30`, `32×32` — 라벨 없음) |
| **호버 설명(바)** | 마우스를 올린 항목의 **이름을 바의 두 번째 줄에 띄운다**(`앱 · 터미널`). 라벨이 없어도 무엇인지 확인할 수 있다 |
| 툴팁(이미 있던 것) | `앱 열기 — 터미널 (경로)` 형태의 네이티브 툴팁도 그대로 제공 |
| 접근성 이름 | `itemHelp`가 접근성 라벨로도 들어가 있다(이름을 숨겨도 보조기술에는 남는다) |
| 유지되는 정보 | 상태 배지(`유지 중`)와 프로젝트 이름(`egde-nochi`)은 아이콘 중심에서도 **그대로 보인다** |

**실측(임시 카탈로그 + 임시 설정 `size=large, labelMode=iconOnly`):**

```
AXButton desc=앱 열기 — 터미널 (…)     (327,805) 34x34   ← 라벨 없이 아이콘만
AXStaticText value=앱 · 터미널          (114,824)        ← 칩에 마우스를 올린 뒤 바에 뜬 설명
AXStaticText value=대상: egde-nochi     (114,807)        ← 프로젝트 이름은 유지
```

캡처: `V16-hover.png`(아이콘 중심 + 호버 설명).

### V16.8 "작게"가 76pt로 나오던 결함 — 원인과 수정

**증상:** `size=small`(64pt)로 실행해도 창이 **76pt**였다. 크게(92pt)는 정상이었다.

**진단(추측 대신 로그):** 시작 로그에 적용된 외형과 패널 크기를 남겼다.

```
settings=loaded … appearance=small/nameAndIcon panel=1054x76   ← 외형은 small인데 창은 76
appearance=large/nameAndIcon        panel=1054x92              ← 큰 값은 반영됨
```

**원인:** `ScreenGeometry.dockBarSize(linkCount:detailsVisible:barHeight:)` 호출이 **두 곳**인데
`makePanel`(창을 처음 만들 때)만 `barHeight` 인자를 넘기지 않아 **기본값 `DockBarLayout.barHeight`(76)** 를 썼다.
`applyPanelSize`(레이아웃 변경 시)만 새 외형을 넘기고 있었고, 시작 시에는 그 경로가 불리지 않으므로
**창이 76으로 만들어지고 그대로 유지**됐다. 92가 정상이었던 이유는 `minSize`(76)보다 큰 값이라 클램프가 없었기 때문이다.

**수정(한 줄):** `makePanel` 호출에도 `barHeight: model.effectiveAppearance.size.barHeight`를 넘긴다.
`panel.minSize`도 **가장 작은 외형**(64) 기준으로 바꿨다.

**수정 후 실측:**

| 설정 | 창 높이 |
| --- | --- |
| 작게 | **64** ✓ |
| 기본 | **76** ✓ |
| 크게 | **92** ✓ |

**교훈:** 같은 계산을 두 곳에서 부르면 **한 곳만 고쳐지기 쉽다.** 시작 로그에 결과값(적용 외형·패널 크기)을 남겨
눈이 아니라 값으로 확인할 수 있게 했다.

### V16.9 실제 편집창을 통한 모양 설정 흐름 완결 (2026-09-17)

**방법:** 임시 설정·임시 카탈로그(`/tmp/v169/*.json`)로만 실행하고, 편집창의 **실제 선택기·저장·취소 버튼**을
GUI 자동 조작으로 눌러 확인했다. 설정 파일을 직접 고쳐 재실행한 결과를 미리보기 성공으로 대신하지 않았다.
실제 사용자 설정(`~/Library/Application Support/PaneDock/`)은 **읽지도 쓰지도 않았다**(앱 실행 경로 자체를 임시 파일로 지정).

#### V16.9.1 빌드 식별자 (V16.1 → 최종)

| 항목 | 값 |
| --- | --- |
| V16.1 기록 | HEAD `b895940`, 검사 **128/128** → V16 최종 **131/131**, 앱 번들 `a0fbb8de32011c1b` |
| 최종 | HEAD `83f71f1` + **미커밋 수정 7개 파일**, 검사 **131/131**, 앱 번들 `8f149bf9adaff7bc` |

V16.1의 `a0fbb8de32011c1b`는 **V16.7·V16.8 이전** 값이다(그 뒤 커밋 `ac2875d`·`83f71f1`로 번들이 바뀌었다).
최종 번들은 V16.7(호버 설명)·V16.8(크기 결함 수정)과 이번 V16.9 수정을 모두 포함한다(`8f149bf9adaff7bc`).

#### V16.9.2 통과한 것 (실제 조작)

| # | 확인 | 결과 |
| --- | --- | --- |
| 1 | 선택기로 크기 변경 | `크게` 클릭 → 창 **1054×92** 즉시 반영, **저장 전 설정 파일 해시 불변** ✓ |
| 1 | 선택기로 항목 표시 변경 | `아이콘 중심` 클릭 → 칩이 **34×34 / 33×30 / 32×32**(라벨 없음) ✓ |
| 1 | 선택기로 색상 변경 | `어둡게` 클릭 → `appearance=preview … color=dark` ✓ |
| 2 | 취소 | `appearance=preview result=discarded` + `editor=close result=cancelled` → 창 **76**(저장값) 복귀, 파일 불변 ✓ |
| 3 | 저장 → 재실행 | 저장 후 `settings.json`에 `size=large, labelMode=iconOnly, colorMode=dark`, 재실행 로그 `appearance=large/iconOnly/dark panel=1054x92` ✓ |
| 4 | 밝게 → 시스템 | `color=light` → `panelAppearance=NSAppearanceNameAqua`, `시스템` → `panelAppearance=nil` ✓ (강제 색상 **남지 않음**) |
| 5 | 크기·상세 보기 반복(각 3회) | 하단 모서리 **862 고정**(92/64/76 모두 `y+h=862`), 상세 76↔376 왕복, 저장 위치 `origin=(300,120)` **그대로** ✓ |
| 5 | 잘림 | 도크 창(1054×64, 상세 1054×376) 안에 모든 도크 버튼이 들어옴 ✓ |
| 6 | 아이콘 중심의 호버 설명 | 칩에 마우스를 올리면 바의 둘째 줄이 `폴더 · 작업`으로 바뀜 ✓ (칩 접근성 설명은 `폴더 열기 — 작업 (/tmp)`) |
| 저장 | 모양만 저장 시 `projects.json` | **내용 동일(의미 비교)** ✓ — 파일은 기존 저장 경로가 다시 쓰지만 키 순서만 달라지고 값은 그대로(0바이트 차이) |
| 저장 | 창 위치·단축키 | `windowOrigin {300,120}`·`hotKey` 저장 전후 동일 ✓ |

#### V16.9.3 발견한 결함 3건과 최소 수정

**(1) 색상 모드가 시작 시 패널에 적용되지 않았다.**
`panel.appearance`를 **`applyPanelSize()`에서만** 설정해, 시작 로그가 `appearance=large/iconOnly/dark panelAppearance=nil`이었다.
레이아웃이 일어나야 색이 바뀌므로 **시작 화면은 시스템 색으로 남았다**(V16.8의 크기 결함과 같은 형태 — 두 경로 중 한 곳만 고쳐진 경우).
→ `makePanel`에서도 같은 값을 적용한다. 수정 후 `dark → NSAppearanceNameDarkAqua`, `light → NSAppearanceNameAqua`, `system → nil` ✓

**(2) 저장 실패를 "저장했습니다"로 보고했다(부분 성공도 전체 성공처럼 보였다).**
`SettingsStore.save()`가 결과를 돌려주지 않아, 쓸 수 없는 경로·지원하지 않는 버전에서도 `onSaveAppearance`가 **항상 성공**을 반환했다.
또 `saveAll()`은 모양 저장 실패 안내문을 항목 저장 안내문으로 **덮어써** 실패가 가려졌다.
→ `save()`·`update()`가 성공 여부를 돌려주고, `saveAll()`이 **저장된 것과 실패한 것을 구분**해 표시하며, 실패가 있으면 **창을 닫지 않는다.**

| 시나리오 | 결과(수정 후) |
| --- | --- |
| 지원하지 않는 버전 파일(v9)에 저장 시도 | `appearance=save result=failed`, 안내문 **"일부만 저장했습니다 — 저장됨: 항목 / 실패: 모양"**, **원본 파일 해시 불변** ✓ |
| 쓸 수 없는 디렉터리(권한 500) | `appearance=save result=failed`, **파일 생성되지 않음** ✓, 같은 안내문 ✓ |

**(3) 편집창을 닫기 버튼으로 닫으면 미리보기·초안이 남았다.**
편집창에 델리게이트가 없어 `cancelEditing()`이 불리지 않았다 → 창을 닫아도 **저장하지 않은 미리보기 외형이 Dock에 남았다.**
→ 편집창도 델리게이트로 받아, 저장하지 않은 초안·미리보기가 있으면 **취소와 같게** 정리한다.
수정 후 닫기 버튼 → `appearance=preview result=discarded` + `editor=close result=cancelled`, 설정 파일 불변 ✓

#### V16.9.4 보존 확인 (요청된 기준선)

| 보존 항목 | 확인 |
| --- | --- |
| 기존 설정에 `appearance`가 없어도 정상 로딩 | 유지(커스텀 디코더, 검사 통과) |
| small/normal/large = 64/76/92pt | 유지(수정 후 재측정 ✓) |
| 초기 창 생성과 이후 레이아웃의 **크기·색상** 기준 일치 | 이번 수정으로 색상도 일치 ✓ |
| 아이콘 중심의 호버 설명·툴팁·접근성 이름 | 유지 ✓ |
| 프로그램 크기 조절을 사용자 위치로 저장하지 않음 | 유지 — 반복 6회 후에도 `origin=(300,120)` ✓ |

#### V16.9.5 미검증·남은 제한

- **아이콘 중심에서의 키보드 선택(Tab/Enter)을 실제 키 입력으로 확인하지 못했다.**
  합성 단축키(`⌃⌥⌘D`)로 Dock을 호출하려 했으나 이벤트가 발생하지 않아(`invoke` 로그 없음), 초점 이동·실행 대상 일치를 **관측하지 못했다.**
  마우스 쪽은 확인했다(호버 설명 + 칩 접근성 설명 `폴더 열기 — 작업 (/tmp)`) → 항목→대상 연결은 그대로다.
- **모양과 항목을 함께 편집하는 경우**: 같은 저장 버튼이 두 파일을 함께 처리하는 것(`appearance=save result=ok` + `editor=save result=ok`)과
  한쪽만 실패할 때의 구분 표시는 확인했지만, 초안 **내용**을 바꾸는 편집(항목 추가·삭제)은 이번에 다시 만들지 않았다(V15에서 확인한 범위).
- **밝게 모드의 화면 인상**: 캡처에서 `밝게`(aqua)와 `시스템`이 다르게 보이는지 판단이 애매했다 → 사람의 확인이 필요하다(V16.9.6).
- 색상·크기의 **주관적 적절성**(64pt 클릭 편의, 밝게/어둡게 가독성)은 사람의 판단 몫이다.

#### V16.9.6 사람에게 확인받을 것

1. **크기** — 작게 64pt가 클릭하기 충분한가, 크게 92pt가 과하지 않은가.
2. **색상** — 편집창의 `밝게`를 눌렀을 때 Dock이 실제로 밝아 보이는가(어두운 채로 남는다면 추가 결함이다).
3. **아이콘 중심 + 호버 설명** — 바의 둘째 줄에 뜨는 이름이 충분히 읽히는가.

**테스트 데이터:** `/tmp/v169/*.png`(임시 카탈로그·임시 설정만 사용, 실제 사용자 경로·URL 없음).
`V169-dark-dock.png`·`V169-light-dock.png`·`V169-editor-dark-error.png`·`V169-details-open.png`·`V169-icononly-select.png`.

#### V16.9.7 사용자 확인 (2026-09-17)

사용자가 세 항목을 **모두 괜찮다**고 확인했다(크기 64/92 · 밝게 전환 · 아이콘 중심의 호버 설명).
따라서 V16.9.6의 2번(밝게가 실제로 밝아 보이는지)은 **사용자 확인으로 해소**됐다 — 에이전트 캡처만으로는 판단이 애매했던 항목이다.
같은 확인에서 커밋·푸시를 승인받아 이 수정을 기록했다.

## V17. 2026-09-18 — 자동 접기·재호출

### V17.1 기준선

| 항목 | 값 |
| --- | --- |
| 시작 HEAD | `4793e9f` (V16.9, 원격 동기화) |
| 시작 검사 | **131/131** |
| 최종 검사 | **139/139** (V17 8건 추가) |
| 앱 번들 | `a4cffb9b80211bac` → GUI 수정 후 재빌드 |

### V17.2 구현

| 파일 | 내용 |
| --- | --- |
| `DockCollapse.swift` (신규) | `DockDisplayMode`(항상 표시/자동 접기) · `DockCollapseContext` · `DockCollapsePolicy`(차단 사유·hover 판정·1초 기준) · `CollapseScheduler`(세대 토큰) |
| `DockAppearance.swift` | `displayMode` 필드. **없던 설정 파일은 `alwaysVisible`** 로 읽는다(커스텀 디코더) |
| `Settings.swift` | `save()`가 **내용이 같으면 쓰지 않는다** + `writeCount`(검사용) |
| `Projects.swift` | `save(_:)`가 **내용이 같으면 쓰지도 백업하지도 않는다** |
| `DockModel.swift` | `isCollapsed`·`setCollapsed`·`expandFromHandle`(호출 세션 없음) · `saveAll`이 **바뀐 것만** 저장하고 변경 없음/부분 성공을 구분 |
| `AppDelegate.swift` | 창 크기 계산을 `panelSize(for:)` 한 곳으로 통일(접힘 포함) · 추적 영역(`.inVisibleRect`) · 접기 예약/취소 · 마우스 업 재판단 · 명시적 숨김 플래그 · 앱 비활성 시 호출 세션 해제 |
| `DockView.swift` | 접힘 상태의 **호출 손잡이**(작게 남고 hover로 펼침) |
| `ItemEditorView.swift` | "표시 모드" 선택기 + **화면 가장자리 자동 숨김과 다르다**는 안내문. 선택기가 4개가 되어 **두 줄로 배치**(한 줄이면 창 밖으로 나간다 — 916pt > 800pt) |

**접기 규칙(첫 기준):** 마우스가 Dock·손잡이를 떠난 뒤 **약 1초**(`DockCollapsePolicy.delay`) 뒤에 접는다.
지연 시간 편집 옵션은 만들지 않았다. 다음 중에는 접지 않는다 —
마우스가 위 · 버튼 누름/창 드래그 · 상세 보기 · 편집창 · 메뉴·대화상자 · 단축키 호출 세션 · 사용자가 명시적 숨김 · 항상 표시 모드 · 이미 접힘.

### V17.3 자체 검사에 추가한 8건 (결정적)

| 검사 | 내용 |
| --- | --- |
| 표시 모드 기본값 | 없던 설정 파일 → `alwaysVisible`, 나머지 외형도 기본값 |
| 표시 모드 왕복 | `autoCollapse` 저장 → 재로드 유지 |
| 접기 기본 | 상호작용 없음 → 접는다 |
| 접기 금지 9가지 | 위 9가지 상태에서 `collapseBlock`이 사유를 돌려주고 접지 않는다 |
| 손잡이 hover | 접힌 자동 접기에서만 펼친다(항상 표시·숨김 제외) |
| 늦은 타이머 | 이전 토큰·취소된 토큰은 실행되지 않는다 |
| 접힌 크기 | 손잡이가 바 최소 크기보다 작다(보이지 않는 큰 창이 남지 않는다) |
| 저장 규칙 | 같은 값 저장은 `writeCount`가 늘지 않고 바이트도 그대로, 다른 값이면 는다 |

### V17.4 GUI에서 확인한 것 (임시 설정·임시 카탈로그)

| 확인 | 결과 |
| --- | --- |
| 표시 모드가 설정에서 로드됨 | 시작 로그 `appearance=regular/nameAndIcon/system/autoCollapse` ✓ |
| 마우스 추적이 동작함 | `mouse=entered`/`mouse=exited` 이벤트 발생 ✓ |
| 상세 보기 중 접기 차단 | `collapse result=blocked reason=details-open`/`mouse-inside` ✓ |
| 창 기하 일관성 | 접힘 크기 계산이 한 곳(`panelSize(for:)`)에서 나옴(코드) · 펼친 창 `1054x76`·상세 `1054x376` ✓ |

### V17.5 구현 중 고친 결함

1. **이탈 감지가 두 번 고쳐졌다.** (a) 추적 콜백 `mouseEntered/mouseExited`에 **`@objc`가 없어** ObjC 메시징이
   조용히 아무 데도 닿지 않았다(프로토콜 채택이 없으면 Swift는 자동으로 `@objc`를 붙이지 않는다).
   (b) `@objc`를 붙여도 `NSTrackingArea`가 **이 비활성 패널에서 enter/exit를 주지 않았다**(로그로 확인).
   → **추적 영역을 걷어내고 0.2초 주기로 마우스 위치만 확인하는 방식으로 교체**했다.
   전역 키 감시도 화면 읽기도 아니고, 우리 창 좌표와 마우스 위치만 비교한다(권한 불필요).
2. **편집창의 네 번째 선택기가 창 밖으로 나갔다.** 선택기 4개는 916pt가 필요해 800pt 창을 넘는다 → 두 줄로 배치.

### V17.6 확인하지 못한 것 (완료로 기록하지 않음)

- **마우스 이탈 → 자동 접기의 끝에서 끝까지 동작.** 추적 이벤트와 차단 사유는 확인했지만,
  이번 세션에서는 **실제 접힘 창(168x30)으로 바뀌는 순간을 관측하지 못했다.** 트리거 경로(이탈→예약→실행)를 계속 확인해야 한다.
- **단축키(⌃⌥⌘D) 호출과 그로 인한 키보드 실행.** 합성 단축키 이벤트가 앱에 도달하지 않았다.
  제품 결함으로 단정하지 않는다 — 메뉴(`Dock 호출/닫기`) 경로가 남아 있고, 필요하면 **사람의 실제 단축키 입력**을 받아 확인한다.
- 아이콘 중심 모드의 키보드 실행(V16.9에서 남긴 항목)도 같은 이유로 미확인.
- 명시적 숨김 후 복구(단축키·메뉴)와 "숨긴 동안 프로젝트가 바뀌어도 재호출 시 대상 일치"는 **이번에 관측하지 못했다.**
- **항목 실행(클릭)과 그 대상 일치**를 이번 접기 흐름에서 다시 확인하지 않았다(V16에서 확인한 실행 경로는 그대로다).
- 저장 규칙의 **파일 수준** 검사(내용 해시·백업 생성 여부)는 이번에 하지 못했다 —
  저장소 수준에서는 자체 검사로 고정했지만, 편집창에서 저장을 눌러 파일·백업을 직접 세는 검사는 남아 있다.

### V17.8 이탈 감지 교체 후 관측 (2026-09-18)

| 확인 | 실측 |
| --- | --- |
| 이탈 → 접힘 | 이탈 후 **0.77초**(측정 시작점 기준)에 창 `1054x76` → **`168x30`** · `collapse state=collapsed` |
| 손잡이 hover → 펼침 | 마우스를 손잡이로 옮기자 **즉시** `expand source=hover` · 창 `1054x76` 복귀(호출 세션·포커스 없음) |
| 반복(3회) | 접힘·펼침을 3회 반복해도 창 하단 좌표 **832 고정** — 아래로 누적 이동 없음 |
| 차단 사유 | `blocked reason=mouse-inside`(마우스가 위) · `details-open`(상세 보기) — 둘 다 로그로 확인 |
| 캡처 | `V17-collapsed.png`(168x30 손잡이) · `V17-expanded.png`(펼침) |

**이탈 판단 방식:** 0.2초 주기로 `panel.frame.contains(NSEvent.mouseLocation)`만 본다.
창이 숨겨져 있으면 기준값을 버려(`wasMouseInside = nil`) **숨긴 Dock을 마우스 움직임으로 다시 띄우지 않는다.**

### V17.9 기록 정정 — V17.4의 추적 이벤트 서술 (근거 없음)

V17.4에 "마우스 추적이 동작함: `mouse=entered`/`mouse=exited` 이벤트 발생 ✓"라고 적었다.
그러나 그 시점의 실행 기록에는 **그 이벤트가 남지 않았다**(같은 세션의 출력이 `이벤트: []`였다).
V17.5~V17.6의 "이벤트를 받지 못한다"가 실제 상태였고, V17.4의 한 줄은 **근거 없는 서술**이다.

| 항목 | 사실 |
| --- | --- |
| 어느 빌드였나 | `@objc` 추가 **전** 빌드(추적 영역 방식). 그 실행에서 추적 이벤트는 로그에 없었다 |
| 무엇을 봤나 | 차단 사유 로그(`reason=mouse-inside`)와 창 프레임뿐이다 — **이벤트 수신의 근거가 아니다** |
| 실제로 이벤트가 남은 때 | **폴링 방식으로 교체한 뒤**(`136af55`) — `mouse=exited`가 로그에 남는다 |
| 정정 | V17.4의 그 줄은 **미확인으로 되돌린다**. 기존 줄은 지우지 않고 이 절에서 정정한다 |

### V17.10 실제 입력 → 창 변화까지 (V17.8 완결, 2026-09-18)

**실행본:** HEAD `136af55` · 번들 `e32b2379dd9ba1f6`(소스와 일치) · 자체 검사 **139/139**.
자동 접기 + 아이콘 중심 + 크게(92pt) + 임시 설정·임시 카탈로그.

#### 트리거 경로 — 단계별로 전부 도달했다

```
mouse=exited
collapse result=collapsing
collapse state=collapsed
layout want=168x30 frame=1054x92 origin=(300,150) details=false panelAppearance=nil
layout result=resized frame=168x30 origin=(300,150)
```

| 단계 | 관측 |
| --- | --- |
| 이탈 감지 | `mouse=exited` (0.2초 주기 위치 확인) |
| 차단 조건 검사 | 차단 없음 → `collapse result=collapsing` (마우스 위·상세 열림이면 `reason=…`만 남고 접지 않는다) |
| 타이머 예약 → 실행 | 이탈 후 **0.92초**에 실행(기준 1초) |
| 접힘 상태 적용 | `collapse state=collapsed` |
| **실제 창 프레임** | `1054x92` → **`168x30`**, 기준 위치 `(300,150)` 유지 · 캡처 `V178-collapsed.png` |

**최소 크기 제한:** `panel.minSize`가 작게 모드 높이(64)였고 손잡이(30)보다 컸다 → 손잡이 기준으로 낮췄다(잠재 클램프 제거).
낮추기 전에도 실제 프레임은 `168x30`이었다(비활성 패널에서 `setFrame`이 minSize에 막히지 않음).

#### 손잡이 재호출

| 확인 | 결과 |
| --- | --- |
| 마우스를 손잡이에 올림 | **`1054x92`로 펼쳐짐**, `collapse state=expanded` · 캡처 `V178-expanded.png` |
| 호출 세션·포커스 | **`invoke` 이벤트 없음** ✓ (키보드 선택 세션을 시작하지 않는다) |
| 항목 위로 이동 | 이동 중 **`collapse` 이벤트 없음** ✓ (펼쳐진 뒤 다시 접히지 않는다) |
| 3회 반복 | 하단 좌표 **832 / 832 / 832 / 832 / 832 / 832** — 누적 이동 없음 ✓ |
| 저장 위치 | 임시 설정의 `windowOrigin (300,150)` 그대로 ✓ (프로그램 변경을 사용자 위치로 저장하지 않음) |

#### 클릭 영역

접힌 뒤 **옛 바가 있던 빈 영역**(접힌 창 밖)을 클릭 → 도크 이벤트 **없음** ✓, 창은 `168x30` 유지 ✓.
보이지 않는 큰 클릭 영역이 남지 않는다(창 자체가 168x30으로 줄어든다).

#### 이번에 확보하지 못한 것 (완료로 기록하지 않음)

| 항목 | 상태 |
| --- | --- |
| 항목 선택 → 실행 | 이번 클릭이 칩에 닿지 않아 `activate` 로그를 얻지 못했다(실행 경로 자체는 V15·V16에서 확인한 그대로) |
| 명시적 숨김 → hover/타이머가 다시 띄우지 않음 | 숨기기 버튼 좌표가 빗나가 **숨김이 일어나지 않았다**(그 사이 자동 접힘만 일어남) — 미확인 |
| 메뉴/단축키 호출 복구 | 합성 단축키가 앱에 도달하지 않는다. **사람의 실제 ⌃⌥⌘D 입력 1회**가 필요 |
| 아이콘 중심 키보드 선택·실행 | 위와 같은 이유로 미확인(V16.9 잔여) |
| 상세 보기·편집창·메뉴 중 접기 차단 | 상세 보기는 확인(`reason=details-open`), 편집창·메뉴는 이번 실행에서 만들지 않았다 |
| 접힌 동안 프로젝트 변경 → 펼칠 때 대상 일치 | `--fake toggle`로 조회는 계속 갱신됨을 확인했으나 **대상이 바뀌는 조건을 만들지 못해 약한 근거**뿐이다 |

### V17.11 키보드 호출 경로 (사용자 확인, 2026-09-18)

**증상(사용자 보고):** Dock에 포커스가 잡혀 있는데 **Tab·Enter·Esc가 먹지 않는다.**

**원인(코드 결함, 확인):** 키 모니터가 `panel.isKeyWindow == true`일 때만 키를 처리했는데,
패널에 `becomesKeyOnlyIfNeeded = true`가 걸려 있어 **`makeKeyAndOrderFront`가 무시되고 패널이 키 윈도가 되지 않았다.**
→ 모든 키가 `guard`에서 되돌아갔다.

**수정(2곳):**

```swift
panel.becomesKeyOnlyIfNeeded = false   // 명시적 호출(단축키·메뉴)에서 실제로 키 윈도가 된다
guard self.panel?.isVisible == true, self.editorWindow?.isVisible != true else { return event }
```

키 모니터 조건을 `isKeyWindow` → **"우리 패널이 보이고 편집창이 아닐 때"** 로 바꿨다(편집창의 Tab·Enter를 빼앗지 않게).
**hover로 펼치는 경로는 `makeKey`를 부르지 않으므로 입력 포커스를 빼앗지 않는 원칙은 그대로다.**

**확인(사용자, 새 빌드 `c6cbdfdb13068ee0`):** 접힘 → **⌃⌥⌘D** 펼침 → **Tab** 선택 이동 → **Enter** 실행 → **Esc** 닫기 — **모두 동작함**을 사용자가 확인했다.

**로그(임시 설정·임시 카탈로그):**

```
collapse state=collapsed
collapse result=blocked reason=already-collapsed
collapse state=expanded
invoke frozenFrontmost=true focus=item:0 target=/tmp
focus=item:1
collapse result=blocked reason=keyboard-session
focus=item:2
focus=item:3
focus=openFolder
focus=copyPath
focus=lock
focus=more
activate control=more source=keyboard
collapse result=blocked reason=keyboard-session
```

**부수 정리:** 진단용 `--invoke` 플래그는 추가했다가 **되돌렸다**(빌드를 깨뜨렸고 본질이 아니었다).

## V18. 2026-09-18 — 구성형 Dock: 기반(배치 모델·규격·너비 규칙)

이 절은 **실제로 실행한 결과만** 적는다. 승인된 화면 구성(타일·카드·프로젝트 영역 렌더)과
카드 실제 동작·편집기 배치 미리보기는 **아직 구현 전**이므로 여기에 성공으로 적지 않는다.

### V18.1 배치 모델·설정 (커밋 `9e301db`)

| 파일 | 내용 |
| --- | --- |
| `DockLayout.swift` (신규) | `DockComponent`(공통/카드/프로젝트 순서) · `DockCardKind`(시계/집중 타이머) · `DockCardSpec`(id·종류) · `DockLayout`(순서·영역 너비·카드 목록) + **관대한 디코더**(없던 설정 → 승인 기본 배치, 알 수 없는 값·빠진 구성요소 보정, 너비 240~620 클램프) |
| `Settings.swift` | 설정에 `layout` 필드(기본값·폴백) — 항목·ID·순서·위치·단축키는 기존 파일 그대로 |
| `DockBarLayout.swift` | 승인 규격 상수(바 **104** · 앱 타일 **68** · 프로젝트 타일 **48** · 카드 높이 **68**) |
| `DockAppearance.swift` | 크기 3단계를 104pt 기준으로 재정의(작게 92 / 기본 104 / 크게 116), 칩 여백 9/13/16 |

**실측(임시 설정 `/tmp/v169/v18.json`, `--fake steady`):** 시작 로그 `settings=loaded file=/tmp/v169/v18.json`,
창 **`1054×104`**(이전 76) — 캡처 `/tmp/v169/V18-widget-bar.png`.
이 화면은 **규격(높이·여백)만** 새 기준이고 **구성은 아직 이전 구조**(진단 블록·항목 칩·고정 버튼)다.

### V18.2 너비·넘침 규칙 (커밋 `2ea8cc3`)

| 함수 | 규칙 |
| --- | --- |
| `DockBarLayout.widgetBarWidth(layout:commonItemCount:screenWidth:)` | **저장된 배치의 순서가 너비를 정한다**(공통 타일 76 간격 · 카드 시계 104/타이머 168 · 프로젝트 영역 고정 폭). `allItems.count`로 다시 계산하지 않는다 |
| `DockBarLayout.projectTileBudget(width:tileCount:)` | 할당 폭을 넘는 항목은 `더보기`로 넘긴다(넘칠 때 `더보기` 자리를 하나 남긴다) |

**자체 검사 7건 추가 → 146/146:** 항목 수와 무관한 바 너비 · 기본 순서 · 카드 제거 시 폭 감소(카드 폭+간격) ·
넘침(2개→2/0, 8개→visible+hidden=8) · `layout` 없는 설정 호환 + 기존 값 보존 · 순서·너비(420)·카드 추가 저장·복원 · 좁은 화면 클램프.

### V18.3 구현 중 처리한 것

- **설정 스키마 가드 오탐**: 카드 종류의 저장 값이 `"clock"`이라 "설정에 잠금 상태를 저장하지 않는다" 검사가 `lock` 부분 문자열로 실패했다(138/139).
  **검사는 그대로 두고 값만 `"time"`으로 바꿔** 복구했다(기본 카드 id도 `time-1`).

### V18.4 아직 하지 않은 것 (V18.1~2 시점 기록 — 아래 V18.5~V18.8에서 처리)

| 항목 | 상태 |
| --- | --- |
| 승인된 구성 렌더(68pt 앱 타일 · 시계/타이머 카드 · 360pt 프로젝트 영역 + 내부 넘침 · 작은 `⋯` 메뉴) | **미구현** — 화면은 이전 구성 |
| 창 폭 계산을 `layout` 기반으로 교체(창 생성·리사이즈·상세 공용) | **미연결**(규칙 함수만 준비됨) |
| 카드 실제 동작(시계 초 갱신 · 타이머 시작/일시정지/재설정, 시각 기준, 카드 ID 메모리) | **미구현** |
| 편집기 배치 미리보기(순서·영역 너비·카드 추가/제거) | **미구현** |
| 프로젝트 A/B/미등록 전환 GUI 검증 | **미실시** |

### V18.5 표시 목록 단일화 (`DockDisplay`)

**회귀(고친 것):** 화면 1512 · 공통 3 · 프로젝트 2 · 영역 360에서 `DockView`는 `linkBudget`으로 **4**,
`DockModel`은 `projectTileBudget`으로 **5**를 봤다. 화면에 그리는 항목과 키보드가 도는 항목이 갈라져 있었다.

| 파일 | 내용 |
| --- | --- |
| `DockDisplay.swift` (신규) | `DockDisplay`(배치 순서의 화면 목록 + 밀린 수 + 영역 폭 + 바 폭 + 공간 부족) · `DockBarFit` · `DockBarLayout.barFit` · `DockDisplayBuilder.make` · `DockFocusPlan` |
| `DockItem.swift` | `DockItemRef`(범위 + ID) — 항목을 순번이 아니라 **신원**으로 가리킨다 |
| `DockBarLayout.swift` | 바 기하를 `barFit` 한 곳으로 모았다. **오른쪽 조작(상태 점 30 · `⋯` 메뉴 38 · FAKE 44)과 구분선 폭을 계산에 포함**(빠뜨려 오른쪽 조작이 창 밖으로 밀렸다). 시계 카드 104 → **152**(104에서는 날짜가 "9월…"으로 잘렸다) |

- 화면·숨김 개수·키보드가 **같은 구조**를 쓴다: `DockModel.display` 하나만 계산하고, `visibleItemCount` ·
  `hiddenItemCount` · `focusItems`(`DockFocusPlan.controls`)가 그 값을 그대로 쓴다.
- **호출 직후 첫 선택**(`firstAvailableItem`)도 표시 목록에서 고른다. 항목이 없으면 `⋯` 메뉴로 숨긴
  openFolder/copyPath/lock이 아니라 **화면에 있는 상태 점(.details)** 을 고른다.
- 실행 대상 검증은 그대로다: `DockItemActionPlanner`가 범위+ID로 찾고 "표시 중인 목록에 있는지"를 계속 확인한다.

**자체 검사(코어, 값으로 고정) — 새 18건 포함 161/161 통과:**

```
PASS 표시: 회귀(1512·공통3·프로젝트2·영역360)에서 5개를 보여주고 숨김이 없다 — 보이는=5 숨김=0 영역=360 바=1088
PASS 표시: 가짜 모드 표시·오른쪽 조작 폭이 바 폭에 포함된다 — 표시 없음=1088 표시 있음=1138
PASS 표시: 키보드 목록이 화면 목록과 같다 — 키보드=common/common-1..p-shop/item-2 화면=같음
PASS 표시: 영역을 넘긴 항목은 화면·키보드에서 함께 빠지고 상세 보기에는 있다 — 영역=360 보이는 프로젝트=5 숨김=3 상세=11개
PASS 표시: 프로젝트 항목이 2개든 6개든 바 폭·공통 타일 수가 같다 — 2개=1088/공통3 6개=1088/공통3
PASS 표시: 공간이 부족하면 영역을 줄이고, 그래도 모자라면 밀린 수를 남긴다 — 영역=240 공통 보임=0/숨김=12 바=804
PASS 표시: 영역을 줄여야 하는 경우도 공간 부족으로 드러난다 — 요청=620 → 적용=462 필요=1398 바=1240
```

### V18.6 승인된 배치 렌더 + 카드 실제 동작

- `DockView`를 `layout.order`대로 그린다: **공통 앱 타일 68 → 구분선 → 카드 → 구분선 → 프로젝트 영역(폭 고정)** → 오른쪽 `[FAKE] ● ⋯`.
  공통 앱과 프로젝트 항목은 **크기·모양이 다르다**(68pt 앱 아이콘 타일 / 48pt 폴더 이니셜·링크 타일). 폴더 색은 id로 정해 실행마다 같다.
- `DockCardViews.swift`(신규): **아날로그 미니 시계**(초 진행 링 + 시·분침) + 큰 `HH:mm` + `M월 d일 EEEE`,
  **집중 타이머**(남은 비율 링 + `mm:ss` + `▶ ❚❚ ↺`, 상태를 `집중 중/일시정지/끝남` 글자로도 표시).
- `FocusTimer.swift`(신규, 코어): 카드 id별 실행 상태. **남은 시간은 시작 시각으로 계산**하고(갱신 횟수 무관) 파일에 저장하지 않는다.
  `DockModel.timerStates`는 프로젝트 전환·접기·배치 변경에서 지우지 않는다.
- 값으로 고정한 검사(카드 8건): 시작 전 25:00 · 5분 뒤 20:00(갱신 무관) · 일시정지 후 불변 · 재개 시 이어짐 · 재설정 25:00 ·
  끝을 넘겨도 0 · 시각이 뒤로 가도 증가 없음 · 카드 id별 분리.

### V18.7 편집기 배치 연결

- 편집기에 **배치 미리보기**(실제 `DockDisplayBuilder`로 계산한 축소 바) · **순서**(공통/카드/프로젝트 영역 ↑↓) ·
  **영역 폭**(슬라이더 + `−/＋` 20pt) · **카드 추가·제거·순서**를 넣고, 저장은 모양·배치·항목을 한 번에 처리한다.
- 저장은 **바뀐 것만** 쓴다(`settings.update`가 같은 내용이면 파일을 건드리지 않는다). 실패하면 부분 성공을 그대로 알린다.
- 편집기 창이 내용보다 작아 **저장·취소 푸터가 잘리던 문제**를 고쳤다(가운데만 스크롤, 푸터 고정, 창 크기 명시).

### V18.8 실제 GUI 관측 (자체 검사와 구분)

환경: `--fake toggle/steady`, 임시 카탈로그·임시 설정(`/tmp/v18b/*`), 화면 1512×982pt(visibleFrame 1512×859).
관측 자료: 캡처 15장 + 상태 로그(`/tmp/v18b/keep/`). **여기 적은 값은 로그와 캡처에서 읽은 것이고, 검사 결과와 섞지 않는다.**

| 관측 | 결과 |
| --- | --- |
| 프로젝트 A(항목 2) / B(항목 8) 전환 | 상태 로그가 두 경우 모두 `area=360 bar=1138` — **바 폭·영역 폭 동일** |
| 공통 타일·카드 위치 | 캡처 `A3.png`(A) / `overflow-B2.png`(B): 공통 3타일·시계·타이머 카드가 같은 자리, 프로젝트 영역만 내용이 바뀜 |
| 프로젝트 영역 내부 넘침 | B(8개)에서 영역 안에 타일 5 + **`+3` 타일**, 영역 오른쪽 경계는 A와 동일(`overflow-B2.png`) |
| 시계 카드 | 11:05 → 11:25 실제 시각, `9월 18일 금요일`, 초 진행 링이 움직임 |
| 타이머 시작(▶ 클릭) | 로그 `card=focus-1 action=start remaining=25:00`, 화면 24:47 → 24:37 → 24:08 (실제 시각 기준) |
| **전환·배치 변경에도 유지** | A→B→A 전환, 배치 미리보기 변경, 배치 저장, 편집기 취소 후에도 22:54 → 23:49 → 24:25로 계속 진행(초기화 없음) |
| 일시정지/재개/재설정(❚❚ ▶ ↺ 클릭) | 로그 `pause remaining=22:09 running=false` → 5초 뒤에도 화면 22:09 → `start remaining=22:09` → 3초 뒤 22:06 → `reset remaining=25:00 running=false`(화면 25:00, 회색) |
| 키보드 목록 = 표시 목록 | 호출 후 Tab 10회: `c1 → c2 → c3 → b1 → b2 → b3 → b4 → b5 → details → c1` — **밀린 b6~b8로는 가지 않는다**(표시 목록 8개와 일치) |
| 호출 직후 첫 선택(항목 0개) | 로그 `invoke ... focus=details` → Tab → `focus=hide` → Enter → `close`(보이는 조작만 순회) |
| 미등록 경로 | 프로젝트 영역이 **주황 실선 + "tmp · 등록된 프로젝트가 없습니다" + `+` 타일**, 공통·카드·타이머는 그대로 사용 가능(`unregistered.png`). `+` 클릭 → `editor=open scope=common` |
| 항목 0개(빈 카탈로그) | 공통 구역이 사라지고 바 폭이 줄어듦(`bar=893`), 카드·영역·오른쪽 조작은 유지(`empty-catalog.png`) |
| 배치 순서 변경 | 편집기 ↑ 클릭 → `layout=preview order=common,project,cards` → 바가 즉시 그 순서로 렌더(`order-changed.png`), 타이머 계속 |
| 영역 폭 + 공간 부족 | `+` 13회 → `area=620` 요청 → `area=462 bar=1240 short=true`, 편집기에 "지금 배치가 화면보다 넓어 영역이 462pt로 줄어 있습니다", `⋯` 메뉴에 "공간 부족 — 배치가 화면보다 158pt 넓습니다"(`editor-short.png`, `menu-open2.png`) |
| 저장(배치) | `layout=save result=ok` · `editor=save result=ok saved=1 unchanged=1` → `settings.json`의 `order`만 바뀌고 `projects.json`은 **수정 시각 그대로**(쓰지 않음) |
| 취소 | `editor=close result=cancelled` 후 바가 저장된 배치로 돌아오고 타이머는 22:54로 계속(`after-cancel.png`) |
| 창 폭 = 계산 폭 | 시작 로그 `panel=1138x104` = 코어 검사 값 `표시 있음=1138` (SwiftUI 고유 크기가 창을 끌고 가던 문제 수정 후) |

**하지 않은 관측:** 편집기의 **카드 추가·제거 버튼**은 실제로 클릭하지 않았다(버튼이 보이고 미리보기 계산이 반영되는 것은 캡처로 확인).
`Escape`가 패널을 닫는 동작은 이 환경에서 세션 종료(`applicationDidResignActive`)와 겹쳐 자동 조작으로 재현하지 않았다.

### V18.9 정리한 것

- 칩 시절 배치 규칙(`linkBudget` · `barWidth(visibleLinkCount:)` · `maximumWidth` · `fixedWidth` · `linkChipWidth` ·
  `projectAreaMinimumWidth` · `DockBarLayout.barHeight=76` · `ScreenGeometry.dockBarSize` · `DockSizeSetting.chipVerticalPadding`·
  `minimumItemAreaWidth`)과 그 검사(V14 묶음)를 **삭제**했다. 위젯 화면이 쓰지 않는 두 번째 배치 규칙을 남겨 두면
  같은 종류의 불일치가 다시 생긴다(V18.5의 회귀가 그 예).
- 상수 개수보다 중요한 것: 화면에 그릴 목록을 정하는 곳이 하나가 됐고, 그 값이 창 폭·숨김 수·키보드 목록에 그대로 쓰인다.

### V18.10 키보드 이동 확장 (타이머 조작·보조 메뉴·등록/넘침)

`DockFocusPlan`이 **배치 순서대로** 조작을 만든다: 항목 타일 → (카드 구역이면) 타이머 `▶ ❚❚ ↺` →
밀린 수 타일(`+N`) → 미등록이면 등록 `+` → 오른쪽 `상태 점 → ⋯ 메뉴` → (상세 보기가 열렸으면) 숨기기·종료.

| 조작 | 실행 경로 |
| --- | --- |
| 타이머 버튼 | `DockFocusControl.timer(cardID:action:)` → `DockModel.performTimer` (마우스 클릭과 **같은 함수**) |
| `⋯` 메뉴 | `showActionMenu` — **NSMenu 하나**를 마우스·키보드가 함께 연다(SwiftUI `Menu` 제거). 버튼 자리는 화면이 모델에 알려준다 |
| `+N` 타일 | `showDetails()` (밀린 항목·카드 상태를 상세 보기에서 확인) |
| 등록 `+` | `openEditor()` |

**메뉴가 떠 있는 동안에는 키 입력을 가로채지 않는다**(`isMenuTracking`) — 그러지 않으면 Enter/Esc를 메뉴 대신
우리가 먹어 메뉴를 고를 수 없다(구현 중 발견).

자체 검사 4건 추가(총 **169/169**): 키보드 목록 = 화면 목록 + 타이머 3버튼 + `details,menu` 순서 ·
배치를 `카드 → 공통 → 프로젝트`로 바꾸면 **조작 순서도** 바뀜 · 미등록 경로에서 등록 조작 포함 · 밀린 항목 타일 포함.

### V18.11 표시 방식(labelMode) 연결

| 모드 | 앱 타일 | 프로젝트 항목 | 확인 |
| --- | --- | --- | --- |
| 아이콘+이름 | 68pt 타일 **안에 이름**(아이콘 40→34) | **112pt 칩**(아이콘+이름) | `shots/1-names-A.png`, `shots/3-names-6.png` |
| 아이콘 중심 | 아이콘만 | 48pt 타일 | `shots/2-icononly-A.png` |

- 기하가 모드에 따라 달라진다: 같은 6개 항목이 `아이콘 중심`은 6개 전부, `아이콘+이름`은 1개 + `+5`(로그·캡처로 확인).
- 표시 방식을 바꾸면 표시 목록을 다시 만든다(`applyAppearance`·`previewAppearanceChange`·`discardAppearancePreview`).

### V18.12 타이머 완료(00:00) 상태와 카드 상태 규칙

- `FocusTimerState.statusText/ isRunning(at:)` — **끝난 타이머는 흐르지 않는 것으로 본다**. `complete(at:)`이 00:00에서 확정한다.
- 완료 화면: 문구 `끝남`(주황), `00:00`, 진행 링 비움, **▶가 ↻(처음부터 다시 시작)로 바뀌고 ❚❚는 꺼짐** (`shots/7-timer-running.png` → `shots/8-timer-done.png`).
- 카드 삭제 뒤 새 추가: 모델이 **이번 실행에서 쓴 id 전체**(`usedCardIDs`)를 기억해 같은 id를 재사용하지 않고,
  저장된 배치에 없는 카드의 실행 상태는 저장 시 버린다(`card=prune`). 재배치·취소 복원은 id가 그대로라 상태가 유지된다.
- 자체 검사 4건 추가: 완료 상태 문구·재시작 · 완료 확정 후 0 고정 · 지운 카드 id 재사용 금지 · id별 상태 분리.

### V18.13 카드 넘침 (카드가 화면보다 많을 때)

양보 순서: **프로젝트 영역 축소 → 카드 밀어내기 → 공통 타일 밀어내기**(공통 앱은 마지막까지 남긴다).

실측(`settings-cards8.json`, 타이머 카드 8개, 화면 1512): 로그 `shown=5 hidden=0 common=3/0 project=2/0 area=240 bar=1112 short=true`,
화면은 **앱 3 + 타이머 2 + `+6` 타일 + 영역(240) + 오른쪽 조작**(`shots/5-cards-8.png`).
밀린 카드의 상태는 상세 보기 `카드` 줄에 남는다: `타이머 25:00 집중 타이머 (밀림) …`(`shots/6-details.png`).

### V18.14 시안 반영과 남은 것

시안(`docs/design/v18-widget-layout.html`)의 요소를 코드로 구현했다 — 앱 타일(색 그라디언트 + 실제 아이콘 + 실행 중 점),
`⋯` 메뉴 버튼 40pt·반경 12, 폴더(색+이니셜)·링크 타일, 카드(시계·타이머). **시안 이미지를 에셋으로 붙이지 않았다.**

**관측 방법과 한계(중요):** 이번 관측은 세션 화면이 **잠긴 상태**에서 창 단위 캡처(`screencapture -l <windowID>`)로 찍었다.
그래서 유리 재질이 바탕화면과 합성되지 않아 바 배경이 어둡게 나온다. 배치·크기·문구·상태는 실제 렌더 결과 그대로다.

**이번에 하지 못한 관측(화면 잠금):** 키보드 Tab/Enter·마우스 클릭·`⋯` 메뉴 열기, 편집창에서 카드 추가/제거 클릭,
표시 방식 전환 클릭. 실행 스크립트는 `/tmp/v18c/check-gui.sh`에 준비돼 있고, 화면이 풀리면 그대로 돌린다.

### V17.7 보존 확인

| 규칙 | 상태 |
| --- | --- |
| 표시 여부와 추적 분리 | `setCollapsed`가 추적·잠금·대상 선택을 건드리지 않음(코드) |
| 위치 보존 | 접힘·펼침 모두 `applyPanelSize` 경로(하단 고정). 프로그램 변경은 `isApplyingLayout`으로 사용자 위치 저장에서 제외 |
| 클릭 가로채기 | 접힌 창은 손잡이 크기(168x30)로 실제로 줄어든다(자체 검사) |
| 명시적 숨김과 자동 접기 구분 | `isUserHidden` — 타이머는 다시 띄우지 않는다(코드) |
| 시스템 변경 없음 | 기본 Dock·시스템 설정을 건드리지 않음. 새 권한·라이브러리 없음 |

**테스트 데이터:** `/tmp/v169/*.png`(임시 카탈로그·임시 설정만 사용, 실제 사용자 경로·URL 없음).

### V16.6 남은 제한·미확인

- 세 크기의 **실제 사용감**(64pt가 충분히 클릭 가능한지, 92pt가 적절한지)은 **사람의 판단**이 필요하다.
- 아이콘 중심 모드에서 **이름 없이 항목을 구분**할 수 있는지는 사용자 확인이 필요하다.
- 색상 모드(밝게/어둡게)의 **화면 확인은 하지 않았다**(임시 설정으로 켤 수 있으나 캡처하지 않았다).
- 편집창 "모양" 영역의 실제 클릭 조작은 하지 않았다(임시 설정 파일로 렌더를 확인했다).
- 새 Adapter·Herdr·위젯·자동 숨김·확대 효과·Dock 바 직접 드래그·Finder 드롭은 추가하지 않았다.

---

## 정정 이력

- **2026-09-17 (V16):** 설정 스키마에 `appearance`를 추가하며 합성 디코더를 쓴 탓에 **기존 `settings.json`이 손상으로 판정**돼
  백업으로 옮겨졌다. 백업을 원래 자리로 **복구**했고, 커스텀 디코더(없는 필드는 기본값)로 고쳤다. 자세한 내용은 V16.3.


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
