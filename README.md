# ai-session-kit (원본 저장소)

AI 세션 기록 킷의 **단일 원본**입니다. 이 폴더를 직접 배포하지 말고, build.sh로 만든 산출물을 배포합니다.

## 구조

- `skills/` `hooks/` `scripts/` `vault-template/` `setup.sh` `uninstall.sh` — 킷 본체 (두 배포판 공통)
- `readmes/README-cli.md` — 터미널·Claude Code 사용자용 안내
- `readmes/README-app.md` — Claude/Codex 앱 사용자용 안내 (일반인)
- `build.sh` — 상위 폴더에 `cli/`, `app/` 산출물 생성 (README만 다르고 코드는 동일)

## 배포 절차

```bash
bash build.sh
cd .. && zip -rq ai-session-kit-cli.zip cli && zip -rq ai-session-kit-app.zip app
```

## 수정 규칙

- 킷 본체 수정은 항상 **이 폴더에서만** 한다. `cli/`, `app/`은 build.sh가 덮어쓰는 산출물이라 직접 고치면 다음 빌드 때 사라진다.
- 대상별 안내 문구는 `readmes/`의 해당 README만 고친다.
- 수정 후 배포 전에 build.sh를 다시 실행한다.
