# cocoon_generator

build_runner code generation for [Cocoon](../cocoon), the typed,
Firestore-style local database on SQLite. Standalone: no Butterfly packages
required.

For every `@Collection` model it generates the `CollectionAdapter`, typed
query handles (`Txn$.bookedOn`, `Txn$.accountId`) and the canonical protobuf
codec; for every `@Embedded` class, a nested-message codec. Field numbers come
from the committed `cocoon.lock.json` at the package root, and the build
fails when the models and the lock disagree. The builder never writes the
lock.

```yaml
dev_dependencies:
  build_runner: ^2.4.13
  cocoon_generator: ^0.0.1
```

Add `cocoon.lock.json` to the build sources (`build.yaml`), declare
`part '<file>.cocoon.dart';` in each model file, then run
`dart run build_runner build -d`. Supported types, defaults and naming are
documented in the Cocoon README ("Models and code generation"); a complete
working setup lives in [cocoon_example](../cocoon_example).

The interactive `dart run cocoon_generator:migrate` command that maintains the
lock for you is coming next.
