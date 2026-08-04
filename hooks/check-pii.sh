#!/usr/bin/env bash
# PostToolUse hook: vault에 쓰이는 파일의 민감정보 스캔
# 이메일·전화번호·토큰·접속 문자열·공인 IP를 감지하면 차단하고 마스킹을 요청한다.
# - vault 밖 파일과 _kit/(킷 코드)은 검사하지 않는다
# - jq가 없으면 검사 없이 통과 (작업을 막지 않는다)
#
# vault 위치: 이 스크립트가 설치된 곳({vault}/_kit/hooks/) 기준 자동 인식, KB_VAULT로 덮어쓰기 가능.

set -euo pipefail

VAULT="${KB_VAULT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat /dev/stdin)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')

if [[ -z "$file_path" || ! -f "$file_path" ]]; then
  exit 0
fi

# vault 안의 지식 문서만 검사
case "$file_path" in
  "$VAULT"/_kit/*) exit 0 ;;
  "$VAULT"/*) ;;
  *) exit 0 ;;
esac

# 바이너리 제외
case "$file_path" in
  *.png|*.jpg|*.jpeg|*.gif|*.ico|*.woff|*.woff2|*.ttf|*.pdf) exit 0 ;;
esac

findings=""

# 1. 이메일 주소 (placeholder/예시 패턴 제외)
emails=$(grep -nE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$file_path" 2>/dev/null \
  | grep -viE '(example\.com|placeholder|MASKED|noreply|test@|user@domain)' || true)
if [[ -n "$emails" ]]; then
  findings+="EMAIL: $emails\n"
fi

# 2. 전화번호 (한국 형식: 010-1234-5678, 02-123-4567)
phones=$(grep -nE '[0-9]{2,4}-[0-9]{3,4}-[0-9]{4}' "$file_path" 2>/dev/null \
  | grep -vE '(xxxx|0000|1234-5678|예시|example)' || true)
if [[ -n "$phones" ]]; then
  findings+="PHONE: $phones\n"
fi

# 3. 토큰, API 키, 비밀값
secrets=$(grep -niE '(password|secret|api_key|apikey|access_token|private_key)[[:space:]]*[=:][[:space:]]*["\x27]?[A-Za-z0-9+/_.=-]{16,}' "$file_path" 2>/dev/null || true)
if [[ -n "$secrets" ]]; then
  findings+="SECRET: $secrets\n"
fi

# 4. DSN / 접속 문자열
dsns=$(grep -niE '(mysql|postgres|mongodb|redis|amqp|sentry)://[^[:space:]"]+' "$file_path" 2>/dev/null \
  | grep -viE '(localhost|127\.0\.0\.1|example|placeholder)' || true)
if [[ -n "$dsns" ]]; then
  findings+="DSN: $dsns\n"
fi

# 5. 공인 IP (사설 대역 제외 — 단순 heuristic)
ips=$(grep -noE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "$file_path" 2>/dev/null \
  | grep -vE '(127\.0\.0\.1|0\.0\.0\.0|255\.255\.255|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' || true)
if [[ -n "$ips" ]]; then
  findings+="IP: $ips\n"
fi

if [[ -n "$findings" ]]; then
  reason=$(printf "⚠ 민감정보가 감지되었습니다: %s\n%b\n마스킹하거나 역할명·예시값으로 바꾼 뒤 다시 저장하세요." "$file_path" "$findings")
  jq -n --arg reason "$reason" '{
    decision: "block",
    reason: $reason
  }'
  exit 0
fi

exit 0
