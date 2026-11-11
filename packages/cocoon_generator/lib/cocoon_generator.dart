/// Code generator for Cocoon: turn plain Dart classes annotated with
/// `@Collection` (from `package:cocoon`) into the `CollectionAdapter`,
/// typed query handles and canonical wire codec the storage engine needs.
///
/// Add the package as a dev dependency and run build_runner; see the Cocoon
/// README for the full workflow, including the committed `cocoon.lock`
/// that pins field numbers.
///
/// ```dart
/// @Collection('accounts/{accountId}/txns', indexes: [
///   Index(['accountId', '-bookedOn']),
/// ])
/// class Txn {
///   const Txn({required this.bookedOn, required this.amountMinor});
///   final int bookedOn;
///   final int amountMinor;
/// }
///
/// part 'models.cocoon.dart'; // generated: txns, TxnCollection, Txn$
/// ```
library;

export 'builder.dart'
    show CocoonGenerator, cocoonBuilder, cocoonSchemaVersionBuilder;
export 'src/extract.dart'
    show
        CocoonBuildError,
        ExtractedClass,
        ExtractedEmbedded,
        ExtractedField,
        ExtractedIndex,
        ExtractedModel,
        LibraryDeclarations,
        describeCollectionDiff,
        describeEmbeddedDiff,
        extractLibrary,
        schemaChangedMessage;
