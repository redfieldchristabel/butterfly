/// Online, consistent backups and safe restores.
///
/// The engine owns the two file primitives — a consistent whole-database
/// copy ([BackupOperations.backupTo]) and a swap of a database file for one
/// of those copies ([BackupOperations.restore]) — while the app owns the
/// policy: where and when to back up, which collections matter, encryption,
/// compression, files stored outside the database, validation and UI. The
/// backup file is a plain SQLite database (created by SQLite's `VACUUM
/// INTO`, which compacts too) with Cocoon's backup metadata stamped into
/// its `_cocoon_meta` table; there is deliberately no app-level backup file
/// format, no cryptography and no export/import stream here.
///
/// Every SQLite statement these paths run lives in `sqlite_executor.dart`
/// (the only file allowed to import the SQLite packages); this file owns the
/// file protocol around them.
library;

import 'dart:io';

import 'package:meta/meta.dart';

import '../id.dart';
import 'naming.dart';
import 'sqlite_executor.dart';

/// The backup file format version written by `backupTo` and understood by
/// `inspectBackup` and `restoreBackup`.
const int backupFormatVersion = 1;

/// The Cocoon library version stamped into backups. Keep in sync with the
/// `version` in this package's `pubspec.yaml`.
const String cocoonLibraryVersion = '0.0.1';

/// Everything known about one Cocoon backup file.
///
/// [Cocoon.backupTo] returns it for the backup it just wrote; the static
/// `Cocoon.inspectBackup` reads it from an existing file; the static
/// `Cocoon.restoreBackup` returns the restored database's copy of it.
final class BackupInfo {
  /// The metadata [Cocoon.backupTo]/[Cocoon.inspectBackup] read and
  /// [Cocoon.restoreBackup] returns for the restored database's copy of it.
  BackupInfo({
    required this.path,
    required this.bytes,
    required this.createdAt,
    required this.formatVersion,
    required this.schemaVersion,
    required this.schemaLockHash,
    required this.lastChangeSeq,
    required this.cocoonVersion,
    this.storageFormatVersion,
  });

  /// The file the info describes: the backup path for `backupTo` and
  /// `inspectBackup`, the restored database path for `restoreBackup`.
  final String path;

  /// The file's size in bytes.
  final int bytes;

  /// When the backup was taken, in UTC (not when the file was last written).
  final DateTime createdAt;

  /// The backup file format version ([backupFormatVersion] when this Cocoon
  /// wrote it; a greater value from a newer app makes `inspectBackup` throw).
  final int formatVersion;

  /// The schema version the source database was migrated to, or `null` when
  /// the app opened it without `schemaVersion:` tracking.
  final int? schemaVersion;

  /// The fingerprint of the `cocoon.lock.json` the source app passed to
  /// `Cocoon.open` (`schemaLock:`), or `null` when it did not. Identical
  /// locks hash equal, so this pins the field numbering of the backup's
  /// wire data.
  final String? schemaLockHash;

  /// The change log head of the snapshot: a committed write either has a
  /// change row at or below this seq in the copy, or is not in it at all.
  /// Equal to the copy's `lastChangeSeq()` after a restore.
  final int lastChangeSeq;

  /// The Cocoon library version that wrote the backup.
  final String cocoonVersion;

  /// The storage format version the source database carried when the
  /// backup was taken, or `null` when the file predates format tracking.
  /// `Cocoon.restoreBackup` refuses a backup written in a NEWER storage
  /// format than this engine reads; an OLDER one restores fine and its
  /// tables are rebuilt at the next `Cocoon.open`.
  final int? storageFormatVersion;

  @override
  bool operator ==(Object other) =>
      other is BackupInfo &&
      other.path == path &&
      other.bytes == bytes &&
      other.createdAt.microsecondsSinceEpoch ==
          createdAt.microsecondsSinceEpoch &&
      other.formatVersion == formatVersion &&
      other.schemaVersion == schemaVersion &&
      other.schemaLockHash == schemaLockHash &&
      other.lastChangeSeq == lastChangeSeq &&
      other.cocoonVersion == cocoonVersion &&
      other.storageFormatVersion == storageFormatVersion;

  @override
  int get hashCode => Object.hash(
    path,
    bytes,
    createdAt.microsecondsSinceEpoch,
    formatVersion,
    schemaVersion,
    schemaLockHash,
    lastChangeSeq,
    cocoonVersion,
    storageFormatVersion,
  );

  @override
  String toString() =>
      'BackupInfo($path, $bytes bytes, format v$formatVersion, '
      'schema v$schemaVersion, seq #$lastChangeSeq)';
}

/// The file at [path] is readable SQLite but not a Cocoon backup: there is
/// no `_cocoon_meta` table, or there is one without a backup marker. A live
/// Cocoon database file (not written by `backupTo`) reports this too.
final class NotCocoonBackupException implements Exception {
  /// The file at [path] does not qualify as a backup; [reason] says what is
  /// missing.
  NotCocoonBackupException(this.path, this.reason);

  /// The inspected file.
  final String path;

  /// Why the file does not qualify as a Cocoon backup.
  final String reason;

  @override
  String toString() =>
      'NotCocoonBackupException: $path is not a Cocoon backup ($reason)';
}

/// The file at [path] is a Cocoon backup SQLite cannot fully read, or whose
/// self-description does not parse: `PRAGMA integrity_check` fails, the
/// bytes are not a database at all, or the backup metadata is corrupt.
final class BackupDamagedException implements Exception {
  /// The file could not be inspected: [reason] says whether the bytes are
  /// not a database at all or the metadata is corrupt.
  BackupDamagedException(this.path, this.reason);

  /// The inspected file.
  final String path;

  /// What is wrong with the file.
  final String reason;

  @override
  String toString() =>
      'BackupDamagedException: $path is damaged or unreadable ($reason)';
}

/// The file at [path] carries a backup format version this Cocoon does not
/// know how to read (a newer app wrote it). Restore the backup with the app
/// version that wrote it, or upgrade.
final class BackupFormatTooNewException implements Exception {
  /// The backup was written by a newer app; [formatVersion] exceeds this
  /// engine's [maxSupported].
  BackupFormatTooNewException({
    required this.path,
    required this.formatVersion,
    required this.maxSupported,
  });

  /// The inspected file.
  final String path;

  /// The format version the file was written with.
  final int formatVersion;

  /// The greatest format version this Cocoon understands.
  final int maxSupported;

  @override
  String toString() =>
      'BackupFormatTooNewException: $path was written in backup format '
      '$formatVersion; this Cocoon reads up to $maxSupported. The backup '
      'was written by a newer app version.';
}

/// The ordered file steps of a restore. Every step either succeeds or —
/// through the failure-injection seam below — throws before touching
/// anything, which is how the tests prove the original database survives a
/// failure at any point.
enum BackupRestoreStep {
  /// Copy the backup file to `<path>.restoring` and fsync it.
  copyBackup,

  /// Re-roll the copy's instance id.
  stampRestoring,

  /// Move the current database (and its WAL/journal sidecars) to
  /// `<path>.before-restore`.
  movePrevious,

  /// Remove any sidecars still sitting next to the target path.
  cleanSidecars,

  /// Rename `<path>.restoring` onto the target path.
  swap,

  /// fsync the swapped-in file.
  fsyncDir,
}

/// The backup/restore file protocols behind the `Cocoon` API methods.
final class BackupOperations {
  BackupOperations._();

  /// When set, the next [restore] throws a [StateError] just before the
  /// given step, without performing it. Test-only; cleared after one use.
  @visibleForTesting
  static BackupRestoreStep? debugFailBeforeStep;

  /// Copies the SQLite database at [sourcePath] to [targetPath] as one
  /// consistent, compacted backup, stamped with Cocoon's backup metadata.
  ///
  /// The copy is written to `<targetPath>.partial` (a leftover from a
  /// crashed backup is removed first), fsynced, then renamed onto
  /// [targetPath], so a failure anywhere before the rename leaves the
  /// previous [targetPath] file untouched and no partial behind. An existing
  /// [targetPath] is refused unless [overwrite] — and then still only
  /// replaced at the final rename, never destroyed by a failed attempt.
  static Future<BackupInfo> backupTo({
    required String sourcePath,
    required String targetPath,
    required bool overwrite,
  }) async {
    if (_absolutePath(sourcePath) == _absolutePath(targetPath)) {
      throw ArgumentError.value(
        targetPath,
        'path',
        'The backup target is the database file itself',
      );
    }
    final target = File(targetPath);
    if (target.existsSync() && !overwrite) {
      throw ArgumentError.value(
        targetPath,
        'path',
        'A file already exists here; pass overwrite: true to replace it',
      );
    }
    final partial = '$targetPath.partial';
    _deleteIfFile(partial);
    try {
      await vacuumInto(sourcePath: sourcePath, targetPath: partial);
      _fsyncFile(partial);
      final createdAt = DateTime.now().toUtc();
      final meta = await stampCocoonMeta(
        path: partial,
        values: {
          backupFormatVersionMetaKey: '$backupFormatVersion',
          backupCreatedAtMetaKey: '${createdAt.microsecondsSinceEpoch}',
          backupCocoonVersionMetaKey: cocoonLibraryVersion,
        },
        instanceId: newDocId(),
      );
      // The rename replaces any previous backup; its stale sidecars must go
      // first so they cannot pair with the new bytes.
      _deleteIfFile('$targetPath-wal');
      _deleteIfFile('$targetPath-shm');
      _deleteIfFile('$targetPath-journal');
      await File(partial).rename(targetPath);
      _fsyncFile(targetPath);
      return BackupInfo(
        path: targetPath,
        bytes: target.lengthSync(),
        createdAt: createdAt,
        formatVersion: backupFormatVersion,
        schemaVersion: meta.schemaVersion,
        schemaLockHash: meta.values[schemaLockHashMetaKey],
        lastChangeSeq: meta.lastChangeSeq,
        cocoonVersion: cocoonLibraryVersion,
        storageFormatVersion: meta.storageFormatVersion,
      );
    } on Object {
      _deleteIfFile(partial);
      rethrow;
    }
  }

  /// Reads [path]'s backup metadata, verifying with `PRAGMA
  /// integrity_check` that the bytes are a whole, healthy database.
  ///
  /// Throws [ArgumentError] when the file does not exist,
  /// [NotCocoonBackupException] when the file is not a Cocoon backup,
  /// [BackupDamagedException] when it cannot be read, and
  /// [BackupFormatTooNewException] when a newer app wrote it. The file's
  /// contents are never modified.
  static Future<BackupInfo> inspect(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw ArgumentError.value(path, 'path', 'No such file');
    }
    final RawFileMeta meta;
    try {
      meta = await readCocoonMeta(path, withIntegrity: true);
    } on Object catch (error) {
      throw BackupDamagedException(path, 'SQLite cannot read the file: $error');
    }
    final damaged = [
      for (final message in meta.integrity)
        if (message != 'ok') message,
    ];
    if (damaged.isNotEmpty) {
      throw BackupDamagedException(
        path,
        'PRAGMA integrity_check reported: '
        '${damaged.take(5).join('; ')}',
      );
    }
    if (!meta.hasCocoonMeta) {
      throw NotCocoonBackupException(
        path,
        'the file has no Cocoon metadata table (_cocoon_meta)',
      );
    }
    final rawVersion = meta.values[backupFormatVersionMetaKey];
    if (rawVersion == null) {
      throw NotCocoonBackupException(
        path,
        'the file carries no backup marker; a Cocoon database file is not '
        'a backup until backupTo wrote it',
      );
    }
    final version = int.tryParse(rawVersion);
    if (version == null || version < 1) {
      throw BackupDamagedException(
        path,
        'backup format version "$rawVersion" does not parse',
      );
    }
    if (version > backupFormatVersion) {
      throw BackupFormatTooNewException(
        path: path,
        formatVersion: version,
        maxSupported: backupFormatVersion,
      );
    }
    final createdAtMicros = int.tryParse(
      meta.values[backupCreatedAtMetaKey] ?? '',
    );
    if (createdAtMicros == null) {
      throw BackupDamagedException(
        path,
        'the backup carries no readable creation timestamp',
      );
    }
    return BackupInfo(
      path: path,
      bytes: file.lengthSync(),
      createdAt: DateTime.fromMicrosecondsSinceEpoch(
        createdAtMicros,
        isUtc: true,
      ),
      formatVersion: version,
      schemaVersion: meta.schemaVersion,
      schemaLockHash: meta.values[schemaLockHashMetaKey],
      lastChangeSeq: meta.lastChangeSeq,
      cocoonVersion: meta.values[backupCocoonVersionMetaKey] ?? '',
      storageFormatVersion: meta.storageFormatVersion,
    );
  }

  /// Swaps the database file at [targetPath] for the verified backup at
  /// [backupPath]; [info] is [inspect]'s result for it.
  ///
  /// The backup is copied to `<targetPath>.restoring` and fsynced, its
  /// instance id re-rolled (a restored database is a new instance — sync
  /// consumers must not trust a watermark saved against the old one), the
  /// current database moves to `<targetPath>.before-restore` together with
  /// its WAL/journal sidecars (deleted after the swap when
  /// [keepPrevious] is false; kept as the safety copy when true), any
  /// sidecars left at the target path are removed, and the copy is renamed
  /// onto the target path. A failure at any point undoes everything done so
  /// far and leaves the original database usable at [targetPath].
  static Future<BackupInfo> restore({
    required String backupPath,
    required String targetPath,
    required bool keepPrevious,
    required BackupInfo info,
  }) async {
    final injected = debugFailBeforeStep;
    debugFailBeforeStep = null;
    final restoring = '$targetPath.restoring';
    final before = '$targetPath.before-restore';
    var movedPrevious = false;
    try {
      _failBefore(injected, BackupRestoreStep.copyBackup);
      _deleteIfFile(restoring);
      await File(backupPath).copy(restoring);
      _fsyncFile(restoring);

      _failBefore(injected, BackupRestoreStep.stampRestoring);
      await stampCocoonMeta(
        path: restoring,
        values: const {},
        instanceId: newDocId(),
      );

      _failBefore(injected, BackupRestoreStep.movePrevious);
      final targetFile = File(targetPath);
      if (targetFile.existsSync()) {
        // A previous restore's safety copy is replaced by this one.
        _deleteIfFile(before);
        _deleteIfFile('$before-wal');
        _deleteIfFile('$before-journal');
        // The WAL and journal belong to the database file: they move with
        // it, so the safety copy is complete and the target path keeps none.
        // The -shm is a rebuildable index over the WAL — dropped.
        for (final suffix in const ['', '-wal', '-journal']) {
          final source = File('$targetPath$suffix');
          if (source.existsSync()) {
            await source.rename('$before$suffix');
          }
        }
        movedPrevious = true;
        _deleteIfFile('$targetPath-shm');
      }

      _failBefore(injected, BackupRestoreStep.cleanSidecars);
      _deleteIfFile('$targetPath-wal');
      _deleteIfFile('$targetPath-shm');
      _deleteIfFile('$targetPath-journal');

      _failBefore(injected, BackupRestoreStep.swap);
      await File(restoring).rename(targetPath);

      _failBefore(injected, BackupRestoreStep.fsyncDir);
      _fsyncFile(targetPath);

      if (movedPrevious && !keepPrevious) {
        _deleteIfFile(before);
        _deleteIfFile('$before-wal');
        _deleteIfFile('$before-journal');
      }
      return BackupInfo(
        path: targetPath,
        bytes: targetFile.lengthSync(),
        createdAt: info.createdAt,
        formatVersion: info.formatVersion,
        schemaVersion: info.schemaVersion,
        schemaLockHash: info.schemaLockHash,
        lastChangeSeq: info.lastChangeSeq,
        cocoonVersion: info.cocoonVersion,
        storageFormatVersion: info.storageFormatVersion,
      );
    } on Object catch (error, stackTrace) {
      // Whatever step failed: the original database goes back where it was.
      try {
        if (File(before).existsSync()) {
          await File(before).rename(targetPath);
          if (File('$before-wal').existsSync()) {
            await File('$before-wal').rename('$targetPath-wal');
          }
          if (File('$before-journal').existsSync()) {
            await File('$before-journal').rename('$targetPath-journal');
          }
        }
        _deleteIfFile(restoring);
      } on Object catch (undoError) {
        throw StateError(
          'Cocoon restore failed ($error) and putting the previous database '
          'back also failed ($undoError). The previous database file is '
          'still at $before — move it back to $targetPath by hand.',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  static void _failBefore(BackupRestoreStep? injected, BackupRestoreStep step) {
    if (injected == step) {
      throw StateError('Injected test failure before the $step step');
    }
  }

  /// fsyncs a file's contents (dart:io cannot fsync a directory, so the
  /// renames these protocols perform are file-durable; see the README).
  static void _fsyncFile(String path) {
    final handle = File(path).openSync(mode: FileMode.append);
    try {
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
  }

  static void _deleteIfFile(String path) {
    if (FileSystemEntity.isFileSync(path)) {
      File(path).deleteSync();
    }
  }

  static String _absolutePath(String path) => File(path).absolute.path;
}
