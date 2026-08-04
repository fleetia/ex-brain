#!/usr/bin/env bash
# SessionStart hook: 지식 vault 동적 컨텍스트 주입
# - 진행 중 태스크 + 최근 7일 수정된 문서 파일명을 additionalContext로 전달
# - 실패해도 세션 시작을 막지 않도록 항상 exit 0
#
# vault 위치: 기본은 이 스크립트가 설치된 곳({vault}/_kit/hooks/) 기준으로 자동 인식.
# KB_VAULT 환경변수로 덮어쓸 수 있다.

VAULT="${KB_VAULT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TASK_DIR="$VAULT/00.memory/tasks/in-progress"
ZONES="00.memory 10.notes 20.work"

task_total=$(ls -1 "$TASK_DIR" 2>/dev/null | grep -c '\.md$')
tasks=$(ls -1r "$TASK_DIR" 2>/dev/null | grep '\.md$' | head -10)
if [ "${task_total:-0}" -gt 10 ]; then
  tasks="$tasks
… 외 $((task_total - 10))건"
fi

# 최근 7일 수정된 md (mtime 역순). stat은 BSD(macOS) 우선, 실패 시 GNU 폴백
recent=$(cd "$VAULT" 2>/dev/null && find $ZONES \
  -name '*.md' -mtime -7 -not -path '*/assets/*' \
  -exec stat -f '%m%t%N' {} + 2>/dev/null | sort -rn | head -12 | cut -f2-)
if [ -z "$recent" ]; then
  recent=$(cd "$VAULT" 2>/dev/null && find $ZONES \
    -name '*.md' -mtime -7 -not -path '*/assets/*' \
    -exec stat -c '%Y'$'\t''%n' {} + 2>/dev/null | sort -rn | head -12 | cut -f2-)
fi

context="[지식 vault — SessionStart hook 자동 주입]
작업 착수 전 vault 조회 규칙은 kb-lookup skill을 따를 것.
세션을 마칠 때는 session-end skill로 기록을 남길 것.

## 진행 중 태스크 (00.memory/tasks/in-progress/, 최신순)
${tasks:-(없음)}

## 최근 7일 수정된 문서 ($VAULT 기준)
${recent:-(없음)}

## 인덱스
10.notes/INDEX.md · 20.work/INDEX.md · 진입점 $VAULT/CLAUDE.md"

if command -v jq >/dev/null 2>&1; then
  printf '%s' "$context" | jq -Rs '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}'
else
  printf '%s' "$context"
fi
exit 0
