#!/usr/bin/env bash
# SessionStart hook: vault 상태와 문서 개수만 context로 주입한다.

set -u

STATE_DIR="${AI_SESSION_KIT_STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
VAULT_RAW="${KB_VAULT:-}"
if [ -z "$VAULT_RAW" ] && [ -f "$STATE_DIR/install-state" ] && [ ! -L "$STATE_DIR/install-state" ]; then
  state_lines=()
  while IFS= read -r state_line || [ -n "$state_line" ]; do
    state_lines[${#state_lines[@]}]="$state_line"
  done < "$STATE_DIR/install-state"
  state_marker="${state_lines[0]:-}"
  state_valid=1
  case "$state_marker" in
    ai-session-kit-state-v1) ;;
    ai-session-kit-state-v2)
      if [ -z "${state_lines[2]:-}" ] || [ -z "${state_lines[3]:-}" ]; then
        state_valid=0
      fi
      ;;
    ai-session-kit-state-v3)
      state_skill_count="${state_lines[5]:-}"
      case "$state_skill_count" in
        ''|0*|*[!0-9]*) state_valid=0 ;;
        *)
          if [ "${state_lines[4]:-}" != 'ai-session-kit-owned-skills-v1' ] ||
            [ "${#state_lines[@]}" -ne $((state_skill_count + 6)) ] ||
            [ -z "${state_lines[2]:-}" ] || [ -z "${state_lines[3]:-}" ]; then
            state_valid=0
          else
            for ((state_skill_index = 0; state_skill_index < state_skill_count; state_skill_index += 1)); do
              state_skill_name="${state_lines[$((state_skill_index + 6))]}"
              case "$state_skill_name" in
                ''|*[!a-z0-9-]*|-*|*-) state_valid=0 ;;
              esac
              for ((previous_state_skill_index = 0; previous_state_skill_index < state_skill_index; previous_state_skill_index += 1)); do
                if [ "$state_skill_name" = "${state_lines[$((previous_state_skill_index + 6))]}" ]; then
                  state_valid=0
                fi
              done
            done
          fi
          ;;
      esac
      ;;
    *) state_valid=0 ;;
  esac
  if [ "$state_valid" -eq 1 ]; then
    VAULT_RAW="${state_lines[1]:-}"
  fi
fi
if [ -z "$VAULT_RAW" ] || ! VAULT="$(cd "$VAULT_RAW" 2>/dev/null && pwd -P)"; then
  exit 0
fi

TASK_DIR="$VAULT/00.memory/tasks/in-progress"
ZONES=(00.memory 10.notes 20.work)

count_tasks() {
  [ -d "$TASK_DIR" ] || {
    printf '0'
    return 0
  }
  find "$TASK_DIR" -maxdepth 1 -type f -name '*.md' -exec printf 'x\n' \; 2>/dev/null |
    wc -l |
    tr -d '[:space:]'
}

count_recent_files() {
  local path count=0

  (
    cd "$VAULT" || exit 0
    while IFS= read -r -d '' path; do
      if grep -qE '^status:[[:space:]]*archived([[:space:]]|$)' "$path" 2>/dev/null; then
        continue
      fi
      count=$((count + 1))
    done < <(find "${ZONES[@]}" -type f -name '*.md' -mtime -7 -not -path '*/assets/*' -not -path '*/_kit/*' -print0 2>/dev/null)
    printf '%s' "$count"
  )
}

task_count="$(count_tasks)"
recent_count="$(count_recent_files)"
case "$task_count" in ''|*[!0-9]*) task_count=0 ;; esac
case "$recent_count" in ''|*[!0-9]*) recent_count=0 ;; esac

lint_line=""
if [ -f "$STATE_DIR/lint-latest.txt" ] && [ ! -L "$STATE_DIR/lint-latest.txt" ]; then
  IFS= read -r lint_line < "$STATE_DIR/lint-latest.txt" || true
  if ! printf '%s\n' "$lint_line" | grep -Eq '^kb-lint [0-9]{4}-[0-9]{2}-[0-9]{2}: ERR [0-9]+( — 모두 정상| — 상세는 kb_lint.py 재실행)$'; then
    lint_line=""
  fi
fi

context="[지식 vault — SessionStart hook 자동 주입]
작업 착수 전 vault 조회 규칙은 kb-lookup skill을 따를 것.
세션 기록은 자동 저장하지 말 것. 긴 작업이 안전하게 넘길 수 있는 지점에 도달하면 session-end skill의 제안 mode를 대화당 한 번만 적용하고, 사용자가 직접 종료를 요청하거나 제안에 동의한 뒤에만 기록할 것.
project가 확인되기 전에는 다른 project의 제목이나 파일명을 자동으로 읽어 context에 넣지 말 것. 사용자가 \"이어서 하자\"라고 하면 session-start skill로 current project를 확인한 뒤 matching task만 조회할 것.
상위 지침이 응답 언어를 정하지 않은 경우, 대화 응답 언어는 (1) 사용자가 명시적으로 지정한 언어, (2) 가장 최근의 의미 있는 사용자 발화 언어 순으로 결정할 것. 최신 발화가 짧거나 code 중심이거나 언어가 혼합되어 모호하면 이미 정해진 대화 언어를 유지할 것. repo·skill·hook·error message의 언어로 사용자 언어를 추론하지 말 것.
code·command·path·identifier·frontmatter·인용문은 원문을 보존할 것. 기존 문서를 수정할 때는 번역 요청이 없으면 원래 문서 언어를 유지하고, 문서 내용을 대화에서 요약할 때는 직접 인용만 원문으로 두고 나머지는 결정된 응답 언어로 설명할 것. 이 규칙은 대화 응답에만 적용한다. vault canonical schema heading과 terminal output은 번역하지 말 것. skill의 user-facing question·label·example은 고정 문자열이 아니라 semantic instruction으로 보고 결정된 응답 언어로 표현할 것.

## Vault 요약
진행 중 태스크: ${task_count}건
최근 7일 수정 문서: ${recent_count}건

## Vault 상태
${lint_line:-(lint 미실행 — session-end skill 실행 시 갱신)}
인덱스: 10.notes/INDEX.md · 20.work/INDEX.md · 진입점: CLAUDE.md · AGENTS.md"

if command -v jq >/dev/null 2>&1; then
  printf '%s' "$context" | jq -Rs '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}'
else
  printf '%s' "$context"
fi
exit 0
