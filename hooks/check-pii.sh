#!/usr/bin/env bash
# PreToolUse hook: vault-bound Write/Edit/apply_patch의 결과를 best-effort 민감정보 검사한다.

set -u

MAX_SCAN_BYTES=5242880
CAPTURE_SENTINEL='__AI_SESSION_KIT_CAPTURE_END_8f4c1d2b__'

parser_failure() {
  printf 'PII guard could not parse the write request, so the write was blocked. jq is required.\n' >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || parser_failure

STATE_DIR="${AI_SESSION_KIT_STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
VAULT_RAW="${KB_VAULT:-}"
if [ -z "$VAULT_RAW" ] && [ -f "$STATE_DIR/install-state" ] && [ ! -L "$STATE_DIR/install-state" ]; then
  VAULT_RAW="$(sed -n '2p' "$STATE_DIR/install-state")"
fi
if [ -z "$VAULT_RAW" ] || ! VAULT="$(cd "$VAULT_RAW" 2>/dev/null && pwd -P)"; then
  printf 'PII guard could not resolve the configured vault, so the write was blocked.\n' >&2
  exit 2
fi
case "$VAULT" in
  *$'\n'*|*$'\r'*|*$'\t'*)
    printf 'PII guard rejected a vault path containing control characters.\n' >&2
    exit 2
    ;;
esac

input="$(cat /dev/stdin)"
if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
  printf 'PII guard received invalid PreToolUse JSON, so the write was blocked.\n' >&2
  exit 2
fi

json_string() {
  local filter="$1" output_name="$2" captured

  captured="$(printf '%s' "$input" | jq -r --arg sentinel "$CAPTURE_SENTINEL" "($filter) + \$sentinel")" || return 1
  case "$captured" in
    *"$CAPTURE_SENTINEL") printf -v "$output_name" '%s' "${captured%"$CAPTURE_SENTINEL"}" ;;
    *) return 1 ;;
  esac
}

read_file_preserving_newlines() {
  local path="$1" output_name="$2" captured expected_size captured_size

  expected_size="$(wc -c < "$path" | tr -d '[:space:]')" || return 1
  case "$expected_size" in
    ''|*[!0-9]*) return 1 ;;
  esac
  captured="$(cat "$path"; printf '%s' "$CAPTURE_SENTINEL")" || return 1
  case "$captured" in
    *"$CAPTURE_SENTINEL") captured="${captured%"$CAPTURE_SENTINEL"}" ;;
    *) return 1 ;;
  esac
  captured_size="$(LC_ALL=C printf '%s' "$captured" | wc -c | tr -d '[:space:]')" || return 1
  case "$captured_size" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$captured_size" = "$expected_size" ] || return 1
  printf -v "$output_name" '%s' "$captured"
}

normalize_path() {
  local path="$1" cwd="$2" part count result=""
  local -a parts=()
  local -a stack=()

  case "$path" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  if [[ "$path" != /* ]]; then
    if ! cwd="$(cd "$cwd" 2>/dev/null && pwd -P)"; then
      return 1
    fi
    case "$cwd" in
      *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
    esac
    path="$cwd/$path"
  fi

  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..)
        count="${#stack[@]}"
        if [ "$count" -gt 0 ]; then
          unset "stack[$((count - 1))]"
        fi
        ;;
      *) stack[${#stack[@]}]="$part" ;;
    esac
  done
  for part in "${stack[@]}"; do
    result="$result/$part"
  done
  printf '%s' "${result:-/}"
}

resolve_physical_path() {
  local path="$1" depth="${2:-0}" resolved ancestor parent base link suffix=""

  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath "$path" 2>/dev/null || true)"
    if [ -n "$resolved" ]; then
      printf '%s' "$resolved"
      return 0
    fi
  fi

  if [ -L "$path" ]; then
    [ "$depth" -lt 40 ] || return 1
    link="$(readlink "$path")" || return 1
    case "$link" in
      /*) ;;
      *) link="${path%/*}/$link" ;;
    esac
    link="$(normalize_path "$link" /)" || return 1
    resolve_physical_path "$link" "$((depth + 1))"
    return $?
  fi

  ancestor="$path"
  while [ ! -d "$ancestor" ]; do
    [ "$ancestor" != / ] || return 1
    base="${ancestor##*/}"
    [ -n "$base" ] || return 1
    suffix="/$base$suffix"
    parent="${ancestor%/*}"
    ancestor="${parent:-/}"
  done
  resolved="$(cd "$ancestor" 2>/dev/null && pwd -P)" || return 1
  case "$resolved" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  printf '%s%s' "$resolved" "$suffix"
}

is_under_vault() {
  case "$1" in
    "$VAULT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

has_internal_symlink_component() {
  local path="$1" relative part current="$VAULT"

  is_under_vault "$path" || return 1
  relative="${path#"$VAULT"/}"
  while [ -n "$relative" ]; do
    part="${relative%%/*}"
    if [ "$relative" = "$part" ]; then
      relative=""
    else
      relative="${relative#*/}"
    fi
    current="$current/$part"
    if [ -L "$current" ]; then
      return 0
    fi
  done
  return 1
}

# stdout: 실제 검사 대상 경로. return 1: vault 밖/제외 대상, return 2: 안전하게 판별 불가.
classify_vault_target() {
  local raw_path="$1" cwd="$2" lexical resolved chosen

  if ! lexical="$(normalize_path "$raw_path" "$cwd")" ||
    ! resolved="$(resolve_physical_path "$lexical")"; then
    printf 'PII guard could not resolve a write target.\n' >&2
    return 2
  fi

  if is_under_vault "$lexical"; then
    if ! is_under_vault "$resolved"; then
      printf 'PII guard blocked a vault path that resolves outside the vault.\n' >&2
      return 2
    fi
    if has_internal_symlink_component "$lexical"; then
      printf 'PII guard blocked a vault write through a symlink.\n' >&2
      return 2
    fi
    chosen="$lexical"
  elif is_under_vault "$resolved"; then
    chosen="$resolved"
  else
    return 1
  fi

  printf '%s' "$chosen"
}

DETECTED_CATEGORIES=""
add_category() {
  if [ -z "$DETECTED_CATEGORIES" ]; then
    DETECTED_CATEGORIES="$1"
  else
    DETECTED_CATEGORIES="$DETECTED_CATEGORIES, $1"
  fi
}

detect_sensitive_content() {
  local content="$1"
  DETECTED_CATEGORIES=""

  if printf '%s\n' "$content" |
    grep -Eo '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' |
    grep -viE '(@example\.com$|^test@|^noreply@|placeholder|masked|^user@domain\.)' >/dev/null; then
    add_category EMAIL
  fi
  if printf '%s\n' "$content" |
    grep -Eo '[0-9xX]{2,4}-[0-9xX]{3,4}-[0-9xX]{4}' |
    grep -vE '^(010-0000-0000|[xX]{2,4}-[xX]{3,4}-[xX]{4}|02-1234-5678)$' >/dev/null; then
    add_category PHONE
  fi
  if printf '%s\n' "$content" |
    grep -Eio "(password|secret|api[_-]?key|access[_-]?token|private[_-]?key)[[:space:]]*[:=][[:space:]]*['\"]?[A-Za-z0-9+/_.=-]{16,}" |
    grep -viE '(placeholder|masked|example)' >/dev/null ||
    printf '%s\n' "$content" | grep -Eiq \
      '(bearer[[:space:]]+[A-Za-z0-9._~-]{16,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'; then
    add_category SECRET
  fi
  if printf '%s\n' "$content" |
    grep -Eio '(mysql|postgres|mongodb|redis|amqp|sentry)://[^[:space:]"<>]+' |
    grep -viE '(://localhost([/:]|$)|://127\.0\.0\.1([/:]|$)|example|placeholder)' >/dev/null; then
    add_category DSN
  fi
  if printf '%s\n' "$content" |
    grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' |
    grep -vE '^(127\.0\.0\.1|0\.0\.0\.0|255\.255\.255\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})$' >/dev/null; then
    add_category IP
  fi
}

emit_deny() {
  local reason
  reason="민감정보 후보($DETECTED_CATEGORIES)가 포함된 vault write를 차단했습니다. 값은 출력하지 않았습니다. 마스킹하거나 역할명·예시값으로 바꾼 뒤 다시 시도하세요."
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
}

scan_content() {
  detect_sensitive_content "$1"
  if [ -n "$DETECTED_CATEGORIES" ]; then
    emit_deny
    exit 0
  fi
}

scan_vault_target_path() {
  scan_content "${1#"$VAULT"/}"
}

inspect_write() {
  local raw_path="$1" content="$2" cwd="$3" target status

  target="$(classify_vault_target "$raw_path" "$cwd")"
  status=$?
  case "$status" in
    0)
      scan_vault_target_path "$target"
      scan_content "$content"
      ;;
    1) return 0 ;;
    *) exit 2 ;;
  esac
}

inspect_edit() {
  local raw_path="$1" old_string="$2" new_string="$3" replace_all="$4" cwd="$5"
  local target status size source prospective

  target="$(classify_vault_target "$raw_path" "$cwd")"
  status=$?
  case "$status" in
    1) return 0 ;;
    2) exit 2 ;;
  esac
  scan_vault_target_path "$target"
  if [ ! -f "$target" ] || [ -L "$target" ]; then
    printf 'PII guard could not read the Edit target, so the write was blocked.\n' >&2
    exit 2
  fi
  size="$(wc -c < "$target" | tr -d ' ')"
  case "$size" in
    ''|*[!0-9]*) printf 'PII guard could not size the Edit target.\n' >&2; exit 2 ;;
  esac
  if [ "$size" -gt "$MAX_SCAN_BYTES" ]; then
    printf 'PII guard blocked an Edit target larger than 5 MiB.\n' >&2
    exit 2
  fi
  if ! read_file_preserving_newlines "$target" source; then
    printf 'PII guard could not read the Edit target, so the write was blocked.\n' >&2
    exit 2
  fi
  if ! prospective="$(printf '%s' "$source" | jq -Rrs \
    --arg old "$old_string" \
    --arg new "$new_string" \
    --arg sentinel "$CAPTURE_SENTINEL" \
    --argjson replaceAll "$replace_all" '
      . as $source |
      ($source | index($old)) as $offset |
      if ($old | length) == 0 or $offset == null then error("old_string not found")
      elif $replaceAll then ($source | split($old) | join($new))
      else $source[0:$offset] + $new + $source[($offset + ($old | length)):]
      end + $sentinel
    ' 2>/dev/null)"; then
    printf 'PII guard could not reconstruct the Edit result, so the write was blocked.\n' >&2
    exit 2
  fi
  prospective="${prospective%"$CAPTURE_SENTINEL"}"
  scan_content "$prospective"
}

inspect_patch() {
  local patch="$1" cwd="$2" line current_path="" source_path="" pending="" saw_header=0
  local destination destination_target destination_status source_target source_status source_content source_size

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '*** Add File: '*|'*** Update File: '*|'*** Delete File: '*)
        if [ -n "$current_path" ] && [ -n "$pending" ]; then
          inspect_write "$current_path" "$pending" "$cwd"
        fi
        pending=""
        saw_header=1
        case "$line" in
          '*** Add File: '*) current_path="${line#*** Add File: }"; source_path="" ;;
          '*** Update File: '*) current_path="${line#*** Update File: }"; source_path="$current_path" ;;
          *) current_path=""; source_path="" ;;
        esac
        ;;
      '*** Move to: '*)
        destination="${line#*** Move to: }"
        destination_target="$(classify_vault_target "$destination" "$cwd")"
        destination_status=$?
        if [ "$destination_status" -eq 2 ]; then
          exit 2
        fi
        if [ "$destination_status" -eq 0 ]; then
          scan_vault_target_path "$destination_target"
          [ -n "$source_path" ] || { printf 'PII guard could not resolve an apply_patch move source.\n' >&2; exit 2; }
          source_target="$(classify_vault_target "$source_path" "$cwd")"
          source_status=$?
          if [ "$source_status" -ne 0 ] || [ ! -f "$source_target" ] || [ -L "$source_target" ]; then
            printf 'PII guard blocks moves into the vault unless the source is a regular vault file.\n' >&2
            exit 2
          fi
          source_size="$(wc -c < "$source_target" | tr -d ' ')"
          case "$source_size" in
            ''|*[!0-9]*) printf 'PII guard could not size an apply_patch move source.\n' >&2; exit 2 ;;
          esac
          if [ "$source_size" -gt "$MAX_SCAN_BYTES" ]; then
            printf 'PII guard blocked an apply_patch move source larger than 5 MiB.\n' >&2
            exit 2
          fi
          if ! read_file_preserving_newlines "$source_target" source_content; then
            printf 'PII guard could not read an apply_patch move source.\n' >&2
            exit 2
          fi
          if [ -n "$pending" ]; then
            source_content="$source_content${source_content:+$'\n'}$pending"
          fi
          scan_content "$source_content"
        fi
        pending=""
        current_path="$destination"
        source_path=""
        saw_header=1
        ;;
      +*)
        if [ -z "$current_path" ]; then
          printf 'PII guard could not associate apply_patch content with a target.\n' >&2
          exit 2
        fi
        pending="$pending${pending:+$'\n'}${line:1}"
        ;;
    esac
  done <<< "$patch"

  if [ -n "$current_path" ] && [ -n "$pending" ]; then
    inspect_write "$current_path" "$pending" "$cwd"
  fi
  if [ "$saw_header" -ne 1 ]; then
    printf 'PII guard received an unrecognized apply_patch payload.\n' >&2
    exit 2
  fi
}

if ! printf '%s' "$input" | jq -e '
  (.tool_name | type) == "string" and
  ((.cwd == null) or (((.cwd | type) == "string") and
    ((.cwd | contains("\u0000")) | not) and
    ((.cwd | contains("\n")) | not) and
    ((.cwd | contains("\r")) | not) and
    ((.cwd | contains("\t")) | not))) and
  (.tool_input | type) == "object"
' >/dev/null 2>&1; then
  printf 'PII guard received an unsupported PreToolUse schema.\n' >&2
  exit 2
fi

json_string '.tool_name' tool_name || parser_failure
json_string '(.cwd // "")' cwd || parser_failure
if [ -z "$cwd" ]; then
  cwd="$(pwd -P)"
fi

case "$tool_name" in
  Write)
    if ! printf '%s' "$input" | jq -e '
      (.tool_input.file_path | type) == "string" and
      (.tool_input.file_path | length) > 0 and
      ((.tool_input.file_path | contains("\u0000")) | not) and
      (.tool_input.content | type) == "string" and
      ((.tool_input.content | contains("\u0000")) | not)
    ' >/dev/null 2>&1; then
      printf 'PII guard received an invalid Write payload.\n' >&2
      exit 2
    fi
    json_string '.tool_input.file_path' file_path || parser_failure
    json_string '.tool_input.content' content || parser_failure
    inspect_write "$file_path" "$content" "$cwd"
    ;;
  Edit)
    if ! printf '%s' "$input" | jq -e '
      (.tool_input.file_path | type) == "string" and
      (.tool_input.file_path | length) > 0 and
      (.tool_input.old_string | type) == "string" and
      (.tool_input.new_string | type) == "string" and
      ((.tool_input.file_path | contains("\u0000")) | not) and
      ((.tool_input.old_string | contains("\u0000")) | not) and
      ((.tool_input.new_string | contains("\u0000")) | not) and
      ((.tool_input.replace_all == null) or ((.tool_input.replace_all | type) == "boolean"))
    ' >/dev/null 2>&1; then
      printf 'PII guard received an invalid Edit payload.\n' >&2
      exit 2
    fi
    json_string '.tool_input.file_path' file_path || parser_failure
    json_string '.tool_input.old_string' old_string || parser_failure
    json_string '.tool_input.new_string' new_string || parser_failure
    replace_all="$(printf '%s' "$input" | jq -r '.tool_input.replace_all // false')"
    inspect_edit "$file_path" "$old_string" "$new_string" "$replace_all" "$cwd"
    ;;
  apply_patch)
    if ! printf '%s' "$input" | jq -e '
      (.tool_input.command | type) == "string" and
      (.tool_input.command | length) > 0 and
      ((.tool_input.command | contains("\u0000")) | not)
    ' >/dev/null 2>&1; then
      printf 'PII guard received an invalid apply_patch payload.\n' >&2
      exit 2
    fi
    json_string '.tool_input.command' patch || parser_failure
    inspect_patch "$patch" "$cwd"
    ;;
  *)
    printf 'PII guard received an unsupported tool name, so the write was blocked.\n' >&2
    exit 2
    ;;
esac
exit 0
