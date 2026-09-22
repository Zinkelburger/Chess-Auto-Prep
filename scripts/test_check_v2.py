#!/usr/bin/env python3
"""Each v2 rule fires on a small bad input and stays quiet on a good one."""
import unittest

from check_v2 import LIB, check_classes, check_functions, check_imports, owner_classes


def owner(fields: str, base: str = "extends ChangeNotifier") -> str:
    return f"final class Busy {base} {{\n{fields}\n}}\n"


def class_findings(source: str, extra: dict[str, str] | None = None) -> list[str]:
    owners = owner_classes({"a.dart": source, **(extra or {})})
    findings: list[str] = []
    check_classes("a.dart", source, owners, findings)
    return findings


ELEVEN_STATE_FIELDS = "\n".join(f"  int _f{i} = 0;" for i in range(11))


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


class OwnerFieldsTest(unittest.TestCase):
    def test_an_owner_with_eleven_fields_of_its_own_fails(self):
        found = class_findings(owner(ELEVEN_STATE_FIELDS))
        self.assertEqual(len(found), 1)
        self.assertIn("owner Busy keeps 11 fields (max 10)", found[0])

    def test_ten_fields_pass(self):
        ten = "\n".join(f"  int _f{i} = 0;" for i in range(10))
        self.assertFalse(class_findings(owner(ten)))

    def test_statics_and_constructor_filled_finals_do_not_count(self):
        fields = "\n".join(
            [f"  int _f{i} = 0;" for i in range(10)]
            + [
                "  Busy(this._store, {this.delay = const Duration(seconds: 1)});",
                "  static const cap = 3;",
                "  static final pattern = RegExp('x');",
                "  final Store _store;",
                "  final Duration delay;",
                "  int get f0 => _f0;",
                "  void bump() { _f0++; }",
                "  final Future<bool> Function(Uri) _open;",
            ]
        )
        self.assertFalse(class_findings(owner(fields)))

    def test_owned_finals_late_fields_and_one_line_lists_count(self):
        fields = "\n".join(
            [f"  int _f{i} = 0;" for i in range(8)]
            + ["  final _answers = <String, int>{};", "  late final Timer _timer;", "  int? _a, _b;"]
        )
        found = class_findings(owner(fields))
        self.assertEqual(len(found), 1)
        self.assertIn("12 fields", found[0])

    def test_braces_in_strings_and_comments_do_not_end_the_class(self):
        fields = "  // }\n  final _s = '${x.map((y) { return y; })} }';\n" + ELEVEN_STATE_FIELDS
        self.assertIn("12 fields", class_findings(owner(fields))[0])

    def test_a_subclass_of_an_owner_is_an_owner(self):
        base = "class Base extends ChangeNotifier {}\n"
        self.assertTrue(class_findings(owner(ELEVEN_STATE_FIELDS, "extends Base"), {"b.dart": base}))
        self.assertTrue(class_findings(owner(ELEVEN_STATE_FIELDS, "with ChangeNotifier")))

    def test_a_value_class_is_not_an_owner(self):
        self.assertFalse(class_findings(owner(ELEVEN_STATE_FIELDS, "")))


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


class FunctionsTest(unittest.TestCase):
    def test_a_long_function_fails(self):
        lines = ["void long() {"] + ["  work();"] * 50 + ["}"]
        findings: list[str] = []
        check_functions(LIB / "chess/x.dart", lines, findings)
        self.assertEqual(len(findings), 1)
        self.assertIn("function is 52 lines", findings[0])


if __name__ == "__main__":
    unittest.main()
