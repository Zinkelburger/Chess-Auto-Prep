---
description: Run focused local checks through the bounded job runner.
argument-hint: [analyze lint | test test/path_test.dart | integration | full]
---

Run `scripts/ci.sh $ARGUMENTS`. Without arguments it runs analysis and lint.
Choose tests relevant to the change; GitHub CI runs only for release tags.
Report actual results, including failures and skipped checks.
