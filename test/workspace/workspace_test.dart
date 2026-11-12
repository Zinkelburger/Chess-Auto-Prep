import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  test('the workspace inspected works on the collection\'s scratch board, '
      'with the settings and engine jobs of the one it came from', () {
    final app = WindowFixture();
    addTearDown(app.dispose);
    final workspace = app.parts.workspace;
    final inspection = workspace.inspection!;
    final inspecting = workspace.inspecting;
    expect(inspecting, isNot(same(workspace)));
    expect(inspecting.session, same(inspection.session));
    expect(inspecting.session, isNot(same(workspace.session)));
    expect(inspecting.settings, same(workspace.settings));
    expect(inspecting.jobs, same(workspace.jobs));
  });
}
