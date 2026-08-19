#!/usr/bin/env bash
# build.sh — 배포용 폴더 생성 (단일 원본 → cli/, app/)
#
# 사용: bash build.sh [출력디렉토리]   (기본: 저장소 안 dist/)
# 하는 일: 출력디렉토리에 cli/, app/ 을 만들고 킷 파일을 복사한 뒤
#          README만 대상에 맞게 갈아끼운다.
#   - cli/ : 터미널·Claude Code 사용자용 (readmes/README-cli.md)
#   - app/ : Claude/Codex 앱 사용자용, 일반인 (readmes/README-app.md)

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OUT_ARG="${1:-$SRC/dist}"
BUILD_MARKER=".ai-session-kit-build"
BUILD_MARKER_CONTENT="ai-session-kit-build-v1"
ARTIFACT_MANIFEST="$SRC/tests/expected-artifact-manifest.txt"

normalize_absolute_path() {
  local path="$1" part count result=""
  local -a parts=()
  local -a stack=()

  case "$path" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
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

resolve_future_directory() {
  local path="$1" ancestor="$1" parent base suffix="" resolved

  while [ ! -d "$ancestor" ]; do
    [ "$ancestor" != / ] || return 1
    base="${ancestor##*/}"
    [ -n "$base" ] || return 1
    suffix="/$base$suffix"
    parent="${ancestor%/*}"
    ancestor="${parent:-/}"
  done
  resolved="$(cd "$ancestor" && pwd -P)" || return 1
  printf '%s%s' "$resolved" "$suffix"
}

case "$OUT_ARG" in
  /*) OUT_REQUESTED="$OUT_ARG" ;;
  *) OUT_REQUESTED="$(pwd -P)/$OUT_ARG" ;;
esac
if ! OUT_REQUESTED="$(normalize_absolute_path "$OUT_REQUESTED")" ||
  ! OUT="$(resolve_future_directory "$OUT_REQUESTED")"; then
  echo "✗ 출력디렉토리 경로를 안전하게 해석할 수 없습니다."
  exit 1
fi

if [ "$OUT" = "$SRC" ]; then
  echo "✗ 출력디렉토리가 원본 폴더와 같습니다. 다른 경로를 지정하세요."
  exit 1
fi
if [ "$OUT" = / ]; then
  echo "✗ 파일시스템 루트는 출력디렉토리로 사용할 수 없습니다."
  exit 1
fi
case "$OUT" in
  "$SRC/dist"|"$SRC/dist/"*) ;;
  "$SRC"/*)
    echo "✗ 원본 저장소 안에서는 dist/ 아래만 출력디렉토리로 사용할 수 있습니다: $OUT"
    exit 1
    ;;
esac

unexpected_source_node="$(find "$SRC" \
  \( -path "$SRC/.git" -o -path "$SRC/node_modules" -o -path "$SRC/dist" \) -prune -o \
  ! -type f ! -type d -print -quit)"
if [ -n "$unexpected_source_node" ]; then
  echo "✗ 원본에 regular file/directory가 아닌 항목이 있어 빌드를 중단합니다: $unexpected_source_node"
  exit 1
fi
for source_readme in "$SRC/readmes/README-cli.md" "$SRC/readmes/README-app.md"; do
  if [ ! -f "$source_readme" ] || [ -L "$source_readme" ]; then
    echo "✗ 배포 README가 symlink가 아닌 regular file이어야 합니다: $source_readme"
    exit 1
  fi
done
if [ ! -f "$ARTIFACT_MANIFEST" ] || [ -L "$ARTIFACT_MANIFEST" ]; then
  echo "✗ 배포 allowlist가 symlink가 아닌 regular file이어야 합니다: $ARTIFACT_MANIFEST"
  exit 1
fi

while IFS= read -r artifact_path || [ -n "$artifact_path" ]; do
  case "$artifact_path" in
    ''|/*|.|..|../*|*/../*|*/..|*'//'*)
      echo "✗ 배포 allowlist에 안전하지 않은 경로가 있습니다: $artifact_path"
      exit 1
      ;;
    "$BUILD_MARKER"|README.md) continue ;;
  esac
  source_path="$SRC/$artifact_path"
  if [ ! -f "$source_path" ] || [ -L "$source_path" ]; then
    echo "✗ 배포 allowlist 파일이 없거나 regular file이 아닙니다: $source_path"
    exit 1
  fi
done < "$ARTIFACT_MANIFEST"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"

assert_replaceable() {
  local target="$1"

  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return
  fi

  if [ -L "$target" ] || [ ! -d "$target" ]; then
    echo "✗ 기존 산출물이 안전한 디렉토리가 아닙니다: $target"
    exit 1
  fi

  if [ -L "$target/$BUILD_MARKER" ] || [ ! -f "$target/$BUILD_MARKER" ] ||
    [ "$(cat "$target/$BUILD_MARKER")" != "$BUILD_MARKER_CONTENT" ]; then
    echo "✗ 소유권 marker가 없는 기존 디렉토리는 변경하지 않습니다: $target"
    exit 1
  fi
}

for variant in cli app; do
  assert_replaceable "$OUT/$variant"
done

STAGING="$(mktemp -d "$OUT/.ai-session-kit-build.XXXXXX")"
cleanup() {
  rm -rf -- "$STAGING"
}
trap cleanup EXIT

for variant in cli app; do
  staged="$STAGING/$variant"
  mkdir -p "$staged"
  while IFS= read -r artifact_path || [ -n "$artifact_path" ]; do
    case "$artifact_path" in
      "$BUILD_MARKER"|README.md) continue ;;
      */*) mkdir -p "$staged/${artifact_path%/*}" ;;
    esac
    cp -p "$SRC/$artifact_path" "$staged/$artifact_path"
  done < "$ARTIFACT_MANIFEST"
  unexpected_node="$(find "$staged" ! -type f ! -type d -print -quit)"
  if [ -n "$unexpected_node" ]; then
    echo "✗ 배포 산출물에 regular file/directory가 아닌 항목이 있습니다: $unexpected_node"
    exit 1
  fi
  cp "$SRC/readmes/README-$variant.md" "$staged/README.md"
  printf '%s\n' "$BUILD_MARKER_CONTENT" > "$staged/$BUILD_MARKER"
  unexpected_node="$(find "$staged" ! -type f ! -type d -print -quit)"
  if [ -n "$unexpected_node" ]; then
    echo "✗ 배포 산출물에 regular file/directory가 아닌 항목이 있습니다: $unexpected_node"
    exit 1
  fi
done

for variant in cli app; do
  target="$OUT/$variant"
  assert_replaceable "$target"
  if [ -d "$target" ]; then
    rm -rf -- "$target"
  fi
  mv "$STAGING/$variant" "$target"
  echo "✓ $target"
done

printf '\n빌드 완료. 배포 zip 만들기:\n  cd '
printf '%q' "$OUT"
printf ' && zip -rq ai-session-kit-cli.zip cli && zip -rq ai-session-kit-app.zip app\n'
