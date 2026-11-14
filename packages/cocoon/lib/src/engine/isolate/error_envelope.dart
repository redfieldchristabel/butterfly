/// Error transfer across the isolate modes' isolate boundaries.
///
/// A worker/helper isolate never sends the thrown error object itself: some
/// errors carry unsendable fields, and a rethrown copy loses the original
/// stack trace. Instead every failure crosses as an [ErrorEnvelope] — plain
/// strings plus a small details map — and the caller rebuilds the SAME
/// error type with the same message ([rebuildError]) when the type is one it
/// knows, or a [CocoonIsolateException] when it is not. The worker's stack
/// trace text travels along and becomes the rethrown error's stack trace.
library;

import 'package:meta/meta.dart';

import '../../cursor.dart';
import '../../migration.dart';
import '../aggregate.dart';
import '../backup.dart';
import '../changes.dart';
import '../format_migration.dart';
import '../query.dart';
import '../transaction_guard.dart';

/// The public error for a failure that crossed an isolate boundary and could
/// not be rebuilt as its original type (or for a worker/helper isolate that
/// crashed). Carries the original type name, its message and the worker
/// stack trace text, so nothing is silently lost.
final class CocoonIsolateException implements Exception {
  /// Builds the exception from the transferred fields.
  CocoonIsolateException({
    required this.typeName,
    required this.message,
    required this.stackTraceText,
    this.sourceIsolate = 'worker',
  });

  /// The original error's runtime type name, e.g. `LockError`.
  final String typeName;

  /// The original error's message (or toString for types without one).
  final String message;

  /// The stack trace the original error carried, as text.
  final String stackTraceText;

  /// Which isolate the error came from (`worker` or `helper`), for the
  /// message.
  final String sourceIsolate;

  @override
  String toString() =>
      'CocoonIsolateException: $typeName from the $sourceIsolate isolate: '
      '$message';
}

/// Serializes an error thrown inside a worker or helper isolate into the
/// plain-string envelope that crosses the isolate boundary.
@internal
ErrorEnvelope envelopeFrom(Object error, StackTrace stackTrace) {
  final details = <String, Object?>{};
  final type = error.runtimeType;
  if (error is MissingIndexException) {
    details['suggestedIndex'] = error.suggestedIndex;
    details['fixCommand'] = error.fixCommand;
  } else if (error is TransactionMisuseError) {
    details['operation'] = error.operation;
  } else if (error is CursorMismatchException) {
    details['expected'] = error.expected;
    details['actual'] = error.actual;
  } else if (error is SchemaTooNewException) {
    details['storedVersion'] = error.storedVersion;
    details['appVersion'] = error.appVersion;
  } else if (error is StorageFormatTooNewException) {
    details['path'] = error.path;
    details['formatVersion'] = error.formatVersion;
    details['maxSupported'] = error.maxSupported;
  } else if (error is ChangesPrunedException) {
    details['requestedSeq'] = error.requestedSeq;
    details['earliestSeq'] = error.earliestSeq;
  } else if (error is UnmirroredFieldException) {
    details['suggestedDeclaration'] = error.suggestedDeclaration;
  } else if (error is BackupFormatTooNewException) {
    details['path'] = error.path;
    details['formatVersion'] = error.formatVersion;
    details['maxSupported'] = error.maxSupported;
  } else if (error is NotCocoonBackupException) {
    details['path'] = error.path;
    details['reason'] = error.reason;
  } else if (error is BackupDamagedException) {
    details['path'] = error.path;
    details['reason'] = error.reason;
  }
  // ArgumentError / StateError / RangeError and friends carry everything in
  // their message and name; both are plain strings either way.
  return ErrorEnvelope(
    typeName: '$type',
    message: _messageOf(error),
    stackTraceText: stackTrace.toString(),
    details: details,
  );
}

/// The error's own `message` when it has one (every Cocoon error type, the
/// core errors, the SQLite exceptions), otherwise its `toString`.
String _messageOf(Object error) {
  if (error is ArgumentError) {
    final message = error.message;
    return message == null ? error.toString() : '$message';
  }
  final dynamic dynamicError = error;
  try {
    final dynamic message = dynamicError.message;
    if (message is String) {
      return message;
    }
  } on NoSuchMethodError {
    // Types without a message member: fall through to toString.
  }
  return error.toString();
}

/// The error envelope: plain sendable fields only.
final class ErrorEnvelope {
  /// Builds the envelope.
  const ErrorEnvelope({
    required this.typeName,
    required this.message,
    required this.stackTraceText,
    this.details = const {},
  });

  /// The original error's runtime type name.
  final String typeName;

  /// The original message (for an [ArgumentError]: its `message` field).
  final String message;

  /// The original stack trace, as text.
  final String stackTraceText;

  /// Extra fields of the known Cocoon error types.
  final Map<String, Object?> details;

  /// Rebuilds the error on the caller side: the same type and message for
  /// every Cocoon error type (the known Dart core errors included), or a
  /// [CocoonIsolateException] carrying the type name, message and stack
  /// text when the type cannot be rebuilt.
  Object rebuild() {
    switch (typeName) {
      case 'MissingIndexException':
        return MissingIndexException(
          message,
          suggestedIndex: details['suggestedIndex'] as String?,
          fixCommand: details['fixCommand'] as String?,
        );
      case 'TransactionMisuseError':
        return TransactionMisuseError.reconstruct(
          details['operation'] as String? ?? '',
          message,
        );
      case 'InvalidCursorException':
        return InvalidCursorException(message);
      case 'CursorMismatchException':
        return CursorMismatchException(
          expected: details['expected']! as String,
          actual: details['actual']! as String,
        );
      case 'SchemaTooNewException':
        return SchemaTooNewException(
          details['storedVersion']! as int,
          details['appVersion']! as int,
        );
      case 'StorageFormatTooNewException':
        return StorageFormatTooNewException(
          path: details['path']! as String,
          formatVersion: details['formatVersion']! as int,
          maxSupported: details['maxSupported']! as int,
        );
      case 'ChangesPrunedException':
        return ChangesPrunedException(
          requestedSeq: details['requestedSeq']! as int,
          earliestSeq: details['earliestSeq']! as int,
        );
      case 'UnmirroredFieldException':
        return UnmirroredFieldException(
          message,
          suggestedDeclaration: details['suggestedDeclaration'] as String?,
        );
      case 'AggregateOverflowException':
        return AggregateOverflowException(message);
      case 'NotCocoonBackupException':
        return NotCocoonBackupException(
          details['path']! as String,
          details['reason']! as String,
        );
      case 'BackupDamagedException':
        return BackupDamagedException(
          details['path']! as String,
          details['reason']! as String,
        );
      case 'BackupFormatTooNewException':
        return BackupFormatTooNewException(
          path: details['path']! as String,
          formatVersion: details['formatVersion']! as int,
          maxSupported: details['maxSupported']! as int,
        );
      case 'ArgumentError':
        return ArgumentError(message, details['name'] as String?);
      case 'RangeError':
        return RangeError(message);
      case 'StateError':
        return StateError(message);
      case 'FormatException':
        return FormatException(message);
      case '_TypeError':
      case 'TypeError':
        return TypeError();
      case 'UnsupportedError':
        return UnsupportedError(message);
      case 'UnimplementedError':
        return UnimplementedError(message);
      case 'ConcurrentModificationError':
        return ConcurrentModificationError();
      case 'OutOfMemoryError':
        return OutOfMemoryError();
      case 'StackOverflowError':
        return StackOverflowError();
    }
    return CocoonIsolateException(
      typeName: typeName,
      message: message,
      stackTraceText: stackTraceText,
    );
  }
}
