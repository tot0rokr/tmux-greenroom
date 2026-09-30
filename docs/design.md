# tmux-llm-agent 설계

상태: M1·M2 구현 완료, 2026-09-30. 제안 P1~P4는 미착수.

## 목표

- 어느 tmux session·window에서든 같은 키로 agent popup을 열고 닫는다.
- popup을 닫으면 detach만 한다. agent 프로세스는 계속 돌고, 다시 열면 그 화면 그대로 이어서 쓴다.
- popup 하나에 agent를 여러 개 띄운다. 용도별로 이름 붙인 popup(workspace)도 여러 개 둔다.
- Claude Code, Codex, Gemini CLI, OpenCode를 기본 지원하고, 다른 CLI는 옵션 한 줄로 추가한다.

## 비목표

- tmux server 재시작이나 재부팅 뒤 agent 대화 복원. agent CLI의 resume 기능(`claude --continue` 등) 영역이다. 보조 기능은 제안 P4.
- 한 화면에 popup 여러 개를 동시에 표시. tmux 3.7까지 popup은 client당 overlay 하나다. workspace는 여러 개지만 한 client에 보이는 건 한 번에 하나다.
- agent CLI 자체의 설정·인증 관리.

## 용어

| 용어         | 뜻                                                    |
| ------------ | ----------------------------------------------------- |
| host server  | 사용자가 평소 쓰는 tmux server                        |
| agent server | 이 플러그인 전용 tmux server, `tmux -L llm-agent`     |
| workspace    | agent server의 session 하나. popup 하나에 대응        |
| agent        | workspace의 window 하나. agent CLI 하나를 실행        |
| origin pane  | popup을 연 host pane. 새 agent의 작업 디렉토리 기준   |

## 구조

```
 host server (your tmux)                 agent server (tmux -L llm-agent)
┌────────────────────────────────┐      ┌─────────────────────────────┐
│ session "work"                 │      │ workspace "main"            │
│  └ popup: attach.sh ───────────┼─────▶│  ├ window 0: claude         │
│                                │      │  └ window 1: codex          │
│ session "notes"                │      │                             │
│  └ popup: attach.sh ───────────┼─────▶│ workspace "review"          │
│                                │      │  └ window 0: claude         │
└────────────────────────────────┘      └─────────────────────────────┘
```

- 어느 host session에서 열든 같은 agent server에 붙는다. 두 host client가 같은 workspace를 동시에 열 수도 있다.
- popup 안의 프로세스는 `tmux -L llm-agent attach` 하나뿐이다. agent 프로세스는 agent server가 소유한다.

## 핵심 결정

### D1. 전용 agent server

- workspace를 host server의 session으로 두지 않고 `tmux -L <socket>` 전용 server에 둔다.
- 이유
  - host의 session 목록(`choose-tree`, `switch-client -n`, tmux-fzf, tmux-resurrect)을 오염시키지 않는다. tmux-toggle-popup도 같은 이유로 전용 server를 기본값으로 둔다.
  - popup 안에서 `prefix + s`/`w`를 누르면 workspace와 agent만 보인다.
  - host server를 kill해도 agent는 산다. 같은 사용자의 다른 host server(`tmux -L work` 등)에서도 같은 workspace를 연다.
- 대가
  - paste buffer가 server별로 분리된다. OSC 52 clipboard가 popup을 통과하는 건 tmux 3.7부터다 (tmux CHANGES "3.6b TO 3.7", 리뷰 조사). buffer 동기화는 제안 P3.
  - agent server에 설정과 바인딩을 따로 적용해야 한다 (D3, D5, D7).
- 기각안: host server에 숨긴 session (tmux-floax, tmux-claude-hatch 방식). 코드는 더 짧지만 목록 오염이 그대로 남는다.

### D2. popup job이 준비와 attach를 맡는다

- host 바인딩은 `display-popup -E -d '#{pane_current_path}' ... attach.sh` 하나다.
- `attach.sh`는 popup 안에서 실행된다. agent server와 workspace가 없으면 만들고, 설정을 적용한 뒤 `exec tmux -L <socket> attach`한다.
- 이유
  - popup job의 cwd가 곧 origin pane 경로다. 경로를 셸 명령에 끼워 넣지 않으므로 공백·따옴표가 있어도 안전하다. `-d`는 format으로 확장된다 (tmux 3.3a `cmd-display-menu.c`, 리뷰 조사).
  - popup job의 `$TMUX`는 host server를 가리키므로 host 옵션을 바로 읽는다.
- 주의
  - popup 안에서 `-L` 없이 `tmux`를 부르면 `$TMUX` 때문에 host server로 간다. host 쪽 코드의 agent server 호출은 항상 `-L`을 붙인다. agent server 안에서 도는 스크립트는 `$TMUX`가 agent server라 `-L`이 필요 없다.
  - agent server를 새로 띄울 때는 `TMUX`, `TMUX_PANE`을 지운다. `TMUX_PANE`이 남으면 agent server 전역 환경으로 새어 들어간다 (리뷰 실측).
  - `display-popup`의 shell-command는 format으로 확장되지 않는다 (실측 9). 바인딩의 경로에 `#` escape를 하지 않는다.

### D3. agent server도 host와 같은 prefix

- `attach.sh`가 host의 `prefix`, `prefix2`를 읽어 여는 때마다 agent server에 설정한다.
- popup이 열려 있는 동안 host는 key table을 처리하지 않고 모든 키를 popup job에 넘긴다. 그래서 중첩 tmux의 이중 prefix 문제가 없다.
  - 실측: 검증 근거 1~3.
  - 사실: tmux 3.3a `server-client.c`의 `server_client_handle_key`는 key table 조회보다 `overlay_key`를 먼저 호출한다 (조사, 리뷰가 교차 확인).
- 닫기 키는 host의 열기 키와 같은 키를 agent server에서 `detach-client`로 바인딩해 만든다. 같은 키가 열고 닫는 토글이 된다.
- 바인딩한 키는 양쪽 server의 `@llm_agent_bound`에 기록하고, 다음 적용 때 먼저 unbind한다. 키 옵션을 바꿔도 옛 키가 남지 않는다.

### D4. workspace는 session, agent는 window

- popup 하나가 workspace(session) 하나, 그 안의 탭이 agent(window)다.
- tmux 기본 기능이 그대로 동작한다.
  - `prefix + n`/`p`/숫자: agent 전환
  - `prefix + &`: agent 종료
  - `prefix + $`: workspace 이름 변경
  - `prefix + s`: workspace 전환
- 기각안: agent마다 session. 한 popup에서 agent를 탭처럼 오가려면 전환 UI를 직접 만들어야 한다.

### D5. agent server는 사용자 tmux.conf를 읽지 않는다

- agent server는 시작할 때 `-f conf/agent-server.conf`와, 설정돼 있으면 `-f <@llm-agent-config>`를 읽는다.
  - `-f`를 여러 번 주면 순서대로 모두 읽고, 앞 파일의 에러가 뒤 파일이나 이어지는 명령을 끊지 않는다 (실측 10). 사용자 conf의 오타가 workspace 준비를 막지 않는다.
- 이유: 사용자 conf를 읽으면 TPM이 모든 플러그인을 agent server에서 다시 실행한다. tmux-continuum 같은 플러그인은 host의 저장본을 agent server 상태로 덮어쓸 수 있다.
- popup 안에서 쓰고 싶은 플러그인은 `@llm-agent-config` 파일에서 직접 `run-shell`한다. 예: `run-shell ~/.tmux/plugins/tmux-cuecard/cuecard.tmux`.
- `conf/agent-server.conf`는 `@llm_agent_server`를 설정하고, `llm-agent.tmux`는 이 값이 있으면 아무것도 하지 않는다. 사용자가 전체 conf를 지정해도 이 플러그인이 agent server 안에서 host 바인딩을 만들지는 않는다. 다른 플러그인의 부작용은 막지 못한다.
  - 초안의 환경 변수 방식(`LLM_AGENT_SERVER=1`)은 버렸다. agent pane에서 띄운 다른 tmux server로 새어 나가 거기서 플러그인이 꺼진다 (리뷰 실측).

### D6. 메뉴는 `display-menu`, 외부 의존성 없음

- agent 종류 선택과 workspace 선택을 tmux 내장 `display-menu`로 만든다. bash와 tmux만 있으면 된다.
- `display-menu`의 이름과 명령은 format으로 확장된다 (man page). 메뉴 명령에 넣는 문자열은 `#`을 `##`로 escape한다.
- 셸과 tmux parser 양쪽에 같은 single-quote 규칙(`'\''`)을 쓴다. tmux parser도 sh처럼 인접 quoted 토큰을 이어 붙인다 (실측 11).
- 사용자가 입력하는 workspace 이름은 `command-prompt`의 `%%%`(따옴표 escape)로 option에 먼저 저장하고, 스크립트가 option에서 읽는다. 입력값이 셸 명령줄을 거치지 않는다.

### D7. 사용자 옵션은 여는 때마다 통째로 복사한다

- 옵션 이름공간을 나눈다. `@llm-agent-*`는 사용자 옵션, `@llm_agent_*`는 플러그인 상태다.
- 여는 때마다 agent server의 `@llm-agent-*`를 모두 지우고 host의 `@llm-agent-*`를 모두 복사한다. host에서 바꾸거나 지운 옵션이 다음 열기에 반영된다.
- 값은 paste buffer를 거쳐 읽는다 (`run-shell -C 'set-buffer "#{q:...}"'` 후 `save-buffer -`).
  - 이유: tmux 3.4는 `show-option`, `display-message`, `show-options` 출력에서 `$`를 escape하고 백슬래시는 그대로 둔다. 출력만으로는 원래 값을 되살릴 수 없다 (실측 12). agent 명령에는 `$`가 흔히 들어간다.
  - agent server 안의 `run-agent.sh`도 같은 방식으로 명령을 읽는다.
- 모든 준비 명령은 tmux 호출 하나로 묶어 보낸다. 두 client가 동시에 열어 한쪽의 `new-session`이 실패해도, workspace가 결국 있으면 그대로 attach한다.

### D8. agent는 wrapper로 실행한다

- window는 agent 명령을 직접 실행하지 않고 `run-agent.sh <name>`을 실행한다.
- wrapper는 명령을 `$SHELL -lc`로 실행한다. login shell이라 사용자 profile의 PATH가 적용된다.
- exit status가 0이 아니면 `[<name> exited with status N. Press any key to close.]`를 출력하고 키 하나를 기다린 뒤 끝난다.
  - 초안의 `remain-on-exit failed`는 버렸다. Ctrl-C에 0이 아닌 status로 끝나는 CLI는 매번 죽은 pane을 `prefix + x`로 치워야 했다 (리뷰 지적).
  - wrapper는 `trap : INT`로 Ctrl-C를 견딘다. 무시(`trap '' INT`)가 아니라 handler라서 agent에게 상속되지 않는다.
- 메뉴에서 PATH에 없는 agent를 비활성으로 표시하는 기능은 버렸다. 검사하는 환경(popup job)과 실행 환경(login shell)의 PATH가 달라 오탐이 난다. 없는 명령은 status 127로 알려 준다.

## 동작 흐름

### popup 열기

1. host에서 `prefix + g`를 누른다.
2. host가 `display-popup -E -d <origin 경로>`로 `attach.sh`를 실행한다.
3. `attach.sh`가 대상 workspace를 정한다. 순서: 인자, `@llm_agent_last`, `@llm-agent-workspace`(기본 `main`) 중 존재하는 것, 아무 workspace, 없으면 `@llm-agent-workspace`를 새로 만든다.
4. 준비 명령을 tmux 호출 하나로 보낸다.
   - agent server가 없으면 이때 뜨고, host의 동작 옵션(`default-terminal`, `mouse`, `base-index`, `extended-keys` 등)을 한 번 복사한다.
   - 사용자 옵션 복사 (D7), 상태 옵션 기록, 옛 바인딩 해제와 새 바인딩 (D3).
   - workspace가 없으면 `@llm-agent-default` agent 하나로 만든다.
   - workspace에 `@llm_agent_origin`으로 origin 경로를 기록한다.
5. `exec tmux -L <socket> attach -t =<workspace>`.
6. 준비가 실패하고 workspace도 없으면 에러를 출력하고 키 입력을 기다린다. `-E` popup이 에러를 보여 주기 전에 닫히지 않게 한다.

### popup 닫기

- popup 안에서 `prefix + g`(열기와 같은 키) 또는 `prefix + d`를 누른다.
- inner client가 detach되면 attach 프로세스가 끝나고 `-E` popup이 닫힌다. agent는 계속 실행된다.

### agent 추가

- popup 안에서 `prefix + c`를 누르면 agent 메뉴가 뜬다. `@llm-agent-agents` 순서대로, 마지막에 구분선과 `shell`.
- 단축키는 이름에서 아직 안 쓴 첫 글자다. `display-menu`가 쓰는 `q j k g G`는 건너뛴다.
- 고른 agent를 `@llm_agent_origin` 경로에서 새 window로 실행한다. window 이름은 agent 이름이다.

### agent 종료

- agent가 status 0으로 끝나면 window가 닫힌다. 그 밖의 status는 D8대로 키 하나를 기다린 뒤 닫힌다.
- workspace의 마지막 agent가 끝나면 session이 사라지고, `detach-on-destroy on`이라 popup이 닫힌다. 다른 workspace로 넘어가지 않는다 (테스트 `last_agent_exit_does_not_switch_workspace`).
- 마지막 workspace가 사라지면 agent server도 종료된다 (`exit-empty` 기본값).

### workspace 관리

- host에서 `prefix + G`를 누르면 popup이 열리고 workspace 메뉴가 뜬다. popup 안에서 `prefix + G`도 같은 메뉴다.
- 메뉴 항목
  - 기존 workspace 목록. agent 수와 현재 표시(`*`), 앞 9개는 숫자 단축키. 고르면 `switch-client`.
  - `n` 새 workspace: 이름을 묻고, 현재 workspace의 origin 경로에서 기본 agent 하나로 만든 뒤 전환.
  - `r` 이름 변경, `x` 현재 workspace 삭제(확인 후).
- workspace 이름에서 `[A-Za-z0-9_-]` 밖의 문자는 `_`로 바꾼다.
- 마지막으로 본 workspace는 `client-attached`, `client-session-changed`, `session-renamed` hook이 `set-option -gF`로 `@llm_agent_last`에 기록한다. `-F`가 없으면 `#{session_name}`이 글자 그대로 저장된다 (리뷰 실측).

## 키 바인딩

host server:

| 키             | 동작                            |
| -------------- | ------------------------------- |
| `prefix` + `g` | 마지막 workspace를 popup으로    |
| `prefix` + `G` | popup + workspace 메뉴          |

popup 안 (agent server):

| 키                         | 동작                             |
| -------------------------- | -------------------------------- |
| `prefix` + `g`             | popup 닫기                       |
| `prefix` + `c`             | agent 메뉴                       |
| `prefix` + `G`             | workspace 메뉴                   |
| `prefix` + `n` `p` `0`-`9` | agent 전환 (tmux 기본)           |
| `prefix` + `s` `w`         | workspace·agent 트리 (tmux 기본) |
| `prefix` + `d`             | popup 닫기 (tmux 기본)           |

- `g`/`G`는 stock tmux와 현재 사용자 conf 양쪽에서 비어 있는 키다 (`list-keys -T prefix`로 확인). 옵션으로 바꾼다.
- `@llm-agent-root-key`(예: `M-g`)를 지정하면 prefix 없이 토글한다. 이 키는 agent server에도 바인딩되므로 agent CLI에는 전달되지 않는다.

## 옵션

| 옵션                      | 기본값                         | 설명                                    |
| ------------------------- | ------------------------------ | --------------------------------------- |
| `@llm-agent-key`          | `g`                            | popup 토글 키 (prefix table)            |
| `@llm-agent-root-key`     | 없음                           | prefix 없이 토글하는 키 (root table)    |
| `@llm-agent-menu-key`     | `G`                            | workspace 메뉴 키                       |
| `@llm-agent-new-key`      | `c`                            | popup 안 agent 메뉴 키                  |
| `@llm-agent-agents`       | `claude codex gemini opencode` | agent 메뉴 항목과 순서                  |
| `@llm-agent-<name>-cmd`   | `<name>`                       | agent 실행 명령                         |
| `@llm-agent-shell-cmd`    | login shell                    | 메뉴의 `shell` 항목이 실행할 명령       |
| `@llm-agent-default`      | `claude`                       | 새 workspace의 첫 agent                 |
| `@llm-agent-workspace`    | `main`                         | 기본 workspace 이름                     |
| `@llm-agent-width`        | `80%`                          | popup 너비                              |
| `@llm-agent-height`       | `80%`                          | popup 높이                              |
| `@llm-agent-x`            | `C`                            | popup 가로 위치                         |
| `@llm-agent-y`            | `C`                            | popup 세로 위치                         |
| `@llm-agent-border-lines` | `rounded`                      | popup 테두리 (`popup-border-lines` 값)  |
| `@llm-agent-socket`       | `llm-agent`                    | agent server socket 이름 (`-L`)         |
| `@llm-agent-config`       | 없음                           | agent server 시작 시 추가로 읽을 conf   |

- host 키(`@llm-agent-key`, `-root-key`, `-menu-key`)와 popup 크기·위치·테두리는 플러그인 로드 때 host 바인딩에 들어간다. 바꾸면 conf를 다시 읽어야 하고, 그때 옛 키는 풀린다.
- 나머지는 여는 때마다 읽는다. agent server 쪽 키 바인딩도 여는 때마다 다시 만든다.

## 파일 구성

```
llm-agent.tmux              TPM entry: bind host keys
conf/agent-server.conf      agent server defaults: marker, status line, hooks
scripts/helpers.sh          option lookup, quoting, raw option reads
scripts/attach.sh           popup job: pick and prepare a workspace, attach
scripts/run-agent.sh        agent wrapper run by every agent window
scripts/workspace-menu.sh   workspace menu (agent server)
scripts/new-workspace.sh    create a workspace from the menu prompt
scripts/rename-workspace.sh rename a workspace from the menu prompt
tests/run.sh                integration tests on isolated tmux servers
```

## 검증 근거

### 설계 전 프로토타입

tmux 3.7b에서 격리된 server 세 개(harness, host, agent)로 실측했다. harness pane 안에서 host client를 돌리고 harness의 `send-keys`로 키를 입력했다.

| #   | 확인 항목                                           | 결과 (실측)                               |
| --- | --------------------------------------------------- | ----------------------------------------- |
| 1   | popup 안 `prefix + c`는 어느 server가 받나          | agent server. window 1→2, host 변화 없음  |
| 2   | popup이 열린 동안 host `bind -n` 키가 발동하나      | 발동 안 함                                |
| 3   | popup이 열린 동안 host prefix 바인딩이 발동하나     | 발동 안 함                                |
| 4   | agent server에서 `detach-client`하면 popup이 닫히나 | 닫힘. session과 window는 유지             |
| 5   | 다시 열면 상태가 유지되나                           | 유지. window 2개 그대로                   |
| 6   | `$TMUX`를 지우지 않고 popup 안에서 attach 되나      | 됨. nested 검사에 걸리지 않음             |
| 7   | workspace의 마지막 window가 끝나면                  | popup 닫힘, agent server 종료             |
| 8   | Shift+Enter가 중첩 계층을 통과하나                  | 통과. 직접, 중첩 모두 `ESC[27;2;13~`      |

- 6번은 같은 server의 session으로 확인했다. 근거 (조사): tmux 3.3 `server_client_check_nested`는 client tty가 그 server의 pane tty일 때만 nested로 본다. popup job은 자체 pty를 쓴다.
- 7번은 session이 하나뿐이라 server가 끝나서 닫힌 경우다. workspace가 여럿일 때는 통합 테스트가 따로 확인한다.
- 8번 조건: host와 agent server 모두 `extended-keys on`, `terminal-features`에 `tmux*:extkeys`. tmux 3.4에서는 같은 키가 `ESC[13;2u`(CSI u)로 도착한다 (리뷰 실측, 통합 테스트로 재확인). 3.3 내장 terminal feature에는 `tmux`용 extkeys가 없어 agent server conf가 직접 추가한다 (리뷰 조사).

### 구현 중 실측

| #   | 확인 항목                                        | 결과 (실측, 3.7b)                                |
| --- | ------------------------------------------------ | ------------------------------------------------ |
| 9   | `display-popup` shell-command의 format 확장      | 안 함. `#{session_name}`이 글자 그대로 남음      |
| 10  | `-f`를 두 번 주면                                | 둘 다 읽음. 둘째 파일의 에러 뒤 줄과 명령도 실행 |
| 11  | tmux parser가 `'it'\''s'`와 중첩 quoting을 받나  | 받음. `$` `;` `#` `"` 백슬래시 모두 보존         |
| 12  | `$`가 든 옵션 값을 `show -gv`로 읽으면           | 3.7b 원문, 3.4는 `\$`. buffer 경유는 둘 다 원문  |
| 13  | pane 대상 인자에 `-t =main`                      | `no such session`. `=main:`이어야 함             |
| 14  | `;`로 끝나는 argv 원소                           | 명령 구분자로 먹힘. 끝을 `\;`로 쓰면 값 보존     |
| 15  | `set-buffer "~/x"`처럼 따옴표 첫 글자가 `~`      | tilde 확장됨 (코드 리뷰 실측). 앞에 `x`를 붙임   |
| 16  | `list-keys -T prefix g` (키 인자)                | 3.7b는 출력 없음, 3.4는 출력. 테스트는 전체 검색 |

- 12번의 3.4 결과는 `/usr/bin/tmux` 3.4로 측정했다. `show-options -g` 출력도 3.4에서는 `\\$`로 이중 escape되어 source로 되살릴 수 없다.

### 코드 리뷰에서 고친 것

- bash 4.2 이하는 `"${1//\'/...}"`의 치환 문자열에서 quote를 제거하지 않는다. `quote()`가 중첩 quoting에서 깨져 agent 메뉴와 새 workspace가 동작하지 않았다 (리뷰 실측, `BASH_COMPAT=3.2`로 11/16). 치환 문자열을 변수에 담아 고쳤다.
- `new-session -c`는 경로를 format으로 확장한다. `#S`가 든 디렉토리는 엉뚱한 곳에서 시작했고, tmux 3.4에서는 `#(...)`가 든 디렉토리 이름이 명령을 실행했다 (리뷰 실측). 시작 디렉토리는 `format_escape`를 거친다.
- 새 workspace의 origin과 입력 이름을 `display-message`, `show-option`으로 읽어 3.4에서 `$`가 깨졌다. `read_raw_options`로 바꿨다.
- workspace 메뉴의 전환·삭제 대상은 이름 대신 session ID를 쓴다. 이름 변경도 입력값을 정리하는 스크립트를 거친다.

### 통합 테스트

`tests/run.sh` 23개가 tmux 3.7b와 3.4에서, 각각 bash 5.2와 `BASH_COMPAT=3.2`로 모두 통과한다 (실측, 네 조합). origin 경로는 `it's #S $x;`처럼 셸 quoting, tmux format, argv 파싱을 깨는 문자를 담는다. 실제 bash 3.2 바이너리는 설치본이 없어 돌리지 못했다.

## 선행 사례

- omerxx/tmux-floax: host server의 `scratch` session을 popup에 띄우는 범용 scratch 터미널. session 이름으로 popup 안인지 판별해 detach한다.
- loichyan/tmux-toggle-popup: 전용 server(`@popup-socket-name`)를 쓰는 범용 popup 토글. README 기준 tmux 3.4+.
- craftzdog/tmux-claude-hatch: host server에 프로젝트별 `claude-<hash>` session. Claude 전용.
- 이 플러그인의 차이: agent 레지스트리와 메뉴, workspace와 agent의 2단 구조, origin 경로 전달. 범용 popup 플러그인 위에 얹으면 의존성만 늘고, 필요한 부분은 여전히 직접 짜야 한다.

## 위험과 알려진 제약

- tmux 3.8(미출시)은 popup을 modal floating pane으로 다시 구현한다 (tmux master 소스 조사, 미실측). 출시되면 통합 테스트를 다시 돌린다.
- 크기가 다른 두 client가 같은 workspace를 보면 window가 마지막으로 입력한 client 크기로 오간다 (`window-size latest`, 리뷰 실측). 문서화만 했다.
- agent server의 `prefix`는 전역 하나, origin 경로는 workspace당 하나다. 설정이 다른 host 둘이 같은 agent server를 쓰면 마지막에 연 host 값이 이긴다.
- agent server의 환경 변수는 처음 띄운 popup job의 환경으로 고정된다. pane 안에서 바꾼 PATH(nvm, direnv 등)는 agent에 닿지 않는다. login shell 실행(D8)이 profile의 PATH까지는 채운다.
- `conf/agent-server.conf`는 agent server 시작 때만 읽는다. 플러그인을 업그레이드하면 agent server를 재시작해야 conf 변경이 반영된다.
- `@llm-agent-<name>-cmd`는 셸로 실행된다. 사용자 conf 값이라 신뢰 경계 안이다.
- 테스트는 항상 고유한 `-L` socket을 쓰고, 기본 server와 실제 `llm-agent` socket에는 접근하지 않는다.

## 단계 계획

### M1. 단일 workspace (완료)

- 토글 열기·닫기, 기본 agent 자동 실행, agent 메뉴, 상태줄, 옵션.
- 테스트: 열기, 닫은 뒤 agent 생존, 다시 열 때 상태 유지, agent 추가, 셸 문법이 든 명령, 옵션 변경 반영, 키 변경, 없는 명령·실패한 agent, 마지막 agent 종료, Shift+Enter, agent server 안의 플러그인 무동작.

### M2. 여러 workspace (완료)

- workspace 메뉴(목록·생성·이름 변경·삭제), `@llm_agent_last` hook, 이름 정리.
- 테스트: 생성과 전환, 토글이 마지막 workspace를 여는지, host 메뉴 키, 다른 workspace가 있을 때 마지막 agent 종료.

### 제안 (승인 시 진행)

필요한 항목만 고른다.

- P1. 숨겨 둔 agent 알림
  - 문제: popup을 닫아 둔 사이 agent가 작업을 끝내거나 입력을 기다려도 알 수 없다.
  - 방법: agent server에 `monitor-bell`과 `alert-bell` hook을 두고, 마지막으로 연 host server에 `display-message`와 상태줄용 옵션(`@llm_agent_alert`)을 설정한다.
  - 대가: agent server가 host socket을 기억해야 한다. host server가 여럿이면 마지막 host에만 알린다. agent CLI가 bell을 내도록 설정돼 있어야 한다.
- P2. host 내용을 agent로 보내기
  - 문제: 에러 로그나 선택 영역을 agent에 넘기려면 복사, popup 열기, 붙여넣기를 따로 해야 한다.
  - 방법: host copy-mode에서 키 하나로 선택 영역을 마지막 workspace의 활성 agent pane에 bracketed paste하고 popup을 연다. Enter는 누르지 않는다.
  - 대가: host copy-mode key table에 바인딩이 하나 늘어난다.
- P3. paste buffer 동기화
  - 문제: popup 안에서 복사한 내용이 host의 `prefix + ]`로 붙지 않는다.
  - 방법: agent server copy-mode의 복사 명령을 `copy-pipe`로 바꿔 host server에 `set-buffer`한다.
  - 대가: host socket 추적이 필요하다 (P1과 공유).
- P4. agent resume 항목
  - 문제: agent server가 죽으면 대화 흐름이 끊긴다.
  - 방법: `@llm-agent-<name>-resume-cmd`(예: `claude --continue`)를 두고 agent 메뉴에 resume 항목을 추가한다.
  - 대가: agent마다 resume 방식이 달라 옵션이 늘어난다.

## 요구사항

- tmux 3.4 이상. 테스트를 돌린 가장 오래된 버전이다 (3.4, 3.7b에서 실측). 기능만 보면 `display-popup`의 `-T`, `-b`가 들어온 3.3부터 가능하지만 실측하지 않아 지원 범위에서 뺐다.
- bash 3.2 이상 (macOS 기본 bash 포함). 연관 배열, `mapfile`, `${var,,}`를 쓰지 않는다.
