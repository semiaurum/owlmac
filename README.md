<p align="center"><img src="docs/icon.png" width="128" alt="OwlMac"></p>

<h1 align="center">OwlMac</h1>
<p align="center"><b>맥북아, 자지 마!</b><br>Claude, npm, 빌드가 도는 동안 맥이 잠들지 않게 지켜 주는 메뉴바 부엉이</p>

---

`caffeinate -is claude`를 매번 치는 대신 메뉴바 부엉이를 클릭해서 **깨우기**를 누르면 돼요.
`claude`나 `npm run dev` 같은 작업이 돌고 있으면 **알아서** 깨어 있다가, 작업이 끝나면 다시 잠들어요.

<p align="center"><img src="docs/faces.png" width="560" alt="잠자는 중 · 지켜보는 중 · 깨어 있음 · 깜빡"></p>

| 부엉이 | 상태 |
|---|---|
| 흐릿하고 눈 감음 | **잠자는 중**: 맥이 평소처럼 잠들어요 |
| 반쯤 뜬 눈 | **지켜보는 중**: 자동 감지가 켜져 있고, 아직 감지된 작업이 없어요 |
| 동그란 호박색 눈 | **깨어 있음**: 맥이 잠들지 않아요 (가끔 눈을 깜빡여요) |

## 설치

```bash
curl -fsSL https://raw.githubusercontent.com/semiaurum/owlmac/main/install.sh | bash
```

`/Applications/OwlMac.app`에 설치되고 바로 실행돼요. macOS 13 (Ventura) 이상, Apple silicon과 Intel 모두 지원해요.

<details>
<summary>소스에서 직접 빌드하기</summary>

Xcode 없이 Command Line Tools만 있으면 돼요 (`xcode-select --install`).

```bash
git clone https://github.com/semiaurum/owlmac.git
cd owlmac
make install     # 빌드 + /Applications 설치 + 실행
```
</details>

<details>
<summary>"확인되지 않은 개발자" 경고가 뜨면</summary>

위 설치 스크립트를 쓰면 보통 경고가 뜨지 않아요. zip을 브라우저로 직접 받았다면 한 번만 이렇게 풀어 주세요.

```bash
xattr -dr com.apple.quarantine /Applications/OwlMac.app
```
</details>

## 사용법

- **클릭**: 메뉴가 열려요 (왼쪽·오른쪽 모두). 깨우기 / 재우기는 메뉴 첫 줄에 있어요.

| 메뉴 | 하는 일 | caffeinate로 치면 |
|---|---|---|
| 깨우기 | 끌 때까지 깨어 있어요 | `caffeinate -is` |
| 시간 정해 깨우기 | 30분 ~ 8시간 뒤 알아서 잠들어요 | `caffeinate -is -t 7200` |
| 개발 작업이 돌면 알아서 깨어 있기 | 감지 대상 명령이 실행되는 동안만 깨어 있어요 (기본 켜짐) | `caffeinate -is -w <pid>` |
| 감지할 명령 편집… | 감지 대상 명령 목록을 바꿔요 | |
| 화면도 켜 두기 | 화면 꺼짐까지 막아요 | `-d` |
| 뚜껑 닫아도 깨어 있기 | 충전기 없이 뚜껑을 닫아도 안 자요 (관리자 비밀번호 필요) | `sudo pmset -a disablesleep 1` |
| 로그인할 때 실행 | 맥을 켜면 부엉이도 같이 일어나요 | |
| 업데이트 자동 확인 | 실행할 때와 하루에 한 번 새 버전이 있는지 봐요 (기본 켜짐) | |
| 업데이트 확인… | 지금 바로 확인하고, 새 버전이 있으면 내려받아 교체해요 | |

**자동 감지 기본 대상**: `claude` `codex` `gemini` `aider` `npm` `pnpm` `yarn` `bun` `deno` `cargo` `gradle` `xcodebuild`

- 10초마다 확인해요. 대소문자를 구분하기 때문에 `claude` CLI만 잡고 Claude 데스크톱 앱(`Claude`)은 잡지 않아요.
- AI 도구가 띄워 두는 **MCP 서버**(`npx some-mcp` 같은 상주 프로세스)는 무시해요. 이것까지 세면 맥이 영영 안 자요.
- 자동 감지로 깨어 있을 때 **재우기**를 누르면 **지금 돌고 있는 작업이 끝날 때까지만** 쉬어요. 다음 작업부터는 다시 지켜봐요.

## 잘 되는지 확인

```bash
pmset -g assertions | grep OwlMac
#  pid 123(OwlMac): ... PreventUserIdleSystemSleep named: "OwlMac (claude)"
```

## 이럴 땐?

- **화면이 꺼지거나 화면보호기가 떠도** 괜찮아요. 안에서는 계속 일해요.
- **배터리로만 쓸 때** 유휴 잠자기(`-i`)는 막지만, 시스템 잠자기(`-s`)는 충전기를 꽂았을 때만 막아요. 긴 작업이면 충전기를 꽂아 두세요.
- **뚜껑을 닫으면** 충전기와 외장 모니터가 둘 다 없을 때는 잠들어요. 이때 "뚜껑 닫아도 깨어 있기"를 켜요.
  - 가방에 넣지 마세요. 뜨거워져요.
  - 부엉이를 재우거나 OwlMac을 끄면 원래대로 돌아가요 (비밀번호를 한 번 더 물어요).

## 업데이트

- 메뉴의 **업데이트 확인…**을 누르면 GitHub 릴리스를 확인해요. 새 버전이 있으면 내려받아 교체하고 OwlMac을 다시 실행해요. 깨어 있던 상태는 다시 켜야 해요.
- **업데이트 자동 확인**이 켜져 있으면 실행할 때와 하루에 한 번 확인하고, 새 버전이 있을 때 한 번만 물어봐요. 나중에 하려면 메뉴 첫 줄의 **새 버전 vX 업데이트…**를 누르면 돼요. 끄면 수동으로만 확인해요.
- 소스에서 직접 빌드한 OwlMac(`make run`)은 버전이 없어서 확인하지 않아요. 포크를 따라가려면 `defaults write io.github.owlmac updateRepo owner/repo`.
- 터미널이 편하면 설치 명령을 다시 실행해도 같은 결과예요.

## 지우기

```bash
curl -fsSL https://raw.githubusercontent.com/semiaurum/owlmac/main/uninstall.sh | bash
```

## 개발

```bash
make run        # 빌드하고 실행
make release    # dist/OwlMac.zip을 GitHub Release로 올리기 (gh 필요)
```

```
Sources/
  AppDelegate.swift     메뉴바 아이템, 메뉴, 상태 관리
  OwlIcon.swift         부엉이 그리기 (메뉴바 아이콘 + 앱 아이콘 모두 코드로 그려요)
  SleepGuard.swift      IOKit 전원 assertion (caffeinate와 같은 방식)
  ProcessWatcher.swift  감지 대상 프로세스 확인
  LidGuard.swift        pmset disablesleep
  Updater.swift         GitHub 릴리스 확인, 새 버전 내려받아 교체
```

## 라이선스

코드, 문서, 부엉이 아이콘과 이미지를 포함한 이 프로젝트는 [MIT 라이선스](LICENSE)로 배포해요.
