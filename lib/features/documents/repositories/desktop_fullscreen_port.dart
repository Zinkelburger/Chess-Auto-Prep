/// Native fullscreen operations owned for the entire workspace lifetime.
abstract interface class DesktopFullscreenPort {
  /// Subscribe before reading initial state, so native events are not missed.
  /// The owner may receive events before this future returns its snapshot.
  Future<bool> attach(void Function(bool fullScreen) onChanged);
  Future<void> setFullScreen(bool value);
  void detach();
}
