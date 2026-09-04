# Scid reference harness

Two tiny C++ programs that link **Scid's own codec** so the Dart writer in
`lib/services/scid/` can be checked against ground truth rather than against a
reading of the format docs.

- `refgen.cpp` — PGN → `.si4`/`.sg4`/`.sn4` or `.si5`/`.sg5`/`.sn5`.
  Produces the fixtures in `test/services/scid/fixtures/`.
- `dumpdb.cpp` — opens a Scid database and prints it as PGN. This is how a
  *Dart-written* database is proved readable: dump it, dump Scid's own, diff.

Neither ships with the app. They exist so the fixtures can be regenerated when
Scid changes, and so a change to the encoder can be re-verified.

## Building

Scid's GUI needs Tcl/Tk, but the codec does not. The eight sources below are
exactly the Tcl-free subset Scid's own `gtest` target uses.

```sh
git clone --depth 1 https://github.com/benini/scid.git /tmp/scid
cd tools/scid_reference
SRC=/tmp/scid/src
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
./refgen SCID4 ../../test/services/scid/fixtures/fixture.pgn ref4
./refgen SCID5 ../../test/services/scid/fixtures/fixture.pgn ref5
cp ref4.si4 ref4.sg4 ref4.sn4 ref5.si5 ref5.sg5 ref5.sn5 \
   ../../test/services/scid/fixtures/
```

`fixture.pgn` is four real TWIC games — chosen to cover castling both sides, a
queen promotion, an under-promotion and en passant — plus one hand-built game
that starts from a FEN and carries comments, a NAG and a variation. Every move
in it was verified legal with `python-chess` before it was used, because an
illegal move makes *both* encoders stop at the same place and the byte
comparison then passes while proving nothing.

## Verifying a Dart-written database

```sh
dart run tools/scid_export.dart some.pgn /tmp/out mydb
tools/scid_reference/dumpdb SCID5 /tmp/out/mydb > dart.pgn
tools/scid_reference/refgen SCID5 some.pgn /tmp/out/scidref
tools/scid_reference/dumpdb SCID5 /tmp/out/scidref > scid.pgn
diff scid.pgn dart.pgn        # must be empty
```

## Licence

Scid is GPL-2.0; these two files link it, so treat any *built binary* as GPL.
Nothing here is linked into the app — `lib/services/scid/` is an independent
implementation written from the format description in
`docs/SCID_FORMAT_FINDINGS.md`, and file formats are not copyrightable.
