# Repertoire component catalog

This local Widgetbook uses production widgets and themes with in-memory fixtures.
It does not initialize the app's storage, account settings or engine services.

From the repository root:

```sh
python3 scripts/app_driver.py start --target widgetbook/main.dart
python3 scripts/app_driver.py dump
python3 scripts/app_driver.py ss component-catalog
python3 scripts/app_driver.py stop
scripts/ci.sh test test/design_system
scripts/ci.sh integration integration_test/design_system_catalog_test.dart
```

Select a case in the left panel. Theme and text-scale addons on the right change
the production theme and scale from 100% to 200%, including pushed forms/dialogs.
Library fixtures support search, rename, delete and restore. Creation fixtures
open the actual creation form with success, three-second delay or failure;
imports use an in-memory PGN. Browse chapters uses an isolated navigation fake.
Reset a case by leaving it and returning. Fixtures are illustrative UI states,
not persistence/recovery tests; the native repository journeys test those.

Keep cases wired to production components. Add state scenarios here instead of
copying the widget under test. Current architecture and remaining gates are in
[the renewal document](../docs/ARCHITECTURE_RENEWAL.md).
