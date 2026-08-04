---
name: kb-routing
description: 지식 vault(~/KnowledgeBase)에 Markdown 문서를 생성·이동·정리·폐기할 때 존 라우팅, frontmatter, INDEX 갱신 규칙을 적용한다.
---

# 지식 라우팅

지식 vault(`~/KnowledgeBase`)에 문서를 추가하거나 옮길 때마다 이 skill을 따른다.

## Core Rules

1. **미래의 조회 의도로 분류한다.** "나중에 어떤 질문으로 이 문서를 찾게 될까?"를 기준으로 두지, 만든 날짜나 만든 계기로 분류하지 않는다.
2. **활성 지식은 정확히 한 곳에만 둔다.** 같은 내용을 두 존에 복사하지 않는다.
3. **대체된 문서는 지우지 않는다.** frontmatter를 `status: archived`로 바꾸고 문서 상단에 대체 문서 링크를 남긴다. 삭제는 사용자가 명시적으로 요청할 때만.
4. **이동하면 링크를 고친다.** 파일을 옮기기 전에 vault 전체에서 파일명을 grep해서 이 파일을 가리키는 링크를 먼저 고치고, 해당 존 INDEX를 갱신한다.
5. **파일명에 사람 이름을 넣지 않는다.** 파일명은 세션 시작 시 자동으로 컨텍스트에 주입된다.
6. **문서 하나를 추가할 때는 그 존의 INDEX만 갱신한다.** 사용자가 재정비를 요청하지 않는 한 다른 폴더·INDEX를 대량 생성하거나 고치지 않는다.

## Zone Contract

존 타입에 따라 의무가 다르다. wiki존 규칙(INDEX 갱신, 고아 문서 검사)을 log존에 적용하지 않는다.

| 존 타입 | 폴더 | 규칙 |
|---|---|---|
| wiki | `10.notes/` `20.work/` | INDEX.md 필수, 추가·이동 시마다 갱신. frontmatter 필수. 모든 문서가 INDEX에서 도달 가능해야 함 |
| log | `00.memory/` | 시간순 기록. 날짜 접두 파일명이 곧 인덱스. INDEX 의무 없음, 링크 안 걸린 문서가 정상 |
| private | `90.private/` | 사용자가 명시적으로 요청하지 않으면 읽지도 인용하지도 않는다 |
| infra | `_kit/` | 스킬·훅·설정 파일. 지식 라우팅 대상이 아님 |

## Routing Map

| 목적지 | 이런 것 |
|---|---|
| `10.notes/` | 개인 배움, 리서치 기록, 도구·방법 비교, 아이디어, 어디서든 통하는 일반 지식 |
| `20.work/` | 회사·프로젝트에 묶인 지식: 결정과 근거, 프로젝트 히스토리, 팀 프로세스, 내부 시스템 설명 |

**Tie-breaker**: 회사 제품·프로젝트·팀에 묶인 지식은 리서치 형태라도 `20.work/`, 일반 지식은 회사 일에 쓰였더라도 `10.notes/`.

## Frontmatter

새 문서에는 다음을 포함한다:

```yaml
---
title:
date: YYYY-MM-DD
tags: []
status: active
---
```

- `status`: `active`(현재 유효) | `archived`(대체됨·더 이상 유효하지 않음)
- 태스크 파일(`00.memory/tasks/`)은 session-end skill의 별도 스키마(`status: todo | in-progress | done`)를 따른다. 폴더 위치와 status는 일치해야 한다 — `done/` 아래 파일이 `status: in-progress`를 달고 있으면 안 된다.

## Link Convention

- 문서 간 링크는 **vault 루트 기준 상대경로**로 쓴다: `](20.work/프로젝트-결정기록.md)`. 파일 위치 기준 `../` 경로를 쓰지 않는다.
- 링크 규칙이 하나면 검색과 이동이 단순해진다. 주 독자는 사람보다 LLM이라는 전제.
