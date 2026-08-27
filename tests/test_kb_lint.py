from __future__ import annotations

import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("kb_lint", ROOT / "scripts" / "kb_lint.py")
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("kb_lint.py를 불러올 수 없습니다")
KB_LINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(KB_LINT)


class KnowledgeBaseLintTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.vault = Path(self.temporary_directory.name) / "Knowledge Base"
        shutil.copytree(ROOT / "vault-template", self.vault)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_template_is_valid_and_entrypoints_match(self) -> None:
        self.assertEqual(KB_LINT.check_structure(self.vault), [])
        self.assertEqual(KB_LINT.check_index(self.vault), [])
        self.assertEqual(
            (self.vault / "CLAUDE.md").read_text(encoding="utf-8"),
            (self.vault / "AGENTS.md").read_text(encoding="utf-8"),
        )

    def test_private_and_kit_documents_are_not_collected(self) -> None:
        (self.vault / "90.private" / "secret.md").write_text("secret", encoding="utf-8")
        kit = self.vault / "_kit"
        kit.mkdir()
        (kit / "internal.md").write_text("internal", encoding="utf-8")

        relative_paths = {path.relative_to(self.vault).as_posix() for path in KB_LINT.md_files(self.vault)}

        self.assertNotIn("90.private/secret.md", relative_paths)
        self.assertNotIn("_kit/internal.md", relative_paths)

    def test_external_markdown_symlink_is_reported_without_crashing(self) -> None:
        outside = Path(self.temporary_directory.name) / "outside.md"
        outside.write_text("---\nstatus: archived\n---\n", encoding="utf-8")
        linked = self.vault / "10.notes" / "external.md"
        linked.symlink_to(outside)
        active = self.vault / "20.work" / "current.md"
        active.write_text(
            "---\nstatus: active\n---\n\n[외부 문서](10.notes/external.md)\n",
            encoding="utf-8",
        )
        self.assertEqual(
            KB_LINT.check_external_symlinks(self.vault, KB_LINT.md_files(self.vault)),
            ["external-symlink: 10.notes/external.md"],
        )
        self.assertEqual(
            KB_LINT.check_active_links_to_archived(self.vault),
            ["active-links-archived: 20.work/current.md → 10.notes/external.md"],
        )

    def test_missing_codex_entrypoint_is_reported(self) -> None:
        (self.vault / "AGENTS.md").unlink()

        self.assertIn("missing: AGENTS.md", KB_LINT.check_structure(self.vault))

    def test_source_checkout_requires_an_explicit_vault_path(self) -> None:
        with self.assertRaisesRegex(ValueError, "vault 경로를 명시"):
            KB_LINT.resolve_vault(["kb_lint.py"])

    def test_archived_document_must_be_in_archived_index_section(self) -> None:
        document = self.vault / "10.notes" / "old.md"
        document.write_text("---\nstatus: archived\n---\n", encoding="utf-8")
        index = self.vault / "10.notes" / "INDEX.md"
        index.write_text(
            "# 10.notes\n\n## 문서\n\n- [옛 문서](10.notes/old.md)\n\n## Archived\n",
            encoding="utf-8",
        )

        errors = KB_LINT.check_index(self.vault)

        self.assertTrue(any(error.startswith("unindexed-archived:") for error in errors))
        self.assertTrue(any(error.startswith("archived-in-active-index:") for error in errors))

        index.write_text(
            "# 10.notes\n\n## 문서\n\n## Archived\n\n- [옛 문서](10.notes/old.md)\n",
            encoding="utf-8",
        )
        self.assertEqual(KB_LINT.check_index(self.vault), [])

    def test_index_requires_an_exact_document_link(self) -> None:
        document = self.vault / "10.notes" / "old.md"
        document.write_text("---\nstatus: active\n---\n", encoding="utf-8")
        similarly_named = self.vault / "10.notes" / "not-old.md"
        similarly_named.write_text("---\nstatus: active\n---\n", encoding="utf-8")
        index = self.vault / "10.notes" / "INDEX.md"
        index.write_text(
            "# 10.notes\n\n## 문서\n\n- [다른 문서](10.notes/not-old.md)\n\n## Archived\n",
            encoding="utf-8",
        )

        errors = KB_LINT.check_index(self.vault)

        self.assertTrue(any(error.startswith("unindexed: 10.notes/old.md") for error in errors))

    def test_links_support_raw_and_percent_encoded_spaces(self) -> None:
        document = self.vault / "10.notes" / "회의 기록.md"
        document.write_text("---\nstatus: active\n---\n", encoding="utf-8")
        index = self.vault / "10.notes" / "INDEX.md"
        index.write_text(
            "# 10.notes\n\n## 문서\n\n- [회의](<10.notes/회의 기록.md>)\n\n## Archived\n",
            encoding="utf-8",
        )
        active = self.vault / "20.work" / "current.md"
        active.write_text(
            "---\nstatus: active\n---\n\n"
            "[raw](10.notes/회의 기록.md)\n"
            "[encoded](10.notes/회의%20기록.md)\n",
            encoding="utf-8",
        )
        (self.vault / "20.work" / "INDEX.md").write_text(
            "# 20.work\n\n## 문서\n\n- [현재](20.work/current.md)\n\n## Archived\n",
            encoding="utf-8",
        )

        self.assertEqual(KB_LINT.check_index(self.vault), [])
        self.assertEqual(KB_LINT.check_links(self.vault, [active]), [])

    def test_cancelled_task_status_must_match_its_folder(self) -> None:
        task = self.vault / "00.memory" / "tasks" / "cancelled" / "task.md"
        task.write_text("---\nstatus: done\n---\n", encoding="utf-8")

        errors = KB_LINT.check_task_status(self.vault)

        self.assertEqual(len(errors), 1)
        self.assertTrue(errors[0].startswith("status-mismatch:"))

    def test_task_status_is_required_and_must_be_known(self) -> None:
        missing = self.vault / "00.memory" / "tasks" / "todo" / "missing.md"
        missing.write_text("---\ntitle: 상태 없음\n---\n", encoding="utf-8")
        invalid = self.vault / "00.memory" / "tasks" / "todo" / "invalid.md"
        invalid.write_text("---\nstatus: waiting\n---\n", encoding="utf-8")

        errors = KB_LINT.check_task_status(self.vault)

        self.assertTrue(any(error.startswith("missing-status:") for error in errors))
        self.assertTrue(any(error.startswith("invalid-status:") for error in errors))

    def test_valid_task_source_snapshots_are_accepted(self) -> None:
        clean = self.vault / "00.memory" / "tasks" / "in-progress" / "clean.md"
        clean.write_text(
            "---\n"
            "status: in-progress\n"
            f'source-revision: "git:{"a" * 40}"\n'
            "working-copy-state: clean\n"
            "---\n",
            encoding="utf-8",
        )
        unborn = self.vault / "00.memory" / "tasks" / "in-progress" / "unborn.md"
        unborn.write_text(
            "---\n"
            "status: in-progress\n"
            "working-copy-state: uncommitted\n"
            "---\n\n"
            "## 작업 사본\n\n"
            "- untracked: src/index.ts\n",
            encoding="utf-8",
        )

        self.assertEqual(KB_LINT.check_task_source_state(self.vault), [])

    def test_invalid_task_source_snapshots_are_reported(self) -> None:
        task_directory = self.vault / "00.memory" / "tasks" / "in-progress"
        (task_directory / "invalid-state.md").write_text(
            "---\nstatus: in-progress\nworking-copy-state: dirty\n---\n",
            encoding="utf-8",
        )
        (task_directory / "invalid-revision.md").write_text(
            "---\n"
            "status: in-progress\n"
            'source-revision: "git:not-a-revision"\n'
            "working-copy-state: clean\n"
            "---\n",
            encoding="utf-8",
        )
        (task_directory / "missing-state.md").write_text(
            "---\n"
            "status: in-progress\n"
            f'source-revision: "git:{"b" * 40}"\n'
            "---\n",
            encoding="utf-8",
        )
        (task_directory / "missing-revision.md").write_text(
            "---\nstatus: in-progress\nworking-copy-state: clean\n---\n",
            encoding="utf-8",
        )
        (task_directory / "missing-section.md").write_text(
            "---\n"
            "status: in-progress\n"
            "working-copy-state: uncommitted\n"
            "---\n",
            encoding="utf-8",
        )

        errors = KB_LINT.check_task_source_state(self.vault)

        self.assertTrue(any(error.startswith("invalid-working-copy-state:") for error in errors))
        self.assertTrue(any(error.startswith("invalid-source-revision:") for error in errors))
        self.assertTrue(any(error.startswith("missing-working-copy-state:") for error in errors))
        self.assertTrue(any(error.startswith("missing-source-revision:") for error in errors))
        self.assertTrue(any(error.startswith("missing-working-copy-section:") for error in errors))

    def test_wiki_status_is_required_and_must_be_known(self) -> None:
        missing = self.vault / "10.notes" / "missing.md"
        missing.write_text("---\ntitle: 상태 없음\n---\n", encoding="utf-8")
        invalid = self.vault / "20.work" / "invalid.md"
        invalid.write_text("---\nstatus: archive\n---\n", encoding="utf-8")

        errors = KB_LINT.check_wiki_status(self.vault)

        self.assertTrue(any(error.startswith("missing-status:") for error in errors))
        self.assertTrue(any(error.startswith("invalid-status:") for error in errors))

    def test_active_wiki_document_cannot_link_to_archived_authority(self) -> None:
        archived = self.vault / "10.notes" / "old.md"
        archived.write_text("---\nstatus: archived\n---\n", encoding="utf-8")
        active = self.vault / "20.work" / "current.md"
        active.write_text(
            "---\nstatus: active\n---\n\n[예전 결정](10.notes/old.md)\n",
            encoding="utf-8",
        )

        errors = KB_LINT.check_active_links_to_archived(self.vault)

        self.assertEqual(
            errors,
            ["active-links-archived: 20.work/current.md → 10.notes/old.md"],
        )

        active.write_text(
            "---\nstatus: active\n---\n\n```markdown\n[과거 예시](10.notes/old.md)\n```\n",
            encoding="utf-8",
        )
        self.assertEqual(KB_LINT.check_active_links_to_archived(self.vault), [])

        assets = self.vault / "20.work" / "assets"
        assets.mkdir()
        (assets / "fixture.md").write_text(
            "---\nstatus: active\n---\n\n[fixture](10.notes/old.md)\n",
            encoding="utf-8",
        )
        self.assertEqual(KB_LINT.check_active_links_to_archived(self.vault), [])


if __name__ == "__main__":
    unittest.main()
