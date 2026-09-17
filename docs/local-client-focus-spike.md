# 로컬 Herdr 클라이언트 포커스 스파이크

> **상태: 취소 (2026-09-16).** 이 스파이크의 C1(클라이언트가 자기 위치를 상태 파일로 발행)은
> **미구현 · 진행 취소**다. Herdr 자체 수정이 필요한 연동은 지원 범위에서 제외하기로 결정했다
> (`docs/scope-decisions.md` D1). 이 문서는 **조사 기록으로 보존**한다.
> 아래 내용은 실행 계획이 아니라 이력이며, 우회 방법을 더 찾지 않는다.

- 작성일: 2026-09-16
- 범위: **소스 조사와 최소 변경 계획까지.** 구현하지 않았다.
- 관련 기록: `docs/verification.md` V3.6~V3.8 (다중 클라이언트에서 전역 포커스가 원격을 따라간 관측)

---

## 0. 결론 먼저

| 질문 | 답 |
| --- | --- |
| 기존 공식 확장 기능(플러그인·통합·이벤트·CLI)만으로 해결되는가 | **아니다.** 클라이언트별 문맥을 노출하는 읽기 경로가 없다 |
| 클라이언트 수정만으로 가능한가 | **가능하다.** 클라이언트는 이미 자기 표시 pane ID를 알고 있다(서버가 보내 준다). 그것을 밖에서 읽을 수 있게 발행하면 된다 |
| 서버 변경도 필요한가 | **최소 검증에는 불필요.** 다만 제품화·upstream 반영에는 클라이언트+서버 API가 바람직하다 |
| 결론 분류 | **"추가 기능 필요"** — 무변경(현 방식)으로는 불가. 변경 범위는 작다 |
| 선행 게이트 | herdr 소스를 **빌드할 수 있어야** 한다. 현재 오프라인 빌드 불가(미캐시 크레이트), Rust 1.95.0 vs 리포 고정 1.96.1, rustup 없음 → **네트워크/툴체인 결정 필요** |

핵심 발견 한 줄: **서버는 이미 클라이언트별 위치를 계산해 그 클라이언트에게 보내고 있다**
(`ClientShellSnapshot.focused_pane_id`). 없는 것은 "그 값을 외부에서 읽는 길"뿐이다.

---

## 1. 확인한 소스

| 항목 | 값 |
| --- | --- |
| 설치본 버전 문자열 | `0.9.0-preview.2026-09-09-5a244caa60b0` |
| 확인한 커밋 | `5a244caa60b0c3a5742315c59d20ed81c05bc23e` (`Merge pull request #169 … v0.9.0`) |
| 받은 방법 | `git init` + `git fetch --depth 1 origin <commit>` → `checkout FETCH_HEAD` (최신 master를 가정하지 않았다) |
| 위치 | `/tmp/herdr-src` (임시. 저장소에 넣지 않았다) |
| 파일 수 | 2,547 |

설치본 바이너리는 `~/.local/bin/herdr` (Mach-O arm64, 23,403,840 bytes, 2026-09-11). 교체하지 않았다.

주요 확인 파일:

| 파일 | 확인한 것 |
| --- | --- |
| `src/server/clients.rs` | `ClientShellLocation`, `ClientConnection.shell_location`, `shell_snapshot`, `outer_terminal_focus`, `is_active_shell_client` |
| `src/client/shell/state.rs` | `ClientShellState.snapshot`, `outer_focused`, `apply_active_snapshot`, `previous_pane_id` |
| `src/protocol/wire.rs:907` | `ClientShellSnapshot` (클라이언트가 받는 자기 위치 스냅샷) |
| `src/server/client_shell.rs:6-40` | 그 스냅샷을 **클라이언트별 location으로** 만드는 곳 |
| `src/server/headless/client_views.rs` | `ShellFocusTarget`, `shell_target_for_client`, `shell_focus_target`, `reconcile_client_shell_locations`, `apply_shell_navigation_request` |
| `src/server/headless.rs:813,915,2323,2044` | `sync_foreground_client_state`, `promote_client_to_foreground`, `ServerEvent::ClientShellFocus` |
| `src/app/api/session.rs:19-30` | `session.snapshot`의 `focused_*`가 **전역** `state.active`에서 나옴 |
| `src/api/schema.rs` | `Method` enum 전체(읽기용 클라이언트 메서드 없음) |
| `src/app/window_title.rs` | 창 제목 템플릿(전역 기반, 아래에서 탈락) |

---

## 2. 기존 PaneDock 코드에서 전역 포커스를 로컬 포커스로 취급하는 지점

전부 `prototypes/focus-probe` 안이다. **이번 스파이크에서 수정하지 않았다.**

| # | 위치 | 무엇을 하는가 |
| --- | --- | --- |
| 1 | `Sources/FocusProbeCore/HerdrAdapter.swift:136-146` (`bootstrap()`) | `session.snapshot`을 호출해 `snapshot.focusedPaneID`를 그대로 가져온다 |
| 2 | `Sources/FocusProbeCore/HerdrWire.swift:90-102` (`SessionSnapshotDTO`) | `focused_pane_id` / `focused_tab_id` / `focused_workspace_id`를 디코드한다 |
| 3 | `Sources/FocusProbeCore/HerdrAdapter.swift:75-78` (`focusedPane`) | 그 ID로 pane 목록에서 대상 레코드를 고른다 |
| 4 | `Sources/FocusProbeCLI/main.swift:168` (`OnceProbe.run`) | `store.alignTarget(to: focused)` — 전역 포커스를 추적 대상으로 확정 |
| 5 | `Sources/FocusProbeCLI/main.swift:312` (`WatchProbe.refreshFocus`) | 같음. 이벤트마다 재조회 |
| 6 | `Sources/FocusProbeCLI/main.swift` (`FocusEvents.changing`) | `pane.focused`/`tab.focused`/`workspace.focused` 이벤트로 재조회를 유발 |
| 7 | `Sources/FocusProbeCore/ContextStore.swift:75` (`alignTarget`) | 확정된 대상을 현재 묶음으로 설치 |

즉 1·2·3이 **값의 출처**, 4·5·6이 **그 값을 로컬 포커스로 승격하는 지점**이다.
7은 상태 기계이므로 그대로 두고, **입력만 바꾸면** 나머지(경로 조회·이벤트 처리·상태 관리·자체 검사)는 보존된다.

이벤트도 같은 성격이다: 서버가 발행하는 `pane.focused` 계열은 `state.active`에서 계산되므로 전역이다.

---

## 3. 데이터 흐름 (설치본 커밋 기준)

```
[클라이언트 A]                          [서버]                                   [클라이언트 B]
   │  workspace.focus / tab.focus / pane.focus  ──▶ Method 처리
   │                                                   │
   │                                        ┌──────────┴───────────┐
   │                                        ▼                      ▼
   │                          client.shell_location          app.state.active
   │                          (per-client: workspace+tab)      (전역: 마지막 탐색)
   │                                        │                      │
   │                                        │                      ├─▶ session.snapshot.focused_pane_id
   │                                        │                      │      (← PaneDock이 쓰던 값)
   │                                        │                      └─▶ pane.focused 이벤트
   │                                        ▼
   └────── ClientShellSnapshot ◀── client_shell::snapshot(location) ──────▶ [클라이언트 B]
            (focused_workspace_id / focused_tab_id / focused_pane_id = 그 클라이언트의 것)
```

근거가 되는 코드:

- `src/app/api/session.rs:19-30` — 전역 스냅샷의 `focused_*`는 `self.state.active`에서 나온다.
- `src/server/headless/client_views.rs:322-359` — `apply_shell_navigation_request`는 **그 클라이언트의** `shell_location`만 바꾼다.
- `src/server/client_shell.rs:6-40` — 클라이언트에게 보낼 스냅샷은 `location`(= 그 클라이언트의 workspace/tab)을 우선 쓰고, pane은 **그 탭의 layout.focused()** 로 정한다. location이 없을 때만 전역으로 폴백한다.
- `src/server/clients.rs:77-86` — `ClientShellLocation::from_snapshot`, `focused_tab_id()`.
- `src/client/shell/state.rs:894,965,1247,1321-1326` — 클라이언트는 `snapshot`과 `outer_focused`를 보관하고, `apply_active_snapshot`에서 `focused_pane_id` 변화를 추적한다.

### 3.1 전역이 왜 원격을 따라갔는가 (V3.6 관측의 설명)

1. 원격 클라이언트가 `workspace.focus`/`tab.focus`를 보낸다.
2. 그 요청은 (a) **그 클라이언트의** `shell_location`을 바꾸고, (b) 전역 핸들러를 통해 `app.state.active`도 바꾼다.
3. 전역이 바뀌므로 `session.snapshot.focused_pane_id`와 포커스 이벤트가 원격 쪽을 가리킨다.
4. 로컬 클라이언트의 **화면**은 자기 `shell_location`으로 렌더되므로 바뀌지 않는다 → "로컬 화면은 그대로인데 값만 원격을 따라감".

이 설명은 코드 구조와 V3.6 관측이 일치한다. 다만 `state.active`가 바뀌는 정확한 호출 지점(전역 핸들러)은
**파일 단위로는 확인했고 함수 단위로는 미확인**이다(§9).

### 3.2 pane 단위 독립성은 없다 (중요)

| 층 | 단위 | 근거 |
| --- | --- | --- |
| 클라이언트가 독립적으로 고르는 것 | **workspace + tab** | `ClientShellLocation { focused_workspace_id, active_tab_ids }` |
| pane 포커스 | **탭 단위 전역** | `ShellFocusTarget.pane_id = tab.layout.focused()` (client_views.rs:365-380, client_shell.rs:20-30) |

**따라서 두 클라이언트가 같은 탭을 보면 같은 pane을 표시하고 같은 pane으로 입력한다.**
독립적인 pane 선택은 성립하지 않는다 — 그리고 이것이 모호성을 **줄여 준다**:
추적 대상 탭만 알면 pane은 유일하게 결정된다.

---

## 4. 기존 공식 확장 기능으로 클라이언트별 문맥을 전달할 수 있는가

**없다.** 다음을 각각 확인했다.

| 후보 | 결과 | 근거 |
| --- | --- | --- |
| 플러그인 이벤트 훅 / 액션 / `HERDR_PLUGIN_CONTEXT_JSON` | 전역 문맥만 | `src/app/api/plugins/context.rs`가 `ws.focused_pane_id()`(전역 active) 로 문맥을 만든다 |
| `client.window_title.set/clear` | 쓰기 전용. 게다가 **전역 기반** | `src/app/window_title.rs`: 템플릿을 `state.active`에서 렌더하고 **foreground 클라이언트**에게만 푸시. 게다가 `{pane}` 토큰은 pane **라벨**이지 ID가 아니다 |
| `client_shell.surface.set` | 쓰기 전용(`active: bool`) | `ClientShellSurfaceSetParams` |
| API 이벤트(`events.subscribe`) | 전역 포커스만 | `tab.focused`/`pane.focused`/`workspace.focused` 뿐. 클라이언트 축 없음 |
| `herdr status client` | 호출한 클라이언트의 버전/채널/protocol 뿐 | `src/cli/status.rs:40,94` |
| `herdr integration` | 내장 **에이전트** 통합(claude/codex 등) | 클라이언트 문맥과 무관 |

전역 포커스를 다시 조회하는 외부 스크립트/플러그인은 해결책으로 인정하지 않았으므로, 위 후보는 모두 탈락이다.
(창 제목 경로는 특히 위험하다: 전역 기반이라 같은 오귀속을 재현할 뿐이다.)

---

## 5. 가장 작은 연동 방법

### 5.1 설계 원칙 (요구 5)

**pane 선택과 CWD 조회를 분리한다.**

```
① 클라이언트 선택   : 사용자가 명시적으로 고른 로컬 herdr 클라이언트 (pty로 식별)
② pane 획득        : 그 클라이언트가 스스로 아는 표시·입력 대상 pane ID
③ CWD 조회         : ②에서 얻은 pane ID를, 그 클라이언트가 알려준 서버·세션 소켓에 pane.get으로 질의
```

③은 기존 `pane.get`을 그대로 쓴다. 즉 **경로 조회 코드는 바꿀 필요가 없다.** 바뀌는 것은 ②의 출처뿐이다.

### 5.2 옵션 비교

| 안 | 내용 | 서버 재시작 | 프로토콜 변경 | 원격 배제 | 크기 |
| --- | --- | --- | --- | --- | --- |
| **C1 (권장)** | 클라이언트가 자기 위치를 상태 파일로 발행 | 불필요 | 없음 | 파일이 pty별로 분리 → 명시 선택 가능 | 작음 (클라이언트 1모듈 + 호출 2~3곳) |
| C2 | 클라이언트가 전용 로컬 소켓으로 응답 | 불필요 | 없음 | 같음 | 중간 (리스너·수명주기·권한) |
| S1 | 서버 읽기 API(`client.list` 등) 추가 | 필요 | 필요(22→23) | **불가** — 서버는 로컬/원격을 구분하지 못한다 | 중간 |
| S1+C1 | S1 + 클라이언트가 자기 식별(pty)을 보고 | 필요 | 필요 | 가능 | 큼 |
| W1 | 창 제목 파싱 | 불필요 | 없음 | 불가(전역 기반) | — |
| W2 | 플러그인 | 불필요 | 없음 | 불가(전역 기반) | — |

**핵심 판단:** S1 단독으로는 요구를 만족하지 못한다. 서버는 유닉스 소켓 연결만 보고
그 클라이언트가 로컬인지 SSH 너머인지 알 수 없다. 그래서 "로컬 클라이언트"를 정하려면
**어차피 클라이언트가 자기 정보를 알려야 한다.** 그렇다면 최소 검증은 클라이언트 단독(C1)으로 충분하다.

### 5.3 C1 변경 범위 (구체)

| 파일 | 변경 |
| --- | --- |
| `src/client/shell/state.rs` (신규 함수 + `apply_active_snapshot` 끝) | 위치가 바뀔 때만 발행. 기존 `previous_pane_id` 갱신 지점(1321-1326)이 좋은 훅이다 |
| `src/client/shell/state.rs` (부팅 리셋 경로, `reset_endpoint_projection` 인근) | `boot_id` 변경 시 새로 발행 |
| `src/client/…` 종료 경로 | 파일 제거(비정상 종료 대비는 아래 검증 규칙으로 보완) |
| 신규 소형 모듈 | 원자적 쓰기(temp+rename), 스로틀(변화 시에만), 경로 계산 |

발행 내용(제안):

```json
{
  "schema": 1,
  "tty": "/dev/ttys000",
  "pid": 8977,
  "session": "default",
  "socket": "/Users/kangjingoo/.config/herdr/herdr.sock",
  "boot_id": "…",
  "revision": 42,
  "focused_workspace_id": "w3D",
  "focused_tab_id": "w3D:t1",
  "focused_pane_id": "w3D:p6",
  "updated_unix_ms": 1789543000000
}
```

경로: `state_dir()/client-shell/<pty 이름>.json`
(`state_dir()` = `$XDG_STATE_HOME/herdr` 또는 `~/.local/state/herdr`, `src/config/io.rs:40`)

**왜 pty로 키를 잡는가:** 사용자가 `who`로 직접 확인할 수 있고, 로컬/원격 클라이언트가 자연히 분리되며,
프로세스 재시작에도 안정적이다. PID는 키로 쓰지 않는다(재사용·불안정).

### 5.4 상태 모델 변경 (최소)

`CurrentWorkInfo`에 **귀속(attribution)** 개념을 추가한다. 기존 필드 의미는 그대로 둔다.

| 값 | 의미 |
| --- | --- |
| `attributed` | 사용자가 고른 로컬 클라이언트의 pane을 확인했다 |
| `unattributed` | 그 클라이언트의 정보를 확인할 수 없다 (**전역 포커스를 대신 쓰지 않는다**) |

`focusStatus`(.tracked/.pending/.held/.unknown)와 `pathStatus`(.valid/.pending/.missing/.unsupported)는
**그대로 재사용**한다. 즉 변경은 "새 필드 1개 + 출처 교체"로 끝나고, 상태 기계·자체 검사는 보존된다.

---

## 6. 반드시 설명할 것 (요구 사항별 답)

### 6.1 원격 SSH 클라이언트를 어떻게 제외하는가

1. **구조적으로 제외된다.** 전역 `session.snapshot.focused_pane_id`를 아예 쓰지 않으므로, 원격이 무엇을
   하든 대상이 흔들리지 않는다.
2. **선택 단계에서 제외한다.** 사용자가 로컬 클라이언트의 pty를 한 번 명시 선택한다(예: `ttys000`).
   발행 파일이 pty별로 분리되므로 원격(`ttys021`)의 파일은 애초에 읽지 않는다.
3. **검증 단계에서 보강한다.** 선택된 pty가 **로컬 터미널 앱(Ghostty)의 자손 프로세스에 속하는지**를
   OS 수준에서 확인해, sshd가 만든 pty면 선택을 거부한다. (프로세스 계보 기반이며, 클라이언트 수·최근
   활동 시각 같은 간접 지표를 쓰지 않는다.)
4. **단정하지 않는다.** 위 확인이 불가능한 환경이면 `unattributed`로 표시한다.

미검증: Ghostty surface ↔ pty 매핑을 자동으로 얻을 수 있는지(6.2 참조).

### 6.2 선택한 바깥 터미널 작업 영역과 Herdr 클라이언트를 어떻게 연결하는가

- 연결 고리는 **pty**다. herdr 클라이언트 프로세스는 자기 pty에서 실행되고, 그 pty는 바깥 터미널(Ghostty)의
  특정 surface가 만든 것이다.
- Ghostty AppleScript는 surface별 **tty를 노출하지 않는다**(`terminal` 객체: `id`, `name`, `working directory`).
  따라서 자동 매핑은 AppleScript로는 불가능하고, **OS 프로세스 계보**(Ghostty → 자손 셸 → pty)로 얻어야 한다.
- 첫 구현은 **사용자 명시 선택**만 한다: 1회 설정에서 "이 Mac의 클라이언트 pty"를 고르고 저장한다.
  자동 매핑·다중 로컬 클라이언트 자동 선택은 **이후 범위**로 분리하며, 첫 구현이 이를 지원하는 것처럼
  표시하지 않는다(사용자 지시).

### 6.3 연결이 끊기거나 재시작됐을 때 오래된 데이터를 어떻게 제외하는가

| 신호 | 규칙 |
| --- | --- |
| `boot_id` | 값이 바뀌면 이전 발행분은 **폐기**하고 새 세대 시작(기존 `focusGeneration` 증가와 동일한 취지) |
| `revision` | 감소·동일 중복은 무시. 증가할 때만 반영 |
| `pid` + `tty` | `kill(pid,0)` + 그 pid의 tty가 파일의 tty와 일치하는지 확인. 불일치/사망 → `unattributed` |
| `updated_unix_ms` | **신선도 표시용으로만** 사용한다. 이 값만으로 귀속을 단정하지 않는다(사용자 제약) |
| pane ID 유효성 | `pane.get`이 `pane_not_found`를 주면 `pathStatus`를 `.missing`/`.unsupported`로 내린다. **전역 폴백 없음** |
| 소켓 | `socket` 필드의 경로로 조회한다. 다른 세션·서버의 pane ID를 섞지 않는다 |

### 6.4 대상 귀속이 확인되지 않으면 어떤 상태로 표시하는가

`attribution = unattributed`. 그리고:
- 마지막으로 알던 pane/경로는 **`previous`로만** 남긴다(기존 `ContextStore`의 "이전 위치" 규칙 재사용).
- `pathStatus`를 `.valid`로 유지하지 않는다.
- **전역 포커스로 대체하지 않는다.** 이것이 이번 스파이크의 핵심 제약이다.

### 6.5 클라이언트 수정만으로 가능한가, 서버 변경도 필요한가

- **최소 검증: 클라이언트 단독(C1)으로 가능하다.**
- **제품화: 클라이언트+서버가 바람직하다.** upstream 관점에서 파일 인터페이스보다
  프로토콜 메서드가 맞다. 다만 그 경우에도 클라이언트가 자기 식별(pty)·위치를 보고하는 부분은
  필요하므로, C1의 작업이 그대로 재사용된다.
- 어느 쪽이든 **서버 재시작이 필요한 변경은 기본 세션에 즉시 적용할 수 없다**(6.6).

### 6.6 기존 서버와 실행 중인 pane을 건드리지 않고 검증할 수 있는가

**가능하다.** 격리 수단이 이미 있다.

- **named session**: `herdr --session <name>`은 별도 소켓(`~/.config/herdr/sessions/<name>/herdr.sock`)과
  별도 서버를 만든다. 기본 세션의 pane·서버에 손대지 않는다.
- 새로 **빌드한 바이너리를 그 세션으로만** 실행한다. 설치본 바이너리(`~/.local/bin/herdr`)를 교체하지 않는다.
- 종료는 그 세션에만 한다(`herdr --session <name> session stop`). 기본 세션은 그대로 둔다.
- 설정 파일(`~/.config/herdr/config.toml`)도 건드리지 않는다.

주의: **개발 중인 클라이언트를 기본(default) 세션에 붙이지 않는다.** 붙이면 foreground/전역 상태를
흔들어 사용자 작업에 영향을 줄 수 있다.

---

## 7. 핵심 시나리오 판정

| 시나리오 | C1 적용 후 기대 | 판정 근거 |
| --- | --- | --- |
| **A. 로컬은 A 고정, 원격만 B/C로 이동 → 대상은 A 유지** | **성립** | 대상은 로컬 클라이언트가 받은 자기 스냅샷에서만 온다. 원격 탐색은 그 값에 영향을 주지 않는다 (§3.1) |
| **B. 원격 고정, 로컬을 D로 이동 → 대상 D로 변경** | **성립** | 로컬 클라이언트의 `shell_location`이 바뀌면 서버가 새 스냅샷을 보내고, 발행 파일이 갱신된다 |
| **C. 로컬 pane에서 `cd` → pane ID 유지, 경로만 갱신** | **성립** | pane ID는 그대로, 기존 `pane.get` 재조회가 새 `cwd`를 가져온다(기존 경로 조회 코드 보존) |
| **D. 두 클라이언트가 같은 탭** | **일치한다. 단 독립 pane 선택은 성립하지 않는다** | pane 포커스는 탭 단위 전역이므로 두 클라이언트의 표시·입력 pane은 **같다**. 전역 `focused_pane_id`가 곧 그 탭의 pane과 같아도 우연이 아니라 구조적 동일이다. 모호해지는 경우는 **서로 다른 탭/워크스페이스**를 볼 때뿐이며, 그때는 per-client location이 갈라진다 |
| **E. 브라우저 이동 / 클라이언트 분리 / 재연결** | **구분 가능** | 브라우저 이동 → 클라이언트 위치 불변 → `held`(최전면 앱 신호로 "유지 중" 표시). 분리·종료 → pid/tty 검증 실패 → `unattributed`. 재연결 → `boot_id`/`revision`으로 이전 세대 폐기. **어느 경우에도 전역 포커스를 정상 로컬 정보로 승격하지 않는다** |

---

## 8. 안전한 재현 절차 (구현 승인 시)

전제: **§10의 게이트를 먼저 통과해야 한다.**

1. `cd /tmp/herdr-src && cargo build` (네트워크 필요. 설치본·기본 세션은 건드리지 않는다)
2. 격리 세션 기동: `./target/debug/herdr --session pdspike`
   - 새 소켓: `~/.config/herdr/sessions/pdspike/herdr.sock` (기본 세션과 무관)
   - 이 세션에서 pane 2~3개를 만든다(새 pane이며 기존 pane이 아니다)
3. 클라이언트 2개를 **서로 다른 pty**에서 띄운다(터미널 창 2개).
   원격 상황을 흉내내려면 `ssh localhost`로 한쪽을 띄운다 — **Remote Login이 켜져 있어야 하며 미검증**.
   켜져 있지 않으면 로컬 pty 2개로 A·B·D를 검증하고, SSH는 V3.6의 실관측으로 대체한다.
4. 발행 파일 확인: `ls -l ~/.local/state/herdr/client-shell/` → pty별 파일이 생기는지
5. **A**: 클라이언트 2에서 workspace를 옮긴다 → **클라이언트 1의 파일이 변하지 않아야 한다**
6. **B**: 클라이언트 1에서 pane을 옮긴다 → 클라이언트 1의 파일만 바뀌어야 한다
7. **C**: 클라이언트 1의 pane에서 `cd /tmp` → 파일의 `focused_pane_id`는 그대로, 별도 조회로 경로만 갱신
8. **D**: 두 클라이언트를 같은 탭으로 맞춘다 → 두 파일의 `focused_pane_id`가 같아야 한다(구조적 동일 확인)
9. **E**: 클라이언트 1을 정상 종료 → 파일이 사라지거나 pid 검증에서 탈락 → `unattributed`
10. 정리: `./target/debug/herdr --session pdspike session stop`, 임시 세션 디렉터리 삭제

각 단계는 **출력 원문**과 함께 `docs/verification.md`에 `V4`로 추가한다(기존 절 보존).

---

## 9. 검증된 사실 / 추정 / 미검증

### 검증된 사실 (E3급, 소스 또는 실측)

1. 설치본 커밋 `5a244ca…`의 소스를 그 커밋으로 고정해 받아 확인했다.
2. `session.snapshot.focused_*`는 **전역** `state.active` 기반이다 (`src/app/api/session.rs:19-30`).
3. 서버는 **클라이언트별** `shell_location`(workspace+tab)을 보관한다 (`src/server/clients.rs:64-90,176-179`).
4. 서버는 그 클라이언트에게 **자기 위치가 담긴** `ClientShellSnapshot`을 보낸다
   (`src/server/client_shell.rs:6-40`, `src/protocol/wire.rs:907`).
5. 클라이언트는 그 스냅샷과 `outer_focused`를 상태로 보관한다 (`src/client/shell/state.rs:894,965,1247`).
6. **pane 포커스는 탭 단위 전역**이다. per-client 독립 pane 선택은 없다 (`ShellFocusTarget.pane_id = tab.layout.focused()`).
7. 서버 API `Method` enum에 **클라이언트 읽기 메서드가 없다**(쓰기 2개뿐).
8. 창 제목은 전역 기반이며 foreground 클라이언트에게만 푸시된다 → 클라이언트 식별에 쓸 수 없다.
9. 플러그인 문맥은 전역 기반이다.
10. 클라이언트별 `outer_terminal_focus`와 `foreground_client_id`(promotion)가 서버 내부에 존재한다
    (`src/server/headless.rs:813,915,2323`).
11. 실제로 클라이언트가 2개(로컬 `ttys000`, 원격 `ttys021`) 붙은 상태에서 전역 포커스가 원격을 따라갔다(V3.6).
12. 오프라인 빌드는 불가하다(`jsonc-parser` 미캐시). Rust 1.95.0 설치, 리포 고정은 1.96.1, rustup 없음.

### 추정 (근거는 있으나 실측 아님)

1. `state.active`가 클라이언트 탐색 요청으로 바뀐다는 **함수 단위 확인은 못 했다**(파일 구조와 관측은 일치).
2. `outer_terminal_focus`가 원격 SSH 클라이언트에서도 true가 될 수 있다(회사 PC 터미널의 포커스 이벤트가
   ssh를 통해 전달된다면). 그래서 이를 로컬 판별에 쓰지 않기로 했다.
3. pty를 키로 한 발행 파일이 재시작·재부착에서 안정적일 것이라는 가정.

### 미검증

| # | 항목 | 왜 |
| --- | --- | --- |
| 1 | herdr 소스가 이 환경에서 **빌드되는지** | 미캐시 크레이트(네트워크 필요), 툴체인 1.95 vs 1.96.1 |
| 2 | Ghostty surface ↔ pty 자동 매핑 | AppleScript가 tty를 노출하지 않음. OS 계보 방식은 미검증 |
| 3 | `ssh localhost`로 원격 클라이언트 재현 가능 여부 | Remote Login 설정에 달렸고 확인하지 않았다 |
| 4 | C1 발행이 성능·부하에 미치는 영향 | 구현 전 |
| 5 | named session에서 클라이언트 2개가 실제로 독립 위치를 갖는지 | 실측 필요(시나리오 A/B가 이걸 확인한다) |
| 6 | 로컬 클라이언트가 여러 개일 때의 선택 UX | 이후 범위로 분리(사용자 지시) |

---

## 10. 결론과 게이트

**결론: "추가 기능 필요" — 클라이언트 측 최소 변경(C1)으로 목표를 달성할 수 있고, 범위는 작다.**

- 무변경(기존 공식 확장 기능)으로는 **불가**하다. 읽기 경로가 없다.
- 서버 재설계는 필요 없다. 전역 포커스를 쓰지 않는 것이 요구의 핵심이고, 필요한 신호는 이미 클라이언트에게
  도착해 있다.
- PaneDock 기존 코드는 **값의 출처(§2의 1·2·3)** 만 교체하면 되고, 경로 조회·이벤트 처리·상태 관리·자체
  검사는 보존된다.

**구현 전 결정이 필요한 게이트**

| # | 게이트 | 왜 필요한가 |
| --- | --- | --- |
| G1 | herdr 소스 빌드를 위한 **네트워크(크레이트 다운로드)** 허용 | 오프라인 해석 실패 확인 |
| G2 | Rust 툴체인 처리(설치된 1.95.0 사용 vs 리포 고정 1.96.1) | rustup이 없어 고정이 무시된다. 빌드 실패 가능 |
| G3 | `/tmp/herdr-src`를 계속 쓸지, 다른 작업 디렉터리를 쓸지 | 사용자 환경 밖 임시 위치 |
| G4 | upstream 이슈/PR 제안 여부 | 사용자 승인 없이 게시하지 않는다 |
| G5 | C1(파일 발행) vs S1+C1(프로토콜) 중 무엇을 먼저 할지 | 검증 속도 vs upstream 수용성 |

G1·G2가 막히면 **클라이언트 수정 검증 자체가 불가능**하다. 그 경우 남는 선택지는
(가) herdr 쪽 변경 없이 "단일 클라이언트 구성"을 지원 조건으로 명시하고 다중이면 `unattributed`로
표시하는 것(감지는 가능하나 사용성 손실), (나) upstream에 읽기 API를 요청하고 대기하는 것뿐이다.
