import 'package:chess_auto_prep/features/documents/repositories/desktop_fullscreen_port.dart';

class FakeDesktopFullscreenPort implements DesktopFullscreenPort {
  bool fullScreen = false;
  void Function(bool)? changed;
  @override
  Future<bool> attach(void Function(bool) onChanged) async {
    changed = onChanged;
    return fullScreen;
  }

  @override
  Future<void> setFullScreen(bool value) async {
    fullScreen = value;
    changed?.call(value);
  }

  @override
  void detach() => changed = null;
}
