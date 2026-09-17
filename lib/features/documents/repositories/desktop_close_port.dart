/// Native window lifetime belongs to the app, not any document screen.
abstract interface class DesktopClosePort {
  Future<void> attach(void Function() onCloseRequested);
  Future<void> close();
  Future<void> detach();
}
