import '../../chess/tactics/game_ids.dart';
import '../../storage/my_accounts.dart';
import '../../storage/my_games_files.dart';
import '../../storage/pending_writes.dart';

/// Accepted HTTP results outlive their screen. Each corpus has an independent
/// persistence obligation; a retry never asks the network for replacement data.
final class DownloadSaves {
  DownloadSaves(this.cache, this.accounts, this.pending);

  final GamesCache cache;
  final AccountStore accounts;
  final PendingWrites pending;
  final _writes = <GameSite, PendingObligation<GamesKeep>>{};

  Map<GameSite, String> get problems => {
    for (final entry in _writes.entries)
      if (!entry.value.committed) entry.key: entry.value.detail,
  };

  Future<GamesKeep> accept(
    GameSite site,
    String username,
    List<String> games,
    DateTime when,
  ) {
    final frozen = List<String>.unmodifiable(games);
    final write = pending.accept<GamesKeep>(
      resource: cache.refFor(site, username),
      label: '${site.label} download',
      work: () => _publish(site, username, frozen, when),
      problem: (result) => result is GamesNotKept ? result.detail : null,
      blocked: () => const GamesNotKept('An earlier download is not saved.'),
    );
    _writes[site] = write;
    return write.run();
  }

  Future<GamesKeep> _publish(
    GameSite site,
    String username,
    List<String> games,
    DateTime when,
  ) async {
    try {
      final kept = await cache.keep(site, username, games, when);
      if (kept is GamesNotKept) return kept;
      final read = await accounts.snapshot();
      if (read is AccountsUnavailable) return GamesNotKept(read.detail);
      // The old account's corpus is saved, but its freshness no longer belongs
      // to this site's current username. No write to the replacement account.
      if ((read as AccountsSnapshot).accounts[site]?.username != username) {
        return const GamesKept();
      }
      return await accounts.setDownloaded(
            site,
            when,
            expectedUsername: username,
          )
          ? const GamesKept()
          : const GamesNotKept('The download date could not be saved.');
    } on Object catch (error) {
      return GamesNotKept('$error');
    }
  }

  Future<void> retry() async {
    for (final write in _writes.values.toList()) {
      if (!write.committed) await pending.retry(write.resource);
    }
  }
}
