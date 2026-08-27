---
name: session-start
description: 세션 시작 시 이전 세션의 컨텍스트를 복원한다. 사용자가 "/session-start", "이어서 하자", "지난번 작업 이어서", 또는 진행 중이던 작업을 복원해달라고 요청할 때 사용.
---

# Session Start

지식 vault(`~/KnowledgeBase`)의 태스크 기록에서 이전 세션의 컨텍스트를 복원한다.

## Workflow

### 1. 진행 중 태스크 확인

- 현재 폴더가 개발 project라면 [project identity 규칙](../kb-routing/references/project-identity.md)으로 canonical project key를 먼저 확인한다.
- 사용자가 태스크 파일명을 지정했으면 `00.memory/tasks/{in-progress,todo,done,cancelled}/` 전체에서 정확한 파일명을 찾는다. 상태가 바뀌어 이동한 기록도 놓치지 않는다. 현재 project와 파일의 `project`가 다르거나 비어 있으면 그 차이를 먼저 알린다. 이 상태에서는 read-only 요약만 할 수 있고, code 작업·상태 이동은 하지 않는다.
- 지정하지 않았으면 `00.memory/tasks/in-progress/`에서 exact current `project` 값을 가진 frontmatter만 먼저 찾는다. unrelated task filename·title·본문을 출력하거나 context에 모으지 않는다:
  - 현재 project와 일치하는 태스크가 1개면 사용한다
  - 현재 project와 일치하는 태스크가 여러 개면 목록을 보여주고 어떤 작업을 이어갈지 묻는다
  - 일치하는 태스크가 없으면 "현재 project의 진행 중 태스크가 없습니다"라고 안내한다. 다른 project나 `project`가 없는 태스크는 개수만 알리고, 사용자가 cross-project 목록을 명시적으로 요청하지 않으면 filename·title을 보여주거나 자동 선택하지 않는다
  - current project를 확정할 수 없고 유일한 태스크에 `project`가 있으면 key와 함께 보여주고 선택을 확인한다. 유일한 태스크도 projectless라면 기존처럼 사용한다
- 지정한 태스크가 `done` 또는 `cancelled`면 현재 상태를 먼저 알리고, 다시 열어 진행할지 확인하기 전에는 `in-progress`로 바꾸지 않는다.

### 2. 태스크 파일 읽기

- 태스크 파일 전체를 읽고 frontmatter(`status`, `project`, `source-revision`, `working-copy-state`, `work-dates`)와 `## 작업 사본`, `## 미완료`, `## 과정 노트`를 파악한다.

### 3. Live code state 대조

개발 기록에 `source-revision` 또는 `working-copy-state`가 있으면 현재 repository에서 read-only command로 full `HEAD`와 staged·unstaged·untracked 상태를 확인한다.

- 기록의 `source-revision`과 현재 full object id가 정확히 같아야 한다. 같은 project key나 같은 branch 이름만으로 같은 code state라고 판단하지 않는다.
- 기록이 `working-copy-state: clean`이면 현재 working tree도 clean이어야 자동으로 재개할 수 있다.
- 기록이 `working-copy-state: uncommitted`이면 자동으로 일치 판정하지 않는다. 기록만으로 original checkout을 식별하거나 diff의 동일성을 증명할 수 없기 때문이다. 현재 `HEAD`와 changed path를 read-only로 보여주고, 사용자가 session-end 때 유지하라고 안내받은 original checkout을 열었다고 명시적으로 확인한 뒤에만 안전하게 확인할 수 있는 tracked diff를 `## 작업 사본`·`## 작업 내용`과 대조한다. 파일명이나 `HEAD`만 같다는 이유로 재개하지 않는다.
- diff나 file content를 열기 전에 path와 file type을 먼저 확인한다. `.env*`, credential·secret·private key, 고객·사용자 export, database dump, 민감정보 가능 path, binary·대용량 file, 기록에서 생략·redact된 path는 내용을 읽지 않는다. 이 파일 없이는 일치를 증명할 수 없다면 fail closed로 `불일치` 또는 `확인 불가`를 보고하고 original checkout을 열도록 안내한다.
- untracked file 내용은 working copy 일치 여부를 판단하려고 열지 않는다. repository-relative path·status와 기록된 결과만 확인하며, 사용자가 original checkout임을 확인하지 못하면 code가 동등해 보여도 자동 재개하지 않는다.
- 기록이 `working-copy-state: unknown`이면 자동으로 재개하지 않고 현재 source와 기록된 산출물을 수동으로 대조한다.
- `HEAD` 또는 dirty state가 다르거나 original checkout인지 확인할 수 없으면 기록은 read-only로 요약하되 code 수정과 태스크 상태 이동은 멈춘다. 원래 checkout을 열거나, 현재 변경을 보존한 채 matching state로 이동하는 방법을 설명하고 사용자에게 선택을 받는다.
- 이 과정에서 `checkout`, `switch`, `reset`, `stash`, `commit`, `fetch`, `pull`, `push`를 자동 실행하지 않는다. 기존 변경을 덮어쓰거나 외부 상태를 바꾸는 방법은 영향과 복구 방법을 설명하고 별도 승인을 받는다.
- legacy 기록에 source snapshot 필드가 없으면 복원이 검증되지 않았다고 밝히고, 현재 diff와 기록된 산출물을 먼저 대조한다. 대조 전에는 "그대로 이어졌다"고 말하지 않는다.
- 문서·조사처럼 repository code state와 무관한 기록은 이 단계를 건너뛴다.

### 4. 관련 지식 조회 (1회)

- 태스크 제목과 핵심 키워드로 `kb-lookup` skill의 검색 동작을 수행한다.
- 매칭 문서가 있으면 요약 마지막에 `### 관련 문서` 섹션으로 경로 + 한 줄 요약을 붙인다. 없으면 섹션을 생략한다.
- 이 검색으로 해당 태스크의 kb-lookup은 완료된 것으로 간주한다 — 이어지는 본 작업에서 같은 주제를 다시 검색하지 않는다.

### 5. 컨텍스트 요약 출력

```
## 세션 시작: {태스크 제목}

**상태**: {status}
**Project**: {project가 있을 때만}
**Code state**: 일치 | 확인 필요 | 불일치 | 기록 없음 | 해당 없음
**작업 일자**: {work-dates}

### 미완료 작업
{## 미완료 섹션 내용}

### 관련 문서
{있을 때만}

---
이 작업을 이어서 진행할까요?
```

### 6. 사용자 확인 후 작업 시작

- 현재 project와 태스크의 `project`가 다르면 matching project를 실제로 연 뒤 project key를 다시 확인하기 전에는 작업을 재개하지 않는다. 기록의 key가 오래된 것으로 의심되면 live repository evidence로 같은 codebase임을 확인하고, 사용자가 key migration을 승인한 뒤 frontmatter를 고친다.
- project가 같아도 기록된 code state와 현재 checkout이 다르면 read-only 요약만 한다. original checkout 또는 matching `HEAD`와 working tree가 확인되기 전에는 code 작업·상태 이동을 하지 않는다.
- current project key를 확인할 수 없는데 태스크에 `project`가 있으면 read-only 요약만 하고, matching project를 연 뒤 다시 시작한다.
- 현재 project에서 `project` 없는 legacy 태스크를 재개하려면 먼저 이 기록이 현재 project 것인지 사용자에게 확인하고, 동의했을 때 canonical key를 frontmatter에 추가한다.
- `in-progress` 태스크는 확인 뒤 그대로 이어간다.
- `done` 또는 `cancelled` 태스크를 사용자가 단순히 읽어보려는 경우에는 파일을 바꾸지 않는다.
- project와 필요한 code state가 일치한 뒤 사용자가 재개를 명시적으로 확인하면 `status: in-progress`로 바꾸고 `end`를 제거한 뒤 `in-progress/`로 옮긴다. 이동 전에 `00.memory/`, `10.notes/`, `20.work/`의 inbound link를 찾아 경로를 고치고, 오늘 날짜를 `work-dates`에 추가하며 이전 상태와 재개 이유를 `## 과정 노트`에 기록한다.

## Edge Cases

| 상황 | 처리 |
|---|---|
| in-progress 태스크 없음 | 안내 후 최근 done/cancelled 기록을 상태와 함께 참고 표시, 새 작업으로 진행 |
| 지정한 파일명이 없음 | 네 status 폴더를 확인한 뒤 in-progress 목록을 보여주고 다시 선택 요청 |
| 현재 project와 태스크의 `project` 불일치 | read-only 요약만 허용. matching project를 열거나 검증된 key migration을 마치기 전에는 code 작업·상태 이동 금지 |
| project는 같지만 `HEAD`·working tree 불일치 | 같은 repository와 같은 checkout을 구분해 설명. matching code state를 열기 전에는 code 작업·상태 이동 금지 |
| uncommitted 기록인데 original checkout 확인 안 됨 | read-only 요약만 허용. 기록과 path가 비슷하다는 이유로 동일한 code라고 판정하지 않음 |
| legacy 개발 기록에 code state 없음 | 현재 diff와 기록된 산출물을 수동 대조하고, 확인 전에는 복원 완료로 표현하지 않음 |
| 지정한 태스크가 done/cancelled | 상태와 마지막 기록을 요약하고, 명시적 재개 확인 전에는 파일을 변경하지 않음 |
| 태스크 파일에 `## 미완료` 없음 | `## 작업 내용` 기준으로 요약 |
