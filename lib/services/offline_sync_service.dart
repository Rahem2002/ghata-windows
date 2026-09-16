import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_database.dart';

class OfflineSyncService {
  OfflineSyncService._();

  static final OfflineSyncService instance = OfflineSyncService._();

  bool _syncing = false;

  Future<void> syncPending() async {
    if (_syncing) return;

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    _syncing = true;

    try {
      final operations =
          await OfflineDatabase.instance.pendingOperations();

      for (final operation in operations) {
        final operationId =
            int.tryParse(operation['operation_id']?.toString() ?? '');

        if (operationId == null) continue;

        try {
          final type =
              operation['operation_type']?.toString() ?? '';

          if (type == 'rpc') {
            await _syncRpc(operation);
          } else {
            await _syncTableOperation(operation);
          }

          await OfflineDatabase.instance
              .completeOperation(operationId);
        } catch (e) {
          await OfflineDatabase.instance
              .failOperation(operationId, e);

          // Keep syncing independent operations.
          continue;
        }
      }
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncRpc(
    Map<String, dynamic> operation,
  ) async {
    final rpcName =
        operation['rpc_name']?.toString() ?? '';

    if (rpcName.isEmpty) {
      throw StateError('Missing RPC name.');
    }

    final rawParams =
        operation['rpc_params']?.toString();

    final params = rawParams == null || rawParams.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(
            jsonDecode(rawParams) as Map,
          );

    await Supabase.instance.client.rpc(
      rpcName,
      params: params,
    );
  }

  Future<void> _ensureExchangeParent(
    Map<String, dynamic> entry,
  ) async {
    final exchangeId = entry['exchange_id']?.toString() ?? '';

    if (exchangeId.isEmpty) {
      throw StateError('Exchange entry is missing exchange_id.');
    }

    final parent = await OfflineDatabase.instance.getRecord(
      'exchanges',
      exchangeId,
      includeDeleted: true,
    );

    if (parent == null) {
      throw StateError(
        'Exchange parent $exchangeId is missing from local data.',
      );
    }

    await Supabase.instance.client
        .from('exchanges')
        .upsert(parent);

    await OfflineDatabase.instance.markSynced(
      'exchanges',
      exchangeId,
    );
  }

  Future<void> _syncTableOperation(
    Map<String, dynamic> operation,
  ) async {
    final type =
        operation['operation_type']?.toString() ?? '';

    final table =
        operation['table_name']?.toString() ?? '';

    final recordId =
        operation['record_id']?.toString() ?? '';

    if (table.isEmpty || recordId.isEmpty) {
      throw StateError('Missing table or record id.');
    }

    final rawPayload =
        operation['payload']?.toString();

    final payload = rawPayload == null || rawPayload.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(
            jsonDecode(rawPayload) as Map,
          );

    switch (type) {
      case 'upsert':
        if (table == 'exchange_entries') {
          await _ensureExchangeParent(payload);
        }

        await Supabase.instance.client
            .from(table)
            .upsert(payload);

        await OfflineDatabase.instance
            .markSynced(table, recordId);
        break;

      case 'soft_delete':
      case 'restore':
        await Supabase.instance.client
            .from(table)
            .update(payload)
            .eq('id', recordId);

        await OfflineDatabase.instance
            .markSynced(table, recordId);
        break;

      case 'delete':
        await Supabase.instance.client
            .from(table)
            .delete()
            .eq('id', recordId);
        break;

      default:
        throw StateError(
          'Unknown offline operation: $type',
        );
    }
  }
}
