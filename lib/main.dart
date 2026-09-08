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
  const GhataCalculatorField({
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
                  padding: const EdgeInsets.all(5),
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
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              );
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
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
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(minHeight: 80),
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        controller.text.isEmpty ? '0' : controller.text,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),

                    Row(
                      children: [
                        calcKey(
                          onPressed: () => refresh(_clear),
                          child: const Text(
                            'AC',
                            style: TextStyle(fontSize: 22),
                          ),
                        ),
                        calcKey(
                          onPressed: () => refresh(_backspace),
                          child: const Icon(
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
                          child: const Text(
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
        suffixIcon: const Icon(Icons.calculate_outlined),
        border: const OutlineInputBorder(),
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

  runApp(const GhataApp());
}

class GhataApp extends StatefulWidget {
  const GhataApp({super.key});

  @override
  State<GhataApp> createState() => _GhataAppState();
}

class _GhataAppState extends State<GhataApp> {
  final navigatorKey = GlobalKey<NavigatorState>();

  Locale _locale = const Locale('en');

  String get currentLanguage => _locale.languageCode;

  void changeLanguage(String languageCode) {
    if (_locale.languageCode == languageCode) return;
    setState(() {
      _locale = Locale(languageCode);
    });
  }

  @override
  void initState() {
    super.initState();

    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.passwordRecovery) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          navigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => const NewPasswordScreen(),
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

      supportedLocales: const [
        Locale('en'), // English
        Locale('ps'), // پښتو
        Locale('fa'), // دری
        Locale('ur'), // اردو
        Locale('ar'), // العربية
      ],

      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: Supabase.instance.client.auth.currentSession == null
          ? const LoginScreen()
          : const GhataStartupGate(),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

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
        const SnackBar(
          content: Text('Please enter your email and password'),
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
        MaterialPageRoute(builder: (_) => const HomeScreen()),
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
        const SnackBar(content: Text('Unable to login. Please try again.')),
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
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.menu_book_rounded,
                    size: 72,
                    color: Colors.blue,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'ګهته',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Ghata – Business Ledger & Accounting',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 36),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Gmail / Email',
                      prefixIcon: Icon(Icons.email_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passwordController,
                    obscureText: hidePassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
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
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ForgotPasswordScreen(),
                          ),
                        );
                      },
                      child: const Text('Forgot Password?'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: isLoading ? null : login,
                      child: const Text('Login'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text("Don't have an account?"),
                      TextButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SignupScreen(),
                            ),
                          );
                        },
                        child: const Text('Create Account'),
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
  const SignupScreen({super.key});

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
        const SnackBar(content: Text('Please fill in all fields')),
      );
      return;
    }

    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password must be at least 6 characters'),
        ),
      );
      return;
    }

    if (password != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passwords do not match')),
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
          const SnackBar(
            content: Text(
              'Account created successfully.',
            ),
          ),
        );

        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) => const HomeScreen(),
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
        const SnackBar(
          content: Text('Something went wrong. Please try again.'),
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
        title: const Text('Create Account'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(
                Icons.person_add_alt_1_rounded,
                size: 70,
                color: Colors.blue,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Full Name',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Gmail / Email',
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                obscureText: hidePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
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
              const SizedBox(height: 16),
              TextField(
                controller: confirmPasswordController,
                obscureText: hideConfirmPassword,
                decoration: InputDecoration(
                  labelText: 'Confirm Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
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
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: isLoading ? null : createAccount,
                  child: isLoading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Create Account'),
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
  const ForgotPasswordScreen({super.key});

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
        const SnackBar(
          content: Text('Please enter your Gmail / Email'),
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
        const SnackBar(
          content: Text('Password reset link sent to your email.'),
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
        const SnackBar(
          content: Text('Unable to send reset link. Please try again.'),
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
        title: const Text('Forgot Password'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 30),
              const Icon(
                Icons.lock_reset_rounded,
                size: 76,
                color: Colors.blue,
              ),
              const SizedBox(height: 20),
              const Text(
                'Enter your Gmail / Email',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'We will send you a password reset link.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Gmail / Email',
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: isLoading ? null : sendResetLink,
                  child: isLoading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Send Reset Link'),
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
        options: const AuthenticationOptions(
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
  const StaffManagementScreen({super.key});

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
        SnackBar(content: Text('Unable to load staff: $e')),
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
          title: const Text('Add Staff'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Staff Email',
                    hintText: 'staff@example.com',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Add / Edit'),
                  subtitle: const Text(
                    'Allow adding and editing accounting records.',
                  ),
                  value: canAddEdit,
                  onChanged: (value) {
                    setDialogState(() => canAddEdit = value);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('View Reports'),
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, true),
              child: const Text('Save'),
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
        const SnackBar(
          content: Text('Enter a valid staff email.'),
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
        const SnackBar(
          content: Text('Staff permissions saved.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to save staff: $e')),
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
        title: const Text('Disable Staff?'),
        content: Text(
          '$email will no longer have staff access.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, true),
            child: const Text('Disable'),
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
        const SnackBar(content: Text('Staff disabled.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to disable staff: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff Management'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: addStaff,
        icon: const Icon(Icons.person_add_outlined),
        label: const Text('Add Staff'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : staff.isEmpty
              ? const Center(
                  child: Text(
                    'No staff added yet.',
                    textAlign: TextAlign.center,
                  ),
                )
              : RefreshIndicator(
                  onRefresh: loadStaff,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
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
                                  tooltip: 'Disable Staff',
                                  icon: const Icon(
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
  const BackupRestoreScreen({super.key});

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
          const JsonEncoder.withIndent('  ').convert(backup),
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
          title: 'Ghata Backup',
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
        const SnackBar(
          content: Text('Backup created successfully.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to create backup: $e')),
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
        title: const Text('Restore Backup'),
        content: const Text(
          'Backup export is ready. Safe restore will be enabled '
          'after restore validation is connected, so an invalid or '
          'wrong-account backup cannot overwrite accounting data.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Backup & Restore'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Create Backup'),
              subtitle: const Text(
                'Export customers, transactions, exchanges and profile.',
              ),
              trailing: busy
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: busy ? null : createBackup,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.restore_outlined),
              title: const Text('Restore Backup'),
              subtitle: const Text(
                'Protected restore with validation.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: showRestoreInfo,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Keep backup files in a safe place such as your '
            'private cloud storage or another trusted device.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}


class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

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
              decoration: const InputDecoration(
                labelText: 'PIN (4-6 digits)',
                border: OutlineInputBorder(),
              ),
            ),
            if (confirm) ...[
              const SizedBox(height: 12),
              TextField(
                controller: secondController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Confirm PIN',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final first = firstController.text.trim();
              final valid =
                  RegExp(r'^\d{4,6}$').hasMatch(first);

              if (!valid) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('PIN must be 4 to 6 digits.'),
                  ),
                );
                return;
              }

              if (confirm && first != secondController.text.trim()) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('PINs do not match.'),
                  ),
                );
                return;
              }

              Navigator.pop(dialogContext, first);
            },
            child: const Text('Save'),
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
      final current = await requestPin(title: 'Enter Current PIN');
      if (current == null) return;

      if (!await GhataSecurity.verifyPin(current)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Incorrect PIN.')),
        );
        return;
      }
    }

    if (!mounted) return;

    final pin = await requestPin(
      title: hasPin ? 'Change App PIN' : 'Create App PIN',
      confirm: true,
    );

    if (pin == null) return;

    await GhataSecurity.savePin(pin);
    await loadSecurityState();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          hasPin ? 'App PIN saved.' : 'App PIN created.',
        ),
      ),
    );
  }

  Future<void> removePin() async {
    final current = await requestPin(title: 'Enter Current PIN');
    if (current == null) return;

    if (!await GhataSecurity.verifyPin(current)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Incorrect PIN.')),
      );
      return;
    }

    await GhataSecurity.removePin();
    await loadSecurityState();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('App PIN removed.')),
    );
  }

  Future<void> changeBiometric(bool enabled) async {
    if (enabled) {
      if (!hasPin) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Create an App PIN first.'),
          ),
        );
        return;
      }

      if (!biometricAvailable) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Fingerprint or Face ID is not available on this device.',
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
        const SnackBar(content: Text('Create an App PIN first.')),
      );
      return;
    }

    if (biometricEnabled) {
      final success = await GhataSecurity.authenticateBiometric();
      if (success) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ghata unlocked successfully.')),
        );
        return;
      }
    }

    if (!mounted) return;

    final pin = await requestPin(title: 'Unlock Ghata');
    if (pin == null) return;

    final valid = await GhataSecurity.verifyPin(pin);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          valid ? 'Ghata unlocked successfully.' : 'Incorrect PIN.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Security'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.pin_outlined),
                        title: Text(
                          hasPin ? 'Change App PIN' : 'Create App PIN',
                        ),
                        subtitle: const Text(
                          'Use a 4 to 6 digit PIN to protect Ghata.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: createOrChangePin,
                      ),
                      if (hasPin)
                        ListTile(
                          leading: const Icon(Icons.lock_open_outlined),
                          title: const Text('Remove App PIN'),
                          onTap: removePin,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: SwitchListTile(
                    secondary: const Icon(Icons.fingerprint),
                    title: const Text('Fingerprint / Face ID'),
                    subtitle: Text(
                      biometricAvailable
                          ? 'Use device biometrics to unlock Ghata.'
                          : 'Biometrics are not available on this device.',
                    ),
                    value: biometricEnabled,
                    onChanged:
                        biometricAvailable ? changeBiometric : null,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: testLock,
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('Test App Lock'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Startup auto-lock will be connected in the final integration batch.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
    );
  }
}



class GhataStartupGate extends StatefulWidget {
  const GhataStartupGate({super.key});

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
        errorText = 'Incorrect PIN.';
      });
    }
  }

  Future<void> signOut() async {
    await Supabase.instance.client.auth.signOut();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const LoginScreen(),
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
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (unlocked) {
      return const HomeScreen();
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 72,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'ګهته – Ghata',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Unlock Ghata',
                    style: TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: pinController,
                    autofocus: !biometricEnabled,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => unlockWithPin(),
                    decoration: InputDecoration(
                      labelText: 'App PIN',
                      border: const OutlineInputBorder(),
                      errorText: errorText,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: unlockWithPin,
                      icon: const Icon(Icons.lock_open_outlined),
                      label: const Text('Unlock'),
                    ),
                  ),
                  if (biometricEnabled) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: checkingBiometric
                            ? null
                            : unlockWithBiometric,
                        icon: checkingBiometric
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.fingerprint),
                        label: const Text(
                          'Fingerprint / Face ID',
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  TextButton(
                    onPressed: signOut,
                    child: const Text('Sign Out'),
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
  const HomeScreen({super.key});

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
        return 'Money In';
      case 'money_out':
        return 'Money Out';
      case 'loan_given':
        return 'Loan Given';
      case 'loan_received':
        return 'Loan Received';
      case 'loan_repayment_received':
        return 'Repayment Received';
      case 'loan_repayment_paid':
        return 'Repayment Paid';
      case 'adjustment_in':
        return 'Adjustment In';
      case 'adjustment_out':
        return 'Adjustment Out';
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
            const ListTile(
              title: Text(
                'Settings & Account',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Profile & Business'),
              onTap: () => Navigator.pop(context, 'profile'),
            ),
            ListTile(
              leading: const Icon(Icons.security_outlined),
              title: const Text('Security'),
              onTap: () => Navigator.pop(context, 'security'),
            ),
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: const Text('Staff & Roles'),
              onTap: () => Navigator.pop(context, 'staff'),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('Backup & Restore'),
              onTap: () => Navigator.pop(context, 'backup'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Recycle Bin'),
              onTap: () => Navigator.pop(context, 'recycle'),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('About Ghata'),
              onTap: () => Navigator.pop(context, 'about'),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign Out'),
              onTap: () => Navigator.pop(context, 'logout'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (!mounted || choice == null) return;

    Widget? screen;

    if (choice == 'profile') {
      screen = const ProfileScreen();
    } else if (choice == 'security') {
      screen = const SecurityScreen();
    } else if (choice == 'staff') {
      screen = const StaffManagementScreen();
    } else if (choice == 'backup') {
      screen = const BackupRestoreScreen();
    } else if (choice == 'recycle') {
      screen = const RecycleBinScreen();
    } else if (choice == 'about') {
      screen = const AboutGhataScreen();
    } else if (choice == 'logout') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sign Out'),
          content: const Text(
            'Are you sure you want to sign out?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sign Out'),
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
            builder: (_) => const AuthScreen(),
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
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
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
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (rows.length > 2)
                const Icon(
                  Icons.swipe_rounded,
                  size: 20,
                  color: Colors.grey,
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            const Text(
              'No balance',
              style: TextStyle(color: Colors.grey),
            )
          else
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: rows.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final e = rows[index];

                  return Container(
                    constraints: const BoxConstraints(
                      minWidth: 140,
                      maxWidth: 185,
                    ),
                    padding: const EdgeInsets.all(12),
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
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          amountText(e.value[key] ?? 0),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
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
          return const SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.data != true) {
          return const SizedBox.shrink();
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
          return const SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.data != true) {
          return const SizedBox.shrink();
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
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ghata',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              'Business Ledger & Accounting',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings & Account',
            onPressed: showHomeMenu,
            icon: const Icon(Icons.menu_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            refreshDashboard();
            await dashboardFuture;
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              FutureBuilder<Map<String, Map<String, double>>>(
                future: dashboardFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState ==
                      ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(30),
                      child: Center(
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }

                  if (snapshot.hasError) {
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
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
                        'Cashbox',
                        Icons.account_balance_wallet_outlined,
                      ),
                      summarySection(
                        data,
                        'today_in',
                        'Money In',
                        Icons.south_west_rounded,
                      ),
                      summarySection(
                        data,
                        'today_out',
                        'Money Out',
                        Icons.north_east_rounded,
                      ),
                      summarySection(
                        data,
                        'receive',
                        'You Receive',
                        Icons.call_received_rounded,
                      ),
                      summarySection(
                        data,
                        'pay',
                        'You Pay',
                        Icons.call_made_rounded,
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 4),

              editPermissionButton(
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: 16,
                      ),
                    ),
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ExchangeScreen(),
                        ),
                      );
                      refreshDashboard();
                    },
                    icon: const Icon(
                      Icons.currency_exchange_rounded,
                    ),
                    label: const Text('Exchange'),
                  ),
                ),
              ),


              const SizedBox(height: 22),

              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Recent Transactions',
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
                              const DailyJournalScreen(),
                        ),
                      );
                      refreshDashboard();
                    },
                    child: const Text('View All'),
                  ),
                ],
              ),

              const SizedBox(height: 6),

              FutureBuilder<List<Map<String, dynamic>>>(
                future: loadRecentTransactions(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState ==
                      ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(18),
                      child: Center(
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }

                  final rows = snapshot.data ?? [];

                  if (rows.isEmpty) {
                    return const Card(
                      child: Padding(
                        padding: EdgeInsets.all(18),
                        child: Center(
                          child: Text(
                            'No transactions yet',
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
                            const EdgeInsets.only(bottom: 8),
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
                            style: const TextStyle(
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
                          trailing: const Icon(
                            Icons.chevron_right,
                          ),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    const DailyJournalScreen(),
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

              const SizedBox(height: 90),

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
                  label: 'Home',
                  selected: true,
                  onTap: () {
                    refreshDashboard();
                  },
                ),
              ),

              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.people_outline,
                  label: 'Customers',
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CustomersScreen(),
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
                                      const DailyJournalScreen(
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
                  label: 'Daily Journal',
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const DailyJournalScreen(),
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
                      label: 'Reports',
                      onTap: snapshot.data != true
                          ? null
                          : () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      const ReportsScreen(),
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
                  label: 'Home',
                  selected: widget.selectedIndex == 0,
                  onTap: widget.selectedIndex == 0
                      ? () {}
                      : () => Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const HomeScreen(),
                            ),
                            (route) => false,
                          ),
                ),
              ),
              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.people_outline,
                  label: 'Customers',
                  selected: widget.selectedIndex == 1,
                  onTap: widget.selectedIndex == 1
                      ? () {}
                      : () => replaceWith(
                            const CustomersScreen(),
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
                                    const DailyJournalScreen(
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
                  label: 'Daily Journal',
                  selected: widget.selectedIndex == 3,
                  onTap: widget.selectedIndex == 3
                      ? () {}
                      : () => replaceWith(
                            const DailyJournalScreen(),
                          ),
                ),
              ),
              Expanded(
                child: _GhataBottomItem(
                  icon: Icons.bar_chart_rounded,
                  label: 'Reports',
                  selected: widget.selectedIndex == 4,
                  onTap: !canReports
                      ? null
                      : widget.selectedIndex == 4
                          ? () {}
                          : () => replaceWith(
                                const ReportsScreen(),
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
  const AboutGhataScreen({super.key});

  Widget guideSection(
    BuildContext context,
    IconData icon,
    String title,
    String text,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              child: Icon(icon),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    text,
                    style: const TextStyle(
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
        title: const Text('About Ghata'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SizedBox(height: 8),

            const Center(
              child: CircleAvatar(
                radius: 42,
                child: Icon(
                  Icons.account_balance_wallet_rounded,
                  size: 42,
                ),
              ),
            ),

            const SizedBox(height: 14),

            const Center(
              child: Text(
                'ګهته – Ghata',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            const SizedBox(height: 4),

            const Center(
              child: Text(
                'Business Ledger & Accounting',
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 24),

            const Text(
              'Complete Guide',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 12),

            guideSection(
              context,
              Icons.home_outlined,
              'Dashboard',
              'The Dashboard gives you a quick overview of your business. '
                  'Cashbox, Money In, Money Out, You Receive and You Pay are '
                  'shown separately for each currency. Ghata does not combine '
                  'different currencies into a converted grand total.',
            ),

            guideSection(
              context,
              Icons.people_outline,
              'Customers',
              'Use Customers to create and manage customer accounts. Open a '
                  'customer profile to see their transaction history and '
                  'separate balances for every currency. You can also edit '
                  'customer information and create customer transactions.',
            ),

            guideSection(
              context,
              Icons.add_circle_outline,
              'Add Transaction',
              'Use the Add button to record Money In, Money Out, loans, loan '
                  'repayments and adjustments. Select the correct currency, '
                  'date, time and customer when required. You can also add a '
                  'description and reference number.',
            ),

            guideSection(
              context,
              Icons.menu_book_outlined,
              'Daily Journal',
              'The Daily Journal keeps your transaction history. Use search '
                  'and filters to find transactions. Transactions can be '
                  'reviewed with their amount, currency, customer, date, time '
                  'and description.',
            ),

            guideSection(
              context,
              Icons.handshake_outlined,
              'Loans & Debts',
              'Ghata tracks money customers owe you and money you owe them. '
                  'Loan repayments reduce the related balance while keeping '
                  'the accounting history available.',
            ),

            guideSection(
              context,
              Icons.currency_exchange,
              'Currency Exchange',
              'Use Exchange for currency buy and sell operations. Select the '
                  'From and To currencies, enter the amounts and exchange '
                  'rate, and optionally select a customer. Each currency '
                  'remains independently recorded.',
            ),

            guideSection(
              context,
              Icons.account_balance_wallet_outlined,
              'Cashbox',
              'Cashbox represents the recorded cash movement of the business. '
                  'Balances are maintained separately by currency and include '
                  'supported transaction and exchange movements.',
            ),

            guideSection(
              context,
              Icons.bar_chart_outlined,
              'Reports',
              'Reports summarize Money In, Money Out, exchanges, loans, '
                  'repayments and adjustments. Reports can be filtered by '
                  'date, currency and customer. Currency totals are never '
                  'automatically converted into another currency.',
            ),

            guideSection(
              context,
              Icons.receipt_long_outlined,
              'Receipts, PDF & Balance Image',
              'Ghata can prepare transaction receipts, customer statements '
                  'and customer balance images for sharing. Always review the '
                  'information before sending a document to another person.',
            ),

            guideSection(
              context,
              Icons.groups_outlined,
              'Staff & Roles',
              'A business owner can manage staff access. Staff permissions '
                  'control whether a staff member can add or edit records and '
                  'whether reports are available to them.',
            ),

            guideSection(
              context,
              Icons.security_outlined,
              'Security',
              'Use Security to protect access to Ghata with the available PIN '
                  'and biometric options. Keep your account password and '
                  'security information private.',
            ),

            guideSection(
              context,
              Icons.cloud_outlined,
              'Backup & Restore',
              'Your Supabase account is the main cloud data source. Backup '
                  'features can also be used to export supported business '
                  'information. Keep exported backup files in a safe place.',
            ),

            guideSection(
              context,
              Icons.delete_outline,
              'Recycle Bin',
              'Deleted accounting records are moved to the Recycle Bin. '
                  'Eligible records can be restored during the retention '
                  'period. Ghata protects accounting history instead of '
                  'silently destroying important financial records.',
            ),

            guideSection(
              context,
              Icons.info_outline,
              'Important',
              'Enter financial information carefully and review balances and '
                  'reports regularly. Ghata is a record-keeping tool; the '
                  'accuracy of reports depends on the information entered.',
            ),

            const SizedBox(height: 14),

            const Card(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Contact Owner',
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

            const SizedBox(height: 24),

            const Center(
              child: Text(
                'Design by MRS',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),

            const SizedBox(height: 3),

            const Center(
              child: Text(
                'Mohammad Rahem Sadaf',
                style: TextStyle(
                  fontSize: 15,
                ),
              ),
            ),

            const SizedBox(height: 30),
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
        padding: const EdgeInsets.symmetric(
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
            const SizedBox(height: 3),
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
  const NewPasswordScreen({super.key});

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
        const SnackBar(
          content: Text('Password must be at least 6 characters'),
        ),
      );
      return;
    }

    if (password != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passwords do not match')),
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
        const SnackBar(
          content: Text('Password changed successfully.'),
        ),
      );

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
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
        title: const Text('New Password'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 30),
              const Icon(
                Icons.password_rounded,
                size: 76,
                color: Colors.blue,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: passwordController,
                obscureText: hidePassword,
                decoration: InputDecoration(
                  labelText: 'New Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
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
              const SizedBox(height: 16),
              TextField(
                controller: confirmPasswordController,
                obscureText: hideConfirmPassword,
                decoration: InputDecoration(
                  labelText: 'Confirm New Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
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
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: isLoading ? null : updatePassword,
                  child: isLoading
                      ? const CircularProgressIndicator()
                      : const Text('Change Password'),
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
  const ProfileScreen({super.key});

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
        const SnackBar(content: Text('Unable to load profile')),
      );
    }
  }

  Future<void> saveProfile() async {
    final fullName = fullNameController.text.trim();
    final username = usernameController.text.trim();

    if (fullName.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete all fields')),
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
        const SnackBar(content: Text('Profile updated successfully')),
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
        title: const Text('Profile'),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Center(
                    child: CircleAvatar(
                      radius: 45,
                      child: Icon(Icons.person, size: 48),
                    ),
                  ),
                  const SizedBox(height: 30),
                  TextField(
                    controller: fullNameController,
                    decoration: const InputDecoration(
                      labelText: 'Full Name',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      prefixIcon: Icon(Icons.alternate_email),
                      border: OutlineInputBorder(),
                      helperText: 'Username can be changed every 30 days',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    readOnly: true,
                    controller: TextEditingController(text: email),
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'Business Profile',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: businessNameController,
                    decoration: const InputDecoration(
                      labelText: 'Business Name',
                      prefixIcon: Icon(Icons.store_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: businessPhoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Business Phone',
                      prefixIcon: Icon(Icons.phone_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: businessAddressController,
                    decoration: const InputDecoration(
                      labelText: 'Business Address',
                      prefixIcon: Icon(Icons.location_on_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: receiptNoteController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Receipt Note',
                      hintText: 'Thank you for your business',
                      prefixIcon: Icon(Icons.notes_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: isSaving ? null : saveProfile,
                      child: isSaving
                          ? const CircularProgressIndicator()
                          : const Text('Save Changes'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.email_outlined),
                      label: const Text('Change Email'),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ChangeEmailScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Recycle Bin'),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const RecycleBinScreen(),
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
  const ChangeEmailScreen({super.key});

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
        const SnackBar(content: Text('Please enter a valid email')),
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
        const SnackBar(
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
        title: const Text('Change Email'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 20),
            Text(
              'Current Email: $currentEmail',
            ),
            const SizedBox(height: 24),
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'New Email',
                prefixIcon: Icon(Icons.email_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: isLoading ? null : changeEmail,
                child: isLoading
                    ? const CircularProgressIndicator()
                    : const Text('Change Email'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({super.key});

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
      const SnackBar(
        content: Text('Transaction restored successfully.'),
      ),
    );

    setState(() {});
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Unable to restore transaction: $e'),
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
      const SnackBar(
        content: Text('Exchange restored successfully.'),
      ),
    );

    setState(() {});
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Unable to restore exchange: $e'),
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
        const SnackBar(
          content: Text('Permanent delete is available after 30 days.'),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Permanently?'),
        content: Text(
          'Permanently delete $label? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete Permanently'),
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
        const SnackBar(content: Text('Exchange removed from Recycle Bin.')),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to permanently delete exchange: $e'),
        ),
      );
    }
  }

  int daysRemaining(String? deletedAt) {
    final deleted = DateTime.tryParse(deletedAt ?? '');
    if (deleted == null) return 30;

    final expires = deleted.add(const Duration(days: 30));
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
      const SnackBar(
        content: Text('Customer restored successfully.'),
      ),
    );

    setState(() {});
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Unable to restore customer: $e'),
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
        const SnackBar(
          content: Text('Permanent delete is available after 30 days.'),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Permanently?'),
        content: Text(
          'Permanently delete $name? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete Permanently'),
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
        const SnackBar(content: Text('Customer removed from Recycle Bin.')),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to permanently delete customer: $e')),
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
        const SnackBar(
          content: Text('Permanent delete is available after 30 days.'),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Permanently?'),
        content: Text(
          'Permanently delete $label? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete Permanently'),
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
        const SnackBar(
          content: Text('Transaction removed from Recycle Bin.'),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to permanently delete transaction: $e'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Recycle Bin'),
        ),
        body: FutureBuilder<List<dynamic>>(
          future: Future.wait([
            loadDeletedCustomers(),
            loadDeletedTransactions(),
            loadDeletedExchanges(),
          ]),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('Unable to load Recycle Bin: ${snapshot.error}'),
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

            if (customers.isEmpty && transactions.isEmpty) {
              return const Center(
                child: Text('Recycle Bin is empty.'),
              );
            }

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (customers.isNotEmpty) ...[
                  const Text(
                    'Customers',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...customers.map((customer) {
                    final id = customer['id']?.toString() ?? '';
                    final name =
                        customer['full_name']?.toString() ?? 'Customer';
                    final address = customer['address']?.toString() ?? '';
                    final remaining =
                        daysRemaining(customer['deleted_at']?.toString());

                    return Card(
                      child: ListTile(
                        leading: const CircleAvatar(
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
                                child: const Text('Restore'),
                              )
                            : TextButton(
                                onPressed: id.isEmpty
                                    ? null
                                    : () => permanentlyDeleteCustomer(
                                          id,
                                          name,
                                          customer['deleted_at']?.toString(),
                                        ),
                                child: const Text('Delete Permanently'),
                              ),
                      ),
                    );
                  }),
                ],

                if (customers.isNotEmpty && transactions.isNotEmpty)
                  const SizedBox(height: 24),

                if (transactions.isNotEmpty) ...[
                  const Text(
                    'Transactions',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
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
                        leading: const CircleAvatar(
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
                                child: const Text('Restore'),
                              )
                            : TextButton(
                                onPressed: id.isEmpty
                                    ? null
                                    : () => permanentlyDeleteTransaction(
                                          id,
                                          label,
                                          transaction['deleted_at']?.toString(),
                                        ),
                                child: const Text('Delete Permanently'),
                              ),
                      ),
                    );
                  }),
                ],
                if (exchanges.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Text(
                    'Exchanges',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
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
                        leading: const CircleAvatar(
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
                                child: const Text('Restore'),
                              )
                            : TextButton(
                                onPressed: id.isEmpty
                                    ? null
                                    : () => permanentlyDeleteExchange(
                                          id,
                                          label,
                                          exchange['deleted_at']?.toString(),
                                        ),
                                child: const Text('Delete Permanently'),
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

  const LanguageScreen({
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
        title: const Text('Language'),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: languages.length,
        separatorBuilder: (_, __) => const Divider(),
        itemBuilder: (context, index) {
          final language = languages[index];
          final selected = currentLanguage == language.$1;

          return ListTile(
            leading: Text(
              language.$3,
              style: const TextStyle(fontSize: 30),
            ),
            title: Text(
              language.$2,
              style: const TextStyle(fontSize: 18),
            ),
            trailing: selected
                ? const Icon(Icons.check_circle)
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

  const DailyJournalScreen({
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

  final currencies = const [
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

  final transactionTypes = const [
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
        const SnackBar(
          content: Text('Please select a customer for loan transactions.'),
        ),
      );
      return;
    }

    final amount = evaluateCalculatorExpression(amountController.text.trim());

    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid amount.')),
      );
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are not logged in.')),
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
            const SnackBar(
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
            const SnackBar(
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
        const SnackBar(
          content: Text('Transaction saved successfully.'),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to save transaction: $e'),
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
            title: const Text('Add Transaction'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: transactionType,
                      decoration: const InputDecoration(
                        labelText: 'Transaction Type',
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
                    const SizedBox(height: 12),

                    GhataCalculatorField(
                      controller: amountController,
                      label: 'Amount',
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
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Result: ${calculatorResult!.toStringAsFixed(calculatorResult! % 1 == 0 ? 0 : 2)} $currency',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 12),

                    DropdownButtonFormField<String>(
                      initialValue: currency,
                      decoration: const InputDecoration(
                        labelText: 'Currency',
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

                    const SizedBox(height: 12),

                    DropdownButtonFormField<String?>(
                      initialValue: selectedCustomerId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Customer (Optional)',
                        prefixIcon:
                            Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('General / No Customer'),
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

                    const SizedBox(height: 8),

                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading:
                          const Icon(Icons.calendar_today),
                      title: const Text('Date'),
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
                        leading: const Icon(
                          Icons.event_available_outlined,
                        ),
                        title: const Text('Due Date'),
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
                          const Icon(Icons.access_time),
                      title: const Text('Time'),
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

                    const SizedBox(height: 8),

                    TextField(
                      controller: descriptionController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        prefixIcon:
                            Icon(Icons.notes_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(height: 12),

                    TextField(
                      controller: referenceController,
                      decoration: const InputDecoration(
                        labelText: 'Reference No.',
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
                child: const Text('Cancel'),
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
                icon: const Icon(Icons.check_rounded),
                label: const Text('Save'),
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
          title: const Text('Edit Transaction'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GhataCalculatorField(
                  controller: amountEditController,
                  label: 'Amount',
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
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Result / Balance: ${editCalculatorResult!.toStringAsFixed(editCalculatorResult! % 1 == 0 ? 0 : 2)} $editCurrency',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: editType,
                  decoration: const InputDecoration(
                    labelText: 'Transaction Type',
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
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: editCurrency,
                  decoration: const InputDecoration(
                    labelText: 'Currency',
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
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today_outlined),
                  title: const Text('Date'),
                  subtitle: Text(
                    '${editDate.year}-${editDate.month.toString().padLeft(2, '0')}-${editDate.day.toString().padLeft(2, '0')}',
                  ),
                  trailing: const Icon(Icons.edit_calendar_outlined),
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
                    leading: const Icon(Icons.event_available),
                    title: const Text('Due Date'),
                    subtitle: Text(
                      editDueDate == null
                          ? 'Not set'
                          : '${editDueDate!.year}-${editDueDate!.month.toString().padLeft(2, '0')}-${editDueDate!.day.toString().padLeft(2, '0')}',
                    ),
                    trailing: const Icon(Icons.edit_calendar_outlined),
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
                  leading: const Icon(Icons.access_time),
                  title: const Text('Time'),
                  subtitle: Text(editTime.format(context)),
                  trailing: const Icon(Icons.edit_outlined),
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
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: editCustomerId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Customer / Person (Optional)',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('No Customer'),
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
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionEditController,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: referenceEditController,
                  decoration: const InputDecoration(
                    labelText: 'Reference No.',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save Changes'),
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
        const SnackBar(
          content: Text('Enter a valid amount greater than zero.'),
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
        const SnackBar(
          content: Text(
            'Select a customer for loan and repayment transactions.',
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
        const SnackBar(
          content: Text('Transaction updated successfully.'),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to update transaction: $e'),
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
              pw.Text('Receipt No: $receiptNo'),
              if (customer.isNotEmpty) pw.Text('Customer: $customer'),
              pw.Text('Type: $typeLabel'),
              pw.SizedBox(height: 10),
              pw.Text(
                'Amount: $amount $currency',
                style: pw.TextStyle(
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                time.isEmpty ? 'Date: $date' : 'Date: $date  $time',
              ),
              if (description.isNotEmpty)
                pw.Text('Description: $description'),
              pw.Spacer(),
              if (ownerName.isNotEmpty) pw.Text('Owner: $ownerName'),
              if (receiptNote.isNotEmpty) ...[
                pw.SizedBox(height: 10),
                pw.Text(receiptNote),
              ],
              pw.SizedBox(height: 8),
              pw.Text(
                'Generated by Ghata - Business Ledger & Accounting',
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
          title: 'Transaction Receipt',
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
        SnackBar(content: Text('Unable to create PDF: $e')),
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
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'ګهته – Ghata',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Transaction Receipt',
                textAlign: TextAlign.center,
              ),
              const Divider(height: 28),
              Text('Receipt No: $receiptNo'),
              if (customer.isNotEmpty) Text('Customer: $customer'),
              Text('Type: $typeLabel'),
              Text(
                'Amount: $amount $currency',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(time.isEmpty ? 'Date: $date' : 'Date: $date $time'),
              if (description.isNotEmpty)
                Text('Description: $description'),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  shareTransactionReceiptPdf(transaction);
                },
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Share PDF Receipt'),
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
        title: const Text('Move to Recycle Bin?'),
        content: Text(
          'Are you sure you want to delete $amount $currencyCode? '
          'It will be restorable from Recycle Bin for 30 days.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Move to Recycle Bin'),
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
        const SnackBar(
          content: Text('Transaction moved to Recycle Bin. You can restore it within 30 days.'),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to delete transaction: $e'),
        ),
      );
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
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
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: searchController,
                decoration: InputDecoration(
                  hintText: 'Search transactions...',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),

              const SizedBox(height: 12),

              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('All'),
                      selected: selectedFilter == 'all',
                      onSelected: (_) {
                        setState(() => selectedFilter = 'all');
                      },
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('Money In'),
                      selected: selectedFilter == 'money_in',
                      onSelected: (_) {
                        setState(() => selectedFilter = 'money_in');
                      },
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('Money Out'),
                      selected: selectedFilter == 'money_out',
                      onSelected: (_) {
                        setState(() => selectedFilter = 'money_out');
                      },
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('Loans'),
                      selected: selectedFilter == 'loan',
                      onSelected: (_) {
                        setState(() => selectedFilter = 'loan');
                      },
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('Customer'),
                      selected: selectedFilter == 'customer',
                      onSelected: (_) {
                        setState(() => selectedFilter = 'customer');
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              FutureBuilder<List<Map<String, dynamic>>>(
                future: loadTransactions(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState ==
                      ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }

                  if (snapshot.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'Unable to load transactions: ${snapshot.error}',
                      ),
                    );
                  }

                  final rows = snapshot.data ?? [];
                  final query =
                      searchController.text.trim().toLowerCase();

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
                        const Text(
                          'Summary',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 105,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            itemCount: summary.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 10),
                            itemBuilder: (context, index) {
                              final e =
                                  summary.entries.elementAt(index);

                              return Container(
                                width: 175,
                                padding: const EdgeInsets.all(14),
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
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
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
                        const SizedBox(height: 18),
                      ],

                      const Text(
                        'Transactions',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),

                      if (filtered.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(35),
                          child: Center(
                            child: Text('No transactions found.'),
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
                            margin: const EdgeInsets.only(bottom: 9),
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
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '$amount $currency',
                                    style: const TextStyle(
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

                      const SizedBox(height: 90),
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
                      decoration: const InputDecoration(
                        labelText: 'Search country or code',
                        hintText: 'Afghanistan or +93',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) {
                        setModalState(() => search = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(
                              child: Text('No country found.'),
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
                                    style: const TextStyle(fontSize: 24),
                                  ),
                                  title: Text(country['name']!),
                                  subtitle: Text(code),
                                  trailing: selected
                                      ? const Icon(Icons.check)
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
  const CustomersScreen({super.key});

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
        const SnackBar(content: Text('Customer name is required.')),
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
        const SnackBar(content: Text('Customer added successfully.')),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to add customer: $e')),
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
        title: const Text('Edit Customer'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameEditController,
                decoration: const InputDecoration(
                  labelText: 'Customer Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
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
                            minimumSize: const Size.fromHeight(56),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
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
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: phoneEditController,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            labelText: 'Phone Number',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: addressEditController,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notesEditController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save Changes'),
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
        const SnackBar(
          content: Text('Customer name is required.'),
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
        const SnackBar(
          content: Text('Customer updated successfully.'),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to update customer: $e'),
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
        title: const Text('Move to Recycle Bin?'),
        content: Text(
          'Are you sure you want to delete $name? '
          'Existing transactions will remain, but they will no longer be linked to this customer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Move to Recycle Bin'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {

      await ghataSoftDeleteLocal('customers', id);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Customer moved to Recycle Bin. You can restore it within 30 days.'),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to delete customer: $e'),
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
          title: const Text('Add Customer'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Customer Name',
                    prefixIcon: Icon(Icons.person_outline),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    SizedBox(
                      width: 112,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
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
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone Number',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: addressController,
                  decoration: const InputDecoration(
                    labelText: 'Address',
                    prefixIcon: Icon(Icons.location_on_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
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
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: isSaving
                  ? null
                  : () async {
                      if (nameController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content:
                                Text('Customer name is required.'),
                          ),
                        );
                        return;
                      }

                      await addCustomer();

                      if (mounted && dialogContext.mounted) {
                        Navigator.pop(dialogContext);
                      }
                    },
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add Customer'),
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
        title: const Text(
          'Customers',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: showAddCustomerDialog,
              icon: const Icon(Icons.add),
              label: const Text('Add'),
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
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: searchController,
                decoration: InputDecoration(
                  hintText: 'Search customers...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: searchController.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
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
              const SizedBox(height: 16),

              FutureBuilder<List<Map<String, dynamic>>>(
                future: loadCustomers(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState ==
                      ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }

                  if (snapshot.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'Unable to load customers: ${snapshot.error}',
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
                    return const Padding(
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
                    return const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(
                        child: Text('No matching customers.'),
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
                        margin: const EdgeInsets.only(bottom: 10),
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 27,
                                  child: Text(
                                    customerInitial(name),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 13),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      if (phone.isNotEmpty) ...[
                                        const SizedBox(height: 3),
                                        Text(
                                          phone,
                                          maxLines: 1,
                                          overflow:
                                              TextOverflow.ellipsis,
                                        ),
                                      ],
                                      if (address.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.location_on_outlined,
                                              size: 15,
                                            ),
                                            const SizedBox(width: 3),
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
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: ListTile(
                                        leading:
                                            Icon(Icons.edit_outlined),
                                        title: Text('Edit'),
                                        contentPadding:
                                            EdgeInsets.zero,
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: ListTile(
                                        leading:
                                            Icon(Icons.delete_outline),
                                        title: Text('Delete'),
                                        contentPadding:
                                            EdgeInsets.zero,
                                      ),
                                    ),
                                  ],
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    ,

      bottomNavigationBar: const _GhataAppBottomNav(
        selectedIndex: 1,
      ),
);
  }

}

class CustomerLedgerScreen extends StatefulWidget {
  final String customerId;
  final String customerName;

  const CustomerLedgerScreen({
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
        title: const Text('Edit Customer'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Customer Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
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
                            minimumSize: const Size.fromHeight(56),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
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
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: phoneController,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            labelText: 'Phone Number',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: addressController,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notesController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save Changes'),
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
          const SnackBar(content: Text('Customer name is required.')),
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
        const SnackBar(content: Text('Customer updated successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to update customer: $e')),
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
      title: const Text('Move to Recycle Bin?'),
      content: Text(
        'Are you sure you want to delete $name?',
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dialogContext, true),
          child: const Text('Delete'),
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
      const SnackBar(
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
        content: Text('Unable to delete customer: $e'),
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
        'Customer: $name',
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
            const Radius.circular(18),
          );

          canvas.drawRRect(
            rect,
            Paint()..color = const Color(0xFFF3F5F7),
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
              style: const TextStyle(
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
        'Generated by Ghata - Business Ledger & Accounting',
        60,
        height - 65,
        fontSize: 22,
        textAlign: TextAlign.center,
        color: Colors.black45,
      );



    final designCreditPainter = TextPainter(
      text: const TextSpan(
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
        throw Exception('Unable to create image.');
      }

      final Uint8List bytes = byteData.buffer.asUint8List();

      final safeName = name
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
          .replaceAll(RegExp(r'_+'), '_');

      await SharePlus.instance.share(
        ShareParams(
          title: 'Customer Balance',
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
          content: Text('Unable to create balance image: $e'),
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
              'Customer Full Statement',
              style: pw.TextStyle(
                fontSize: 18,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Text('Customer: $name'),
            if (phone.isNotEmpty) pw.Text('Phone: $phone'),
            if (address.isNotEmpty) pw.Text('Address: $address'),
            pw.SizedBox(height: 16),

            pw.Text(
              'Current Balance',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),

            if (balances.isEmpty)
              pw.Text('No outstanding balance.')
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
              headers: const [
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
              'Generated by Ghata - Business Ledger & Accounting',
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
          title: 'Customer Statement',
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
        SnackBar(content: Text('Unable to create statement PDF: $e')),
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
                  style: const TextStyle(
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
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'pdf',
                  child: Text('Full Statement (PDF)'),
                ),
                PopupMenuItem(
                  value: 'share',
                  child: Text('Share Balance Image'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'edit',
                  child: Text('Edit Customer'),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete Customer'),
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
              return const Center(
                child: CircularProgressIndicator(),
              );
            }

            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'Unable to load ledger: ${snapshot.error}',
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
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () =>
                            openCustomerMoneyEntry('money_in'),
                        icon: const Icon(Icons.south_west),
                        label: const Text('Money In'),
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(54),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            openCustomerMoneyEntry('money_out'),
                        icon: const Icon(Icons.north_east),
                        label: const Text('Money Out'),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
                            minimumSize: const Size.fromHeight(54),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                  const Text(
                    'Balances',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),

                  if (balances.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(18),
                        child: Text('No balance yet.'),
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
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '${flagForCurrency(code)} $code',
                          ),
                          trailing: Text(
                            amount.abs().toStringAsFixed(2),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      );
                    }),

                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),

                const Text(
                  'Transactions',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),

                if (transactions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('No transactions yet.'),
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
                            style: const TextStyle(
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
  const LoansScreen({super.key});

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
        title: const Text('Loans & Debts'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: loadLoans(),
        builder: (context, snapshot) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Unable to load loans: ${snapshot.error}',
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
                  style: const TextStyle(
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
                  style: const TextStyle(
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
                  style: const TextStyle(
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
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: loanSearchController,
                decoration: InputDecoration(
                  labelText: 'Search loans',
                  hintText: 'Customer, currency, type, due date...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: loanSearchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            loanSearchController.clear();
                            setState(() {});
                          },
                        )
                      : null,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: loanFilter == 'all',
                    onSelected: (_) => setState(() => loanFilter = 'all'),
                  ),
                  ChoiceChip(
                    label: const Text('You Receive'),
                    selected: loanFilter == 'receive',
                    onSelected: (_) => setState(() => loanFilter = 'receive'),
                  ),
                  ChoiceChip(
                    label: const Text('You Pay'),
                    selected: loanFilter == 'pay',
                    onSelected: (_) => setState(() => loanFilter = 'pay'),
                  ),
                  ChoiceChip(
                    label: const Text('Overdue'),
                    selected: loanFilter == 'overdue',
                    onSelected: (_) => setState(() => loanFilter = 'overdue'),
                  ),
                  ChoiceChip(
                    label: const Text('Due Soon'),
                    selected: loanFilter == 'due_soon',
                    onSelected: (_) => setState(() => loanFilter = 'due_soon'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (balanceCards.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('No outstanding loans or debts.'),
                )
              else
                ...balanceCards,
              const SizedBox(height: 12),
              const Text(
                'History',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (historyCards.isEmpty)
                const Text('No loan history yet.')
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
  const CashboxScreen({super.key});

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
        title: const Text('Cashbox'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: loadTransactions(),
        builder: (context, snapshot) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Unable to load cashbox: ${snapshot.error}',
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
                  style: const TextStyle(
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
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            );
          }).toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (balanceCards.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('Cashbox balance is zero.'),
                )
              else
                ...balanceCards,
              const SizedBox(height: 12),
              const Text(
                'History',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (historyCards.isEmpty)
                const Text('No cashbox history yet.')
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
  const ExchangeScreen({super.key});

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

  final currencies = const [
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
        title: const Text('Move to Recycle Bin?'),
        content: const Text(
          'This exchange will be hidden from reports and cashbox. You can restore it from Recycle Bin within 30 days.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Move to Recycle Bin'),
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
        const SnackBar(
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
          content: Text('Unable to move exchange to Recycle Bin: $e'),
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
          title: const Text('Edit Exchange'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: editExchangeType,
                  decoration: const InputDecoration(
                    labelText: 'Type',
              prefixIcon: Icon(Icons.swap_horiz_rounded),
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'buy',
                      child: Text('Buy'),
                    ),
                    DropdownMenuItem(
                      value: 'sell',
                      child: Text('Sell'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => editExchangeType = value);
                    }
                  },
                ),
                const SizedBox(height: 12),

                DropdownButtonFormField<String>(
                  initialValue: editFromCurrency,
                  decoration: const InputDecoration(
                    labelText: 'From Currency',
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
                const SizedBox(height: 12),
                GhataCalculatorField(
                  controller: fromController,
                  label: 'Amount You Give',
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
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: editToCurrency,
                  decoration: const InputDecoration(
                    labelText: 'To Currency',
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
                const SizedBox(height: 12),
                GhataCalculatorField(
                  controller: toController,
                  label: 'Amount You Receive',
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
                const SizedBox(height: 12),
                GhataCalculatorField(
                  controller: editRateController,
                  label: 'Exchange Rate (optional)',
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
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  value: editCustomerId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Customer (optional)',
                  prefixIcon: Icon(Icons.person_outline),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('No Customer'),
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
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today_outlined),
                  title: const Text('Date'),
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
                  leading: const Icon(Icons.access_time),
                  title: const Text('Time'),
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
                const SizedBox(height: 12),
                TextField(
                  controller: editNotesController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
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
          const SnackBar(
            content: Text('Please check exchange values.'),
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
        const SnackBar(
          content: Text('Exchange updated successfully.'),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to update exchange: $e'),
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
        const SnackBar(
          content: Text('Please enter a valid From amount.'),
        ),
      );
      return;
    }

    if (toAmount == null || toAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid To amount.'),
        ),
      );
      return;
    }

    if (fromCurrency == toCurrency) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select two different currencies.'),
        ),
      );
      return;
    }

    if (rate != null && rate <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Rate must be greater than zero.'),
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
        const SnackBar(
          content: Text('Exchange saved successfully.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to save exchange: $e'),
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
        title: const Text('Exchange'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            value: exchangeType,
            decoration: const InputDecoration(
              labelText: 'Exchange Type',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: 'buy',
                child: Text('Buy'),
              ),
              DropdownMenuItem(
                value: 'sell',
                child: Text('Sell'),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => exchangeType = value);
              }
            },
          ),
          const SizedBox(height: 12),

          DropdownButtonFormField<String>(
            value: fromCurrency,
            decoration: const InputDecoration(
              labelText: 'From Currency',
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
          const SizedBox(height: 12),

          GhataCalculatorField(
            controller: fromAmountController,
            label: 'From Amount',
            onChanged: () =>
                updateExchangeCalculatorResults(changed: 'from'),
          ),
          if (fromCalculatorResult != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Result: ${fromCalculatorResult!.toStringAsFixed(fromCalculatorResult! % 1 == 0 ? 0 : 2)} $fromCurrency',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
          const SizedBox(height: 12),

          DropdownButtonFormField<String>(
            value: toCurrency,
            decoration: const InputDecoration(
              labelText: 'To Currency',
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
          const SizedBox(height: 12),

          GhataCalculatorField(
            controller: toAmountController,
            label: 'To Amount',
            onChanged: () =>
                updateExchangeCalculatorResults(changed: 'to'),
          ),
          if (toCalculatorResult != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Result: ${toCalculatorResult!.toStringAsFixed(toCalculatorResult! % 1 == 0 ? 0 : 2)} $toCurrency',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
          const SizedBox(height: 12),

          GhataCalculatorField(
            controller: rateController,
            label: 'Rate (optional)',
            onChanged: () =>
                updateExchangeCalculatorResults(changed: 'rate'),
          ),
          if (rateCalculatorResult != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '1 $fromCurrency = ${rateCalculatorResult!.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')} $toCurrency',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
          const SizedBox(height: 12),

          FutureBuilder<List<Map<String, dynamic>>>(
            future: loadCustomers(),
            builder: (context, snapshot) {
              final customers = snapshot.data ?? [];

              return DropdownButtonFormField<String?>(
                value: selectedCustomerId,
                decoration: const InputDecoration(
                  labelText: 'Customer (optional)',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('No Customer'),
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
          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_month),
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
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.access_time),
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

          const SizedBox(height: 12),

          TextField(
            controller: notesController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Notes',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
            onPressed: isSaving ? null : saveExchange,
            icon: const Icon(Icons.currency_exchange_rounded),
            label: Text(
              isSaving ? 'Saving...' : 'Record Exchange',
            ),
          ),
          ),

          const SizedBox(height: 28),

          FutureBuilder<List<Map<String, dynamic>>>(
            future: loadExchangeHistory(),
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return const SizedBox.shrink();
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
                return const SizedBox.shrink();
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Profit / Loss',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
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
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                ],
              );
            },
          ),

          const Divider(),
          const SizedBox(height: 12),

          const Row(
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
          const SizedBox(height: 10),

          FutureBuilder<List<Map<String, dynamic>>>(
            future: loadExchangeHistory(),
            builder: (context, snapshot) {
              if (snapshot.connectionState ==
                  ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                );
              }

              if (snapshot.hasError) {
                return Text(
                  'Unable to load exchange history: ${snapshot.error}',
                );
              }

              final history = snapshot.data ?? [];

              if (history.isEmpty) {
                return const Text('No exchange history yet.');
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
                      leading: const Icon(
                        Icons.currency_exchange_outlined,
                      ),
                      title: Text('$outText → $inText'),
                      subtitle: Text(details.join(' • ')),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Edit Exchange',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => editExchange(exchange),
                          ),
                          IconButton(
                            tooltip: 'Delete Exchange',
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
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  DateTime? fromDate;
  DateTime? toDate;
  String? selectedCurrency;
  String? selectedCustomerId;

  final reportCurrencies = const [
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
        title: const Text('Reports'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.date_range),
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
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.event),
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
                    tooltip: 'Clear dates',
                    icon: const Icon(Icons.clear),
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: DropdownButtonFormField<String?>(
              value: selectedCurrency,
              decoration: const InputDecoration(
                labelText: 'Currency',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All currencies'),
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: loadCustomers(),
              builder: (context, snapshot) {
                final customers = snapshot.data ?? [];

                return DropdownButtonFormField<String?>(
                  value: selectedCustomerId,
                  decoration: const InputDecoration(
                    labelText: 'Customer',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('All customers'),
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
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.filter_alt_off_outlined),
                  label: const Text('Clear All Filters'),
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
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Unable to load reports: ${snapshot.error}',
                ),
              ),
            );
          }

          final transactions = snapshot.data ?? [];
          final report = calculateReport(transactions);

          if (report.isEmpty) {
            return const Center(
              child: Text('No report data yet.'),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Currency Summary',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),

              SizedBox(
                height: 150,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: report.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final entry = report.entries.elementAt(index);
                    final currency = entry.key;
                    final data = entry.value;

                    return Container(
                      width: 210,
                      padding: const EdgeInsets.all(16),
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
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Money In: ${data['money_in']!.toStringAsFixed(2)}',
                          ),
                          Text(
                            'Money Out: ${data['money_out']!.toStringAsFixed(2)}',
                          ),
                          const Spacer(),
                          Text(
                            'Net: ${data['net_cash_flow']!.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 22),

              const Text(
                'Detailed Report',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),

              ...report.entries.map((entry) {
                final currency = entry.key;
                final data = entry.value;

                Widget row(String title, String key) {
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Expanded(child: Text(title)),
                        Text(
                          data[key]!.toStringAsFixed(2),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ExpansionTile(
                    leading: CircleAvatar(
                      child: Text(flagForCurrency(currency)),
                    ),
                    title: Text(
                      currency,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      'Net Cash Flow: ${data['net_cash_flow']!.toStringAsFixed(2)}',
                    ),
                    childrenPadding:
                        const EdgeInsets.fromLTRB(16, 0, 16, 16),
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

              const SizedBox(height: 80),
            ],
          );
        },
      ),
          ),
        ],
      ),
    ,

      bottomNavigationBar: const _GhataAppBottomNav(
        selectedIndex: 4,
      ),
);
  }
}
