import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';

/// A bounded, on-demand report. Never opens account preferences or chess data.
final class DiagnosticReport {
  DiagnosticReport(this.folder, {this.application, this.platform});

  final Directory folder;
  final Future<String> Function()? application;
  final String? platform;
  static const maxBytes = 32 * 1024;
  static const maxLines = 160;

  Future<String> read() async {
    final version = await _version();
    final system =
        platform ??
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n'
            'Dart: ${Platform.version}';
    final tail = await _tail();
    return 'Chess Auto Prep v2\n$version\n$system\n\n'
        'Recent app.log (up to $maxLines lines / $maxBytes bytes):\n$tail';
  }

  Future<String> _version() async {
    try {
      if (application case final read?) return await read();
      final info = await PackageInfo.fromPlatform();
      return 'Version: ${info.version}+${info.buildNumber}';
    } catch (error) {
      log.w('Read diagnostic version', error);
      return 'Version unavailable';
    }
  }

  Future<String> _tail() async {
    final file = File(p.join(folder.path, 'app.log'));
    try {
      if (!await file.exists()) return 'No app.log yet.';
      final handle = await file.open();
      try {
        final size = await handle.length();
        final start = math.max(0, size - maxBytes);
        await handle.setPosition(start);
        final bytes = await handle.read(math.min(size, maxBytes));
        var text = utf8.decode(bytes, allowMalformed: true);
        // The first bytes may begin midway through UTF-8 or a credential.
        if (start > 0) {
          final newline = text.indexOf('\n');
          if (newline < 0) return 'No complete recent log lines.';
          text = text.substring(newline + 1);
        }
        final lines = const LineSplitter().convert(text);
        return lines
            .skip(math.max(0, lines.length - maxLines))
            .map(_withoutCredentials)
            .join('\n');
      } finally {
        await handle.close();
      }
    } catch (error) {
      log.w('Read diagnostic log', error);
      return 'Recent log unavailable.';
    }
  }
}

// Defense in depth: logging credentials is prohibited at their source too.
// Omit the entire line rather than guessing where a quoted secret ends.
final _credentials = RegExp(
  r'authorization|bearer\s|access[_ -]?token|refresh[_ -]?token|'
  r'client[_ -]?secret|code[_ -]?verifier|password|[?&]code=|'
  r'\b(?:token|secret)\s*[=:]|\b(?:lip|lio)_[A-Za-z0-9]',
  caseSensitive: false,
);

String _withoutCredentials(String line) => _credentials.hasMatch(line)
    ? '[Credential-bearing log line omitted]'
    : line;
