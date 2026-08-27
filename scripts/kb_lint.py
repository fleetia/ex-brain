#!/usr/bin/env python3
"""지식 vault 위생 검사: 깨진 링크, INDEX 누락, 폴더-status 불일치.

사용:
    python3 kb_lint.py [vault경로] [--check]

vault 경로를 생략하면 스크립트 위치({vault}/_kit/scripts/) 기준으로 자동 인식.
--check: 문제가 있으면 exit code 1 (자동화용). 없으면 항상 0.
AI_SESSION_KIT_STATE_DIR가 지정되면 결과 요약 한 줄을 그 local state의
lint-latest.txt에 남긴다 (세션 시작 훅이 주입).
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
from datetime import date
from pathlib import Path
from urllib.parse import unquote

WIKI_ZONES = ["10.notes", "20.work"]
TASKS_DIR = "00.memory/tasks"
TASK_STATUSES = ["todo", "in-progress", "done", "cancelled"]
SKIP_PARTS = {"90.private", "_kit", ".git", ".obsidian", "assets", "node_modules"}
REQUIRED_FILES = ["CLAUDE.md", "AGENTS.md", "10.notes/INDEX.md", "20.work/INDEX.md"]
ARCHIVED_HEADING = "## Archived"

LINK_RE = re.compile(
    r"\]\(\s*(?:<([^>#\n]+?\.md)(?:#[^>\n]*)?>|([^\n)#]+?\.md)(?:#[^)\n]*)?)\s*\)"
)
CODE_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
STATUS_RE = re.compile(r"^status:\s*(\S+)", re.MULTILINE)
FRONTMATTER_RE = re.compile(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)", re.DOTALL)
SOURCE_REVISION_RE = re.compile(r"git:(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\Z")
WORKING_COPY_STATES = {"clean", "uncommitted", "unknown"}
WIKI_STATUSES = {"active", "archived"}


def resolve_vault(argv: list[str]) -> Path:
    for arg in argv[1:]:
        if not arg.startswith("-"):
            return Path(arg).expanduser().resolve()
    script = Path(__file__).resolve()
    if script.parent.name == "scripts" and script.parent.parent.name == "_kit":
        return script.parent.parent.parent
    raise ValueError("source checkout에서는 vault 경로를 명시하세요")


def md_files(vault: Path) -> list[Path]:
    return [
        p
        for p in sorted(vault.rglob("*.md"))
        if not SKIP_PARTS.intersection(p.relative_to(vault).parts)
    ]


def read(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return ""


def get_status(p: Path) -> str | None:
    frontmatter = FRONTMATTER_RE.search(read(p))
    if not frontmatter:
        return None
    match = STATUS_RE.search(frontmatter.group(1))
    return match.group(1) if match else None


def get_frontmatter_value(text: str, key: str) -> str | None:
    frontmatter = FRONTMATTER_RE.search(text)
    if not frontmatter:
        return None
    match = re.search(rf"^{re.escape(key)}:\s*(.*?)\s*$", frontmatter.group(1), re.MULTILINE)
    if not match:
        return None
    value = match.group(1)
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def without_code(text: str) -> str:
    return INLINE_CODE_RE.sub("", CODE_FENCE_RE.sub("", text))


def link_targets(text: str) -> list[str]:
    return [unquote(match.group(1) or match.group(2)).strip() for match in LINK_RE.finditer(text)]


def check_structure(vault: Path) -> list[str]:
    errors = []
    for relative_path in REQUIRED_FILES:
        if not (vault / relative_path).is_file():
            errors.append(f"missing: {relative_path}")
    for status in TASK_STATUSES:
        relative_path = f"{TASKS_DIR}/{status}"
        if not (vault / relative_path).is_dir():
            errors.append(f"missing: {relative_path}/")
    return errors


def check_links(vault: Path, files: list[Path]) -> list[str]:
    errors = []
    for f in files:
        text = without_code(read(f))
        for target in link_targets(text):
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            # vault 루트 기준이 정본, 파일 기준은 legacy 허용
            if (vault / target).exists() or (f.parent / target).exists():
                continue
            errors.append(f"broken-link: {f.relative_to(vault)} → {target}")
    return errors


def check_external_symlinks(vault: Path, files: list[Path]) -> list[str]:
    errors = []
    resolved_vault = vault.resolve()
    for p in files:
        if not p.is_symlink():
            continue
        try:
            p.resolve(strict=True).relative_to(resolved_vault)
        except (OSError, ValueError):
            errors.append(f"external-symlink: {p.relative_to(vault)}")
    return errors


def resolved_internal_links(source: Path, text: str, vault: Path) -> set[Path]:
    targets = set()
    for target in link_targets(text):
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        for candidate in (vault / target, source.parent / target):
            if candidate.is_file():
                targets.add(candidate.resolve())
    return targets


def has_index_link(index: Path, text: str, document: Path, vault: Path) -> bool:
    document_path = document.resolve()
    for target in link_targets(text):
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        candidates = ((vault / target).resolve(), (index.parent / target).resolve())
        if document_path in candidates:
            return True
    return False


def check_index(vault: Path) -> list[str]:
    errors = []
    for zone in WIKI_ZONES:
        zdir = vault / zone
        if not zdir.is_dir():
            continue
        index = zdir / "INDEX.md"
        if not index.exists():
            errors.append(f"no-index: {zone}/INDEX.md 없음")
            continue
        index_text = read(index)
        active_text, separator, archived_text = index_text.partition(ARCHIVED_HEADING)
        for p in sorted(zdir.rglob("*.md")):
            if p.name == "INDEX.md" or SKIP_PARTS.intersection(p.relative_to(vault).parts):
                continue
            if get_status(p) == "archived":
                if not separator:
                    errors.append(f"no-archived-section: {zone}/INDEX.md")
                elif not has_index_link(index, archived_text, p, vault):
                    errors.append(
                        f"unindexed-archived: {p.relative_to(vault)} — {zone}/INDEX.md Archived에 없음"
                    )
                if has_index_link(index, active_text, p, vault):
                    errors.append(
                        f"archived-in-active-index: {p.relative_to(vault)} — 현재 문서 목록에서 제거 필요"
                    )
                continue
            if not has_index_link(index, active_text, p, vault):
                errors.append(f"unindexed: {p.relative_to(vault)} — {zone}/INDEX.md에 없음")
            if has_index_link(index, archived_text, p, vault):
                errors.append(
                    f"active-in-archived-index: {p.relative_to(vault)} — Archived에서 현재 문서로 이동 필요"
                )
    return errors


def check_task_status(vault: Path) -> list[str]:
    errors = []
    for status in TASK_STATUSES:
        d = vault / TASKS_DIR / status
        if not d.is_dir():
            continue
        for p in sorted(d.glob("*.md")):
            document_status = get_status(p)
            if document_status is None:
                errors.append(f"missing-status: {p.relative_to(vault)}")
            elif document_status not in TASK_STATUSES:
                errors.append(
                    f"invalid-status: {p.relative_to(vault)} — 허용값: {', '.join(TASK_STATUSES)}"
                )
            elif document_status != status:
                errors.append(
                    f"status-mismatch: {p.relative_to(vault)} — frontmatter는 status: {document_status}"
                )
    return errors


def check_task_source_state(vault: Path) -> list[str]:
    errors = []
    for status in TASK_STATUSES:
        directory = vault / TASKS_DIR / status
        if not directory.is_dir():
            continue
        for path in sorted(directory.glob("*.md")):
            text = read(path)
            relative_path = path.relative_to(vault)
            source_revision = get_frontmatter_value(text, "source-revision")
            working_copy_state = get_frontmatter_value(text, "working-copy-state")

            if source_revision is not None and not SOURCE_REVISION_RE.fullmatch(source_revision):
                errors.append(f"invalid-source-revision: {relative_path}")
            if source_revision is not None and working_copy_state is None:
                errors.append(f"missing-working-copy-state: {relative_path}")
            if working_copy_state is None:
                continue
            if working_copy_state not in WORKING_COPY_STATES:
                allowed = ", ".join(sorted(WORKING_COPY_STATES))
                errors.append(
                    f"invalid-working-copy-state: {relative_path} — 허용값: {allowed}"
                )
                continue
            if working_copy_state == "clean" and not source_revision:
                errors.append(f"missing-source-revision: {relative_path}")
            if working_copy_state == "uncommitted":
                if not re.search(r"^## 작업 사본\s*$", text, re.MULTILINE):
                    errors.append(f"missing-working-copy-section: {relative_path}")
    return errors


def check_wiki_status(vault: Path) -> list[str]:
    errors = []
    for zone in WIKI_ZONES:
        zone_dir = vault / zone
        if not zone_dir.is_dir():
            continue
        for p in sorted(zone_dir.rglob("*.md")):
            if p.name == "INDEX.md" or SKIP_PARTS.intersection(p.relative_to(vault).parts):
                continue
            document_status = get_status(p)
            if document_status is None:
                errors.append(f"missing-status: {p.relative_to(vault)}")
            elif document_status not in WIKI_STATUSES:
                allowed = ", ".join(sorted(WIKI_STATUSES))
                errors.append(f"invalid-status: {p.relative_to(vault)} — 허용값: {allowed}")
    return errors


def check_active_links_to_archived(vault: Path) -> list[str]:
    archived = {
        p.resolve(): p.relative_to(vault)
        for zone in WIKI_ZONES
        for p in (vault / zone).rglob("*.md")
        if p.name != "INDEX.md"
        and not SKIP_PARTS.intersection(p.relative_to(vault).parts)
        and get_status(p) == "archived"
    }
    if not archived:
        return []

    errors = []
    for zone in WIKI_ZONES:
        for p in sorted((vault / zone).rglob("*.md")):
            if (
                p.name == "INDEX.md"
                or SKIP_PARTS.intersection(p.relative_to(vault).parts)
                or get_status(p) != "active"
            ):
                continue
            for target in sorted(resolved_internal_links(p, without_code(read(p)), vault)):
                if target in archived:
                    errors.append(
                        f"active-links-archived: {p.relative_to(vault)} → {archived[target]}"
                    )
    return errors


def main() -> int:
    try:
        vault = resolve_vault(sys.argv)
    except ValueError as error:
        print(f"✗ {error}")
        return 1
    if not vault.is_dir() or not (vault / TASKS_DIR).is_dir():
        print(f"✗ vault가 아닌 것 같습니다 (없음: {vault / TASKS_DIR})")
        return 1

    files = md_files(vault)
    structure_errors = check_structure(vault)
    errors = (
        structure_errors
        + check_links(vault, files)
        + check_external_symlinks(vault, files)
        + check_index(vault)
        + check_task_status(vault)
        + check_task_source_state(vault)
        + check_wiki_status(vault)
        + check_active_links_to_archived(vault)
    )

    for e in errors:
        print(f"✗ {e}")
    summary = f"kb-lint {date.today().isoformat()}: ERR {len(errors)}"
    summary += " — 모두 정상" if not errors else " — 상세는 kb_lint.py 재실행"
    print(summary)

    state_dir_raw = os.environ.get("AI_SESSION_KIT_STATE_DIR")
    if not structure_errors and state_dir_raw:
        state_dir = Path(state_dir_raw).expanduser()
        latest = state_dir / "lint-latest.txt"
        temporary = None
        try:
            resolved_state = state_dir.resolve(strict=True)
            if state_dir.is_symlink() or latest.is_symlink() or not resolved_state.is_dir():
                raise OSError("unsafe state directory")
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=resolved_state,
                prefix=".lint-latest.",
                delete=False,
            ) as temporary_file:
                temporary_file.write(summary + "\n")
                temporary = Path(temporary_file.name)
            temporary.replace(resolved_state / "lint-latest.txt")
        except OSError:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    return 1 if errors and "--check" in sys.argv else 0


if __name__ == "__main__":
    sys.exit(main())
