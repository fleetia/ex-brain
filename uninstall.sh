#!/usr/bin/env bash
# uninstall.sh — installer가 소유한 배선만 제거한다. vault 데이터는 남긴다.

set -euo pipefail

USER_HOME="${AI_SESSION_KIT_USER_HOME:-$HOME}"
CLAUDE_DIR="$USER_HOME/.claude"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
CODEX_HOOKS="$USER_HOME/.codex/hooks.json"
STATE_DIR="$USER_HOME/.ai-session-kit"
STATE_FILE="$STATE_DIR/install-state"
STATE_MARKER="ai-session-kit-state-v3"
PREVIOUS_STATE_MARKER="ai-session-kit-state-v2"
LEGACY_STATE_MARKER="ai-session-kit-state-v1"
STATE_SKILLS_MARKER="ai-session-kit-owned-skills-v1"
RUNTIME_DIR="$STATE_DIR/runtime"
RUNTIME_MARKER=".ai-session-kit-runtime"
RUNTIME_MARKER_CONTENT="ai-session-kit-runtime-v2"
LEGACY_RUNTIME_MARKER_CONTENT="ai-session-kit-runtime-v1"
SESSION_HOOK_MARKER="AI_SESSION_KIT_HOOK=session-context"
PII_HOOK_MARKER="AI_SESSION_KIT_HOOK=check-pii"
SKILLS=(session-start session-end kb-lookup kb-routing guided-development guided-debugging project-run-and-preview change-verification humanize-ko cognitive-rhythm-writing task-doc-writing weekly-summary monthly-summary)
LEGACY_STATE_SKILLS=(session-start session-end kb-lookup kb-routing humanize-ko cognitive-rhythm-writing task-doc-writing weekly-summary monthly-summary)
SKILL_ROOTS=("$CLAUDE_DIR/skills" "$USER_HOME/.agents/skills")
ts="$(date +%Y%m%d%H%M%S)"
result=0
skill_before_exists=()
skill_before_target=()
runtime_restore=""
runtime_was_present=0

fail() {
  printf '✗ %s\n' "$*" >&2
  return 1
}

shell_quote() {
  local escaped
  escaped="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$escaped"
}

backup_file() {
  local source="$1" backup

  if ! backup="$(mktemp "$source.bak-$ts.XXXXXX")"; then
    return 1
  fi
  if ! cp -p "$source" "$backup"; then
    rm -f -- "$backup"
    return 1
  fi
  printf '%s' "$backup"
}

case "$USER_HOME" in
  /*) ;;
  *) fail "AI_SESSION_KIT_USER_HOME은 절대경로여야 합니다"; exit 1 ;;
esac
case "$USER_HOME" in
  *$'\n'*|*$'\r'*|*$'\t'*|*'`'*) fail "AI_SESSION_KIT_USER_HOME에 제어문자나 backtick을 사용할 수 없습니다"; exit 1 ;;
esac

INSTALLED_VAULT=""
INSTALLED_SESSION_COMMAND=""
INSTALLED_PII_COMMAND=""
OWNED_SKILLS=()
EXPECTED_RUNTIME_MARKER_CONTENT=""
has_valid_state=0
if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
  if [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; then
    state_lines=()
    while IFS= read -r state_line || [ -n "$state_line" ]; do
      state_lines[${#state_lines[@]}]="$state_line"
    done < "$STATE_FILE"
    state_marker="${state_lines[0]:-}"
    INSTALLED_VAULT="${state_lines[1]:-}"
    INSTALLED_SESSION_COMMAND="${state_lines[2]:-}"
    INSTALLED_PII_COMMAND="${state_lines[3]:-}"
    if [ -n "$INSTALLED_VAULT" ]; then
      case "$INSTALLED_VAULT" in
        /*) has_valid_state=1 ;;
      esac
      case "$INSTALLED_VAULT" in
        *$'\n'*|*$'\r'*|*$'\t'*|*'`'*) has_valid_state=0 ;;
      esac
    fi
    if [ "$state_marker" = "$STATE_MARKER" ]; then
      if [ -z "$INSTALLED_SESSION_COMMAND" ] || [ -z "$INSTALLED_PII_COMMAND" ]; then
        has_valid_state=0
      fi
      state_skill_count="${state_lines[5]:-}"
      case "$state_skill_count" in
        ''|0*|*[!0-9]*) has_valid_state=0 ;;
        *)
          if [ "${state_lines[4]:-}" != "$STATE_SKILLS_MARKER" ] ||
            [ "${#state_lines[@]}" -ne $((state_skill_count + 6)) ]; then
            has_valid_state=0
          else
            for ((state_skill_index = 0; state_skill_index < state_skill_count; state_skill_index += 1)); do
              state_skill_name="${state_lines[$((state_skill_index + 6))]}"
              case "$state_skill_name" in
                ''|*[!a-z0-9-]*|-*|*-) has_valid_state=0 ;;
              esac
              for ((previous_skill_index = 0; previous_skill_index < state_skill_index; previous_skill_index += 1)); do
                if [ "$state_skill_name" = "${OWNED_SKILLS[$previous_skill_index]}" ]; then
                  has_valid_state=0
                fi
              done
              OWNED_SKILLS[${#OWNED_SKILLS[@]}]="$state_skill_name"
            done
          fi
          ;;
      esac
      EXPECTED_RUNTIME_MARKER_CONTENT="$RUNTIME_MARKER_CONTENT"
    elif [ "$state_marker" = "$PREVIOUS_STATE_MARKER" ] || [ "$state_marker" = "$LEGACY_STATE_MARKER" ]; then
      if [ "$state_marker" = "$PREVIOUS_STATE_MARKER" ] &&
        { [ -z "$INSTALLED_SESSION_COMMAND" ] || [ -z "$INSTALLED_PII_COMMAND" ]; }; then
        has_valid_state=0
      fi
      OWNED_SKILLS=("${LEGACY_STATE_SKILLS[@]}")
      EXPECTED_RUNTIME_MARKER_CONTENT="$LEGACY_RUNTIME_MARKER_CONTENT"
    else
      has_valid_state=0
      printf '✗ 이 제거 스크립트가 지원하지 않는 설치 상태 버전입니다. 설치에 사용한 버전의 uninstall.sh를 실행하세요: %s\n' "$STATE_FILE" >&2
    fi
  fi
  if [ "$has_valid_state" -ne 1 ]; then
    printf '✗ 설치 상태 파일을 확인할 수 없어 skill symlink를 제거하지 않습니다: %s\n' "$STATE_FILE" >&2
    result=1
  fi
else
  printf '✗ 설치 상태 파일이 없어 installer 소유 symlink를 식별할 수 없습니다. setup.sh를 다시 실행한 뒤 제거하세요.\n' >&2
  result=1
fi

validate_hook_config() {
  jq -e '
    def valid_event($name):
      (.hooks[$name] == null) or
      ((.hooks[$name] | type) == "array" and
       all(.hooks[$name][];
         (type == "object") and
         ((.hooks | type) == "array") and
         all(.hooks[];
           (type == "object") and
           ((.command == null) or ((.command | type) == "string")))));
    (type == "object") and
    (((.hooks // {}) | type) == "object") and
    valid_event("SessionStart") and
    valid_event("PreToolUse") and
    valid_event("PostToolUse")
  ' "$1" >/dev/null 2>&1
}

if [ "$has_valid_state" -eq 1 ]; then
  snapshot_index=0
  for root in "${SKILL_ROOTS[@]}"; do
    for name in "${OWNED_SKILLS[@]}"; do
      target="$root/$name"
      expected="$RUNTIME_DIR/skills/$name"
      legacy_expected="$INSTALLED_VAULT/_kit/skills/$name"
      if [ -L "$target" ]; then
        actual="$(readlink "$target")"
        if [ "$actual" != "$expected" ] && [ "$actual" != "$legacy_expected" ]; then
          printf '! unrelated symlink 보존: %s → %s\n' "$target" "$actual" >&2
          result=1
          skill_before_exists[$snapshot_index]=0
          skill_before_target[$snapshot_index]=""
        else
          skill_before_exists[$snapshot_index]=1
          skill_before_target[$snapshot_index]="$actual"
        fi
      elif [ -e "$target" ]; then
        printf '! installer 경로의 기존 파일/폴더 보존: %s\n' "$target" >&2
        result=1
        skill_before_exists[$snapshot_index]=0
        skill_before_target[$snapshot_index]=""
      else
        skill_before_exists[$snapshot_index]=0
        skill_before_target[$snapshot_index]=""
      fi
      snapshot_index=$((snapshot_index + 1))
    done
  done

  if [ -e "$RUNTIME_DIR" ] || [ -L "$RUNTIME_DIR" ]; then
    if [ -L "$RUNTIME_DIR" ] || [ ! -d "$RUNTIME_DIR" ] ||
      [ -L "$RUNTIME_DIR/$RUNTIME_MARKER" ] || [ ! -f "$RUNTIME_DIR/$RUNTIME_MARKER" ] ||
      [ "$(cat "$RUNTIME_DIR/$RUNTIME_MARKER")" != "$EXPECTED_RUNTIME_MARKER_CONTENT" ]; then
      printf '✗ installer 소유 runtime으로 확인되지 않아 제거하지 않습니다: %s\n' "$RUNTIME_DIR" >&2
      result=1
    else
      unexpected_runtime_node="$(find "$RUNTIME_DIR" ! -type f ! -type d -print -quit 2>/dev/null)" || {
        printf '✗ local runtime 구조를 안전하게 확인할 수 없어 제거하지 않습니다: %s\n' "$RUNTIME_DIR" >&2
        result=1
      }
      if [ -n "${unexpected_runtime_node:-}" ]; then
        printf '✗ local runtime에 regular file/directory가 아닌 항목이 있어 제거하지 않습니다: %s\n' "$unexpected_runtime_node" >&2
        result=1
      fi
    fi
  fi
fi

needs_jq=0
for file in "$CLAUDE_SETTINGS" "$CODEX_HOOKS"; do
  if [ -e "$file" ] || [ -L "$file" ]; then
    needs_jq=1
  fi
done
if [ "$has_valid_state" -eq 1 ] && [ "$needs_jq" -eq 1 ]; then
  if ! command -v jq >/dev/null 2>&1; then
    printf '✗ jq가 없어 JSON 설정에서 installer 소유 hook을 안전하게 제거할 수 없습니다\n' >&2
    result=1
  else
    for file in "$CLAUDE_SETTINGS" "$CODEX_HOOKS"; do
      if { [ -e "$file" ] || [ -L "$file" ]; } &&
        { [ ! -f "$file" ] || [ -L "$file" ] || ! validate_hook_config "$file"; }; then
        printf '✗ 유효한 JSON hook 설정이 아니어서 전체 제거를 시작하지 않았습니다: %s\n' "$file" >&2
        result=1
      fi
    done
  fi
fi

if [ "$result" -ne 0 ]; then
  printf '\n제거를 시작하지 않았습니다. 위 경고를 해결한 뒤 uninstall.sh를 다시 실행하세요. vault는 그대로 남아 있습니다.\n' >&2
  exit "$result"
fi

prepare_owned_hooks() {
  local file="$1" tmp_name="$2" changed_name="$3" tmp legacy_hook="" legacy_pii="" legacy_session_command="" legacy_pii_command="" filter
  local -a jq_args

  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf -v "$tmp_name" '%s' ''
    printf -v "$changed_name" '%s' 0
    return 0
  fi
  if [ ! -f "$file" ] || [ -L "$file" ] || ! validate_hook_config "$file"; then
    fail "유효한 JSON hook 설정이 아니어서 보존했습니다: $file"
    return 1
  fi
  if [ "$has_valid_state" -eq 1 ]; then
    legacy_hook="$INSTALLED_VAULT/_kit/hooks/session-context.sh"
    legacy_pii="$INSTALLED_VAULT/_kit/hooks/check-pii.sh"
    legacy_session_command="$SESSION_HOOK_MARKER bash $(shell_quote "$legacy_hook")"
    legacy_pii_command="$PII_HOOK_MARKER bash $(shell_quote "$legacy_pii")"
  fi
  filter='
    def without_owned($owned):
      map(
        . as $group |
        (($group.hooks // []) |
          map(. as $hook | select(($owned | index($hook.command // "")) == null))) as $remaining |
        if ($remaining | length) == (($group.hooks // []) | length) then $group
        elif ($remaining | length) > 0 then ($group | .hooks = $remaining)
        else empty
        end
      );
    ([$sessionCommand, $legacySessionCommand, $legacySessionBare] |
      map(select(length > 0)) | unique) as $ownedSession |
    ([$piiCommand, $legacyPiiCommand, $legacyPiiBare] |
      map(select(length > 0)) | unique) as $ownedPii |
    if .hooks.SessionStart == null then .
    else .hooks.SessionStart |= without_owned($ownedSession)
    end |
    if .hooks.PreToolUse == null then .
    else .hooks.PreToolUse |= without_owned($ownedPii)
    end |
    if .hooks.PostToolUse == null then .
    else .hooks.PostToolUse |= without_owned($ownedPii)
    end
  '
  jq_args=(
    --arg sessionCommand "$INSTALLED_SESSION_COMMAND"
    --arg piiCommand "$INSTALLED_PII_COMMAND"
    --arg legacySessionCommand "$legacy_session_command"
    --arg legacyPiiCommand "$legacy_pii_command"
    --arg legacySessionBare "$legacy_hook"
    --arg legacyPiiBare "$legacy_pii"
  )
  if ! tmp="$(mktemp "$(dirname "$file")/.hooks.XXXXXX")"; then
    fail "hook 설정 임시 파일을 만들 수 없습니다: $(dirname "$file")"
    return 1
  fi
  if ! jq "${jq_args[@]}" "$filter" "$file" > "$tmp"; then
    rm -f -- "$tmp"
    fail "hook 설정 정리에 실패해 원본을 보존했습니다: $file"
    return 1
  fi
  if cmp -s "$file" "$tmp"; then
    rm -f -- "$tmp"
    printf -v "$tmp_name" '%s' ''
    printf -v "$changed_name" '%s' 0
    return 0
  fi
  printf -v "$tmp_name" '%s' "$tmp"
  printf -v "$changed_name" '%s' 1
}

claude_tmp=""
codex_tmp=""
claude_changed=0
codex_changed=0
if ! prepare_owned_hooks "$CLAUDE_SETTINGS" claude_tmp claude_changed ||
  ! prepare_owned_hooks "$CODEX_HOOKS" codex_tmp codex_changed; then
  rm -f -- "$claude_tmp" "$codex_tmp"
  printf '\n제거를 시작하지 않았습니다. hook 설정을 확인한 뒤 uninstall.sh를 다시 실행하세요. vault는 그대로 남아 있습니다.\n' >&2
  exit 1
fi

claude_backup=""
codex_backup=""
if [ "$claude_changed" -eq 1 ] && ! claude_backup="$(backup_file "$CLAUDE_SETTINGS")"; then
  rm -f -- "$claude_tmp" "$codex_tmp"
  printf '✗ Claude hook backup을 만들 수 없어 제거를 시작하지 않았습니다.\n' >&2
  exit 1
fi
if [ "$codex_changed" -eq 1 ] && ! codex_backup="$(backup_file "$CODEX_HOOKS")"; then
  rm -f -- "$claude_tmp" "$codex_tmp"
  printf '✗ Codex hook backup을 만들 수 없어 제거를 시작하지 않았습니다.\n' >&2
  exit 1
fi

claude_committed=0
codex_committed=0
hook_commit_failed=0
if [ "$claude_changed" -eq 1 ]; then
  if mv "$claude_tmp" "$CLAUDE_SETTINGS"; then
    claude_tmp=""
    claude_committed=1
  else
    hook_commit_failed=1
  fi
fi
if [ "$hook_commit_failed" -eq 0 ] && [ "$codex_changed" -eq 1 ]; then
  if mv "$codex_tmp" "$CODEX_HOOKS"; then
    codex_tmp=""
    codex_committed=1
  else
    hook_commit_failed=1
  fi
fi
if [ "$hook_commit_failed" -ne 0 ]; then
  rollback_failed=0
  if [ "$claude_committed" -eq 1 ]; then
    cp -p "$claude_backup" "$CLAUDE_SETTINGS" 2>/dev/null || rollback_failed=1
  fi
  if [ "$codex_committed" -eq 1 ]; then
    cp -p "$codex_backup" "$CODEX_HOOKS" 2>/dev/null || rollback_failed=1
  fi
  rm -f -- "$claude_tmp" "$codex_tmp"
  if [ "$rollback_failed" -eq 0 ]; then
    printf '✗ hook 설정을 교체할 수 없어 기존 설정을 복원했습니다. 제거를 시작하지 않았습니다.\n' >&2
  else
    printf '✗ hook 설정 교체와 rollback 일부가 실패했습니다. backup 파일을 확인하세요.\n' >&2
  fi
  exit 1
fi

if [ "$claude_changed" -eq 1 ]; then
  printf '✓ installer 소유 hook 제거: %s (백업: %s)\n' "$CLAUDE_SETTINGS" "$claude_backup"
else
  printf '· installer 소유 hook 없음: %s\n' "$CLAUDE_SETTINGS"
fi
if [ "$codex_changed" -eq 1 ]; then
  printf '✓ installer 소유 hook 제거: %s (백업: %s)\n' "$CODEX_HOOKS" "$codex_backup"
else
  printf '· installer 소유 hook 없음: %s\n' "$CODEX_HOOKS"
fi

restore_wiring() {
  local index=0 root name target before restore_failed=0

  if [ "$claude_changed" -eq 1 ]; then
    cp -p "$claude_backup" "$CLAUDE_SETTINGS" 2>/dev/null || restore_failed=1
  fi
  if [ "$codex_changed" -eq 1 ]; then
    cp -p "$codex_backup" "$CODEX_HOOKS" 2>/dev/null || restore_failed=1
  fi
  for root in "${SKILL_ROOTS[@]}"; do
    for name in "${OWNED_SKILLS[@]}"; do
      if [ "${skill_before_exists[$index]:-0}" -eq 1 ]; then
        target="$root/$name"
        before="${skill_before_target[$index]}"
        if [ -L "$target" ]; then
          [ "$(readlink "$target")" = "$before" ] || restore_failed=1
        elif [ ! -e "$target" ]; then
          mkdir -p "$root" 2>/dev/null && ln -s "$before" "$target" 2>/dev/null || restore_failed=1
        else
          restore_failed=1
        fi
      fi
      index=$((index + 1))
    done
  done
  return "$restore_failed"
}

clear_runtime_delete_flags() {
  local target="$1"

  if command -v chflags >/dev/null 2>&1; then
    chflags -R -P nouchg,nouappnd,noschg,nosappnd "$target" 2>/dev/null
  fi
}

discard_runtime_restore() {
  if [ -z "$runtime_restore" ] || [ ! -d "$runtime_restore" ]; then
    runtime_restore=""
    return 0
  fi
  if ! clear_runtime_delete_flags "$runtime_restore" || ! rm -rf -- "$runtime_restore"; then
    return 1
  fi
  runtime_restore=""
}

restore_runtime_copy() {
  if [ "$runtime_was_present" -eq 0 ]; then
    return 0
  fi
  if [ -e "$RUNTIME_DIR" ] || [ -L "$RUNTIME_DIR" ] ||
    [ -z "$runtime_restore" ] || [ ! -d "$runtime_restore" ]; then
    return 1
  fi
  if ! mv "$runtime_restore" "$RUNTIME_DIR"; then
    return 1
  fi
  runtime_restore=""
  [ -f "$RUNTIME_DIR/$RUNTIME_MARKER" ] &&
    [ ! -L "$RUNTIME_DIR/$RUNTIME_MARKER" ] &&
    [ "$(cat "$RUNTIME_DIR/$RUNTIME_MARKER")" = "$EXPECTED_RUNTIME_MARKER_CONTENT" ]
}

if [ -d "$RUNTIME_DIR" ]; then
  runtime_was_present=1
  if ! runtime_restore="$(mktemp -d "$STATE_DIR/.runtime-restore.XXXXXX")"; then
    restore_wiring || true
    printf '✗ runtime rollback 공간을 만들 수 없어 제거를 시작하지 않았습니다.\n' >&2
    exit 1
  fi
  if ! rmdir "$runtime_restore" || ! cp -pR "$RUNTIME_DIR" "$runtime_restore" ||
    ! diff -qr "$RUNTIME_DIR" "$runtime_restore" >/dev/null 2>&1; then
    discard_runtime_restore || true
    restore_wiring || true
    printf '✗ runtime rollback 복사본을 검증할 수 없어 제거를 시작하지 않았습니다.\n' >&2
    exit 1
  fi
fi

removed=0
skill_remove_failed=0
snapshot_index=0
for root in "${SKILL_ROOTS[@]}"; do
  for name in "${OWNED_SKILLS[@]}"; do
    target="$root/$name"
    if [ "${skill_before_exists[$snapshot_index]:-0}" -eq 1 ]; then
      if rm -- "$target"; then
        removed=$((removed + 1))
      else
        skill_remove_failed=1
      fi
    fi
    snapshot_index=$((snapshot_index + 1))
  done
done
if [ "$skill_remove_failed" -ne 0 ]; then
  restore_wiring || true
  discard_runtime_restore || true
  printf '✗ skill symlink 제거에 실패해 기존 hook·skill 연결을 복원했습니다.\n' >&2
  exit 1
fi
printf '✓ installer 소유 skill symlink %s개 제거 (Claude + Codex)\n' "$removed"

runtime_hold=""
if [ -d "$RUNTIME_DIR" ]; then
  if ! runtime_hold="$(mktemp -d "$STATE_DIR/.runtime-uninstall.XXXXXX")"; then
    restore_wiring || true
    discard_runtime_restore || true
    printf '✗ runtime 제거 준비에 실패해 기존 hook·skill 연결을 복원했습니다.\n' >&2
    exit 1
  fi
  rmdir "$runtime_hold"
  if ! mv "$RUNTIME_DIR" "$runtime_hold"; then
    restore_wiring || true
    discard_runtime_restore || true
    printf '✗ runtime을 분리할 수 없어 기존 hook·skill 연결을 복원했습니다.\n' >&2
    exit 1
  fi
fi

if [ -n "$runtime_hold" ]; then
  if ! clear_runtime_delete_flags "$runtime_hold" || ! rm -rf -- "$runtime_hold"; then
    rollback_failed=0
    restore_runtime_copy || rollback_failed=1
    restore_wiring || rollback_failed=1
    if [ "$rollback_failed" -eq 0 ]; then
      printf '✗ runtime 제거에 실패해 기존 runtime·hook·skill 연결을 복원했습니다. 남은 임시 폴더: %s\n' "$runtime_hold" >&2
    else
      printf '✗ runtime 제거와 rollback 일부가 실패했습니다. 복구 복사본과 install-state를 보존했습니다.\n' >&2
    fi
    exit 1
  fi
  runtime_hold=""
fi

if ! rm -- "$STATE_FILE"; then
  rollback_failed=0
  restore_runtime_copy || rollback_failed=1
  restore_wiring || rollback_failed=1
  if [ "$rollback_failed" -eq 0 ]; then
    printf '✗ install-state를 제거할 수 없어 기존 runtime·hook·skill 연결을 복원했습니다.\n' >&2
  else
    printf '✗ install-state 제거와 rollback 일부가 실패했습니다. backup 파일을 확인하세요.\n' >&2
  fi
  exit 1
fi

if ! discard_runtime_restore; then
  printf '✗ 제거는 완료됐지만 runtime rollback 복사본을 지우지 못했습니다: %s\n' "$runtime_restore" >&2
  exit 1
fi
printf '✓ installer 소유 local runtime 제거: %s\n' "$RUNTIME_DIR"

printf '\n제거 완료. vault(지식 폴더)는 그대로 남아 있습니다.\n'
exit 0
