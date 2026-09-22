import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_database.dart';

class OfflineSyncService {
  OfflineSyncService._();

  static final OfflineSyncService instance = OfflineSyncService._();

  Future<void>? _activeSync;

  static const Duration _networkTimeout = Duration(seconds: 20);

  Future<void> syncPending() {
    final active = _activeSync;
    if (active != null) {
      return active;
    }

    final sync = _runPendingSync();
    _activeSync = sync;

    return sync.whenComplete(() {
      if (identical(_activeSync, sync)) {
        _activeSync = null;
      }
    });
  }

  Future<void> _runPendingSync() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    try {
      final operations =
          await OfflineDatabase.instance.pendingOperations();

      // Dependency-safe queue order.
      // Exchange parents must be available before exchange_entries children.
      operations.sort((a, b) {
        int priority(Map<String, dynamic> operation) {
          final type =
              operation['operation_type']?.toString() ?? '';
          final table =
              operation['table_name']?.toString() ?? '';

          if (type == 'upsert' && table == 'exchanges') {
            return 10;
          }

          if (type == 'upsert' &&
              table == 'exchange_entries') {
            return 20;
          }

          return 15;
        }

        final result = priority(a).compareTo(priority(b));
        if (result != 0) return result;

        final aId = int.tryParse(
              a['operation_id']?.toString() ?? '',
            ) ??
            0;
        final bId = int.tryParse(
              b['operation_id']?.toString() ?? '',
            ) ??
            0;

        return aId.compareTo(bId);
      });

      // A failure for one record must not block unrelated records.
      // If a record fails, later operations for that same record are
      // skipped during this pass so its operation order stays intact.
      final blockedRecords = <String>{};
      final completedExchangeParents = <String>{};
      bool rpcBlocked = false;

      for (final operation in operations) {
        final operationId =
            int.tryParse(operation['operation_id']?.toString() ?? '');

        if (operationId == null) continue;

        final type =
            operation['operation_type']?.toString() ?? '';
        final table =
            operation['table_name']?.toString() ?? '';
        final recordId =
            operation['record_id']?.toString() ?? '';

        final recordKey =
            type == 'rpc' ? '' : '$table::$recordId';

        if (table == 'exchanges' &&
            completedExchangeParents.contains(recordId) &&
            (type == 'upsert' ||
                type == 'soft_delete' ||
                type == 'restore')) {
          continue;
        }

        if (type == 'rpc') {
          if (rpcBlocked) continue;
        } else if (blockedRecords.contains(recordKey)) {
          continue;
        }

        try {
          if (type == 'rpc') {
            await _syncRpc(operation);
          } else {
            final recoveredExchangeParentId =
                await _syncTableOperation(operation);

            if (recoveredExchangeParentId != null) {
              completedExchangeParents.add(
                recoveredExchangeParentId,
              );
            }
          }

          await OfflineDatabase.instance
              .completeOperation(operationId);
        } catch (e) {
          await OfflineDatabase.instance
              .failOperation(operationId, e);

          if (type == 'rpc') {
            // Keep RPC operations ordered relative to other RPCs.
            rpcBlocked = true;
          } else {
            // Preserve ordering only for this failed record.
            blockedRecords.add(recordKey);
          }

          // Continue with unrelated records instead of blocking
          // the entire offline sync queue.
          continue;
        }
      }
    } finally {
      // _activeSync is cleared by syncPending().whenComplete().
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

    await Supabase.instance.client
        .rpc(
          rpcName,
          params: params,
        )
        .timeout(_networkTimeout);
  }

  Future<void> _syncProfileUpsert(
    String recordId,
    Map<String, dynamic> payload,
  ) async {
    final user = Supabase.instance.client.auth.currentUser;

    if (user == null) {
      throw StateError('Not authenticated.');
    }

    // A profile operation may only update the signed-in user's profile.
    if (recordId != user.id) {
      throw StateError(
        'Profile operation belongs to another account.',
      );
    }

    final fullName =
        payload['full_name']?.toString().trim() ?? '';
    final username =
        payload['username']?.toString().trim() ?? '';

    if (fullName.isNotEmpty && username.isNotEmpty) {
      await Supabase.instance.client
          .rpc(
            'update_my_profile',
            params: {
              'new_full_name': fullName,
              'new_username': username,
            },
          )
          .timeout(_networkTimeout);
    }

    // Only user-editable business fields are restored.
    // System-managed fields and avatar_path are intentionally excluded.
    final businessFields = <String, dynamic>{};

    for (final key in const [
      'business_name',
      'business_phone',
      'business_address',
      'receipt_note',
    ]) {
      if (payload.containsKey(key)) {
        businessFields[key] = payload[key];
      }
    }

    if (businessFields.isNotEmpty) {
      await Supabase.instance.client
          .rpc(
            'update_my_business_profile',
            params: {
              'new_business_name':
                  businessFields['business_name']?.toString() ?? '',
              'new_business_phone':
                  businessFields['business_phone']?.toString() ?? '',
              'new_business_address':
                  businessFields['business_address']?.toString() ?? '',
              'new_receipt_note':
                  businessFields['receipt_note']?.toString() ?? '',
            },
          )
          .timeout(_networkTimeout);
    }

    await OfflineDatabase.instance.markSynced(
      'profiles',
      recordId,
    );
  }

  Future<String?> _ensureExchangeParent(
    Map<String, dynamic> entryPayload,
  ) async {
    final exchangeId =
        entryPayload['exchange_id']?.toString().trim() ?? '';

    if (exchangeId.isEmpty) {
      throw StateError(
        'Exchange entry is missing exchange_id.',
      );
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      throw StateError('Not authenticated.');
    }

    // First check whether the parent already exists remotely.
    final remote = await Supabase.instance.client
        .from('exchanges')
        .select('id')
        .eq('id', exchangeId)
        .maybeSingle()
        .timeout(_networkTimeout);

    if (remote != null) return null;

    // Parent is not available remotely. Recover it from the local
    // offline database instead of dropping the financial entry.
    final localParent =
        await OfflineDatabase.instance.getRecord(
      'exchanges',
      exchangeId,
      includeDeleted: true,
    );

    if (localParent == null) {
      throw StateError(
        'Exchange parent is missing locally and remotely: $exchangeId',
      );
    }

    final parentUserId =
        localParent['user_id']?.toString().trim() ?? '';

    if (parentUserId.isNotEmpty &&
        parentUserId != user.id) {
      throw StateError(
        'Exchange parent belongs to another account.',
      );
    }

    final safeParent =
        Map<String, dynamic>.from(localParent);

    if (parentUserId.isEmpty) {
      safeParent['user_id'] = user.id;
    }

    // Re-create the real local parent, including its deleted_at state.
    // This preserves recycle/history data and satisfies the FK.
    await Supabase.instance.client
        .from('exchanges')
        .upsert(safeParent)
        .timeout(_networkTimeout);

    await OfflineDatabase.instance.markSynced(
      'exchanges',
      exchangeId,
    );

    // The real current local parent state is now on the server.
    // Remove obsolete non-destructive parent operations so an older
    // upsert/soft-delete/restore cannot overwrite it later in this pass.
    await OfflineDatabase.instance.completeRecordOperations(
      table: 'exchanges',
      recordId: exchangeId,
      operationTypes: const {
        'upsert',
        'soft_delete',
        'restore',
      },
    );

    return exchangeId;
  }

  Future<String?> _syncTableOperation(
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
        if (table == 'profiles') {
          await _syncProfileUpsert(
            recordId,
            payload,
          );
          return null;
        } else {
          String? recoveredExchangeParentId;

          if (table == 'exchange_entries') {
            recoveredExchangeParentId =
                await _ensureExchangeParent(payload);
          }

          await Supabase.instance.client
              .from(table)
              .upsert(payload)
              .timeout(_networkTimeout);

          await OfflineDatabase.instance
              .markSynced(table, recordId);

          return recoveredExchangeParentId;
        }

      case 'soft_delete':
      case 'restore':
        await Supabase.instance.client
            .from(table)
            .update(payload)
            .eq('id', recordId)
            .timeout(_networkTimeout);

        await OfflineDatabase.instance
            .markSynced(table, recordId);
        return null;

      case 'delete':
        await Supabase.instance.client
            .from(table)
            .delete()
            .eq('id', recordId)
            .timeout(_networkTimeout);
        return null;

      default:
        throw StateError(
          'Unknown offline operation: $type',
        );
    }
  }
}
