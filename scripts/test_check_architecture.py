#!/usr/bin/env python3
"""Each architecture rule fires on a small bad input and stays quiet on a good one."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import check_architecture

from check_architecture import (
    LIB,
    MAX_FUNCTION_LINES,
    TEST,
    check_classes,
    check_functions,
    check_imports,
    check_members,
)


def class_findings(source: str) -> list[str]:
    findings: list[str] = []
    check_classes("a.dart", source, findings)
    return findings


class LayoutTest(unittest.TestCase):
    def test_retired_app_trees_cannot_return(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / "lib/app").mkdir(parents=True)
            (root / "test/app").mkdir(parents=True)
            self.assertEqual(check_architecture.check_layout(root), [])
            (root / "lib/main_v2.dart").touch()
            (root / "test/v2").mkdir()
            (root / "lib/services").mkdir()
            self.assertEqual(len(check_architecture.check_layout(root)), 3)


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

    def test_package_imports_obey_the_same_architecture(self):
        self.assertTrue(self.findings("chess/model.dart", "package:chess_auto_prep/storage/settings.dart"))
        self.assertTrue(self.findings("features/study/panel.dart", "package:chess_auto_prep/features/library/library.dart"))
        self.assertFalse(self.findings("features/study/panel.dart", "package:chess_auto_prep/workspace/document_session.dart"))

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


def member_findings(source: str) -> list[str]:
    findings: list[str] = []
    check_members("lib/chess/x.dart", source, findings)
    return findings


class FunctionsTest(unittest.TestCase):
    body = "    work();\n" * MAX_FUNCTION_LINES

    def test_a_long_function_fails(self):
        findings = member_findings("void long() {\n" + self.body + "}\n")
        self.assertEqual(len(findings), 1)
        self.assertIn(f":1: function is {MAX_FUNCTION_LINES + 2} lines", findings[0])

    def test_a_long_arrow_body_in_a_class_fails(self):
        source = "class A {\n  @override\n  Widget build(BuildContext c) => Column(\n" + self.body + "  );\n}\n"
        findings = member_findings(source)
        self.assertEqual(len(findings), 1)
        self.assertIn(":3: function is", findings[0])

    def test_a_signature_over_several_lines_is_measured(self):
        source = "class A {\n  Future<void> run({\n    required int a,\n  }) async {\n" + self.body + "  }\n}\n"
        self.assertEqual(len(member_findings(source)), 1)

    def test_a_long_getter_fails(self):
        self.assertEqual(len(member_findings("List<int> get all => [\n" + "  1,\n" * MAX_FUNCTION_LINES + "];\n")), 1)

    def test_a_long_value_is_not_a_function(self):
        table = "const table = {\n" + "  'a': 1,\n" * MAX_FUNCTION_LINES + "};\n"
        field = "class A {\n  final rows = [\n" + "    Row(),\n" * MAX_FUNCTION_LINES + "  ];\n}\n"
        self.assertFalse(member_findings(table))
        self.assertFalse(member_findings(field))

    def test_a_composition_root_may_say_why_it_is_long(self):
        source = "class A {\n  // long: lists every part\n  factory A.real() => A(\n" + self.body + "  );\n}\n"
        self.assertFalse(member_findings(source))
        self.assertTrue(member_findings(source.replace("// long: lists every part", "// long:")))

    def test_a_short_function_in_an_enum_passes(self):
        self.assertFalse(member_findings("enum E {\n  a, b;\n  bool get first => this == a;\n}\n"))

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
            folder = root / "lib/workspace"
            folder.mkdir(parents=True)
            (folder / "owner.dart").write_text(owner)
            (folder / "worker.dart").write_text(child)
            with patch.multiple(check_architecture, REPO=root, LIB=root / "lib", TEST=root / "test"):
                findings = []
                for path in folder.glob("*.dart"):
                    check_architecture.check_file(path, findings)
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
