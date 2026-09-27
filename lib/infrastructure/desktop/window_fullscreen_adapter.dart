import 'package:window_manager/window_manager.dart';
import '../../features/documents/repositories/desktop_fullscreen_port.dart';

class WindowFullscreenAdapter
    with WindowListener
    implements DesktopFullscreenPort {
  void Function(bool)? _changed;

  @override
  Future<bool> attach(void Function(bool) onChanged) async {
    detach();
    _changed = onChanged;
    windowManager.addListener(this);
    return windowManager.isFullScreen();
  }

  @override
  void onWindowEnterFullScreen() => _changed?.call(true);
  @override
  void onWindowLeaveFullScreen() => _changed?.call(false);
  @override
  Future<void> setFullScreen(bool value) => windowManager.setFullScreen(value);
  @override
  void detach() {
    _changed = null;
    windowManager.removeListener(this);
  }
}
