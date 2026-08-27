# 지식 Vault — Agent 진입점

이 폴더는 개인 지식베이스다. 세션 기록(00.memory)과 재사용 지식(10.notes, 20.work)이 쌓인다.

## 검색 순서

1. 존별 인덱스 먼저: [10.notes/INDEX.md](10.notes/INDEX.md) · [20.work/INDEX.md](20.work/INDEX.md)
2. 과거 작업 기록: `00.memory/tasks/` — `YYMMDD_주제.md` 파일명이 결론을 담고 있어 파일명 grep이 가장 빠른 경로다
3. 없으면 `00.memory/`, `10.notes/`, `20.work/`만 grep한다. 같은 개념이 한글/영문 파일명으로 나뉘어 있을 수 있으니 두 언어 변형으로 검색한다

`90.private/`와 `_kit/`는 검색 후보를 모으는 단계부터 제외한다. `status: archived` 문서는 현재 지식으로 사용하지 않고, 사용자가 과거 이력 확인을 요청했을 때만 읽는다.

## 존 규칙

- **wiki존** `10.notes` `20.work`: 문서 추가·이동 시 해당 존 INDEX.md 갱신 필수 (`kb-routing` skill 참조)
- **log존** `00.memory`: 시간순 기록, 링크 없어도 정상. `cancelled`는 완료가 아니라 중단된 태스크
- **private존** `90.private`: 명시 요청 없이 읽지 말 것
- **legacy infra** `_kit`: 구버전 설치 잔여물이 있을 수 있으나 기본 검색·실행·수정 대상이 아님. 현재 runtime은 vault 밖에 있음

## 링크 해석 규칙

문서 간 markdown 링크는 **vault 루트 기준 상대경로**다 (예: `20.work/프로젝트-결정기록.md`). 파일 위치 기준(file-relative)으로 해석하지 말 것.

## 대화 응답 언어

- 상위 지침이 응답 언어를 정하지 않은 경우, 사용자가 응답 언어를 명시적으로 지정하면 그 언어를 사용한다. 지정이 없으면 가장 최근의 의미 있는 사용자 발화 언어를 따른다.
- 최신 발화가 짧거나 code 중심이거나 언어가 혼합되어 모호하면 이미 정해진 대화 언어를 유지한다. repo·skill·hook·error message의 언어로 사용자 언어를 추론하지 않는다.
- code·command·path·identifier·frontmatter·인용문은 원문을 보존한다. 기존 문서를 수정할 때는 번역 요청이 없으면 원래 문서 언어를 유지한다. 문서 내용을 대화에서 요약할 때는 직접 인용만 원문으로 두고 나머지는 결정된 응답 언어로 설명한다.
- 이 규칙은 대화 응답에만 적용한다. `## 작업 사본`같은 vault canonical schema heading과 terminal output은 번역하지 않는다. skill의 user-facing question·label·example은 고정 문자열이 아니라 semantic instruction이며, 결정된 응답 언어로 표현한다.
