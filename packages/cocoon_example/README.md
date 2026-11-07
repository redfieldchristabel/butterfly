# cocoon_example

A small finance-style Cocoon app model, used as the end-to-end test bed for
`cocoon` and `cocoon_generator`:

- `Account` at `accounts`, with an embedded `Address` (which embeds a
  `GeoPoint`);
- `Txn` at `accounts/{accountId}/txns`, amounts in integer minor units;
- `Split` at `accounts/{accountId}/txns/{txnId}/splits`.

`cocoon.lock.json` is committed; generated `*.cocoon.dart` and
`lib/cocoon_schema.g.dart` are not. `tool/make_lock.dart` wrote the lock by
hand until the `migrate` CLI exists.

```sh
dart run build_runner build -d
dart test
```
