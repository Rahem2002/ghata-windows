import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'services/offline_database.dart';
import 'services/offline_sync_service.dart';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';




const _ghataUuid = Uuid();

Future<void> ghataTrySync() async {
  try {
    await OfflineSyncService.instance.syncPending();
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

  // Best effort only. Local save already succeeded.
  ghataTrySync();
}

Future<void> ghataSoftDeleteLocal(
  String table,
  String id,
) async {
  await OfflineDatabase.instance.softDeleteLocalRecord(table, id);
  ghataTrySync();
}


Future<void> ghataRefreshOfflineCache() async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return;

  try {
    final customers =
        await Supabase.instance.client.from('customers').select();

    await OfflineDatabase.instance.cacheServerRecords(
      'customers',
      List<Map<String, dynamic>>.from(customers),
    );
  } catch (_) {}

  try {
    final transactions =
        await Supabase.instance.client.from('transactions').select();

    await OfflineDatabase.instance.cacheServerRecords(
      'transactions',
      List<Map<String, dynamic>>.from(transactions),
    );
  } catch (_) {}

  try {
    final exchanges =
        await Supabase.instance.client.from('exchanges').select();

    await OfflineDatabase.instance.cacheServerRecords(
      'exchanges',
      List<Map<String, dynamic>>.from(exchanges),
    );
  } catch (_) {}

  try {
    final entries =
        await Supabase.instance.client.from('exchange_entries').select();

    await OfflineDatabase.instance.cacheServerRecords(
      'exchange_entries',
      List<Map<String, dynamic>>.from(entries),
    );
  } catch (_) {}
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
  await ghataRefreshOfflineCache();

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
      'loan_given',
      'loan_received',
      'loan_repayment_received',
      'loan_repayment_paid',
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

            return SafeArea(
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  runApp(GhataApp());
}


const Map<String, Map<String, String>> ghataTranslations = {
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
  'Loan Given': {
    'en': 'Loan Given',
    'ps': 'ورکړل شوی پور',
    'fa': 'قرض داده‌شده',
    'ur': 'دیا گیا قرض',
    'ar': 'قرض مُعطى',
  },
  'Loan Received': {
    'en': 'Loan Received',
    'ps': 'اخیستل شوی پور',
    'fa': 'قرض دریافت‌شده',
    'ur': 'لیا گیا قرض',
    'ar': 'قرض مستلم',
  },
  'Repayment Received': {
    'en': 'Repayment Received',
    'ps': 'ترلاسه شوې د پور ورکړه',
    'fa': 'بازپرداخت دریافت‌شده',
    'ur': 'واپسی موصول',
    'ar': 'دفعة مستلمة',
  },
  'Repayment Paid': {
    'en': 'Repayment Paid',
    'ps': 'ورکړل شوې د پور ورکړه',
    'fa': 'بازپرداخت پرداخت‌شده',
    'ur': 'واپسی ادا کی گئی',
    'ar': 'دفعة مدفوعة',
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
  'Due Date': {
    'en': 'Due Date',
    'ps': 'د ورکړې نېټه',
    'fa': 'تاریخ سررسید',
    'ur': 'واجب الادا تاریخ',
    'ar': 'تاريخ الاستحقاق',
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
  'Search loans': {
    'en': 'Search loans',
    'ps': 'پورونه ولټوئ',
    'fa': 'جستجوی قرض‌ها',
    'ur': 'قرض تلاش کریں',
    'ar': 'بحث القروض',
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
  'Loans & Debts': {
    'en': 'Loans & Debts',
    'ps': 'پورونه او قرضونه',
    'fa': 'قرض‌ها و بدهی‌ها',
    'ur': 'قرض اور واجبات',
    'ar': 'القروض والديون',
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
  'Test App Lock': {
    'en': 'Test App Lock',
    'ps': 'د اپ قلف وازمویئ',
    'fa': 'آزمایش قفل برنامه',
    'ur': 'ایپ لاک آزمائیں',
    'ar': 'اختبار قفل التطبيق',
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
  'Use Customers to create and manage customer accounts. Open a customer profile to see their transaction history and separate balances for every currency. You can also edit customer information and create customer transactions.': {
    'en': 'Use Customers to create and manage customer accounts. Open a customer profile to see their transaction history and separate balances for every currency. You can also edit customer information and create customer transactions.',
    'ps': 'د پېرودونکو برخه د پېرودونکو حسابونو د جوړولو او مدیریت لپاره وکاروئ. د پېرودونکي پروفایل خلاص کړئ ترڅو د هغه د معاملو تاریخ او د هر اسعار جلا بیلانس وګورئ. د پېرودونکي معلومات هم سمولای او نوې معاملې ورته جوړولای شئ.',
    'fa': 'از بخش مشتریان برای ایجاد و مدیریت حساب‌های مشتری استفاده کنید. پروفایل مشتری را باز کنید تا تاریخچه معاملات و موجودی جداگانه هر ارز را ببینید. همچنین می‌توانید اطلاعات مشتری را ویرایش و برای او معامله ثبت کنید.',
    'ur': 'گاہکوں کے اکاؤنٹس بنانے اور منظم کرنے کے لیے Customers استعمال کریں۔ گاہک کا پروفائل کھول کر لین دین کی تاریخ اور ہر کرنسی کا الگ بیلنس دیکھیں۔ آپ گاہک کی معلومات میں ترمیم اور اس کے لیے نئی ٹرانزیکشن بھی بنا سکتے ہیں۔',
    'ar': 'استخدم قسم العملاء لإنشاء حسابات العملاء وإدارتها. افتح ملف العميل لعرض سجل معاملاته وأرصدته المنفصلة لكل عملة. ويمكنك أيضًا تعديل معلومات العميل وإنشاء معاملات له.',
  },
  'Use the Add button to record Money In, Money Out, loans, loan repayments and adjustments. Select the correct currency, date, time and customer when required. You can also add a description and reference number.': {
    'en': 'Use the Add button to record Money In, Money Out, loans, loan repayments and adjustments. Select the correct currency, date, time and customer when required. You can also add a description and reference number.',
    'ps': 'د Add تڼۍ په وسیله داخلې پیسې، وتلې پیسې، پورونه، د پور تادیات او سمونونه ثبت کړئ. اړین اسعار، نېټه، وخت او پېرودونکی په سمه توګه وټاکئ. تشریح او د حوالې شمېره هم اضافه کولای شئ.',
    'fa': 'با دکمه افزودن، پول ورودی، پول خروجی، قرض‌ها، بازپرداخت قرض و اصلاحات را ثبت کنید. در صورت نیاز ارز، تاریخ، زمان و مشتری درست را انتخاب کنید. توضیحات و شماره مرجع نیز قابل افزودن است.',
    'ur': 'Add بٹن سے رقم وصول، رقم ادائیگی، قرض، قرض کی واپسی اور ایڈجسٹمنٹ درج کریں۔ ضرورت کے مطابق درست کرنسی، تاریخ، وقت اور گاہک منتخب کریں۔ تفصیل اور حوالہ نمبر بھی شامل کیا جا سکتا ہے۔',
    'ar': 'استخدم زر الإضافة لتسجيل الأموال الداخلة والخارجة والقروض وسداد القروض والتعديلات. اختر العملة والتاريخ والوقت والعميل الصحيح عند الحاجة. ويمكنك أيضًا إضافة وصف ورقم مرجعي.',
  },
  'The Daily Journal keeps your transaction history. Use search and filters to find transactions. Transactions can be reviewed with their amount, currency, customer, date, time and description.': {
    'en': 'The Daily Journal keeps your transaction history. Use search and filters to find transactions. Transactions can be reviewed with their amount, currency, customer, date, time and description.',
    'ps': 'ورځنی ژورنال ستاسو د معاملو تاریخ ساتي. د معاملې موندلو لپاره لټون او فلټرونه وکاروئ. هره معامله د مبلغ، اسعار، پېرودونکي، نېټې، وخت او تشریح سره کتلای شئ.',
    'fa': 'دفتر روزانه تاریخچه معاملات شما را نگهداری می‌کند. برای یافتن معاملات از جستجو و فیلترها استفاده کنید. هر معامله با مبلغ، ارز، مشتری، تاریخ، زمان و توضیحات قابل مشاهده است.',
    'ur': 'روزانہ جرنل آپ کے لین دین کی تاریخ محفوظ رکھتا ہے۔ ٹرانزیکشن تلاش کرنے کے لیے سرچ اور فلٹر استعمال کریں۔ ہر لین دین کو رقم، کرنسی، گاہک، تاریخ، وقت اور تفصیل کے ساتھ دیکھا جا سکتا ہے۔',
    'ar': 'يحتفظ السجل اليومي بتاريخ معاملاتك. استخدم البحث وعوامل التصفية للعثور على المعاملات. ويمكن مراجعة كل معاملة مع المبلغ والعملة والعميل والتاريخ والوقت والوصف.',
  },
  'Ghata tracks money customers owe you and money you owe them. Loan repayments reduce the related balance while keeping the accounting history available.': {
    'en': 'Ghata tracks money customers owe you and money you owe them. Loan repayments reduce the related balance while keeping the accounting history available.',
    'ps': 'ګهته هغه پیسې ثبتوي چې پېرودونکي یې تاسو ته پوروړي دي او هغه پیسې چې تاسو یې هغوی ته پوروړي یاست. د پور تادیات اړوند بیلانس کموي، خو د حسابدارۍ تاریخ خوندي ساتي.',
    'fa': 'گِهته مبالغی را که مشتریان به شما بدهکارند و مبالغی را که شما به آنان بدهکارید پیگیری می‌کند. بازپرداخت قرض، موجودی مربوط را کاهش می‌دهد و تاریخچه حسابداری را حفظ می‌کند.',
    'ur': 'گھتہ وہ رقم ریکارڈ کرتا ہے جو گاہکوں نے آپ کو دینی ہے اور وہ رقم جو آپ نے انہیں دینی ہے۔ قرض کی واپسی متعلقہ بیلنس کم کرتی ہے جبکہ اکاؤنٹنگ تاریخ محفوظ رہتی ہے۔',
    'ar': 'تتابع غهته الأموال التي يدين بها العملاء لك والأموال التي تدين بها لهم. ويؤدي سداد القروض إلى خفض الرصيد المرتبط مع الحفاظ على السجل المحاسبي.',
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
  'Reports summarize Money In, Money Out, exchanges, loans, repayments and adjustments. Reports can be filtered by date, currency and customer. Currency totals are never automatically converted into another currency.': {
    'en': 'Reports summarize Money In, Money Out, exchanges, loans, repayments and adjustments. Reports can be filtered by date, currency and customer. Currency totals are never automatically converted into another currency.',
    'ps': 'راپورونه داخلې پیسې، وتلې پیسې، تبادلې، پورونه، تادیات او سمونونه لنډیز کوي. راپورونه د نېټې، اسعار او پېرودونکي له مخې فلټر کېدای شي. د اسعارو مجموعې هېڅکله په اتومات ډول بل اسعار ته نه بدلېږي.',
    'fa': 'گزارش‌ها پول ورودی، پول خروجی، تبادلات، قرض‌ها، بازپرداخت‌ها و اصلاحات را خلاصه می‌کنند. گزارش‌ها بر اساس تاریخ، ارز و مشتری قابل فیلتر هستند. مجموع ارزها هرگز به صورت خودکار به ارز دیگری تبدیل نمی‌شود.',
    'ur': 'رپورٹس رقم وصول، رقم ادائیگی، ایکسچینج، قرض، واپسی اور ایڈجسٹمنٹ کا خلاصہ دکھاتی ہیں۔ تاریخ، کرنسی اور گاہک کے مطابق فلٹر کیا جا سکتا ہے۔ کرنسی کے مجموعے خودکار طور پر دوسری کرنسی میں تبدیل نہیں کیے جاتے۔',
    'ar': 'تلخص التقارير الأموال الداخلة والخارجة وعمليات الصرف والقروض والسداد والتعديلات. ويمكن تصفية التقارير حسب التاريخ والعملة والعميل. ولا يتم تحويل إجماليات العملات تلقائيًا إلى عملة أخرى.',
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
  'Use Security to protect access to Ghata with the available PIN and biometric options. Keep your account password and security information private.': {
    'en': 'Use Security to protect access to Ghata with the available PIN and biometric options. Keep your account password and security information private.',
    'ps': 'د PIN او بایومتریک شته انتخابونو په وسیله ګهته خوندي کړئ. د خپل حساب پاسورډ او امنیتي معلومات له نورو پټ وساتئ.',
    'fa': 'با استفاده از PIN و گزینه‌های بیومتریک موجود، دسترسی به گِهته را محافظت کنید. رمز حساب و اطلاعات امنیتی خود را محرمانه نگه دارید.',
    'ur': 'دستیاب PIN اور بایومیٹرک آپشنز سے گھتہ تک رسائی محفوظ کریں۔ اپنے اکاؤنٹ کا پاس ورڈ اور سیکیورٹی معلومات نجی رکھیں۔',
    'ar': 'استخدم خيارات PIN والقياسات الحيوية المتاحة لحماية الوصول إلى غهته. حافظ على خصوصية كلمة مرور حسابك ومعلومات الأمان.',
  },
  'Your Supabase account is the main cloud data source. Backup features can also be used to export supported business information. Keep exported backup files in a safe place.': {
    'en': 'Your Supabase account is the main cloud data source. Backup features can also be used to export supported business information. Keep exported backup files in a safe place.',
    'ps': 'ستاسو Supabase حساب د کلاوډ معلوماتو اصلي سرچینه ده. د بیک اپ له لارې ملاتړ شوي کاروباري معلومات صادرولای شئ. صادر شوي بیک اپ فایلونه په خوندي ځای کې وساتئ.',
    'fa': 'حساب Supabase شما منبع اصلی داده‌های ابری است. از امکانات پشتیبان‌گیری می‌توان برای صدور اطلاعات پشتیبانی‌شده تجارت نیز استفاده کرد. فایل‌های پشتیبان صادرشده را در محل امن نگهداری کنید.',
    'ur': 'آپ کا Supabase اکاؤنٹ کلاؤڈ ڈیٹا کا بنیادی ذریعہ ہے۔ بیک اپ فیچر سے معاون کاروباری معلومات ایکسپورٹ بھی کی جا سکتی ہیں۔ ایکسپورٹ شدہ بیک اپ فائلیں محفوظ جگہ رکھیں۔',
    'ar': 'حساب Supabase الخاص بك هو مصدر البيانات السحابية الرئيسي. ويمكن استخدام ميزات النسخ الاحتياطي لتصدير معلومات النشاط المدعومة. احتفظ بملفات النسخ الاحتياطي المصدرة في مكان آمن.',
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
  'Loans': {
    'en': 'Loans',
    'ps': 'پورونه',
    'fa': 'قرض‌ها',
    'ur': 'قرض',
    'ar': 'القروض',
  },
  'Address': {
    'en': 'Address',
    'ps': 'پته',
    'fa': 'آدرس',
    'ur': 'پتہ',
    'ar': 'العنوان',
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
  'Customer, currency, type, due date...': {
    'en': 'Customer, currency, type, due date...',
    'ps': 'پېرودونکی، اسعار، ډول، د ورکړې نېټه...',
    'fa': 'مشتری، ارز، نوع، تاریخ سررسید...',
    'ur': 'گاہک، کرنسی، قسم، آخری تاریخ...',
    'ar': 'العميل، العملة، النوع، تاريخ الاستحقاق...',
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
  'This customer has no loan to repay in this currency.': {
    'en': 'This customer has no loan to repay in this currency.',
    'ps': 'دا پېرودونکی په دې اسعارو کې د بېرته ورکولو پور نه لري.',
    'fa': 'این مشتری در این ارز قرضی برای بازپرداخت ندارد.',
    'ur': 'اس گاہک کے پاس اس کرنسی میں واپس کرنے کے لیے کوئی قرض نہیں۔',
    'ar': 'لا يوجد على هذا العميل قرض للسداد بهذه العملة.',
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
  'Loan Repayment Paid': {
    'en': 'Loan Repayment Paid',
    'ps': 'د پور ورکړل شوې تادیه',
    'fa': 'بازپرداخت قرض پرداخت‌شده',
    'ur': 'قرض کی واپسی ادا کی گئی',
    'ar': 'دفعة قرض مدفوعة',
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
  'No loan history yet.': {
    'en': 'No loan history yet.',
    'ps': 'تر اوسه د پور تاریخچه نشته.',
    'fa': 'هنوز سابقه قرض نیست.',
    'ur': 'ابھی قرض کی تاریخ نہیں۔',
    'ar': 'لا يوجد سجل قروض بعد.',
  },
  'No transactions yet.': {
    'en': 'No transactions yet.',
    'ps': 'تر اوسه معاملې نشته.',
    'fa': 'هنوز معامله‌ای نیست.',
    'ur': 'ابھی کوئی لین دین نہیں۔',
    'ar': 'لا توجد معاملات بعد.',
  },
  'Fingerprint / Face ID': {
    'en': 'Fingerprint / Face ID',
    'ps': 'د ګوتې نښه / Face ID',
    'fa': 'اثر انگشت / Face ID',
    'ur': 'فنگر پرنٹ / Face ID',
    'ar': 'البصمة / Face ID',
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
  'Use the Add button to record Money In, Money Out, loans, loan': {
    'en': 'Use the Add button to record Money In, Money Out, loans, loan',
    'ps': 'د Add تڼۍ له لارې داخلې او وتلې پیسې، پورونه او د پور',
    'fa': 'با دکمه افزودن، پول ورودی و خروجی، قرض‌ها و بازپرداخت',
    'ur': 'Add بٹن سے آمد رقم، خرج رقم، قرض اور قرض کی',
    'ar': 'استخدم زر الإضافة لتسجيل الأموال الداخلة والخارجة والقروض',
  },
  'repayments and adjustments. Select the correct currency,': {
    'en': 'repayments and adjustments. Select the correct currency,',
    'ps': 'تادیات او سمونونه ثبت کړئ. سم اسعار وټاکئ،',
    'fa': 'قرض و اصلاحات را ثبت کنید. ارز صحیح را انتخاب کنید،',
    'ur': 'واپسی اور ایڈجسٹمنٹ درج کریں۔ درست کرنسی منتخب کریں،',
    'ar': 'والدفعات والتسويات. اختر العملة الصحيحة،',
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
  'Loan repayments reduce the related balance while keeping': {
    'en': 'Loan repayments reduce the related balance while keeping',
    'ps': 'د پور تادیات اړوند بیلانس کموي، خو',
    'fa': 'بازپرداخت قرض موجودی مربوط را کاهش می‌دهد، در حالی که',
    'ur': 'قرض کی واپسی متعلقہ بیلنس کم کرتی ہے جبکہ',
    'ar': 'تقلل دفعات القرض الرصيد المرتبط مع الاحتفاظ',
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
  'Reports summarize Money In, Money Out, exchanges, loans,': {
    'en': 'Reports summarize Money In, Money Out, exchanges, loans,',
    'ps': 'راپورونه داخلې او وتلې پیسې، تبادلې او پورونه لنډیز کوي،',
    'fa': 'گزارش‌ها پول ورودی، خروجی، تبادلات و قرض‌ها را خلاصه می‌کنند،',
    'ur': 'رپورٹس آمد رقم، خرج رقم، ایکسچینج اور قرض کا خلاصہ دیتے ہیں،',
    'ar': 'تلخص التقارير الأموال الداخلة والخارجة والصرافة والقروض،',
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
  'No outstanding loans or debts.': {
    'en': 'No outstanding loans or debts.',
    'ps': 'پاتې پور یا قرض نشته.',
    'fa': 'قرض یا بدهی باقی نیست.',
    'ur': 'کوئی بقایا قرض یا واجب الادا رقم نہیں۔',
    'ar': 'لا توجد قروض أو ديون مستحقة.',
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
  },  'Unable to load loans': {
    'en': 'Unable to load loans',
    'ps': 'پورونه نه شي پورته کېدای',
    'fa': 'قرض‌ها بارگذاری نمی‌شوند',
    'ur': 'قرض لوڈ نہیں ہوسکے',
    'ar': 'تعذر تحميل القروض',
  },  'Unable to load reports': {
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

class GhataApp extends StatefulWidget {
  GhataApp({super.key});

  @override
  State<GhataApp> createState() => _GhataAppState();
}

class _GhataAppState extends State<GhataApp> {
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

  @override
  void initState() {
    super.initState();

    _loadSavedAppearance();

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
      }
    });
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
        colorSchemeSeed: Colors.blue,
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
          content: Text(ghataT(context, 'Please enter your email and password')),
        ),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (!mounted) return;

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
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Unable to login. Please try again.'))),
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
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.menu_book_rounded,
                    size: 72,
                    color: Colors.blue,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'ګهته',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Ghata – Business Ledger & Accounting',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                  SizedBox(height: 36),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: ghataT(context, 'Gmail / Email'),
                      prefixIcon: Icon(Icons.email_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: passwordController,
                    obscureText: hidePassword,
                    decoration: InputDecoration(
                      labelText: ghataT(context, 'Password'),
                      prefixIcon: Icon(Icons.lock_outline),
                      border: OutlineInputBorder(),
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
                  SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ForgotPasswordScreen(),
                          ),
                        );
                      },
                      child: Text(ghataT(context, 'Forgot Password?')),
                    ),
                  ),
                  SizedBox(height: 8),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: isLoading ? null : login,
                      child: Text(ghataT(context, 'Login')),
                    ),
                  ),
                  SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(ghataT(context, "Don't have an account?")),
                      TextButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SignupScreen(),
                            ),
                          );
                        },
                        child: Text(ghataT(context, 'Create Account')),
                      ),
                    ],
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
        SnackBar(content: Text(ghataT(context, 'Please fill in all fields'))),
      );
      return;
    }

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
      final response = await Supabase.instance.client.auth.signUp(
        email: email,
        password: password,
        data: {
          'full_name': fullName,
        },
      );

      if (!mounted) return;

      if (response.user != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ghataT(context, 'Account created successfully.'),
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
      }
    } on AuthException catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Something went wrong. Please try again.')),
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
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'Create Account')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(
                Icons.person_add_alt_1_rounded,
                size: 70,
                color: Colors.blue,
              ),
              SizedBox(height: 24),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Full Name'),
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 16),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Gmail / Email'),
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 16),
              TextField(
                controller: passwordController,
                obscureText: hidePassword,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Password'),
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
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
              SizedBox(height: 16),
              TextField(
                controller: confirmPasswordController,
                obscureText: hideConfirmPassword,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Confirm Password'),
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                  suffixIcon: IconButton(
                    onPressed: () {
                      setState(() {
                        hideConfirmPassword = !hideConfirmPassword;
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
              SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: isLoading ? null : createAccount,
                  child: isLoading
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : Text(ghataT(context, 'Create Account')),
                ),
              ),
            ],
          ),
        ),
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
  static const _pinKey = 'ghata_app_pin';
  static const _biometricKey = 'ghata_biometric_enabled';

  static Future<bool> hasPin() async {
    final value = await _storage.read(key: _pinKey);
    return value != null && value.length >= 4;
  }

  static Future<void> savePin(String pin) async {
    await _storage.write(key: _pinKey, value: pin);
  }

  static Future<bool> verifyPin(String pin) async {
    final saved = await _storage.read(key: _pinKey);
    return saved != null && saved == pin;
  }

  static Future<void> removePin() async {
    await _storage.delete(key: _pinKey);
    await setBiometricEnabled(false);
  }

  static Future<bool> biometricEnabled() async {
    return (await _storage.read(key: _biometricKey)) == 'true';
  }

  static Future<void> setBiometricEnabled(bool enabled) async {
    await _storage.write(
      key: _biometricKey,
      value: enabled ? 'true' : 'false',
    );
  }

  static Future<bool> canUseBiometrics() async {
    try {
      final auth = LocalAuthentication();
      return await auth.isDeviceSupported() &&
          (await auth.canCheckBiometrics);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> authenticateBiometric() async {
    try {
      final auth = LocalAuthentication();
      return await auth.authenticate(
        localizedReason: 'Unlock Ghata',
        options: AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
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
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      final data = await Supabase.instance.client
          .from('staff_members')
          .select()
          .eq('owner_id', user.id)
          .order('created_at', ascending: false);

      if (!mounted) return;

      setState(() {
        staff = List<Map<String, dynamic>>.from(data);
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${ghataT(context, 'Unable to load staff')}: $e")),
      );
    }
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

  Future<void> createBackup() async {
    if (busy) return;

    setState(() => busy = true);

    try {
      final client = Supabase.instance.client;
      final user = client.auth.currentUser;

      if (user == null) {
        throw Exception('You are not signed in.');
      }

      final customers = await client
          .from('customers')
          .select();

      final transactions = await client
          .from('transactions')
          .select();

      final exchanges = await client
          .from('exchanges')
          .select();

      final exchangeEntries = await client
          .from('exchange_entries')
          .select();

      final profile = await client
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();

      final backup = <String, dynamic>{
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

      final bytes = Uint8List.fromList(
        utf8.encode(
          JsonEncoder.withIndent('  ').convert(backup),
        ),
      );

      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');

      final fileName =
          'Ghata_Backup_'
          '${now.year}${two(now.month)}${two(now.day)}_'
          '${two(now.hour)}${two(now.minute)}.json';

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
            ),
          ],
          fileNameOverrides: [fileName],
        ),
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Backup created successfully.')),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${ghataT(context, 'Unable to create backup')}: $e")),
      );
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  void showRestoreInfo() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ghataT(context, 'Restore Backup')),
        content: Text(
          'Backup export is ready. Safe restore will be enabled '
          'after restore validation is connected, so an invalid or '
          'wrong-account backup cannot overwrite accounting data.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(ghataT(context, 'OK')),
          ),
        ],
      ),
    );
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
                'Export customers, transactions, exchanges and profile.',
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
                'Protected restore with validation.',
              ),
              trailing: Icon(Icons.chevron_right),
              onTap: showRestoreInfo,
            ),
          ),
          SizedBox(height: 16),
          Text(
            ghataT(context, 'Keep backup files in a safe place such as your') +
                ' ' +
                ghataT(context, 'private cloud storage or another trusted device.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
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
  bool hasPin = false;
  bool biometricAvailable = false;
  bool biometricEnabled = false;

  @override
  void initState() {
    super.initState();
    loadSecurityState();
  }

  Future<void> loadSecurityState() async {
    final pin = await GhataSecurity.hasPin();
    final available = await GhataSecurity.canUseBiometrics();
    final enabled = await GhataSecurity.biometricEnabled();

    if (!mounted) return;

    setState(() {
      hasPin = pin;
      biometricAvailable = available;
      biometricEnabled = enabled && pin;
      loading = false;
    });
  }

  Future<String?> requestPin({
    required String title,
    bool confirm = false,
  }) async {
    final firstController = TextEditingController();
    final secondController = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: firstController,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: InputDecoration(
                labelText: ghataT(context, 'PIN (4-6 digits)'),
                border: OutlineInputBorder(),
              ),
            ),
            if (confirm) ...[
              SizedBox(height: 12),
              TextField(
                controller: secondController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Confirm PIN'),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(ghataT(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              final first = firstController.text.trim();
              final valid =
                  RegExp(r'^\d{4,6}$').hasMatch(first);

              if (!valid) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ghataT(context, 'PIN must be 4 to 6 digits.')),
                  ),
                );
                return;
              }

              if (confirm && first != secondController.text.trim()) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ghataT(context, 'PINs do not match.')),
                  ),
                );
                return;
              }

              Navigator.pop(dialogContext, first);
            },
            child: Text(ghataT(context, 'Save')),
          ),
        ],
      ),
    );

    firstController.dispose();
    secondController.dispose();
    return result;
  }

  Future<void> createOrChangePin() async {
    if (hasPin) {
      final current = await requestPin(title: ghataT(context, 'Enter Current PIN'));
      if (current == null) return;

      if (!await GhataSecurity.verifyPin(current)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ghataT(context, 'Incorrect PIN.'))),
        );
        return;
      }
    }

    if (!mounted) return;

    final pin = await requestPin(
      title: hasPin ? ghataT(context, 'Change App PIN') : ghataT(context, 'Create App PIN'),
      confirm: true,
    );

    if (pin == null) return;

    await GhataSecurity.savePin(pin);
    await loadSecurityState();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          hasPin ? ghataT(context, 'App PIN saved.') : ghataT(context, 'App PIN created.'),
        ),
      ),
    );
  }

  Future<void> removePin() async {
    final current = await requestPin(title: ghataT(context, 'Enter Current PIN'));
    if (current == null) return;

    if (!await GhataSecurity.verifyPin(current)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Incorrect PIN.'))),
      );
      return;
    }

    await GhataSecurity.removePin();
    await loadSecurityState();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ghataT(context, 'App PIN removed.'))),
    );
  }

  Future<void> changeBiometric(bool enabled) async {
    if (enabled) {
      if (!hasPin) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ghataT(context, 'Create an App PIN first.')),
          ),
        );
        return;
      }

      if (!biometricAvailable) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ghataT(context, 'Fingerprint or Face ID is not available on this device.'),
            ),
          ),
        );
        return;
      }

      final authenticated =
          await GhataSecurity.authenticateBiometric();

      if (!authenticated) return;
    }

    await GhataSecurity.setBiometricEnabled(enabled);
    await loadSecurityState();
  }

  Future<void> testLock() async {
    if (!hasPin) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Create an App PIN first.'))),
      );
      return;
    }

    if (biometricEnabled) {
      final success = await GhataSecurity.authenticateBiometric();
      if (success) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ghataT(context, 'Ghata unlocked successfully.'))),
        );
        return;
      }
    }

    if (!mounted) return;

    final pin = await requestPin(title: ghataT(context, 'Unlock Ghata'));
    if (pin == null) return;

    final valid = await GhataSecurity.verifyPin(pin);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          valid ? ghataT(context, 'Ghata unlocked successfully.') : ghataT(context, 'Incorrect PIN.'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'Security')),
      ),
      body: loading
          ? Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.all(16),
              children: [
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: Icon(Icons.pin_outlined),
                        title: Text(
                          hasPin ? ghataT(context, 'Change App PIN') : ghataT(context, 'Create App PIN'),
                        ),
                        subtitle: Text(
                          'Use a 4 to 6 digit PIN to protect Ghata.',
                        ),
                        trailing: Icon(Icons.chevron_right),
                        onTap: createOrChangePin,
                      ),
                      if (hasPin)
                        ListTile(
                          leading: Icon(Icons.lock_open_outlined),
                          title: Text(ghataT(context, 'Remove App PIN')),
                          onTap: removePin,
                        ),
                    ],
                  ),
                ),
                SizedBox(height: 12),
                Card(
                  child: SwitchListTile(
                    secondary: Icon(Icons.fingerprint),
                    title: Text(ghataT(context, 'Fingerprint / Face ID')),
                    subtitle: Text(
                      biometricAvailable
                          ? 'Use device biometrics to unlock Ghata.'
                          : ghataT(context, 'Biometrics are not available on this device.'),
                    ),
                    value: biometricEnabled,
                    onChanged:
                        biometricAvailable ? changeBiometric : null,
                  ),
                ),
                SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: testLock,
                  icon: Icon(Icons.lock_outline),
                  label: Text(ghataT(context, 'Test App Lock')),
                ),
                SizedBox(height: 12),
                Text(
                  '',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
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
  final pinController = TextEditingController();

  bool loading = true;
  bool unlocked = false;
  bool biometricEnabled = false;
  bool checkingBiometric = false;
  String? errorText;

  @override
  void initState() {
    super.initState();
    prepareLock();
  }

  Future<void> prepareLock() async {
    try {
      await Supabase.instance.client.rpc('link_my_staff_account');
    } catch (_) {
      // Owner accounts or accounts without a staff invitation continue normally.
    }

    final hasPin = await GhataSecurity.hasPin();

    if (!hasPin) {
      if (!mounted) return;
      setState(() {
        unlocked = true;
        loading = false;
      });
      return;
    }

    final biometric = await GhataSecurity.biometricEnabled();

    if (!mounted) return;

    setState(() {
      biometricEnabled = biometric;
      loading = false;
    });

    if (biometric) {
      await unlockWithBiometric();
    }
  }

  Future<void> unlockWithBiometric() async {
    if (checkingBiometric) return;

    setState(() {
      checkingBiometric = true;
      errorText = null;
    });

    final success = await GhataSecurity.authenticateBiometric();

    if (!mounted) return;

    setState(() {
      checkingBiometric = false;

      if (success) {
        unlocked = true;
      }
    });
  }

  Future<void> unlockWithPin() async {
    final pin = pinController.text.trim();

    if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) {
      setState(() {
        errorText = 'Enter your 4 to 6 digit PIN.';
      });
      return;
    }

    final valid = await GhataSecurity.verifyPin(pin);

    if (!mounted) return;

    if (valid) {
      pinController.clear();

      setState(() {
        unlocked = true;
        errorText = null;
      });
    } else {
      setState(() {
        errorText = ghataT(context, 'Incorrect PIN.');
      });
    }
  }

  Future<void> signOut() async {
    await Supabase.instance.client.auth.signOut();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => LoginScreen(),
      ),
      (_) => false,
    );
  }

  @override
  void dispose() {
    pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (unlocked) {
      return HomeScreen();
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 72,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'ګهته – Ghata',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Unlock Ghata',
                    style: TextStyle(fontSize: 18),
                  ),
                  SizedBox(height: 28),
                  TextField(
                    controller: pinController,
                    autofocus: !biometricEnabled,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => unlockWithPin(),
                    decoration: InputDecoration(
                      labelText: ghataT(context, 'App PIN'),
                      border: OutlineInputBorder(),
                      errorText: errorText,
                    ),
                  ),
                  SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: unlockWithPin,
                      icon: Icon(Icons.lock_open_outlined),
                      label: Text(ghataT(context, 'Unlock')),
                    ),
                  ),
                  if (biometricEnabled) ...[
                    SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: checkingBiometric
                            ? null
                            : unlockWithBiometric,
                        icon: checkingBiometric
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(Icons.fingerprint),
                        label: Text(
                          'Fingerprint / Face ID',
                        ),
                      ),
                    ),
                  ],
                  SizedBox(height: 18),
                  TextButton(
                    onPressed: signOut,
                    child: Text(ghataT(context, 'Sign Out')),
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


class HomeScreen extends StatefulWidget {
  HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<bool> canEditFuture;
  late Future<bool> canViewReportsFuture;

  Future<bool> loadCanEdit() async {
    try {
      final value =
          await Supabase.instance.client.rpc('can_staff_edit');
      return value == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> loadCanViewReports() async {
    try {
      final value =
          await Supabase.instance.client.rpc('can_staff_view_reports');
      return value == true;
    } catch (_) {
      return false;
    }
  }

  void refreshPermissions() {
    canEditFuture = loadCanEdit();
    canViewReportsFuture = loadCanViewReports();
  }

  late Future<Map<String, Map<String, double>>> dashboardFuture;

  @override
  void initState() {
    super.initState();
    refreshPermissions();
    dashboardFuture = loadDashboardSummary();
  }

  Future<Map<String, Map<String, double>>> loadDashboardSummary() async {
    await ghataRefreshOfflineCache();

    final transactions =
        await OfflineDatabase.instance.getRecords('transactions');

    final exchangeEntries =
        await ghataLocalExchangeEntriesWithExchange();

    final result = <String, Map<String, double>>{};

    Map<String, double> values(String currency) {
      return result.putIfAbsent(
        currency,
        () => {
          'today_in': 0,
          'today_out': 0,
          'receive': 0,
          'pay': 0,
          'cashbox': 0,
        },
      );
    }

    final receivableByCustomer = <String, double>{};
    final payableByCustomer = <String, double>{};

    for (final raw in transactions) {
      final row = Map<String, dynamic>.from(raw);
      final currency = (row['currency'] ?? '').toString();
      if (currency.isEmpty) continue;

      final amount =
          double.tryParse((row['amount'] ?? 0).toString()) ?? 0;
      if (amount <= 0) continue;

      final type = (row['transaction_type'] ?? '').toString();
      final date = (row['transaction_date'] ?? '').toString();
      final customerId = (row['customer_id'] ?? '').toString();
      final data = values(currency);

      if (customerId.isEmpty) {
        if (type == 'money_in') {
          data['today_in'] = data['today_in']! + amount;
        } else if (type == 'money_out') {
          data['today_out'] = data['today_out']! + amount;
        }
      }

      final loanKey = '$customerId|$currency';

      switch (type) {
        case 'loan_given':
          if (customerId.isNotEmpty) {
            receivableByCustomer[loanKey] =
                (receivableByCustomer[loanKey] ?? 0) + amount;
          }
          data['cashbox'] = data['cashbox']! - amount;
          break;

        case 'loan_repayment_received':
          if (customerId.isNotEmpty) {
            final current = receivableByCustomer[loanKey] ?? 0;
            receivableByCustomer[loanKey] =
                (current - amount).clamp(0, double.infinity).toDouble();
          }
          data['cashbox'] = data['cashbox']! + amount;
          break;

        case 'loan_received':
          if (customerId.isNotEmpty) {
            payableByCustomer[loanKey] =
                (payableByCustomer[loanKey] ?? 0) + amount;
          }
          data['cashbox'] = data['cashbox']! + amount;
          break;

        case 'loan_repayment_paid':
          if (customerId.isNotEmpty) {
            final current = payableByCustomer[loanKey] ?? 0;
            payableByCustomer[loanKey] =
                (current - amount).clamp(0, double.infinity).toDouble();
          }
          data['cashbox'] = data['cashbox']! - amount;
          break;

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

    for (final entry in receivableByCustomer.entries) {
      final currency = entry.key.split('|').last;
      values(currency)['receive'] =
          values(currency)['receive']! + entry.value;
    }

    for (final entry in payableByCustomer.entries) {
      final currency = entry.key.split('|').last;
      values(currency)['pay'] =
          values(currency)['pay']! + entry.value;
    }

    for (final raw in exchangeEntries) {
      final row = Map<String, dynamic>.from(raw);
      final exchange = row['exchanges'];

      if (exchange == null ||
          (exchange is Map && exchange['deleted_at'] != null)) {
        continue;
      }

      final currency = (row['currency'] ?? '').toString();
      if (currency.isEmpty) continue;

      final amount =
          double.tryParse((row['amount'] ?? 0).toString()) ?? 0;
      final type = (row['entry_type'] ?? '').toString();
      final data = values(currency);

      if (type == 'money_in') {
        data['cashbox'] = data['cashbox']! + amount;
      } else if (type == 'money_out') {
        data['cashbox'] = data['cashbox']! - amount;
      }
    }

    for (final data in result.values) {
      if ((data['receive'] ?? 0) < 0) data['receive'] = 0;
      if ((data['pay'] ?? 0) < 0) data['pay'] = 0;
    }

    return result;
  }


  Future<List<Map<String, dynamic>>> loadRecentTransactions() async {
  await ghataRefreshOfflineCache();

  final local =
      await OfflineDatabase.instance.getRecords('transactions');

  local.sort((a, b) {
    final ad =
        '${a['transaction_date'] ?? ''} ${a['transaction_time'] ?? ''} ${a['created_at'] ?? ''}';
    final bd =
        '${b['transaction_date'] ?? ''} ${b['transaction_time'] ?? ''} ${b['created_at'] ?? ''}';

    return bd.compareTo(ad);
  });

  return local.take(5).toList();
}

  String homeTransactionLabel(String type) {
    switch (type) {
      case 'money_in':
        return ghataT(context, 'Money In');
      case 'money_out':
        return ghataT(context, 'Money Out');
      case 'loan_given':
        return ghataT(context, 'Loan Given');
      case 'loan_received':
        return ghataT(context, 'Loan Received');
      case 'loan_repayment_received':
        return ghataT(context, 'Repayment Received');
      case 'loan_repayment_paid':
        return ghataT(context, 'Repayment Paid');
      case 'adjustment_in':
        return ghataT(context, 'Adjustment In');
      case 'adjustment_out':
        return ghataT(context, 'Adjustment Out');
      default:
        return type;
    }
  }

  Future<void> showHomeMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'Settings & Account',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.person_outline),
              title: Text(ghataT(context, 'Profile & Business')),
              onTap: () => Navigator.pop(context, 'profile'),
            ),
            ListTile(
              leading: Icon(Icons.security_outlined),
              title: Text(ghataT(context, 'Security')),
              onTap: () => Navigator.pop(context, 'security'),
            ),
            ListTile(
              leading: Icon(Icons.groups_outlined),
              title: Text(ghataT(context, 'Staff & Roles')),
              onTap: () => Navigator.pop(context, 'staff'),
            ),
            ListTile(
              leading: Icon(Icons.cloud_outlined),
              title: Text(ghataT(context, 'Backup & Restore')),
              onTap: () => Navigator.pop(context, 'backup'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text(ghataT(context, 'Recycle Bin')),
              onTap: () => Navigator.pop(context, 'recycle'),
            ),
            ListTile(
              leading: Icon(Icons.info_outline_rounded),
              title: Text(ghataT(context, 'About Ghata')),
              onTap: () => Navigator.pop(context, 'about'),
            ),
            Divider(),
            ListTile(
              leading: Icon(Icons.logout),
              title: Text(ghataT(context, 'Sign Out')),
              onTap: () => Navigator.pop(context, 'logout'),
            ),
            SizedBox(height: 8),
          ],
        ),
      ),
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

  Widget summarySection(
    Map<String, Map<String, double>> data,
    String key,
    String title,
    IconData icon,
  ) {
    final rows = data.entries
        .where((e) => (e.value[key] ?? 0).abs() > 0.000001)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (rows.length > 2)
                Icon(
                  Icons.swipe_rounded,
                  size: 20,
                  color: Colors.grey,
                ),
            ],
          ),
          SizedBox(height: 12),
          if (rows.isEmpty)
            Text(
              'No balance',
              style: TextStyle(color: Colors.grey),
            )
          else
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: BouncingScrollPhysics(),
                itemCount: rows.length,
                separatorBuilder: (_, __) =>
                    SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final e = rows[index];

                  return Container(
                    constraints: BoxConstraints(
                      minWidth: 140,
                      maxWidth: 185,
                    ),
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.key,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          amountText(e.value[key] ?? 0),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  void refreshDashboard() {
    setState(() {
      dashboardFuture = loadDashboardSummary();
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
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ghata',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              ghataT(context, 'Business Ledger & Accounting'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: ghataT(context, 'Settings & Account'),
            onPressed: showHomeMenu,
            icon: Icon(Icons.menu_rounded),
          ),
          SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            refreshDashboard();
            await dashboardFuture;
          },
          child: ListView(
            padding: EdgeInsets.all(16),
            children: [
              // GHATA_LANGUAGE_THEME_CONTROLS
              Builder(
                builder: (context) {
                  final appState =
                      context.findAncestorStateOfType<_GhataAppState>();
                  final languageCode =
                      Localizations.localeOf(context).languageCode;
                  final isDark =
                      Theme.of(context).brightness == Brightness.dark;

                  return Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        PopupMenuButton<String>(
                          tooltip: ghataT(context, 'language'),
                          onSelected: (value) {
                            appState?.changeLanguage(value);
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'en',
                              child: Text('🇬🇧 English'),
                            ),
                            PopupMenuItem(
                              value: 'ps',
                              child: Text('🇦🇫 پښتو'),
                            ),
                            PopupMenuItem(
                              value: 'fa',
                              child: Text('🇦🇫 دری'),
                            ),
                            PopupMenuItem(
                              value: 'ur',
                              child: Text('🇵🇰 اردو'),
                            ),
                            PopupMenuItem(
                              value: 'ar',
                              child: Text('🇸🇦 العربية'),
                            ),
                          ],
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.language_rounded,
                                  size: 20,
                                ),
                                SizedBox(width: 7),
                                Text(
                                  ghataLanguageName(languageCode),
                                ),
                                SizedBox(width: 3),
                                Icon(
                                  Icons.arrow_drop_down,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(width: 8),
                        Tooltip(
                          message: isDark
                              ? ghataT(context, 'lightMode')
                              : ghataT(context, 'darkMode'),
                          child: IconButton.filledTonal(
                            onPressed: appState?.toggleTheme,
                            icon: Icon(
                              isDark
                                  ? Icons.light_mode_rounded
                                  : Icons.dark_mode_rounded,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),

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
                      summarySection(
                        data,
                        'today_in',
                        ghataT(context, 'Money In'),
                        Icons.south_west_rounded,
                      ),
                      summarySection(
                        data,
                        'today_out',
                        ghataT(context, 'Money Out'),
                        Icons.north_east_rounded,
                      ),
                      summarySection(
                        data,
                        'receive',
                        ghataT(context, 'You Receive'),
                        Icons.call_received_rounded,
                      ),
                      summarySection(
                        data,
                        'pay',
                        ghataT(context, 'You Pay'),
                        Icons.call_made_rounded,
                      ),
                    ],
                  );
                },
              ),

              SizedBox(height: 4),

              editPermissionButton(
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.symmetric(
                        vertical: 16,
                      ),
                    ),
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ExchangeScreen(),
                        ),
                      );
                      refreshDashboard();
                    },
                    icon: Icon(
                      Icons.currency_exchange_rounded,
                    ),
                    label: Text(ghataT(context, 'Exchange')),
                  ),
                ),
              ),


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
                future: loadRecentTransactions(),
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
                    return Card(
                      child: Padding(
                        padding: EdgeInsets.all(18),
                        child: Center(
                          child: Text(
                            ghataT(context, 'No transactions yet'),
                            style: TextStyle(
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  return Column(
                    children: rows.map((row) {
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
                          type ==
                              'loan_repayment_received' ||
                          type == 'loan_received' ||
                          type == 'adjustment_in';

                      return Card(
                        margin:
                            EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Icon(
                              incoming
                                  ? Icons
                                      .south_west_rounded
                                  : Icons
                                      .north_east_rounded,
                            ),
                          ),
                          title: Text(
                            '$amount $currency',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            [
                              homeTransactionLabel(type),
                              if (customer.isNotEmpty)
                                customer,
                              if (date.isNotEmpty) date,
                            ].join(' • '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Icon(
                            Icons.chevron_right,
                          ),
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
                      );
                    }).toList(),
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
                      label: 'Add',
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
    );
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
    try {
      final results = await Future.wait([
        Supabase.instance.client.rpc('can_staff_edit'),
        Supabase.instance.client.rpc('can_staff_view_reports'),
      ]);

      return [
        results[0] == true,
        results[1] == true,
      ];
    } catch (_) {
      return [false, false];
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

          return Row(
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
                  label: 'Add',
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
                  icon: Icons.bar_chart_rounded,
                  label: ghataT(context, 'Reports'),
                  selected: widget.selectedIndex == 4,
                  onTap: !canReports
                      ? null
                      : widget.selectedIndex == 4
                          ? () {}
                          : () => replaceWith(
                                ReportsScreen(),
                              ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}


class AboutGhataScreen extends StatelessWidget {
  AboutGhataScreen({super.key});

  Widget guideSection(
    BuildContext context,
    IconData icon,
    String title,
    String text,
  ) {
    return Card(
      margin: EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              child: Icon(icon),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    text,
                    style: TextStyle(
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ghataT(context, 'About Ghata')),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(16),
          children: [
            SizedBox(height: 8),

            Center(
              child: CircleAvatar(
                radius: 42,
                child: Icon(
                  Icons.account_balance_wallet_rounded,
                  size: 42,
                ),
              ),
            ),

            SizedBox(height: 14),

            Center(
              child: Text(
                'ګهته – Ghata',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            SizedBox(height: 4),

            Center(
              child: Text(
                ghataT(context, 'Business Ledger & Accounting'),
                textAlign: TextAlign.center,
              ),
            ),

            SizedBox(height: 24),

            Text(
              ghataT(context, 'Complete Guide'),
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.bold,
              ),
            ),

            SizedBox(height: 12),

            guideSection(
              context,
              Icons.home_outlined,
              ghataT(context, 'Dashboard'),
              ghataT(context, 'The Dashboard gives you a quick overview of your business. Cashbox, Money In, Money Out, You Receive and You Pay are shown separately for each currency. Ghata does not combine different currencies into a converted grand total.'),
            ),

            guideSection(
              context,
              Icons.people_outline,
              ghataT(context, 'Customers'),
              ghataT(context, 'Use Customers to create and manage customer accounts. Open a customer profile to see their transaction history and separate balances for every currency. You can also edit customer information and create customer transactions.'),
            ),

            guideSection(
              context,
              Icons.add_circle_outline,
              ghataT(context, 'Add Transaction'),
              ghataT(context, 'Use the Add button to record Money In, Money Out, loans, loan repayments and adjustments. Select the correct currency, date, time and customer when required. You can also add a description and reference number.'),
            ),

            guideSection(
              context,
              Icons.menu_book_outlined,
              ghataT(context, 'Daily Journal'),
              ghataT(context, 'The Daily Journal keeps your transaction history. Use search and filters to find transactions. Transactions can be reviewed with their amount, currency, customer, date, time and description.'),
            ),

            guideSection(
              context,
              Icons.handshake_outlined,
              ghataT(context, 'Loans & Debts'),
              ghataT(context, 'Ghata tracks money customers owe you and money you owe them. Loan repayments reduce the related balance while keeping the accounting history available.'),
            ),

            guideSection(
              context,
              Icons.currency_exchange,
              ghataT(context, 'Currency Exchange'),
              ghataT(context, 'Use Exchange for currency buy and sell operations. Select the From and To currencies, enter the amounts and exchange rate, and optionally select a customer. Each currency remains independently recorded.'),
            ),

            guideSection(
              context,
              Icons.account_balance_wallet_outlined,
              ghataT(context, 'Cashbox'),
              ghataT(context, 'Cashbox represents the recorded cash movement of the business. Balances are maintained separately by currency and include supported transaction and exchange movements.'),
            ),

            guideSection(
              context,
              Icons.bar_chart_outlined,
              ghataT(context, 'Reports'),
              ghataT(context, 'Reports summarize Money In, Money Out, exchanges, loans, repayments and adjustments. Reports can be filtered by date, currency and customer. Currency totals are never automatically converted into another currency.'),
            ),

            guideSection(
              context,
              Icons.receipt_long_outlined,
              ghataT(context, 'Receipts, PDF & Balance Image'),
              ghataT(context, 'Ghata can prepare transaction receipts, customer statements and customer balance images for sharing. Always review the information before sending a document to another person.'),
            ),

            guideSection(
              context,
              Icons.groups_outlined,
              ghataT(context, 'Staff & Roles'),
              ghataT(context, 'A business owner can manage staff access. Staff permissions control whether a staff member can add or edit records and whether reports are available to them.'),
            ),

            guideSection(
              context,
              Icons.security_outlined,
              ghataT(context, 'Security'),
              ghataT(context, 'Use Security to protect access to Ghata with the available PIN and biometric options. Keep your account password and security information private.'),
            ),

            guideSection(
              context,
              Icons.cloud_outlined,
              ghataT(context, 'Backup & Restore'),
              ghataT(context, 'Your Supabase account is the main cloud data source. Backup features can also be used to export supported business information. Keep exported backup files in a safe place.'),
            ),

            guideSection(
              context,
              Icons.delete_outline,
              ghataT(context, 'Recycle Bin'),
              ghataT(context, 'Deleted accounting records are moved to the Recycle Bin. Eligible records can be restored during the retention period. Ghata protects accounting history instead of silently destroying important financial records.'),
            ),

            guideSection(
              context,
              Icons.info_outline,
              ghataT(context, 'Important'),
              ghataT(context, 'Enter financial information carefully and review balances and reports regularly. Ghata is a record-keeping tool; the accuracy of reports depends on the information entered.'),
            ),

            SizedBox(height: 14),

            Card(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ghataT(context, 'Contact Owner'),
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 16),

                    SelectableText(
                      'Email\nmrahemsadaf@gmail.com',
                    ),

                    SizedBox(height: 16),

                    SelectableText(
                      'WhatsApp 1\n+93 771 770 927',
                    ),

                    SizedBox(height: 16),

                    SelectableText(
                      'WhatsApp 2\n+93 774 832 595',
                    ),
                  ],
                ),
              ),
            ),

            SizedBox(height: 24),

            Center(
              child: Text(
                'Design by MRS',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),

            SizedBox(height: 3),

            Center(
              child: Text(
                'Mohammad Rahem Sadaf',
                style: TextStyle(
                  fontSize: 15,
                ),
              ),
            ),

            SizedBox(height: 30),
          ],
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
  String email = '';

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

      final data = await Supabase.instance.client
          .from('profiles')
          .select(
          'full_name, username, business_name, business_phone, business_address, receipt_note',
        )
          .eq('id', user.id)
          .single();

      if (!mounted) return;

      fullNameController.text = data['full_name'] ?? '';
      usernameController.text = data['username'] ?? '';
      businessNameController.text = data['business_name'] ?? '';
      businessPhoneController.text = data['business_phone'] ?? '';
      businessAddressController.text = data['business_address'] ?? '';
      receiptNoteController.text = data['receipt_note'] ?? '';

      setState(() {
        email = user.email ?? '';
        isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() => isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Unable to load profile'))),
      );
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

      await Supabase.instance.client
          .from('profiles')
          .update({
            'business_name': businessNameController.text.trim(),
            'business_phone': businessPhoneController.text.trim(),
            'business_address': businessAddressController.text.trim(),
            'receipt_note': receiptNoteController.text.trim(),
          })
          .eq('id', user.id);

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
                    child: CircleAvatar(
                      radius: 45,
                      child: Icon(Icons.person, size: 48),
                    ),
                  ),
                  SizedBox(height: 30),
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
                        icon: Icon(Icons.delete_outline),
                        label: Text(ghataT(context, 'Recycle Bin')),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => RecycleBinScreen(),
                            ),
                          );
                        },
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
  Future<List<Map<String, dynamic>>> loadDeletedCustomers() async {
  await ghataRefreshOfflineCache();

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

  Future<List<Map<String, dynamic>>> loadDeletedTransactions() async {
  await ghataRefreshOfflineCache();

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

    ghataTrySync();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ghataT(context, 'Transaction restored successfully.')),
      ),
    );

    setState(() {});
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("${ghataT(context, 'Unable to restore transaction')}: $e"),
      ),
    );
  }
}

  Future<List<Map<String, dynamic>>> loadDeletedExchanges() async {
  await ghataRefreshOfflineCache();

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

    ghataTrySync();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ghataT(context, 'Exchange restored successfully.')),
      ),
    );

    setState(() {});
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("${ghataT(context, 'Unable to restore exchange')}: $e"),
      ),
    );
  }
}

  Future<void> permanentlyDeleteExchange(
    String id,
    String label,
    String? deletedAt,
  ) async {
    if (daysRemaining(deletedAt) > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Permanent delete is available after 30 days.')),
        ),
      );
      return;
    }

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
      await OfflineDatabase.instance.updateLocalRecord(
        'exchanges',
        id,
        {
          'purged_at':
              DateTime.now().toUtc().toIso8601String(),
        },
      );

      ghataTrySync();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Exchange removed from Recycle Bin.'))),
      );

      setState(() {});
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

    ghataTrySync();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ghataT(context, 'Customer restored successfully.')),
      ),
    );

    setState(() {});
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
    if (daysRemaining(deletedAt) > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Permanent delete is available after 30 days.')),
        ),
      );
      return;
    }

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
      await OfflineDatabase.instance
          .permanentlyDeleteLocalRecord(
        'customers',
        id,
      );

      ghataTrySync();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ghataT(context, 'Customer removed from Recycle Bin.'))),
      );

      setState(() {});
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
    if (daysRemaining(deletedAt) > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Permanent delete is available after 30 days.')),
        ),
      );
      return;
    }

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
      await OfflineDatabase.instance.updateLocalRecord(
        'transactions',
        id,
        {
          'purged_at':
              DateTime.now().toUtc().toIso8601String(),
        },
      );

      ghataTrySync();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Transaction removed from Recycle Bin.')),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to permanently delete transaction')}: $e"),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
      return Scaffold(
        appBar: AppBar(
          title: Text(ghataT(context, 'Recycle Bin')),
        ),
        body: FutureBuilder<List<dynamic>>(
          future: Future.wait([
            loadDeletedCustomers(),
            loadDeletedTransactions(),
            loadDeletedExchanges(),
          ]),
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
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Icon(Icons.person_outline),
                        ),
                        title: Text(name),
                        subtitle: Text(
                          address.isEmpty
                              ? '$remaining days remaining'
                              : '$address\n$remaining days remaining',
                        ),
                        isThreeLine: address.isNotEmpty,
                        trailing: remaining > 0
                            ? TextButton(
                                onPressed: id.isEmpty
                                    ? null
                                    : () => restoreCustomer(id),
                                child: Text(ghataT(context, 'Restore')),
                              )
                            : TextButton(
                                onPressed: id.isEmpty
                                    ? null
                                    : () => permanentlyDeleteCustomer(
                                          id,
                                          name,
                                          customer['deleted_at']?.toString(),
                                        ),
                                child: Text(ghataT(context, 'Delete Permanently')),
                              ),
                      ),
                    );
                  }),
                ],

                if (customers.isNotEmpty && transactions.isNotEmpty)
                  SizedBox(height: 24),

                if (transactions.isNotEmpty) ...[
                  Text(
                    'Transactions',
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
                      'loan_given' => 'Loan Given',
                      'loan_received' => 'Loan Received',
                      'loan_repayment_received' => 'Repayment Received',
                      'loan_repayment_paid' => 'Repayment Paid',
                      'adjustment_in' => 'Adjustment In',
                      'adjustment_out' => 'Adjustment Out',
                      _ => type,
                    };

                    final label = '$typeLabel $amount $currency';

                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Icon(Icons.receipt_long_outlined),
                        ),
                        title: Text('$amount $currency'),
                        subtitle: Text(
                          [
                            typeLabel,
                            if (customer.isNotEmpty) customer,
                            '$remaining days remaining',
                          ].join(' • '),
                        ),
                        trailing: remaining > 0
                            ? TextButton(
                                onPressed: id.isEmpty
                                    ? null
                                    : () => restoreTransaction(id),
                                child: Text(ghataT(context, 'Restore')),
                              )
                            : TextButton(
                                onPressed: id.isEmpty
                                    ? null
                                    : () => permanentlyDeleteTransaction(
                                          id,
                                          label,
                                          transaction['deleted_at']?.toString(),
                                        ),
                                child: Text(ghataT(context, 'Delete Permanently')),
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
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Icon(Icons.currency_exchange),
                        ),
                        title: Text(typeLabel),
                        subtitle: Text(
                          [
                            if (customer.isNotEmpty) customer,
                            if (date.isNotEmpty) date,
                            '$remaining days remaining',
                          ].join(' • '),
                        ),
                        trailing: remaining > 0
                            ? TextButton(
                                onPressed: id.isEmpty
                                    ? null
                                    : () => restoreExchange(id),
                                child: Text(ghataT(context, 'Restore')),
                              )
                            : TextButton(
                                onPressed: id.isEmpty
                                    ? null
                                    : () => permanentlyDeleteExchange(
                                          id,
                                          label,
                                          exchange['deleted_at']?.toString(),
                                        ),
                                child: Text(ghataT(context, 'Delete Permanently')),
                              ),
                      ),
                    );
                  }),
                ],
              ],
            );
          },
        ),
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
      ('en', 'English', '🇬🇧'),
      ('ps', 'پښتو', '🇦🇫'),
      ('fa', 'دری', '🇦🇫'),
      ('ur', 'اردو', '🇵🇰'),
      ('ar', 'العربية', '🇸🇦'),
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
            leading: Text(
              language.$3,
              style: TextStyle(fontSize: 30),
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
  String selectedFilter = 'all';

  final amountController = TextEditingController();
  final descriptionController = TextEditingController();
  final referenceController = TextEditingController();
  final journalSearchController = TextEditingController();

  String transactionType = 'money_in';
  String currency = 'AFN';
  DateTime selectedDate = DateTime.now();
  DateTime? selectedDueDate;
  TimeOfDay selectedTime = TimeOfDay.now();
  bool isSaving = false;
  double? calculatorResult;

  String? selectedCustomerId;
  String? selectedCustomerName;

  @override
  void initState() {
    super.initState();

    selectedCustomerId = widget.initialCustomerId;
    selectedCustomerName = widget.initialCustomerName;

    if (widget.initialTransactionType != null) {
      transactionType = widget.initialTransactionType!;
    }

    if (widget.openAddForm) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showAddTransactionDialog();
      });
    }
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
    try {
      final user = Supabase.instance.client.auth.currentUser;

      if (user != null) {
        final data = await Supabase.instance.client
            .from('customers')
            .select('id, full_name, phone')
            .isFilter('deleted_at', null)
            .order('full_name');

        final records = List<Map<String, dynamic>>.from(data);
        await OfflineDatabase.instance.cacheServerRecords(
          'customers',
          records,
        );
        return records;
      }
    } catch (_) {
      // Offline: use local database.
    }

    final local = await OfflineDatabase.instance.getRecords('customers');
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
    ('loan_given', 'Loan Given'),
    ('loan_received', 'Loan Received'),
    ('loan_repayment_received', 'Loan Repayment Received'),
    ('loan_repayment_paid', 'Loan Repayment Paid'),
    ('adjustment_in', 'Adjustment In'),
    ('adjustment_out', 'Adjustment Out'),
  ];

  Future<List<Map<String, dynamic>>> loadTransactions() async {
    final local =
        await OfflineDatabase.instance.getRecords('transactions');

    local.sort((a, b) {
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

    ghataRefreshOfflineCache();

    return local.take(100).toList();
  }

  Future<void> saveTransaction() async {
    const customerRequiredTypes = {
      'loan_given',
      'loan_received',
      'loan_repayment_received',
      'loan_repayment_paid',
    };

    if (customerRequiredTypes.contains(transactionType) &&
        selectedCustomerId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ghataT(context, 'Please select a customer for loan transactions.')),
        ),
      );
      return;
    }

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

    if (transactionType == 'loan_repayment_received' ||
        transactionType == 'loan_repayment_paid') {
      final allLoanData =
          await OfflineDatabase.instance.getRecords('transactions');

      final loanData = allLoanData.where((item) {
        final itemCustomerId =
            item['customer_id']?.toString() ?? '';
        final itemCurrency =
            item['currency']?.toString() ?? '';
        final itemType =
            item['transaction_type']?.toString() ?? '';

        return itemCustomerId == selectedCustomerId &&
            itemCurrency == currency &&
            {
              'loan_given',
              'loan_received',
              'loan_repayment_received',
              'loan_repayment_paid',
            }.contains(itemType);
      }).toList();

      double receivableBalance = 0;
      double payableBalance = 0;

      for (final item in List<Map<String, dynamic>>.from(loanData)) {
        final type = item['transaction_type']?.toString() ?? '';
        final value =
            double.tryParse(item['amount']?.toString() ?? '0') ?? 0;

        if (type == 'loan_given') receivableBalance += value;
        if (type == 'loan_repayment_received') receivableBalance -= value;
        if (type == 'loan_received') payableBalance += value;
        if (type == 'loan_repayment_paid') payableBalance -= value;
      }

      if (transactionType == 'loan_repayment_received') {
        if (receivableBalance <= 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'This customer has no loan to repay in this currency.',
              ),
            ),
          );
          return;
        }

        if (amount > receivableBalance) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Repayment cannot exceed ${receivableBalance.toStringAsFixed(2)} $currency.',
              ),
            ),
          );
          return;
        }
      }

      if (transactionType == 'loan_repayment_paid') {
        if (payableBalance <= 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'You do not owe this customer in this currency.',
              ),
            ),
          );
          return;
        }

        if (amount > payableBalance) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Repayment cannot exceed ${payableBalance.toStringAsFixed(2)} $currency.',
              ),
            ),
          );
          return;
        }
      }
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
          'due_date': (transactionType == 'loan_given' ||
                      transactionType == 'loan_received') &&
                  selectedDueDate != null
              ? '${selectedDueDate!.year}-${selectedDueDate!.month.toString().padLeft(2, '0')}-${selectedDueDate!.day.toString().padLeft(2, '0')}'
              : null,
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
      selectedDueDate = null;
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
          final needsDueDate =
              transactionType == 'loan_given' ||
              transactionType == 'loan_received';

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
                          if (!needsDueDate) {
                            selectedDueDate = null;
                          }
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
                              child:
                                  Text('${item.$2} ${item.$1}'),
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
                        const DropdownMenuItem<String?>(
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

                    if (needsDueDate)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.event_available_outlined,
                        ),
                        title: Text(ghataT(context, 'Due Date')),
                        subtitle: Text(
                          selectedDueDate == null
                              ? 'Not set'
                              : '${selectedDueDate!.year}-${selectedDueDate!.month.toString().padLeft(2, '0')}-${selectedDueDate!.day.toString().padLeft(2, '0')}',
                        ),
                        onTap: () async {
                          await chooseDueDate();
                          if (mounted) {
                            setDialogState(() {});
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

  Future<void> chooseDueDate() async {
    final firstDueDate = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
    );

    final date = await showDatePicker(
      context: context,
      initialDate: selectedDueDate != null &&
              !selectedDueDate!.isBefore(firstDueDate)
          ? selectedDueDate!
          : firstDueDate,
      firstDate: firstDueDate,
      lastDate: DateTime(2100),
    );

    if (date != null) {
      setState(() => selectedDueDate = date);
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
    amountController.dispose();
    descriptionController.dispose();
    referenceController.dispose();
    journalSearchController.dispose();
    super.dispose();
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

    DateTime? editDueDate = DateTime.tryParse(
      transaction['due_date']?.toString() ?? '',
    );

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
                          editDueDate = null;
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
                          child: Text('${item.$2} ${item.$1}'),
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
                        if (editDueDate != null &&
                            editDueDate!.isBefore(editDate)) {
                          editDueDate = editDate;
                        }
                      });
                    }
                  },
                ),
                if (editType == 'loan_given' ||
                    editType == 'loan_received')
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.event_available),
                    title: Text(ghataT(context, 'Due Date')),
                    subtitle: Text(
                      editDueDate == null
                          ? 'Not set'
                          : '${editDueDate!.year}-${editDueDate!.month.toString().padLeft(2, '0')}-${editDueDate!.day.toString().padLeft(2, '0')}',
                    ),
                    trailing: Icon(Icons.edit_calendar_outlined),
                    onTap: () async {
                      final firstDueDate = DateTime(
                        editDate.year,
                        editDate.month,
                        editDate.day,
                      );

                      final picked = await showDatePicker(
                        context: context,
                        initialDate: editDueDate != null &&
                                !editDueDate!.isBefore(firstDueDate)
                            ? editDueDate!
                            : firstDueDate,
                        firstDate: firstDueDate,
                        lastDate: DateTime(2100),
                      );

                      if (picked != null) {
                        setDialogState(() => editDueDate = picked);
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

    final customerId = editCustomerId;

    final requiresCustomer = editType == 'loan_given' ||
        editType == 'loan_received' ||
        editType == 'loan_repayment_received' ||
        editType == 'loan_repayment_paid';

    if (requiresCustomer &&
        (customerId == null || customerId.isEmpty)) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ghataT(context, 'Select a customer for loan and repayment transactions.'),
          ),
        ),
      );

      amountEditController.dispose();
      descriptionEditController.dispose();
      referenceEditController.dispose();
      return;
    }

    if ((editType == 'loan_repayment_received' ||
            editType == 'loan_repayment_paid') &&
        customerId != null &&
        customerId.isNotEmpty) {
      final user = Supabase.instance.client.auth.currentUser;

      if (user != null) {
        final allLoanData =
            await OfflineDatabase.instance.getRecords('transactions');

        final loanData = allLoanData.where((item) {
          final itemId = item['id']?.toString() ?? '';
          final itemCustomerId =
              item['customer_id']?.toString() ?? '';
          final itemCurrency =
              item['currency']?.toString() ?? '';
          final itemType =
              item['transaction_type']?.toString() ?? '';

          return itemId != id &&
              itemCustomerId == customerId &&
              itemCurrency == editCurrency &&
              {
                'loan_given',
                'loan_received',
                'loan_repayment_received',
                'loan_repayment_paid',
              }.contains(itemType);
        }).toList();

        double receivableBalance = 0;
        double payableBalance = 0;

        for (final item in List<Map<String, dynamic>>.from(loanData)) {
          final type = item['transaction_type']?.toString() ?? '';
          final value =
              double.tryParse(item['amount']?.toString() ?? '') ?? 0;

          if (type == 'loan_given') receivableBalance += value;
          if (type == 'loan_repayment_received') receivableBalance -= value;
          if (type == 'loan_received') payableBalance += value;
          if (type == 'loan_repayment_paid') payableBalance -= value;
        }

        if (editType == 'loan_repayment_received' &&
            (receivableBalance <= 0 || amount > receivableBalance)) {
          if (!mounted) return;

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                receivableBalance <= 0
                    ? 'This customer has no loan to repay in this currency.'
                    : 'Repayment cannot be greater than ${receivableBalance.toStringAsFixed(2)} $editCurrency.',
              ),
            ),
          );
          return;
        }

        if (editType == 'loan_repayment_paid' &&
            (payableBalance <= 0 || amount > payableBalance)) {
          if (!mounted) return;

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                payableBalance <= 0
                    ? 'You do not owe this customer in this currency.'
                    : 'Repayment cannot be greater than ${payableBalance.toStringAsFixed(2)} $editCurrency.',
              ),
            ),
          );
          return;
        }
      }
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
        'due_date': (editType == 'loan_given' ||
                editType == 'loan_received') &&
            editDueDate != null
            ? '${editDueDate!.year}-${editDueDate!.month.toString().padLeft(2, '0')}-${editDueDate!.day.toString().padLeft(2, '0')}'
            : null,
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
  return pw.Center(
    child: pw.Transform.rotate(
      angle: -0.35,
      child: pw.Opacity(
        opacity: 0.10,
        child: pw.Column(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Text(
              'Design by MRS',
              style: pw.TextStyle(
                fontSize: 38,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Mohammad Rahem Sadaf',
              style: const pw.TextStyle(fontSize: 22),
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
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      final profile = await Supabase.instance.client
          .from('profiles')
          .select(
            'full_name, business_name, business_phone, business_address, receipt_note',
          )
          .eq('id', user.id)
          .maybeSingle();

      final id = transaction['id']?.toString() ?? '';
      final reference = transaction['reference_no']?.toString() ?? '';
      final customer = transaction['customer_name']?.toString() ?? '';
      final type = transaction['transaction_type']?.toString() ?? '';
      final amount = transaction['amount']?.toString() ?? '0';
      final currency = transaction['currency']?.toString() ?? '';
      final date = transaction['transaction_date']?.toString() ?? '';
      final rawTime = transaction['transaction_time']?.toString() ?? '';
      final time =
          rawTime.length >= 5 ? rawTime.substring(0, 5) : rawTime;
      final description = transaction['description']?.toString() ?? '';

      final typeLabel = switch (type) {
        'money_in' => 'Money In',
        'money_out' => 'Money Out',
        'loan_given' => 'Loan Given',
        'loan_received' => 'Loan Received',
        'loan_repayment_received' => 'Repayment Received',
        'loan_repayment_paid' => 'Repayment Paid',
        'adjustment_in' => 'Adjustment In',
        'adjustment_out' => 'Adjustment Out',
        _ => type.replaceAll('_', ' '),
      };

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

      final pdf = pw.Document();

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (_) => pw.Stack(
            children: [
              pw.Positioned.fill(
                child: ghataPdfWatermark(),
              ),
              pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text(
                businessName.isEmpty ? 'Ghata' : businessName,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 24,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                'Transaction Receipt',
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(fontSize: 14),
              ),
              if (businessAddress.isNotEmpty)
                pw.Text(
                  businessAddress,
                  textAlign: pw.TextAlign.center,
                ),
              if (businessPhone.isNotEmpty)
                pw.Text(
                  businessPhone,
                  textAlign: pw.TextAlign.center,
                ),
              pw.SizedBox(height: 16),
              pw.Divider(),
              pw.SizedBox(height: 12),
              pw.Text("${ghataT(context, 'Reference')}: $receiptNo"),
              if (customer.isNotEmpty) pw.Text("${ghataT(context, 'Customer')}: $customer"),
              pw.Text("${ghataT(context, 'Type')}: $typeLabel"),
              pw.SizedBox(height: 10),
              pw.Text(
                "${ghataT(context, 'Amount')}: $amount $currency",
                style: pw.TextStyle(
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                time.isEmpty ? 'Date: $date' : 'Date: $date  $time',
              ),
              if (description.isNotEmpty)
                pw.Text("${ghataT(context, 'Description')}: $description"),
              pw.Spacer(),
              if (ownerName.isNotEmpty) pw.Text('${ghataT(context, 'Owner')}: $ownerName'),
              if (receiptNote.isNotEmpty) ...[
                pw.SizedBox(height: 10),
                pw.Text(receiptNote),
              ],
              pw.SizedBox(height: 8),
              pw.Text(
                ghataT(context, 'Generated by Ghata - Business Ledger & Accounting'),
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(fontSize: 9),
              ),
            ],
          )
            ],
          ),
        ),
      );





      final bytes = await pdf.save();

      await SharePlus.instance.share(
        ShareParams(
          title: ghataT(context, 'Transaction Receipt'),
          subject: 'Receipt $receiptNo',
          files: [
            XFile.fromData(
              bytes,
              mimeType: 'application/pdf',
            ),
          ],
          fileNameOverrides: ['Ghata_Receipt_$receiptNo.pdf'],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${ghataT(context, 'Unable to create PDF')}: $e")),
      );
    }
  }

  void showTransactionReceipt(Map<String, dynamic> transaction) {
    final id = transaction['id']?.toString() ?? '';
    final reference = transaction['reference_no']?.toString() ?? '';
    final customer = transaction['customer_name']?.toString() ?? '';
    final type = transaction['transaction_type']?.toString() ?? '';
    final amount = transaction['amount']?.toString() ?? '0';
    final currency = transaction['currency']?.toString() ?? '';
    final date = transaction['transaction_date']?.toString() ?? '';
    final rawTime = transaction['transaction_time']?.toString() ?? '';
    final time =
        rawTime.length >= 5 ? rawTime.substring(0, 5) : rawTime;
    final description = transaction['description']?.toString() ?? '';

    final typeLabel = switch (type) {
      'money_in' => 'Money In',
      'money_out' => 'Money Out',
      'loan_given' => 'Loan Given',
      'loan_received' => 'Loan Received',
      'loan_repayment_received' => 'Repayment Received',
      'loan_repayment_paid' => 'Repayment Paid',
      'adjustment_in' => 'Adjustment In',
      'adjustment_out' => 'Adjustment Out',
      _ => type.replaceAll('_', ' '),
    };

    final receiptNo = reference.isNotEmpty
        ? reference
        : (id.length > 8
            ? id.substring(0, 8).toUpperCase()
            : id.toUpperCase());

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'ګهته – Ghata',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Transaction Receipt',
                textAlign: TextAlign.center,
              ),
              Divider(height: 28),
              Text("${ghataT(context, 'Reference')}: $receiptNo"),
              if (customer.isNotEmpty) Text("${ghataT(context, 'Customer')}: $customer"),
              Text("${ghataT(context, 'Type')}: $typeLabel"),
              Text(
                "${ghataT(context, 'Amount')}: $amount $currency",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(time.isEmpty ? 'Date: $date' : 'Date: $date $time'),
              if (description.isNotEmpty)
                Text("${ghataT(context, 'Description')}: $description"),
              SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  shareTransactionReceiptPdf(transaction);
                },
                icon: Icon(Icons.picture_as_pdf_outlined),
                label: Text(ghataT(context, 'Share PDF Receipt')),
              ),
            ],
          ),
        ),
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
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Daily Journal',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
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
                      label: Text(ghataT(context, 'Loans')),
                      selected: selectedFilter == 'loan',
                      onSelected: (_) {
                        setState(() => selectedFilter = 'loan');
                      },
                    ),
                    SizedBox(width: 8),
                    FilterChip(
                      label: Text(ghataT(context, 'Customer')),
                      selected: selectedFilter == 'customer',
                      onSelected: (_) {
                        setState(() => selectedFilter = 'customer');
                      },
                    ),
                  ],
                ),
              ),

              SizedBox(height: 16),

              FutureBuilder<List<Map<String, dynamic>>>(
                future: loadTransactions(),
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
                    } else if (selectedFilter == 'loan') {
                      filterOk = type.startsWith('loan_');
                    } else if (selectedFilter == 'customer') {
                      filterOk = customer.trim().isNotEmpty;
                    }

                    if (!filterOk) return false;
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
                        type == 'loan_received' ||
                        type == 'loan_repayment_received' ||
                        type == 'adjustment_in') {
                      values['in'] = values['in']! + amount;
                    } else if (type == 'money_out' ||
                        type == 'loan_given' ||
                        type == 'loan_repayment_paid' ||
                        type == 'adjustment_out') {
                      values['out'] = values['out']! + amount;
                    }
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (summary.isNotEmpty) ...[
                        Text(
                          'Summary',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 10),
                        SizedBox(
                          height: 105,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: BouncingScrollPhysics(),
                            itemCount: summary.length,
                            separatorBuilder: (_, __) =>
                                SizedBox(width: 10),
                            itemBuilder: (context, index) {
                              final e =
                                  summary.entries.elementAt(index);

                              return Container(
                                width: 175,
                                padding: EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerLow,
                                  borderRadius:
                                      BorderRadius.circular(18),
                                  border: Border.all(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      e.key,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      'In: ${e.value['in']!.toStringAsFixed(2)}',
                                    ),
                                    Text(
                                      'Out: ${e.value['out']!.toStringAsFixed(2)}',
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        SizedBox(height: 18),
                      ],

                      Text(
                        'Transactions',
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
                        ...filtered.map((row) {
                          final type =
                              row['transaction_type']?.toString() ??
                                  '';
                          final amount =
                              row['amount']?.toString() ?? '0';
                          final currency =
                              row['currency']?.toString() ?? '';
                          final customer =
                              row['customer_name']?.toString() ?? '';
                          final description =
                              row['description']?.toString() ?? '';
                          final date =
                              row['transaction_date']?.toString() ??
                                  '';
                          final rawTime =
                              row['transaction_time']?.toString() ??
                                  '';
                          final time = rawTime.length >= 5
                              ? rawTime.substring(0, 5)
                              : rawTime;

                          final label = switch (type) {
                            'money_in' => 'Money In',
                            'money_out' => 'Money Out',
                            'loan_given' => 'Loan Given',
                            'loan_received' => 'Loan Received',
                            'loan_repayment_received' =>
                              'Repayment Received',
                            'loan_repayment_paid' =>
                              'Repayment Paid',
                            'adjustment_in' => 'Adjustment In',
                            'adjustment_out' => 'Adjustment Out',
                            _ => type.replaceAll('_', ' '),
                          };

                          return Card(
                            margin: EdgeInsets.only(bottom: 9),
                            child: ListTile(
                              leading: CircleAvatar(
                                child: Icon(
                                  type == 'money_in' ||
                                          type ==
                                              'loan_repayment_received' ||
                                          type == 'loan_received' ||
                                          type == 'adjustment_in'
                                      ? Icons.south_west
                                      : Icons.north_east,
                                ),
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      customer.trim().isEmpty
                                          ? 'General'
                                          : customer,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '$amount $currency',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                [
                                  label,
                                  if (time.isEmpty)
                                    date
                                  else
                                    '$date $time',
                                  if (description.isNotEmpty)
                                    description,
                                ].join(' • '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () {
                                showTransactionReceipt(row);
                              },
                            ),
                          );
                        }),

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
                                  leading: Text(
                                    country['flag']!,
                                    style: TextStyle(fontSize: 24),
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

class CustomersScreen extends StatefulWidget {
  CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final addressController = TextEditingController();
  final notesController = TextEditingController();
  final searchController = TextEditingController();

  bool isSaving = false;
  String selectedCustomerCountryCode = '+93';

  Future<List<Map<String, dynamic>>> loadCustomers() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;

      if (user != null) {
        final data = await Supabase.instance.client
            .from('customers')
            .select()
            .isFilter('deleted_at', null)
            .order('full_name');

        final records = List<Map<String, dynamic>>.from(data);
        await OfflineDatabase.instance.cacheServerRecords(
          'customers',
          records,
        );
        return records;
      }
    } catch (_) {
      // Offline: use local database.
    }

    final local = await OfflineDatabase.instance.getRecords('customers');
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

      nameController.clear();
      phoneController.clear();
      selectedCustomerCountryCode = '+93';
      addressController.clear();
      notesController.clear();

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

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(ghataT(context, 'Edit Customer')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                          child: Text(
                            '${selectedCountry['flag']} $selectedEditCountryCode',
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

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(ghataT(context, 'Add Customer')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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

    final parts =
        value.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();

    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }

    return '${parts.first.substring(0, 1)}'
            '${parts.last.substring(0, 1)}'
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Customers',
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
                future: loadCustomers(),
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
                                CircleAvatar(
                                  radius: 27,
                                  child: Text(
                                    customerInitial(name),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
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
                                        Text(
                                          phone,
                                          maxLines: 1,
                                          overflow:
                                              TextOverflow.ellipsis,
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

  @override
  void initState() {
    super.initState();
    refreshCustomerProfile();
  }

  Future<void> refreshCustomerProfile() async {
    final profile = await loadCustomerProfile();
    if (!mounted) return;

    setState(() {
      customerProfile = profile;
    });
  }

  Future<Map<String, dynamic>?> loadCustomerProfile() async {
  await ghataRefreshOfflineCache();

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

  Future<List<Map<String, dynamic>>> loadCustomerTransactions() async {
  await ghataRefreshOfflineCache();

  final local =
      await OfflineDatabase.instance.getRecords('transactions');

  final allowed = {
    'money_in',
    'money_out',
    'loan_given',
    'loan_received',
    'loan_repayment_received',
    'loan_repayment_paid',
  };

  final rows = local.where((row) {
    return row['customer_id']?.toString() == customerId &&
        allowed.contains(
          row['transaction_type']?.toString() ?? '',
        );
  }).toList();

  rows.sort((a, b) {
    final ad =
        '${a['transaction_date'] ?? ''} ${a['transaction_time'] ?? ''} ${a['created_at'] ?? ''}';
    final bd =
        '${b['transaction_date'] ?? ''} ${b['transaction_time'] ?? ''} ${b['created_at'] ?? ''}';

    return bd.compareTo(ad);
  });

  return rows;
}

  Map<String, double> calculateBalances(
    List<Map<String, dynamic>> transactions,
  ) {
    final balances = <String, double>{};

    for (final transaction in transactions) {
      final currency = transaction['currency']?.toString() ?? '';
      final type = transaction['transaction_type']?.toString() ?? '';
      final amount =
          double.tryParse(transaction['amount']?.toString() ?? '0') ?? 0;

      if (currency.isEmpty) continue;

      balances.putIfAbsent(currency, () => 0);

      switch (type) {
        case 'money_out':
        case 'loan_given':
        case 'loan_repayment_paid':
          balances[currency] = balances[currency]! + amount;
          break;

        case 'money_in':
        case 'loan_received':
        case 'loan_repayment_received':
          balances[currency] = balances[currency]! - amount;
          break;

        default:
          break;
      }
    }

    return balances;
  }

  Future<void> openCustomerMoneyEntry(String type) async {
    final profileName =
        customerProfile?['full_name']?.toString().trim().isNotEmpty == true
            ? customerProfile!['full_name'].toString()
            : customerName;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DailyJournalScreen(
          initialCustomerId: customerId,
          initialCustomerName: profileName,
          initialTransactionType: type,
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

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ghataT(context, 'Edit Customer')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                          child: Text(
                            '${selectedCountry['flag']} $selectedProfileCountryCode',
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

      final business = await Supabase.instance.client
          .from('profiles')
          .select(
            'business_name, business_phone, business_address, receipt_note',
          )
          .eq('id', user.id)
          .maybeSingle();

      final name =
          profile?['full_name']?.toString().trim().isNotEmpty == true
              ? profile!['full_name'].toString()
              : customerName;

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

      const width = 1080.0;
      final balanceCount = balances.isEmpty ? 1 : balances.length;
      final height = 520.0 + (balanceCount * 115.0);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final size = Size(width, height);

      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = Colors.white,
      );

      void drawText(
        String text,
        double x,
        double y, {
        double fontSize = 34,
        FontWeight fontWeight = FontWeight.normal,
        Color color = Colors.black87,
        TextAlign textAlign = TextAlign.left,
        double maxWidth = 960,
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
          textDirection: TextDirection.ltr,
          maxLines: 3,
        )..layout(maxWidth: maxWidth);

        double dx = x;
        if (textAlign == TextAlign.center) {
          dx = (width - painter.width) / 2;
        }

        painter.paint(canvas, Offset(dx, y));
      }

      drawText(
        businessName.isEmpty ? 'Ghata' : businessName,
        60,
        45,
        fontSize: 54,
        fontWeight: FontWeight.bold,
        textAlign: TextAlign.center,
      );

      drawText(
        'Customer Balance',
        60,
        115,
        fontSize: 30,
        textAlign: TextAlign.center,
        color: Colors.black54,
      );

      double top = 180;

      if (businessAddress.isNotEmpty) {
        drawText(
          businessAddress,
          60,
          top,
          fontSize: 25,
          textAlign: TextAlign.center,
          color: Colors.black54,
        );
        top += 38;
      }

      if (businessPhone.isNotEmpty) {
        drawText(
          businessPhone,
          60,
          top,
          fontSize: 25,
          textAlign: TextAlign.center,
          color: Colors.black54,
        );
        top += 45;
      }

      canvas.drawLine(
        Offset(60, top),
        Offset(width - 60, top),
        Paint()
          ..color = Colors.black26
          ..strokeWidth = 2,
      );

      top += 35;

      drawText(
        "${ghataT(context, 'Customer')}: $name",
        70,
        top,
        fontSize: 35,
        fontWeight: FontWeight.bold,
      );

      top += 70;

      if (balances.isEmpty) {
        drawText(
          'No outstanding balance',
          70,
          top,
          fontSize: 34,
          color: Colors.black54,
        );
        top += 80;
      } else {
        for (final entry in balances.entries) {
          final value = entry.value;
          final youReceive = value > 0;
          final label = youReceive ? 'You Receive' : 'You Pay';

          final rect = RRect.fromRectAndRadius(
            Rect.fromLTWH(60, top, width - 120, 88),
            Radius.circular(18),
          );

          canvas.drawRRect(
            rect,
            Paint()..color = Color(0xFFF3F5F7),
          );

          drawText(
            label,
            90,
            top + 20,
            fontSize: 29,
            fontWeight: FontWeight.w600,
            maxWidth: 360,
          );

          final amountText =
              '${value.abs().toStringAsFixed(2)} ${entry.key}';

          final amountPainter = TextPainter(
            text: TextSpan(
              text: amountText,
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();

          amountPainter.paint(
            canvas,
            Offset(
              width - 90 - amountPainter.width,
              top + 18,
            ),
          );

          top += 110;
        }
      }

      if (receiptNote.isNotEmpty) {
        drawText(
          receiptNote,
          70,
          top,
          fontSize: 25,
          color: Colors.black54,
        );
        top += 65;
      }

      drawText(
        ghataT(context, 'Generated by Ghata - Business Ledger & Accounting'),
        60,
        height - 65,
        fontSize: 22,
        textAlign: TextAlign.center,
        color: Colors.black45,
      );



    final designCreditPainter = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: 'Design by MRS\n',
            style: TextStyle(
              color: Color(0xFF555555),
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(
            text: 'Mohammad Rahem Sadaf',
            style: TextStyle(
              color: Color(0xFF555555),
              fontSize: 17,
            ),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );

    designCreditPainter.layout(
      minWidth: 0,
      maxWidth: 700,
    );

    designCreditPainter.paint(
      canvas,
      Offset(
        (800 - designCreditPainter.width) / 2,
        1010 - designCreditPainter.height,
      ),
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
        throw Exception(ghataT(context, 'Unable to create image.'));
      }

      final Uint8List bytes = byteData.buffer.asUint8List();

      final safeName = name
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
          .replaceAll(RegExp(r'_+'), '_');

      await SharePlus.instance.share(
        ShareParams(
          title: ghataT(context, 'Customer Balance'),
          subject: '$name - Balance',
          text: 'Customer balance from Ghata',
          files: [
            XFile.fromData(
              bytes,
              mimeType: 'image/png',
            ),
          ],
          fileNameOverrides: [
            'Ghata_Balance_${safeName.isEmpty ? 'Customer' : safeName}.png',
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${ghataT(context, 'Unable to create balance image')}: $e"),
        ),
      );
    }
  }

  Future<void> shareCustomerStatementPdf() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      final transactions = await loadCustomerTransactions();
      final profile = customerProfile ?? await loadCustomerProfile();

      final business = await Supabase.instance.client
          .from('profiles')
          .select(
            'full_name, business_name, business_phone, business_address, receipt_note',
          )
          .eq('id', user.id)
          .maybeSingle();

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
          'loan_given' => 'Loan Given',
          'loan_received' => 'Loan Received',
          'loan_repayment_received' => 'Repayment Received',
          'loan_repayment_paid' => 'Repayment Paid',
          _ => type.replaceAll('_', ' '),
        };
      }

      final pdf = pw.Document();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(28),
          header: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text(
                businessName.isEmpty ? 'Ghata' : businessName,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 22,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              if (businessAddress.isNotEmpty)
                pw.Text(
                  businessAddress,
                  textAlign: pw.TextAlign.center,
                ),
              if (businessPhone.isNotEmpty)
                pw.Text(
                  businessPhone,
                  textAlign: pw.TextAlign.center,
                ),
              pw.SizedBox(height: 8),
              pw.Divider(),
            ],
          ),
          footer: (context) => pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ),
          build: (_) => [
            pw.Text(
              ghataT(context, 'Customer Full Statement'),
              style: pw.TextStyle(
                fontSize: 18,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Text("${ghataT(context, 'Customer')}: $name"),
            if (phone.isNotEmpty) pw.Text("${ghataT(context, 'Phone')}: $phone"),
            if (address.isNotEmpty) pw.Text('${ghataT(context, 'Address')}: $address'),
            pw.SizedBox(height: 16),

            pw.Text(
              ghataT(context, 'Current Balance'),
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),

            if (balances.isEmpty)
              pw.Text(ghataT(context, 'No outstanding balance.'))
            else
              ...balances.entries.map((entry) {
                final value = entry.value;
                return pw.Text(
                  value > 0
                      ? 'You Receive: ${value.abs().toStringAsFixed(2)} ${entry.key}'
                      : 'You Pay: ${value.abs().toStringAsFixed(2)} ${entry.key}',
                );
              }),

            pw.SizedBox(height: 18),
            pw.Text(
              'Transactions',
              style: pw.TextStyle(
                fontSize: 16,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),

            pw.Table.fromTextArray(
              headers: [
                'Date',
                'Type',
                'Amount',
                'Currency',
                'Description',
              ],
              data: transactions.map((transaction) {
                final date =
                    transaction['transaction_date']?.toString() ?? '';
                final rawTime =
                    transaction['transaction_time']?.toString() ?? '';
                final time = rawTime.length >= 5
                    ? rawTime.substring(0, 5)
                    : rawTime;

                return [
                  time.isEmpty ? date : '$date $time',
                  typeLabel(
                    transaction['transaction_type']?.toString() ?? '',
                  ),
                  transaction['amount']?.toString() ?? '0',
                  transaction['currency']?.toString() ?? '',
                  transaction['description']?.toString() ?? '',
                ];
              }).toList(),
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 8,
              ),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellAlignment: pw.Alignment.centerLeft,
            ),

            if (receiptNote.isNotEmpty) ...[
              pw.SizedBox(height: 16),
              pw.Text(receiptNote),
            ],

            pw.SizedBox(height: 12),
            pw.Text(
              ghataT(context, 'Generated by Ghata - Business Ledger & Accounting'),
              style: const pw.TextStyle(fontSize: 9),
            ),
          ],
        ),
      );





      final bytes = await pdf.save();

      final safeName = name
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
          .replaceAll(RegExp(r'_+'), '_');

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
          fileNameOverrides: [
            'Ghata_Statement_${safeName.isEmpty ? 'Customer' : safeName}.pdf',
          ],
        ),
      );
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
    Widget build(BuildContext context) {
      final profileName =
          customerProfile?['full_name']?.toString().trim().isNotEmpty == true
              ? customerProfile!['full_name'].toString()
              : customerName;
      final profileAddress =
          customerProfile?['address']?.toString().trim() ?? '';

      return Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                profileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
          actions: [
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'pdf') {
                  shareCustomerStatementPdf();
                } else if (value == 'share') {
                  shareCustomerBalanceImage();
                } else if (value == 'edit') {
                  editProfileCustomer();
                } else if (value == 'delete') {
                  deleteProfileCustomer();
                }
              },
              itemBuilder: (context) =>  [
                PopupMenuItem(
                  value: 'pdf',
                  child: Text(ghataT(context, 'Full Statement (PDF)')),
                ),
                PopupMenuItem(
                  value: 'share',
                  child: Text(ghataT(context, 'Share Balance Image')),
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
          future: loadCustomerTransactions(),
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
                      child: FilledButton.icon(
                        onPressed: () =>
                            openCustomerMoneyEntry('money_in'),
                        icon: Icon(Icons.south_west),
                        label: Text(ghataT(context, 'Money In')),
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            minimumSize: Size.fromHeight(54),
                        ),
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            openCustomerMoneyEntry('money_out'),
                        icon: Icon(Icons.north_east),
                        label: Text(ghataT(context, 'Money Out')),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: BorderSide(color: Colors.red),
                            minimumSize: Size.fromHeight(54),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 24),
                  Text(
                    'Balances',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 10),

                  if (balances.isEmpty)
                    Card(
                      child: Padding(
                        padding: EdgeInsets.all(18),
                        child: Text(ghataT(context, 'No balance yet.')),
                      ),
                    )
                  else
                    ...balances.entries.map((entry) {
                      final amount = entry.value;
                      final code = entry.key;
                      final youReceive = amount > 0;

                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Icon(
                              youReceive
                                  ? Icons.handshake_outlined
                                  : Icons.volunteer_activism_outlined,
                            ),
                          ),
                          title: Text(
                            youReceive ? 'You Receive' : 'You Pay',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '${flagForCurrency(code)} $code',
                          ),
                          trailing: Text(
                            amount.abs().toStringAsFixed(2),
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      );
                    }),

                SizedBox(height: 24),
                Divider(),
                SizedBox(height: 8),

                Text(
                  'Transactions',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
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
                  ...transactions.map((transaction) {
                    final type =
                        transaction['transaction_type']?.toString() ?? '';
                    final amount =
                        transaction['amount']?.toString() ?? '0';
                    final currency =
                        transaction['currency']?.toString() ?? '';
                    final date =
                        transaction['transaction_date']?.toString() ?? '';
                    final rawTime =
                        transaction['transaction_time']?.toString() ?? '';
                    final time = rawTime.length >= 5
                        ? rawTime.substring(0, 5)
                        : '';
                    final description =
                        transaction['description']?.toString() ?? '';

                      final typeLabel = switch (type) {
                        'money_in' => 'Money In',
                        'money_out' => 'Money Out',
                        'loan_given' => 'Loan Given',
                        'loan_received' => 'Loan Received',
                        'loan_repayment_received' => 'Repayment Received',
                        'loan_repayment_paid' => 'Repayment Paid',
                        _ => type,
                      };

                      final cashIn = type == 'money_in' ||
                          type == 'loan_received' ||
                          type == 'loan_repayment_received';

                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Icon(
                              cashIn ? Icons.south_west : Icons.north_east,
                            ),
                          ),
                          title: Text(
                            '$amount $currency',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            [
                              typeLabel,
                              '${flagForCurrency(currency)} $currency',
                              if (time.isEmpty) date else '$date $time',
                              if (description.isNotEmpty) description,
                            ].join(' • '),
                          ),
                        ),
                      );
                  }),
              ],
            );
          },
        ),
      ),
    );
  }
}

class LoansScreen extends StatefulWidget {
  LoansScreen({super.key});

  @override
  State<LoansScreen> createState() => _LoansScreenState();
}

class _LoansScreenState extends State<LoansScreen> {
  final loanSearchController = TextEditingController();
  String loanFilter = 'all';

  @override
  void dispose() {
    loanSearchController.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> loadLoans() async {
  await ghataRefreshOfflineCache();

  final local =
      await OfflineDatabase.instance.getRecords('transactions');

  final allowed = {
    'loan_given',
    'loan_received',
    'loan_repayment_received',
    'loan_repayment_paid',
  };

  final rows = local.where((row) {
    return allowed.contains(
      row['transaction_type']?.toString() ?? '',
    );
  }).toList();

  rows.sort((a, b) {
    final ad =
        '${a['transaction_date'] ?? ''} ${a['transaction_time'] ?? ''} ${a['created_at'] ?? ''}';
    final bd =
        '${b['transaction_date'] ?? ''} ${b['transaction_time'] ?? ''} ${b['created_at'] ?? ''}';

    return bd.compareTo(ad);
  });

  return rows;
}

  Map<String, Map<String, dynamic>> calculateLoanBalances(
    List<Map<String, dynamic>> transactions,
  ) {
    final grouped = <String, List<Map<String, dynamic>>>{};

    for (final transaction in transactions) {
      final customerId = transaction['customer_id']?.toString();
      final currency = transaction['currency']?.toString() ?? '';

      if (customerId == null ||
          customerId.isEmpty ||
          currency.isEmpty) {
        continue;
      }

      final key = '$customerId|$currency';
      grouped.putIfAbsent(key, () => []).add(transaction);
    }

    final balances = <String, Map<String, dynamic>>{};

    for (final entry in grouped.entries) {
      final items = [...entry.value];

      items.sort((a, b) {
        final aKey =
            '${a['transaction_date'] ?? ''} ${a['transaction_time'] ?? ''}';
        final bKey =
            '${b['transaction_date'] ?? ''} ${b['transaction_time'] ?? ''}';
        return aKey.compareTo(bKey);
      });

      final customerId = items.first['customer_id'].toString();
      final customerName =
          items.last['customer_name']?.toString() ?? 'Unknown Customer';
      final currency = items.first['currency']?.toString() ?? '';

      final receivableLots = <Map<String, dynamic>>[];
      final payableLots = <Map<String, dynamic>>[];

      for (final transaction in items) {
        final type =
            transaction['transaction_type']?.toString() ?? '';
        final amount = double.tryParse(
              transaction['amount']?.toString() ?? '0',
            ) ??
            0;

        if (amount <= 0) continue;

        if (type == 'loan_given') {
          receivableLots.add({
            'remaining': amount,
            'due_date': transaction['due_date']?.toString() ?? '',
          });
        } else if (type == 'loan_repayment_received') {
          var payment = amount;

          for (final lot in receivableLots) {
            if (payment <= 0) break;

            final remaining = lot['remaining'] as double;
            if (remaining <= 0) continue;

            final used = payment > remaining ? remaining : payment;
            lot['remaining'] = remaining - used;
            payment -= used;
          }
        } else if (type == 'loan_received') {
          payableLots.add({
            'remaining': amount,
            'due_date': transaction['due_date']?.toString() ?? '',
          });
        } else if (type == 'loan_repayment_paid') {
          var payment = amount;

          for (final lot in payableLots) {
            if (payment <= 0) break;

            final remaining = lot['remaining'] as double;
            if (remaining <= 0) continue;

            final used = payment > remaining ? remaining : payment;
            lot['remaining'] = remaining - used;
            payment -= used;
          }
        }
      }

      final receivable = receivableLots.fold<double>(
        0,
        (sum, lot) => sum + (lot['remaining'] as double),
      );

      final payable = payableLots.fold<double>(
        0,
        (sum, lot) => sum + (lot['remaining'] as double),
      );

      String? oldestReceivableDueDate;
      for (final lot in receivableLots) {
        final remaining = lot['remaining'] as double;
        final dueDate = lot['due_date']?.toString() ?? '';

        if (remaining <= 0 || dueDate.isEmpty) continue;
        if (oldestReceivableDueDate == null ||
            dueDate.compareTo(oldestReceivableDueDate) < 0) {
          oldestReceivableDueDate = dueDate;
        }
      }

      String? oldestPayableDueDate;
      for (final lot in payableLots) {
        final remaining = lot['remaining'] as double;
        final dueDate = lot['due_date']?.toString() ?? '';

        if (remaining <= 0 || dueDate.isEmpty) continue;
        if (oldestPayableDueDate == null ||
            dueDate.compareTo(oldestPayableDueDate) < 0) {
          oldestPayableDueDate = dueDate;
        }
      }

      if (receivable > 0.000001) {
        balances['${entry.key}|receive'] = {
          'customer_id': customerId,
          'customer_name': customerName,
          'currency': currency,
          'balance': receivable,
          'direction': 'receive',
          'due_date': oldestReceivableDueDate,
        };
      }

      if (payable > 0.000001) {
        balances['${entry.key}|pay'] = {
          'customer_id': customerId,
          'customer_name': customerName,
          'currency': currency,
          'balance': payable,
          'direction': 'pay',
          'due_date': oldestPayableDueDate,
        };
      }
    }

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
        title: Text(ghataT(context, 'Loans & Debts')),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: loadLoans(),
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
                  "${ghataT(context, 'Unable to load loans')}: ${snapshot.error}",
                ),
              ),
            );
          }

          final loans = snapshot.data ?? [];

          final query = loanSearchController.text.trim().toLowerCase();

          final filteredLoans = query.isEmpty
              ? loans
              : loans.where((loan) {
                  final customer =
                      loan['customer_name']?.toString().toLowerCase() ?? '';
                  final currency =
                      loan['currency']?.toString().toLowerCase() ?? '';
                  final type =
                      loan['transaction_type']?.toString().toLowerCase() ?? '';
                  final description =
                      loan['description']?.toString().toLowerCase() ?? '';
                  final dueDate =
                      loan['due_date']?.toString().toLowerCase() ?? '';

                  return customer.contains(query) ||
                      currency.contains(query) ||
                      type.contains(query) ||
                      description.contains(query) ||
                      dueDate.contains(query);
                }).toList();

          final balances = calculateLoanBalances(loans);

          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);

          final remaining = balances.values.where((item) {
            final balance = item['balance'] as double;

            if (query.isNotEmpty) {
              final customer =
                  item['customer_name']?.toString().toLowerCase() ?? '';
              final currency =
                  item['currency']?.toString().toLowerCase() ?? '';

              if (!customer.contains(query) &&
                  !currency.contains(query)) {
                return false;
              }
            }
            final dueDate = item['due_date']?.toString() ?? '';
            final due =
                dueDate.isNotEmpty ? DateTime.tryParse(dueDate) : null;

            final isOverdue =
                due != null && due.isBefore(today);

            final daysUntilDue =
                due == null ? null : due.difference(today).inDays;

            final isDueSoon =
                daysUntilDue != null &&
                daysUntilDue >= 0 &&
                daysUntilDue <= 3;

            switch (loanFilter) {
              case 'receive':
                return item['direction'] == 'receive';
              case 'pay':
                return item['direction'] == 'pay';
              case 'overdue':
                return isOverdue;
              case 'due_soon':
                return isDueSoon && !isOverdue;
              default:
                return true;
            }
          }).toList();

          final balanceCards = remaining.map((item) {
            final customer =
                item['customer_name']?.toString() ??
                    'Unknown Customer';

            final currency =
                item['currency']?.toString() ?? '';

            final balance =
                item['balance'] as double;

            final youReceive = item['direction'] == 'receive';

            final dueDate = item['due_date']?.toString() ?? '';
            final due = dueDate.isNotEmpty
                ? DateTime.tryParse(dueDate)
                : null;

            final now = DateTime.now();
            final today = DateTime(now.year, now.month, now.day);

            final isOverdue =
                due != null && due.isBefore(today);
            final isDueToday =
                due != null && due.isAtSameMomentAs(today);
            final daysUntilDue =
                due == null ? null : due.difference(today).inDays;
            final isDueSoon =
                daysUntilDue != null &&
                daysUntilDue >= 1 &&
                daysUntilDue <= 3;

            return Card(
              child: ListTile(
                leading: CircleAvatar(
                  child: Text(flagForCurrency(currency)),
                ),
                title: Text(
                  customer,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  [
                    youReceive ? 'You Receive' : 'You Pay',
                    if (dueDate.isNotEmpty) 'Due: $dueDate',
                    if (isOverdue)
                      'Overdue'
                    else if (isDueToday)
                      'Due Today'
                    else if (isDueSoon)
                      'Due Soon',
                  ].join(' • '),
                ),
                trailing: Text(
                  '${balance.abs().toStringAsFixed(2)} $currency',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CustomerLedgerScreen(
                        customerId:
                            item['customer_id'].toString(),
                        customerName: customer,
                      ),
                    ),
                  );
                },
              ),
            );
          }).toList();

          final historyCards = filteredLoans.map((loan) {
            final type =
                loan['transaction_type']?.toString() ?? '';
            final customer =
                loan['customer_name']?.toString() ??
                    'Unknown Customer';
            final currency =
                loan['currency']?.toString() ?? '';
            final amount =
                double.tryParse(loan['amount']?.toString() ?? '0') ??
                    0;
            final date =
                loan['transaction_date']?.toString() ?? '';
            final rawTime =
                loan['transaction_time']?.toString() ?? '';
            final time =
                rawTime.length >= 5 ? rawTime.substring(0, 5) : rawTime;
            final description =
                loan['description']?.toString() ?? '';
            final dueDate =
                loan['due_date']?.toString() ?? '';

            String label;
            switch (type) {
              case 'loan_given':
                label = 'Loan Given';
                break;
              case 'loan_received':
                label = 'Loan Received';
                break;
              case 'loan_repayment_received':
                label = 'Repayment Received';
                break;
              case 'loan_repayment_paid':
                label = 'Repayment Paid';
                break;
              default:
                label = type.replaceAll('_', ' ');
            }

            final details = <String>[
              if (date.isNotEmpty) date,
              if (time.isNotEmpty) time,
              if ((type == 'loan_given' || type == 'loan_received') &&
                  dueDate.isNotEmpty)
                'Due: $dueDate',
              if (description.isNotEmpty) description,
            ];

            return Card(
              child: ListTile(
                leading: CircleAvatar(
                  child: Text(flagForCurrency(currency)),
                ),
                title: Text('$label • $customer'),
                subtitle: Text(details.join(' • ')),
                trailing: Text(
                  '${amount.toStringAsFixed(2)} $currency',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onTap: () {
                  final customerId = loan['customer_id']?.toString();
                  if (customerId == null || customerId.isEmpty) return;

                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CustomerLedgerScreen(
                        customerId: customerId,
                        customerName: customer,
                      ),
                    ),
                  );
                },
              ),
            );
          }).toList();

          return ListView(
            padding: EdgeInsets.all(16),
            children: [
              TextField(
                controller: loanSearchController,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Search loans'),
                  hintText: ghataT(context, 'Customer, currency, type, due date...'),
                  prefixIcon: Icon(Icons.search),
                  suffixIcon: loanSearchController.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear),
                          onPressed: () {
                            loanSearchController.clear();
                            setState(() {});
                          },
                        )
                      : null,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: Text(ghataT(context, 'All')),
                    selected: loanFilter == 'all',
                    onSelected: (_) => setState(() => loanFilter = 'all'),
                  ),
                  ChoiceChip(
                    label: Text(ghataT(context, 'You Receive')),
                    selected: loanFilter == 'receive',
                    onSelected: (_) => setState(() => loanFilter = 'receive'),
                  ),
                  ChoiceChip(
                    label: Text(ghataT(context, 'You Pay')),
                    selected: loanFilter == 'pay',
                    onSelected: (_) => setState(() => loanFilter = 'pay'),
                  ),
                  ChoiceChip(
                    label: Text(ghataT(context, 'Overdue')),
                    selected: loanFilter == 'overdue',
                    onSelected: (_) => setState(() => loanFilter = 'overdue'),
                  ),
                  ChoiceChip(
                    label: Text(ghataT(context, 'Due Soon')),
                    selected: loanFilter == 'due_soon',
                    onSelected: (_) => setState(() => loanFilter = 'due_soon'),
                  ),
                ],
              ),
              SizedBox(height: 16),
              if (balanceCards.isEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(ghataT(context, 'No outstanding loans or debts.')),
                )
              else
                ...balanceCards,
              SizedBox(height: 12),
              Text(
                'History',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              if (historyCards.isEmpty)
                Text(ghataT(context, 'No loan history yet.'))
              else
                ...historyCards,
            ],
          );
        },
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
      } else if (type == 'loan_given') {
        balances[currency] = balances[currency]! - amount;
      } else if (type == 'loan_received') {
        balances[currency] = balances[currency]! + amount;
      } else if (type == 'loan_repayment_received') {
        balances[currency] = balances[currency]! + amount;
      } else if (type == 'loan_repayment_paid') {
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
        title: Text(ghataT(context, 'Cashbox')),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: loadTransactions(),
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
            return Card(
              child: ListTile(
                leading: CircleAvatar(
                  child: Text(flagForCurrency(entry.key)),
                ),
                title: Text(entry.key),
                subtitle: Text(
                  entry.value >= 0
                      ? 'Available Balance'
                      : 'Negative Balance',
                ),
                trailing: Text(
                  '${entry.value.toStringAsFixed(2)} ${entry.key}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
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
                label = 'Money In';
                isIn = true;
                break;
              case 'money_out':
                label = 'Money Out';
                isIn = false;
                break;
              case 'loan_given':
                label = 'Loan Given';
                isIn = false;
                break;
              case 'loan_received':
                label = 'Loan Received';
                isIn = true;
                break;
              case 'loan_repayment_received':
                label = 'Loan Repayment Received';
                isIn = true;
                break;
              case 'loan_repayment_paid':
                label = 'Loan Repayment Paid';
                isIn = false;
                break;
              case 'adjustment_in':
                label = 'Adjustment In';
                isIn = true;
                break;
              case 'adjustment_out':
                label = 'Adjustment Out';
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

            return Card(
              child: ListTile(
                leading: Icon(
                  isIn
                      ? Icons.arrow_downward_outlined
                      : Icons.arrow_upward_outlined,
                ),
                title: Text(label),
                subtitle: Text(details.join(' • ')),
                trailing: Text(
                  '${isIn ? '+' : '-'}${amount.toStringAsFixed(2)} $currency',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
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
                'History',
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
  ExchangeScreen({super.key});

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

  double? fromCalculatorResult;
  double? toCalculatorResult;
  double? rateCalculatorResult;

  String? lastExchangeInput;
  bool exchangeRateManuallySet = false;

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

  Future<List<Map<String, dynamic>>> loadCustomers() async {
    final local =
        await OfflineDatabase.instance.getRecords('customers');

    local.sort(
      (a, b) => (a['full_name']?.toString() ?? '')
          .compareTo(b['full_name']?.toString() ?? ''),
    );

    ghataRefreshOfflineCache();

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


  Future<List<Map<String, dynamic>>> loadExchangeHistory() async {
  await ghataRefreshOfflineCache();

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
            'Exchange moved to Recycle Bin. You can restore it within 30 days.',
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
                          child: Text('${item.$2} ${item.$1}'),
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
                          child: Text('${item.$2} ${item.$1}'),
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
                    const DropdownMenuItem<String?>(
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
                child: Text('${item.$2} ${item.$1} - ${item.$3}'),
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
                child: Text('${item.$2} ${item.$1} - ${item.$3}'),
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
            future: loadCustomers(),
            builder: (context, snapshot) {
              final customers = snapshot.data ?? [];

              return DropdownButtonFormField<String?>(
                value: selectedCustomerId,
                decoration: InputDecoration(
                  labelText: ghataT(context, 'Customer (optional)'),
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
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
              isSaving ? 'Saving...' : 'Record Exchange',
            ),
          ),
          ),

          SizedBox(height: 28),

          FutureBuilder<List<Map<String, dynamic>>>(
            future: loadExchangeHistory(),
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

                    return Card(
                      child: ListTile(
                        leading: Icon(
                          profit >= 0
                              ? Icons.trending_up
                              : Icons.trending_down,
                        ),
                        title: Text(
                          '${flagForCurrency(asset)} $asset / '
                          '${flagForCurrency(settlement)} $settlement',
                        ),
                        subtitle: Text(text),
                        trailing: Text(
                          '${profit.abs().toStringAsFixed(2)} $settlement',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
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
            'Recent Exchanges',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          SizedBox(height: 10),

          FutureBuilder<List<Map<String, dynamic>>>(
            future: loadExchangeHistory(),
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
                      : '${flagForCurrency(outCurrency)} ${outEntry['amount']} $outCurrency';

                  final inText = inEntry == null
                      ? '-'
                      : '${flagForCurrency(inCurrency)} ${inEntry['amount']} $inCurrency';

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

                  return Card(
                    child: ListTile(
                      leading: Icon(
                        Icons.currency_exchange_outlined,
                      ),
                      title: Text('$outText → $inText'),
                      subtitle: Text(details.join(' • ')),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: ghataT(context, 'Edit Exchange'),
                            icon: Icon(Icons.edit_outlined),
                            onPressed: () => editExchange(exchange),
                          ),
                          IconButton(
                            tooltip: ghataT(context, 'Delete Exchange'),
                            icon: Icon(Icons.delete_outline),
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
    );
  }

  @override
  void dispose() {
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
  DateTime? fromDate;
  DateTime? toDate;
  String? selectedCurrency;
  String? selectedCustomerId;

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

  Future<List<Map<String, dynamic>>> loadCustomers() async {
    final local =
        await OfflineDatabase.instance.getRecords('customers');

    local.sort(
      (a, b) => (a['full_name']?.toString() ?? '')
          .compareTo(b['full_name']?.toString() ?? ''),
    );

    ghataRefreshOfflineCache();

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
          transaction['customer_id']?.toString();

      if (selectedCustomerId != null &&
          transactionCustomerId != selectedCustomerId) {
        return false;
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
          'loan_given': 0,
          'loan_received': 0,
          'loan_repayment_received': 0,
          'loan_repayment_paid': 0,
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
          type == 'loan_received' ||
          type == 'loan_repayment_received' ||
          type == 'exchange_in' ||
          type == 'adjustment_in') {
        row['net_cash_flow'] = row['net_cash_flow']! + amount;
      } else if (type == 'money_out' ||
          type == 'loan_given' ||
          type == 'loan_repayment_paid' ||
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
                          ? 'From date'
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
                          ? 'To date'
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
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text(ghataT(context, 'All currencies')),
                ),
                ...reportCurrencies.map(
                  (code) => DropdownMenuItem<String?>(
                    value: code,
                    child: Text('${flagForCurrency(code)} $code'),
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
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: loadCustomers(),
              builder: (context, snapshot) {
                final customers = snapshot.data ?? [];

                return DropdownButtonFormField<String?>(
                  value: selectedCustomerId,
                  decoration: InputDecoration(
                    labelText: ghataT(context, 'Customer'),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
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
              future: loadTransactions(),
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
                'Currency Summary',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 10),

              SizedBox(
                height: 150,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: BouncingScrollPhysics(),
                  itemCount: report.length,
                  separatorBuilder: (_, __) =>
                      SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final entry = report.entries.elementAt(index);
                    final currency = entry.key;
                    final data = entry.value;

                    return Container(
                      width: 210,
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLow,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .outlineVariant,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${flagForCurrency(currency)} $currency',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 12),
                          Text(
                            'Money In: ${data['money_in']!.toStringAsFixed(2)}',
                          ),
                          Text(
                            'Money Out: ${data['money_out']!.toStringAsFixed(2)}',
                          ),
                          Spacer(),
                          Text(
                            'Net: ${data['net_cash_flow']!.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),

              SizedBox(height: 22),

              Text(
                'Detailed Report',
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
                      child: Text(flagForCurrency(currency)),
                    ),
                    title: Text(
                      currency,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      'Net Cash Flow: ${data['net_cash_flow']!.toStringAsFixed(2)}',
                    ),
                    childrenPadding:
                        EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      row('Money In', 'money_in'),
                      row('Money Out', 'money_out'),
                      row('Exchange In', 'exchange_in'),
                      row('Exchange Out', 'exchange_out'),
                      row('Loan Given', 'loan_given'),
                      row('Loan Received', 'loan_received'),
                      row(
                        'Repayment Received',
                        'loan_repayment_received',
                      ),
                      row(
                        'Repayment Paid',
                        'loan_repayment_paid',
                      ),
                      row('Adjustment In', 'adjustment_in'),
                      row('Adjustment Out', 'adjustment_out'),
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
        selectedIndex: 4,
      ),
);
  }
}
