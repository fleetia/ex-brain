#!/usr/bin/env bash
# uninstall.sh — 킷 배선 제거 (vault의 지식 데이터는 남긴다)
#
# 하는 일: ~/.claude/skills/ 의 킷 symlink 제거 + settings.json 에서 킷 훅 2개 제거
# 안 하는 일: vault 삭제 — 지식 폴더는 평범한 markdown 폴더라 원하는 만큼 보관하면 된다

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
SKILLS=(session-start session-end kb-lookup kb-routing humanize-ko cognitive-rhythm-writing task-doc-writing weekly-summary monthly-summary)
ts="$(date +%Y%m%d%H%M%S)"

removed=0
for name in "${SKILLS[@]}"; do
  target="$CLAUDE_DIR/skills/$name"
  if [ -L "$target" ]; then
    rm "$target"
    removed=$((removed + 1))
  fi
done
echo "✓ 스킬 symlink ${removed}개 제거"

if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  cp "$SETTINGS" "$SETTINGS.bak-$ts"
  tmp="$(mktemp)"
  jq '
    .hooks //= {} |
    .hooks.SessionStart = [ (.hooks.SessionStart // [])[]
      | select(([.hooks[]? | (.command // "") | test("session-context\\.sh")] | any) | not) ] |
    .hooks.PostToolUse = [ (.hooks.PostToolUse // [])[]
      | select(([.hooks[]? | (.command // "") | test("check-pii\\.sh")] | any) | not) ] |
    (if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end) |
    (if .hooks.PostToolUse == [] then del(.hooks.PostToolUse) else . end) |
    (if .hooks == {} then del(.hooks) else . end)
  ' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo "✓ settings.json 에서 킷 훅 제거 (백업: settings.json.bak-$ts)"
else
  echo "! settings.json 은 수동으로 정리하세요:"
  echo "  - hooks.SessionStart 에서 session-context.sh 항목 제거"
  echo "  - hooks.PostToolUse 에서 check-pii.sh 항목 제거"
fi

echo ""
echo "제거 완료. vault(지식 폴더)는 그대로 남아 있습니다 — 더 이상 필요 없으면 폴더째 지우면 됩니다."
