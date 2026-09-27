import '../models/viewer_perspective.dart';
import '../repositories/desktop_fullscreen_port.dart';

/// Owns reading orientation and serialized fullscreen intent. Native callbacks
/// and asynchronous acknowledgements cannot outlive this workspace owner.
class ViewerPresentationController {
  ViewerPresentationController({
    required this.window,
    required this.onChanged,
    this.onReclaimFocus,
  });

  final DesktopFullscreenPort window;
  final void Function() onChanged;
  final void Function()? onReclaimFocus;
  Perspective _perspective = const Perspective();
  bool _boardFlipped = false;
  bool _fullScreen = false;
  bool _disposed = false;
  bool _attached = false;
  int _nativeRevision = 0;
  int _request = 0;
  bool? _desired;
  Future<void>? _initializing;
  Future<void>? _working;
  Object? _error;

  Perspective get perspective => _perspective;
  bool get boardFlipped => _boardFlipped;
  bool get isFullScreen => _fullScreen;
  bool get changingWindow => _desired != null;
  Object? get error => _error;

  /// Restore alongside other host state; the host publishes the full snapshot.
  void restoreBoard({Perspective? perspective, bool? flipped}) {
    if (_disposed) return;
    if (perspective != null) _perspective = perspective;
    if (flipped != null) _boardFlipped = flipped;
  }

  void orient(Map<String, String>? headers) {
    if (_disposed || headers == null) return;
    _boardFlipped = _perspective.flippedFor(headers) ?? _boardFlipped;
    onChanged();
  }

  void setPerspective(Perspective value, Map<String, String>? headers) {
    if (_disposed) return;
    _perspective = value;
    if (headers != null) {
      _boardFlipped = value.flippedFor(headers) ?? _boardFlipped;
    }
    onChanged();
    onReclaimFocus?.call();
  }

  /// Flipping does not change the side of an already running solitaire game.
  void toggleBoardFlipped() {
    if (_disposed) return;
    _boardFlipped = !_boardFlipped;
    _perspective = Perspective(
      mode: _boardFlipped ? PerspectiveMode.black : PerspectiveMode.white,
    );
    onChanged();
  }

  Future<void> initialize() async {
    if (_disposed || _attached) return;
    final pending = _initializing ??= _attach();
    await pending;
    if (identical(_initializing, pending)) _initializing = null;
  }

  Future<void> _attach() async {
    final revision = _nativeRevision;
    try {
      final initial = await window.attach(_nativeChanged);
      if (_disposed) return;
      _attached = true;
      if (revision == _nativeRevision) _fullScreen = initial;
      _error = null;
    } catch (error) {
      if (_disposed) return;
      window.detach();
      _error = error;
    }
    if (!_disposed) onChanged();
  }

  void _nativeChanged(bool value) {
    if (_disposed) return;
    _nativeRevision++;
    _fullScreen = value;
    onChanged();
  }

  Future<void> toggleFullScreen() async {
    await initialize();
    if (_disposed || !_attached) return;
    await _requestWindow(!(_desired ?? _fullScreen));
  }

  Future<void> exitFullScreen() async {
    await initialize();
    if (_disposed || !_attached) return;
    await _requestWindow(false);
  }

  Future<void> _requestWindow(bool value) {
    if (_disposed) return Future.value();
    _desired = value;
    _request++;
    _error = null;
    final pending = _working ??= _drain();
    return pending;
  }

  Future<void> _drain() async {
    // Start on a microtask so even a synchronous host callback sees _working.
    await Future<void>.value();
    try {
      await initialize();
      if (_disposed || !_attached) return;
      while (!_disposed && _desired != null) {
        final value = _desired!;
        final request = _request;
        try {
          if (value != _fullScreen) {
            await window.setFullScreen(value);
            if (_disposed) return;
            _fullScreen = value;
          }
          if (request == _request) {
            _desired = null;
            _error = null;
            onReclaimFocus?.call();
          }
        } catch (error) {
          if (_disposed) return;
          if (request == _request) {
            _desired = null;
            _error = error;
          }
        }
        if (!_disposed) onChanged();
      }
    } finally {
      _working = null;
      if (!_disposed) {
        _desired = null;
        onChanged();
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _desired = null;
    window.detach();
  }
}
