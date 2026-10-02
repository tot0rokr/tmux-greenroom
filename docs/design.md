# tmux-greenroom 설계

tmux-greenroom의 결정과 그 이유, 근거를 남기는 설계 기록이다. 사용법은 [README.md](../README.md)에 있다.

- 상태 (2026-10-02, [단계 계획](#단계-계획))
  - 완료: M1·M2 (2026-09-30), P1 bell 알림·P2 popup으로 보내기·I1 popup 크기 조절·I2 profile 목록 (2026-10-01), I3 command 메뉴 (2026-10-02).
  - 구현 안 함: P3 paste buffer 동기화. tmux 3.7 이상에서는 clipboard 경로로 충분하다.
  - 뺌: P4 agent resume 항목.
- 지원 범위: tmux 3.4 이상, bash 3.2 이상 ([요구사항](#요구사항)).
- 이름: 처음 이름은 tmux-llm-agent였다. 공개 전에 tmux-greenroom으로 바꿨다. 출연자가 무대에 오르기 전에 대기하는 green room처럼, agent들이 popup 밖에서 돌며 기다린다는 뜻이다. tmux-cuecard와 같은 무대 비유다.
- 근거 표기: (실측)은 격리된 tmux server에서 잰 결과, (조사)는 tmux 소스·문서를 읽은 결과다. (리뷰 실측)·(리뷰 조사)는 코드 리뷰 단계의 것이고, (리뷰 지적)은 코드 리뷰가 짚은 문제다. (미실측)은 재지 않은 추론이다. "실측 N"은 [검증 근거](#검증-근거) 표의 N번 행이다.

## 목차

- [범위](#범위): 목표, 비목표, 요구사항
- [용어](#용어)
- [구조](#구조): server 구성, 파일 구성
- [핵심 결정](#핵심-결정)
  - [D1. 전용 greenroom server](#d1-전용-greenroom-server)
  - [D2. popup job이 맡는 준비와 attach](#d2-popup-job이-맡는-준비와-attach)
  - [D3. greenroom server도 host와 같은 prefix](#d3-greenroom-server도-host와-같은-prefix)
  - [D4. session인 workspace, window인 profile](#d4-session인-workspace-window인-profile)
  - [D5. 사용자 tmux.conf를 읽지 않는 greenroom server](#d5-사용자-tmuxconf를-읽지-않는-greenroom-server)
  - [D6. 메뉴는 `display-menu`, 외부 의존성 없음](#d6-메뉴는-display-menu-외부-의존성-없음)
  - [D7. 여는 때마다 통째로 복사하는 사용자 옵션](#d7-여는-때마다-통째로-복사하는-사용자-옵션)
  - [D8. profile을 실행하는 wrapper](#d8-profile을-실행하는-wrapper)
  - [D9. tmux의 bell flag를 그대로 쓰는 bell 알림](#d9-tmux의-bell-flag를-그대로-쓰는-bell-알림)
  - [D10. host buffer를 거쳐 attach 뒤에 붙여넣는 보내기](#d10-host-buffer를-거쳐-attach-뒤에-붙여넣는-보내기)
  - [D11. host 상태인 popup 크기와 re-open](#d11-host-상태인-popup-크기와-re-open)
  - [D12. id 목록 하나로 만드는 command 메뉴](#d12-id-목록-하나로-만드는-command-메뉴)
- [동작 흐름](#동작-흐름)
- [키 바인딩](#키-바인딩)
- [옵션](#옵션): 사용자 옵션, 플러그인 상태, 이름 변경 이력
- [검증 근거](#검증-근거): 실측 표, 코드 리뷰에서 고친 것, 통합 테스트
- [선행 사례](#선행-사례)
- [위험과 알려진 제약](#위험과-알려진-제약)
- [단계 계획](#단계-계획)

## 범위

### 목표

- 어느 tmux session·window에서든 같은 키로 popup을 열고 닫는다.
- popup을 닫으면 detach만 한다. window의 프로세스는 계속 돌고, 다시 열면 그 화면 그대로 이어서 쓴다.
- popup 하나에 window를 여러 개 띄운다. 용도별로 이름 붙인 popup(workspace)도 여러 개 둔다.
- Claude Code, Codex, Gemini CLI, OpenCode를 기본 profile로 두고, 다른 CLI는 옵션 한 줄로 추가한다.

### 비목표

- tmux server 재시작이나 재부팅 뒤 agent 대화 복원. agent CLI의 resume 기능(`claude --continue` 등) 영역이다. resume 항목을 따로 두는 안(P4)도 뺐다.
- 한 화면에 popup 여러 개를 동시에 표시. tmux 3.7까지 popup은 client당 overlay 하나다. workspace는 여러 개지만 한 client에 보이는 건 한 번에 하나다.
- agent CLI 자체의 설정·인증 관리. agent CLI가 터미널 bell을 내게 하는 설정도 사용자 몫이다 (D9).

### 요구사항

- tmux 3.4 이상. 테스트를 돌린 가장 오래된 버전이다 (3.4, 3.7b에서 실측). 기능만 보면 `display-popup`의 `-T`, `-b`가 들어온 3.3부터 가능하지만 실측하지 않아 지원 범위에서 뺐다.
- bash 3.2 이상 (macOS 기본 bash 포함). 연관 배열, `mapfile`, `${var,,}`를 쓰지 않는다.
- runtime 의존성은 bash와 tmux뿐이다. 메뉴도 tmux 내장 `display-menu`로 만든다 (D6).

## 용어

| 용어             | 뜻                                                                        |
| ---------------- | ------------------------------------------------------------------------- |
| host server      | 사용자가 평소 쓰는 tmux server                                            |
| greenroom server | 이 플러그인 전용 tmux server, `tmux -L greenroom`                         |
| workspace        | greenroom server의 session 하나. popup 하나에 대응                        |
| profile          | 이름 붙은 명령 하나(`claude`, `shell`, `lazygit` 등). profile 메뉴의 항목 |
| window           | workspace의 window 하나. profile 하나를 실행                              |
| origin pane      | popup을 연 host pane. 새 window의 작업 디렉토리 기준                      |
| host client      | popup을 띄운 host server의 client                                         |
| popup job        | popup 안의 프로세스. `attach.sh`로 시작해 `tmux attach`가 된다            |
| inner client     | popup job이 된 greenroom server의 client                                  |
| re-open          | 크기를 바꾸려고 같은 host client의 popup을 닫고 바로 다시 여는 것 (D11)   |

## 구조

### server 구성

```
 host server (your tmux)                 greenroom server (tmux -L greenroom)
┌────────────────────────────────┐      ┌───────────────────────────────────┐
│ session "work"                 │      │ workspace "main"                  │
│  └ popup: attach.sh ───────────┼─────▶│  ├ window 0: claude               │
│                                │      │  └ window 1: codex                │
│ session "notes"                │      │                                   │
│  └ popup: attach.sh ───────────┼─────▶│ workspace "review"                │
│                                │      │  └ window 0: claude               │
└────────────────────────────────┘      └───────────────────────────────────┘
```

- 어느 host session에서 열든 같은 greenroom server에 붙는다. 두 host client가 같은 workspace를 동시에 열 수도 있다.
- popup 안의 프로세스는 `tmux -L greenroom attach` 하나뿐이다. window의 프로세스는 greenroom server가 소유한다.

### 파일 구성

```text
greenroom.tmux              TPM entry: bind host keys
conf/greenroom-server.conf  greenroom server defaults: marker, status line, terminal features
scripts/helpers.sh          option lookup, quoting, raw option reads
scripts/open.sh             open the host popup at the current size (host)
scripts/attach.sh           popup job: pick and prepare a workspace, attach
scripts/size.sh             popup size keys: store the size, re-open (greenroom server)
scripts/run-profile.sh      profile wrapper run by every window
scripts/workspace-menu.sh   workspace menu and its actions (greenroom server)
scripts/new-workspace.sh    create a workspace from the menu prompt
scripts/rename-workspace.sh rename a workspace from the menu prompt
scripts/alert.sh            bell alerts to the host (greenroom server hooks)
scripts/send.sh             send a selection or a pane screen (host)
scripts/paste.sh            paste sent text after attach (greenroom server)
tests/run.sh                integration tests on isolated tmux servers
```

## 핵심 결정

### D1. 전용 greenroom server

- workspace를 host server의 session으로 두지 않고 `tmux -L <socket>` 전용 server에 둔다.
- 이유
  - host의 session 목록(`choose-tree`, `switch-client -n`, tmux-fzf, tmux-resurrect)을 오염시키지 않는다. tmux-toggle-popup도 같은 이유로 전용 server를 기본값으로 둔다.
  - popup 안에서 `prefix` + `s`/`w`를 누르면 workspace와 그 window만 보인다.
  - host server를 kill해도 window는 산다. 같은 사용자의 다른 host server(`tmux -L work` 등)에서도 같은 workspace를 연다.
- 대가
  - paste buffer가 server별로 분리된다. OSC 52 clipboard가 popup을 통과하는 건 tmux 3.7부터다 (tmux CHANGES "3.6b TO 3.7", 리뷰 조사). buffer 동기화(P3)는 구현하지 않았다 ([단계 계획](#p3-paste-buffer-동기화-구현-안-함)).
  - greenroom server에 설정과 바인딩을 따로 적용해야 한다 (D3, D5, D7).
- 기각안: host server에 숨긴 session (tmux-floax, tmux-claude-hatch 방식). 코드는 더 짧지만 목록 오염이 그대로 남는다.

### D2. popup job이 맡는 준비와 attach

- host 바인딩은 `run-shell -b`로 `open.sh`를 실행하고, `open.sh`가 `display-popup -E -d <origin 경로> ... attach.sh`로 popup을 연다 (D11).
- `attach.sh`는 popup 안에서 실행된다. greenroom server와 workspace가 없으면 만들고, 설정을 적용한 뒤 `exec tmux -L <socket> attach`한다.
- 이유
  - popup job의 cwd가 곧 origin pane 경로다. `attach.sh` 명령에 경로를 끼워 넣지 않으므로 공백·따옴표가 있어도 안전하다. 바인딩에서 `open.sh`로 넘길 때는 `#{q:pane_current_path}`가 셸용으로 quote한다. `-d`는 format으로 확장되어 `open.sh`가 `format_escape`한다 (tmux 3.3a `cmd-display-menu.c`, 리뷰 조사).
  - popup job의 `$TMUX`는 host server를 가리키므로 host 옵션을 바로 읽는다.
- 주의
  - popup 안에서 `-L` 없이 `tmux`를 부르면 `$TMUX` 때문에 host server로 간다. host 쪽 코드의 greenroom server 호출은 항상 `-L`을 붙인다. greenroom server 안에서 도는 스크립트는 `$TMUX`가 greenroom server라 `-L`이 필요 없다.
  - greenroom server를 새로 띄울 때는 `TMUX`, `TMUX_PANE`을 지운다. `TMUX_PANE`이 남으면 greenroom server 전역 환경으로 새어 들어간다 (리뷰 실측).
  - `display-popup`의 shell-command는 format으로 확장되지 않는다 (실측 9). `open.sh`가 넘기는 `attach.sh` 명령에는 `#` escape를 하지 않는다. format으로 확장되는 `run-shell` 바인딩 안의 `open.sh` 경로는 escape한다.

### D3. greenroom server도 host와 같은 prefix

- `attach.sh`가 host의 `prefix`, `prefix2`를 읽어 여는 때마다 greenroom server에 설정한다. `prefix`가 `None`이 아니면 `prefix` + `prefix`를 `send-prefix`로 바인딩한다.
- popup이 열려 있는 동안 host는 key table을 처리하지 않고 모든 키를 popup job에 넘긴다. 그래서 중첩 tmux의 이중 prefix 문제가 없다.
  - 실측: 검증 근거 1~3.
  - 사실: tmux 3.3a `server-client.c`의 `server_client_handle_key`는 key table 조회보다 `overlay_key`를 먼저 호출한다 (조사, 리뷰가 교차 확인).
- 닫기 키는 host의 열기 키와 같은 키를 greenroom server에서 `detach-client`로 바인딩해 만든다. 같은 키가 열고 닫는 토글이 된다.
- 바인딩한 키는 양쪽 server의 `@greenroom_bound`에 기록하고, 다음 적용 때 먼저 unbind한다. 키 옵션을 바꿔도 옛 키가 남지 않는다.
  - greenroom server에서 tmux 기본 바인딩이 있는 `c`, `M`, `z`(플러그인 기본 키)와 `-`, `=`(README 예시)는 unbind 대신 tmux 바인딩(`new-window`, `select-pane -M`, `resize-pane -Z`, `delete-buffer`, `choose-buffer -Z`)으로 되돌린다. 그 밖의 키는 greenroom server를 재시작할 때까지 비어 있다.
  - 이유: tmux에는 기본 바인딩 하나를 되살리는 명령이 없다. 처음 바인딩하기 전 값도 읽을 수 없다. 새 greenroom server는 바인딩을 넣는 그 준비 명령 안에서 뜬다.

### D4. session인 workspace, window인 profile

- popup 하나가 workspace(session) 하나, 그 안의 탭이 window다. window마다 profile 하나를 실행한다.
- tmux 기본 기능이 그대로 동작한다.
  - `prefix` + `n`/`p`/숫자: window 전환
  - `prefix` + `&`: window 종료
  - `prefix` + `$`: workspace 이름 변경
  - `prefix` + `s`: workspace 전환
- 기각안: profile마다 session. 한 popup에서 window를 탭처럼 오가려면 전환 UI를 직접 만들어야 한다.

### D5. 사용자 tmux.conf를 읽지 않는 greenroom server

- greenroom server는 시작할 때 `-f conf/greenroom-server.conf`와, 설정돼 있으면 `-f <@greenroom-config>`를 읽는다.
  - `-f`를 여러 번 주면 순서대로 모두 읽고, 한 파일의 에러가 이어지는 준비 명령을 끊지 않는다 (실측 10). 사용자 conf의 오타가 workspace 준비를 막지 않는다. 다만 없는 명령 같은 파싱 에러가 있으면 그 파일 전체가 적용되지 않는다.
- 이유: 사용자 conf를 읽으면 TPM이 모든 플러그인을 greenroom server에서 다시 실행한다. tmux-continuum 같은 플러그인은 host의 저장본을 greenroom server 상태로 덮어쓸 수 있다.
- popup 안에서 쓰고 싶은 플러그인은 `@greenroom-config` 파일에서 직접 `run-shell`한다. 예: `run-shell ~/.tmux/plugins/tmux-cuecard/cuecard.tmux`.
- `conf/greenroom-server.conf`는 `@greenroom_server`를 설정하고, `greenroom.tmux`는 이 값이 있으면 아무것도 하지 않는다. 사용자가 전체 conf를 지정해도 이 플러그인이 greenroom server 안에서 host 바인딩을 만들지는 않는다. 다른 플러그인의 부작용은 막지 못한다.
  - 초안의 환경 변수 방식(`GREENROOM_SERVER=1`)은 버렸다. greenroom server의 pane에서 띄운 다른 tmux server로 새어 나가 거기서 플러그인이 꺼진다 (리뷰 실측).

### D6. 메뉴는 `display-menu`, 외부 의존성 없음

- profile, workspace, command 메뉴를 모두 tmux 내장 `display-menu`로 만든다. bash와 tmux만 있으면 된다.
- escape와 quoting
  - `display-menu`의 이름과 명령은 format으로 확장된다 (man page). 메뉴 명령에 넣는 문자열은 `#`을 `##`로 escape한다.
  - 셸과 tmux parser 양쪽에 같은 single-quote 규칙(`'\''`)을 쓴다. tmux parser도 sh처럼 인접 quoted 토큰을 이어 붙인다 (실측 11).
  - profile·command 메뉴는 첫 항목 이름이 `-`로 시작하면 `display-menu`가 flag로 읽어 실패하므로 항목 앞에 `--`를 둔다. `-`로 시작하는 이름은 비활성으로 그려져서 앞에 `#[default]`를 붙인다 (실측). workspace 메뉴는 둘 다 하지 않는다 ([위험과 알려진 제약](#위험과-알려진-제약)).
- 사용자가 입력하는 workspace 이름은 `command-prompt`의 `%%%`(따옴표 escape)로 option에 먼저 저장하고, 스크립트가 option에서 읽는다. 입력값이 셸 명령줄을 거치지 않는다. option은 client마다 따로 둔다 (`@greenroom_pending_<client pid>`).
- profile 메뉴는 `@greenroom-profiles` 목록 하나가 구성과 순서를 모두 정한다. `|`는 구분선이고, `shell`도 자동으로 붙이지 않는 일반 항목이다. 추가·삭제·순서 변경이 옵션 한 줄로 끝난다.
  - 이름은 `[A-Za-z0-9_-]`만 쓴다. 잘못된 이름은 건너뛰고, 중복 이름은 첫 자리만 남긴다. `@greenroom-default`는 목록과 별개라 목록에 없는 이름도 된다.
  - 앞·끝·연속 `|`는 플러그인이 지운다. tmux는 앞 구분선을 버리고 연속 구분선을 합치지만 끝 구분선은 그린다 (실측, 3.4·3.7b).
  - 목록이 비거나 구분선뿐이면 비활성 항목 `no profiles configured` 하나만 보인다. 빈 값은 기본값이 아니라 빈 메뉴다.
  - profile 옵션은 `@greenroom-profile-` 접두어를 써서 플러그인 키 옵션(`@greenroom-root-key` 등)과 이름이 겹치지 않는다. `root`, `send`, `grow` 같은 이름의 profile도 자기 `@greenroom-profile-<name>-key`를 쓴다.
- 단축키 규칙 (`menu_keys`, command 메뉴도 같다)
  - 명시 키(`@greenroom-profile-<name>-key`)를 목록 순서로 먼저 배정한다. 앞 항목이 이미 잡은 키를 뒤 항목이 또 지정하면 뒤 항목은 자동 규칙으로 간다.
  - 자동 단축키는 이름에서 아직 안 쓴 첫 소문자·숫자다. 항목 단축키는 `display-menu`의 내장 키보다 우선하므로 자동 단축키는 `q j k g G`를 피한다. 명시 키는 이 키도 쓸 수 있다.
  - 화살표 키는 단축키로 발동하지 않으므로 자동 규칙으로 돌린다. 맨 화살표는 3.7b에서, modifier가 붙은 화살표(`S-Up`, `C-Up`, `M-Up`)는 3.4·3.7b 모두 그렇다 (실측). 이름 있는 키는 대소문자를 가리지 않아 `up`도 `Up`이다.
  - `;`로 끝나는 단축키(`;`, `M-;`)는 `tmux_arg`를 두 번 거친다. `bind-key`가 명령 인자를 한 번 더 parse하므로, 한 번만 escape하면 `;`가 `display-menu`를 끊고 준비 명령 전체가 실패한다 (실측, 3.4·3.7b).

### D7. 여는 때마다 통째로 복사하는 사용자 옵션

- 옵션 이름공간을 나눈다. `@greenroom-*`는 사용자 옵션, `@greenroom_*`는 플러그인 상태다.
- 여는 때마다 greenroom server의 `@greenroom-*`를 모두 지우고 host의 `@greenroom-*`를 모두 복사한다. host에서 바꾸거나 지운 옵션이 다음 열기에 반영된다.
- 값은 paste buffer를 거쳐 읽는다 (`run-shell -C 'set-buffer "#{q:...}"'` 후 `save-buffer -`).
  - 이유: tmux 3.4는 `show-option`, `display-message`, `show-options` 출력에서 `$`를 escape하고 백슬래시는 그대로 둔다. 출력만으로는 원래 값을 되살릴 수 없다 (실측 12). profile 명령에는 `$`가 흔히 들어간다.
  - greenroom server 안의 `run-profile.sh`도 같은 방식으로 명령을 읽는다.
- host의 동작 옵션(`default-terminal`, `history-limit`, `mouse`, `mode-keys`, `status-keys`, `base-index`, `pane-base-index`, `escape-time`, `extended-keys`, `set-clipboard`)은 greenroom server가 뜰 때 한 번만 복사한다.
- 모든 준비 명령은 tmux 호출 하나로 묶어 보낸다. 두 client가 동시에 열어 한쪽의 `new-session`이 실패해도, workspace가 결국 있으면 그대로 attach한다.

### D8. profile을 실행하는 wrapper

- window는 profile 명령을 직접 실행하지 않고 `run-profile.sh <name>`을 실행한다.
- wrapper는 명령을 `$SHELL -lc`로 실행한다. login shell이라 사용자 셸 설정(`~/.profile` 등)의 PATH가 적용된다.
- exit status가 0이 아니면 `[<name> exited with status N. Press any key to close.]`를 출력하고 키 하나를 기다린 뒤 끝난다.
  - 초안의 `remain-on-exit failed`는 버렸다. Ctrl-C에 0이 아닌 status로 끝나는 CLI는 매번 죽은 pane을 `prefix` + `x`로 치워야 했다 (리뷰 지적).
  - wrapper는 `trap : INT`로 Ctrl-C를 견딘다. 무시(`trap '' INT`)가 아니라 handler라서 실행한 명령에 상속되지 않는다.
- `shell` profile은 `@greenroom-profile-shell-cmd`가 없으면 wrapper가 `exec -l "$SHELL"`로 login shell이 된다. 옵션이 있으면 다른 profile과 같은 경로로 실행한다.
- 메뉴에서 PATH에 없는 profile을 비활성으로 표시하는 기능은 버렸다. 검사하는 환경(popup job)과 실행 환경(login shell)의 PATH가 달라 오탐이 난다. 없는 명령은 status 127로 알려 준다.

### D9. tmux의 bell flag를 그대로 쓰는 bell 알림

- 알림의 근원은 window의 프로그램이 내는 터미널 bell 하나다. 플러그인은 agent CLI 설정을 건드리지 않는다. bell을 내게 할지는 사용자가 agent CLI 쪽(예: 작업 종료 hook)에서 정한다.
- tmux는 아무 client도 보고 있지 않은 window에만 bell flag를 세우고, client가 그 window를 보면 지운다 (실측 17). 그래서 "놓친 bell" 목록은 `window_bell_flag`가 1인 window 그대로다. 플러그인이 따로 상태를 들고 있지 않는다.
- greenroom server의 `alert-bell` hook이 `alert.sh bell`을, attach·전환·window 종료 hook들이 `alert.sh refresh`를 실행한다.
  - `alert.sh`는 목록을 host의 `@greenroom_alert`에 `<window>@<workspace>`를 공백으로 이은 값으로 쓴다.
  - bell일 때는 host client마다 `greenroom: <window>@<workspace> rang the bell`을 `display-message`로 띄운다.
- popup 안 window 목록은 bell flag가 선 window 이름 뒤에 `!`를 붙인다 (`conf/greenroom-server.conf`의 `window-status-format`).
- greenroom server는 `bell-action any`로 둔다. 기본값 `other`에서는 popup이 닫힌 workspace의 현재 window bell에 hook이 돌지 않는다 (실측 18).
- host socket은 `attach.sh`가 보통 열기마다 `@greenroom_host`에 기록한다 (re-open은 건너뛴다). 알림은 마지막으로 연 host로 간다.
- status line 표시는 사용자가 `status-right`에 `#{@greenroom_alert}` 조건부 구간을 넣는다. 사용자 status line을 플러그인이 고치지 않는다. 옵션이 없으면 구간이 비므로 플러그인이 없는 환경에서도 그대로 둘 수 있다.
- hook은 slot 101(알림), 100(마지막 workspace)에 두고, 둘 다 `attach.sh`가 보통 열기마다 다시 건다. index 없는 `set-hook`은 배열 전체를 바꿔 플러그인 slot도 지우기 때문이다 (실측, 3.4·3.7b). 처음에는 slot 100을 `conf/greenroom-server.conf`에만 둬서, `@greenroom-config`의 index 없는 `set-hook`이 마지막 workspace 추적을 server 재시작 때까지 끊었다 (문서 검증에서 발견). `@greenroom-config`의 hook은 `-a`나 `[0]`처럼 index를 주면 플러그인 hook과 함께 남는다.

### D10. host buffer를 거쳐 attach 뒤에 붙여넣는 보내기

- copy-mode의 `pipe-and-cancel`(복사하지 않고 넘기기만 함)이나 `capture-pane`으로 얻은 텍스트를 `send.sh`가 host buffer `greenroom_send`에 넣고 popup을 연다. 공백뿐인 텍스트는 보내지 않고 popup도 열지 않는다.
- popup의 `attach.sh --paste`가 그 buffer를 greenroom server로 옮기고, attach 직후 `paste.sh`가 workspace의 active pane에 `paste-buffer -p`(bracketed paste)한다. Enter는 보내지 않는다.
- 새로 만든 workspace의 첫 window는 아직 입력을 받지 못할 수 있다. tmux에는 bracketed paste 모드를 알려 주는 format이 없어서, 화면이 그려지고 0.3초 간격 두 번 같을 때까지(최대 10초) 기다린 뒤 붙여넣는다. 이미 떠 있는 window에는 바로 붙여넣는다.
- 사용자 paste buffer와 clipboard는 건드리지 않는다. 쓰고 난 `greenroom_send`는 지운다.

### D11. host 상태인 popup 크기와 re-open

- 크기는 host server의 상태 옵션이다. 크기 키를 누르면 greenroom server의 `size.sh`가 새 크기를 host에 쓰고, host가 같은 client에 같은 workspace로 popup을 닫았다 다시 연다. window는 resize만 겪는다.
- 이유: 열린 popup의 크기를 바꾸는 명령이 없다. 이미 popup이 떠 있는 client에 `display-popup`을 다시 하면 조용히 버려진다 (실측 26). `-w`, `-h`는 format으로 확장되지 않아서 바인딩이 상태 옵션을 직접 쓸 수도 없다 (실측 21).
- host popup은 `scripts/open.sh` 한 곳에서만 연다.
  - host 바인딩은 `run-shell -b "open.sh '#{client_name}' #{q:pane_current_path}"`다. `display-popup`은 `-e`도 shell-command도 확장하지 않아 client 이름을 job에 넘길 수 없고, `run-shell`은 확장한다 (실측 22). `send.sh`도 `open.sh --paste`를 쓴다.
  - `-c <client>`로 연다. command client의 `display-popup` 안 format은 그 client가 아니라 최근 활성 session 기준이라 (실측 23), 경로는 확장된 값을 받아 `format_escape`, `tmux_arg`를 거쳐 `-d`에 넣는다.
  - 옵션은 `display-message -p` 한 번으로 읽는다. 스크립트를 거치면 열기가 15~18ms 늦어지고 tmux 호출 하나가 3.6~5.5ms 더한다 (실측 24). 크기·위치 값에는 `$`가 없어서 `read_raw_options`가 필요 없다.
  - `@greenroom-y`가 기본값 `C`면 `open.sh`가 `-y`를 `#{client_height}`, `#{popup_height}`로 계산해 client 전체의 가운데에 둔다. 남는 줄이 홀수면 아래에 한 줄 더 둔다. tmux의 `C`는 홀수 행 client의 짝수 행 popup만 가운데에 두고 나머지는 한 줄 위에 둔다. 그래서 95%면 21~40행은 모두, 41~60행은 짝수 행(50, 60행 등)에서 위 테두리가 0행에 닿았다 (실측 35). `-y`는 format으로 확장되고, 그 안의 client format은 `-c` client의 값이다 (실측 36).
  - `display-popup`은 popup이 닫힐 때까지 돌아오지 않는다. 그래서 `open.sh`는 늘 `run-shell -b`나 그 job 안에서 돈다. 끝 status는 popup job의 status이고 re-open이 지우면 129다 (실측 25). `run-shell -b`는 0 아닌 status를 pane에 띄우고 stderr는 버리므로 (실측 31), `open.sh`는 status를 버리고 에러 메시지만 `display-message`로 보인다.
- 상태와 동작
  - `@greenroom_size_width`, `@greenroom_size_height`: 보통 크기, `80%` 같은 %. 없으면 `@greenroom-width`, `@greenroom-height`(기본 80%).
  - `@greenroom_size_large`: large 모드일 때 1. 크기는 `@greenroom-large-width`, `@greenroom-large-height`(기본 95%). 100%가 아니라서 테두리와 host 여백이 남아 popup으로 보인다. 20행 이하에서는 남는 줄이 하나라 위 테두리가 맨 윗줄에 닿는다.
  - `large`는 large 모드를 토글한다. `grow`, `shrink`는 보통 크기를 가로·세로 모두 `@greenroom-resize-step`(기본 10)%p 바꾸고 20~95%로 자르며 large 모드를 끝낸다. `reset`은 상태를 지운다.
  - 사용자 옵션이 셀 수(`%` 없음)면 `grow`, `shrink`가 popup이 뜬 host client의 크기로 %로 바꾼다. %는 status line을 포함한 client 전체 기준이다 (실측 21). `display-message -c <client>`는 최근 활성 client의 크기를 주므로 상태와 크기를 `list-clients -F` 한 번으로 읽고 그 client 줄을 쓴다 (실측 34).
  - 결과가 지금 상태와 같으면(95%에서 `grow`) 다시 열지 않는다.
  - host server 옵션이라 popup을 닫았다 열어도, `prefix` + `S`로 열어도 유지되고, reset이나 host server 재시작으로 사라진다. host client 모두가 하나를 같이 쓴다.
- re-open
  - `size.sh`는 상태를 쓰는 명령과 `run-shell -b "open.sh <client> <origin> --reopen <workspace>"`를 host 호출 하나로 보내고 바로 끝난다. popup을 기다리는 `display-popup`은 host job에 남고 greenroom server에는 job이 남지 않는다 (실측 25).
  - `open.sh --reopen`은 `display-popup -C -c <client> ; display-popup -c <client> ...`를 한 명령 목록으로 보낸다. 두 번 나눠 부르면 host pane이 비치고 그 사이 키가 host pane으로 간다 (실측 27, 28). `-C`를 빼면 3.4는 무시하고 3.7b는 제목·테두리만 바꾼다 (실측 26).
  - 시작 디렉토리는 workspace의 `@greenroom_origin`(raw로 읽음)이다.
  - 새 popup job은 `attach.sh --reopen`이다. workspace와 설정은 준비돼 있으므로 host client만 기록하고 바로 attach한다. 보통 열기처럼 준비를 다시 하면 새 popup이 0.5초쯤 빈 채로 있다 (실측 32). 준비를 건너뛴 뒤에는 키부터 새 client까지 0.2~0.3초다. `@greenroom_origin`도 건드리지 않는다.
  - 결과: 같은 workspace, 같은 pane id, inner client 하나.
- host client 찾기
  - `open.sh`가 host client 이름을 `attach.sh --client`로 넘긴다. `attach.sh`는 준비 명령에 `set-option -g @greenroom_host_client_<$$> <client>`를 넣고 `exec tmux attach`한다. 그래서 `$$`가 inner client의 `#{client_pid}`다 (실측 30). 크기 키는 `'#{client_pid}'`로 이 기록을 찾는다.
  - 보통 열기는 `list-clients`에 없는 pid의 기록을 같은 준비 명령에서 지운다. re-open은 지우지 않는다. 사라지는 client가 마지막으로 보낸 크기 키도 자기 기록을 찾아야 한다.
  - 기록이 없으면 아무것도 하지 않는다. 크기 키는 greenroom server의 모든 client에 걸리므로, greenroom server에 직접 attach한 client에서 누르면 첫 host client로 가는 대체 규칙이 그 host에 popup을 열고 같은 workspace에 inner client를 하나 더 붙였다 (리뷰 실측, 3.4·3.7b). 기록 없는 popup은 기록을 넣기 전의 `attach.sh`가 연 것뿐이고, 다음 열기부터 기록이 생긴다.
  - 기각안: 최근 활성 host client. popup이 떠 있는 동안 host의 `client_activity`가 바뀌지 않아 client가 둘이면 틀린다 (실측 29). session 환경(`update-environment`)은 session마다 마지막 attach 값이라 틀리고, `/proc/<pid>/environ`은 Linux 전용이다.
- 동시 실행: re-open 중에 친 키는 새 inner client에 한꺼번에 도착한다. 크기 키 둘이 같이 돌면 같은 상태를 읽어 한 단계가 사라져서 (실측 33), `size.sh`는 greenroom server의 `wait-for -L greenroom_size`로 차례를 지킨다.
- 키: `@greenroom-large-key`(기본 `z`, zoom), `@greenroom-grow-key`, `@greenroom-shrink-key`, `@greenroom-reset-key`(기본 없음 = 바인딩 안 함). popup 안 prefix table에 묶고 `@greenroom_bound`로 관리한다. `z`는 tmux의 pane zoom 키를 대신하므로 `@greenroom-large-key`를 빈 값으로 두면 바인딩하지 않는다. 실행 중인 greenroom server에서 빈 값이나 다른 키로 바꾸면 다음 열기에서 `z`를 tmux zoom으로 되돌린다 (D3).
- 진입점은 `size.sh <action> <client_pid> <workspace> [rows]` 하나다. 다른 UI(메뉴 등)도 같은 명령을 부른다. `rows`는 command 메뉴의 `shrink`가 넘기는 메뉴 높이다 (D12).

### D12. id 목록 하나로 만드는 command 메뉴

- popup 안 `prefix` + `M`(`@greenroom-commands-key`)이 command 메뉴를 연다. 항목과 순서는 `@greenroom-commands`의 id 목록이 정한다. 기본값은 `profiles workspaces | large grow shrink reset | hide`다.
- 목록 문법과 단축키 규칙은 profile 메뉴(D6)와 같고, `attach.sh`의 같은 함수(`menu_entries`, `menu_keys`)를 쓴다.
  - built-in id의 기본 키(`c w z + - = h n r x X`)도 명시 키로 친다. 목록 순서로 먼저 잡은 항목이 갖고, 뒤 항목과 화살표 키는 자동 규칙으로 간다.
  - 자동 단축키는 label이 아니라 id에서 고른다. profile 메뉴의 이름 규칙과 같다.
  - 정의 안 된 id는 비활성 `<id> (not defined)`로 그리고 단축키를 주지 않는다. 뒤 항목의 자동 단축키를 빼앗지 않는다.
  - 목록이 비거나 구분선뿐이면 비활성 항목 `no commands configured` 하나만 보인다.
- 메뉴는 profile 메뉴처럼 여는 때마다 `attach.sh`가 만들어 키에 `display-menu`로 직접 바인딩한다.
  - 이유: 키 바인딩의 `display-menu`는 키를 누른 client와 그 session을 context로 쓴다. 항목 명령의 `#{client_name}`, `#{client_pid}`, `#{session_name}`과 사용자 명령이 직접 바인딩한 키처럼 그 popup에서 돈다 (테스트 `command_menu_actions_act_in_their_own_popup`).
  - 항목이 option에만 달려 있어 여는 때 만들면 된다. workspace 메뉴처럼 키를 누를 때 job이 메뉴를 만들면 job이 뜨는 동안 늦고, 스크립트의 `display-menu -c`에는 target session을 따로 줘야 한다 (미실측. 실측 23의 command client와 같은 경로).
- built-in 동작은 같은 일을 하는 키·메뉴의 명령을 그대로 쓴다.
  - `profiles`: profile 메뉴의 `display-menu` 인자를 명령 한 줄로 이어 붙인 것(`command_line`). command 메뉴의 확장에 맞춰 `#`을 escape하되 `#[` style은 그대로 둔다. tmux 확장은 `##[`를 줄이지 않고 남기므로, 모두 escape하면 중첩 메뉴가 제목의 `#[align=centre]`와 `-` 이름 앞 `#[default]`를 글자로 그렸다 (리뷰 실측, 3.4·3.7b).
  - `workspaces`, 크기 항목: 각 키 바인딩과 같은 `run-shell` 명령. 크기는 `size.sh`(D11).
  - `shrink`는 메뉴 높이(항목, 구분선, 위아래 테두리)도 넘긴다. `size.sh`는 줄인 popup 안이 그보다 낮아지면 줄이지 않는다. tmux는 client보다 높은 메뉴를 메시지 없이 그리지 않는데, grow·reset은 기본 키가 없어 메뉴가 안 열리면 되돌릴 방법이 `prefix` + `z`뿐이었다 (리뷰 실측, 3.4·3.7b). 크기 키의 shrink는 그대로 20%까지 간다.
  - `new-workspace`, `rename-workspace`, `kill-workspace`: `workspace-menu.sh <client> new|rename|kill`. workspace 메뉴의 그 항목 명령을 `-t <client>`로 바로 실행한다. 값은 `client_values`로 읽는다.
  - 이 prompt는 `-b`로 띄운다. job이 답을 기다리면 n에 job이 실패해 pane이 `returned 1`을 보였고, 답하기 전에 popup이 사라지면 job이 끝나지 않아 마지막 workspace가 닫혀도 greenroom server가 남았다 (리뷰 실측, 3.4·3.7b).
  - `kill-window`: tmux의 `prefix` + `&`처럼 `confirm-before -p 'kill window #W? (y/n)' kill-window`. 확인한 client의 현재 window가 대상이다.
  - `hide`: `detach-client`.
- 사용자 명령 `@greenroom-command-<id>-run`은 쓴 그대로 항목 명령에 넣는다. `display-menu`는 메뉴를 그릴 때 명령의 format을 확장하므로 글자 `#`는 `##`로 써야 한다. 메뉴를 연 뒤 바꾼 option 값이 아니라 연 때의 값이 들어간다 (실측, 3.4·3.7b).
- id별 옵션은 `@greenroom-command-<id>-label`, `-key`, `-run`이고, 셋 다 접미어가 반드시 붙는다.
  - 이유: id에 `-`가 들어갈 수 있다. 접미어 없는 옵션(`@greenroom-command-<id>`)을 두면 id `x-key`의 명령 옵션이 id `x`의 단축키 옵션과 같은 이름이 된다. 세 접미어는 어느 것도 다른 것의 끝부분이 아니므로 id가 다르면 옵션 이름도 반드시 다르다.
  - 접두어 `@greenroom-command-`는 목록 `@greenroom-commands`, 메뉴 키 `@greenroom-commands-key`와도 겹치지 않는다. `command` 다음 글자가 `-`와 `s`로 갈린다.
  - built-in id는 `-run`을 무시한다. 사용자가 built-in 동작을 다른 명령으로 바꾸려면 다른 id를 쓴다.
- `M`은 tmux 기본 바인딩(`select-pane -M`, 표시한 pane 해제)이 있는 키다 (실측, 3.4·3.7b `list-keys`). 빈 값이면 바인딩하지 않고, 키를 바꾸거나 비우면 D3대로 tmux 바인딩을 되돌린다.
- status line 힌트에 `<prefix> <키> menu`를 더했다. 키가 비면 숨긴다. 메뉴 제목 ` commands `와 다른 낱말을 써서 화면에서 메뉴를 찾는 테스트가 status line과 헷갈리지 않는다.

## 동작 흐름

### popup 열기

1. host에서 `prefix` + `g`를 누른다.
2. host가 `run-shell -b`로 `open.sh`를 실행하고, `open.sh`가 현재 크기로 `display-popup -c <client> -E -d <origin 경로>`를 열어 `attach.sh --client <client>`를 실행한다 (D11).
3. `attach.sh`가 대상 workspace를 정한다. 순서: 인자, `@greenroom_last`, `@greenroom-workspace`(기본 `main`) 중 존재하는 것, 아무 workspace, 없으면 `@greenroom-workspace`를 새로 만든다. greenroom server가 없으면 host에 남은 `@greenroom_alert`를 지운다.
4. 준비 명령을 tmux 호출 하나로 보낸다 (D7).
   - greenroom server가 없으면 이때 뜨고, host의 동작 옵션을 한 번 복사한다 (D7).
   - 사용자 옵션 복사 (D7), 상태 옵션 기록, 옛 바인딩 해제와 새 바인딩 (D3), 알림 hook과 `@greenroom_host` (D9), host client 기록 (D11).
   - workspace가 없으면 `@greenroom-default` profile의 window 하나로 만든다.
   - workspace에 `@greenroom_origin`으로 origin 경로를 기록한다.
5. `exec tmux -L <socket> attach -t =<workspace>`. `--menu`(host `prefix` + `G`)면 attach 뒤 workspace 메뉴를, `--paste`(D10)면 `paste.sh`를 같은 호출에서 `run-shell -b`로 띄운다.
6. 준비가 실패하고 workspace도 없으면 에러를 출력하고 키 입력을 기다린다. `-E` popup이 에러를 보여 주기 전에 닫히지 않게 한다.

### popup 닫기

- popup 안에서 `prefix` + `g`(열기와 같은 키), `prefix` + `d`, 설정한 `@greenroom-root-key`, 또는 command 메뉴의 `hide`를 고른다.
- inner client가 detach되면 attach 프로세스가 끝나고 `-E` popup이 닫힌다. window는 계속 실행된다.

### popup 크기 바꾸기

1. popup 안에서 `prefix` + `z`, 설정한 grow·shrink·reset 키, 또는 command 메뉴의 크기 항목을 고른다.
2. `size.sh`가 lock을 잡고, `@greenroom_host_client_<client_pid>`로 host client를 찾고, host 상태와 client 크기를 읽어 새 상태를 계산한다.
3. 새 상태를 쓰는 명령과 `run-shell -b open.sh ... --reopen <workspace>`를 host 호출 하나로 보내고 끝난다.
4. host의 `open.sh`가 `display-popup -C` 뒤에 새 크기의 `display-popup`을 한 명령 목록으로 연다. 새 popup의 `attach.sh --reopen`은 host client를 기록하고 바로 attach한다.

### window 추가

- popup 안에서 `prefix` + `c`(`@greenroom-profiles-key`)를 누르면 profile 메뉴가 뜬다. command 메뉴의 `profiles`도 같은 메뉴다.
- 항목은 `@greenroom-profiles` 순서 그대로다. 기본값 `claude codex gemini opencode | shell`은 agent CLI 넷, 구분선, `shell` 순이다. 목록 문법과 단축키는 D6.
- 고른 profile을 `@greenroom_origin` 경로에서 새 window로 실행한다. window 이름은 profile 이름이다.

### window 종료

- window의 명령이 status 0으로 끝나면 window가 닫힌다. 그 밖의 status는 D8대로 키 하나를 기다린 뒤 닫힌다.
- workspace의 마지막 window가 끝나면 session이 사라지고, `detach-on-destroy on`이라 popup이 닫힌다. 다른 workspace로 넘어가지 않는다 (테스트 `last_window_exit_does_not_switch_workspace`).
- 마지막 workspace가 사라지면 greenroom server도 종료된다 (`exit-empty` 기본값).

### workspace 관리

- host에서 `prefix` + `G`를 누르면 popup이 열리고 workspace 메뉴가 뜬다. popup 안의 `prefix` + `G`와 command 메뉴의 `workspaces`도 같은 메뉴다.
- 메뉴 항목
  - 기존 workspace 목록. window 수와 현재 표시(`*`), 앞 9개는 숫자 단축키. 고르면 `switch-client`.
  - `n` 새 workspace: 이름을 묻고, 현재 workspace의 origin 경로에서 기본 profile의 window 하나로 만든 뒤 전환. 같은 이름이 있으면 전환만 한다.
  - `r` 이름 변경, `x` 현재 workspace 삭제(확인 후).
- command 메뉴의 `new-workspace`, `rename-workspace`, `kill-workspace`는 메뉴 없이 같은 prompt를 바로 띄운다 (D12).
- 메뉴와 prompt는 그 메뉴를 연 client의 session을 대상으로 한다. popup 둘이 다른 workspace를 봐도 서로의 workspace를 바꾸지 않는다 ([코드 리뷰에서 고친 것](#코드-리뷰에서-고친-것)).
- workspace 이름에서 `[A-Za-z0-9_-]` 밖의 문자는 `_`로 바꾼다.
- 마지막으로 본 workspace는 `client-attached`, `client-session-changed`, `session-renamed` hook이 `set-option -gF`로 `@greenroom_last`에 기록한다. `-F`가 없으면 `#{session_name}`이 글자 그대로 저장된다 (리뷰 실측).

## 키 바인딩

host server:

| 키                    | 동작                                        |
| --------------------- | ------------------------------------------- |
| `prefix` + `g`        | 마지막 workspace를 popup으로                |
| `prefix` + `G`        | popup + workspace 메뉴                      |
| `prefix` + `S`        | pane 화면을 popup으로 보내기                |
| copy-mode `a`         | 선택 영역을 popup으로 보내기                |
| `@greenroom-root-key` | prefix 없이 `prefix` + `g`와 같음 (설정 시) |

popup 안 (greenroom server):

| 키                         | 동작                              |
| -------------------------- | --------------------------------- |
| `prefix` + `g`             | popup 닫기                        |
| `prefix` + `c`             | profile 메뉴                      |
| `prefix` + `G`             | workspace 메뉴                    |
| `prefix` + `M`             | command 메뉴                      |
| `prefix` + `z`             | large 모드 토글                   |
| `prefix` + `prefix`        | prefix 키를 pane으로 보내기       |
| `prefix` + `n` `p` `0`-`9` | window 전환 (tmux 기본)           |
| `prefix` + `&`             | window 종료 (tmux 기본)           |
| `prefix` + `s` `w`         | workspace·window 트리 (tmux 기본) |
| `prefix` + `$`             | workspace 이름 변경 (tmux 기본)   |
| `prefix` + `d`             | popup 닫기 (tmux 기본)            |

- copy-mode `a`는 `copy-mode`, `copy-mode-vi` table 모두에 바인딩한다.
- `g`/`G`, `S`와 copy-mode `a`는 stock tmux에 바인딩이 없는 키다 (실측, 3.4·3.7b `list-keys`). 옵션으로 바꾼다.
- `@greenroom-root-key`(예: `M-g`)를 지정하면 prefix 없이 토글한다. 이 키는 greenroom server에도 바인딩되므로 window의 프로그램에는 전달되지 않는다.
- grow, shrink, reset 키는 기본값이 없다 (D11).
- popup 안의 `c`, `M`, `z`는 tmux 기본 바인딩(`new-window`, `select-pane -M`, `resize-pane -Z`)을 대신한다. 키 옵션을 다른 키로 바꾸면(`M`, `z`는 비워도) 다음 열기에서 tmux 바인딩으로 되돌린다 (D3).

## 옵션

### 사용자 옵션

| 옵션                            | 기본값                                                   | 설명                                      |
| ------------------------------- | -------------------------------------------------------- | ----------------------------------------- |
| `@greenroom-key`                | `g`                                                      | popup 토글 키 (prefix table)              |
| `@greenroom-root-key`           | 없음                                                     | prefix 없이 토글하는 키 (root table)      |
| `@greenroom-workspaces-key`     | `G`                                                      | workspace 메뉴 키 (host, popup 안 공통)   |
| `@greenroom-profiles-key`       | `c`                                                      | popup 안 profile 메뉴 키                  |
| `@greenroom-commands-key`       | `M`                                                      | popup 안 command 메뉴 키                  |
| `@greenroom-send-key`           | `a`                                                      | 선택 영역 보내기 키 (copy-mode)           |
| `@greenroom-send-pane-key`      | `S`                                                      | pane 화면 보내기 키 (prefix table)        |
| `@greenroom-large-key`          | `z`                                                      | popup 안 large 모드 토글 키               |
| `@greenroom-grow-key`           | 없음                                                     | popup 안 크기 키우기 키                   |
| `@greenroom-shrink-key`         | 없음                                                     | popup 안 크기 줄이기 키                   |
| `@greenroom-reset-key`          | 없음                                                     | popup 안 크기 되돌리기 키                 |
| `@greenroom-profiles`           | `claude codex gemini opencode \| shell`                  | profile 메뉴 항목과 순서                  |
| `@greenroom-profile-<name>-cmd` | `<name>`                                                 | profile 실행 명령                         |
| `@greenroom-profile-<name>-key` | 자동                                                     | profile 메뉴 단축키                       |
| `@greenroom-profile-shell-cmd`  | login shell                                              | 메뉴의 `shell` 항목이 실행할 명령         |
| `@greenroom-commands`           | `profiles workspaces \| large grow shrink reset \| hide` | command 메뉴 항목과 순서                  |
| `@greenroom-command-<id>-label` | built-in 이름 또는 `<id>`                                | command 메뉴 항목 이름                    |
| `@greenroom-command-<id>-key`   | built-in 키 또는 자동                                    | command 메뉴 단축키                       |
| `@greenroom-command-<id>-run`   | 없음                                                     | built-in이 아닌 id가 실행할 tmux 명령     |
| `@greenroom-default`            | `claude`                                                 | 새 workspace의 첫 window profile          |
| `@greenroom-workspace`          | `main`                                                   | 기본 workspace 이름                       |
| `@greenroom-width`              | `80%`                                                    | popup 너비                                |
| `@greenroom-height`             | `80%`                                                    | popup 높이                                |
| `@greenroom-large-width`        | `95%`                                                    | large 모드 popup 너비                     |
| `@greenroom-large-height`       | `95%`                                                    | large 모드 popup 높이                     |
| `@greenroom-resize-step`        | `10`                                                     | 키우기·줄이기 한 번에 바뀌는 %p           |
| `@greenroom-x`                  | `C`                                                      | popup 가로 위치                           |
| `@greenroom-y`                  | `C`                                                      | popup 세로 위치                           |
| `@greenroom-border-lines`       | `rounded`                                                | popup 테두리 (`popup-border-lines` 값)    |
| `@greenroom-socket`             | `greenroom`                                              | greenroom server socket 이름 (`-L`)       |
| `@greenroom-config`             | 없음                                                     | greenroom server 시작 시 추가로 읽을 conf |

- 반영 시점
  - host 키(`@greenroom-key`, `-root-key`, `-workspaces-key`, `-send-key`, `-send-pane-key`)는 플러그인 로드 때 host 바인딩에 들어간다. 바꾸면 conf를 다시 읽어야 하고, 그때 옛 키는 풀린다 (host의 `@greenroom_bound`).
  - 나머지는 여는 때마다 읽는다. popup 크기·위치·테두리는 `open.sh`가 읽는다 (D11). greenroom server 쪽 키 바인딩도 여는 때마다 다시 만든다 (D3).
  - `@greenroom-config`는 greenroom server가 뜰 때만 읽힌다 (D5).
- 빈 값
  - `@greenroom-root-key`, `@greenroom-commands-key`, `@greenroom-large-key`, `@greenroom-grow-key`, `@greenroom-shrink-key`, `@greenroom-reset-key`는 빈 값이면 바인딩하지 않는다. 이 중 기본값이 있는 것은 `@greenroom-commands-key`(`M`)와 `@greenroom-large-key`(`z`)다.
  - `@greenroom-profiles`, `@greenroom-commands`의 빈 값은 빈 메뉴다 (D6, D12).
  - 그 밖의 옵션은 빈 값이면 기본값을 쓴다.
- 이름 규칙
  - 메뉴 키 옵션 이름은 `@greenroom-<메뉴>-key` 형식이다 (`-profiles-key`, `-workspaces-key`, `-commands-key`).
  - 항목별 옵션은 `@greenroom-profile-<name>-*`(D6), `@greenroom-command-<id>-label`·`-key`·`-run`(D12)이다. 접두어가 따로 있어 플러그인 옵션과 이름이 겹치지 않는다.

### 플러그인 상태

`@greenroom_*` 옵션은 플러그인이 관리한다. 사용자는 status line에서 `@greenroom_alert`를 읽기만 한다 (D9).

| 옵션                           | 위치                 | 뜻                                                           |
| ------------------------------ | -------------------- | ------------------------------------------------------------ |
| `@greenroom_bound`             | host, greenroom 전역 | 플러그인이 바인딩한 `table:key` 목록 (D3)                    |
| `@greenroom_alert`             | host 전역            | 놓친 bell이 있는 `<window>@<workspace>` 목록 (D9)            |
| `@greenroom_size_large`        | host 전역            | large 모드일 때 1 (D11)                                      |
| `@greenroom_size_width`        | host 전역            | 바꾼 보통 크기의 너비 (D11)                                  |
| `@greenroom_size_height`       | host 전역            | 바꾼 보통 크기의 높이 (D11)                                  |
| `@greenroom_server`            | greenroom 전역       | greenroom server 표시. `greenroom.tmux`가 보고 멈춘다 (D5)   |
| `@greenroom_last`              | greenroom 전역       | 마지막으로 본 workspace                                      |
| `@greenroom_host`              | greenroom 전역       | 마지막으로 popup을 연 host server의 socket 경로 (D9)         |
| `@greenroom_host_client_<pid>` | greenroom 전역       | inner client pid별 host client 이름 (D11)                    |
| `@greenroom_pending_<pid>`     | greenroom 전역       | inner client pid별로 prompt에 입력한 workspace 이름 (D6)     |
| `@greenroom_key`               | greenroom 전역       | status line 힌트의 닫기 키                                   |
| `@greenroom_profiles_key`      | greenroom 전역       | popup 안 profile 메뉴 키. 사용자 status line용               |
| `@greenroom_workspaces_key`    | greenroom 전역       | popup 안 workspace 메뉴 키. 사용자 status line용             |
| `@greenroom_commands_key`      | greenroom 전역       | status line 힌트의 command 메뉴 키. 비면 힌트를 숨긴다 (D12) |
| `@greenroom_default`           | greenroom 전역       | 새 workspace의 첫 profile. `new-workspace.sh`가 읽는다       |
| `@greenroom_origin`            | greenroom workspace  | workspace의 origin 경로                                      |

### 이름 변경 이력

- 어느 변경에도 호환 별칭은 두지 않았다.
- 2026-10-01: 플러그인 이름 tmux-llm-agent를 tmux-greenroom으로 바꿨다. entry 파일을 `llm-agent.tmux`에서 `greenroom.tmux`로, 옵션을 `@llm-agent-*`·`@llm_agent_*`에서 `@greenroom-*`·`@greenroom_*`로, 기본 socket을 `llm-agent`에서 `greenroom`으로 바꿨다.
- 2026-10-01: 메뉴 키 옵션 `@greenroom-new-key`, `@greenroom-menu-key`를 `@greenroom-agents-key`, `@greenroom-workspaces-key`로 바꿨다. 이때 `@greenroom-<메뉴>-key` 형식을 정했다.
- 2026-10-02: 메뉴 항목을 agent에서 profile로, 전용 server를 agent server에서 greenroom server로 바꿨다. 옵션을 `@greenroom-agents`·`-agents-key`·`-<name>-cmd`·`-<name>-key`에서 `@greenroom-profiles`·`-profiles-key`·`-profile-<name>-cmd`·`-profile-<name>-key`로, 파일을 `conf/agent-server.conf`에서 `conf/greenroom-server.conf`로, `scripts/run-agent.sh`에서 `scripts/run-profile.sh`로 바꿨다. 접두어를 따로 두어 profile 이름이 플러그인 키 옵션과 구조적으로 겹치지 않으므로 이름 목록 우회를 지웠다.

## 검증 근거

### 설계 전 프로토타입

tmux 3.7b에서 격리된 server 세 개(harness, host, greenroom)로 실측했다. harness pane 안에서 host client를 돌리고 harness의 `send-keys`로 키를 입력했다.

| #   | 확인 항목                                               | 결과 (실측)                                              |
| --- | ------------------------------------------------------- | -------------------------------------------------------- |
| 1   | popup 안 `prefix` + `c`는 어느 server가 받나            | greenroom server. window가 1개에서 2개로, host 변화 없음 |
| 2   | popup이 열린 동안 host `bind -n` 키가 발동하나          | 발동 안 함                                               |
| 3   | popup이 열린 동안 host prefix 바인딩이 발동하나         | 발동 안 함                                               |
| 4   | greenroom server에서 `detach-client`하면 popup이 닫히나 | 닫힘. session과 window는 유지                            |
| 5   | 다시 열면 상태가 유지되나                               | 유지. window 2개 그대로                                  |
| 6   | `$TMUX`를 지우지 않고 popup 안에서 attach 되나          | 됨. nested 검사에 걸리지 않음                            |
| 7   | workspace의 마지막 window가 끝나면                      | popup 닫힘, greenroom server 종료                        |
| 8   | Shift+Enter가 중첩 계층을 통과하나                      | 통과. 직접, 중첩 모두 `ESC[27;2;13~`                     |

- 6번은 같은 server의 session으로 확인했다. 근거 (조사): tmux 3.3 `server_client_check_nested`는 client tty가 그 server의 pane tty일 때만 nested로 본다. popup job은 자체 pty를 쓴다.
- 7번은 session이 하나뿐이라 server가 끝나서 닫힌 경우다. workspace가 여럿일 때는 통합 테스트가 따로 확인한다.
- 8번 조건: host와 greenroom server 모두 `extended-keys on`, `terminal-features`에 `tmux*:extkeys`. tmux 3.4에서는 같은 키가 `ESC[13;2u`(CSI u)로 도착한다 (리뷰 실측, 통합 테스트로 재확인). 3.3 내장 terminal feature에는 `tmux`용 extkeys가 없어 greenroom server conf가 직접 추가한다 (리뷰 조사).

### 구현 중 실측

| #   | 확인 항목                                            | 결과 (실측, 3.7b)                                |
| --- | ---------------------------------------------------- | ------------------------------------------------ |
| 9   | `display-popup` shell-command의 format 확장          | 안 함. `#{session_name}`이 글자 그대로 남음      |
| 10  | `-f`를 두 번 주면                                    | 둘 다 읽음. 에러 종류에 따라 다름 (아래)         |
| 11  | tmux parser가 `'it'\''s'`와 중첩 quoting을 받나      | 받음. `$` `;` `#` `"` 백슬래시 모두 보존         |
| 12  | `$`가 든 옵션 값을 `show -gv`로 읽으면               | 3.7b 원문, 3.4는 `\$`. buffer 경유는 둘 다 원문  |
| 13  | pane 대상 인자에 `-t =main`                          | `no such session`. `=main:`이어야 함             |
| 14  | `;`로 끝나는 argv 원소                               | 명령 구분자로 먹힘. 끝을 `\;`로 쓰면 값 보존     |
| 15  | `set-buffer "~/x"`처럼 따옴표 첫 글자가 `~`          | tilde 확장됨 (리뷰 실측). 앞에 `x`를 붙임        |
| 16  | `list-keys -T prefix g` (키 인자)                    | 3.7b는 출력 없음, 3.4는 출력. 테스트는 전체 검색 |
| 17  | bell flag가 서는 때와 지워지는 때                    | 안 보는 window에만 섬. attach·선택하면 지워짐    |
| 18  | `bell-action other`에서 닫힌 popup의 현재 window     | flag는 서지만 `alert-bell` hook이 돌지 않음      |
| 19  | popup 안에서 복사 (host `set-clipboard on`)          | OSC 52로 바깥 터미널까지 감. host buffer도 생김  |
| 20  | greenroom server `copy-command`로 host에 load-buffer | copy-mode 복사가 host paste buffer에 들어감      |

- 10번: 실행 중 에러(예: 없는 옵션 `set -g bogus-option x`)는 그 줄만 실패하고 앞뒤 줄이 모두 적용된다. 파싱 에러(예: 없는 명령 `bogus-command x`)는 그 파일 전체가 적용되지 않는다. 에러보다 앞 줄도 마찬가지다. 어느 쪽이든 이어지는 준비 명령은 실행돼 popup은 열린다 (실측, 3.4·3.7b). 처음에는 실행 중 에러만 재서 "에러 뒤 줄도 실행"이라고 적었다가 문서 검증에서 바로잡았다.
- 12번의 3.4 결과는 `/usr/bin/tmux` 3.4로 측정했다. `show-options -g` 출력도 3.4에서는 `\\$`로 이중 escape되어 source로 되살릴 수 없다.

### popup 크기 조절 실측

21~31은 구현 전에 통합 테스트와 같은 harness에서 대역 스크립트로, 32~33은 구현한 플러그인으로, 34는 통합 중에, 35~36은 리뷰 뒤에 격리 server로 쟀다. 두 버전 결과가 같다.

| #   | 확인 항목                                       | 결과 (실측, 3.4·3.7b)                                          |
| --- | ----------------------------------------------- | -------------------------------------------------------------- |
| 21  | `display-popup -w '#{@w}'`처럼 크기에 format    | 확장 안 함 (`width invalid`). %는 status line 포함 client 기준 |
| 22  | `-e`, shell-command 안의 `#{client_name}`       | 글자 그대로 감. `run-shell` 명령에서는 확장됨                  |
| 23  | command client `display-popup -c C`의 format    | C가 아니라 최근 활성 session 기준. popup은 C에 뜸              |
| 24  | 바인딩 대신 `run-shell -b` 스크립트로 열기      | 15/15 열림. 15~18ms 늦고, tmux 호출 하나에 3.6~5.5ms           |
| 25  | CLI `display-popup`이 돌아오는 때               | popup이 닫힐 때, job의 status로. `-C`로 지우면 129             |
| 26  | popup이 떠 있는 client에 `display-popup`        | rc 0으로 버려짐. 3.7b는 제목·테두리만 바뀜                     |
| 27  | `display-popup -C ; display-popup` 한 명령 목록 | 깜빡임·새는 키 없음. inner client 하나, pane id 그대로         |
| 28  | 같은 두 명령을 따로 호출                        | host pane이 다시 그려지고 사이에 친 키가 host로 감             |
| 29  | popup이 떠 있는 동안 host `client_activity`     | 안 바뀜. 최근 활성 client로 찾으면 틀림                        |
| 30  | popup job의 `$$`와 inner client `#{client_pid}` | 같음. host client 둘, workspace 전환, re-open 뒤에도           |
| 31  | `run-shell -b` job이 0 아닌 status로 끝남       | pane에 `'...' returned N`. stderr는 안 보임                    |
| 32  | re-open에서 `attach.sh` 준비를 다시 함          | 키부터 새 client까지 0.5~0.6초, 그동안 빈 popup                |
| 33  | 0.1·0.2초 간격으로 크기 키 8번                  | lock 없이는 단계가 빠짐. 두 `size.sh`가 같은 상태를 읽음       |
| 34  | `display-message -c C -p '#{client_width}'`     | C가 아니라 최근 활성 client의 값. `list-clients -F`는 맞음     |
| 35  | `-y C`로 둔 95% popup의 위 테두리               | 홀수 행 client의 짝수 행 popup만 가운데, 나머지는 한 줄 위     |
| 36  | `display-popup -c C -y`의 `#{client_height}`    | C의 높이. 최근 활성 client와 무관. 위 줄은 y - popup 높이      |

- 32번 때문에 re-open은 준비를 건너뛴다 (D11).
- 33번 때문에 `size.sh`에 lock을 넣었다. 그 뒤 0.2초 간격은 14번 중 13번, 0.3초 간격은 10번 모두 8단계가 다 반영됐다. 0.1초 간격은 여전히 빠진다. 다음 re-open이 막 연 popup을 닫으면 그 popup에 쌓인 키가 사라진다.
- 35번은 100열 client의 20, 24, 30, 40~52, 55, 56, 60, 61, 70, 80행에서 쟀다. 처음 측정(24, 40, 41, 45행)만 보고 "40행 이하"라고 적었다가 리뷰에서 50, 60행도 0행임을 찾았다. 계산한 `-y`로는 24~70행에서 위 테두리가 1행 이상이다 (실측, 통합 테스트 `size_large_popup_keeps_its_margin_at_other_heights`).
- 36번은 `-y '#{client_height}'`로 쟀다. 50행 client에 다른 41행 client가 최근 활성이어도 popup이 50행 기준 맨 아래에 떴다.

### 코드 리뷰에서 고친 것

- quoting과 escape
  - bash 4.2 이하는 `"${1//\'/...}"`의 치환 문자열에서 quote를 제거하지 않는다. `quote()`가 중첩 quoting에서 깨져 profile 메뉴와 새 workspace가 동작하지 않았다 (리뷰 실측, 당시 테스트를 `BASH_COMPAT=3.2`로 돌린 결과 11/16). 치환 문자열을 변수에 담아 고쳤다.
  - `new-session -c`는 경로를 format으로 확장한다. `#S`가 든 디렉토리는 엉뚱한 곳에서 시작했고, tmux 3.4에서는 `#(...)`가 든 디렉토리 이름이 명령을 실행했다 (리뷰 실측). 시작 디렉토리는 `format_escape`를 거친다.
  - 새 workspace의 origin과 입력 이름을 `display-message`, `show-option`으로 읽어 3.4에서 `$`가 깨졌다. `read_raw_options`로 바꿨다.
  - workspace 메뉴는 profile·command 메뉴와 달리 첫 항목 앞에 `--`가 없고 `-`로 시작하는 이름에 `#[default]`도 붙이지 않았다. 이름이 `-dash`인 workspace가 맨 앞이면 메뉴가 `unknown flag`로 뜨지 않았다 (문서 검증에서 발견, 실측). 테스트 helper `type_text`도 `send-keys -l`에 `--`가 없어 `-`로 시작하는 글자를 플래그로 읽었다.
  - 명령 출력에서 tmux는 백슬래시를 `\\`로 찍고, 3.4는 구분자 byte도 `\037`로 찍는다 (리뷰 실측, 3.4·3.7b). `client_values`가 모든 `\037`을 구분자로 바꿔 이름에 글자로 든 `\037`(출력은 `\\037`)이 갈라졌다. 줄에 구분자 byte가 없을 때만, `\\` 쌍을 뺀 `\037`만 바꾼다. 3.4에서 0x1F byte가 든 이름은 여전히 구분자와 같아 보인다 (3.7b는 그런 이름을 받지 않는다). 값은 tmux가 찍은 그대로 둔다. 메뉴 목록의 이름과 같다.
- 대상 client와 session
  - workspace 메뉴의 전환·삭제 대상은 이름 대신 session ID를 쓴다. 이름 변경도 입력값을 정리하는 스크립트를 거친다.
  - workspace 메뉴, 이름 변경, 새 workspace가 자기 client의 session·pane을 `display-message -c <client> -p`로 읽었다. 그 값은 최근 활성 session과 그 client의 것이고, 메뉴·prompt 안의 키는 활동으로 치지 않는다 (실측, 3.4·3.7b). popup 둘이 다른 workspace를 볼 때 메뉴를 연 뒤 다른 popup에 입력하면 이름 변경과 새 workspace의 origin이, 메뉴 job이 뜨는 사이에 입력하면 현재 표시와 삭제도 다른 popup의 workspace를 따랐다. `size.sh`와 함께 `list-clients -F`의 그 client 줄을 읽는 `client_values`를 쓴다.
  - 이름 변경과 새 workspace는 그 client의 pane ID를 대상으로 썼다. tmux는 pane 대상을 그 window가 든 session 중 최근 활성 session으로 바꾼다. window가 여러 session에 있으면(session group, `link-window`) 다른 popup의 workspace 이름이 바뀌고 origin도 그쪽 것을 썼다 (리뷰 실측, 3.4·3.7b). client의 session ID를 대상으로 쓴다.
  - 두 popup이 이름 prompt를 거의 같이 확인하면 전역 `@greenroom_pending` 하나를 두 job이 나눠 읽었다. 한 workspace가 다른 popup의 이름을 받고 다른 쪽 변경은 사라졌다 (리뷰 실측, 3.4·3.7b). option 이름에 client pid를 붙인다.
- 키 바인딩
  - 실행 중인 greenroom server에서 `@greenroom-large-key`를 빈 값이나 `Z`로 바꾸면 `prefix` + `z`가 zoom도 large 모드도 아닌 빈 키로 남았다 (리뷰 실측, 3.4·3.7b). D3대로 tmux 바인딩을 되돌린다.

### 통합 테스트

- `tests/run.sh`가 통합 테스트다. 설계 전 프로토타입처럼 harness server의 pane에서 실제 host client를 돌리고 harness의 `send-keys`로 키를 입력한다.
- 테스트는 항상 고유한 `-L` socket(`tgr-test-<pid>-<역할>`)을 쓰고, 기본 server와 실제 `greenroom` socket에는 접근하지 않는다. 끝나면 socket 파일도 지운다.
- origin 경로는 `it's #S $x;`처럼 셸 quoting, tmux format, argv 파싱을 깨는 문자를 담는다.
- 테스트가 tmux 3.7b와 3.4에서, 각각 bash 5.2와 `BASH_COMPAT=3.2`로 모두 통과한다 (실측, 네 조합). 다른 tmux build는 그 `tmux` symlink를 둔 디렉토리를 `PATH` 앞에 넣어 돌린다. 실제 bash 3.2 바이너리는 설치본이 없어 돌리지 못했다.
- 이 문서는 테스트를 `test_`를 뺀 함수 이름으로 가리킨다 (예: `last_window_exit_does_not_switch_workspace`). `tests/run.sh <이름 일부>`는 이름이 맞는 테스트만 돌린다.

## 선행 사례

- omerxx/tmux-floax: host server의 `scratch` session을 popup에 띄우는 범용 scratch 터미널. session 이름으로 popup 안인지 판별해 detach한다.
- loichyan/tmux-toggle-popup: 전용 server(`@popup-socket-name`)를 쓰는 범용 popup 토글. README 기준 tmux 3.4+.
- craftzdog/tmux-claude-hatch: host server에 프로젝트별 `claude-<hash>` session. Claude 전용.
- 이 플러그인의 차이: profile 목록과 메뉴, workspace와 window의 2단 구조, origin 경로 전달. 범용 popup 플러그인 위에 얹으면 의존성만 늘고, 필요한 부분은 여전히 직접 짜야 한다.

## 위험과 알려진 제약

- tmux 버전
  - tmux 3.8(미출시)은 popup을 modal floating pane으로 다시 구현한다 (tmux master 소스 조사, 미실측). 출시되면 통합 테스트를 다시 돌린다.
- 여러 client·host가 greenroom server 하나를 쓸 때
  - 크기가 다른 두 client가 같은 workspace를 보면 window가 마지막으로 입력한 client 크기로 오간다 (`window-size latest`, 리뷰 실측). 문서화만 했다.
  - greenroom server의 `prefix`는 전역 하나, origin 경로는 workspace당 하나다. 설정이 다른 host 둘이 같은 greenroom server를 쓰면 마지막에 연 host 값이 이긴다.
  - bell 알림과 크기 키는 `@greenroom_host`(마지막으로 popup을 연 host server)로 간다. host 둘이 같은 greenroom server를 쓰면 다른 host의 popup에서는 크기 키가 아무것도 하지 않는다.
  - 크기 상태는 host server에 하나다. client마다 따로 두지 않고, 다른 client의 popup은 다음에 열 때 반영된다.
- greenroom server의 수명
  - greenroom server의 환경 변수는 처음 띄운 popup job의 환경으로 고정된다. pane 안에서 바꾼 PATH(nvm, direnv 등)는 새 window에 닿지 않는다. login shell 실행(D8)이 셸 설정 파일의 PATH까지는 채운다.
  - `conf/greenroom-server.conf`는 greenroom server 시작 때만 읽는다. 플러그인을 업그레이드하면 greenroom server를 재시작해야 conf 변경이 반영된다.
  - 플러그인이 쓰다가 놓은 greenroom server 키 중 `c`, `M`, `z`, `-`, `=` 밖의 키는 greenroom server를 재시작할 때까지 바인딩이 없다 (D3).
  - popup이 닫힌 채 greenroom server가 끝나면 host의 `@greenroom_alert`가 남는다. 다음에 popup을 열 때 지운다.
- 크기 조절
  - greenroom server에 직접 attach한 client에서는 크기 키가 아무것도 하지 않는다. 그 client에서 `prefix` + `z`는 zoom도 아니다.
  - 터미널을 줄이거나 크기 키로 줄여 popup 안이 command 메뉴보다 낮아지면 메뉴가 메시지 없이 열리지 않는다. `prefix` + `z`로 large 모드가 되면 다시 열린다.
  - 크기 키를 re-open보다 빨리(0.1초 간격) 누르면 단계가 빠질 수 있다 (실측 33 아래). 두 re-open의 `open.sh`가 거의 같이 돌아 `display-popup` 순서가 뒤집히면 popup이 바로 전 크기로 남을 수 있다 (미실측, 다음 크기 키나 열기에서 바로잡힌다).
- workspace 메뉴
  - 이름이 `-`로 시작하는 workspace가 있으면 workspace 메뉴가 깨진다. 이름 정리는 `-`를 남기므로 새 workspace prompt나 `@greenroom-workspace`로 그런 이름이 생길 수 있다.
  - `-`는 숫자와 글자보다 앞에 정렬되어 그 workspace가 첫 항목이 되고, `display-menu`가 그 항목을 flag로 읽는다. 목록 행에는 이름 대신 숫자만 보이고 구분선이 사라지며, 메뉴가 가운데가 아니라 왼쪽 위에 뜬다 (실측, 3.4·3.7b, workspace 둘).
  - profile·command 메뉴와 달리 `workspace-menu.sh`는 항목 앞의 `--`와 이름 앞의 `#[default]`를 쓰지 않는다 (D6).
- 보내기
  - 새 workspace로 보내는 텍스트는 화면이 잠잠해지는 것을 보고 붙여넣는 추정 방식이다. 첫 window의 프로그램이 화면을 다 그린 뒤에도 입력을 늦게 받기 시작하면 앞부분이 빠질 수 있다.
- 신뢰 경계
  - `@greenroom-profile-<name>-cmd`는 셸로, `@greenroom-command-<id>-run`은 tmux 명령으로 그대로 실행된다. 사용자 conf 값이라 신뢰 경계 안이다.

## 단계 계획

처음 계획은 M1, M2와 제안 P1~P4였다. 구현 중에 I1 popup 크기 조절, I2 profile 목록, I3 command 메뉴를 더했다. 각 단계의 테스트는 [통합 테스트](#통합-테스트)의 `tests/run.sh`에 있다.

### M1. 단일 workspace (완료)

- 토글 열기·닫기, 기본 profile 자동 실행, profile 메뉴, 상태줄, 옵션.
- 테스트: 열기, 닫은 뒤 window 생존, 다시 열 때 상태 유지, window 추가, 셸 문법이 든 명령, 옵션 변경 반영, 키 변경, 없는 명령·실패한 명령, 마지막 window 종료, Shift+Enter, greenroom server 안의 플러그인 무동작.

### M2. 여러 workspace (완료)

- workspace 메뉴(목록·생성·이름 변경·삭제), `@greenroom_last` hook, 이름 정리.
- 테스트: 생성과 전환, 토글이 마지막 workspace를 여는지, host 메뉴 키, 다른 workspace가 있을 때 마지막 window 종료.
- 2026-10-02에 popup 둘이 다른 workspace를 볼 때 메뉴와 prompt가 자기 popup의 workspace를 다루도록 고쳤다 ([코드 리뷰에서 고친 것](#코드-리뷰에서-고친-것)). 테스트: `workspace_menu_*_own_popup`, `workspace_menu_*_shared_window`, `workspace_prompts_confirmed_together_keep_their_names`, `workspace_menu_shows_a_name_with_a_literal_separator_escape`.

### P1. bell 알림 (완료)

- D9대로 구현. agent CLI 설정은 추가하지 않는다. greenroom server에는 `bell-action any`만 강제한다.
- 테스트: 닫힌 popup의 bell이 host 옵션과 메시지로 가고 popup을 열면 지워지는지, 보고 있는 window의 bell은 알리지 않는지, README의 status line 구간이 알림이 있을 때만 그려지는지.

### P2. host 내용을 popup으로 보내기 (완료)

- D10대로 구현. copy-mode `a`는 선택 영역, `prefix` + `S`는 pane에 보이는 화면을 보낸다.
- 테스트: 이미 떠 있는 window로 선택 영역 보내기, greenroom server가 없을 때 pane 화면 보내기(새 workspace 대기 경로), 둘 다 host buffer를 남기지 않는지.

### P3. paste buffer 동기화 (구현 안 함)

- 구현하지 않는다. tmux 3.7 이상에서 host가 `set-clipboard on`이면 popup 안 복사가 OSC 52로 바깥 터미널 clipboard에 가고, host도 paste buffer로 저장한다 (실측 19).
- 3.4~3.6에서는 복사가 greenroom server 안에 남는다. greenroom server `copy-command`를 host `load-buffer`로 바꾸는 한 줄로 host buffer에 넣을 수 있음은 확인했다 (실측 20).

### P4. agent resume 항목 (뺌)

- agent에 들어가 resume하면 되고, `claude --continue` 같은 항목은 기존 옵션으로 만들 수 있다 (`@greenroom-profiles`에 이름 추가, `@greenroom-profile-<name>-cmd`에 명령).

### I1. popup 크기 조절 (완료)

- D11대로 구현. `prefix` + `z` large 모드, 키를 따로 주는 grow·shrink·reset.
- 테스트: 이름이 `size_`로 시작하는 테스트. large 토글과 여백, 단계와 20~95% 한계, 셀 수 변환, 키 옵션과 tmux 바인딩 복원, 닫기·보내기·host 재시작 뒤 상태, re-open의 workspace·origin 보존, host client 둘, 직접 attach한 client, re-open 중 친 키.

### I2. profile 목록 (완료)

- D6대로 구현. `@greenroom-profiles` 하나가 profile 메뉴의 구성과 순서를 정한다. 처음에는 agent 메뉴(`@greenroom-agents`)였고 2026-10-02에 profile로 이름을 바꿨다 ([이름 변경 이력](#이름-변경-이력)).
- 테스트: 이름이 `profile_menu_`로 시작하는 테스트와 `default_profile_outside_the_list_still_starts`. 목록 순서, 구분선 정리, 잘못된·중복 이름, 명시 키와 대체 규칙, 화살표·`;` 키, `-`로 시작하는 이름, 플러그인 키 이름의 profile, 빈 목록, 다음 열기 반영.

### I3. command 메뉴 (완료)

- D12대로 구현. `prefix` + `M`, `@greenroom-commands`.
- 테스트: 이름이 `command_menu_`로 시작하는 테스트. 기본 항목과 built-in id 전부, profile·workspace·크기·window 항목, 사용자 명령과 format 확장, 정의 안 된 id, label·key 덮어쓰기, 목록 문법, 키 옵션 변경과 `M` 복원, popup 둘에서 자기 popup에 작용하는지.
