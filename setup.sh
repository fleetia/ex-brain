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
SKILLS=(session-start session-end kb-lookup kb-routing)
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

# 2) 스킬·훅을 vault/_kit/ 로 복사 (킷 폴더를 나중에 지워도 동작하도록)
mkdir -p "$VAULT/_kit/hooks"
cp "$KIT/hooks/session-context.sh" "$VAULT/_kit/hooks/session-context.sh"
chmod +x "$VAULT/_kit/hooks/session-context.sh"
for name in "${SKILLS[@]}"; do
  mkdir -p "$VAULT/_kit/skills/$name"
  cp "$KIT/skills/$name/SKILL.md" "$VAULT/_kit/skills/$name/SKILL.md"
done
# 기본 경로가 아니면 스킬 문서 속 vault 경로 표기를 실제 경로로 치환
if [ "$VAULT" != "$HOME/KnowledgeBase" ]; then
  for name in "${SKILLS[@]}"; do
    "${SED_I[@]}" "s|~/KnowledgeBase|$VAULT|g" "$VAULT/_kit/skills/$name/SKILL.md"
  done
fi
echo "✓ 스킬 ${#SKILLS[@]}개 + 훅 → $VAULT/_kit/"

# 3) ~/.claude/skills/ symlink
mkdir -p "$CLAUDE_DIR/skills"
for name in "${SKILLS[@]}"; do
  target="$CLAUDE_DIR/skills/$name"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "✗ $target 가 이미 실제 폴더/파일로 존재합니다. 내용 확인·백업 후 제거하고 다시 실행하세요."
    exit 1
  fi
  ln -sfn "$VAULT/_kit/skills/$name" "$target"
done
echo "✓ ~/.claude/skills/ symlink 연결"

# 4) settings.json 에 SessionStart 훅 등록
HOOK_CMD="$VAULT/_kit/hooks/session-context.sh"

manual_notice() {
  echo ""
  echo "  수동 등록 방법:"
  echo "  1) $KIT/settings-snippet.json 을 열어 __HOOK_PATH__ 를 아래 경로로 바꾼다"
  echo "       $HOOK_CMD"
  echo "  2) 그 내용을 $SETTINGS 의 hooks 항목에 합친다"
  echo "  (Claude Code에게 두 파일을 보여주고 \"합쳐줘\"라고 해도 된다)"
}

if [ -f "$SETTINGS" ] && grep -q "session-context.sh" "$SETTINGS" 2>/dev/null; then
  echo "· SessionStart 훅이 이미 등록되어 있습니다"
elif [ ! -f "$SETTINGS" ]; then
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
    ]
  }
}
EOF
  echo "✓ settings.json 생성 + SessionStart 훅 등록"
elif command -v jq >/dev/null 2>&1; then
  if jq -e '.hooks.SessionStart' "$SETTINGS" >/dev/null 2>&1; then
    echo "! settings.json 에 다른 SessionStart 훅이 이미 있습니다 — 자동 병합하지 않습니다."
    manual_notice
  else
    cp "$SETTINGS" "$SETTINGS.bak-$ts"
    tmp="$(mktemp)"
    jq --arg cmd "$HOOK_CMD" \
      '.hooks = (.hooks // {}) + {SessionStart: [{matcher: "startup|clear", hooks: [{type: "command", command: $cmd, timeout: 10, statusMessage: "지식베이스 컨텍스트 로딩..."}]}]}' \
      "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    echo "✓ SessionStart 훅 등록 (기존 설정은 settings.json.bak-$ts 로 백업)"
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

cat <<'DONE'

설치 완료. 다음 단계:
- 새 Claude Code 세션을 열면 진행 중 작업 목록이 자동으로 로드됩니다 (처음엔 "(없음)"이 정상)
- 세션을 마칠 때 "세션 종료해줘"라고 하면 오늘 작업이 vault에 기록됩니다
- 다음 세션에서 "이어서 하자"라고 하면 기록을 읽고 컨텍스트를 복원합니다
DONE
exit "$fail"
