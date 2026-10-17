# Scid reference harness

Two tiny C++ programs that link **Scid's own codec** so a Dart Scid writer can
be checked against ground truth rather than against a reading of the format
docs. The app has no Scid export; one starts from
[the format findings](../../docs/SCID_FORMAT_FINDINGS.md).

- `refgen.cpp` — PGN → `.si4`/`.sg4`/`.sn4` or `.si5`/`.sg5`/`.sn5`.
  Produces reference databases for a writer's tests.
- `dumpdb.cpp` — opens a Scid database and prints it as PGN. This is how a
  *Dart-written* database is proved readable: dump it, dump Scid's own, diff.

Neither ships with the app. They exist so the fixtures can be regenerated when
Scid changes, and so a change to the encoder can be re-verified.

## Building

Scid's GUI needs Tcl/Tk, but the codec does not. The eight sources below are
exactly the Tcl-free subset Scid's own `gtest` target uses.

```sh
git clone --depth 1 https://github.com/benini/scid.git $HOME/src/scid
cd tools/scid_reference
SRC=$HOME/src/scid/src
for prog in refgen dumpdb; do
  g++ -std=c++20 -O1 -I"$SRC" -o $prog $prog.cpp \
    "$SRC"/codec_scid4.cpp "$SRC"/scidbase.cpp "$SRC"/sortcache.cpp \
    "$SRC"/stored.cpp "$SRC"/game.cpp "$SRC"/position.cpp \
    "$SRC"/textbuf.cpp "$SRC"/misc.cpp -lpthread
done
```

## Regenerating the fixtures

```sh
cd tools/scid_reference
./refgen SCID4 path/to/fixture.pgn ref4
./refgen SCID5 path/to/fixture.pgn ref5
# copy ref4.* and ref5.* next to the writer's tests
```

`fixture.pgn` should hold real games covering castling both sides, a queen
promotion, an under-promotion and en passant, plus one game that starts from a
FEN and carries comments, a NAG and a variation. Verify every move legal with
`python-chess` before using it, because an
illegal move makes *both* encoders stop at the same place and the byte
comparison then passes while proving nothing.

## Verifying a Dart-written database

```sh
# write some.pgn to out/mydb with the Dart writer under test, then:
tools/scid_reference/dumpdb SCID5 out/mydb > dart.pgn
tools/scid_reference/refgen SCID5 some.pgn out/scidref
tools/scid_reference/dumpdb SCID5 out/scidref > scid.pgn
diff scid.pgn dart.pgn        # must be empty
```

## Licence

Scid is GPL-2.0; these two files link it, so treat any *built binary* as GPL.
Nothing here is linked into the app; a Dart writer is an independent
implementation written from the format description in
`docs/SCID_FORMAT_FINDINGS.md`, and file formats are not copyrightable.
