import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class OfflineDatabase {
  OfflineDatabase._();

  static final OfflineDatabase instance = OfflineDatabase._();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;

    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'ghata_offline.db');

    _database = await openDatabase(
      path,
      version: 2,
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
      },
    );

    return _database!;
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE offline_records (
        local_id INTEGER PRIMARY KEY AUTOINCREMENT,
        table_name TEXT NOT NULL,
        record_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        sync_status INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        UNIQUE(table_name, record_id)
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

    final id = data['id']?.toString();

    if (id == null || id.isEmpty) {
      throw ArgumentError('Record must contain an id.');
    }

    await db.insert(
      'offline_records',
      {
        'table_name': table,
        'record_id': id,
        'payload': jsonEncode(data),
        'sync_status': synced ? 1 : 0,
        'deleted': data['deleted_at'] == null ? 0 : 1,
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

    final rows = await db.query(
      'offline_records',
      where: includeDeleted
          ? 'table_name = ?'
          : 'table_name = ? AND deleted = 0',
      whereArgs: [table],
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

    final rows = await db.query(
      'offline_records',
      where: includeDeleted
          ? 'table_name = ? AND record_id = ?'
          : 'table_name = ? AND record_id = ? AND deleted = 0',
      whereArgs: [table, id],
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

  Future<void> permanentlyDeleteLocalRecord(
    String table,
    String id,
  ) async {
    final db = await database;

    await db.delete(
      'offline_records',
      where: 'table_name = ? AND record_id = ?',
      whereArgs: [table, id],
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

    await db.insert(
      'offline_operations',
      {
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

    return db.query(
      'offline_operations',
      orderBy: 'operation_id ASC',
    );
  }

  Future<void> completeOperation(int operationId) async {
    final db = await database;

    await db.delete(
      'offline_operations',
      where: 'operation_id = ?',
      whereArgs: [operationId],
    );
  }

  Future<void> failOperation(
    int operationId,
    Object error,
  ) async {
    final db = await database;

    await db.rawUpdate(
      '''
      UPDATE offline_operations
      SET attempts = attempts + 1,
          last_error = ?
      WHERE operation_id = ?
      ''',
      [error.toString(), operationId],
    );
  }

  Future<void> markSynced(
    String table,
    String id,
  ) async {
    final db = await database;

    await db.update(
      'offline_records',
      {'sync_status': 1},
      where: 'table_name = ? AND record_id = ?',
      whereArgs: [table, id],
    );
  }

  Future<void> cacheServerRecords(
    String table,
    List<dynamic> records,
  ) async {
    final db = await database;

    for (final item in records) {
      if (item is! Map) continue;

      final record = Map<String, dynamic>.from(item);
      final id = record['id']?.toString();

      if (id == null || id.isEmpty) continue;

      final existing = await db.query(
        'offline_records',
        columns: ['sync_status'],
        where: 'table_name = ? AND record_id = ?',
        whereArgs: [table, id],
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

  Future<int> pendingOperationCount() async {
    final db = await database;

    final result = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM offline_operations',
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
