A runnable tour of Cocoon's core API in one file, no code generation needed.

`main.dart` opens a database in a fresh temp directory, writes and reads
documents, runs an indexed query with keyset pagination, computes an
aggregate, and watches a document — then cleans up after itself:

```sh
cd packages/cocoon
dart run example/main.dart
```

The model's adapter is hand-written to keep the example generator-free; in an
app, `cocoon_generator` emits it from a `@Collection` model. See the README's
"Models and code generation" and "Writing an adapter by hand" sections, and
the [cocoon_example](https://github.com/redfieldchristabel/butterfly/tree/master/packages/cocoon_example)
package for the full generated flow.
