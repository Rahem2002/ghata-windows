import 'dart:convert';
import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:supabase_flutter/supabase_flutter.dart';

class OfflineDatabase {
  OfflineDatabase._();

  static final OfflineDatabase instance = OfflineDatabase._();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;

    if (Platform.isWindows) {
      ffi.sqfliteFfiInit();
    }

    final dbPath = Platform.isWindows
        ? await ffi.databaseFactoryFfi.getDatabasesPath()
        : await getDatabasesPath();
    final path = p.join(dbPath, 'ghata_offline.db');

    _database = Platform.isWindows
        ? await ffi.databaseFactoryFfi.openDatabase(
            path,
            options: ffi.OpenDatabaseOptions(
              version: 3,
              onCreate: (db, version) async {
                await _createTables(db);
              },
              onUpgrade: (db, oldVersion, newVersion) async {
                if (oldVersion < 2) {
                  await db.execute('''
                    CREATE TABLE IF NOT EXISTS offline_operations (
                      operation_id INTEGER PRIMARY KEY AUTOINCREMENT,
                      operation_type TEXT NOT NULL,
                      table_name TEXT,
                      record_id TEXT,
                      payload TEXT,
                      rpc_name TEXT,
                      rpc_params TEXT,
                      created_at TEXT NOT NULL,
                      attempts INTEGER NOT NULL DEFAULT 0,
                      last_error TEXT
                    )
                  ''');
                  await db.execute('''
                    CREATE INDEX IF NOT EXISTS idx_offline_operations_created
                    ON offline_operations(created_at)
                  ''');
                }
                  if (oldVersion < 3) {
                    await _upgradeToV3(db);
                  }
              },
            ),
          )
        : await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS offline_operations (
              operation_id INTEGER PRIMARY KEY AUTOINCREMENT,
              operation_type TEXT NOT NULL,
              table_name TEXT,
              record_id TEXT,
              payload TEXT,
              rpc_name TEXT,
              rpc_params TEXT,
              created_at TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0,
              last_error TEXT
            )
          ''');

          await db.execute('''
            CREATE INDEX IF NOT EXISTS idx_offline_operations_created
            ON offline_operations(created_at)
          ''');
        }
          if (oldVersion < 3) {
            await _upgradeToV3(db);
          }
      },
    );

    return _database!;
  }

  Future<void> _upgradeToV3(Database db) async {
    final recordColumns = await db.rawQuery(
      'PRAGMA table_info(offline_records)',
    );

    final recordHasUserId =
        recordColumns.any((row) => row['name']?.toString() == 'user_id');

    if (!recordHasUserId) {
      await db.execute(
        'ALTER TABLE offline_records ADD COLUMN user_id TEXT',
      );
    }

    final operationColumns = await db.rawQuery(
      'PRAGMA table_info(offline_operations)',
    );

    final operationHasUserId =
        operationColumns.any((row) => row['name']?.toString() == 'user_id');

    if (!operationHasUserId) {
      await db.execute(
        'ALTER TABLE offline_operations ADD COLUMN user_id TEXT',
      );
    }

    final records = await db.query('offline_records');

    for (final row in records) {
      final localId = row['local_id'];
      final rawPayload = row['payload']?.toString();

      if (localId == null || rawPayload == null || rawPayload.isEmpty) {
        continue;
      }

      String userId = '';

      try {
        final payload = Map<String, dynamic>.from(
          jsonDecode(rawPayload) as Map,
        );

        userId = payload['user_id']?.toString().trim() ?? '';
      } catch (_) {}

      // Do not assign unknown legacy data to whichever account
      // happens to be signed in during migration.
      if (userId.isNotEmpty) {
        await db.update(
          'offline_records',
          {'user_id': userId},
          where: 'local_id = ?',
          whereArgs: [localId],
        );
      }
    }

    await db.execute('DROP TABLE IF EXISTS offline_records_v3');

    await db.execute('''
      CREATE TABLE offline_records_v3 (
        local_id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        table_name TEXT NOT NULL,
        record_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        sync_status INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        UNIQUE(user_id, table_name, record_id)
      )
    ''');

    await db.execute('''
      INSERT INTO offline_records_v3 (
        local_id,
        user_id,
        table_name,
        record_id,
        payload,
        sync_status,
        deleted,
        updated_at
      )
      SELECT
        local_id,
        user_id,
        table_name,
        record_id,
        payload,
        sync_status,
        deleted,
        updated_at
      FROM offline_records
      WHERE user_id IS NOT NULL AND user_id <> ''
    ''');

    await db.execute('DROP TABLE offline_records');

    await db.execute(
      'ALTER TABLE offline_records_v3 RENAME TO offline_records',
    );

    await db.execute('''
      CREATE INDEX idx_offline_records_table
      ON offline_records(table_name)
    ''');

    await db.execute('''
      CREATE INDEX idx_offline_records_sync
      ON offline_records(sync_status)
    ''');

    await db.execute('''
      CREATE INDEX idx_offline_records_user
      ON offline_records(user_id)
    ''');

    final operations = await db.query('offline_operations');

    for (final row in operations) {
      final operationId = row['operation_id'];
      if (operationId == null) continue;

      String userId = row['user_id']?.toString().trim() ?? '';

      if (userId.isEmpty) {
        for (final field in ['payload', 'rpc_params']) {
          final raw = row[field]?.toString();
          if (raw == null || raw.isEmpty) continue;

          try {
            final data = Map<String, dynamic>.from(
              jsonDecode(raw) as Map,
            );

            userId = data['user_id']?.toString().trim() ?? '';

            if (userId.isNotEmpty) break;
          } catch (_) {}
        }
      }

      // Unknown-owner legacy operations remain unassigned.
      // This prevents cross-account queue ownership.
      if (userId.isNotEmpty) {
        await db.update(
          'offline_operations',
          {'user_id': userId},
          where: 'operation_id = ?',
          whereArgs: [operationId],
        );
      }
    }

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_offline_operations_user
      ON offline_operations(user_id)
    ''');
  }

  String _requireUserId() {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      throw StateError('No authenticated account for offline data.');
    }
    return user.id;
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE offline_records (
        local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id TEXT NOT NULL,
        table_name TEXT NOT NULL,
        record_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        sync_status INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        UNIQUE(user_id, table_name, record_id)
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_offline_records_table
      ON offline_records(table_name)
    ''');

    await db.execute('''
      CREATE INDEX idx_offline_records_sync
      ON offline_records(sync_status)
    ''');

    await db.execute('''
      CREATE TABLE offline_operations (
        operation_id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        table_name TEXT,
        record_id TEXT,
        payload TEXT,
        rpc_name TEXT,
        rpc_params TEXT,
        created_at TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_offline_operations_created
      ON offline_operations(created_at)
    ''');
  }

  Future<void> saveRecord(
    String table,
    Map<String, dynamic> data, {
    bool synced = false,
  }) async {
    final db = await database;
    final userId = _requireUserId();

    final id = data['id']?.toString();

    if (id == null || id.isEmpty) {
      throw ArgumentError('Record must contain an id.');
    }

    final ownedData = <String, dynamic>{
      ...data,
      'user_id': userId,
    };

    await db.insert(
      'offline_records',
      {
        'user_id': userId,
        'table_name': table,
        'record_id': id,
        'payload': jsonEncode(ownedData),
        'sync_status': synced ? 1 : 0,
        'deleted': ownedData['deleted_at'] == null ? 0 : 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> saveLocalRecord(
    String table,
    Map<String, dynamic> data, {
    String operationType = 'upsert',
  }) async {
    await saveRecord(table, data, synced: false);

    await queueOperation(
      operationType: operationType,
      table: table,
      recordId: data['id']?.toString(),
      payload: data,
    );
  }

  Future<List<Map<String, dynamic>>> getRecords(
    String table, {
    bool includeDeleted = false,
  }) async {
    final db = await database;
    final userId = _requireUserId();

    final rows = await db.query(
      'offline_records',
      where: includeDeleted
          ? 'user_id = ? AND table_name = ?'
          : 'user_id = ? AND table_name = ? AND deleted = 0',
      whereArgs: [userId, table],
      orderBy: 'updated_at DESC',
    );

    return rows.map((row) {
      return Map<String, dynamic>.from(
        jsonDecode(row['payload'] as String) as Map,
      );
    }).toList();
  }

  Future<Map<String, dynamic>?> getRecord(
    String table,
    String id, {
    bool includeDeleted = false,
  }) async {
    final db = await database;
    final userId = _requireUserId();

    final rows = await db.query(
      'offline_records',
      where: includeDeleted
          ? 'user_id = ? AND table_name = ? AND record_id = ?'
          : 'user_id = ? AND table_name = ? AND record_id = ? AND deleted = 0',
      whereArgs: [userId, table, id],
      limit: 1,
    );

    if (rows.isEmpty) return null;

    return Map<String, dynamic>.from(
      jsonDecode(rows.first['payload'] as String) as Map,
    );
  }

  Future<void> updateLocalRecord(
    String table,
    String id,
    Map<String, dynamic> changes,
  ) async {
    final current = await getRecord(
      table,
      id,
      includeDeleted: true,
    );

    if (current == null) return;

    final updated = <String, dynamic>{
      ...current,
      ...changes,
      'id': id,
    };

    await saveLocalRecord(
      table,
      updated,
      operationType: 'upsert',
    );
  }

  Future<void> softDeleteLocalRecord(
    String table,
    String id,
  ) async {
    final deletedAt = DateTime.now().toUtc().toIso8601String();

    final current = await getRecord(
      table,
      id,
      includeDeleted: true,
    );

    if (current == null) return;

    final updated = <String, dynamic>{
      ...current,
      'id': id,
      'deleted_at': deletedAt,
    };

    await saveRecord(table, updated, synced: false);

    await queueOperation(
      operationType: 'soft_delete',
      table: table,
      recordId: id,
      payload: {'deleted_at': deletedAt},
    );
  }

  Future<void> restoreLocalRecord(
    String table,
    String id,
  ) async {
    final current = await getRecord(
      table,
      id,
      includeDeleted: true,
    );

    if (current == null) return;

    final updated = <String, dynamic>{
      ...current,
      'id': id,
      'deleted_at': null,
    };

    await saveRecord(table, updated, synced: false);

    await queueOperation(
      operationType: 'restore',
      table: table,
      recordId: id,
      payload: {'deleted_at': null},
    );
  }

  Future<void> permanentlyDeleteLocalOnlyRecord(
    String table,
    String id,
  ) async {
    final db = await database;
    final userId = _requireUserId();

    await db.delete(
      'offline_records',
      where: 'user_id = ? AND table_name = ? AND record_id = ?',
      whereArgs: [userId, table, id],
    );
  }

  Future<void> permanentlyDeleteLocalRecord(
    String table,
    String id,
  ) async {
    final db = await database;
    final userId = _requireUserId();

    await db.delete(
      'offline_records',
      where: 'user_id = ? AND table_name = ? AND record_id = ?',
      whereArgs: [userId, table, id],
    );

    await queueOperation(
      operationType: 'delete',
      table: table,
      recordId: id,
    );
  }

  Future<void> queueOperation({
    required String operationType,
    String? table,
    String? recordId,
    Map<String, dynamic>? payload,
    String? rpcName,
    Map<String, dynamic>? rpcParams,
  }) async {
    final db = await database;
    final userId = _requireUserId();

    await db.insert(
      'offline_operations',
      {
        'user_id': userId,
        'operation_type': operationType,
        'table_name': table,
        'record_id': recordId,
        'payload': payload == null ? null : jsonEncode(payload),
        'rpc_name': rpcName,
        'rpc_params': rpcParams == null ? null : jsonEncode(rpcParams),
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'attempts': 0,
        'last_error': null,
      },
    );
  }

  Future<void> queueRpc(
    String rpcName,
    Map<String, dynamic> params,
  ) async {
    await queueOperation(
      operationType: 'rpc',
      rpcName: rpcName,
      rpcParams: params,
    );
  }

  Future<List<Map<String, dynamic>>> pendingOperations() async {
    final db = await database;
    final userId = _requireUserId();

    final rows = await db.query(
      'offline_operations',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'operation_id ASC',
    );

    // sqflite query results can be read-only. The sync worker sorts this
    // collection by dependency priority, so return a mutable copy.
    return rows
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: true);
  }

  Future<void> completeOperation(int operationId) async {
    final db = await database;
    final userId = _requireUserId();

    await db.delete(
      'offline_operations',
      where: 'user_id = ? AND operation_id = ?',
      whereArgs: [userId, operationId],
    );
  }

  Future<void> failOperation(
    int operationId,
    Object error, {
    bool incrementAttempts = true,
  }) async {
    final db = await database;
    final userId = _requireUserId();

    await db.rawUpdate(
      incrementAttempts
          ? '''
      UPDATE offline_operations
      SET attempts = attempts + 1, last_error = ?
      WHERE user_id = ? AND operation_id = ?
      '''
          : '''
      UPDATE offline_operations
      SET last_error = ?
      WHERE user_id = ? AND operation_id = ?
      ''',
      [error.toString(), userId, operationId],
    );
  }

  Future<void> resetOperationFailures() async {
    final db = await database;
    final userId = _requireUserId();
    await db.update(
      'offline_operations',
      {'attempts': 0, 'last_error': null},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  Future<void> completeRecordOperations({
    required String table,
    required String recordId,
    Set<String>? operationTypes,
  }) async {
    final db = await database;
    final userId = _requireUserId();

    if (operationTypes == null || operationTypes.isEmpty) {
      await db.delete(
        'offline_operations',
        where: 'user_id = ? AND table_name = ? AND record_id = ?',
        whereArgs: [userId, table, recordId],
      );
      return;
    }

    final placeholders =
        List.filled(operationTypes.length, '?').join(',');

    await db.delete(
      'offline_operations',
      where:
          'user_id = ? AND table_name = ? AND record_id = ? '
          'AND operation_type IN ($placeholders)',
      whereArgs: [
        userId,
        table,
        recordId,
        ...operationTypes,
      ],
    );
  }

  Future<void> markSynced(
    String table,
    String id,
  ) async {
    final db = await database;
    final userId = _requireUserId();

    await db.update(
      'offline_records',
      {'sync_status': 1},
      where: 'user_id = ? AND table_name = ? AND record_id = ?',
      whereArgs: [userId, table, id],
    );
  }

  Future<void> cacheServerRecords(
    String table,
    List<dynamic> records,
  ) async {
    final db = await database;
    final userId = _requireUserId();

    for (final item in records) {
      if (item is! Map) continue;

      final record = Map<String, dynamic>.from(item);
      final id = record['id']?.toString();

      if (id == null || id.isEmpty) continue;

      // If this record was permanently deleted locally but the delete
      // operation has not reached the server yet, do not resurrect it
      // from an older server cache refresh.
      final pendingDelete = await db.query(
        'offline_operations',
        columns: ['operation_id'],
        where:
              'user_id = ? AND operation_type = ? AND table_name = ? AND record_id = ?',
          whereArgs: [userId, 'delete', table, id],
        limit: 1,
      );

      if (pendingDelete.isNotEmpty) {
        continue;
      }

      final existing = await db.query(
        'offline_records',
        columns: ['sync_status'],
          where: 'user_id = ? AND table_name = ? AND record_id = ?',
          whereArgs: [userId, table, id],
        limit: 1,
      );

      // Never overwrite an unsynced local edit with older server data.
      if (existing.isNotEmpty &&
          (existing.first['sync_status'] as int? ?? 0) == 0) {
        continue;
      }

      await saveRecord(
        table,
        record,
        synced: true,
      );
    }
  }

  Future<void> clearAllLocalData() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('offline_operations');
      await txn.delete('offline_records');
    });
  }


  Future<Map<String, dynamic>> syncDiagnostics() async {
    final db = await database;
    final userId = _requireUserId();

    final operations = await db.query(
      'offline_operations',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'operation_id ASC',
    );

    int failed = 0;
    int attempted = 0;
    final problems = <Map<String, dynamic>>[];

    for (final operation in operations) {
      final attempts =
          int.tryParse(operation['attempts']?.toString() ?? '0') ?? 0;
      final error =
          operation['last_error']?.toString().trim() ?? '';

      if (attempts > 0) attempted++;
      if (error.isNotEmpty) failed++;

      if (attempts > 0 || error.isNotEmpty) {
        problems.add(<String, dynamic>{
          'operation_id': operation['operation_id'],
          'operation_type': operation['operation_type'],
          'table_name': operation['table_name'],
          'record_id': operation['record_id'],
          'attempts': attempts,
          'last_error': error,
        });
      }
    }

    return <String, dynamic>{
      'pending': operations.length,
      'attempted': attempted,
      'failed': failed,
      'problems': problems,
    };
  }

  Future<int> pendingOperationCount() async {
    final db = await database;
    final userId = _requireUserId();

    final result = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM offline_operations WHERE user_id = ?',
      [userId],
    );

    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> close() async {
    final db = _database;

    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
