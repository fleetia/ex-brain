---
"ai-session-kit": patch
---

설치·배포 안전성 보강 — 실행되는 skill·hook·lint를 sync vault 밖 local runtime으로 분리하고 installer 소유 symlink·hook만 갱신·제거하도록 변경, Codex SessionStart/PreToolUse hook 지원, symlink·filename·result-aware 쓰기 전 PII 검사와 secret-safe 결과, 안전한 dist 빌드와 PR artifact 검증, AGENTS.md·archived/cancelled lifecycle·vault lint 정합성 추가
