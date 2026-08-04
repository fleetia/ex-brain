# ai-session-kit (원본 저장소)

AI 세션 기록 킷의 **단일 원본**입니다. 이 폴더를 직접 배포하지 말고, build.sh로 만든 산출물을 배포합니다.

## 구조

- `skills/` `hooks/` `scripts/` `vault-template/` `setup.sh` `uninstall.sh` — 킷 본체 (두 배포판 공통)
- `readmes/README-cli.md` — 터미널·Claude Code 사용자용 안내
- `readmes/README-app.md` — Claude/Codex 앱 사용자용 안내 (일반인)
- `build.sh` — 상위 폴더에 `cli/`, `app/` 산출물 생성 (README만 다르고 코드는 동일)

## 배포 절차 (CI 자동)

버전 관리는 [changesets](https://github.com/changesets/changesets), 릴리스는 GitHub Actions가 담당한다.

1. 킷을 수정한다
2. `npx changeset` — 변경 요약을 쓰고 patch/minor를 고른다 (`.changeset/*.md` 생성됨)
3. main에 푸시 → CI가 **"chore: 버전 릴리스 준비" PR**을 생성/갱신한다 (쌓인 changeset = 업데이트 리스트가 CHANGELOG.md로 누적)
4. 그 PR을 머지 → CI가 `vX.Y.Z` GitHub Release를 만들고 `ai-session-kit-cli-vX.Y.Z.zip`, `ai-session-kit-app-vX.Y.Z.zip`을 첨부한다

친구에게는 Release 페이지의 zip 링크를 주면 된다.

로컬에서 확인용 빌드는 여전히 가능하다:

```bash
bash build.sh          # 상위 폴더(exterior/)에 cli/, app/ 생성
bash build.sh dist     # 원하는 출력 폴더 지정
```

## 수정 규칙

- 킷 본체 수정은 항상 **이 폴더에서만** 한다. `cli/`, `app/`은 build.sh가 덮어쓰는 산출물이라 직접 고치면 다음 빌드 때 사라진다.
- 대상별 안내 문구는 `readmes/`의 해당 README만 고친다.
- 수정을 main에 올리기 전에 `npx changeset`으로 변경 기록을 남긴다 (사용자에게 보이는 변경이 없으면 생략 가능 — 그 경우 릴리스도 생기지 않는다).
