#!/usr/bin/env python3
"""Each v2 rule fires on a small bad input and stays quiet on a good one."""
import unittest

from check_v2 import LIB, MAX_FUNCTION_LINES, check_classes, check_functions, check_imports


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


if __name__ == "__main__":
    unittest.main()
