#!/usr/bin/env bash
# setup.sh — AI 세션 지식 킷 설치 (멱등: 여러 번 실행해도 안전)

set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_HOME="${AI_SESSION_KIT_USER_HOME:-$HOME}"
VAULT="${1:-$USER_HOME/KnowledgeBase}"
CLAUDE_DIR="$USER_HOME/.claude"
CODEX_DIR="$USER_HOME/.codex"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
CODEX_HOOKS="$CODEX_DIR/hooks.json"
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
STATELESS_LEGACY_SENTINEL_SKILLS=(session-start session-end kb-lookup kb-routing)
STATELESS_LEGACY_OPTIONAL_SKILLS=(humanize-ko cognitive-rhythm-writing task-doc-writing weekly-summary monthly-summary)
SKILL_ROOTS=("$CLAUDE_DIR/skills" "$USER_HOME/.agents/skills")
ts="$(date +%Y%m%d%H%M%S)"
stage=""
runtime_old=""
runtime_swapped=0
transaction_committed=0
claude_snapshot=""
codex_snapshot=""
claude_had_config=0
codex_had_config=0
skill_snapshot_ready=0
skill_before_exists=()
skill_before_target=()

cleanup() {
  local status=$? index=0 root name target before rollback_failed=0

  if [ "$runtime_swapped" -eq 1 ] && [ "$transaction_committed" -eq 0 ]; then
    if [ "$claude_had_config" -eq 1 ]; then
      cp -p "$claude_snapshot" "$CLAUDE_SETTINGS" 2>/dev/null || rollback_failed=1
    elif [ -f "$CLAUDE_SETTINGS" ] && [ ! -L "$CLAUDE_SETTINGS" ]; then
      rm -f -- "$CLAUDE_SETTINGS" 2>/dev/null || rollback_failed=1
    fi
    if [ "$codex_had_config" -eq 1 ]; then
      cp -p "$codex_snapshot" "$CODEX_HOOKS" 2>/dev/null || rollback_failed=1
    elif [ -f "$CODEX_HOOKS" ] && [ ! -L "$CODEX_HOOKS" ]; then
      rm -f -- "$CODEX_HOOKS" 2>/dev/null || rollback_failed=1
    fi

    if [ "$skill_snapshot_ready" -eq 1 ]; then
      for root in "${SKILL_ROOTS[@]}"; do
        for name in "${SKILLS[@]}"; do
          target="$root/$name"
          if [ "${skill_before_exists[$index]:-0}" -eq 1 ]; then
            before="${skill_before_target[$index]}"
            if [ -L "$target" ]; then
              if [ "$(readlink "$target")" != "$before" ]; then
                rm -- "$target" 2>/dev/null && ln -s "$before" "$target" 2>/dev/null || rollback_failed=1
              fi
            elif [ ! -e "$target" ]; then
              ln -s "$before" "$target" 2>/dev/null || rollback_failed=1
            else
              rollback_failed=1
            fi
          elif [ -L "$target" ] && [ "$(readlink "$target")" = "$RUNTIME_DIR/skills/$name" ]; then
            rm -- "$target" 2>/dev/null || rollback_failed=1
          fi
          index=$((index + 1))
        done
      done
    fi

    if [ -e "$RUNTIME_DIR" ] || [ -L "$RUNTIME_DIR" ]; then
      rm -rf -- "$RUNTIME_DIR" 2>/dev/null || rollback_failed=1
    fi
    if [ -n "$runtime_old" ] && [ -d "$runtime_old" ]; then
      mv "$runtime_old" "$RUNTIME_DIR" 2>/dev/null || rollback_failed=1
      runtime_old=""
    fi
    if [ "$rollback_failed" -eq 0 ]; then
      printf '! 설치 실패로 기존 runtime·hook·skill 연결을 복원했습니다.\n' >&2
    else
      printf '✗ 설치 rollback 일부가 실패했습니다. install-state를 보존했으니 setup.sh를 다시 실행하세요.\n' >&2
    fi
  fi

  if [ -n "$stage" ] && [ -d "$stage" ]; then
    case "$stage" in
      "$STATE_DIR"/.runtime-stage.*) rm -rf -- "$stage" ;;
    esac
  fi
  if [ -n "$runtime_old" ] && [ -d "$runtime_old" ]; then
    case "$runtime_old" in
      "$STATE_DIR"/.runtime-old.*) rm -rf -- "$runtime_old" ;;
    esac
  fi
  for snapshot in "$claude_snapshot" "$codex_snapshot"; do
    if [ -n "$snapshot" ] && [ -f "$snapshot" ]; then
      case "$snapshot" in
        "$STATE_DIR"/.hook-snapshot.*) rm -f -- "$snapshot" ;;
      esac
    fi
  done
  return "$status"
}
trap cleanup EXIT

fail() {
  printf '✗ %s\n' "$*" >&2
  return 1
}

case "$USER_HOME" in
  /*) ;;
  *) fail "AI_SESSION_KIT_USER_HOME은 절대경로여야 합니다"; exit 1 ;;
esac
case "$USER_HOME" in
  *$'\n'*|*$'\r'*|*$'\t'*|*'`'*) fail "AI_SESSION_KIT_USER_HOME에 제어문자나 backtick을 사용할 수 없습니다"; exit 1 ;;
esac
case "$VAULT" in
  /*) ;;
  *) fail "vault 경로는 절대경로로 지정하세요 (예: bash setup.sh \"\$HOME/my vault\")"; exit 1 ;;
esac
case "$VAULT" in
  *$'\n'*|*$'\r'*|*$'\t'*|*'`'*) fail "vault 경로에 제어문자나 backtick을 사용할 수 없습니다"; exit 1 ;;
  /) fail "파일시스템 루트는 vault로 사용할 수 없습니다"; exit 1 ;;
esac

if [ -L "$STATE_DIR" ] || { [ -e "$STATE_DIR" ] && [ ! -d "$STATE_DIR" ]; }; then
  fail "로컬 설치 상태 경로가 안전한 폴더가 아닙니다: $STATE_DIR"
  exit 1
fi
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

OLD_VAULT=""
PREVIOUS_SESSION_COMMAND=""
PREVIOUS_PII_COMMAND=""
if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
  if [ ! -f "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
    fail "설치 상태 파일이 손상되었습니다: $STATE_FILE"
    exit 1
  fi
  state_lines=()
  while IFS= read -r state_line || [ -n "$state_line" ]; do
    state_lines[${#state_lines[@]}]="$state_line"
  done < "$STATE_FILE"
  state_marker="${state_lines[0]:-}"
  OLD_VAULT="${state_lines[1]:-}"
  PREVIOUS_SESSION_COMMAND="${state_lines[2]:-}"
  PREVIOUS_PII_COMMAND="${state_lines[3]:-}"
  if { [ "$state_marker" != "$STATE_MARKER" ] &&
    [ "$state_marker" != "$PREVIOUS_STATE_MARKER" ] &&
    [ "$state_marker" != "$LEGACY_STATE_MARKER" ]; } || [ -z "$OLD_VAULT" ]; then
    fail "설치 상태 파일 형식을 확인할 수 없습니다: $STATE_FILE"
    exit 1
  fi
  if { [ "$state_marker" = "$STATE_MARKER" ] || [ "$state_marker" = "$PREVIOUS_STATE_MARKER" ]; } &&
    { [ -z "$PREVIOUS_SESSION_COMMAND" ] || [ -z "$PREVIOUS_PII_COMMAND" ]; }; then
    fail "설치 상태에 exact hook command가 없습니다: $STATE_FILE"
    exit 1
  fi
  if [ "$state_marker" = "$STATE_MARKER" ]; then
    state_skill_count="${state_lines[5]:-}"
    case "$state_skill_count" in
      ''|0*|*[!0-9]*) fail "설치 상태의 skill manifest 개수가 유효하지 않습니다: $STATE_FILE"; exit 1 ;;
    esac
    if [ "${state_lines[4]:-}" != "$STATE_SKILLS_MARKER" ] ||
      [ "${#state_lines[@]}" -ne $((state_skill_count + 6)) ]; then
      fail "설치 상태의 skill manifest를 확인할 수 없습니다: $STATE_FILE"
      exit 1
    fi
    for ((state_skill_index = 0; state_skill_index < state_skill_count; state_skill_index += 1)); do
      state_skill_name="${state_lines[$((state_skill_index + 6))]}"
      case "$state_skill_name" in
        ''|*[!a-z0-9-]*|-*|*-) fail "설치 상태의 skill 이름이 유효하지 않습니다: $STATE_FILE"; exit 1 ;;
      esac
      for ((previous_skill_index = 0; previous_skill_index < state_skill_index; previous_skill_index += 1)); do
        if [ "$state_skill_name" = "${state_lines[$((previous_skill_index + 6))]}" ]; then
          fail "설치 상태의 skill manifest에 중복 항목이 있습니다: $STATE_FILE"
          exit 1
        fi
      done
    done
    if [ "$state_skill_count" -ne "${#SKILLS[@]}" ]; then
      fail "기존 v3 skill manifest가 현재 설치 목록과 달라 자동 업그레이드를 중단합니다. 설치에 사용한 버전의 uninstaller로 먼저 제거하세요: $STATE_FILE"
      exit 1
    fi
    for ((state_skill_index = 0; state_skill_index < state_skill_count; state_skill_index += 1)); do
      if [ "${state_lines[$((state_skill_index + 6))]}" != "${SKILLS[$state_skill_index]}" ]; then
        fail "기존 v3 skill manifest가 현재 설치 목록과 달라 자동 업그레이드를 중단합니다. 설치에 사용한 버전의 uninstaller로 먼저 제거하세요: $STATE_FILE"
        exit 1
      fi
    done
  fi
  case "$OLD_VAULT" in
    /*) ;;
    *) fail "설치 상태의 vault 경로가 유효하지 않습니다: $STATE_FILE"; exit 1 ;;
  esac
fi

discover_legacy_vault() {
  local name target actual suffix prefix candidate=""

  for name in "${STATELESS_LEGACY_SENTINEL_SKILLS[@]}"; do
    target="$CLAUDE_DIR/skills/$name"
    [ -L "$target" ] || return 1
    actual="$(readlink "$target")"
    suffix="/_kit/skills/$name"
    case "$actual" in
      /*"$suffix") prefix="${actual%"$suffix"}" ;;
      *) return 1 ;;
    esac
    [ -n "$prefix" ] || return 1
    if [ -z "$candidate" ]; then
      candidate="$prefix"
    elif [ "$candidate" != "$prefix" ]; then
      return 1
    fi
  done

  for name in "${STATELESS_LEGACY_OPTIONAL_SKILLS[@]}"; do
    target="$CLAUDE_DIR/skills/$name"
    if [ -L "$target" ]; then
      actual="$(readlink "$target")"
      [ "$actual" = "$candidate/_kit/skills/$name" ] || return 1
    elif [ -e "$target" ]; then
      return 1
    fi
  done

  if [ -f "$candidate/_kit/hooks/session-context.sh" ] ||
    [ -f "$VAULT/_kit/hooks/session-context.sh" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

if [ -z "$OLD_VAULT" ]; then
  if legacy_vault="$(discover_legacy_vault)"; then
    OLD_VAULT="$legacy_vault"
    printf '· state 도입 전 legacy install 감지: %s\n' "$OLD_VAULT"
  fi
fi

validate_vault_template() {
  local rel dst

  if [ -e "$VAULT" ] || [ -L "$VAULT" ]; then
    if [ ! -d "$VAULT" ]; then
      fail "vault 경로가 폴더가 아닙니다: $VAULT"
      return 1
    fi
  fi
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    dst="$VAULT/$rel"
    if [ -L "$dst" ]; then
      fail "필수 vault 폴더가 symlink라서 중단합니다: $dst"
      return 1
    fi
    if [ -e "$dst" ] && [ ! -d "$dst" ]; then
      fail "필수 vault 폴더 자리에 다른 파일이 있습니다: $dst"
      return 1
    fi
  done < <(cd "$KIT/vault-template" && find . -type d -print0)
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    dst="$VAULT/$rel"
    if [ -L "$dst" ]; then
      fail "필수 vault 파일이 symlink라서 중단합니다: $dst"
      return 1
    fi
    if [ -e "$dst" ] && [ ! -f "$dst" ]; then
      fail "필수 vault 파일 자리에 다른 항목이 있습니다: $dst"
      return 1
    fi
  done < <(cd "$KIT/vault-template" && find . -type f -print0)
}

backup_file() {
  local source="$1" backup

  backup="$(mktemp "$source.bak-$ts.XXXXXX")"
  cp -p "$source" "$backup"
  printf '%s' "$backup"
}

migrate_entrypoints() {
  local name destination legacy current backup

  legacy="$KIT/legacy-vault-entrypoint-v0.md"
  [ -f "$legacy" ] || return 0
  for name in CLAUDE.md AGENTS.md; do
    destination="$VAULT/$name"
    current="$KIT/vault-template/$name"
    [ -f "$destination" ] || continue
    if cmp -s "$destination" "$legacy"; then
      backup="$(backup_file "$destination")"
      cp "$current" "$destination"
      printf '✓ 구버전 기본 %s를 갱신했습니다 (백업: %s)\n' "$name" "$backup"
    elif ! cmp -s "$destination" "$current" && grep -Fq 'vault 전체 grep' "$destination"; then
      printf '! 사용자 수정 %s에 구버전 전체 검색 규칙이 남아 있습니다. 90.private와 _kit 제외 여부를 직접 확인하세요: %s\n' "$name" "$destination" >&2
    fi
  done
}

merge_vault_template() {
  local rel src dst merged=0

  mkdir -p "$VAULT"
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    mkdir -p "$VAULT/$rel"
  done < <(cd "$KIT/vault-template" && find . -type d -print0)
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    src="$KIT/vault-template/$rel"
    dst="$VAULT/$rel"
    if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
      cp "$src" "$dst"
      merged=$((merged + 1))
    fi
  done < <(cd "$KIT/vault-template" && find . -type f -print0)
  printf '✓ vault 기본 구조 확인 (누락 파일 %s개 추가, 기존 내용 보존)\n' "$merged"
}

validate_vault_template
migrate_entrypoints
merge_vault_template
VAULT="$(cd "$VAULT" && pwd -P)"
validate_vault_template
printf '지식 vault: %s\n' "$VAULT"

shell_quote() {
  local escaped
  escaped="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$escaped"
}

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

snapshot_hook_config() {
  local file="$1" snapshot_name="$2" had_name="$3" snapshot

  if [ -f "$file" ]; then
    snapshot="$(mktemp "$STATE_DIR/.hook-snapshot.XXXXXX")"
    cp -p "$file" "$snapshot"
    printf -v "$snapshot_name" '%s' "$snapshot"
    printf -v "$had_name" '%s' 1
  else
    printf -v "$snapshot_name" '%s' ''
    printf -v "$had_name" '%s' 0
  fi
}

assert_runtime_replaceable() {
  if [ ! -e "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR" ]; then
    return 0
  fi
  if [ -L "$RUNTIME_DIR" ] || [ ! -d "$RUNTIME_DIR" ]; then
    fail "로컬 runtime이 안전한 폴더가 아닙니다: $RUNTIME_DIR"
    return 1
  fi
  if [ -L "$RUNTIME_DIR/$RUNTIME_MARKER" ] || [ ! -f "$RUNTIME_DIR/$RUNTIME_MARKER" ]; then
    fail "installer 소유 marker가 없는 runtime을 보존했습니다: $RUNTIME_DIR"
    return 1
  fi
  runtime_marker_content="$(cat "$RUNTIME_DIR/$RUNTIME_MARKER")"
  if [ "$runtime_marker_content" != "$RUNTIME_MARKER_CONTENT" ] &&
    [ "$runtime_marker_content" != "$LEGACY_RUNTIME_MARKER_CONTENT" ]; then
    fail "installer 소유 marker가 없는 runtime을 보존했습니다: $RUNTIME_DIR"
    return 1
  fi
}

preflight_skill_links() {
  local root name target actual current_expected old_expected
  local has_conflict=0

  for root in "${SKILL_ROOTS[@]}"; do
    for name in "${SKILLS[@]}"; do
      target="$root/$name"
      current_expected="$RUNTIME_DIR/skills/$name"
      old_expected=""
      if [ -n "$OLD_VAULT" ]; then
        old_expected="$OLD_VAULT/_kit/skills/$name"
      fi
      if [ -L "$target" ]; then
        actual="$(readlink "$target")"
        if [ "$actual" != "$current_expected" ] && { [ -z "$old_expected" ] || [ "$actual" != "$old_expected" ]; }; then
          printf '✗ unrelated symlink 보존: %s → %s\n' "$target" "$actual" >&2
          has_conflict=1
        fi
      elif [ -e "$target" ]; then
        printf '✗ 기존 파일/폴더 보존: %s\n' "$target" >&2
        has_conflict=1
      fi
    done
  done
  return "$has_conflict"
}

if ! preflight_skill_links; then
  fail "기존 skill 항목과 충돌하여 symlink 설치를 중단했습니다"
  exit 1
fi

assert_runtime_replaceable
if ! command -v jq >/dev/null 2>&1; then
  printf '✗ jq가 없어 JSON hook 설정과 pre-write PII guard를 안전하게 활성화할 수 없습니다\n' >&2
  printf '  jq를 설치한 뒤 같은 setup.sh 명령을 다시 실행하세요. 기존 runtime·hook·skill 연결은 변경하지 않았습니다.\n' >&2
  exit 1
fi
for hook_file in "$CLAUDE_SETTINGS" "$CODEX_HOOKS"; do
  if { [ -e "$hook_file" ] || [ -L "$hook_file" ]; } &&
    { [ ! -f "$hook_file" ] || [ -L "$hook_file" ] || ! validate_hook_config "$hook_file"; }; then
    printf '✗ 유효한 JSON hook 설정이 아니어서 보존했습니다: %s\n' "$hook_file" >&2
    printf '  JSON을 고친 뒤 setup.sh를 다시 실행하세요. 기존 runtime·hook·skill 연결은 변경하지 않았습니다.\n' >&2
    exit 1
  fi
done

snapshot_hook_config "$CLAUDE_SETTINGS" claude_snapshot claude_had_config
snapshot_hook_config "$CODEX_HOOKS" codex_snapshot codex_had_config
snapshot_index=0
for root in "${SKILL_ROOTS[@]}"; do
  for name in "${SKILLS[@]}"; do
    target="$root/$name"
    if [ -L "$target" ]; then
      skill_before_exists[$snapshot_index]=1
      skill_before_target[$snapshot_index]="$(readlink "$target")"
    else
      skill_before_exists[$snapshot_index]=0
      skill_before_target[$snapshot_index]=""
    fi
    snapshot_index=$((snapshot_index + 1))
  done
done
skill_snapshot_ready=1

stage="$(mktemp -d "$STATE_DIR/.runtime-stage.XXXXXX")"
mkdir -p "$stage/hooks" "$stage/scripts" "$stage/skills"
cp "$KIT/hooks/session-context.sh" "$stage/hooks/session-context.sh"
cp "$KIT/hooks/check-pii.sh" "$stage/hooks/check-pii.sh"
cp "$KIT/scripts/kb_lint.py" "$stage/scripts/kb_lint.py"
chmod 700 "$stage/hooks/session-context.sh" "$stage/hooks/check-pii.sh"

escaped_vault="$(printf '%s' "$VAULT" | sed 's/[\\&|]/\\&/g')"
lint_command="AI_SESSION_KIT_STATE_DIR=$(shell_quote "$STATE_DIR") python3 $(shell_quote "$RUNTIME_DIR/scripts/kb_lint.py") $(shell_quote "$VAULT") --check"
escaped_lint_command="$(printf '%s' "$lint_command" | sed 's/[\\&|]/\\&/g')"
for name in "${SKILLS[@]}"; do
  mkdir -p "$stage/skills/$name"
  cp -R "$KIT/skills/$name/." "$stage/skills/$name/"
  rewrite_tmp="$(mktemp "$stage/.rewrite.XXXXXX")"
  sed \
    -e "s|~/KnowledgeBase|$escaped_vault|g" \
    -e "s|__KB_LINT_COMMAND__|$escaped_lint_command|g" \
    "$stage/skills/$name/SKILL.md" > "$rewrite_tmp"
  mv "$rewrite_tmp" "$stage/skills/$name/SKILL.md"
done
printf '%s\n' "$RUNTIME_MARKER_CONTENT" > "$stage/$RUNTIME_MARKER"

if [ -d "$RUNTIME_DIR" ]; then
  runtime_old="$(mktemp -d "$STATE_DIR/.runtime-old.XXXXXX")"
  rmdir "$runtime_old"
  mv "$RUNTIME_DIR" "$runtime_old"
fi
if mv "$stage" "$RUNTIME_DIR"; then
  stage=""
  runtime_swapped=1
else
  if [ -n "$runtime_old" ] && [ ! -e "$RUNTIME_DIR" ]; then
    mv "$runtime_old" "$RUNTIME_DIR"
    runtime_old=""
  fi
  fail "로컬 runtime 교체에 실패했습니다"
  exit 1
fi
printf '✓ 스킬 %s개 + 훅 2개 + lint 스크립트 → %s\n' "${#SKILLS[@]}" "$RUNTIME_DIR"

HOOK_CMD="$RUNTIME_DIR/hooks/session-context.sh"
PII_CMD="$RUNTIME_DIR/hooks/check-pii.sh"
SESSION_HOOK_COMMAND="$SESSION_HOOK_MARKER KB_VAULT=$(shell_quote "$VAULT") AI_SESSION_KIT_STATE_DIR=$(shell_quote "$STATE_DIR") bash $(shell_quote "$HOOK_CMD")"
PII_HOOK_COMMAND="$PII_HOOK_MARKER KB_VAULT=$(shell_quote "$VAULT") AI_SESSION_KIT_STATE_DIR=$(shell_quote "$STATE_DIR") bash $(shell_quote "$PII_CMD")"
OLD_HOOK_CMD=""
OLD_PII_CMD=""
LEGACY_SESSION_COMMAND=""
LEGACY_PII_COMMAND=""
if [ -n "$OLD_VAULT" ]; then
  OLD_HOOK_CMD="$OLD_VAULT/_kit/hooks/session-context.sh"
  OLD_PII_CMD="$OLD_VAULT/_kit/hooks/check-pii.sh"
  LEGACY_SESSION_COMMAND="$SESSION_HOOK_MARKER bash $(shell_quote "$OLD_HOOK_CMD")"
  LEGACY_PII_COMMAND="$PII_HOOK_MARKER bash $(shell_quote "$OLD_PII_CMD")"
fi

configure_hooks() {
  local file="$1" session_matcher="$2" pii_matcher="$3" tmp input_mode
  local filter
  local -a jq_args

  if ! mkdir -p "$(dirname "$file")"; then
    fail "hook 설정 폴더를 준비할 수 없습니다: $(dirname "$file")"
    return 1
  fi
  if [ -e "$file" ] || [ -L "$file" ]; then
    if [ ! -f "$file" ] || [ -L "$file" ] || ! validate_hook_config "$file"; then
      fail "유효한 JSON hook 설정이 아니어서 보존했습니다: $file"
      return 1
    fi
    input_mode=file
  else
    input_mode=null
  fi

  if ! tmp="$(mktemp "$(dirname "$file")/.hooks.XXXXXX")"; then
    fail "hook 설정 임시 파일을 만들 수 없습니다: $(dirname "$file")"
    return 1
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
    . = (. // {}) |
    .hooks = (.hooks // {}) |
    ([$sessionCommand, $previousSession, $legacySession, $legacySessionBare] |
      map(select(length > 0)) | unique) as $ownedSession |
    ([$piiCommand, $previousPii, $legacyPii, $legacyPiiBare] |
      map(select(length > 0)) | unique) as $ownedPii |
    .hooks.SessionStart =
      (((.hooks.SessionStart // []) | without_owned($ownedSession)) + [{
        matcher: $sessionMatcher,
        hooks: [{type: "command", command: $sessionCommand, timeout: 10, statusMessage: "지식베이스 컨텍스트 로딩..."}]
      }]) |
    .hooks.PreToolUse =
      (((.hooks.PreToolUse // []) | without_owned($ownedPii)) + [{
        matcher: $piiMatcher,
        hooks: [{type: "command", command: $piiCommand, timeout: 10}]
      }]) |
    if .hooks.PostToolUse == null then .
    else .hooks.PostToolUse |= without_owned($ownedPii)
    end
  '
  jq_args=(
    --arg sessionCommand "$SESSION_HOOK_COMMAND"
    --arg piiCommand "$PII_HOOK_COMMAND"
    --arg previousSession "$PREVIOUS_SESSION_COMMAND"
    --arg previousPii "$PREVIOUS_PII_COMMAND"
    --arg legacySession "$LEGACY_SESSION_COMMAND"
    --arg legacyPii "$LEGACY_PII_COMMAND"
    --arg legacySessionBare "$OLD_HOOK_CMD"
    --arg legacyPiiBare "$OLD_PII_CMD"
    --arg sessionMatcher "$session_matcher"
    --arg piiMatcher "$pii_matcher"
  )
  if [ "$input_mode" = file ]; then
    if ! jq "${jq_args[@]}" "$filter" "$file" > "$tmp"; then
      rm "$tmp"
      fail "hook 설정 병합에 실패해 원본을 보존했습니다: $file"
      return 1
    fi
  else
    if ! jq -n "${jq_args[@]}" "$filter" > "$tmp"; then
      rm "$tmp"
      fail "hook 설정 생성에 실패했습니다: $file"
      return 1
    fi
  fi

  if [ -f "$file" ] && cmp -s "$file" "$tmp"; then
    rm -f -- "$tmp"
  else
    if [ -f "$file" ]; then
      if ! backup_file "$file" >/dev/null; then
        rm -f -- "$tmp"
        fail "hook 설정 backup을 만들 수 없어 원본을 보존했습니다: $file"
        return 1
      fi
    elif ! chmod 600 "$tmp"; then
      rm -f -- "$tmp"
      fail "새 hook 설정 권한을 지정할 수 없습니다: $file"
      return 1
    fi
    if ! mv "$tmp" "$file"; then
      rm -f -- "$tmp"
      fail "hook 설정을 교체할 수 없어 원본을 보존했습니다: $file"
      return 1
    fi
  fi
}

verify_hook_config() {
  local file="$1"
  jq -e --arg sessionCommand "$SESSION_HOOK_COMMAND" --arg piiCommand "$PII_HOOK_COMMAND" '
    ([.hooks.SessionStart[]?.hooks[]?.command? | select(. == $sessionCommand)] | length) == 1 and
    ([.hooks.PreToolUse[]?.hooks[]?.command? | select(. == $piiCommand)] | length) == 1 and
    ([.hooks.PostToolUse[]?.hooks[]?.command? | select(. == $piiCommand)] | length) == 0
  ' "$file" >/dev/null 2>&1
}

result=0
if configure_hooks "$CLAUDE_SETTINGS" 'startup|resume|clear|compact' 'Write|Edit'; then
  if verify_hook_config "$CLAUDE_SETTINGS"; then
    printf '✓ Claude SessionStart + PreToolUse hook 등록·검증 완료\n'
  else
    fail "Claude hook 검증 실패: $CLAUDE_SETTINGS"
    result=1
  fi
else
  result=1
fi
if [ "$result" -eq 0 ] && configure_hooks "$CODEX_HOOKS" 'startup|resume|clear|compact' 'apply_patch|Edit|Write'; then
  if verify_hook_config "$CODEX_HOOKS"; then
    printf '✓ Codex SessionStart + PreToolUse hook 등록·검증 완료\n'
  else
    fail "Codex hook 검증 실패: $CODEX_HOOKS"
    result=1
  fi
elif [ "$result" -eq 0 ]; then
  result=1
fi

if [ "$result" -ne 0 ]; then
  printf '! hook 설정이 완료되지 않아 skill symlink와 install-state는 변경하지 않았습니다. 문제를 해결한 뒤 setup.sh를 다시 실행하세요.\n' >&2
  exit "$result"
fi

for root in "${SKILL_ROOTS[@]}"; do
  mkdir -p "$root"
  for name in "${SKILLS[@]}"; do
    target="$root/$name"
    expected="$RUNTIME_DIR/skills/$name"
    if [ -L "$target" ] && [ "$(readlink "$target")" != "$expected" ]; then
      rm "$target"
    fi
    if [ ! -L "$target" ]; then
      ln -s "$expected" "$target"
    fi
  done
done

for root in "${SKILL_ROOTS[@]}"; do
  for name in "${SKILLS[@]}"; do
    target="$root/$name"
    expected="$RUNTIME_DIR/skills/$name"
    if [ ! -L "$target" ] || [ "$(readlink "$target")" != "$expected" ] || [ ! -e "$target" ]; then
      fail "skill symlink 검증 실패: $target"
      exit 1
    fi
  done
done
printf '✓ Claude + Codex skill symlink 설치·검증 완료\n'

state_tmp="$(mktemp "$STATE_DIR/.install-state.XXXXXX")"
{
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$STATE_MARKER" "$VAULT" "$SESSION_HOOK_COMMAND" "$PII_HOOK_COMMAND" \
    "$STATE_SKILLS_MARKER" "${#SKILLS[@]}"
  printf '%s\n' "${SKILLS[@]}"
} > "$state_tmp"
chmod 600 "$state_tmp"
mv "$state_tmp" "$STATE_FILE"
transaction_committed=1

out="$(KB_VAULT="$VAULT" AI_SESSION_KIT_STATE_DIR="$STATE_DIR" "$HOOK_CMD" 2>/dev/null || true)"
if [ -n "$out" ]; then
  printf '✓ SessionStart hook 스모크 테스트 통과\n'
else
  fail "SessionStart hook이 아무것도 출력하지 않았습니다: $HOOK_CMD"
  result=1
fi

if command -v python3 >/dev/null 2>&1; then
  lint_output=""
  if lint_output="$(AI_SESSION_KIT_STATE_DIR="$STATE_DIR" python3 "$RUNTIME_DIR/scripts/kb_lint.py" "$VAULT" 2>/dev/null)"; then
    lint_summary="$(printf '%s\n' "$lint_output" | grep -E '^kb-lint [0-9]{4}-[0-9]{2}-[0-9]{2}: ERR [0-9]+' | tail -1)"
    if [ -z "$lint_summary" ]; then
      printf '! 설치는 완료됐지만 lint 결과를 확인하지 못했습니다. python3를 확인한 뒤 session-end skill에서 다시 실행하세요.\n'
    elif printf '%s\n' "$lint_summary" | grep -Eq ': ERR 0( |$)'; then
      printf '✓ lint 스모크 테스트 통과 (vault 위생 정상)\n'
    else
      lint_count="$(printf '%s\n' "$lint_summary" | sed -n 's/.*: ERR \([0-9][0-9]*\).*/\1/p')"
      printf '! 설치는 완료됐지만 vault 정리 %s건이 남아 있습니다. 세션 종료 시 session-end skill이 lint 상세를 확인하고 정리합니다.\n' "${lint_count:-여러}"
    fi
  else
    printf '! 설치는 완료됐지만 lint 검증을 실행하지 못했습니다. python3를 확인한 뒤 session-end skill에서 다시 실행하세요.\n'
  fi
else
  printf '· python3 없음 — lint 검증 생략 (세션 기록·복원은 정상 동작)\n'
fi

cat <<'DONE'

설치 후 확인:
- Claude: 새 세션에서 SessionStart hook이 진행 중 작업 개수만 안내합니다.
- Codex: /hooks에서 새 command hook 정의를 검토하고 trust해야 실행됩니다. vault를 옮겨 재설치하면 command가 바뀌므로 다시 trust하세요.
- 세션 기록은 자동 저장되지 않습니다. 직접 "세션 종료해줘"라고 말하거나, AI가 안전하게 끊을 수 있는 지점에서 정리를 제안하면 동의하세요.
- 이전 설치의 vault/_kit은 자동 삭제하지 않지만 더 이상 실행하거나 global skill로 연결하지 않습니다.
DONE
exit "$result"
