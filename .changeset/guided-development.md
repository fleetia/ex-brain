---
"ai-session-kit": minor
---

비개발자의 자연어 요청을 작은 local 구현과 검증까지 연결하는 `guided-development` skill을 추가합니다. 오류 추적용 `guided-debugging`, local 실행·미리보기용 `project-run-and-preview`, 완료 확인용 `change-verification`도 함께 제공합니다. 개발 기록은 canonical project와 source revision·working copy 상태를 함께 확인해 복원하며, 긴 작업이 안전한 checkpoint에 도달하면 동의 기반 session-end를 한 번 제안합니다. SessionStart hook은 project 확인 전에 문서 filename을 주입하지 않고 count만 안내합니다. README는 일회성 질문보다 여러 대화에 걸친 개발에서 이 킷이 필요한 이유와 실제 동작 범위를 먼저 설명합니다. state 도입 전 4개·7개·9개 skill 설치본도 새 구성으로 안전하게 업데이트합니다.
