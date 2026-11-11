# cocoon_example

A small finance-style Cocoon app model, used as the end-to-end test bed for
`cocoon` and `cocoon_generator`:

- `Account` at `accounts`, with an embedded `Address` (which embeds a
  `GeoPoint`);
- `Txn` at `accounts/{accountId}/txns`, amounts in integer minor units;
- `Split` at `accounts/{accountId}/txns/{txnId}/splits`.

`cocoon.lock` is committed and maintained by
`dart run cocoon_generator:migrate`, never by hand: schema v1 stored
`Txn.bookedOn` as an ISO date String at field number 1, and migrating it to
the current yyyymmdd int produced `lib/cocoon_migrations/` — the committed
lock is that command's output, with number 1 reserved forever and
`m0002_txn_booked_on_to_booked_on.dart` implementing the conversion. The
generated `*.cocoon.dart` and `lib/cocoon_schema.g.dart` files are not
committed. Tests open a database written by the v1 schema and verify
`Cocoon.open(schemaVersion: cocoonSchemaVersion, migrations:
cocoonMigrations)` rewrites it once, in order.

```sh
dart run build_runner build -d
dart test
```
