## Unreleased

- First version: build_runner codegen for `@Collection` and `@Embedded`
  classes. Emits the adapter, typed query handles and canonical wire codec
  using field numbers from the committed `cocoon.lock.json`, plus
  `cocoonSchemaVersion`. Fails the build when models and lock disagree.
