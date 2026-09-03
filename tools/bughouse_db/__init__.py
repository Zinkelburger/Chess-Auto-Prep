"""The FICS bughouse archive: fetch it, index it, explore it.

`bughouse-db.org` publishes every bughouse game FICS has seen since 2005 as
one bzip2'd BPGN per year.  This package turns that into the opening book
behind Bughouse Lab's explorer:

    fetch.py  -> corpus/export<year>.bpgn.bz2   (2.1 GB, kept compressed)
    index.py  -> bughouse_book.db               (sqlite, read by the app)

The app opens that book read-only, the same way the chess-prep MCP server
reads the app's `master_games.db` -- files are the only thing the two share.
"""
