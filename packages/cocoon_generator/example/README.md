`cocoon_generator` runs inside your project's build, so there is no
standalone runnable script to ship here — the package being generated is the
example. The complete, working setup (annotated models, a committed
`cocoon.lock`, generated adapters, and end-to-end tests over a real
SQLite database) lives in
[cocoon_example](https://github.com/redfieldchristabel/butterfly/tree/master/packages/cocoon_example).

To generate Cocoon code in your own package:

```sh
dart pub add cocoon
dart pub add --dev cocoon_generator build_runner
```

1. Annotate a plain class with `@Collection` (nested value classes with
   `@Embedded`) and declare `part '<file>.cocoon.dart';`.
2. Add `cocoon.lock` to the build sources (`build.yaml`) — the Cocoon
   README's "Models and code generation" section shows the exact file.
3. Run the two commands whenever the models change:

```sh
dart run cocoon_generator:migrate # maintains cocoon.lock (asks about renames/drops)
dart run build_runner build -d    # emits adapters, typed handles, wire codecs
```

The rules the generator enforces (supported types, constructor shape,
subcollection indexes starting with the path params) are documented in the
[Cocoon README](https://pub.dev/packages/cocoon).
