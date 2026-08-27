# ai-session-kit

## 0.3.0

### Minor Changes

- ec28e0c: 대화 응답이 사용자가 명시한 언어를 우선하고, 별도 지정이 없으면 현재 대화의 사용자 언어를 자동으로 따르도록 합니다. code·command·path 같은 기술 식별자, 기존 문서를 편집할 때의 원문 언어, vault의 canonical schema는 그대로 유지합니다.
- 4405a0c: 비개발자의 자연어 요청을 작은 local 구현과 검증까지 연결하는 `guided-development` skill을 추가합니다. 오류 추적용 `guided-debugging`, local 실행·미리보기용 `project-run-and-preview`, 완료 확인용 `change-verification`도 함께 제공합니다. 개발 기록은 canonical project와 source revision·working copy 상태를 함께 확인해 복원하며, 긴 작업이 안전한 checkpoint에 도달하면 동의 기반 session-end를 한 번 제안합니다. SessionStart hook은 project 확인 전에 문서 filename을 주입하지 않고 count만 안내합니다. README는 일회성 질문보다 여러 대화에 걸친 개발에서 이 킷이 필요한 이유와 실제 동작 범위를 먼저 설명합니다. state 도입 전 4개·7개·9개 skill 설치본도 새 구성으로 안전하게 업데이트합니다.

## 0.2.0

### Minor Changes

- ef3db76: Windows PowerShell 5.1용 설치·제거·hook과 native Windows CI 검증을 추가합니다.

## 0.1.0

### Minor Changes

- d2de031: 초기 구성 — 세션 기록·복원·조회 스킬(session-end/session-start/kb-lookup/kb-routing), 글쓰기 스킬(humanize-ko/cognitive-rhythm-writing/task-doc-writing), 주간·월간 요약(수동), vault lint, PII 스캔 훅, Claude/Codex 배선, cli·app 이원 배포

### Patch Changes

- 16e45ea: 기록 규칙 다듬기 — session-end에서 같은 주제 후보가 여럿이면 자동 선택하지 않고 확인, kb-lookup은 private 존을 수집 단계부터 제외, weekly-summary에 2주 이상 방치된 in-progress 태스크 정리 제안 추가
- 4412369: 설치·배포 안전성 보강 — 실행되는 skill·hook·lint를 sync vault 밖 local runtime으로 분리하고 installer 소유 symlink·hook만 갱신·제거하도록 변경, Codex SessionStart/PreToolUse hook 지원, symlink·filename·result-aware 쓰기 전 PII 검사와 secret-safe 결과, 안전한 dist 빌드와 PR artifact 검증, AGENTS.md·archived/cancelled lifecycle·vault lint 정합성 추가
