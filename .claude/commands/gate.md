---
description: Run focused local checks through the bounded job runner.
argument-hint: [analyze lint | test test/path_test.dart | integration | full]
---

Run `scripts/ci.sh $ARGUMENTS`. Without arguments it runs analysis and lint.
Choose tests relevant to the change; full batch checks run on the development backup in GitHub CI.
Report actual results, including failures and skipped checks.
