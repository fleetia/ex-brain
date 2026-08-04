#!/usr/bin/env bash
# build.sh — 배포용 폴더 생성 (단일 원본 → cli/, app/)
#
# 사용: bash build.sh
# 하는 일: 상위 폴더(exterior/)에 cli/, app/ 을 만들고 킷 파일을 복사한 뒤
#          README만 대상에 맞게 갈아끼운다.
#   - cli/ : 터미널·Claude Code 사용자용 (readmes/README-cli.md)
#   - app/ : Claude/Codex 앱 사용자용, 일반인 (readmes/README-app.md)

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(cd "$SRC/.." && pwd)"

for variant in cli app; do
  dst="$OUT/$variant"
  rsync -a --delete \
    --exclude '.git' \
    --exclude '.DS_Store' \
    --exclude 'readmes' \
    --exclude 'build.sh' \
    --exclude 'README.md' \
    "$SRC/" "$dst/"
  cp "$SRC/readmes/README-$variant.md" "$dst/README.md"
  echo "✓ $dst"
done

cat <<EOF

빌드 완료. 배포 zip 만들기:
  cd $OUT && zip -rq ai-session-kit-cli.zip cli && zip -rq ai-session-kit-app.zip app
EOF
