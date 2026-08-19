# ex-brain

비개발자와 디자이너도 로컬 폴더에 AI 작업 기록과 재사용 지식을 쌓을 수 있게 만드는 `ai-session-kit`의 원본 저장소입니다.

## ai-session-kit 원본 저장소

AI 세션 기록 킷의 **단일 원본**입니다. 이 폴더를 직접 배포하지 말고, build.sh로 만든 산출물을 배포합니다.

## 구조

- `skills/` `hooks/` `scripts/` `vault-template/` `setup.sh` `setup.ps1` `uninstall.sh` `uninstall.ps1` — macOS·Linux·Windows 공통 킷 본체
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

native Windows installer 회귀 검증은 GitHub Actions의 `windows-latest` job에서 Windows PowerShell 5.1로 실행합니다.

`build.sh`는 자신이 만든 marker가 있는 `cli/`, `app/`만 교체합니다. 같은 이름의 일반 폴더나 symlink가 있으면 내용을 건드리지 않고 실패합니다.

## 수정 규칙

- 킷 본체 수정은 항상 **이 폴더에서만** 한다. `cli/`, `app/`은 build.sh가 덮어쓰는 산출물이라 직접 고치면 다음 빌드 때 사라진다.
- 대상별 안내 문구는 `readmes/`의 해당 README만 고친다.
- 수정을 main에 올리기 전에 `npx changeset`으로 변경 기록을 남긴다 (사용자에게 보이는 변경이 없으면 생략 가능 — 그 경우 릴리스도 생기지 않는다).
