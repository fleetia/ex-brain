# 지식 Vault — Agent 진입점

이 폴더는 개인 지식베이스다. 세션 기록(00.memory)과 재사용 지식(10.notes, 20.work)이 쌓인다.

## 검색 순서

1. 존별 인덱스 먼저: [10.notes/INDEX.md](10.notes/INDEX.md) · [20.work/INDEX.md](20.work/INDEX.md)
2. 과거 작업 기록: `00.memory/tasks/` — `YYMMDD_주제.md` 파일명이 결론을 담고 있어 파일명 grep이 가장 빠른 경로다
3. 없으면 vault 전체 grep — 같은 개념이 한글/영문 파일명으로 나뉘어 있을 수 있으니 두 언어 변형으로 검색할 것

## 존 규칙

- **wiki존** `10.notes` `20.work`: 문서 추가·이동 시 해당 존 INDEX.md 갱신 필수 (`kb-routing` skill 참조)
- **log존** `00.memory`: 시간순 기록, 링크 없어도 정상
- **private존** `90.private`: 명시 요청 없이 읽지 말 것
- **infra존** `_kit`: 스킬·훅 코드, 지식 라우팅 대상 아님

## 링크 해석 규칙

문서 간 markdown 링크는 **vault 루트 기준 상대경로**다 (예: `20.work/프로젝트-결정기록.md`). 파일 위치 기준(file-relative)으로 해석하지 말 것.
