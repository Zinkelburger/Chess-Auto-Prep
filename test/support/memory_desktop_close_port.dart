import 'package:chess_auto_prep/features/documents/repositories/desktop_close_port.dart';

class MemoryDesktopClosePort implements DesktopClosePort {
  void Function()? request;
  int closes = 0;
  int attaches = 0;
  int detaches = 0;
  Object? closeError;
  @override
  Future<void> attach(void Function() onCloseRequested) async {
    attaches++;
    request = onCloseRequested;
  }

  @override
  Future<void> close() async {
    if (closeError != null) throw closeError!;
    closes++;
  }

  @override
  Future<void> detach() async {
    request = null;
    detaches++;
  }
}
