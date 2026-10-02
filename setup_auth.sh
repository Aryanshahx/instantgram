#!/usr/bin/env bash
# Instantgram - Step 1: Firebase Auth (email/password) + Firestore profile + app skeleton
# Run from the project root:  bash setup_auth.sh
set -euo pipefail

PKG="com.hypertechlabs.instantgram"

echo "==> Checking project..."
[ -f pubspec.yaml ] || { echo "ERROR: run this from the Flutter project root (pubspec.yaml not found)."; exit 1; }
[ -d android ]      || { echo "ERROR: android/ folder missing. Run: flutter create --platforms=android --org com.hypertechlabs ."; exit 1; }

GS="android/app/google-services.json"
if [ ! -f "$GS" ]; then
  echo "ERROR: $GS not found."
  echo "Download it from Firebase console (Project settings -> Your apps -> Android) and copy it to android/app/ first."
  exit 1
fi
if ! grep -q "\"package_name\": \"$PKG\"" "$GS"; then
  echo "ERROR: google-services.json does not contain package_name $PKG"
  echo "Register the Android app in Firebase with exactly: $PKG"
  exit 1
fi

APP_NAME=$(grep -E '^name:' pubspec.yaml | head -1 | awk '{print $2}')
echo "==> Dart package name: $APP_NAME"

echo "==> Adding dependencies..."
flutter pub add firebase_core firebase_auth cloud_firestore

echo "==> Patching Android Gradle files for Firebase..."
python3 - <<'PY'
import re, os, sys

def read(p):
    with open(p) as f: return f.read()
def write(p, s):
    with open(p, 'w') as f: f.write(s)

def pick(*names):
    for n in names:
        if os.path.exists(n): return n
    return None

settings = pick('android/settings.gradle.kts', 'android/settings.gradle')
app      = pick('android/app/build.gradle.kts', 'android/app/build.gradle')
if not settings or not app:
    print("ERROR: Gradle files not found"); sys.exit(1)

anchor = re.compile(r'^([ \t]*)id\s*\(?\s*["\']com\.android\.application["\'][^\n]*$', re.M)

# --- settings.gradle(.kts): declare plugin version
s = read(settings)
if 'com.google.gms.google-services' in s:
    print("  settings: already patched")
else:
    m = anchor.search(s)
    if not m:
        print("ERROR: could not find com.android.application in " + settings)
        print("Your Flutter project uses an old Gradle layout. Upgrade Flutter or patch manually."); sys.exit(1)
    kts = settings.endswith('.kts')
    line = ('id("com.google.gms.google-services") version "4.4.2" apply false' if kts
            else 'id "com.google.gms.google-services" version "4.4.2" apply false')
    s = s[:m.end()] + '\n' + m.group(1) + line + s[m.end():]
    write(settings, s)
    print("  settings: patched " + settings)

# --- app/build.gradle(.kts): apply plugin + minSdk
a = read(app)
kts = app.endswith('.kts')
if 'com.google.gms.google-services' in a:
    print("  app: plugin already applied")
else:
    m = anchor.search(a)
    if not m:
        print("ERROR: could not find com.android.application in " + app); sys.exit(1)
    line = 'id("com.google.gms.google-services")' if kts else 'id "com.google.gms.google-services"'
    a = a[:m.end()] + '\n' + m.group(1) + line + a[m.end():]
    print("  app: plugin applied")

if 'maxOf(23' not in a and 'Math.max(23' not in a:
    repl = 'maxOf(23, flutter.minSdkVersion)' if kts else 'Math.max(23, flutter.minSdkVersion)'
    a, n = re.subn(r'flutter\.minSdkVersion', repl, a, count=1)
    print("  app: minSdk >= 23 " + ("set" if n else "NOT FOUND (set minSdk 23 manually)"))
write(app, a)
PY

echo "==> Writing Dart source files..."
mkdir -p lib/core lib/services lib/screens/auth lib/screens/home test

cat > lib/main.dart <<'EOF'
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const InstantgramApp());
}
EOF

cat > lib/app.dart <<'EOF'
import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'screens/auth/auth_gate.dart';

class InstantgramApp extends StatelessWidget {
  const InstantgramApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Instantgram',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const AuthGate(),
    );
  }
}
EOF

cat > lib/core/theme.dart <<'EOF'
import 'package:flutter/material.dart';

class AppTheme {
  static const Color brand = Color(0xFFE1306C);
  static const Color blue = Color(0xFF3797EF);

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: brand, primary: blue),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFFAFAFA),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFDBDBDB)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFDBDBDB)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: blue,
            minimumSize: const Size.fromHeight(48),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );
}
EOF

cat > lib/services/auth_service.dart <<'EOF'
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UsernameTakenException implements Exception {
  const UsernameTakenException();
  @override
  String toString() => 'That username is already taken.';
}

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Stream<User?> get authChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  static final RegExp usernameRegex = RegExp(r'^[a-z0-9._]{3,20}$');

  Future<bool> isUsernameAvailable(String username) async {
    final doc = await _db.collection('usernames').doc(username).get();
    return !doc.exists;
  }

  Future<void> signIn({required String email, required String password}) async {
    await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> signUp({
    required String email,
    required String password,
    required String username,
  }) async {
    final uname = username.trim().toLowerCase();

    if (!await isUsernameAvailable(uname)) {
      throw const UsernameTakenException();
    }

    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = cred.user!;

    try {
      // Claim the username + create profile atomically (guards against races).
      await _db.runTransaction((tx) async {
        final nameRef = _db.collection('usernames').doc(uname);
        final snap = await tx.get(nameRef);
        if (snap.exists) throw const UsernameTakenException();
        tx.set(nameRef, {'uid': user.uid});
        tx.set(_db.collection('users').doc(user.uid), {
          'uid': user.uid,
          'username': uname,
          'email': email.trim(),
          'bio': '',
          'photoUrl': '',
          'followersCount': 0,
          'followingCount': 0,
          'postsCount': 0,
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
      await user.updateDisplayName(uname);
    } catch (e) {
      // Roll back the auth account so the user can retry.
      await user.delete();
      rethrow;
    }
  }

  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());

  Future<void> signOut() => _auth.signOut();

  /// Turns any error into a short, user-friendly message.
  static String friendlyError(Object e) {
    if (e is UsernameTakenException) return e.toString();
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'invalid-email':
          return 'That email address is not valid.';
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential':
          return 'Incorrect email or password.';
        case 'email-already-in-use':
          return 'An account already exists with that email.';
        case 'weak-password':
          return 'Password is too weak (use at least 6 characters).';
        case 'user-disabled':
          return 'This account has been disabled.';
        case 'too-many-requests':
          return 'Too many attempts. Please try again later.';
        case 'network-request-failed':
          return 'No internet connection.';
        case 'operation-not-allowed':
          return 'Email/password sign-in is not enabled in Firebase.';
      }
      return e.message ?? 'Authentication failed.';
    }
    if (e is FirebaseException) {
      if (e.code == 'permission-denied') {
        return 'Database permission denied. Check Firestore rules.';
      }
      return e.message ?? 'Database error.';
    }
    return 'Something went wrong. Please try again.';
  }
}
EOF

cat > lib/screens/auth/auth_gate.dart <<'EOF'
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../home/home_screen.dart';
import 'login_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: AuthService.instance.authChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasData) return const HomeScreen();
        return const LoginScreen();
      },
    );
  }
}
EOF

cat > lib/screens/auth/login_screen.dart <<'EOF'
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../services/auth_service.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await AuthService.instance
          .signIn(email: _email.text, password: _password.text);
      // AuthGate switches to Home automatically.
    } catch (e) {
      _toast(AuthService.friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forgot() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      _toast('Enter your email above first.');
      return;
    }
    try {
      await AuthService.instance.sendPasswordReset(email);
      _toast('Password reset email sent.');
    } catch (e) {
      _toast(AuthService.friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Instantgram',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w700,
                      fontStyle: FontStyle.italic,
                      color: AppTheme.brand,
                    ),
                  ),
                  const SizedBox(height: 36),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(hintText: 'Email'),
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Enter a valid email'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _password,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      hintText: 'Password',
                      suffixIcon: IconButton(
                        icon: Icon(_obscure
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Enter your password' : null,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _forgot,
                      child: const Text('Forgot password?'),
                    ),
                  ),
                  FilledButton(
                    onPressed: _loading ? null : _login,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Log in'),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text("Don't have an account?"),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const SignupScreen()),
                        ),
                        child: const Text('Sign up'),
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
EOF

cat > lib/screens/auth/signup_screen.dart <<'EOF'
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../services/auth_service.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await AuthService.instance.signUp(
        email: _email.text,
        password: _password.text,
        username: _username.text,
      );
      // Account created: close this screen, AuthGate shows Home.
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      _toast(AuthService.friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Sign up',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.brand,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Create an account to share photos and videos.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 28),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(hintText: 'Email'),
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Enter a valid email'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _username,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: 'Username',
                      helperText: '3-20 chars: a-z, 0-9, dot, underscore',
                    ),
                    validator: (v) {
                      final u = (v ?? '').trim().toLowerCase();
                      return AuthService.usernameRegex.hasMatch(u)
                          ? null
                          : 'Invalid username';
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _password,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      hintText: 'Password',
                      suffixIcon: IconButton(
                        icon: Icon(_obscure
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) => (v == null || v.length < 6)
                        ? 'At least 6 characters'
                        : null,
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _loading ? null : _signUp,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Sign up'),
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
EOF

cat > lib/screens/home/home_screen.dart <<'EOF'
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../services/auth_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      const _Placeholder(icon: Icons.home_outlined, label: 'Feed (coming next)'),
      const _Placeholder(icon: Icons.search, label: 'Search (coming soon)'),
      const _Placeholder(
          icon: Icons.add_box_outlined, label: 'New post (coming soon)'),
      const _Placeholder(
          icon: Icons.play_circle_outline, label: 'Reels (coming soon)'),
      const _ProfileTab(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Instantgram',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontStyle: FontStyle.italic,
            color: AppTheme.brand,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
            onPressed: () => AuthService.instance.signOut(),
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(
              icon: Icon(Icons.add_box_outlined), label: 'Post'),
          NavigationDestination(
              icon: Icon(Icons.play_circle_outline), label: 'Reels'),
          NavigationDestination(
              icon: Icon(Icons.person_outline), label: 'Profile'),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: Colors.black26),
          const SizedBox(height: 12),
          Text(label, style: const TextStyle(color: Colors.black54)),
        ],
      ),
    );
  }
}

class _ProfileTab extends StatelessWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final username = data?['username'] ?? user.displayName ?? '...';
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircleAvatar(
                radius: 44,
                backgroundColor: Color(0xFFEFEFEF),
                child: Icon(Icons.person, size: 48, color: Colors.black38),
              ),
              const SizedBox(height: 12),
              Text('@$username',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(user.email ?? '',
                  style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _Stat('Posts', data?['postsCount'] ?? 0),
                  _Stat('Followers', data?['followersCount'] ?? 0),
                  _Stat('Following', data?['followingCount'] ?? 0),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final Object value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        children: [
          Text('$value',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          Text(label, style: const TextStyle(color: Colors.black54)),
        ],
      ),
    );
  }
}
EOF

# The default counter test references MyApp (removed) -> replace with a harmless test
cat > test/widget_test.dart <<'EOF'
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/services/auth_service.dart';

void main() {
  test('username regex accepts valid and rejects invalid names', () {
    expect(AuthService.usernameRegex.hasMatch('aryan.shah_1'), isTrue);
    expect(AuthService.usernameRegex.hasMatch('ab'), isFalse);
    expect(AuthService.usernameRegex.hasMatch('Has Space'), isFalse);
  });
}
EOF
sed -i "s#package:instantgram/#package:${APP_NAME}/#" test/widget_test.dart

echo "==> flutter pub get"
flutter pub get

echo "==> flutter analyze (informational)"
flutter analyze || echo "(analyzer reported issues - send me the output)"

cat <<'DONE'

====================================================
 Setup complete. Next:
   git add .
   git commit -m "Add Firebase auth, signup/login, home skeleton"
   git push
 Then download the APK from the GitHub Actions run.
====================================================
DONE
