import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:file_selector/file_selector.dart';
import 'package:printing/printing.dart';
import 'services/offline_database.dart';
import 'services/offline_sync_service.dart';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';




const _ghataUuid = Uuid();


Widget ghataCurrencyFlagWidget(
  String currency, {
  double width = 26,
  double height = 18,
}) {
  try {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: CountryFlag.fromCurrencyCode(
        currency.toUpperCase(),
        theme: ImageTheme(
          width: width,
          height: height,
          shape: const RoundedRectangle(3),
        ),
      ),
    );
  } catch (_) {
    return SizedBox(
      width: width,
      height: height,
      child: const Icon(Icons.public, size: 16),
    );
  }
}


Widget ghataLanguageFlagWidget(
  String languageCode, {
  double width = 26,
  double height = 18,
}) {
  final countryCode = switch (languageCode) {
    'en' => 'GB',
    'ps' => 'AF',
    'fa' => 'AF',
    'ur' => 'PK',
    'ar' => 'SA',
    _ => 'GB',
  };

  return CountryFlag.fromCountryCode(
    countryCode,
    theme: ImageTheme(
      width: width,
      height: height,
      shape: const RoundedRectangle(3),
    ),
  );
}




Future<pw.Font> ghataPdfUnicodeFont() async {
  final data = await rootBundle.load(
    'assets/fonts/NotoNaskhArabic.ttf',
  );
  return pw.Font.ttf(data);
}




Future<String?> ghataPickCustomerPhoto(BuildContext context) async {
  try {
    if (Platform.isWindows) {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: 'Images',
            extensions: ['jpg', 'jpeg', 'png', 'webp'],
          ),
        ],
      );

      return file?.path;
    }

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.photo_camera_outlined),
                  title: Text(ghataT(context, 'Camera')),
                  onTap: () =>
                      Navigator.pop(sheetContext, ImageSource.camera),
                ),
                ListTile(
                  leading: Icon(Icons.photo_library_outlined),
                  title: Text(ghataT(context, 'Gallery')),
                  onTap: () =>
                      Navigator.pop(sheetContext, ImageSource.gallery),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (source == null) return null;

    final image = await ImagePicker().pickImage(
      source: source,
      imageQuality: 82,
      maxWidth: 1200,
    );

    return image?.path;
  } catch (e) {
    debugPrint('Customer photo picker error: $e');
    return null;
  }
}

String ghataPhotoExtension(String path) {
  final value = path.toLowerCase();
  if (value.endsWith('.png')) return '.png';
  if (value.endsWith('.webp')) return '.webp';
  return '.jpg';
}

Future<String> ghataCustomerPhotoDirectory() async {
  final root = await getApplicationDocumentsDirectory();
  final dir = Directory('${root.path}/customer_photos');

  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }

  return dir.path;
}

Future<String?> ghataSaveCustomerPhoto(
  String customerId,
  String sourcePath,
) async {
  try {
    final source = File(sourcePath);
    if (!await source.exists()) return null;

    final dir = await ghataCustomerPhotoDirectory();
    final ext = ghataPhotoExtension(sourcePath);
    final stamp =
        DateTime.now().toUtc().millisecondsSinceEpoch;
    final localPath =
        '$dir/${customerId}_$stamp$ext';
    final localFile = File(localPath);

    if (source.absolute.path != localFile.absolute.path) {
      await source.copy(localPath);
    }

    final customer =
        await OfflineDatabase.instance.getRecord(
      'customers',
      customerId,
      includeDeleted: true,
    );

    final previousCloudPath =
        customer?['photo_path']?.toString() ?? '';

    final user =
        Supabase.instance.client.auth.currentUser;

    if (user == null) {
      await OfflineDatabase.instance.saveRecord(
        'customer_photos',
        {
          'id': customerId,
          'photo_path': localPath,
          'cloud_path': previousCloudPath,
          'updated_at':
              DateTime.now().toUtc().toIso8601String(),
        },
        synced: true,
      );

      return localPath;
    }

    final cloudPath =
        '${user.id}/customers/${customerId}_$stamp$ext';

    try {
      await Supabase.instance.client.storage
          .from('ghata-media')
          .upload(
            cloudPath,
            localFile,
            fileOptions:
                const FileOptions(upsert: true),
          );

      await Supabase.instance.client
          .from('customers')
          .update({
            'photo_path': cloudPath,
          })
          .eq('id', customerId)
            .eq('user_id', user.id);

      await OfflineDatabase.instance.updateLocalRecord(
        'customers',
        customerId,
        {
          'photo_path': cloudPath,
        },
      );

      await OfflineDatabase.instance.saveRecord(
        'customer_photos',
        {
          'id': customerId,
          'photo_path': localPath,
          'cloud_path': cloudPath,
          'updated_at':
              DateTime.now().toUtc().toIso8601String(),
        },
        synced: true,
      );

      if (previousCloudPath.isNotEmpty &&
          previousCloudPath != cloudPath) {
        try {
          await Supabase.instance.client.storage
              .from('ghata-media')
              .remove([previousCloudPath]);
        } catch (e) {
          debugPrint(
            'Old customer photo cleanup failed: $e',
          );
        }
      }

      ghataScheduleAutomaticBackup();
    } catch (e) {
      debugPrint(
        'Customer cloud photo upload error: $e',
      );

      await OfflineDatabase.instance.saveRecord(
        'customer_photos',
        {
          'id': customerId,
          'photo_path': localPath,
          'cloud_path': previousCloudPath,
          'updated_at':
              DateTime.now().toUtc().toIso8601String(),
        },
        synced: true,
      );
    }

    return localPath;
  } catch (e) {
    debugPrint('Customer photo save error: $e');
    return null;
  }
}

Future<String?> ghataLoadCustomerPhoto(
  String customerId, {
  void Function(String localPath)? onBackgroundLoaded,
}) async {
  try {
    final cached =
        await OfflineDatabase.instance.getRecord(
      'customer_photos',
      customerId,
      includeDeleted: true,
    );

    final cachedLocalPath =
        cached?['photo_path']?.toString() ?? '';

    // Offline-first: if a valid local photo exists, return it immediately.
    if (cachedLocalPath.isNotEmpty &&
        await File(cachedLocalPath).exists()) {
      return cachedLocalPath;
    }

    final customer =
        await OfflineDatabase.instance.getRecord(
      'customers',
      customerId,
      includeDeleted: true,
    );

    final localCloudPath =
        customer?['photo_path']?.toString() ?? '';

    // Do not block the UI on Supabase or Storage.
    Future<void>(() async {
      try {
        final photoUser =
            Supabase.instance.client.auth.currentUser;
        if (photoUser == null) return;

        var cloudPath = localCloudPath;

        if (cloudPath.isEmpty) {
          final remote = await Supabase.instance.client
              .from('customers')
              .select('photo_path')
              .eq('id', customerId)
              .eq('user_id', photoUser.id)
              .maybeSingle();

          cloudPath =
              remote?['photo_path']?.toString() ?? '';
        }

        if (cloudPath.isEmpty) return;

        final bytes = await Supabase.instance.client.storage
            .from('ghata-media')
            .download(cloudPath);

        final dir = await ghataCustomerPhotoDirectory();
        final cloudName = cloudPath.split('/').last;
        final localPath = '$dir/$cloudName';

        await File(localPath).writeAsBytes(
          bytes,
          flush: true,
        );

        await OfflineDatabase.instance.saveRecord(
          'customer_photos',
          {
            'id': customerId,
            'photo_path': localPath,
            'cloud_path': cloudPath,
            'updated_at':
                DateTime.now().toUtc().toIso8601String(),
          },
          synced: true,
        );

        onBackgroundLoaded?.call(localPath);
      } catch (e) {
        debugPrint(
          'Customer photo background refresh failed: $e',
        );
      }
    });

    return null;
  } catch (e) {
    debugPrint('Customer photo local load error: $e');
    return null;
  }
}

Future<void> ghataDeleteCustomerPhoto(
  String customerId,
) async {
      final photoUser = Supabase.instance.client.auth.currentUser;
  try {
    final cached = await OfflineDatabase.instance.getRecord(
      'customer_photos',
      customerId,
      includeDeleted: true,
    );

    final localPath =
        cached?['photo_path']?.toString() ?? '';

    if (localPath.isNotEmpty) {
      final file = File(localPath);
      if (await file.exists()) await file.delete();
    }

    final customer = await OfflineDatabase.instance.getRecord(
      'customers',
      customerId,
      includeDeleted: true,
    );

    final cloudPath =
        customer?['photo_path']?.toString() ?? '';

    if (cloudPath.isNotEmpty) {
      try {
        await Supabase.instance.client.storage
            .from('ghata-media')
            .remove([cloudPath]);
      } catch (_) {}
    }

    try {
      await Supabase.instance.client
          .from('customers')
          .update({'photo_path': null})
            .eq('user_id', photoUser?.id ?? '')
          .eq('id', customerId);
    } catch (_) {}

    try {
      await OfflineDatabase.instance.updateLocalRecord(
        'customers',
        customerId,
        {'photo_path': null},
      );
    } catch (_) {}

    await OfflineDatabase.instance
        .permanentlyDeleteLocalOnlyRecord(
      'customer_photos',
      customerId,
    );

    ghataScheduleAutomaticBackup();
  } catch (e) {
    debugPrint('Customer photo delete error: $e');
  }
}


Future<String> ghataProfilePhotoDirectory() async {
  final root = await getApplicationDocumentsDirectory();
  final dir = Directory('${root.path}/profile_photos');

  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }

  return dir.path;
}

Future<String?> ghataSaveProfilePhoto(
  String sourcePath,
) async {
  try {
    final user =
        Supabase.instance.client.auth.currentUser;

    if (user == null) return null;

    final source = File(sourcePath);
    if (!await source.exists()) return null;

    final dir = await ghataProfilePhotoDirectory();
    final ext = ghataPhotoExtension(sourcePath);
    final stamp =
        DateTime.now().toUtc().millisecondsSinceEpoch;
    final localPath =
        '$dir/${user.id}_avatar_$stamp$ext';
    final localFile = File(localPath);

    if (source.absolute.path != localFile.absolute.path) {
      await source.copy(localPath);
    }

    final existing =
        await OfflineDatabase.instance.getRecord(
              'profiles',
              user.id,
              includeDeleted: true,
            ) ??
            <String, dynamic>{
              'id': user.id,
            };

    final previousCloudPath =
        existing['avatar_path']?.toString() ?? '';

    final cloudPath =
        '${user.id}/profile/avatar_$stamp$ext';

    await Supabase.instance.client.storage
        .from('ghata-media')
        .upload(
          cloudPath,
          localFile,
          fileOptions:
              const FileOptions(upsert: true),
        );

    await Supabase.instance.client
        .from('profiles')
        .update({
          'avatar_path': cloudPath,
        })
        .eq('id', user.id);

    await OfflineDatabase.instance.saveRecord(
      'profiles',
      {
        ...existing,
        'id': user.id,
        'avatar_path': cloudPath,
      },
      synced: true,
    );

    await OfflineDatabase.instance.saveRecord(
      'profile_photos',
      {
        'id': user.id,
        'photo_path': localPath,
        'cloud_path': cloudPath,
        'updated_at':
            DateTime.now().toUtc().toIso8601String(),
      },
      synced: true,
    );

    if (previousCloudPath.isNotEmpty &&
        previousCloudPath != cloudPath) {
      try {
        await Supabase.instance.client.storage
            .from('ghata-media')
            .remove([previousCloudPath]);
      } catch (e) {
        debugPrint(
          'Old profile photo cleanup failed: $e',
        );
      }
    }

    ghataScheduleAutomaticBackup();

    return localPath;
  } catch (e) {
    debugPrint('Profile photo save error: $e');
    return null;
  }
}

Future<String?> ghataLoadProfilePhoto({
  void Function(String localPath)? onBackgroundLoaded,
}) async {
  try {
    final user =
        Supabase.instance.client.auth.currentUser;

    if (user == null) return null;

    final cached =
        await OfflineDatabase.instance.getRecord(
      'profile_photos',
      user.id,
      includeDeleted: true,
    );

    final cachedLocalPath =
        cached?['photo_path']?.toString() ?? '';

    // Offline-first: use the cached local avatar immediately.
    if (cachedLocalPath.isNotEmpty &&
        await File(cachedLocalPath).exists()) {
      return cachedLocalPath;
    }

    final localProfile =
        await OfflineDatabase.instance.getRecord(
      'profiles',
      user.id,
      includeDeleted: true,
    );

    final localCloudPath =
        localProfile?['avatar_path']?.toString() ?? '';

    // Do not block Profile screen on Supabase or Storage.
    Future<void>(() async {
      try {
        var cloudPath = localCloudPath;

        if (cloudPath.isEmpty) {
          final remote = await Supabase.instance.client
              .from('profiles')
              .select('avatar_path')
              .eq('id', user.id)
              .maybeSingle();

          cloudPath =
              remote?['avatar_path']?.toString() ?? '';
        }

        if (cloudPath.isEmpty) return;

        final bytes = await Supabase.instance.client.storage
            .from('ghata-media')
            .download(cloudPath);

        final dir = await ghataProfilePhotoDirectory();
        final cloudName = cloudPath.split('/').last;
        final localPath =
            '$dir/${user.id}_$cloudName';

        await File(localPath).writeAsBytes(
          bytes,
          flush: true,
        );

        await OfflineDatabase.instance.saveRecord(
          'profile_photos',
          {
            'id': user.id,
            'photo_path': localPath,
            'cloud_path': cloudPath,
            'updated_at':
                DateTime.now().toUtc().toIso8601String(),
          },
          synced: true,
        );

        onBackgroundLoaded?.call(localPath);
      } catch (e) {
        debugPrint(
          'Profile photo background refresh failed: $e',
        );
      }
    });

    return null;
  } catch (e) {
    debugPrint('Profile photo local load error: $e');
    return null;
  }
}

Future<void> ghataDeleteProfilePhoto() async {
  try {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final cached =
        await OfflineDatabase.instance.getRecord(
      'profile_photos',
      user.id,
      includeDeleted: true,
    );

    final localPath =
        cached?['photo_path']?.toString() ?? '';

    if (localPath.isNotEmpty) {
      final file = File(localPath);
      if (await file.exists()) {
        await file.delete();
      }
    }

    final localProfile =
        await OfflineDatabase.instance.getRecord(
      'profiles',
      user.id,
      includeDeleted: true,
    );

    var cloudPath =
        localProfile?['avatar_path']?.toString() ?? '';

    if (cloudPath.isEmpty) {
      final remote = await Supabase.instance.client
          .from('profiles')
          .select('avatar_path')
          .eq('id', user.id)
          .maybeSingle();

      cloudPath =
          remote?['avatar_path']?.toString() ?? '';
    }

    if (cloudPath.isNotEmpty) {
      try {
        await Supabase.instance.client.storage
            .from('ghata-media')
            .remove([cloudPath]);
      } catch (_) {}
    }

    await Supabase.instance.client
        .from('profiles')
        .update({
          'avatar_path': null,
        })
        .eq('id', user.id);

    final existing =
        await OfflineDatabase.instance.getRecord(
              'profiles',
              user.id,
              includeDeleted: true,
            ) ??
            <String, dynamic>{
              'id': user.id,
            };

    await OfflineDatabase.instance.saveRecord(
      'profiles',
      {
        ...existing,
        'id': user.id,
        'avatar_path': null,
      },
      synced: true,
    );

    await OfflineDatabase.instance
        .permanentlyDeleteLocalOnlyRecord(
      'profile_photos',
      user.id,
    );

    ghataScheduleAutomaticBackup();
  } catch (e) {
    debugPrint('Profile photo delete error: $e');
  }
}


Future<void> ghataRefreshTransactionsCache() async {
  final user =
      Supabase.instance.client.auth.currentUser;

  if (user == null) return;

  try {
    final rows =
        await Supabase.instance.client
            .from('transactions')
            .select().eq('user_id', user.id);

    await OfflineDatabase.instance.cacheServerRecords(
      'transactions',
      List<Map<String, dynamic>>.from(rows),
    );
  } catch (e) {
    debugPrint(
      'Transactions cache refresh error: $e',
    );
  }
}


Future<void> ghataRefreshCustomersCache() async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return;

  try {
    final rows =
        await Supabase.instance.client.from('customers').select().eq('user_id', user.id);

    await OfflineDatabase.instance.cacheServerRecords(
      'customers',
      List<Map<String, dynamic>>.from(rows),
    );
  } catch (e) {
    debugPrint('Customer cache refresh error: $e');
  }
}

Future<Map<String, dynamic>?> ghataLoadBusinessProfile() async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return null;

  final local = await OfflineDatabase.instance.getRecord(
    'profiles',
    user.id,
    includeDeleted: true,
  );

  () async {
    try {
      final data = await Supabase.instance.client
          .from('profiles')
          .select(
            'full_name, username, business_name, business_phone, business_address, receipt_note, avatar_path',
          )
          .eq('id', user.id)
          .maybeSingle();

      if (data != null) {
        final record = <String, dynamic>{
          ...Map<String, dynamic>.from(data),
          'id': user.id,
        };

        await OfflineDatabase.instance.saveRecord(
          'profiles',
          record,
          synced: true,
        );
      }
    } catch (_) {}
  }();

  return local;
}


Future<void>? _ghataFullSyncFuture;

Future<void> ghataSyncAll() {
  final existing = _ghataFullSyncFuture;
  if (existing != null) return existing;

  late final Future<void> syncFuture;

  syncFuture = _ghataSyncAllImpl().whenComplete(() {
    if (identical(_ghataFullSyncFuture, syncFuture)) {
      _ghataFullSyncFuture = null;
    }
  });

  _ghataFullSyncFuture = syncFuture;
  return syncFuture;
}

Future<void> _ghataSyncAllImpl() async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return;

  try {
    // Important: upload local pending changes first.
    await OfflineSyncService.instance.syncPending();
  } catch (e) {
    debugPrint('Ghata pending upload failed: $e');
  }

  try {
    // Then pull the latest server state.
    // cacheServerRecords protects unsynced local records.
    await ghataRefreshOfflineCache();
  } catch (e) {
    debugPrint('Ghata server refresh failed: $e');
  }
}


Timer? _ghataAutomaticBackupTimer;
bool _ghataAutomaticBackupRunning = false;

void ghataScheduleAutomaticBackup() {
  _ghataAutomaticBackupTimer?.cancel();

  _ghataAutomaticBackupTimer = Timer(
    const Duration(seconds: 3),
    () {
      ghataCreateAutomaticBackup();
    },
  );
}

Future<Map<String, dynamic>> ghataBuildAutomaticBackup() async {
  final user = Supabase.instance.client.auth.currentUser;

  if (user == null) {
    throw StateError('Not signed in.');
  }

  final customers =
      await OfflineDatabase.instance.getRecords(
    'customers',
    includeDeleted: true,
  );

  final transactions =
      await OfflineDatabase.instance.getRecords(
    'transactions',
    includeDeleted: true,
  );

  final exchanges =
      await OfflineDatabase.instance.getRecords(
    'exchanges',
    includeDeleted: true,
  );

  final exchangeEntries =
      await OfflineDatabase.instance.getRecords(
    'exchange_entries',
    includeDeleted: true,
  );

  final profile =
      await OfflineDatabase.instance.getRecord(
    'profiles',
    user.id,
    includeDeleted: true,
  );

  return <String, dynamic>{
    'app': 'Ghata',
    'backup_type': 'automatic',
    'format_version': 1,
    'created_at':
        DateTime.now().toUtc().toIso8601String(),
    'user_id': user.id,
    'profile': profile,
    'customers': customers,
    'transactions': transactions,
    'exchanges': exchanges,
    'exchange_entries': exchangeEntries,
  };
}

Future<void> ghataCreateAutomaticBackup() async {
  if (_ghataAutomaticBackupRunning) {
    return;
  }

  final user =
      Supabase.instance.client.auth.currentUser;

  if (user == null) {
    return;
  }

  _ghataAutomaticBackupRunning = true;

  try {
    final backup =
        await ghataBuildAutomaticBackup();

    final root =
        await getApplicationDocumentsDirectory();

    final directory = Directory(
      '${root.path}/Ghata/backups',
    );

    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final safeUserId = user.id.replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '_',
    );

    final file = File(
      '${directory.path}/'
      'Ghata_Auto_Latest_$safeUserId.json',
    );

    final temp = File('${file.path}.tmp');

    final content =
        const JsonEncoder.withIndent(' ').convert(
      backup,
    );

    await temp.writeAsString(
      content,
      flush: true,
    );

    if (await file.exists()) {
      await file.delete();
    }

    await temp.rename(file.path);

    debugPrint(
      'Ghata automatic backup updated: '
      '${file.path}',
    );
  } catch (e) {
    debugPrint(
      'Ghata automatic backup failed: $e',
    );
  } finally {
    _ghataAutomaticBackupRunning = false;
  }
}

Future<void> ghataTrySync() async {
  try {
    await ghataSyncAll();
  } catch (_) {
    // Offline is allowed. Pending operations remain queued.
  }
}

Future<void> ghataSaveLocal(
  String table,
  Map<String, dynamic> record,
) async {
  await OfflineDatabase.instance.saveLocalRecord(
    table,
    record,
    operationType: 'upsert',
  );

  ghataScheduleAutomaticBackup();

  // Best effort only. Local save already succeeded.
  ghataTrySync();
}

Future<void> ghataSoftDeleteLocal(
  String table,
  String id,
) async {
  await OfflineDatabase.instance.softDeleteLocalRecord(table, id);
  ghataScheduleAutomaticBackup();
  ghataTrySync();
}


Future<void>? _ghataOfflineCacheRefreshFuture;

Future<void> ghataRefreshOfflineCache() {
  final existing = _ghataOfflineCacheRefreshFuture;
  if (existing != null) {
    return existing;
  }

  late final Future<void> refreshFuture;

  refreshFuture = _ghataOfflineCacheRefreshImpl().whenComplete(() {
    if (identical(_ghataOfflineCacheRefreshFuture, refreshFuture)) {
      _ghataOfflineCacheRefreshFuture = null;
    }
  });

  _ghataOfflineCacheRefreshFuture = refreshFuture;
  return refreshFuture;
}

Future<void> _ghataOfflineCacheRefreshImpl() async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return;

  try {
    final customers =
        await Supabase.instance.client.from('customers').select().eq('user_id', user.id);

    await OfflineDatabase.instance.cacheServerRecords(
      'customers',
      List<Map<String, dynamic>>.from(customers),
    );
  } catch (e) {
    debugPrint('Ghata customers cache refresh failed: $e');
  }

  try {
    final transactions =
        await Supabase.instance.client.from('transactions').select().eq('user_id', user.id);

    await OfflineDatabase.instance.cacheServerRecords(
      'transactions',
      List<Map<String, dynamic>>.from(transactions),
    );
  } catch (e) {
    debugPrint('Ghata transactions cache refresh failed: $e');
  }

    final exchangeIds = <String>[];

    try {
      final exchanges =
          await Supabase.instance.client
              .from('exchanges')
              .select()
              .eq('user_id', user.id);

      exchangeIds.addAll(
        List<Map<String, dynamic>>.from(exchanges)
            .map((row) => row['id']?.toString() ?? '')
            .where((id) => id.isNotEmpty),
      );

      await OfflineDatabase.instance.cacheServerRecords(
        'exchanges',
        List<Map<String, dynamic>>.from(exchanges),
      );
    } catch (e) {
      debugPrint('Ghata exchanges cache refresh failed: $e');
    }

    try {
      final entries = exchangeIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(
              await Supabase.instance.client
                  .from('exchange_entries')
                  .select()
                  .inFilter('exchange_id', exchangeIds),
            );

      await OfflineDatabase.instance.cacheServerRecords(
        'exchange_entries',
        entries,
      );
    } catch (e) {
      debugPrint('Ghata exchange entries cache refresh failed: $e');
    }

  try {
    final profiles =
        await Supabase.instance.client
            .from('profiles')
            .select().eq('id', user.id);

    await OfflineDatabase.instance.cacheServerRecords(
      'profiles',
      List<Map<String, dynamic>>.from(profiles),
    );
  } catch (e) {
    debugPrint(
      'Ghata profiles cache refresh failed: $e',
    );
  }
}

Future<List<Map<String, dynamic>>>
    ghataLocalExchangeEntriesWithExchange() async {
  final entries =
      await OfflineDatabase.instance.getRecords('exchange_entries');

  final exchanges =
      await OfflineDatabase.instance.getRecords(
    'exchanges',
    includeDeleted: true,
  );

  final exchangesById = <String, Map<String, dynamic>>{};

  for (final exchange in exchanges) {
    final id = exchange['id']?.toString() ?? '';
    if (id.isNotEmpty) {
      exchangesById[id] = exchange;
    }
  }

  final result = <Map<String, dynamic>>[];

  for (final entry in entries) {
    final exchangeId = entry['exchange_id']?.toString() ?? '';
    final exchange = exchangesById[exchangeId];

    if (exchange == null) continue;

    result.add({
      ...entry,
      'exchanges': exchange,
    });
  }

  return result;
}

Future<List<Map<String, dynamic>>> ghataLocalFinancialRows() async {
  ghataRefreshOfflineCache();

  final transactionData =
      await OfflineDatabase.instance.getRecords('transactions');

  final exchangeData =
      await ghataLocalExchangeEntriesWithExchange();

  final all = <Map<String, dynamic>>[];

  for (final row in transactionData) {
    final type = row['transaction_type']?.toString() ?? '';

    if ([
      'money_in',
      'money_out',
      'adjustment_in',
      'adjustment_out',
    ].contains(type)) {
      all.add(Map<String, dynamic>.from(row));
    }
  }

  for (final entry in exchangeData) {
    final entryType = entry['entry_type']?.toString() ?? '';
    final exchange = entry['exchanges'];

    if (exchange is! Map) continue;
    if (exchange['deleted_at'] != null) continue;

    if (entryType != 'money_in' && entryType != 'money_out') {
      continue;
    }

    all.add({
      'transaction_type':
          entryType == 'money_out' ? 'exchange_out' : 'exchange_in',
      'amount': entry['amount'],
      'currency': entry['currency'],
      'transaction_date': exchange['exchange_date'],
      'transaction_time': exchange['exchange_time'],
      'customer_id': exchange['customer_id'],
      'customer_name': exchange['customer_name'],
    });
  }

  return all;
}

double? evaluateCalculatorExpression(String input) {
  final expression = input
      .replaceAll('×', '*')
      .replaceAll('÷', '/')
      .replaceAll(',', '')
      .replaceAll(' ', '');

  if (expression.isEmpty) return null;

  var index = 0;

  double? parseExpression() {
    double? parseNumber() {
      var sign = 1.0;

      if (index < expression.length &&
          (expression[index] == '+' || expression[index] == '-')) {
        if (expression[index] == '-') sign = -1;
        index++;
      }

      double? value;

      if (index < expression.length && expression[index] == '(') {
        index++;
        value = parseExpression();

        if (value == null ||
            index >= expression.length ||
            expression[index] != ')') {
          return null;
        }

        index++;
      } else {
        final startNumber = index;
        var dotCount = 0;

        while (index < expression.length &&
            ((expression.codeUnitAt(index) >= 48 &&
                    expression.codeUnitAt(index) <= 57) ||
                expression[index] == '.')) {
          if (expression[index] == '.') dotCount++;
          if (dotCount > 1) return null;
          index++;
        }

        if (startNumber == index) return null;

        value = double.tryParse(
          expression.substring(startNumber, index),
        );

        if (value == null) return null;
      }

      value *= sign;

      if (index < expression.length && expression[index] == '%') {
        value /= 100;
        index++;
      }

      return value;
    }

    double? parseTerm() {
      var value = parseNumber();
      if (value == null) return null;

      while (index < expression.length &&
          (expression[index] == '*' || expression[index] == '/')) {
        final op = expression[index];
        index++;

        final right = parseNumber();
        if (right == null) return null;

        if (op == '*') {
          value = value! * right;
        } else {
          if (right == 0) return null;
          value = value! / right;
        }
      }

      return value;
    }

    var value = parseTerm();
    if (value == null) return null;

    while (index < expression.length &&
        (expression[index] == '+' || expression[index] == '-')) {
      final op = expression[index];
      index++;

      final percentStart = index;
      final right = parseTerm();
      if (right == null) return null;

      final rawRight =
          expression.substring(percentStart, index).endsWith('%');

      final amount = rawRight ? value! * right : right;

      if (op == '+') {
        value = value! + amount;
      } else {
        value = value! - amount;
      }
    }

    return value;
  }

  final result = parseExpression();

  if (result == null || index != expression.length) {
    return null;
  }

  return result;
}


class GhataCalculatorField extends StatelessWidget {
  GhataCalculatorField({
    super.key,
    required this.controller,
    required this.label,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final VoidCallback? onChanged;

  void _notify() => onChanged?.call();

  void _append(String value) {
    controller.text += value;
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    _notify();
  }

  void _toggleSign() {
    final text = controller.text.trim();

    if (text.isEmpty) {
      controller.text = '-';
    } else if (text.startsWith('-')) {
      controller.text = text.substring(1);
    } else {
      controller.text = '-$text';
    }

    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    _notify();
  }

  void _backspace() {
    if (controller.text.isEmpty) return;
    controller.text =
        controller.text.substring(0, controller.text.length - 1);
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    _notify();
  }

  void _clear() {
    controller.clear();
    _notify();
  }

  void _equals() {
    final result =
        evaluateCalculatorExpression(controller.text.trim());
    if (result == null) return;

    final isWhole = result == result.roundToDouble();
    controller.text =
        isWhole ? result.toInt().toString() : result.toString();

    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    _notify();
  }

  Future<void> _openCalculator(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void refresh(VoidCallback action) {
              action();
              setSheetState(() {});
            }

            Widget calcKey({
              required Widget child,
              required VoidCallback onPressed,
              bool primary = false,
            }) {
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.all(5),
                  child: SizedBox(
                    height: 68,
                    child: primary
                        ? FilledButton(
                            onPressed: onPressed,
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            child: child,
                          )
                        : FilledButton.tonal(
                            onPressed: onPressed,
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            child: child,
                          ),
                  ),
                ),
              );
            }

            Widget textKey(String key, {bool primary = false}) {
              return calcKey(
                primary: primary,
                onPressed: () {
                  if (key == '=') {
                    refresh(_equals);
                    Navigator.pop(sheetContext);
                  } else {
                    refresh(() => _append(key));
                  }
                },
                child: Text(
                  key,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              );
            }

            return Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) {
                  return KeyEventResult.ignored;
                }

                final character = event.character ?? '';
                final key = event.logicalKey;

                if (RegExp(r'^[0-9]$').hasMatch(character)) {
                  refresh(() => _append(character));
                  return KeyEventResult.handled;
                }

                if (character == '.') {
                  refresh(() => _append('.'));
                  return KeyEventResult.handled;
                }

                if (character == '+') {
                  refresh(() => _append('+'));
                  return KeyEventResult.handled;
                }

                if (character == '-') {
                  refresh(() => _append('-'));
                  return KeyEventResult.handled;
                }

                if (character == '*' || character == '×') {
                  refresh(() => _append('×'));
                  return KeyEventResult.handled;
                }

                if (character == '/' || character == '÷') {
                  refresh(() => _append('÷'));
                  return KeyEventResult.handled;
                }

                if (character == '%') {
                  refresh(() => _append('%'));
                  return KeyEventResult.handled;
                }

                if (key == LogicalKeyboardKey.backspace ||
                    key == LogicalKeyboardKey.delete) {
                  refresh(_backspace);
                  return KeyEventResult.handled;
                }

                if (key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.numpadEnter) {
                  refresh(_equals);
                  Navigator.pop(sheetContext);
                  return KeyEventResult.handled;
                }

                if (key == LogicalKeyboardKey.escape) {
                  Navigator.pop(sheetContext);
                  return KeyEventResult.handled;
                }

                return KeyEventResult.ignored;
              },
              child: SafeArea(
                child: Padding(
                padding: EdgeInsets.fromLTRB(14, 12, 14, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      constraints: BoxConstraints(minHeight: 80),
                      alignment: Alignment.centerRight,
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        controller.text.isEmpty ? '0' : controller.text,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    SizedBox(height: 8),

                    Row(
                      children: [
                        calcKey(
                          onPressed: () => refresh(_clear),
                          child: Text(
                            'AC',
                            style: TextStyle(fontSize: 22),
                          ),
                        ),
                        calcKey(
                          onPressed: () => refresh(_backspace),
                          child: Icon(
                            Icons.backspace_outlined,
                            size: 26,
                          ),
                        ),
                        textKey('%'),
                        textKey('÷'),
                      ],
                    ),
                    Row(
                      children: [
                        textKey('7'),
                        textKey('8'),
                        textKey('9'),
                        textKey('×'),
                      ],
                    ),
                    Row(
                      children: [
                        textKey('4'),
                        textKey('5'),
                        textKey('6'),
                        textKey('-'),
                      ],
                    ),
                    Row(
                      children: [
                        textKey('1'),
                        textKey('2'),
                        textKey('3'),
                        textKey('+'),
                      ],
                    ),
                    Row(
                      children: [
                        calcKey(
                          onPressed: () => refresh(_toggleSign),
                          child: Text(
                            '+/−',
                            style: TextStyle(fontSize: 20),
                          ),
                        ),
                        textKey('0'),
                        textKey('.'),
                        textKey('=', primary: true),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      readOnly: true,
      showCursor: false,
      onTap: () => _openCalculator(context),
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: Icon(Icons.calculate_outlined),
        border: OutlineInputBorder(),
      ),
    );
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  if (args.contains('--uninstall-cleanup')) {
    await _ghataWindowsUninstallCleanup();
    exit(0);
  }

  runApp(GhataApp());
}

Future<void> _ghataWindowsUninstallCleanup() async {
  if (!Platform.isWindows) return;

  // Remove the persisted Supabase login/session.
  try {
    await Supabase.instance.client.auth.signOut();
  } catch (_) {}

  // Remove Ghata secure settings such as local account owner,
  // language/theme secure values and other local settings.
  try {
    const storage = FlutterSecureStorage();
    await storage.deleteAll();
  } catch (_) {}

  // Remove all locally cached/offline business data.
  try {
    await OfflineDatabase.instance.clearAllLocalData();
    await OfflineDatabase.instance.close();
  } catch (_) {}
}


const Map<String, Map<String, String>> ghataTranslations = {
'About Ghata description': {    'en': 'Ghata is a business ledger and accounting system for managing customers, daily transactions, currency exchange, reports, backup and secure multi-device access.',    'ps': 'ګهته د سوداګرۍ د حسابونو او محاسبې سیستم دی چې د مشتریانو، ورځنیو معاملو، د اسعارو تبادلې، راپورونو، بیک اپ او خوندي څو وسیله لاسرسي د مدیریت لپاره کارېږي.',    'fa': 'Ghata یک سیستم دفتر حساب و حسابداری تجاری برای مدیریت مشتریان، معاملات روزانه، تبادله ارز، گزارش‌ها، پشتیبان‌گیری و دسترسی امن چنددستگاهی است.',    'ur': 'Ghata ایک کاروباری لیجر اور اکاؤنٹنگ سسٹم ہے جو گاہکوں، روزانہ لین دین، کرنسی ایکسچینج، رپورٹس، بیک اپ اور محفوظ متعدد ڈیوائس رسائی کے انتظام کے لیے ہے۔',    'ar': 'Ghata هو نظام دفتر أعمال ومحاسبة لإدارة العملاء والمعاملات اليومية وصرف العملات والتقارير والنسخ الاحتياطي والوصول الآمن عبر أجهزة متعددة.',  },
'How to Use Ghata description': { 'en': 'Use Customers for customer ledgers, Daily Journal for general business entries, Exchange for currency exchange, Reports for summaries, and Backup & Restore to protect your Ghata data.', 'ps': 'د مشتریانو حسابونو لپاره Customers، د عمومي سوداګریزو ثبتونو لپاره Daily Journal، د اسعارو د تبادلې لپاره Exchange، د لنډیزونو لپاره Reports، او د خپلو ګهته معلوماتو د خوندي ساتلو لپاره Backup & Restore وکاروئ.', 'fa': 'برای حساب‌های مشتریان از Customers، برای ثبت‌های عمومی کسب‌وکار از Daily Journal، برای تبادله ارز از Exchange، برای خلاصه‌ها از Reports و برای محافظت از معلومات Ghata از Backup & Restore استفاده کنید.', 'ur': 'گاہکوں کے کھاتوں کے لیے Customers، عمومی کاروباری اندراجات کے لیے Daily Journal، کرنسی کے تبادلے کے لیے Exchange، خلاصوں کے لیے Reports، اور اپنے Ghata ڈیٹا کی حفاظت کے لیے Backup & Restore استعمال کریں۔', 'ar': 'استخدم Customers لحسابات العملاء، وDaily Journal للقيود التجارية العامة، وExchange لصرف العملات، وReports للملخصات، وBackup & Restore لحماية بيانات Ghata الخاصة بك.' },
'FAQ Q1': { 'en': 'What is Ghata used for?', 'ps': 'ګهته د څه لپاره کارېږي؟', 'fa': 'Ghata برای چه استفاده می‌شود؟', 'ur': 'Ghata کس لیے استعمال ہوتا ہے؟', 'ar': 'ما استخدام Ghata؟' },'FAQ A1': { 'en': 'Ghata helps manage customers, daily business transactions, currency exchange, cash balances, reports, backups and synchronized account data.', 'ps': 'ګهته د مشتریانو، ورځنیو سوداګریزو معاملو، د اسعارو تبادلې، نغدي بیلانسونو، راپورونو، بیک اپ او همغږي شوو حسابي معلوماتو په مدیریت کې مرسته کوي.', 'fa': 'Ghata به مدیریت مشتریان، معاملات روزانه تجاری، تبادله ارز، موجودی نقدی، گزارش‌ها، پشتیبان‌گیری و معلومات همگام‌شده حساب کمک می‌کند.', 'ur': 'Ghata گاہکوں، روزانہ کاروباری لین دین، کرنسی ایکسچینج، نقد بیلنس، رپورٹس، بیک اپ اور ہم آہنگ اکاؤنٹ ڈیٹا کے انتظام میں مدد کرتا ہے۔', 'ar': 'يساعد Ghata في إدارة العملاء والمعاملات التجارية اليومية وصرف العملات والأرصدة النقدية والتقارير والنسخ الاحتياطية وبيانات الحساب المتزامنة.' },
'FAQ Q2': { 'en': 'How do I protect my data?', 'ps': 'خپل معلومات څنګه خوندي کړم؟', 'fa': 'چگونه از معلومات خود محافظت کنم؟', 'ur': 'اپنا ڈیٹا کیسے محفوظ رکھوں؟', 'ar': 'كيف أحمي بياناتي؟' },'FAQ A2': { 'en': 'Use Backup & Restore to create backups of important Ghata data and keep exported backup files in a safe place.', 'ps': 'د Backup & Restore له لارې د ګهته مهمو معلوماتو بیک اپ جوړ کړئ او صادر شوي بیک اپ فایلونه په خوندي ځای کې وساتئ.', 'fa': 'با Backup & Restore از معلومات مهم Ghata نسخه پشتیبان بسازید و فایل‌های پشتیبان صادرشده را در جای امن نگهداری کنید.', 'ur': 'Backup & Restore کے ذریعے اہم Ghata ڈیٹا کا بیک اپ بنائیں اور برآمد شدہ بیک اپ فائلوں کو محفوظ جگہ پر رکھیں۔', 'ar': 'استخدم Backup & Restore لإنشاء نسخ احتياطية من بيانات Ghata المهمة واحتفظ بملفات النسخ الاحتياطي المصدرة في مكان آمن.' },
'FAQ Q3': { 'en': 'How does synchronization work?', 'ps': 'همغږي څنګه کار کوي؟', 'fa': 'همگام‌سازی چگونه کار می‌کند؟', 'ur': 'ہم آہنگی کیسے کام کرتی ہے؟', 'ar': 'كيف تعمل المزامنة؟' },'FAQ A3': { 'en': 'Ghata keeps supported account data synchronized when internet access is available. Pending changes remain in the sync queue and are sent when synchronization succeeds.', 'ps': 'کله چې انټرنېټ موجود وي، ګهته د حساب اړوند معلومات همغږي کوي. پاتې بدلونونه د همغږۍ په کتار کې ساتل کېږي او د بریالۍ همغږۍ پر مهال لېږل کېږي.', 'fa': 'وقتی اینترنت موجود باشد، Ghata معلومات پشتیبانی‌شده حساب را همگام می‌کند. تغییرات باقی‌مانده در صف همگام‌سازی نگهداری می‌شوند و پس از موفقیت همگام‌سازی ارسال می‌شوند.', 'ur': 'انٹرنیٹ دستیاب ہونے پر Ghata معاون اکاؤنٹ ڈیٹا کو ہم آہنگ کرتا ہے۔ زیر التوا تبدیلیاں سنک قطار میں رہتی ہیں اور کامیاب ہم آہنگی پر بھیجی جاتی ہیں۔', 'ar': 'عند توفر الإنترنت يقوم Ghata بمزامنة بيانات الحساب المدعومة. تبقى التغييرات المعلقة في قائمة انتظار المزامنة ويتم إرسالها عند نجاح المزامنة.' },
'FAQ Q4': { 'en': 'How do customer accounts work?', 'ps': 'د مشتریانو حسابونه څنګه کار کوي؟', 'fa': 'حساب‌های مشتریان چگونه کار می‌کنند؟', 'ur': 'گاہکوں کے اکاؤنٹس کیسے کام کرتے ہیں؟', 'ar': 'كيف تعمل حسابات العملاء؟' },'FAQ A4': { 'en': 'Create a customer and record Money In or Money Out in the correct currency. Ghata keeps each currency balance separate and shows the customer ledger and current balances.', 'ps': 'مشتري جوړ کړئ او په سمه کرنسۍ کې Money In یا Money Out ثبت کړئ. ګهته د هرې کرنسۍ بیلانس جلا ساتي او د مشتري حساب او اوسني بیلانسونه ښيي.', 'fa': 'یک مشتری ایجاد کنید و Money In یا Money Out را با ارز درست ثبت کنید. Ghata موجودی هر ارز را جدا نگه می‌دارد و دفتر حساب و موجودی فعلی مشتری را نشان می‌دهد.', 'ur': 'گاہک بنائیں اور درست کرنسی میں Money In یا Money Out درج کریں۔ Ghata ہر کرنسی کا بیلنس الگ رکھتا ہے اور گاہک کا لیجر اور موجودہ بیلنس دکھاتا ہے۔', 'ar': 'أنشئ عميلاً وسجل Money In أو Money Out بالعملة الصحيحة. يحتفظ Ghata برصيد كل عملة بشكل منفصل ويعرض دفتر العميل والأرصدة الحالية.' },
'FAQ Q5': { 'en': 'How does currency exchange work?', 'ps': 'د اسعارو تبادله څنګه کار کوي؟', 'fa': 'تبادله ارز چگونه کار می‌کند؟', 'ur': 'کرنسی ایکسچینج کیسے کام کرتا ہے؟', 'ar': 'كيف يعمل صرف العملات؟' },'FAQ A5': { 'en': 'In Exchange, select the From and To currencies, enter the amounts and exchange rate, and optionally select a customer. Ghata records both sides of the exchange while keeping each currency separate.', 'ps': 'په Exchange کې د From او To کرنسۍ وټاکئ، مقدارونه او د تبادلې نرخ ولیکئ، او که اړتیا وي مشتري وټاکئ. ګهته د تبادلې دواړه خواوې ثبتوي او هره کرنسي جلا ساتي.', 'fa': 'در Exchange ارزهای From و To را انتخاب کنید، مبلغ‌ها و نرخ تبادله را وارد کنید و در صورت نیاز مشتری را انتخاب کنید. Ghata هر دو طرف تبادله را ثبت کرده و هر ارز را جدا نگه می‌دارد.', 'ur': 'Exchange میں From اور To کرنسیاں منتخب کریں، رقوم اور شرح تبادلہ درج کریں، اور ضرورت ہو تو گاہک منتخب کریں۔ Ghata ایکسچینج کے دونوں رخ ریکارڈ کرتا ہے اور ہر کرنسی کو الگ رکھتا ہے۔', 'ar': 'في Exchange اختر عملتي From وTo وأدخل المبالغ وسعر الصرف، ويمكنك اختيار عميل عند الحاجة. يسجل Ghata طرفي عملية الصرف مع إبقاء كل عملة منفصلة.' },
'FAQ Q6': { 'en': 'What is the Daily Journal?', 'ps': 'ورځنی ژورنال څه شی دی؟', 'fa': 'دفتر روزانه چیست؟', 'ur': 'ڈیلی جرنل کیا ہے؟', 'ar': 'ما هي اليومية؟' },'FAQ A6': { 'en': 'Daily Journal shows general business transactions and exchange movements. You can search and filter entries by type, currency, date and time.', 'ps': 'ورځنی ژورنال عمومي سوداګریزې معاملې او د اسعارو د تبادلې حرکتونه ښيي. ثبتونه د ډول، کرنسۍ، نېټې او وخت له مخې لټول او فلټر کولای شئ.', 'fa': 'دفتر روزانه معاملات عمومی کسب‌وکار و حرکات تبادله ارز را نشان می‌دهد. می‌توانید ثبت‌ها را بر اساس نوع، ارز، تاریخ و زمان جستجو و فیلتر کنید.', 'ur': 'ڈیلی جرنل عمومی کاروباری لین دین اور کرنسی ایکسچینج کی حرکات دکھاتا ہے۔ اندراجات کو قسم، کرنسی، تاریخ اور وقت کے لحاظ سے تلاش اور فلٹر کیا جا سکتا ہے۔', 'ar': 'تعرض اليومية المعاملات التجارية العامة وحركات صرف العملات. يمكنك البحث عن القيود وتصفيتها حسب النوع والعملة والتاريخ والوقت.' },
'FAQ Q7': { 'en': 'How do Reports work?', 'ps': 'راپورونه څنګه کار کوي؟', 'fa': 'گزارش‌ها چگونه کار می‌کنند؟', 'ur': 'رپورٹس کیسے کام کرتی ہیں؟', 'ar': 'كيف تعمل التقارير؟' },'FAQ A7': { 'en': 'Reports summarize Money In, Money Out, exchanges and adjustments. Reports can be filtered by date, currency and customer, and each currency remains separate.', 'ps': 'راپورونه Money In، Money Out، تبادلې او تعدیلات لنډیز کوي. راپورونه د نېټې، کرنسۍ او مشتري له مخې فلټر کېدای شي او هره کرنسي جلا پاتې کېږي.', 'fa': 'گزارش‌ها Money In، Money Out، تبادلات و تعدیلات را خلاصه می‌کنند. گزارش‌ها بر اساس تاریخ، ارز و مشتری قابل فیلتر هستند و هر ارز جدا باقی می‌ماند.', 'ur': 'رپورٹس Money In، Money Out، ایکسچینج اور ایڈجسٹمنٹ کا خلاصہ دکھاتی ہیں۔ انہیں تاریخ، کرنسی اور گاہک کے لحاظ سے فلٹر کیا جا سکتا ہے اور ہر کرنسی الگ رہتی ہے۔', 'ar': 'تلخص التقارير Money In وMoney Out وعمليات الصرف والتعديلات، ويمكن تصفيتها حسب التاريخ والعملة والعميل مع بقاء كل عملة منفصلة.' },'FAQ Q8': { 'en': 'How is my account protected?', 'ps': 'زما حساب څنګه خوندي کېږي؟', 'fa': 'حساب من چگونه محافظت می‌شود؟', 'ur': 'میرا اکاؤنٹ کیسے محفوظ کیا جاتا ہے؟', 'ar': 'كيف تتم حماية حسابي؟' },'FAQ A8': { 'en': 'Ghata uses authenticated access, account-scoped data operations and device and session controls. Keep your sign-in credentials private and review active devices regularly.', 'ps': 'ګهته تایید شوی لاسرسی، حساب پورې محدود معلوماتي عملیات او د وسیلو او ناستو کنټرولونه کاروي. خپل د ننوتلو معلومات پټ وساتئ او فعال وسایل په منظم ډول وګورئ.', 'fa': 'Ghata از دسترسی تأییدشده، عملیات معلومات محدود به حساب و کنترل دستگاه و نشست استفاده می‌کند. معلومات ورود خود را محرمانه نگه دارید و دستگاه‌های فعال را منظم بررسی کنید.', 'ur': 'Ghata تصدیق شدہ رسائی، اکاؤنٹ تک محدود ڈیٹا آپریشنز اور ڈیوائس و سیشن کنٹرول استعمال کرتا ہے۔ اپنی سائن اِن معلومات محفوظ رکھیں اور فعال ڈیوائسز باقاعدگی سے چیک کریں۔', 'ar': 'يستخدم Ghata الوصول الموثق وعمليات البيانات المقيدة بالحساب وعناصر التحكم في الأجهزة والجلسات. حافظ على سرية بيانات تسجيل الدخول وراجع الأجهزة النشطة بانتظام.' },
  'Privacy Policy description': {
    'en': 'Ghata uses account and business data to provide its accounting features. Access to account data is limited to the authenticated account according to the permissions implemented by Ghata.',
    'ps': 'ګهته د خپلو محاسبوي ځانګړنو د وړاندې کولو لپاره د حساب او سوداګرۍ معلومات کاروي. د حساب معلوماتو ته لاسرسی د ګهته د پلي شوو اجازو له مخې یوازې تایید شوي حساب ته محدود دی.',
    'fa': 'Ghata برای ارائه قابلیت‌های حسابداری خود از معلومات حساب و کسب‌وکار استفاده می‌کند. دسترسی به معلومات حساب بر اساس مجوزهای پیاده‌شده در Ghata به حساب تأییدشده محدود است.',
    'ur': 'Ghata اپنی اکاؤنٹنگ خصوصیات فراہم کرنے کے لیے اکاؤنٹ اور کاروباری ڈیٹا استعمال کرتا ہے۔ اکاؤنٹ ڈیٹا تک رسائی Ghata میں نافذ اجازتوں کے مطابق تصدیق شدہ اکاؤنٹ تک محدود ہے۔',
    'ar': 'يستخدم Ghata بيانات الحساب والأعمال لتقديم ميزات المحاسبة. يقتصر الوصول إلى بيانات الحساب على الحساب الموثق وفق الصلاحيات المطبقة في Ghata.'
  },
  'Data Security description': {
    'en': 'Ghata uses authenticated access, account-scoped data operations and device/session controls to help protect account information.',
    'ps': 'ګهته د حساب د معلوماتو د ساتنې لپاره تایید شوی لاسرسی، حساب پورې محدود معلوماتي عملیات او د وسیلې او ناستې کنټرولونه کاروي.',
    'fa': 'Ghata برای کمک به محافظت از معلومات حساب از دسترسی تأییدشده، عملیات معلومات محدود به حساب و کنترل دستگاه و نشست استفاده می‌کند.',
    'ur': 'Ghata اکاؤنٹ کی معلومات کے تحفظ میں مدد کے لیے تصدیق شدہ رسائی، اکاؤنٹ تک محدود ڈیٹا آپریشنز اور ڈیوائس و سیشن کنٹرول استعمال کرتا ہے۔',
    'ar': 'يستخدم Ghata الوصول الموثق وعمليات البيانات المقيدة بالحساب وعناصر التحكم في الجهاز والجلسة للمساعدة في حماية معلومات الحساب.'
  },
  'Data Storage description': {
    'en': 'Ghata Windows supports local/offline accounting data and synchronizes supported account data with central Ghata cloud services when synchronization is available.',
    'ps': 'ګهته وینډوز محلي او افلاین محاسبوي معلومات ساتي او کله چې همغږي موجوده وي، د حساب ملاتړ شوي معلومات د ګهته له مرکزي کلاوډ خدمتونو سره همغږي کوي.',
    'fa': 'Ghata Windows از معلومات حسابداری محلی و آفلاین پشتیبانی می‌کند و هنگام موجود بودن همگام‌سازی، معلومات پشتیبانی‌شده حساب را با خدمات مرکزی ابری Ghata همگام می‌کند.',
    'ur': 'Ghata Windows مقامی اور آف لائن اکاؤنٹنگ ڈیٹا کی معاونت کرتا ہے اور سنک دستیاب ہونے پر معاون اکاؤنٹ ڈیٹا کو مرکزی Ghata کلاؤڈ سروسز کے ساتھ ہم آہنگ کرتا ہے۔',
    'ar': 'يدعم Ghata Windows بيانات المحاسبة المحلية وغير المتصلة، ويزامن بيانات الحساب المدعومة مع خدمات Ghata السحابية المركزية عند توفر المزامنة.'
  },
  'Terms of Use description': {
    'en': 'Use Ghata only with accounts and business information you are authorized to manage. Keep your sign-in credentials secure and maintain appropriate backups of important business information.',
    'ps': 'ګهته یوازې د هغو حسابونو او سوداګریزو معلوماتو لپاره وکاروئ چې د مدیریت اجازه یې لرئ. خپل د ننوتلو معلومات خوندي وساتئ او د مهمو سوداګریزو معلوماتو مناسب بیک اپونه وساتئ.',
    'fa': 'Ghata را فقط برای حساب‌ها و معلومات تجاری استفاده کنید که اجازه مدیریت آن‌ها را دارید. معلومات ورود خود را امن نگه دارید و از معلومات مهم تجاری نسخه‌های پشتیبان مناسب حفظ کنید.',
    'ur': 'Ghata صرف ان اکاؤنٹس اور کاروباری معلومات کے لیے استعمال کریں جنہیں منظم کرنے کی آپ کو اجازت ہے۔ اپنی سائن اِن معلومات محفوظ رکھیں اور اہم کاروباری معلومات کے مناسب بیک اپ برقرار رکھیں۔',
    'ar': 'استخدم Ghata فقط مع الحسابات ومعلومات الأعمال المصرح لك بإدارتها. حافظ على أمان بيانات تسجيل الدخول واحتفظ بنسخ احتياطية مناسبة من معلومات الأعمال المهمة.'
  },
  'Dashboard': {
    'en': 'Dashboard',
    'ps': 'کورپاڼه',
    'fa': 'داشبورد',
    'ur': 'ڈیش بورڈ',
    'ar': 'لوحة التحكم',
  },
  'Home': {
    'en': 'Home',
    'ps': 'کور',
    'fa': 'خانه',
    'ur': 'ہوم',
    'ar': 'الرئيسية',
  },
  'Daily Journal': {
    'en': 'Daily Journal',
    'ps': 'ورځنی ژورنال',
    'fa': 'دفتر روزانه',
    'ur': 'روزانہ جرنل',
    'ar': 'السجل اليومي',
  },
  'Add Transaction': {
    'en': 'Add Transaction',
    'ps': 'معامله اضافه کړئ',
    'fa': 'افزودن معامله',
    'ur': 'لین دین شامل کریں',
    'ar': 'إضافة معاملة',
  },
  'Customers': {
    'en': 'Customers',
    'ps': 'پېرودونکي',
    'fa': 'مشتریان',
    'ur': 'گاہک',
    'ar': 'العملاء',
  },
  'Reports': {
    'en': 'Reports',
    'ps': 'راپورونه',
    'fa': 'گزارش‌ها',
    'ur': 'رپورٹس',
    'ar': 'التقارير',
  },
  'Cashbox': {
    'en': 'Cashbox',
    'ps': 'صندوق',
    'fa': 'صندوق',
    'ur': 'کیش باکس',
    'ar': 'الصندوق',
  },
  'Total Balance': {
    'en': 'Total Balance',
    'ps': 'ټوله بیلانس',
    'fa': 'مجموع موجودی',
    'ur': 'کل بیلنس',
    'ar': 'إجمالي الرصيد',
  },
  'Customer Photo': {
    'en': 'Customer Photo',
    'ps': 'د پېرودونکي عکس',
    'fa': 'عکس مشتری',
    'ur': 'گاہک کی تصویر',
    'ar': 'صورة العميل',
  },
  'Summary by Currency': {
    'en': 'Summary by Currency',
    'ps': 'د اسعارو له مخې لنډیز',
    'fa': 'خلاصه بر اساس ارز',
    'ur': 'کرنسی کے لحاظ سے خلاصہ',
    'ar': 'الملخص حسب العملة',
  },
  'From Date': {
    'en': 'From Date',
    'ps': 'له نېټې',
    'fa': 'از تاریخ',
    'ur': 'تاریخ سے',
    'ar': 'من تاريخ',
  },
  'To Date': {
    'en': 'To Date',
    'ps': 'تر نېټې',
    'fa': 'تا تاریخ',
    'ur': 'تاریخ تک',
    'ar': 'إلى تاريخ',
  },
  'Save Statement (PDF)': {
    'en': 'Save Statement (PDF)',
    'ps': 'حساب پاڼه خوندي کړئ (PDF)',
    'fa': 'ذخیره صورت‌حساب (PDF)',
    'ur': 'اسٹیٹمنٹ محفوظ کریں (PDF)',
    'ar': 'حفظ كشف الحساب (PDF)',
  },
  'Money In': {
    'en': 'Money In',
    'ps': 'داخلې پیسې',
    'fa': 'پول ورودی',
    'ur': 'آمد رقم',
    'ar': 'الأموال الداخلة',
  },
  'Money Out': {
    'en': 'Money Out',
    'ps': 'وتلې پیسې',
    'fa': 'پول خروجی',
    'ur': 'خرج رقم',
    'ar': 'الأموال الخارجة',
  },
  'You Receive': {
    'en': 'You Receive',
    'ps': 'تاسو یې اخلئ',
    'fa': 'شما دریافت می‌کنید',
    'ur': 'آپ کو ملنے ہیں',
    'ar': 'لك عند الآخرين',
  },
  'You Pay': {
    'en': 'You Pay',
    'ps': 'تاسو یې ورکوئ',
    'fa': 'شما پرداخت می‌کنید',
    'ur': 'آپ کو دینے ہیں',
    'ar': 'عليك للآخرين',
  },
  'Exchange': {
    'en': 'Exchange',
    'ps': 'تبادله',
    'fa': 'تبادله اسعار',
    'ur': 'کرنسی ایکسچینج',
    'ar': 'الصرافة',
  },
  'Recent Transactions': {
    'en': 'Recent Transactions',
    'ps': 'وروستۍ معاملې',
    'fa': 'معاملات اخیر',
    'ur': 'حالیہ لین دین',
    'ar': 'المعاملات الأخيرة',
  },
  'View All': {
    'en': 'View All',
    'ps': 'ټول وګورئ',
    'fa': 'مشاهده همه',
    'ur': 'سب دیکھیں',
    'ar': 'عرض الكل',
  },
  'No transactions yet': {
    'en': 'No transactions yet',
    'ps': 'تر اوسه معامله نشته',
    'fa': 'هنوز معامله‌ای نیست',
    'ur': 'ابھی کوئی لین دین نہیں',
    'ar': 'لا توجد معاملات بعد',
  },
  'Settings & Account': {
    'en': 'Settings & Account',
    'ps': 'تنظیمات او حساب',
    'fa': 'تنظیمات و حساب',
    'ur': 'ترتیبات اور اکاؤنٹ',
    'ar': 'الإعدادات والحساب',
  },
  'Settings': {
    'en': 'Settings',
    'ps': 'تنظیمات',
    'fa': 'تنظیمات',
    'ur': 'ترتیبات',
    'ar': 'الإعدادات',
  },
  'Profile & Business': {
    'en': 'Profile & Business',
    'ps': 'پروفایل او کاروبار',
    'fa': 'پروفایل و تجارت',
    'ur': 'پروفائل اور کاروبار',
    'ar': 'الملف والنشاط التجاري',
  },
  'Security': {
    'en': 'Security',
    'ps': 'امنیت',
    'fa': 'امنیت',
    'ur': 'سیکیورٹی',
    'ar': 'الأمان',
  },
  'Staff & Roles': {
    'en': 'Staff & Roles',
    'ps': 'کارکوونکي او رولونه',
    'fa': 'کارمندان و نقش‌ها',
    'ur': 'عملہ اور کردار',
    'ar': 'الموظفون والأدوار',
  },
  'Backup & Restore': {
    'en': 'Backup & Restore',
    'ps': 'بیک اپ او بیا راګرځول',
    'fa': 'پشتیبان‌گیری و بازیابی',
    'ur': 'بیک اپ اور بحالی',
    'ar': 'النسخ الاحتياطي والاستعادة',
  },
  'Recycle Bin': {
    'en': 'Recycle Bin',
    'ps': 'حذف شوي توکي',
    'fa': 'سطل بازیافت',
    'ur': 'ری سائیکل بن',
    'ar': 'سلة المحذوفات',
  },
  'About Ghata': {
    'en': 'About Ghata',
    'ps': 'د ګهته په اړه',
    'fa': 'درباره گهته',
    'ur': 'گھتہ کے بارے میں',
    'ar': 'حول غاتا',
  },
  'Sign Out': {
    'en': 'Sign Out',
    'ps': 'وتل',
    'fa': 'خروج',
    'ur': 'سائن آؤٹ',
    'ar': 'تسجيل الخروج',
  },
  'Language': {
    'en': 'Language',
    'ps': 'ژبه',
    'fa': 'زبان',
    'ur': 'زبان',
    'ar': 'اللغة',
  },
  'Dark Mode': {
    'en': 'Dark Mode',
    'ps': 'تیاره حالت',
    'fa': 'حالت تاریک',
    'ur': 'ڈارک موڈ',
    'ar': 'الوضع الداكن',
  },
  'Light Mode': {
    'en': 'Light Mode',
    'ps': 'روښانه حالت',
    'fa': 'حالت روشن',
    'ur': 'روشن موڈ',
    'ar': 'الوضع الفاتح',
  },
  'Save': {
    'en': 'Save',
    'ps': 'خوندي کړئ',
    'fa': 'ذخیره',
    'ur': 'محفوظ کریں',
    'ar': 'حفظ',
  },
  'Cancel': {
    'en': 'Cancel',
    'ps': 'لغوه',
    'fa': 'لغو',
    'ur': 'منسوخ',
    'ar': 'إلغاء',
  },
  'Delete': {
    'en': 'Delete',
    'ps': 'حذف',
    'fa': 'حذف',
    'ur': 'حذف کریں',
    'ar': 'حذف',
  },
  'Edit': {
    'en': 'Edit',
    'ps': 'سمون',
    'fa': 'ویرایش',
    'ur': 'ترمیم',
    'ar': 'تعديل',
  },
  'Add': {
    'en': 'Add',
    'ps': 'اضافه',
    'fa': 'افزودن',
    'ur': 'شامل کریں',
    'ar': 'إضافة',
  },
  'Search': {
    'en': 'Search',
    'ps': 'لټون',
    'fa': 'جستجو',
    'ur': 'تلاش',
    'ar': 'بحث',
  },
  'Restore': {
    'en': 'Restore',
    'ps': 'بیا راګرځول',
    'fa': 'بازیابی',
    'ur': 'بحال کریں',
    'ar': 'استعادة',
  },
  'Delete Permanently': {
    'en': 'Delete Permanently',
    'ps': 'دایمي حذف',
    'fa': 'حذف دائمی',
    'ur': 'مستقل حذف',
    'ar': 'حذف نهائي',
  },
  'Transactions': {
    'en': 'Transactions',
    'ps': 'معاملې',
    'fa': 'معاملات',
    'ur': 'لین دین',
    'ar': 'المعاملات',
  },
  'Exchanges': {
    'en': 'Exchanges',
    'ps': 'تبادلې',
    'fa': 'تبادلات',
    'ur': 'ایکسچینجز',
    'ar': 'عمليات الصرافة',
  },
  'Customer': {
    'en': 'Customer',
    'ps': 'پېرودونکی',
    'fa': 'مشتری',
    'ur': 'گاہک',
    'ar': 'العميل',
  },
  'Customer Name': {
    'en': 'Customer Name',
    'ps': 'د پېرودونکي نوم',
    'fa': 'نام مشتری',
    'ur': 'گاہک کا نام',
    'ar': 'اسم العميل',
  },
  'Amount': {
    'en': 'Amount',
    'ps': 'اندازه',
    'fa': 'مبلغ',
    'ur': 'رقم',
    'ar': 'المبلغ',
  },
  'Currency': {
    'en': 'Currency',
    'ps': 'اسعار',
    'fa': 'ارز',
    'ur': 'کرنسی',
    'ar': 'العملة',
  },
  'Date': {
    'en': 'Date',
    'ps': 'نېټه',
    'fa': 'تاریخ',
    'ur': 'تاریخ',
    'ar': 'التاريخ',
  },
  'Description': {
    'en': 'Description',
    'ps': 'تفصیل',
    'fa': 'توضیحات',
    'ur': 'تفصیل',
    'ar': 'الوصف',
  },
  'Reference': {
    'en': 'Reference',
    'ps': 'حواله',
    'fa': 'مرجع',
    'ur': 'حوالہ',
    'ar': 'المرجع',
  },
  'Adjustment In': {
    'en': 'Adjustment In',
    'ps': 'داخل سمون',
    'fa': 'اصلاح ورودی',
    'ur': 'اندرونی ایڈجسٹمنٹ',
    'ar': 'تسوية داخلة',
  },
  'Adjustment Out': {
    'en': 'Adjustment Out',
    'ps': 'وتلی سمون',
    'fa': 'اصلاح خروجی',
    'ur': 'بیرونی ایڈجسٹمنٹ',
    'ar': 'تسوية خارجة',
  },
  'Exchange Buy': {
    'en': 'Exchange Buy',
    'ps': 'د اسعارو پېر',
    'fa': 'خرید ارز',
    'ur': 'کرنسی خرید',
    'ar': 'شراء عملة',
  },
  'Exchange Sell': {
    'en': 'Exchange Sell',
    'ps': 'د اسعارو پلور',
    'fa': 'فروش ارز',
    'ur': 'کرنسی فروخت',
    'ar': 'بيع عملة',
  },
  'From': {
    'en': 'From',
    'ps': 'له',
    'fa': 'از',
    'ur': 'سے',
    'ar': 'من',
  },
  'To': {
    'en': 'To',
    'ps': 'تر',
    'fa': 'به',
    'ur': 'تک',
    'ar': 'إلى',
  },
  'Rate': {
    'en': 'Rate',
    'ps': 'نرخ',
    'fa': 'نرخ',
    'ur': 'ریٹ',
    'ar': 'السعر',
  },
  'Buy': {
    'en': 'Buy',
    'ps': 'پېر',
    'fa': 'خرید',
    'ur': 'خرید',
    'ar': 'شراء',
  },
  'Sell': {
    'en': 'Sell',
    'ps': 'پلور',
    'fa': 'فروش',
    'ur': 'فروخت',
    'ar': 'بيع',
  },
  'Today': {
    'en': 'Today',
    'ps': 'نن',
    'fa': 'امروز',
    'ur': 'آج',
    'ar': 'اليوم',
  },
  'All': {
    'en': 'All',
    'ps': 'ټول',
    'fa': 'همه',
    'ur': 'سب',
    'ar': 'الكل',
  },
  'Name': {
    'en': 'Name',
    'ps': 'نوم',
    'fa': 'نام',
    'ur': 'نام',
    'ar': 'الاسم',
  },
  'Phone': {
    'en': 'Phone',
    'ps': 'تلیفون',
    'fa': 'تلفن',
    'ur': 'فون',
    'ar': 'الهاتف',
  },
  'Balance': {
    'en': 'Balance',
    'ps': 'بیلانس',
    'fa': 'موجودی',
    'ur': 'بیلنس',
    'ar': 'الرصيد',
  },
  'Notes': {
    'en': 'Notes',
    'ps': 'یادښتونه',
    'fa': 'یادداشت‌ها',
    'ur': 'نوٹس',
    'ar': 'ملاحظات',
  },
  'Report': {
    'en': 'Report',
    'ps': 'راپور',
    'fa': 'گزارش',
    'ur': 'رپورٹ',
    'ar': 'تقرير',
  },
  'Refresh': {
    'en': 'Refresh',
    'ps': 'تازه کول',
    'fa': 'تازه‌سازی',
    'ur': 'تازہ کریں',
    'ar': 'تحديث',
  },
  'Close': {
    'en': 'Close',
    'ps': 'بندول',
    'fa': 'بستن',
    'ur': 'بند کریں',
    'ar': 'إغلاق',
  },
  'Confirm': {
    'en': 'Confirm',
    'ps': 'تایید',
    'fa': 'تأیید',
    'ur': 'تصدیق',
    'ar': 'تأكيد',
  },

  'App PIN': {
    'en': 'App PIN',
    'ps': 'د اپ PIN',
    'fa': 'PIN برنامه',
    'ur': 'ایپ PIN',
    'ar': 'رمز التطبيق',
  },
  'Due Soon': {
    'en': 'Due Soon',
    'ps': 'ژر موعد',
    'fa': 'به‌زودی سررسید',
    'ur': 'جلد واجب الادا',
    'ar': 'يستحق قريباً',
  },
  'Add Staff': {
    'en': 'Add Staff',
    'ps': 'کارکوونکی اضافه کړئ',
    'fa': 'افزودن کارمند',
    'ur': 'عملہ شامل کریں',
    'ar': 'إضافة موظف',
  },
  'Full Name': {
    'en': 'Full Name',
    'ps': 'بشپړ نوم',
    'fa': 'نام کامل',
    'ur': 'پورا نام',
    'ar': 'الاسم الكامل',
  },
  'New Email': {
    'en': 'New Email',
    'ps': 'نوی ایمیل',
    'fa': 'ایمیل جدید',
    'ur': 'نیا ای میل',
    'ar': 'البريد الجديد',
  },
  'Add / Edit': {
    'en': 'Add / Edit',
    'ps': 'اضافه / سمون',
    'fa': 'افزودن / ویرایش',
    'ur': 'شامل / ترمیم',
    'ar': 'إضافة / تعديل',
  },
  'No balance': {
    'en': 'No balance',
    'ps': 'بیلانس نشته',
    'fa': 'موجودی نیست',
    'ur': 'کوئی بیلنس نہیں',
    'ar': 'لا يوجد رصيد',
  },
  'Clear dates': {
    'en': 'Clear dates',
    'ps': 'نېټې پاکې کړئ',
    'fa': 'پاک کردن تاریخ‌ها',
    'ur': 'تاریخیں صاف کریں',
    'ar': 'مسح التواريخ',
  },
  'Confirm PIN': {
    'en': 'Confirm PIN',
    'ps': 'PIN تایید کړئ',
    'fa': 'تأیید PIN',
    'ur': 'PIN کی تصدیق',
    'ar': 'تأكيد الرمز',
  },
  'All Currencies': {
    'en': 'All Currencies',
    'ps': 'ټولې کرنسۍ',
    'fa': 'همه ارزها',
    'ur': 'تمام کرنسیاں',
    'ar': 'جميع العملات',
  },
  'No Customer': {
    'en': 'No Customer',
    'ps': 'پېرودونکی نشته',
    'fa': 'بدون مشتری',
    'ur': 'کوئی گاہک نہیں',
    'ar': 'بدون عميل',
  },
  'Staff Email': {
    'en': 'Staff Email',
    'ps': 'د کارکوونکي ایمیل',
    'fa': 'ایمیل کارمند',
    'ur': 'عملے کا ای میل',
    'ar': 'بريد الموظف',
  },
  'To Currency': {
    'en': 'To Currency',
    'ps': 'تر اسعار',
    'fa': 'ارز مقصد',
    'ur': 'مطلوبہ کرنسی',
    'ar': 'العملة المستلمة',
  },
  'Add Customer': {
    'en': 'Add Customer',
    'ps': 'پېرودونکی اضافه کړئ',
    'fa': 'افزودن مشتری',
    'ur': 'گاہک شامل کریں',
    'ar': 'إضافة عميل',
  },
  'Delete Account': {
    'en': 'Delete Account',
    'ps': 'اکاونټ حذف کړئ',
    'fa': 'حذف حساب',
    'ur': 'اکاؤنٹ حذف کریں',
    'ar': 'حذف الحساب',
  },
  'Delete Account?': {
    'en': 'Delete Account?',
    'ps': 'اکاونټ حذف کړئ؟',
    'fa': 'حساب حذف شود؟',
    'ur': 'اکاؤنٹ حذف کریں؟',
    'ar': 'حذف الحساب؟',
  },
  'This permanently deletes your Ghata account and cloud accounting data. This cannot be undone.': {
    'en': 'This permanently deletes your Ghata account and cloud accounting data. This cannot be undone.',
    'ps': 'دا به ستاسو د ګهته اکاونټ او په کلاوډ کې حسابي معلومات د تل لپاره حذف کړي. بېرته نه راګرځي.',
    'fa': 'این کار حساب گَهته و اطلاعات حسابداری ابری شما را برای همیشه حذف می‌کند و قابل بازگشت نیست.',
    'ur': 'یہ آپ کا گہتہ اکاؤنٹ اور کلاؤڈ اکاؤنٹنگ ڈیٹا مستقل طور پر حذف کر دے گا۔ اسے واپس نہیں لایا جا سکتا۔',
    'ar': 'سيؤدي هذا إلى حذف حساب غهته وبيانات المحاسبة السحابية نهائياً ولا يمكن التراجع عنه.',
  },
  'Are you absolutely sure?': {
    'en': 'Are you absolutely sure?',
    'ps': 'ایا بشپړ ډاډه یاست؟',
    'fa': 'آیا کاملاً مطمئن هستید؟',
    'ur': 'کیا آپ کو مکمل یقین ہے؟',
    'ar': 'هل أنت متأكد تماماً؟',
  },
  'Account deleted successfully.': {
    'en': 'Account deleted successfully.',
    'ps': 'اکاونټ په بریالیتوب حذف شو.',
    'fa': 'حساب با موفقیت حذف شد.',
    'ur': 'اکاؤنٹ کامیابی سے حذف ہو گیا۔',
    'ar': 'تم حذف الحساب بنجاح.',
  },
  'Unable to delete account': {
    'en': 'Unable to delete account',
    'ps': 'اکاونټ حذف نشو',
    'fa': 'حذف حساب ممکن نشد',
    'ur': 'اکاؤنٹ حذف نہیں ہو سکا',
    'ar': 'تعذر حذف الحساب',
  },
  'Change Email': {
    'en': 'Change Email',
    'ps': 'ایمیل بدل کړئ',
    'fa': 'تغییر ایمیل',
    'ur': 'ای میل تبدیل کریں',
    'ar': 'تغيير البريد',
  },
  'Ghata Backup': {
    'en': 'Ghata Backup',
    'ps': 'د ګهته بیک اپ',
    'fa': 'پشتیبان گهته',
    'ur': 'گھتہ بیک اپ',
    'ar': 'نسخة غاتا الاحتياطية',
  },
  'New Password': {
    'en': 'New Password',
    'ps': 'نوی پاسورډ',
    'fa': 'رمز جدید',
    'ur': 'نیا پاس ورڈ',
    'ar': 'كلمة المرور الجديدة',
  },
  'Phone Number': {
    'en': 'Phone Number',
    'ps': 'د تلیفون شمېره',
    'fa': 'شماره تلفن',
    'ur': 'فون نمبر',
    'ar': 'رقم الهاتف',
  },
  'Receipt Note': {
    'en': 'Receipt Note',
    'ps': 'د رسید یادښت',
    'fa': 'یادداشت رسید',
    'ur': 'رسید نوٹ',
    'ar': 'ملاحظة الإيصال',
  },
  'Save Changes': {
    'en': 'Save Changes',
    'ps': 'بدلونونه خوندي کړئ',
    'fa': 'ذخیره تغییرات',
    'ur': 'تبدیلیاں محفوظ کریں',
    'ar': 'حفظ التغييرات',
  },
  'Enter your 4 to 6 digit PIN.': {
    'en': 'Enter your 4 to 6 digit PIN.',
    'ps': 'خپل له ۴ تر ۶ عددي PIN داخل کړئ.',
    'fa': 'PIN چهار تا شش رقمی خود را وارد کنید.',
    'ur': 'اپنا 4 سے 6 ہندسوں کا PIN درج کریں۔',
    'ar': 'أدخل رمز PIN المكون من 4 إلى 6 أرقام.',
  },
  'Unlock Ghata': {
    'en': 'Unlock Ghata',
    'ps': 'ګهته خلاص کړئ',
    'fa': 'باز کردن گهته',
    'ur': 'گھتہ کھولیں',
    'ar': 'فتح غاتا',
  },
  'View Reports': {
    'en': 'View Reports',
    'ps': 'راپورونه وګورئ',
    'fa': 'مشاهده گزارش‌ها',
    'ur': 'رپورٹس دیکھیں',
    'ar': 'عرض التقارير',
  },
  'All customers': {
    'en': 'All customers',
    'ps': 'ټول پېرودونکي',
    'fa': 'همه مشتریان',
    'ur': 'تمام گاہک',
    'ar': 'كل العملاء',
  },
  'Business Name': {
    'en': 'Business Name',
    'ps': 'د کاروبار نوم',
    'fa': 'نام تجارت',
    'ur': 'کاروبار کا نام',
    'ar': 'اسم النشاط',
  },
  'Contact Owner': {
    'en': 'Contact Owner',
    'ps': 'له مالک سره اړیکه',
    'fa': 'تماس با مالک',
    'ur': 'مالک سے رابطہ',
    'ar': 'اتصل بالمالك',
  },
  'Create Backup': {
    'en': 'Create Backup',
    'ps': 'بیک اپ جوړ کړئ',
    'fa': 'ایجاد پشتیبان',
    'ur': 'بیک اپ بنائیں',
    'ar': 'إنشاء نسخة احتياطية',
  },

  'Automatic backup stays updated. Create Backup exports the latest backup.': {
    'en': 'Automatic backup stays updated. Create Backup exports the latest backup.',
    'ps': 'اوتومات بیک اپ تل تازه ساتل کېږي. Create Backup وروستی بیک اپ فایل خوندي یا اکسپورټ کوي.',
    'fa': 'پشتیبان خودکار همیشه به‌روز نگه داشته می‌شود. Create Backup آخرین نسخه پشتیبان را ذخیره یا صادر می‌کند.',
    'ur': 'خودکار بیک اپ ہمیشہ تازہ رکھا جاتا ہے۔ Create Backup تازہ ترین بیک اپ کو محفوظ یا ایکسپورٹ کرتا ہے۔',
    'ar': 'يتم تحديث النسخة الاحتياطية التلقائية باستمرار. يقوم Create Backup بحفظ أو تصدير أحدث نسخة احتياطية.',
  },
  'Disable Staff': {
    'en': 'Disable Staff',
    'ps': 'کارکوونکی غیر فعال کړئ',
    'fa': 'غیرفعال کردن کارمند',
    'ur': 'عملہ غیر فعال کریں',
    'ar': 'تعطيل الموظف',
  },
  'Edit Customer': {
    'en': 'Edit Customer',
    'ps': 'پېرودونکی سم کړئ',
    'fa': 'ویرایش مشتری',
    'ur': 'گاہک میں ترمیم',
    'ar': 'تعديل العميل',
  },
  'Edit Exchange': {
    'en': 'Edit Exchange',
    'ps': 'تبادله سمه کړئ',
    'fa': 'ویرایش تبادله',
    'ur': 'ایکسچینج میں ترمیم',
    'ar': 'تعديل الصرافة',
  },
  'Exchange Type': {
    'en': 'Exchange Type',
    'ps': 'د تبادلې ډول',
    'fa': 'نوع تبادله',
    'ur': 'ایکسچینج کی قسم',
    'ar': 'نوع الصرافة',
  },
  'From Currency': {
    'en': 'From Currency',
    'ps': 'له اسعار',
    'fa': 'ارز مبدأ',
    'ur': 'ابتدائی کرنسی',
    'ar': 'العملة المدفوعة',
  },
  'Gmail / Email': {
    'en': 'Gmail / Email',
    'ps': 'جیمیل / ایمیل',
    'fa': 'جیمیل / ایمیل',
    'ur': 'جی میل / ای میل',
    'ar': 'Gmail / البريد',
  },
  'Profit / Loss': {
    'en': 'Profit / Loss',
    'ps': 'ګټه / تاوان',
    'fa': 'سود / زیان',
    'ur': 'منافع / نقصان',
    'ar': 'الربح / الخسارة',
  },
  'Reference No.': {
    'en': 'Reference No.',
    'ps': 'د حوالې شمېره',
    'fa': 'شماره مرجع',
    'ur': 'حوالہ نمبر',
    'ar': 'رقم المرجع',
  },
  'Select': {
    'en': 'Select',
    'ps': 'انتخاب',
    'fa': 'انتخاب',
    'ur': 'منتخب کریں',
    'ar': 'تحديد',
  },
  'Cancel Selection': {
    'en': 'Cancel Selection',
    'ps': 'انتخاب لغوه کړئ',
    'fa': 'لغو انتخاب',
    'ur': 'انتخاب منسوخ کریں',
    'ar': 'إلغاء التحديد',
  },
  'Delete All': {
    'en': 'Delete All',
    'ps': 'ټول حذف کړئ',
    'fa': 'حذف همه',
    'ur': 'سب حذف کریں',
    'ar': 'حذف الكل',
  },
  'Delete Selected': {
    'en': 'Delete Selected',
    'ps': 'ټاکل شوي حذف کړئ',
    'fa': 'حذف انتخاب‌شده‌ها',
    'ur': 'منتخب شدہ حذف کریں',
    'ar': 'حذف المحدد',
  },
  'No items selected.': {
    'en': 'No items selected.',
    'ps': 'هیڅ شی نه دی ټاکل شوی.',
    'fa': 'هیچ موردی انتخاب نشده است.',
    'ur': 'کوئی آئٹم منتخب نہیں کیا گیا۔',
    'ar': 'لم يتم تحديد أي عنصر.',
  },
  'Delete selected items permanently? This cannot be undone.': {
    'en': 'Delete selected items permanently? This cannot be undone.',
    'ps': 'ټاکل شوي توکي دایمي حذف شي؟ دا کار بېرته نه راګرځي.',
    'fa': 'موارد انتخاب‌شده برای همیشه حذف شوند؟ این کار قابل بازگشت نیست.',
    'ur': 'منتخب آئٹمز مستقل طور پر حذف کریں؟ یہ عمل واپس نہیں ہو سکتا۔',
    'ar': 'حذف العناصر المحددة نهائيًا؟ لا يمكن التراجع عن هذا الإجراء.',
  },
  'Delete all items permanently? This cannot be undone.': {
    'en': 'Delete all items permanently? This cannot be undone.',
    'ps': 'ټول توکي دایمي حذف شي؟ دا کار بېرته نه راګرځي.',
    'fa': 'همه موارد برای همیشه حذف شوند؟ این کار قابل بازگشت نیست.',
    'ur': 'تمام آئٹمز مستقل طور پر حذف کریں؟ یہ عمل واپس نہیں ہو سکتا۔',
    'ar': 'حذف جميع العناصر نهائيًا؟ لا يمكن التراجع عن هذا الإجراء.',
  },
  'Selected items deleted permanently.': {
    'en': 'Selected items deleted permanently.',
    'ps': 'ټاکل شوي توکي دایمي حذف شول.',
    'fa': 'موارد انتخاب‌شده برای همیشه حذف شدند.',
    'ur': 'منتخب آئٹمز مستقل طور پر حذف ہو گئے۔',
    'ar': 'تم حذف العناصر المحددة نهائيًا.',
  },
  'Recycle Bin cleared.': {
    'en': 'Recycle Bin cleared.',
    'ps': 'ریسایکل بین پاک شو.',
    'fa': 'سطل بازیافت پاک شد.',
    'ur': 'ری سائیکل بن صاف کر دیا گیا۔',
    'ar': 'تم إفراغ سلة المحذوفات.',
  },
  'Unable to delete selected items': {
    'en': 'Unable to delete selected items',
    'ps': 'ټاکل شوي توکي حذف نشول',
    'fa': 'حذف موارد انتخاب‌شده ممکن نشد',
    'ur': 'منتخب آئٹمز حذف نہیں ہو سکے',
    'ar': 'تعذر حذف العناصر المحددة',
  },
  'Unable to clear Recycle Bin': {
    'en': 'Unable to clear Recycle Bin',
    'ps': 'ریسایکل بین پاک نشو',
    'fa': 'پاک‌سازی سطل بازیافت ممکن نشد',
    'ur': 'ری سائیکل بن صاف نہیں ہو سکا',
    'ar': 'تعذر إفراغ سلة المحذوفات',
  },

  'Device authentication was cancelled.': {
    'en': 'Device authentication was cancelled.',
    'ps': 'د وسیلې تصدیق لغوه شو.',
    'fa': 'تأیید هویت دستگاه لغو شد.',
    'ur': 'ڈیوائس کی تصدیق منسوخ کر دی گئی۔',
    'ar': 'تم إلغاء مصادقة الجهاز.',
  },
  'All currencies': {
    'en': 'All currencies',
    'ps': 'ټول اسعار',
    'fa': 'همه ارزها',
    'ur': 'تمام کرنسیاں',
    'ar': 'كل العملات',
  },
  'Business Phone': {
    'en': 'Business Phone',
    'ps': 'د کاروبار تلیفون',
    'fa': 'تلفن تجارت',
    'ur': 'کاروباری فون',
    'ar': 'هاتف النشاط',
  },
  'Currency Exchange': {
    'en': 'Currency Exchange',
    'ps': 'د اسعارو تبادله',
    'fa': 'تبادل ارز',
    'ur': 'کرنسی ایکسچینج',
    'ar': 'صرف العملات',
  },
  'Receipts, PDF & Balance Image': {
    'en': 'Receipts, PDF & Balance Image',
    'ps': 'رسیدونه، PDF او د بیلانس انځور',
    'fa': 'رسیدها، PDF و تصویر موجودی',
    'ur': 'رسیدیں، PDF اور بیلنس تصویر',
    'ar': 'الإيصالات وPDF وصورة الرصيد',
  },
  'Important': {
    'en': 'Important',
    'ps': 'مهم',
    'fa': 'مهم',
    'ur': 'اہم',
    'ar': 'مهم',
  },
  'The Dashboard gives you a quick overview of your business. Cashbox, Money In, Money Out, You Receive and You Pay are shown separately for each currency. Ghata does not combine different currencies into a converted grand total.': {
    'en': 'The Dashboard gives you a quick overview of your business. Cashbox, Money In, Money Out, You Receive and You Pay are shown separately for each currency. Ghata does not combine different currencies into a converted grand total.',
    'ps': 'ډشبورډ ستاسو د کاروبار چټک لنډیز ښيي. صندوق، داخلې پیسې، وتلې پیسې، ستاسو اخیستنې او ستاسو ورکړې د هر اسعار لپاره جلا ښودل کېږي. ګهته بېلابېل اسعار په یوه تبدیل شوي عمومي ټول کې نه ګډوي.',
    'fa': 'داشبورد یک نمای سریع از تجارت شما نشان می‌دهد. صندوق، پول ورودی، پول خروجی، طلب شما و بدهی شما برای هر ارز جداگانه نمایش داده می‌شود. گِهته ارزهای مختلف را در یک مجموع تبدیل‌شده با هم ترکیب نمی‌کند.',
    'ur': 'ڈیش بورڈ آپ کے کاروبار کا فوری خلاصہ دکھاتا ہے۔ کیش باکس، رقم وصول، رقم ادائیگی، آپ کو وصول ہونا ہے اور آپ کو ادا کرنا ہے ہر کرنسی کے لیے الگ دکھائے جاتے ہیں۔ گھتہ مختلف کرنسیوں کو تبدیل کرکے ایک مجموعی رقم میں شامل نہیں کرتا۔',
    'ar': 'تعرض لوحة التحكم ملخصًا سريعًا لنشاطك. ويظهر الصندوق والأموال الداخلة والخارجة والمبالغ المستحقة لك وعليك بشكل منفصل لكل عملة. ولا تقوم غهته بدمج العملات المختلفة في إجمالي محوّل واحد.',
  },
  'Use Customers to create and manage customer accounts. Each currency has its own independent running balance. Money In increases the customer balance, Money Out decreases it, and Exchange updates both related currencies. Open a customer to view the dated running ledger and current balances.': {
    'en': 'Use Customers to create and manage customer accounts. Every currency is calculated separately and has its own independent running balance. Money In increases that currency balance and Money Out decreases it. Exchange updates both related currencies separately. Newest transactions are shown at the top while the running balance is calculated in chronological order. Press and hold a customer transaction to open Edit and Delete. If an older transaction is edited or deleted, the running balance is automatically recalculated.',
    'ps': 'د پېرودونکو برخه د پېرودونکو د حسابونو د جوړولو او مدیریت لپاره وکاروئ. د هر پېرودونکي هره کرنسي جلا حسابېږي او خپل مستقل روان بیلانس لري. Money In د هماغې کرنسۍ بیلانس زیاتوي او Money Out یې کموي. Exchange دواړه اړوندې کرنسۍ جلا جلا بدلوي. نوې معامله د لست په سر کې ښودل کېږي، خو روان بیلانس د پخوانۍ معاملې څخه تر نوې معاملې پورې حسابېږي. د یوې معاملې د اصلاح یا ړنګولو لپاره پرې اوږد فشار ورکړئ؛ Edit او Delete به ښکاره شي. که پخوانۍ معامله اصلاح یا ړنګه شي، روان بیلانس په اتومات ډول له سره حسابېږي.',
    'fa': 'از بخش مشتریان برای ایجاد و مدیریت حساب‌های مشتری استفاده کنید. هر ارز مشتری جداگانه محاسبه می‌شود و موجودی جاری مستقل خود را دارد. Money In موجودی همان ارز را افزایش می‌دهد و Money Out آن را کاهش می‌دهد. Exchange هر دو ارز مرتبط را جداگانه تغییر می‌دهد. جدیدترین معاملات در بالای فهرست نمایش داده می‌شوند، اما موجودی جاری به ترتیب زمانی از قدیمی‌ترین معامله محاسبه می‌شود. برای ویرایش یا حذف یک معامله، روی آن لمس طولانی کنید تا Edit و Delete نمایش داده شود. اگر معامله قدیمی ویرایش یا حذف شود، موجودی جاری به‌صورت خودکار دوباره محاسبه می‌شود.',
    'ur': 'گاہکوں کے اکاؤنٹس بنانے اور منظم کرنے کے لیے Customers استعمال کریں۔ ہر گاہک کی ہر کرنسی الگ حساب ہوتی ہے اور اس کا اپنا مستقل رننگ بیلنس ہوتا ہے۔ Money In اسی کرنسی کا بیلنس بڑھاتا ہے اور Money Out کم کرتا ہے۔ Exchange دونوں متعلقہ کرنسیوں کو الگ الگ تبدیل کرتا ہے۔ نئی ٹرانزیکشن اوپر دکھائی جاتی ہے، لیکن رننگ بیلنس پرانی سے نئی ٹرانزیکشن تک حساب ہوتا ہے۔ کسی ٹرانزیکشن کو Edit یا Delete کرنے کے لیے اسے دیر تک دبائیں۔ اگر پرانی ٹرانزیکشن میں ترمیم یا حذف کیا جائے تو رننگ بیلنس خودکار طور پر دوبارہ حساب ہوتا ہے۔',
    'ar': 'استخدم قسم العملاء لإنشاء حسابات العملاء وإدارتها. يتم حساب كل عملة للعميل بشكل منفصل ولكل عملة رصيد جارٍ مستقل. تزيد Money In رصيد العملة نفسها وتخفضه Money Out. ويحدّث Exchange العملتين المرتبطتين بشكل منفصل. تظهر أحدث المعاملات في أعلى القائمة، بينما يتم حساب الرصيد الجاري زمنياً من أقدم معاملة إلى أحدثها. اضغط مطولاً على أي معاملة لإظهار Edit وDelete. وإذا تم تعديل أو حذف معاملة قديمة، تتم إعادة حساب الرصيد الجاري تلقائياً.',
  },
  'Use the Add button to record Money In, Money Out and adjustments. Select the correct currency, date and time, and choose a customer when needed. Add a clear description so the reason for every transaction remains recorded.': {
    'en': 'Use the Add button to record Money In, Money Out and adjustments. Select the correct currency, date and time, and choose a customer when needed. Add a clear description so the reason for every transaction remains recorded.',
    'ps': 'د Add تڼۍ په وسیله Money In، Money Out او سمونونه ثبت کړئ. سم اسعار، نېټه او وخت وټاکئ، او د اړتیا پر مهال پېرودونکی انتخاب کړئ. روښانه تشریح ولیکئ ترڅو د هرې معاملې دلیل ثبت پاتې شي.',
    'fa': 'با دکمه Add، Money In، Money Out و اصلاحات را ثبت کنید. ارز، تاریخ و زمان درست را انتخاب کنید و در صورت نیاز مشتری را مشخص کنید. توضیح روشنی وارد کنید تا دلیل هر معامله ثبت بماند.',
    'ur': 'Add بٹن سے Money In، Money Out اور ایڈجسٹمنٹ درج کریں۔ درست کرنسی، تاریخ اور وقت منتخب کریں اور ضرورت کے مطابق گاہک منتخب کریں۔ واضح تفصیل لکھیں تاکہ ہر لین دین کی وجہ محفوظ رہے۔',
    'ar': 'استخدم زر Add لتسجيل Money In وMoney Out والتعديلات. اختر العملة والتاريخ والوقت الصحيح، وحدد العميل عند الحاجة. أضف وصفًا واضحًا حتى يبقى سبب كل معاملة مسجلًا.',
  },
  'The Daily Journal shows general business transactions and exchange movements. Use search and filters by type, currency, date and time. Amounts and running balances remain separate for each currency.': {
    'en': 'The Daily Journal shows general business transactions and exchange movements. Use search and filters by type, currency, date and time. Amounts and running balances remain separate for each currency.',
    'ps': 'ورځنی ژورنال د کاروبار عمومي معاملې او د اسعارو د تبادلې حرکتونه ښيي. د ډول، اسعار، نېټې او وخت له مخې لټون او فلټرونه وکاروئ. مبلغونه او روان بیلانسونه د هرې کرنسۍ لپاره جلا ساتل کېږي.',
    'fa': 'دفتر روزانه معاملات عمومی تجارت و حرکات تبادل ارز را نشان می‌دهد. از جستجو و فیلتر بر اساس نوع، ارز، تاریخ و زمان استفاده کنید. مبالغ و موجودی‌های جاری برای هر ارز جداگانه نگهداری می‌شوند.',
    'ur': 'روزانہ جرنل کاروبار کی عمومی ٹرانزیکشنز اور کرنسی ایکسچینج کی نقل و حرکت دکھاتا ہے۔ قسم، کرنسی، تاریخ اور وقت کے مطابق سرچ اور فلٹر استعمال کریں۔ رقم اور رننگ بیلنس ہر کرنسی کے لیے الگ رہتے ہیں۔',
    'ar': 'يعرض السجل اليومي المعاملات العامة للنشاط وحركات صرف العملات. استخدم البحث والتصفية حسب النوع والعملة والتاريخ والوقت. وتبقى المبالغ والأرصدة الجارية منفصلة لكل عملة.',
  },
  'Customer balances automatically show the financial position for each currency. A positive balance is shown in green, a negative balance in red, and zero is neutral. Backdated transactions are placed at their actual date and time and the running balance is recalculated.': {
    'en': 'Customer balances automatically show the financial position for each currency. A positive balance is shown in green, a negative balance in red, and zero is neutral. Backdated transactions are placed at their actual date and time and the running balance is recalculated.',
    'ps': 'د پېرودونکي بیلانس د هر اسعار مالي حالت په اتومات ډول ښيي. مثبت بیلانس په شین، منفي بیلانس په سور او صفر په عادي رنګ ښودل کېږي. که پخوانۍ نېټه او وخت وټاکئ، معامله خپل اصلي ځای ته ځي او ورپسې روان بیلانسونه بیا محاسبه کېږي.',
    'fa': 'موجودی مشتری وضعیت مالی هر ارز را به‌صورت خودکار نشان می‌دهد. موجودی مثبت سبز، موجودی منفی قرمز و صفر خنثی نمایش داده می‌شود. معاملات با تاریخ گذشته در تاریخ و زمان واقعی خود قرار می‌گیرند و موجودی‌های جاری بعدی دوباره محاسبه می‌شوند.',
    'ur': 'گاہک کا بیلنس ہر کرنسی کی مالی حالت خودکار طور پر دکھاتا ہے۔ مثبت بیلنس سبز، منفی سرخ اور صفر غیر جانبدار دکھایا جاتا ہے۔ پچھلی تاریخ کی ٹرانزیکشن اپنے اصل تاریخ اور وقت پر رکھی جاتی ہے اور بعد کے رننگ بیلنس دوبارہ حساب ہوتے ہیں۔',
    'ar': 'يعرض رصيد العميل الوضع المالي لكل عملة تلقائيًا. يظهر الرصيد الموجب بالأخضر والسالب بالأحمر والصفر بلون محايد. توضع المعاملات المؤرخة بتاريخ سابق في تاريخها ووقتها الفعليين وتُعاد حساب الأرصدة الجارية اللاحقة.',
  },
  'Use Exchange for currency buy and sell operations. Select the From and To currencies, enter the amounts and exchange rate, and optionally select a customer. Each currency remains independently recorded.': {
    'en': 'Use Exchange for currency buy and sell operations. Select the From and To currencies, enter the amounts and exchange rate, and optionally select a customer. Each currency remains independently recorded.',
    'ps': 'د اسعارو د پېر او پلور لپاره Exchange وکاروئ. د From او To اسعار وټاکئ، مبلغونه او د تبادلې نرخ ولیکئ او که اړتیا وي پېرودونکی هم وټاکئ. هر اسعار په خپلواکه توګه ثبت پاتې کېږي.',
    'fa': 'برای خرید و فروش ارز از بخش تبادل استفاده کنید. ارز مبدأ و مقصد، مبالغ و نرخ تبدیل را وارد کنید و در صورت نیاز مشتری را انتخاب کنید. هر ارز به صورت مستقل ثبت می‌شود.',
    'ur': 'کرنسی خرید و فروخت کے لیے Exchange استعمال کریں۔ From اور To کرنسیاں منتخب کریں، رقم اور ایکسچینج ریٹ درج کریں اور ضرورت ہو تو گاہک منتخب کریں۔ ہر کرنسی الگ ریکارڈ رہتی ہے۔',
    'ar': 'استخدم قسم الصرافة لعمليات شراء وبيع العملات. اختر عملتي المصدر والوجهة وأدخل المبالغ وسعر الصرف، ويمكن اختيار عميل عند الحاجة. وتبقى كل عملة مسجلة بشكل مستقل.',
  },
  'Cashbox represents the recorded cash movement of the business. Balances are maintained separately by currency and include supported transaction and exchange movements.': {
    'en': 'Cashbox represents the recorded cash movement of the business. Balances are maintained separately by currency and include supported transaction and exchange movements.',
    'ps': 'صندوق د کاروبار ثبت شوی نغدي حرکت ښيي. بیلانسونه د هر اسعار لپاره جلا ساتل کېږي او ملاتړ شوې معاملې او د اسعارو تبادلې پکې شاملې دي.',
    'fa': 'صندوق نشان‌دهنده گردش نقدی ثبت‌شده تجارت است. موجودی‌ها برای هر ارز جداگانه نگهداری می‌شوند و معاملات و تبادلات پشتیبانی‌شده را شامل می‌شوند.',
    'ur': 'کیش باکس کاروبار کی ریکارڈ شدہ نقدی نقل و حرکت دکھاتا ہے۔ بیلنس ہر کرنسی کے لیے الگ رکھا جاتا ہے اور معاون ٹرانزیکشنز اور ایکسچینج شامل ہوتے ہیں۔',
    'ar': 'يمثل الصندوق حركة النقد المسجلة للنشاط. ويتم الاحتفاظ بالأرصدة بشكل منفصل لكل عملة وتشمل المعاملات وحركات الصرف المدعومة.',
  },
  'Reports summarize Money In, Money Out, exchanges and adjustments. Reports can be filtered by date, currency and customer. Each currency is reported separately and is never automatically converted into another currency.': {
    'en': 'Reports summarize Money In, Money Out, exchanges and adjustments. Reports can be filtered by date, currency and customer. Each currency is reported separately and is never automatically converted into another currency.',
    'ps': 'راپورونه Money In، Money Out، تبادلې او سمونونه لنډیز کوي. راپورونه د نېټې، اسعار او پېرودونکي له مخې فلټر کېدای شي. هر اسعار جلا راپور کېږي او هېڅکله په اتومات ډول بل اسعار ته نه بدلېږي.',
    'fa': 'گزارش‌ها Money In، Money Out، تبادلات و اصلاحات را خلاصه می‌کنند. گزارش‌ها بر اساس تاریخ، ارز و مشتری قابل فیلتر هستند. هر ارز جداگانه گزارش می‌شود و هرگز به‌صورت خودکار به ارز دیگری تبدیل نمی‌شود.',
    'ur': 'رپورٹس Money In، Money Out، ایکسچینج اور ایڈجسٹمنٹ کا خلاصہ دکھاتی ہیں۔ تاریخ، کرنسی اور گاہک کے مطابق فلٹر کیا جا سکتا ہے۔ ہر کرنسی الگ رپورٹ ہوتی ہے اور خودکار طور پر دوسری کرنسی میں تبدیل نہیں کی جاتی۔',
    'ar': 'تلخص التقارير Money In وMoney Out وعمليات الصرف والتعديلات. ويمكن تصفية التقارير حسب التاريخ والعملة والعميل. يتم عرض كل عملة بشكل منفصل ولا يتم تحويلها تلقائيًا إلى عملة أخرى.',
  },
  'Ghata can prepare transaction receipts, customer statements and customer balance images for sharing. Always review the information before sending a document to another person.': {
    'en': 'Ghata can prepare transaction receipts, customer statements and customer balance images for sharing. Always review the information before sending a document to another person.',
    'ps': 'ګهته د شریکولو لپاره د معاملو رسیدونه، د پېرودونکو سټېټمنټونه او د بیلانس انځورونه جوړولای شي. له بل چا سره د سند تر شریکولو مخکې تل معلومات وګورئ.',
    'fa': 'گِهته می‌تواند رسید معاملات، صورت‌حساب مشتری و تصویر موجودی مشتری را برای اشتراک آماده کند. همیشه پیش از ارسال سند به شخص دیگر، اطلاعات را بررسی کنید.',
    'ur': 'گھتہ شیئر کرنے کے لیے ٹرانزیکشن رسیدیں، گاہک اسٹیٹمنٹ اور بیلنس تصاویر تیار کر سکتا ہے۔ کسی دوسرے شخص کو دستاویز بھیجنے سے پہلے معلومات ضرور چیک کریں۔',
    'ar': 'يمكن لغهته إعداد إيصالات المعاملات وكشوف حساب العملاء وصور أرصدة العملاء للمشاركة. راجع المعلومات دائمًا قبل إرسال أي مستند إلى شخص آخر.',
  },
  'A business owner can manage staff access. Staff permissions control whether a staff member can add or edit records and whether reports are available to them.': {
    'en': 'A business owner can manage staff access. Staff permissions control whether a staff member can add or edit records and whether reports are available to them.',
    'ps': 'د کاروبار مالک د کارکوونکو لاسرسی اداره کولای شي. د کارکوونکو صلاحیتونه ټاکي چې څوک ریکارډونه اضافه یا سمولای شي او راپورونو ته لاسرسی ولري.',
    'fa': 'مالک تجارت می‌تواند دسترسی کارمندان را مدیریت کند. مجوزهای کارمندان تعیین می‌کند که آیا کارمند می‌تواند رکوردها را اضافه یا ویرایش کند و به گزارش‌ها دسترسی داشته باشد.',
    'ur': 'کاروبار کا مالک عملے کی رسائی منظم کر سکتا ہے۔ اجازتیں طے کرتی ہیں کہ عملے کا رکن ریکارڈ شامل یا ترمیم کر سکتا ہے اور اسے رپورٹس دستیاب ہوں گی یا نہیں۔',
    'ar': 'يمكن لمالك النشاط إدارة وصول الموظفين. وتحدد صلاحيات الموظف ما إذا كان يستطيع إضافة السجلات أو تعديلها وما إذا كانت التقارير متاحة له.',
  },
  'Your Ghata account keeps supported business data synchronized when internet access is available. Signing in with the same account on another supported Android or iPhone device can restore synchronized account data. Exported backup files should be kept in a safe place.': {
    'en': 'Your Ghata account keeps supported business data synchronized when internet access is available. Signing in with the same account on another supported Android or iPhone device can restore synchronized account data. Exported backup files should be kept in a safe place.',
    'ps': 'ستاسو د ګهته حساب، د انټرنېټ د شتون پر مهال، ملاتړ شوي کاروباري معلومات همغږي کوي. په بل ملاتړ شوي Android یا iPhone وسیله کې د همدې حساب په وسیله ننوتل کولای شي همغږي شوي حسابي معلومات بېرته راولي. صادر شوي بیک اپ فایلونه په خوندي ځای کې وساتئ.',
    'fa': 'حساب گِهته شما هنگام دسترسی به اینترنت، اطلاعات پشتیبانی‌شده تجارت را همگام‌سازی می‌کند. ورود با همان حساب در یک دستگاه Android یا iPhone پشتیبانی‌شده دیگر می‌تواند داده‌های همگام‌شده حساب را بازیابی کند. فایل‌های پشتیبان صادرشده را در جای امن نگهداری کنید.',
    'ur': 'آپ کا گھتہ اکاؤنٹ انٹرنیٹ دستیاب ہونے پر معاون کاروباری ڈیٹا کو ہم آہنگ رکھتا ہے۔ کسی دوسرے معاون Android یا iPhone ڈیوائس پر اسی اکاؤنٹ سے سائن اِن کرنے پر ہم آہنگ شدہ اکاؤنٹ ڈیٹا بحال کیا جا سکتا ہے۔ ایکسپورٹ شدہ بیک اپ فائلیں محفوظ جگہ رکھیں۔',
    'ar': 'يحافظ حساب غهته على مزامنة بيانات النشاط المدعومة عند توفر الإنترنت. ويمكن لتسجيل الدخول بالحساب نفسه على جهاز Android أو iPhone مدعوم آخر استعادة بيانات الحساب التي تمت مزامنتها. احتفظ بملفات النسخ الاحتياطي المصدرة في مكان آمن.',
  },
  'Deleted accounting records are moved to the Recycle Bin. Eligible records can be restored during the retention period. Ghata protects accounting history instead of silently destroying important financial records.': {
    'en': 'Deleted accounting records are moved to the Recycle Bin. Eligible records can be restored during the retention period. Ghata protects accounting history instead of silently destroying important financial records.',
    'ps': 'حذف شوي حسابداري ریکارډونه Recycle Bin ته انتقالېږي. د ساتنې مودې په جریان کې د شرایطو وړ ریکارډونه بېرته راګرځول کېدای شي. ګهته د مهمو مالي ریکارډونو د پټې له منځه وړلو پر ځای د حسابدارۍ تاریخ ساتي.',
    'fa': 'رکوردهای حسابداری حذف‌شده به سطل بازیافت منتقل می‌شوند. رکوردهای واجد شرایط در دوره نگهداری قابل بازیابی هستند. گِهته به جای حذف پنهانی اطلاعات مهم مالی، تاریخچه حسابداری را حفظ می‌کند.',
    'ur': 'حذف شدہ اکاؤنٹنگ ریکارڈ Recycle Bin میں منتقل ہوتے ہیں۔ مقررہ مدت کے دوران اہل ریکارڈ بحال کیے جا سکتے ہیں۔ گھتہ اہم مالی ریکارڈ خاموشی سے ختم کرنے کے بجائے اکاؤنٹنگ تاریخ محفوظ رکھتا ہے۔',
    'ar': 'يتم نقل السجلات المحاسبية المحذوفة إلى سلة المحذوفات. ويمكن استعادة السجلات المؤهلة خلال مدة الاحتفاظ. وتحافظ غهته على السجل المحاسبي بدلًا من إتلاف السجلات المالية المهمة دون تنبيه.',
  },
  'Enter financial information carefully and review balances and reports regularly. Ghata is a record-keeping tool; the accuracy of reports depends on the information entered.': {
    'en': 'Enter financial information carefully and review balances and reports regularly. Ghata is a record-keeping tool; the accuracy of reports depends on the information entered.',
    'ps': 'مالي معلومات په احتیاط ثبت کړئ او بیلانسونه او راپورونه په منظم ډول وګورئ. ګهته د ریکارډ ساتلو وسیله ده؛ د راپورونو دقت په داخل شوو معلوماتو پورې اړه لري.',
    'fa': 'اطلاعات مالی را با دقت وارد کنید و موجودی‌ها و گزارش‌ها را به طور منظم بررسی کنید. گِهته ابزار ثبت اطلاعات است و دقت گزارش‌ها به اطلاعات واردشده بستگی دارد.',
    'ur': 'مالی معلومات احتیاط سے درج کریں اور بیلنس اور رپورٹس باقاعدگی سے چیک کریں۔ گھتہ ریکارڈ رکھنے کا ذریعہ ہے؛ رپورٹس کی درستگی درج کردہ معلومات پر منحصر ہے۔',
    'ar': 'أدخل المعلومات المالية بعناية وراجع الأرصدة والتقارير بانتظام. غهته أداة لحفظ السجلات، وتعتمد دقة التقارير على المعلومات التي يتم إدخالها.',
  },
  'Password': {
    'en': 'Password',
    'ps': 'پاسورډ',
    'fa': 'رمز عبور',
    'ur': 'پاس ورڈ',
    'ar': 'كلمة المرور',
  },
  'Login': {
    'en': 'Login',
    'ps': 'ننوتل',
    'fa': 'ورود',
    'ur': 'لاگ اِن',
    'ar': 'تسجيل الدخول',
  },
  'Please enter your Gmail / Email': {
    'en': 'Please enter your Gmail / Email',
    'ps': 'مهرباني وکړئ خپل Gmail / Email ولیکئ',
    'fa': 'لطفاً Gmail / Email خود را وارد کنید',
    'ur': 'براہ کرم اپنا Gmail / Email درج کریں',
    'ar': 'يرجى إدخال Gmail / Email',
  },
  'Disable Staff?': {
    'en': 'Disable Staff?',
    'ps': 'کارکوونکی غیرفعال کړئ؟',
    'fa': 'کارمند غیرفعال شود؟',
    'ur': 'عملے غیرفعال کریں؟',
    'ar': 'تعطيل الموظف؟',
  },
  'Disable': {
    'en': 'Disable',
    'ps': 'غیرفعال کړئ',
    'fa': 'غیرفعال کردن',
    'ur': 'غیر فعال کریں',
    'ar': 'تعطيل',
  },
  'OK': {
    'en': 'OK',
    'ps': 'سمه ده',
    'fa': 'تأیید',
    'ur': 'ٹھیک ہے',
    'ar': 'موافق',
  },
  'Unlock': {
    'en': 'Unlock',
    'ps': 'خلاص کړئ',
    'fa': 'باز کردن',
    'ur': 'کھولیں',
    'ar': 'فتح',
  },
  'Profile': {
    'en': 'Profile',
    'ps': 'پروفایل',
    'fa': 'پروفایل',
    'ur': 'پروفائل',
    'ar': 'الملف الشخصي',
  },
  'Username': {
    'en': 'Username',
    'ps': 'کارن نوم',
    'fa': 'نام کاربری',
    'ur': 'صارف نام',
    'ar': 'اسم المستخدم',
  },
  'Username can be changed every 30 days': {
    'en': 'Username can be changed every 30 days',
    'ps': 'کارن نوم په هرو ۳۰ ورځو کې یو ځل بدلولای شئ',
    'fa': 'نام کاربری هر ۳۰ روز یک‌بار قابل تغییر است',
    'ur': 'صارف نام ہر 30 دن بعد تبدیل کیا جا سکتا ہے',
    'ar': 'يمكن تغيير اسم المستخدم كل 30 يومًا',
  },
  'Email': {
    'en': 'Email',
    'ps': 'برېښنالیک',
    'fa': 'ایمیل',
    'ur': 'ای میل',
    'ar': 'البريد الإلكتروني',
  },
  'Thank you for your business': {
    'en': 'Thank you for your business',
    'ps': 'ستاسو له معاملې مننه',
    'fa': 'از معامله شما سپاسگزاریم',
    'ur': 'آپ کے کاروبار کا شکریہ',
    'ar': 'شكرًا لتعاملك معنا',
  },
  'Customer (Optional)': {
    'en': 'Customer (Optional)',
    'ps': 'پېرودونکی (اختیاري)',
    'fa': 'مشتری (اختیاری)',
    'ur': 'گاہک (اختیاری)',
    'ar': 'العميل (اختياري)',
  },
  'Customer / Person (Optional)': {
    'en': 'Customer / Person (Optional)',
    'ps': 'پېرودونکی / شخص (اختیاري)',
    'fa': 'مشتری / شخص (اختیاری)',
    'ur': 'گاہک / شخص (اختیاری)',
    'ar': 'العميل / الشخص (اختياري)',
  },
  'Time': {
    'en': 'Time',
    'ps': 'وخت',
    'fa': 'زمان',
    'ur': 'وقت',
    'ar': 'الوقت',
  },
  'Address': {
    'en': 'Address',
    'ps': 'پته',
    'fa': 'آدرس',
    'ur': 'پتہ',
    'ar': 'العنوان',
  },
  'Due': {
    'en': 'Due',
    'ps': 'د ورکړې نېټه',
    'fa': 'سررسید',
    'ur': 'ادائیگی کی تاریخ',
    'ar': 'تاريخ الاستحقاق',
  },
  'Overdue': {
    'en': 'Overdue',
    'ps': 'له وخته تېر',
    'fa': 'سررسید گذشته',
    'ur': 'واجب الادا',
    'ar': 'متأخر',
  },
  'Type': {
    'en': 'Type',
    'ps': 'ډول',
    'fa': 'نوع',
    'ur': 'قسم',
    'ar': 'النوع',
  },
  'Owner': {
    'en': 'Owner',
    'ps': 'مالک',
    'fa': 'مالک',
    'ur': 'مالک',
    'ar': 'المالك',
  },
  'No outstanding balance.': {
    'en': 'No outstanding balance.',
    'ps': 'هیڅ پاتې بیلانس نشته.',
    'fa': 'هیچ موجودی معوقی وجود ندارد.',
    'ur': 'کوئی بقایا بیلنس نہیں ہے۔',
    'ar': 'لا يوجد رصيد مستحق.',
  },
  'Exchange removed from Recycle Bin.': {
    'en': 'Exchange removed from Recycle Bin.',
    'ps': 'تبادله له حذف شوو معلوماتو څخه لرې شوه.',
    'fa': 'تبادله از سطل بازیافت حذف شد.',
    'ur': 'ایکسچینج ری سائیکل بن سے حذف کر دیا گیا۔',
    'ar': 'تم حذف عملية الصرف من سلة المحذوفات.',
  },
  'Customer removed from Recycle Bin.': {
    'en': 'Customer removed from Recycle Bin.',
    'ps': 'پېرودونکی له حذف شوو معلوماتو څخه لرې شو.',
    'fa': 'مشتری از سطل بازیافت حذف شد.',
    'ur': 'گاہک ری سائیکل بن سے حذف کر دیا گیا۔',
    'ar': 'تم حذف العميل من سلة المحذوفات.',
  },
  'Transaction removed from Recycle Bin.': {
    'en': 'Transaction removed from Recycle Bin.',
    'ps': 'معامله له حذف شوو معلوماتو څخه لرې شوه.',
    'fa': 'معامله از سطل بازیافت حذف شد.',
    'ur': 'لین دین ری سائیکل بن سے حذف کر دیا گیا۔',
    'ar': 'تم حذف المعاملة من سلة المحذوفات.',
  },
  'Transaction moved to Recycle Bin. You can restore it within 30 days.': {
    'en': 'Transaction moved to Recycle Bin. You can restore it within 30 days.',
    'ps': 'معامله حذف شوو معلوماتو ته انتقال شوه. تر ۳۰ ورځو پورې یې بېرته راګرځولای شئ.',
    'fa': 'معامله به سطل بازیافت منتقل شد. تا ۳۰ روز می‌توانید آن را بازیابی کنید.',
    'ur': 'لین دین ری سائیکل بن میں منتقل ہو گیا۔ آپ اسے 30 دن کے اندر بحال کر سکتے ہیں۔',
    'ar': 'تم نقل المعاملة إلى سلة المحذوفات. يمكنك استعادتها خلال 30 يومًا.',
  },
  'Customer moved to Recycle Bin. You can restore it within 30 days.': {
    'en': 'Customer moved to Recycle Bin. You can restore it within 30 days.',
    'ps': 'پېرودونکی حذف شوو معلوماتو ته انتقال شو. تر ۳۰ ورځو پورې یې بېرته راګرځولای شئ.',
    'fa': 'مشتری به سطل بازیافت منتقل شد. تا ۳۰ روز می‌توانید آن را بازیابی کنید.',
    'ur': 'گاہک ری سائیکل بن میں منتقل ہو گیا۔ آپ اسے 30 دن کے اندر بحال کر سکتے ہیں۔',
    'ar': 'تم نقل العميل إلى سلة المحذوفات. يمكنك استعادته خلال 30 يومًا.',
  },
  'Business Ledger & Accounting': {
    'en': 'Business Ledger & Accounting',
    'ps': 'د سوداګرۍ حساب او محاسبه',
    'fa': 'دفتر حساب و حسابداری تجارت',
    'ur': 'کاروباری کھاتہ اور حسابداری',
    'ar': 'دفتر الأعمال والمحاسبة',
  },
  'Enter your Gmail / Email': {
    'en': 'Enter your Gmail / Email',
    'ps': 'خپل Gmail / Email ولیکئ',
    'fa': 'Gmail / Email خود را وارد کنید',
    'ur': 'اپنا Gmail / Email درج کریں',
    'ar': 'أدخل Gmail / Email',
  },
  'Disabled': {
    'en': 'Disabled',
    'ps': 'غیرفعال',
    'fa': 'غیرفعال',
    'ur': 'غیر فعال',
    'ar': 'معطل',
  },
  'Change App PIN': {
    'en': 'Change App PIN',
    'ps': 'د اپ PIN بدل کړئ',
    'fa': 'تغییر PIN برنامه',
    'ur': 'ایپ PIN تبدیل کریں',
    'ar': 'تغيير PIN التطبيق',
  },
  'Create App PIN': {
    'en': 'Create App PIN',
    'ps': 'د اپ PIN جوړ کړئ',
    'fa': 'ایجاد PIN برنامه',
    'ur': 'ایپ PIN بنائیں',
    'ar': 'إنشاء PIN للتطبيق',
  },
  'App PIN saved.': {
    'en': 'App PIN saved.',
    'ps': 'د اپ PIN خوندي شو.',
    'fa': 'PIN برنامه ذخیره شد.',
    'ur': 'ایپ PIN محفوظ ہوگیا۔',
    'ar': 'تم حفظ PIN التطبيق.',
  },
  'App PIN created.': {
    'en': 'App PIN created.',
    'ps': 'د اپ PIN جوړ شو.',
    'fa': 'PIN برنامه ایجاد شد.',
    'ur': 'ایپ PIN بن گیا۔',
    'ar': 'تم إنشاء PIN التطبيق.',
  },
  'Use a 4 to 6 digit PIN to protect Ghata.': {
    'en': 'Use a 4 to 6 digit PIN to protect Ghata.',
    'ps': 'د ګهته د ساتنې لپاره له ۴ تر ۶ عددي PIN وکاروئ.',
    'fa': 'برای محافظت از گِهته از PIN چهار تا شش رقمی استفاده کنید.',
    'ur': 'گھتہ کی حفاظت کے لیے 4 سے 6 ہندسوں کا PIN استعمال کریں۔',
    'ar': 'استخدم PIN من 4 إلى 6 أرقام لحماية غهته.',
  },
  'Verification email sent. Please check your email.': {
    'en': 'Verification email sent. Please check your email.',
    'ps': 'د تایید ایمیل ولېږل شو. خپل ایمیل وګورئ.',
    'fa': 'ایمیل تأیید ارسال شد. ایمیل خود را بررسی کنید.',
    'ur': 'تصدیقی ای میل بھیج دی گئی ہے۔ اپنا ای میل چیک کریں۔',
    'ar': 'تم إرسال بريد التحقق. تحقق من بريدك الإلكتروني.',
  },
  'You do not owe this customer in this currency.': {
    'en': 'You do not owe this customer in this currency.',
    'ps': 'تاسو دې پېرودونکي ته په دې اسعارو کې پور نه لرئ.',
    'fa': 'شما در این ارز به این مشتری بدهکار نیستید.',
    'ur': 'آپ اس کرنسی میں اس گاہک کے مقروض نہیں ہیں۔',
    'ar': 'أنت غير مدين لهذا العميل بهذه العملة.',
  },
  'Summary': {
    'en': 'Summary',
    'ps': 'لنډیز',
    'fa': 'خلاصه',
    'ur': 'خلاصہ',
    'ar': 'الملخص',
  },
  'General': {
    'en': 'General',
    'ps': 'عمومي',
    'fa': 'عمومی',
    'ur': 'عمومی',
    'ar': 'عام',
  },
  'Customer Full Statement': {
    'en': 'Customer Full Statement',
    'ps': 'د پېرودونکي بشپړ حساب',
    'fa': 'صورت‌حساب کامل مشتری',
    'ur': 'گاہک کا مکمل اسٹیٹمنٹ',
    'ar': 'كشف الحساب الكامل للعميل',
  },
  'Balances': {
    'en': 'Balances',
    'ps': 'بیلانسونه',
    'fa': 'موجودی‌ها',
    'ur': 'بیلنس',
    'ar': 'الأرصدة',
  },
  'History': {
    'en': 'History',
    'ps': 'تاریخچه',
    'fa': 'تاریخچه',
    'ur': 'تاریخ',
    'ar': 'السجل',
  },
  'Available Balance': {
    'en': 'Available Balance',
    'ps': 'موجود بیلانس',
    'fa': 'موجودی قابل دسترس',
    'ur': 'دستیاب بیلنس',
    'ar': 'الرصيد المتاح',
  },
  'Negative Balance': {
    'en': 'Negative Balance',
    'ps': 'منفي بیلانس',
    'fa': 'موجودی منفی',
    'ur': 'منفی بیلنس',
    'ar': 'الرصيد السالب',
  },
  'Exchange moved to Recycle Bin. You can restore it within 30 days.': {
    'en': 'Exchange moved to Recycle Bin. You can restore it within 30 days.',
    'ps': 'تبادله حذف شوو معلوماتو ته انتقال شوه. تر ۳۰ ورځو پورې یې بېرته راګرځولای شئ.',
    'fa': 'تبادله به سطل بازیافت منتقل شد. تا ۳۰ روز می‌توانید آن را بازیابی کنید.',
    'ur': 'ایکسچینج ری سائیکل بن میں منتقل ہوگیا۔ آپ اسے 30 دن کے اندر بحال کر سکتے ہیں۔',
    'ar': 'تم نقل عملية الصرف إلى سلة المحذوفات. يمكنك استعادتها خلال 30 يومًا.',
  },
  'Amount You Give': {
    'en': 'Amount You Give',
    'ps': 'هغه مقدار چې ورکوئ',
    'fa': 'مقداری که می‌دهید',
    'ur': 'وہ رقم جو آپ دیتے ہیں',
    'ar': 'المبلغ الذي تدفعه',
  },
  'Exchange Rate (optional)': {
    'en': 'Exchange Rate (optional)',
    'ps': 'د تبادلې نرخ (اختیاري)',
    'fa': 'نرخ تبادله (اختیاری)',
    'ur': 'شرح تبادلہ (اختیاری)',
    'ar': 'سعر الصرف (اختياري)',
  },
  'From Amount': {
    'en': 'From Amount',
    'ps': 'د ورکړې مقدار',
    'fa': 'مقدار مبدأ',
    'ur': 'ابتدائی رقم',
    'ar': 'المبلغ المصدر',
  },
  'To Amount': {
    'en': 'To Amount',
    'ps': 'د ترلاسه کولو مقدار',
    'fa': 'مقدار مقصد',
    'ur': 'وصولی رقم',
    'ar': 'المبلغ المستلم',
  },
  'Rate (optional)': {
    'en': 'Rate (optional)',
    'ps': 'نرخ (اختیاري)',
    'fa': 'نرخ (اختیاری)',
    'ur': 'شرح (اختیاری)',
    'ar': 'السعر (اختياري)',
  },
  'Saving...': {
    'en': 'Saving...',
    'ps': 'خوندي کېږي...',
    'fa': 'در حال ذخیره...',
    'ur': 'محفوظ ہو رہا ہے...',
    'ar': 'جارٍ الحفظ...',
  },
  'Record Exchange': {
    'en': 'Record Exchange',
    'ps': 'تبادله ثبت کړئ',
    'fa': 'ثبت تبادله',
    'ur': 'ایکسچینج محفوظ کریں',
    'ar': 'تسجيل الصرف',
  },
  'Generated by Ghata - Business Ledger & Accounting': {
    'en': 'Generated by Ghata - Business Ledger & Accounting',
    'ps': 'د ګهته – سوداګرۍ حساب او محاسبې لخوا جوړ شوی',
    'fa': 'ایجاد شده توسط گِهته – دفتر حساب و حسابداری تجارت',
    'ur': 'گھتہ – کاروباری کھاتہ اور حسابداری کے ذریعے تیار شدہ',
    'ar': 'تم إنشاؤه بواسطة غهته – دفتر الأعمال والمحاسبة',
  },
  'Complete Guide': {
    'en': 'Complete Guide',
    'ps': 'بشپړ لارښود',
    'fa': 'راهنمای کامل',
    'ur': 'مکمل رہنمائی',
    'ar': 'الدليل الكامل',
  },
  'Create Account': {
    'en': 'Create Account',
    'ps': 'حساب جوړ کړئ',
    'fa': 'ایجاد حساب',
    'ur': 'اکاؤنٹ بنائیں',
    'ar': 'إنشاء حساب',
  },
  'Remove App PIN': {
    'en': 'Remove App PIN',
    'ps': 'د اپ PIN لرې کړئ',
    'fa': 'حذف PIN برنامه',
    'ur': 'ایپ PIN ہٹائیں',
    'ar': 'إزالة رمز التطبيق',
  },
  'Restore Backup': {
    'en': 'Restore Backup',
    'ps': 'بیک اپ را وګرځوئ',
    'fa': 'بازیابی پشتیبان',
    'ur': 'بیک اپ بحال کریں',
    'ar': 'استعادة النسخة',
  },
  'Change Password': {
    'en': 'Change Password',
    'ps': 'پاسورډ بدل کړئ',
    'fa': 'تغییر رمز',
    'ur': 'پاس ورڈ تبدیل کریں',
    'ar': 'تغيير كلمة المرور',
  },
  'Current Balance': {
    'en': 'Current Balance',
    'ps': 'اوسنی بیلانس',
    'fa': 'موجودی فعلی',
    'ur': 'موجودہ بیلنس',
    'ar': 'الرصيد الحالي',
  },
  'Delete Customer': {
    'en': 'Delete Customer',
    'ps': 'پېرودونکی حذف کړئ',
    'fa': 'حذف مشتری',
    'ur': 'گاہک حذف کریں',
    'ar': 'حذف العميل',
  },
  'Delete Exchange': {
    'en': 'Delete Exchange',
    'ps': 'تبادله حذف کړئ',
    'fa': 'حذف تبادله',
    'ur': 'ایکسچینج حذف کریں',
    'ar': 'حذف الصرافة',
  },
  'Exchange In': {
    'en': 'Exchange In',
    'ps': 'داخلي تبادله',
    'fa': 'تبادله ورودی',
    'ur': 'اندر آنے والا تبادلہ',
    'ar': 'تبادل وارد',
  },
  'Exchange Out': {
    'en': 'Exchange Out',
    'ps': 'وتلې تبادله',
    'fa': 'تبادله خروجی',
    'ur': 'باہر جانے والا تبادلہ',
    'ar': 'تبادل صادر',
  },
  'Net Cash Flow': {
    'en': 'Net Cash Flow',
    'ps': 'خالص نغدي جریان',
    'fa': 'جریان خالص نقدی',
    'ur': 'خالص نقد بہاؤ',
    'ar': 'صافي التدفق النقدي',
  },
  'Detailed Report': {
    'en': 'Detailed Report',
    'ps': 'تفصیلي راپور',
    'fa': 'گزارش تفصیلی',
    'ur': 'تفصیلی رپورٹ',
    'ar': 'تقرير مفصل',
  },
  'Forgot Password': {
    'en': 'Forgot Password',
    'ps': 'پاسورډ مو هېر شوی',
    'fa': 'فراموشی رمز',
    'ur': 'پاس ورڈ بھول گئے',
    'ar': 'نسيت كلمة المرور',
  },
  'Send Reset Link': {
    'en': 'Send Reset Link',
    'ps': 'د بیا تنظیم لینک ولېږئ',
    'fa': 'ارسال لینک بازنشانی',
    'ur': 'ری سیٹ لنک بھیجیں',
    'ar': 'إرسال رابط الاستعادة',
  },
  'Business Address': {
    'en': 'Business Address',
    'ps': 'د کاروبار پته',
    'fa': 'آدرس تجارت',
    'ur': 'کاروباری پتہ',
    'ar': 'عنوان النشاط',
  },
  'Business Profile': {
    'en': 'Business Profile',
    'ps': 'د کاروبار پروفایل',
    'fa': 'پروفایل تجارت',
    'ur': 'کاروباری پروفائل',
    'ar': 'ملف النشاط',
  },
  'Confirm Password': {
    'en': 'Confirm Password',
    'ps': 'پاسورډ تایید کړئ',
    'fa': 'تأیید رمز',
    'ur': 'پاس ورڈ کی تصدیق',
    'ar': 'تأكيد كلمة المرور',
  },
  'Currency Summary': {
    'en': 'Currency Summary',
    'ps': 'د اسعارو لنډیز',
    'fa': 'خلاصه ارزها',
    'ur': 'کرنسی خلاصہ',
    'ar': 'ملخص العملات',
  },
  'Customer currencies are calculated separately.': {
  'en': 'Each customer currency is calculated separately. AFN, PKR, USD and every other currency keep their own independent running balance.',
  'ps': 'د هر پېرودونکي هره کرنسي جلا حسابېږي. افغانۍ، پاکستانۍ کلدارې، ډالر او نورې ټولې کرنسۍ خپل مستقل روان بیلانس لري.',
  'fa': 'هر ارز مشتری به‌صورت جداگانه محاسبه می‌شود. افغانی، روپیه پاکستان، دالر و سایر ارزها هرکدام موجودی جاری مستقل دارند.',
  'ur': 'ہر گاہک کی ہر کرنسی الگ حساب ہوتی ہے۔ افغانی، پاکستانی روپیہ، ڈالر اور دوسری تمام کرنسیاں اپنا الگ چلتا ہوا بیلنس رکھتی ہیں۔',
  'ar': 'يتم حساب كل عملة للعميل بشكل منفصل. الأفغاني والروبية الباكستانية والدولار وباقي العملات لكل منها رصيد جارٍ مستقل.',
},
'Customer transactions can be edited or deleted by long press.': {
  'en': 'Press and hold a customer transaction to open Edit and Delete. After editing or deleting an older transaction, the running balance is recalculated automatically.',
  'ps': 'د پېرودونکي پر معاملې اوږد فشار ورکړئ، Edit او Delete به ښکاره شي. که پخوانۍ معامله اصلاح یا ړنګه شي، روان بیلانس په اتومات ډول له سره حسابېږي.',
  'fa': 'روی معامله مشتری لمس طولانی کنید تا Edit و Delete نمایش داده شود. پس از ویرایش یا حذف معامله قبلی، موجودی جاری به‌صورت خودکار دوباره محاسبه می‌شود.',
  'ur': 'گاہک کی ٹرانزیکشن کو دیر تک دبائیں تو Edit اور Delete ظاہر ہوں گے۔ پرانی ٹرانزیکشن میں ترمیم یا حذف کے بعد چلتا ہوا بیلنس خودکار طور پر دوبارہ حساب ہوتا ہے۔',
  'ar': 'اضغط مطولاً على معاملة العميل لإظهار Edit وDelete. بعد تعديل أو حذف معاملة قديمة، تتم إعادة حساب الرصيد الجاري تلقائياً.',
},
'Customer exchange affects each currency separately.': {
  'en': 'Customer Exchange updates both currencies separately. The outgoing currency is reduced and the incoming currency is increased without mixing their balances.',
  'ps': 'د پېرودونکي Exchange دواړه کرنسۍ جلا بدلوي. وتلې کرنسي کمېږي او راغلې کرنسي زیاتېږي، خو د دواړو بیلانسونه سره نه ګډېږي.',
  'fa': 'Exchange مشتری هر دو ارز را جداگانه تغییر می‌دهد. ارز خروجی کم و ارز ورودی زیاد می‌شود و موجودی‌ها با هم مخلوط نمی‌شوند.',
  'ur': 'گاہک کا Exchange دونوں کرنسیوں کو الگ الگ تبدیل کرتا ہے۔ جانے والی کرنسی کم اور آنے والی کرنسی زیادہ ہوتی ہے، دونوں بیلنس آپس میں نہیں ملتے۔',
  'ar': 'يحدّث Exchange الخاص بالعميل كلتا العملتين بشكل منفصل. تنخفض العملة الخارجة وتزداد العملة الداخلة دون خلط الأرصدة.',
},
'Customer Balance': {
    'en': 'Customer Balance',
    'ps': 'د پېرودونکي بیلانس',
    'fa': 'موجودی مشتری',
    'ur': 'گاہک کا بیلنس',
    'ar': 'رصيد العميل',
  },
  'Edit Transaction': {
    'en': 'Edit Transaction',
    'ps': 'معامله سمه کړئ',
    'fa': 'ویرایش معامله',
    'ur': 'لین دین میں ترمیم',
    'ar': 'تعديل المعاملة',
  },
  'Forgot Password?': {
    'en': 'Forgot Password?',
    'ps': 'پاسورډ مو هېر شوی؟',
    'fa': 'رمز را فراموش کرده‌اید؟',
    'ur': 'پاس ورڈ بھول گئے؟',
    'ar': 'نسيت كلمة المرور؟',
  },
  'PIN (4-6 digits)': {
    'en': 'PIN (4-6 digits)',
    'ps': 'PIN (۴-۶ شمېرې)',
    'fa': 'PIN (۴-۶ رقم)',
    'ur': 'PIN (4-6 ہندسے)',
    'ar': 'الرمز (4-6 أرقام)',
  },
  'Recent Exchanges': {
    'en': 'Recent Exchanges',
    'ps': 'وروستۍ تبادلې',
    'fa': 'تبادلات اخیر',
    'ur': 'حالیہ ایکسچینجز',
    'ar': 'عمليات الصرافة الأخيرة',
  },
  'Staff Management': {
    'en': 'Staff Management',
    'ps': 'د کارکوونکو مدیریت',
    'fa': 'مدیریت کارمندان',
    'ur': 'عملے کا انتظام',
    'ar': 'إدارة الموظفين',
  },
  'Transaction Type': {
    'en': 'Transaction Type',
    'ps': 'د معاملې ډول',
    'fa': 'نوع معامله',
    'ur': 'لین دین کی قسم',
    'ar': 'نوع المعاملة',
  },
  'Clear All Filters': {
    'en': 'Clear All Filters',
    'ps': 'ټول فلټرونه پاک کړئ',
    'fa': 'پاک کردن همه فیلترها',
    'ur': 'تمام فلٹر صاف کریں',
    'ar': 'مسح كل عوامل التصفية',
  },
  'Enter Current PIN': {
    'en': 'Enter Current PIN',
    'ps': 'اوسنی PIN ولیکئ',
    'fa': 'PIN فعلی را وارد کنید',
    'ur': 'موجودہ PIN درج کریں',
    'ar': 'أدخل الرمز الحالي',
  },
  'No country found.': {
    'en': 'No country found.',
    'ps': 'هېواد ونه موندل شو.',
    'fa': 'کشوری یافت نشد.',
    'ur': 'ملک نہیں ملا۔',
    'ar': 'لم يتم العثور على دولة.',
  },
  'No customers yet.': {
    'en': 'No customers yet.',
    'ps': 'تر اوسه پېرودونکي نشته.',
    'fa': 'هنوز مشتری نیست.',
    'ur': 'ابھی کوئی گاہک نہیں۔',
    'ar': 'لا يوجد عملاء بعد.',
  },
  'Share PDF Receipt': {
    'en': 'Share PDF Receipt',
    'ps': 'PDF رسید شریک کړئ',
    'fa': 'اشتراک رسید PDF',
    'ur': 'PDF رسید شیئر کریں',
    'ar': 'مشاركة إيصال PDF',
  },
  'Afghanistan or +93': {
    'en': 'Afghanistan or +93',
    'ps': 'افغانستان یا +93',
    'fa': 'افغانستان یا +93',
    'ur': 'افغانستان یا +93',
    'ar': 'أفغانستان أو +93',
  },
  'Amount You Receive': {
    'en': 'Amount You Receive',
    'ps': 'هغه اندازه چې ترلاسه کوئ',
    'fa': 'مبلغ دریافتی شما',
    'ur': 'آپ کو ملنے والی رقم',
    'ar': 'المبلغ الذي تستلمه',
  },
  'Customer Statement': {
    'en': 'Customer Statement',
    'ps': 'د پېرودونکي حساب',
    'fa': 'صورت‌حساب مشتری',
    'ur': 'گاہک کا بیان',
    'ar': 'كشف حساب العميل',
  },
  'Customer (optional)': {
    'en': 'Customer (optional)',
    'ps': 'پېرودونکی (اختیاري)',
    'fa': 'مشتری (اختیاری)',
    'ur': 'گاہک (اختیاری)',
    'ar': 'العميل (اختياري)',
  },
  'Delete Permanently?': {
    'en': 'Delete Permanently?',
    'ps': 'دایمي حذف شي؟',
    'fa': 'حذف دائمی؟',
    'ur': 'مستقل حذف کریں؟',
    'ar': 'حذف نهائي؟',
  },
  'Move to Recycle Bin': {
    'en': 'Move to Recycle Bin',
    'ps': 'حذف شوو ته یې ولېږئ',
    'fa': 'انتقال به سطل بازیافت',
    'ur': 'ری سائیکل بن میں منتقل کریں',
    'ar': 'نقل إلى سلة المحذوفات',
  },
  'No report data yet.': {
    'en': 'No report data yet.',
    'ps': 'تر اوسه د راپور معلومات نشته.',
    'fa': 'هنوز داده گزارش نیست.',
    'ur': 'ابھی رپورٹ ڈیٹا نہیں۔',
    'ar': 'لا توجد بيانات تقرير بعد.',
  },
  'No staff added yet.': {
    'en': 'No staff added yet.',
    'ps': 'تر اوسه کارکوونکی نه دی اضافه شوی.',
    'fa': 'هنوز کارمندی اضافه نشده.',
    'ur': 'ابھی عملہ شامل نہیں۔',
    'ar': 'لم تتم إضافة موظفين بعد.',
  },
  'Search customers...': {
    'en': 'Search customers...',
    'ps': 'پېرودونکي ولټوئ...',
    'fa': 'جستجوی مشتریان...',
    'ur': 'گاہک تلاش کریں...',
    'ar': 'بحث العملاء...',
  },
  'Share Balance Image': {
    'en': 'Share Balance Image',
    'ps': 'د بیلانس انځور شریک کړئ',
    'fa': 'اشتراک تصویر موجودی',
    'ur': 'بیلنس تصویر شیئر کریں',
    'ar': 'مشاركة صورة الرصيد',
  },
  'Transaction Receipt': {
    'en': 'Transaction Receipt',
    'ps': 'د معاملې رسید',
    'fa': 'رسید معامله',
    'ur': 'لین دین کی رسید',
    'ar': 'إيصال المعاملة',
  },
  'Confirm New Password': {
    'en': 'Confirm New Password',
    'ps': 'نوی پاسورډ تایید کړئ',
    'fa': 'تأیید رمز جدید',
    'ur': 'نئے پاس ورڈ کی تصدیق',
    'ar': 'تأكيد كلمة المرور الجديدة',
  },
  'Full Statement (PDF)': {
    'en': 'Full Statement (PDF)',
    'ps': 'بشپړ حساب (PDF)',
    'fa': 'صورت‌حساب کامل (PDF)',
    'ur': 'مکمل بیان (PDF)',
    'ar': 'كشف كامل (PDF)',
  },
  'Move to Recycle Bin?': {
    'en': 'Move to Recycle Bin?',
    'ps': 'حذف شوو ته ولېږل شي؟',
    'fa': 'به سطل بازیافت منتقل شود؟',
    'ur': 'ری سائیکل بن میں منتقل کریں؟',
    'ar': 'نقل إلى سلة المحذوفات؟',
  },
  'No transactions yet.': {
    'en': 'No transactions yet.',
    'ps': 'تر اوسه معاملې نشته.',
    'fa': 'هنوز معامله‌ای نیست.',
    'ur': 'ابھی کوئی لین دین نہیں۔',
    'ar': 'لا توجد معاملات بعد.',
  },
  'General / No Customer': {
    'en': 'General / No Customer',
    'ps': 'عمومي / بې پېرودونکي',
    'fa': 'عمومی / بدون مشتری',
    'ur': 'عام / کوئی گاہک نہیں',
    'ar': 'عام / بدون عميل',
  },
  'Recycle Bin is empty.': {
    'en': 'Recycle Bin is empty.',
    'ps': 'حذف شوي توکي تش دي.',
    'fa': 'سطل بازیافت خالی است.',
    'ur': 'ری سائیکل بن خالی ہے۔',
    'ar': 'سلة المحذوفات فارغة.',
  },
  'Don\'t have an account?': {
    'en': 'Don\'t have an account?',
    'ps': 'حساب نه لرئ؟',
    'fa': 'حساب ندارید؟',
    'ur': 'اکاؤنٹ نہیں ہے؟',
    'ar': 'ليس لديك حساب؟',
  },
  'No matching customers.': {
    'en': 'No matching customers.',
    'ps': 'سمون لرونکی پېرودونکی نشته.',
    'fa': 'مشتری مطابق یافت نشد.',
    'ur': 'مماثل گاہک نہیں ملا۔',
    'ar': 'لا يوجد عميل مطابق.',
  },
  'No outstanding balance': {
    'en': 'No outstanding balance',
    'ps': 'پاتې بیلانس نشته',
    'fa': 'موجودی باقی نیست',
    'ur': 'کوئی بقایا بیلنس نہیں',
    'ar': 'لا يوجد رصيد مستحق',
  },
  'No transactions found.': {
    'en': 'No transactions found.',
    'ps': 'معامله ونه موندل شوه.',
    'fa': 'معامله‌ای یافت نشد.',
    'ur': 'کوئی لین دین نہیں ملا۔',
    'ar': 'لم يتم العثور على معاملات.',
  },
  'Passwords do not match': {
    'en': 'Passwords do not match',
    'ps': 'پاسورډونه سره برابر نه دي',
    'fa': 'رمزها مطابقت ندارند',
    'ur': 'پاس ورڈ مماثل نہیں',
    'ar': 'كلمتا المرور غير متطابقتين',
  },
  'Search country or code': {
    'en': 'Search country or code',
    'ps': 'هېواد یا کوډ ولټوئ',
    'fa': 'جستجوی کشور یا کد',
    'ur': 'ملک یا کوڈ تلاش کریں',
    'ar': 'بحث عن دولة أو رمز',
  },
  'Search transactions...': {
    'en': 'Search transactions...',
    'ps': 'معاملې ولټوئ...',
    'fa': 'جستجوی معاملات...',
    'ur': 'لین دین تلاش کریں...',
    'ar': 'بحث المعاملات...',
  },
  'Unable to load profile': {
    'en': 'Unable to load profile',
    'ps': 'پروفایل نه شي پورته کېدای',
    'fa': 'بارگذاری پروفایل ممکن نیست',
    'ur': 'پروفائل لوڈ نہیں ہو سکا',
    'ar': 'تعذر تحميل الملف',
  },
  'You are not logged in.': {
    'en': 'You are not logged in.',
    'ps': 'تاسو ننوتلي نه یاست.',
    'fa': 'شما وارد نشده‌اید.',
    'ur': 'آپ لاگ اِن نہیں ہیں۔',
    'ar': 'أنت غير مسجل الدخول.',
  },
  'You are not signed in.': {
    'en': 'You are not signed in.',
    'ps': 'تاسو حساب ته نه یاست ننوتلي.',
    'fa': 'شما وارد حساب نشده‌اید.',
    'ur': 'آپ سائن اِن نہیں ہیں۔',
    'ar': 'أنت غير مسجل الدخول.',
  },

  'The Dashboard gives you a quick overview of your business.': {
    'en': 'The Dashboard gives you a quick overview of your business.',
    'ps': 'ډشبورډ ستاسو د کاروبار چټک عمومي حالت ښيي.',
    'fa': 'داشبورد نمای سریع از وضعیت تجارت شما نشان می‌دهد.',
    'ur': 'ڈیش بورڈ آپ کے کاروبار کا فوری خلاصہ دکھاتا ہے۔',
    'ar': 'تعرض لوحة التحكم نظرة سريعة على نشاطك.',
  },
  'Cashbox, Money In, Money Out, You Receive and You Pay are': {
    'en': 'Cashbox, Money In, Money Out, You Receive and You Pay are',
    'ps': 'صندوق، داخلې پیسې، وتلې پیسې، ستاسو اخیستنې او ورکړې',
    'fa': 'صندوق، پول ورودی، پول خروجی، دریافت‌ها و پرداخت‌های شما',
    'ur': 'کیش باکس، آمد رقم، خرج رقم، وصولیاں اور ادائیگیاں',
    'ar': 'الصندوق والأموال الداخلة والخارجة والمستحقات والمدفوعات',
  },
  'shown separately for each currency. Ghata does not combine': {
    'en': 'shown separately for each currency. Ghata does not combine',
    'ps': 'د هر اسعار لپاره جلا ښودل کېږي. ګهته بېلابېل اسعار',
    'fa': 'برای هر ارز جداگانه نمایش داده می‌شوند. گهته ارزهای مختلف را',
    'ur': 'ہر کرنسی کے لیے الگ دکھائے جاتے ہیں۔ گھتہ مختلف کرنسیوں کو',
    'ar': 'تُعرض بشكل منفصل لكل عملة. لا تقوم غاتا بدمج العملات المختلفة',
  },
  'different currencies into a converted grand total.': {
    'en': 'different currencies into a converted grand total.',
    'ps': 'په یوه تبدیل شوي عمومي مجموع کې نه ګډوي.',
    'fa': 'در یک مجموع تبدیل‌شده با هم ترکیب نمی‌کند.',
    'ur': 'ایک تبدیل شدہ مجموعی رقم میں نہیں ملاتا۔',
    'ar': 'في إجمالي واحد بعد التحويل.',
  },
  'Use the Add button to record Money In, Money Out and adjustments.': {
    'en': 'Use the Add button to record Money In, Money Out and adjustments.',
    'ps': 'د Add تڼۍ له لارې داخلې او وتلې پیسې او سمونونه ثبت کړئ.',
    'fa': 'با دکمه افزودن، پول ورودی، پول خروجی و اصلاحات را ثبت کنید.',
    'ur': 'Add بٹن سے آمد رقم، خرج رقم اور ایڈجسٹمنٹ درج کریں۔',
    'ar': 'استخدم زر الإضافة لتسجيل الأموال الداخلة والخارجة والتسويات.',
  },
  'date, time and customer when required. You can also add a': {
    'en': 'date, time and customer when required. You can also add a',
    'ps': 'نېټه، وخت او د اړتیا پر مهال پېرودونکی وټاکئ. همدارنګه',
    'fa': 'تاریخ، زمان و در صورت نیاز مشتری را انتخاب کنید. همچنین',
    'ur': 'تاریخ، وقت اور ضرورت پر گاہک منتخب کریں۔ آپ',
    'ar': 'والتاريخ والوقت والعميل عند الحاجة. ويمكنك أيضاً إضافة',
  },
  'description and reference number.': {
    'en': 'description and reference number.',
    'ps': 'تفصیل او د حوالې شمېره هم اضافه کولای شئ.',
    'fa': 'توضیحات و شماره مرجع نیز اضافه کنید.',
    'ur': 'تفصیل اور حوالہ نمبر بھی شامل کر سکتے ہیں۔',
    'ar': 'وصف ورقم مرجعي.',
  },
  'The Daily Journal keeps your transaction history. Use search': {
    'en': 'The Daily Journal keeps your transaction history. Use search',
    'ps': 'ورځنی ژورنال ستاسو د معاملو تاریخچه ساتي. د لټون',
    'fa': 'دفتر روزانه تاریخ معاملات شما را نگه می‌دارد. از جستجو',
    'ur': 'روزانہ جرنل آپ کے لین دین کی تاریخ رکھتا ہے۔ تلاش',
    'ar': 'يحتفظ السجل اليومي بتاريخ معاملاتك. استخدم البحث',
  },
  'and filters to find transactions. Transactions can be': {
    'en': 'and filters to find transactions. Transactions can be',
    'ps': 'او فلټرونو له لارې معاملې پیدا کړئ. معاملې',
    'fa': 'و فیلترها برای یافتن معاملات استفاده کنید. معاملات',
    'ur': 'اور فلٹر سے لین دین تلاش کریں۔ لین دین',
    'ar': 'وعوامل التصفية للعثور على المعاملات. ويمكن',
  },
  'reviewed with their amount, currency, customer, date, time': {
    'en': 'reviewed with their amount, currency, customer, date, time',
    'ps': 'د اندازې، اسعارو، پېرودونکي، نېټې او وخت سره کتل کېدای شي',
    'fa': 'با مبلغ، ارز، مشتری، تاریخ و زمان بررسی می‌شوند',
    'ur': 'رقم، کرنسی، گاہک، تاریخ اور وقت کے ساتھ دیکھی جا سکتی ہیں',
    'ar': 'مراجعتها مع المبلغ والعملة والعميل والتاريخ والوقت',
  },
  'and description.': {
    'en': 'and description.',
    'ps': 'او تفصیل یې هم لیدل کېږي.',
    'fa': 'و توضیحات آن‌ها نیز دیده می‌شود.',
    'ur': 'اور تفصیل بھی دیکھی جا سکتی ہے۔',
    'ar': 'والوصف.',
  },
  'Use Customers to create and manage customer accounts. Open a': {
    'en': 'Use Customers to create and manage customer accounts. Open a',
    'ps': 'د پېرودونکو برخه کې حسابونه جوړ او اداره کړئ. د پېرودونکي',
    'fa': 'در بخش مشتریان حساب‌ها را ایجاد و مدیریت کنید. پروفایل مشتری را',
    'ur': 'Customers میں گاہکوں کے اکاؤنٹ بنائیں اور سنبھالیں۔ گاہک کا',
    'ar': 'استخدم العملاء لإنشاء حسابات العملاء وإدارتها. افتح ملف العميل',
  },
  'customer profile to see their transaction history and': {
    'en': 'customer profile to see their transaction history and',
    'ps': 'پروفایل خلاص کړئ څو د معاملو تاریخچه او',
    'fa': 'باز کنید تا تاریخ معاملات و',
    'ur': 'پروفائل کھول کر لین دین کی تاریخ اور',
    'ar': 'لرؤية سجل معاملاته و',
  },
  'customer information and create customer transactions.': {
    'en': 'customer information and create customer transactions.',
    'ps': 'معلومات وګورئ او د هغه لپاره معاملې جوړې کړئ.',
    'fa': 'اطلاعات او را ببینید و معامله ایجاد کنید.',
    'ur': 'معلومات دیکھیں اور اس کے لیے لین دین بنائیں۔',
    'ar': 'معلوماته وإنشاء معاملات له.',
  },
  'Ghata tracks money customers owe you and money you owe them.': {
    'en': 'Ghata tracks money customers owe you and money you owe them.',
    'ps': 'ګهته هغه پیسې ثبتوي چې پېرودونکي یې تاسو ته پوروړي دي او هغه پیسې چې تاسو یې هغوی ته پوروړي یاست.',
    'fa': 'گهته پولی را که مشتریان به شما بدهکارند و پولی را که شما به آن‌ها بدهکارید پیگیری می‌کند.',
    'ur': 'گھتہ وہ رقم ٹریک کرتا ہے جو گاہک آپ کو یا آپ گاہکوں کو دینے والے ہیں۔',
    'ar': 'تتابع غاتا الأموال التي يدين بها العملاء لك والتي تدين بها لهم.',
  },
  'the accounting history available.': {
    'en': 'the accounting history available.',
    'ps': 'د حسابدارۍ تاریخچه خوندي پاتې کېږي.',
    'fa': 'سابقه حسابداری حفظ می‌شود.',
    'ur': 'اکاؤنٹنگ تاریخ محفوظ رہتی ہے۔',
    'ar': 'بسجل المحاسبة متاحاً.',
  },
  'Use Exchange for currency buy and sell operations. Select the': {
    'en': 'Use Exchange for currency buy and sell operations. Select the',
    'ps': 'Exchange د اسعارو د پېر او پلور لپاره وکاروئ. اړوند',
    'fa': 'از تبادله برای خرید و فروش ارز استفاده کنید. ارزهای',
    'ur': 'Exchange کو کرنسی خرید و فروخت کے لیے استعمال کریں۔',
    'ar': 'استخدم الصرافة لعمليات شراء وبيع العملات. اختر',
  },
  'From and To currencies, enter the amounts and exchange': {
    'en': 'From and To currencies, enter the amounts and exchange',
    'ps': 'له او تر اسعار وټاکئ، اندازې او د تبادلې',
    'fa': 'مبدأ و مقصد را انتخاب کرده، مبالغ و نرخ',
    'ur': 'From اور To کرنسیاں منتخب کرکے رقم اور ایکسچینج',
    'ar': 'عملتي المصدر والوجهة وأدخل المبالغ وسعر',
  },
  'rate, and optionally select a customer. Each currency': {
    'en': 'rate, and optionally select a customer. Each currency',
    'ps': 'نرخ ولیکئ او که وغواړئ پېرودونکی وټاکئ. هر اسعار',
    'fa': 'تبادله را وارد کنید و در صورت نیاز مشتری انتخاب کنید. هر ارز',
    'ur': 'ریٹ درج کریں اور چاہیں تو گاہک منتخب کریں۔ ہر کرنسی',
    'ar': 'الصرف، ويمكن اختيار عميل. كل عملة',
  },
  'remains independently recorded.': {
    'en': 'remains independently recorded.',
    'ps': 'په جلا ډول ثبت پاتې کېږي.',
    'fa': 'به‌صورت مستقل ثبت می‌ماند.',
    'ur': 'الگ ریکارڈ رہتی ہے۔',
    'ar': 'تبقى مسجلة بشكل مستقل.',
  },
  'Cashbox represents the recorded cash movement of the business.': {
    'en': 'Cashbox represents the recorded cash movement of the business.',
    'ps': 'صندوق د کاروبار ثبت شوي نغدي حرکتونه ښيي.',
    'fa': 'صندوق حرکت نقدی ثبت‌شده تجارت را نشان می‌دهد.',
    'ur': 'کیش باکس کاروبار کی ریکارڈ شدہ نقد حرکت دکھاتا ہے۔',
    'ar': 'يمثل الصندوق حركة النقد المسجلة للنشاط.',
  },
  'Reports summarize Money In, Money Out, exchanges and adjustments.': {
    'en': 'Reports summarize Money In, Money Out, exchanges and adjustments.',
    'ps': 'راپورونه داخلې او وتلې پیسې، تبادلې او سمونونه لنډیز کوي.',
    'fa': 'گزارش‌ها پول ورودی، خروجی، تبادلات و اصلاحات را خلاصه می‌کنند.',
    'ur': 'رپورٹس آمد رقم، خرج رقم، ایکسچینج اور ایڈجسٹمنٹ کا خلاصہ دیتے ہیں۔',
    'ar': 'تلخص التقارير الأموال الداخلة والخارجة والصرافة والتسويات.',
  },
  'Ghata can prepare transaction receipts, customer statements': {
    'en': 'Ghata can prepare transaction receipts, customer statements',
    'ps': 'ګهته د معاملو رسیدونه او د پېرودونکو حسابونه جوړولای شي',
    'fa': 'گهته می‌تواند رسید معاملات و صورت‌حساب مشتریان را آماده کند',
    'ur': 'گھتہ لین دین کی رسیدیں اور گاہک کے بیانات بنا سکتا ہے',
    'ar': 'يمكن لِغاتا إعداد إيصالات المعاملات وكشوف العملاء',
  },
  'A business owner can manage staff access. Staff permissions': {
    'en': 'A business owner can manage staff access. Staff permissions',
    'ps': 'د کاروبار مالک د کارکوونکو لاسرسی اداره کولای شي. د کارکوونکو اجازې',
    'fa': 'مالک تجارت می‌تواند دسترسی کارمندان را مدیریت کند. مجوزهای کارمندان',
    'ur': 'کاروبار کا مالک عملے کی رسائی سنبھال سکتا ہے۔ عملے کی اجازتیں',
    'ar': 'يمكن لمالك النشاط إدارة وصول الموظفين. تتحكم صلاحيات الموظفين',
  },
  'Use Security to protect access to Ghata with the available PIN': {
    'en': 'Use Security to protect access to Ghata with the available PIN',
    'ps': 'د امنیت برخه کې د موجود PIN په وسیله ګهته خوندي کړئ',
    'fa': 'با بخش امنیت و PIN موجود از دسترسی به گهته محافظت کنید',
    'ur': 'Security میں دستیاب PIN سے گھتہ کی رسائی محفوظ کریں',
    'ar': 'استخدم الأمان لحماية الوصول إلى غاتا باستخدام رمز PIN',
  },
  'security information private.': {
    'en': 'security information private.',
    'ps': 'امنیتي معلومات شخصي وساتئ.',
    'fa': 'اطلاعات امنیتی را خصوصی نگه دارید.',
    'ur': 'سیکیورٹی معلومات نجی رکھیں۔',
    'ar': 'حافظ على خصوصية معلومات الأمان.',
  },
  'Deleted accounting records are moved to the Recycle Bin.': {
    'en': 'Deleted accounting records are moved to the Recycle Bin.',
    'ps': 'حذف شوي حسابداري ریکارډونه حذف شوو توکو ته لېږدول کېږي.',
    'fa': 'رکوردهای حسابداری حذف‌شده به سطل بازیافت منتقل می‌شوند.',
    'ur': 'حذف شدہ اکاؤنٹنگ ریکارڈ ری سائیکل بن میں جاتے ہیں۔',
    'ar': 'تُنقل سجلات المحاسبة المحذوفة إلى سلة المحذوفات.',
  },
  'Enter financial information carefully and review balances and': {
    'en': 'Enter financial information carefully and review balances and',
    'ps': 'مالي معلومات په احتیاط ولیکئ او بیلانسونه او',
    'fa': 'اطلاعات مالی را با دقت وارد کرده و موجودی‌ها و',
    'ur': 'مالی معلومات احتیاط سے درج کریں اور بیلنس اور',
    'ar': 'أدخل المعلومات المالية بعناية وراجع الأرصدة و',
  },
  'accuracy of reports depends on the information entered.': {
    'en': 'accuracy of reports depends on the information entered.',
    'ps': 'د راپورونو دقت په داخل شوو معلوماتو پورې تړلی دی.',
    'fa': 'دقت گزارش‌ها به اطلاعات واردشده بستگی دارد.',
    'ur': 'رپورٹس کی درستگی درج معلومات پر منحصر ہے۔',
    'ar': 'دقة التقارير تعتمد على المعلومات المدخلة.',
  },

  'Incorrect PIN.': {
    'en': 'Incorrect PIN.',
    'ps': 'ناسم PIN.',
    'fa': 'PIN نادرست است.',
    'ur': 'غلط PIN۔',
    'ar': 'رمز PIN غير صحيح.',
  },
  'Staff disabled.': {
    'en': 'Staff disabled.',
    'ps': 'کارکوونکی غیر فعال شو.',
    'fa': 'کارمند غیرفعال شد.',
    'ur': 'عملہ غیر فعال ہوگیا۔',
    'ar': 'تم تعطيل الموظف.',
  },
  'App PIN removed.': {
    'en': 'App PIN removed.',
    'ps': 'د اپ PIN لرې شو.',
    'fa': 'PIN برنامه حذف شد.',
    'ur': 'ایپ PIN ہٹا دیا گیا۔',
    'ar': 'تمت إزالة رمز التطبيق.',
  },
  'PINs do not match.': {
    'en': 'PINs do not match.',
    'ps': 'PIN ګانې سره برابر نه دي.',
    'fa': 'PINها مطابقت ندارند.',
    'ur': 'PIN مماثل نہیں ہیں۔',
    'ar': 'رموز PIN غير متطابقة.',
  },
  'No balance yet.': {
    'en': 'No balance yet.',
    'ps': 'تر اوسه بیلانس نشته.',
    'fa': 'هنوز موجودی نیست.',
    'ur': 'ابھی کوئی بیلنس نہیں۔',
    'ar': 'لا يوجد رصيد بعد.',
  },
  'No cashbox history yet.': {
    'en': 'No cashbox history yet.',
    'ps': 'تر اوسه د صندوق تاریخچه نشته.',
    'fa': 'هنوز سابقه صندوق نیست.',
    'ur': 'ابھی کیش باکس کی تاریخ نہیں۔',
    'ar': 'لا يوجد سجل للصندوق بعد.',
  },
  'No exchange history yet.': {
    'en': 'No exchange history yet.',
    'ps': 'تر اوسه د تبادلې تاریخچه نشته.',
    'fa': 'هنوز سابقه تبادله نیست.',
    'ur': 'ابھی ایکسچینج کی تاریخ نہیں۔',
    'ar': 'لا يوجد سجل للصرافة بعد.',
  },
  'Cashbox balance is zero.': {
    'en': 'Cashbox balance is zero.',
    'ps': 'د صندوق بیلانس صفر دی.',
    'fa': 'موجودی صندوق صفر است.',
    'ur': 'کیش باکس بیلنس صفر ہے۔',
    'ar': 'رصيد الصندوق صفر.',
  },
  'Create an App PIN first.': {
    'en': 'Create an App PIN first.',
    'ps': 'لومړی د اپ PIN جوړ کړئ.',
    'fa': 'ابتدا PIN برنامه را ایجاد کنید.',
    'ur': 'پہلے ایپ PIN بنائیں۔',
    'ar': 'أنشئ رمز PIN للتطبيق أولاً.',
  },
  'Staff permissions saved.': {
    'en': 'Staff permissions saved.',
    'ps': 'د کارکوونکي اجازې خوندي شوې.',
    'fa': 'مجوزهای کارمند ذخیره شد.',
    'ur': 'عملے کی اجازتیں محفوظ ہوگئیں۔',
    'ar': 'تم حفظ صلاحيات الموظف.',
  },
  'Cash received / reason': {
    'en': 'Cash received / reason',
    'ps': 'ترلاسه شوې پیسې / دلیل',
    'fa': 'پول دریافت‌شده / دلیل',
    'ur': 'وصول شدہ رقم / وجہ',
    'ar': 'المبلغ المستلم / السبب',
  },
  'Cash given / reason': {
    'en': 'Cash given / reason',
    'ps': 'ورکړل شوې پیسې / دلیل',
    'fa': 'پول پرداخت‌شده / دلیل',
    'ur': 'دی گئی رقم / وجہ',
    'ar': 'المبلغ المدفوع / السبب',
  },
  'Please fill in all fields': {
    'en': 'Please fill in all fields',
    'ps': 'مهرباني وکړئ ټولې خانې ډکې کړئ',
    'fa': 'لطفاً همه بخش‌ها را پر کنید',
    'ur': 'براہ کرم تمام خانے پُر کریں',
    'ar': 'يرجى ملء جميع الحقول',
  },
  'Please complete all fields': {
    'en': 'Please complete all fields',
    'ps': 'مهرباني وکړئ ټولې خانې بشپړې کړئ',
    'fa': 'لطفاً همه بخش‌ها را تکمیل کنید',
    'ur': 'براہ کرم تمام خانے مکمل کریں',
    'ar': 'يرجى إكمال جميع الحقول',
  },
  'Customer name is required.': {
    'en': 'Customer name is required.',
    'ps': 'د پېرودونکي نوم اړین دی.',
    'fa': 'نام مشتری ضروری است.',
    'ur': 'گاہک کا نام ضروری ہے۔',
    'ar': 'اسم العميل مطلوب.',
  },
  'Enter a valid staff email.': {
    'en': 'Enter a valid staff email.',
    'ps': 'د کارکوونکي سم ایمیل ولیکئ.',
    'fa': 'ایمیل معتبر کارمند را وارد کنید.',
    'ur': 'عملے کا درست ای میل درج کریں۔',
    'ar': 'أدخل بريداً صحيحاً للموظف.',
  },
  'PIN must be 4 to 6 digits.': {
    'en': 'PIN must be 4 to 6 digits.',
    'ps': 'PIN باید له ۴ تر ۶ شمېرو وي.',
    'fa': 'PIN باید ۴ تا ۶ رقم باشد.',
    'ur': 'PIN 4 سے 6 ہندسوں کا ہونا چاہیے۔',
    'ar': 'يجب أن يتكون PIN من 4 إلى 6 أرقام.',
  },
  'Please enter a valid email': {
    'en': 'Please enter a valid email',
    'ps': 'مهرباني وکړئ سم ایمیل ولیکئ',
    'fa': 'لطفاً ایمیل معتبر وارد کنید',
    'ur': 'براہ کرم درست ای میل درج کریں',
    'ar': 'يرجى إدخال بريد إلكتروني صحيح',
  },
  'Backup created successfully.': {
    'en': 'Backup created successfully.',
    'ps': 'بیک اپ په بریالیتوب جوړ شو.',
    'fa': 'پشتیبان با موفقیت ایجاد شد.',
    'ur': 'بیک اپ کامیابی سے بن گیا۔',
    'ar': 'تم إنشاء النسخة الاحتياطية بنجاح.',
  },
  'Customer added successfully.': {
    'en': 'Customer added successfully.',
    'ps': 'پېرودونکی په بریالیتوب اضافه شو.',
    'fa': 'مشتری با موفقیت اضافه شد.',
    'ur': 'گاہک کامیابی سے شامل ہوگیا۔',
    'ar': 'تمت إضافة العميل بنجاح.',
  },
  'Exchange saved successfully.': {
    'en': 'Exchange saved successfully.',
    'ps': 'تبادله په بریالیتوب خوندي شوه.',
    'fa': 'تبادله با موفقیت ذخیره شد.',
    'ur': 'ایکسچینج کامیابی سے محفوظ ہوگیا۔',
    'ar': 'تم حفظ الصرافة بنجاح.',
  },
  'Ghata unlocked successfully.': {
    'en': 'Ghata unlocked successfully.',
    'ps': 'ګهته په بریالیتوب خلاص شو.',
    'fa': 'گهته با موفقیت باز شد.',
    'ur': 'گھتہ کامیابی سے کھل گیا۔',
    'ar': 'تم فتح غاتا بنجاح.',
  },
  'Please enter a valid amount.': {
    'en': 'Please enter a valid amount.',
    'ps': 'مهرباني وکړئ سمه اندازه ولیکئ.',
    'fa': 'لطفاً مبلغ معتبر وارد کنید.',
    'ur': 'براہ کرم درست رقم درج کریں۔',
    'ar': 'يرجى إدخال مبلغ صحيح.',
  },
  'Profile updated successfully': {
    'en': 'Profile updated successfully',
    'ps': 'پروفایل په بریالیتوب تازه شو',
    'fa': 'پروفایل با موفقیت به‌روزرسانی شد',
    'ur': 'پروفائل کامیابی سے اپڈیٹ ہوگیا',
    'ar': 'تم تحديث الملف بنجاح',
  },
  'Account created successfully.': {
    'en': 'Account created successfully.',
    'ps': 'حساب په بریالیتوب جوړ شو.',
    'fa': 'حساب با موفقیت ایجاد شد.',
    'ur': 'اکاؤنٹ کامیابی سے بن گیا۔',
    'ar': 'تم إنشاء الحساب بنجاح.',
  },
  'Please check exchange values.': {
    'en': 'Please check exchange values.',
    'ps': 'مهرباني وکړئ د تبادلې ارزښتونه وګورئ.',
    'fa': 'لطفاً مقادیر تبادله را بررسی کنید.',
    'ur': 'براہ کرم ایکسچینج کی قدریں چیک کریں۔',
    'ar': 'يرجى التحقق من قيم الصرافة.',
  },
  'Customer updated successfully.': {
    'en': 'Customer updated successfully.',
    'ps': 'پېرودونکی په بریالیتوب تازه شو.',
    'fa': 'مشتری با موفقیت به‌روزرسانی شد.',
    'ur': 'گاہک کامیابی سے اپڈیٹ ہوگیا۔',
    'ar': 'تم تحديث العميل بنجاح.',
  },
  'Exchange updated successfully.': {
    'en': 'Exchange updated successfully.',
    'ps': 'تبادله په بریالیتوب تازه شوه.',
    'fa': 'تبادله با موفقیت به‌روزرسانی شد.',
    'ur': 'ایکسچینج کامیابی سے اپڈیٹ ہوگیا۔',
    'ar': 'تم تحديث الصرافة بنجاح.',
  },
  'Password changed successfully.': {
    'en': 'Password changed successfully.',
    'ps': 'پاسورډ په بریالیتوب بدل شو.',
    'fa': 'رمز با موفقیت تغییر کرد.',
    'ur': 'پاس ورڈ کامیابی سے تبدیل ہوگیا۔',
    'ar': 'تم تغيير كلمة المرور بنجاح.',
  },
  'Customer restored successfully.': {
    'en': 'Customer restored successfully.',
    'ps': 'پېرودونکی په بریالیتوب بېرته راوګرځول شو.',
    'fa': 'مشتری با موفقیت بازیابی شد.',
    'ur': 'گاہک کامیابی سے بحال ہوگیا۔',
    'ar': 'تمت استعادة العميل بنجاح.',
  },
  'Exchange restored successfully.': {
    'en': 'Exchange restored successfully.',
    'ps': 'تبادله په بریالیتوب بېرته راوګرځول شوه.',
    'fa': 'تبادله با موفقیت بازیابی شد.',
    'ur': 'ایکسچینج کامیابی سے بحال ہوگیا۔',
    'ar': 'تمت استعادة الصرافة بنجاح.',
  },
  'Transaction saved successfully.': {
    'en': 'Transaction saved successfully.',
    'ps': 'معامله په بریالیتوب خوندي شوه.',
    'fa': 'معامله با موفقیت ذخیره شد.',
    'ur': 'لین دین کامیابی سے محفوظ ہوگیا۔',
    'ar': 'تم حفظ المعاملة بنجاح.',
  },
  'Transaction updated successfully.': {
    'en': 'Transaction updated successfully.',
    'ps': 'معامله په بریالیتوب تازه شوه.',
    'fa': 'معامله با موفقیت به‌روزرسانی شد.',
    'ur': 'لین دین کامیابی سے اپڈیٹ ہوگیا۔',
    'ar': 'تم تحديث المعاملة بنجاح.',
  },
  'Transaction restored successfully.': {
    'en': 'Transaction restored successfully.',
    'ps': 'معامله په بریالیتوب بېرته راوګرځول شوه.',
    'fa': 'معامله با موفقیت بازیابی شد.',
    'ur': 'لین دین کامیابی سے بحال ہوگیا۔',
    'ar': 'تمت استعادة المعاملة بنجاح.',
  },
  'Unable to create image.': {
    'en': 'Unable to create image.',
    'ps': 'انځور نه شي جوړېدای.',
    'fa': 'ایجاد تصویر ممکن نیست.',
    'ur': 'تصویر نہیں بن سکی۔',
    'ar': 'تعذر إنشاء الصورة.',
  },
  'Unable to login. Please try again.': {
    'en': 'Unable to login. Please try again.',
    'ps': 'ننوتل ممکن نه شول. بیا هڅه وکړئ.',
    'fa': 'ورود ممکن نشد. دوباره تلاش کنید.',
    'ur': 'لاگ اِن نہیں ہوسکا۔ دوبارہ کوشش کریں۔',
    'ar': 'تعذر تسجيل الدخول. حاول مرة أخرى.',
  },
  'Something went wrong. Please try again.': {
    'en': 'Something went wrong. Please try again.',
    'ps': 'ستونزه رامنځته شوه. بیا هڅه وکړئ.',
    'fa': 'مشکلی رخ داد. دوباره تلاش کنید.',
    'ur': 'کچھ غلط ہوگیا۔ دوبارہ کوشش کریں۔',
    'ar': 'حدث خطأ. حاول مرة أخرى.',
  },  'Unable to add customer': {
    'en': 'Unable to add customer',
    'ps': 'پېرودونکی نه شي اضافه کېدای',
    'fa': 'مشتری اضافه نمی‌شود',
    'ur': 'گاہک شامل نہیں کیا جا سکا',
    'ar': 'تعذرت إضافة العميل',
  },  'Unable to create PDF': {
    'en': 'Unable to create PDF',
    'ps': 'PDF نه شي جوړېدای',
    'fa': 'PDF ایجاد نمی‌شود',
    'ur': 'PDF نہیں بن سکی',
    'ar': 'تعذر إنشاء PDF',
  },  'Unable to create backup': {
    'en': 'Unable to create backup',
    'ps': 'بیک اپ نه شي جوړېدای',
    'fa': 'پشتیبان ایجاد نمی‌شود',
    'ur': 'بیک اپ نہیں بن سکا',
    'ar': 'تعذر إنشاء النسخة الاحتياطية',
  },  'Unable to create balance image': {
    'en': 'Unable to create balance image',
    'ps': 'د بیلانس انځور نه شي جوړېدای',
    'fa': 'تصویر موجودی ایجاد نمی‌شود',
    'ur': 'بیلنس تصویر نہیں بن سکی',
    'ar': 'تعذر إنشاء صورة الرصيد',
  },  'Unable to create statement PDF': {
    'en': 'Unable to create statement PDF',
    'ps': 'د حساب PDF نه شي جوړېدای',
    'fa': 'PDF صورت‌حساب ایجاد نمی‌شود',
    'ur': 'اسٹیٹمنٹ PDF نہیں بن سکی',
    'ar': 'تعذر إنشاء PDF لكشف الحساب',
  },  'Unable to delete customer': {
    'en': 'Unable to delete customer',
    'ps': 'پېرودونکی نه شي حذف کېدای',
    'fa': 'مشتری حذف نمی‌شود',
    'ur': 'گاہک حذف نہیں کیا جا سکا',
    'ar': 'تعذر حذف العميل',
  },  'Unable to delete transaction': {
    'en': 'Unable to delete transaction',
    'ps': 'معامله نه شي حذف کېدای',
    'fa': 'معامله حذف نمی‌شود',
    'ur': 'لین دین حذف نہیں کیا جا سکا',
    'ar': 'تعذر حذف المعاملة',
  },  'Unable to disable staff': {
    'en': 'Unable to disable staff',
    'ps': 'کارکوونکی نه شي غیر فعال کېدای',
    'fa': 'کارمند غیرفعال نمی‌شود',
    'ur': 'عملہ غیر فعال نہیں کیا جا سکا',
    'ar': 'تعذر تعطيل الموظف',
  },  'Unable to load Recycle Bin': {
    'en': 'Unable to load Recycle Bin',
    'ps': 'حذف شوي توکي نه شي پورته کېدای',
    'fa': 'سطل بازیافت بارگذاری نمی‌شود',
    'ur': 'ری سائیکل بن لوڈ نہیں ہوسکا',
    'ar': 'تعذر تحميل سلة المحذوفات',
  },  'Unable to load cashbox': {
    'en': 'Unable to load cashbox',
    'ps': 'صندوق نه شي پورته کېدای',
    'fa': 'صندوق بارگذاری نمی‌شود',
    'ur': 'کیش باکس لوڈ نہیں ہوسکا',
    'ar': 'تعذر تحميل الصندوق',
  },  'Unable to load customers': {
    'en': 'Unable to load customers',
    'ps': 'پېرودونکي نه شي پورته کېدای',
    'fa': 'مشتریان بارگذاری نمی‌شوند',
    'ur': 'گاہک لوڈ نہیں ہوسکے',
    'ar': 'تعذر تحميل العملاء',
  },  'Unable to load exchange history': {
    'en': 'Unable to load exchange history',
    'ps': 'د تبادلې تاریخچه نه شي پورته کېدای',
    'fa': 'سابقه تبادله بارگذاری نمی‌شود',
    'ur': 'ایکسچینج تاریخ لوڈ نہیں ہوسکی',
    'ar': 'تعذر تحميل سجل الصرافة',
  },  'Unable to load ledger': {
    'en': 'Unable to load ledger',
    'ps': 'حساب کتاب نه شي پورته کېدای',
    'fa': 'دفتر حساب بارگذاری نمی‌شود',
    'ur': 'لیجر لوڈ نہیں ہوسکا',
    'ar': 'تعذر تحميل دفتر الحساب',
    'en': 'Unable to load reports',
    'ps': 'راپورونه نه شي پورته کېدای',
    'fa': 'گزارش‌ها بارگذاری نمی‌شوند',
    'ur': 'رپورٹس لوڈ نہیں ہوسکیں',
    'ar': 'تعذر تحميل التقارير',
  },  'Unable to load staff': {
    'en': 'Unable to load staff',
    'ps': 'کارکوونکي نه شي پورته کېدای',
    'fa': 'کارمندان بارگذاری نمی‌شوند',
    'ur': 'عملہ لوڈ نہیں ہوسکا',
    'ar': 'تعذر تحميل الموظفين',
  },  'Unable to load transactions': {
    'en': 'Unable to load transactions',
    'ps': 'معاملې نه شي پورته کېدای',
    'fa': 'معاملات بارگذاری نمی‌شوند',
    'ur': 'لین دین لوڈ نہیں ہوسکے',
    'ar': 'تعذر تحميل المعاملات',
  },  'Unable to move exchange to Recycle Bin': {
    'en': 'Unable to move exchange to Recycle Bin',
    'ps': 'تبادله حذف شوو ته نه شي لېږدول کېدای',
    'fa': 'تبادله به سطل بازیافت منتقل نمی‌شود',
    'ur': 'ایکسچینج ری سائیکل بن میں منتقل نہیں ہوسکا',
    'ar': 'تعذر نقل الصرافة إلى سلة المحذوفات',
  },  'Unable to permanently delete customer': {
    'en': 'Unable to permanently delete customer',
    'ps': 'پېرودونکی دایمي نه شي حذف کېدای',
    'fa': 'مشتری به‌طور دائمی حذف نمی‌شود',
    'ur': 'گاہک مستقل حذف نہیں ہوسکا',
    'ar': 'تعذر حذف العميل نهائياً',
  },  'Unable to permanently delete exchange': {
    'en': 'Unable to permanently delete exchange',
    'ps': 'تبادله دایمي نه شي حذف کېدای',
    'fa': 'تبادله به‌طور دائمی حذف نمی‌شود',
    'ur': 'ایکسچینج مستقل حذف نہیں ہوسکا',
    'ar': 'تعذر حذف الصرافة نهائياً',
  },  'Unable to permanently delete transaction': {
    'en': 'Unable to permanently delete transaction',
    'ps': 'معامله دایمي نه شي حذف کېدای',
    'fa': 'معامله به‌طور دائمی حذف نمی‌شود',
    'ur': 'لین دین مستقل حذف نہیں ہوسکا',
    'ar': 'تعذر حذف المعاملة نهائياً',
  },  'Unable to restore customer': {
    'en': 'Unable to restore customer',
    'ps': 'پېرودونکی بېرته نه شي راوګرځول کېدای',
    'fa': 'مشتری بازیابی نمی‌شود',
    'ur': 'گاہک بحال نہیں ہوسکا',
    'ar': 'تعذر استعادة العميل',
  },  'Unable to restore exchange': {
    'en': 'Unable to restore exchange',
    'ps': 'تبادله بېرته نه شي راوګرځول کېدای',
    'fa': 'تبادله بازیابی نمی‌شود',
    'ur': 'ایکسچینج بحال نہیں ہوسکا',
    'ar': 'تعذر استعادة الصرافة',
  },  'Unable to restore transaction': {
    'en': 'Unable to restore transaction',
    'ps': 'معامله بېرته نه شي راوګرځول کېدای',
    'fa': 'معامله بازیابی نمی‌شود',
    'ur': 'لین دین بحال نہیں ہوسکا',
    'ar': 'تعذر استعادة المعاملة',
  },  'Unable to save exchange': {
    'en': 'Unable to save exchange',
    'ps': 'تبادله نه شي خوندي کېدای',
    'fa': 'تبادله ذخیره نمی‌شود',
    'ur': 'ایکسچینج محفوظ نہیں ہوسکا',
    'ar': 'تعذر حفظ الصرافة',
  },  'Unable to save staff': {
    'en': 'Unable to save staff',
    'ps': 'کارکوونکی نه شي خوندي کېدای',
    'fa': 'کارمند ذخیره نمی‌شود',
    'ur': 'عملہ محفوظ نہیں ہوسکا',
    'ar': 'تعذر حفظ الموظف',
  },  'Unable to save transaction': {
    'en': 'Unable to save transaction',
    'ps': 'معامله نه شي خوندي کېدای',
    'fa': 'معامله ذخیره نمی‌شود',
    'ur': 'لین دین محفوظ نہیں ہوسکا',
    'ar': 'تعذر حفظ المعاملة',
  },  'Unable to update customer': {
    'en': 'Unable to update customer',
    'ps': 'پېرودونکی نه شي تازه کېدای',
    'fa': 'مشتری به‌روزرسانی نمی‌شود',
    'ur': 'گاہک اپڈیٹ نہیں ہوسکا',
    'ar': 'تعذر تحديث العميل',
  },  'Unable to update exchange': {
    'en': 'Unable to update exchange',
    'ps': 'تبادله نه شي تازه کېدای',
    'fa': 'تبادله به‌روزرسانی نمی‌شود',
    'ur': 'ایکسچینج اپڈیٹ نہیں ہوسکا',
    'ar': 'تعذر تحديث الصرافة',
  },  'Unable to update transaction': {
    'en': 'Unable to update transaction',
    'ps': 'معامله نه شي تازه کېدای',
    'fa': 'معامله به‌روزرسانی نمی‌شود',
    'ur': 'لین دین اپڈیٹ نہیں ہوسکا',
    'ar': 'تعذر تحديث المعاملة',
  },  'whether reports are available to them.': {
    'en': 'whether reports are available to them.',
    'ps': 'او دا چې راپورونو ته لاسرسی ولري که نه.',
    'fa': 'و اینکه آیا به گزارش‌ها دسترسی داشته باشند یا خیر.',
    'ur': 'اور آیا انہیں رپورٹس تک رسائی ہو یا نہیں۔',
    'ar': 'وما إذا كانت التقارير متاحة لهم.',
  },  'supported transaction and exchange movements.': {
    'en': 'supported transaction and exchange movements.',
    'ps': 'د ملاتړ شوو معاملو او تبادلو حرکتونه.',
    'fa': 'حرکت‌های پشتیبانی‌شده معاملات و تبادلات.',
    'ur': 'معاون لین دین اور ایکسچینج حرکات۔',
    'ar': 'حركات المعاملات والصرافة المدعومة.',
  },  'automatically converted into another currency.': {
    'en': 'automatically converted into another currency.',
    'ps': 'په اوتومات ډول بل اسعار ته نه اړول کېږي.',
    'fa': 'به‌صورت خودکار به ارز دیگری تبدیل نمی‌شود.',
    'ur': 'خودکار طور پر دوسری کرنسی میں تبدیل نہیں ہوتا۔',
    'ar': 'لا يتم تحويلها تلقائياً إلى عملة أخرى.',
  },  'Keep backup files in a safe place such as your': {
    'en': 'Keep backup files in a safe place such as your',
    'ps': 'د بیک اپ فایلونه په خوندي ځای کې وساتئ لکه ستاسو',
    'fa': 'فایل‌های پشتیبان را در جای امن نگه دارید مانند',
    'ur': 'بیک اپ فائلیں کسی محفوظ جگہ رکھیں جیسے آپ کی',
    'ar': 'احتفظ بملفات النسخ الاحتياطية في مكان آمن مثل',
  },  'private cloud storage or another trusted device.': {
    'en': 'private cloud storage or another trusted device.',
    'ps': 'شخصي کلاوډ یا بل باوري وسیله.',
    'fa': 'فضای ابری خصوصی یا دستگاه قابل اعتماد دیگر.',
    'ur': 'نجی کلاؤڈ اسٹوریج یا کوئی دوسرا قابل اعتماد آلہ۔',
    'ar': 'التخزين السحابي الخاص أو جهاز موثوق آخر.',
  },  'silently destroying important financial records.': {
    'en': 'silently destroying important financial records.',
    'ps': 'مهم مالي ریکارډونه په پټه نه له منځه وړي.',
    'fa': 'سوابق مهم مالی را بدون اطلاع از بین نمی‌برد.',
    'ur': 'اہم مالی ریکارڈ خاموشی سے ضائع نہیں کرتا۔',
    'ar': 'بدلاً من حذف السجلات المالية المهمة دون تنبيه.',
  },  'information before sending a document to another person.': {
    'en': 'information before sending a document to another person.',
    'ps': 'معلومات مخکې له دې وګورئ چې سند بل چا ته ولېږئ.',
    'fa': 'اطلاعات را پیش از ارسال سند به شخص دیگر بررسی کنید.',
    'ur': 'دستاویز کسی دوسرے کو بھیجنے سے پہلے معلومات چیک کریں۔',
    'ar': 'راجع المعلومات قبل إرسال المستند إلى شخص آخر.',
  },  'information. Keep exported backup files in a safe place.': {
    'en': 'information. Keep exported backup files in a safe place.',
    'ps': 'معلومات. صادر شوي بیک اپ فایلونه په خوندي ځای کې وساتئ.',
    'fa': 'اطلاعات. فایل‌های پشتیبان صادرشده را در جای امن نگه دارید.',
    'ur': 'معلومات۔ ایکسپورٹ شدہ بیک اپ فائلیں محفوظ جگہ رکھیں۔',
    'ar': 'المعلومات. احتفظ بملفات النسخ الاحتياطية المصدرة في مكان آمن.',
  },

  'Log Out Other Devices': {
    'en': 'Log Out Other Devices',
    'ps': 'له نورو وسیلو څخه وتل',
    'fa': 'خروج از دستگاه‌های دیگر',
    'ur': 'دیگر ڈیوائسز سے لاگ آؤٹ',
    'ar': 'تسجيل الخروج من الأجهزة الأخرى',
  },
  'This will sign out your account from all other devices. This device will stay signed in.': {
    'en': 'This will sign out your account from all other devices. This device will stay signed in.',
    'ps': 'ستاسو حساب به له ټولو نورو وسیلو څخه ووځي. دا وسیله به لاګ اِن پاتې شي.',
    'fa': 'حساب شما از تمام دستگاه‌های دیگر خارج می‌شود. این دستگاه وارد حساب باقی می‌ماند.',
    'ur': 'آپ کا اکاؤنٹ تمام دیگر ڈیوائسز سے لاگ آؤٹ ہو جائے گا۔ یہ ڈیوائس لاگ اِن رہے گی۔',
    'ar': 'سيتم تسجيل خروج حسابك من جميع الأجهزة الأخرى. سيبقى هذا الجهاز مسجلاً للدخول.',
  },
  'Other devices have been logged out successfully.': {
    'en': 'Other devices have been logged out successfully.',
    'ps': 'له نورو وسیلو څخه په بریالیتوب سره ووتل.',
    'fa': 'خروج از دستگاه‌های دیگر با موفقیت انجام شد.',
    'ur': 'دیگر ڈیوائسز سے کامیابی کے ساتھ لاگ آؤٹ ہو گیا۔',
    'ar': 'تم تسجيل الخروج من الأجهزة الأخرى بنجاح.',
  },
  'Unable to log out other devices. Check your internet connection.': {
    'en': 'Unable to log out other devices. Check your internet connection.',
    'ps': 'له نورو وسیلو څخه وتل ممکن نه شول. خپل انټرنېټ اتصال وګورئ.',
    'fa': 'خروج از دستگاه‌های دیگر ممکن نشد. اتصال اینترنت خود را بررسی کنید.',
    'ur': 'دیگر ڈیوائسز سے لاگ آؤٹ نہیں ہو سکا۔ اپنا انٹرنیٹ کنکشن چیک کریں۔',
    'ar': 'تعذر تسجيل الخروج من الأجهزة الأخرى. تحقق من اتصالك بالإنترنت.',
  },
  'Sign out your account from all other phones and devices.': {
    'en': 'Sign out your account from all other phones and devices.',
    'ps': 'خپل حساب له ټولو نورو موبایلونو او وسیلو څخه وباسئ.',
    'fa': 'حساب خود را از تمام تلفن‌ها و دستگاه‌های دیگر خارج کنید.',
    'ur': 'اپنے اکاؤنٹ کو تمام دیگر فونز اور ڈیوائسز سے لاگ آؤٹ کریں۔',
    'ar': 'سجّل خروج حسابك من جميع الهواتف والأجهزة الأخرى.',
  },

  'Active Devices': {
    'en': 'Active Devices',
    'ps': 'فعالې وسیلې',
    'fa': 'دستگاه‌های فعال',
    'ur': 'فعال ڈیوائسز',
    'ar': 'الأجهزة النشطة',
  },
  'This device': {
    'en': 'This device',
    'ps': 'همدا وسیله',
    'fa': 'این دستگاه',
    'ur': 'یہ ڈیوائس',
    'ar': 'هذا الجهاز',
  },
  'Logged out': {
    'en': 'Logged out',
    'ps': 'وتل شوی',
    'fa': 'خارج شده',
    'ur': 'لاگ آؤٹ',
    'ar': 'تم تسجيل الخروج',
  },
  'Last seen': {
    'en': 'Last seen',
    'ps': 'وروستی فعالیت',
    'fa': 'آخرین فعالیت',
    'ur': 'آخری سرگرمی',
    'ar': 'آخر نشاط',
  },
  'Log out device': {
    'en': 'Log out device',
    'ps': 'وسیله وباسئ',
    'fa': 'خروج دستگاه',
    'ur': 'ڈیوائس لاگ آؤٹ کریں',
    'ar': 'تسجيل خروج الجهاز',
  },
  'View signed-in devices and log out a specific device.': {
    'en': 'View signed-in devices and log out a specific device.',
    'ps': 'لاګین شوې وسیلې وګورئ او ټاکلې وسیله وباسئ.',
    'fa': 'دستگاه‌های واردشده را ببینید و یک دستگاه مشخص را خارج کنید.',
    'ur': 'لاگ اِن ڈیوائسز دیکھیں اور کسی مخصوص ڈیوائس کو لاگ آؤٹ کریں۔',
    'ar': 'اعرض الأجهزة المسجّل دخولها وسجّل خروج جهاز محدد.',
  },
  'Filter': {
    'en': 'Filter',
    'ps': 'فلټر',
    'fa': 'فیلتر',
    'ur': 'فلٹر',
    'ar': 'تصفية',
  },
  'Adjustments': {
    'en': 'Adjustments',
    'ps': 'سمونونه',
    'fa': 'تعدیلات',
    'ur': 'ایڈجسٹمنٹس',
    'ar': 'التعديلات',
  },
  'Change Photo': {
    'en': 'Change Photo',
    'ps': 'عکس بدل کړئ',
    'fa': 'تغییر عکس',
    'ur': 'تصویر تبدیل کریں',
    'ar': 'تغيير الصورة',
  },
  'Remove Photo': {
    'en': 'Remove Photo',
    'ps': 'عکس لرې کړئ',
    'fa': 'حذف عکس',
    'ur': 'تصویر ہٹائیں',
    'ar': 'إزالة الصورة',
  },
  'Profile Photo': {
    'en': 'Profile Photo',
    'ps': 'د پروفایل عکس',
    'fa': 'عکس پروفایل',
    'ur': 'پروفائل تصویر',
    'ar': 'صورة الملف الشخصي',
  },
  'Everything is synced': {'en':'Everything is synced','ps':'ټول معلومات همغږي دي','fa':'همه اطلاعات همگام است','ur':'تمام معلومات ہم آہنگ ہیں','ar':'تمت مزامنة جميع البيانات'},
  'Log Out Device': {'en':'Log Out Device','ps':'وسیله وباسئ','fa':'خروج دستگاه','ur':'ڈیوائس لاگ آؤٹ کریں','ar':'تسجيل خروج الجهاز'},
  'Sync Problem': {
    'en': 'Sync Problem',
    'ps': 'د همغږۍ ستونزه',
    'fa': 'مشکل همگام‌سازی',
    'ur': 'سنک کا مسئلہ',
    'ar': 'مشكلة المزامنة',
  },
  'Sync Status': {
    'en': 'Sync Status',
    'ps': 'د همغږۍ حالت',
    'fa': 'وضعیت همگام‌سازی',
    'ur': 'سنک کی حالت',
    'ar': 'حالة المزامنة',
  },
  'Offline Sync Queue': {
    'en': 'Offline Sync Queue',
    'ps': 'د افلاین همغږۍ کتار',
    'fa': 'صف همگام‌سازی آفلاین',
    'ur': 'آف لائن سنک قطار',
    'ar': 'قائمة انتظار المزامنة دون اتصال',
  },
  'Pending': {
    'en': 'Pending',
    'ps': 'پاتې',
    'fa': 'در انتظار',
    'ur': 'زیر التوا',
    'ar': 'قيد الانتظار',
  },
  'Attempted': {
    'en': 'Attempted',
    'ps': 'هڅه شوي',
    'fa': 'تلاش‌شده',
    'ur': 'کوشش شدہ',
    'ar': 'تمت المحاولة',
  },
  'Failed': {
    'en': 'Failed',
    'ps': 'ناکام',
    'fa': 'ناموفق',
    'ur': 'ناکام',
    'ar': 'فشل',
  },
  'First Sync Problem': {
    'en': 'First Sync Problem',
    'ps': 'د همغږۍ لومړۍ ستونزه',
    'fa': 'اولین مشکل همگام‌سازی',
    'ur': 'پہلا سنک مسئلہ',
    'ar': 'أول مشكلة مزامنة',
  },
  'Operation': {
    'en': 'Operation',
    'ps': 'عملیات',
    'fa': 'عملیات',
    'ur': 'عمل',
    'ar': 'العملية',
  },
  'Table': {
    'en': 'Table',
    'ps': 'جدول',
    'fa': 'جدول',
    'ur': 'ٹیبل',
    'ar': 'الجدول',
  },
  'Record ID': {
    'en': 'Record ID',
    'ps': 'د ریکارډ پېژند',
    'fa': 'شناسه رکورد',
    'ur': 'ریکارڈ آئی ڈی',
    'ar': 'معرّف السجل',
  },
  'Attempts': {
    'en': 'Attempts',
    'ps': 'هڅې',
    'fa': 'تلاش‌ها',
    'ur': 'کوششیں',
    'ar': 'المحاولات',
  },
  'Error': {
    'en': 'Error',
    'ps': 'تېروتنه',
    'fa': 'خطا',
    'ur': 'خرابی',
    'ar': 'خطأ',
  },
  'Unknown error': {
    'en': 'Unknown error',
    'ps': 'نامعلومه تېروتنه',
    'fa': 'خطای ناشناخته',
    'ur': 'نامعلوم خرابی',
    'ar': 'خطأ غير معروف',
  },
  'No failed sync operation found': {
    'en': 'No failed sync operation found',
    'ps': 'د همغږۍ کوم ناکام عملیات ونه موندل شول',
    'fa': 'هیچ عملیات ناموفق همگام‌سازی یافت نشد',
    'ur': 'کوئی ناکام سنک عمل نہیں ملا',
    'ar': 'لم يتم العثور على عملية مزامنة فاشلة',
  },
  'This screen is read-only and does not change your data.': {
    'en': 'This screen is read-only and does not change your data.',
    'ps': 'دا سکرین یوازې د کتلو لپاره دی او ستاسو معلومات نه بدلوي.',
    'fa': 'این صفحه فقط برای مشاهده است و اطلاعات شما را تغییر نمی‌دهد.',
    'ur': 'یہ اسکرین صرف دیکھنے کے لیے ہے اور آپ کا ڈیٹا تبدیل نہیں کرتی۔',
    'ar': 'هذه الشاشة للقراءة فقط ولا تغيّر بياناتك.',
  },
  'Diagnostics error': {
    'en': 'Diagnostics error',
    'ps': 'د تشخیص تېروتنه',
    'fa': 'خطای تشخیص',
    'ur': 'تشخیصی خرابی',
    'ar': 'خطأ التشخيص',
  },
  'Check pending or failed data synchronization.': {
    'en': 'Check pending or failed data synchronization.',
    'ps': 'پاتې یا ناکامه د معلوماتو همغږي وګورئ.',
    'fa': 'همگام‌سازی در انتظار یا ناموفق اطلاعات را بررسی کنید.',
    'ur': 'زیر التوا یا ناکام ڈیٹا سنک چیک کریں۔',
    'ar': 'تحقق من مزامنة البيانات المعلقة أو الفاشلة.',
  },
  'Log Out': {'en':'Log Out','ps':'وتل','fa':'خروج','ur':'لاگ آؤٹ','ar':'تسجيل الخروج'},
  'Active now': {
    'en': 'Active now',
    'ps': 'اوس فعال',
    'fa': 'اکنون فعال',
    'ur': 'ابھی فعال',
    'ar': 'نشط الآن',
  },
  'Android Device': {
    'en': 'Android Device',
    'ps': 'انډرایډ وسیله',
    'fa': 'دستگاه اندروید',
    'ur': 'اینڈرائیڈ ڈیوائس',
    'ar': 'جهاز أندرويد',
  },
  'View devices signed in to your Ghata account.': {
    'en': 'View devices signed in to your Ghata account.',
    'ps': 'هغه وسایل وګورئ چې ستاسو د ګهته حساب ته ننوتلي دي.',
    'fa': 'دستگاه‌های واردشده به حساب غته خود را مشاهده کنید.',
    'ur': 'اپنے غتہ اکاؤنٹ میں سائن اِن ڈیوائسز دیکھیں۔',
    'ar': 'اعرض الأجهزة المسجّل دخولها إلى حساب غتة الخاص بك.',
  },

  'Unknown': {
    'en': 'Unknown',
    'ps': 'نامعلوم',
    'fa': 'نامعلوم',
    'ur': 'نامعلوم',
    'ar': 'غير معروف',
  },
  'min ago': {
    'en': 'min ago',
    'ps': 'دقیقې مخکې',
    'fa': 'دقیقه پیش',
    'ur': 'منٹ پہلے',
    'ar': 'دقيقة مضت',
  },
  'h ago': {
    'en': 'h ago',
    'ps': 'ساعته مخکې',
    'fa': 'ساعت پیش',
    'ur': 'گھنٹے پہلے',
    'ar': 'ساعة مضت',
  },
  'd ago': {
    'en': 'd ago',
    'ps': 'ورځې مخکې',
    'fa': 'روز پیش',
    'ur': 'دن پہلے',
    'ar': 'يوم مضى',
  },
  'Log out device confirmation': {
    'en': 'Log out this device from your Ghata account?',
    'ps': 'دا وسیله له خپل ګهته حساب څخه وباسئ؟',
    'fa': 'این دستگاه از حساب غته شما خارج شود؟',
    'ur': 'اس ڈیوائس کو اپنے غتہ اکاؤنٹ سے لاگ آؤٹ کریں؟',
    'ar': 'تسجيل خروج هذا الجهاز من حساب غتة الخاص بك؟',
  },
  'Device logged out successfully.': {
    'en': 'Device logged out successfully.',
    'ps': 'وسیله په بریالیتوب سره ووتله.',
    'fa': 'دستگاه با موفقیت خارج شد.',
    'ur': 'ڈیوائس کامیابی سے لاگ آؤٹ ہو گئی۔',
    'ar': 'تم تسجيل خروج الجهاز بنجاح.',
  },
  'Unable to load active devices': {
    'en': 'Unable to load active devices',
    'ps': 'د فعالو وسیلو پورته کول ممکن نه شول',
    'fa': 'بارگذاری دستگاه‌های فعال ممکن نشد',
    'ur': 'فعال ڈیوائسز لوڈ نہیں ہو سکیں',
    'ar': 'تعذر تحميل الأجهزة النشطة',
  },
  'Unable to log out device': {
    'en': 'Unable to log out device',
    'ps': 'له وسیلې څخه وتل ممکن نه شول',
    'fa': 'خروج دستگاه ممکن نشد',
    'ur': 'ڈیوائس لاگ آؤٹ نہیں ہو سکی',
    'ar': 'تعذر تسجيل خروج الجهاز',
  },

  'Restore failed': {
    'en': 'Restore failed',
    'ps': 'بیا راګرځول ناکام شول',
    'fa': 'بازیابی ناموفق بود',
    'ur': 'بحالی ناکام ہو گئی',
    'ar': 'فشلت الاستعادة',
  },
  'Unable to open email app.': {
    'en': 'Unable to open email app.',
    'ps': 'د ایمیل اپ خلاصول ممکن نه شول.',
    'fa': 'باز کردن برنامه ایمیل ممکن نشد.',
    'ur': 'ای میل ایپ نہیں کھل سکی۔',
    'ar': 'تعذر فتح تطبيق البريد الإلكتروني.',
  },
  'Unable to open WhatsApp.': {
    'en': 'Unable to open WhatsApp.',
    'ps': 'د WhatsApp خلاصول ممکن نه شول.',
    'fa': 'باز کردن WhatsApp ممکن نشد.',
    'ur': 'WhatsApp نہیں کھل سکا۔',
    'ar': 'تعذر فتح WhatsApp.',
  },
  'No journal records to print.': {
    'en': 'No journal records to print.',
    'ps': 'د چاپ لپاره د ورځپاڼې ریکارډونه نشته.',
    'fa': 'هیچ رکورد روزنامه‌ای برای چاپ وجود ندارد.',
    'ur': 'پرنٹ کرنے کے لیے کوئی روزنامچہ ریکارڈ نہیں ہے۔',
    'ar': 'لا توجد سجلات يومية للطباعة.',
  },
  'Unable to print Daily Journal': {
    'en': 'Unable to print Daily Journal',
    'ps': 'د ورځپاڼې چاپ ممکن نه شو',
    'fa': 'چاپ روزنامه ممکن نشد',
    'ur': 'روزنامچہ پرنٹ نہیں ہو سکا',
    'ar': 'تعذرت طباعة اليومية',
  },
  'Print Full Journal': {
    'en': 'Print Full Journal',
    'ps': 'بشپړه ورځپاڼه چاپ کړئ',
    'fa': 'چاپ کامل روزنامه',
    'ur': 'مکمل روزنامچہ پرنٹ کریں',
    'ar': 'طباعة اليومية كاملة',
  },
  'Print Statement': {
    'en': 'Print Statement',
    'ps': 'حساب پاڼه چاپ کړئ',
    'fa': 'چاپ صورت‌حساب',
    'ur': 'اسٹیٹمنٹ پرنٹ کریں',
    'ar': 'طباعة كشف الحساب',
  },
  'WhatsApp': {
    'en': 'WhatsApp',
    'ps': 'WhatsApp',
    'fa': 'WhatsApp',
    'ur': 'WhatsApp',
    'ar': 'WhatsApp',
  },


  'Account and data protection': {
      'en': 'Account and data protection',
      'ps': 'د حساب او معلوماتو ساتنه',
      'fa': 'محافظت از حساب و اطلاعات',
      'ur': 'اکاؤنٹ اور ڈیٹا کا تحفظ',
      'ar': 'حماية الحساب والبيانات',
    },

  'App Information': {
      'en': 'App Information',
      'ps': 'د اپلېکېشن معلومات',
      'fa': 'اطلاعات برنامه',
      'ur': 'ایپ کی معلومات',
      'ar': 'معلومات التطبيق',
    },

  'Contact Us': {
      'en': 'Contact Us',
      'ps': 'اړیکه ونیسئ',
      'fa': 'تماس با ما',
      'ur': 'ہم سے رابطہ کریں',
      'ar': 'اتصل بنا',
    },

  'Data Security': {
      'en': 'Data Security',
      'ps': 'د معلوماتو امنیت',
      'fa': 'امنیت اطلاعات',
      'ur': 'ڈیٹا سیکیورٹی',
      'ar': 'أمان البيانات',
    },

  'Data Storage': {
      'en': 'Data Storage',
      'ps': 'د معلوماتو زېرمه',
      'fa': 'ذخیره‌سازی اطلاعات',
      'ur': 'ڈیٹا اسٹوریج',
      'ar': 'تخزين البيانات',
    },

  'Email Support': {
      'en': 'Email Support',
      'ps': 'د ایمیل ملاتړ',
      'fa': 'پشتیبانی ایمیل',
      'ur': 'ای میل سپورٹ',
      'ar': 'دعم البريد الإلكتروني',
    },

  'FAQ': {
      'en': 'FAQ',
      'ps': 'عامې پوښتنې',
      'fa': 'پرسش‌های متداول',
      'ur': 'عمومی سوالات',
      'ar': 'الأسئلة الشائعة',
    },

  'Frequently asked questions': {
      'en': 'Frequently asked questions',
      'ps': 'ډېرې پوښتل کېدونکې پوښتنې',
      'fa': 'پرسش‌های متداول',
      'ur': 'اکثر پوچھے جانے والے سوالات',
      'ar': 'الأسئلة المتكررة',
    },

  'How Ghata handles your information': {
      'en': 'How Ghata handles your information',
      'ps': 'ګهته ستاسو معلومات څنګه اداره کوي',
      'fa': 'گَهته چگونه اطلاعات شما را مدیریت می‌کند',
      'ur': 'گھتہ آپ کی معلومات کو کیسے سنبھالتا ہے',
      'ar': 'كيفية تعامل غاتا مع معلوماتك',
    },

  'How to Use Ghata': {
      'en': 'How to Use Ghata',
      'ps': 'د ګهته د کارولو لارښود',
      'fa': 'راهنمای استفاده از گَهته',
      'ur': 'گھتہ استعمال کرنے کا طریقہ',
      'ar': 'كيفية استخدام غاتا',
    },

  'Learn more about Ghata': {
      'en': 'Learn more about Ghata',
      'ps': 'د ګهته په اړه نور معلومات',
      'fa': 'درباره گَهته بیشتر بدانید',
      'ur': 'گھتہ کے بارے میں مزید جانیں',
      'ar': 'تعرّف أكثر على غاتا',
    },

  'Learn the main Ghata features': {
      'en': 'Learn the main Ghata features',
      'ps': 'د ګهته اصلي ځانګړنې وپېژنئ',
      'fa': 'با قابلیت‌های اصلی گَهته آشنا شوید',
      'ur': 'گھتہ کی اہم خصوصیات جانیں',
      'ar': 'تعرّف على ميزات غاتا الرئيسية',
    },

  'Privacy': {
      'en': 'Privacy',
      'ps': 'محرمیت',
      'fa': 'حریم خصوصی',
      'ur': 'رازداری',
      'ar': 'الخصوصية',
    },

  'Privacy Policy': {
      'en': 'Privacy Policy',
      'ps': 'د محرمیت تګلاره',
      'fa': 'سیاست حریم خصوصی',
      'ur': 'رازداری کی پالیسی',
      'ar': 'سياسة الخصوصية',
    },

  'Rules for using Ghata': {
      'en': 'Rules for using Ghata',
      'ps': 'د ګهته د کارولو اصول',
      'fa': 'قوانین استفاده از گَهته',
      'ur': 'گھتہ استعمال کرنے کے اصول',
      'ar': 'قواعد استخدام غاتا',
    },

  'Simple Accounting for a Better Tomorrow': {
      'en': 'Simple Accounting for a Better Tomorrow',
      'ps': 'د غوره سبا لپاره ساده حسابداري',
      'fa': 'حسابداری ساده برای فردایی بهتر',
      'ur': 'بہتر کل کے لیے آسان اکاؤنٹنگ',
      'ar': 'محاسبة بسيطة لغد أفضل',
    },

  'Terms of Use': {
      'en': 'Terms of Use',
      'ps': 'د کارولو شرایط',
      'fa': 'شرایط استفاده',
      'ur': 'استعمال کی شرائط',
      'ar': 'شروط الاستخدام',
    },

  'Thank you for using Ghata!': {
      'en': 'Thank you for using Ghata!',
      'ps': 'د ګهته د کارولو مننه!',
      'fa': 'از استفاده از گَهته سپاسگزاریم!',
      'ur': 'گھتہ استعمال کرنے کا شکریہ!',
      'ar': 'شكرًا لاستخدام غاتا!',
    },

  'Version': {
      'en': 'Version',
      'ps': 'نسخه',
      'fa': 'نسخه',
      'ur': 'ورژن',
      'ar': 'الإصدار',
    },

  'WhatsApp Support': {
      'en': 'WhatsApp Support',
      'ps': 'د واټساپ ملاتړ',
      'fa': 'پشتیبانی واتساپ',
      'ur': 'واٹس ایپ سپورٹ',
      'ar': 'دعم واتساب',
    },

  'Where Ghata data is stored': {
      'en': 'Where Ghata data is stored',
      'ps': 'د ګهته معلومات چېرته ساتل کېږي',
      'fa': 'اطلاعات گَهته کجا ذخیره می‌شود',
      'ur': 'گھتہ کا ڈیٹا کہاں محفوظ ہوتا ہے',
      'ar': 'مكان تخزين بيانات غاتا',
    },

  'Apply': {'en':'Apply','ps':'تطبیق','fa':'اعمال','ur':'لاگو کریں','ar':'تطبيق'},

  'Camera': {'en':'Camera','ps':'کمره','fa':'دوربین','ur':'کیمرہ','ar':'الكاميرا'},

  'Clear': {'en':'Clear','ps':'پاکول','fa':'پاک کردن','ur':'صاف کریں','ar':'مسح'},

  'Enter a valid amount greater than zero.': {'en':'Enter a valid amount greater than zero.','ps':'له صفر څخه لویه سمه اندازه ولیکئ.','fa':'مبلغ معتبر بزرگ‌تر از صفر وارد کنید.','ur':'صفر سے زیادہ درست رقم درج کریں۔','ar':'أدخل مبلغًا صالحًا أكبر من صفر.'},

  'From Time': {'en':'From Time','ps':'له وخت','fa':'از زمان','ur':'وقت سے','ar':'من الوقت'},

  'Gallery': {'en':'Gallery','ps':'ګالري','fa':'گالری','ur':'گیلری','ar':'المعرض'},

  'Note': {'en':'Note','ps':'یادښت','fa':'یادداشت','ur':'نوٹ','ar':'ملاحظة'},

  'Password must be at least 6 characters': {'en':'Password must be at least 6 characters','ps':'پاسورډ باید لږ تر لږه ۶ توري ولري','fa':'رمز عبور باید حداقل ۶ نویسه باشد','ur':'پاس ورڈ کم از کم 6 حروف کا ہونا چاہیے','ar':'يجب أن تتكون كلمة المرور من 6 أحرف على الأقل'},

  'Password reset link sent to your email.': {'en':'Password reset link sent to your email.','ps':'د پاسورډ د بیا ټاکلو لینک مو ایمیل ته ولېږل شو.','fa':'لینک بازنشانی رمز عبور به ایمیل شما ارسال شد.','ur':'پاس ورڈ ری سیٹ لنک آپ کے ای میل پر بھیج دیا گیا ہے۔','ar':'تم إرسال رابط إعادة تعيين كلمة المرور إلى بريدك الإلكتروني.'},

  'Please enter a valid From amount.': {'en':'Please enter a valid From amount.','ps':'مهرباني وکړئ د ورکړې سمه اندازه ولیکئ.','fa':'لطفاً مبلغ مبدأ معتبر وارد کنید.','ur':'براہ کرم درست ابتدائی رقم درج کریں۔','ar':'يرجى إدخال مبلغ مصدر صالح.'},

  'Please enter a valid To amount.': {'en':'Please enter a valid To amount.','ps':'مهرباني وکړئ د ترلاسه کېدو سمه اندازه ولیکئ.','fa':'لطفاً مبلغ مقصد معتبر وارد کنید.','ur':'براہ کرم درست منزل کی رقم درج کریں۔','ar':'يرجى إدخال مبلغ وجهة صالح.'},

  'Please enter your email and password': {'en':'Please enter your email and password','ps':'مهرباني وکړئ ایمیل او پاسورډ ولیکئ','fa':'لطفاً ایمیل و رمز عبور خود را وارد کنید','ur':'براہ کرم اپنا ای میل اور پاس ورڈ درج کریں','ar':'يرجى إدخال البريد الإلكتروني وكلمة المرور'},

  'Please select two different currencies.': {'en':'Please select two different currencies.','ps':'مهرباني وکړئ دوه بېلابېل اسعار وټاکئ.','fa':'لطفاً دو ارز متفاوت انتخاب کنید.','ur':'براہ کرم دو مختلف کرنسیاں منتخب کریں۔','ar':'يرجى اختيار عملتين مختلفتين.'},

  'Profile photo removed': {
    'en': 'Profile photo removed',
    'ps': 'د پروفایل عکس لرې شو',
    'fa': 'عکس پروفایل حذف شد',
    'ur': 'پروفائل تصویر ہٹا دی گئی',
    'ar': 'تمت إزالة صورة الملف الشخصي',
  },

  'Profile photo updated': {
    'en': 'Profile photo updated',
    'ps': 'د پروفایل عکس تازه شو',
    'fa': 'عکس پروفایل به‌روزرسانی شد',
    'ur': 'پروفائل تصویر اپ ڈیٹ ہو گئی',
    'ar': 'تم تحديث صورة الملف الشخصي',
  },

  'Rate must be greater than zero.': {'en':'Rate must be greater than zero.','ps':'نرخ باید له صفر څخه لوی وي.','fa':'نرخ باید بزرگ‌تر از صفر باشد.','ur':'شرح صفر سے زیادہ ہونی چاہیے۔','ar':'يجب أن يكون السعر أكبر من صفر.'},

  'Receipt': {'en':'Receipt','ps':'رسید','fa':'رسید','ur':'رسید','ar':'إيصال'},

  'To Time': {'en':'To Time','ps':'تر وخت','fa':'تا زمان','ur':'وقت تک','ar':'إلى الوقت'},

  'Unable to load reports': {
    'en': 'Unable to load reports',
    'ps': 'راپورونه نه شي پورته کېدای',
    'fa': 'گزارش‌ها بارگذاری نمی‌شوند',
    'ur': 'رپورٹس لوڈ نہیں ہوسکیں',
    'ar': 'تعذر تحميل التقارير',
  },

  'Unable to save photo': {
    'en': 'Unable to save photo',
    'ps': 'عکس خوندي نه شو',
    'fa': 'ذخیره عکس ممکن نشد',
    'ur': 'تصویر محفوظ نہیں ہو سکی',
    'ar': 'تعذر حفظ الصورة',
  },

  'Unable to send reset link. Please try again.': {'en':'Unable to send reset link. Please try again.','ps':'د بیا ټاکلو لینک ونه لېږل شو. بیا هڅه وکړئ.','fa':'لینک بازنشانی ارسال نشد. دوباره تلاش کنید.','ur':'ری سیٹ لنک نہیں بھیجا جا سکا۔ دوبارہ کوشش کریں۔','ar':'تعذر إرسال رابط إعادة التعيين. حاول مرة أخرى.'},

  'We will send you a password reset link.': {'en':'We will send you a password reset link.','ps':'موږ به د پاسورډ د بیا ټاکلو لینک درولېږو.','fa':'لینک بازنشانی رمز عبور برای شما ارسال خواهد شد.','ur':'ہم آپ کو پاس ورڈ ری سیٹ لنک بھیجیں گے۔','ar':'سنرسل إليك رابطًا لإعادة تعيين كلمة المرور.'},

  'darkMode': {'en':'Dark Mode','ps':'تیاره بڼه','fa':'حالت تاریک','ur':'ڈارک موڈ','ar':'الوضع الداكن'},

  'language': {'en':'Language','ps':'ژبه','fa':'زبان','ur':'زبان','ar':'اللغة'},

  'lightMode': {'en':'Light Mode','ps':'روښانه بڼه','fa':'حالت روشن','ur':'لائٹ موڈ','ar':'الوضع الفاتح'},

  'Already have an account?': {
    'en': 'Already have an account?',
    'ps': 'له مخکې حساب لرئ؟',
    'fa': 'از قبل حساب دارید؟',
    'ur': 'کیا آپ کا پہلے سے اکاؤنٹ ہے؟',
    'ar': 'هل لديك حساب بالفعل؟',
  },

  'Are you sure you want to delete this transaction?': {
    'en': 'Are you sure you want to delete this transaction?',
    'ps': 'ایا ډاډه یاست چې دا معامله حذف کړئ؟',
    'fa': 'آیا مطمئن هستید که می‌خواهید این تراکنش را حذف کنید؟',
    'ur': 'کیا آپ واقعی یہ لین دین حذف کرنا چاہتے ہیں؟',
    'ar': 'هل أنت متأكد أنك تريد حذف هذه المعاملة؟',
  },

  'Continue with Google': {
    'en': 'Continue with Google',
    'ps': 'د Google له لارې دوام ورکړئ',
    'fa': 'ادامه با Google',
    'ur': 'Google کے ساتھ جاری رکھیں',
    'ar': 'المتابعة باستخدام Google',
  },

  'Customer phone number is not available.': {
    'en': 'Customer phone number is not available.',
    'ps': 'د پېرودونکي د تلیفون شمېره نشته.',
    'fa': 'شماره تلفن مشتری موجود نیست.',
    'ur': 'گاہک کا فون نمبر دستیاب نہیں ہے۔',
    'ar': 'رقم هاتف العميل غير متوفر.',
  },

  'Exchange moved to Recycle Bin.': {
    'en': 'Exchange moved to Recycle Bin.',
    'ps': 'تبادله حذف شوو معلوماتو ته انتقال شوه.',
    'fa': 'تبادله به سطل بازیافت منتقل شد.',
    'ur': 'ایکسچینج ری سائیکل بن میں منتقل کر دیا گیا۔',
    'ar': 'تم نقل عملية الصرف إلى سلة المحذوفات.',
  },

  'OR': {
    'en': 'OR',
    'ps': 'یا',
    'fa': 'یا',
    'ur': 'یا',
    'ar': 'أو',
  },

  'Open Exchange to edit this transaction.': {
    'en': 'Open Exchange to edit this transaction.',
    'ps': 'د دې معاملې د سمون لپاره تبادله پرانیزئ.',
    'fa': 'برای ویرایش این تراکنش، بخش تبادله را باز کنید.',
    'ur': 'اس لین دین میں ترمیم کے لیے ایکسچینج کھولیں۔',
    'ar': 'افتح قسم الصرف لتعديل هذه المعاملة.',
  },

  'Pending changes will sync when the connection is available.': {
    'en': 'Pending changes will sync when the connection is available.',
    'ps': 'پاتې بدلونونه به د انټرنېټ له شتون سره همغږي شي.',
    'fa': 'تغییرات در انتظار، هنگام در دسترس بودن اتصال همگام می‌شوند.',
    'ur': 'زیر التوا تبدیلیاں کنکشن دستیاب ہونے پر ہم آہنگ ہو جائیں گی۔',
    'ar': 'ستتم مزامنة التغييرات المعلقة عند توفر الاتصال.',
  },

  'Sync operations are pending': {
    'en': 'Sync operations are pending',
    'ps': 'د همغږۍ عملیات پاتې دي',
    'fa': 'عملیات همگام‌سازی در انتظار است',
    'ur': 'ہم آہنگی کی کارروائیاں زیر التوا ہیں',
    'ar': 'عمليات المزامنة معلقة',
  },

  'There are no pending or failed sync operations.': {
    'en': 'There are no pending or failed sync operations.',
    'ps': 'د همغږۍ هېڅ پاتې یا ناکام عملیات نشته.',
    'fa': 'هیچ عملیات همگام‌سازی در انتظار یا ناموفق وجود ندارد.',
    'ur': 'کوئی زیر التوا یا ناکام ہم آہنگی کی کارروائی موجود نہیں ہے۔',
    'ar': 'لا توجد عمليات مزامنة معلقة أو فاشلة.',
  },
};
String ghataT(BuildContext context, String key) {
  final code = Localizations.localeOf(context).languageCode;
  final values = ghataTranslations[key];

  if (values == null) return key;

  return values[code] ??
      values['en'] ??
      key;
}

String ghataLanguageName(String code) {
  switch (code) {
    case 'ps':
      return 'پښتو';
    case 'fa':
      return 'دری';
    case 'ur':
      return 'اردو';
    case 'ar':
      return 'العربية';
    default:
      return 'English';
  }
}


String ghataDevicePlatform() {
  if (Platform.isWindows) return 'windows';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  return Platform.operatingSystem;
}

String ghataDeviceDisplayName() {
  String base;

  if (Platform.isWindows) {
    base = 'Windows PC';
  } else if (Platform.isAndroid) {
    base = 'Android Device';
  } else if (Platform.isIOS) {
    base = 'iPhone / iPad';
  } else if (Platform.isMacOS) {
    base = 'Mac';
  } else if (Platform.isLinux) {
    base = 'Linux Device';
  } else {
    base = 'Ghata Device';
  }

  try {
    final host = Platform.localHostname.trim();

    if (host.isNotEmpty &&
        host.toLowerCase() != 'localhost') {
      return '$base • $host';
    }
  } catch (_) {}

  return base;
}

Future<void> ghataRegisterCurrentDevice() async {
  try {
    final user =
        Supabase.instance.client.auth.currentUser;

    if (user == null) return;

    final deviceId = await GhataSecurity.deviceId();

    final existing =
        await Supabase.instance.client
            .from('user_devices')
            .select(
              'id, device_id, revoked_at',
            )
            .eq('user_id', user.id)
            .eq('device_id', deviceId)
            .maybeSingle();

    if (existing != null) {
      final revokedAt =
          existing['revoked_at']?.toString() ?? '';

      if (revokedAt.isNotEmpty) {
        if (_ghataExplicitAuthInProgress) {
          return;
        }

        await Supabase.instance.client.auth.signOut(
          scope: SignOutScope.local,
        );
        return;
      }

      final now =
          DateTime.now().toUtc().toIso8601String();

      await Supabase.instance.client
          .from('user_devices')
          .update({
            'device_name':
                ghataDeviceDisplayName(),
            'platform':
                ghataDevicePlatform(),
            'last_seen': now,
            'updated_at': now,
          })
          .eq('user_id', user.id)
          .eq('device_id', deviceId);

      return;
    }

    final now =
        DateTime.now().toUtc().toIso8601String();

    await Supabase.instance.client
        .from('user_devices')
        .insert({
          'user_id': user.id,
          'device_id': deviceId,
          'device_name':
              ghataDeviceDisplayName(),
          'platform':
              ghataDevicePlatform(),
          'last_seen': now,
          'created_at': now,
          'updated_at': now,
        });
  } catch (e) {
    debugPrint(
      'Device registration error: $e',
    );
  }
}

Future<void> ghataReactivateDeviceAfterExplicitLogin() async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return;

  try {
    final deviceId = await GhataSecurity.deviceId();
    final now = DateTime.now().toUtc().toIso8601String();

    final existing = await Supabase.instance.client
        .from('user_devices')
        .select('id')
        .eq('user_id', user.id)
        .eq('device_id', deviceId)
        .maybeSingle();

    if (existing == null) {
      await Supabase.instance.client
          .from('user_devices')
          .insert({
        'user_id': user.id,
        'device_id': deviceId,
        'device_name': ghataDeviceDisplayName(),
        'platform': ghataDevicePlatform(),
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
        'revoked_at': null,
      });
    } else {
      await Supabase.instance.client
          .from('user_devices')
          .update({
        'device_name': ghataDeviceDisplayName(),
        'platform': ghataDevicePlatform(),
        'last_seen': now,
        'updated_at': now,
        'revoked_at': null,
      })
          .eq('user_id', user.id)
          .eq('device_id', deviceId);
    }
  } catch (e) {
    debugPrint(
      'Explicit-login device reactivation failed: $e',
    );
  }
}


Future<bool> ghataCheckCurrentDeviceRevocation() async {
  final user = Supabase.instance.client.auth.currentUser;

  if (user == null) return false;

  try {
    final deviceId = await GhataSecurity.deviceId();

    final row = await Supabase.instance.client
        .from('user_devices')
        .select('revoked_at')
        .eq('user_id', user.id)
        .eq('device_id', deviceId)
        .maybeSingle();

    if (row == null) {
      await ghataRegisterCurrentDevice();
      return false;
    }

    final revokedAt =
        row['revoked_at']?.toString();

    if (revokedAt == null || revokedAt.isEmpty) {
      return false;
    }

    try {
      await Supabase.instance.client.auth.signOut(
        scope: SignOutScope.local,
      );
    } catch (e) {
      debugPrint(
        'Ghata revoked-device local sign out failed: $e',
      );
    }

    return true;
  } catch (e) {
    debugPrint(
      'Ghata device revocation check failed: $e',
    );
    return false;
  }
}

Future<void> ghataTouchCurrentDevice() async {
  final user = Supabase.instance.client.auth.currentUser;

  if (user == null) return;

  try {
    final revoked =
        await ghataCheckCurrentDeviceRevocation();

    if (revoked) return;

    final deviceId = await GhataSecurity.deviceId();

    await Supabase.instance.client
        .from('user_devices')
        .update(
          <String, dynamic>{
            'last_seen':
                DateTime.now().toUtc().toIso8601String(),
            'updated_at':
                DateTime.now().toUtc().toIso8601String(),
          },
        )
        .eq('user_id', user.id)
        .eq('device_id', deviceId);
  } catch (e) {
    debugPrint(
      'Ghata device last_seen update failed: $e',
    );
  }
}

class GhataApp extends StatefulWidget {
  GhataApp({super.key});

  @override
  State<GhataApp> createState() => _GhataAppState();
}

class _GhataAppState extends State<GhataApp>
    with WidgetsBindingObserver {
  final navigatorKey = GlobalKey<NavigatorState>();

  static const _settingsStorage = FlutterSecureStorage();
  static const _languageKey = 'ghata_language';
  static const _themeKey = 'ghata_theme_mode';

  Locale _locale = Locale('en');
  ThemeMode _themeMode = ThemeMode.light;

  String get currentLanguage => _locale.languageCode;
  ThemeMode get currentThemeMode => _themeMode;

  void changeLanguage(String languageCode) {
    const supported = {'en', 'ps', 'fa', 'ur', 'ar'};
    if (!supported.contains(languageCode)) return;

    if (_locale.languageCode != languageCode) {
      setState(() {
        _locale = Locale(languageCode);
      });
    }

    _settingsStorage.write(
      key: _languageKey,
      value: languageCode,
    );
  }

  void toggleTheme() {
    final next = _themeMode == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;

    setState(() {
      _themeMode = next;
    });

    _settingsStorage.write(
      key: _themeKey,
      value: next == ThemeMode.dark ? 'dark' : 'light',
    );
  }

  Future<void> _loadSavedAppearance() async {
    try {
      final language =
          await _settingsStorage.read(key: _languageKey);

      final theme =
          await _settingsStorage.read(key: _themeKey);

      const supported = {'en', 'ps', 'fa', 'ur', 'ar'};

      if (!mounted) return;

      setState(() {
        if (language != null && supported.contains(language)) {
          _locale = Locale(language);
        }

        _themeMode =
            theme == 'dark' ? ThemeMode.dark : ThemeMode.light;
      });
    } catch (_) {
      // Keep default English + light mode.
    }
  }

  Timer? _ghataSyncTimer;
  RealtimeChannel? _ghataRealtimeChannel;

  void _startGhataRealtimeSync() {
    if (Supabase.instance.client.auth.currentUser == null) {
      return;
    }

    if (_ghataRealtimeChannel != null) {
      return;
    }

    final channel = Supabase.instance.client.channel(
      'ghata-multidevice-sync',
    );

    void handleRealtimeChange(PostgresChangePayload payload) {
      // Multi-device sync: update the local cache first,
      // then notify the currently open UI to reread SQLite.
      Future<void>(() async {
        await ghataTrySync();
        ghataNotifyLocalDataChanged();
      });
    }

    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'customers',
          callback: handleRealtimeChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'transactions',
          callback: handleRealtimeChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'exchanges',
          callback: handleRealtimeChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'exchange_entries',
          callback: handleRealtimeChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'profiles',
          callback: handleRealtimeChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'user_devices',
          callback: (payload) {
            ghataCheckCurrentDeviceRevocation();
          },
        )
        .subscribe();

    _ghataRealtimeChannel = channel;
  }

  Future<void> _stopGhataRealtimeSync() async {
    final channel = _ghataRealtimeChannel;
    _ghataRealtimeChannel = null;

    if (channel != null) {
      try {
        await Supabase.instance.client.removeChannel(channel);
      } catch (e) {
        debugPrint('Ghata realtime channel cleanup failed: $e');
      }
    }
  }

  void _startGhataAutomaticSync() {
    _ghataSyncTimer?.cancel();

    if (Supabase.instance.client.auth.currentUser == null) {
      return;
    }

    ghataRegisterCurrentDevice();
    ghataTrySync();
    _startGhataRealtimeSync();

    _ghataSyncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (Supabase.instance.client.auth.currentUser != null) {
          ghataTouchCurrentDevice();
          ghataTrySync();
        }
      },
    );
  }

  void _stopGhataAutomaticSync() {
    _ghataSyncTimer?.cancel();
    _ghataSyncTimer = null;
    _stopGhataRealtimeSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startGhataAutomaticSync();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopGhataAutomaticSync();
    }
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _loadSavedAppearance();

    if (Supabase.instance.client.auth.currentUser != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startGhataAutomaticSync();
      });
    }

    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.passwordRecovery) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          navigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => NewPasswordScreen(),
            ),
            (route) => false,
          );
        });
        return;
      }

      if (data.event == AuthChangeEvent.signedIn ||
          data.event == AuthChangeEvent.tokenRefreshed ||
          data.event == AuthChangeEvent.userUpdated) {
        if (_ghataExplicitAuthInProgress) {
          () async {
            while (_ghataExplicitAuthInProgress) {
              await Future.delayed(
                const Duration(milliseconds: 100),
              );
            }

            if (Supabase.instance.client.auth.currentUser != null) {
              _startGhataAutomaticSync();
            }
          }();
        } else {
          _startGhataAutomaticSync();
        }
      }

      if (data.event == AuthChangeEvent.signedOut) {
        _stopGhataAutomaticSync();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopGhataAutomaticSync();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Ghata',

      // Default language: English
      locale: _locale,

      supportedLocales: [
        Locale('en'), // English
        Locale('ps'), // پښتو
        Locale('fa'), // دری
        Locale('ur'), // اردو
        Locale('ar'), // العربية
      ],

      localizationsDelegates: [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF6FFE8),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF63B32E),
          brightness: Brightness.light,
          surface: const Color(0xFFFFFEF7),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF2FFD8),
          foregroundColor: Color(0xFF12351F),
          elevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFFFFFEF7),
          elevation: 1.5,
          margin: EdgeInsets.zero,
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: Color(0xFFFFFEF7),
          elevation: 12,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFFFFFEF7),
          indicatorColor: Color(0xFFD9F7A7),
        ),
        dividerColor: const Color(0xFFDDECC8),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blue,
      ),
      themeMode: _themeMode,
      home: Supabase.instance.client.auth.currentSession == null
          ? LoginScreen()
          : GhataStartupGate(),
    );
  }
}

final ValueNotifier<int> ghataDataRevision =
    ValueNotifier<int>(0);

void ghataNotifyLocalDataChanged() {
  ghataDataRevision.value++;
}

bool _ghataExplicitAuthInProgress = false;

class LoginScreen extends StatefulWidget {
  LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool hidePassword = true;
  bool isLoading = false;

  Future<void> login() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(context, 'Please enter your email and password'),
          ),
        ),
      );
      return;
    }

    setState(() => isLoading = true);
    _ghataExplicitAuthInProgress = true;

    try {
      final response =
          await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final user = response.user;

      if (user == null) {
        throw StateError('Login succeeded without a user.');
      }

      // Offline data is isolated by user_id, so switching accounts
      // must not erase another account's local records.
      await GhataSecurity.setLocalAccountOwner(user.id);

      // Offline-first after successful authentication.
      // Home must not wait for device registration or cloud synchronization.
      Future<void>(() async {
        // A successful password login is a new explicit authorization
        // for this physical device, so an old remote-logout marker may
        // be cleared here. Normal startup never clears revoked_at.
        await ghataReactivateDeviceAfterExplicitLogin();
        await ghataTrySync();
      });

      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => HomeScreen(),
        ),
        (route) => false,
      );
    } on AuthException catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e, st) {
      debugPrint('Ghata login error: $e');
      debugPrintStack(stackTrace: st);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(
              context,
              'Unable to login. Please try again.',
            ),
          ),
        ),
      );
    } finally {
      _ghataExplicitAuthInProgress = false;

      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF123D2B);
    const cream = Color(0xFFFFFBF2);
    const gold = Color(0xFFFFE8A3);

    InputDecoration authDecoration(
      String label,
      IconData icon, {
      Widget? suffixIcon,
    }) {
      return InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: green),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: Colors.white.withValues(alpha: .94),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: green.withValues(alpha: .14),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(
            color: green,
            width: 1.5,
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/images/about_accounting.png',
            fit: BoxFit.cover,
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  green.withValues(alpha: .90),
                  const Color(0xFF1F5A43).withValues(alpha: .80),
                  const Color(0xFF8A6B2D).withValues(alpha: .60),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(30, 28, 30, 22),
                    decoration: BoxDecoration(
                      color: cream.withValues(alpha: .96),
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .18),
                          blurRadius: 32,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 72,
                            height: 72,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Image.asset(
                              'assets/images/ghata_leaf.png',
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'ګهته / Ghata',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: green,
                            fontSize: 27,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          ghataT(context, 'Business Ledger & Accounting'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF5F6F65),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          ghataT(
                            context,
                            'Simple Accounting for a Better Tomorrow',
                          ),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF7B6A3B),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 26),
                        TextField(
                          controller: emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: authDecoration(
                            ghataT(context, 'Gmail / Email'),
                            Icons.email_outlined,
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: passwordController,
                          obscureText: hidePassword,
                          decoration: authDecoration(
                            ghataT(context, 'Password'),
                            Icons.lock_outline,
                            suffixIcon: IconButton(
                              onPressed: () {
                                setState(() {
                                  hidePassword = !hidePassword;
                                });
                              },
                              icon: Icon(
                                hidePassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: isLoading
                                ? null
                                : () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            ForgotPasswordScreen(),
                                      ),
                                    );
                                  },
                            child: Text(
                              ghataT(context, 'Forgot Password?'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        SizedBox(
                          height: 52,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: green,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: isLoading ? null : login,
                            child: isLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(
                                    ghataT(context, 'Login'),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            const Expanded(child: Divider()),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                ghataT(context, 'OR'),
                                style: const TextStyle(
                                  color: Color(0xFF6E776F),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const Expanded(child: Divider()),
                          ],
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 50,
                          child: OutlinedButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.g_mobiledata_rounded),
                            label: Text(
                              ghataT(context, 'Continue with Google'),
                            ),
                            style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                ghataT(
                                  context,
                                  "Don't have an account?",
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: isLoading
                                  ? null
                                  : () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => SignupScreen(),
                                        ),
                                      );
                                    },
                              child: Text(
                                ghataT(context, 'Create Account'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Design by MRS',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: green,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SignupScreen extends StatefulWidget {
  SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  bool hidePassword = true;
  bool hideConfirmPassword = true;
  bool isLoading = false;

  Future<void> createAccount() async {
    final fullName = nameController.text.trim();
    final email = emailController.text.trim();
    final password = passwordController.text;
    final confirmPassword = confirmPasswordController.text;

    if (fullName.isEmpty ||
        email.isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(context, 'Please fill in all fields'),
          ),
        ),
      );
      return;
    }

    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(
              context,
              'Password must be at least 6 characters',
            ),
          ),
        ),
      );
      return;
    }

    if (password != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(context, 'Passwords do not match'),
          ),
        ),
      );
      return;
    }

    setState(() => isLoading = true);
    _ghataExplicitAuthInProgress = true;

    try {
      final response =
          await Supabase.instance.client.auth.signUp(
        email: email,
        password: password,
        data: {
          'full_name': fullName,
        },
      );

      final user = response.user;

      if (user == null) {
        throw StateError(
          'Account creation returned no user.',
        );
      }

      // If Supabase authenticated the new account immediately,
      // isolate local data before opening Home.
      if (response.session != null) {
        // Keep other accounts' offline records intact.
        // OfflineDatabase scopes reads and writes by current user_id.
        await GhataSecurity.setLocalAccountOwner(user.id);

        // Offline-first after successful signup:
        // do not delay navigation while waiting for Supabase cache refresh.
        Future<void>(() async {
          await ghataRefreshOfflineCache();
        });

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ghataT(
                context,
                'Account created successfully.',
              ),
            ),
          ),
        );

        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) => HomeScreen(),
          ),
          (route) => false,
        );
      } else {
        // Email confirmation is required.
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ghataT(
                context,
                'Account created successfully.',
              ),
            ),
          ),
        );

        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) => LoginScreen(),
          ),
          (route) => false,
        );
      }
    } on AuthException catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e, st) {
      debugPrint('Ghata signup error: $e');
      debugPrintStack(stackTrace: st);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(
              context,
              'Something went wrong. Please try again.',
            ),
          ),
        ),
      );
    } finally {
      _ghataExplicitAuthInProgress = false;

      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF123D2B);
    const cream = Color(0xFFFFFBF2);

    InputDecoration authDecoration(
      String label,
      IconData icon, {
      Widget? suffixIcon,
    }) {
      return InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: green),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: Colors.white.withValues(alpha: .94),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: green.withValues(alpha: .14),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(
            color: green,
            width: 1.5,
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/images/about_accounting.png',
            fit: BoxFit.cover,
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  green.withValues(alpha: .90),
                  const Color(0xFF1F5A43).withValues(alpha: .80),
                  const Color(0xFF8A6B2D).withValues(alpha: .60),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(30, 26, 30, 22),
                    decoration: BoxDecoration(
                      color: cream.withValues(alpha: .96),
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .18),
                          blurRadius: 32,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 66,
                            height: 66,
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Image.asset(
                              'assets/images/ghata_leaf.png',
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'ګهته / Ghata',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: green,
                            fontSize: 25,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          ghataT(context, 'Create Account'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF5F6F65),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 22),
                        TextField(
                          controller: nameController,
                          decoration: authDecoration(
                            ghataT(context, 'Full Name'),
                            Icons.person_outline,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: authDecoration(
                            ghataT(context, 'Gmail / Email'),
                            Icons.email_outlined,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: passwordController,
                          obscureText: hidePassword,
                          decoration: authDecoration(
                            ghataT(context, 'Password'),
                            Icons.lock_outline,
                            suffixIcon: IconButton(
                              onPressed: () {
                                setState(() {
                                  hidePassword = !hidePassword;
                                });
                              },
                              icon: Icon(
                                hidePassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: confirmPasswordController,
                          obscureText: hideConfirmPassword,
                          decoration: authDecoration(
                            ghataT(context, 'Confirm Password'),
                            Icons.lock_outline,
                            suffixIcon: IconButton(
                              onPressed: () {
                                setState(() {
                                  hideConfirmPassword =
                                      !hideConfirmPassword;
                                });
                              },
                              icon: Icon(
                                hideConfirmPassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          height: 52,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: green,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed:
                                isLoading ? null : createAccount,
                            child: isLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(
                                    ghataT(context, 'Create Account'),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            const Expanded(child: Divider()),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                ghataT(context, 'OR'),
                                style: const TextStyle(
                                  color: Color(0xFF6E776F),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const Expanded(child: Divider()),
                          ],
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 50,
                          child: OutlinedButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.g_mobiledata_rounded),
                            label: Text(
                              ghataT(context, 'Continue with Google'),
                            ),
                            style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                ghataT(
                                  context,
                                  'Already have an account?',
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: isLoading
                                  ? null
                                  : () => Navigator.pop(context),
                              child: Text(
                                ghataT(context, 'Login'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Design by MRS',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: green,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ForgotPasswordScreen extends StatefulWidget {
  ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final emailController = TextEditingController();
  bool isLoading = false;

  Future<void> sendResetLink() async {
    final email = emailController.text.trim();

    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Please enter your Gmail / Email')),
        ),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: 'com.rahemsadaf.ghata://reset-password',
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Password reset link sent to your email.')),
        ),
      );
    } on AuthException catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Unable to send reset link. Please try again.')),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'Forgot Password')),
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            children: [
              SizedBox(height: 30),
              Icon(
                Icons.lock_reset_rounded,
                size: 76,
                color: Colors.blue,
              ),
              SizedBox(height: 20),
              Text(
                'Enter your Gmail / Email',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              Text(
                ghataT(context, 'We will send you a password reset link.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              SizedBox(height: 24),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Gmail / Email'),
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: isLoading ? null : sendResetLink,
                  child: isLoading
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : Text(ghataT(context, 'Send Reset Link')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class GhataSecurity {
  static const _storage = FlutterSecureStorage();
  static const _localAccountOwnerKey = 'ghata_local_account_owner';
  static const _deviceIdKey = 'ghata_device_id';

  static Future<String> deviceId() async {
    final existing = await _storage.read(key: _deviceIdKey);

    if (existing != null && existing.trim().isNotEmpty) {
      return existing;
    }

    final id = const Uuid().v4();

    await _storage.write(
      key: _deviceIdKey,
      value: id,
    );

    return id;
  }

  static Future<String?> localAccountOwner() async {
    return _storage.read(key: _localAccountOwnerKey);
  }

  static Future<void> setLocalAccountOwner(String userId) async {
    await _storage.write(
      key: _localAccountOwnerKey,
      value: userId,
    );
  }

}




class StaffManagementScreen extends StatefulWidget {
  StaffManagementScreen({super.key});

  @override
  State<StaffManagementScreen> createState() =>
      _StaffManagementScreenState();
}

class _StaffManagementScreenState
    extends State<StaffManagementScreen> {
  bool loading = true;
  List<Map<String, dynamic>> staff = [];

  @override
  void initState() {
    super.initState();
    loadStaff();
  }

  Future<void> loadStaff() async {
    final user = Supabase.instance.client.auth.currentUser;

    if (user == null) {
      if (mounted) {
        setState(() {
          staff = [];
          loading = false;
        });
      }
      return;
    }

    // Offline-first: show the last cached staff list immediately.
    final local =
        await OfflineDatabase.instance.getRecords('staff_members');

    local.sort((a, b) {
      final ad = a['created_at']?.toString() ?? '';
      final bd = b['created_at']?.toString() ?? '';
      return bd.compareTo(ad);
    });

    if (mounted) {
      setState(() {
        staff = local;
        loading = false;
      });
    }

    // Refresh the read-only staff cache in the background.
    // Staff add/disable operations remain protected Supabase RPC actions.
    Future<void>(() async {
      try {
        final data = await Supabase.instance.client
            .from('staff_members')
            .select()
            .eq('owner_id', user.id)
            .order('created_at', ascending: false);

        final rows = List<Map<String, dynamic>>.from(data);

        await OfflineDatabase.instance.cacheServerRecords(
          'staff_members',
          rows,
        );

        if (!mounted) return;

        setState(() {
          staff = rows;
        });
      } catch (e) {
        // Offline is valid. Keep showing the cached staff list.
        debugPrint('Ghata staff background refresh failed: $e');
      }
    });
  }

  Future<void> addStaff() async {
    final emailController = TextEditingController();
    bool canAddEdit = true;
    bool canViewReports = true;

    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(ghataT(context, 'Add Staff')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Staff Email'),
                    hintText: 'staff@example.com',
                    border: OutlineInputBorder(),
                  ),
                ),
                SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(ghataT(context, 'Add / Edit')),
                  subtitle: Text(
                    'Allow adding and editing accounting records.',
                  ),
                  value: canAddEdit,
                  onChanged: (value) {
                    setDialogState(() => canAddEdit = value);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(ghataT(context, 'View Reports')),
                  value: canViewReports,
                  onChanged: (value) {
                    setDialogState(
                      () => canViewReports = value,
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, false),
              child: Text(ghataT(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, true),
              child: Text(ghataT(context, 'Save')),
            ),
          ],
        ),
      ),
    );

    if (save != true) {
      emailController.dispose();
      return;
    }

    final email = emailController.text.trim().toLowerCase();
    emailController.dispose();

    if (email.isEmpty || !email.contains('@')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Enter a valid staff email.')),
        ),
      );
      return;
    }

    try {
      await Supabase.instance.client.rpc(
        'save_staff_member',
        params: {
          'p_email': email,
          'p_can_add_edit': canAddEdit,
          'p_can_view_reports': canViewReports,
        },
      );

      await loadStaff();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Staff permissions saved.')),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${ghataT(context, 'Unable to save staff')}: $e")),
      );
    }
  }

  Future<void> disableStaff(
    Map<String, dynamic> member,
  ) async {
    final id = member['id']?.toString();
    if (id == null || id.isEmpty) return;

    final email = member['staff_email']?.toString() ?? 'Staff';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ghataT(context, 'Disable Staff?')),
        content: Text(
          '$email will no longer have staff access.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, true),
            child: Text(ghataT(context, 'Disable')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await Supabase.instance.client.rpc(
        'disable_staff_member',
        params: {'p_staff_id': id},
      );

      await loadStaff();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Staff disabled.'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${ghataT(context, 'Unable to disable staff')}: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'Staff Management')),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: addStaff,
        icon: Icon(Icons.person_add_outlined),
        label: Text(ghataT(context, 'Add Staff')),
      ),
      body: loading
          ? Center(child: CircularProgressIndicator())
          : staff.isEmpty
              ? Center(
                  child: Text(
                    'No staff added yet.',
                    textAlign: TextAlign.center,
                  ),
                )
              : RefreshIndicator(
                  onRefresh: loadStaff,
                  child: ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                      12,
                      12,
                      12,
                      90,
                    ),
                    itemCount: staff.length,
                    itemBuilder: (context, index) {
                      final member = staff[index];

                      final email =
                          member['staff_email']?.toString() ?? '';
                      final active =
                          member['is_active'] == true;
                      final addEdit =
                          member['can_add_edit'] == true;
                      final reports =
                          member['can_view_reports'] == true;

                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Icon(
                              active
                                  ? Icons.person_outline
                                  : Icons.person_off_outlined,
                            ),
                          ),
                          title: Text(email),
                          subtitle: Text(
                            '${active ? 'Active' : 'Disabled'}'
                            ' • Add/Edit: ${addEdit ? 'Yes' : 'No'}'
                            ' • Reports: ${reports ? 'Yes' : 'No'}',
                          ),
                          trailing: active
                              ? IconButton(
                                  tooltip: ghataT(context, 'Disable Staff'),
                                  icon: Icon(
                                    Icons.block_outlined,
                                  ),
                                  onPressed: () =>
                                      disableStaff(member),
                                )
                              : null,
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}


class BackupRestoreScreen extends StatefulWidget {
  BackupRestoreScreen({super.key});

  @override
  State<BackupRestoreScreen> createState() =>
      _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  bool busy = false;

  static const XTypeGroup _jsonTypeGroup = XTypeGroup(
    label: 'Ghata Backup',
    extensions: <String>['json'],
  );

  Future<Map<String, dynamic>> _buildBackup() async {
    final user = Supabase.instance.client.auth.currentUser;

    if (user == null) {
      throw Exception('You are not signed in.');
    }

    final customers =
        await OfflineDatabase.instance.getRecords('customers');

    final transactions =
        await OfflineDatabase.instance.getRecords('transactions');

    final exchanges =
        await OfflineDatabase.instance.getRecords('exchanges');

    final exchangeEntries =
        await OfflineDatabase.instance.getRecords('exchange_entries');

    final profile = await OfflineDatabase.instance.getRecord(
      'profiles',
      user.id,
      includeDeleted: true,
    );

    return <String, dynamic>{
      'app': 'Ghata',
      'format_version': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'user_id': user.id,
      'profile': profile,
      'customers': customers,
      'transactions': transactions,
      'exchanges': exchanges,
      'exchange_entries': exchangeEntries,
    };
  }

  Future<void> createBackup() async {
    if (busy) return;

    setState(() => busy = true);

    try {
      // Backup B:
      // Keep the automatic backup current, then export that exact latest file.
      while (_ghataAutomaticBackupRunning) {
        await Future.delayed(const Duration(milliseconds: 100));
      }

      await ghataCreateAutomaticBackup();

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        throw StateError('No signed-in user.');
      }

      final root = await getApplicationDocumentsDirectory();
      final safeUserId = user.id.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '_',
      );

      final autoBackupFile = File(
        '${root.path}/Ghata/backups/'
        'Ghata_Auto_Latest_$safeUserId.json',
      );

      if (!await autoBackupFile.exists()) {
        throw StateError('Automatic backup file was not created.');
      }

      final bytes = await autoBackupFile.readAsBytes();

      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');

      final fileName =
          'Ghata_Backup_'
          '${now.year}${two(now.month)}${two(now.day)}_'
          '${two(now.hour)}${two(now.minute)}.json';

      if (Platform.isWindows) {
        final location = await getSaveLocation(
          suggestedName: fileName,
          acceptedTypeGroups: const <XTypeGroup>[_jsonTypeGroup],
        );

        if (location == null) return;

        final file = XFile.fromData(
          bytes,
          mimeType: 'application/json',
          name: fileName,
        );

        await file.saveTo(location.path);
      } else {
        await SharePlus.instance.share(
          ShareParams(
            title: ghataT(context, 'Ghata Backup'),
            subject: 'Ghata Accounting Backup',
            text:
                'Ghata backup created ${now.toString().substring(0, 16)}',
            files: [
              XFile.fromData(
                bytes,
                mimeType: 'application/json',
                name: fileName,
              ),
            ],
            fileNameOverrides: [fileName],
          ),
        );
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(context, 'Backup created successfully.'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "${ghataT(context, 'Unable to create backup')}: $e",
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  List<Map<String, dynamic>> _validatedList(
    Map<String, dynamic> backup,
    String key,
  ) {
    final value = backup[key];

    if (value == null) {
      return <Map<String, dynamic>>[];
    }

    if (value is! List) {
      throw FormatException('Invalid backup section: $key');
    }

    return value.map<Map<String, dynamic>>((item) {
      if (item is! Map) {
        throw FormatException('Invalid record in: $key');
      }

      final record = Map<String, dynamic>.from(item);

      final id = record['id']?.toString() ?? '';

      if (id.isEmpty) {
        throw FormatException('Missing record id in: $key');
      }

      return record;
    }).toList();
  }

  Future<void> restoreBackup() async {
    if (busy) return;

    final selected = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[_jsonTypeGroup],
    );

    if (selected == null) return;

    try {
      final raw = await selected.readAsString();
      final decoded = jsonDecode(raw);

      if (decoded is! Map) {
        throw FormatException('Invalid backup file.');
      }

      final backup = Map<String, dynamic>.from(decoded);

      if (backup['app']?.toString() != 'Ghata') {
        throw FormatException('This is not a Ghata backup.');
      }

      if (backup['format_version'] != 1) {
        throw FormatException('Unsupported backup version.');
      }

      final user = Supabase.instance.client.auth.currentUser;

      if (user == null) {
        throw Exception('You are not signed in.');
      }

      final backupUserId = backup['user_id']?.toString() ?? '';

      if (backupUserId.isEmpty || backupUserId != user.id) {
        throw Exception(
          'This backup belongs to another Ghata account.',
        );
      }

      final customers = _validatedList(backup, 'customers');
      final transactions = _validatedList(backup, 'transactions');
      final exchanges = _validatedList(backup, 'exchanges');
      final exchangeEntries =
          _validatedList(backup, 'exchange_entries');

      void validateOwnedRecords(
        String section,
        List<Map<String, dynamic>> records,
      ) {
        for (final record in records) {
          if (record['user_id']?.toString() != user.id) {
            throw Exception(
              'Backup contains $section data from another account.',
            );
          }
        }
      }

      validateOwnedRecords('customer', customers);
      validateOwnedRecords('transaction', transactions);
      validateOwnedRecords('exchange', exchanges);
      validateOwnedRecords('exchange entry', exchangeEntries);

      final customerIds = customers
          .map((record) => record['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();

      final exchangeIds = exchanges
          .map((record) => record['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();

      for (final record in [...transactions, ...exchanges]) {
        final customerId =
            record['customer_id']?.toString().trim() ?? '';

        if (customerId.isNotEmpty &&
            !customerIds.contains(customerId)) {
          throw Exception(
            'Backup contains an invalid customer reference.',
          );
        }
      }

      for (final entry in exchangeEntries) {
        final exchangeId =
            entry['exchange_id']?.toString().trim() ?? '';

        if (exchangeId.isEmpty ||
            !exchangeIds.contains(exchangeId)) {
          throw Exception(
            'Backup contains an exchange entry without a valid owned exchange.',
          );
        }
      }

      Map<String, dynamic>? profile;

      if (backup['profile'] != null) {
        if (backup['profile'] is! Map) {
          throw FormatException('Invalid profile data.');
        }

        profile =
            Map<String, dynamic>.from(backup['profile'] as Map);

        if (profile['id']?.toString() != user.id) {
          throw Exception(
            'The profile in this backup belongs to another account.',
          );
        }
      }

      if (!mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(ghataT(context, 'Restore Backup')),
          content: Text(
            'This backup was validated for your current Ghata account. '
            'Its records will be restored to this device and queued for '
            'safe synchronization. Existing records with the same ID '
            'will be updated.',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, false),
              child: Text(ghataT(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, true),
              child: Text(ghataT(context, 'Restore Backup')),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;

      setState(() => busy = true);

      Future<void> restoreRecords(
        String table,
        List<Map<String, dynamic>> records,
      ) async {
        for (final record in records) {
          await OfflineDatabase.instance.saveLocalRecord(
            table,
            record,
            operationType: 'upsert',
          );
        }
      }

      if (profile != null) {
        await OfflineDatabase.instance.saveLocalRecord(
          'profiles',
          profile,
          operationType: 'upsert',
        );
      }

      await restoreRecords('customers', customers);
      await restoreRecords('transactions', transactions);
      await restoreRecords('exchanges', exchanges);
      await restoreRecords('exchange_entries', exchangeEntries);

      ghataScheduleAutomaticBackup();
        ghataTrySync();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Backup restored successfully.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Restore failed')}: $e"),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'Backup & Restore')),
      ),
      body: ListView(
        padding: EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(Icons.cloud_upload_outlined),
              title: Text(ghataT(context, 'Create Backup')),
              subtitle: Text(
                ghataT(
                  context,
                  'Automatic backup stays updated. Create Backup exports the latest backup.',
                ),
              ),
              trailing: busy
                  ? SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : Icon(Icons.chevron_right),
              onTap: busy ? null : createBackup,
            ),
          ),
          SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: Icon(Icons.restore_outlined),
              title: Text(ghataT(context, 'Restore Backup')),
              subtitle: Text(
                'Select a validated Ghata JSON backup file.',
              ),
              trailing: busy
                  ? SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : Icon(Icons.chevron_right),
              onTap: busy ? null : restoreBackup,
            ),
          ),
          SizedBox(height: 16),
          Text(
            ghataT(
                  context,
                  'Keep backup files in a safe place such as your',
                ) +
                ' ' +
                ghataT(
                  context,
                  'private cloud storage or another trusted device.',
                ),
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}



class ActiveDevicesScreen extends StatefulWidget {
  const ActiveDevicesScreen({super.key});

  @override
  State<ActiveDevicesScreen> createState() =>
      _ActiveDevicesScreenState();
}

class _ActiveDevicesScreenState extends State<ActiveDevicesScreen> {
  bool loading = true;
  String? currentDeviceId;
  List<Map<String, dynamic>> devices = [];

  @override
  void initState() {
    super.initState();
    loadDevices();
  }

  IconData _platformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'windows':
        return Icons.desktop_windows_outlined;
      case 'android':
        return Icons.android_outlined;
      case 'ios':
        return Icons.phone_iphone_outlined;
      case 'macos':
        return Icons.laptop_mac_outlined;
      case 'linux':
        return Icons.computer_outlined;
      default:
        return Icons.devices_other_outlined;
    }
  }

  String _lastSeenText(BuildContext context, dynamic value) {
    final raw = value?.toString() ?? '';
    final date = DateTime.tryParse(raw);

    if (date == null) {
      return ghataT(context, 'Unknown');
    }

    final now = DateTime.now().toUtc();
    final diff = now.difference(date.toUtc());

    if (diff.inSeconds < 60) {
      return ghataT(context, 'Active now');
    }

    if (diff.inMinutes < 60) {
      return '${diff.inMinutes} ${ghataT(context, 'min ago')}';
    }

    if (diff.inHours < 24) {
      return '${diff.inHours} ${ghataT(context, 'h ago')}';
    }

    if (diff.inDays < 30) {
      return '${diff.inDays} ${ghataT(context, 'd ago')}';
    }

    return date.toLocal().toString().substring(0, 16);
  }

  Future<void> loadDevices() async {
    final user = Supabase.instance.client.auth.currentUser;

    if (user == null) {
      if (mounted) {
        setState(() {
          devices = [];
          loading = false;
        });
      }
      return;
    }

    // Device ID is local and does not require the network.
    final id = await GhataSecurity.deviceId();

    // Offline-first: show the last cached device list immediately.
    final local =
        await OfflineDatabase.instance.getRecords('user_devices');

    local.sort((a, b) {
      final ad = a['last_seen']?.toString() ?? '';
      final bd = b['last_seen']?.toString() ?? '';
      return bd.compareTo(ad);
    });

    if (mounted) {
      setState(() {
        currentDeviceId = id;
        devices = local;
        loading = false;
      });
    }

    // Registration and server refresh are best-effort background work.
    Future<void>(() async {
      try {
        await ghataRegisterCurrentDevice();

        final rows = await Supabase.instance.client
            .from('user_devices')
            .select()
            .eq('user_id', user.id)
            .order('last_seen', ascending: false);

        final latest = List<Map<String, dynamic>>.from(rows);

        await OfflineDatabase.instance.cacheServerRecords(
          'user_devices',
          latest,
        );

        if (!mounted) return;

        setState(() {
          currentDeviceId = id;
          devices = latest;
        });
      } catch (e) {
        // Offline is valid. Keep the cached device list visible.
        debugPrint('Ghata devices background refresh failed: $e');
      }
    });
  }

  Future<void> revokeDevice(
    Map<String, dynamic> device,
  ) async {
    final deviceId = device['device_id']?.toString() ?? '';

    if (deviceId.isEmpty ||
        deviceId == currentDeviceId) {
      return;
    }

    final name =
        device['device_name']?.toString() ?? 'Device';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ghataT(context, 'Log Out Device')),
        content: Text(
          '${ghataT(context, 'Log out device confirmation')} "$name"?',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, false),
            child: Text(
              ghataT(context, 'Cancel'),
            ),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, true),
            child: Text(ghataT(context, 'Log Out')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final user = Supabase.instance.client.auth.currentUser;

      if (user == null) return;

      final now =
          DateTime.now().toUtc().toIso8601String();

      await Supabase.instance.client
          .from('user_devices')
          .update(
            <String, dynamic>{
              'revoked_at': now,
              'updated_at': now,
            },
          )
          .eq('user_id', user.id)
          .eq('device_id', deviceId);

      // Cloud revoke succeeded. Update the local cache immediately
      // so the offline-first device list cannot show stale state.
      try {
        await OfflineDatabase.instance.saveRecord(
          'user_devices',
          {
            ...device,
            'device_id': deviceId,
            'revoked_at': now,
            'updated_at': now,
          },
          synced: true,
        );
      } catch (e) {
        debugPrint(
          'Ghata revoked-device local cache update failed: $e',
        );
      }

      if (!mounted) return;

      setState(() {
        devices = devices.map((row) {
          if (row['device_id']?.toString() != deviceId) {
            return row;
          }

          return <String, dynamic>{
            ...row,
            'revoked_at': now,
            'updated_at': now,
          };
        }).toList();
      });

      // Best-effort background reconciliation with the server.
      Future<void>(() async {
        await loadDevices();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(context, 'Device logged out successfully.'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '''${ghataT(context, 'Unable to log out device')}: $e''',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'Active Devices')),
        actions: [
          IconButton(
            tooltip: ghataT(context, 'Refresh'),
            onPressed: loading ? null : loadDevices,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : RefreshIndicator(
              onRefresh: loadDevices,
              child: devices.isEmpty
                  ? ListView(
                      children: [
                        SizedBox(height: 140),
                        Center(
                          child: Text(
                            ghataT(
                              context,
                              'No active devices found.',
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: devices.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final device = devices[index];

                        final deviceId =
                            device['device_id']
                                    ?.toString() ??
                                '';

                        final isCurrent =
                            deviceId == currentDeviceId;

                        final revokedAt =
                            device['revoked_at']
                                ?.toString();

                        final revoked =
                            revokedAt != null &&
                                revokedAt.isNotEmpty;

                        final platform =
                            device['platform']
                                    ?.toString() ??
                                'unknown';

                        final name =
                            device['device_name']
                                    ?.toString() ??
                                'Unknown device';

                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Icon(
                                _platformIcon(platform),
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(name),
                                ),
                                if (isCurrent)
                                  Padding(
                                      padding: EdgeInsets.only(left: 8),
                                      child: Chip(
                                        label: Text(
                                          ghataT(context, 'This device'),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              revoked
                                  ? ghataT(context, 'Logged out')
                                  : '${platform.toUpperCase()} • ${_lastSeenText(context, device['last_seen'])}',
                            ),
                            trailing: isCurrent || revoked
                                ? null
                                : IconButton(
                                    tooltip:
                                        'Log Out Device',
                                    onPressed: () =>
                                        revokeDevice(device),
                                    icon: const Icon(
                                      Icons.logout,
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}



class SyncDiagnosticsScreen extends StatefulWidget {
  const SyncDiagnosticsScreen({super.key});

  @override
  State<SyncDiagnosticsScreen> createState() =>
      _SyncDiagnosticsScreenState();
}

class _SyncDiagnosticsScreenState extends State<SyncDiagnosticsScreen> {
  bool loading = true;
  Map<String, dynamic>? diagnostics;
  String? loadError;

  @override
  void initState() {
    super.initState();
    loadDiagnostics();
  }

  Future<void> loadDiagnostics({bool syncFirst = false}) async {
    setState(() {
      loading = true;
      loadError = null;
    });

    try {
      if (syncFirst) {
        await OfflineSyncService.instance.syncPending();
      }

      final result =
          await OfflineDatabase.instance.syncDiagnostics();

      if (!mounted) return;

      setState(() {
        diagnostics = result;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loadError = e.toString();
        loading = false;
      });
    }
  }

  Widget diagnosticRow(String label, Object? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: SelectableText(value?.toString() ?? '-'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = diagnostics;
    final problems = data?['problems'] is List
        ? (data!['problems'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];

    final pending = data?['pending'] ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'Sync Status')),
        actions: [
          IconButton(
            tooltip: ghataT(context, 'Refresh'),
            onPressed: loading
                ? null
                : () => loadDiagnostics(syncFirst: true),
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              ghataT(context, 'Offline Sync Queue'),
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge,
                            ),
                            const SizedBox(height: 14),
                            diagnosticRow(
                              ghataT(context, 'Pending'),
                              pending,
                            ),
                            diagnosticRow(
                              ghataT(context, 'Attempted'),
                              data?['attempted'] ?? 0,
                            ),
                            diagnosticRow(
                              ghataT(context, 'Failed'),
                              data?['failed'] ?? 0,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (problems.isEmpty)
                      Card(
                        child: ListTile(
                          leading: Icon(
                            pending == 0
                                ? Icons.check_circle_outline
                                : Icons.schedule_outlined,
                          ),
                          title: Text(
                            pending == 0
                                ? ghataT(context, 'Everything is synced')
                                : ghataT(
                                    context,
                                    'Sync operations are pending',
                                  ),
                          ),
                          subtitle: Text(
                            pending == 0
                                ? ghataT(
                                    context,
                                    'There are no pending or failed sync operations.',
                                  )
                                : ghataT(
                                    context,
                                    'Pending changes will sync when the connection is available.',
                                  ),
                          ),
                        ),
                      )
                    else
                      ...problems.asMap().entries.map((entry) {
                        final problem = entry.value;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${ghataT(context, 'Sync Problem')} ${entry.key + 1}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  const SizedBox(height: 12),
                                  diagnosticRow(
                                    ghataT(context, 'Operation'),
                                    problem['operation_type'],
                                  ),
                                  diagnosticRow(
                                    ghataT(context, 'Table'),
                                    problem['table_name'],
                                  ),
                                  diagnosticRow(
                                    ghataT(context, 'Record ID'),
                                    problem['record_id'],
                                  ),
                                  diagnosticRow(
                                    ghataT(context, 'Attempts'),
                                    problem['attempts'],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    ghataT(context, 'Error'),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  SelectableText(
                                    problem['last_error']
                                            ?.toString() ??
                                        ghataT(
                                          context,
                                          'Unknown error',
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                    if (loadError != null) ...[
                      const SizedBox(height: 16),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: SelectableText(
                            "${ghataT(context, 'Diagnostics error')}: $loadError",
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

class SecurityScreen extends StatefulWidget {
  SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  bool loading = true;

  Future<void> logOutOtherDevices() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ghataT(context, 'Log Out Other Devices')),
        content: Text(
          ghataT(
            context,
            'This will sign out your account from all other devices. This device will stay signed in.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(ghataT(context, 'Log Out')),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final user = Supabase.instance.client.auth.currentUser;

      if (user == null) return;

      final currentDeviceId =
          await GhataSecurity.deviceId();

      final now =
          DateTime.now().toUtc().toIso8601String();

      await Supabase.instance.client
          .from('user_devices')
          .update(
            <String, dynamic>{
              'revoked_at': now,
              'updated_at': now,
            },
          )
          .eq('user_id', user.id)
          .neq('device_id', currentDeviceId);

      await Supabase.instance.client.auth.signOut(
        scope: SignOutScope.others,
      );

      await ghataTouchCurrentDevice();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(
              context,
              'Other devices have been logged out successfully.',
            ),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(
              context,
              'Unable to log out other devices. Check your internet connection.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'Security')),
      ),
      body: ListView(
              padding: EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: Icon(Icons.devices_other_outlined),
                    title: Text(ghataT(context, 'Active Devices')),
                    subtitle: Text(
                      ghataT(context, 'View signed-in devices and log out a specific device.'),
                    ),
                    trailing: Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              const ActiveDevicesScreen(),
                        ),
                      );
                    },
                  ),
                ),
                SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: Icon(Icons.devices_outlined),
                    title: Text(
                      ghataT(context, 'Log Out Other Devices'),
                    ),
                    subtitle: Text(
                      ghataT(
                        context,
                        'Sign out your account from all other phones and devices.',
                      ),
                    ),
                    trailing: Icon(Icons.logout),
                    onTap: logOutOtherDevices,
                  ),
                ),
              ],
            ),
    );
  }
}

class GhataStartupGate extends StatefulWidget {
  GhataStartupGate({super.key});

  @override
  State<GhataStartupGate> createState() => _GhataStartupGateState();
}

class _GhataStartupGateState extends State<GhataStartupGate> {
  @override
  void initState() {
    super.initState();
    prepareStartup();
  }

  Future<void> prepareStartup() async {
    final user = Supabase.instance.client.auth.currentUser;

    if (user != null) {
      final localOwner = await GhataSecurity.localAccountOwner();
      final accountChanged =
          localOwner == null || localOwner != user.id;

      // Keep each account's offline data isolated.
      await GhataSecurity.setLocalAccountOwner(user.id);

      // Never block Windows startup on network/Supabase work.
      Future<void>(() async {
        if (!accountChanged) {
          await ghataTrySync();
        } else {
          await ghataRefreshOfflineCache();
        }
      });

      Future<void>(() async {
        try {
          await Supabase.instance.client.rpc('link_my_staff_account');
        } catch (_) {}
      });
    }

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<bool> canEditFuture;
  late Future<bool> canViewReportsFuture;

  Future<bool> loadCanEdit() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return false;

    final cached = await OfflineDatabase.instance.getRecord(
      'permission_cache',
      user.id,
      includeDeleted: true,
    );

    final localValue = cached?['can_edit'] == true;

    () async {
      try {
        final value =
            await Supabase.instance.client.rpc('can_staff_edit');

        final latest =
            await OfflineDatabase.instance.getRecord(
                  'permission_cache',
                  user.id,
                  includeDeleted: true,
                ) ??
                <String, dynamic>{};

        await OfflineDatabase.instance.saveRecord(
          'permission_cache',
          {
            ...latest,
            'id': user.id,
            'can_edit': value == true,
          },
          synced: true,
        );
      } catch (_) {}
    }();

    return localValue;
  }

  Future<bool> loadCanViewReports() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return false;

    final cached = await OfflineDatabase.instance.getRecord(
      'permission_cache',
      user.id,
      includeDeleted: true,
    );

    final localValue = cached?['can_view_reports'] == true;

    () async {
      try {
        final value =
            await Supabase.instance.client.rpc('can_staff_view_reports');

        final latest =
            await OfflineDatabase.instance.getRecord(
                  'permission_cache',
                  user.id,
                  includeDeleted: true,
                ) ??
                <String, dynamic>{};

        await OfflineDatabase.instance.saveRecord(
          'permission_cache',
          {
            ...latest,
            'id': user.id,
            'can_view_reports': value == true,
          },
          synced: true,
        );
      } catch (_) {}
    }();

    return localValue;
  }

  void refreshPermissions() {
    canEditFuture = loadCanEdit();
    canViewReportsFuture = loadCanViewReports();
  }

  late Future<Map<String, Map<String, double>>> dashboardFuture;
  late Future<List<Map<String, dynamic>>> recentTransactionsFuture;
  String selectedDashboardCurrency = 'ALL';
  String selectedRecentTransactionFilter = 'ALL';
  String selectedRecentCurrency = 'ALL';

  @override
  void initState() {
    super.initState();
    refreshPermissions();
    dashboardFuture = loadDashboardSummary();
    recentTransactionsFuture = loadRecentTransactions();
    ghataDataRevision.addListener(_handleRealtimeDataRevision);
  }

  void _handleRealtimeDataRevision() {
    if (!mounted) return;

    // Realtime sync already refreshed SQLite.
    // Re-read local data only; do not start another cloud refresh.
    setState(() {
      dashboardFuture = loadDashboardSummary(refreshCloud: false);
      recentTransactionsFuture =
          loadRecentTransactions(refreshCloud: false);
    });
  }

  @override
  void dispose() {
    ghataDataRevision.removeListener(_handleRealtimeDataRevision);
    super.dispose();
  }

  Future<Map<String, Map<String, double>>> loadDashboardSummary({
    bool refreshCloud = true,
  }) async {
    // Offline-first: show SQLite data immediately.
    // Supabase refresh runs in the background and must not block Dashboard.
    if (refreshCloud) ghataRefreshOfflineCache();

    final transactions =
        await OfflineDatabase.instance.getRecords('transactions');

    final exchangeEntries =
        await ghataLocalExchangeEntriesWithExchange();

    final result = <String, Map<String, double>>{};

    Map<String, double> values(String currency) {
      final code = currency.toUpperCase();
      return result.putIfAbsent(
        code,
        () => {
          'today_in': 0,
          'today_out': 0,
          'receive': 0,
          'pay': 0,
          'cashbox': 0,
        },
      );
    }

    // Customer Ledger balance:
    // Money In  = positive
    // Money Out = negative
    // Therefore:
    // positive customer balance -> You Receive
    // negative customer balance -> You Pay
    final customerBalances = <String, double>{};

    void changeCustomerBalance(
      String customerId,
      String currency,
      double delta,
    ) {
      if (customerId.isEmpty || currency.isEmpty || delta == 0) return;

      final code = currency.toUpperCase();
      final key = '$customerId|$code';

      customerBalances[key] =
          (customerBalances[key] ?? 0) + delta;
    }

    for (final raw in transactions) {
      final row = Map<String, dynamic>.from(raw);

      if (row['deleted_at'] != null) continue;

      final currency =
          (row['currency'] ?? '').toString().toUpperCase();
      if (currency.isEmpty) continue;

      final amount =
          double.tryParse((row['amount'] ?? 0).toString()) ?? 0;
      if (amount <= 0) continue;

      final type = (row['transaction_type'] ?? '').toString();
      final customerId = (row['customer_id'] ?? '').toString();
      final data = values(currency);

      // Dashboard Money In / Money Out cards keep their existing
      // business-level behavior and do not duplicate customer entries.
      if (customerId.isEmpty) {
        if (type == 'money_in') {
          data['today_in'] = data['today_in']! + amount;
        } else if (type == 'money_out') {
          data['today_out'] = data['today_out']! + amount;
        }
      }

      // Customer balance uses exactly the same sign convention
      // as calculateBalances() in Customer Details.
      if (customerId.isNotEmpty) {
        switch (type) {
          case 'money_in':
            changeCustomerBalance(
              customerId,
              currency,
              amount,
            );
            break;

          case 'money_out':
            changeCustomerBalance(
              customerId,
              currency,
              -amount,
            );
            break;
        }
      }

      // Cashbox accounting remains unchanged.
      switch (type) {
        case 'money_in':
        case 'adjustment_in':
          data['cashbox'] = data['cashbox']! + amount;
          break;

        case 'money_out':
        case 'adjustment_out':
          data['cashbox'] = data['cashbox']! - amount;
          break;
      }
    }

    // Exchange affects both Cashbox and the selected customer's
    // independent currency balances.
    for (final raw in exchangeEntries) {
      final row = Map<String, dynamic>.from(raw);
      final exchangeRaw = row['exchanges'];

      if (exchangeRaw == null) continue;

      Map<String, dynamic>? exchange;
      if (exchangeRaw is Map) {
        exchange = Map<String, dynamic>.from(exchangeRaw);
      }

      if (exchange == null || exchange['deleted_at'] != null) {
        continue;
      }

      final currency =
          (row['currency'] ?? '').toString().toUpperCase();
      if (currency.isEmpty) continue;

      final amount =
          double.tryParse((row['amount'] ?? 0).toString()) ?? 0;
      if (amount <= 0) continue;

      final type = (row['entry_type'] ?? '').toString();
      final data = values(currency);

      if (type == 'money_in') {
        data['cashbox'] = data['cashbox']! + amount;
      } else if (type == 'money_out') {
        data['cashbox'] = data['cashbox']! - amount;
      }

      final customerId =
          (exchange['customer_id'] ?? '').toString();

      if (customerId.isNotEmpty) {
        if (type == 'money_in') {
          changeCustomerBalance(
            customerId,
            currency,
            amount,
          );
        } else if (type == 'money_out') {
          changeCustomerBalance(
            customerId,
            currency,
            -amount,
          );
        }
      }
    }

    // Split every customer's FINAL currency balance separately.
    // Do not net different customers against each other.
    for (final entry in customerBalances.entries) {
      final parts = entry.key.split('|');
      if (parts.length < 2) continue;

      final currency = parts.last;
      final balance = entry.value;
      final data = values(currency);

      if (balance > 0.000001) {
        data['receive'] = data['receive']! + balance;
      } else if (balance < -0.000001) {
        data['pay'] = data['pay']! + balance.abs();
      }
    }

    return result;
  }

  Future<List<Map<String, dynamic>>> loadRecentTransactions({
    bool refreshCloud = true,
  }) async {
  final local =
      await OfflineDatabase.instance.getRecords(
    'transactions',
  );

  // Offline-first: refresh cloud cache without blocking this section.
  if (refreshCloud) ghataRefreshTransactionsCache();

  local.sort((a, b) {
    final ad =
        '${a['transaction_date'] ?? ''} ${a['transaction_time'] ?? ''} ${a['created_at'] ?? ''}';
    final bd =
        '${b['transaction_date'] ?? ''} ${b['transaction_time'] ?? ''} ${b['created_at'] ?? ''}';

    return bd.compareTo(ad);
  });

  final filtered = local.where((row) {
    final type = row['transaction_type']?.toString() ?? '';
    final currency =
        (row['currency'] ?? '').toString().toUpperCase();

    if (selectedRecentCurrency != 'ALL' &&
        currency != selectedRecentCurrency) {
      return false;
    }

    switch (selectedRecentTransactionFilter) {
      case 'MONEY_IN':
        return type == 'money_in' ||
            type == 'adjustment_in';

      case 'MONEY_OUT':
        return type == 'money_out' ||
            type == 'adjustment_out';
      case 'ADJUSTMENTS':
        return type == 'adjustment_in' ||
            type == 'adjustment_out';

      default:
        return true;
    }
  }).toList();

  return filtered.take(5).toList();
}

  String homeTransactionLabel(String type) {
    switch (type) {
      case 'money_in':
        return ghataT(context, 'Money In');
      case 'money_out':
        return ghataT(context, 'Money Out');
      case 'adjustment_in':
        return ghataT(context, 'Adjustment In');
      case 'adjustment_out':
        return ghataT(context, 'Adjustment Out');
      default:
        return type;
    }
  }

  Future<void> showHomeMenu() async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;

    if (overlay == null) return;

    const menuWidth = 320.0;
    const rightMargin = 8.0;

    final topPosition =
        MediaQuery.of(context).padding.top +
        kToolbarHeight +
        4;

    final leftPosition =
        overlay.size.width - menuWidth - rightMargin;

    final choice = await showMenu<String>(
      context: context,
      elevation: 14,
      color: Theme.of(context).colorScheme.surface,
      constraints: const BoxConstraints(
        minWidth: 290,
        maxWidth: menuWidth,
      ),
      position: RelativeRect.fromLTRB(
        leftPosition < 8 ? 8 : leftPosition,
        topPosition,
        rightMargin,
        8,
      ),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 54,
          child: Text(
            ghataT(context, 'Settings & Account'),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        PopupMenuItem<String>(
          value: 'profile',
          child: Row(
            children: [
              const Icon(Icons.person_outline),
              const SizedBox(width: 12),
              Text(ghataT(context, 'Profile & Business')),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'security',
          child: Row(
            children: [
              const Icon(Icons.security_outlined),
              const SizedBox(width: 12),
              Text(ghataT(context, 'Security')),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'staff',
          child: Row(
            children: [
              const Icon(Icons.groups_outlined),
              const SizedBox(width: 12),
              Text(ghataT(context, 'Staff & Roles')),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'backup',
          child: Row(
            children: [
              const Icon(Icons.cloud_outlined),
              const SizedBox(width: 12),
              Text(ghataT(context, 'Backup & Restore')),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'sync_status',
          child: Row(
            children: [
              const Icon(Icons.sync_outlined),
              const SizedBox(width: 12),
              Text(ghataT(context, 'Sync Status')),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'recycle',
          child: Row(
            children: [
              const Icon(Icons.delete_outline),
              const SizedBox(width: 12),
              Text(ghataT(context, 'Recycle Bin')),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'about',
          child: Row(
            children: [
              const Icon(Icons.info_outline_rounded),
              const SizedBox(width: 12),
              Text(ghataT(context, 'About Ghata')),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'logout',
          child: Row(
            children: [
              const Icon(Icons.logout),
              const SizedBox(width: 12),
              Text(ghataT(context, 'Sign Out')),
            ],
          ),
        ),
      ],
    );

    if (!mounted || choice == null) return;

    Widget? screen;

    if (choice == 'profile') {
      screen = ProfileScreen();
    } else if (choice == 'security') {
      screen = SecurityScreen();
    } else if (choice == 'staff') {
      screen = StaffManagementScreen();
    } else if (choice == 'backup') {
      screen = BackupRestoreScreen();
    } else if (choice == 'sync_status') {
      screen = const SyncDiagnosticsScreen();
    } else if (choice == 'recycle') {
      screen = RecycleBinScreen();
    } else if (choice == 'about') {
      screen = AboutGhataScreen();
    } else if (choice == 'logout') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(ghataT(context, 'Sign Out')),
          content: Text(
            'Are you sure you want to sign out?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(ghataT(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(ghataT(context, 'Sign Out')),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        await Supabase.instance.client.auth.signOut();
        if (!mounted) return;

        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) => LoginScreen(),
          ),
          (route) => false,
        );
      }
      return;
    }

    if (screen != null && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => screen!),
      );

      if (mounted) {
        refreshPermissions();
        refreshDashboard();
      }
    }
  }

  String amountText(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }

  String dashboardFlag(String code) {
    switch (code.toUpperCase()) {
      case 'AFN': return '🇦🇫';
      case 'USD': return '🇺🇸';
      case 'PKR': return '🇵🇰';
      case 'EUR': return '🇪🇺';
      case 'AED': return '🇦🇪';
      case 'SAR': return '🇸🇦';
      case 'KWD': return '🇰🇼';
      case 'QAR': return '🇶🇦';
      case 'OMR': return '🇴🇲';
      case 'GBP': return '🇬🇧';
      case 'IRR': return '🇮🇷';
      case 'INR': return '🇮🇳';
      case 'CNY': return '🇨🇳';
      case 'TRY': return '🇹🇷';
      case 'RUB': return '🇷🇺';
      case 'JPY': return '🇯🇵';
      case 'CAD': return '🇨🇦';
      default: return '💱';
    }
  }

  Color dashboardCurrencyColor(String code) {
    switch (code.toUpperCase()) {
      case 'AFN': return Colors.green;
      case 'USD': return Colors.blue;
      case 'PKR': return Colors.green;
      case 'EUR': return Colors.indigo;
      case 'AED': return Colors.orange;
      default: return Theme.of(context).colorScheme.primary;
    }
  }

  Widget summarySection(
    Map<String, Map<String, double>> data,
    String key,
    String title,
    IconData icon,
  ) {
    final availableDashboardCurrencies = data.entries
        .where((e) {
          final row = e.value;
          return (row['cashbox'] ?? 0).abs() > 0.000001 ||
              (row['today_in'] ?? 0).abs() > 0.000001 ||
              (row['today_out'] ?? 0).abs() > 0.000001 ||
              (row['receive'] ?? 0).abs() > 0.000001 ||
              (row['pay'] ?? 0).abs() > 0.000001;
        })
        .map((e) => e.key.toUpperCase())
        .toSet()
        .toList()
      ..sort();

    final effectiveDashboardCurrency =
        selectedDashboardCurrency == 'ALL' ||
                availableDashboardCurrencies.contains(
                  selectedDashboardCurrency,
                )
            ? selectedDashboardCurrency
            : 'ALL';

    final currencies = data.entries
        .where((e) => (e.value[key] ?? 0).abs() > 0.000001)
        .map((e) => e.key.toUpperCase())
        .where(
          (code) =>
              effectiveDashboardCurrency == 'ALL' ||
              code == effectiveDashboardCurrency,
        )
        .toList()
      ..sort();

    final isCashbox = key == 'cashbox';
    final isMoneyIn = key == 'today_in';
    final isMoneyOut = key == 'today_out';
    final isReceive = key == 'receive';

    final accent = isCashbox
        ? Theme.of(context).colorScheme.primary
        : isMoneyIn
            ? Colors.green
            : isMoneyOut
                ? Colors.red
                : isReceive
                    ? Colors.blue
                    : Colors.orange;

    final bg = accent.withValues(alpha: 0.08);

    return Container(
      margin: EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(isCashbox ? 13 : 9),
      decoration: BoxDecoration(
        color: isCashbox
            ? Theme.of(context).colorScheme.surface
            : bg,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: accent.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.13),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  isCashbox
                      ? '${ghataT(context, 'Cashbox')} (${ghataT(context, 'Total Balance')})'
                      : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isCashbox ? 17 : 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (isCashbox)
                  SizedBox(
                    width: 140,
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: effectiveDashboardCurrency,
                        isExpanded: true,
                        isDense: true,
                        borderRadius: BorderRadius.circular(14),
                        items: [
                          DropdownMenuItem<String>(
                            value: 'ALL',
                            child: Text(
                              ghataT(context, 'All Currencies'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          ...availableDashboardCurrencies.map(
                            (code) => DropdownMenuItem<String>(
                              value: code,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ghataCurrencyFlagWidget(code),
                                  SizedBox(width: 7),
                                  Text(code, maxLines: 1),
                                ],
                              ),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            selectedDashboardCurrency = value;
                          });
                        },
                      ),
                    ),
                  )
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 21,
                    color: accent,
                  ),
            ],
          ),
          SizedBox(height: isCashbox ? 9 : 6),

          if (currencies.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                ghataT(context, 'No balance'),
                style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant,
                ),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final itemWidth = isCashbox
                    ? (constraints.maxWidth < 380 ? 92.0 : 105.0)
                    : (constraints.maxWidth < 180 ? 66.0 : 78.0);

                return SizedBox(
                  height: isCashbox ? 92 : 66,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    physics: BouncingScrollPhysics(),
                    itemCount: currencies.length,
                    separatorBuilder: (_, __) => SizedBox(width: 6),
                    itemBuilder: (context, index) {
                      final code = currencies[index];
                      final value = data[code]?[key] ?? 0;
                      final c = dashboardCurrencyColor(code);

                      return Container(
                        width: itemWidth,
                        padding: EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: isCashbox ? 8 : 4,
                        ),
                        decoration: BoxDecoration(
                          color: isCashbox
                              ? c.withValues(alpha: 0.08)
                              : Theme.of(context)
                                  .colorScheme
                                  .surface
                                  .withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ghataCurrencyFlagWidget(
                              code,
                              width: isCashbox ? 28 : 24,
                              height: isCashbox ? 19 : 16,
                            ),
                            SizedBox(height: 2),
                            Text(
                              code,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: 2),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                amountText(value),
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: isCashbox ? 15 : 12,
                                  fontWeight: FontWeight.bold,
                                    color: isCashbox
                                        ? (value > 0
                                            ? Colors.green
                                            : value < 0
                                                ? Colors.red
                                                : Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant)
                                        : accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  void refreshDashboard() {
    setState(() {
      dashboardFuture = loadDashboardSummary();
      recentTransactionsFuture = loadRecentTransactions();
    });
  }


  Widget editPermissionButton(Widget child) {
    return FutureBuilder<bool>(
      future: canEditFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.data != true) {
          return SizedBox.shrink();
        }

        return child;
      },
    );
  }

  Widget reportsPermissionButton(Widget child) {
    return FutureBuilder<bool>(
      future: canViewReportsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.data != true) {
          return SizedBox.shrink();
        }

        return child;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final homeScaffold = Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: const Color(0xFF123D2B),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 42,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFBF2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Image.asset(
                  'assets/images/ghata_leaf.png',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'ګهته / Ghata',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    ghataT(context, 'Business Ledger & Accounting'),
                    style: const TextStyle(
                      color: Color(0xFFFFE8A3),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
        Directionality(
          textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            final appState =
                context.findAncestorStateOfType<_GhataAppState>();
            final isDark =
                Theme.of(context).brightness == Brightness.dark;

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PopupMenuButton<String>(
                  tooltip: ghataT(context, 'language'),
                  onSelected: appState?.changeLanguage,
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'en',
                      child: Row(
                        children: [
                          ghataLanguageFlagWidget('en'),
                          SizedBox(width: 8),
                          Text('English'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'ps',
                      child: Row(
                        children: [
                          ghataLanguageFlagWidget('ps'),
                          SizedBox(width: 8),
                          Text('پښتو'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'fa',
                      child: Row(
                        children: [
                          ghataLanguageFlagWidget('fa'),
                          SizedBox(width: 8),
                          Text('دری'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'ur',
                      child: Row(
                        children: [
                          ghataLanguageFlagWidget('ur'),
                          SizedBox(width: 8),
                          Text('اردو'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'ar',
                      child: Row(
                        children: [
                          ghataLanguageFlagWidget('ar'),
                          SizedBox(width: 8),
                          Text('العربية'),
                        ],
                      ),
                    ),
                  ],
                  icon: Icon(Icons.language_rounded),
                ),
                IconButton(
                  tooltip: isDark
                      ? ghataT(context, 'lightMode')
                      : ghataT(context, 'darkMode'),
                  onPressed: appState?.toggleTheme,
                  icon: Icon(
                    isDark
                        ? Icons.light_mode_rounded
                        : Icons.dark_mode_rounded,
                  ),
                ),
                IconButton(
                  tooltip: ghataT(context, 'Settings & Account'),
                  onPressed: showHomeMenu,
                  icon: Icon(Icons.menu_rounded),
                ),
                SizedBox(width: 4),
              ],
            );
          },
        ),
        ),
      ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            refreshDashboard();
            await dashboardFuture;
          },
          child: ListView(
            padding: EdgeInsets.symmetric(
              vertical: 16,
              horizontal: Platform.isWindows &&
                      MediaQuery.sizeOf(context).width > 1212
                  ? (MediaQuery.sizeOf(context).width - 1180) / 2
                  : 16,
            ),
            children: [
              FutureBuilder<Map<String, Map<String, double>>>(
                future: dashboardFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState ==
                      ConnectionState.waiting) {
                    return Padding(
                      padding: EdgeInsets.all(30),
                      child: Center(
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }

                  if (snapshot.hasError) {
                    return Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Could not load dashboard: ${snapshot.error}',
                        ),
                      ),
                    );
                  }

                  final data = snapshot.data ?? {};

                  return Column(
                    children: [
                      summarySection(
                        data,
                        'cashbox',
                        ghataT(context, 'Cashbox'),
                        Icons.account_balance_wallet_outlined,
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: summarySection(
                              data,
                              'today_in',
                              ghataT(context, 'Money In'),
                              Icons.south_west_rounded,
                            ),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: summarySection(
                              data,
                              'today_out',
                              ghataT(context, 'Money Out'),
                              Icons.north_east_rounded,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: summarySection(
                              data,
                              'receive',
                              ghataT(context, 'You Receive'),
                              Icons.call_received_rounded,
                            ),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: summarySection(
                              data,
                              'pay',
                              ghataT(context, 'You Pay'),
                              Icons.call_made_rounded,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),

              SizedBox(height: 4),

SizedBox(height: 22),

              Row(
                children: [
                  Expanded(
                    child: Text(
                      ghataT(context, 'Recent Transactions'),
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: ghataT(context, 'Filter'),
                    icon: Icon(
                      selectedRecentTransactionFilter == 'ALL'
                          ? Icons.filter_alt_outlined
                          : Icons.filter_alt_rounded,
                    ),
                    onSelected: (value) {
                      setState(() {
                        selectedRecentTransactionFilter = value;
                      });
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'ALL',
                        child: Text(ghataT(context, 'All')),
                      ),
                      PopupMenuItem(
                        value: 'MONEY_IN',
                        child: Text(ghataT(context, 'Money In')),
                      ),
                      PopupMenuItem(
                        value: 'MONEY_OUT',
                        child: Text(ghataT(context, 'Money Out')),
                      ),
                      PopupMenuItem(
                        value: 'ADJUSTMENTS',
                        child: Text(ghataT(context, 'Adjustments')),
                      ),
                    ],
                  ),
                    PopupMenuButton<String>(
                      tooltip: ghataT(context, 'Currency'),
                      icon: Icon(
                        selectedRecentCurrency == 'ALL'
                            ? Icons.payments_outlined
                            : Icons.payments_rounded,
                      ),
                      onSelected: (value) {
                        setState(() {
                          selectedRecentCurrency = value;
                        });
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem<String>(
                          value: 'ALL',
                          child: Text(
                            ghataT(context, 'All Currencies'),
                          ),
                        ),
                        ...[
                          'AFN',
                          'PKR',
                          'USD',
                          'EUR',
                          'GBP',
                          'AED',
                          'SAR',
                          'KWD',
                          'QAR',
                          'OMR',
                          'TRY',
                          'CNY',
                          'INR',
                          'IRR',
                        ].map(
                          (code) => PopupMenuItem<String>(
                            value: code,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ghataCurrencyFlagWidget(code),
                                SizedBox(width: 8),
                                Text(code),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  TextButton(
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              DailyJournalScreen(),
                        ),
                      );
                      refreshDashboard();
                    },
                    child: Text(ghataT(context, 'View All')),
                  ),
                ],
              ),

              SizedBox(height: 6),

              FutureBuilder<List<Map<String, dynamic>>>(
                future: recentTransactionsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState ==
                      ConnectionState.waiting) {
                    return Padding(
                      padding: EdgeInsets.all(18),
                      child: Center(
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }

                  final rows = snapshot.data ?? [];

                  if (rows.isEmpty) {
                    return Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Center(
                        child: Text(
                          ghataT(context, 'No transactions yet'),
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                    );
                  }

                  return Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outlineVariant,
                      ),
                    ),
                    child: Column(
                      children: [
                        ...rows.asMap().entries.map((entry) {
                          final index = entry.key;
                          final row = entry.value;

                          final type =
                              row['transaction_type']
                                      ?.toString() ??
                                  '';
                          final amount =
                              row['amount']?.toString() ?? '0';
                          final currency =
                              row['currency']?.toString() ?? '';
                          final customer =
                              row['customer_name']
                                      ?.toString() ??
                                  '';
                          final date =
                              row['transaction_date']
                                      ?.toString() ??
                                  '';

                          final incoming =
                              type == 'money_in' ||
                              type == 'adjustment_in';

                          final accent =
                              incoming ? Colors.green : Colors.red;

                          return Column(
                            children: [
                              InkWell(
                                borderRadius:
                                    BorderRadius.circular(16),
                                onTap: () async {
                                  final isExchange =
                                      row['_is_exchange'] == true;
                                  final transactionId =
                                      row['id']?.toString() ?? '';
                                  final exchangeId =
                                      row['exchange_id']?.toString() ?? '';

                                  if (isExchange &&
                                      exchangeId.isNotEmpty) {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ExchangeScreen(
                                          initialExchangeId: exchangeId,
                                        ),
                                      ),
                                    );
                                  } else if (transactionId.isNotEmpty) {
                                    await ghataShowTransactionReceipt(
                                      context,
                                      row,
                                    );
                                  }

                                  refreshDashboard();
                                },
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 11,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: accent.withValues(
                                            alpha: 0.10,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          incoming
                                              ? Icons
                                                  .south_west_rounded
                                              : Icons
                                                  .north_east_rounded,
                                          color: accent,
                                          size: 20,
                                        ),
                                      ),
                                      SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              customer.isNotEmpty
                                                  ? customer
                                                  : homeTransactionLabel(
                                                      type,
                                                    ),
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight:
                                                    FontWeight.w600,
                                              ),
                                            ),
                                            SizedBox(height: 3),
                                            Text(
                                              [
                                                homeTransactionLabel(
                                                  type,
                                                ),
                                                if (date.isNotEmpty)
                                                  date,
                                              ].join(' • '),
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            '$amount $currency',
                                            style: TextStyle(
                                              color: accent,
                                              fontSize: 13,
                                              fontWeight:
                                                  FontWeight.bold,
                                            ),
                                          ),
                                          SizedBox(height: 3),
                                          ghataCurrencyFlagWidget(
                                            currency,
                                            width: 24,
                                            height: 16,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (index != rows.length - 1)
                                Divider(height: 1),
                            ],
                          );
                        }),
                      ],
                    ),
                  );
                },
              ),

              SizedBox(height: 90),

            ],
          ),
        ),
      ),

      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              top: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: Platform.isWindows ? 900 : double.infinity,
              ),
              child: Row(
                children: [
              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.home_rounded,
                  label: ghataT(context, 'Home'),
                  selected: true,
                  onTap: () {
                    refreshDashboard();
                  },
                ),
              ),

              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.people_outline,
                  label: ghataT(context, 'Customers'),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CustomersScreen(),
                      ),
                    );
                    refreshDashboard();
                  },
                ),
              ),

              Expanded(
                child: FutureBuilder<bool>(
                  future: canEditFuture,
                  builder: (context, snapshot) {
                    final allowed = snapshot.data == true;

                    return _GhataBottomItem(
                      icon: Icons.add_circle,
                      label: ghataT(context, 'Add'),
                      prominent: true,
                      onTap: !allowed
                          ? null
                          : () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      DailyJournalScreen(
                                        openAddForm: true,
                                      ),
                                ),
                              );
                              refreshDashboard();
                            },
                    );
                  },
                ),
              ),

              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.menu_book_outlined,
                  label: ghataT(context, 'Daily Journal'),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            DailyJournalScreen(),
                      ),
                    );
                    refreshDashboard();
                  },
                ),
              ),

              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.currency_exchange_rounded,
                  label: ghataT(context, 'Exchange'),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ExchangeScreen(),
                      ),
                    );
                    refreshDashboard();
                  },
                ),
              ),

              Expanded(
                child: FutureBuilder<bool>(
                  future: canViewReportsFuture,
                  builder: (context, snapshot) {
                    return _GhataBottomItem(
                      icon: Icons.bar_chart_rounded,
                      label: ghataT(context, 'Reports'),
                      onTap: snapshot.data != true
                          ? null
                          : () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ReportsScreen(),
                                ),
                              );
                            },
                    );
                  },
                ),
              ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // Page content follows the selected language direction.
    // Header/navigation direction is controlled locally.
    return homeScaffold;

  }
}


class _GhataAppBottomNav extends StatefulWidget {
  final int selectedIndex;
  final VoidCallback? onAddHere;

  const _GhataAppBottomNav({
    super.key,
    required this.selectedIndex,
    this.onAddHere,
  });

  @override
  State<_GhataAppBottomNav> createState() =>
      _GhataAppBottomNavState();
}

class _GhataAppBottomNavState extends State<_GhataAppBottomNav> {
  late Future<List<bool>> permissionsFuture;

  @override
  void initState() {
    super.initState();
    permissionsFuture = loadPermissions();
  }

  Future<List<bool>> loadPermissions() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return [false, false];

    try {
      final results = await Future.wait([
        Supabase.instance.client.rpc('can_staff_edit'),
        Supabase.instance.client.rpc('can_staff_view_reports'),
      ]);

      final values = <bool>[
        results[0] == true,
        results[1] == true,
      ];

      await OfflineDatabase.instance.saveRecord(
        'permission_cache',
        {
          'id': user.id,
          'can_edit': values[0],
          'can_view_reports': values[1],
        },
        synced: true,
      );

      return values;
    } catch (_) {
      final cached = await OfflineDatabase.instance.getRecord(
        'permission_cache',
        user.id,
        includeDeleted: true,
      );

      return <bool>[
        cached?['can_edit'] == true,
        cached?['can_view_reports'] == true,
      ];
    }
  }

  void replaceWith(Widget screen) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: FutureBuilder<List<bool>>(
        future: permissionsFuture,
        builder: (context, snapshot) {
          final canEdit =
              snapshot.hasData && snapshot.data![0];
          final canReports =
              snapshot.hasData && snapshot.data![1];

          final nav = Row(
            children: [
              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.home_rounded,
                  label: ghataT(context, 'Home'),
                  selected: widget.selectedIndex == 0,
                  onTap: widget.selectedIndex == 0
                      ? () {}
                      : () => Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  HomeScreen(),
                            ),
                            (route) => false,
                          ),
                ),
              ),
              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.people_outline,
                  label: ghataT(context, 'Customers'),
                  selected: widget.selectedIndex == 1,
                  onTap: widget.selectedIndex == 1
                      ? () {}
                      : () => replaceWith(
                            CustomersScreen(),
                          ),
                ),
              ),
              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.add_circle,
                  label: ghataT(context, 'Add'),
                  prominent: true,
                  onTap: !canEdit
                      ? null
                      : () {
                          if (widget.onAddHere != null) {
                            widget.onAddHere!();
                          } else {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    DailyJournalScreen(
                                  openAddForm: true,
                                ),
                              ),
                            );
                          }
                        },
                ),
              ),
              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.menu_book_outlined,
                  label: ghataT(context, 'Daily Journal'),
                  selected: widget.selectedIndex == 3,
                  onTap: widget.selectedIndex == 3
                      ? () {}
                      : () => replaceWith(
                            DailyJournalScreen(),
                          ),
                ),
              ),
              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.currency_exchange_rounded,
                  label: ghataT(context, 'Exchange'),
                  selected: widget.selectedIndex == 4,
                  onTap: widget.selectedIndex == 4
                      ? () {}
                      : () => replaceWith(
                            ExchangeScreen(),
                          ),
                ),
              ),

              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.bar_chart_rounded,
                  label: ghataT(context, 'Reports'),
                  selected: widget.selectedIndex == 5,
                  onTap: !canReports
                      ? null
                      : widget.selectedIndex == 5
                          ? () {}
                          : () => replaceWith(
                                ReportsScreen(),
                              ),
                ),
              ),
            ],
          );

          if (!Platform.isWindows) {
            return nav;
          }

            return Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: nav,
                ),
              ),
            );
        },
      ),
    );
  }
}


class AboutGhataScreen extends StatelessWidget {
  const AboutGhataScreen({super.key});

  static const _green = Color(0xFF1F5A43);
  static const _softGreen = Color(0xFFE8F2EC);
  static const _cream = Color(0xFFFFFBF2);

  Future<void> _openUri(
    BuildContext context,
    Uri uri, {
    required String errorText,
  }) async {
    try {
      final opened = await launchUrl(uri);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorText)),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorText)),
        );
      }
    }
  }

  void _showTextDialog(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            child: Text(
              body,
              style: const TextStyle(height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(ghataT(context, 'Close')),
          ),
        ],
      ),
    );
  }

  Widget _sectionLink({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: _green.withValues(alpha: .10),
        ),
      ),
      child: ListTile(
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: _softGreen,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: _green),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }

  Widget _sectionCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _cream,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _green.withValues(alpha: .12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: _softGreen,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: _green),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _green,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _appInformation(BuildContext context) {
    return _sectionCard(
      context: context,
      icon: Icons.info_outline_rounded,
      title: ghataT(context, 'App Information'),
      children: [
        _sectionLink(
          context: context,
          icon: Icons.account_balance_wallet_outlined,
          title: ghataT(context, 'About Ghata'),
          subtitle: ghataT(context, 'Learn more about Ghata'),
          onTap: () => _showTextDialog(
            context,
            title: ghataT(context, 'About Ghata'),
            body: ghataT(context, 'About Ghata description'),
          ),
        ),
        _sectionLink(
          context: context,
          icon: Icons.menu_book_outlined,
          title: ghataT(context, 'How to Use Ghata'),
          subtitle: ghataT(context, 'Learn the main Ghata features'),
          onTap: () => _showTextDialog(
            context,
            title: ghataT(context, 'How to Use Ghata'),
            body: ghataT(context, 'How to Use Ghata description'),
          ),
        ),
        _sectionLink(
          context: context,
          icon: Icons.verified_outlined,
          title: ghataT(context, 'Version'),
          subtitle: '1.0.0',
          onTap: () => _showTextDialog(
            context,
            title: ghataT(context, 'Version'),
            body: 'Ghata Version 1.0.0',
          ),
        ),
      ],
    );
  }

  Widget _contactUs(BuildContext context) {
    return _sectionCard(
      context: context,
      icon: Icons.support_agent_rounded,
      title: ghataT(context, 'Contact Us'),
      children: [
        _sectionLink(
          context: context,
          icon: Icons.chat_rounded,
          title: ghataT(context, 'WhatsApp Support'),
          subtitle: '+93 771 770 927',
          onTap: () => _openUri(
            context,
            Uri.parse('https://wa.me/93771770927'),
            errorText: ghataT(context, 'Unable to open WhatsApp.'),
          ),
        ),
        _sectionLink(
          context: context,
          icon: Icons.chat_outlined,
          title: 'WhatsApp 2',
          subtitle: '+93 774 832 595',
          onTap: () => _openUri(
            context,
            Uri.parse('https://wa.me/93774832595'),
            errorText: ghataT(context, 'Unable to open WhatsApp.'),
          ),
        ),
        _sectionLink(
          context: context,
          icon: Icons.email_outlined,
          title: ghataT(context, 'Email Support'),
          subtitle: 'rahemsadafghata@gmail.com',
          onTap: () => _openUri(
            context,
            Uri(
              scheme: 'mailto',
              path: 'rahemsadafghata@gmail.com',
            ),
            errorText: ghataT(
              context,
              'Something went wrong. Please try again.',
            ),
          ),
        ),
        _sectionLink(
          context: context,
          icon: Icons.help_outline_rounded,
          title: ghataT(context, 'FAQ'),
          subtitle: ghataT(context, 'Frequently asked questions'),
          onTap: () => _showTextDialog(
            context,
            title: ghataT(context, 'FAQ'),
            body: [
              for (var i = 1; i <= 8; i++)
                '${ghataT(context, 'FAQ Q$i')}\n${ghataT(context, 'FAQ A$i')}',
            ].join('\n\n'),
          ),
        ),
      ],
    );
  }

  Widget _privacy(BuildContext context) {
    return _sectionCard(
      context: context,
      icon: Icons.privacy_tip_outlined,
      title: ghataT(context, 'Privacy'),
      children: [
        _sectionLink(
          context: context,
          icon: Icons.policy_outlined,
          title: ghataT(context, 'Privacy Policy'),
          subtitle: ghataT(context, 'How Ghata handles your information'),
          onTap: () => _showTextDialog(
            context,
            title: ghataT(context, 'Privacy Policy'),
            body: ghataT(context, 'Privacy Policy description'),
          ),
        ),
        _sectionLink(
          context: context,
          icon: Icons.security_rounded,
          title: ghataT(context, 'Data Security'),
          subtitle: ghataT(context, 'Account and data protection'),
          onTap: () => _showTextDialog(
            context,
            title: ghataT(context, 'Data Security'),
            body: ghataT(context, 'Data Security description'),
          ),
        ),
        _sectionLink(
          context: context,
          icon: Icons.storage_rounded,
          title: ghataT(context, 'Data Storage'),
          subtitle: ghataT(context, 'Where Ghata data is stored'),
          onTap: () => _showTextDialog(
            context,
            title: ghataT(context, 'Data Storage'),
            body: ghataT(context, 'Data Storage description'),
          ),
        ),
        _sectionLink(
          context: context,
          icon: Icons.description_outlined,
          title: ghataT(context, 'Terms of Use'),
          subtitle: ghataT(context, 'Rules for using Ghata'),
          onTap: () => _showTextDialog(
            context,
            title: ghataT(context, 'Terms of Use'),
            body: ghataT(context, 'Terms of Use description'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'About Ghata')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 285),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(26),
                      boxShadow: [
                        BoxShadow(
                          color: _green.withValues(alpha: .16),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          child: Image.asset(
                            'assets/images/about_accounting.png',
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  const Color(0xFF123D2B)
                                      .withValues(alpha: .94),
                                  const Color(0xFF1F5A43)
                                      .withValues(alpha: .82),
                                  const Color(0xFF9A7B32)
                                      .withValues(alpha: .56),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 28,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 92,
                                height: 92,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFFBF2)
                                      .withValues(alpha: .96),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black
                                          .withValues(alpha: .16),
                                      blurRadius: 18,
                                      offset: const Offset(0, 6),
                                    ),
                                  ],
                                ),
                                child: Image.asset(
                                  'assets/images/ghata_leaf.png',
                                  fit: BoxFit.contain,
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'ګهته',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const Text(
                                'Ghata',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF1C7)
                                      .withValues(alpha: .94),
                                  borderRadius: BorderRadius.circular(30),
                                ),
                                child: Text(
                                  '${ghataT(context, 'Version')} 1.0.0',
                                  style: const TextStyle(
                                    color: Color(0xFF123D2B),
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                ghataT(
                                  context,
                                  'Simple Accounting for a Better Tomorrow',
                                ),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final cards = <Widget>[
                        _appInformation(context),
                        _contactUs(context),
                        _privacy(context),
                      ];

                      if (constraints.maxWidth < 900) {
                        return Column(
                          children: [
                            for (var i = 0; i < cards.length; i++) ...[
                              cards[i],
                              if (i != cards.length - 1)
                                const SizedBox(height: 16),
                            ],
                          ],
                        );
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: cards[0]),
                          const SizedBox(width: 16),
                          Expanded(child: cards[1]),
                          const SizedBox(width: 16),
                          Expanded(child: cards[2]),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: _softGreen,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.favorite_rounded,
                          color: _green,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          ghataT(context, 'Thank you for using Ghata!'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: _green,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Design by MRS',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _green,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Mohammad Rahem Sadaf',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _green,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GhataBottomItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final bool prominent;

  const _GhataBottomItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.prominent = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: 8,
          horizontal: 2,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: prominent ? 34 : 24,
              color: !enabled
                  ? Colors.grey
                  : selected || prominent
                      ? Theme.of(context).colorScheme.primary
                      : null,
            ),
            SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight:
                    selected ? FontWeight.bold : FontWeight.normal,
                color: enabled ? null : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NewPasswordScreen extends StatefulWidget {
  NewPasswordScreen({super.key});

  @override
  State<NewPasswordScreen> createState() => _NewPasswordScreenState();
}

class _NewPasswordScreenState extends State<NewPasswordScreen> {
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  bool hidePassword = true;
  bool hideConfirmPassword = true;
  bool isLoading = false;

  Future<void> updatePassword() async {
    final password = passwordController.text;
    final confirmPassword = confirmPasswordController.text;

    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Password must be at least 6 characters')),
        ),
      );
      return;
    }

    if (password != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Passwords do not match'))),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: password),
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Password changed successfully.')),
        ),
      );

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => HomeScreen()),
        (route) => false,
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'New Password')),
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            children: [
              SizedBox(height: 30),
              Icon(
                Icons.password_rounded,
                size: 76,
                color: Colors.blue,
              ),
              SizedBox(height: 24),
              TextField(
                controller: passwordController,
                obscureText: hidePassword,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'New Password'),
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                  suffixIcon: IconButton(
                    onPressed: () {
                      setState(() => hidePassword = !hidePassword);
                    },
                    icon: Icon(
                      hidePassword
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 16),
              TextField(
                controller: confirmPasswordController,
                obscureText: hideConfirmPassword,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Confirm New Password'),
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                  suffixIcon: IconButton(
                    onPressed: () {
                      setState(
                        () => hideConfirmPassword = !hideConfirmPassword,
                      );
                    },
                    icon: Icon(
                      hideConfirmPassword
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: isLoading ? null : updatePassword,
                  child: isLoading
                      ? CircularProgressIndicator()
                      : Text(ghataT(context, 'Change Password')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final fullNameController = TextEditingController();
  final usernameController = TextEditingController();
  final businessNameController = TextEditingController();
  final businessPhoneController = TextEditingController();
  final businessAddressController = TextEditingController();
  final receiptNoteController = TextEditingController();

  bool isLoading = true;
  bool isSaving = false;
  bool isPhotoSaving = false;
  String email = '';
  String? profilePhotoPath;

  @override
  void initState() {
    super.initState();
    loadProfile();
  }

  Future<void> loadProfile() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;

      if (user == null) {
        throw Exception('Not logged in');
      }

      final data = await ghataLoadBusinessProfile();
      final loadedProfilePhoto =
          await ghataLoadProfilePhoto(
        onBackgroundLoaded: (localPath) {
          if (!mounted) return;
          setState(() {
            profilePhotoPath = localPath;
          });
        },
      );

      if (!mounted) return;

      if (data != null) {
        fullNameController.text = data['full_name'] ?? '';
        usernameController.text = data['username'] ?? '';
        businessNameController.text = data['business_name'] ?? '';
        businessPhoneController.text = data['business_phone'] ?? '';
        businessAddressController.text = data['business_address'] ?? '';
        receiptNoteController.text = data['receipt_note'] ?? '';
      }

      setState(() {
        email = user.email ?? '';
        if (loadedProfilePhoto != null &&
            loadedProfilePhoto.isNotEmpty) {
          profilePhotoPath = loadedProfilePhoto;
        }
        isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() => isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Unable to load profile')),
        ),
      );
    }
  }

  Future<void> changeProfilePhoto() async {
    if (isPhotoSaving) return;

    final picked =
        await ghataPickCustomerPhoto(context);

    if (picked == null || !mounted) return;

    setState(() => isPhotoSaving = true);

    try {
      final saved =
          await ghataSaveProfilePhoto(picked);

      if (!mounted) return;

      if (saved == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ghataT(
                context,
                'Unable to save photo',
              ),
            ),
          ),
        );
        return;
      }

      setState(() {
        profilePhotoPath = saved;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(
              context,
              'Profile photo updated',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isPhotoSaving = false);
      }
    }
  }

  Future<void> removeProfilePhoto() async {
    if (isPhotoSaving) return;

    setState(() => isPhotoSaving = true);

    try {
      await ghataDeleteProfilePhoto();

      if (!mounted) return;

      setState(() {
        profilePhotoPath = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(
              context,
              'Profile photo removed',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isPhotoSaving = false);
      }
    }
  }

  Future<void> saveProfile() async {
    final fullName = fullNameController.text.trim();
    final username = usernameController.text.trim();

    if (fullName.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Please complete all fields'))),
      );
      return;
    }

    setState(() => isSaving = true);

    try {
      await Supabase.instance.client.rpc(
        'update_my_profile',
        params: {
          'new_full_name': fullName,
          'new_username': username,
        },
      );

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('Not logged in');

        await Supabase.instance.client.rpc(
          'update_my_business_profile',
          params: {
            'new_business_name': businessNameController.text.trim(),
            'new_business_phone': businessPhoneController.text.trim(),
            'new_business_address': businessAddressController.text.trim(),
            'new_receipt_note': receiptNoteController.text.trim(),
          },
        );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Profile updated successfully'))),
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) {
        setState(() => isSaving = false);
      }
    }
  }


  Future<void> deleteAccount() async {
    final firstConfirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ghataT(context, 'Delete Account?')),
        content: Text(
          ghataT(
            context,
            'This permanently deletes your Ghata account and cloud accounting data. This cannot be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(ghataT(context, 'Delete Account')),
          ),
        ],
      ),
    );

    if (firstConfirm != true || !mounted) return;

    final finalConfirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ghataT(context, 'Are you absolutely sure?')),
        content: Text(
          ghataT(
            context,
            'This permanently deletes your Ghata account and cloud accounting data. This cannot be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(ghataT(context, 'Delete Permanently')),
          ),
        ],
      ),
    );

    if (finalConfirm != true || !mounted) return;

    setState(() => isSaving = true);

    try {
      await Supabase.instance.client.rpc('delete_my_account');

      await OfflineDatabase.instance.clearAllLocalData();

      try {
        await Supabase.instance.client.auth.signOut();
      } catch (_) {}

      if (!mounted) return;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => LoginScreen()),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "${ghataT(context, 'Unable to delete account')}: $e",
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isSaving = false);
      }
    }
  }

  @override
  void dispose() {
    fullNameController.dispose();
    usernameController.dispose();
    businessNameController.dispose();
    businessPhoneController.dispose();
    businessAddressController.dispose();
    receiptNoteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'Profile')),
      ),
      body: isLoading
          ? Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: EdgeInsets.all(24),
                children: [
                  Center(
                    child: Column(
                      children: [
                        GestureDetector(
                          onTap: isPhotoSaving
                              ? null
                              : changeProfilePhoto,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              CircleAvatar(
                                radius: 48,
                                backgroundImage:
                                    profilePhotoPath != null &&
                                            profilePhotoPath!
                                                .isNotEmpty
                                        ? FileImage(
                                            File(
                                              profilePhotoPath!,
                                            ),
                                          )
                                        : null,
                                child:
                                    profilePhotoPath == null ||
                                            profilePhotoPath!
                                                .isEmpty
                                        ? Icon(
                                            Icons.person,
                                            size: 48,
                                          )
                                        : null,
                              ),
                              Positioned(
                                right: -2,
                                bottom: -2,
                                child: CircleAvatar(
                                  radius: 16,
                                  child: isPhotoSaving
                                      ? SizedBox(
                                          width: 16,
                                          height: 16,
                                          child:
                                              CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Icon(
                                          Icons.camera_alt_rounded,
                                          size: 17,
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: 8),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: isPhotoSaving
                                  ? null
                                  : changeProfilePhoto,
                              icon: Icon(
                                Icons.photo_library_outlined,
                              ),
                              label: Text(
                                ghataT(
                                  context,
                                  'Change Photo',
                                ),
                              ),
                            ),
                            if (profilePhotoPath != null &&
                                profilePhotoPath!.isNotEmpty)
                              TextButton.icon(
                                onPressed: isPhotoSaving
                                    ? null
                                    : removeProfilePhoto,
                                icon: Icon(
                                  Icons.delete_outline,
                                  color: Colors.red,
                                ),
                                label: Text(
                                  ghataT(
                                    context,
                                    'Remove Photo',
                                  ),
                                  style: TextStyle(
                                    color: Colors.red,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 22),
                  TextField(
                    controller: fullNameController,
                    decoration: InputDecoration(
                      labelText: ghataT(context, 'Full Name'),
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: usernameController,
                    decoration: InputDecoration(
                      labelText: ghataT(context, 'Username'),
                      prefixIcon: Icon(Icons.alternate_email),
                      border: OutlineInputBorder(),
                      helperText: ghataT(context, 'Username can be changed every 30 days'),
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    readOnly: true,
                    controller: TextEditingController(text: email),
                    decoration: InputDecoration(
                      labelText: ghataT(context, 'Email'),
                      prefixIcon: Icon(Icons.email_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 28),
                  Text(ghataT(context, 'Business Profile'),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: businessNameController,
                    decoration: InputDecoration(
                      labelText: ghataT(context, 'Business Name'),
                      prefixIcon: Icon(Icons.store_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: businessPhoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: ghataT(context, 'Business Phone'),
                      prefixIcon: Icon(Icons.phone_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: businessAddressController,
                    decoration: InputDecoration(
                      labelText: ghataT(context, 'Business Address'),
                      prefixIcon: Icon(Icons.location_on_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: receiptNoteController,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: ghataT(context, 'Receipt Note'),
                      hintText: ghataT(context, 'Thank you for your business'),
                      prefixIcon: Icon(Icons.notes_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 24),
                  SizedBox(height: 24),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: isSaving ? null : saveProfile,
                      child: isSaving
                          ? CircularProgressIndicator()
                          : Text(ghataT(context, 'Save Changes')),
                    ),
                  ),
                  SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      icon: Icon(Icons.email_outlined),
                      label: Text(ghataT(context, 'Change Email')),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChangeEmailScreen(),
                          ),
                        );
                      },
                    ),
                  ),

                  SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                      icon: Icon(Icons.delete_forever_outlined),
                      label: Text(ghataT(context, 'Delete Account')),
                      onPressed: isSaving ? null : deleteAccount,
                    ),
                  ),

                ],
              ),
            ),
    );
  }
}

class ChangeEmailScreen extends StatefulWidget {
  ChangeEmailScreen({super.key});

  @override
  State<ChangeEmailScreen> createState() => _ChangeEmailScreenState();
}

class _ChangeEmailScreenState extends State<ChangeEmailScreen> {
  final emailController = TextEditingController();
  bool isLoading = false;

  Future<void> changeEmail() async {
    final newEmail = emailController.text.trim();

    if (newEmail.isEmpty || !newEmail.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Please enter a valid email'))),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(email: newEmail),
        emailRedirectTo: 'com.rahemsadaf.ghata://email-change',
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Verification email sent. Please check your email.',
          ),
        ),
      );
    } on AuthException catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentEmail =
        Supabase.instance.client.auth.currentUser?.email ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'Change Email')),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(24),
          children: [
            SizedBox(height: 20),
            Text(
              "${ghataT(context, 'New Email')}: $currentEmail",
            ),
            SizedBox(height: 24),
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: ghataT(context, 'New Email'),
                prefixIcon: Icon(Icons.email_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: isLoading ? null : changeEmail,
                child: isLoading
                    ? CircularProgressIndicator()
                    : Text(ghataT(context, 'Change Email')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RecycleBinScreen extends StatefulWidget {
  RecycleBinScreen({super.key});

  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {

  late Future<List<dynamic>> recycleBinFuture;

  @override
  void initState() {
    super.initState();
    recycleBinFuture = _loadRecycleBin();
    ghataDataRevision.addListener(_handleRealtimeDataRevision);
  }

  Future<List<dynamic>> _loadRecycleBin({
    bool refreshCloud = true,
  }) async {
    if (refreshCloud) {
      ghataRefreshOfflineCache();
    }

    return Future.wait([
      loadDeletedCustomers(refreshCloud: false),
      loadDeletedTransactions(refreshCloud: false),
      loadDeletedExchanges(refreshCloud: false),
    ]);
  }

  void _handleRealtimeDataRevision() {
    if (!mounted) return;

    setState(() {
      recycleBinFuture = _loadRecycleBin(refreshCloud: false);
    });
  }

  void _refreshRecycleBinLocal() {
    if (!mounted) return;

    setState(() {
      recycleBinFuture = _loadRecycleBin(refreshCloud: false);
    });
  }

  @override
  void dispose() {
    ghataDataRevision.removeListener(_handleRealtimeDataRevision);
    super.dispose();
  }

  bool _selectionMode = false;
  final Set<String> _selectedRecycleItems = <String>{};

  String _recycleKey(String table, String id) => '$table:$id';

  void _toggleRecycleSelection(String table, String id, bool selected) {
    setState(() {
      final key = _recycleKey(table, id);
      if (selected) {
        _selectedRecycleItems.add(key);
      } else {
        _selectedRecycleItems.remove(key);
      }
    });
  }

  Future<List<Map<String, dynamic>>> loadDeletedCustomers({
    bool refreshCloud = true,
  }) async {
  if (refreshCloud) ghataRefreshOfflineCache();

  final local = await OfflineDatabase.instance.getRecords(
    'customers',
    includeDeleted: true,
  );

  final deleted = local.where((row) {
    return row['deleted_at'] != null &&
        row['purged_at'] == null;
  }).toList();

  deleted.sort(
    (a, b) => (b['deleted_at']?.toString() ?? '')
        .compareTo(a['deleted_at']?.toString() ?? ''),
  );

  return deleted;
}

  Future<List<Map<String, dynamic>>> loadDeletedTransactions({
    bool refreshCloud = true,
  }) async {
  if (refreshCloud) ghataRefreshOfflineCache();

  final local = await OfflineDatabase.instance.getRecords(
    'transactions',
    includeDeleted: true,
  );

  final deleted = local.where((row) {
    return row['deleted_at'] != null &&
        row['purged_at'] == null;
  }).toList();

  deleted.sort(
    (a, b) => (b['deleted_at']?.toString() ?? '')
        .compareTo(a['deleted_at']?.toString() ?? ''),
  );

  return deleted;
}

  Future<void> restoreTransaction(String id) async {
  try {
    await OfflineDatabase.instance.restoreLocalRecord(
      'transactions',
      id,
    );

    ghataScheduleAutomaticBackup();
    ghataTrySync();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ghataT(context, 'Transaction restored successfully.')),
      ),
    );

    _refreshRecycleBinLocal();
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("${ghataT(context, 'Unable to restore transaction')}: $e"),
      ),
    );
  }
}

  Future<List<Map<String, dynamic>>> loadDeletedExchanges({
    bool refreshCloud = true,
  }) async {
  if (refreshCloud) ghataRefreshOfflineCache();

  final local = await OfflineDatabase.instance.getRecords(
    'exchanges',
    includeDeleted: true,
  );

  final deleted = local.where((row) {
    return row['deleted_at'] != null &&
        row['purged_at'] == null;
  }).toList();

  deleted.sort(
    (a, b) => (b['deleted_at']?.toString() ?? '')
        .compareTo(a['deleted_at']?.toString() ?? ''),
  );

  return deleted;
}

  Future<void> restoreExchange(String id) async {
  try {
    await OfflineDatabase.instance.restoreLocalRecord(
      'exchanges',
      id,
    );

    ghataScheduleAutomaticBackup();
    ghataTrySync();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ghataT(context, 'Exchange restored successfully.')),
      ),
    );

    _refreshRecycleBinLocal();
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("${ghataT(context, 'Unable to restore exchange')}: $e"),
      ),
    );
  }
}

  Future<void> permanentlyDeleteExchangeData(String exchangeId) async {
    final entries = await OfflineDatabase.instance.getRecords(
      'exchange_entries',
      includeDeleted: true,
    );

    for (final entry in entries) {
      if (entry['exchange_id']?.toString() != exchangeId) continue;

      final entryId = entry['id']?.toString() ?? '';
      if (entryId.isEmpty) continue;

      await OfflineDatabase.instance.permanentlyDeleteLocalRecord(
        'exchange_entries',
        entryId,
      );
    }

    await OfflineDatabase.instance.permanentlyDeleteLocalRecord(
      'exchanges',
      exchangeId,
    );
  }

  Future<void> permanentlyDeleteExchange(
    String id,
    String label,
    String? deletedAt,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ghataT(context, 'Delete Permanently?')),
        content: Text(
          'Permanently delete $label? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(ghataT(context, 'Delete Permanently')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await permanentlyDeleteExchangeData(id);

      ghataScheduleAutomaticBackup();
      ghataTrySync();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Exchange removed from Recycle Bin.'))),
      );

      _refreshRecycleBinLocal();
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to permanently delete exchange')}: $e"),
        ),
      );
    }
  }

  int daysRemaining(String? deletedAt) {
    final deleted = DateTime.tryParse(deletedAt ?? '');
    if (deleted == null) return 30;

    final expires = deleted.add(Duration(days: 30));
    final remaining = expires.difference(DateTime.now().toUtc()).inDays + 1;

    if (remaining < 0) return 0;
    if (remaining > 30) return 30;
    return remaining;
  }

  Future<void> restoreCustomer(String id) async {
  try {
    await OfflineDatabase.instance.restoreLocalRecord(
      'customers',
      id,
    );

    ghataScheduleAutomaticBackup();
    ghataTrySync();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ghataT(context, 'Customer restored successfully.')),
      ),
    );

    _refreshRecycleBinLocal();
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("${ghataT(context, 'Unable to restore customer')}: $e"),
      ),
    );
  }
}

  Future<void> permanentlyDeleteCustomer(
    String id,
    String name,
    String? deletedAt,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ghataT(context, 'Delete Permanently?')),
        content: Text(
          'Permanently delete $name? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(ghataT(context, 'Delete Permanently')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ghataDeleteCustomerPhoto(id);

      await OfflineDatabase.instance
          .permanentlyDeleteLocalRecord(
        'customers',
        id,
      );

      ghataScheduleAutomaticBackup();
      ghataTrySync();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Customer removed from Recycle Bin.'))),
      );

      _refreshRecycleBinLocal();
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${ghataT(context, 'Unable to permanently delete customer')}: $e")),
      );
    }
  }

  Future<void> permanentlyDeleteTransaction(
    String id,
    String label,
    String? deletedAt,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ghataT(context, 'Delete Permanently?')),
        content: Text(
          'Permanently delete $label? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(ghataT(context, 'Delete Permanently')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await OfflineDatabase.instance.permanentlyDeleteLocalRecord(
        'transactions',
        id,
      );

      ghataScheduleAutomaticBackup();
      ghataTrySync();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Transaction removed from Recycle Bin.')),
        ),
      );

      _refreshRecycleBinLocal();
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to permanently delete transaction')}: $e"),
        ),
      );
    }
  }

  Future<void> _deleteRecycleBatch({
    required bool selectedOnly,
  }) async {
    final customers =
        await loadDeletedCustomers(refreshCloud: false);
    final transactions =
        await loadDeletedTransactions(refreshCloud: false);
    final exchanges =
        await loadDeletedExchanges(refreshCloud: false);

    bool wanted(String table, Map<String, dynamic> row) {
      final id = row['id']?.toString() ?? '';
      if (id.isEmpty) return false;
      if (!selectedOnly) return true;
      return _selectedRecycleItems.contains(_recycleKey(table, id));
    }

    final selectedCustomers =
        customers.where((row) => wanted('customers', row)).toList();
    final selectedTransactions =
        transactions.where((row) => wanted('transactions', row)).toList();
    final selectedExchanges =
        exchanges.where((row) => wanted('exchanges', row)).toList();

    final total = selectedCustomers.length +
        selectedTransactions.length +
        selectedExchanges.length;

    if (total == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'No items selected.'))),
      );
      return;
    }

    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          ghataT(
            context,
            selectedOnly ? 'Delete Selected' : 'Delete All',
          ),
        ),
        content: Text(
          ghataT(
            context,
            selectedOnly
                ? 'Delete selected items permanently? This cannot be undone.'
                : 'Delete all items permanently? This cannot be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              ghataT(
                context,
                selectedOnly ? 'Delete Selected' : 'Delete All',
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      for (final customer in selectedCustomers) {
        final id = customer['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        await ghataDeleteCustomerPhoto(id);
        await OfflineDatabase.instance.permanentlyDeleteLocalRecord(
          'customers',
          id,
        );
      }

      for (final transaction in selectedTransactions) {
        final id = transaction['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        await OfflineDatabase.instance.permanentlyDeleteLocalRecord(
          'transactions',
          id,
        );
      }

      for (final exchange in selectedExchanges) {
        final id = exchange['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        await permanentlyDeleteExchangeData(id);
      }

      ghataScheduleAutomaticBackup();

      ghataTrySync();

      if (!mounted) return;

      setState(() {
        _selectedRecycleItems.clear();
        _selectionMode = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(
              context,
              selectedOnly
                  ? 'Selected items deleted permanently.'
                  : 'Recycle Bin cleared.',
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${ghataT(context, selectedOnly ? 'Unable to delete selected items' : 'Unable to clear Recycle Bin')}: $e',
          ),
        ),
      );
    }
  }

  Future<void> _deleteAllRecycleBin() async {
    await _deleteRecycleBatch(selectedOnly: false);
  }

  Future<void> _deleteSelectedRecycleBin() async {
    await _deleteRecycleBatch(selectedOnly: true);
  }

  @override
  Widget build(BuildContext context) {
      return Scaffold(
        appBar: AppBar(
          title: Text(ghataT(context, 'Recycle Bin')),
          actions: [
            IconButton(
              tooltip: ghataT(
                context,
                _selectionMode ? 'Cancel Selection' : 'Select',
              ),
              icon: Icon(
                _selectionMode ? Icons.close : Icons.checklist,
              ),
              onPressed: () {
                setState(() {
                  _selectionMode = !_selectionMode;
                  if (!_selectionMode) {
                    _selectedRecycleItems.clear();
                  }
                });
              },
            ),
            IconButton(
              tooltip: ghataT(context, 'Delete All'),
              icon: Icon(Icons.delete_sweep_outlined),
              onPressed: _deleteAllRecycleBin,
            ),
          ],
        ),
        body: FutureBuilder<List<dynamic>>(
          future: recycleBinFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text("${ghataT(context, 'Unable to load Recycle Bin')}: ${snapshot.error}"),
                ),
              );
            }

            final data = snapshot.data ?? [];
            final customers = data.isNotEmpty
                ? List<Map<String, dynamic>>.from(data[0])
                : <Map<String, dynamic>>[];
            final transactions = data.length > 1
                ? List<Map<String, dynamic>>.from(data[1])
                : <Map<String, dynamic>>[];
            final exchanges = data.length > 2
                ? List<Map<String, dynamic>>.from(data[2])
                : <Map<String, dynamic>>[];

            if (customers.isEmpty &&
                transactions.isEmpty &&
                exchanges.isEmpty) {
              return Center(
                child: Text(ghataT(context, 'Recycle Bin is empty.')),
              );
            }

            return ListView(
              padding: EdgeInsets.all(16),
              children: [
                if (customers.isNotEmpty) ...[
                  Text(
                    'Customers',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  ...customers.map((customer) {
                    final id = customer['id']?.toString() ?? '';
                    final name =
                        customer['full_name']?.toString() ?? 'Customer';
                    final address = customer['address']?.toString() ?? '';
                    final remaining =
                        daysRemaining(customer['deleted_at']?.toString());

                    return Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_selectionMode)
                              Checkbox(
                                value: _selectedRecycleItems.contains(
                                  _recycleKey('customers', id),
                                ),
                                onChanged: id.isEmpty
                                    ? null
                                    : (value) => _toggleRecycleSelection(
                                          'customers',
                                          id,
                                          value ?? false,
                                        ),
                              ),
                            CircleAvatar(
                              child: Icon(Icons.person_outline),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 16,
                                    ),
                                  ),
                                  if (address.isNotEmpty) ...[
                                    SizedBox(height: 4),
                                    Text(
                                      address,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                  SizedBox(height: 4),
                                  Text('$remaining days remaining'),
                                  SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                    TextButton(
                                        onPressed: id.isEmpty
                                            ? null
                                            : () => restoreCustomer(id),
                                        child: Text(
                                          ghataT(context, 'Restore'),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: id.isEmpty
                                            ? null
                                            : () => permanentlyDeleteCustomer(
                                                  id,
                                                  name,
                                                  customer['deleted_at']
                                                      ?.toString(),
                                                ),
                                        child: Text(
                                          ghataT(
                                            context,
                                            'Delete Permanently',
                                          ),
                                          style: TextStyle(
                                            color: Colors.red,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],

                if (customers.isNotEmpty && transactions.isNotEmpty)
                  SizedBox(height: 24),

                if (transactions.isNotEmpty) ...[
                  Text(
                    ghataT(context, 'Transactions'),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  ...transactions.map((transaction) {
                    final id = transaction['id']?.toString() ?? '';
                    final type =
                        transaction['transaction_type']?.toString() ?? '';
                    final amount = transaction['amount']?.toString() ?? '0';
                    final currency =
                        transaction['currency']?.toString() ?? '';
                    final customer =
                        transaction['customer_name']?.toString() ?? '';
                    final remaining =
                        daysRemaining(transaction['deleted_at']?.toString());

                    final typeLabel = switch (type) {
                      'money_in' => 'Money In',
                      'money_out' => 'Money Out',
                                                                              'adjustment_in' => 'Adjustment In',
                      'adjustment_out' => 'Adjustment Out',
                      _ => type,
                    };

                    final label = '$typeLabel $amount $currency';

                    return Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_selectionMode)
                              Checkbox(
                                value: _selectedRecycleItems.contains(
                                  _recycleKey('transactions', id),
                                ),
                                onChanged: id.isEmpty
                                    ? null
                                    : (value) => _toggleRecycleSelection(
                                          'transactions',
                                          id,
                                          value ?? false,
                                        ),
                              ),
                            CircleAvatar(
                              child: Icon(Icons.receipt_long_outlined),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$amount $currency',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    [
                                      typeLabel,
                                      if (customer.isNotEmpty) customer,
                                      '$remaining days remaining',
                                    ].join(' • '),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      TextButton(
                                        onPressed: id.isEmpty
                                            ? null
                                            : () => restoreTransaction(id),
                                        child: Text(
                                          ghataT(context, 'Restore'),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: id.isEmpty
                                            ? null
                                            : () => permanentlyDeleteTransaction(
                                                  id,
                                                  label,
                                                  transaction['deleted_at']
                                                      ?.toString(),
                                                ),
                                        child: Text(
                                          ghataT(
                                            context,
                                            'Delete Permanently',
                                          ),
                                          style: TextStyle(
                                            color: Colors.red,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
                if (exchanges.isNotEmpty) ...[
                  SizedBox(height: 24),
                  Text(
                    'Exchanges',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  ...exchanges.map((exchange) {
                    final id = exchange['id']?.toString() ?? '';
                    final type = exchange['exchange_type']?.toString() ?? '';
                    final customer =
                        exchange['customer_name']?.toString() ?? '';
                    final date =
                        exchange['exchange_date']?.toString() ?? '';
                    final remaining =
                        daysRemaining(exchange['deleted_at']?.toString());

                    final typeLabel = type == 'buy'
                        ? 'Exchange Buy'
                        : type == 'sell'
                            ? 'Exchange Sell'
                            : 'Exchange';

                    final label = customer.isEmpty
                        ? '$typeLabel $date'
                        : '$typeLabel - $customer';

                    return Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_selectionMode)
                              Checkbox(
                                value: _selectedRecycleItems.contains(
                                  _recycleKey('exchanges', id),
                                ),
                                onChanged: id.isEmpty
                                    ? null
                                    : (value) => _toggleRecycleSelection(
                                          'exchanges',
                                          id,
                                          value ?? false,
                                        ),
                              ),
                            CircleAvatar(
                              child: Icon(Icons.currency_exchange),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    typeLabel,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    [
                                      if (customer.isNotEmpty) customer,
                                      if (date.isNotEmpty) date,
                                      '$remaining days remaining',
                                    ].join(' • '),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      TextButton(
                                        onPressed: id.isEmpty
                                            ? null
                                            : () => restoreExchange(id),
                                        child: Text(
                                          ghataT(context, 'Restore'),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: id.isEmpty
                                            ? null
                                            : () => permanentlyDeleteExchange(
                                                  id,
                                                  label,
                                                  exchange['deleted_at']
                                                      ?.toString(),
                                                ),
                                        child: Text(
                                          ghataT(
                                            context,
                                            'Delete Permanently',
                                          ),
                                          style: TextStyle(
                                            color: Colors.red,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ],
            );
          },
        ),
        floatingActionButton:
            _selectionMode && _selectedRecycleItems.isNotEmpty
                ? FloatingActionButton.extended(
                    onPressed: _deleteSelectedRecycleBin,
                    icon: Icon(Icons.delete_forever),
                    label: Text(
                      '${ghataT(context, 'Delete Selected')} (${_selectedRecycleItems.length})',
                    ),
                  )
                : null,
      );
    }
}

class LanguageScreen extends StatelessWidget {
  final void Function(String) onLanguageChanged;
  final String currentLanguage;

  LanguageScreen({
    super.key,
    required this.onLanguageChanged,
    required this.currentLanguage,
  });

  @override
  Widget build(BuildContext context) {
    final languages = [
      ('en', 'English'),
      ('ps', 'پښتو'),
      ('fa', 'دری'),
      ('ur', 'اردو'),
      ('ar', 'العربية'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'Language')),
      ),
      body: ListView.separated(
        padding: EdgeInsets.all(16),
        itemCount: languages.length,
        separatorBuilder: (_, __) => Divider(),
        itemBuilder: (context, index) {
          final language = languages[index];
          final selected = currentLanguage == language.$1;

          return ListTile(
            leading: ghataLanguageFlagWidget(
              language.$1,
              width: 32,
              height: 22,
            ),
            title: Text(
              language.$2,
              style: TextStyle(fontSize: 18),
            ),
            trailing: selected
                ? Icon(Icons.check_circle)
                : null,
            onTap: () {
              onLanguageChanged(language.$1);
              Navigator.pop(context);
            },
          );
        },
      ),
    );
  }
}

Future<void> ghataShowTransactionReceipt(
  BuildContext context,
  Map<String, dynamic> transaction,
) async {
  final id = transaction['id']?.toString() ?? '';
  final reference = transaction['reference_no']?.toString() ?? '';
  final customer = transaction['customer_name']?.toString() ?? '';
  final type = transaction['transaction_type']?.toString() ?? '';
  final amount = transaction['amount']?.toString() ?? '0';
  final currency =
      transaction['currency']?.toString().toUpperCase() ?? '';
  final date = transaction['transaction_date']?.toString() ?? '';
  final rawTime = transaction['transaction_time']?.toString() ?? '';
  final time =
      rawTime.length >= 5 ? rawTime.substring(0, 5) : rawTime;
  final description =
      transaction['description']?.toString() ?? '';

  final typeLabel = switch (type) {
    'money_in' => ghataT(context, 'Money In'),
    'money_out' => ghataT(context, 'Money Out'),
    'adjustment_in' => ghataT(context, 'Adjustment In'),
    'adjustment_out' => ghataT(context, 'Adjustment Out'),
    _ => type.replaceAll('_', ' '),
  };

  final receiptNo = reference.isNotEmpty
      ? reference
      : (id.length > 8
          ? id.substring(0, 8).toUpperCase()
          : id.toUpperCase());

  final isPositive =
      type == 'money_in' || type == 'adjustment_in';
  final accent = isPositive ? Colors.green : Colors.red;

  Widget receiptRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(
              label,
              style: TextStyle(
                color:
                    Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style:
                  const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding:
            const EdgeInsets.fromLTRB(18, 4, 18, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF3157D5),
                borderRadius:
                    BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  const Text(
                    'ګهته • Ghata',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    ghataT(
                      context,
                      'Transaction Receipt',
                    ),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color:
                    Theme.of(context).colorScheme.surface,
                borderRadius:
                    BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant,
                ),
              ),
              child: Column(
                children: [
                  receiptRow(
                    ghataT(context, 'Reference'),
                    receiptNo,
                  ),
                  if (customer.isNotEmpty)
                    receiptRow(
                      ghataT(context, 'Customer'),
                      customer,
                    ),
                  receiptRow(
                    ghataT(context, 'Type'),
                    typeLabel,
                  ),
                  receiptRow(
                    ghataT(context, 'Date'),
                    time.isEmpty
                        ? date
                        : '$date  $time',
                  ),
                  if (description.isNotEmpty)
                    receiptRow(
                      ghataT(context, 'Description'),
                      description,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 18,
              ),
              decoration: BoxDecoration(
                color:
                    accent.withValues(alpha: 0.08),
                borderRadius:
                    BorderRadius.circular(16),
                border: Border.all(
                  color:
                      accent.withValues(alpha: 0.35),
                ),
              ),
              child: Column(
                children: [
                  Text(
                    ghataT(context, 'Amount'),
                    style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$amount $currency',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: accent,
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius:
                          BorderRadius.circular(20),
                    ),
                    child: Text(
                      typeLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class DailyJournalScreen extends StatefulWidget {
  final String? initialCustomerId;
  final String? initialCustomerName;
  final String? initialTransactionType;
  final bool openAddForm;

  DailyJournalScreen({
    super.key,
    this.initialCustomerId,
    this.initialCustomerName,
    this.initialTransactionType,
    this.openAddForm = false,
  });

  @override
  State<DailyJournalScreen> createState() =>
      _DailyJournalScreenState();
}

class _DailyJournalScreenState extends State<DailyJournalScreen> {

  List<Map<String, dynamic>> buildDailyJournalRunningLedger(
    List<Map<String, dynamic>> transactions,
  ) {
    final ordered = transactions
        .map((row) => Map<String, dynamic>.from(row))
        .toList();

    // Calculate oldest first so backdated entries correctly
    // recalculate every balance that follows them.
    ordered.sort((a, b) {
      final ad =
          '${a['transaction_date'] ?? ''} '
          '${a['transaction_time'] ?? ''} '
          '${a['created_at'] ?? ''}';
      final bd =
          '${b['transaction_date'] ?? ''} '
          '${b['transaction_time'] ?? ''} '
          '${b['created_at'] ?? ''}';
      return ad.compareTo(bd);
    });

    final running = <String, double>{};
    final rows = <Map<String, dynamic>>[];

    for (final transaction in ordered) {
      final currency =
          transaction['currency']?.toString().toUpperCase() ?? '';
      final type =
          transaction['transaction_type']?.toString() ?? '';
      final amount =
          double.tryParse(transaction['amount']?.toString() ?? '0') ?? 0;

      if (currency.isEmpty) continue;

      running.putIfAbsent(currency, () => 0);

      double moneyIn = 0;
      double moneyOut = 0;

      switch (type) {
        case 'money_in':
        case 'adjustment_in':
          moneyIn = amount;
          running[currency] = running[currency]! + amount;
          break;

        case 'money_out':
        case 'adjustment_out':
          moneyOut = amount;
          running[currency] = running[currency]! - amount;
          break;

        default:
          continue;
      }

      rows.add({
        ...transaction,
        '_journal_in': moneyIn,
        '_journal_out': moneyOut,
        '_journal_balance': running[currency],
      });
    }

    // Show newest first after calculating balances chronologically.
    return rows.reversed.toList();
  }

  late Future<List<Map<String, dynamic>>>
      journalTransactionsFuture;

  String selectedFilter = 'all';

  DateTime? journalFromDate;
  DateTime? journalToDate;
  TimeOfDay? journalFromTime;
  TimeOfDay? journalToTime;
  String? journalCurrencyFilter;

  final amountController = TextEditingController();
  final descriptionController = TextEditingController();
  final referenceController = TextEditingController();
  final journalSearchController = TextEditingController();

  String transactionType = 'money_in';
  String currency = 'AFN';
  DateTime selectedDate = DateTime.now();
  TimeOfDay selectedTime = TimeOfDay.now();
  bool isSaving = false;
  double? calculatorResult;

  String? selectedCustomerId;
  String? selectedCustomerName;

  @override
  void initState() {
    super.initState();

    journalTransactionsFuture = loadTransactions();
    ghataDataRevision.addListener(
      _handleRealtimeDataRevision,
    );

    selectedCustomerId = widget.initialCustomerId;
    selectedCustomerName = widget.initialCustomerName;

    if (widget.initialTransactionType != null) {
      transactionType = widget.initialTransactionType!;
    }

    if (widget.openAddForm) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showAddTransactionDialog();
        if (mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      });
    }
  }

  void _handleRealtimeDataRevision() {
    if (!mounted) return;

    // Realtime sync already refreshed SQLite.
    // Re-read Daily Journal locally only.
    setState(() {
      journalTransactionsFuture =
          loadTransactions(refreshCloud: false);
    });
  }

  void updateCalculatorResult() {
    final result =
        evaluateCalculatorExpression(amountController.text.trim());

    if (calculatorResult != result) {
      setState(() => calculatorResult = result);
    }
  }

  String flagForCurrency(String code) {
    for (final item in currencies) {
      if (item.$1 == code) return item.$2;
    }
    return '💰';
  }


  Future<List<Map<String, dynamic>>> loadCustomers() async {
    var local =
        await OfflineDatabase.instance.getRecords('customers');

    // Offline-first: never block Reports while waiting for Supabase.
    // Show local SQLite data immediately and refresh in the background.
    ghataRefreshCustomersCache();

    local.sort(
      (a, b) => (a['full_name']?.toString() ?? '')
          .compareTo(b['full_name']?.toString() ?? ''),
    );

    return local;
  }

  final currencies = [
    ('AFN', '🇦🇫', 'Afghan Afghani'),
    ('PKR', '🇵🇰', 'Pakistani Rupee'),
    ('USD', '🇺🇸', 'US Dollar'),
    ('EUR', '🇪🇺', 'Euro'),
    ('GBP', '🇬🇧', 'British Pound'),
    ('AED', '🇦🇪', 'UAE Dirham'),
    ('SAR', '🇸🇦', 'Saudi Riyal'),
    ('KWD', '🇰🇼', 'Kuwaiti Dinar'),
    ('QAR', '🇶🇦', 'Qatari Riyal'),
    ('OMR', '🇴🇲', 'Omani Rial'),
    ('TRY', '🇹🇷', 'Turkish Lira'),
    ('CNY', '🇨🇳', 'Chinese Yuan'),
    ('INR', '🇮🇳', 'Indian Rupee'),
    ('IRR', '🇮🇷', 'Iranian Rial'),
  ];

  final transactionTypes = [
    ('money_in', 'Money In'),
    ('money_out', 'Money Out'),
    ('adjustment_in', 'Adjustment In'),
    ('adjustment_out', 'Adjustment Out'),
  ];

  Future<List<Map<String, dynamic>>>
      loadTransactions({
    bool refreshCloud = true,
  }) async {
    final transactions =
        await OfflineDatabase.instance.getRecords('transactions');

    final rows = transactions.where((row) {
      final customerId = row['customer_id']?.toString().trim() ?? '';
      return customerId.isEmpty;
    }).map((row) => Map<String, dynamic>.from(row)).toList();

    final exchanges =
        await OfflineDatabase.instance.getRecords('exchanges');

    final exchangeEntries =
        await OfflineDatabase.instance.getRecords('exchange_entries');

    for (final exchange in exchanges) {
      final customerId =
          exchange['customer_id']?.toString().trim() ?? '';

      final deletedAt =
          exchange['deleted_at']?.toString().trim() ?? '';

      if (customerId.isNotEmpty || deletedAt.isNotEmpty) {
        continue;
      }

      final exchangeId = exchange['id']?.toString() ?? '';
      if (exchangeId.isEmpty) continue;

      final entries = exchangeEntries.where((entry) {
        return entry['exchange_id']?.toString() == exchangeId;
      }).toList();

      Map<String, dynamic>? outEntry;
      Map<String, dynamic>? inEntry;

      for (final entry in entries) {
        final entryType =
            entry['entry_type']?.toString() ?? '';

        if (entryType == 'money_out' && outEntry == null) {
          outEntry = entry;
        }

        if (entryType == 'money_in' && inEntry == null) {
          inEntry = entry;
        }
      }

      final outAmount =
          double.tryParse(outEntry?['amount']?.toString() ?? '') ?? 0;

      final inAmount =
          double.tryParse(inEntry?['amount']?.toString() ?? '') ?? 0;

      final outCurrency =
          outEntry?['currency']?.toString().toUpperCase() ?? '';

      final inCurrency =
          inEntry?['currency']?.toString().toUpperCase() ?? '';

      final exchangeDate =
          exchange['exchange_date']?.toString() ?? '';

      final exchangeTime =
          exchange['exchange_time']?.toString() ?? '';

      final createdAt =
          exchange['created_at']?.toString() ?? '';

      final notes =
          exchange['notes']?.toString().trim() ?? '';

      final exchangeDescription =
          outAmount > 0 &&
                  inAmount > 0 &&
                  outCurrency.isNotEmpty &&
                  inCurrency.isNotEmpty
              ? 'Exchange (${outAmount % 1 == 0 ? outAmount.toStringAsFixed(0) : outAmount.toStringAsFixed(2)} $outCurrency → ${inAmount % 1 == 0 ? inAmount.toStringAsFixed(0) : inAmount.toStringAsFixed(2)} $inCurrency)'
              : 'Exchange';

      final description =
          notes.isEmpty
              ? exchangeDescription
              : '$exchangeDescription • $notes';

      if (outEntry != null &&
          outAmount > 0 &&
          outCurrency.isNotEmpty) {
        rows.add({
          'id': 'exchange_out_$exchangeId',
          'exchange_id': exchangeId,
          'customer_id': null,
          'customer_name': '',
          'transaction_date': exchangeDate,
          'transaction_time': exchangeTime,
          'transaction_type': 'money_out',
          'amount': outAmount,
          'currency': outCurrency,
          'description': description,
          'reference_no': 'Exchange',
          'created_at': createdAt,
          '_is_exchange': true,
          '_exchange_leg': 'out',
        });
      }

      if (inEntry != null &&
          inAmount > 0 &&
          inCurrency.isNotEmpty) {
        rows.add({
          'id': 'exchange_in_$exchangeId',
          'exchange_id': exchangeId,
          'customer_id': null,
          'customer_name': '',
          'transaction_date': exchangeDate,
          'transaction_time': exchangeTime,
          'transaction_type': 'money_in',
          'amount': inAmount,
          'currency': inCurrency,
          'description': description,
          'reference_no': 'Exchange',
          'created_at': createdAt,
          '_is_exchange': true,
          '_exchange_leg': 'in',
        });
      }
    }

    rows.sort((a, b) {
      final ad =
          '${a['transaction_date'] ?? ''} '
          '${a['transaction_time'] ?? ''} '
          '${a['created_at'] ?? ''}';

      final bd =
          '${b['transaction_date'] ?? ''} '
          '${b['transaction_time'] ?? ''} '
          '${b['created_at'] ?? ''}';

      return bd.compareTo(ad);
    });

    if (refreshCloud) ghataRefreshOfflineCache();

    return rows.take(200).toList();
  }

  Future<void> saveTransaction() async {

    final amount = evaluateCalculatorExpression(amountController.text.trim());

    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Please enter a valid amount.'))),
      );
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'You are not logged in.'))),
      );
      return;
    }


    setState(() => isSaving = true);

    try {
      final dateText =
          '${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}';

      final transactionId = _ghataUuid.v4();

      await ghataSaveLocal(
        'transactions',
        {
          'id': transactionId,
          'user_id': user.id,
          'transaction_date': dateText,
          'transaction_time':
              '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}:00',
          'transaction_type': transactionType,
          'amount': amount,
          'currency': currency,
          'customer_id': selectedCustomerId,
          'customer_name': selectedCustomerName,
          'description': descriptionController.text.trim().isEmpty
              ? null
              : descriptionController.text.trim(),
          'reference_no': referenceController.text.trim().isEmpty
              ? null
              : referenceController.text.trim(),
          'deleted_at': null,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        },
      );

      if (!mounted) return;

      amountController.clear();
      selectedCustomerId = null;
      selectedCustomerName = null;
      descriptionController.clear();
      referenceController.clear();

      setState(() {
        calculatorResult = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Transaction saved successfully.')),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to save transaction')}: $e"),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isSaving = false);
      }
    }
  }


  Future<void> showAddTransactionDialog() async {
    final customers = await loadCustomers();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {

          return AlertDialog(
            title: Text(ghataT(context, 'Add Transaction')),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: transactionType,
                      decoration: InputDecoration(
                        labelText: ghataT(context, 'Transaction Type'),
                        prefixIcon:
                            Icon(Icons.swap_vert_rounded),
                        border: OutlineInputBorder(),
                      ),
                      items: transactionTypes
                          .map(
                            (item) =>
                                DropdownMenuItem<String>(
                              value: item.$1,
                              child: Text(item.$2),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          transactionType = value;
                        });
                      },
                    ),
                    SizedBox(height: 12),

                    GhataCalculatorField(
                      controller: amountController,
                      label: ghataT(context, 'Amount'),
                      onChanged: () {
                        setDialogState(() {
                          calculatorResult =
                              evaluateCalculatorExpression(
                            amountController.text.trim(),
                          );
                        });
                      },
                    ),

                    if (calculatorResult != null) ...[
                      SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Result: ${calculatorResult!.toStringAsFixed(calculatorResult! % 1 == 0 ? 0 : 2)} $currency',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],

                    SizedBox(height: 12),

                    DropdownButtonFormField<String>(
                      initialValue: currency,
                      decoration: InputDecoration(
                        labelText: ghataT(context, 'Currency'),
                        prefixIcon:
                            Icon(Icons.payments_outlined),
                        border: OutlineInputBorder(),
                      ),
                      items: currencies
                          .map(
                            (item) =>
                                DropdownMenuItem<String>(
                              value: item.$1,
                              child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ghataCurrencyFlagWidget(
                                  item.$1,
                                  width: 26,
                                  height: 18,
                                ),
                                SizedBox(width: 8),
                                Text(item.$1),
                              ],
                            ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() {
                            currency = value;
                          });
                        }
                      },
                    ),

                    SizedBox(height: 12),

                    DropdownButtonFormField<String?>(
                      initialValue: selectedCustomerId,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: ghataT(context, 'Customer (Optional)'),
                        prefixIcon:
                            Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text(ghataT(context, 'General / No Customer')),
                        ),
                        ...customers.map(
                          (customer) =>
                              DropdownMenuItem<String?>(
                            value: customer['id'].toString(),
                            child: Text(
                              customer['full_name']
                                      ?.toString() ??
                                  '',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          selectedCustomerId = value;

                          if (value == null) {
                            selectedCustomerName = null;
                          } else {
                            final match =
                                customers.firstWhere(
                              (item) =>
                                  item['id'].toString() ==
                                  value,
                            );
                            selectedCustomerName =
                                match['full_name']
                                    ?.toString();
                          }
                        });
                      },
                    ),

                    SizedBox(height: 8),

                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading:
                          Icon(Icons.calendar_today),
                      title: Text(ghataT(context, 'Date')),
                      subtitle: Text(
                        '${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}',
                      ),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: selectedDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );

                        if (picked != null) {
                          setDialogState(() {
                            selectedDate = picked;
                          });
                        }
                      },
                    ),


                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading:
                          Icon(Icons.access_time),
                      title: Text(ghataT(context, 'Time')),
                      subtitle:
                          Text(selectedTime.format(context)),
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: selectedTime,
                        );

                        if (picked != null) {
                          setDialogState(() {
                            selectedTime = picked;
                          });
                        }
                      },
                    ),

                    SizedBox(height: 8),

                    TextField(
                      controller: descriptionController,
                      maxLines: 2,
                      decoration: InputDecoration(
                        labelText: ghataT(context, 'Description'),
                        prefixIcon:
                            Icon(Icons.notes_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),

                    SizedBox(height: 12),

                    TextField(
                      controller: referenceController,
                      decoration: InputDecoration(
                        labelText: ghataT(context, 'Reference No.'),
                        prefixIcon:
                            Icon(Icons.tag_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSaving
                    ? null
                    : () => Navigator.pop(dialogContext),
                child: Text(ghataT(context, 'Cancel')),
              ),
              FilledButton.icon(
                onPressed: isSaving
                    ? null
                    : () async {
                        await saveTransaction();

                        if (!mounted ||
                            !dialogContext.mounted) {
                          return;
                        }

                        if (amountController.text.isEmpty &&
                            !isSaving) {
                          Navigator.pop(dialogContext);
                        }
                      },
                icon: Icon(Icons.check_rounded),
                label: Text(ghataT(context, 'Save')),
              ),
            ],
          );
        },
      ),
    );

    if (mounted) setState(() {});
  }

  Future<void> chooseDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (date != null) {
      setState(() => selectedDate = date);
    }
  }

  Future<void> chooseTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: selectedTime,
    );

    if (time != null) {
      setState(() => selectedTime = time);
    }
  }

  @override
  void dispose() {
    ghataDataRevision.removeListener(
      _handleRealtimeDataRevision,
    );
    amountController.dispose();
    descriptionController.dispose();
    referenceController.dispose();
    journalSearchController.dispose();
    super.dispose();
  }

  Future<void> showJournalRowActions(
    Map<String, dynamic> row,
  ) async {
    final isExchange = row['_is_exchange'] == true;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: Icon(Icons.edit_rounded),
                title: Text(ghataT(context, 'Edit')),
                onTap: () async {
                  Navigator.pop(sheetContext);

                  if (isExchange) {
                    final exchangeId =
                        row['exchange_id']?.toString() ?? '';

                    if (exchangeId.isEmpty) return;

                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ExchangeScreen(
                          initialExchangeId: exchangeId,
                        ),
                      ),
                    );

                    if (mounted) {
                      setState(() {});
                    }
                  } else {
                    await editTransaction(row);
                  }
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.red,
                ),
                title: Text(
                  ghataT(context, 'Delete'),
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  Navigator.pop(sheetContext);

                  if (isExchange) {
                    final exchangeId =
                        row['exchange_id']?.toString() ?? '';

                    if (exchangeId.isEmpty) return;

                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: Text(
                          ghataT(context, 'Move to Recycle Bin?'),
                        ),
                        content: Text(
                          'This exchange will be moved to Recycle Bin.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: Text(
                              ghataT(context, 'Cancel'),
                            ),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, true),
                            child: Text(
                              ghataT(
                                context,
                                'Move to Recycle Bin',
                              ),
                            ),
                          ),
                        ],
                      ),
                    );

                    if (confirmed != true) return;

                    await ghataSoftDeleteLocal(
                      'exchanges',
                      exchangeId,
                    );

                    ghataTrySync();

                    if (!mounted) return;

                    setState(() {});

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          ghataT(
                            context,
                            'Exchange moved to Recycle Bin.',
                          ),
                        ),
                      ),
                    );
                  } else {
                    await deleteTransaction(row);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> editTransaction(
    Map<String, dynamic> transaction,
  ) async {
    final id = transaction['id']?.toString();
    if (id == null || id.isEmpty) return;

    final amountEditController = TextEditingController(
      text: transaction['amount']?.toString() ?? '',
    );
    final descriptionEditController = TextEditingController(
      text: transaction['description']?.toString() ?? '',
    );
    final referenceEditController = TextEditingController(
      text: transaction['reference_no']?.toString() ?? '',
    );

    var editType =
        transaction['transaction_type']?.toString() ?? 'money_in';
    var editCurrency =
        transaction['currency']?.toString() ?? 'AFN';

    var editCustomerId = transaction['customer_id']?.toString();
    var editCustomerName = transaction['customer_name']?.toString();

    var editDate = DateTime.tryParse(
          transaction['transaction_date']?.toString() ?? '',
        ) ??
        DateTime.now();


    final rawEditTime = transaction['transaction_time']?.toString() ?? '';
    final timeParts = rawEditTime.split(':');
    var editTime = timeParts.length >= 2
        ? TimeOfDay(
            hour: int.tryParse(timeParts[0]) ?? TimeOfDay.now().hour,
            minute: int.tryParse(timeParts[1]) ?? TimeOfDay.now().minute,
          )
        : TimeOfDay.now();

    double? editCalculatorResult =
        evaluateCalculatorExpression(amountEditController.text.trim());

    final editCustomers = await loadCustomers();

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(ghataT(context, 'Edit Transaction')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GhataCalculatorField(
                  controller: amountEditController,
                  label: ghataT(context, 'Amount'),
                  onChanged: () {
                    setDialogState(() {
                      editCalculatorResult =
                          evaluateCalculatorExpression(
                        amountEditController.text.trim(),
                      );
                    });
                  },
                ),
                if (editCalculatorResult != null) ...[
                  SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Result / Balance: ${editCalculatorResult!.toStringAsFixed(editCalculatorResult! % 1 == 0 ? 0 : 2)} $editCurrency',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
                SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: editType,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Transaction Type'),
                    border: OutlineInputBorder(),
                  ),
                  items: transactionTypes
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.$1,
                          child: Text(item.$2),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() {
                        editType = value;
                        if (value == 'adjustment_in' ||
                            value == 'adjustment_out') {
                          editCustomerId = null;
                        }
                      });
                    }
                  },
                ),
                SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: editCurrency,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Currency'),
                    border: OutlineInputBorder(),
                  ),
                  items: currencies
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.$1,
                          child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ghataCurrencyFlagWidget(
                                  item.$1,
                                  width: 26,
                                  height: 18,
                                ),
                                SizedBox(width: 8),
                                Text(item.$1),
                              ],
                            ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => editCurrency = value);
                    }
                  },
                ),
                SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.calendar_today_outlined),
                  title: Text(ghataT(context, 'Date')),
                  subtitle: Text(
                    '${editDate.year}-${editDate.month.toString().padLeft(2, '0')}-${editDate.day.toString().padLeft(2, '0')}',
                  ),
                  trailing: Icon(Icons.edit_calendar_outlined),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: editDate,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );

                    if (picked != null) {
                      setDialogState(() {
                        editDate = picked;
                      });
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.access_time),
                  title: Text(ghataT(context, 'Time')),
                  subtitle: Text(editTime.format(context)),
                  trailing: Icon(Icons.edit_outlined),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: editTime,
                    );

                    if (picked != null) {
                      setDialogState(() => editTime = picked);
                    }
                  },
                ),
                SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: editCustomerId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Customer / Person (Optional)'),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem<String>(
                      value: null,
                      child: Text(ghataT(context, 'No Customer')),
                    ),
                    ...editCustomers.map(
                      (customer) => DropdownMenuItem<String>(
                        value: customer['id'].toString(),
                        child: Text(
                          customer['full_name']?.toString() ?? '',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    final customer = editCustomers
                        .where(
                          (item) => item['id'].toString() == value,
                        )
                        .firstOrNull;

                    setDialogState(() {
                      editCustomerId = value;
                      editCustomerName =
                          customer?['full_name']?.toString();
                    });
                  },
                ),
                SizedBox(height: 12),
                TextField(
                  controller: descriptionEditController,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Description'),
                    border: OutlineInputBorder(),
                  ),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: referenceEditController,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Reference No.'),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(ghataT(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(ghataT(context, 'Save Changes')),
            ),
          ],
        ),
      ),
    );

    if (saved != true) {
      amountEditController.dispose();
      descriptionEditController.dispose();
      referenceEditController.dispose();
      return;
    }

    final amount = evaluateCalculatorExpression(amountEditController.text.trim());

    if (amount == null || amount <= 0) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Enter a valid amount greater than zero.')),
        ),
      );

      amountEditController.dispose();
      descriptionEditController.dispose();
      referenceEditController.dispose();
      return;
    }


    try {
      await OfflineDatabase.instance.updateLocalRecord(
        'transactions',
        id,
        {        'amount': amount,
        'transaction_type': editType,
        'currency': editCurrency,
        'transaction_date':
            '${editDate.year}-${editDate.month.toString().padLeft(2, '0')}-${editDate.day.toString().padLeft(2, '0')}',
        'transaction_time':
            '${editTime.hour.toString().padLeft(2, '0')}:${editTime.minute.toString().padLeft(2, '0')}:00',
        'customer_id': editCustomerId,
        'customer_name': editCustomerName,
        'description': descriptionEditController.text.trim().isEmpty
            ? null
            : descriptionEditController.text.trim(),
        'reference_no': referenceEditController.text.trim().isEmpty
            ? null
            : referenceEditController.text.trim(),
        },
      );

      ghataTrySync();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Transaction updated successfully.')),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to update transaction')}: $e"),
        ),
      );
    } finally {
      amountEditController.dispose();
      descriptionEditController.dispose();
      referenceEditController.dispose();
    }
  }


  pw.Widget ghataPdfWatermark() {
    final language = Localizations.localeOf(context).languageCode;

    final designBy = switch (language) {
      'ps' => 'ډیزاین: MRS',
      'fa' => 'طراحی توسط MRS',
      'ur' => 'ڈیزائن: MRS',
      'ar' => 'تصميم بواسطة MRS',
      _ => 'Design by MRS',
    };

    return pw.Center(
      child: pw.Transform.rotate(
        angle: -0.35,
        child: pw.Opacity(
          opacity: 0.10,
          child: pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.Text(
                designBy,
                style: pw.TextStyle(
                  fontSize: 38,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),

            ],
          ),
        ),
      ),
    );
  }

Future<void> shareTransactionReceiptPdf(
    Map<String, dynamic> transaction,
  ) async {
    final ghataPdfFont = await ghataPdfUnicodeFont();
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      final profile = await ghataLoadBusinessProfile();

      final id = transaction['id']?.toString() ?? '';
      final reference = transaction['reference_no']?.toString() ?? '';
      final customer = transaction['customer_name']?.toString() ?? '';
      final type = transaction['transaction_type']?.toString() ?? '';
      final amount = transaction['amount']?.toString() ?? '0';
      final currency =
          transaction['currency']?.toString().toUpperCase() ?? '';
      final date = transaction['transaction_date']?.toString() ?? '';
      final rawTime = transaction['transaction_time']?.toString() ?? '';
      final time = rawTime.length >= 5 ? rawTime.substring(0, 5) : rawTime;
      final description = transaction['description']?.toString() ?? '';

      final typeKey = switch (type) {
        'money_in' => 'Money In',
        'money_out' => 'Money Out',
        'adjustment_in' => 'Adjustment In',
        'adjustment_out' => 'Adjustment Out',
        _ => type.replaceAll('_', ' '),
      };
      final typeLabel = ghataT(context, typeKey);

      final receiptNo = reference.isNotEmpty
          ? reference
          : (id.length > 8
              ? id.substring(0, 8).toUpperCase()
              : id.toUpperCase());

      final businessName =
          profile?['business_name']?.toString().trim() ?? '';
      final businessPhone =
          profile?['business_phone']?.toString().trim() ?? '';
      final businessAddress =
          profile?['business_address']?.toString().trim() ?? '';
      final receiptNote =
          profile?['receipt_note']?.toString().trim() ?? '';
      final ownerName = profile?['full_name']?.toString().trim() ?? '';

      final isPositive = type == 'money_in' ||
          type == 'adjustment_in';

      final accent = isPositive
          ? PdfColor.fromHex('#16A34A')
          : PdfColor.fromHex('#DC2626');
      final paleAccent = isPositive
          ? PdfColor.fromHex('#F0FDF4')
          : PdfColor.fromHex('#FEF2F2');
      final blue = PdfColor.fromHex('#3157D5');
      final paleBlue = PdfColor.fromHex('#EEF2FF');
      final border = PdfColor.fromHex('#E5E7EB');
      final muted = PdfColor.fromHex('#6B7280');

      pw.Widget infoRow(String label, String value) {
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(
                width: 115,
                child: pw.Text(
                  label,
                  style: pw.TextStyle(
                    fontSize: 10,
                    color: muted,
                  ),
                ),
              ),
              pw.Expanded(
                child: pw.Text(
                  value,
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
      }

      final pdf = pw.Document(
        theme: pw.ThemeData.withFont(
          base: ghataPdfFont,
          bold: ghataPdfFont,
          italic: ghataPdfFont,
          boldItalic: ghataPdfFont,
        ),
      );

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(30),
          build: (_) => pw.Stack(
            children: [
              pw.Positioned.fill(child: ghataPdfWatermark()),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Container(
                    padding: const pw.EdgeInsets.all(18),
                    decoration: pw.BoxDecoration(
                      color: blue,
                      borderRadius: pw.BorderRadius.circular(14),
                    ),
                    child: pw.Column(
                      children: [
                        pw.Text(
                          businessName.isEmpty ? 'ګهته • Ghata' : businessName,
                          textAlign: pw.TextAlign.center,
                          style: pw.TextStyle(
                            color: PdfColors.white,
                            fontSize: 23,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.SizedBox(height: 5),
                        pw.Text(
                          ghataT(context, 'Transaction Receipt'),
                          textAlign: pw.TextAlign.center,
                          style: pw.TextStyle(
                            color: PdfColors.white,
                            fontSize: 14,
                          ),
                        ),
                        if (businessAddress.isNotEmpty) ...[
                          pw.SizedBox(height: 6),
                          pw.Text(
                            businessAddress,
                            textAlign: pw.TextAlign.center,
                            style: const pw.TextStyle(
                              color: PdfColors.white,
                              fontSize: 9,
                            ),
                          ),
                        ],
                        if (businessPhone.isNotEmpty)
                          pw.Text(
                            businessPhone,
                            textAlign: pw.TextAlign.center,
                            style: const pw.TextStyle(
                              color: PdfColors.white,
                              fontSize: 9,
                            ),
                          ),
                      ],
                    ),
                  ),
                  pw.SizedBox(height: 14),

                  pw.Container(
                    padding: const pw.EdgeInsets.all(14),
                    decoration: pw.BoxDecoration(
                      color: PdfColors.white,
                      border: pw.Border.all(color: border),
                      borderRadius: pw.BorderRadius.circular(12),
                    ),
                    child: pw.Column(
                      children: [
                        infoRow(ghataT(context, 'Reference'), receiptNo),
                        if (customer.isNotEmpty)
                          infoRow(ghataT(context, 'Customer'), customer),
                        infoRow(ghataT(context, 'Type'), typeLabel),
                        infoRow(
                          ghataT(context, 'Date'),
                          time.isEmpty ? date : '$date  $time',
                        ),
                        if (description.isNotEmpty)
                          infoRow(
                            ghataT(context, 'Description'),
                            description,
                          ),
                      ],
                    ),
                  ),
                  pw.SizedBox(height: 14),

                  pw.Container(
                    padding: const pw.EdgeInsets.all(18),
                    decoration: pw.BoxDecoration(
                      color: paleAccent,
                      borderRadius: pw.BorderRadius.circular(12),
                      border: pw.Border.all(color: accent, width: 1.2),
                    ),
                    child: pw.Column(
                      children: [
                        pw.Text(
                          ghataT(context, 'Amount'),
                          style: pw.TextStyle(
                            color: muted,
                            fontSize: 11,
                          ),
                        ),
                        pw.SizedBox(height: 5),
                        pw.Text(
                          '${flagForCurrency(currency)}  $amount $currency',
                          textAlign: pw.TextAlign.center,
                          style: pw.TextStyle(
                            color: accent,
                            fontSize: 25,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.SizedBox(height: 5),
                        pw.Container(
                          padding: const pw.EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          decoration: pw.BoxDecoration(
                            color: accent,
                            borderRadius: pw.BorderRadius.circular(20),
                          ),
                          child: pw.Text(
                            typeLabel,
                            style: pw.TextStyle(
                              color: PdfColors.white,
                              fontSize: 10,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (ownerName.isNotEmpty) ...[
                    pw.SizedBox(height: 14),
                    pw.Container(
                      padding: const pw.EdgeInsets.all(12),
                      decoration: pw.BoxDecoration(
                        color: paleBlue,
                        borderRadius: pw.BorderRadius.circular(10),
                      ),
                      child: infoRow(
                        ghataT(context, 'Owner'),
                        ownerName,
                      ),
                    ),
                  ],

                  if (receiptNote.isNotEmpty) ...[
                    pw.SizedBox(height: 12),
                    pw.Container(
                      padding: const pw.EdgeInsets.all(12),
                      decoration: pw.BoxDecoration(
                        color: PdfColor.fromHex('#FFFBEB'),
                        borderRadius: pw.BorderRadius.circular(10),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            ghataT(context, 'Receipt Note'),
                            style: pw.TextStyle(
                              fontSize: 10,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                          pw.SizedBox(height: 4),
                          pw.Text(
                            receiptNote,
                            style: const pw.TextStyle(fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  ],

                  pw.Spacer(),
                  pw.Divider(color: border),
                  pw.Text(
                    ghataT(
                      context,
                      'Generated by Ghata - Business Ledger & Accounting',
                    ),
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(
                      fontSize: 9,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      final bytes = await pdf.save();

      final receiptFileName = 'Ghata_Receipt_$receiptNo.pdf';

      if (Platform.isWindows) {
        final location = await getSaveLocation(
          suggestedName: receiptFileName,
          acceptedTypeGroups: const <XTypeGroup>[
            XTypeGroup(
              label: 'PDF',
              extensions: <String>['pdf'],
            ),
          ],
        );

        if (location == null) return;

        await XFile.fromData(
          bytes,
          mimeType: 'application/pdf',
          name: receiptFileName,
        ).saveTo(location.path);
      } else {
        await SharePlus.instance.share(
          ShareParams(
            title: ghataT(context, 'Transaction Receipt'),
            subject: '${ghataT(context, 'Receipt')} $receiptNo',
            files: [
              XFile.fromData(
                bytes,
                mimeType: 'application/pdf',
              ),
            ],
            fileNameOverrides: [receiptFileName],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "${ghataT(context, 'Unable to create PDF')}: $e",
          ),
        ),
      );
    }
  }

  void showTransactionReceipt(Map<String, dynamic> transaction) {
    final id = transaction['id']?.toString() ?? '';
    final reference = transaction['reference_no']?.toString() ?? '';
    final customer = transaction['customer_name']?.toString() ?? '';
    final type = transaction['transaction_type']?.toString() ?? '';
    final amount = transaction['amount']?.toString() ?? '0';
    final currency =
        transaction['currency']?.toString().toUpperCase() ?? '';
    final date = transaction['transaction_date']?.toString() ?? '';
    final rawTime = transaction['transaction_time']?.toString() ?? '';
    final time = rawTime.length >= 5 ? rawTime.substring(0, 5) : rawTime;
    final description = transaction['description']?.toString() ?? '';

    final typeKey = switch (type) {
      'money_in' => 'Money In',
      'money_out' => 'Money Out',
      'adjustment_in' => 'Adjustment In',
      'adjustment_out' => 'Adjustment Out',
      _ => type.replaceAll('_', ' '),
    };
    final typeLabel = ghataT(context, typeKey);

    final receiptNo = reference.isNotEmpty
        ? reference
        : (id.length > 8
            ? id.substring(0, 8).toUpperCase()
            : id.toUpperCase());

    final isPositive = type == 'money_in' ||
        type == 'adjustment_in';

    final accent = isPositive ? Colors.green : Colors.red;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(18, 4, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Color(0xFF3157D5),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                    Text(
                      'ګهته • Ghata',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      ghataT(context, 'Transaction Receipt'),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12),

              Container(
                padding: EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Column(
                  children: [
                    _receiptPreviewRow(
                      ghataT(context, 'Reference'),
                      receiptNo,
                    ),
                    if (customer.isNotEmpty)
                      _receiptPreviewRow(
                        ghataT(context, 'Customer'),
                        customer,
                      ),
                    _receiptPreviewRow(
                      ghataT(context, 'Type'),
                      typeLabel,
                    ),
                    _receiptPreviewRow(
                      ghataT(context, 'Date'),
                      time.isEmpty ? date : '$date  $time',
                    ),
                    if (description.isNotEmpty)
                      _receiptPreviewRow(
                        ghataT(context, 'Description'),
                        description,
                      ),
                  ],
                ),
              ),
              SizedBox(height: 12),

              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 18,
                ),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: accent.withValues(alpha: 0.35),
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      ghataT(context, 'Amount'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(height: 5),
                    Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ghataCurrencyFlagWidget(currency),
                          SizedBox(width: 8),
                          Text(
                            '$amount $currency',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: accent,
                              fontSize: 25,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 7),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        typeLabel,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 18),

              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  shareTransactionReceiptPdf(transaction);
                },
                icon: Icon(Icons.picture_as_pdf_outlined),
                label: Text(
                  ghataT(context, 'Share PDF Receipt'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _receiptPreviewRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> deleteTransaction(
    Map<String, dynamic> transaction,
  ) async {
    final id = transaction['id']?.toString();
    if (id == null || id.isEmpty) return;

    final amount = transaction['amount']?.toString() ?? '';
    final currencyCode = transaction['currency']?.toString() ?? '';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(ghataT(context, 'Move to Recycle Bin?')),
        content: Text(
          'Are you sure you want to delete $amount $currencyCode? '
          'It will be restorable from Recycle Bin for 30 days.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(ghataT(context, 'Move to Recycle Bin')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
        await ghataSoftDeleteLocal(
          'transactions',
          id,
        );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Transaction moved to Recycle Bin. You can restore it within 30 days.')),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to delete transaction')}: $e"),
        ),
      );
    }
  }
  Future<void> showJournalAdvancedFilters() async {
    final customers = await loadCustomers();
    if (!mounted) return;

    DateTime? fromDate = journalFromDate;
    DateTime? toDate = journalToDate;
    TimeOfDay? fromTime = journalFromTime;
    TimeOfDay? toTime = journalToTime;
    String? currencyFilter = journalCurrencyFilter;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          String dateText(DateTime? value) {
            if (value == null) return ghataT(context, 'All');
            return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
          }

          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.tune_rounded),
                SizedBox(width: 8),
                Text(ghataT(context, 'Filter')),
              ],
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.date_range_outlined),
                      title: Text(ghataT(context, 'From Date')),
                      subtitle: Text(dateText(fromDate)),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: fromDate ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setDialogState(() => fromDate = picked);
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.event_outlined),
                      title: Text(ghataT(context, 'To Date')),
                      subtitle: Text(dateText(toDate)),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: toDate ?? fromDate ?? DateTime.now(),
                          firstDate: fromDate ?? DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setDialogState(() => toDate = picked);
                        }
                      },
                    ),
                    Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.schedule_outlined),
                      title: Text(ghataT(context, 'From Time')),
                      subtitle: Text(
                        fromTime == null
                            ? ghataT(context, 'All')
                            : fromTime!.format(context),
                      ),
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: fromTime ?? TimeOfDay(hour: 0, minute: 0),
                        );
                        if (picked != null) {
                          setDialogState(() => fromTime = picked);
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.schedule_rounded),
                      title: Text(ghataT(context, 'To Time')),
                      subtitle: Text(
                        toTime == null
                            ? ghataT(context, 'All')
                            : toTime!.format(context),
                      ),
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: context,
                          initialTime:
                              toTime ?? TimeOfDay(hour: 23, minute: 59),
                        );
                        if (picked != null) {
                          setDialogState(() => toTime = picked);
                        }
                      },
                    ),
                    SizedBox(height: 8),
                    DropdownButtonFormField<String?>(
                      initialValue: currencyFilter,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: ghataT(context, 'Currency'),
                        prefixIcon: Icon(Icons.payments_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text(ghataT(context, 'All')),
                        ),
                        ...currencies.map(
                          (item) => DropdownMenuItem<String?>(
                            value: item.$1,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ghataCurrencyFlagWidget(
                                  item.$1,
                                  width: 26,
                                  height: 18,
                                ),
                                SizedBox(width: 8),
                                Text(item.$1),
                              ],
                            ),
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        setDialogState(() => currencyFilter = value);
                      },
                    ),
                    SizedBox(height: 12),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() {
                    journalFromDate = null;
                    journalToDate = null;
                    journalFromTime = null;
                    journalToTime = null;
                    journalCurrencyFilter = null;
                  });
                  Navigator.pop(dialogContext);
                },
                child: Text(ghataT(context, 'Clear')),
              ),
              FilledButton(
                onPressed: () {
                  setState(() {
                    journalFromDate = fromDate;
                    journalToDate = toDate;
                    journalFromTime = fromTime;
                    journalToTime = toTime;
                    journalCurrencyFilter = currencyFilter;
                  });
                  Navigator.pop(dialogContext);
                },
                child: Text(ghataT(context, 'Apply')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> printFullDailyJournal() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      final transactions = await loadTransactions();
      final rows = buildDailyJournalRunningLedger(transactions);

      if (rows.isEmpty) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ghataT(context, 'No journal records to print.')),
          ),
        );
        return;
      }

      final profile = await ghataLoadBusinessProfile();
      final pdfFont = await ghataPdfUnicodeFont();

      final businessName =
          profile?['business_name']?.toString().trim() ?? '';
      final businessPhone =
          profile?['business_phone']?.toString().trim() ?? '';
      final businessAddress =
          profile?['business_address']?.toString().trim() ?? '';

      String typeLabel(String type) {
        return switch (type) {
          'money_in' => ghataT(context, 'Money In'),
          'money_out' => ghataT(context, 'Money Out'),
          'adjustment_in' => ghataT(context, 'Adjustment In'),
          'adjustment_out' => ghataT(context, 'Adjustment Out'),
          _ => type.replaceAll('_', ' '),
        };
      }

      String amountText(dynamic value) {
        final number =
            double.tryParse(value?.toString() ?? '') ?? 0;

        if (number == 0) return '';

        if (number == number.roundToDouble()) {
          return number.toStringAsFixed(0);
        }

        return number.toStringAsFixed(2);
      }

      final pdf = pw.Document(
        theme: pw.ThemeData.withFont(
          base: pdfFont,
          bold: pdfFont,
          italic: pdfFont,
          boldItalic: pdfFont,
        ),
      );

      final blue = PdfColor.fromHex('#3157D5');
      final lightBlue = PdfColor.fromHex('#EEF2FF');
      final border = PdfColor.fromHex('#D1D5DB');
      final muted = PdfColor.fromHex('#6B7280');

      final totalsIn = <String, double>{};
      final totalsOut = <String, double>{};

      for (final row in rows) {
        final currency =
            row['currency']?.toString().toUpperCase() ?? '';

        if (currency.isEmpty) continue;

        final moneyIn = double.tryParse(
              row['_journal_in']?.toString() ?? '0',
            ) ??
            0;

        final moneyOut = double.tryParse(
              row['_journal_out']?.toString() ?? '0',
            ) ??
            0;

        totalsIn[currency] =
            (totalsIn[currency] ?? 0) + moneyIn;

        totalsOut[currency] =
            (totalsOut[currency] ?? 0) + moneyOut;
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(24),
          header: (context) => pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 12),
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color: blue,
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Text(
                  businessName.isEmpty
                      ? 'ګهته • Ghata'
                      : businessName,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  ghataT(this.context, 'Daily Journal'),
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 12,
                  ),
                ),
                if (businessAddress.isNotEmpty)
                  pw.Text(
                    businessAddress,
                    textAlign: pw.TextAlign.center,
                    style: const pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 8,
                    ),
                  ),
                if (businessPhone.isNotEmpty)
                  pw.Text(
                    businessPhone,
                    textAlign: pw.TextAlign.center,
                    style: const pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 8,
                    ),
                  ),
              ],
            ),
          ),
          footer: (context) => pw.Container(
            padding: const pw.EdgeInsets.only(top: 7),
            decoration: pw.BoxDecoration(
              border: pw.Border(
                top: pw.BorderSide(
                  color: border,
                  width: 0.5,
                ),
              ),
            ),
            child: pw.Row(
              mainAxisAlignment:
                  pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Design by MRS',
                  style: pw.TextStyle(
                    fontSize: 7,
                    color: muted,
                  ),
                ),
                pw.Text(
                  'Page ${context.pageNumber} / ${context.pagesCount}',
                  style: pw.TextStyle(
                    fontSize: 7,
                    color: muted,
                  ),
                ),
              ],
            ),
          ),
          build: (context) => [
            pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 10),
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: lightBlue,
                borderRadius: pw.BorderRadius.circular(6),
              ),
              child: pw.Row(
                mainAxisAlignment:
                    pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Total records: ${rows.length}',
                    style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'Printed: ${DateTime.now().toString().substring(0, 16)}',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                ],
              ),
            ),
            pw.Table(
              border: pw.TableBorder.all(
                color: border,
                width: 0.5,
              ),
              columnWidths: const {
                0: pw.FixedColumnWidth(26),
                1: pw.FixedColumnWidth(62),
                2: pw.FixedColumnWidth(40),
                3: pw.FixedColumnWidth(76),
                4: pw.FlexColumnWidth(2.2),
                5: pw.FixedColumnWidth(68),
                6: pw.FixedColumnWidth(42),
                7: pw.FixedColumnWidth(62),
                8: pw.FixedColumnWidth(62),
                9: pw.FixedColumnWidth(70),
              },
              children: [
                pw.TableRow(
                  decoration: pw.BoxDecoration(
                    color: lightBlue,
                  ),
                  children: [
                    'No.',
                    'Date',
                    'Time',
                    'Type',
                    'Description',
                    'Receipt',
                    'Curr.',
                    'Money In',
                    'Money Out',
                    'Balance',
                  ].map(
                    (value) => pw.Padding(
                      padding: const pw.EdgeInsets.all(4),
                      child: pw.Text(
                        value,
                        style: pw.TextStyle(
                          fontSize: 7,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ),
                  ).toList(),
                ),
                ...List.generate(rows.length, (index) {
                  final row = rows[index];

                  final rawTime =
                      row['transaction_time']?.toString() ?? '';

                  final time = rawTime.length >= 5
                      ? rawTime.substring(0, 5)
                      : rawTime;

                  final values = <String>[
                    '${index + 1}',
                    row['transaction_date']?.toString() ?? '',
                    time,
                    typeLabel(
                      row['transaction_type']?.toString() ?? '',
                    ),
                    row['description']?.toString() ?? '',
                    row['reference_no']?.toString() ?? '',
                    row['currency']?.toString().toUpperCase() ?? '',
                    amountText(row['_journal_in']),
                    amountText(row['_journal_out']),
                    amountText(row['_journal_balance']),
                  ];

                  return pw.TableRow(
                    children: values.map(
                      (value) => pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 4,
                        ),
                        child: pw.Text(
                          value,
                          style: const pw.TextStyle(fontSize: 6.7),
                        ),
                      ),
                    ).toList(),
                  );
                }),
              ],
            ),
            pw.SizedBox(height: 12),
            pw.Wrap(
              spacing: 8,
              runSpacing: 8,
              children: totalsIn.keys.map((currency) {
                final incoming = totalsIn[currency] ?? 0;
                final outgoing = totalsOut[currency] ?? 0;
                final balance = incoming - outgoing;

                return pw.Container(
                  width: 165,
                  padding: const pw.EdgeInsets.all(8),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(
                      color: border,
                      width: 0.5,
                    ),
                    borderRadius: pw.BorderRadius.circular(6),
                  ),
                  child: pw.Column(
                    crossAxisAlignment:
                        pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        currency,
                        style: pw.TextStyle(
                          fontSize: 9,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 3),
                      pw.Text(
                        'Money In: ${amountText(incoming)}',
                        style: const pw.TextStyle(fontSize: 7),
                      ),
                      pw.Text(
                        'Money Out: ${amountText(outgoing)}',
                        style: const pw.TextStyle(fontSize: 7),
                      ),
                      pw.Text(
                        'Balance: ${amountText(balance)}',
                        style: pw.TextStyle(
                          fontSize: 7,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      );

      final bytes = await pdf.save();

      await Printing.layoutPdf(
        name: 'Ghata_Daily_Journal.pdf',
        onLayout: (_) async => bytes,
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to print Daily Journal')}: $e"),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF123D2B),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text(
          ghataT(context, 'Daily Journal'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (Platform.isWindows)
            IconButton(
              tooltip: ghataT(context, 'Print Full Journal'),
              icon: Icon(Icons.print_outlined),
              onPressed: printFullDailyJournal,
            ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            setState(() {});
          },
          child: ListView(
            padding: EdgeInsets.all(16),
            children: [
              TextField(
                controller: journalSearchController,
                decoration: InputDecoration(
                  hintText: ghataT(context, 'Search transactions...'),
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),

              SizedBox(height: 12),

              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    FilterChip(
                      avatar: selectedFilter == 'all'
                          ? Icon(Icons.check_rounded, size: 17)
                          : null,
                      label: Text(ghataT(context, 'All')),
                      selected: selectedFilter == 'all',
                      onSelected: (_) {
                        setState(() => selectedFilter = 'all');
                      },
                    ),
                    SizedBox(width: 8),
                    FilterChip(
                      label: Text(ghataT(context, 'Money In')),
                      selected: selectedFilter == 'money_in',
                      onSelected: (_) {
                        setState(() => selectedFilter = 'money_in');
                      },
                    ),
                    SizedBox(width: 8),
                    FilterChip(
                      label: Text(ghataT(context, 'Money Out')),
                      selected: selectedFilter == 'money_out',
                      onSelected: (_) {
                        setState(() => selectedFilter = 'money_out');
                      },
                    ),
                    SizedBox(width: 8),
                    FilterChip(
                      label: Text(ghataT(context, 'Adjustments')),
                      selected: selectedFilter == 'adjustment',
                      onSelected: (_) {
                        setState(() => selectedFilter = 'adjustment');
                      },
                    ),
                    SizedBox(width: 8),
                    ActionChip(
                      avatar: Icon(Icons.tune_rounded, size: 18),
                      label: Text(ghataT(context, 'Filter')),
                      onPressed: showJournalAdvancedFilters,
                    ),
                  ],
                ),
              ),

              SizedBox(height: 10),

              if (journalFromDate != null ||
                  journalToDate != null ||
                  journalFromTime != null ||
                  journalToTime != null ||
                  journalCurrencyFilter != null)
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.filter_alt_outlined, size: 18),
                      SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          [
                            if (journalFromDate != null)
                              'From ${journalFromDate!.year}-${journalFromDate!.month.toString().padLeft(2, '0')}-${journalFromDate!.day.toString().padLeft(2, '0')}',
                            if (journalToDate != null)
                              'To ${journalToDate!.year}-${journalToDate!.month.toString().padLeft(2, '0')}-${journalToDate!.day.toString().padLeft(2, '0')}',
                            if (journalFromTime != null)
                              'Time ${journalFromTime!.format(context)}',
                            if (journalToTime != null)
                              '– ${journalToTime!.format(context)}',
                            if (journalCurrencyFilter != null)
                              journalCurrencyFilter!,
                          ].join(' • '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          setState(() {
                            journalFromDate = null;
                            journalToDate = null;
                            journalFromTime = null;
                            journalToTime = null;
                            journalCurrencyFilter = null;
                                  });
                        },
                        icon: Icon(Icons.close_rounded, size: 19),
                      ),
                    ],
                  ),
                ),

              SizedBox(height: 16),


              FutureBuilder<List<Map<String, dynamic>>>(
                future: journalTransactionsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState ==
                      ConnectionState.waiting) {
                    return Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }

                  if (snapshot.hasError) {
                    return Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        "${ghataT(context, 'Unable to load transactions')}: ${snapshot.error}",
                      ),
                    );
                  }

                  final rows = snapshot.data ?? [];
                  final query =
                      journalSearchController.text.trim().toLowerCase();

                  final filtered = rows.where((row) {
                    final type =
                        row['transaction_type']?.toString() ?? '';
                    final customer =
                        row['customer_name']?.toString() ?? '';
                    final description =
                        row['description']?.toString() ?? '';
                    final currency =
                        row['currency']?.toString() ?? '';
                    final reference =
                        row['reference_no']?.toString() ?? '';

                    bool filterOk = true;

                    if (selectedFilter == 'money_in') {
                      filterOk = type == 'money_in';
                    } else if (selectedFilter == 'money_out') {
                      filterOk = type == 'money_out';
                    } else if (selectedFilter == 'customer') {
                      filterOk = customer.trim().isNotEmpty;
                    }

                    if (selectedFilter == 'adjustment') {
                      filterOk = type.startsWith('adjustment_');
                    }

                    if (!filterOk) return false;

                    if (journalCurrencyFilter != null &&
                        currency != journalCurrencyFilter) {
                      return false;
                    }

                    final rowDate = DateTime.tryParse(
                      row['transaction_date']?.toString() ?? '',
                    );

                    if (rowDate != null) {
                      final day = DateTime(
                        rowDate.year,
                        rowDate.month,
                        rowDate.day,
                      );

                      if (journalFromDate != null) {
                        final from = DateTime(
                          journalFromDate!.year,
                          journalFromDate!.month,
                          journalFromDate!.day,
                        );
                        if (day.isBefore(from)) return false;
                      }

                      if (journalToDate != null) {
                        final to = DateTime(
                          journalToDate!.year,
                          journalToDate!.month,
                          journalToDate!.day,
                        );
                        if (day.isAfter(to)) return false;
                      }
                    }

                    final rawFilterTime =
                        row['transaction_time']?.toString() ?? '';
                    final timeParts = rawFilterTime.split(':');

                    if (timeParts.length >= 2) {
                      final hour = int.tryParse(timeParts[0]) ?? 0;
                      final minute = int.tryParse(timeParts[1]) ?? 0;
                      final rowMinutes = hour * 60 + minute;

                      if (journalFromTime != null) {
                        final fromMinutes =
                            journalFromTime!.hour * 60 +
                            journalFromTime!.minute;
                        if (rowMinutes < fromMinutes) return false;
                      }

                      if (journalToTime != null) {
                        final toMinutes =
                            journalToTime!.hour * 60 +
                            journalToTime!.minute;
                        if (rowMinutes > toMinutes) return false;
                      }
                    }

                    if (query.isEmpty) return true;

                    return type.toLowerCase().contains(query) ||
                        customer.toLowerCase().contains(query) ||
                        description.toLowerCase().contains(query) ||
                        currency.toLowerCase().contains(query) ||
                        reference.toLowerCase().contains(query);
                  }).toList();

                  final summary = <String, Map<String, double>>{};

                  for (final row in filtered) {
                    final currency =
                        row['currency']?.toString() ?? '';
                    final type =
                        row['transaction_type']?.toString() ?? '';
                    final amount = double.tryParse(
                          row['amount']?.toString() ?? '0',
                        ) ??
                        0;

                    if (currency.isEmpty || amount <= 0) continue;

                    final values = summary.putIfAbsent(
                      currency,
                      () => {
                        'in': 0,
                        'out': 0,
                      },
                    );

                    if (type == 'money_in' ||
                        type == 'adjustment_in') {
                      values['in'] = values['in']! + amount;
                    } else if (type == 'money_out' ||
                        type == 'adjustment_out') {
                      values['out'] = values['out']! + amount;
                    }
                  }

                  final visibleSummary = summary.entries
                      .where(
                        (e) =>
                            (e.value['in'] ?? 0).abs() > 0.000001 ||
                            (e.value['out'] ?? 0).abs() > 0.000001,
                      )
                      .toList();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (visibleSummary.isNotEmpty) ...[
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                ghataT(context, 'Summary by Currency'),
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            SizedBox(width: 8),
                            SizedBox(
                              width: 150,
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String?>(
                                  value: journalCurrencyFilter,
                                  isExpanded: true,
                                  isDense: true,
                                  borderRadius: BorderRadius.circular(14),
                                  hint: Text(
                                    ghataT(context, 'All Currencies'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  items: [
                                    DropdownMenuItem<String?>(
                                      value: null,
                                      child: Text(
                                        ghataT(context, 'All Currencies'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    ...currencies.map(
                                      (item) => DropdownMenuItem<String?>(
                                        value: item.$1,
                                        child: Text(
                                          '${item.$2} ${item.$1}',
                                          maxLines: 1,
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    setState(() {
                                      journalCurrencyFilter = value;
                                    });
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 11),
                        SizedBox(
                          height: 130,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: BouncingScrollPhysics(),
                            itemCount: visibleSummary.length,
                            separatorBuilder: (_, __) =>
                                SizedBox(width: 10),
                            itemBuilder: (context, index) {
                              final e = visibleSummary[index];
                              final incoming = e.value['in'] ?? 0;
                              final outgoing = e.value['out'] ?? 0;

                              return Container(
                                width: 155,
                                padding: EdgeInsets.all(13),
                                decoration: BoxDecoration(
                                  color: index % 3 == 0
                                      ? Colors.green.withValues(alpha: 0.07)
                                      : index % 3 == 1
                                          ? Colors.blue.withValues(alpha: 0.07)
                                          : Colors.orange.withValues(alpha: 0.07),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant
                                        .withValues(alpha: 0.7),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        ghataCurrencyFlagWidget(
                                          e.key,
                                          width: 32,
                                          height: 22,
                                        ),
                                        SizedBox(width: 8),
                                        Text(
                                          e.key,
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Spacer(),
                                    Text(
                                      'In: ${incoming.toStringAsFixed(incoming % 1 == 0 ? 0 : 2)}',
                                      maxLines: 1,
                                      style: TextStyle(
                                        color: Colors.green.shade700,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Out: ${outgoing.toStringAsFixed(outgoing % 1 == 0 ? 0 : 2)}',
                                      maxLines: 1,
                                      style: TextStyle(
                                        color: Colors.red.shade600,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        SizedBox(height: 20),
                      ],

                      Text(
                        ghataT(context, 'Transactions'),
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 8),

                      if (filtered.isEmpty)
                        Padding(
                          padding: EdgeInsets.all(35),
                          child: Center(
                            child: Text(ghataT(context, 'No transactions found.')),
                          ),
                        )
                      else
                        Builder(
                          builder: (context) {
                            final journal =
                                buildDailyJournalRunningLedger(filtered);

                            String amountText(dynamic value) {
                              final number =
                                  double.tryParse(value.toString()) ?? 0;
                              if (number.abs() <= 0.000001) return '—';
                              return number % 1 == 0
                                  ? number.toStringAsFixed(0)
                                  : number.toStringAsFixed(2);
                            }

                            return SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              physics: BouncingScrollPhysics(),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(minWidth: 820),
                                child: SizedBox(
                                  width: Platform.isWindows
                                      ? (MediaQuery.sizeOf(context).width - 32)
                                          .clamp(820.0, 1180.0)
                                          .toDouble()
                                      : 820,
                                  child: Column(
                                    children: [
                                      Container(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 13,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Row(
                                          children: [
                                            SizedBox(
                                              width: 100,
                                              child: Text(
                                                ghataT(context, 'Date'),
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 3,
                                              child: Text(
                                                ghataT(context, 'Description'),
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 2,
                                              child: Text(
                                                ghataT(context, 'Money In'),
                                                textAlign: TextAlign.end,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.green,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 2,
                                              child: Text(
                                                ghataT(context, 'Money Out'),
                                                textAlign: TextAlign.end,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.red,
                                                ),
                                              ),
                                            ),
                                            SizedBox(
                                              width: 90,
                                              child: Text(
                                                ghataT(context, 'Currency'),
                                                textAlign: TextAlign.end,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 2,
                                              child: Text(
                                                ghataT(context, 'Balance'),
                                                textAlign: TextAlign.end,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      SizedBox(height: 4),
                                      ...journal.map((row) {
                                        final currency =
                                            row['currency']
                                                    ?.toString()
                                                    .toUpperCase() ??
                                                '';

                                        final date =
                                            row['transaction_date']
                                                    ?.toString() ??
                                                '';

                                        final rawTime =
                                            row['transaction_time']
                                                    ?.toString() ??
                                                '';

                                        final time = rawTime.length >= 5
                                            ? rawTime.substring(0, 5)
                                            : rawTime;

                                        final description =
                                            row['description']
                                                    ?.toString()
                                                    .trim() ??
                                                '';

                                        final type =
                                            row['transaction_type']
                                                    ?.toString() ??
                                                '';

                                        final moneyIn =
                                            row['_journal_in'] ?? 0.0;
                                        final moneyOut =
                                            row['_journal_out'] ?? 0.0;

                                        final balance = double.tryParse(
                                              row['_journal_balance']
                                                  .toString(),
                                            ) ??
                                            0;

                                        final balanceColor = balance > 0
                                            ? Colors.green
                                            : balance < 0
                                                ? Colors.red
                                                : Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant;

                                        final label = switch (type) {
                                          'money_in' => 'Money In',
                                          'money_out' => 'Money Out',
                                          'adjustment_in' => 'Adjustment In',
                                          'adjustment_out' => 'Adjustment Out',
                                          _ => type.replaceAll('_', ' '),
                                        };

                                        final displayDescription =
                                            description.isNotEmpty
                                                ? description
                                                : ghataT(context, label);

                                        return GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () =>
                                              showTransactionReceipt(row),
                                          onLongPress: () =>
                                              showJournalRowActions(row),
                                          child: Container(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 13,
                                            ),
                                            decoration: BoxDecoration(
                                              border: Border(
                                                bottom: BorderSide(
                                                  color: Theme.of(context)
                                                      .dividerColor
                                                      .withValues(alpha: 0.45),
                                                ),
                                              ),
                                            ),
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                SizedBox(
                                                  width: 100,
                                                  child: Text(
                                                    time.isEmpty
                                                        ? date
                                                        : '$date\n$time',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  flex: 3,
                                                  child: Text(
                                                    displayDescription,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  flex: 2,
                                                  child: Text(
                                                    amountText(moneyIn),
                                                    textAlign: TextAlign.end,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      color: Colors.green,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  flex: 2,
                                                  child: Text(
                                                    amountText(moneyOut),
                                                    textAlign: TextAlign.end,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      color: Colors.red,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                                  SizedBox(
                                                    width: 90,
                                                    child: Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment.end,
                                                      children: [
                                                        ghataCurrencyFlagWidget(
                                                          currency,
                                                          width: 22,
                                                          height: 15,
                                                        ),
                                                        SizedBox(width: 5),
                                                        Text(
                                                          currency,
                                                          style: TextStyle(
                                                            fontSize: 13,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                Expanded(
                                                  flex: 2,
                                                  child: Text(
                                                    amountText(balance),
                                                    textAlign: TextAlign.end,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      color: balanceColor,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      }),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),

                      SizedBox(height: 90),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),

      bottomNavigationBar: _GhataAppBottomNav(
        selectedIndex: 3,
        onAddHere: showAddTransactionDialog,
      ),
    );
  }

}

const List<Map<String, String>> customerCountryCodes = [
  {'flag':'🇦🇫','code':'+93','name':'Afghanistan'},
  {'flag':'🇦🇱','code':'+355','name':'Albania'},
  {'flag':'🇩🇿','code':'+213','name':'Algeria'},
  {'flag':'🇦🇩','code':'+376','name':'Andorra'},
  {'flag':'🇦🇴','code':'+244','name':'Angola'},
  {'flag':'🇦🇬','code':'+1-268','name':'Antigua and Barbuda'},
  {'flag':'🇦🇷','code':'+54','name':'Argentina'},
  {'flag':'🇦🇲','code':'+374','name':'Armenia'},
  {'flag':'🇦🇺','code':'+61','name':'Australia'},
  {'flag':'🇦🇹','code':'+43','name':'Austria'},
  {'flag':'🇦🇿','code':'+994','name':'Azerbaijan'},
  {'flag':'🇧🇸','code':'+1-242','name':'Bahamas'},
  {'flag':'🇧🇭','code':'+973','name':'Bahrain'},
  {'flag':'🇧🇩','code':'+880','name':'Bangladesh'},
  {'flag':'🇧🇧','code':'+1-246','name':'Barbados'},
  {'flag':'🇧🇾','code':'+375','name':'Belarus'},
  {'flag':'🇧🇪','code':'+32','name':'Belgium'},
  {'flag':'🇧🇿','code':'+501','name':'Belize'},
  {'flag':'🇧🇯','code':'+229','name':'Benin'},
  {'flag':'🇧🇹','code':'+975','name':'Bhutan'},
  {'flag':'🇧🇴','code':'+591','name':'Bolivia'},
  {'flag':'🇧🇦','code':'+387','name':'Bosnia and Herzegovina'},
  {'flag':'🇧🇼','code':'+267','name':'Botswana'},
  {'flag':'🇧🇷','code':'+55','name':'Brazil'},
  {'flag':'🇧🇳','code':'+673','name':'Brunei'},
  {'flag':'🇧🇬','code':'+359','name':'Bulgaria'},
  {'flag':'🇧🇫','code':'+226','name':'Burkina Faso'},
  {'flag':'🇧🇮','code':'+257','name':'Burundi'},
  {'flag':'🇨🇻','code':'+238','name':'Cabo Verde'},
  {'flag':'🇰🇭','code':'+855','name':'Cambodia'},
  {'flag':'🇨🇲','code':'+237','name':'Cameroon'},
  {'flag':'🇨🇦','code':'+1','name':'Canada'},
  {'flag':'🇨🇫','code':'+236','name':'Central African Republic'},
  {'flag':'🇹🇩','code':'+235','name':'Chad'},
  {'flag':'🇨🇱','code':'+56','name':'Chile'},
  {'flag':'🇨🇳','code':'+86','name':'China'},
  {'flag':'🇨🇴','code':'+57','name':'Colombia'},
  {'flag':'🇰🇲','code':'+269','name':'Comoros'},
  {'flag':'🇨🇬','code':'+242','name':'Congo'},
  {'flag':'🇨🇩','code':'+243','name':'DR Congo'},
  {'flag':'🇨🇷','code':'+506','name':'Costa Rica'},
  {'flag':'🇨🇮','code':'+225','name':'Ivory Coast'},
  {'flag':'🇭🇷','code':'+385','name':'Croatia'},
  {'flag':'🇨🇺','code':'+53','name':'Cuba'},
  {'flag':'🇨🇾','code':'+357','name':'Cyprus'},
  {'flag':'🇨🇿','code':'+420','name':'Czechia'},
  {'flag':'🇩🇰','code':'+45','name':'Denmark'},
  {'flag':'🇩🇯','code':'+253','name':'Djibouti'},
  {'flag':'🇩🇲','code':'+1-767','name':'Dominica'},
  {'flag':'🇩🇴','code':'+1-809','name':'Dominican Republic'},
  {'flag':'🇪🇨','code':'+593','name':'Ecuador'},
  {'flag':'🇪🇬','code':'+20','name':'Egypt'},
  {'flag':'🇸🇻','code':'+503','name':'El Salvador'},
  {'flag':'🇬🇶','code':'+240','name':'Equatorial Guinea'},
  {'flag':'🇪🇷','code':'+291','name':'Eritrea'},
  {'flag':'🇪🇪','code':'+372','name':'Estonia'},
  {'flag':'🇸🇿','code':'+268','name':'Eswatini'},
  {'flag':'🇪🇹','code':'+251','name':'Ethiopia'},
  {'flag':'🇫🇯','code':'+679','name':'Fiji'},
  {'flag':'🇫🇮','code':'+358','name':'Finland'},
  {'flag':'🇫🇷','code':'+33','name':'France'},
  {'flag':'🇬🇦','code':'+241','name':'Gabon'},
  {'flag':'🇬🇲','code':'+220','name':'Gambia'},
  {'flag':'🇬🇪','code':'+995','name':'Georgia'},
  {'flag':'🇩🇪','code':'+49','name':'Germany'},
  {'flag':'🇬🇭','code':'+233','name':'Ghana'},
  {'flag':'🇬🇷','code':'+30','name':'Greece'},
  {'flag':'🇬🇩','code':'+1-473','name':'Grenada'},
  {'flag':'🇬🇹','code':'+502','name':'Guatemala'},
  {'flag':'🇬🇳','code':'+224','name':'Guinea'},
  {'flag':'🇬🇼','code':'+245','name':'Guinea-Bissau'},
  {'flag':'🇬🇾','code':'+592','name':'Guyana'},
  {'flag':'🇭🇹','code':'+509','name':'Haiti'},
  {'flag':'🇭🇳','code':'+504','name':'Honduras'},
  {'flag':'🇭🇺','code':'+36','name':'Hungary'},
  {'flag':'🇮🇸','code':'+354','name':'Iceland'},
  {'flag':'🇮🇳','code':'+91','name':'India'},
  {'flag':'🇮🇩','code':'+62','name':'Indonesia'},
  {'flag':'🇮🇷','code':'+98','name':'Iran'},
  {'flag':'🇮🇶','code':'+964','name':'Iraq'},
  {'flag':'🇮🇪','code':'+353','name':'Ireland'},
  {'flag':'🇮🇱','code':'+972','name':'Israel'},
  {'flag':'🇮🇹','code':'+39','name':'Italy'},
  {'flag':'🇯🇲','code':'+1-876','name':'Jamaica'},
  {'flag':'🇯🇵','code':'+81','name':'Japan'},
  {'flag':'🇯🇴','code':'+962','name':'Jordan'},
  {'flag':'🇰🇿','code':'+7','name':'Kazakhstan'},
  {'flag':'🇰🇪','code':'+254','name':'Kenya'},
  {'flag':'🇰🇮','code':'+686','name':'Kiribati'},
  {'flag':'🇰🇵','code':'+850','name':'North Korea'},
  {'flag':'🇰🇷','code':'+82','name':'South Korea'},
  {'flag':'🇰🇼','code':'+965','name':'Kuwait'},
  {'flag':'🇰🇬','code':'+996','name':'Kyrgyzstan'},
  {'flag':'🇱🇦','code':'+856','name':'Laos'},
  {'flag':'🇱🇻','code':'+371','name':'Latvia'},
  {'flag':'🇱🇧','code':'+961','name':'Lebanon'},
  {'flag':'🇱🇸','code':'+266','name':'Lesotho'},
  {'flag':'🇱🇷','code':'+231','name':'Liberia'},
  {'flag':'🇱🇾','code':'+218','name':'Libya'},
  {'flag':'🇱🇮','code':'+423','name':'Liechtenstein'},
  {'flag':'🇱🇹','code':'+370','name':'Lithuania'},
  {'flag':'🇱🇺','code':'+352','name':'Luxembourg'},
  {'flag':'🇲🇬','code':'+261','name':'Madagascar'},
  {'flag':'🇲🇼','code':'+265','name':'Malawi'},
  {'flag':'🇲🇾','code':'+60','name':'Malaysia'},
  {'flag':'🇲🇻','code':'+960','name':'Maldives'},
  {'flag':'🇲🇱','code':'+223','name':'Mali'},
  {'flag':'🇲🇹','code':'+356','name':'Malta'},
  {'flag':'🇲🇭','code':'+692','name':'Marshall Islands'},
  {'flag':'🇲🇷','code':'+222','name':'Mauritania'},
  {'flag':'🇲🇺','code':'+230','name':'Mauritius'},
  {'flag':'🇲🇽','code':'+52','name':'Mexico'},
  {'flag':'🇫🇲','code':'+691','name':'Micronesia'},
  {'flag':'🇲🇩','code':'+373','name':'Moldova'},
  {'flag':'🇲🇨','code':'+377','name':'Monaco'},
  {'flag':'🇲🇳','code':'+976','name':'Mongolia'},
  {'flag':'🇲🇪','code':'+382','name':'Montenegro'},
  {'flag':'🇲🇦','code':'+212','name':'Morocco'},
  {'flag':'🇲🇿','code':'+258','name':'Mozambique'},
  {'flag':'🇲🇲','code':'+95','name':'Myanmar'},
  {'flag':'🇳🇦','code':'+264','name':'Namibia'},
  {'flag':'🇳🇷','code':'+674','name':'Nauru'},
  {'flag':'🇳🇵','code':'+977','name':'Nepal'},
  {'flag':'🇳🇱','code':'+31','name':'Netherlands'},
  {'flag':'🇳🇿','code':'+64','name':'New Zealand'},
  {'flag':'🇳🇮','code':'+505','name':'Nicaragua'},
  {'flag':'🇳🇪','code':'+227','name':'Niger'},
  {'flag':'🇳🇬','code':'+234','name':'Nigeria'},
  {'flag':'🇲🇰','code':'+389','name':'North Macedonia'},
  {'flag':'🇳🇴','code':'+47','name':'Norway'},
  {'flag':'🇴🇲','code':'+968','name':'Oman'},
  {'flag':'🇵🇰','code':'+92','name':'Pakistan'},
  {'flag':'🇵🇼','code':'+680','name':'Palau'},
  {'flag':'🇵🇸','code':'+970','name':'Palestine'},
  {'flag':'🇵🇦','code':'+507','name':'Panama'},
  {'flag':'🇵🇬','code':'+675','name':'Papua New Guinea'},
  {'flag':'🇵🇾','code':'+595','name':'Paraguay'},
  {'flag':'🇵🇪','code':'+51','name':'Peru'},
  {'flag':'🇵🇭','code':'+63','name':'Philippines'},
  {'flag':'🇵🇱','code':'+48','name':'Poland'},
  {'flag':'🇵🇹','code':'+351','name':'Portugal'},
  {'flag':'🇶🇦','code':'+974','name':'Qatar'},
  {'flag':'🇷🇴','code':'+40','name':'Romania'},
  {'flag':'🇷🇺','code':'+7','name':'Russia'},
  {'flag':'🇷🇼','code':'+250','name':'Rwanda'},
  {'flag':'🇰🇳','code':'+1-869','name':'Saint Kitts and Nevis'},
  {'flag':'🇱🇨','code':'+1-758','name':'Saint Lucia'},
  {'flag':'🇻🇨','code':'+1-784','name':'Saint Vincent and the Grenadines'},
  {'flag':'🇼🇸','code':'+685','name':'Samoa'},
  {'flag':'🇸🇲','code':'+378','name':'San Marino'},
  {'flag':'🇸🇹','code':'+239','name':'Sao Tome and Principe'},
  {'flag':'🇸🇦','code':'+966','name':'Saudi Arabia'},
  {'flag':'🇸🇳','code':'+221','name':'Senegal'},
  {'flag':'🇷🇸','code':'+381','name':'Serbia'},
  {'flag':'🇸🇨','code':'+248','name':'Seychelles'},
  {'flag':'🇸🇱','code':'+232','name':'Sierra Leone'},
  {'flag':'🇸🇬','code':'+65','name':'Singapore'},
  {'flag':'🇸🇰','code':'+421','name':'Slovakia'},
  {'flag':'🇸🇮','code':'+386','name':'Slovenia'},
  {'flag':'🇸🇧','code':'+677','name':'Solomon Islands'},
  {'flag':'🇸🇴','code':'+252','name':'Somalia'},
  {'flag':'🇿🇦','code':'+27','name':'South Africa'},
  {'flag':'🇸🇸','code':'+211','name':'South Sudan'},
  {'flag':'🇪🇸','code':'+34','name':'Spain'},
  {'flag':'🇱🇰','code':'+94','name':'Sri Lanka'},
  {'flag':'🇸🇩','code':'+249','name':'Sudan'},
  {'flag':'🇸🇷','code':'+597','name':'Suriname'},
  {'flag':'🇸🇪','code':'+46','name':'Sweden'},
  {'flag':'🇨🇭','code':'+41','name':'Switzerland'},
  {'flag':'🇸🇾','code':'+963','name':'Syria'},
  {'flag':'🇹🇼','code':'+886','name':'Taiwan'},
  {'flag':'🇹🇯','code':'+992','name':'Tajikistan'},
  {'flag':'🇹🇿','code':'+255','name':'Tanzania'},
  {'flag':'🇹🇭','code':'+66','name':'Thailand'},
  {'flag':'🇹🇱','code':'+670','name':'Timor-Leste'},
  {'flag':'🇹🇬','code':'+228','name':'Togo'},
  {'flag':'🇹🇴','code':'+676','name':'Tonga'},
  {'flag':'🇹🇹','code':'+1-868','name':'Trinidad and Tobago'},
  {'flag':'🇹🇳','code':'+216','name':'Tunisia'},
  {'flag':'🇹🇷','code':'+90','name':'Turkey'},
  {'flag':'🇹🇲','code':'+993','name':'Turkmenistan'},
  {'flag':'🇹🇻','code':'+688','name':'Tuvalu'},
  {'flag':'🇺🇬','code':'+256','name':'Uganda'},
  {'flag':'🇺🇦','code':'+380','name':'Ukraine'},
  {'flag':'🇦🇪','code':'+971','name':'United Arab Emirates'},
  {'flag':'🇬🇧','code':'+44','name':'United Kingdom'},
  {'flag':'🇺🇸','code':'+1','name':'United States'},
  {'flag':'🇺🇾','code':'+598','name':'Uruguay'},
  {'flag':'🇺🇿','code':'+998','name':'Uzbekistan'},
  {'flag':'🇻🇺','code':'+678','name':'Vanuatu'},
  {'flag':'🇻🇦','code':'+39','name':'Vatican City'},
  {'flag':'🇻🇪','code':'+58','name':'Venezuela'},
  {'flag':'🇻🇳','code':'+84','name':'Vietnam'},
  {'flag':'🇾🇪','code':'+967','name':'Yemen'},
  {'flag':'🇿🇲','code':'+260','name':'Zambia'},
  {'flag':'🇿🇼','code':'+263','name':'Zimbabwe'},
];

Future<String?> showCustomerCountryCodePicker(
  BuildContext context,
  String selectedCode,
) async {
  String search = '';

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (context, setModalState) {
          final query = search.trim().toLowerCase().replaceAll(' ', '');

          final filtered = customerCountryCodes.where((country) {
            if (query.isEmpty) return true;

            final name = country['name']!.toLowerCase();
            final code = country['code']!;
            final cleanCode =
                code.replaceAll('+', '').replaceAll('-', '');

            final cleanQuery =
                query.replaceAll('+', '').replaceAll('-', '');

            return name.contains(query) ||
                code.contains(query) ||
                cleanCode.contains(cleanQuery);
          }).toList();

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.75,
                child: Column(
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: ghataT(context, 'Search country or code'),
                        hintText: ghataT(context, 'Afghanistan or +93'),
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) {
                        setModalState(() => search = value);
                      },
                    ),
                    SizedBox(height: 12),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(ghataT(context, 'No country found.')),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final country = filtered[index];
                                final code = country['code']!;
                                final selected = code == selectedCode;

                                return ListTile(
                                  leading: ghataCountryFlagWidget(
                                    country['flag']!,
                                    width: 32,
                                    height: 22,
                                  ),
                                  title: Text(country['name']!),
                                  subtitle: Text(code),
                                  trailing: selected
                                      ? Icon(Icons.check)
                                      : null,
                                  onTap: () {
                                    Navigator.pop(sheetContext, code);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

Map<String, String> splitCustomerPhone(String? phone) {
  final value = (phone ?? '').trim();

  final codes = [...customerCountryCodes]
    ..sort((a, b) => b['code']!.length.compareTo(a['code']!.length));

  for (final country in codes) {
    final code = country['code']!;
    final compactCode = code.replaceAll('-', '');

    if (value.startsWith(code)) {
      return {'code': code, 'number': value.substring(code.length).trim()};
    }

    if (value.startsWith(compactCode)) {
      return {
        'code': code,
        'number': value.substring(compactCode.length).trim(),
      };
    }
  }

  return {'code': '+93', 'number': value};
}

String buildCustomerPhone(String code, String number) {
  var clean = number
      .trim()
      .replaceAll(' ', '')
      .replaceAll('-', '')
      .replaceAll('(', '')
      .replaceAll(')', '');

  while (clean.startsWith('0')) {
    clean = clean.substring(1);
  }

  if (clean.isEmpty) return '';

  return '${code.replaceAll('-', '')}$clean';
}


String? ghataIsoCountryCodeFromFlag(String flag) {
  final regional = flag.runes
      .where(
        (rune) =>
            rune >= 0x1F1E6 &&
            rune <= 0x1F1FF,
      )
      .toList();

  if (regional.length != 2) return null;

  return String.fromCharCodes(
    regional.map(
      (rune) => 65 + (rune - 0x1F1E6),
    ),
  );
}

Widget ghataCountryFlagWidget(
  String flag, {
  double width = 30,
  double height = 20,
}) {
  final countryCode =
      ghataIsoCountryCodeFromFlag(flag);

  if (countryCode == null) {
    return SizedBox(
      width: width,
      height: height,
      child: const Icon(
        Icons.public,
        size: 17,
      ),
    );
  }

  return ClipRRect(
    borderRadius: BorderRadius.circular(3),
    child: CountryFlag.fromCountryCode(
      countryCode,
      theme: ImageTheme(
        width: width,
        height: height,
        shape: const RoundedRectangle(3),
      ),
    ),
  );
}

Widget ghataPhoneFlagWidget(
  String? phone, {
  double width = 28,
  double height = 18,
}) {
  final split = splitCustomerPhone(phone);
  final code = split['code'] ?? '+93';

  Map<String, String>? matched;

  for (final country in customerCountryCodes) {
    if (country['code'] == code) {
      matched = country;
      break;
    }
  }

  matched ??= customerCountryCodes.firstWhere(
    (country) => country['code'] == '+93',
  );

  return ghataCountryFlagWidget(
    matched['flag'] ?? '',
    width: width,
    height: height,
  );
}

class CustomersScreen extends StatefulWidget {
  CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final Map<String, Future<String?>> customerPhotoFutures =
      <String, Future<String?>>{};

  Future<String?> customerPhotoFuture(String customerId) {
    return customerPhotoFutures.putIfAbsent(
      customerId,
      () => ghataLoadCustomerPhoto(customerId),
    );
  }

  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final addressController = TextEditingController();
  final notesController = TextEditingController();
  final searchController = TextEditingController();

  late Future<List<Map<String, dynamic>>> customersFuture;

  bool isSaving = false;
  String selectedCustomerCountryCode = '+93';
  String? pendingCustomerPhotoPath;

  @override
  void initState() {
    super.initState();
    customersFuture = loadCustomers();
    ghataDataRevision.addListener(_handleRealtimeDataRevision);
  }

  void _handleRealtimeDataRevision() {
    if (!mounted) return;

    // Realtime sync already refreshed SQLite.
    // Re-read customers locally without another cloud request.
    setState(() {
      customersFuture = loadCustomers(refreshCloud: false);
    });
  }

  Future<List<Map<String, dynamic>>> loadCustomers({
    bool refreshCloud = true,
  }) async {
    final local =
        await OfflineDatabase.instance.getRecords('customers');

    // Offline-first: never block this page waiting for Supabase.
    if (refreshCloud) ghataRefreshCustomersCache();

    local.sort(
      (a, b) => (a['full_name']?.toString() ?? '')
          .compareTo(b['full_name']?.toString() ?? ''),
    );

    return local;
  }

  Future<void> addCustomer() async {
    final name = nameController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Customer name is required.'))),
      );
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    setState(() => isSaving = true);

    try {
      final customerId = _ghataUuid.v4();

      await ghataSaveLocal(
        'customers',
        {
          'id': customerId,        'user_id': user.id,
        'full_name': name,
        'phone': phoneController.text.trim().isEmpty
            ? null
            : buildCustomerPhone(
                selectedCustomerCountryCode,
                phoneController.text,
              ),
        'address': addressController.text.trim().isEmpty
            ? null
            : addressController.text.trim(),
        'notes': notesController.text.trim().isEmpty
            ? null
            : notesController.text.trim(),
          'deleted_at': null,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        },
      );

      if (pendingCustomerPhotoPath != null &&
          pendingCustomerPhotoPath!.isNotEmpty) {
        await ghataSaveCustomerPhoto(
          customerId,
          pendingCustomerPhotoPath!,
        );
      }

      nameController.clear();
      phoneController.clear();
      selectedCustomerCountryCode = '+93';
      addressController.clear();
      notesController.clear();
      pendingCustomerPhotoPath = null;

      if (!mounted) return;

      setState(() {});

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Customer added successfully.'))),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${ghataT(context, 'Unable to add customer')}: $e")),
      );
    } finally {
      if (mounted) {
        setState(() => isSaving = false);
      }
    }
  }

  Future<void> editCustomer(Map<String, dynamic> customer) async {
    final id = customer['id']?.toString();
    if (id == null || id.isEmpty) return;

    final nameEditController = TextEditingController(
      text: customer['full_name']?.toString() ?? '',
    );
    final parsedPhone =
        splitCustomerPhone(customer['phone']?.toString());
    String selectedEditCountryCode = parsedPhone['code'] ?? '+93';

    final phoneEditController = TextEditingController(
      text: parsedPhone['number'] ?? '',
    );
    final addressEditController = TextEditingController(
      text: customer['address']?.toString() ?? '',
    );
    final notesEditController = TextEditingController(
      text: customer['notes']?.toString() ?? '',
    );

    String? editPhotoPath =
        await ghataLoadCustomerPhoto(id);
    bool removeCustomerPhoto = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: StatefulBuilder(
          builder: (context, setTitleState) {
            final editName = nameEditController.text.trim();
            final editInitial =
                editName.isEmpty ? '?' : editName.substring(0, 1).toUpperCase();

            return Row(
              children: [
                CircleAvatar(
                  radius: 25,
                  backgroundImage: editPhotoPath != null
                      ? FileImage(File(editPhotoPath!))
                      : null,
                  child: editPhotoPath == null
                      ? Text(
                          editInitial,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      : null,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    ghataT(context, 'Edit Customer'),
                  ),
                ),
              ],
            );
          },
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatefulBuilder(
                builder: (context, setPhotoState) {
                  return Column(
                    children: [
                      GestureDetector(
                        onTap: () async {
                          final path =
                              await ghataPickCustomerPhoto(context);

                          if (path != null) {
                            setPhotoState(() {
                              editPhotoPath = path;
                              removeCustomerPhoto = false;
                            });
                          }
                        },
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            CircleAvatar(
                              radius: 42,
                              backgroundImage:
                                  editPhotoPath != null
                                      ? FileImage(File(editPhotoPath!))
                                      : null,
                              child: editPhotoPath == null
                                  ? Icon(
                                      Icons.person_outline,
                                      size: 38,
                                    )
                                  : null,
                            ),
                            Positioned(
                              right: -3,
                              bottom: -3,
                              child: CircleAvatar(
                                radius: 15,
                                child: Icon(
                                  Icons.camera_alt_rounded,
                                  size: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () async {
                          final path =
                              await ghataPickCustomerPhoto(context);

                          if (path != null) {
                            setPhotoState(() {
                              editPhotoPath = path;
                              removeCustomerPhoto = false;
                            });
                          }
                        },
                        icon: Icon(Icons.photo_camera_outlined),
                        label: Text(
                          ghataT(context, 'Change Photo'),
                        ),
                      ),
                      if (editPhotoPath != null)
                        TextButton.icon(
                          onPressed: () {
                            setPhotoState(() {
                              editPhotoPath = null;
                              removeCustomerPhoto = true;
                            });
                          },
                          icon: Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                          ),
                          label: Text(
                            ghataT(context, 'Remove Photo'),
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                    ],
                  );
                },
              ),
              SizedBox(height: 10),
              TextField(
                controller: nameEditController,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Customer Name'),
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 12),
              StatefulBuilder(
                builder: (context, setDialogState) {
                  final selectedCountry = customerCountryCodes.firstWhere(
                    (country) =>
                        country['code'] == selectedEditCountryCode,
                    orElse: () => customerCountryCodes.first,
                  );

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 115,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            minimumSize: Size.fromHeight(56),
                            padding: EdgeInsets.symmetric(horizontal: 8),
                          ),
                          onPressed: () async {
                            final code =
                                await showCustomerCountryCodePicker(
                              context,
                              selectedEditCountryCode,
                            );

                            if (code != null) {
                              setDialogState(() {
                                selectedEditCountryCode = code;
                              });
                            }
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ghataCountryFlagWidget(
                                selectedCountry['flag']!,
                                width: 28,
                                height: 18,
                              ),
                              SizedBox(width: 6),
                              Text(selectedEditCountryCode),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: phoneEditController,
                          keyboardType: TextInputType.phone,
                          decoration: InputDecoration(
                            labelText: ghataT(context, 'Phone Number'),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              SizedBox(height: 12),
              TextField(
                controller: addressEditController,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Address'),
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 12),
              TextField(
                controller: notesEditController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Notes'),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(ghataT(context, 'Save Changes')),
          ),
        ],
      ),
    );

    if (saved != true) {
      nameEditController.dispose();
      phoneEditController.dispose();
      addressEditController.dispose();
      notesEditController.dispose();
      return;
    }

    final name = nameEditController.text.trim();

    if (name.isEmpty) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Customer name is required.')),
        ),
      );

      nameEditController.dispose();
      phoneEditController.dispose();
      addressEditController.dispose();
      notesEditController.dispose();
      return;
    }

    try {
      await OfflineDatabase.instance.updateLocalRecord(
        'customers',
        id,
        {
          'full_name': name,
          'phone': phoneEditController.text.trim().isEmpty
              ? null
              : buildCustomerPhone(
                  selectedEditCountryCode,
                  phoneEditController.text,
                ),
          'address': addressEditController.text.trim().isEmpty
              ? null
              : addressEditController.text.trim(),
          'notes': notesEditController.text.trim().isEmpty
              ? null
              : notesEditController.text.trim(),
        },
      );

      if (removeCustomerPhoto) {
        await ghataDeleteCustomerPhoto(id);
      } else if (editPhotoPath != null &&
          editPhotoPath!.isNotEmpty) {
        final existing =
            await ghataLoadCustomerPhoto(id);

        if (existing != editPhotoPath) {
          await ghataSaveCustomerPhoto(
            id,
            editPhotoPath!,
          );
        }
      }

      final localTransactions =
          await OfflineDatabase.instance.getRecords('transactions');

      for (final tx in localTransactions) {
        if (tx['customer_id']?.toString() == id) {
          final txId = tx['id']?.toString();
          if (txId != null && txId.isNotEmpty) {
            await OfflineDatabase.instance.updateLocalRecord(
              'transactions',
              txId,
              {'customer_name': name},
            );
          }
        }
      }

      final localExchanges =
          await OfflineDatabase.instance.getRecords('exchanges');

      for (final ex in localExchanges) {
        if (ex['customer_id']?.toString() == id) {
          final exId = ex['id']?.toString();
          if (exId != null && exId.isNotEmpty) {
            await OfflineDatabase.instance.updateLocalRecord(
              'exchanges',
              exId,
              {'customer_name': name},
            );
          }
        }
      }

      ghataTrySync();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Customer updated successfully.')),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to update customer')}: $e"),
        ),
      );
    } finally {
      nameEditController.dispose();
      phoneEditController.dispose();
      addressEditController.dispose();
      notesEditController.dispose();
    }
  }

  Future<void> deleteCustomer(Map<String, dynamic> customer) async {
    final id = customer['id']?.toString();
    if (id == null || id.isEmpty) return;

    final name = customer['full_name']?.toString() ?? 'Customer';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(ghataT(context, 'Move to Recycle Bin?')),
        content: Text(
          'Are you sure you want to delete $name? '
          'Existing transactions will remain, but they will no longer be linked to this customer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(ghataT(context, 'Move to Recycle Bin')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {

      await ghataSoftDeleteLocal('customers', id);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Customer moved to Recycle Bin. You can restore it within 30 days.')),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to delete customer')}: $e"),
        ),
      );
    }
  }


  @override
  void dispose() {
    ghataDataRevision.removeListener(_handleRealtimeDataRevision);
    nameController.dispose();
    phoneController.dispose();
    addressController.dispose();
    notesController.dispose();
    searchController.dispose();
    super.dispose();
  }

  Future<void> showAddCustomerDialog() async {
    nameController.clear();
    phoneController.clear();
    addressController.clear();
    notesController.clear();
    selectedCustomerCountryCode = '+93';
    pendingCustomerPhotoPath = null;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(ghataT(context, 'Add Customer')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () async {
                    final path =
                        await ghataPickCustomerPhoto(context);

                    if (path != null) {
                      setDialogState(() {
                        pendingCustomerPhotoPath = path;
                      });
                    }
                  },
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CircleAvatar(
                        radius: 45,
                        backgroundImage:
                            pendingCustomerPhotoPath != null
                                ? FileImage(
                                    File(pendingCustomerPhotoPath!),
                                  )
                                : null,
                        child: pendingCustomerPhotoPath == null
                            ? Icon(
                                Icons.person_outline,
                                size: 42,
                              )
                            : null,
                      ),
                      Positioned(
                        right: -3,
                        bottom: -3,
                        child: CircleAvatar(
                          radius: 16,
                          child: Icon(
                            Icons.camera_alt_rounded,
                            size: 17,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () async {
                    final path =
                        await ghataPickCustomerPhoto(context);

                    if (path != null) {
                      setDialogState(() {
                        pendingCustomerPhotoPath = path;
                      });
                    }
                  },
                  icon: Icon(Icons.add_a_photo_outlined),
                  label: Text(ghataT(context, 'Customer Photo')),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Customer Name'),
                    prefixIcon: Icon(Icons.person_outline),
                    border: OutlineInputBorder(),
                  ),
                ),
                SizedBox(height: 12),
                Row(
                  children: [
                    SizedBox(
                      width: 112,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: Size.fromHeight(56),
                        ),
                        onPressed: () async {
                          final code =
                              await showCustomerCountryCodePicker(
                            context,
                            selectedCustomerCountryCode,
                          );
                          if (code != null) {
                            setDialogState(() {
                              selectedCustomerCountryCode = code;
                            });
                          }
                        },
                        child: Text(
                          '${customerCountryCodes.firstWhere(
                            (c) => c['code'] ==
                                selectedCustomerCountryCode,
                            orElse: () =>
                                customerCountryCodes.first,
                          )['flag']} $selectedCustomerCountryCode',
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: ghataT(context, 'Phone Number'),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 12),
                TextField(
                  controller: addressController,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Address'),
                    prefixIcon: Icon(Icons.location_on_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Notes'),
                    prefixIcon: Icon(Icons.notes_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(ghataT(context, 'Cancel')),
            ),
            FilledButton.icon(
              onPressed: isSaving
                  ? null
                  : () async {
                      if (nameController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content:
                                Text(ghataT(context, 'Customer name is required.')),
                          ),
                        );
                        return;
                      }

                      await addCustomer();

                      if (mounted && dialogContext.mounted) {
                        Navigator.pop(dialogContext);
                      }
                    },
              icon: Icon(Icons.person_add_alt_1),
              label: Text(ghataT(context, 'Add Customer')),
            ),
          ],
        ),
      ),
    );
  }

  String customerInitial(String name) {
    final value = name.trim();
    if (value.isEmpty) return '?';
    return value.substring(0, 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF123D2B),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text(
          ghataT(context, 'Customers'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: showAddCustomerDialog,
              icon: Icon(Icons.add),
              label: Text(ghataT(context, 'Add')),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            setState(() {});
          },
          child: ListView(
            padding: EdgeInsets.all(16),
            children: [
              TextField(
                controller: searchController,
                decoration: InputDecoration(
                  hintText: ghataT(context, 'Search customers...'),
                  prefixIcon: Icon(Icons.search),
                  suffixIcon: searchController.text.isEmpty
                      ? null
                      : IconButton(
                          icon: Icon(Icons.close),
                          onPressed: () {
                            searchController.clear();
                            setState(() {});
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: 16),

              FutureBuilder<List<Map<String, dynamic>>>(
                future: customersFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState ==
                      ConnectionState.waiting) {
                    return Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }

                  if (snapshot.hasError) {
                    return Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        "${ghataT(context, 'Unable to load customers')}: ${snapshot.error}",
                      ),
                    );
                  }

                  final customers = snapshot.data ?? [];
                  final query =
                      searchController.text.trim().toLowerCase();

                  final filtered = customers.where((customer) {
                    if (query.isEmpty) return true;

                    final name = customer['full_name']
                            ?.toString()
                            .toLowerCase() ??
                        '';
                    final phone = customer['phone']
                            ?.toString()
                            .toLowerCase() ??
                        '';
                    final address = customer['address']
                            ?.toString()
                            .toLowerCase() ??
                        '';

                    return name.contains(query) ||
                        phone.contains(query) ||
                        address.contains(query);
                  }).toList();

                  if (customers.isEmpty) {
                    return Padding(
                      padding: EdgeInsets.symmetric(vertical: 60),
                      child: Column(
                        children: [
                          Icon(
                            Icons.people_outline,
                            size: 64,
                            color: Colors.grey,
                          ),
                          SizedBox(height: 12),
                          Text(
                            'No customers yet.',
                            style: TextStyle(fontSize: 17),
                          ),
                        ],
                      ),
                    );
                  }

                  if (filtered.isEmpty) {
                    return Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(
                        child: Text(ghataT(context, 'No matching customers.')),
                      ),
                    );
                  }

                  return Column(
                    children: filtered.map((customer) {
                      final name =
                          customer['full_name']?.toString() ?? '';
                      final phone =
                          customer['phone']?.toString() ?? '';
                      final address =
                          customer['address']?.toString() ?? '';

                      return Card(
                        margin: EdgeInsets.only(bottom: 10),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    CustomerLedgerScreen(
                                  customerId:
                                      customer['id'].toString(),
                                  customerName: name,
                                ),
                              ),
                            );
                            if (mounted) setState(() {});
                          },
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                FutureBuilder<String?>(
                                  future: customerPhotoFuture(
                                    customer['id'].toString(),
                                  ),
                                  builder: (context, photoSnapshot) {
                                    final photoPath =
                                        photoSnapshot.data;

                                    return CircleAvatar(
                                      radius: 27,
                                      backgroundImage:
                                          photoPath != null
                                              ? FileImage(
                                                  File(photoPath),
                                                )
                                              : null,
                                      child: photoPath == null
                                          ? Text(
                                              customerInitial(name),
                                              style: TextStyle(
                                                fontWeight:
                                                    FontWeight.bold,
                                              ),
                                            )
                                          : null,
                                    );
                                  },
                                ),
                                SizedBox(width: 13),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        style: TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      if (phone.isNotEmpty) ...[
                      SizedBox(height: 3),
                      Row(
                        children: [
                          ghataPhoneFlagWidget(
                            phone,
                            width: 22,
                            height: 14,
                          ),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              phone,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (address.isNotEmpty) ...[
                                        SizedBox(height: 2),
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.location_on_outlined,
                                              size: 15,
                                            ),
                                            SizedBox(width: 3),
                                            Expanded(
                                              child: Text(
                                                address,
                                                maxLines: 1,
                                                overflow: TextOverflow
                                                    .ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  onSelected: (value) {
                                    if (value == 'edit') {
                                      editCustomer(customer);
                                    } else if (value == 'delete') {
                                      deleteCustomer(customer);
                                    }
                                  },
                                  itemBuilder: (_) =>  [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: ListTile(
                                        leading:
                                            Icon(Icons.edit_outlined),
                                        title: Text(ghataT(context, 'Edit')),
                                        contentPadding:
                                            EdgeInsets.zero,
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: ListTile(
                                        leading:
                                            Icon(Icons.delete_outline),
                                        title: Text(ghataT(context, 'Delete')),
                                        contentPadding:
                                            EdgeInsets.zero,
                                      ),
                                    ),
                                  ],
                                ),
                                Icon(Icons.chevron_right),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
              SizedBox(height: 80),
            ],
          ),
        ),
      ),

      bottomNavigationBar: const _GhataAppBottomNav(
        selectedIndex: 1,
      ),
);
  }

}

class CustomerLedgerScreen extends StatefulWidget {
  final String customerId;
  final String customerName;

  CustomerLedgerScreen({
    super.key,
    required this.customerId,
    required this.customerName,
  });

  @override
  State<CustomerLedgerScreen> createState() => _CustomerLedgerScreenState();
}

class _CustomerLedgerScreenState extends State<CustomerLedgerScreen> {
  String get customerId => widget.customerId;
  String get customerName => widget.customerName;

  Map<String, dynamic>? customerProfile;
  String? customerPhotoPath;
  String selectedLedgerCurrency = 'ALL';

  late Future<List<Map<String, dynamic>>> customerTransactionsFuture;

  @override
  void initState() {
    super.initState();
    customerTransactionsFuture = loadCustomerTransactions();
    refreshCustomerProfile();
    ghataDataRevision.addListener(_handleRealtimeDataRevision);
  }

  void _handleRealtimeDataRevision() {
    if (!mounted) return;

    // Realtime sync already refreshed SQLite.
    // Re-read this customer's local data only.
    setState(() {
      customerTransactionsFuture =
          loadCustomerTransactions(refreshCloud: false);
    });

    refreshCustomerProfile(refreshCloud: false);
  }

  Future<void> refreshCustomerProfile({bool refreshCloud = true}) async {
    final profile = await loadCustomerProfile(refreshCloud: refreshCloud);
    final photo = await ghataLoadCustomerPhoto(
      customerId,
      onBackgroundLoaded: (localPath) {
        if (!mounted) return;
        setState(() {
          customerPhotoPath = localPath;
        });
      },
    );

    if (!mounted) return;

    setState(() {
      customerProfile = profile;
      if (photo != null && photo.isNotEmpty) {
        customerPhotoPath = photo;
      }
    });
  }

  Future<Map<String, dynamic>?> loadCustomerProfile({
    bool refreshCloud = true,
  }) async {
  if (refreshCloud) ghataRefreshOfflineCache();

  final customers = await OfflineDatabase.instance.getRecords(
    'customers',
  );

  for (final customer in customers) {
    if (customer['id']?.toString() == customerId) {
      return customer;
    }
  }

  return null;
}

  Future<List<Map<String, dynamic>>> loadCustomerTransactions({
    bool refreshCloud = true,
  }) async {
    if (refreshCloud) ghataRefreshOfflineCache();

    final local =
        await OfflineDatabase.instance.getRecords('transactions');

    final allowed = {
      'money_in',
      'money_out',
    };

    final rows = local.where((row) {
      return row['customer_id']?.toString() == customerId &&
          allowed.contains(
            row['transaction_type']?.toString() ?? '',
          );
    }).map((row) => Map<String, dynamic>.from(row)).toList();

    // --------------------------------------------------
    // Add customer-linked Exchange as virtual ledger rows.
    // We DO NOT create duplicate transaction records.
    // Cashbox continues to use the original exchange entries.
    // --------------------------------------------------
    final exchanges =
        await OfflineDatabase.instance.getRecords('exchanges');

    final exchangeEntries =
        await OfflineDatabase.instance.getRecords('exchange_entries');

    final customerExchanges = exchanges.where((exchange) {
      final deletedAt = exchange['deleted_at']?.toString() ?? '';

      return exchange['customer_id']?.toString() == customerId &&
          deletedAt.isEmpty;
    }).toList();

    for (final exchange in customerExchanges) {
      final exchangeId = exchange['id']?.toString() ?? '';
      if (exchangeId.isEmpty) continue;

      final entries = exchangeEntries.where((entry) {
        return entry['exchange_id']?.toString() == exchangeId;
      }).toList();

      Map<String, dynamic>? outEntry;
      Map<String, dynamic>? inEntry;

      for (final entry in entries) {
        final entryType = entry['entry_type']?.toString() ?? '';

        if (entryType == 'money_out' && outEntry == null) {
          outEntry = entry;
        }

        if (entryType == 'money_in' && inEntry == null) {
          inEntry = entry;
        }
      }

      final outAmount =
          double.tryParse(outEntry?['amount']?.toString() ?? '') ?? 0;

      final inAmount =
          double.tryParse(inEntry?['amount']?.toString() ?? '') ?? 0;

      final outCurrency =
          outEntry?['currency']?.toString().toUpperCase() ?? '';

      final inCurrency =
          inEntry?['currency']?.toString().toUpperCase() ?? '';

      final exchangeDate =
          exchange['exchange_date']?.toString() ?? '';

      final exchangeTime =
          exchange['exchange_time']?.toString() ?? '';

      final createdAt =
          exchange['created_at']?.toString() ?? '';

      final notes =
          exchange['notes']?.toString().trim() ?? '';

      final exchangeDescription =
          outAmount > 0 &&
                  inAmount > 0 &&
                  outCurrency.isNotEmpty &&
                  inCurrency.isNotEmpty
              ? 'Exchange (${outAmount % 1 == 0 ? outAmount.toStringAsFixed(0) : outAmount.toStringAsFixed(2)} $outCurrency → ${inAmount % 1 == 0 ? inAmount.toStringAsFixed(0) : inAmount.toStringAsFixed(2)} $inCurrency)'
              : 'Exchange';

      final description = notes.isEmpty
          ? exchangeDescription
          : '$exchangeDescription • $notes';

      if (outEntry != null &&
          outAmount > 0 &&
          outCurrency.isNotEmpty) {
        rows.add({
          'id': 'exchange_out_$exchangeId',
          'exchange_id': exchangeId,
          'customer_id': customerId,
          'customer_name':
              exchange['customer_name']?.toString() ?? customerName,
          'transaction_date': exchangeDate,
          'transaction_time': exchangeTime,
          'transaction_type': 'money_out',
          'amount': outAmount,
          'currency': outCurrency,
          'description': description,
          'reference_no': 'Exchange',
          'created_at': createdAt,
          '_is_exchange': true,
          '_exchange_leg': 'out',
        });
      }

      if (inEntry != null &&
          inAmount > 0 &&
          inCurrency.isNotEmpty) {
        rows.add({
          'id': 'exchange_in_$exchangeId',
          'exchange_id': exchangeId,
          'customer_id': customerId,
          'customer_name':
              exchange['customer_name']?.toString() ?? customerName,
          'transaction_date': exchangeDate,
          'transaction_time': exchangeTime,
          'transaction_type': 'money_in',
          'amount': inAmount,
          'currency': inCurrency,
          'description': description,
          'reference_no': 'Exchange',
          'created_at': createdAt,
          '_is_exchange': true,
          '_exchange_leg': 'in',
        });
      }
    }

    rows.sort((a, b) {
      final ad =
          '${a['transaction_date'] ?? ''} '
          '${a['transaction_time'] ?? ''} '
          '${a['created_at'] ?? ''}';

      final bd =
          '${b['transaction_date'] ?? ''} '
          '${b['transaction_time'] ?? ''} '
          '${b['created_at'] ?? ''}';

      return bd.compareTo(ad);
    });

    return rows;
  }

  Map<String, double> calculateBalances(
    List<Map<String, dynamic>> transactions,
  ) {
    final balances = <String, double>{};

    for (final transaction in transactions) {
      final currency =
          transaction['currency']?.toString().toUpperCase() ?? '';
      final type =
          transaction['transaction_type']?.toString() ?? '';
      final amount =
          double.tryParse(transaction['amount']?.toString() ?? '0') ?? 0;

      if (currency.isEmpty) continue;

      balances.putIfAbsent(currency, () => 0);

      switch (type) {
        case 'money_in':
          balances[currency] = balances[currency]! + amount;
          break;

        case 'money_out':
          balances[currency] = balances[currency]! - amount;
          break;


        default:
          break;
      }
    }

    return balances;
  }

  Future<void> showCustomerTransactionActions(
    Map<String, dynamic> transaction,
  ) async {
    if (transaction['_is_exchange'] == true) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(ghataT(context, 'Exchange')),
          content: Text(
            ghataT(
              context,
              'Open Exchange to edit this transaction.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(ghataT(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                openCustomerExchange();
              },
              child: Text(ghataT(context, 'Exchange')),
            ),
          ],
        ),
      );
      return;
    }

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.edit_outlined),
              title: Text(ghataT(context, 'Edit')),
              onTap: () => Navigator.pop(sheetContext, 'edit'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red),
              title: Text(
                ghataT(context, 'Delete'),
                style: TextStyle(color: Colors.red),
              ),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;

    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(ghataT(context, 'Delete')),
          content: Text(
            ghataT(
              context,
              'Are you sure you want to delete this transaction?',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(ghataT(context, 'Cancel')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(ghataT(context, 'Delete')),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;

      final updated = Map<String, dynamic>.from(transaction)
        ..remove('_ledger_in')
        ..remove('_ledger_out')
        ..remove('_ledger_balance');

      updated['deleted_at'] = DateTime.now().toIso8601String();

      await ghataSaveLocal('transactions', updated);
      ghataTrySync();

      if (!mounted) return;
      setState(() {});
      return;
    }

    if (action != 'edit') return;

    final amountController = TextEditingController(
      text: transaction['amount']?.toString() ?? '',
    );
    final descriptionController = TextEditingController(
      text: transaction['description']?.toString() ?? '',
    );
    final noteController = TextEditingController(
      text: transaction['reference_no']?.toString() ?? '',
    );

    const currencies = [
      'AFN',
      'PKR',
      'USD',
      'EUR',
      'GBP',
      'AED',
      'SAR',
      'KWD',
      'QAR',
      'OMR',
      'TRY',
      'CNY',
      'INR',
      'IRR',
    ];

    var currency =
        transaction['currency']?.toString().toUpperCase() ?? 'AFN';

    if (!currencies.contains(currency)) {
      currency = 'AFN';
    }

    var selectedDate = DateTime.tryParse(
          transaction['transaction_date']?.toString() ?? '',
        ) ??
        DateTime.now();

    final rawTime =
        transaction['transaction_time']?.toString() ?? '';

    var selectedTime = TimeOfDay.now();

    if (rawTime.length >= 5) {
      final parts = rawTime.substring(0, 5).split(':');
      final hour =
          parts.isNotEmpty ? int.tryParse(parts[0]) : null;
      final minute =
          parts.length > 1 ? int.tryParse(parts[1]) : null;

      if (hour != null && minute != null) {
        selectedTime = TimeOfDay(
          hour: hour,
          minute: minute,
        );
      }
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(ghataT(context, 'Edit')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: amountController,
                  keyboardType:
                      TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Amount'),
                  ),
                ),
                SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: currency,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Currency'),
                  ),
                  items: currencies
                      .map(
                        (code) => DropdownMenuItem<String>(
                          value: code,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ghataCurrencyFlagWidget(code),
                              SizedBox(width: 8),
                              Text(code),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() {
                      currency = value;
                    });
                  },
                ),
                SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  decoration: InputDecoration(
                    labelText:
                        ghataT(context, 'Description'),
                  ),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Note'),
                  ),
                ),
                SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading:
                      Icon(Icons.calendar_today_outlined),
                  title: Text(
                    '${selectedDate.year.toString().padLeft(4, '0')}-'
                    '${selectedDate.month.toString().padLeft(2, '0')}-'
                    '${selectedDate.day.toString().padLeft(2, '0')}',
                  ),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: selectedDate,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );

                    if (picked != null) {
                      setDialogState(() {
                        selectedDate = picked;
                      });
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.access_time),
                  title: Text(
                    '${selectedTime.hour.toString().padLeft(2, '0')}:'
                    '${selectedTime.minute.toString().padLeft(2, '0')}',
                  ),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: selectedTime,
                    );

                    if (picked != null) {
                      setDialogState(() {
                        selectedTime = picked;
                      });
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, false),
              child: Text(ghataT(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                final amount = double.tryParse(
                  amountController.text.trim(),
                );

                if (amount == null ||
                    amount <= 0 ||
                    descriptionController.text
                        .trim()
                        .isEmpty) {
                  return;
                }

                Navigator.pop(dialogContext, true);
              },
              child: Text(ghataT(context, 'Save')),
            ),
          ],
        ),
      ),
    );

    if (saved != true || !mounted) {
      amountController.dispose();
      descriptionController.dispose();
      noteController.dispose();
      return;
    }

    final updated = Map<String, dynamic>.from(transaction)
      ..remove('_ledger_in')
      ..remove('_ledger_out')
      ..remove('_ledger_balance');

    updated['amount'] =
        double.parse(amountController.text.trim());
    updated['currency'] = currency;
    updated['description'] =
        descriptionController.text.trim();
    updated['reference_no'] =
        noteController.text.trim();

    updated['transaction_date'] =
        '${selectedDate.year.toString().padLeft(4, '0')}-'
        '${selectedDate.month.toString().padLeft(2, '0')}-'
        '${selectedDate.day.toString().padLeft(2, '0')}';

    updated['transaction_time'] =
        '${selectedTime.hour.toString().padLeft(2, '0')}:'
        '${selectedTime.minute.toString().padLeft(2, '0')}:00';

    await ghataSaveLocal('transactions', updated);
    ghataTrySync();

    amountController.dispose();
    descriptionController.dispose();
    noteController.dispose();

    if (!mounted) return;
    setState(() {});
  }

  List<Map<String, dynamic>> buildCustomerRunningLedger(
    List<Map<String, dynamic>> transactions,
  ) {
    final ordered =
        List<Map<String, dynamic>>.from(transactions);

    // Oldest first so backdated transactions recalculate
    // every balance that follows them.
    ordered.sort((a, b) {
      final ad =
          '${a['transaction_date'] ?? ''} '
          '${a['transaction_time'] ?? ''} '
          '${a['created_at'] ?? ''}';
      final bd =
          '${b['transaction_date'] ?? ''} '
          '${b['transaction_time'] ?? ''} '
          '${b['created_at'] ?? ''}';

      return ad.compareTo(bd);
    });

    final running = <String, double>{};
    final rows = <Map<String, dynamic>>[];

    for (final transaction in ordered) {
      final currency =
          transaction['currency']?.toString().toUpperCase() ?? '';
      final type =
          transaction['transaction_type']?.toString() ?? '';
      final amount =
          double.tryParse(transaction['amount']?.toString() ?? '0') ?? 0;

      if (currency.isEmpty) continue;

      running.putIfAbsent(currency, () => 0);

      double moneyIn = 0;
      double moneyOut = 0;

      switch (type) {
        case 'money_in':
          moneyIn = amount;
          running[currency] = running[currency]! + amount;
          break;

        case 'money_out':
          moneyOut = amount;
          running[currency] = running[currency]! - amount;
          break;

        default:
          continue;
      }

      rows.add({
        ...transaction,
        '_ledger_in': moneyIn,
        '_ledger_out': moneyOut,
        '_ledger_balance': running[currency],
      });
    }

    // Display newest first, but balances were calculated oldest first.
    return rows.reversed.toList();
  }

  Future<void> openCustomerWhatsApp() async {
    final phone = customerProfile?['phone']?.toString().trim() ?? '';

    var digits = phone.replaceAll(RegExp(r'[^0-9]'), '');

    if (digits.startsWith('00')) {
      digits = digits.substring(2);
    }

    if (digits.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Customer phone number is not available.')),
        ),
      );
      return;
    }

    final name =
        customerProfile?['full_name']?.toString().trim().isNotEmpty == true
            ? customerProfile!['full_name'].toString()
            : customerName;

    final message = Uri.encodeComponent(
      'Hello $name',
    );

    final uri = Uri.parse(
      'https://wa.me/$digits?text=$message',
    );

    try {
      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ghataT(context, 'Unable to open WhatsApp.')),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Unable to open WhatsApp.')),
        ),
      );
    }
  }

  Future<void> openCustomerMoneyEntry(String type) async {
    final profileName =
        customerProfile?['full_name']?.toString().trim().isNotEmpty == true
            ? customerProfile!['full_name'].toString()
            : customerName;

    final amountController = TextEditingController();
    final descriptionController = TextEditingController();
    final noteController = TextEditingController();

    const currencies = [
      ('AFN', '🇦🇫'),
      ('PKR', '🇵🇰'),
      ('USD', '🇺🇸'),
      ('EUR', '🇪🇺'),
      ('GBP', '🇬🇧'),
      ('AED', '🇦🇪'),
      ('SAR', '🇸🇦'),
      ('KWD', '🇰🇼'),
      ('QAR', '🇶🇦'),
      ('OMR', '🇴🇲'),
      ('TRY', '🇹🇷'),
      ('CNY', '🇨🇳'),
      ('INR', '🇮🇳'),
      ('IRR', '🇮🇷'),
    ];

    var selectedCurrency = 'AFN';
    var selectedDate = DateTime.now();
    var selectedTime = TimeOfDay.now();
    var saving = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          String dateText(DateTime date) =>
              '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  type == 'money_in'
                      ? Icons.south_west_rounded
                      : Icons.north_east_rounded,
                  color: type == 'money_in'
                      ? Colors.green
                      : Colors.red,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    ghataT(
                      context,
                      type == 'money_in' ? 'Money In' : 'Money Out',
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLow,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.person_outline),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              profileName,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 14),

                    GhataCalculatorField(
                      controller: amountController,
                      label: ghataT(context, 'Amount'),
                      onChanged: () {},
                    ),
                    SizedBox(height: 12),

                    DropdownButtonFormField<String>(
                      initialValue: selectedCurrency,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: ghataT(context, 'Currency'),
                        prefixIcon: Icon(Icons.payments_outlined),
                        border: OutlineInputBorder(),
                      ),
                      items: currencies
                          .map(
                            (item) => DropdownMenuItem<String>(
                              value: item.$1,
                              child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ghataCurrencyFlagWidget(
                                  item.$1,
                                  width: 26,
                                  height: 18,
                                ),
                                SizedBox(width: 8),
                                Text(item.$1),
                              ],
                            ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          selectedCurrency = value;
                        });
                      },
                    ),
                    SizedBox(height: 12),

                    TextField(
                      controller: descriptionController,
                      maxLines: 2,
                      decoration: InputDecoration(
                        labelText: ghataT(context, 'Description'),
                        hintText: type == 'money_in'
                            ? ghataT(context, 'Cash received / reason')
                            : ghataT(context, 'Cash given / reason'),
                        prefixIcon: Icon(Icons.notes_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: Icon(Icons.calendar_today_outlined),
                            label: Text(dateText(selectedDate)),
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: selectedDate,
                                firstDate: DateTime(2000),
                                lastDate: DateTime(2100),
                              );

                              if (picked != null) {
                                setDialogState(() {
                                  selectedDate = picked;
                                });
                              }
                            },
                          ),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: Icon(Icons.access_time),
                            label: Text(selectedTime.format(context)),
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: selectedTime,
                              );

                              if (picked != null) {
                                setDialogState(() {
                                  selectedTime = picked;
                                });
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 12),

                    TextField(
                      controller: noteController,
                      maxLines: 2,
                      decoration: InputDecoration(
                        labelText: ghataT(context, 'Notes'),
                        prefixIcon: Icon(Icons.edit_note_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed:
                    saving ? null : () => Navigator.pop(dialogContext, false),
                child: Text(ghataT(context, 'Cancel')),
              ),
              FilledButton.icon(
                onPressed: saving
                    ? null
                    : () async {
                        final amount = evaluateCalculatorExpression(
                          amountController.text.trim(),
                        );

                        if (amount == null || amount <= 0) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                ghataT(
                                  context,
                                  'Please enter a valid amount.',
                                ),
                              ),
                            ),
                          );
                          return;
                        }

                        final description =
                            descriptionController.text.trim();

                        if (description.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                ghataT(
                                  context,
                                  'Please fill in all fields',
                                ),
                              ),
                            ),
                          );
                          return;
                        }

                        final user =
                            Supabase.instance.client.auth.currentUser;

                        if (user == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                ghataT(
                                  context,
                                  'You are not logged in.',
                                ),
                              ),
                            ),
                          );
                          return;
                        }

                        setDialogState(() {
                          saving = true;
                        });

                        try {
                          final id = _ghataUuid.v4();
                          final note = noteController.text.trim();

                          await ghataSaveLocal(
                            'transactions',
                            {
                              'id': id,
                              'user_id': user.id,
                              'transaction_date':
                                  dateText(selectedDate),
                              'transaction_time':
                                  '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}:00',
                              'transaction_type': type,
                              'amount': amount,
                              'currency': selectedCurrency,
                              'customer_id': customerId,
                              'customer_name': profileName,
                              'description': description,
                              'reference_no':
                                  note.isEmpty ? null : note,
                              'deleted_at': null,
                              'created_at':
                                  DateTime.now().toUtc().toIso8601String(),
                            },
                          );

                          ghataTrySync();

                          if (!dialogContext.mounted) return;
                          Navigator.pop(dialogContext, true);
                        } catch (e) {
                          if (!dialogContext.mounted) return;

                          setDialogState(() {
                            saving = false;
                          });

                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                "${ghataT(context, 'Unable to save transaction')}: $e",
                              ),
                            ),
                          );
                        }
                      },
                icon: saving
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : Icon(Icons.check_rounded),
                label: Text(ghataT(context, 'Save')),
              ),
            ],
          );
        },
      ),
    );

    amountController.dispose();
    descriptionController.dispose();
    noteController.dispose();

    if (saved == true && mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(context, 'Transaction saved successfully.'),
          ),
        ),
      );
    }
  }

  Future<void> openCustomerExchange() async {
    final profileName =
        customerProfile?['full_name']?.toString().trim().isNotEmpty == true
            ? customerProfile!['full_name'].toString()
            : customerName;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExchangeScreen(
          initialCustomerId: customerId,
          initialCustomerName: profileName,
        ),
      ),
    );

    if (!mounted) return;
    setState(() {});
  }

  Future<void> editProfileCustomer() async {
    final customer = customerProfile;
    if (customer == null) return;

    final nameController = TextEditingController(
      text: customer['full_name']?.toString() ?? '',
    );
    final parsedPhone =
        splitCustomerPhone(customer['phone']?.toString());
    String selectedProfileCountryCode = parsedPhone['code'] ?? '+93';

    final phoneController = TextEditingController(
      text: parsedPhone['number'] ?? '',
    );
    final addressController = TextEditingController(
      text: customer['address']?.toString() ?? '',
    );
    final notesController = TextEditingController(
      text: customer['notes']?.toString() ?? '',
    );

    String? editPhotoPath =
        await ghataLoadCustomerPhoto(customerId);
    final originalPhotoPath = editPhotoPath;
    bool removeCustomerPhoto = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundImage:
                  editPhotoPath != null && editPhotoPath!.isNotEmpty
                      ? FileImage(File(editPhotoPath!))
                      : null,
              child: editPhotoPath == null || editPhotoPath!.isEmpty
                  ? Text(
                      nameController.text.trim().isEmpty
                          ? '?'
                          : nameController.text
                              .trim()
                              .substring(0, 1)
                              .toUpperCase(),
                    )
                  : null,
            ),
            SizedBox(width: 10),
            Text(ghataT(context, 'Edit Customer')),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatefulBuilder(
                builder: (context, setPhotoState) {
                  final initial = nameController.text.trim().isEmpty
                      ? '?'
                      : nameController.text
                          .trim()
                          .substring(0, 1)
                          .toUpperCase();

                  return Column(
                    children: [
                      CircleAvatar(
                        radius: 42,
                        backgroundImage:
                            editPhotoPath != null &&
                                    editPhotoPath!.isNotEmpty
                                ? FileImage(File(editPhotoPath!))
                                : null,
                        child: editPhotoPath == null ||
                                editPhotoPath!.isEmpty
                            ? Text(
                                initial,
                                style: TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            : null,
                      ),
                      SizedBox(height: 10),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () async {
                              final picked =
                                  await ghataPickCustomerPhoto(context);

                              if (picked == null) return;

                              setPhotoState(() {
                                editPhotoPath = picked;
                                removeCustomerPhoto = false;
                              });
                            },
                            icon: Icon(Icons.photo_library_outlined),
                            label: Text(
                              ghataT(context, 'Change Photo'),
                            ),
                          ),
                          if (editPhotoPath != null &&
                              editPhotoPath!.isNotEmpty)
                            TextButton.icon(
                              onPressed: () {
                                setPhotoState(() {
                                  editPhotoPath = null;
                                  removeCustomerPhoto = true;
                                });
                              },
                              icon: Icon(
                                Icons.delete_outline,
                                color: Colors.red,
                              ),
                              label: Text(
                                ghataT(context, 'Remove Photo'),
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                        ],
                      ),
                      SizedBox(height: 14),
                    ],
                  );
                },
              ),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Customer Name'),
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 12),
              StatefulBuilder(
                builder: (context, setDialogState) {
                  final selectedCountry = customerCountryCodes.firstWhere(
                    (country) =>
                        country['code'] == selectedProfileCountryCode,
                    orElse: () => customerCountryCodes.first,
                  );

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 115,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            minimumSize: Size.fromHeight(56),
                            padding: EdgeInsets.symmetric(horizontal: 8),
                          ),
                          onPressed: () async {
                            final code =
                                await showCustomerCountryCodePicker(
                              context,
                              selectedProfileCountryCode,
                            );

                            if (code != null) {
                              setDialogState(() {
                                selectedProfileCountryCode = code;
                              });
                            }
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ghataCountryFlagWidget(
                                selectedCountry['flag']!,
                                width: 28,
                                height: 18,
                              ),
                              SizedBox(width: 6),
                              Text(selectedProfileCountryCode),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: phoneController,
                          keyboardType: TextInputType.phone,
                          decoration: InputDecoration(
                            labelText: ghataT(context, 'Phone Number'),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              SizedBox(height: 12),
              TextField(
                controller: addressController,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Address'),
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 12),
              TextField(
                controller: notesController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Notes'),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(ghataT(context, 'Save Changes')),
          ),
        ],
      ),
    );

    if (saved != true) {
      nameController.dispose();
      phoneController.dispose();
      addressController.dispose();
      notesController.dispose();
      return;
    }

    final name = nameController.text.trim();

    if (name.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ghataT(context, 'Customer name is required.'))),
        );
      }
      nameController.dispose();
      phoneController.dispose();
      addressController.dispose();
      notesController.dispose();
      return;
    }

    try {
      await OfflineDatabase.instance.updateLocalRecord(
        'customers',
        (customerId).toString(),
        {        'full_name': name,
        'phone': phoneController.text.trim().isEmpty
            ? null
            : buildCustomerPhone(
                selectedProfileCountryCode,
                phoneController.text,
              ),
        'address': addressController.text.trim().isEmpty
            ? null
            : addressController.text.trim(),
        'notes': notesController.text.trim().isEmpty
            ? null
            : notesController.text.trim(),
        },
      );

      if (removeCustomerPhoto) {
        await ghataDeleteCustomerPhoto(customerId);
      } else if (editPhotoPath != null &&
          editPhotoPath!.isNotEmpty &&
          editPhotoPath != originalPhotoPath) {
        await ghataSaveCustomerPhoto(
          customerId,
          editPhotoPath!,
        );
      }

      ghataTrySync();

      final relatedTransactions =
          await OfflineDatabase.instance.getRecords('transactions');

      for (final transaction in relatedTransactions) {
        if (transaction['customer_id']?.toString() ==
            customerId) {
          final transactionId =
              transaction['id']?.toString() ?? '';

          if (transactionId.isNotEmpty) {
            await OfflineDatabase.instance.updateLocalRecord(
              'transactions',
              transactionId,
              {'customer_name': name},
            );
          }
        }
      }

      final relatedExchanges =
          await OfflineDatabase.instance.getRecords('exchanges');

      for (final exchange in relatedExchanges) {
        if (exchange['customer_id']?.toString() ==
            customerId) {
          final exchangeId =
              exchange['id']?.toString() ?? '';

          if (exchangeId.isNotEmpty) {
            await OfflineDatabase.instance.updateLocalRecord(
              'exchanges',
              exchangeId,
              {'customer_name': name},
            );
          }
        }
      }

      ghataTrySync();

      await refreshCustomerProfile();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Customer updated successfully.'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${ghataT(context, 'Unable to update customer')}: $e")),
      );
    } finally {
      nameController.dispose();
      phoneController.dispose();
      addressController.dispose();
      notesController.dispose();
    }
  }

  Future<void> deleteProfileCustomer() async {
  final customer = customerProfile;
  if (customer == null) return;

  final name =
      customer['full_name']?.toString() ?? customerName;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(ghataT(context, 'Move to Recycle Bin?')),
      content: Text(
        'Are you sure you want to delete $name?',
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, false),
          child: Text(ghataT(context, 'Cancel')),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dialogContext, true),
          child: Text(ghataT(context, 'Delete')),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  try {
    await ghataSoftDeleteLocal(
      'customers',
      customerId,
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Customer moved to Recycle Bin. You can restore it within 30 days.',
        ),
      ),
    );

    Navigator.pop(context, true);
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("${ghataT(context, 'Unable to delete customer')}: $e"),
      ),
    );
  }
}

  Future<void> shareCustomerBalanceImage() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      final transactions = await loadCustomerTransactions();
      final profile = customerProfile ?? await loadCustomerProfile();

      final business = await ghataLoadBusinessProfile();

      final name =
          profile?['full_name']?.toString().trim().isNotEmpty == true
              ? profile!['full_name'].toString()
              : customerName;

      final phone = profile?['phone']?.toString().trim() ?? '';
      final address = profile?['address']?.toString().trim() ?? '';

      final balances = calculateBalances(transactions)
        ..removeWhere((_, value) => value.abs() <= 0.000001);

      final businessName =
          business?['business_name']?.toString().trim() ?? '';
      final businessPhone =
          business?['business_phone']?.toString().trim() ?? '';
      final businessAddress =
          business?['business_address']?.toString().trim() ?? '';
      final receiptNote =
          business?['receipt_note']?.toString().trim() ?? '';

      final language = Localizations.localeOf(context).languageCode;
      final rtl = {'ps', 'fa', 'ur', 'ar'}.contains(language);

      final designLabel = switch (language) {
        'ps' => 'ډیزاین: MRS',
        'fa' => 'طراحی توسط MRS',
        'ur' => 'ڈیزائن: MRS',
        'ar' => 'تصميم بواسطة MRS',
        _ => 'Design by MRS',
      };

      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');
      final dateText =
          '${now.year}-${two(now.month)}-${two(now.day)}  '
          '${two(now.hour)}:${two(now.minute)}';

      const width = 1080.0;
      final balanceCount = balances.isEmpty ? 1 : balances.length;
      final extraCustomerLines =
          (phone.isNotEmpty ? 42.0 : 0.0) +
          (address.isNotEmpty ? 48.0 : 0.0);
      final extraBusinessLines =
          (businessAddress.isNotEmpty ? 36.0 : 0.0) +
          (businessPhone.isNotEmpty ? 36.0 : 0.0);
      final extraNote = receiptNote.isNotEmpty ? 80.0 : 0.0;

      final height = 690.0 +
          extraCustomerLines +
          extraBusinessLines +
          extraNote +
          (balanceCount * 132.0);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final size = Size(width, height);

      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xFFF7F8FC),
      );

      void drawText(
        String text,
        double x,
        double y, {
        double fontSize = 30,
        FontWeight fontWeight = FontWeight.normal,
        Color color = const Color(0xFF1D2433),
        TextAlign textAlign = TextAlign.left,
        double maxWidth = 920,
      }) {
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: fontWeight,
              color: color,
            ),
          ),
          textAlign: textAlign,
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          maxLines: 3,
          ellipsis: '…',
        )..layout(maxWidth: maxWidth);

        double dx = x;
        if (textAlign == TextAlign.center) {
          dx = (width - painter.width) / 2;
        } else if (textAlign == TextAlign.right) {
          dx = width - x - painter.width;
        }

        painter.paint(canvas, Offset(dx, y));
      }

      // Header
      final headerRect = RRect.fromRectAndRadius(
        const Rect.fromLTWH(36, 34, width - 72, 185),
        const Radius.circular(30),
      );

      canvas.drawRRect(
        headerRect,
        Paint()..color = const Color(0xFF2563EB),
      );

      drawText(
        businessName.isEmpty ? 'ګهته • Ghata' : businessName,
        70,
        62,
        fontSize: 48,
        fontWeight: FontWeight.bold,
        color: Colors.white,
        textAlign: TextAlign.center,
      );

      drawText(
        ghataT(context, 'Customer Balance'),
        70,
        126,
        fontSize: 29,
        fontWeight: FontWeight.w600,
        color: const Color(0xFFEAF1FF),
        textAlign: TextAlign.center,
      );

      drawText(
        dateText,
        70,
        171,
        fontSize: 21,
        color: const Color(0xFFD7E5FF),
        textAlign: TextAlign.center,
      );

      double top = 245;

      if (businessAddress.isNotEmpty || businessPhone.isNotEmpty) {
        if (businessAddress.isNotEmpty) {
          drawText(
            businessAddress,
            70,
            top,
            fontSize: 22,
            color: const Color(0xFF667085),
            textAlign: TextAlign.center,
          );
          top += 36;
        }

        if (businessPhone.isNotEmpty) {
          drawText(
            businessPhone,
            70,
            top,
            fontSize: 22,
            color: const Color(0xFF667085),
            textAlign: TextAlign.center,
          );
          top += 36;
        }

        top += 10;
      }

      // Customer information card
      final customerCardHeight =
          112.0 +
          (phone.isNotEmpty ? 42.0 : 0.0) +
          (address.isNotEmpty ? 48.0 : 0.0);

      final customerRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(55, top, width - 110, customerCardHeight),
        const Radius.circular(26),
      );

      canvas.drawRRect(
        customerRect,
        Paint()..color = Colors.white,
      );

      canvas.drawRRect(
        customerRect,
        Paint()
          ..color = const Color(0xFFE2E8F0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );

      drawText(
        ghataT(context, 'Customer'),
        85,
        top + 24,
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: const Color(0xFF64748B),
      );

      drawText(
        name,
        85,
        top + 56,
        fontSize: 34,
        fontWeight: FontWeight.bold,
        maxWidth: 860,
      );

      double customerLine = top + 102;

      if (phone.isNotEmpty) {
        drawText(
          '${ghataT(context, 'Phone')}: $phone',
          85,
          customerLine,
          fontSize: 23,
          color: const Color(0xFF64748B),
        );
        customerLine += 42;
      }

      if (address.isNotEmpty) {
        drawText(
          '${ghataT(context, 'Address')}: $address',
          85,
          customerLine,
          fontSize: 23,
          color: const Color(0xFF64748B),
          maxWidth: 860,
        );
      }

      top += customerCardHeight + 38;

      drawText(
        ghataT(context, 'Current Balance'),
        60,
        top,
        fontSize: 31,
        fontWeight: FontWeight.bold,
      );

      top += 54;

      if (balances.isEmpty) {
        final emptyRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(55, top, width - 110, 100),
          const Radius.circular(24),
        );

        canvas.drawRRect(
          emptyRect,
          Paint()..color = const Color(0xFFF1F5F9),
        );

        drawText(
          ghataT(context, 'No outstanding balance.'),
          85,
          top + 30,
          fontSize: 27,
          color: const Color(0xFF64748B),
        );

        top += 125;
      } else {
        for (final entry in balances.entries) {
          final value = entry.value;
            final isPositive = value > 0;

            final accent = isPositive
                ? const Color(0xFF16A34A)
                : const Color(0xFFDC2626);

            final background = isPositive
                ? const Color(0xFFF0FDF4)
                : const Color(0xFFFEF2F2);

          final rect = RRect.fromRectAndRadius(
            Rect.fromLTWH(55, top, width - 110, 108),
            const Radius.circular(24),
          );

          canvas.drawRRect(
            rect,
            Paint()..color = background,
          );

          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(55, top, 9, 108),
              const Radius.circular(10),
            ),
            Paint()..color = accent,
          );

            final label = ghataT(context, 'Balance');

          drawText(
            '${flagForCurrency(entry.key)}  ${entry.key}',
            90,
            top + 17,
            fontSize: 27,
            fontWeight: FontWeight.bold,
          );

          drawText(
            label,
            90,
            top + 58,
            fontSize: 23,
            fontWeight: FontWeight.w600,
            color: accent,
          );

            final amountText = '${value > 0 ? '+' : ''}${value.toStringAsFixed(2)}';

          final amountPainter = TextPainter(
            text: TextSpan(
              text: amountText,
              style: TextStyle(
                fontSize: 35,
                fontWeight: FontWeight.bold,
                color: accent,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();

          amountPainter.paint(
            canvas,
            Offset(
              width - 90 - amountPainter.width,
              top + 34,
            ),
          );

          top += 132;
        }
      }

      if (receiptNote.isNotEmpty) {
        final noteRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(55, top, width - 110, 70),
          const Radius.circular(20),
        );

        canvas.drawRRect(
          noteRect,
          Paint()..color = const Color(0xFFFFFBEB),
        );

        drawText(
          receiptNote,
          82,
          top + 20,
          fontSize: 22,
          color: const Color(0xFF92400E),
          maxWidth: 850,
        );

        top += 90;
      }

      // Footer
      canvas.drawLine(
        Offset(70, height - 150),
        Offset(width - 70, height - 150),
        Paint()
          ..color = const Color(0xFFE2E8F0)
          ..strokeWidth = 2,
      );

      drawText(
        ghataT(
          context,
          'Generated by Ghata - Business Ledger & Accounting',
        ),
        60,
        height - 126,
        fontSize: 19,
        textAlign: TextAlign.center,
        color: const Color(0xFF94A3B8),
      );

      drawText(
        designLabel,
        60,
        height - 91,
        fontSize: 18,
        fontWeight: FontWeight.bold,
        textAlign: TextAlign.center,
        color: const Color(0xFF64748B),
      );

      final picture = recorder.endRecording();

      final image = await picture.toImage(
        width.toInt(),
        height.toInt(),
      );

      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );

      image.dispose();

      if (byteData == null) {
        throw Exception(
          ghataT(context, 'Unable to create image.'),
        );
      }

      final Uint8List bytes = byteData.buffer.asUint8List();

      final safeName = name
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
          .replaceAll(RegExp(r'_+'), '_');

      final balanceFileName =
          'Ghata_Balance_${safeName.isEmpty ? 'Customer' : safeName}.png';

      if (Platform.isWindows) {
        final location = await getSaveLocation(
          suggestedName: balanceFileName,
          acceptedTypeGroups: const <XTypeGroup>[
            XTypeGroup(
              label: 'PNG Image',
              extensions: <String>['png'],
            ),
          ],
        );

        if (location == null) return;

        await XFile.fromData(
          bytes,
          mimeType: 'image/png',
          name: balanceFileName,
        ).saveTo(location.path);
      } else {
        await SharePlus.instance.share(
          ShareParams(
            title: ghataT(context, 'Customer Balance'),
            subject: '$name - Balance',
            text: '${ghataT(context, 'Customer Balance')} - $name',
            files: [
              XFile.fromData(
                bytes,
                mimeType: 'image/png',
              ),
            ],
            fileNameOverrides: [balanceFileName],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "${ghataT(context, 'Unable to create balance image')}: $e",
          ),
        ),
      );
    }
  }

  Future<void> shareCustomerStatementPdf({
    bool printDirect = false,
  }) async {
    final ghataPdfFont = await ghataPdfUnicodeFont();
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      final transactions = await loadCustomerTransactions();
      final profile = customerProfile ?? await loadCustomerProfile();

      final business = await ghataLoadBusinessProfile();

      final name =
          profile?['full_name']?.toString().trim().isNotEmpty == true
              ? profile!['full_name'].toString()
              : customerName;
      final phone = profile?['phone']?.toString() ?? '';
      final address = profile?['address']?.toString() ?? '';

      final balances = calculateBalances(transactions)
        ..removeWhere((_, value) => value.abs() <= 0.000001);

      final businessName =
          business?['business_name']?.toString().trim() ?? '';
      final businessPhone =
          business?['business_phone']?.toString().trim() ?? '';
      final businessAddress =
          business?['business_address']?.toString().trim() ?? '';
      final receiptNote =
          business?['receipt_note']?.toString().trim() ?? '';

      String typeLabel(String type) {
        return switch (type) {
          'money_in' => 'Money In',
          'money_out' => 'Money Out',
                  _ => type.replaceAll('_', ' '),
        };
      }

      final pdf = pw.Document(
        theme: pw.ThemeData.withFont(
          base: ghataPdfFont,
          bold: ghataPdfFont,
          italic: ghataPdfFont,
          boldItalic: ghataPdfFont,
        ),
      );

      final blue = PdfColor.fromHex('#3157D5');
      final paleBlue = PdfColor.fromHex('#EEF2FF');
      final green = PdfColor.fromHex('#16A34A');
      final paleGreen = PdfColor.fromHex('#F0FDF4');
      final red = PdfColor.fromHex('#DC2626');
      final paleRed = PdfColor.fromHex('#FEF2F2');
      final border = PdfColor.fromHex('#E5E7EB');
      final muted = PdfColor.fromHex('#6B7280');

      final language = Localizations.localeOf(context).languageCode;
      final designBy = switch (language) {
        'ps' => 'ډیزاین: MRS',
        'fa' => 'طراحی توسط MRS',
        'ur' => 'ڈیزائن: MRS',
        'ar' => 'تصميم بواسطة MRS',
        _ => 'Design by MRS',
      };
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 34),

          header: (_) => pw.Container(
            padding: const pw.EdgeInsets.all(14),
            decoration: pw.BoxDecoration(
              color: blue,
              borderRadius: pw.BorderRadius.circular(12),
            ),
            child: pw.Column(
              children: [
                pw.Text(
                  businessName.isEmpty ? 'ګهته • Ghata' : businessName,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 21,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  ghataT(context, 'Customer Statement'),
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 13,
                  ),
                ),
                if (businessAddress.isNotEmpty) ...[
                  pw.SizedBox(height: 4),
                  pw.Text(
                    businessAddress,
                    textAlign: pw.TextAlign.center,
                    style: const pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 8,
                    ),
                  ),
                ],
                if (businessPhone.isNotEmpty)
                  pw.Text(
                    businessPhone,
                    textAlign: pw.TextAlign.center,
                    style: const pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 8,
                    ),
                  ),
              ],
            ),
          ),

          footer: (pdfContext) => pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.Divider(color: border),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    designBy,
                    style: pw.TextStyle(
                      fontSize: 7,
                      color: muted,
                    ),
                  ),
                  pw.Text(
                    '${pdfContext.pageNumber} / ${pdfContext.pagesCount}',
                    style: pw.TextStyle(
                      fontSize: 8,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ],
          ),

          build: (_) => [
            pw.SizedBox(height: 12),

            pw.Container(
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(
                color: paleBlue,
                borderRadius: pw.BorderRadius.circular(12),
                border: pw.Border.all(color: border),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Text(
                    ghataT(context, 'Customer'),
                    style: pw.TextStyle(
                      color: blue,
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 5),
                  pw.Text(
                    name,
                    style: pw.TextStyle(
                      fontSize: 17,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (phone.isNotEmpty) ...[
                    pw.SizedBox(height: 4),
                    pw.Text(
                      '${ghataT(context, 'Phone')}: $phone',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                  ],
                  if (address.isNotEmpty)
                    pw.Text(
                      '${ghataT(context, 'Address')}: $address',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                ],
              ),
            ),

            pw.SizedBox(height: 14),

            pw.Text(
              ghataT(context, 'Current Balance'),
              style: pw.TextStyle(
                fontSize: 15,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),

            if (balances.isEmpty)
              pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: paleGreen,
                  borderRadius: pw.BorderRadius.circular(10),
                ),
                child: pw.Text(
                  ghataT(context, 'No outstanding balance.'),
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    color: green,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              )
            else
              pw.Wrap(
                spacing: 8,
                runSpacing: 8,
                children: balances.entries.map((entry) {
                  final value = entry.value;
                    final isPositive = value > 0;
                    final accent = isPositive ? green : red;
                    final bg = isPositive ? paleGreen : paleRed;
                  final code = entry.key.toUpperCase();

                  return pw.Container(
                    width: 250,
                    padding: const pw.EdgeInsets.all(11),
                    decoration: pw.BoxDecoration(
                      color: bg,
                      borderRadius: pw.BorderRadius.circular(10),
                      border: pw.Border.all(color: accent),
                    ),
                    child: pw.Row(
                      children: [
                        pw.Text(
                          flagForCurrency(code),
                          style: const pw.TextStyle(fontSize: 17),
                        ),
                        pw.SizedBox(width: 8),
                        pw.Expanded(
                          child: pw.Column(
                            crossAxisAlignment:
                                pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(
                                code,
                                style: pw.TextStyle(
                                  fontSize: 9,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                              pw.Text(
                                  ghataT(context, 'Balance'),
                                style: pw.TextStyle(
                                  fontSize: 8,
                                  color: accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                        pw.Text(
                            '${value > 0 ? '+' : ''}${value.toStringAsFixed(2)}',
                          style: pw.TextStyle(
                            fontSize: 13,
                            color: accent,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),

            pw.SizedBox(height: 18),

            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  ghataT(context, 'Transactions'),
                  style: pw.TextStyle(
                    fontSize: 15,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: pw.BoxDecoration(
                    color: paleBlue,
                    borderRadius: pw.BorderRadius.circular(20),
                  ),
                  child: pw.Text(
                    transactions.length.toString(),
                    style: pw.TextStyle(
                      color: blue,
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 8),

            if (transactions.isEmpty)
              pw.Text(
                ghataT(context, 'No transactions yet.'),
                textAlign: pw.TextAlign.center,
              )
            else
              pw.Table.fromTextArray(
                headers: [
                  ghataT(context, 'Date'),
                  ghataT(context, 'Type'),
                  ghataT(context, 'Amount'),
                  ghataT(context, 'Currency'),
                  ghataT(context, 'Description'),
                ],
                data: transactions.map((transaction) {
                  final date =
                      transaction['transaction_date']?.toString() ?? '';
                  final rawTime =
                      transaction['transaction_time']?.toString() ?? '';
                  final time = rawTime.length >= 5
                      ? rawTime.substring(0, 5)
                      : rawTime;
                  final code =
                      transaction['currency']?.toString().toUpperCase() ??
                          '';

                  return [
                    time.isEmpty ? date : '$date $time',
                    transaction['_is_exchange'] == true
                        ? ghataT(context, 'Exchange')
                        : ghataT(
                            context,
                            typeLabel(
                              transaction['transaction_type']?.toString() ?? '',
                            ),
                          ),
                    transaction['amount']?.toString() ?? '0',
                    '${flagForCurrency(code)} $code',
                    transaction['description']?.toString() ?? '',
                  ];
                }).toList(),
                headerDecoration: pw.BoxDecoration(
                  color: blue,
                ),
                headerStyle: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 8,
                  fontWeight: pw.FontWeight.bold,
                ),
                cellStyle: const pw.TextStyle(fontSize: 7.5),
                cellAlignment: pw.Alignment.centerLeft,
                cellPadding: const pw.EdgeInsets.all(5),
                border: pw.TableBorder.all(
                  color: border,
                  width: 0.6,
                ),
                oddRowDecoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('#F9FAFB'),
                ),
              ),

            if (receiptNote.isNotEmpty) ...[
              pw.SizedBox(height: 14),
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(11),
                decoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('#FFFBEB'),
                  borderRadius: pw.BorderRadius.circular(10),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      ghataT(context, 'Receipt Note'),
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 3),
                    pw.Text(
                      receiptNote,
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                  ],
                ),
              ),
            ],

            pw.SizedBox(height: 12),
            pw.Text(
              ghataT(
                context,
                'Generated by Ghata - Business Ledger & Accounting',
              ),
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: 8,
                color: muted,
              ),
            ),
          ],
        ),
      );

      final bytes = await pdf.save();

      final safeName = name
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
          .replaceAll(RegExp(r'_+'), '_');

      final statementFileName =
          'Ghata_Statement_${safeName.isEmpty ? 'Customer' : safeName}.pdf';

      if (Platform.isWindows && printDirect) {
        await Printing.layoutPdf(
          name: statementFileName,
          onLayout: (_) async => bytes,
        );
      } else if (Platform.isWindows) {
        final location = await getSaveLocation(
          suggestedName: statementFileName,
          acceptedTypeGroups: const <XTypeGroup>[
            XTypeGroup(
              label: 'PDF',
              extensions: <String>['pdf'],
            ),
          ],
        );

        if (location == null) return;

        await XFile.fromData(
          bytes,
          mimeType: 'application/pdf',
          name: statementFileName,
        ).saveTo(location.path);
      } else {
        await SharePlus.instance.share(
          ShareParams(
            title: ghataT(context, 'Customer Statement'),
            subject: '$name - Statement',
            files: [
              XFile.fromData(
                bytes,
                mimeType: 'application/pdf',
              ),
            ],
            fileNameOverrides: [statementFileName],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${ghataT(context, 'Unable to create statement PDF')}: $e")),
      );
    }
  }

  String flagForCurrency(String code) {
    const flags = {
      'AFN': '🇦🇫',
      'PKR': '🇵🇰',
      'USD': '🇺🇸',
      'EUR': '🇪🇺',
      'GBP': '🇬🇧',
      'AED': '🇦🇪',
      'SAR': '🇸🇦',
      'KWD': '🇰🇼',
      'QAR': '🇶🇦',
      'OMR': '🇴🇲',
      'TRY': '🇹🇷',
      'CNY': '🇨🇳',
      'INR': '🇮🇳',
      'IRR': '🇮🇷',
    };

    return flags[code] ?? '💰';
  }

  @override
    @override
    void dispose() {
      ghataDataRevision.removeListener(_handleRealtimeDataRevision);
      super.dispose();
    }

    Widget build(BuildContext context) {
      final profileName =
          customerProfile?['full_name']?.toString().trim().isNotEmpty == true
              ? customerProfile!['full_name'].toString()
              : customerName;
      final profilePhone =
          customerProfile?['phone']?.toString().trim() ?? '';
      final profileAddress =
          customerProfile?['address']?.toString().trim() ?? '';
      final profileInitial =
          profileName.trim().isEmpty
              ? '?'
              : profileName.trim().substring(0, 1).toUpperCase();

      return Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundImage: customerPhotoPath != null
                    ? FileImage(File(customerPhotoPath!))
                    : null,
                child: customerPhotoPath == null
                    ? Text(
                        profileInitial,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      )
                    : null,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      profileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (profilePhone.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ghataPhoneFlagWidget(
                            profilePhone,
                            width: 22,
                            height: 14,
                          ),
                          SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              profilePhone,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.normal,
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (profileAddress.isNotEmpty)
                      Text(
                        profileAddress,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'print') {
                  shareCustomerStatementPdf(printDirect: true);
                } else if (value == 'pdf') {
                  shareCustomerStatementPdf();
                } else if (value == 'share') {
                  shareCustomerBalanceImage();
                } else if (value == 'whatsapp') {
                  openCustomerWhatsApp();
                } else if (value == 'edit') {
                  editProfileCustomer();
                } else if (value == 'delete') {
                  deleteProfileCustomer();
                }
              },
              itemBuilder: (context) =>  [
                if (Platform.isWindows)
                  PopupMenuItem(
                    value: 'print',
                    child: Row(
                      children: [
                        Icon(Icons.print_outlined),
                        SizedBox(width: 10),
                        Text(ghataT(context, 'Print Statement')),
                      ],
                    ),
                  ),
                PopupMenuItem(
                  value: 'pdf',
                  child: Text(
                    Platform.isWindows
                        ? ghataT(context, 'Save Statement (PDF)')
                        : ghataT(context, 'Full Statement (PDF)'),
                  ),
                ),
                PopupMenuItem(
                  value: 'share',
                  child: Text(ghataT(context, 'Share Balance Image')),
                ),
                PopupMenuItem(
                  value: 'whatsapp',
                  child: Row(
                    children: [
                      Icon(Icons.chat_outlined, color: Colors.green),
                      SizedBox(width: 10),
                      Text(ghataT(context, 'WhatsApp')),
                    ],
                  ),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'edit',
                  child: Text(ghataT(context, 'Edit Customer')),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(ghataT(context, 'Delete Customer')),
                ),
              ],
            ),
          ],
        ),
      body: SafeArea(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: customerTransactionsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState ==
                ConnectionState.waiting) {
              return Center(
                child: CircularProgressIndicator(),
              );
            }

            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    "${ghataT(context, 'Unable to load ledger')}: ${snapshot.error}",
                  ),
                ),
              );
            }

            final transactions = snapshot.data ?? [];

            final ledgerCurrencies = transactions
                .map(
                  (transaction) =>
                      transaction['currency']?.toString().toUpperCase() ?? '',
                )
                .where((currency) => currency.isNotEmpty)
                .toSet()
                .toList()
              ..sort();

            final effectiveLedgerCurrency =
                selectedLedgerCurrency == 'ALL' ||
                        ledgerCurrencies.contains(selectedLedgerCurrency)
                    ? selectedLedgerCurrency
                    : 'ALL';

            final filteredTransactions =
                effectiveLedgerCurrency == 'ALL'
                    ? transactions
                    : transactions
                        .where(
                          (transaction) =>
                              transaction['currency']
                                  ?.toString()
                                  .toUpperCase() ==
                              effectiveLedgerCurrency,
                        )
                        .toList();

            final allBalances = calculateBalances(transactions);

            // Show only currencies with a remaining balance.
            // Zero-balance currencies stay hidden.
            final balances = Map<String, double>.fromEntries(
              allBalances.entries.where(
                (entry) => entry.value.abs() > 0.000001,
              ),
            );

            return ListView(
              padding: EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () =>
                            openCustomerMoneyEntry('money_in'),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.south_west, size: 18),
                            SizedBox(height: 3),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                ghataT(context, 'Money In'),
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          minimumSize: Size.fromHeight(54),
                          padding: EdgeInsets.symmetric(horizontal: 6),
                        ),
                      ),
                    ),
                    SizedBox(width: 6),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            openCustomerMoneyEntry('money_out'),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.north_east, size: 18),
                            SizedBox(height: 3),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                ghataT(context, 'Money Out'),
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: BorderSide(color: Colors.red),
                          minimumSize: Size.fromHeight(54),
                          padding: EdgeInsets.symmetric(horizontal: 6),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: openCustomerWhatsApp,
                    icon: Icon(
                      Icons.chat_outlined,
                      color: Colors.green,
                    ),
                    label: Text(
                      ghataT(context, 'WhatsApp'),
                      style: TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.green),
                      minimumSize: Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 14),
                Text(
                  ghataT(context, 'Balances'),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8),

                if (balances.isEmpty)
                  Card(
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: Text(
                        ghataT(context, 'No balance yet.'),
                      ),
                    ),
                  )
                else
                  SizedBox(
                    height: 90,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      physics: BouncingScrollPhysics(),
                      itemCount: balances.length,
                      separatorBuilder: (_, __) => SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final entry =
                            balances.entries.elementAt(index);
                        final amount = entry.value;
                        final code = entry.key;

                        final balanceColor = amount > 0
                            ? Colors.green
                            : amount < 0
                                ? Colors.red
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant;

                        final balanceSign = amount > 0 ? '+' : '';

                        return Container(
                          width: 150,
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerLow,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant,
                            ),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                child: ghataCurrencyFlagWidget(
                                  code,
                                  width: 26,
                                  height: 18,
                                ),
                              ),
                              SizedBox(width: 9),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      code,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    SizedBox(height: 3),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        '$balanceSign${amount.toStringAsFixed(2)}',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: balanceColor,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),

                SizedBox(height: 12),
                Divider(height: 1),
                SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        ghataT(context, 'Transactions'),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    SizedBox(width: 10),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: effectiveLedgerCurrency,
                        borderRadius: BorderRadius.circular(14),
                        items: [
                          DropdownMenuItem<String>(
                            value: 'ALL',
                            child: Text(
                              ghataT(context, 'All Currencies'),
                            ),
                          ),
                          ...ledgerCurrencies.map(
                            (currency) => DropdownMenuItem<String>(
                                value: currency,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ghataCurrencyFlagWidget(
                                      currency,
                                      width: 24,
                                      height: 16,
                                    ),
                                    SizedBox(width: 7),
                                    Text(currency),
                                  ],
                                ),
                              ),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            selectedLedgerCurrency = value;
                          });
                        },
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),

                if (transactions.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text(ghataT(context, 'No transactions yet.')),
                    ),
                  )
                else
                  Builder(
                    builder: (context) {
                      final ledger =
                          buildCustomerRunningLedger(
                            filteredTransactions,
                          );

                      String amountText(dynamic value) {
                        final number =
                            double.tryParse(value.toString()) ?? 0;

                        if (number.abs() <= 0.000001) return '—';

                        return number % 1 == 0
                            ? number.toStringAsFixed(0)
                            : number.toStringAsFixed(2);
                      }

                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: BouncingScrollPhysics(),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minWidth: 760),
                          child: SizedBox(
                            width: Platform.isWindows
                                ? (MediaQuery.sizeOf(context).width - 32)
                                    .clamp(760.0, 1180.0)
                                    .toDouble()
                                : 760,
                            child: Column(
                              children: [
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 100,
                                  child: Text(
                                    ghataT(context, 'Date'),
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    ghataT(context, 'Description'),
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    ghataT(context, 'Money In'),
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    ghataT(context, 'Money Out'),
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    ghataT(context, 'Balance'),
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: 4),
                          ...ledger.map((transaction) {
                            final currency =
                                transaction['currency']
                                        ?.toString()
                                        .toUpperCase() ??
                                    '';

                            final date =
                                transaction['transaction_date']
                                        ?.toString() ??
                                    '';

                            final rawTime =
                                transaction['transaction_time']
                                        ?.toString() ??
                                    '';

                            final time = rawTime.length >= 5
                                ? rawTime.substring(0, 5)
                                : rawTime;

                            final description =
                                transaction['description']
                                        ?.toString()
                                        .trim() ??
                                    '';

                            final moneyIn =
                                transaction['_ledger_in'] ?? 0.0;
                            final moneyOut =
                                transaction['_ledger_out'] ?? 0.0;

                            final balance = double.tryParse(
                                  transaction['_ledger_balance']
                                      .toString(),
                                ) ??
                                0;

                            final balanceColor = balance > 0
                                ? Colors.green
                                : balance < 0
                                    ? Colors.red
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant;

                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                if (transaction['_is_exchange'] == true) {
                                  showCustomerTransactionActions(
                                    transaction,
                                  );
                                } else {
                                  ghataShowTransactionReceipt(
                                    context,
                                    transaction,
                                  );
                                }
                              },
                              onLongPress: () =>
                                  showCustomerTransactionActions(
                                transaction,
                              ),
                              child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 14,
                              ),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: Theme.of(context)
                                        .dividerColor
                                        .withValues(alpha: 0.45),
                                  ),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 100,
                                    child: Text(
                                      time.isEmpty
                                          ? date
                                          : '$date\n$time',
                                      style: TextStyle(
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 3,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          description.isEmpty
                                              ? '—'
                                              : description,
                                          maxLines: 2,
                                          overflow:
                                              TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight:
                                                FontWeight.w500,
                                          ),
                                        ),
                                        SizedBox(height: 2),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ghataCurrencyFlagWidget(currency),
                                            SizedBox(width: 6),
                                            Text(currency),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      amountText(moneyIn),
                                      textAlign: TextAlign.end,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: (double.tryParse(
                                                      moneyIn.toString(),
                                                    ) ??
                                                    0) >
                                                0
                                            ? Colors.green
                                            : null,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      amountText(moneyOut),
                                      textAlign: TextAlign.end,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: (double.tryParse(
                                                      moneyOut.toString(),
                                                    ) ??
                                                    0) >
                                                0
                                            ? Colors.red
                                            : null,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      amountText(balance),
                                      textAlign: TextAlign.end,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: balanceColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              ),
                            );
                          }),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  )
              ],
            );
          },
        ),
      ),
    );
  }
}

class CashboxScreen extends StatefulWidget {
  CashboxScreen({super.key});

  @override
  State<CashboxScreen> createState() => _CashboxScreenState();
}

class _CashboxScreenState extends State<CashboxScreen> {

  late Future<List<Map<String, dynamic>>> cashboxTransactionsFuture;

  @override
  void initState() {
    super.initState();
    cashboxTransactionsFuture = loadTransactions();
    ghataDataRevision.addListener(_handleRealtimeDataRevision);
  }

  void _handleRealtimeDataRevision() {
    if (!mounted) return;

    // Realtime sync already updated SQLite.
    // Cashbox only needs to reread local transactions.
    setState(() {
      cashboxTransactionsFuture = loadTransactions();
    });
  }

  @override
  void dispose() {
    ghataDataRevision.removeListener(_handleRealtimeDataRevision);
    super.dispose();
  }


  Future<List<Map<String, dynamic>>> loadTransactions() async {
    final all = await ghataLocalFinancialRows();

    return all;
  }

  Map<String, double> calculateCashbox(
    List<Map<String, dynamic>> transactions,
  ) {
    final balances = <String, double>{};

    for (final transaction in transactions) {
      final currency =
          transaction['currency']?.toString() ?? '';
      final type =
          transaction['transaction_type']?.toString() ?? '';
      final amount = double.tryParse(
            transaction['amount']?.toString() ?? '0',
          ) ??
          0;

      if (currency.isEmpty) continue;

      balances.putIfAbsent(currency, () => 0);

      if (type == 'money_in') {
        balances[currency] = balances[currency]! + amount;
      } else if (type == 'money_out') {
        balances[currency] = balances[currency]! - amount;
      } else if (type == 'adjustment_in') {
        balances[currency] = balances[currency]! + amount;
      } else if (type == 'adjustment_out') {
        balances[currency] = balances[currency]! - amount;
      } else if (type == 'exchange_in') {
        balances[currency] = balances[currency]! + amount;
      } else if (type == 'exchange_out') {
        balances[currency] = balances[currency]! - amount;
      }
    }

    balances.removeWhere(
      (_, balance) => balance.abs() <= 0.000001,
    );

    return balances;
  }

  String flagForCurrency(String code) {
    const flags = {
      'AFN': '🇦🇫',
      'PKR': '🇵🇰',
      'USD': '🇺🇸',
      'EUR': '🇪🇺',
      'GBP': '🇬🇧',
      'AED': '🇦🇪',
      'SAR': '🇸🇦',
      'KWD': '🇰🇼',
      'QAR': '🇶🇦',
      'OMR': '🇴🇲',
      'TRY': '🇹🇷',
      'CNY': '🇨🇳',
      'INR': '🇮🇳',
      'IRR': '🇮🇷',
    };

    return flags[code] ?? '💰';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF123D2B),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text(ghataT(context, 'Cashbox')),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: cashboxTransactionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Text(
                "${ghataT(context, 'Unable to load cashbox')}: ${snapshot.error}",
              ),
            );
          }

          final balances =
              calculateCashbox(snapshot.data ?? []);

          final transactions =
              List<Map<String, dynamic>>.from(snapshot.data ?? []);

          transactions.sort((a, b) {
            final aDate =
                '${a['transaction_date'] ?? ''} ${a['transaction_time'] ?? ''}';
            final bDate =
                '${b['transaction_date'] ?? ''} ${b['transaction_time'] ?? ''}';
            return bDate.compareTo(aDate);
          });

          final balanceCards = balances.entries.map((entry) {
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Theme.of(context).colorScheme.surface
                    : const Color(0xFFFFFBF2),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Theme.of(context).colorScheme.outlineVariant
                      : const Color(0xFFE4D59B),
                ),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                leading: Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.12)
                        : const Color(0xFFFFE8A3)
                            .withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: ghataCurrencyFlagWidget(
                    entry.key,
                    width: 28,
                    height: 19,
                  ),
                ),
                title: Text(
                  entry.key,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  entry.value > 0
                      ? ghataT(context, 'Available Balance')
                      : entry.value < 0
                          ? ghataT(context, 'Negative Balance')
                          : ghataT(context, 'Balance'),
                ),
                trailing: Text(
                  '${entry.value > 0 ? '+' : ''}${entry.value.toStringAsFixed(2)} ${entry.key}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: entry.value > 0
                        ? Colors.green
                        : entry.value < 0
                            ? Colors.red
                            : Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                  ),
                ),
              ),
            );
          }).toList();

          final historyCards = transactions.map((transaction) {
            final type =
                transaction['transaction_type']?.toString() ?? '';
            final currency = transaction['currency']?.toString() ?? '';
            final amount =
                double.tryParse(transaction['amount']?.toString() ?? '0') ??
                    0;

            final date =
                transaction['transaction_date']?.toString() ?? '';
            final rawTime =
                transaction['transaction_time']?.toString() ?? '';
            final time = rawTime.length >= 5
                ? rawTime.substring(0, 5)
                : rawTime;

            final customer =
                transaction['customer_name']?.toString() ?? '';
            final description =
                transaction['description']?.toString() ?? '';

            String label;
            bool isIn;

            switch (type) {
              case 'money_in':
                label = ghataT(context, 'Money In');
                isIn = true;
                break;
              case 'money_out':
                label = ghataT(context, 'Money Out');
                isIn = false;
                break;
              case 'adjustment_in':
                label = ghataT(context, 'Adjustment In');
                isIn = true;
                break;
              case 'adjustment_out':
                label = ghataT(context, 'Adjustment Out');
                isIn = false;
                break;
              case 'exchange_in':
                label = 'Exchange In';
                isIn = true;
                break;
              case 'exchange_out':
                label = 'Exchange Out';
                isIn = false;
                break;
              default:
                label = type.replaceAll('_', ' ');
                isIn = false;
            }

            final details = <String>[
              if (date.isNotEmpty) date,
              if (time.isNotEmpty) time,
              if (customer.isNotEmpty) customer,
              if (description.isNotEmpty) description,
            ];

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant
                      .withValues(alpha: 0.65),
                ),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: (isIn ? Colors.green : Colors.red)
                        .withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isIn
                        ? Icons.arrow_downward_rounded
                        : Icons.arrow_upward_rounded,
                    color: isIn ? Colors.green : Colors.red,
                  ),
                ),
                title: Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  details.join(' • '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Text(
                  '${isIn ? '+' : '-'}${amount.toStringAsFixed(2)} $currency',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isIn ? Colors.green : Colors.red,
                  ),
                ),
              ),
            );
          }).toList();

          return ListView(
            padding: EdgeInsets.all(16),
            children: [
              if (balanceCards.isEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(ghataT(context, 'Cashbox balance is zero.')),
                )
              else
                ...balanceCards,
              SizedBox(height: 12),
              Text(
                ghataT(context, 'History'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              if (historyCards.isEmpty)
                Text(ghataT(context, 'No cashbox history yet.'))
              else
                ...historyCards,
            ],
          );
        },
      ),
    );
  }

}

class ExchangeScreen extends StatefulWidget {
  final String? initialCustomerId;
  final String? initialCustomerName;
  final String? initialExchangeId;

  ExchangeScreen({
    super.key,
    this.initialCustomerId,
    this.initialCustomerName,
    this.initialExchangeId,
  });

  @override
  State<ExchangeScreen> createState() => _ExchangeScreenState();
}

class _ExchangeScreenState extends State<ExchangeScreen> {
  final fromAmountController = TextEditingController();
  final toAmountController = TextEditingController();
  final rateController = TextEditingController();
  final notesController = TextEditingController();

  String fromCurrency = 'AFN';
  String toCurrency = 'USD';
  String exchangeType = 'buy';
  String? selectedCustomerId;
  String? selectedCustomerName;
  DateTime selectedExchangeDate = DateTime.now();
  TimeOfDay selectedExchangeTime = TimeOfDay.now();
  bool isSaving = false;

  late Future<List<Map<String, dynamic>>> exchangeCustomersFuture;
  late Future<List<Map<String, dynamic>>> exchangeHistoryFuture;

  double? fromCalculatorResult;
  double? toCalculatorResult;
  double? rateCalculatorResult;

  String? lastExchangeInput;
  bool exchangeRateManuallySet = false;

  @override
  void initState() {
    super.initState();

    exchangeCustomersFuture = loadCustomers();
    exchangeHistoryFuture = loadExchangeHistory();
    ghataDataRevision.addListener(_handleRealtimeDataRevision);

    selectedCustomerId = widget.initialCustomerId;
    selectedCustomerName = widget.initialCustomerName;

    final initialExchangeId = widget.initialExchangeId;

    if (initialExchangeId != null &&
        initialExchangeId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final history = await exchangeHistoryFuture;

        if (!mounted) return;

        Map<String, dynamic>? target;

        for (final exchange in history) {
          if (exchange['id']?.toString() == initialExchangeId) {
            target = exchange;
            break;
          }
        }

        if (target != null) {
          await editExchange(target);
        }

        if (mounted) {
          Navigator.pop(context);
        }
      });
    }
  }

  void _handleRealtimeDataRevision() {
    if (!mounted) return;

    // Realtime sync already refreshed SQLite.
    // Re-read Exchange data locally only.
    setState(() {
      exchangeCustomersFuture = loadCustomers(refreshCloud: false);
      exchangeHistoryFuture =
          loadExchangeHistory(refreshCloud: false);
    });
  }

  void updateExchangeCalculatorResults({String? changed}) {
    if (changed != null) {
      lastExchangeInput = changed;
    }

    if (changed == 'rate') {
      exchangeRateManuallySet = true;
    } else if (changed == 'to') {
      exchangeRateManuallySet = false;
    }

    final fromResult = evaluateCalculatorExpression(
      fromAmountController.text.trim(),
    );
    var toResult = evaluateCalculatorExpression(
      toAmountController.text.trim(),
    );
    var rateResult = evaluateCalculatorExpression(
      rateController.text.trim(),
    );

    if (fromResult != null && fromResult > 0) {
      if ((changed == 'rate' ||
              (changed == 'from' && exchangeRateManuallySet)) &&
          rateResult != null &&
          rateResult > 0) {
        toResult = fromResult * rateResult;
        toAmountController.text = toResult
            .toStringAsFixed(6)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
      } else if ((changed == 'from' || changed == 'to') &&
          toResult != null &&
          toResult > 0) {
        rateResult = toResult / fromResult;
        rateController.text = rateResult
            .toStringAsFixed(6)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
      }
    }

    setState(() {
      fromCalculatorResult = fromResult;
      toCalculatorResult = toResult;
      rateCalculatorResult = rateResult;
    });
  }

  final currencies = [
    ('AFN', '🇦🇫', 'Afghan Afghani'),
    ('PKR', '🇵🇰', 'Pakistani Rupee'),
    ('USD', '🇺🇸', 'US Dollar'),
    ('EUR', '🇪🇺', 'Euro'),
    ('GBP', '🇬🇧', 'British Pound'),
    ('AED', '🇦🇪', 'UAE Dirham'),
    ('SAR', '🇸🇦', 'Saudi Riyal'),
    ('KWD', '🇰🇼', 'Kuwaiti Dinar'),
    ('QAR', '🇶🇦', 'Qatari Riyal'),
    ('OMR', '🇴🇲', 'Omani Rial'),
    ('TRY', '🇹🇷', 'Turkish Lira'),
    ('CNY', '🇨🇳', 'Chinese Yuan'),
    ('INR', '🇮🇳', 'Indian Rupee'),
    ('IRR', '🇮🇷', 'Iranian Rial'),
  ];

  String flagForCurrency(String code) {
    for (final item in currencies) {
      if (item.$1 == code) return item.$2;
    }
    return '💰';
  }

  Future<List<Map<String, dynamic>>> loadCustomers({
    bool refreshCloud = true,
  }) async {
    final local =
        await OfflineDatabase.instance.getRecords('customers');

    // Offline-first: never block this page waiting for Supabase.
    if (refreshCloud) ghataRefreshCustomersCache();

    local.sort(
      (a, b) => (a['full_name']?.toString() ?? '')
          .compareTo(b['full_name']?.toString() ?? ''),
    );

    return local;
  }

  List<Map<String, dynamic>> calculateExchangeProfitLoss(
    List<Map<String, dynamic>> history,
  ) {
    final books = <String, Map<String, dynamic>>{};

    final ordered = history.reversed.toList();

    for (final exchange in ordered) {
      final entries = List<Map<String, dynamic>>.from(
        exchange['entries'] ?? [],
      );

      Map<String, dynamic>? outEntry;
      Map<String, dynamic>? inEntry;

      for (final entry in entries) {
        if (entry['entry_type'] == 'money_out') {
          outEntry = entry;
        } else if (entry['entry_type'] == 'money_in') {
          inEntry = entry;
        }
      }

      if (outEntry == null || inEntry == null) continue;

      final type = exchange['exchange_type']?.toString() ?? 'buy';

      final outAmount =
          double.tryParse(outEntry['amount']?.toString() ?? '') ?? 0;
      final inAmount =
          double.tryParse(inEntry['amount']?.toString() ?? '') ?? 0;

      if (outAmount <= 0 || inAmount <= 0) continue;

      late String assetCurrency;
      late String settlementCurrency;
      late double assetAmount;
      late double settlementAmount;

      if (type == 'sell') {
        assetCurrency = outEntry['currency']?.toString() ?? '';
        settlementCurrency = inEntry['currency']?.toString() ?? '';
        assetAmount = outAmount;
        settlementAmount = inAmount;
      } else {
        assetCurrency = inEntry['currency']?.toString() ?? '';
        settlementCurrency = outEntry['currency']?.toString() ?? '';
        assetAmount = inAmount;
        settlementAmount = outAmount;
      }

      if (assetCurrency.isEmpty || settlementCurrency.isEmpty) continue;

      final key = '$assetCurrency/$settlementCurrency';

      final book = books.putIfAbsent(
        key,
        () => {
          'asset_currency': assetCurrency,
          'settlement_currency': settlementCurrency,
          'quantity': 0.0,
          'cost': 0.0,
          'profit': 0.0,
          'unmatched_sell': 0.0,
        },
      );

      var quantity = book['quantity'] as double;
      var cost = book['cost'] as double;
      var profit = book['profit'] as double;
      var unmatchedSell = book['unmatched_sell'] as double;

      if (type == 'buy') {
        quantity += assetAmount;
        cost += settlementAmount;
      } else {
        if (quantity <= 0) {
          unmatchedSell += assetAmount;
        } else {
          final matchedQuantity =
              assetAmount > quantity ? quantity : assetAmount;
          unmatchedSell += assetAmount - matchedQuantity;
          final averageCost = cost / quantity;
          final matchedProceeds =
              settlementAmount * (matchedQuantity / assetAmount);
          final matchedCost = averageCost * matchedQuantity;

          profit += matchedProceeds - matchedCost;
          quantity -= matchedQuantity;
          cost -= matchedCost;

          if (quantity.abs() < 0.0000001) {
            quantity = 0;
            cost = 0;
          }
        }
      }

      book['quantity'] = quantity;
      book['cost'] = cost;
      book['profit'] = profit;
      book['unmatched_sell'] = unmatchedSell;
    }

    return books.values.toList();
  }


  Future<List<Map<String, dynamic>>> loadExchangeHistory({
    bool refreshCloud = true,
  }) async {
  if (refreshCloud) ghataRefreshOfflineCache();

  final exchanges =
      await OfflineDatabase.instance.getRecords('exchanges');

  final entries =
      await OfflineDatabase.instance.getRecords('exchange_entries');

  final entriesByExchange =
      <String, List<Map<String, dynamic>>>{};

  for (final entry in entries) {
    final exchangeId =
        entry['exchange_id']?.toString() ?? '';

    if (exchangeId.isEmpty) continue;

    entriesByExchange
        .putIfAbsent(exchangeId, () => [])
        .add(entry);
  }

  exchanges.sort((a, b) {
    final ad =
        '${a['exchange_date'] ?? ''} ${a['exchange_time'] ?? ''} ${a['created_at'] ?? ''}';
    final bd =
        '${b['exchange_date'] ?? ''} ${b['exchange_time'] ?? ''} ${b['created_at'] ?? ''}';

    return bd.compareTo(ad);
  });

  return exchanges.map((exchange) {
    final exchangeId =
        exchange['id']?.toString() ?? '';

    return {
      ...exchange,
      'entries':
          entriesByExchange[exchangeId] ??
              <Map<String, dynamic>>[],
    };
  }).toList();
}

  Future<void> deleteExchange(Map<String, dynamic> exchange) async {
    final id = exchange['id']?.toString();
    if (id == null || id.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(ghataT(context, 'Move to Recycle Bin?')),
        content: Text(
          'This exchange will be hidden from reports and cashbox. You can restore it from Recycle Bin within 30 days.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(ghataT(context, 'Move to Recycle Bin')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ghataSoftDeleteLocal(
        'exchanges',
        id,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(
              context,
              'Exchange moved to Recycle Bin. You can restore it within 30 days.',
            ),
          ),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to move exchange to Recycle Bin')}: $e"),
        ),
      );
    }
  }

  Future<void> editExchange(Map<String, dynamic> exchange) async {
    final id = exchange['id']?.toString();
    if (id == null || id.isEmpty) return;

    final entries = List<Map<String, dynamic>>.from(
      exchange['entries'] ?? [],
    );

    Map<String, dynamic>? outEntry;
    Map<String, dynamic>? inEntry;

    for (final entry in entries) {
      if (entry['entry_type'] == 'money_out') {
        outEntry = entry;
      } else if (entry['entry_type'] == 'money_in') {
        inEntry = entry;
      }
    }

    final fromController = TextEditingController(
      text: outEntry?['amount']?.toString() ?? '',
    );
    final toController = TextEditingController(
      text: inEntry?['amount']?.toString() ?? '',
    );
    final editRateController = TextEditingController(
      text: outEntry?['rate']?.toString() ??
          inEntry?['rate']?.toString() ??
          '',
    );
    final editNotesController = TextEditingController(
      text: exchange['notes']?.toString() ?? '',
    );

    var editFromCurrency = outEntry?['currency']?.toString() ?? 'AFN';
    var editToCurrency = inEntry?['currency']?.toString() ?? 'USD';
    var editExchangeType = exchange['exchange_type']?.toString() ?? 'buy';
    var editCustomerId = exchange['customer_id']?.toString();
    var editCustomerName = exchange['customer_name']?.toString();

    var editDate = DateTime.tryParse(
          exchange['exchange_date']?.toString() ?? '',
        ) ??
        DateTime.now();

    final rawTime = exchange['exchange_time']?.toString() ?? '';
    final timeParts = rawTime.split(':');
    var editTime = timeParts.length >= 2
        ? TimeOfDay(
            hour: int.tryParse(timeParts[0]) ?? TimeOfDay.now().hour,
            minute: int.tryParse(timeParts[1]) ?? TimeOfDay.now().minute,
          )
        : TimeOfDay.now();

    final customers = await loadCustomers();

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(ghataT(context, 'Edit Exchange')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: editExchangeType,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Type'),
              prefixIcon: Icon(Icons.swap_horiz_rounded),
                    border: OutlineInputBorder(),
                  ),
                  items:  [
                    DropdownMenuItem(
                      value: 'buy',
                      child: Text(ghataT(context, 'Buy')),
                    ),
                    DropdownMenuItem(
                      value: 'sell',
                      child: Text(ghataT(context, 'Sell')),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => editExchangeType = value);
                    }
                  },
                ),
                SizedBox(height: 12),

                DropdownButtonFormField<String>(
                  initialValue: editFromCurrency,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'From Currency'),
              prefixIcon: Icon(Icons.arrow_upward_rounded),
                    border: OutlineInputBorder(),
                  ),
                  items: currencies
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.$1,
                          child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ghataCurrencyFlagWidget(
                                  item.$1,
                                  width: 26,
                                  height: 18,
                                ),
                                SizedBox(width: 8),
                                Text(item.$1),
                              ],
                            ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => editFromCurrency = value);
                    }
                  },
                ),
                SizedBox(height: 12),
                GhataCalculatorField(
                  controller: fromController,
                  label: ghataT(context, 'Amount You Give'),
                  onChanged: () {
                    final fromValue = evaluateCalculatorExpression(
                      fromController.text.trim(),
                    );
                    final toValue = evaluateCalculatorExpression(
                      toController.text.trim(),
                    );
                    if (fromValue != null &&
                        toValue != null &&
                        fromValue > 0 &&
                        toValue > 0) {
                      final rate = toValue / fromValue;
                      editRateController.text = rate
                          .toStringAsFixed(6)
                          .replaceFirst(RegExp(r'0+$'), '')
                          .replaceFirst(RegExp(r'\.$'), '');
                    }
                    setDialogState(() {});
                  },
                ),
                SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: editToCurrency,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'To Currency'),
              prefixIcon: Icon(Icons.arrow_downward_rounded),
                    border: OutlineInputBorder(),
                  ),
                  items: currencies
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.$1,
                          child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ghataCurrencyFlagWidget(
                                  item.$1,
                                  width: 26,
                                  height: 18,
                                ),
                                SizedBox(width: 8),
                                Text(item.$1),
                              ],
                            ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => editToCurrency = value);
                    }
                  },
                ),
                SizedBox(height: 12),
                GhataCalculatorField(
                  controller: toController,
                  label: ghataT(context, 'Amount You Receive'),
                  onChanged: () {
                    final fromValue = evaluateCalculatorExpression(
                      fromController.text.trim(),
                    );
                    final toValue = evaluateCalculatorExpression(
                      toController.text.trim(),
                    );
                    if (fromValue != null &&
                        toValue != null &&
                        fromValue > 0 &&
                        toValue > 0) {
                      final rate = toValue / fromValue;
                      editRateController.text = rate
                          .toStringAsFixed(6)
                          .replaceFirst(RegExp(r'0+$'), '')
                          .replaceFirst(RegExp(r'\.$'), '');
                    }
                    setDialogState(() {});
                  },
                ),
                SizedBox(height: 12),
                GhataCalculatorField(
                  controller: editRateController,
                  label: ghataT(context, 'Exchange Rate (optional)'),
                  onChanged: () {
                    final fromValue = evaluateCalculatorExpression(
                      fromController.text.trim(),
                    );
                    final rateValue = evaluateCalculatorExpression(
                      editRateController.text.trim(),
                    );

                    if (fromValue != null &&
                        rateValue != null &&
                        fromValue > 0 &&
                        rateValue > 0) {
                      final toValue = fromValue * rateValue;
                      toController.text = toValue
                          .toStringAsFixed(6)
                          .replaceFirst(RegExp(r'0+$'), '')
                          .replaceFirst(RegExp(r'\.$'), '');
                    }

                    setDialogState(() {});
                  },
                ),
                SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  value: editCustomerId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Customer (optional)'),
                  prefixIcon: Icon(Icons.person_outline),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(ghataT(context, 'No Customer')),
                    ),
                    ...customers.map((customer) {
                      final customerId = customer['id'].toString();
                      final name = customer['full_name']?.toString() ?? '';
                      final phone = customer['phone']?.toString() ?? '';

                      return DropdownMenuItem<String?>(
                        value: customerId,
                        child: Text(
                          phone.isEmpty ? name : '$name - $phone',
                        ),
                      );
                    }),
                  ],
                  onChanged: (value) {
                    setDialogState(() {
                      editCustomerId = value;

                      if (value == null) {
                        editCustomerName = null;
                      } else {
                        final match = customers.firstWhere(
                          (customer) => customer['id'].toString() == value,
                        );
                        editCustomerName =
                            match['full_name']?.toString();
                      }
                    });
                  },
                ),
                SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.calendar_today_outlined),
                  title: Text(ghataT(context, 'Date')),
                  subtitle: Text(
                    '${editDate.year}-${editDate.month.toString().padLeft(2, '0')}-${editDate.day.toString().padLeft(2, '0')}',
                  ),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: editDate,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );

                    if (picked != null) {
                      setDialogState(() => editDate = picked);
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.access_time),
                  title: Text(ghataT(context, 'Time')),
                  subtitle: Text(editTime.format(context)),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: editTime,
                    );

                    if (picked != null) {
                      setDialogState(() => editTime = picked);
                    }
                  },
                ),
                SizedBox(height: 12),
                TextField(
                  controller: editNotesController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Notes'),
              prefixIcon: Icon(Icons.notes_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(ghataT(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(ghataT(context, 'Save')),
            ),
          ],
        ),
      ),
    );

    if (saved != true) {
      fromController.dispose();
      toController.dispose();
      editRateController.dispose();
      editNotesController.dispose();
      return;
    }

    final fromAmount =
        evaluateCalculatorExpression(fromController.text.trim());
    final toAmount =
        evaluateCalculatorExpression(toController.text.trim());
    final rate =
        evaluateCalculatorExpression(editRateController.text.trim());

    if (fromAmount == null ||
        fromAmount <= 0 ||
        toAmount == null ||
        toAmount <= 0 ||
        editFromCurrency == editToCurrency ||
        (rate != null && rate <= 0)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ghataT(context, 'Please check exchange values.')),
          ),
        );
      }

      fromController.dispose();
      toController.dispose();
      editRateController.dispose();
      editNotesController.dispose();
      return;
    }

    try {
      final exchangeDate =
          '${editDate.year}-'
          '${editDate.month.toString().padLeft(2, '0')}-'
          '${editDate.day.toString().padLeft(2, '0')}';

      final exchangeTime =
          '${editTime.hour.toString().padLeft(2, '0')}:'
          '${editTime.minute.toString().padLeft(2, '0')}:00';

      await OfflineDatabase.instance.updateLocalRecord(
        'exchanges',
        id,
        {
          'exchange_date': exchangeDate,
          'exchange_time': exchangeTime,
          'customer_id': editCustomerId,
          'customer_name': editCustomerName,
          'notes': editNotesController.text.trim(),
          'exchange_type': editExchangeType,
        },
      );

      final existingEntries =
          await OfflineDatabase.instance.getRecords(
        'exchange_entries',
      );

      Map<String, dynamic>? outEntry;
      Map<String, dynamic>? inEntry;

      for (final entry in existingEntries) {
        if (entry['exchange_id']?.toString() != id) {
          continue;
        }

        final entryType =
            entry['entry_type']?.toString() ?? '';

        if (entryType == 'money_out' &&
            outEntry == null) {
          outEntry = entry;
        }

        if (entryType == 'money_in' &&
            inEntry == null) {
          inEntry = entry;
        }
      }

      if (outEntry != null &&
          outEntry['id']?.toString().isNotEmpty == true) {
        await OfflineDatabase.instance.updateLocalRecord(
          'exchange_entries',
          outEntry['id'].toString(),
          {
            'exchange_id': id,
            'entry_type': 'money_out',
            'amount': fromAmount,
            'currency': editFromCurrency,
            'rate': rate,
          },
        );
      } else {
        await ghataSaveLocal(
          'exchange_entries',
          {
            'id': _ghataUuid.v4(),
            'exchange_id': id,
            'entry_type': 'money_out',
            'amount': fromAmount,
            'currency': editFromCurrency,
            'rate': rate,
            'created_at':
                DateTime.now().toUtc().toIso8601String(),
          },
        );
      }

      if (inEntry != null &&
          inEntry['id']?.toString().isNotEmpty == true) {
        await OfflineDatabase.instance.updateLocalRecord(
          'exchange_entries',
          inEntry['id'].toString(),
          {
            'exchange_id': id,
            'entry_type': 'money_in',
            'amount': toAmount,
            'currency': editToCurrency,
            'rate': rate,
          },
        );
      } else {
        await ghataSaveLocal(
          'exchange_entries',
          {
            'id': _ghataUuid.v4(),
            'exchange_id': id,
            'entry_type': 'money_in',
            'amount': toAmount,
            'currency': editToCurrency,
            'rate': rate,
            'created_at':
                DateTime.now().toUtc().toIso8601String(),
          },
        );
      }

      ghataTrySync();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Exchange updated successfully.')),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to update exchange')}: $e"),
        ),
      );
    } finally {
      fromController.dispose();
      toController.dispose();
      editRateController.dispose();
      editNotesController.dispose();
    }
  }

  Future<void> saveExchange() async {
    final fromAmount =
        evaluateCalculatorExpression(fromAmountController.text.trim());
    final toAmount =
        evaluateCalculatorExpression(toAmountController.text.trim());
    final rate =
        evaluateCalculatorExpression(rateController.text.trim());

    if (fromAmount == null || fromAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Please enter a valid From amount.')),
        ),
      );
      return;
    }

    if (toAmount == null || toAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Please enter a valid To amount.')),
        ),
      );
      return;
    }

    if (fromCurrency == toCurrency) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Please select two different currencies.')),
        ),
      );
      return;
    }

    if (rate != null && rate <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Rate must be greater than zero.')),
        ),
      );
      return;
    }

    setState(() => isSaving = true);

    try {
      final user =
          Supabase.instance.client.auth.currentUser;

      if (user == null) {
        throw Exception('You are not logged in.');
      }

      final exchangeId = _ghataUuid.v4();

      final exchangeDate =
          '${selectedExchangeDate.year}-'
          '${selectedExchangeDate.month.toString().padLeft(2, '0')}-'
          '${selectedExchangeDate.day.toString().padLeft(2, '0')}';

      final exchangeTime =
          '${selectedExchangeTime.hour.toString().padLeft(2, '0')}:'
          '${selectedExchangeTime.minute.toString().padLeft(2, '0')}:00';

      final createdAt =
          DateTime.now().toUtc().toIso8601String();

      await ghataSaveLocal(
        'exchanges',
        {
          'id': exchangeId,
          'user_id': user.id,
          'exchange_date': exchangeDate,
          'exchange_time': exchangeTime,
          'exchange_type': exchangeType,
          'customer_id': selectedCustomerId,
          'customer_name': selectedCustomerName,
          'notes': notesController.text.trim(),
          'deleted_at': null,
          'purged_at': null,
          'created_at': createdAt,
        },
      );

      await ghataSaveLocal(
        'exchange_entries',
        {
          'id': _ghataUuid.v4(),
          'exchange_id': exchangeId,
          'entry_type': 'money_out',
          'amount': fromAmount,
          'currency': fromCurrency,
          'rate': rate,
          'created_at': createdAt,
        },
      );

      await ghataSaveLocal(
        'exchange_entries',
        {
          'id': _ghataUuid.v4(),
          'exchange_id': exchangeId,
          'entry_type': 'money_in',
          'amount': toAmount,
          'currency': toCurrency,
          'rate': rate,
          'created_at': createdAt,
        },
      );

      ghataTrySync();

      if (!mounted) return;

      fromAmountController.clear();
      toAmountController.clear();
      rateController.clear();
      notesController.clear();

      setState(() {
        selectedCustomerId = null;
        selectedCustomerName = null;
        selectedExchangeDate = DateTime.now();
        selectedExchangeTime = TimeOfDay.now();
        fromCalculatorResult = null;
        toCalculatorResult = null;
        rateCalculatorResult = null;
        lastExchangeInput = null;
        exchangeRateManuallySet = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Exchange saved successfully.')),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to save exchange')}: $e"),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF123D2B),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text(ghataT(context, 'Exchange')),
      ),
      body: ListView(
        padding: EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            value: exchangeType,
            decoration: InputDecoration(
              labelText: ghataT(context, 'Exchange Type'),
              border: OutlineInputBorder(),
            ),
            items:  [
              DropdownMenuItem(
                value: 'buy',
                child: Text(ghataT(context, 'Buy')),
              ),
              DropdownMenuItem(
                value: 'sell',
                child: Text(ghataT(context, 'Sell')),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => exchangeType = value);
              }
            },
          ),
          SizedBox(height: 12),

          DropdownButtonFormField<String>(
            value: fromCurrency,
            decoration: InputDecoration(
              labelText: ghataT(context, 'From Currency'),
              border: OutlineInputBorder(),
            ),
            items: currencies.map((item) {
              return DropdownMenuItem<String>(
                value: item.$1,
                child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ghataCurrencyFlagWidget(
                                item.$1,
                                width: 26,
                                height: 18,
                              ),
                              SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  '${item.$1} - ${item.$3}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
              );
            }).toList(),
            onChanged: (value) {
              if (value != null) {
                setState(() => fromCurrency = value);
              }
            },
          ),
          SizedBox(height: 12),

          GhataCalculatorField(
            controller: fromAmountController,
            label: ghataT(context, 'From Amount'),
            onChanged: () =>
                updateExchangeCalculatorResults(changed: 'from'),
          ),
          if (fromCalculatorResult != null) ...[
            SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Result: ${fromCalculatorResult!.toStringAsFixed(fromCalculatorResult! % 1 == 0 ? 0 : 2)} $fromCurrency',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
          SizedBox(height: 12),

          DropdownButtonFormField<String>(
            value: toCurrency,
            decoration: InputDecoration(
              labelText: ghataT(context, 'To Currency'),
              border: OutlineInputBorder(),
            ),
            items: currencies.map((item) {
              return DropdownMenuItem<String>(
                value: item.$1,
                child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ghataCurrencyFlagWidget(
                                item.$1,
                                width: 26,
                                height: 18,
                              ),
                              SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  '${item.$1} - ${item.$3}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
              );
            }).toList(),
            onChanged: (value) {
              if (value != null) {
                setState(() => toCurrency = value);
              }
            },
          ),
          SizedBox(height: 12),

          GhataCalculatorField(
            controller: toAmountController,
            label: ghataT(context, 'To Amount'),
            onChanged: () =>
                updateExchangeCalculatorResults(changed: 'to'),
          ),
          if (toCalculatorResult != null) ...[
            SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Result: ${toCalculatorResult!.toStringAsFixed(toCalculatorResult! % 1 == 0 ? 0 : 2)} $toCurrency',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
          SizedBox(height: 12),

          GhataCalculatorField(
            controller: rateController,
            label: ghataT(context, 'Rate (optional)'),
            onChanged: () =>
                updateExchangeCalculatorResults(changed: 'rate'),
          ),
          if (rateCalculatorResult != null) ...[
            SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '1 $fromCurrency = ${rateCalculatorResult!.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')} $toCurrency',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
          SizedBox(height: 12),

          FutureBuilder<List<Map<String, dynamic>>>(
            future: exchangeCustomersFuture,
            builder: (context, snapshot) {
              final customers = snapshot.data ?? [];

              return DropdownButtonFormField<String?>(
                value: selectedCustomerId,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Customer (optional)'),
                  border: OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(ghataT(context, 'No Customer')),
                  ),
                  ...customers.map((customer) {
                    final id = customer['id'].toString();
                    final name =
                        customer['full_name']?.toString() ?? '';
                    final phone =
                        customer['phone']?.toString() ?? '';

                    return DropdownMenuItem<String?>(
                      value: id,
                      child: Text(
                        phone.isEmpty ? name : '$name - $phone',
                      ),
                    );
                  }),
                ],
                onChanged: (value) {
                  setState(() {
                    selectedCustomerId = value;

                    if (value == null) {
                      selectedCustomerName = null;
                    } else {
                      final match = customers.firstWhere(
                        (customer) =>
                            customer['id'].toString() == value,
                      );

                      selectedCustomerName =
                          match['full_name']?.toString();
                    }
                  });
                },
              );
            },
          ),
          SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: Icon(Icons.calendar_month),
                  label: Text(
                    '${selectedExchangeDate.year}-${selectedExchangeDate.month.toString().padLeft(2, '0')}-${selectedExchangeDate.day.toString().padLeft(2, '0')}',
                  ),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: selectedExchangeDate,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );

                    if (picked != null) {
                      setState(() => selectedExchangeDate = picked);
                    }
                  },
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: Icon(Icons.access_time),
                  label: Text(selectedExchangeTime.format(context)),
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: selectedExchangeTime,
                    );

                    if (picked != null) {
                      setState(() => selectedExchangeTime = picked);
                    }
                  },
                ),
              ),
            ],
          ),

          SizedBox(height: 12),

          TextField(
            controller: notesController,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: ghataT(context, 'Notes'),
              border: OutlineInputBorder(),
            ),
          ),
          SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
            onPressed: isSaving ? null : saveExchange,
            icon: Icon(Icons.currency_exchange_rounded),
            label: Text(
              isSaving
                  ? ghataT(context, 'Saving...')
                  : ghataT(context, 'Record Exchange'),
            ),
          ),
          ),

          SizedBox(height: 28),

          FutureBuilder<List<Map<String, dynamic>>>(
            future: exchangeHistoryFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return SizedBox.shrink();
              }

              final profitLoss =
                  calculateExchangeProfitLoss(snapshot.data!);

              final visible = profitLoss.where((item) {
                final profit = item['profit'] as double;
                final unmatchedSell = item['unmatched_sell'] as double;
                return profit.abs() >= 0.0000001 ||
                    unmatchedSell > 0.0000001;
              }).toList();

              if (visible.isEmpty) {
                return SizedBox.shrink();
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ghataT(context, 'Profit / Loss'),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 10),
                  ...visible.map((item) {
                    final asset =
                        item['asset_currency']?.toString() ?? '';
                    final settlement =
                        item['settlement_currency']?.toString() ?? '';
                    final profit = item['profit'] as double;
                    final unmatchedSell = item['unmatched_sell'] as double;

                    final text = [
                      if (profit.abs() >= 0.0000001)
                        profit >= 0 ? 'Profit' : 'Loss',
                      if (unmatchedSell > 0.0000001)
                        'Unmatched Sell: ${unmatchedSell.toStringAsFixed(2)} $asset',
                    ].join(' • ');

                    final isPositive = profit >= 0;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness ==
                                Brightness.dark
                            ? Theme.of(context).colorScheme.surface
                            : const Color(0xFFFFFBF2),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Theme.of(context).brightness ==
                                  Brightness.dark
                              ? Theme.of(context)
                                  .colorScheme
                                  .outlineVariant
                              : const Color(0xFFE4D59B),
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: (isPositive
                                    ? Colors.green
                                    : Colors.red)
                                .withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            isPositive
                                ? Icons.trending_up_rounded
                                : Icons.trending_down_rounded,
                            color:
                                isPositive ? Colors.green : Colors.red,
                          ),
                        ),
                        title: Row(
                          children: [
                            ghataCurrencyFlagWidget(asset),
                            const SizedBox(width: 6),
                            Text('$asset /'),
                            const SizedBox(width: 6),
                            ghataCurrencyFlagWidget(settlement),
                            const SizedBox(width: 6),
                            Text(settlement),
                          ],
                        ),
                        subtitle: text.isEmpty ? null : Text(text),
                        trailing: Text(
                          '${profit > 0 ? '+' : ''}${profit.toStringAsFixed(2)} $settlement',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: profit > 0
                                ? Colors.green
                                : profit < 0
                                    ? Colors.red
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                          ),
                        ),
                      ),
                    );
                  }),
                  SizedBox(height: 16),
                ],
              );
            },
          ),

          Divider(),
          SizedBox(height: 12),

          Row(
            children: [
              Icon(Icons.history_rounded),
              SizedBox(width: 8),
              Text(
            ghataT(context, 'Recent Exchanges'),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          SizedBox(height: 10),

          FutureBuilder<List<Map<String, dynamic>>>(
            future: exchangeHistoryFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState ==
                  ConnectionState.waiting) {
                return Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                );
              }

              if (snapshot.hasError) {
                return Text(
                  "${ghataT(context, 'Unable to load exchange history')}: ${snapshot.error}",
                );
              }

              final history = snapshot.data ?? [];

              if (history.isEmpty) {
                return Text(ghataT(context, 'No exchange history yet.'));
              }

              return Column(
                children: history.map((exchange) {
                  final entries =
                      List<Map<String, dynamic>>.from(
                    exchange['entries'] ?? [],
                  );

                  Map<String, dynamic>? outEntry;
                  Map<String, dynamic>? inEntry;

                  for (final entry in entries) {
                    if (entry['entry_type'] == 'money_out') {
                      outEntry = entry;
                    } else if (entry['entry_type'] == 'money_in') {
                      inEntry = entry;
                    }
                  }

                  final customer =
                      exchange['customer_name']?.toString();

                  final date =
                      exchange['exchange_date']?.toString() ?? '';
                  final rawTime =
                      exchange['exchange_time']?.toString() ?? '';
                  final time = rawTime.length >= 5
                      ? rawTime.substring(0, 5)
                      : '';

                  final outCurrency =
                      outEntry?['currency']?.toString() ?? '';
                  final inCurrency =
                      inEntry?['currency']?.toString() ?? '';

                  final outText = outEntry == null
                      ? '-'
                      : '${outEntry['amount']} $outCurrency';

                  final inText = inEntry == null
                      ? '-'
                      : '${inEntry['amount']} $inCurrency';

                  final rate =
                      outEntry?['rate']?.toString() ??
                      inEntry?['rate']?.toString();

                  final notes =
                      exchange['notes']?.toString() ?? '';

                  final exchangeType =
                      exchange['exchange_type']?.toString() ?? 'buy';
                  final exchangeTypeLabel =
                      exchangeType == 'sell' ? 'Sell' : 'Buy';

                  final details = <String>[
                    exchangeTypeLabel,
                    if (customer != null && customer.isNotEmpty)
                      customer,
                    if (time.isEmpty) date else '$date $time',
                    if (rate != null && rate.isNotEmpty)
                      'Rate: $rate',
                    if (notes.isNotEmpty)
                      notes,
                  ];

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness ==
                              Brightness.dark
                          ? Theme.of(context).colorScheme.surface
                          : const Color(0xFFFFFBF2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Theme.of(context).brightness ==
                                Brightness.dark
                            ? Theme.of(context)
                                .colorScheme
                                .outlineVariant
                            : const Color(0xFFDDECC8),
                      ),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(
                        12,
                        5,
                        4,
                        5,
                      ),
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFE8A3)
                              .withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.currency_exchange_rounded,
                          color: Color(0xFF123D2B),
                        ),
                      ),
                      title: Row(
                        children: [
                          if (outEntry != null) ...[
                            ghataCurrencyFlagWidget(
                              outCurrency,
                              width: 24,
                              height: 16,
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(outText),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('→'),
                          ),
                          if (inEntry != null) ...[
                            ghataCurrencyFlagWidget(
                              inCurrency,
                              width: 24,
                              height: 16,
                            ),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: Text(
                              inText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        details.join(' • '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: ghataT(context, 'Edit Exchange'),
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => editExchange(exchange),
                          ),
                          IconButton(
                            tooltip: ghataT(context, 'Delete Exchange'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => deleteExchange(exchange),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: const _GhataAppBottomNav(
        selectedIndex: 4,
      ),
    );
  }

  @override
  void dispose() {
    ghataDataRevision.removeListener(_handleRealtimeDataRevision);
    fromAmountController.dispose();
    toAmountController.dispose();
    rateController.dispose();
    notesController.dispose();
    super.dispose();
  }
}

class ReportsScreen extends StatefulWidget {
  ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {

  late Future<List<Map<String, dynamic>>> reportsCustomersFuture;
  late Future<List<Map<String, dynamic>>> reportsTransactionsFuture;

  @override
  void initState() {
    super.initState();
    reportsCustomersFuture = loadCustomers();
    reportsTransactionsFuture = loadTransactions();
    ghataDataRevision.addListener(_handleRealtimeDataRevision);
  }

  void _handleRealtimeDataRevision() {
    if (!mounted) return;

    // Realtime sync already updated SQLite.
    // Reports only needs to reread local data.
    setState(() {
      reportsCustomersFuture = loadCustomers(refreshCloud: false);
      reportsTransactionsFuture = loadTransactions();
    });
  }

  @override
  void dispose() {
    ghataDataRevision.removeListener(_handleRealtimeDataRevision);
    super.dispose();
  }

  DateTime? fromDate;
  DateTime? toDate;
  String? selectedCurrency;
  String? selectedCustomerId;

  // Keep customer reports separate from Daily Journal.
  String reportScope = 'customers';

  final reportCurrencies = [
    'AFN',
    'PKR',
    'USD',
    'EUR',
    'GBP',
    'AED',
    'SAR',
    'KWD',
    'QAR',
    'OMR',
    'TRY',
    'CNY',
    'INR',
    'IRR',
  ];

  Future<List<Map<String, dynamic>>> loadCustomers({
    bool refreshCloud = true,
  }) async {
    var local =
        await OfflineDatabase.instance.getRecords('customers');

    // Offline-first: use SQLite immediately.
    if (refreshCloud) ghataRefreshCustomersCache();

    local.sort(
      (a, b) => (a['full_name']?.toString() ?? '')
          .compareTo(b['full_name']?.toString() ?? ''),
    );

    return local;
  }

  Future<List<Map<String, dynamic>>> loadTransactions() async {
    final all = await ghataLocalFinancialRows();


    return all.where((transaction) {
      final transactionCurrency =
          transaction['currency']?.toString() ?? '';

      if (selectedCurrency != null &&
          transactionCurrency != selectedCurrency) {
        return false;
      }

      final transactionCustomerId =
          transaction['customer_id']?.toString().trim() ?? '';
      final hasCustomer = transactionCustomerId.isNotEmpty;

      if (reportScope == 'journal') {
        // Daily Journal = records without customer_id.
        if (hasCustomer) return false;
      } else {
        // Customer reports = customer-linked records only.
        if (!hasCustomer) return false;

        if (selectedCustomerId != null &&
            transactionCustomerId != selectedCustomerId) {
          return false;
        }
      }

      final rawDate = transaction['transaction_date']?.toString();
      if (rawDate == null || rawDate.isEmpty) return true;

      final date = DateTime.tryParse(rawDate);
      if (date == null) return true;

      final normalized =
          DateTime(date.year, date.month, date.day);

      if (fromDate != null) {
        final from =
            DateTime(fromDate!.year, fromDate!.month, fromDate!.day);
        if (normalized.isBefore(from)) return false;
      }

      if (toDate != null) {
        final to =
            DateTime(toDate!.year, toDate!.month, toDate!.day);
        if (normalized.isAfter(to)) return false;
      }

      return true;
    }).toList();
  }

  Map<String, Map<String, double>> calculateReport(
    List<Map<String, dynamic>> transactions,
  ) {
    final report = <String, Map<String, double>>{};

    for (final transaction in transactions) {
      final currency = transaction['currency']?.toString() ?? '';
      final type =
          transaction['transaction_type']?.toString() ?? '';
      final amount =
          double.tryParse(transaction['amount']?.toString() ?? '0') ??
              0;

      if (currency.isEmpty || amount <= 0) continue;

      report.putIfAbsent(
        currency,
        () => {
          'money_in': 0,
          'money_out': 0,
          'exchange_in': 0,
          'exchange_out': 0,
          'adjustment_in': 0,
          'adjustment_out': 0,
          'net_cash_flow': 0,
        },
      );

      final row = report[currency]!;

      if (row.containsKey(type)) {
        row[type] = row[type]! + amount;
      }

      if (type == 'money_in' ||
          type == 'exchange_in' ||
          type == 'adjustment_in') {
        row['net_cash_flow'] = row['net_cash_flow']! + amount;
      } else if (type == 'money_out' ||
          type == 'exchange_out' ||
          type == 'adjustment_out') {
        row['net_cash_flow'] = row['net_cash_flow']! - amount;
      }
    }

    return report;
  }

  String flagForCurrency(String code) {
    const flags = {
      'AFN': '🇦🇫',
      'PKR': '🇵🇰',
      'USD': '🇺🇸',
      'EUR': '🇪🇺',
      'GBP': '🇬🇧',
      'AED': '🇦🇪',
      'SAR': '🇸🇦',
      'KWD': '🇰🇼',
      'QAR': '🇶🇦',
      'OMR': '🇴🇲',
      'TRY': '🇹🇷',
      'CNY': '🇨🇳',
      'INR': '🇮🇳',
      'IRR': '🇮🇷',
    };
    return flags[code] ?? '💰';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF123D2B),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text(ghataT(context, 'Reports')),
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: Icon(Icons.date_range),
                    label: Text(
                      fromDate == null
                          ? ghataT(context, 'From Date')
                          : '${fromDate!.year}-${fromDate!.month.toString().padLeft(2, '0')}-${fromDate!.day.toString().padLeft(2, '0')}',
                    ),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: fromDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: toDate ?? DateTime(2100),
                      );
                      if (picked != null) {
                        setState(() => fromDate = picked);
                      }
                    },
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: Icon(Icons.event),
                    label: Text(
                      toDate == null
                          ? ghataT(context, 'To Date')
                          : '${toDate!.year}-${toDate!.month.toString().padLeft(2, '0')}-${toDate!.day.toString().padLeft(2, '0')}',
                    ),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: toDate ??
                            (fromDate != null &&
                                    DateTime.now().isBefore(fromDate!)
                                ? fromDate!
                                : DateTime.now()),
                        firstDate: fromDate ?? DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) {
                        setState(() => toDate = picked);
                      }
                    },
                  ),
                ),
                if (fromDate != null || toDate != null)
                  IconButton(
                    tooltip: ghataT(context, 'Clear dates'),
                    icon: Icon(Icons.clear),
                    onPressed: () {
                      setState(() {
                        fromDate = null;
                        toDate = null;
                      });
                    },
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: DropdownButtonFormField<String?>(
              value: selectedCurrency,
              decoration: InputDecoration(
                labelText: ghataT(context, 'Currency'),
                border: OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text(ghataT(context, 'All currencies')),
                ),
                ...reportCurrencies.map(
                  (code) => DropdownMenuItem<String?>(
                    value: code,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ghataCurrencyFlagWidget(code),
                        SizedBox(width: 8),
                        Text(code),
                      ],
                    ),
                  ),
                ),
              ],
              onChanged: (value) {
                setState(() => selectedCurrency = value);
              },
            ),
          ),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SegmentedButton<String>(
                segments: [
                  ButtonSegment<String>(
                    value: 'customers',
                    icon: Icon(Icons.people_outline),
                    label: Text(ghataT(context, 'Customers')),
                  ),
                  ButtonSegment<String>(
                    value: 'journal',
                    icon: Icon(Icons.menu_book_outlined),
                    label: Text(ghataT(context, 'Daily Journal')),
                  ),
                ],
                selected: {reportScope},
                onSelectionChanged: (selection) {
                  if (selection.isEmpty) return;

                  setState(() {
                    reportScope = selection.first;
                    if (reportScope == 'journal') {
                      selectedCustomerId = null;
                    }
                  });
                },
              ),
            ),
            if (reportScope == 'customers')
          Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: reportsCustomersFuture,
              builder: (context, snapshot) {
                final customers = snapshot.data ?? [];

                return DropdownButtonFormField<String?>(
                  value: selectedCustomerId,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Customer'),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(ghataT(context, 'All customers')),
                    ),
                    ...customers.map(
                      (customer) => DropdownMenuItem<String?>(
                        value: customer['id']?.toString(),
                        child: Text(
                          customer['full_name']?.toString() ?? 'Unnamed',
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() => selectedCustomerId = value);
                  },
                );
              },
            ),
          ),
          if (fromDate != null ||
              toDate != null ||
              selectedCurrency != null ||
              selectedCustomerId != null)
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: Icon(Icons.filter_alt_off_outlined),
                  label: Text(ghataT(context, 'Clear All Filters')),
                  onPressed: () {
                    setState(() {
                      fromDate = null;
                      toDate = null;
                      selectedCurrency = null;
                      selectedCustomerId = null;
                    });
                  },
                ),
              ),
            ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: reportsTransactionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  "${ghataT(context, 'Unable to load reports')}: ${snapshot.error}",
                ),
              ),
            );
          }

          final transactions = snapshot.data ?? [];
          final report = calculateReport(transactions);

          if (report.isEmpty) {
            return Center(
              child: Text(ghataT(context, 'No report data yet.')),
            );
          }

          return ListView(
            padding: EdgeInsets.all(16),
            children: [
              Text(
                ghataT(context, 'Currency Summary'),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 12),

              Builder(
                                                  builder: (context) {
                                                    final visibleSummary =
                                                        report.entries.where((entry) {
                                                      final data = entry.value;
                                                      return (data['money_in'] ?? 0).abs() >
                                                              0.000001 ||
                                                          (data['money_out'] ?? 0).abs() >
                                                              0.000001 ||
                                                          (data['net_cash_flow'] ?? 0).abs() >
                                                              0.000001;
                                                    }).toList();

                                                    if (visibleSummary.isEmpty) {
                                                      return SizedBox.shrink();
                                                    }

                                                    const cardColors = [
                                                      Color(0xFFEAF3FF),
                                                      Color(0xFFECF8F0),
                                                      Color(0xFFFFF4E5),
                                                      Color(0xFFF2ECFF),
                                                      Color(0xFFFFECEC),
                                                      Color(0xFFE9F8F8),
                                                    ];

                                                    return SizedBox(
                                                      height: 165,
                                                      child: ListView.separated(
                                                        scrollDirection:
                                                            Axis.horizontal,
                                                        physics:
                                                            BouncingScrollPhysics(),
                                                        itemCount:
                                                            visibleSummary.length,
                                                        separatorBuilder:
                                                            (_, __) =>
                                                                SizedBox(width: 10),
                                                        itemBuilder:
                                                            (context, index) {
                                                          final entry =
                                                              visibleSummary[index];
                                                          final currency =
                                                              entry.key;
                                                          final data =
                                                              entry.value;

                                                          final moneyIn =
                                                              (data['money_in'] ??
                                                                      0)
                                                                  .toDouble();
                                                          final moneyOut =
                                                              (data['money_out'] ??
                                                                      0)
                                                                  .toDouble();
                                                          final net =
                                                              (data['net_cash_flow'] ??
                                                                      0)
                                                                  .toDouble();

                                                          return Container(
                                                            width: 190,
                                                            padding:
                                                                EdgeInsets.all(14),
                                                            decoration:
                                                                BoxDecoration(
                                                              color: cardColors[
                                                                  index %
                                                                      cardColors
                                                                          .length],
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(18),
                                                              border: Border.all(
                                                                color: Theme.of(
                                                                        context)
                                                                    .colorScheme
                                                                    .outlineVariant
                                                                    .withValues(
                                                                        alpha:
                                                                            0.55),
                                                              ),
                                                            ),
                                                            child: Column(
                                                              crossAxisAlignment:
                                                                  CrossAxisAlignment
                                                                      .start,
                                                              children: [
                                                                Row(
                                                                  children: [
                                                                      ghataCurrencyFlagWidget(
                                                                        currency,
                                                                        width: 34,
                                                                        height: 24,
                                                                      ),
                                                                    SizedBox(
                                                                        width:
                                                                            8),
                                                                    Expanded(
                                                                      child:
                                                                          Text(
                                                                        currency,
                                                                        style:
                                                                            TextStyle(
                                                                          fontSize:
                                                                              18,
                                                                          fontWeight:
                                                                              FontWeight.bold,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                                SizedBox(
                                                                    height: 12),
                                                                Row(
                                                                  children: [
                                                                    Icon(
                                                                      Icons
                                                                          .south_west_rounded,
                                                                      size: 17,
                                                                      color: Colors
                                                                          .green
                                                                          .shade700,
                                                                    ),
                                                                    SizedBox(
                                                                        width:
                                                                            5),
                                                                    Expanded(
                                                                      child:
                                                                          Text(
                                                                        '${ghataT(context, 'Money In')}: ${moneyIn.toStringAsFixed(2)}',
                                                                        style:
                                                                            TextStyle(
                                                                          color: Colors
                                                                              .green
                                                                              .shade700,
                                                                          fontWeight:
                                                                              FontWeight.w600,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                                SizedBox(
                                                                    height: 5),
                                                                Row(
                                                                  children: [
                                                                    Icon(
                                                                      Icons
                                                                          .north_east_rounded,
                                                                      size: 17,
                                                                      color: Colors
                                                                          .red
                                                                          .shade700,
                                                                    ),
                                                                    SizedBox(
                                                                        width:
                                                                            5),
                                                                    Expanded(
                                                                      child:
                                                                          Text(
                                                                        '${ghataT(context, 'Money Out')}: ${moneyOut.toStringAsFixed(2)}',
                                                                        style:
                                                                            TextStyle(
                                                                          color: Colors
                                                                              .red
                                                                              .shade700,
                                                                          fontWeight:
                                                                              FontWeight.w600,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                                SizedBox(
                                                                    height: 10),
                                                                Divider(height: 1),
                                                                SizedBox(
                                                                    height: 9),
                                                                Text(
                                                                  'Net: ${net.toStringAsFixed(2)}',
                                                                  style:
                                                                      TextStyle(
                                                                    fontSize: 16,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .bold,
                                                                    color: net >
                                                                            0
                                                                        ? Colors
                                                                            .green
                                                                            .shade800
                                                                        : net <
                                                                                0
                                                                            ? Colors
                                                                                .red
                                                                                .shade800
                                                                            : Theme.of(context)
                                                                                .colorScheme
                                                                                .onSurfaceVariant,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          );
                                                        },
                                                      ),
                                                    );
                                                  },
                                                ),

                                                SizedBox(height: 22),

              Text(
                ghataT(context, 'Detailed Report'),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 10),

              ...report.entries.map((entry) {
                final currency = entry.key;
                final data = entry.value;

                Widget row(String title, String key) {
                  return Padding(
                    padding:
                        EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Expanded(child: Text(title)),
                        Text(
                          data[key]!.toStringAsFixed(2),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return Card(
                  margin: EdgeInsets.only(bottom: 10),
                  child: ExpansionTile(
                    leading: CircleAvatar(
                      child: ghataCurrencyFlagWidget(
                        currency,
                        width: 26,
                        height: 18,
                      ),
                    ),
                    title: Text(
                      currency,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      '${ghataT(context, 'Net Cash Flow')}: ${data['net_cash_flow']!.toStringAsFixed(2)}',
                    ),
                    childrenPadding:
                        EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      row(ghataT(context, 'Money In'), 'money_in'),
                      row(ghataT(context, 'Money Out'), 'money_out'),
                      row(ghataT(context, 'Exchange In'), 'exchange_in'),
                      row(ghataT(context, 'Exchange Out'), 'exchange_out'),
                      row(ghataT(context, 'Adjustment In'), 'adjustment_in'),
                      row(ghataT(context, 'Adjustment Out'), 'adjustment_out'),
                    ],
                  ),
                );
              }),

              SizedBox(height: 80),
            ],
          );
        },
      ),
          ),
        ],
      ),

      bottomNavigationBar: const _GhataAppBottomNav(
        selectedIndex: 5,
      ),
);
  }
}
