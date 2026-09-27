import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../storage/pending_writes.dart';
import '../../net/player_ratings.dart';
import '../../storage/player_files.dart';
import '../../chess/players/player.dart';

/// Owns the saved directory and group selection. Failed writes remain explicit
/// retryable obligations; refresh never pretends that a save succeeded.
final class Players extends ChangeNotifier {
  Players(this.store, this.pending, {this.lookupRating});
  final Future<PlayerRating> Function(String id)? lookupRating;
  bool lookingUp = false;
  String? lookupStatus;
  bool _stopLookup = false;
  final PlayerStore store;
  final PendingWrites pending;
  List<Player> players = const [];
  List<PlayerGroup> groups = const [];
  String? groupId;
  String query = '';
  bool showingGroups = false, busy = false, loaded = false;
  String? error;
  bool _disposed = false;
  PendingObligation<void>? _failed;

  PlayerGroup? get group => groups.where((g) => g.id == groupId).firstOrNull;
  List<Player> get visible =>
      players
          .where(
            (p) =>
                (group == null || group!.contains(p.id)) &&
                p.search.contains(query.toLowerCase()),
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  void changed() {
    if (!_disposed) notifyListeners();
  }

  void search(String value) {
    query = value;
    changed();
  }

  void showGroup(String? id) {
    groupId = id;
    query = '';
    changed();
  }

  void showGroups(bool value) {
    showingGroups = value;
    groupId = null;
    query = '';
    changed();
  }

  Future<void> load() async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    changed();
    try {
      await _read();
    } on Object catch (e) {
      error = 'Could not load players: $e';
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> _read() async {
    final read = await store.read();
    if (_disposed) return;
    players = read.players;
    groups = read.groups;
    loaded = true;
    if (groupId != null && group == null) groupId = null;
  }

  Future<bool> _write(String label, Future<void> Function() work) async {
    if (busy || _disposed || _failed != null) return false;
    busy = true;
    error = null;
    changed();
    final obligation = pending.accept<void>(
      resource: this,
      label: label,
      work: work,
      problem: (_) => null,
    );
    try {
      await obligation.run();
      await _read();
      return true;
    } on Object catch (e) {
      if (!obligation.committed) _failed = obligation;
      error = 'Could not save: $e';
      return false;
    } finally {
      busy = false;
      changed();
    }
  }

  bool get needsRetry => _failed != null;
  Future<void> retry() async {
    final failed = _failed;
    if (failed == null || busy) return;
    busy = true;
    changed();
    try {
      await failed.run();
      _failed = null;
      error = null;
      await _read();
    } on Object catch (e) {
      error = 'Could not save: $e';
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> discardFailed() async {
    if (_failed?.discard() != true) return;
    _failed = null;
    await load();
  }

  Future<bool> save(Player player, {Player? expected}) => _write(
    'Save ${player.name}',
    () => store.savePlayer(player, expected: expected),
  );
  Future<bool> saveGroup(PlayerGroup next, {PlayerGroup? expected}) => _write(
    'Save ${next.name}',
    () => store.saveGroup(next, expected: expected),
  );
  Future<bool> remove(Player player) => _write(
    'Remove ${player.name}',
    () async {
      final current = await store.read();
      for (final group in current.groups.where((g) => g.contains(player.id))) {
        await store.saveGroup(
          group.member(player.id, remove: true),
          expected: group,
        );
      }
      await store.removePlayer(player);
    },
  );
  Future<bool> removeGroup(PlayerGroup group) =>
      _write('Remove ${group.name}', () => store.removeGroup(group));

  /// Match reliable IDs/accounts first, then an exact name. Fill only empty
  /// fields so roster import never erases prep notes or known identities.
  Future<bool> import(List<Player> incoming) async {
    final into = group;
    return _write('Import players', () async {
      final current = await store.read();
      final people = [...current.players];
      var target = into == null
          ? null
          : current.groups.where((g) => g.id == into.id).firstOrNull;
      for (final player in incoming) {
        final existing = people.where((p) => samePlayer(p, player)).firstOrNull;
        final next = existing == null
            ? player
            : existing.edited({
                for (final e in player.fields.entries)
                  if (!{'id', 'created_at', 'updated_at'}.contains(e.key) &&
                      (existing.fields[e.key] == null ||
                          existing.fields[e.key] == ''))
                    e.key: e.value,
              });
        final linked = next.edited({
          for (final key in ['aliases', 'pgn_files', 'game_sets'])
            key: {...?existing?.strings(key), ...player.strings(key)}.toList(),
        });
        await store.savePlayer(linked, expected: existing);
        people.removeWhere((p) => p.id == next.id);
        people.add(linked);
        if (target != null) target = target.member(next.id);
      }
      if (target != null)
        await store.saveGroup(
          target,
          expected: current.groups.firstWhere((g) => g.id == target!.id),
        );
    });
  }

  void stopLookup() {
    _stopLookup = true;
  }

  Future<void> updateRatings() async {
    if (lookingUp || lookupRating == null) return;
    final people = visible.where((p) => p.text('uscf_id').isNotEmpty).toList();
    if (people.isEmpty) {
      lookupStatus = 'Add a US Chess ID to a player first.';
      changed();
      return;
    }
    lookingUp = true;
    _stopLookup = false;
    var updated = 0, missed = 0;
    for (final (i, person) in people.indexed) {
      if (_disposed || _stopLookup) break;
      lookupStatus = 'Looking up ${person.name} · ${i + 1} / ${people.length}';
      changed();
      try {
        final result = await lookupRating!(person.text('uscf_id'));
        if (_disposed || _stopLookup) break;
        if (result.rating == null) {
          missed++;
          continue;
        }
        if (!await save(
          person.edited({'rating': result.rating}),
          expected: person,
        ))
          break;
        updated++;
      } on Object {
        missed++;
      }
    }
    lookingUp = false;
    lookupStatus = '$updated ratings updated · $missed unavailable';
    changed();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
