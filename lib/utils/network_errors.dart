/// Telling "the machine has no network" apart from "the site answered with
/// something unusable".
///
/// Pure Dart on purpose: the download caches and the controllers that fall
/// back to them need this answer, and none of them may depend on Flutter or
/// on the user-facing message catalogue.
library;

import 'dart:async';

/// Whether [error] is the machine failing to reach the network at all.
///
/// Matched on the message because `package:http` wraps the socket failure in
/// its own `ClientException`, which carries no cause to test.
bool looksOffline(Object error) {
  if (error is TimeoutException) return true;
  final text = error.toString();
  return text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('Connection refused') ||
      text.contains('Connection reset') ||
      text.contains('Network is unreachable') ||
      text.contains('No route to host');
}
