// GateOps Cloud Sync (Android) - Single file main.dart
// Features:
// - Firebase Auth login (email/password) with username form (isim.soyisim -> isim.soyisim@gozen.local)
// - Firestore realtime multi-device sync (10+ devices)
// - Flight session create/join
// - Camera barcode scan (mobile_scanner) + parser for common barcode payloads (best-effort)
// - Pax tagging: DFT (== Randomly Selected) or Pre-Boarded
// - Offload flow + re-entry warning (offloaded pax re-scan prompts and re-adds as DFT)
// - Seat duplicate warning (non-infant pax cannot share same seat within same flight session)
// - Equipment (Table/Desk/ETD with model IS600 / Itemiser 4DX) + multi-serial support
// - Personnel (manual name + title from list)
// - Operation Times tab
// - XLSX export (pax + dft + equipment + times + personnel with signature columns)
//
// NOTE: To keep internal operations practical, user creation is expected to be done in Firebase Console.
// Admin role is stored under /users/{uid}. This app reads that role and gates admin-only UI.

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' as xls;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const GateOpsApp());
}

/// Shows a detailed operation error to help field debugging (internal app).
/// In release builds, this still shows the Firebase error code (if any).
void showOpError(BuildContext context, Object error, [StackTrace? st]) {
  String title = 'Islem hatasi';
  String detail = '';

  if (error is FirebaseException) {
    final code = error.code;
    final msg = (error.message ?? '').trim();
    title = 'Firebase: $code';
    detail = msg.isNotEmpty ? msg : error.toString();
  } else {
    detail = error.toString();
  }

  final stackText = st != null ? '\n\nSTACK\n${st.toString()}' : '';
  final fullText = '${title}\n${detail}${stackText}';

  debugPrint('GateOps ERROR: $fullText');

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        fullText,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      duration: const Duration(seconds: 10),
      behavior: SnackBarBehavior.floating,
      action: SnackBarAction(
        label: 'DETAY',
        onPressed: () async {
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(
                child: SelectableText(fullText),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: fullText));
                    if (ctx.mounted) {
                      Navigator.of(ctx).pop();
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Kopyalandi')),
                    );
                  },
                  child: const Text('KOPYALA'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('KAPAT'),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}


// -------------------------
// Theme
// -------------------------

class GateOpsApp extends StatelessWidget {
  const GateOpsApp({super.key});

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFD60F2B);
    const bg = Color(0xFFF7F7F8);

    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: red, brightness: Brightness.light),
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(centerTitle: true),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE6E6EA))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: red, width: 2)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFFEAEAF0))),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GateOps',
      theme: theme,
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _Splash();
        }
        if (snap.data == null) {
          return const LoginScreen();
        }
        return const HomeShell();
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('GateOps is loading...'),
          ],
        ),
      ),
    );
  }
}

// -------------------------
// Models
// -------------------------

enum PaxTag { dft, pre }

enum PaxStatus { active, offloaded }


class _ParsedScan {
  final String raw;
  final String flightCode;
  final String seat;
  final String surname;
  final String givenName;
  final String fullName;
  final bool isBCBP;

  const _ParsedScan({
    required this.raw,
    required this.flightCode,
    required this.seat,
    required this.surname,
    required this.givenName,
    required this.fullName,
    required this.isBCBP,
  });
}


class Pax {
  Pax({
    required this.id,
    required this.flightCode,
    required this.fullName,
    required this.surname,
    required this.givenName,
    required this.seat,
    required this.tag,
    required this.status,
    required this.isInfant,
    required this.scannedAt,
    required this.lastEvent,
  });

  final String id;
  final String flightCode;
  final String fullName;
  final String surname;
  final String givenName;
  final String seat;
  final PaxTag tag;
  final PaxStatus status;
  final bool isInfant;
  final DateTime scannedAt;
  final String lastEvent; // scanned/offloaded/reinstated

  Map<String, dynamic> toMap() {
    return {
      'flightCode': flightCode,
      'fullName': fullName,
      'surname': surname,
      'givenName': givenName,
      'seat': seat,
      'tag': tag.name,
      'status': status.name,
      'isInfant': isInfant,
      'scannedAt': Timestamp.fromDate(scannedAt),
      'lastEvent': lastEvent,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static Pax fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? <String, dynamic>{};
    return Pax(
      id: doc.id,
      flightCode: (d['flightCode'] ?? '') as String,
      fullName: (d['fullName'] ?? '') as String,
      surname: (d['surname'] ?? '') as String,
      givenName: (d['givenName'] ?? '') as String,
      seat: (d['seat'] ?? '') as String,
      tag: ((d['tag'] ?? 'dft') as String) == 'pre' ? PaxTag.pre : PaxTag.dft,
      status: ((d['status'] ?? 'active') as String) == 'offloaded' ? PaxStatus.offloaded : PaxStatus.active,
      isInfant: (d['isInfant'] ?? false) as bool,
      scannedAt: ((d['scannedAt'] as Timestamp?)?.toDate()) ?? DateTime.now(),
      lastEvent: (d['lastEvent'] ?? 'scanned') as String,
    );
  }
}

enum EquipmentType { table, desk, etd }

enum EtdModel { is600, itemiser4dx }

class EquipmentItem {
  EquipmentItem({
    required this.id,
    required this.type,
    required this.serials,
    this.etdModel,
  });

  final String id;
  final EquipmentType type;
  final List<String> serials;
  final EtdModel? etdModel;

  Map<String, dynamic> toMap() {
    return {
      'type': type.name,
      'serials': serials,
      'etdModel': etdModel?.name,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static EquipmentItem fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? <String, dynamic>{};
    final typeStr = (d['type'] ?? 'table') as String;
    final modelStr = d['etdModel'] as String?;
    return EquipmentItem(
      id: doc.id,
      type: EquipmentType.values.firstWhere((e) => e.name == typeStr, orElse: () => EquipmentType.table),
      serials: ((d['serials'] ?? const <dynamic>[]) as List).map((e) => e.toString()).toList(),
      etdModel: modelStr == null
          ? null
          : EtdModel.values.firstWhere((e) => e.name == modelStr, orElse: () => EtdModel.is600),
    );
  }

  String label() {
    switch (type) {
      case EquipmentType.table:
        return 'Masa';
      case EquipmentType.desk:
        return 'Desk';
      case EquipmentType.etd:
        final m = (etdModel ?? EtdModel.is600) == EtdModel.is600 ? 'IS600' : 'Itemiser 4DX';
        return 'ETD ($m)';
    }
  }
}

class Personnel {
  Personnel({required this.id, required this.name, required this.title});
  final String id;
  final String name;
  final String title;

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'title': title,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static Personnel fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? <String, dynamic>{};
    return Personnel(id: doc.id, name: (d['name'] ?? '') as String, title: (d['title'] ?? '') as String);
  }
}

// -------------------------
// Helpers
// -------------------------

String usernameToEmail(String username) {
  final u = username.trim().toLowerCase();
  if (u.contains('@')) return u;
  return '$u@gozen.local';
}

bool isStrongPassword(String pwd) {
  if (pwd.length < 8) return false;
  final hasUpper = RegExp(r'[A-Z]').hasMatch(pwd);
  final hasLower = RegExp(r'[a-z]').hasMatch(pwd);
  final hasDigit = RegExp(r'\d').hasMatch(pwd);
  final hasPunct = RegExp(r'[^A-Za-z0-9]').hasMatch(pwd);
  return hasUpper && hasLower && hasDigit && hasPunct;
}

String sanitizeKey(String input) {
  final s = input.trim();
  return s.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
}

String normalizeSeat(String seat) {
  final s = seat.trim().toUpperCase();
  return s.replaceAll(RegExp(r'\s+'), '');
}

// Best-effort barcode payload parser.
// Returns a map with fields: flightCode, surname, givenName, seat.
// Supports:
// - Our legacy mock format: FLIGHT|SURNAME/NAME|SEAT
// - Common IATA BCBP text: starts with 'M1' or contains airline flight + name + seat (heuristics)
Map<String, String> parseBoardingPayload(String raw) {
  final text = raw.trim();

  // 1) mock
  if (text.contains('|')) {
    final parts = text.split('|');
    if (parts.length >= 3) {
      final flight = parts[0].trim();
      final namePart = parts[1].trim();
      final seat = normalizeSeat(parts[2]);
      String surname = '';
      String given = '';
      if (namePart.contains('/')) {
        final np = namePart.split('/');
        surname = np[0].trim();
        given = np.sublist(1).join(' ').trim();
      } else {
        surname = namePart;
      }
      return {
        'flightCode': flight,
        'surname': surname,
        'givenName': given,
        'seat': seat,
      };
    }
  }

  // 2) IATA BCBP (very rough heuristics)
  // BCBP is often 60/70/80 chars and begins with 'M' then number.
  if (text.length >= 20 && (text.startsWith('M') || text.startsWith('m'))) {
    // Surname/given are usually around positions 2..22 until padding with spaces.
    final nameChunk = text.substring(2, text.length.clamp(2, 24)).trim();
    String surname = nameChunk;
    String given = '';
    if (nameChunk.contains('/')) {
      final np = nameChunk.split('/');
      surname = np[0].trim();
      given = np.sublist(1).join(' ').trim();
    }

    // Flight number usually appears later; try a regex for 2 letters + 3-4 digits.
    final flightMatch = RegExp(r'([A-Z0-9]{2})\s?(\d{3,4})').firstMatch(text.toUpperCase());
    final flight = flightMatch == null ? '' : '${flightMatch.group(1)}${flightMatch.group(2)}';

    // Seat: often 3 chars like 12A appears near end; find last seat-like token.
    final seatMatches = RegExp(r'(\d{1,2}[A-Z])').allMatches(text.toUpperCase()).toList();
    final seat = seatMatches.isEmpty ? '' : normalizeSeat(seatMatches.last.group(1) ?? '');

    return {
      'flightCode': flight,
      'surname': surname,
      'givenName': given,
      'seat': seat,
    };
  }

  // fallback: try extract seat
  final seatMatches = RegExp(r'(\d{1,2}[A-Z])').allMatches(text.toUpperCase()).toList();
  final seat = seatMatches.isEmpty ? '' : normalizeSeat(seatMatches.last.group(1) ?? '');
  return {
    'flightCode': '',
    'surname': '',
    'givenName': '',
    'seat': seat,
  };
}

// -------------------------
// Login
// -------------------------

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final username = _username.text.trim();
    final pwd = _password.text;

    if (username.isEmpty || pwd.isEmpty) {
      _toast('Kullanici adi ve sifre gerekli.');
      return;
    }

    setState(() => _busy = true);
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: usernameToEmail(username), password: pwd);
    } on FirebaseAuthException catch (e) {
      _toast(_prettyAuthError(e));
    } catch (_) {
      _toast('Giris basarisiz.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _prettyAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'wrong-password':
        return 'Sifre hatali.';
      case 'user-not-found':
        return 'Kullanici bulunamadi.';
      case 'invalid-email':
        return 'Kullanici adi / email gecersiz.';
      case 'too-many-requests':
        return 'Cok fazla deneme. Biraz bekleyin.';
      default:
        return 'Giris hatasi: ${e.code}';
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.flight_takeoff_rounded, color: Colors.white),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('GateOps', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                                SizedBox(height: 2),
                                Text('Cloud Sync • Internal', style: TextStyle(color: Colors.black54)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _username,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Kullanici Adi (isim.soyisim)',
                          prefixIcon: Icon(Icons.person_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        obscureText: _obscure,
                        onSubmitted: (_) => _login(),
                        decoration: InputDecoration(
                          labelText: 'Sifre',
                          prefixIcon: const Icon(Icons.lock_rounded),
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => _obscure = !_obscure),
                            icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: FilledButton(
                          onPressed: _busy ? null : _login,
                          child: _busy
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Text('Giris Yap'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Not: Kullanicilar Firebase Console > Authentication tarafindan olusturulur.\nSifre kurali: en az 8 karakter, buyuk/kucuk harf, rakam, noktalama.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54, fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (_) => const _PasswordRuleDialog(),
                          );
                        },
                        child: const Text('Sifre kurallari'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PasswordRuleDialog extends StatelessWidget {
  const _PasswordRuleDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sifre Kurallari'),
      content: const Text('Min 8 karakter. Buyuk harf, kucuk harf, rakam ve noktalama icermelidir.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tamam'))],
    );
  }
}

// -------------------------
// Home shell
// -------------------------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  String? _activeSessionId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(FirebaseAuth.instance.currentUser!.uid).snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final role = (data?['role'] ?? 'user') as String;
        final isAdmin = role == 'admin';

        return Scaffold(
          appBar: AppBar(
            title: const Text('GateOps'),
            actions: [
              IconButton(
                tooltip: 'Logout',
                onPressed: () async {
                  await FirebaseAuth.instance.signOut();
                },
                icon: const Icon(Icons.logout_rounded),
              ),
            ],
          ),
          body: _activeSessionId == null
              ? _SessionPicker(
                  isAdmin: isAdmin,
                  onJoined: (sid) => setState(() => _activeSessionId = sid),
                )
              : FlightWorkspace(
                  sessionId: _activeSessionId!,
                  isAdmin: isAdmin,
                  onExit: () => setState(() => _activeSessionId = null),
                ),
        );
      },
    );
  }
}

// -------------------------
// Session create/join
// -------------------------

class _SessionPicker extends StatefulWidget {
  const _SessionPicker({required this.isAdmin, required this.onJoined});
  final bool isAdmin;
  final void Function(String sessionId) onJoined;

  @override
  State<_SessionPicker> createState() => _SessionPickerState();
}

class _SessionPickerState extends State<_SessionPicker> {
  final _flight = TextEditingController();
  final _gate = TextEditingController();
  final _booked = TextEditingController(text: '0');
  bool _busy = false;

  @override
  void dispose() {
    _flight.dispose();
    _gate.dispose();
    _booked.dispose();
    super.dispose();
  }

  Future<void> _createSession() async {
    final flight = _flight.text.trim().toUpperCase();
    final gate = _gate.text.trim().toUpperCase();
    final booked = int.tryParse(_booked.text.trim()) ?? 0;

    if (flight.isEmpty) {
      _toast('Ucus kodu gerekli.');
      return;
    }

    setState(() => _busy = true);
    try {
      final now = DateTime.now();
      final sid = '${sanitizeKey(flight)}_${sanitizeKey(gate.isEmpty ? 'G' : gate)}_${now.millisecondsSinceEpoch}';

      await FirebaseFirestore.instance.collection('sessions').doc(sid).set({
        'flightCode': flight,
        'gate': gate,
        'bookedPax': booked,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': FirebaseAuth.instance.currentUser!.uid,
        'boardingFinished': false,
      });

      widget.onJoined(sid);
    } catch (e) {
      _toast('Session olusturulamadi.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinSession(String sid) async {
    setState(() => _busy = true);
    try {
      final doc = await FirebaseFirestore.instance.collection('sessions').doc(sid).get();
      if (!doc.exists) {
        _toast('Session bulunamadi.');
        return;
      }
      widget.onJoined(sid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Ucus Oturumu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _flight,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(labelText: 'Ucus Kodu', prefixIcon: Icon(Icons.confirmation_number_rounded)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _gate,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(labelText: 'Gate', prefixIcon: Icon(Icons.meeting_room_rounded)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _booked,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Booked Pax', prefixIcon: Icon(Icons.people_alt_rounded)),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _createSession,
                      icon: const Icon(Icons.add_circle_outline_rounded),
                      label: _busy ? const Text('...') : const Text('Yeni Ucus Oturumu Olustur'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Baska cihazlar alttaki listeden ayni oturuma katilabilir.', style: TextStyle(color: Colors.black54)),
                ],
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('sessions')
                  .orderBy('createdAt', descending: true)
                  .limit(30)
                  .snapshots(),
              builder: (context, snap) {
                final docs = snap.data?.docs ?? const [];
                if (docs.isEmpty) {
                  return const Center(child: Text('Henüz oturum yok.'));
                }
                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i].data();
                    final sid = docs[i].id;
                    final flight = (d['flightCode'] ?? '') as String;
                    final gate = (d['gate'] ?? '') as String;
                    final booked = (d['bookedPax'] ?? 0);
                    final finished = (d['boardingFinished'] ?? false) as bool;
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: finished ? Colors.black87 : Theme.of(context).colorScheme.primary,
                          child: Icon(finished ? Icons.check_rounded : Icons.flight_takeoff_rounded, color: Colors.white),
                        ),
                        title: Text('$flight  •  Gate $gate'),
                        subtitle: Text('Booked: $booked  •  ID: ${sid.substring(0, sid.length.clamp(0, 18))}...'),
                        trailing: FilledButton(
                          onPressed: _busy ? null : () => _joinSession(sid),
                          child: const Text('Katıl'),
                        ),
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

// -------------------------
// Flight Workspace
// -------------------------

class FlightWorkspace extends StatefulWidget {
  const FlightWorkspace({super.key, required this.sessionId, required this.isAdmin, required this.onExit});
  final String sessionId;
  final bool isAdmin;
  final VoidCallback onExit;

  @override
  State<FlightWorkspace> createState() => _FlightWorkspaceState();
}

class _FlightWorkspaceState extends State<FlightWorkspace> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId).snapshots(),
      builder: (context, snap) {
        final s = snap.data?.data();
        if (s == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final flight = (s['flightCode'] ?? '') as String;
        final gate = (s['gate'] ?? '') as String;
        final booked = (s['bookedPax'] ?? 0) as int;
        final boardingFinished = (s['boardingFinished'] ?? false) as bool;

        return Column(
          children: [
            _WorkspaceHeader(
              sessionId: widget.sessionId,
              flight: flight,
              gate: gate,
              booked: booked,
              boardingFinished: boardingFinished,
              isAdmin: widget.isAdmin,
              onExit: widget.onExit,
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  ScanTab(sessionId: widget.sessionId, flightCode: flight, booked: booked),
                  ListsTab(sessionId: widget.sessionId, booked: booked),
                  EquipmentTab(sessionId: widget.sessionId),
                  PersonnelTab(sessionId: widget.sessionId),
                  TimesTab(sessionId: widget.sessionId),
                  ExportTab(sessionId: widget.sessionId, flightCode: flight, gate: gate),
                ],
              ),
            ),
            _BottomNav(
              index: _tab,
              onChange: (i) => setState(() => _tab = i),
            ),
          ],
        );
      },
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({
    required this.sessionId,
    required this.flight,
    required this.gate,
    required this.booked,
    required this.boardingFinished,
    required this.isAdmin,
    required this.onExit,
  });

  final String sessionId;
  final String flight;
  final String gate;
  final int booked;
  final bool boardingFinished;
  final bool isAdmin;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(14)),
              child: const Icon(Icons.flight_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$flight  •  Gate $gate', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 2),
                  Text('Booked Pax: $booked  •  Session: ${sessionId.substring(0, sessionId.length.clamp(0, 16))}...',
                      style: const TextStyle(color: Colors.black54)),
                ],
              ),
            ),
            Column(
              children: [
                _Pill(
                  icon: boardingFinished ? Icons.check_circle_rounded : Icons.timelapse_rounded,
                  text: boardingFinished ? 'Finished' : 'Live',
                  color: boardingFinished ? Colors.black87 : cs.primary,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: onExit,
                  icon: const Icon(Icons.exit_to_app_rounded),
                  label: const Text('Cikis'),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha((0.12 * 255).round()),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withAlpha((0.22 * 255).round())),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.index, required this.onChange});
  final int index;
  final void Function(int) onChange;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: index,
      onDestinationSelected: onChange,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.qr_code_scanner_rounded), label: 'Scan'),
        NavigationDestination(icon: Icon(Icons.list_alt_rounded), label: 'Lists'),
        NavigationDestination(icon: Icon(Icons.inventory_2_rounded), label: 'Equip'),
        NavigationDestination(icon: Icon(Icons.badge_rounded), label: 'Personnel'),
        NavigationDestination(icon: Icon(Icons.schedule_rounded), label: 'Times'),
        NavigationDestination(icon: Icon(Icons.file_download_rounded), label: 'Export'),
      ],
    );
  }
}

// -------------------------
// Scan Tab
// -------------------------

class ScanTab extends StatefulWidget {
  const ScanTab({super.key, required this.sessionId, required this.flightCode, required this.booked});
  final String sessionId;
  final String flightCode;
  final int booked;

  @override
  State<ScanTab> createState() => _ScanTabState();
}

class _ScanTabState extends State<ScanTab> {
  final MobileScannerController _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  bool _cameraOn = true;
  bool _busy = false;
  String? _lastRaw;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  CollectionReference<Map<String, dynamic>> get _paxCol =>
      FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId).collection('pax');

  DocumentReference<Map<String, dynamic>> _seatLockDoc(String seat) =>
      FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId).collection('seats').doc(seat);

  Future<int> _countActiveBoarded() async {
    final q = await _paxCol.where('status', isEqualTo: 'active').get();
    return q.docs.length;
  }

  Stream<int> _activeCountStream() {
    return _paxCol.where('status', isEqualTo: 'active').snapshots().map((s) => s.docs.length);
  }

  Stream<int> _dftCountStream() {
    return _paxCol.where('status', isEqualTo: 'active').where('tag', isEqualTo: 'dft').snapshots().map((s) => s.docs.length);
  }

  Stream<bool> _boardingFinishedStream() {
    return FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId).snapshots().map((d) {
      final data = d.data();
      return (data?['boardingFinished'] ?? false) as bool;
    });
  }

  
  Future<void> _handleBarcode(String raw) async {
    if (_busy) return;
    setState(() => _busy = true);
    _lastRaw = raw;

    try {
      // 1) Parse
      final parsed = _parseFromRaw(raw) ?? await _manualEntryDialog(raw);
      if (parsed == null) {
        _toast('Kart okunamadı. Manuel giriş yapabilirsiniz.');
        return;
      }

      // 2) Flight must match current session flight
      final expected = _normalizeFlight(widget.flightCode);
      final got = _normalizeFlight(parsed.flightCode);
      if (expected.isNotEmpty && got.isNotEmpty && expected != got) {
        _toast('Farklı uçuş: $got (beklenen $expected)');
        return;
      }

      // 3) Choose action
      final tag = await _pickTypeDialog(parsed);
      if (tag == null) return;

      // 4) Save
      await _saveScan(parsed, tag: tag, forceInfant: false);

      _toast('${tag == PaxTag.dft ? 'DFT' : 'Pre'} kaydedildi: ${_normalizeSeat(parsed.seat)}');
    } on _SeatDuplicateException catch (e) {
      final proceed = await _confirm(
        'Mükerrer Seat',
        'Bu uçuşta aynı seat (infant hariç) olamaz.\n'
        'Seat: ${e.seat}\n\n'
        'Bu yolcuyu INFANT olarak kaydetmek ister misin?',
      );
      if (proceed) {
        final parsed = _parseFromRaw(_lastRaw ?? '') ?? await _manualEntryDialog(_lastRaw ?? '');
        if (parsed != null) {
          final tag = await _pickTypeDialog(parsed);
          if (tag != null) {
            await _saveScan(parsed, tag: tag, forceInfant: true);
            _toast('INFANT kaydedildi: ${_normalizeSeat(parsed.seat)}');
          }
        }
      }
    } catch (e, st) {
      showOpError(context, e, st);
    } finally {
      if (!mounted) return;
      setState(() => _busy = false);
    }
  }

  Future<void> _saveScan(_ParsedScan parsed, {required PaxTag tag, required bool forceInfant}) async {
    final seatNorm = _normalizeSeat(parsed.seat);
    if (seatNorm.isEmpty) {
      throw StateError('seat-empty');
    }

    final nowTs = Timestamp.now();
    final paxId = '${nowTs.millisecondsSinceEpoch}_$seatNorm';
    final paxDoc = _paxCol.doc(paxId);
    final seatDoc = _seatLockDoc(seatNorm);
    final sessionDoc = FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      // Transactions require all reads before any writes.
      final seatSnap = await tx.get(seatDoc);
      final sessionSnap = await tx.get(sessionDoc);

      if (seatSnap.exists) {
        final occupiedBy = (seatSnap.data()?['occupiedBy'] as String?) ?? '';
        final isInfant = (seatSnap.data()?['isInfant'] as bool?) ?? false;
        if (!forceInfant && !isInfant) {
          throw _SeatDuplicateException(seatNorm, occupiedBy: occupiedBy);
        }
      }

      final pax = Pax(
        id: paxId,
        flightCode: _normalizeFlight(parsed.flightCode),
        fullName: parsed.fullName,
        surname: parsed.surname,
        givenName: parsed.givenName,
        seat: seatNorm,
        tag: tag,
        status: PaxStatus.active,
        scannedAt: DateTime.now(),
        lastEvent: tag == PaxTag.dft ? 'dft' : 'pre',
        isInfant: forceInfant,
      );

      // writes
      tx.set(paxDoc, pax.toMap(), SetOptions(merge: true));
      tx.set(
        seatDoc,
        {
          'seat': seatNorm,
          'occupiedBy': paxId,
          'occupiedAt': nowTs,
          'isInfant': forceInfant,
          'lastTag': tag.name,
        },
        SetOptions(merge: true),
      );

      final sessionData = sessionSnap.data() as Map<String, dynamic>? ?? <String, dynamic>{};
      if (sessionData['firstPaxAt'] == null) {
        tx.set(sessionDoc, {'firstPaxAt': nowTs}, SetOptions(merge: true));
      }
      tx.set(sessionDoc, {'lastPaxAt': nowTs}, SetOptions(merge: true));
    });
  }

  String _normalizeFlight(String v) {
    final s = v.trim().toUpperCase().replaceAll(' ', '');
    final m = RegExp(r'^([A-Z0-9]{2,3})(\d{1,5})$').firstMatch(s);
    if (m == null) return s;
    final carrier = m.group(1)!;
    final num = m.group(2)!.replaceFirst(RegExp(r'^0+'), '');
    return '$carrier$num';
  }

  String _normalizeSeat(String v) {
    var s = v.trim().toUpperCase().replaceAll(' ', '');
    if (s.isEmpty) return '';
    // common: 003A -> 3A
    final m4 = RegExp(r'^(\d{1,3})([A-Z])$').firstMatch(s);
    if (m4 != null) {
      final num = m4.group(1)!.replaceFirst(RegExp(r'^0+'), '');
      return '${num.isEmpty ? '0' : num}${m4.group(2)!}';
    }
    // try to find inside
    final m = RegExp(r'\b(\d{1,3})([A-Z])\b').firstMatch(s);
    if (m != null) {
      final num = m.group(1)!.replaceFirst(RegExp(r'^0+'), '');
      return '${num.isEmpty ? '0' : num}${m.group(2)!}';
    }
    return s;
  }

  _ParsedScan? _parseFromRaw(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return null;

    // BCBP raw (IATA) usually starts with 'M' and has fixed fields
    if (v.length >= 60 && v[0] == 'M') {
      try {
        final nameField = v.substring(2, 22).trim(); // SURNAME/GIVEN
        String surname = '';
        String givenName = '';
        if (nameField.contains('/')) {
          final parts = nameField.split('/');
          surname = parts[0].trim();
          givenName = parts.sublist(1).join('/').trim();
        } else {
          surname = nameField.trim();
        }

        final carrier = v.substring(36, 39).trim();
        final flightNum = v.substring(39, 44).trim();
        final flightCode = _normalizeFlight('$carrier$flightNum');

        final seatField = v.substring(48, 52).trim();
        final seat = _normalizeSeat(seatField);

        final fullName = (givenName.isEmpty) ? surname : '$givenName $surname';

        if (seat.isEmpty || flightCode.isEmpty) return null;

        return _ParsedScan(
          raw: raw,
          flightCode: flightCode,
          seat: seat,
          surname: surname,
          givenName: givenName,
          fullName: fullName,
          isBCBP: true,
        );
      } catch (_) {
        // fallthrough to heuristic
      }
    }

    // Heuristic parsing for non-BCBP / vendor formats
    final flightMatch = RegExp(r'''\b([A-Z0-9]{2,3})\s*0?(\d{3,5})\b''').firstMatch(v.toUpperCase());
    final flightCode = flightMatch == null ? '' : _normalizeFlight('${flightMatch.group(1)}${flightMatch.group(2)}');

    final seatMatch = RegExp(r'''\b(\d{1,3}\s*[A-Z])\b''').firstMatch(v.toUpperCase());
    final seat = seatMatch == null ? '' : _normalizeSeat(seatMatch.group(1)!.replaceAll(' ', ''));

    // Name heuristic (very unreliable)
    String surname = '';
    String givenName = '';
    final nameMatch = RegExp(r'\b([A-Z]{2,})/([A-Z]{2,})\b').firstMatch(v.toUpperCase());
    if (nameMatch != null) {
      surname = nameMatch.group(1)!.trim();
      givenName = nameMatch.group(2)!.trim();
    }
    final fullName = (givenName.isEmpty) ? surname : '$givenName $surname';

    if (seat.isEmpty) return null;

    return _ParsedScan(
      raw: raw,
      flightCode: flightCode,
      seat: seat,
      surname: surname,
      givenName: givenName,
      fullName: fullName,
      isBCBP: false,
    );
  }

  Future<PaxTag?> _pickTypeDialog(_ParsedScan parsed) async {
    return showDialog<PaxTag>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('İşlem Türü'),
          content: Text(
            'Uçuş: ${parsed.flightCode.isEmpty ? widget.flightCode : parsed.flightCode}\n'
            'Seat: ${_normalizeSeat(parsed.seat)}\n'
            'İsim: ${parsed.fullName.isEmpty ? '-' : parsed.fullName}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
            FilledButton(onPressed: () => Navigator.pop(context, PaxTag.dft), child: const Text('DFT')),
            FilledButton(onPressed: () => Navigator.pop(context, PaxTag.pre), child: const Text('Pre')),
          ],
        );
      },
    );
  }

  Future<_ParsedScan?> _manualEntryDialog(String raw) async {
    // Only open manual input if camera read failed / user wants override.
    // If raw is non-empty but parsing failed, still allow manual entry.
    final flightCtrl = TextEditingController(text: widget.flightCode);
    final seatCtrl = TextEditingController();
    final surnameCtrl = TextEditingController();
    final givenCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('Manuel Giriş'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: flightCtrl, decoration: const InputDecoration(labelText: 'Uçuş Kodu (örn BA679)')),
                const SizedBox(height: 8),
                TextField(controller: seatCtrl, decoration: const InputDecoration(labelText: 'Seat (örn 3A)')),
                const SizedBox(height: 8),
                TextField(controller: givenCtrl, decoration: const InputDecoration(labelText: 'Ad')),
                const SizedBox(height: 8),
                TextField(controller: surnameCtrl, decoration: const InputDecoration(labelText: 'Soyad')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kaydet')),
          ],
        );
      },
    );

    if (ok != true) return null;

    final flight = _normalizeFlight(flightCtrl.text);
    final seat = _normalizeSeat(seatCtrl.text);
    final surname = surnameCtrl.text.trim().toUpperCase();
    final givenName = givenCtrl.text.trim().toUpperCase();
    final fullName = ((givenName.isEmpty && surname.isEmpty) ? '' : '$givenName $surname').trim();

    if (seat.isEmpty) return null;

    return _ParsedScan(
      raw: raw,
      flightCode: flight.isEmpty ? _normalizeFlight(widget.flightCode) : flight,
      seat: seat,
      surname: surname,
      givenName: givenName,
      fullName: fullName,
      isBCBP: false,
    );
  }

Future<void> _forceAddAsInfant() async {
    final raw = _lastRaw;
    if (raw == null) return;
    final parsed = parseBoardingPayload(raw);
    final surname = (parsed['surname'] ?? '').trim();
    final given = (parsed['givenName'] ?? '').trim();
    final seat = normalizeSeat(parsed['seat'] ?? '');
    final namePreview = (surname.isEmpty && given.isEmpty) ? '(isim okunamadi)' : '$surname $given'.trim();

    final tag = await showDialog<PaxTag>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Override'),
        content: const Text('Mükerrer seat override için yolcu INFANT olarak kaydedilecek. Etiket seç:'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgec')),
          FilledButton(onPressed: () => Navigator.pop(context, PaxTag.dft), child: const Text('DFT')),
          FilledButton(onPressed: () => Navigator.pop(context, PaxTag.pre), child: const Text('Pre')),
        ],
      ),
    );
    if (tag == null) return;

    final pid = sanitizeKey('${seat}_${surname}_${given}'.toUpperCase());
    await _paxCol.doc(pid).set(
          Pax(
            id: pid,
            flightCode: widget.flightCode,
            fullName: namePreview,
            surname: surname,
            givenName: given,
            seat: seat,
            tag: tag,
            status: PaxStatus.active,
            isInfant: true,
            scannedAt: DateTime.now(),
            lastEvent: 'scanned',
          ).toMap(),
          SetOptions(merge: true),
        );

    _toast('Override kaydedildi (INFANT): $seat');
  }

  Future<void> _offloadBySeat(String seat) async {
    final normSeat = normalizeSeat(seat);
    if (normSeat.isEmpty) return;

    // Find active pax with seat
    final q = await _paxCol.where('seat', isEqualTo: normSeat).where('status', isEqualTo: 'active').limit(5).get();
    if (q.docs.isEmpty) {
      _toast('Aktif yolcu bulunamadi: $normSeat');
      return;
    }

    final doc = q.docs.first;
    final pax = Pax.fromDoc(doc);

    final ok = await _confirm('Offload', '${pax.fullName} ($normSeat) offload?');
    if (!ok) return;

    await FirebaseFirestore.instance.runTransaction((tx) async {
      tx.set(doc.reference, {'status': 'offloaded', 'lastEvent': 'offloaded', 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));

      // Clear seat lock if this pax held it
      if (!pax.isInfant) {
        final seatDoc = _seatLockDoc(normSeat);
        final seatSnap = await tx.get(seatDoc);
        if (seatSnap.exists) {
          final d = seatSnap.data() as Map<String, dynamic>;
          final activeId = (d['activePaxId'] ?? '') as String;
          if (activeId == pax.id) {
            tx.set(seatDoc, {'active': false, 'activePaxId': '', 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
          }
        }
      }

      final sessionDoc = FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId);
      tx.set(sessionDoc, {'lastPaxAt': Timestamp.fromDate(DateTime.now())}, SetOptions(merge: true));
    });

    _toast('Offload edildi: $normSeat');
  }

  Future<bool> _confirm(String title, String msg) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Hayir')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Evet')),
        ],
      ),
    );
    return res ?? false;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Camera Scan', style: TextStyle(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: AspectRatio(
                      aspectRatio: 16 / 10,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_cameraOn)
                            MobileScanner(
                              controller: _scanner,
                              onDetect: (capture) {
                                final barcodes = capture.barcodes;
                                if (barcodes.isEmpty) return;
                                final raw = barcodes.first.rawValue;
                                if (raw == null || raw.trim().isEmpty) return;
                                _handleBarcode(raw);
                              },
                            )
                          else
                            Container(
                              color: Colors.black12,
                              child: const Center(child: Text('Camera kapali')),
                            ),
                          Positioned(
                            left: 12,
                            top: 12,
                            right: 12,
                            child: Row(
                              children: [
                                _Pill(icon: Icons.wifi_tethering_rounded, text: 'Cloud Sync', color: cs.primary),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withAlpha((0.35 * 255).round()),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: const Text(
                                      'DFT = Randomly Selected',
                                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  onPressed: () {
                                    setState(() => _cameraOn = !_cameraOn);
                                    if (_cameraOn) {
                                      _scanner.start();
                                    } else {
                                      _scanner.stop();
                                    }
                                  },
                                  icon: Icon(_cameraOn ? Icons.videocam_off_rounded : Icons.videocam_rounded, color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                          if (_busy)
                            Container(
                              color: Colors.black.withAlpha((0.15 * 255).round()),
                              child: const Center(child: CircularProgressIndicator()),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final seat = await showDialog<String>(
                              context: context,
                              builder: (_) => const _ManualSeatDialog(title: 'Offload (Seat gir)', hint: '12A'),
                            );
                            if (seat == null) return;
                            await _offloadBySeat(seat);
                          },
                          icon: const Icon(Icons.person_remove_alt_1_rounded),
                          label: const Text('Manual Offload'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () async {
                            // Boarding finished toggle
                            final sessionRef = FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId);
                            final snap = await sessionRef.get();
                            final finished = (snap.data()?['boardingFinished'] ?? false) as bool;
                            final ok = await _confirm('Boarding Finished', finished ? 'Finish geri alinsin mi?' : 'Boarding Finished yapilsin mi?');
                            if (!ok) return;
                            await sessionRef.set({'boardingFinished': !finished, 'boardingFinishedAt': !finished ? Timestamp.fromDate(DateTime.now()) : null}, SetOptions(merge: true));

                            if (!context.mounted) return;
                            _toast(!finished ? 'Boarding Finished' : 'Boarding Finished geri alindi');
                          },
                          icon: const Icon(Icons.done_all_rounded),
                          label: const Text('Boarding Finished'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: StreamBuilder<bool>(
                      stream: _boardingFinishedStream(),
                      builder: (context, snapBF) {
                        final finished = snapBF.data ?? false;
                        return StreamBuilder<int>(
                          stream: _dftCountStream(),
                          builder: (context, snapD) {
                            final dft = snapD.data ?? 0;
                            return StreamBuilder<int>(
                              stream: _activeCountStream(),
                              builder: (context, snapA) {
                                final active = snapA.data ?? 0;
                                final denom = finished ? (active == 0 ? 1 : active) : (widget.booked == 0 ? 1 : widget.booked);
                                final ratio = dft / denom;
                                final pct = (ratio * 100).clamp(0, 999).toStringAsFixed(1);
                                final label = finished
                                    ? 'DFT / Boarded = $dft / $active'
                                    : 'DFT / Booked = $dft / ${widget.booked}';
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                                    const SizedBox(height: 6),
                                    LinearProgressIndicator(value: denom == 0 ? 0 : (dft / denom).clamp(0, 1)),
                                    const SizedBox(height: 6),
                                    Text('Oran: %$pct', style: const TextStyle(color: Colors.black54)),
                                  ],
                                );
                              },
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
        ],
      ),
    );
  }
}

class _SeatDuplicateException implements Exception {
  _SeatDuplicateException(this.seat, {this.occupiedBy = ''});
  final String seat;
  final String occupiedBy;
}

enum _ScanAction { dft, pre, offload }

class _ScanDecision {
  _ScanDecision({required this.action, required this.isInfant});
  final _ScanAction action;
  final bool isInfant;
}

class _ScanDecisionSheet extends StatefulWidget {
  const _ScanDecisionSheet({required this.flightCode, required this.seat, required this.name});
  final String flightCode;
  final String seat;
  final String name;

  @override
  State<_ScanDecisionSheet> createState() => _ScanDecisionSheetState();
}

class _ScanDecisionSheetState extends State<_ScanDecisionSheet> {
  bool infant = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.flightCode}  •  Seat ${widget.seat}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text(widget.name, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            value: infant,
            onChanged: (v) => setState(() => infant = v),
            title: const Text('Infant yolcu (seat duplicate muaf)'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, _ScanDecision(action: _ScanAction.dft, isInfant: infant)),
                  icon: const Icon(Icons.search_rounded),
                  label: const Text('DFT (Random)'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => Navigator.pop(context, _ScanDecision(action: _ScanAction.pre, isInfant: infant)),
                  icon: const Icon(Icons.how_to_reg_rounded),
                  label: const Text('Pre-Board'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.pop(context, _ScanDecision(action: _ScanAction.offload, isInfant: false)),
              icon: const Icon(Icons.person_remove_alt_1_rounded),
              label: const Text('Offload (Bu seat)'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualSeatDialog extends StatefulWidget {
  const _ManualSeatDialog({required this.title, required this.hint});
  final String title;
  final String hint;

  @override
  State<_ManualSeatDialog> createState() => _ManualSeatDialogState();
}

class _ManualSeatDialogState extends State<_ManualSeatDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        decoration: InputDecoration(labelText: 'Seat', hintText: widget.hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Iptal')),
        FilledButton(onPressed: () => Navigator.pop(context, _ctrl.text.trim()), child: const Text('Tamam')),
      ],
    );
  }
}

// -------------------------
// Lists Tab
// -------------------------

class ListsTab extends StatefulWidget {
  const ListsTab({super.key, required this.sessionId, required this.booked});
  final String sessionId;
  final int booked;

  @override
  State<ListsTab> createState() => _ListsTabState();
}

class _ListsTabState extends State<ListsTab> {
  final _query = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  CollectionReference<Map<String, dynamic>> get _paxCol =>
      FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId).collection('pax');

  Stream<bool> _boardingFinishedStream() {
    return FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId).snapshots().map((d) {
      final data = d.data();
      return (data?['boardingFinished'] ?? false) as bool;
    });
  }

  Stream<int> _activeCountStream() {
    return _paxCol.where('status', isEqualTo: 'active').snapshots().map((s) => s.docs.length);
  }

  Stream<int> _dftCountStream() {
    return _paxCol.where('status', isEqualTo: 'active').where('tag', isEqualTo: 'dft').snapshots().map((s) => s.docs.length);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  TextField(
                    controller: _query,
                    onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                    decoration: const InputDecoration(
                      labelText: 'Ara: isim/soyisim veya seat',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                  ),
                  const SizedBox(height: 10),
                  StreamBuilder<bool>(
                    stream: _boardingFinishedStream(),
                    builder: (context, snapBF) {
                      final finished = snapBF.data ?? false;
                      return StreamBuilder<int>(
                        stream: _dftCountStream(),
                        builder: (context, snapD) {
                          final dft = snapD.data ?? 0;
                          return StreamBuilder<int>(
                            stream: _activeCountStream(),
                            builder: (context, snapA) {
                              final active = snapA.data ?? 0;
                              final denom = finished ? (active == 0 ? 1 : active) : (widget.booked == 0 ? 1 : widget.booked);
                              final ratio = dft / denom;
                              final pct = (ratio * 100).clamp(0, 999).toStringAsFixed(1);
                              final label = finished
                                  ? 'DFT / Boarded = $dft / $active'
                                  : 'DFT / Booked = $dft / ${widget.booked}';
                              return Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                                        const SizedBox(height: 6),
                                        LinearProgressIndicator(value: denom == 0 ? 0 : (dft / denom).clamp(0, 1)),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text('%$pct', style: const TextStyle(fontWeight: FontWeight.w900)),
                                ],
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _paxCol.orderBy('scannedAt', descending: true).limit(500).snapshots(),
              builder: (context, snap) {
                final docs = snap.data?.docs ?? const [];
                final paxAll = docs.map(Pax.fromDoc).toList();

                List<Pax> filtered = paxAll;
                if (_q.isNotEmpty) {
                  filtered = paxAll.where((p) {
                    final s = '${p.fullName} ${p.seat}'.toLowerCase();
                    return s.contains(_q);
                  }).toList();
                }

                if (filtered.isEmpty) {
                  return const Center(child: Text('Kayıt yok.'));
                }

                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final p = filtered[i];
                    final isActive = p.status == PaxStatus.active;
                    final tagLabel = p.tag == PaxTag.dft ? 'DFT' : 'PRE';
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: p.tag == PaxTag.dft ? Theme.of(context).colorScheme.primary : Colors.black87,
                          child: Text(tagLabel, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                        ),
                        title: Text(p.fullName.isEmpty ? '(isim yok)' : p.fullName, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('Seat: ${p.seat}  •  ${isActive ? 'Active' : 'Offloaded'}  •  ${p.isInfant ? 'Infant' : 'Adult'}'),
                        trailing: isActive
                            ? OutlinedButton(
                                onPressed: () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (_) => AlertDialog(
                                      title: const Text('Offload'),
                                      content: Text('${p.fullName} (${p.seat}) offload?'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Hayir')),
                                        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Evet')),
                                      ],
                                    ),
                                  );
                                  if (ok != true) return;
                                  await _offloadPax(p);
                                },
                                child: const Text('Offload'),
                              )
                            : const Text(''),
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

  Future<void> _offloadPax(Pax p) async {
    final paxRef = _paxCol.doc(p.id);
    await paxRef.set({'status': 'offloaded', 'lastEvent': 'offloaded', 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    // clear seat lock if held
    if (!p.isInfant) {
      final seatRef = FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId).collection('seats').doc(p.seat);
      await seatRef.set({'active': false, 'activePaxId': '', 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    }
  }
}

// -------------------------
// Equipment Tab
// -------------------------

class EquipmentTab extends StatefulWidget {
  const EquipmentTab({super.key, required this.sessionId});
  final String sessionId;

  @override
  State<EquipmentTab> createState() => _EquipmentTabState();
}

class _EquipmentTabState extends State<EquipmentTab> {
  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId).collection('equipment');

  Future<void> _addOrEdit({EquipmentItem? existing}) async {
    final res = await showDialog<EquipmentItem>(
      context: context,
      builder: (_) => _EquipmentDialog(existing: existing),
    );
    if (res == null) return;

    final doc = existing == null ? _col.doc() : _col.doc(existing.id);
    await doc.set(res.toMap(), SetOptions(merge: true));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Equipment', style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                  FilledButton.icon(
                    onPressed: () => _addOrEdit(),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Ekle'),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _col.orderBy('updatedAt', descending: true).snapshots(),
              builder: (context, snap) {
                final docs = snap.data?.docs ?? const [];
                if (docs.isEmpty) return const Center(child: Text('Equipment yok.'));
                final items = docs.map(EquipmentItem.fromDoc).toList();
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final it = items[i];
                    return Card(
                      child: ListTile(
                        title: Text(it.label(), style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text('Seri No: ${it.serials.join(', ')}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.edit_rounded),
                          onPressed: () => _addOrEdit(existing: it),
                        ),
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

class _EquipmentDialog extends StatefulWidget {
  const _EquipmentDialog({this.existing});
  final EquipmentItem? existing;

  @override
  State<_EquipmentDialog> createState() => _EquipmentDialogState();
}

class _EquipmentDialogState extends State<_EquipmentDialog> {
  EquipmentType type = EquipmentType.table;
  EtdModel etdModel = EtdModel.is600;
  final _serials = TextEditingController();

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      type = ex.type;
      etdModel = ex.etdModel ?? EtdModel.is600;
      _serials.text = ex.serials.join(', ');
    }
  }

  @override
  void dispose() {
    _serials.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Equipment Ekle' : 'Equipment Duzenle'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<EquipmentType>(
              value: type,
              items: const [
                DropdownMenuItem(value: EquipmentType.table, child: Text('Masa')),
                DropdownMenuItem(value: EquipmentType.desk, child: Text('Desk')),
                DropdownMenuItem(value: EquipmentType.etd, child: Text('ETD')),
              ],
              onChanged: (v) => setState(() => type = v ?? EquipmentType.table),
              decoration: const InputDecoration(labelText: 'Tip'),
            ),
            const SizedBox(height: 10),
            if (type == EquipmentType.etd)
              DropdownButtonFormField<EtdModel>(
                value: etdModel,
                items: const [
                  DropdownMenuItem(value: EtdModel.is600, child: Text('IS600')),
                  DropdownMenuItem(value: EtdModel.itemiser4dx, child: Text('Itemiser 4DX')),
                ],
                onChanged: (v) => setState(() => etdModel = v ?? EtdModel.is600),
                decoration: const InputDecoration(labelText: 'ETD Model'),
              ),
            if (type == EquipmentType.etd) const SizedBox(height: 10),
            TextField(
              controller: _serials,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Seri No(lar)', hintText: 'SN1, SN2, SN3'),
            ),
            const SizedBox(height: 6),
            const Text('Not: Birden fazla seri no virgülle ayır.', style: TextStyle(color: Colors.black54, fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Iptal')),
        FilledButton(
          onPressed: () {
            final serials = _serials.text
                .split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toSet()
                .toList();
            final id = widget.existing?.id ?? '';
            Navigator.pop(
              context,
              EquipmentItem(id: id, type: type, serials: serials, etdModel: type == EquipmentType.etd ? etdModel : null),
            );
          },
          child: const Text('Kaydet'),
        ),
      ],
    );
  }
}

// -------------------------
// Personnel Tab
// -------------------------

class PersonnelTab extends StatefulWidget {
  const PersonnelTab({super.key, required this.sessionId});
  final String sessionId;

  @override
  State<PersonnelTab> createState() => _PersonnelTabState();
}

class _PersonnelTabState extends State<PersonnelTab> {
  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId).collection('personnel');

  static const titles = [
    'Erkek Airsider',
    'Kadın Airsider',
    'Profiler',
    'Interviewer',
    'Team Leader',
    'Supervisor',
  ];

  Future<void> _addOrEdit({Personnel? existing}) async {
    final res = await showDialog<Personnel>(
      context: context,
      builder: (_) => _PersonnelDialog(existing: existing),
    );
    if (res == null) return;
    final doc = existing == null ? _col.doc() : _col.doc(existing.id);
    await doc.set(res.toMap(), SetOptions(merge: true));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(child: Text('Personnel', style: TextStyle(fontWeight: FontWeight.w900))),
                  FilledButton.icon(
                    onPressed: () => _addOrEdit(),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Ekle'),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _col.orderBy('updatedAt', descending: true).snapshots(),
              builder: (context, snap) {
                final docs = snap.data?.docs ?? const [];
                if (docs.isEmpty) return const Center(child: Text('Personel yok.'));
                final items = docs.map(Personnel.fromDoc).toList();
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final p = items[i];
                    return Card(
                      child: ListTile(
                        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text(p.title),
                        trailing: IconButton(icon: const Icon(Icons.edit_rounded), onPressed: () => _addOrEdit(existing: p)),
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

class _PersonnelDialog extends StatefulWidget {
  const _PersonnelDialog({this.existing});
  final Personnel? existing;

  @override
  State<_PersonnelDialog> createState() => _PersonnelDialogState();
}

class _PersonnelDialogState extends State<_PersonnelDialog> {
  final _name = TextEditingController();
  String title = _PersonnelTabState.titles.first;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      _name.text = ex.name;
      title = ex.title.isEmpty ? title : ex.title;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Personel Ekle' : 'Personel Duzenle'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Isim Soyisim', prefixIcon: Icon(Icons.person_rounded)),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: title,
            items: _PersonnelTabState.titles.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
            onChanged: (v) => setState(() => title = v ?? _PersonnelTabState.titles.first),
            decoration: const InputDecoration(labelText: 'Title', prefixIcon: Icon(Icons.badge_rounded)),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Iptal')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, Personnel(id: widget.existing?.id ?? '', name: name, title: title));
          },
          child: const Text('Kaydet'),
        ),
      ],
    );
  }
}

// -------------------------
// Times Tab
// -------------------------

class TimesTab extends StatefulWidget {
  const TimesTab({super.key, required this.sessionId});
  final String sessionId;

  @override
  State<TimesTab> createState() => _TimesTabState();
}

class _TimesTabState extends State<TimesTab> {
  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId);

  Future<void> _setTime(String key) async {
    final now = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Saat Kaydet'),
        content: Text('$key = ${now.toString().substring(0, 19)}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgec')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kaydet')),
        ],
      ),
    );
    if (ok != true) return;
    await _doc.set({key: Timestamp.fromDate(now)}, SetOptions(merge: true));
  }

  Widget _tile(String label, String field, Map<String, dynamic> data) {
    final ts = data[field] as Timestamp?;
    final val = ts?.toDate().toString().substring(11, 19) ?? '--:--:--';
    return Card(
      child: ListTile(
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(val),
        trailing: FilledButton.tonal(
          onPressed: () => _setTime(field),
          child: const Text('Set Now'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _doc.snapshots(),
        builder: (context, snap) {
          final data = snap.data?.data() ?? <String, dynamic>{};
          return ListView(
            children: [
              const SizedBox(height: 6),
              _tile('Gate Tahsis', 'gateAssignAt', data),
              _tile('Operation Start', 'operationStartAt', data),
              _tile('First Pax', 'firstPaxAt', data),
              _tile('Last Pax', 'lastPaxAt', data),
              _tile('Boarding Finished', 'boardingFinishedAt', data),
              _tile('Operation Finished', 'operationFinishedAt', data),
              const SizedBox(height: 10),
            ],
          );
        },
      ),
    );
  }
}

// -------------------------
// Export Tab
// -------------------------

class ExportTab extends StatefulWidget {
  const ExportTab({super.key, required this.sessionId, required this.flightCode, required this.gate});
  final String sessionId;
  final String flightCode;
  final String gate;

  @override
  State<ExportTab> createState() => _ExportTabState();
}

class _ExportTabState extends State<ExportTab> {
  bool _busy = false;

  Future<void> _exportXlsx() async {
    setState(() => _busy = true);
    try {
      final fs = FirebaseFirestore.instance;
      final paxSnap = await fs.collection('sessions').doc(widget.sessionId).collection('pax').orderBy('scannedAt').get();
      final eqSnap = await fs.collection('sessions').doc(widget.sessionId).collection('equipment').get();
      final perSnap = await fs.collection('sessions').doc(widget.sessionId).collection('personnel').get();
      final sessionSnap = await fs.collection('sessions').doc(widget.sessionId).get();

      final pax = paxSnap.docs.map(Pax.fromDoc).toList();
      final dftActive = pax.where((p) => p.status == PaxStatus.active && p.tag == PaxTag.dft).toList();
      final equipment = eqSnap.docs.map(EquipmentItem.fromDoc).toList();
      final personnel = perSnap.docs.map(Personnel.fromDoc).toList();
      final sdata = sessionSnap.data() ?? <String, dynamic>{};

      final excel = xls.Excel.createExcel();

      void writeRow(xls.Sheet sheet, int row, List<String> values) {
        for (var c = 0; c < values.length; c++) {
          sheet.updateCell(xls.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row), xls.TextCellValue(values[c]));
        }
      }

      // Sheet: Pax
      final shPax = excel['PAX'];
      writeRow(shPax, 0, ['No', 'Name', 'Seat', 'Tag', 'Status', 'Infant', 'ScannedAt']);
      for (int i = 0; i < pax.length; i++) {
        final p = pax[i];
        writeRow(shPax, i + 1, [
          '${i + 1}',
          p.fullName,
          p.seat,
          p.tag == PaxTag.dft ? 'DFT' : 'PRE',
          p.status == PaxStatus.active ? 'ACTIVE' : 'OFFLOADED',
          p.isInfant ? 'YES' : 'NO',
          p.scannedAt.toString().substring(0, 19),
        ]);
      }

      // Sheet: DFT
      final shDft = excel['DFT'];
      writeRow(shDft, 0, ['No', 'Name', 'Seat']);
      for (int i = 0; i < dftActive.length; i++) {
        final p = dftActive[i];
        writeRow(shDft, i + 1, ['${i + 1}', p.fullName, p.seat]);
      }

      // Sheet: Equipment
      final shEq = excel['EQUIPMENT'];
      writeRow(shEq, 0, ['Type', 'Model', 'Serials']);
      for (int i = 0; i < equipment.length; i++) {
        final e = equipment[i];
        final model = e.type == EquipmentType.etd
            ? ((e.etdModel ?? EtdModel.is600) == EtdModel.is600 ? 'IS600' : 'Itemiser 4DX')
            : '';
        writeRow(shEq, i + 1, [e.type.name.toUpperCase(), model, e.serials.join(' | ')]);
      }

      // Sheet: Times
      final shT = excel['TIMES'];
      String fmtTs(String key) {
        final ts = sdata[key] as Timestamp?;
        return ts?.toDate().toString().substring(0, 19) ?? '';
      }

      writeRow(shT, 0, ['GateAssign', 'OpStart', 'FirstPax', 'LastPax', 'BoardingFinished', 'OpFinished']);
      writeRow(shT, 1, [
        fmtTs('gateAssignAt'),
        fmtTs('operationStartAt'),
        fmtTs('firstPaxAt'),
        fmtTs('lastPaxAt'),
        fmtTs('boardingFinishedAt'),
        fmtTs('operationFinishedAt'),
      ]);

      // Sheet: Personnel + signature columns
      final shPer = excel['PERSONNEL'];
      writeRow(shPer, 0, ['No', 'Name', 'Title', 'Signature']);
      for (int i = 0; i < personnel.length; i++) {
        final p = personnel[i];
        writeRow(shPer, i + 1, ['${i + 1}', p.name, p.title, '']);
      }

      // Remove default sheet if created
      if (excel.sheets.keys.contains('Sheet1') && excel.sheets.keys.length > 1) {
        excel.delete('Sheet1');
      }

      final bytes = excel.encode();
      if (bytes == null) throw Exception('xlsx encode failed');

      final dir = await getTemporaryDirectory();
      final fileName = 'GateOps_${widget.flightCode}_${widget.gate}_${DateTime.now().millisecondsSinceEpoch}.xlsx'
          .replaceAll(' ', '_');
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);

      if (!context.mounted) return;
      await Share.shareXFiles([XFile(file.path)], text: 'GateOps Report: ${widget.flightCode} Gate ${widget.gate}');

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('XLSX hazir: $fileName')));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Export basarisiz.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        children: [
          const SizedBox(height: 6),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Export', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('Flight: ${widget.flightCode} • Gate: ${widget.gate}', style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _exportXlsx,
                      icon: const Icon(Icons.file_download_rounded),
                      label: Text(_busy ? 'Hazirlaniyor...' : 'XLSX Export + Share'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Dosya telefonda paylasim ekrani ile "Downloads" veya baska bir hedefe kaydedilebilir.\n'
                    'Not: iOS/Android dosya konumu cihaz politikasina gore degisebilir.',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
