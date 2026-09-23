# Lichess official broadcasts, filtered

Every official Lichess broadcast game from 2020-01 to 2026-08 that TWIC and the
curated collections do not already hold: 596,200 games, one xz-compressed PGN
per month. Built by `tools/lichess_broadcast_archive.py`; see
`docs/BROADCAST_GAMES.md`.

Rebuild the queryable database from this copy:

    python3 tools/lichess_broadcast_archive.py restore

Source: the Lichess broadcast database, https://database.lichess.org/#broadcasts.
Broadcast games are released under the Creative Commons Attribution-ShareAlike
4.0 license (https://creativecommons.org/licenses/by-sa/4.0/); this filtered
copy (comments removed, duplicates and variants dropped) is shared under the
same license.
