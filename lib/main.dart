import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


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

  void changeLanguage(String languageCode) {
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
          : const HomeScreen(),
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

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('ګهته – Ghata'),
        actions: [
          IconButton(
            tooltip: 'Language',
            icon: const Icon(Icons.language),
            onPressed: () {
              final appState =
                  context.findAncestorStateOfType<_GhataAppState>();

              if (appState == null) return;

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LanguageScreen(
                    currentLanguage: appState._locale.languageCode,
                    onLanguageChanged: appState.changeLanguage,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.person_outline),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ProfileScreen(),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await Supabase.instance.client.auth.signOut();

              if (!context.mounted) return;

              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(
                  builder: (_) => const LoginScreen(),
                ),
                (route) => false,
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.account_balance_wallet_rounded,
                size: 80,
                color: Colors.blue,
              ),
              SizedBox(height: 20),
              Text(
                'Welcome to Ghata',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              const Text(
                'Business Ledger & Accounting',
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 30),
              SizedBox(
                width: 240,
                height: 52,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const DailyJournalScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('Daily Journal'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 240,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CustomersScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.people_outline),
                  label: const Text('Customers'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 240,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LoansScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  label: const Text('Loans & Debts'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 240,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CashboxScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.account_balance_outlined),
                  label: const Text('Cashbox'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 240,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ExchangeScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.currency_exchange_outlined),
                  label: const Text('Exchange'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 240,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ReportsScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.bar_chart_outlined),
                  label: const Text('Reports'),
                ),
              ),
            ],
          ),
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
          .select('full_name, username')
          .eq('id', user.id)
          .single();

      if (!mounted) return;

      fullNameController.text = data['full_name'] ?? '';
      usernameController.text = data['username'] ?? '';

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
  const DailyJournalScreen({super.key});

  @override
  State<DailyJournalScreen> createState() =>
      _DailyJournalScreenState();
}

class _DailyJournalScreenState extends State<DailyJournalScreen> {
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
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return [];

    final data = await Supabase.instance.client
        .from('customers')
        .select('id, full_name, phone')
        .eq('user_id', user.id)
        .order('full_name');

    return List<Map<String, dynamic>>.from(data);
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
    ('adjustment', 'Adjustment'),
  ];

  Future<List<Map<String, dynamic>>> loadTransactions() async {
    final user = Supabase.instance.client.auth.currentUser;

    if (user == null) {
      return [];
    }

    final data = await Supabase.instance.client
        .from('transactions')
        .select()
        .eq('user_id', user.id)
        .order('transaction_date', ascending: false)
        .order('transaction_time', ascending: false)
        .order('created_at', ascending: false)
        .limit(100);

    return List<Map<String, dynamic>>.from(data);
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
      final loanData = await Supabase.instance.client
          .from('transactions')
          .select('transaction_type, amount')
          .eq('user_id', user.id)
          .eq('customer_id', selectedCustomerId!)
          .eq('currency', currency)
          .inFilter('transaction_type', [
            'loan_given',
            'loan_received',
            'loan_repayment_received',
            'loan_repayment_paid',
          ]);

      double loanBalance = 0;

      for (final item in List<Map<String, dynamic>>.from(loanData)) {
        final type = item['transaction_type']?.toString() ?? '';
        final value =
            double.tryParse(item['amount']?.toString() ?? '0') ?? 0;

        if (type == 'loan_given') loanBalance += value;
        if (type == 'loan_repayment_received') loanBalance -= value;
        if (type == 'loan_received') loanBalance -= value;
        if (type == 'loan_repayment_paid') loanBalance += value;
      }

      if (transactionType == 'loan_repayment_received') {
        if (loanBalance <= 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'This customer has no loan to repay in this currency.',
              ),
            ),
          );
          return;
        }

        if (amount > loanBalance) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Repayment cannot exceed ${loanBalance.toStringAsFixed(2)} $currency.',
              ),
            ),
          );
          return;
        }
      }

      if (transactionType == 'loan_repayment_paid') {
        if (loanBalance >= 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'You do not owe this customer in this currency.',
              ),
            ),
          );
          return;
        }

        if (amount > loanBalance.abs()) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Repayment cannot exceed ${loanBalance.abs().toStringAsFixed(2)} $currency.',
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

      await Supabase.instance.client.from('transactions').insert({
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
      });

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
                TextField(
                  controller: amountEditController,
                  keyboardType: TextInputType.text,
                  onChanged: (_) {
                    setDialogState(() {
                      editCalculatorResult =
                          evaluateCalculatorExpression(
                        amountEditController.text.trim(),
                      );
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (editCalculatorResult != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Result / بقایه: ${editCalculatorResult!.toStringAsFixed(editCalculatorResult! % 1 == 0 ? 0 : 2)} $editCurrency',
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
                      setDialogState(() => editType = value);
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
                      setDialogState(() => editDate = picked);
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
        final loanData = await Supabase.instance.client
            .from('transactions')
            .select('transaction_type, amount')
            .eq('user_id', user.id)
            .eq('customer_id', customerId)
            .eq('currency', editCurrency)
            .neq('id', id)
            .inFilter('transaction_type', [
          'loan_given',
          'loan_received',
          'loan_repayment_received',
          'loan_repayment_paid',
        ]);

        double balance = 0;

        for (final item in List<Map<String, dynamic>>.from(loanData)) {
          final type = item['transaction_type']?.toString() ?? '';
          final value =
              double.tryParse(item['amount']?.toString() ?? '') ?? 0;

          if (type == 'loan_given') balance += value;
          if (type == 'loan_repayment_received') balance -= value;
          if (type == 'loan_received') balance -= value;
          if (type == 'loan_repayment_paid') balance += value;
        }

        if (editType == 'loan_repayment_received' &&
            (balance <= 0 || amount > balance)) {
          if (!mounted) return;

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                balance <= 0
                    ? 'This customer has no loan to repay in this currency.'
                    : 'Repayment cannot be greater than ${balance.toStringAsFixed(2)} $editCurrency.',
              ),
            ),
          );
          return;
        }

        if (editType == 'loan_repayment_paid' &&
            (balance >= 0 || amount > balance.abs())) {
          if (!mounted) return;

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                balance >= 0
                    ? 'You do not owe this customer in this currency.'
                    : 'Repayment cannot be greater than ${balance.abs().toStringAsFixed(2)} $editCurrency.',
              ),
            ),
          );
          return;
        }
      }
    }

    try {
      await Supabase.instance.client.from('transactions').update({
        'amount': amount,
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
      }).eq('id', id);

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
        title: const Text('Delete Transaction?'),
        content: Text(
          'Are you sure you want to delete $amount $currencyCode? '
          'This will update related balances and reports.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await Supabase.instance.client
          .from('transactions')
          .delete()
          .eq('id', id);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transaction deleted successfully.'),
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
    final dateText =
        '${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily Journal'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: chooseDate,
                    icon: const Icon(Icons.calendar_month),
                    label: Text(dateText),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: chooseTime,
                    icon: const Icon(Icons.access_time),
                    label: Text(selectedTime.format(context)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            DropdownButtonFormField<String>(
              initialValue: transactionType,
              decoration: const InputDecoration(
                labelText: 'Transaction Type',
                border: OutlineInputBorder(),
              ),
              items: transactionTypes
                  .map(
                    (item) => DropdownMenuItem(
                      value: item.$1,
                      child: Text(item.$2),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => transactionType = value);
                }
              },
            ),
            const SizedBox(height: 16),

            TextField(
              controller: amountController,
              keyboardType: TextInputType.text,
              onChanged: (_) => updateCalculatorResult(),
              decoration: const InputDecoration(
                labelText: 'Amount',
                prefixIcon: Icon(Icons.payments_outlined),
                border: OutlineInputBorder(),
              ),
            ),

            if (calculatorResult != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Result / بقایه: ${calculatorResult!.toStringAsFixed(calculatorResult! % 1 == 0 ? 0 : 2)} $currency',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 16),

            DropdownButtonFormField<String>(
              initialValue: currency,
              decoration: const InputDecoration(
                labelText: 'Currency',
                border: OutlineInputBorder(),
              ),
              items: currencies
                  .map(
                    (item) => DropdownMenuItem(
                      value: item.$1,
                      child: Text(
                        '${item.$2} ${item.$3} (${item.$1})',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => currency = value);
                }
              },
            ),
            const SizedBox(height: 16),

            FutureBuilder<List<Map<String, dynamic>>>(
              future: loadCustomers(),
              builder: (context, snapshot) {
                if (snapshot.connectionState ==
                    ConnectionState.waiting) {
                  return const LinearProgressIndicator();
                }

                if (snapshot.hasError) {
                  return Text(
                    'Unable to load customers: ${snapshot.error}',
                  );
                }

                final customers = snapshot.data ?? [];
                final query = searchController.text.trim().toLowerCase();

                final filteredCustomers = customers.where((customer) {
                  if (query.isEmpty) return true;

                  final name =
                      customer['full_name']?.toString().toLowerCase() ?? '';
                  final phone =
                      customer['phone']?.toString().toLowerCase() ?? '';

                  return name.contains(query) || phone.contains(query);
                }).toList();

                if (filteredCustomers.isEmpty) {
                  return const InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Customer / Person',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                    child: Text(
                      'No customers yet. Add a customer first.',
                    ),
                  );
                }

                return DropdownButtonFormField<String>(
                  initialValue: selectedCustomerId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Customer / Person (Optional)',
                    prefixIcon: Icon(Icons.person_outline),
                    border: OutlineInputBorder(),
                  ),
                  items: customers.map((customer) {
                    final id = customer['id'].toString();
                    final name =
                        customer['full_name']?.toString() ?? '';
                    final phone =
                        customer['phone']?.toString() ?? '';

                    return DropdownMenuItem<String>(
                      value: id,
                      child: Text(
                        phone.isEmpty ? name : '$name • $phone',
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    final customer = customers
                        .where(
                          (item) => item['id'].toString() == value,
                        )
                        .firstOrNull;

                    setState(() {
                      selectedCustomerId = value;
                      selectedCustomerName =
                          customer?['full_name']?.toString();
                    });
                  },
                );
              },
            ),
            const SizedBox(height: 16),

            TextField(
              controller: descriptionController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Description',
                prefixIcon: Icon(Icons.notes),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: referenceController,
              decoration: const InputDecoration(
                labelText: 'Reference No.',
                prefixIcon: Icon(Icons.numbers),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),

            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: isSaving ? null : saveTransaction,
                icon: const Icon(Icons.save_outlined),
                label: Text(
                  isSaving ? 'Saving...' : 'Save Transaction',
                ),
              ),
            ),

            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 12),

            Row(
              children: [
                const Icon(Icons.history),
                const SizedBox(width: 8),
                const Text(
                  'Transaction History',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: () => setState(() {}),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),

            const SizedBox(height: 8),
            TextField(
              controller: journalSearchController,
              decoration: const InputDecoration(
                labelText: 'Search transactions',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),

            FutureBuilder<List<Map<String, dynamic>>>(
              future: loadTransactions(),
              builder: (context, snapshot) {
                if (snapshot.connectionState ==
                    ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: CircularProgressIndicator(),
                    ),
                  );
                }

                if (snapshot.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Unable to load transactions: ${snapshot.error}',
                    ),
                  );
                }

                final transactions = snapshot.data ?? [];
                final query =
                    journalSearchController.text.trim().toLowerCase();

                final filteredTransactions =
                    transactions.where((transaction) {
                  if (query.isEmpty) return true;

                  final type = transaction['transaction_type']
                          ?.toString()
                          .toLowerCase() ??
                      '';
                  final currencyCode =
                      transaction['currency']?.toString().toLowerCase() ??
                          '';
                  final customer =
                      transaction['customer_name']?.toString().toLowerCase() ??
                          '';
                  final description =
                      transaction['description']?.toString().toLowerCase() ??
                          '';
                  final reference =
                      transaction['reference_no']?.toString().toLowerCase() ??
                          '';

                  return type.contains(query) ||
                      currencyCode.contains(query) ||
                      customer.contains(query) ||
                      description.contains(query) ||
                      reference.contains(query);
                }).toList();

                if (filteredTransactions.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('No transactions yet.'),
                    ),
                  );
                }

                return Column(
                  children: filteredTransactions.map((transaction) {
                    final type =
                        transaction['transaction_type']?.toString() ?? '';
                    final amount =
                        transaction['amount']?.toString() ?? '0';
                    final currencyCode =
                        transaction['currency']?.toString() ?? '';
                    final date =
                        transaction['transaction_date']?.toString() ?? '';
                    final rawTime =
                        transaction['transaction_time']?.toString() ?? '';
                    final time = rawTime.length >= 5
                        ? rawTime.substring(0, 5)
                        : '';
                    final customer =
                        transaction['customer_name']?.toString() ?? '';

                    final typeLabel = transactionTypes
                        .where((item) => item.$1 == type)
                        .map((item) => item.$2)
                        .firstOrNull;

                    final currencyInfo = currencies
                        .where((item) => item.$1 == currencyCode)
                        .firstOrNull;

                    final flag =
                        currencyInfo == null ? '💰' : currencyInfo.$2;

                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Text(flag),
                        ),
                        title: Text(
                          '$amount $currencyCode',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          [
                            typeLabel ?? type,
                            if (time.isEmpty) date else '$date $time',
                            if (customer.isNotEmpty) customer,
                          ].join(' • '),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Edit',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => editTransaction(transaction),
                            ),
                            IconButton(
                              tooltip: 'Delete',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => deleteTransaction(transaction),
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
      ),
    );
  }
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

  Future<List<Map<String, dynamic>>> loadCustomers() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return [];

    final data = await Supabase.instance.client
        .from('customers')
        .select()
        .eq('user_id', user.id)
        .order('full_name');

    return List<Map<String, dynamic>>.from(data);
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
      await Supabase.instance.client.from('customers').insert({
        'user_id': user.id,
        'full_name': name,
        'phone': phoneController.text.trim().isEmpty
            ? null
            : phoneController.text.trim(),
        'address': addressController.text.trim().isEmpty
            ? null
            : addressController.text.trim(),
        'notes': notesController.text.trim().isEmpty
            ? null
            : notesController.text.trim(),
      });

      nameController.clear();
      phoneController.clear();
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
    final phoneEditController = TextEditingController(
      text: customer['phone']?.toString() ?? '',
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
              TextField(
                controller: phoneEditController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone',
                  border: OutlineInputBorder(),
                ),
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
      await Supabase.instance.client.from('customers').update({
        'full_name': name,
        'phone': phoneEditController.text.trim().isEmpty
            ? null
            : phoneEditController.text.trim(),
        'address': addressEditController.text.trim().isEmpty
            ? null
            : addressEditController.text.trim(),
        'notes': notesEditController.text.trim().isEmpty
            ? null
            : notesEditController.text.trim(),
      }).eq('id', id);

      await Supabase.instance.client
          .from('transactions')
          .update({'customer_name': name})
          .eq('customer_id', id);

      await Supabase.instance.client
          .from('exchanges')
          .update({'customer_name': name})
          .eq('customer_id', id);

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
        title: const Text('Delete Customer?'),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final transactionLinks = await Supabase.instance.client
          .from('transactions')
          .select('id')
          .eq('customer_id', id)
          .limit(1);

      final exchangeLinks = await Supabase.instance.client
          .from('exchanges')
          .select('id')
          .eq('customer_id', id)
          .limit(1);

      final hasTransactions =
          List<Map<String, dynamic>>.from(transactionLinks).isNotEmpty;
      final hasExchanges =
          List<Map<String, dynamic>>.from(exchangeLinks).isNotEmpty;

      if (hasTransactions || hasExchanges) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'This customer has accounting history and cannot be deleted.',
            ),
          ),
        );
        return;
      }

      await Supabase.instance.client
          .from('customers')
          .delete()
          .eq('id', id);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Customer deleted successfully.'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customers'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
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
            TextField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone',
                prefixIcon: Icon(Icons.phone_outlined),
                border: OutlineInputBorder(),
              ),
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
                prefixIcon: Icon(Icons.notes),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: isSaving ? null : addCustomer,
                icon: const Icon(Icons.person_add_alt_1),
                label: Text(
                  isSaving ? 'Saving...' : 'Add Customer',
                ),
              ),
            ),
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 8),
            const Text(
              'Customer List',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: searchController,
              decoration: const InputDecoration(
                labelText: 'Search customers',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: loadCustomers(),
              builder: (context, snapshot) {
                if (snapshot.connectionState ==
                    ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                if (snapshot.hasError) {
                  return Text(
                    'Unable to load customers: ${snapshot.error}',
                  );
                }

                final customers = snapshot.data ?? [];

                if (customers.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('No customers yet.'),
                    ),
                  );
                }

                return Column(
                  children: filteredCustomers.map((customer) {
                    final name =
                        customer['full_name']?.toString() ?? '';
                    final phone =
                        customer['phone']?.toString() ?? '';

                    return Card(
                      child: ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.person),
                        ),
                        title: Text(name),
                        subtitle:
                            phone.isEmpty ? null : Text(phone),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Edit',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => editCustomer(customer),
                            ),
                            IconButton(
                              tooltip: 'Delete',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => deleteCustomer(customer),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CustomerLedgerScreen(
                                customerId: customer['id'].toString(),
                                customerName: name,
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class CustomerLedgerScreen extends StatelessWidget {
  final String customerId;
  final String customerName;

  const CustomerLedgerScreen({
    super.key,
    required this.customerId,
    required this.customerName,
  });

  Future<List<Map<String, dynamic>>> loadCustomerTransactions() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return [];

    final data = await Supabase.instance.client
        .from('transactions')
        .select()
        .eq('user_id', user.id)
        .eq('customer_id', customerId)
        .order('transaction_date', ascending: false)
        .order('transaction_time', ascending: false)
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(data);
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
        title: Text(customerName),
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
                const Text(
                  'Currency Balances',
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

                    final status = amount > 0
                        ? 'You Receive'
                        : amount < 0
                            ? 'You Pay'
                            : 'Settled';

                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Text(flagForCurrency(code)),
                        ),
                        title: Text(
                          '${amount.abs().toStringAsFixed(2)} $code',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(status),
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

                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Text(flagForCurrency(currency)),
                        ),
                        title: Text(
                          '$amount $currency',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          [
                            type,
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

class LoansScreen extends StatelessWidget {
  const LoansScreen({super.key});

  Future<List<Map<String, dynamic>>> loadLoans() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return [];

    final data = await Supabase.instance.client
        .from('transactions')
        .select('id, customer_id, customer_name, transaction_type, amount, currency, transaction_date, transaction_time, description')
        .eq('user_id', user.id)
        .inFilter(
          'transaction_type',
          [
            'loan_given',
            'loan_received',
            'loan_repayment_received',
            'loan_repayment_paid',
          ],
        )
        .order('transaction_date', ascending: false)
        .order('transaction_time', ascending: false)
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(data);
  }

  Map<String, Map<String, dynamic>> calculateLoanBalances(
    List<Map<String, dynamic>> transactions,
  ) {
    final balances = <String, Map<String, dynamic>>{};

    for (final transaction in transactions) {
      final customerId = transaction['customer_id']?.toString();
      final currency = transaction['currency']?.toString() ?? '';

      if (customerId == null ||
          customerId.isEmpty ||
          currency.isEmpty) {
        continue;
      }

      final customerName =
          transaction['customer_name']?.toString() ?? 'Unknown Customer';

      final type =
          transaction['transaction_type']?.toString() ?? '';

      final amount = double.tryParse(
            transaction['amount']?.toString() ?? '0',
          ) ??
          0;

      final key = '$customerId|$currency';

      balances.putIfAbsent(
        key,
        () => {
          'customer_id': customerId,
          'customer_name': customerName,
          'currency': currency,
          'balance': 0.0,
        },
      );

      var balance = balances[key]!['balance'] as double;

      if (type == 'loan_given') balance += amount;
      if (type == 'loan_repayment_received') balance -= amount;
      if (type == 'loan_received') balance -= amount;
      if (type == 'loan_repayment_paid') balance += amount;

      balances[key]!['balance'] = balance;
    }

    balances.removeWhere(
      (_, item) => (item['balance'] as double).abs() <= 0.000001,
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
          final balances = calculateLoanBalances(loans);
          final remaining = balances.values.toList();

          if (remaining.isEmpty) {
            return const Center(
              child: Text('No outstanding loans or debts.'),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: remaining.length,
            itemBuilder: (context, index) {
              final item = remaining[index];

              final customer =
                  item['customer_name']?.toString() ??
                      'Unknown Customer';

              final currency =
                  item['currency']?.toString() ?? '';

              final balance =
                  item['balance'] as double;

              final youReceive = balance > 0;

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
                    youReceive ? 'You Receive' : 'You Pay',
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
            },
          );
        },
      ),
          ),
        ],
      ),
    );
  }
}

class CashboxScreen extends StatelessWidget {
  const CashboxScreen({super.key});

  Future<List<Map<String, dynamic>>> loadTransactions() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return [];

    final transactionData = await Supabase.instance.client
        .from('transactions')
        .select('transaction_type, amount, currency, transaction_date, transaction_time')
        .eq('user_id', user.id);

    final exchangeData = await Supabase.instance.client
        .from('exchange_entries')
        .select(
          'entry_type, amount, currency, exchanges!inner(exchange_date, exchange_time, customer_id, customer_name)',
        )
        .eq('user_id', user.id);

    final all = <Map<String, dynamic>>[];

    all.addAll(
      List<Map<String, dynamic>>.from(transactionData),
    );

    for (final entry
        in List<Map<String, dynamic>>.from(exchangeData)) {
      final entryType = entry['entry_type']?.toString() ?? '';

      all.add({
        'transaction_type':
            entryType == 'money_out' ? 'exchange_out' : 'exchange_in',
        'amount': entry['amount'],
        'currency': entry['currency'],
        'report_date': entry['created_at'],
      });
    }

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

          if (balances.isEmpty) {
            return const Center(
              child: Text('Cashbox is empty.'),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: balances.entries.map((entry) {
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
            }).toList(),
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
  String? selectedCustomerId;
  String? selectedCustomerName;
  DateTime selectedExchangeDate = DateTime.now();
  TimeOfDay selectedExchangeTime = TimeOfDay.now();
  bool isSaving = false;

  double? fromCalculatorResult;
  double? toCalculatorResult;
  double? rateCalculatorResult;

  void updateExchangeCalculatorResults() {
    setState(() {
      fromCalculatorResult = evaluateCalculatorExpression(
        fromAmountController.text.trim(),
      );
      toCalculatorResult = evaluateCalculatorExpression(
        toAmountController.text.trim(),
      );
      rateCalculatorResult = evaluateCalculatorExpression(
        rateController.text.trim(),
      );
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
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return [];

    final data = await Supabase.instance.client
        .from('customers')
        .select('id, full_name, phone')
        .eq('user_id', user.id)
        .order('full_name');

    return List<Map<String, dynamic>>.from(data);
  }

  Future<List<Map<String, dynamic>>> loadExchangeHistory() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return [];

    final exchanges = await Supabase.instance.client
        .from('exchanges')
        .select(
          'id, exchange_date, exchange_time, customer_name, notes, created_at',
        )
        .eq('user_id', user.id)
        .order('exchange_date', ascending: false)
        .order('exchange_time', ascending: false)
        .order('created_at', ascending: false);

    final result = <Map<String, dynamic>>[];

    for (final exchange
        in List<Map<String, dynamic>>.from(exchanges)) {
      final entries = await Supabase.instance.client
          .from('exchange_entries')
          .select('entry_type, amount, currency, rate')
          .eq('exchange_id', exchange['id']);

      result.add({
        ...exchange,
        'entries': List<Map<String, dynamic>>.from(entries),
      });
    }

    return result;
  }

  Future<void> deleteExchange(Map<String, dynamic> exchange) async {
    final id = exchange['id']?.toString();
    if (id == null || id.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Exchange?'),
        content: const Text(
          'This will remove the exchange and its related entries from reports and cashbox.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await Supabase.instance.client.rpc(
        'delete_exchange',
        params: {
          'p_exchange_id': id,
        },
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Exchange deleted successfully.'),
        ),
      );

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to delete exchange: $e'),
        ),
      );
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
      await Supabase.instance.client.rpc(
        'create_exchange',
        params: {
          'p_exchange_date':
              '${selectedExchangeDate.year}-${selectedExchangeDate.month.toString().padLeft(2, '0')}-${selectedExchangeDate.day.toString().padLeft(2, '0')}',
          'p_exchange_time':
              '${selectedExchangeTime.hour.toString().padLeft(2, '0')}:${selectedExchangeTime.minute.toString().padLeft(2, '0')}:00',
          'p_customer_id': selectedCustomerId,
          'p_customer_name': selectedCustomerName,
          'p_notes': notesController.text.trim(),
          'p_from_currency': fromCurrency,
          'p_from_amount': fromAmount,
          'p_to_currency': toCurrency,
          'p_to_amount': toAmount,
          'p_rate': rate,
        },
      );

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

          TextField(
            controller: fromAmountController,
            keyboardType: TextInputType.text,
            onChanged: (_) => updateExchangeCalculatorResults(),
            decoration: const InputDecoration(
              labelText: 'From Amount',
              border: OutlineInputBorder(),
            ),
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

          TextField(
            controller: toAmountController,
            keyboardType: TextInputType.text,
            onChanged: (_) => updateExchangeCalculatorResults(),
            decoration: const InputDecoration(
              labelText: 'To Amount',
              border: OutlineInputBorder(),
            ),
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

          TextField(
            controller: rateController,
            keyboardType: TextInputType.text,
            onChanged: (_) => updateExchangeCalculatorResults(),
            decoration: const InputDecoration(
              labelText: 'Rate (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          if (rateCalculatorResult != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Result: ${rateCalculatorResult!.toStringAsFixed(rateCalculatorResult! % 1 == 0 ? 0 : 4)}',
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

          FilledButton.icon(
            onPressed: isSaving ? null : saveExchange,
            icon: const Icon(Icons.save_outlined),
            label: Text(
              isSaving ? 'Saving...' : 'Save Exchange',
            ),
          ),

          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 12),

          const Text(
            'Exchange History',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
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

                  final details = <String>[
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
                      trailing: IconButton(
                        tooltip: 'Delete Exchange',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => deleteExchange(exchange),
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
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return [];

    final data = await Supabase.instance.client
        .from('customers')
        .select('id, full_name, phone')
        .eq('user_id', user.id)
        .order('full_name');

    return List<Map<String, dynamic>>.from(data);
  }

  Future<List<Map<String, dynamic>>> loadTransactions() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return [];

    final transactionData = await Supabase.instance.client
        .from('transactions')
        .select('transaction_type, amount, currency, transaction_date, transaction_time, customer_id, customer_name')
        .eq('user_id', user.id);

    final exchangeData = await Supabase.instance.client
        .from('exchange_entries')
        .select('entry_type, amount, currency, created_at')
        .eq('user_id', user.id);

    final all = <Map<String, dynamic>>[];

    all.addAll(
      List<Map<String, dynamic>>.from(transactionData),
    );

    for (final entry
        in List<Map<String, dynamic>>.from(exchangeData)) {
      final entryType = entry['entry_type']?.toString() ?? '';

      final exchange = entry['exchanges'] as Map<String, dynamic>?;

      all.add({
        'transaction_type':
            entryType == 'money_out' ? 'exchange_out' : 'exchange_in',
        'amount': entry['amount'],
        'currency': entry['currency'],
        'transaction_date': exchange?['exchange_date'],
        'transaction_time': exchange?['exchange_time'],
        'customer_id': exchange?['customer_id'],
        'customer_name': exchange?['customer_name'],
      });
    }

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
        },
      );

      final row = report[currency]!;

      if (row.containsKey(type)) {
        row[type] = row[type]! + amount;
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
                        lastDate: DateTime(2100),
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
                        initialDate: toDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
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
            children: report.entries.map((entry) {
              final currency = entry.key;
              final data = entry.value;

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${flagForCurrency(currency)} $currency',
                        style: const TextStyle(
                          fontSize: 20,
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
                      Text(
                        'Exchange In: ${data['exchange_in']!.toStringAsFixed(2)}',
                      ),
                      Text(
                        'Exchange Out: ${data['exchange_out']!.toStringAsFixed(2)}',
                      ),
                      Text(
                        'Loan Given: ${data['loan_given']!.toStringAsFixed(2)}',
                      ),
                      Text(
                        'Loan Received: ${data['loan_received']!.toStringAsFixed(2)}',
                      ),
                      Text(
                        'Loan Repayment Received: ${data['loan_repayment_received']!.toStringAsFixed(2)}',
                      ),
                      Text(
                        'Loan Repayment Paid: ${data['loan_repayment_paid']!.toStringAsFixed(2)}',
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
          ),
        ],
      ),
    );
  }
}
