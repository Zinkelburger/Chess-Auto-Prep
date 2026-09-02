---
description: Run the local pre-commit gates (format, analyze, test, lint) through the shared Flutter lock, and report honestly whether the tree is committable.
argument-hint: [optional subset: format analyze test lint integration]
---

Run the gates. These are the only thing standing between this repo and a
broken push: CI runs on `v*` tags and manual dispatch only, so nothing catches
a regression on a normal commit except this.

```
scripts/ci.sh $ARGUMENTS
```

(no arguments = `format analyze test lint`)

Rules:

- **Go through `scripts/ci.sh`.** Raw `flutter test` / `flutter analyze` are
  denied by a `PreToolUse` hook, because several agents share this machine and
  parallel Flutter jobs crash it. `ci.sh` serialises them behind one flock and
  replays a cached pass when the tree is unchanged.
- If it prints `waiting for the Flutter lock (held by: …)`, **wait**. Do not
  start a second job, and do not switch to a raw command to get around it.
- `--fresh` bypasses the result cache. Use it only when you suspect the cache,
  not routinely.
- **Warnings are fatal**, as in CI — `analyze` fails on any `error •` or
  `warning •` line even when Flutter's exit code is 0. `info •` lines are not
  failures.
- `format` **rewrites** files. Expect a dirty tree afterwards; that is the
  point, commit it.

Then report the real outcome: if a step failed, say which and paste the
failing lines. If you skipped a step, say so. Do not report "all green"
unless `── all green:` actually appeared.
