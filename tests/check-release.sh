#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="${AI_SESSION_KIT_TEST_BASH:-/bin/bash}"
cd "$REPO_ROOT"

while IFS= read -r -d '' shell_file; do
  "$BASH_BIN" -n "$shell_file"
done < <(
  find . -type f -name '*.sh' \
    -not -path './.git/*' \
    -not -path './dist/*' \
    -not -path './node_modules/*' \
    -print0
)

while IFS= read -r -d '' json_file; do
  python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$json_file"
done < <(
  find . -type f -name '*.json' \
    -not -path './.git/*' \
    -not -path './dist/*' \
    -not -path './node_modules/*' \
    -print0
)

while IFS= read -r -d '' python_file; do
  python3 -c 'import pathlib, sys; source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"); compile(source, sys.argv[1], "exec")' "$python_file"
done < <(
  find . -type f -name '*.py' \
    -not -path './.git/*' \
    -not -path './dist/*' \
    -not -path './node_modules/*' \
    -print0
)

while IFS= read -r -d '' powershell_file; do
  if [ "$(od -An -tx1 -N3 "$powershell_file" | tr -d '[:space:]')" != 'efbbbf' ]; then
    echo "✗ Windows PowerShell 5.1 호환 UTF-8 BOM이 없습니다: $powershell_file"
    exit 1
  fi
done < <(
  find . -type f -name '*.ps1' \
    -not -path './.git/*' \
    -not -path './dist/*' \
    -not -path './node_modules/*' \
    -print0
)

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'
AI_SESSION_KIT_TEST_BASH="$BASH_BIN" "$BASH_BIN" tests/installer-hooks.sh

CHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-session-kit-check.XXXXXX")"
cleanup() {
  rm -rf -- "$CHECK_TMP"
}
trap cleanup EXIT

mkdir -p "$CHECK_TMP/unowned/app"
printf 'keep\n' > "$CHECK_TMP/unowned/app/sentinel.txt"
if "$BASH_BIN" build.sh "$CHECK_TMP/unowned" > "$CHECK_TMP/unowned.log" 2>&1; then
  echo "✗ marker가 없는 기존 app/ 디렉토리를 빌드가 거부하지 않았습니다."
  exit 1
fi
grep -qx 'keep' "$CHECK_TMP/unowned/app/sentinel.txt"
test ! -e "$CHECK_TMP/unowned/cli"

mkdir -p "$CHECK_TMP/protected" "$CHECK_TMP/symlinked"
printf 'keep\n' > "$CHECK_TMP/protected/sentinel.txt"
ln -s "$CHECK_TMP/protected" "$CHECK_TMP/symlinked/cli"
if "$BASH_BIN" build.sh "$CHECK_TMP/symlinked" > "$CHECK_TMP/symlinked.log" 2>&1; then
  echo "✗ symlink cli/ 디렉토리를 빌드가 거부하지 않았습니다."
  exit 1
fi
test -L "$CHECK_TMP/symlinked/cli"
grep -qx 'keep' "$CHECK_TMP/protected/sentinel.txt"
test ! -e "$CHECK_TMP/symlinked/app"

mkdir -p "$CHECK_TMP/marker-target" "$CHECK_TMP/marker-symlink/cli"
printf 'ai-session-kit-build-v1\n' > "$CHECK_TMP/marker-target/marker"
ln -s "$CHECK_TMP/marker-target/marker" "$CHECK_TMP/marker-symlink/cli/.ai-session-kit-build"
printf 'keep\n' > "$CHECK_TMP/marker-symlink/cli/sentinel.txt"
if "$BASH_BIN" build.sh "$CHECK_TMP/marker-symlink" > "$CHECK_TMP/marker-symlink.log" 2>&1; then
  echo "✗ symlink marker가 있는 foreign cli/를 빌드가 거부하지 않았습니다."
  exit 1
fi
grep -qx 'keep' "$CHECK_TMP/marker-symlink/cli/sentinel.txt"

ln -s "$REPO_ROOT" "$CHECK_TMP/source-alias"
if "$BASH_BIN" build.sh "$CHECK_TMP/source-alias" > "$CHECK_TMP/source-alias.log" 2>&1; then
  echo "✗ 원본 폴더를 가리키는 출력 symlink를 빌드가 거부하지 않았습니다."
  exit 1
fi
test ! -e "$REPO_ROOT/cli"
test ! -e "$REPO_ROOT/app"

mkdir -p "$CHECK_TMP/default-source"
rsync -a \
  --exclude '/.git' \
  --exclude '/dist/' \
  --exclude '/node_modules/' \
  "$REPO_ROOT/" "$CHECK_TMP/default-source/"

if "$BASH_BIN" "$CHECK_TMP/default-source/build.sh" "$CHECK_TMP/default-source/skills" > "$CHECK_TMP/source-overlap.log" 2>&1; then
  echo "✗ source subtree를 출력디렉토리로 허용했습니다."
  exit 1
fi
test ! -e "$CHECK_TMP/default-source/skills/cli"

if "$BASH_BIN" "$CHECK_TMP/default-source/build.sh" "$CHECK_TMP/default-source/out[1]" > "$CHECK_TMP/pattern-overlap.log" 2>&1; then
  echo "✗ pattern 문자가 있는 source-internal 출력디렉토리를 허용했습니다."
  exit 1
fi
test ! -e "$CHECK_TMP/default-source/out[1]"

ln -s /etc/hosts "$CHECK_TMP/default-source/skills/unexpected-hosts-link"
if "$BASH_BIN" "$CHECK_TMP/default-source/build.sh" > "$CHECK_TMP/artifact-symlink.log" 2>&1; then
  echo "✗ source symlink가 포함된 release artifact를 허용했습니다."
  exit 1
fi
rm "$CHECK_TMP/default-source/skills/unexpected-hosts-link"

printf 'keep-marker-target\n' > "$CHECK_TMP/marker-target-file"
ln -s "$CHECK_TMP/marker-target-file" "$CHECK_TMP/default-source/.ai-session-kit-build"
if "$BASH_BIN" "$CHECK_TMP/default-source/build.sh" > "$CHECK_TMP/source-marker-symlink.log" 2>&1; then
  echo "✗ source build marker symlink를 허용했습니다."
  exit 1
fi
grep -qx 'keep-marker-target' "$CHECK_TMP/marker-target-file"
rm "$CHECK_TMP/default-source/.ai-session-kit-build"

mv "$CHECK_TMP/default-source/readmes/README-cli.md" "$CHECK_TMP/default-source/readmes/README-cli.original"
printf 'keep-readme-target\n' > "$CHECK_TMP/readme-target-file"
ln -s "$CHECK_TMP/readme-target-file" "$CHECK_TMP/default-source/readmes/README-cli.md"
if "$BASH_BIN" "$CHECK_TMP/default-source/build.sh" > "$CHECK_TMP/source-readme-symlink.log" 2>&1; then
  echo "✗ symlink 배포 README를 허용했습니다."
  exit 1
fi
grep -qx 'keep-readme-target' "$CHECK_TMP/readme-target-file"
rm "$CHECK_TMP/default-source/readmes/README-cli.md"
mv "$CHECK_TMP/default-source/readmes/README-cli.original" "$CHECK_TMP/default-source/readmes/README-cli.md"

printf 'gitdir: /Users/example/private/worktrees/ex-brain\n' > "$CHECK_TMP/default-source/.git"
printf 'API_TOKEN=private-build-secret\n' > "$CHECK_TMP/default-source/.env"
"$BASH_BIN" "$CHECK_TMP/default-source/build.sh"
ARTIFACTS="$CHECK_TMP/default-source/dist"
test -d "$ARTIFACTS/cli"
test -d "$ARTIFACTS/app"
for variant in cli app; do
  test ! -e "$ARTIFACTS/$variant/.git"
  test ! -e "$ARTIFACTS/$variant/.env"
  if grep -R -Fq -- '/Users/example/private/worktrees/ex-brain' "$ARTIFACTS/$variant"; then
    echo "✗ worktree .git의 local path가 artifact에 포함됐습니다."
    exit 1
  fi
  if grep -R -Fq -- 'private-build-secret' "$ARTIFACTS/$variant"; then
    echo "✗ source의 untracked secret이 artifact에 포함됐습니다."
    exit 1
  fi
done

touch "$ARTIFACTS/cli/stale-file"
"$BASH_BIN" "$CHECK_TMP/default-source/build.sh"
test ! -e "$ARTIFACTS/cli/stale-file"

for variant in cli app; do
  unexpected_node="$(find "$ARTIFACTS/$variant" ! -type f ! -type d -print -quit)"
  if [ -n "$unexpected_node" ]; then
    echo "✗ artifact에 regular file/directory가 아닌 항목이 있습니다: $unexpected_node"
    exit 1
  fi
  (
    cd "$ARTIFACTS/$variant"
    find . -type f -print | sed 's#^\./##' | LC_ALL=C sort
  ) > "$CHECK_TMP/$variant-manifest.txt"
  diff -u tests/expected-artifact-manifest.txt "$CHECK_TMP/$variant-manifest.txt"
  cmp "readmes/README-$variant.md" "$ARTIFACTS/$variant/README.md"
  cmp "vault-template/90.private/README.md" "$ARTIFACTS/$variant/vault-template/90.private/README.md"
done

(
  cd "$CHECK_TMP/default-source"
  find skills -type f -print | LC_ALL=C sort
) > "$CHECK_TMP/source-skills-manifest.txt"
(
  cd "$ARTIFACTS/cli"
  find skills -type f -print | LC_ALL=C sort
) > "$CHECK_TMP/artifact-skills-manifest.txt"
if ! diff -u "$CHECK_TMP/source-skills-manifest.txt" "$CHECK_TMP/artifact-skills-manifest.txt"; then
  echo "✗ source skill 파일과 실제 CLI artifact가 다릅니다."
  exit 1
fi

artifact_user_home="$CHECK_TMP/artifact-install-home"
artifact_vault="$CHECK_TMP/artifact-install-vault"
mkdir -p "$artifact_user_home"
if ! AI_SESSION_KIT_USER_HOME="$artifact_user_home" \
  "$BASH_BIN" "$ARTIFACTS/cli/setup.sh" "$artifact_vault" > "$CHECK_TMP/artifact-setup.log" 2>&1; then
  sed -n '1,240p' "$CHECK_TMP/artifact-setup.log" >&2
  echo "✗ 실제 CLI artifact 설치 smoke test가 실패했습니다."
  exit 1
fi
while IFS= read -r -d '' artifact_skill_dir; do
  skill_name="${artifact_skill_dir##*/}"
  for skill_root in "$artifact_user_home/.claude/skills" "$artifact_user_home/.agents/skills"; do
    skill_link="$skill_root/$skill_name"
    if [ ! -L "$skill_link" ] || [ ! -e "$skill_link" ]; then
      echo "✗ 실제 CLI artifact가 skill을 설치하지 않았습니다: $skill_name"
      exit 1
    fi
  done
done < <(find "$ARTIFACTS/cli/skills" -mindepth 1 -maxdepth 1 -type d -print0)

if ! AI_SESSION_KIT_USER_HOME="$artifact_user_home" \
  "$BASH_BIN" "$ARTIFACTS/cli/uninstall.sh" > "$CHECK_TMP/artifact-uninstall.log" 2>&1; then
  sed -n '1,240p' "$CHECK_TMP/artifact-uninstall.log" >&2
  echo "✗ 실제 CLI artifact 제거 smoke test가 실패했습니다."
  exit 1
fi
while IFS= read -r -d '' artifact_skill_dir; do
  skill_name="${artifact_skill_dir##*/}"
  for skill_root in "$artifact_user_home/.claude/skills" "$artifact_user_home/.agents/skills"; do
    skill_link="$skill_root/$skill_name"
    if [ -e "$skill_link" ] || [ -L "$skill_link" ]; then
      echo "✗ 실제 CLI artifact 제거 뒤 skill 연결이 남았습니다: $skill_name"
      exit 1
    fi
  done
done < <(find "$ARTIFACTS/cli/skills" -mindepth 1 -maxdepth 1 -type d -print0)

workflow=.github/workflows/verify.yml
test ! -e .github/workflows/release.yml
test "$(grep -Fc -- 'runs-on: windows-latest' "$workflow")" -eq 1
grep -Fq -- 'tests\windows-installer.ps1' "$workflow"
test "$(grep -Fc -- 'runs-on: macos-latest' "$workflow")" -eq 1
grep -Fq -- 'shell: /bin/bash {0}' "$workflow"
grep -Fq -- 'brew install jq' "$workflow"
grep -Fq -- 'run: /bin/bash tests/check-release.sh' "$workflow"
grep -Fq -- "if: github.event_name == 'push' && github.ref == 'refs/heads/main'" "$workflow"
grep -Fq -- 'needs: [release-checks, macos-native, windows-native]' "$workflow"
grep -Fq -- 'concurrency: ${{ github.workflow }}-${{ github.ref }}' "$workflow"
grep -Fq -- 'contents: write' "$workflow"
grep -Fq -- 'pull-requests: write' "$workflow"
grep -Fq -- '"commandWindows": "__SESSION_HOOK_WINDOWS_COMMAND__"' codex-hooks-snippet.json
grep -Fq -- '"commandWindows": "__PII_HOOK_WINDOWS_COMMAND__"' codex-hooks-snippet.json

grep -Fq -- '--target "$GITHUB_SHA"' "$workflow"
grep -Fq -- '--json isDraft,targetCommitish,assets' "$workflow"
grep -Fq -- '.targetCommitish == $tagCommit' "$workflow"
grep -Fq -- '.name == $cli and .size > 0' "$workflow"
grep -Fq -- '.name == $app and .size > 0' "$workflow"
grep -Fq -- 'EXISTING_TAG_COMMIT" != "$GITHUB_SHA"' "$workflow"
if [ "$(grep -Fc -- 'git rev-parse --verify "refs/tags/$TAG^{commit}"' "$workflow")" -ne 2 ]; then
  echo "✗ release workflow의 tag 존재 확인이 fail-closed 하지 않습니다."
  exit 1
fi
missing_tag="v0.0.0-ai-session-kit-missing-tag"
missing_tag_commit="$(git rev-parse --verify "refs/tags/$missing_tag^{commit}" 2>/dev/null || true)"
if [ -n "$missing_tag_commit" ]; then
  echo "✗ 없는 release tag를 존재하는 commit으로 잘못 해석했습니다: $missing_tag_commit"
  exit 1
fi
if grep -Fq -- '.targetCommitish == $sha' "$workflow"; then
  echo "✗ 기존 release를 현재 workflow commit과 비교해 후속 main push를 실패시킵니다."
  exit 1
fi

release_fixture="$(jq -n '{
  isDraft: false,
  targetCommitish: "commit-a",
  assets: [
    {name: "ai-session-kit-cli-v1.0.0.zip", size: 10},
    {name: "ai-session-kit-app-v1.0.0.zip", size: 20}
  ]
}')"
printf '%s' "$release_fixture" | jq -e \
  --arg tagCommit commit-a \
  --arg cli ai-session-kit-cli-v1.0.0.zip \
  --arg app ai-session-kit-app-v1.0.0.zip '
    .isDraft == false and
    .targetCommitish == $tagCommit and
    any(.assets[]; .name == $cli and .size > 0) and
    any(.assets[]; .name == $app and .size > 0)
  ' >/dev/null

unexpected_cache="$(
  find "$ARTIFACTS" \
    \( -type d -name '__pycache__' -o -type f \( -name '*.pyc' -o -name '*.pyo' \) \) \
    -print -quit
)"
if [ -n "$unexpected_cache" ]; then
  echo "✗ Python cache가 산출물에 포함됐습니다: $unexpected_cache"
  exit 1
fi

PYTHONDONTWRITEBYTECODE=1 python3 \
  "$ARTIFACTS/cli/scripts/kb_lint.py" \
  "$ARTIFACTS/cli/vault-template" \
  --check

echo "✓ release checks passed"
