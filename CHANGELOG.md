# ai-session-kit

## 0.1.0

### Minor Changes

- d2de031: 초기 구성 — 세션 기록·복원·조회 스킬(session-end/session-start/kb-lookup/kb-routing), 글쓰기 스킬(humanize-ko/cognitive-rhythm-writing/task-doc-writing), 주간·월간 요약(수동), vault lint, PII 스캔 훅, Claude/Codex 배선, cli·app 이원 배포

### Patch Changes

- 16e45ea: 기록 규칙 다듬기 — session-end에서 같은 주제 후보가 여럿이면 자동 선택하지 않고 확인, kb-lookup은 private 존을 수집 단계부터 제외, weekly-summary에 2주 이상 방치된 in-progress 태스크 정리 제안 추가
- 4412369: 설치·배포 안전성 보강 — 실행되는 skill·hook·lint를 sync vault 밖 local runtime으로 분리하고 installer 소유 symlink·hook만 갱신·제거하도록 변경, Codex SessionStart/PreToolUse hook 지원, symlink·filename·result-aware 쓰기 전 PII 검사와 secret-safe 결과, 안전한 dist 빌드와 PR artifact 검증, AGENTS.md·archived/cancelled lifecycle·vault lint 정합성 추가
