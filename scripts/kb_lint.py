#!/usr/bin/env python3
"""지식 vault 위생 검사: 깨진 링크, INDEX 누락, 폴더-status 불일치.

사용:
    python3 kb_lint.py [vault경로] [--check]

vault 경로를 생략하면 스크립트 위치({vault}/_kit/scripts/) 기준으로 자동 인식.
--check: 문제가 있으면 exit code 1 (자동화용). 없으면 항상 0.
결과 요약 한 줄을 {vault}/_kit/lint-latest.txt 에 남긴다 (세션 시작 훅이 주입).
"""

from __future__ import annotations

import re
import sys
from datetime import date
from pathlib import Path

WIKI_ZONES = ["10.notes", "20.work"]
TASKS_DIR = "00.memory/tasks"
TASK_STATUSES = ["todo", "in-progress", "done"]
SKIP_PARTS = {"90.private", "_kit", ".git", ".obsidian", "assets", "node_modules"}

LINK_RE = re.compile(r"\]\(([^)#\s]+\.md)(?:#[^)]*)?\)")
CODE_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
STATUS_RE = re.compile(r"^status:\s*(\S+)", re.MULTILINE)


def resolve_vault(argv: list[str]) -> Path:
    for arg in argv[1:]:
        if not arg.startswith("-"):
            return Path(arg).expanduser().resolve()
    return Path(__file__).resolve().parent.parent.parent


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


def check_links(vault: Path, files: list[Path]) -> list[str]:
    errors = []
    for f in files:
        text = INLINE_CODE_RE.sub("", CODE_FENCE_RE.sub("", read(f)))
        for m in LINK_RE.finditer(text):
            target = m.group(1)
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            # vault 루트 기준이 정본, 파일 기준은 legacy 허용
            if (vault / target).exists() or (f.parent / target).exists():
                continue
            errors.append(f"broken-link: {f.relative_to(vault)} → {target}")
    return errors


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
        for p in sorted(zdir.rglob("*.md")):
            if p.name == "INDEX.md" or SKIP_PARTS.intersection(p.relative_to(vault).parts):
                continue
            if p.name not in index_text:
                errors.append(f"unindexed: {p.relative_to(vault)} — {zone}/INDEX.md에 없음")
    return errors


def check_task_status(vault: Path) -> list[str]:
    errors = []
    for status in TASK_STATUSES:
        d = vault / TASKS_DIR / status
        if not d.is_dir():
            continue
        for p in sorted(d.glob("*.md")):
            m = STATUS_RE.search(read(p)[:500])
            if m and m.group(1) != status:
                errors.append(
                    f"status-mismatch: {p.relative_to(vault)} — frontmatter는 status: {m.group(1)}"
                )
    return errors


def main() -> int:
    vault = resolve_vault(sys.argv)
    if not (vault / TASKS_DIR).is_dir():
        print(f"✗ vault가 아닌 것 같습니다 (없음: {vault / TASKS_DIR})")
        return 1

    files = md_files(vault)
    errors = check_links(vault, files) + check_index(vault) + check_task_status(vault)

    for e in errors:
        print(f"✗ {e}")
    summary = f"kb-lint {date.today().isoformat()}: ERR {len(errors)}"
    summary += " — 모두 정상" if not errors else " — 상세는 kb_lint.py 재실행"
    print(summary)

    latest = vault / "_kit" / "lint-latest.txt"
    try:
        latest.parent.mkdir(parents=True, exist_ok=True)
        latest.write_text(summary + "\n", encoding="utf-8")
    except OSError:
        pass

    return 1 if errors and "--check" in sys.argv else 0


if __name__ == "__main__":
    sys.exit(main())
