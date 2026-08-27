# AI 개발·세션 기록 킷

Claude Code나 Codex로 앱과 웹사이트를 만들고 고치는 일을 여러 대화에 걸쳐 이어가기 위한 `ai-session-kit`의 원본 저장소입니다. 한 번 질문하고 끝나는 대화에는 필요하지 않습니다. 작업이 길어지면 AI가 이전 결정과 남은 일을 놓치거나, 방향만 제안한 상태를 실제 구현·검증 완료처럼 설명하기 쉬워집니다.

이 킷은 새로운 개발 AI가 아니라 **AI가 일하는 규칙과 다음 대화용 인수인계 방식**을 설치합니다. 사용자는 기술 스택 대신 원하는 결과를 평소 말로 설명하고, AI는 기존 project를 살펴본 뒤 작은 범위로 구현하고 확인합니다.

## 무엇이 달라지나

- "완료한 항목을 숨길 수 있게 해줘"처럼 결과를 말하면 AI가 확인 가능한 동작으로 정리해 구현합니다.
- 결과를 `제안`, `구현`, `검증`, `전달`로 구분해 어디까지 끝났는지 설명합니다.
- 대화가 길어지고 안전한 마무리 지점에 도달하면 AI가 세션 정리를 한 번 제안합니다. 동의하면 결정·검증·남은 일을 local markdown으로 기록합니다.
- 새 대화에서 "이어서 하자"라고 하면 현재 project의 기록과 실제 code state를 확인한 뒤 계속합니다. 인수인계 기록이 code 자체를 복사하지는 않으므로, commit하지 않은 변경은 원래 작업 폴더에 남아 있어야 합니다.

처음 설치하거나 사용하는 사람은 [앱 사용자 안내](readmes/README-app.md)를 먼저 읽으세요. 터미널에서 직접 설치하려면 [CLI 사용자 안내](readmes/README-cli.md)를 참고하세요.

## ai-session-kit 원본 저장소

AI 개발·세션 기록 킷의 **단일 원본**입니다. 이 폴더를 직접 배포하지 말고, build.sh로 만든 산출물을 배포합니다.

## 구조

- `skills/` `hooks/` `scripts/` `vault-template/` `setup.sh` `setup.ps1` `uninstall.sh` `uninstall.ps1` — 기능 구현·오류 추적·local 미리보기·변경 확인과 세션 기록을 포함한 macOS·Linux·Windows 공통 킷 본체
- `readmes/README-cli.md` — 터미널·Claude Code 사용자용 안내
- `readmes/README-app.md` — Claude/Codex 앱 사용자용 안내 (일반인)
- `build.sh` — `dist/cli`, `dist/app` 산출물 생성 (README만 다르고 코드는 동일)
- `tests/` — vault 규칙과 실제 release artifact 검증

## 배포 절차 (CI 자동)

버전 관리는 [changesets](https://github.com/changesets/changesets), 릴리스는 GitHub Actions가 담당한다.

1. 킷을 수정한다
2. `npx changeset` — 변경 요약을 쓰고 patch/minor를 고른다 (`.changeset/*.md` 생성됨)
3. main에 푸시 → CI가 **"chore: 버전 릴리스 준비" PR**을 생성/갱신한다 (쌓인 changeset = 업데이트 리스트가 CHANGELOG.md로 누적)
4. 그 PR을 머지 → CI가 `vX.Y.Z` GitHub Release를 만들고 `ai-session-kit-cli-vX.Y.Z.zip`, `ai-session-kit-app-vX.Y.Z.zip`을 첨부한다

친구에게는 Release 페이지의 zip 링크를 주면 된다.

로컬에서 확인용 빌드는 여전히 가능하다:

```bash
bash build.sh              # 저장소 안 dist/에 cli/, app/ 생성
bash build.sh /tmp/output  # 원하는 출력 폴더 지정
bash tests/check-release.sh
```

`tests/check-release.sh` 실행에는 Bash, `jq`, Python 3가 필요합니다. macOS에 `jq`가 없다면 `brew install jq`로 설치할 수 있습니다. Python 3는 이 배포 검증과 vault lint에 필요하지만, 배포된 킷의 기록·복원 기능 자체는 Python 없이도 동작합니다.

GitHub Actions는 Ubuntu, macOS의 시스템 `/bin/bash`, native Windows를 각각 검증합니다. Windows job은 `windows-latest`에서 Windows PowerShell 5.1로 실행하며, 세 환경이 모두 통과한 `main` 푸시만 릴리스를 진행합니다.

`build.sh`는 자신이 만든 marker가 있는 `cli/`, `app/`만 교체합니다. 같은 이름의 일반 폴더나 symlink가 있으면 내용을 건드리지 않고 실패합니다.

## 수정 규칙

- 킷 본체 수정은 항상 **이 폴더에서만** 한다. `cli/`, `app/`은 build.sh가 덮어쓰는 산출물이라 직접 고치면 다음 빌드 때 사라진다.
- 대상별 안내 문구는 `readmes/`의 해당 README만 고친다.
- 수정을 main에 올리기 전에 `npx changeset`으로 변경 기록을 남긴다 (사용자에게 보이는 변경이 없으면 생략 가능 — 그 경우 릴리스도 생기지 않는다).
