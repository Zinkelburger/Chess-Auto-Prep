// The known-violation ledger shared by the owner and interleaving runs, as
// the fault matrix keeps its own: each entry names a confirmed finding, a
// violation no entry names fails the run, and so does an entry that no
// longer shows, so the ledger only ever shrinks.
import 'package:flutter_test/flutter_test.dart';

import 'contracts.dart';

/// Fails with a report when [found] holds a violation [known] does not
/// name, or, unless only [partial] cases ran (a replay), [known] names one
/// that did not show. A key is `<case>/<contract>`, as the report prints
/// it; `*` in an entry stands for any run of characters. A loss is never a
/// known finding.
void checkLedger(
  String name,
  List<Violation> found,
  Map<String, String> known, {
  required String Function(Violation violation) replay,
  bool partial = false,
}) {
  final keyed = {for (final v in found) '${v.at}/${v.contract}': v};
  final patterns = [for (final id in known.keys) (id, ledgerPattern(id))];
  final unexpected = [
    for (final MapEntry(:key, :value) in keyed.entries)
      if (value.contract == dataLost ||
          !patterns.any((entry) => entry.$2.hasMatch(key)))
        value,
  ];
  final stale = [
    for (final (id, pattern) in patterns)
      if (!partial && !keyed.keys.any(pattern.hasMatch)) id,
  ];
  if (unexpected.isEmpty && stale.isEmpty) return;
  final out = StringBuffer();
  for (final v in unexpected) {
    out
      ..writeln(v)
      ..writeln('  replay: ${replay(v)}');
  }
  for (final id in stale) {
    out.writeln(
      'no longer shows, so take it off the ledger: $id (${known[id]})',
    );
  }
  fail('$name:\n$out');
}

/// A ledger key as a pattern: `*` stands for any run of characters.
RegExp ledgerPattern(String id) =>
    RegExp('^${id.split('*').map(RegExp.escape).join('.*')}\$');
