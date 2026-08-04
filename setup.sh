#!/usr/bin/env bash
# setup.sh — AI 세션 지식 킷 설치 (멱등: 여러 번 실행해도 안전)
#
# 사용: bash setup.sh [vault경로]
#   기본 vault 경로: ~/KnowledgeBase
#
# 하는 일:
#   1) 지식 vault 폴더 생성 (이미 있으면 기존 내용 보존)
#   2) 스킬·훅을 vault/_kit/ 안으로 복사
#   3) ~/.claude/skills/ 에 스킬 symlink 연결
#   4) ~/.claude/settings.json 에 SessionStart 훅 등록 (기존 설정을 덮어쓰지 않음)
#   5) 배선 검증 + 훅 스모크 테스트

set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${1:-$HOME/KnowledgeBase}"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
SKILLS=(session-start session-end kb-lookup kb-routing humanize-ko cognitive-rhythm-writing task-doc-writing weekly-summary monthly-summary)
ts="$(date +%Y%m%d%H%M%S)"

case "$VAULT" in
  /*) ;;
  *) echo "✗ vault 경로는 절대경로로 지정하세요 (예: bash setup.sh \$HOME/my-vault)"; exit 1 ;;
esac
case "$VAULT" in
  *[\ \"\'\|]*) echo "✗ vault 경로에 공백이나 특수문자를 쓰지 마세요: $VAULT"; exit 1 ;;
esac

# BSD(macOS) / GNU sed 구분
if sed --version >/dev/null 2>&1; then SED_I=(sed -i); else SED_I=(sed -i ''); fi

echo "지식 vault: $VAULT"

# 1) vault 생성
if [ -d "$VAULT" ]; then
  echo "· vault 폴더가 이미 있습니다 — 기존 내용은 건드리지 않습니다"
else
  mkdir -p "$VAULT"
  cp -R "$KIT/vault-template/." "$VAULT/"
  echo "✓ vault 생성"
fi

# 2) 스킬·훅·스크립트를 vault/_kit/ 로 복사 (킷 폴더를 나중에 지워도 동작하도록)
#    로컬에서 수정한 파일이 있으면 .bak-{시각} 으로 백업한 뒤 킷 버전으로 교체한다.
backup_count=0
install_file() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    cp "$dst" "$dst.bak-$ts"
    backup_count=$((backup_count + 1))
  fi
  cp "$src" "$dst"
}

install_file "$KIT/hooks/session-context.sh" "$VAULT/_kit/hooks/session-context.sh"
install_file "$KIT/hooks/check-pii.sh" "$VAULT/_kit/hooks/check-pii.sh"
chmod +x "$VAULT/_kit/hooks/"*.sh
install_file "$KIT/scripts/kb_lint.py" "$VAULT/_kit/scripts/kb_lint.py"

# 스킬은 staging에서 vault 경로 치환까지 마친 뒤 설치 (재실행 시 불필요한 백업 방지)
stage="$(mktemp -d)"
for name in "${SKILLS[@]}"; do
  mkdir -p "$stage/$name"
  cp -R "$KIT/skills/$name/." "$stage/$name/"
  if [ "$VAULT" != "$HOME/KnowledgeBase" ]; then
    "${SED_I[@]}" "s|~/KnowledgeBase|$VAULT|g" "$stage/$name/SKILL.md"
  fi
  while IFS= read -r rel; do
    rel="${rel#./}"
    install_file "$stage/$name/$rel" "$VAULT/_kit/skills/$name/$rel"
  done < <(cd "$stage/$name" && find . -type f)
done
rm -rf "$stage"

echo "✓ 스킬 ${#SKILLS[@]}개 + 훅 2개 + lint 스크립트 → $VAULT/_kit/"
if [ "$backup_count" -gt 0 ]; then
  echo "· 로컬에서 수정했던 파일 ${backup_count}개를 .bak-$ts 로 백업한 뒤 킷 버전으로 교체했습니다"
  echo "  (수정 내용을 유지하려면 백업 파일과 비교해 다시 반영하세요)"
fi

# 3) 스킬 연결 — Claude(~/.claude/skills)와 Codex(~/.agents/skills) 양쪽
mkdir -p "$CLAUDE_DIR/skills"
for name in "${SKILLS[@]}"; do
  target="$CLAUDE_DIR/skills/$name"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "✗ $target 가 이미 실제 폴더/파일로 존재합니다. 내용 확인·백업 후 제거하고 다시 실행하세요."
    exit 1
  fi
  ln -sfn "$VAULT/_kit/skills/$name" "$target"
done
echo "✓ Claude 스킬 연결 (~/.claude/skills/)"

AGENT_SKILLS="$HOME/.agents/skills"
mkdir -p "$AGENT_SKILLS"
codex_linked=0
codex_skipped=0
for name in "${SKILLS[@]}"; do
  target="$AGENT_SKILLS/$name"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    codex_skipped=$((codex_skipped + 1))
    continue
  fi
  ln -sfn "$VAULT/_kit/skills/$name" "$target"
  codex_linked=$((codex_linked + 1))
done
echo "✓ Codex 스킬 연결 (~/.agents/skills/, ${codex_linked}개 연결·${codex_skipped}개 기존 보존)"

# 4) settings.json 에 훅 등록 (SessionStart: 컨텍스트 주입, PostToolUse: 민감정보 스캔)
HOOK_CMD="$VAULT/_kit/hooks/session-context.sh"
PII_CMD="$VAULT/_kit/hooks/check-pii.sh"

manual_notice() {
  echo ""
  echo "  수동 등록 방법:"
  echo "  1) $KIT/settings-snippet.json 을 열어 placeholder 를 아래 경로로 바꾼다"
  echo "       __HOOK_PATH__     → $HOOK_CMD"
  echo "       __PII_HOOK_PATH__ → $PII_CMD"
  echo "  2) 그 내용을 $SETTINGS 의 hooks 항목에 합친다"
  echo "  (Claude Code에게 두 파일을 보여주고 \"합쳐줘\"라고 해도 된다)"
}

if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$CLAUDE_DIR"
  cat > "$SETTINGS" <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear",
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_CMD",
            "timeout": 10,
            "statusMessage": "지식베이스 컨텍스트 로딩..."
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "$PII_CMD",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF
  echo "✓ settings.json 생성 + 훅 2개 등록"
elif command -v jq >/dev/null 2>&1; then
  settings_backed_up=0
  backup_settings() {
    if [ "$settings_backed_up" -eq 0 ]; then
      cp "$SETTINGS" "$SETTINGS.bak-$ts"
      settings_backed_up=1
    fi
  }
  # SessionStart: 다른 훅이 이미 있으면 건드리지 않음 (보수적)
  if grep -q "session-context.sh" "$SETTINGS" 2>/dev/null; then
    echo "· SessionStart 훅이 이미 등록되어 있습니다"
  elif jq -e '.hooks.SessionStart' "$SETTINGS" >/dev/null 2>&1; then
    echo "! settings.json 에 다른 SessionStart 훅이 이미 있습니다 — 자동 병합하지 않습니다."
    manual_notice
  else
    backup_settings
    tmp="$(mktemp)"
    jq --arg cmd "$HOOK_CMD" \
      '.hooks = (.hooks // {}) + {SessionStart: [{matcher: "startup|clear", hooks: [{type: "command", command: $cmd, timeout: 10, statusMessage: "지식베이스 컨텍스트 로딩..."}]}]}' \
      "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    echo "✓ SessionStart 훅 등록"
  fi
  # PostToolUse: 배열이라 기존 항목 뒤에 append 가능
  if grep -q "check-pii.sh" "$SETTINGS" 2>/dev/null; then
    echo "· 민감정보 스캔 훅이 이미 등록되어 있습니다"
  else
    backup_settings
    tmp="$(mktemp)"
    jq --arg cmd "$PII_CMD" \
      '.hooks = (.hooks // {}) | .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{matcher: "Write|Edit", hooks: [{type: "command", command: $cmd, timeout: 10}]}])' \
      "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    echo "✓ 민감정보 스캔 훅 등록"
  fi
  if [ "$settings_backed_up" -eq 1 ]; then
    echo "· 기존 설정은 settings.json.bak-$ts 로 백업되어 있습니다"
  fi
else
  echo "! jq 가 없어 기존 settings.json 에 자동 병합할 수 없습니다."
  manual_notice
fi

# 5) 검증
fail=0
for name in "${SKILLS[@]}"; do
  p="$CLAUDE_DIR/skills/$name"
  if [ -e "$p" ]; then
    echo "✓ $p → $(readlink "$p")"
  else
    echo "✗ DANGLING: $p"
    fail=1
  fi
done
out="$("$VAULT/_kit/hooks/session-context.sh" 2>/dev/null || true)"
if [ -n "$out" ]; then
  echo "✓ 훅 스모크 테스트 통과"
else
  echo "✗ 훅이 아무것도 출력하지 않았습니다 — bash $VAULT/_kit/hooks/session-context.sh 로 직접 확인하세요"
  fail=1
fi
if command -v python3 >/dev/null 2>&1; then
  if python3 "$VAULT/_kit/scripts/kb_lint.py" "$VAULT" --check >/dev/null 2>&1; then
    echo "✓ lint 스모크 테스트 통과 (vault 위생 정상)"
  else
    echo "· lint가 문제를 발견했습니다 — python3 $VAULT/_kit/scripts/kb_lint.py 로 상세 확인"
  fi
else
  echo "· python3 없음 — lint 검증 생략 (세션 기록·복원은 정상 동작)"
fi

cat <<'DONE'

설치 완료. 다음 단계:
- 세션을 마칠 때 "세션 종료해줘"라고 하면 오늘 작업이 vault에 기록됩니다
- 다음 세션에서 "이어서 하자"라고 하면 기록을 읽고 컨텍스트를 복원합니다
- Claude: 새 세션을 열면 진행 중 작업 목록이 자동으로 로드됩니다 (처음엔 "(없음)"이 정상)
- Codex: 자동 로드가 없으므로 세션을 시작할 때 "이어서 하자"라고 직접 말하면 됩니다
DONE
exit "$fail"
