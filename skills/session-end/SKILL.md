---
name: session-end
description: 세션 종료 시 현재 세션의 컨텍스트를 요약하고 미완료 작업과 재사용 지식을 vault에 저장한다. 사용자가 `/session-end`를 호출하거나, 사용 언어와 관계없이 현재 세션의 종료·저장·인수인계를 요청했을 때 실행한다. 긴 작업이 안전하게 넘길 수 있는 checkpoint에 도달했을 때는 한 번만 정리를 제안하며, 명시 요청이 없으면 동의 전에 파일을 쓰지 않는다.
---

# Session End

현재 세션의 컨텍스트를 지식 vault(`~/KnowledgeBase`)에 정리하고, 다음 세션이 이어받을 수 있게 저장한다.

상위 지침이 언어를 정하지 않은 경우 사용자에게 보이는 질문·안내·상태 label은 사용자가 지정한 언어를 우선하고, 없으면 최근의 의미 있는 사용자 발화 언어를 따른다. 발화가 짧거나 혼합되어 모호하면 이미 형성된 대화 언어를 유지하며, code·command·path·identifier는 번역하지 않는다. 아래 한국어 안내문은 고정 문구가 아니라 의미 예시이므로 선택한 응답 언어로 표현한다. 다만 새 문서 구조의 frontmatter key와 `## 작업 내용`, `## 검증`, `## 작업 사본`, `## 미완료`, `## 과정 노트` heading은 canonical vault schema이므로 번역하지 않는다.

## 실행 모드와 제안 모드

사용자가 `/session-end`를 호출하거나 어떤 언어로든 현재 세션을 종료·저장·인수인계하겠다는 의도를 명시하면 바로 아래 workflow를 실행한다. 특정 오류나 내용을 README·문서 등에 기록해 달라는 요청은 session-end 실행 신호로 보지 않는다.

명시 요청이 없어도 다음 조건을 모두 만족하면 세션 정리를 한 번 제안할 수 있다.

- 조사·구현·검증처럼 실질적인 phase가 여러 개 누적됐거나, host가 context compaction·한계 신호를 제공했거나, 다음 phase를 별도 대화로 나누는 편이 명확히 유리하다.
- 현재 milestone이 끝났고 local 변경, 결정, 검증 결과 또는 명확한 blocker를 온전히 설명할 수 있다.
- 다음에 이어갈 작업이나 별도 phase가 남아 있다.
- command·test가 실행 중이지 않고, migration이나 파일 변경이 반쯤 적용된 상태가 아니며, 즉시 받아야 할 사용자 결정도 없다.
- 개발 작업이면 다음 세션이 현재 code state를 실제로 볼 수 있다. Git working tree가 dirty라면 같은 checkout에서 새 대화를 열 수 있거나, 사용자가 별도로 승인한 방법으로 변경이 다음 환경에서 도달 가능한 상태여야 한다. 같은 repository라는 이유만으로 이 조건을 충족했다고 보지 않는다.

turn 수나 추정 token 수만으로 제안하거나 성능·비용 절감량을 단정하지 않는다. 현재 대화에서 이미 제안했다면 수락·거절·무응답과 관계없이 다시 제안하지 않는다. 사용자가 "나중에 다시 알려줘"라고 명시한 경우만 다음 안정적인 checkpoint에서 다시 제안한다.

다음처럼 기술 용어보다 안전한 인수인계에 초점을 맞춘다.

> 여기까지는 안전하게 끊을 수 있는 지점이에요. 지금까지의 결정·확인한 것·남은 일을 기록한 뒤 새 대화에서 "이어서 하자"라고 하면 계속할 수 있습니다. 지금 정리할까요?

제안 여부는 현재 대화의 상태로 판단하며, 제안만을 위해 vault를 새로 읽지 않는다. 동의 전에는 vault나 다른 파일을 쓰지 않는다. code state를 다음 대화에서 볼 수 있는지 확실하지 않다면 "안전하게 끊을 수 있다"고 제안하지 말고, 현재 변경이 이 checkout에만 있을 수 있다는 점과 필요한 선택을 먼저 설명한다. commit·stash·push는 사용자가 승인하지 않은 채 인수인계를 위해 실행하지 않는다.

동의하면 아래 workflow를 실행한다. 다음 대화가 같은 code state에 접근할 수 있음을 확인한 경우에만 미완료 작업의 완료 보고를 다음 안내로 끝낸다.

> 기록했어요. 같은 code state가 열리는 새 대화에서 "이어서 하자"라고 말하면 이 작업을 불러옵니다.

dirty working tree처럼 현재 checkout에만 변경이 남아 있다면 새 대화 전환을 보장하지 말고 다음처럼 알린다.

> 기록은 남겼지만 수정한 코드는 아직 현재 checkout에만 있습니다. 이 작업 화면과 checkout을 유지하고, 새 대화도 같은 checkout에서 열 때만 그대로 이어갈 수 있어요.

## Safety

- 명시 요청을 받았거나 제안에 동의한 뒤에는 저장 여부를 중간에 다시 묻지 말고 끝까지 진행한다.
- vault에 파일을 만들고 고치는 것 외의 상태 변경(파일 삭제, 외부 전송, 설정 변경)은 하지 않는다.
- `90.private/`는 사용자가 이번 세션에서 명시적으로 다룬 경우가 아니면 읽지 않는다.

## Workflow

### 1. 세션 결과 정리

- 대화를 기준으로 완료한 작업, 남은 작업, 진행 중 새로 발견한 작업을 정리한다.
- 구현과 검증을 구분한다. 실행한 test·build·lint와 직접 확인한 사용 흐름, 아직 검증하지 못한 항목을 기록한다. local 구현을 배포나 외부 전달 완료로 표현하지 않는다.
- **과정 노트**를 보존한다: 시도했다가 접은 방향, 번복된 결정, 실패 원인, 최종 결론, 사용자가 직접 고친 부분을 시간순으로 남긴다. 결과만 남기지 말고 "왜 그렇게 됐는지"를 남긴다.
- 결과물 파일(시안, 문서, 산출물)이 세션 밖에 있으면 경로나 링크를 기록한다.
- Git repository의 code·config를 다룬 세션이면 read-only command로 full `HEAD`와 working tree가 `clean`인지 `dirty`인지 확인하고, dirty라면 staged·unstaged·untracked changed path를 확인한다. repository script는 실행하지 않는다.
- absolute checkout path와 diff 내용은 vault에 저장하지 않는다. changed path는 repository-relative로만 기록하고, 이름 자체가 민감하면 원문 대신 영역과 개수만 남긴다. ignored file·submodule·생성물이 다음 작업에 필요하지만 `HEAD`와 status로 확인되지 않으면 `working-copy-state: unknown`으로 기록하고 그 한계도 남긴다.

### 2. 태스크 파일 생성 또는 갱신

1. 개발 대상이 있는 세션이면 [project identity 규칙](../kb-routing/references/project-identity.md)을 읽고 canonical project key를 확인한다.
2. `00.memory/tasks/{done,in-progress,todo,cancelled}/`에서 같은 project와 주제의 기존 파일을 파일명·frontmatter로 찾는다 (`ls` + grep).
3. 있으면 그 파일을 갱신하고, 없으면 `YYMMDD_{주제-kebab-case}.md`를 새로 만든다.
4. 같은 주제로 볼 만한 기존 파일이 2개 이상이거나, 개발 기록의 `project`가 다르거나 비어 있어 동일 project인지 판단할 수 없으면 자동으로 고르거나 병합하지 말고 경로를 나열해 어느 쪽을 갱신할지 사용자에게 확인받는다.
5. 유일한 기존 파일이라도 `done` 또는 `cancelled` 상태면 조용히 다시 열지 않는다. 사용자가 해당 기록을 재개할지 확인한 뒤, 동의했을 때만 `status: in-progress`로 바꾸고 `end`를 제거해 `in-progress/`로 옮긴다. 재개 사실과 이유를 `## 과정 노트`에 남긴다.
6. 남은 작업이 있으면 `in-progress/`, 모두 끝났으면 `done/`에 둔다. 사용자가 이 일을 더 진행하지 않겠다고 명시적으로 확정한 경우에만 `cancelled/`에 둔다.

새 문서 구조:

```markdown
---
title: {작업 한 줄 요약}
status: done | in-progress | cancelled
project: "{개발 작업일 때 canonical project key}"
source-revision: "git:{Git full object id; code·config를 다룬 세션에서 HEAD가 있을 때}"
working-copy-state: clean | uncommitted | unknown
start: YYYY-MM-DD
end: YYYY-MM-DD
tags: [{관련 태그}]
work-dates: [YYYY-MM-DD]
---

## 작업 내용
- {주요 결과}

## 검증
- {실행한 검사와 결과, 또는 미검증 항목}

## 작업 사본
- {이번 task 관련 changed path의 staged·unstaged·untracked 상태와 다음 세션이 같은 상태를 찾기 위한 조건}

## 미완료
- {남은 작업}

## 과정 노트
- {시도, 실패, 번복, 결정 과정}
```

- 값이 없는 섹션과 frontmatter 필드는 생략한다. 구현·파일 변경처럼 검증 대상이 있는 세션에서 검증을 실행하지 못했다면 `## 검증`을 생략하지 말고 무엇을 확인하지 못했는지 남긴다.
- Git repository의 code·config를 다룬 세션에서는 `working-copy-state`를 매번 최신 값으로 덮어쓴다. `HEAD`가 있으면 `source-revision`도 기록한다. 아직 첫 commit이 없어 `HEAD`가 없지만 status는 확인할 수 있으면 `source-revision`만 생략하고 실제 상태를 `uncommitted`로 기록한다. status 자체를 확인할 수 없을 때만 `working-copy-state: unknown`과 이유를 남긴다.
- `working-copy-state: uncommitted`이면 `## 작업 사본`을 생략하지 않는다. 전체 dirty file을 이번 task의 결과로 추정하지 말고, 이번 task와 관련된 repository-relative path만 staged·unstaged·untracked로 구분한다. 관련 없는 기존 변경은 별도로 존재 여부만 알리고 task 결과에 포함하지 않는다. 이 기록만으로 다른 checkout에 code가 복사되거나 working copy가 동일해졌다고 증명할 수 없으므로, original checkout을 유지하고 다음 세션에서 사용자가 같은 checkout임을 확인해야 이어갈 수 있다고 명시한다.
- 요청된 동작의 필수 검증이 남아 있으면 미완료로 취급해 `## 미완료`에도 남기고 `in-progress`를 유지한다. 사용자가 검증 한계를 알고도 이 상태로 닫겠다고 명시한 경우에만 `done`으로 정리한다.
- 기존 문서를 갱신할 때는 오늘 날짜를 `work-dates`에 추가하고, 해결된 미완료 항목을 지운다.
- 모든 작업이 끝났으면 `status: done`과 `end`를 기록하고 파일을 `done/`으로 옮긴다. 옮기기 전에 `00.memory/`, `10.notes/`, `20.work/`에서 파일명을 grep해 이 파일을 가리키는 링크가 있으면 경로를 함께 고친다. `90.private/`는 이번 세션에서 사용자가 명시적으로 다룬 경우에만 별도로 확인한다.
- 사용자가 중단을 확정하면 `status: cancelled`와 `end`를 기록하고 `cancelled/`로 옮긴다. 완료하지 않은 일을 `done`으로 보내지 않고, 중단 이유를 `## 과정 노트`에 남긴다. 방치됐다는 이유만으로 취소를 추론하지 않는다.
- 파일명에 사람 이름을 넣지 않는다. hook은 filename을 자동 주입하지 않지만, 인수인계 기록을 찾거나 공유할 때 검색 결과로 보일 수 있다.

### 3. 재사용 지식 승격

이번 태스크와 무관하게 나중에 다시 찾아볼 가치가 있는 것만 승격한다: 결정과 그 근거, 도구·방법 비교, 반복될 문제의 원인과 해결, 재사용 패턴.

- 먼저 같은 project와 주제를 vault에서 검색하고, 기존 문서가 있으면 병합한다. 다른 project 문서와 자동 병합하지 않는다.
- 저장 위치와 frontmatter는 `kb-routing` skill의 규칙을 따른다 (개인 배움 → `10.notes/`, 회사·프로젝트 지식 → `20.work/`).
- 개발 태스크의 지식을 특정 codebase용 `20.work` 문서로 승격하면 태스크와 같은 canonical `project` 값을 보존한다.
- 승격한 문서의 경로를 태스크 파일에 링크로 남긴다.
- 억지로 새 문서를 만들지 않는다. 승격할 게 없으면 조용히 건너뛴다.

### 4. Vault lint

`__KB_LINT_COMMAND__`를 실행한다. setup.sh 또는 setup.ps1이 이 자리를 local runtime과 vault에 맞는 명령으로 바꾼다.

- 이번 세션이 만든 깨진 링크, INDEX 누락, 폴더-status 불일치는 즉시 수정하고 다시 검사한다.
- 세션과 무관한 기존 문제는 수정하지 않고 태스크 파일의 `## 미완료`에 남긴다.
- Python 3가 없으면 조용히 건너뛴다.

### 5. 완료 보고

- 생성·갱신한 파일 경로와 구현·검증 상태를 구분해 알려준다.
- 미완료 작업이 있으면 개수와 함께 code state의 인수인계 가능 여부를 알려준다. 같은 상태에 접근할 수 있다고 확인한 경우에만 "다음 세션에서 session-start로 이어서 할 수 있다"고 안내한다.
- lint에서 고친 것이 있을 때만 한 줄로 덧붙인다.
