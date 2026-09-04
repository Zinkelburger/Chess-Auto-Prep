# Scid: what we can take

Exploration of [github.com/benini/scid](https://github.com/benini/scid) at
`fc26337` (3 Jun 2026), the actively maintained upstream — *not* Scid vs. PC,
which is a fork with a different, older codebase. Everything below is read from
that source, not from documentation.

Originally findings only. **Sections 1-6 are the exploration; section 8
records what was then built from it** — a Scid v5 writer verified byte-for-byte
against Scid's own output.

---

## 1. The headline: si4 is legacy, SCID5 is the current format

Every public write-up (and my own earlier research) is about `.si4`, whose only
published spec covers the index *header* and tells you to read C++ for the rest.
That is the Scid vs. PC lineage. Upstream has moved on:

- `src/codec_scid5.h` implements **SCID v5** (`.si5` / `.sg5` / `.sn5`).
- `tcl/file.tcl:180` — a new database with no extension **defaults to SCID5**.
- `tcl/errors.tcl:136` — "Chess960 games can only be saved in PGN or SCID5
  databases", i.e. si4 is feature-frozen.
- Registered in `src/codec.h:45` as `enum Codec { MEMORY, PGN, SCID4, SCID5 }`
  and constructed in `src/scidbase.cpp:41`.

**And `codec_scid5.h` carries an MIT licence header**, not the GPL header every
other file in the repo has. Fulvio Benini released that file permissively.

### The whole SCID5 spec is a comment in that one file

`src/codec_scid5.h:44-151` documents the format completely — bit-by-bit index
layout, namebase encoding, game blob layout, limits. No reverse-engineering
required. Summary:

**Index (`.si5`)** — 56 bytes/game: 12 little-endian `uint32_t` + 8 bytes of
home-pawn data. Packs player/event/site/round name IDs (28–32 bits each),
Elo + date for both game and event, ply count, flags, game-data offset (47
bits) and length (17 bits), ECO, result, final material, stored-line code, and
three 4-bit "how annotated is this" ratings derived from comment/variation/NAG
counts.

**Namebase (`.sn5`)** — append-only sequence of `varint(length * 8 + type)`
followed by bytes; the low 3 bits are the type (PLAYER/EVENT/SITE/ROUND/
DB_INFO). IDs are sequential from 0.

**Games (`.sg5`)** — per game: extra tag pairs, optional start FEN, moves,
comments.

Limits vs si4, which is the reason v5 exists:

| | si4 | si5 |
|---|---|---|
| games | 16.7 M | 4 billion |
| game file | 4 GB | 128 TB |
| unique players | 2^20 | 268 M |

Benini's own listed shortcoming (`codec_scid5.h:121`): "neither the tags nor
the comments are compressed in any way… it would be possible to save a lot of
space." Our zlib-with-preset-dictionary movetext is *ahead* of Scid here.

---

## 2. The move encoding — ~150 lines, fully portable

`src/game.cpp:2489-2596`. One byte per move: **high nibble = index into the
side's piece list, low nibble = a per-piece-type direction code.**

- King is always list index 0. A king has ≤ 8 real destinations, so low-nibble
  values 9–15 are free for special tokens: `9` castle queenside, `10` castle
  kingside, `11` NAG, `12` comment placeholder, `13` start variation, `14` end
  variation, `15` end of game, `0` null move.
- Knight: `to - from` ∈ {±6, ±10, ±15, ±17} → table lookup to 1–8.
- Rook: same rank → file of `to` (0–7); same file → `8 + rank of to`.
- Bishop: file of `to`, `+8` when the diagonal is up-left/down-right.
- Queen: rook-like moves exactly as rook. Diagonals are **two bytes** — first
  byte encodes a bogus rook-horizontal move to the from-square as a marker,
  second byte is `to + 64` (the `+64` keeps it clear of the special tokens).
- Pawn: `0/1/2` = capture-left / forward / capture-right, `+3·(promo−1)` for
  Q/R/B/N promotions, `15` = double push.

Squares are plain 0–63. There is no 0x88 board, no magic tables.

### The one genuinely hard part: the piece list

Decoding needs the *exact* piece-list ordering Scid maintains, because the high
nibble is an index into it (`src/game.cpp:2617`:
`pos->GetList(toMove)[val >> 4]`). Three rules, all deterministic:

1. **Standard start** (`position.cpp:656-675`) — fixed order per side:
   `K=0, R=1, N=2, B=3, Q=4, B=5, N=6, R=7`, pawns a→h at `8..15`.
2. **Capture** (`position.cpp:1568-1571`) — swap-with-last: the last piece in
   the list moves into the captured piece's slot, then count shrinks.
3. **Promotion** (`position.cpp:1520,1529`) — the promoted piece **keeps the
   pawn's index**.
4. **FEN start** (`position.cpp:720-743`) — pieces are appended in FEN read
   order (rank 8→1, file a→h), except the king, which is forced to index 0 by
   moving whatever sat there to the end.

Get any of these wrong and decoding desynchronises silently a few moves in.

### There is a ready-made conformance suite

`gtest/test_decodemove.cpp` is tables of explicit
`(moveCode, expectedTo, expectedPromo)` vectors per piece type — pure data,
directly transcribable into Dart tests. And `gtest/res_database.si4/.sg4/.sn4`
(178 KB / 63 KB / 39 KB) is a real reference database to decode and diff
against. That removes most of the risk from a Dart implementation.

---

## 3. Three search accelerators worth stealing outright

These are independent of the file format and apply to **our own SQLite store**.
Our `book` table answers position→moves in 4 µs but only to **ply 29**. Past
that we have no index at all. These are exactly the tools for that gap, and
they cost ~6 bytes per game (~12 MB for our 1.9 M games), computed during the
import replay we already do.

**Material signature** (`src/matsig.h`) — 24 bits: pawn counts 0–8 in 4 bits,
other pieces 0–3 in 2 bits each, per side. Stored per game as the *final*
material. Since material only ever decreases, a game whose final material has
fewer of some piece than the target position needs cannot contain it
(`searchpos.h:41` `less_mat`, with `promo`/`upromo` flags to stay correct when
promotions could have created the piece).

**Home-pawn signature** (`src/matsig.h:298`) — 16 bits, one per home pawn
square a2–h2 / a7–h7, set once that pawn has left. Pawns never return, so the
final signature bounds every position the game passed through. The index also
keeps 9 bytes recording the *order* pawns left home (`indexentry.h:32,85`), so
one game's departure order can be prefix-tested against another's.

**Stored lines** (`src/stored.h`) — the sharpest idea. 255 precomputed common
opening lines; each game stores one byte for the longest one it follows. At
search time each stored line is classified once against the target position as
−2 (cannot reach), −1 (can reach), or ≥0 (**reaches it at this exact ply**).
Then a game's single byte answers "could this game contain the position, and
where" with zero decoding.

---

## 4. The Filter — the model for "slices" on a Databases page

`src/hfilter.h:28-36`. A filter is **one byte per game**: `0` = excluded,
`1-255` = included *and which ply to show when the game is opened* (1 = start,
2 = after White's first move…).

That last part is the good bit. A search doesn't return "these games match", it
returns "these games match **and here is where**", so clicking a result lands on
the position rather than at move 1. For our 1.9 M games a filter is 1.9 MB —
cheap enough to hold several and compose them.

Searches are small predicate objects over the **index entry only** — no game
data is touched, which is why it stays fast — composed with AND/OR/NOT
(`src/searchindex.cpp`, `SearchParam` with `opNot_`/`opOr_`). The dimensions
already implemented there are a good menu for our own filter UI:

- player / event / site / round name, with `"quoted"` = exact match
- site country
- game result, and chess variant
- date range, ECO range (`B07` auto-expands to `B07`–`B07z4` to include
  subcodes)
- Elo range, and **Elo *difference* range**
- game-number range, where a negative number counts from the end
- user flags (mark games, e.g. duplicates pending deletion)

Position search is multithreaded (`searchpos.h` includes `<thread>`).

---

## 5. Bigger features seen, for later

- **Opening report** (`src/optable.cpp`, 2342 lines) — generates a full report
  with positional themes: same/opposite-side castling, queen swap, bishop pair,
  king storm, isolated queen pawn, and more. Outputs Text/HTML/LaTeX. The most
  distinctive thing in the codebase.
- **Name spelling files** (`src/spellchk.h`) — canonical player/event/site
  names plus `%Prefix`/`%Infix`/`%Suffix` rewrite rules. Directly useful for
  TWIC, where the same player appears under several spellings.
- **ECO classification** (`scid.eco`, 20,818 lines) — with an extended code
  scheme (`A00`, `A00a`, `A00a1`…`A00z4`) finer than plain ECO. We already
  carry an `eco` column; this would let us fill it properly.
- **Crosstables** (`src/crosstab.cpp`) — we already have one for engine
  tournaments (`lib/services/crosstable_builder.dart`); this handles real
  events, up to 500 players / 60 rounds, with country and score sorting.
- **Sort cache** (`src/sortcache.cpp`) — maintained sorted orderings of the
  index for large result lists.

---

## 6. Licence

Repo is **GPL-2.0** (`COPYING`). Two wrinkles:

- Per-file headers say "under the terms of the GNU General Public License as
  published by the Free Software Foundation" with **no version and no "or
  later"**. GPLv2 §9 says that when the program specifies no version you may
  choose any version the FSF ever published — which would permit v3 and so
  AGPLv3 compatibility. This is ambiguous enough that it should not be relied
  on without a considered answer.
- **`src/codec_scid5.h` is MIT** — the one file that matters most for writing
  SCID5, and the one file we could port verbatim.

The practical position: a **format is not copyrightable**, so reimplementing
the encoding in Dart from what is documented above is clean regardless.
Transcribing the `test_decodemove.cpp` vectors is transcribing facts. Porting
GPL *code* is the only encumbered path, and we do not need to.

---

## 7. What I'd actually recommend

Ranked by value per unit of work.

1. **Take the three accelerators (matsig / hpSig / stored lines) into our own
   SQLite store.** No format work, no interop risk, ~12 MB, and it buys the
   thing we genuinely lack: searching master games *past ply 29*. This is the
   highest-value item and it is independent of everything else.
2. **Take the Filter model** — a byte per game carrying the match ply — as the
   representation behind filters/slices on the Databases page, with the
   `searchindex.cpp` dimension list as the menu.
3. **Export PGN (gzipped) and let `pgnscid` do the conversion.** Still the
   right answer for "give me a Scid database": Scid's own docs call `pgnscid`
   more reliable than its GUI import for large files, and it reads `.pgn.gz`
   directly.
4. **Read `.si4`/`.si5` as an import path**, if and when someone wants to bring
   a Mega Database or Monsterbase collection in. Now clearly feasible: the v5
   spec is fully documented, the move encoding is ~150 lines, and there is a
   reference database plus vector tables to test against. Read si4 too — that
   is what most existing collections are.
5. **Writing SCID5** is possible (`codec_scid5.h` is MIT and could be ported
   directly) but I would still not do it. It only saves the user one
   `pgnscid` command, and it makes us responsible for producing files another
   program must accept.

Explicitly *not* recommended: adopting Scid's format as our storage. The
earlier measurement stands — Scid has no persistent position index, and our
`book` table answers in 4 µs what Scid answers with a filtered scan.

---

## 8. What was built (Sept 4 2026)

`lib/services/scid/` writes SCID v5 databases. Verified, not merely believed:

| check | result |
|---|---|
| game data (`.sg5`) vs Scid's own | **byte-identical** |
| index (`.si5`) vs Scid's own | byte-identical except the stored-line byte |
| namebase (`.sn5`) names + ids | identical set, identical ids |
| Scid reading the Dart-written database | **PGN output identical to reading its own** |

The one deliberate difference is the stored-line code (word 10's high byte).
Scid classifies each game against its table of 255 opening lines; we write 0,
which Scid reads as "unclassified — check this game properly". Its searches
stay correct, they just skip that shortcut. Carrying the table would mean
porting `stored.cpp`'s data; the accelerator is worth having on *our* side
(section 3) but not for files we hand to Scid.

### The pieces

- `scid_piece_list.dart` — the per-side piece list the move encoding indexes
  into. This is the part that silently corrupts a stream if it drifts: fixed
  order from the standard start, FEN read order (king forced to slot 0) from a
  FEN, swap-with-last on capture, promotion keeps the pawn's slot.
- `scid_move_codec.dart` — the one-byte move encoding and its special tokens.
- `scid_game_encoder.dart` — the game blob (tags, start board, moves,
  comments) plus the fields the index derives from a game: ply count,
  promotion flags, home-pawn departures, material signature.
- `scid_index_entry.dart` — the 56-byte record, and Scid's date / ECO / result
  / annotation-count encodings.
- `scid_namebase.dart` — the append-only `varint(len*8+type)` name file.
- `scid_writer.dart` — the three files, written to temporaries and renamed
  together so an interrupted export leaves no half-database.
- `tools/scid_export.dart` — `dart run tools/scid_export.dart in.pgn out_dir`.

### How it is verified

`tools/scid_reference/` holds two small C++ programs that link Scid's own
codec: one converts PGN to a Scid database (producing the test fixtures), the
other opens a database and prints PGN (proving Scid can read what Dart wrote).
See its README for the build line and the regeneration steps.

The fixture is four real TWIC games covering castling both sides, a queen
promotion, an under-promotion and en passant, plus a hand-built FEN-start game
with comments, a NAG and a variation. Every move was checked legal with
`python-chess` first — an illegal move makes both encoders stop at the same
place, so the byte comparison would pass while proving nothing. That actually
happened on the first attempt.

### Not done

- **SCID4 output.** The game data is identical between v4 and v5, so only the
  index record and the namebase differ — but `.sn4` adds sorting and prefix
  compression, which is where the bugs would be. v5 is upstream's default; v4
  matters only for Scid vs. PC, which cannot read v5.
- **Reading** Scid databases. The encoder is the hard half and it is done; a
  reader is mostly the same tables run backwards.
- The three search accelerators and the Filter model from sections 3 and 4,
  which are about making *our* store faster and are independent of this.
