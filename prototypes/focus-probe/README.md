# focus-probe — PaneDock 진단 프로토타입

현재 포커스된 terminal의 **식별자와 작업 경로**를 읽고, **출처·연결 상태·마지막 확인 시각**을
보여주는 최소 진단 도구다. Dock UI는 만들지 않았다.

| 경로 | Adapter | 상태 |
| --- | --- | --- |
| **정상** | `ghostty` (기본) | Ghostty 공식 AppleScript. **지원 범위** |
| 실험 | `herdr` (`--adapter herdr`) | **지원 범위 밖.** 조사·재현용으로만 보존 |

Herdr를 제외한 이유는 `docs/scope-decisions.md` D1에 있다. 요약: 원격 SSH 클라이언트가 붙으면
서버 전역 `focused_pane_id`가 그쪽을 따라가고, 클라이언트별 포커스를 읽는 공식 API가 없다.
Herdr 자체 수정 없이는 로컬 귀속을 확정할 수 없다.

## 요구 사항

- macOS, Command Line Tools (Xcode 불필요 — `swiftc`/SwiftPM만 사용)
- Ghostty 1.3.0 이상 (AppleScript 지원 도입 버전). 확인한 설치본: 1.3.1
- macOS 자동화(Automation) 승인 — 이 Mac에서는 이미 승인되어 있었다

## 빌드와 실행

```bash
cd prototypes/focus-probe
swift build

swift run focus-probe --once                  # 1회 진단 (Ghostty)
swift run focus-probe --watch                 # 변경 추적 (폴링)
swift run focus-probe --once --json           # 기계 판독용
swift run focus-probe --self-test             # 연동 없이 결정적 검사 35건

swift run focus-probe --adapter herdr --once  # 실험(지원 범위 밖). stderr에 경고를 낸다
```

## 출력

```
pane        5D31DDD8-...   workspace tab-group-...   tab tab-7594a0f000   terminal 5D31DDD8-...
title       …/PaneDock/prototypes/focus-probe
focus       held                     (focusGeneration 1)
path        /Users/kangjingoo/Workspace/tool/PaneDock/prototypes/focus-probe
cwdSource   ghostty:terminal.workingDirectory
validity    valid              (디렉터리 확인됨)
observed    2026-09-16T18:10:55+09:00   revision -
connection  connected          AppleScript (ghostty 1.3.1)
host        ghostty / ghostty 1.3.1
frontmost   false              (최전면 아님 — 마지막 위치 유지로 표시)
previous    -                  (이전 위치 없음)
background  54DBC13A-...   /Users/kangjingoo   (valid)   Kangui-MacBookPro.local: Demon
nesting     unknown            (중첩 TUI 내부 경로는 공식 조회로 알 수 없음)
```

| 필드 | 의미 |
| --- | --- |
| `pane` | terminal ID. Ghostty에서 분할 pane 하나에 해당한다 |
| `workspace` / `tab` | 창 ID / 탭 ID |
| `focus` | `tracked`(포커스·경로 유효) `held`(최전면 아님, 마지막 위치 유지) `pending`(경로 확인 중) `unknown`(확인 불가) |
| `focusGeneration` | 대상이 바뀔 때마다 증가. 늦은 응답을 버리는 기준 |
| `path` | 연동이 보고한 작업 경로(원본 그대로) |
| `cwdSource` | 경로 출처. Ghostty는 `ghostty:terminal.workingDirectory` |
| `validity` | `valid` `pending` `missing`(경로가 없음) `unsupported`(연동이 경로 미제공) |
| `observed` | 마지막으로 확인한 시각 |
| `host` / `frontmost` | 바깥 앱과 버전 / 그 앱이 최전면인지 |
| `previous` | 직전에 표시한 위치. "이전 위치"로만 표시하며 새 pane의 경로로 승격하지 않는다 |
| `background` | 대상이 아닌 pane의 최근 보고. **표시 묶음에는 영향을 주지 않는다** |
| `nesting` | 중첩 TUI 내부 경로는 알 수 없음을 명시한다(자동 감지하지 않음) |

## 지켜야 하는 규칙 (코드로 강제)

| # | 규칙 | 구현 지점 |
| --- | --- | --- |
| R1 | 이 프로세스의 PWD를 작업 경로로 쓰지 않는다 | 경로는 연동 응답에서만 온다 |
| R2 | 호출한 pane/컨텍스트를 진단 목표로 승격하지 않는다 | Ghostty 경로는 창·탭·terminal 구조로만 대상을 정한다. herdr 경로는 `caller_pane_id`를 보내지 않는다 |
| R3 | 포커스는 **연동이 보고한 대상**만 쓴다 | `focused terminal of selected tab of front window` |
| R4 | 늦은 응답을 버린다 | `FocusResolver`의 `focusGeneration` 비교 |
| R5 | 새 pane 경로 미확인 시 이전 경로를 새 경로처럼 표시하지 않는다 | `alignTarget`이 경로 슬롯을 비우고 `previous`로 분리 |
| R6 | 비활성 pane 갱신은 캐시만 바꾼다 | `ContextStore.apply` → `.cachedBackground` |
| R7 | 연결/조회 오류와 추적 상태를 구분한다 | `connectionStatus` 별도 필드 |
| R8 | 바깥 터미널이 보고한 경로를 중첩 TUI의 내부 경로로 표시하지 않는다 | `nesting unknown` 줄로 한계를 명시하고, 감지했다고 주장하지 않는다 |
| R9 | 미지원은 미지원으로 표시한다 | 미실행 → `unavailable`, 권한 거부 → `denied`, AppleScript 미지원 → `incompatible`, 창 없음 → 대상 없음(연결은 정상) |

## 공식 API만 쓴다

`GhosttyAdapter`가 쓰는 것은 공식 scripting dictionary의 속성뿐이다:
`version`, `frontmost`, `front window`, `selected tab`, `focused terminal`, `working directory`.

**하지 않는 것**: 창·탭·terminal 생성, 입력 전송, 포커스 변경, 화면 내용 읽기,
앱 활성화. 조회는 `/usr/bin/osascript`로 실행한다(승인 주체가 바뀌지 않게 하려고).

## 자동 검증

```bash
swift run focus-probe --self-test      # 35건
```

XCTest는 Command Line Tools 환경에서 쓸 수 없어(`no such module 'XCTest'`) 실행 파일 모드로 둔다.

| 항목 | 내용 |
| --- | --- |
| **A** | pane 전환 시 새 식별자·새 경로, 이전 경로는 `previous`로 분리 |
| **B** | 같은 pane에서 경로만 갱신 |
| **C** | 비활성 pane 갱신은 대상을 바꾸지 않음 |
| **D** | 늦은 응답 폐기 |
| **E** | 경로 미제공/사라짐을 정상 추적과 구분 |
| — | 최전면 아님 + 유효 경로 → `held` |
| — | 오류 분류 4종(-600/-1743/-1708/-1728) |
| — | AppleScript 출력 파싱, `notRunning` 거부, 버전 게이트 |
| — | (보존) Herdr 시절 규칙 22건 — 늦은 응답, 재연결, errno 분류, 경로 정규화, 이벤트 이름 정규화 |

## 사용자 검증 절차

```bash
cd prototypes/focus-probe && swift run focus-probe --watch
```

| 순서 | 조작 | 기대 |
| --- | --- | --- |
| A | Ghostty에서 다른 탭/분할 pane으로 포커스 이동 | `pane`이 그 terminal ID로 바뀌고 `path`가 그 셸의 경로가 된다. 이전 경로는 `previous`에 남는다 |
| B | 대상 셸에서 `cd /tmp` | `pane`은 그대로, `path`와 `observed`만 바뀐다 |
| C | 대상이 **아닌** pane에서 `cd` | `background` 줄만 바뀌고 대상 `pane`/`path`는 그대로다 |
| D | 위를 빠르게 반복 | 마지막 블록이 마지막 포커스와 일치한다 |
| E | (선택) 없는 디렉터리로 이동 | `validity missing`, `focus unknown`으로 정상 추적과 구분된다 |

## 알려진 한계

- **중첩 TUI**: 대상 terminal에서 herdr·tmux·에이전트 TUI가 돌고 있으면 `working directory`는
  **바깥 프로세스의 cwd**이며 그 TUI의 내부 프로젝트 경로가 아니다. 공식 조회로 중첩 여부를
  확실히 판별할 수 없어 **자동 감지하지 않는다.** 직접 셸 환경 전용이다.
- **Herdr 미지원**: Herdr 안에서 작업하는 환경은 지원 대상이 아니다(`docs/scope-decisions.md` D1).
- **폴링**: Ghostty에는 구독 API가 없어 `--interval`(기본 1000ms) 주기로 다시 조회한다.
- **다중 창**: 대상은 `front window` 기준이다. 창이 여러 개일 때 사용자 기대와 맞는지는 미검증이다.
- **herdr 실험 경로**: `--adapter herdr`는 지원 범위 밖이며 새 정상 경로가 아니다.
