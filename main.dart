import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, debugPrint;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'firebase_options.dart'; // created by `flutterfire configure`

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    CloudService.firebaseReady = true;
  } catch (e) {
    // The app still works fully offline if Firebase could not start.
    debugPrint('Firebase init failed: $e');
  }
  runApp(const PurityApp());
}

// ---------------------------------------------------------------------------
// Custom slate color palette (Flutter's Colors class has no slateXXX values)
// ---------------------------------------------------------------------------
class AppColors {
  static const Color slate200 = Color(0xFFE2E8F0);
  static const Color slate300 = Color(0xFFCBD5E1);
  static const Color slate400 = Color(0xFF94A3B8);
  static const Color slate500 = Color(0xFF64748B);
  static const Color slate600 = Color(0xFF475569);
  static const Color slate700 = Color(0xFF334155);
  static const Color slate800 = Color(0xFF1E293B);
  static const Color slate900 = Color(0xFF0F172A);
}

// ---------------------------------------------------------------------------
// History database — one row per day, so the person can always look back
// and see how far they have come.
// ---------------------------------------------------------------------------

// "2026-10-18" style key, used as the primary key of a day.
String dateKey(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

class DailyRecord {
  final String date;
  final int water;
  final int waterGoal;
  final int steps;
  final double weightKg;
  final bool waterHabit;
  final bool mealHabit;
  final bool sleepHabit;

  const DailyRecord({
    required this.date,
    required this.water,
    required this.waterGoal,
    required this.steps,
    required this.weightKg,
    required this.waterHabit,
    required this.mealHabit,
    required this.sleepHabit,
  });

  int get habitsDone =>
      (waterHabit ? 1 : 0) + (mealHabit ? 1 : 0) + (sleepHabit ? 1 : 0);

  // Something was logged on this day.
  bool get isActive => water > 0 || steps > 0 || habitsDone > 0;

  // All three daily habits were ticked.
  bool get isPerfect => habitsDone == 3;

  Map<String, Object?> toMap() => {
        'date': date,
        'water': water,
        'water_goal': waterGoal,
        'steps': steps,
        'weight_kg': weightKg,
        'water_habit': waterHabit ? 1 : 0,
        'meal_habit': mealHabit ? 1 : 0,
        'sleep_habit': sleepHabit ? 1 : 0,
      };

  factory DailyRecord.fromMap(Map<String, Object?> m) => DailyRecord(
        date: m['date'] as String,
        water: (m['water'] as num).toInt(),
        waterGoal: (m['water_goal'] as num).toInt(),
        steps: (m['steps'] as num).toInt(),
        weightKg: (m['weight_kg'] as num).toDouble(),
        waterHabit: m['water_habit'] == 1,
        mealHabit: m['meal_habit'] == 1,
        sleepHabit: m['sleep_habit'] == 1,
      );
}

class HistoryDb {
  HistoryDb._();
  static final HistoryDb instance = HistoryDb._();

  static const _table = 'daily_records';
  static const _jsonKey = 'history_json';

  Database? _db;
  SharedPreferences? _prefs;
  bool ready = false;

  // sqflite works on Android, iOS and macOS. On web / Windows / Linux the
  // same data is kept as JSON inside shared_preferences instead, so the
  // app still works there.
  bool get _useSqlite =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  Future<void> init() async {
    if (ready) return;
    try {
      if (_useSqlite) {
        final dir = await getDatabasesPath();
        _db = await openDatabase(
          '$dir/fitness_history.db',
          version: 1,
          onCreate: (db, version) => db.execute(
            'CREATE TABLE $_table ('
            'date TEXT PRIMARY KEY, '
            'water INTEGER NOT NULL, '
            'water_goal INTEGER NOT NULL, '
            'steps INTEGER NOT NULL, '
            'weight_kg REAL NOT NULL, '
            'water_habit INTEGER NOT NULL, '
            'meal_habit INTEGER NOT NULL, '
            'sleep_habit INTEGER NOT NULL)',
          ),
        );
      } else {
        _prefs = await SharedPreferences.getInstance();
      }
      ready = true;
    } catch (e) {
      debugPrint('HistoryDb init failed: $e');
    }
  }

  // Insert the day's row, or overwrite it if it already exists.
  Future<void> upsert(DailyRecord r) async {
    if (!ready) return;
    try {
      final db = _db;
      if (db != null) {
        await db.insert(
          _table,
          r.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else {
        final all = _readJson();
        all[r.date] = r.toMap();
        await _prefs!.setString(_jsonKey, jsonEncode(all));
      }
    } catch (e) {
      debugPrint('HistoryDb upsert failed: $e');
    }
  }

  // Every saved day, newest first.
  Future<List<DailyRecord>> allRecords() async {
    if (!ready) return [];
    try {
      final db = _db;
      if (db != null) {
        final rows = await db.query(_table, orderBy: 'date DESC');
        return rows.map(DailyRecord.fromMap).toList();
      }
      final list = _readJson()
          .values
          .map((m) => DailyRecord.fromMap(Map<String, Object?>.from(m as Map)))
          .toList();
      list.sort((a, b) => b.date.compareTo(a.date));
      return list;
    } catch (e) {
      debugPrint('HistoryDb read failed: $e');
      return [];
    }
  }

  Map<String, dynamic> _readJson() {
    final raw = _prefs?.getString(_jsonKey);
    if (raw == null) return {};
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }
}

// ---------------------------------------------------------------------------
// Cloud sync — Firebase Auth (login) + Cloud Firestore (database in the cloud).
// The app stays offline-first: everything is saved on the phone first, and
// Firestore is the backup/sync copy. If the internet is down, the app keeps
// working and syncs next time it can.
//
// Firestore layout (each person can only reach their own "users/{uid}"):
//   users/{uid}/records/{2026-10-21}   one document per day
//   users/{uid}/meta/profile           height, weight, age, gender
// ---------------------------------------------------------------------------

class CloudService {
  CloudService._();
  static final CloudService instance = CloudService._();

  static bool firebaseReady = false;
  static const _timeout = Duration(seconds: 8);

  User? get user => firebaseReady ? FirebaseAuth.instance.currentUser : null;
  bool get signedIn => user != null;
  bool get enabled => signedIn;
  String get email => user?.email ?? '';

  DocumentReference<Map<String, dynamic>> get _userDoc =>
      FirebaseFirestore.instance.collection('users').doc(user!.uid);
  CollectionReference<Map<String, dynamic>> get _records =>
      _userDoc.collection('records');
  DocumentReference<Map<String, dynamic>> get _profileDoc =>
      _userDoc.collection('meta').doc('profile');

  // Firebase restores a saved login a moment after start-up; wait for it.
  Future<void> waitForAuth() async {
    if (!firebaseReady) return;
    try {
      await FirebaseAuth.instance.authStateChanges().first.timeout(
            const Duration(seconds: 4),
          );
    } catch (_) {}
  }

  // --- Login -----------------------------------------------------------------
  // Each returns null on success, or a short message to show the person.

  Future<String?> signIn(String email, String password) =>
      _auth(() => FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email.trim(), password: password));

  Future<String?> signUp(String email, String password) =>
      _auth(() => FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email.trim(), password: password));

  Future<String?> signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
      return null;
    } catch (_) {
      return 'Could not sign out.';
    }
  }

  Future<String?> _auth(Future<void> Function() action) async {
    if (!firebaseReady) {
      return 'Firebase is not set up yet (run "flutterfire configure").';
    }
    try {
      await action();
      return null;
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'invalid-email':
          return 'That email address does not look right.';
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential':
          return 'Wrong email or password.';
        case 'email-already-in-use':
          return 'This email already has an account. Try Sign in.';
        case 'weak-password':
          return 'Password is too short (use at least 6 characters).';
        case 'network-request-failed':
          return 'No internet connection.';
        case 'too-many-requests':
          return 'Too many tries. Please wait a bit and try again.';
        default:
          return 'Something went wrong (${e.code}).';
      }
    } catch (_) {
      return 'Something went wrong. Please try again.';
    }
  }

  // --- Data ------------------------------------------------------------------

  static Map<String, Object?> _recordToMap(DailyRecord r) => {
        'date': r.date,
        'water': r.water,
        'waterGoal': r.waterGoal,
        'steps': r.steps,
        'weightKg': r.weightKg,
        'waterHabit': r.waterHabit,
        'mealHabit': r.mealHabit,
        'sleepHabit': r.sleepHabit,
      };

  static DailyRecord _recordFromMap(Map<String, dynamic> m) => DailyRecord(
        date: m['date'] as String,
        water: (m['water'] as num).toInt(),
        waterGoal: (m['waterGoal'] as num).toInt(),
        steps: (m['steps'] as num).toInt(),
        weightKg: (m['weightKg'] as num).toDouble(),
        waterHabit: m['waterHabit'] == true,
        mealHabit: m['mealHabit'] == true,
        sleepHabit: m['sleepHabit'] == true,
      );

  // Can we reach the cloud right now? (a real read from the server)
  Future<bool> ping() async {
    if (!enabled) return false;
    try {
      await _profileDoc
          .get(const GetOptions(source: Source.server))
          .timeout(_timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  // Save one day. Offline, Firestore keeps the write and sends it later —
  // the timeout only stops the app from waiting for it.
  Future<bool> putRecord(DailyRecord r) async {
    if (!enabled) return false;
    try {
      await _records.doc(r.date).set(_recordToMap(r)).timeout(_timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  // Save many days (Firestore allows up to 500 writes per batch).
  Future<bool> pushAll(List<DailyRecord> records) async {
    if (!enabled) return false;
    if (records.isEmpty) return true;
    try {
      for (var i = 0; i < records.length; i += 400) {
        final batch = FirebaseFirestore.instance.batch();
        for (final r in records.skip(i).take(400)) {
          batch.set(_records.doc(r.date), _recordToMap(r));
        }
        await batch.commit().timeout(_timeout);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<DailyRecord>?> fetchRecords() async {
    if (!enabled) return null;
    try {
      final snap = await _records
          .get(const GetOptions(source: Source.server))
          .timeout(_timeout);
      return snap.docs.map((d) => _recordFromMap(d.data())).toList();
    } catch (_) {
      return null;
    }
  }

  Future<bool> putProfile({
    required double heightCm,
    required double weightKg,
    required int age,
    required int gender,
  }) async {
    if (!enabled) return false;
    try {
      await _profileDoc.set({
        'heightCm': heightCm,
        'weightKg': weightKg,
        'age': age,
        'gender': gender,
      }).timeout(_timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  // null if nothing saved yet or the cloud cannot be reached
  Future<Map<String, dynamic>?> getProfile() async {
    if (!enabled) return null;
    try {
      final doc = await _profileDoc
          .get(const GetOptions(source: Source.server))
          .timeout(_timeout);
      return doc.data();
    } catch (_) {
      return null;
    }
  }
}

class PurityApp extends StatefulWidget {
  const PurityApp({super.key});

  @override
  State<PurityApp> createState() => _PurityAppState();
}

class _PurityAppState extends State<PurityApp> {
  // Theme state
  AppThemePalette _currentPalette = AppThemePalette.emeraldGlow;

  void _updateTheme(AppThemePalette palette) {
    setState(() {
      _currentPalette = palette;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fitness Tracker - Good Food, Good Mood',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: _currentPalette.isDark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: 'Roboto',
        colorSchemeSeed: _currentPalette.primaryColor,
      ),
      home: DashboardScreen(
        currentPalette: _currentPalette,
        onThemeChanged: _updateTheme,
      ),
    );
  }
}

enum AppThemePalette {
  emeraldGlow(
    name: 'Emerald Glow',
    primaryColor: Color(0xFF059669),
    secondaryColor: Color(0xFF0D9488),
    accentColor: Color(0xFF06B6D4),
    bgGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFE0F2FE), Color(0xFFF0FDF4)],
    ),
    cardBg: Color(0xD9FFFFFF),
    isDark: false,
  ),
  softSky(
    name: 'Soft Sky',
    primaryColor: Color(0xFF0284C7),
    secondaryColor: Color(0xFF0D9488),
    accentColor: Color(0xFF10B981),
    bgGradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFE0F2FE), Color(0xFFF8FAFC)],
    ),
    cardBg: Color(0xEBFFFFFF),
    isDark: false,
  ),
  modernDark(
    name: 'Modern Slate',
    primaryColor: Color(0xFF10B981),
    secondaryColor: Color(0xFF14B8A6),
    accentColor: Color(0xFF38BDF8),
    bgGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
    ),
    cardBg: Color(0xD91E293B),
    isDark: true,
  );

  final String name;
  final Color primaryColor;
  final Color secondaryColor;
  final Color accentColor;
  final Gradient bgGradient;
  final Color cardBg;
  final bool isDark;

  const AppThemePalette({
    required this.name,
    required this.primaryColor,
    required this.secondaryColor,
    required this.accentColor,
    required this.bgGradient,
    required this.cardBg,
    required this.isDark,
  });
}

class DashboardScreen extends StatefulWidget {
  final AppThemePalette currentPalette;
  final ValueChanged<AppThemePalette> onThemeChanged;

  const DashboardScreen({
    super.key,
    required this.currentPalette,
    required this.onThemeChanged,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

enum Gender { male, female, other }

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  // Water Tracker State
  int _currentWater = 0;

  // Steps Tracker State (manually added, like Water)
  int _currentSteps = 0;
  final int _targetSteps = 10000;

  // Profile / Body Stats State (user-editable, drives BMI & personalised goals)
  double _heightCm = 168;
  double _weightKg = 63;
  int _age = 25;
  Gender _gender = Gender.male;

  // Daily Habits State
  bool _waterHabitChecked = false;
  bool _cleanMealHabitChecked = false;
  bool _sleepHabitChecked = false;

  // --- Persistence (so data survives closing/reopening the app) ----------

  SharedPreferences? _prefs;
  bool _isLoaded = false;
  bool _online = false; // was the API reachable on the last try?
  bool _hadLocalProfile = true; // false on a brand-new install
  // Until the first sync attempt is over, today's row is not sent to the
  // server (a fresh install would otherwise overwrite the server's copy
  // with zeros before it could be restored).
  bool _syncReady = false;

  Timer? _dayTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
    // If the app stays open past midnight, start the new day automatically.
    _dayTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_isLoaded) _rolloverIfNewDay();
    });
  }

  @override
  void dispose() {
    _dayTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app on a new day → start fresh for today.
    if (state == AppLifecycleState.resumed && _isLoaded) {
      _rolloverIfNewDay();
      _syncWithServer();
    }
  }

  Future<void> _loadData() async {
    await HistoryDb.instance.init();
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
        _hadLocalProfile = prefs.containsKey('heightCm');
    setState(() {
      _currentWater = prefs.getInt('currentWater') ?? 0;
      _currentSteps = prefs.getInt('currentSteps') ?? 0;
      _heightCm = prefs.getDouble('heightCm') ?? 168;
      _weightKg = prefs.getDouble('weightKg') ?? 63;
      _age = prefs.getInt('age') ?? 25;
      _gender = Gender.values[prefs.getInt('gender') ?? 0];
      _waterHabitChecked = prefs.getBool('waterHabitChecked') ?? false;
      _cleanMealHabitChecked = prefs.getBool('cleanMealHabitChecked') ?? false;
      _sleepHabitChecked = prefs.getBool('sleepHabitChecked') ?? false;
      _isLoaded = true;
    });
    await _rolloverIfNewDay();
    await CloudService.instance.waitForAuth();
    if (mounted) setState(() {}); // refresh the cloud icon
    _syncWithServer(); // in the background — the screen does not wait for it
  }

  // Fire-and-forget save — called after every change so nothing is lost
  // even if the person switches apps or closes this one immediately after.
  void _saveData() {
    final prefs = _prefs;
    if (prefs == null) return;
    prefs.setInt('currentWater', _currentWater);
    prefs.setInt('currentSteps', _currentSteps);
    prefs.setDouble('heightCm', _heightCm);
    prefs.setDouble('weightKg', _weightKg);
    prefs.setInt('age', _age);
    prefs.setInt('gender', _gender.index);
    prefs.setBool('waterHabitChecked', _waterHabitChecked);
    prefs.setBool('cleanMealHabitChecked', _cleanMealHabitChecked);
    prefs.setBool('sleepHabitChecked', _sleepHabitChecked);
    _saveToHistory();
  }

  // --- History (one database row per day) ----------------------------------

  DailyRecord _currentRecord(String date) => DailyRecord(
        date: date,
        water: _currentWater,
        waterGoal: _targetWater,
        steps: _currentSteps,
        weightKg: _weightKg,
        waterHabit: _waterHabitChecked,
        mealHabit: _cleanMealHabitChecked,
        sleepHabit: _sleepHabitChecked,
      );

  // Writes today's numbers into the database. The row is keyed by the day
  // currently being tracked, so a late-night tap can never land on the
  // wrong day.
  void _saveToHistory() {
    final date = _prefs?.getString('lastDate') ?? dateKey(DateTime.now());
    final record = _currentRecord(date);
    HistoryDb.instance.upsert(record);
    // Also send it to the API. If that fails the row is still safe on the
    // phone and gets sent with the next sync.
    if (_syncReady) {
      CloudService.instance.putRecord(record).then((ok) {
        if (mounted && ok != _online) setState(() => _online = ok);
      });
    }
  }

  // --- API sync -----------------------------------------------------------

  // Two-way sync with the server:
  //  1. a brand-new phone gets its profile (and today's numbers) back
  //  2. days that exist only on the server are copied to the phone
  //  3. every day on the phone is sent to the server
  Future<void> _syncWithServer() async {
    final api = CloudService.instance;
    final prefs = _prefs;
    if (prefs == null) return;

    if (!api.enabled || !await api.ping()) {
      _syncReady = true;
      if (mounted) setState(() => _online = false);
      return;
    }

    // 1. profile — only if this phone has never saved one
    if (!_hadLocalProfile) {
      _hadLocalProfile = true;
      final p = await api.getProfile();
      if (p != null && mounted) {
        setState(() {
          _heightCm = (p['heightCm'] as num).toDouble();
          _weightKg = (p['weightKg'] as num).toDouble();
          _age = (p['age'] as num).toInt();
          _gender = Gender.values[(p['gender'] as num).toInt().clamp(0, 2)];
        });
        _saveData();
      }
    }

    // 2. history
    final remote = await api.fetchRecords();
    var local = await HistoryDb.instance.allRecords();
    if (remote != null) {
      final have = local.map((r) => r.date).toSet();
      for (final r in remote) {
        if (!have.contains(r.date)) await HistoryDb.instance.upsert(r);
      }

      // Fresh install, same day: take back today's numbers from the server
      // instead of overwriting them with zeros.
      final today = prefs.getString('lastDate');
      final nothingLoggedHere =
          _currentWater == 0 && _currentSteps == 0 && !_waterHabitChecked &&
              !_cleanMealHabitChecked && !_sleepHabitChecked;
      final serverToday = remote.where((r) => r.date == today).firstOrNull;
      if (nothingLoggedHere && serverToday != null && serverToday.isActive) {
        if (mounted) {
          setState(() {
            _currentWater = serverToday.water;
            _currentSteps = serverToday.steps;
            _waterHabitChecked = serverToday.waterHabit;
            _cleanMealHabitChecked = serverToday.mealHabit;
            _sleepHabitChecked = serverToday.sleepHabit;
          });
        }
        _saveData();
      }
      local = await HistoryDb.instance.allRecords();
    }

    // 3. send everything on the phone to the server
    final pushed = await api.pushAll(local);
    await api.putProfile(
      heightCm: _heightCm,
      weightKg: _weightKg,
      age: _age,
      gender: _gender.index,
    );
    _syncReady = true;
    if (mounted) setState(() => _online = pushed);
  }

  void _pushProfile() {
    CloudService.instance.putProfile(
      heightCm: _heightCm,
      weightKg: _weightKg,
      age: _age,
      gender: _gender.index,
    );
  }

  // Sign in / create account / sign out, so the data is backed up in the
  // cloud and can be restored on a new phone.
  void _showAccountDialog(AppThemePalette palette) {
    final emailC = TextEditingController();
    final passC = TextEditingController();
    String? status;
    var busy = false;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final cloud = CloudService.instance;
            final signedIn = cloud.signedIn;
            final titleColor = palette.isDark ? Colors.white : AppColors.slate900;
            final mutedColor =
                palette.isDark ? AppColors.slate400 : AppColors.slate600;

            // Runs a login action; closes the dialog and syncs on success.
            Future<void> run(Future<String?> Function() action) async {
              setDialogState(() {
                busy = true;
                status = null;
              });
              final err = await action();
              if (!dialogContext.mounted) return;
              if (err == null) {
                Navigator.of(dialogContext).pop();
                if (mounted) setState(() {});
                _syncWithServer();
              } else {
                setDialogState(() {
                  busy = false;
                  status = err;
                });
              }
            }

            InputDecoration deco(String label, IconData icon) => InputDecoration(
                  labelText: label,
                  prefixIcon:
                      Icon(icon, size: 20, color: palette.primaryColor),
                  filled: true,
                  fillColor:
                      palette.isDark ? AppColors.slate700 : AppColors.slate200,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                );

            return AlertDialog(
              backgroundColor: palette.isDark ? AppColors.slate800 : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(
                children: [
                  Icon(Icons.cloud_sync_outlined, color: palette.primaryColor),
                  const SizedBox(width: 8),
                  Text(
                    signedIn ? 'Your account' : 'Sign in to back up',
                    style: TextStyle(
                      color: titleColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (signedIn) ...[
                      Text(
                        'Signed in as ${cloud.email}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: titleColor,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _online
                            ? '✅ Your data is backed up.'
                            : '⚠️ Cannot reach the cloud right now. Your data is safe on this phone and will upload when the internet is back.',
                        style: TextStyle(fontSize: 12, color: mutedColor),
                      ),
                    ] else ...[
                      Text(
                        'Your data is always saved on this phone. Sign in to also back it up '
                        'and get it back on a new phone.',
                        style: TextStyle(fontSize: 12, color: mutedColor),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: emailC,
                        keyboardType: TextInputType.emailAddress,
                        style: TextStyle(color: titleColor),
                        decoration: deco('Email', Icons.email_outlined),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: passC,
                        obscureText: true,
                        style: TextStyle(color: titleColor),
                        decoration: deco('Password', Icons.lock_outline),
                      ),
                    ],
                    if (busy) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(color: palette.primaryColor),
                    ],
                    if (status != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        status!,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.red.shade400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Close'),
                ),
                if (signedIn) ...[
                  TextButton(
                    onPressed: busy ? null : () => run(cloud.signOut),
                    child: const Text('Sign out'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: palette.primaryColor,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: busy ? null : () => run(() async => null),
                    child: const Text('Sync now'),
                  ),
                ] else ...[
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => run(() => cloud.signUp(emailC.text, passC.text)),
                    child: const Text('Create account'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: palette.primaryColor,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: busy
                        ? null
                        : () => run(() => cloud.signIn(emailC.text, passC.text)),
                    child: const Text('Sign in'),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  // When a new calendar day starts: store yesterday's final numbers in the
  // database, then reset the daily counters (water, steps, habit ticks).
  Future<void> _rolloverIfNewDay() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final today = dateKey(DateTime.now());
    final last = prefs.getString('lastDate');
    if (last == today) return;
    // Device clock moved backwards — don't wipe anything.
    if (last != null && last.compareTo(today) > 0) return;

    if (last != null) {
      await HistoryDb.instance.upsert(_currentRecord(last));
      if (!mounted) return;
      setState(() {
        _currentWater = 0;
        _currentSteps = 0;
        _waterHabitChecked = false;
        _cleanMealHabitChecked = false;
        _sleepHabitChecked = false;
      });
    }
    // First run after this update: today's existing numbers are kept and
    // simply become today's first history row.
    await prefs.setString('lastDate', today);
    _saveData();
  }

  // --- Derived / personalised metrics -------------------------------------

  double get _bmi {
    final heightM = _heightCm / 100;
    if (heightM <= 0) return 0;
    return _weightKg / (heightM * heightM);
  }

  // Recommended daily water intake, roughly 33 ml per kg of body weight,
  // rounded to the nearest 50 ml so the UI shows a clean number.
  int get _targetWater {
    final raw = _weightKg * 33;
    return (raw / 50).round() * 50;
  }

  ({String label, Color color}) _bmiCategory(AppThemePalette palette) {
    final bmi = _bmi;
    if (bmi <= 0) {
      return (label: '—', color: AppColors.slate500);
    } else if (bmi < 18.5) {
      return (label: 'Underweight', color: Colors.orange.shade700);
    } else if (bmi < 25) {
      return (label: 'Normal', color: palette.primaryColor);
    } else if (bmi < 30) {
      return (label: 'Overweight', color: Colors.orange.shade800);
    } else {
      return (label: 'Obese', color: Colors.red.shade700);
    }
  }

  // One-line, BMI-aware tip so the plan feels tailored to the user.
  String _bmiTip() {
    final bmi = _bmi;
    if (bmi <= 0) {
      return 'Set your height & weight in Profile to personalise your plan.';
    } else if (bmi < 18.5) {
      return 'Focus on calorie-dense clean meals to reach a healthy weight.';
    } else if (bmi < 25) {
      return 'Great balance — keep maintaining your current habits.';
    } else if (bmi < 30) {
      return 'Slightly above range — a bit more activity & portion control will help.';
    } else {
      return 'Consider consulting a nutritionist alongside this plan for best results.';
    }
  }

  void _addWater(int amount) {
    setState(() {
      _currentWater += amount;
      if (_currentWater > _targetWater) {
        _currentWater = _targetWater;
      }
      // Auto-check water habit when goal reached
      if (_currentWater >= _targetWater) {
        _waterHabitChecked = true;
      }
    });
    _saveData();
  }

  void _addSteps(int amount) {
    setState(() {
      _currentSteps += amount;
      if (_currentSteps > _targetSteps) {
        _currentSteps = _targetSteps;
      }
    });
    _saveData();
  }

  void _resetSteps() {
    setState(() {
      _currentSteps = 0;
    });
    _saveData();
  }

  // Opens the Profile / Body Stats editor so any user (any BMI) can tailor
  // the app to their own height & weight.
  void _showProfileDialog(AppThemePalette palette) {
    final heightController =
        TextEditingController(text: _heightCm.toStringAsFixed(0));
    final weightController =
        TextEditingController(text: _weightKg.toStringAsFixed(0));
    final ageController = TextEditingController(text: _age.toString());
    Gender selectedGender = _gender;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              backgroundColor: palette.isDark ? AppColors.slate800 : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Row(
                children: [
                  Icon(Icons.person_outline, color: palette.primaryColor),
                  const SizedBox(width: 8),
                  Text(
                    'Profile & Body Stats',
                    style: TextStyle(
                      color: palette.isDark ? Colors.white : AppColors.slate900,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Enter your details — the app will personalise BMI, water goal & tips for you.',
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.isDark ? AppColors.slate400 : AppColors.slate600,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _profileTextField(
                      controller: heightController,
                      label: 'Height (cm)',
                      icon: Icons.height,
                      palette: palette,
                    ),
                    const SizedBox(height: 12),
                    _profileTextField(
                      controller: weightController,
                      label: 'Weight (kg)',
                      icon: Icons.monitor_weight_outlined,
                      palette: palette,
                    ),
                    const SizedBox(height: 12),
                    _profileTextField(
                      controller: ageController,
                      label: 'Age',
                      icon: Icons.cake_outlined,
                      palette: palette,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Gender',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: palette.isDark ? AppColors.slate300 : AppColors.slate700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: Gender.values.map((g) {
                        final isSelected = selectedGender == g;
                        return ChoiceChip(
                          label: Text(
                            g.name[0].toUpperCase() + g.name.substring(1),
                            style: TextStyle(
                              fontSize: 12,
                              color: isSelected
                                  ? Colors.white
                                  : (palette.isDark
                                      ? AppColors.slate300
                                      : AppColors.slate700),
                            ),
                          ),
                          selected: isSelected,
                          selectedColor: palette.primaryColor,
                          backgroundColor: palette.isDark
                              ? AppColors.slate700
                              : AppColors.slate200,
                          onSelected: (_) {
                            setDialogState(() => selectedGender = g);
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: palette.primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () {
                    final newHeight =
                        double.tryParse(heightController.text) ?? _heightCm;
                    final newWeight =
                        double.tryParse(weightController.text) ?? _weightKg;
                    final newAge = int.tryParse(ageController.text) ?? _age;
                    setState(() {
                      _heightCm = newHeight.clamp(100, 250);
                      _weightKg = newWeight.clamp(30, 250);
                      _age = newAge.clamp(10, 100);
                      _gender = selectedGender;
                      // Keep current water progress in range of the new goal.
                      if (_currentWater > _targetWater) {
                        _currentWater = _targetWater;
                      }
                    });
                    _saveData();
                    _pushProfile();
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _profileTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required AppThemePalette palette,
  }) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: false),
      style: TextStyle(
        color: palette.isDark ? Colors.white : AppColors.slate900,
      ),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20, color: palette.primaryColor),
        filled: true,
        fillColor: palette.isDark ? AppColors.slate700 : AppColors.slate200,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.currentPalette;
    final isDark = palette.isDark;

    if (!_isLoaded) {
      return Container(
        decoration: BoxDecoration(gradient: palette.bgGradient),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(
            child: CircularProgressIndicator(color: palette.primaryColor),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(gradient: palette.bgGradient),
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [palette.primaryColor, palette.secondaryColor],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'F',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShaderMask(
                    shaderCallback: (bounds) => LinearGradient(
                      colors: [palette.primaryColor, palette.accentColor],
                    ).createShader(bounds),
                    child: const Text(
                      'Fitness Tracker',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Text(
                    'Eat Clean, Stay Lean',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? AppColors.slate300 : AppColors.slate600,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: _online ? 'Backed up to your account' : 'Sign in / back up',
              icon: Icon(
                _online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                color: _online
                    ? palette.primaryColor
                    : (isDark ? AppColors.slate400 : AppColors.slate500),
              ),
              onPressed: () => _showAccountDialog(palette),
            ),
            IconButton(
              tooltip: 'My Progress & History',
              icon: Icon(
                Icons.insights_outlined,
                color: isDark ? Colors.white : AppColors.slate800,
              ),
              onPressed: () => _openHistory(palette),
            ),
            IconButton(
              tooltip: 'Profile & Body Stats',
              icon: Icon(
                Icons.person_outline,
                color: isDark ? Colors.white : AppColors.slate800,
              ),
              onPressed: () => _showProfileDialog(palette),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: PopupMenuButton<AppThemePalette>(
                icon: Icon(
                  Icons.palette_outlined,
                  color: isDark ? Colors.white : AppColors.slate800,
                ),
                onSelected: widget.onThemeChanged,
                itemBuilder: (context) => AppThemePalette.values.map((p) {
                  return PopupMenuItem(
                    value: p,
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 8,
                          backgroundColor: p.primaryColor,
                        ),
                        const SizedBox(width: 8),
                        Text(p.name),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          physics: const BouncingScrollPhysics(),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildGlassCard(
                    palette: palette,
                    child: Row(
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [palette.primaryColor, palette.accentColor],
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Center(
                            child: Text(
                              'F',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 32,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: palette.primaryColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  'Clean Lifestyle Assistant',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: palette.primaryColor,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Welcome to Fitness Tracker',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white : AppColors.slate800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Good Food Good Mood',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark ? AppColors.slate300 : AppColors.slate600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth > 600) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _buildWaterCard(palette)),
                            const SizedBox(width: 12),
                            Expanded(child: _buildStepsCard(palette)),
                            const SizedBox(width: 12),
                            Expanded(child: _buildBmiCard(palette)),
                          ],
                        );
                      } else {
                        return Column(
                          children: [
                            _buildWaterCard(palette),
                            const SizedBox(height: 12),
                            _buildStepsCard(palette),
                            const SizedBox(height: 12),
                            _buildBmiCard(palette),
                          ],
                        );
                      }
                    },
                  ),

                  const SizedBox(height: 16),

                  _buildHistoryCard(palette),

                  const SizedBox(height: 16),

                  _buildHabitsCard(palette),

                  const SizedBox(height: 16),

                  _buildNutritionPlan(palette),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Reusable Glass Card Wrapper
  Widget _buildGlassCard({
    required AppThemePalette palette,
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: palette.isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.white.withValues(alpha: 0.6),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  void _openHistory(AppThemePalette palette) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HistoryScreen(
          palette: palette,
          targetSteps: _targetSteps,
        ),
      ),
    );
  }

  // Tap-through card that opens the Progress & History screen
  Widget _buildHistoryCard(AppThemePalette palette) {
    final isDark = palette.isDark;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openHistory(palette),
      child: _buildGlassCard(
        palette: palette,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [palette.primaryColor, palette.accentColor],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.insights, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'My Progress & History',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : AppColors.slate900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'See your streak, weekly improvement & every past day.',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? AppColors.slate400 : AppColors.slate600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: isDark ? AppColors.slate400 : AppColors.slate500,
            ),
          ],
        ),
      ),
    );
  }

  // Water Tracker Card
  Widget _buildWaterCard(AppThemePalette palette) {
    final double waterProgress = (_currentWater / _targetWater).clamp(0.0, 1.0);

    return _buildGlassCard(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Water Goal',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: palette.isDark ? AppColors.slate300 : AppColors.slate700,
                ),
              ),
              const Icon(Icons.water_drop, color: Colors.cyan, size: 22),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$_currentWater',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: palette.isDark ? Colors.white : AppColors.slate900,
                ),
              ),
              Text(
                ' / $_targetWater ml',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: waterProgress,
              minHeight: 8,
              backgroundColor: palette.isDark ? AppColors.slate700 : AppColors.slate200,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.cyan),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _addWater(250),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              icon: const Icon(Icons.add, size: 16),
              label: const Text(
                'Add 250 ml',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Steps Counter Card — manually added by the person, same pattern as Water
  Widget _buildStepsCard(AppThemePalette palette) {
    final double stepsProgress = (_currentSteps / _targetSteps).clamp(0.0, 1.0);
    // Rough calorie estimate personalised by the user's own weight
    // (~0.00057 kcal per step per kg of body weight).
    final int kcalBurned = (_currentSteps * _weightKg * 0.00057).round();

    return _buildGlassCard(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Daily Steps',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: palette.isDark ? AppColors.slate300 : AppColors.slate700,
                ),
              ),
              Row(
                children: [
                  Icon(Icons.directions_walk, color: palette.primaryColor, size: 22),
                  IconButton(
                    tooltip: 'Reset steps',
                    onPressed: _resetSteps,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      Icons.refresh,
                      size: 16,
                      color: palette.isDark ? AppColors.slate400 : AppColors.slate500,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$_currentSteps',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: palette.isDark ? Colors.white : AppColors.slate900,
                ),
              ),
              Text(
                ' / $_targetSteps',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: stepsProgress,
              minHeight: 8,
              backgroundColor: palette.isDark ? AppColors.slate700 : AppColors.slate200,
              valueColor: AlwaysStoppedAnimation<Color>(palette.primaryColor),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '🔥 $kcalBurned kcal burned today',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: palette.isDark ? AppColors.slate400 : AppColors.slate600,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _addSteps(500),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: palette.primaryColor,
                    side: BorderSide(color: palette.primaryColor.withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text(
                    '+500',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _addSteps(1000),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: palette.primaryColor,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text(
                    '+1000',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // BMI Card — fully driven by the user's own height/weight from Profile,
  // so any body type (underweight, normal, overweight, obese) is reflected.
  Widget _buildBmiCard(AppThemePalette palette) {
    final category = _bmiCategory(palette);

    return _buildGlassCard(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Body Stats',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: palette.isDark ? AppColors.slate300 : AppColors.slate700,
                ),
              ),
              InkWell(
                onTap: () => _showProfileDialog(palette),
                borderRadius: BorderRadius.circular(20),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.edit_outlined, color: Colors.indigo, size: 20),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                _bmi.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: palette.isDark ? Colors.white : AppColors.slate900,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: category.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  category.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: category.color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Height: ${_heightCm.toStringAsFixed(0)} cm | Weight: ${_weightKg.toStringAsFixed(0)} kg',
            style: TextStyle(
              fontSize: 12,
              color: palette.isDark ? AppColors.slate400 : AppColors.slate600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _bmiTip(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: palette.isDark ? AppColors.slate300 : AppColors.slate600,
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // Daily Habits Checklist Widget
  Widget _buildHabitsCard(AppThemePalette palette) {
    return _buildGlassCard(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined, color: palette.primaryColor, size: 20),
              const SizedBox(width: 8),
              Text(
                'Daily Healthy Habits',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: palette.isDark ? Colors.white : AppColors.slate900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildHabitTile(
            title:
                'Drink 3.5 Liters Water (${(_currentWater / 1000).toStringAsFixed(1)}L reached)',
            value: _waterHabitChecked,
            onChanged: (val) {
              setState(() => _waterHabitChecked = val ?? false);
              _saveData();
            },
            palette: palette,
          ),
          _buildHabitTile(
            title: 'Eat Clean Meal (No Junk Food)',
            value: _cleanMealHabitChecked,
            onChanged: (val) {
              setState(() => _cleanMealHabitChecked = val ?? false);
              _saveData();
            },
            palette: palette,
          ),
          _buildHabitTile(
            title: '7-8 Hours Healthy Sleep',
            value: _sleepHabitChecked,
            onChanged: (val) {
              setState(() => _sleepHabitChecked = val ?? false);
              _saveData();
            },
            palette: palette,
          ),
        ],
      ),
    );
  }

  Widget _buildHabitTile({
    required String title,
    required bool value,
    required ValueChanged<bool?> onChanged,
    required AppThemePalette palette,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: palette.isDark
            ? AppColors.slate800.withValues(alpha: 0.5)
            : Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      // Material sits above the coloured Container so the tile's ink effect
      // is painted on top of it (removes the "ink splashes may be invisible" warning).
      child: Material(
        type: MaterialType.transparency,
        child: CheckboxListTile(
        title: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            decoration: value ? TextDecoration.lineThrough : null,
            color: value
                ? Colors.grey
                : (palette.isDark ? AppColors.slate200 : AppColors.slate800),
          ),
        ),
        value: value,
        activeColor: palette.primaryColor,
        onChanged: onChanged,
        controlAffinity: ListTileControlAffinity.leading,
        dense: true,
        ),
      ),
    );
  }

  // Bengali Nutrition Plan Widget
  Widget _buildNutritionPlan(AppThemePalette palette) {
    return _buildGlassCard(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.restaurant, color: palette.primaryColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Precision Nutrition Plan',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: palette.isDark ? Colors.white : AppColors.slate900,
                      ),
                    ),
                    Text(
                      'Authentic Bengali meal planning with explicit Macros (P|C|F) & swappable alternatives.',
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.isDark ? AppColors.slate400 : AppColors.slate600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildMealItem(
            title: '🌅 Breakfast (8:00 AM - 8:30 AM)',
            macros: '~380 kcal | P: 18g | C: 45g | F: 10g',
            titleColor: palette.primaryColor,
            description: '২ টি পাতলা আটার রুটি + ১টি সিদ্ধ ডিম + ১ কাপ পেঁপে/সবজি ভাজি (কম তেলে)।',
            alternative: '১ কাপ চিড়া ও আধা কাপ টক দই + ১টি কলা অথবা ৫০ গ্রাম ওটস খিচুড়ি।',
            palette: palette,
          ),
          const SizedBox(height: 12),
          _buildMealItem(
            title: '🍛 Lunch (1:00 PM - 1:30 PM)',
            macros: '~520 kcal | P: 30g | C: 65g | F: 12g',
            titleColor: palette.secondaryColor,
            description:
                '১ কাপ লাল চালের ভাত + ১ টুকরা মাছ/মুরগি (কম তেলে রান্না) + ১ কাপ মিক্সড সবজি + ডাল ও সালাদ।',
            alternative: '২ টি আটার রুটি + মুরগির/সয়াবিনের ঝোল তরকারি + শসা-টমেটো সালাদ।',
            palette: palette,
          ),
          const SizedBox(height: 12),
          _buildMealItem(
            title: '🍎 Evening Snacks (5:00 PM - 5:30 PM)',
            macros: '~210 kcal | P: 8g | C: 30g | F: 4g',
            titleColor: palette.secondaryColor,
            description: 'সিদ্ধ ছোলা চাট (৫০ গ্রাম ছোলা, শসা, টমেটো, লেবুর রস ও মুড়ি)।',
            alternative: '১টি পেয়ারা/আপেল + এক মুঠ বাদাম (কাঠবাদাম/চীনাবাদাম)।',
            palette: palette,
          ),
          const SizedBox(height: 12),
          _buildMealItem(
            title: '🌙 Dinner (8:30 PM - 9:00 PM)',
            macros: '~420 kcal | P: 26g | C: 50g | F: 9g',
            titleColor: palette.accentColor,
            description:
                '১ কাপ লাল চালের ভাত + ১ টুকরা রুই/কাতলা মাছের পাতলা ঝোল + ১ কাপ ঘন ডাল ও সালাদ।',
            alternative: '২ টি আটার রুটি + ১০০ গ্রাম পাতলা মসলা মুরগির মাংসের তরকারি।',
            palette: palette,
          ),
        ],
      ),
    );
  }

  Widget _buildMealItem({
    required String title,
    required String macros,
    required Color titleColor,
    required String description,
    required String alternative,
    required AppThemePalette palette,
  }) {
    final isDark = palette.isDark;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppColors.slate800.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? AppColors.slate700 : AppColors.slate200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: titleColor,
                  ),
                ),
              ),
              Text(
                macros,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppColors.slate400 : AppColors.slate500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: isDark ? AppColors.slate200 : AppColors.slate800,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isDark ? Colors.amber.shade900.withValues(alpha: 0.3) : Colors.amber.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isDark ? Colors.amber.shade800.withValues(alpha: 0.4) : Colors.amber.shade200,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.swap_horiz_rounded,
                  size: 16,
                  color: isDark ? Colors.amber.shade200 : Colors.amber.shade900,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Alternative: $alternative',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.amber.shade200 : Colors.amber.shade900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// My Progress & History screen — reads the saved days from the database and
// shows how the person is improving over time.
// ---------------------------------------------------------------------------

// 12500 → "12,500"
String _thousands(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

// 7500 → "7.5k", 10000 → "10k"
String _compact(int v) {
  if (v < 1000) return '$v';
  final k = v / 1000;
  final decimals = k == k.roundToDouble() ? 0 : 1;
  return '${k.toStringAsFixed(decimals)}k';
}

DateTime _todayUtc() {
  final n = DateTime.now();
  return DateTime.utc(n.year, n.month, n.day);
}

DateTime _parseDateKey(String key) {
  final p = key.split('-');
  return DateTime.utc(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

enum _ChartMetric { steps, water }

class HistoryScreen extends StatefulWidget {
  final AppThemePalette palette;
  final int targetSteps;

  const HistoryScreen({
    super.key,
    required this.palette,
    required this.targetSteps,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  List<DailyRecord>? _records; // newest first
  _ChartMetric _metric = _ChartMetric.steps;

  AppThemePalette get _p => widget.palette;
  bool get _isDark => _p.isDark;
  Color get _titleColor => _isDark ? Colors.white : AppColors.slate900;
  Color get _bodyColor => _isDark ? AppColors.slate300 : AppColors.slate700;
  Color get _mutedColor => _isDark ? AppColors.slate400 : AppColors.slate600;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await HistoryDb.instance.allRecords();
    if (!mounted) return;
    setState(() => _records = list);
  }

  // --- Calculations --------------------------------------------------------

  // Days in a row (ending today — or yesterday, if today is still empty) on
  // which something was logged.
  int _currentStreak(Map<String, DailyRecord> byDate) {
    var day = _todayUtc();
    if (!(byDate[dateKey(day)]?.isActive ?? false)) {
      day = day.subtract(const Duration(days: 1));
    }
    var streak = 0;
    while (byDate[dateKey(day)]?.isActive ?? false) {
      streak++;
      day = day.subtract(const Duration(days: 1));
    }
    return streak;
  }

  int _bestStreak(List<DailyRecord> records) {
    final days = records
        .where((r) => r.isActive)
        .map((r) => _parseDateKey(r.date))
        .toList()
      ..sort();
    var best = 0;
    var run = 0;
    DateTime? prev;
    for (final d in days) {
      if (prev != null && d.difference(prev).inDays == 1) {
        run++;
      } else {
        run = 1;
      }
      if (run > best) best = run;
      prev = d;
    }
    return best;
  }

  // Average per logged day over the 7 days that begin `newestAgo` days ago.
  // Today is left out of the weekly comparison because it is still in
  // progress (a half-finished day would unfairly pull the average down).
  double? _weekAvg(
    Map<String, DailyRecord> byDate,
    int newestAgo,
    num Function(DailyRecord) pick,
  ) {
    final today = _todayUtc();
    var total = 0.0;
    var count = 0;
    for (var i = newestAgo; i < newestAgo + 7; i++) {
      final r = byDate[dateKey(today.subtract(Duration(days: i)))];
      if (r != null && pick(r) > 0) {
        total += pick(r);
        count++;
      }
    }
    return count == 0 ? null : total / count;
  }

  double? _pctChange(double? now, double? prev) {
    if (now == null || prev == null || prev <= 0) return null;
    return (now - prev) / prev * 100;
  }

  String _dayLabel(String key) {
    final d = _parseDateKey(key);
    final today = _todayUtc();
    if (d == today) return 'Today';
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';
  }

  String _shortDate(String key) {
    final d = _parseDateKey(key);
    return '${d.day} ${_months[d.month - 1]}';
  }

  // --- Small building blocks ----------------------------------------------

  Widget _card({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: _p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.white.withValues(alpha: 0.6),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _sectionTitle(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: _p.primaryColor, size: 20),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: _titleColor,
          ),
        ),
      ],
    );
  }

  Widget _message(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, height: 1.4, color: _mutedColor),
        ),
      ),
    );
  }

  Widget _statTile(String emoji, String value, String label) {
    return Expanded(
      child: _card(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: _titleColor,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: _mutedColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _changePill(double pct) {
    final rounded = pct.round();
    final up = rounded > 0;
    final down = rounded < 0;
    final color = up
        ? _p.primaryColor
        : (down ? Colors.orange.shade800 : AppColors.slate500);
    final sign = up ? '+' : '';
    final text = rounded == 0 ? 'Same' : '$sign$rounded%';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up
                ? Icons.arrow_upward
                : (down ? Icons.arrow_downward : Icons.remove),
            size: 14,
            color: color,
          ),
          const SizedBox(width: 2),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _compareRow({
    required IconData icon,
    required Color color,
    required String label,
    required double? now,
    required double? prev,
    required String Function(double) format,
  }) {
    final pct = _pctChange(now, prev);
    String detail;
    if (now == null) {
      detail = 'Not enough data yet';
    } else if (prev == null) {
      detail = '${format(now)} per day';
    } else {
      detail = '${format(now)} per day  (before: ${format(prev)})';
    }

    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _bodyColor,
                ),
              ),
              Text(
                detail,
                style: TextStyle(fontSize: 12, color: _mutedColor),
              ),
            ],
          ),
        ),
        if (pct != null) _changePill(pct),
      ],
    );
  }

  Widget _metricChip(String label, _ChartMetric m) {
    final selected = _metric == m;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: selected ? Colors.white : _bodyColor,
        ),
      ),
      selected: selected,
      showCheckmark: false,
      selectedColor: _p.primaryColor,
      backgroundColor: _isDark ? AppColors.slate700 : AppColors.slate200,
      onSelected: (_) => setState(() => _metric = m),
    );
  }

  Widget _bar(DateTime d, DailyRecord? r, int goal, bool isSteps) {
    final value = r == null ? 0 : (isSteps ? r.steps : r.water);
    final frac = goal > 0 ? (value / goal).clamp(0.0, 1.0).toDouble() : 0.0;
    final reached = goal > 0 && value >= goal;
    final isToday = d == _todayUtc();
    final barHeight = value == 0 ? 4.0 : 8.0 + frac * 80.0;
    final barColor = value == 0
        ? (_isDark ? AppColors.slate700 : AppColors.slate200)
        : (reached ? _p.primaryColor : _p.primaryColor.withValues(alpha: 0.4));
    final valueText = value == 0
        ? '–'
        : (isSteps ? _compact(value) : (value / 1000).toStringAsFixed(1));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            valueText,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: _mutedColor,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            height: barHeight,
            decoration: BoxDecoration(
              color: barColor,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _weekdays[d.weekday - 1],
            style: TextStyle(
              fontSize: 10,
              fontWeight: isToday ? FontWeight.bold : FontWeight.w500,
              color: isToday ? _p.primaryColor : _mutedColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: _titleColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: _mutedColor),
          ),
        ],
      ),
    );
  }

  Widget _dayRow(DailyRecord r) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _isDark
            ? AppColors.slate800.withValues(alpha: 0.5)
            : Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _dayLabel(r.date),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _titleColor,
                  ),
                ),
              ),
              Icon(
                r.isPerfect ? Icons.star_rounded : Icons.star_border_rounded,
                size: 16,
                color: r.isPerfect ? Colors.amber.shade600 : _mutedColor,
              ),
              const SizedBox(width: 4),
              Text(
                '${r.habitsDone}/3 habits',
                style: TextStyle(fontSize: 11, color: _mutedColor),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '💧 ${(r.water / 1000).toStringAsFixed(1)} / ${(r.waterGoal / 1000).toStringAsFixed(1)} L'
            '   ·   👣 ${_thousands(r.steps)} steps',
            style: TextStyle(fontSize: 12, color: _bodyColor),
          ),
        ],
      ),
    );
  }

  // --- Sections --------------------------------------------------------------

  Widget _buildInsightCard(int activeDays, double? stepsNow, double? stepsPrev) {
    final pct = _pctChange(stepsNow, stepsPrev);
    String emoji;
    String text;

    if (activeDays < 2) {
      emoji = '🌱';
      text = 'Your journey starts here! Log your water, steps and habits each '
          'day — your progress will build up on this page.';
    } else if (pct != null) {
      final rounded = pct.round();
      if (rounded >= 5) {
        emoji = '🎉';
        text = 'Great work! You walked $rounded% more per day than the week before.';
      } else if (rounded <= -5) {
        emoji = '💪';
        text = 'Your steps dipped ${rounded.abs()}% compared with the week before. '
            'A few extra walks and you will be right back on track.';
      } else {
        emoji = '👍';
        text = 'Steady and consistent — your activity is about the same as the week before.';
      }
    } else {
      emoji = '📈';
      text = 'You have logged $activeDays days so far. Keep going — once you '
          'have a second week of steps, you will see exactly how much you improved.';
    }

    return _card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 32)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.4,
                color: _titleColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeeklyCard(
    double? stepsNow,
    double? stepsPrev,
    double? waterNow,
    double? waterPrev,
  ) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.trending_up, 'Weekly comparison'),
          const SizedBox(height: 4),
          Text(
            'Last 7 days compared with the 7 days before (today not counted — it is still in progress).',
            style: TextStyle(fontSize: 11, color: _mutedColor),
          ),
          const SizedBox(height: 14),
          _compareRow(
            icon: Icons.directions_walk,
            color: _p.primaryColor,
            label: 'Steps',
            now: stepsNow,
            prev: stepsPrev,
            format: (v) => _thousands(v.round()),
          ),
          const SizedBox(height: 14),
          _compareRow(
            icon: Icons.water_drop,
            color: Colors.cyan,
            label: 'Water',
            now: waterNow,
            prev: waterPrev,
            format: (v) => '${(v / 1000).toStringAsFixed(1)} L',
          ),
        ],
      ),
    );
  }

  Widget _buildChartCard(Map<String, DailyRecord> byDate, int latestWaterGoal) {
    final isSteps = _metric == _ChartMetric.steps;
    final today = _todayUtc();
    final days = [
      for (var i = 6; i >= 0; i--) today.subtract(Duration(days: i)),
    ];

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.bar_chart_rounded, 'Last 7 days'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              _metricChip('Steps', _ChartMetric.steps),
              _metricChip('Water', _ChartMetric.water),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 150,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final d in days)
                  Expanded(
                    child: _bar(
                      d,
                      byDate[dateKey(d)],
                      isSteps
                          ? widget.targetSteps
                          : (byDate[dateKey(d)]?.waterGoal ?? latestWaterGoal),
                      isSteps,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isSteps
                ? 'Steps per day · solid bar = goal of ${_thousands(widget.targetSteps)} reached'
                : 'Litres per day · solid bar = daily water goal reached',
            style: TextStyle(fontSize: 11, color: _mutedColor),
          ),
        ],
      ),
    );
  }

  Widget _buildWeightCard(List<DailyRecord> records) {
    final first = records.last; // oldest
    final latest = records.first; // newest
    final diff = latest.weightKg - first.weightKg;
    final sign = diff > 0 ? '+' : '-';
    final changeText = diff.abs() < 0.05
        ? 'No change yet'
        : '$sign${diff.abs().toStringAsFixed(1)} kg';

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.monitor_weight_outlined, 'Weight journey'),
          const SizedBox(height: 14),
          Row(
            children: [
              _miniStat(
                'Starting (${_shortDate(first.date)})',
                '${first.weightKg.toStringAsFixed(1)} kg',
              ),
              _miniStat('Now', '${latest.weightKg.toStringAsFixed(1)} kg'),
              _miniStat('Change', changeText),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Update your weight in Profile (top right) whenever it changes — '
            'this page keeps track for you.',
            style: TextStyle(fontSize: 11, color: _mutedColor),
          ),
        ],
      ),
    );
  }

  Widget _buildDailyList(List<DailyRecord> records) {
    final shown = records.take(30).toList();

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.history, 'Day by day'),
          const SizedBox(height: 12),
          for (final r in shown) _dayRow(r),
          if (records.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Showing the latest 30 of ${records.length} days.',
                style: TextStyle(fontSize: 11, color: _mutedColor),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContent(List<DailyRecord> records) {
    final byDate = {for (final r in records) r.date: r};
    final activeDays = records.where((r) => r.isActive).length;
    final streak = _currentStreak(byDate);
    final best = _bestStreak(records);
    final perfect = records.where((r) => r.isPerfect).length;

    final stepsNow = _weekAvg(byDate, 1, (r) => r.steps);
    final stepsPrev = _weekAvg(byDate, 8, (r) => r.steps);
    final waterNow = _weekAvg(byDate, 1, (r) => r.water);
    final waterPrev = _weekAvg(byDate, 8, (r) => r.water);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      physics: const BouncingScrollPhysics(),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildInsightCard(activeDays, stepsNow, stepsPrev),
              const SizedBox(height: 16),
              Row(
                children: [
                  _statTile('🔥', '$streak', 'Current streak'),
                  const SizedBox(width: 10),
                  _statTile('🏆', '$best', 'Best streak'),
                  const SizedBox(width: 10),
                  _statTile('⭐', '$perfect', 'Perfect days'),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Streak = days in a row with something logged. '
                'Perfect day = all 3 daily habits ticked.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: _mutedColor),
              ),
              const SizedBox(height: 16),
              _buildWeeklyCard(stepsNow, stepsPrev, waterNow, waterPrev),
              const SizedBox(height: 16),
              _buildChartCard(byDate, records.first.waterGoal),
              const SizedBox(height: 16),
              _buildWeightCard(records),
              const SizedBox(height: 16),
              _buildDailyList(records),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;
    final Widget body;

    if (records == null) {
      body = Center(child: CircularProgressIndicator(color: _p.primaryColor));
    } else if (!HistoryDb.instance.ready) {
      body = _message('History could not be opened on this device.');
    } else if (records.isEmpty) {
      body = _message(
        'No history yet. Add some water or steps on the dashboard, then come back!',
      );
    } else {
      body = _buildContent(records);
    }

    return Container(
      decoration: BoxDecoration(gradient: _p.bgGradient),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: _titleColor,
          title: Text(
            'My Progress & History',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: _titleColor,
            ),
          ),
        ),
        body: body,
      ),
    );
  }
}