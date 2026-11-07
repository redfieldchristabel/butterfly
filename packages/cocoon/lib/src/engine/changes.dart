import 'package:meta/meta.dart';

/// The kind of write a [Change] records.
enum ChangeOp {
  /// The document was written (`set` or `add`, including upserts that
  /// replaced an existing document).
  set,

  /// The document was deleted, including by a cascade delete of an ancestor
  /// document.
  delete,
}

/// One committed write, as recorded in the database's change log and
/// returned by `Cocoon.changesSince`.
///
/// The log feeds realtime watches in-process; the same rows on disk can
/// later drive sync outboxes and audits.
final class Change {
  @internal
  const Change({
    required this.seq,
    required this.collection,
    required this.path,
    required this.op,
    required this.at,
  });

  /// The log position of this change. Rows are ordered by [seq], and
  /// `changesSince(seq)` returns changes with a strictly greater [seq].
  final int seq;

  /// The collection's model name, e.g. `Txn` (not the SQL table name).
  final String collection;

  /// The full document path, e.g. `accounts/a1/txns/t9`.
  final String path;

  /// Whether the document was written or deleted.
  final ChangeOp op;

  /// When the write was committed, in UTC.
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is Change &&
      other.seq == seq &&
      other.collection == collection &&
      other.path == path &&
      other.op == op &&
      other.at.microsecondsSinceEpoch == at.microsecondsSinceEpoch;

  @override
  int get hashCode => Object.hash(seq, collection, path, op, at);

  @override
  String toString() => 'Change(#$seq $op $path)';
}

/// One touched (SQL table, document path, operation) triple — the identity
/// of a change inside one commit, without the log's [Change.seq] and
/// [Change.at].
typedef TouchedChange = (String table, String path, ChangeOp op);

/// The internal notification one committed transaction produces: the set of
/// (table, path, op) triples it touched.
///
/// Emitted after the transaction's cache updates were applied; never for a
/// rolled-back transaction.
@internal
final class CommitEvent {
  @internal
  const CommitEvent(this.touched);

  /// Every (SQL table, document path, operation) the transaction touched.
  final Set<TouchedChange> touched;
}
