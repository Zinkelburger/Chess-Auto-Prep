# Desktop document file IO

Private AGPL-3.0 package for the architecture-renewal document store. The build
hook compiles the narrow C ABI with Dart's resolved `native_toolchain_c` toolchain
(already used transitively by SQLite). No prebuilt opaque binary is downloaded.
It is bundled as a code asset in Flutter desktop builds and unit tests.

`observeFile` reads bytes and native identity from one open OS object, checks
size/timestamps after reading, and verifies the final path still names it.
POSIX uses device/inode; Windows uses volume serial and 128-bit `FileIdInfo`.
All blocking native calls run in an isolate. Files over 512 MiB, non-regular
objects, final symlinks/reparse points and hardlinks are unsupported and fail
closed. Parent aliases are resolved by the app's document store before locking.
A missing path is distinct from unreadable/unsupported/changed observations.
The observation is not a history of external deletion/recreation or filesystem
compare-and-swap. An external editor can race the last check and publication.

`installNewFile` publishes a flushed same-filesystem temporary file without
replacing an existing name (POSIX link/unlink; Windows MoveFileExW without
REPLACE_EXISTING). A collision has its own exception type. `syncDirectory` uses
POSIX fsync and explicitly fails as unsupported on Windows. The Dart atomic
writer owns temp/recovery handling and remains the only staging implementation.
The C API owns every native allocation; its result is copied and freed before
an observation crosses the isolate boundary. Embedded NUL paths are rejected.

Linux x64 is tested. macOS and Windows source paths are not native-host verified.
Production adoption is Linux only until macOS full-sync and Windows replacement,
ACL/backup, transient-sharing and namespace-durability gates are satisfied.
The package does not implement ReplaceFileW, macOS F_FULLFSYNC or sync-provider
hydration APIs, and makes no blanket power-loss guarantee.

Checks from repository root:

```
scripts/ci.sh test test/infrastructure/documents/native_pgn_document_store_test.dart test/utils/atomic_file_safety_test.dart
scripts/ci.sh integration integration_test/repertoire_catalog_test.dart
```

The app-level typed contract is in `lib/features/documents/`; native/platform
implementation stays under `lib/infrastructure/documents/`. Recovered baseline
bytes are retained beside documents under `.cap-pgn-history/`, digest-named and
never silently pruned. User-facing restoration/retention and cross-file
transactions are remaining renewal work, not provided by this native probe.
