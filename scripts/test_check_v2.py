#!/usr/bin/env python3
"""Each v2 rule fires on a small bad input and stays quiet on a good one."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import check_v2

from check_v2 import LIB, MAX_FUNCTION_LINES, TEST, check_classes, check_functions, check_imports


def class_findings(source: str) -> list[str]:
    findings: list[str] = []
    check_classes("a.dart", source, findings)
    return findings


class ImportsTest(unittest.TestCase):
    def findings(self, path: str, target: str) -> list[str]:
        findings: list[str] = []
        check_imports(LIB / path, [f"import '{target}';"], findings)
        return findings

    def test_one_mode_may_not_import_another(self):
        found = self.findings("features/study/panel.dart", "../library/library.dart")
        self.assertEqual(len(found), 1)
        self.assertIn("feature study imports feature library", found[0])

    def test_a_mode_may_import_its_own_folder_and_the_workspace(self):
        self.assertFalse(self.findings("features/study/panel.dart", "studies.dart"))
        self.assertFalse(self.findings("features/study/panel.dart", "../../workspace/board.dart"))

    def test_net_may_listen_on_a_socket_but_ui_may_not(self):
        self.assertFalse(self.findings("net/login.dart", "dart:io"))
        self.assertTrue(self.findings("ui/theme.dart", "dart:io"))


LISTENING = """
class _PaneState extends State<Pane> {{
  @override
  void initState() {{
    super.initState();
    widget.session.addListener(_changed);
  }}
{extra}
}}
"""


class ListeningTest(unittest.TestCase):
    def test_listening_to_the_widget_without_following_it_fails(self):
        found = class_findings(LISTENING.format(extra=""))
        self.assertEqual(len(found), 1)
        self.assertIn("_PaneState listens to widget", found[0])

    def test_a_cascade_is_listening_too(self):
        source = LISTENING.format(extra="").replace(
            "widget.session.addListener", "_heard = widget.changes\n      ..addListener"
        )
        self.assertTrue(class_findings(source))

    def test_did_update_widget_or_listening_state_passes(self):
        update = "  @override\n  void didUpdateWidget(Pane old) { super.didUpdateWidget(old); }"
        self.assertFalse(class_findings(LISTENING.format(extra=update)))
        mixin = LISTENING.format(extra="").replace(
            "State<Pane> {", "State<Pane> with ListeningState<Pane> {"
        )
        self.assertFalse(class_findings(mixin))

    def test_braces_in_strings_and_comments_do_not_end_the_class(self):
        noise = "  // }\n  final _s = '${x.map((y) { return y; })} }';\n"
        source = LISTENING.format(extra="").replace("{\n  @override", "{\n" + noise + "  @override", 1)
        self.assertTrue(class_findings(source))


class FunctionsTest(unittest.TestCase):
    def test_a_long_function_fails(self):
        lines = ["void long() {"] + ["  work();"] * MAX_FUNCTION_LINES + ["}"]
        findings: list[str] = []
        check_functions(LIB / "chess/x.dart", lines, findings)
        self.assertEqual(len(findings), 1)
        self.assertIn(f"function is {MAX_FUNCTION_LINES + 2} lines", findings[0])

    def test_a_long_group_is_a_list_of_cases_but_its_tests_are_checked(self):
        body = ["    work();"] * MAX_FUNCTION_LINES
        lines = ["  group('g', () {"] + ["    test('t', () {"] + body + ["    });"] + ["  });"]
        findings: list[str] = []
        check_functions(TEST / "x_test.dart", lines, findings)
        self.assertEqual(len(findings), 1)
        self.assertIn(":2: function is", findings[0])


class PartsTest(unittest.TestCase):
    def findings(self, child: str, owner: str = "part 'worker.dart';\nclass Owner {}"):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            folder = root / "lib/v2/workspace"
            folder.mkdir(parents=True)
            (folder / "owner.dart").write_text(owner)
            (folder / "worker.dart").write_text(child)
            with patch.multiple(check_v2, REPO=root, LIB=root / "lib/v2", TEST=root / "test/v2"):
                findings = []
                for path in folder.glob("*.dart"):
                    check_v2.check_file(path, findings)
                return findings

    def test_complete_collaborator_classes_are_allowed(self):
        self.assertFalse(self.findings("part of 'owner.dart';\nfinal class Worker { void run() {} }"))

    def test_part_cannot_hide_extension_methods_of_owner(self):
        self.assertTrue(self.findings("part of 'owner.dart';\nextension Work on Owner { void run() {} }"))

    def test_part_cannot_hide_owner_mixin_or_top_level_methods(self):
        for fragment in ["mixin Work { void run() {} }", "void run() {}"]:
            self.assertTrue(self.findings("part of 'owner.dart';\n" + fragment))

    def test_part_must_name_owner_in_same_directory(self):
        self.assertTrue(self.findings("part of '../owner.dart';\nclass Worker {}"))
        self.assertTrue(self.findings("part of other;\nclass Worker {}"))

    def test_part_keeps_file_and_function_caps(self):
        child = "part of 'owner.dart';\nclass Worker {\n  void run() {\n" + "    work();\n" * 1001 + "  }\n}"
        found = self.findings(child)
        self.assertTrue(any("lines (max 1000)" in f for f in found))
        self.assertTrue(any("function is" in f for f in found))


if __name__ == "__main__":
    unittest.main()
