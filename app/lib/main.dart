// lib/main.dart
// Gate Ops MVP (Single file) — Flutter Web prototype
//
// ✅ Update: Gate tahsis BİTİŞ alanı kaldırıldı (sadece başlangıç var)
// ✅ Update: Kullanıcı girişi eklendi
//    - İlk kurulum: Master şifre oluştur
//    - Admin Mode: Master şifre ile giriş -> SADECE USER ekle/sil/şifre reset
//    - Kullanıcı girişi: isim.soyisim + şifre
//
// ⚠️ Not (paket): Bu dosya, şifre hashlemek için `crypto` paketini kullanır.
// pubspec.yaml içine ekleyin:
//   dependencies:
//     crypto: ^3.0.3
//
// ⚠️ Not (depolama): MVP'de kullanıcılar ve master bilgisi tarayıcı localStorage’da saklanır.
// (Web için uygundur. Mobil/desktop hedeflenirse storage katmanı ayrıca ele alınmalıdır.)

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Web localStorage (Flutter Web için)
import 'dart:html' as html;

void main() => runApp(const GateOpsRoot());

/* =========================================================
   AUTH STORAGE (LocalStorage)
========================================================= */

class AuthStore {
  static const _key = 'gateops_auth_v1';

  static AuthData load() {
    try {
      final raw = html.window.localStorage[_key];
      if (raw == null || raw.trim().isEmpty) return AuthData.empty();
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return AuthData.fromJson(map);
    } catch (_) {
      return AuthData.empty();
    }
  }

  static void save(AuthData data) {
    try {
      html.window.localStorage[_key] = jsonEncode(data.toJson());
    } catch (_) {
      // ignore in MVP
    }
  }

  static void clearAll() {
    try {
      html.window.localStorage.remove(_key);
    } catch (_) {}
  }
}

class AuthData {
  final MasterSecret? master;
  final List<UserRecord> users;

  const AuthData({required this.master, required this.users});

  factory AuthData.empty() => const AuthData(master: null, users: []);

  bool get hasMaster => master != null;

  AuthData copyWith({MasterSecret? master, List<UserRecord>? users}) {
    return AuthData(master: master ?? this.master, users: users ?? this.users);
  }

  Map<String, dynamic> toJson() => {
        'master': master?.toJson(),
        'users': users.map((e) => e.toJson()).toList(),
      };

  factory AuthData.fromJson(Map<String, dynamic> json) {
    final m = json['master'];
    final u = (json['users'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    return AuthData(
      master: m == null ? null : MasterSecret.fromJson((m as Map).cast<String, dynamic>()),
      users: u.map((e) => UserRecord.fromJson(e)).toList(),
    );
  }
}

class MasterSecret {
  final String saltB64;
  final String hashB64;
  const MasterSecret({required this.saltB64, required this.hashB64});

  Map<String, dynamic> toJson() => {'saltB64': saltB64, 'hashB64': hashB64};

  factory MasterSecret.fromJson(Map<String, dynamic> json) {
    return MasterSecret(
      saltB64: (json['saltB64'] ?? '') as String,
      hashB64: (json['hashB64'] ?? '') as String,
    );
  }
}

class UserRecord {
  final String username; // normalized: lowercase isim.soyisim
  final String saltB64;
  final String hashB64;

  const UserRecord({required this.username, required this.saltB64, required this.hashB64});

  Map<String, dynamic> toJson() => {'username': username, 'saltB64': saltB64, 'hashB64': hashB64};

  factory UserRecord.fromJson(Map<String, dynamic> json) {
    return UserRecord(
      username: (json['username'] ?? '') as String,
      saltB64: (json['saltB64'] ?? '') as String,
      hashB64: (json['hashB64'] ?? '') as String,
    );
  }
}

class PasswordPolicy {
  // min 8, upper, lower, digit, punctuation/special
  static bool validate(String pwd) {
    if (pwd.length < 8) return false;
    final hasUpper = RegExp(r'[A-Z]').hasMatch(pwd);
    final hasLower = RegExp(r'[a-z]').hasMatch(pwd);
    final hasDigit = RegExp(r'\d').hasMatch(pwd);
    final hasPunct = RegExp(r'''[!@#$%^&*(),.?":{}|<>_\-+=\[\]\\\/;'`~]''').hasMatch(pwd);
    return hasUpper && hasLower && hasDigit && hasPunct;
  }

  static String hint() =>
      'Min 8 karakter; büyük harf + küçük harf + rakam + noktalama/özel karakter içermeli.';
}

class UsernamePolicy {
  // isim.soyisim (tek nokta, boşluk yok)
  static final _re = RegExp(r'^[a-z]+(\.[a-z]+)+$'); // mehmet.yilmaz or ad.soyad.ek etc.

  static String normalize(String u) => u.trim().toLowerCase();

  static bool validate(String u) {
    final n = normalize(u);
    if (n.isEmpty) return false;
    if (n.contains(' ')) return false;
    return _re.hasMatch(n);
  }

  static String hint() => 'Format: isim.soyisim (küçük harf, boşluk yok)';
}

class CryptoUtil {
  static Uint8List _randBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  static String genSaltB64([int n = 16]) => base64Encode(_randBytes(n));

  static String hashB64(String saltB64, String password) {
    final salt = base64Decode(saltB64);
    final bytes = Uint8List.fromList([...salt, ...utf8.encode(password)]);
    final digest = sha256.convert(bytes).bytes;
    return base64Encode(digest);
  }

  static bool verify({required String saltB64, required String hashB64, required String password}) {
    final h = hashB64Func(saltB64, password);
    return h == hashB64;
  }

  static String hashB64Func(String saltB64, String password) => hashB64(saltB64, password);
}

/* =========================================================
   ROOT + AUTH FLOW
========================================================= */

enum SessionMode { none, user, adminMode }

class AppSession {
  SessionMode mode = SessionMode.none;
  String? username; // for user mode

  void logout() {
    mode = SessionMode.none;
    username = null;
  }
}

class GateOpsRoot extends StatefulWidget {
  const GateOpsRoot({super.key});

  @override
  State<GateOpsRoot> createState() => _GateOpsRootState();
}

class _GateOpsRootState extends State<GateOpsRoot> {
  final session = AppSession();
  late AuthData auth;

  @override
  void initState() {
    super.initState();
    auth = AuthStore.load();
  }

  void _reloadAuth() {
    setState(() => auth = AuthStore.load());
  }

  void _loginUser(String username) {
    setState(() {
      session.mode = SessionMode.user;
      session.username = username;
    });
  }

  void _loginAdmin() {
    setState(() {
      session.mode = SessionMode.adminMode;
      session.username = null;
    });
  }

  void _logout() {
    setState(() => session.logout());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gate Ops',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: Builder(
        builder: (context) {
          if (!auth.hasMaster) {
            return MasterSetupScreen(
              onDone: () {
                _reloadAuth();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Master şifre oluşturuldu. Admin Mode ile kullanıcı ekleyebilirsin.')),
                );
              },
            );
          }

          if (session.mode == SessionMode.none) {
            return LoginScreen(
              auth: auth,
              onAuthChanged: _reloadAuth,
              onUserLogin: _loginUser,
              onAdminLogin: _loginAdmin,
            );
          }

          if (session.mode == SessionMode.adminMode) {
            return AdminShell(
              auth: auth,
              onAuthChanged: _reloadAuth,
              onLogout: _logout,
            );
          }

          // user mode
          return GateOpsShell(
            username: session.username!,
            onLogout: _logout,
          );
        },
      ),
    );
  }
}

/* =========================================================
   SCREENS: MASTER SETUP / LOGIN / ADMIN
========================================================= */

class MasterSetupScreen extends StatefulWidget {
  final VoidCallback onDone;
  const MasterSetupScreen({super.key, required this.onDone});

  @override
  State<MasterSetupScreen> createState() => _MasterSetupScreenState();
}

class _MasterSetupScreenState extends State<MasterSetupScreen> {
  final p1 = TextEditingController();
  final p2 = TextEditingController();

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _save() {
    final a = p1.text;
    final b = p2.text;
    if (a != b) return _toast('Şifreler aynı değil.');
    if (!PasswordPolicy.validate(a)) return _toast(PasswordPolicy.hint());

    final salt = CryptoUtil.genSaltB64();
    final hash = CryptoUtil.hashB64Func(salt, a);

    final data = AuthData(master: MasterSecret(saltB64: salt, hashB64: hash), users: const []);
    AuthStore.save(data);
    widget.onDone();
  }

  @override
  void dispose() {
    p1.dispose();
    p2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('İlk Kurulum • Master Şifre')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'İlk kurulum: Master şifreyi bir kez oluşturacaksın.\n'
            'Sonrasında Admin Mode ile kullanıcıları (user) ekleyeceksin.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: p1,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Master şifre'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: p2,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Master şifre (tekrar)'),
          ),
          const SizedBox(height: 8),
          Text(PasswordPolicy.hint()),
          const SizedBox(height: 16),
          ElevatedButton.icon(onPressed: _save, icon: const Icon(Icons.lock), label: const Text('Master Şifreyi Oluştur')),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              // Intentional: nothing
            },
            child: const Text(''),
          ),
        ],
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  final AuthData auth;
  final VoidCallback onAuthChanged;
  final void Function(String username) onUserLogin;
  final VoidCallback onAdminLogin;

  const LoginScreen({
    super.key,
    required this.auth,
    required this.onAuthChanged,
    required this.onUserLogin,
    required this.onAdminLogin,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  late final TabController tab;

  final userCtrl = TextEditingController();
  final passCtrl = TextEditingController();

  final masterCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    tab.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
    masterCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _userLogin() {
    final u = UsernamePolicy.normalize(userCtrl.text);
    final p = passCtrl.text;

    if (!UsernamePolicy.validate(u)) return _toast(UsernamePolicy.hint());

    final rec = widget.auth.users.where((e) => e.username == u).toList();
    if (rec.isEmpty) return _toast('Kullanıcı bulunamadı.');

    final r = rec.first;
    final ok = CryptoUtil.hashB64Func(r.saltB64, p) == r.hashB64;
    if (!ok) return _toast('Şifre yanlış.');

    widget.onUserLogin(u);
  }

  void _adminLogin() {
    final p = masterCtrl.text;
    final m = widget.auth.master!;
    final ok = CryptoUtil.hashB64Func(m.saltB64, p) == m.hashB64;
    if (!ok) return _toast('Master şifre yanlış.');
    widget.onAdminLogin();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gate Ops • Giriş'),
        bottom: TabBar(
          controller: tab,
          tabs: const [
            Tab(text: 'Kullanıcı'),
            Tab(text: 'Admin Mode'),
          ],
        ),
      ),
      body: TabBarView(
        controller: tab,
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: userCtrl,
                decoration: InputDecoration(labelText: 'Kullanıcı adı (${UsernamePolicy.hint()})'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Şifre'),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _userLogin,
                icon: const Icon(Icons.login),
                label: const Text('Giriş Yap'),
              ),
              const SizedBox(height: 10),
              Text('Kullanıcı hesabı yoksa, Admin Mode ile admin kullanıcı eklemeli.'),
            ],
          ),
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Admin Mode sadece master şifre ile açılır.\nBuradan sadece USER eklenir/silinir/şifre resetlenir.'),
              const SizedBox(height: 12),
              TextField(
                controller: masterCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Master şifre'),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _adminLogin,
                icon: const Icon(Icons.admin_panel_settings),
                label: const Text('Admin Mode Aç'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class AdminShell extends StatelessWidget {
  final AuthData auth;
  final VoidCallback onAuthChanged;
  final VoidCallback onLogout;

  const AdminShell({super.key, required this.auth, required this.onAuthChanged, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Mode • Kullanıcı Yönetimi'),
        actions: [
          IconButton(onPressed: onLogout, icon: const Icon(Icons.logout), tooltip: 'Çıkış'),
        ],
      ),
      body: AdminUserManagement(auth: auth, onAuthChanged: onAuthChanged),
    );
  }
}

class AdminUserManagement extends StatefulWidget {
  final AuthData auth;
  final VoidCallback onAuthChanged;
  const AdminUserManagement({super.key, required this.auth, required this.onAuthChanged});

  @override
  State<AdminUserManagement> createState() => _AdminUserManagementState();
}

class _AdminUserManagementState extends State<AdminUserManagement> {
  final uCtrl = TextEditingController();
  final p1Ctrl = TextEditingController();
  final p2Ctrl = TextEditingController();

  @override
  void dispose() {
    uCtrl.dispose();
    p1Ctrl.dispose();
    p2Ctrl.dispose();
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _save(AuthData data) {
    AuthStore.save(data);
    widget.onAuthChanged();
    setState(() {});
  }

  void _addUser() {
    final u = UsernamePolicy.normalize(uCtrl.text);
    final p1 = p1Ctrl.text;
    final p2 = p2Ctrl.text;

    if (!UsernamePolicy.validate(u)) return _toast(UsernamePolicy.hint());
    if (p1 != p2) return _toast('Şifreler aynı değil.');
    if (!PasswordPolicy.validate(p1)) return _toast(PasswordPolicy.hint());

    final current = AuthStore.load();
    final exists = current.users.any((e) => e.username == u);
    if (exists) return _toast('Bu kullanıcı zaten var.');

    final salt = CryptoUtil.genSaltB64();
    final hash = CryptoUtil.hashB64Func(salt, p1);
    final updated = current.copyWith(users: [...current.users, UserRecord(username: u, saltB64: salt, hashB64: hash)]);

    _save(updated);
    uCtrl.clear();
    p1Ctrl.clear();
    p2Ctrl.clear();
    _toast('Kullanıcı eklendi: $u');
  }

  void _deleteUser(String username) {
    final current = AuthStore.load();
    final updated = current.copyWith(users: current.users.where((e) => e.username != username).toList());
    _save(updated);
    _toast('Silindi: $username');
  }

  void _resetPasswordDialog(String username) {
    final np1 = TextEditingController();
    final np2 = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Şifre Reset • $username'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: np1, obscureText: true, decoration: const InputDecoration(labelText: 'Yeni şifre')),
            const SizedBox(height: 8),
            TextField(controller: np2, obscureText: true, decoration: const InputDecoration(labelText: 'Yeni şifre (tekrar)')),
            const SizedBox(height: 8),
            Text(PasswordPolicy.hint(), style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('İptal')),
          ElevatedButton(
            onPressed: () {
              final a = np1.text;
              final b = np2.text;
              if (a != b) {
                _toast('Şifreler aynı değil.');
                return;
              }
              if (!PasswordPolicy.validate(a)) {
                _toast(PasswordPolicy.hint());
                return;
              }

              final current = AuthStore.load();
              final salt = CryptoUtil.genSaltB64();
              final hash = CryptoUtil.hashB64Func(salt, a);

              final updatedUsers = current.users.map((e) {
                if (e.username != username) return e;
                return UserRecord(username: e.username, saltB64: salt, hashB64: hash);
              }).toList();

              _save(current.copyWith(users: updatedUsers));
              Navigator.pop(context);
              _toast('Şifre güncellendi.');
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = AuthStore.load();
    final users = [...current.users]..sort((a, b) => a.username.compareTo(b.username));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('USER Ekle', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              TextField(
                controller: uCtrl,
                decoration: InputDecoration(labelText: 'Kullanıcı adı (${UsernamePolicy.hint()})'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: p1Ctrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Şifre'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: p2Ctrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Şifre (tekrar)'),
              ),
              const SizedBox(height: 8),
              Text(PasswordPolicy.hint(), style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 12),
              ElevatedButton.icon(onPressed: _addUser, icon: const Icon(Icons.person_add), label: const Text('Kullanıcı Ekle')),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Kullanıcılar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (users.isEmpty) const Text('Henüz kullanıcı yok.'),
        ...users.map((u) => Card(
              child: ListTile(
                title: Text(u.username),
                subtitle: const Text('Role: USER'),
                trailing: Wrap(
                  spacing: 6,
                  children: [
                    TextButton(
                      onPressed: () => _resetPasswordDialog(u.username),
                      child: const Text('Şifre Reset'),
                    ),
                    IconButton(
                      tooltip: 'Sil',
                      onPressed: () => _deleteUser(u.username),
                      icon: const Icon(Icons.delete),
                    ),
                  ],
                ),
              ),
            )),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () {
            // Danger button: reset all (optional). We'll keep it hidden but functional in MVP.
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Tüm sistemi sıfırla?'),
                content: const Text('Master şifre + tüm kullanıcılar silinir. Bu işlem geri alınamaz.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('İptal')),
                  ElevatedButton(
                    onPressed: () {
                      AuthStore.clearAll();
                      widget.onAuthChanged();
                      Navigator.pop(context);
                      _toast('Sistem sıfırlandı. Sayfayı yenileyin.');
                    },
                    child: const Text('Sıfırla'),
                  ),
                ],
              ),
            );
          },
          icon: const Icon(Icons.delete_forever),
          label: const Text('Tüm Sistemi Sıfırla (Dikkat)'),
        ),
      ],
    );
  }
}

/* =========================================================
   GATE OPS SHELL (existing app)
========================================================= */

class GateOpsShell extends StatefulWidget {
  final String username;
  final VoidCallback onLogout;

  const GateOpsShell({super.key, required this.username, required this.onLogout});

  @override
  State<GateOpsShell> createState() => _GateOpsShellState();
}

class _GateOpsShellState extends State<GateOpsShell> {
  final session = FlightSession();

  @override
  Widget build(BuildContext context) {
    return session.isCreated
        ? FlightDetailScreen(
            session: session,
            username: widget.username,
            onReset: () => setState(() => session.clearAll()),
            onLogout: widget.onLogout,
          )
        : FlightCreateScreen(
            username: widget.username,
            session: session,
            onLogout: widget.onLogout,
            onCreated: (_) => setState(() {}),
          );
  }
}

/* =========================================================
   MODELS / OPS STATE (Gate)
========================================================= */

enum StaffRole { supervisor, asMale, asFemale, other }

extension StaffRoleLabel on StaffRole {
  String get label {
    switch (this) {
      case StaffRole.supervisor:
        return 'Supervisor';
      case StaffRole.asMale:
        return 'AS Erkek';
      case StaffRole.asFemale:
        return 'AS Kadın';
      case StaffRole.other:
        return 'Diğer';
    }
  }
}

class StaffAssignment {
  final String name;
  final StaffRole role;
  final String start; // HH:MM
  final String end; // HH:MM

  StaffAssignment({required this.name, required this.role, required this.start, required this.end});

  int totalMinutes() {
    final s = _parseHHMM(start);
    final e = _parseHHMM(end);
    if (s == null || e == null) return 0;
    final diff = e - s;
    return diff < 0 ? 0 : diff;
  }
}

enum EtdModel { is600, fourDX }

extension EtdModelLabel on EtdModel {
  String get label => this == EtdModel.is600 ? 'IS600' : '4DX';
}

class EtdDevice {
  final EtdModel model;
  final String serialNo;
  EtdDevice({required this.model, required this.serialNo});
}

class Passenger {
  final String nameNorm;
  final String nameDisplay;
  final String seat;
  final DateTime scannedAt;

  Passenger({required this.nameNorm, required this.nameDisplay, required this.seat, required this.scannedAt});
}

class PassengerEvent {
  final Passenger passenger;
  final bool watchlistHit;
  bool dftSelected;
  bool dftSearched;

  PassengerEvent({required this.passenger, required this.watchlistHit, required this.dftSelected, required this.dftSearched});
}

class NameParts {
  final String surname;
  final String firstNameToken;

  NameParts({required this.surname, required this.firstNameToken});

  static NameParts fromNormalized(String nameNorm) {
    final tokens = nameNorm.split(' ').where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return NameParts(surname: '', firstNameToken: '');
    if (tokens.length == 1) return NameParts(surname: tokens[0], firstNameToken: '');
    return NameParts(surname: tokens[0], firstNameToken: tokens[1]);
  }

  static String? reverseTokens(String nameNorm) {
    final tokens = nameNorm.split(' ').where((t) => t.isNotEmpty).toList();
    if (tokens.length < 2) return null;
    return (tokens.sublist(1)..add(tokens[0])).join(' ');
  }
}

class FlightSession {
  // Flight basics
  String flightCode = '';
  int bookedPax = 0;
  String gateNo = '';
  String gateAssignStart = ''; // HH:MM

  // Ops times
  String? gateSetupTime;
  String? firstPaxTime;
  String? lastPaxTime;
  String? dutyStart;
  String? dutyEnd;

  // Lists
  final Set<String> watchlist = {}; // normalized names
  final Map<String, NameParts> watchlistParts = {}; // normalized name -> parts

  final List<StaffAssignment> staff = [];
  final Set<String> tableSerials = {};
  final Set<String> deskSerials = {};
  final List<EtdDevice> etdDevices = [];

  // Scans keyed by unique key
  final Map<String, PassengerEvent> scans = {};

  bool get isCreated => flightCode.isNotEmpty;

  void clearAll() {
    flightCode = '';
    bookedPax = 0;
    gateNo = '';
    gateAssignStart = '';

    gateSetupTime = null;
    firstPaxTime = null;
    lastPaxTime = null;
    dutyStart = null;
    dutyEnd = null;

    watchlist.clear();
    watchlistParts.clear();
    staff.clear();
    tableSerials.clear();
    deskSerials.clear();
    etdDevices.clear();
    scans.clear();
  }

  void create({required String flightCodeInput, required int booked, required String gate, required String start}) {
    flightCode = normalizeFlight(flightCodeInput);
    bookedPax = booked;
    gateNo = gate.trim().toUpperCase();
    gateAssignStart = start.trim();
  }

  void rebuildWatchlistParts() {
    watchlistParts.clear();
    for (final n in watchlist) {
      watchlistParts[n] = NameParts.fromNormalized(n);
    }
  }

  bool isWatchlistHit(String scannedNameNorm) {
    if (watchlist.isEmpty) return false;
    if (watchlist.contains(scannedNameNorm)) return true;

    final scanned = NameParts.fromNormalized(scannedNameNorm);
    if (scanned.surname.isEmpty || scanned.firstNameToken.isEmpty) {
      final reversed = NameParts.reverseTokens(scannedNameNorm);
      if (reversed != null && watchlist.contains(reversed)) return true;
      return false;
    }

    for (final wp in watchlistParts.values) {
      if (wp.surname == scanned.surname && wp.firstNameToken == scanned.firstNameToken) return true;
    }

    final reversed = NameParts.reverseTokens(scannedNameNorm);
    if (reversed != null && watchlist.contains(reversed)) return true;

    return false;
  }

  void addStaff(StaffAssignment s) => staff.add(s);

  void removeStaffAt(int index) {
    if (index >= 0 && index < staff.length) staff.removeAt(index);
  }

  bool addTableSerial(String serial) {
    final s = serial.trim().toUpperCase();
    if (s.isEmpty) return false;
    final before = tableSerials.length;
    tableSerials.add(s);
    return tableSerials.length > before;
  }

  bool addDeskSerial(String serial) {
    final s = serial.trim().toUpperCase();
    if (s.isEmpty) return false;
    final before = deskSerials.length;
    deskSerials.add(s);
    return deskSerials.length > before;
  }

  void removeTableSerial(String serial) => tableSerials.remove(serial);
  void removeDeskSerial(String serial) => deskSerials.remove(serial);

  void addEtd(EtdDevice etd) {
    final sn = etd.serialNo.trim().toUpperCase();
    if (sn.isEmpty) throw ArgumentError('ETD seri no zorunlu');
    final exists = etdDevices.any((e) => e.serialNo.toUpperCase() == sn);
    if (exists) throw ArgumentError('ETD seri no duplicate: $sn');
    etdDevices.add(EtdDevice(model: etd.model, serialNo: sn));
  }

  void removeEtdAt(int index) {
    if (index >= 0 && index < etdDevices.length) etdDevices.removeAt(index);
  }

  ScanResult onMockScan(String mock) {
    // mock format: FLIGHT|NAME|SEAT
    final parts = mock.split('|');
    if (parts.length < 3) return ScanResult(ScanResultType.error, 'Format: FLIGHT|NAME|SEAT');

    final scannedFlight = normalizeFlight(parts[0]);
    final nameNorm = normalizeName(parts[1]);
    final seat = parts[2].trim().toUpperCase();

    if (scannedFlight != flightCode) {
      return ScanResult(ScanResultType.wrongFlight, 'Yanlış uçuş: $scannedFlight (beklenen $flightCode)');
    }

    if (firstPaxTime == null) firstPaxTime = _nowHHMM();

    final key = '$flightCode|$nameNorm|$seat';
    if (scans.containsKey(key)) {
      return ScanResult(ScanResultType.duplicate, 'Zaten okutuldu', passenger: scans[key]!.passenger);
    }

    final p = Passenger(nameNorm: nameNorm, nameDisplay: nameNorm, seat: seat, scannedAt: DateTime.now());

    final hit = isWatchlistHit(nameNorm);
    scans[key] = PassengerEvent(passenger: p, watchlistHit: hit, dftSelected: false, dftSearched: false);

    lastPaxTime = _nowHHMM();

    if (hit) return ScanResult(ScanResultType.watchlistHit, 'Watchlist yolcu tespit edildi', passenger: p);
    return ScanResult(ScanResultType.ok, 'OK', passenger: p);
  }

  void toggleDftSelected(String scanKey) {
    final e = scans[scanKey];
    if (e == null) return;
    e.dftSelected = !e.dftSelected;
  }

  void toggleDftSearched(String scanKey) {
    final e = scans[scanKey];
    if (e == null) return;
    e.dftSearched = !e.dftSearched;
  }

  Stats getStats() {
    final arrived = scans.length;
    final notArrived = max(0, bookedPax - arrived);

    int wlArrived = 0;
    final arrivedNames = <String>{};
    for (final e in scans.values) {
      arrivedNames.add(e.passenger.nameNorm);
      if (e.watchlistHit) wlArrived++;
    }
    final wlTotal = watchlist.length;
    final wlNotArrived = max(0, wlTotal - wlArrived);
    final wlMissing = watchlist.where((n) => !arrivedNames.contains(n)).toList()..sort();

    int dftSel = 0, dftSea = 0;
    for (final e in scans.values) {
      if (e.dftSelected) dftSel++;
      if (e.dftSearched) dftSea++;
    }
    final dftRate = arrived == 0 ? 0.0 : (dftSea / arrived) * 100.0;

    return Stats(
      arrived: arrived,
      notArrived: notArrived,
      watchlistTotal: wlTotal,
      watchlistArrived: wlArrived,
      watchlistNotArrived: wlNotArrived,
      watchlistMissing: wlMissing,
      dftSelected: dftSel,
      dftSearched: dftSea,
      dftRatePercent: dftRate,
    );
  }

  Map<String, dynamic> buildSummaryRow({required String byUser}) {
    final s = getStats();
    return {
      'FlightCode': flightCode,
      'GateNo': gateNo,
      'GateAssignStart': gateAssignStart,
      'BookedPax': bookedPax,
      'ArrivedCount': s.arrived,
      'NotArrivedCount': s.notArrived,
      'WatchlistTotal': s.watchlistTotal,
      'WatchlistArrived': s.watchlistArrived,
      'WatchlistNotArrived': s.watchlistNotArrived,
      'DFT_Selected_Count': s.dftSelected,
      'DFT_Searched_Count': s.dftSearched,
      'DFT_Search_Rate_%': double.parse(s.dftRatePercent.toStringAsFixed(1)),
      'GateSetupTime': gateSetupTime,
      'FirstPaxTime': firstPaxTime,
      'LastPaxTime': lastPaxTime,
      'DutyStart': dutyStart,
      'DutyEnd': dutyEnd,
      'RecordedBy': byUser,
    };
  }

  List<Map<String, dynamic>> buildStaffRows() {
    return staff
        .map((s) => {
              'FlightCode': flightCode,
              'PersonName': s.name,
              'Role': s.role.label,
              'Start': s.start,
              'End': s.end,
              'TotalMinutes': s.totalMinutes(),
            })
        .toList();
  }

  List<Map<String, dynamic>> buildEquipmentRows() {
    final rows = <Map<String, dynamic>>[];
    for (final t in tableSerials) {
      rows.add({'FlightCode': flightCode, 'Type': 'TABLE', 'Model': null, 'SerialNumber': t});
    }
    for (final d in deskSerials) {
      rows.add({'FlightCode': flightCode, 'Type': 'DESK', 'Model': null, 'SerialNumber': d});
    }
    for (final e in etdDevices) {
      rows.add({'FlightCode': flightCode, 'Type': 'ETD', 'Model': e.model.label, 'SerialNumber': e.serialNo.toUpperCase()});
    }
    return rows;
  }

  List<Map<String, dynamic>> buildDftRows() {
    final rows = <Map<String, dynamic>>[];
    for (final entry in scans.entries) {
      final e = entry.value;
      if (e.dftSelected || e.dftSearched) {
        rows.add({
          'FlightCode': flightCode,
          'PassengerName': e.passenger.nameDisplay,
          'Seat': e.passenger.seat,
          'DFT_Selected': e.dftSelected ? 'Y' : 'N',
          'DFT_Searched': e.dftSearched ? 'Y' : 'N',
          'ScanTime': _hhmm(e.passenger.scannedAt),
        });
      }
    }
    return rows;
  }
}

class Stats {
  final int arrived;
  final int notArrived;
  final int watchlistTotal;
  final int watchlistArrived;
  final int watchlistNotArrived;
  final List<String> watchlistMissing;
  final int dftSelected;
  final int dftSearched;
  final double dftRatePercent;

  Stats({
    required this.arrived,
    required this.notArrived,
    required this.watchlistTotal,
    required this.watchlistArrived,
    required this.watchlistNotArrived,
    required this.watchlistMissing,
    required this.dftSelected,
    required this.dftSearched,
    required this.dftRatePercent,
  });
}

enum ScanResultType { ok, wrongFlight, duplicate, watchlistHit, error }

class ScanResult {
  final ScanResultType type;
  final String message;
  final Passenger? passenger;

  ScanResult(this.type, this.message, {this.passenger});
}

/* =========================================================
   UI (Gate Ops) — Create / Detail / Tabs
========================================================= */

class FlightCreateScreen extends StatefulWidget {
  final String username;
  final FlightSession session;
  final VoidCallback onLogout;
  final void Function(FlightSession) onCreated;

  const FlightCreateScreen({
    super.key,
    required this.username,
    required this.session,
    required this.onLogout,
    required this.onCreated,
  });

  @override
  State<FlightCreateScreen> createState() => _FlightCreateScreenState();
}

class _FlightCreateScreenState extends State<FlightCreateScreen> {
  final flightCtrl = TextEditingController();
  final bookedCtrl = TextEditingController();
  final gateCtrl = TextEditingController();
  final startCtrl = TextEditingController();

  bool _validHHMM(String s) {
    final r = RegExp(r'^\d{2}:\d{2}$');
    if (!r.hasMatch(s)) return false;
    final hh = int.tryParse(s.substring(0, 2));
    final mm = int.tryParse(s.substring(3, 5));
    if (hh == null || mm == null) return false;
    return hh >= 0 && hh <= 23 && mm >= 0 && mm <= 59;
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  void dispose() {
    flightCtrl.dispose();
    bookedCtrl.dispose();
    gateCtrl.dispose();
    startCtrl.dispose();
    super.dispose();
  }

  void _create() {
    final flight = flightCtrl.text.trim();
    final booked = int.tryParse(bookedCtrl.text.trim()) ?? -1;
    final gate = gateCtrl.text.trim();
    final s = startCtrl.text.trim();

    if (flight.isEmpty || gate.isEmpty || booked < 0) return _toast('Flight / Booked / Gate zorunlu');
    if (!_validHHMM(s)) return _toast('Gate tahsis başlangıç saati HH:MM olmalı');

    widget.session.create(flightCodeInput: flight, booked: booked, gate: gate, start: s);
    widget.onCreated(widget.session);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Uçuş Oluştur • ${widget.username}'),
        actions: [
          IconButton(onPressed: widget.onLogout, icon: const Icon(Icons.logout), tooltip: 'Çıkış'),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: flightCtrl, decoration: const InputDecoration(labelText: 'Flight Code (örn: BA679)')),
          const SizedBox(height: 12),
          TextField(
            controller: bookedCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Rezervasyonlu yolcu (Booked Pax)'),
          ),
          const SizedBox(height: 12),
          TextField(controller: gateCtrl, decoration: const InputDecoration(labelText: 'Gate No (örn: A12)')),
          const SizedBox(height: 12),
          TextField(controller: startCtrl, decoration: const InputDecoration(labelText: 'Gate tahsis başlangıç (HH:MM)')),
          const SizedBox(height: 20),
          ElevatedButton.icon(onPressed: _create, icon: const Icon(Icons.playlist_add), label: const Text('Uçuşu Başlat')),
          const SizedBox(height: 12),
          const Text('Not: Bu MVP RAM’de çalışır. Sayfayı yenilersen uçuş verileri silinir.'),
        ],
      ),
    );
  }
}

class FlightDetailScreen extends StatefulWidget {
  final FlightSession session;
  final String username;
  final VoidCallback onReset;
  final VoidCallback onLogout;

  const FlightDetailScreen({
    super.key,
    required this.session,
    required this.username,
    required this.onReset,
    required this.onLogout,
  });

  @override
  State<FlightDetailScreen> createState() => _FlightDetailScreenState();
}

class _FlightDetailScreenState extends State<FlightDetailScreen> with SingleTickerProviderStateMixin {
  late final TabController tab;

  @override
  void initState() {
    super.initState();
    tab = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session.getStats();

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.session.flightCode} • Gate ${widget.session.gateNo}'),
        actions: [
          IconButton(onPressed: widget.onLogout, icon: const Icon(Icons.logout), tooltip: 'Çıkış'),
          IconButton(tooltip: 'Uçuşu sıfırla', onPressed: widget.onReset, icon: const Icon(Icons.refresh)),
        ],
        bottom: TabBar(
          controller: tab,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Dashboard'),
            Tab(text: 'Watchlist'),
            Tab(text: 'Scan'),
            Tab(text: 'Personel'),
            Tab(text: 'Ekipman'),
          ],
        ),
      ),
      body: TabBarView(
        controller: tab,
        children: [
          _DashboardTab(session: widget.session, username: widget.username),
          _WatchlistTab(session: widget.session, onChanged: () => setState(() {})),
          _ScanTab(session: widget.session, onChanged: () => setState(() {})),
          _StaffTab(session: widget.session, onChanged: () => setState(() {})),
          _EquipmentTab(session: widget.session, onChanged: () => setState(() {})),
        ],
      ),
      bottomNavigationBar: _BottomSummaryBar(stats: s),
    );
  }
}

class _BottomSummaryBar extends StatelessWidget {
  final Stats stats;
  const _BottomSummaryBar({required this.stats});

  @override
  Widget build(BuildContext context) {
    final dft = '${stats.dftSearched}/${stats.arrived} (${stats.dftRatePercent.toStringAsFixed(1)}%)';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 8,
        children: [
          Chip(label: Text('Gelen: ${stats.arrived}')),
          Chip(label: Text('Kalan: ${stats.notArrived}')),
          Chip(label: Text('Watchlist: ${stats.watchlistArrived}/${stats.watchlistTotal}')),
          Chip(label: Text('DFT: $dft')),
        ],
      ),
    );
  }
}

class _DashboardTab extends StatefulWidget {
  final FlightSession session;
  final String username;
  const _DashboardTab({required this.session, required this.username});

  @override
  State<_DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<_DashboardTab> {
  final gateSetupCtrl = TextEditingController();
  final dutyStartCtrl = TextEditingController();
  final dutyEndCtrl = TextEditingController();

  @override
  void dispose() {
    gateSetupCtrl.dispose();
    dutyStartCtrl.dispose();
    dutyEndCtrl.dispose();
    super.dispose();
  }

  void _saveTimes() {
    widget.session.gateSetupTime = gateSetupCtrl.text.trim().isEmpty ? null : gateSetupCtrl.text.trim();
    widget.session.dutyStart = dutyStartCtrl.text.trim().isEmpty ? null : dutyStartCtrl.text.trim();
    widget.session.dutyEnd = dutyEndCtrl.text.trim().isEmpty ? null : dutyEndCtrl.text.trim();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kaydedildi')));
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final stats = session.getStats();

    gateSetupCtrl.text = session.gateSetupTime ?? '';
    dutyStartCtrl.text = session.dutyStart ?? '';
    dutyEndCtrl.text = session.dutyEnd ?? '';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Recorded By: ${widget.username}'),
              const SizedBox(height: 8),
              Text('Booked Pax: ${session.bookedPax}', style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 8),
              Text('Gelen: ${stats.arrived}  |  Kalan: ${stats.notArrived}', style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 8),
              Text('Gate Tahsis Başlangıç: ${session.gateAssignStart}'),
              const SizedBox(height: 8),
              Text('İlk yolcu müracaat: ${session.firstPaxTime ?? "-"}'),
              Text('Son yolcu müracaat: ${session.lastPaxTime ?? "-"}'),
              const SizedBox(height: 8),
              Text('Watchlist: ${stats.watchlistArrived}/${stats.watchlistTotal}'),
              Text('DFT: ${stats.dftSearched}/${stats.arrived} (${stats.dftRatePercent.toStringAsFixed(1)}%)'),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Operasyon Saatleri', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              TextField(controller: gateSetupCtrl, decoration: const InputDecoration(labelText: 'Gate kurulum saati (HH:MM)')),
              const SizedBox(height: 12),
              TextField(controller: dutyStartCtrl, decoration: const InputDecoration(labelText: 'Görev başlangıç (HH:MM)')),
              const SizedBox(height: 12),
              TextField(controller: dutyEndCtrl, decoration: const InputDecoration(labelText: 'Görev bitiş (HH:MM)')),
              const SizedBox(height: 12),
              ElevatedButton.icon(onPressed: _saveTimes, icon: const Icon(Icons.save), label: const Text('Kaydet')),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Rapor Önizleme (Excel satırları)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Text('Flight_Summary Row:\n${session.buildSummaryRow(byUser: widget.username)}'),
              const SizedBox(height: 10),
              Text('Staff Rows: ${session.buildStaffRows().length}'),
              Text('Equipment Rows: ${session.buildEquipmentRows().length}'),
              Text('DFT Rows: ${session.buildDftRows().length}'),
            ]),
          ),
        ),
      ],
    );
  }
}

class _WatchlistTab extends StatefulWidget {
  final FlightSession session;
  final VoidCallback onChanged;
  const _WatchlistTab({required this.session, required this.onChanged});

  @override
  State<_WatchlistTab> createState() => _WatchlistTabState();
}

class _WatchlistTabState extends State<_WatchlistTab> {
  final nameCtrl = TextEditingController();

  @override
  void dispose() {
    nameCtrl.dispose();
    super.dispose();
  }

  void _add() {
    final raw = nameCtrl.text.trim();
    if (raw.isEmpty) return;
    if (widget.session.watchlist.length >= 10) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Watchlist max 10 kişi')));
      return;
    }
    widget.session.watchlist.add(normalizeName(raw));
    widget.session.rebuildWatchlistParts();
    nameCtrl.clear();
    widget.onChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final wl = widget.session.watchlist.toList()..sort();
    final stats = widget.session.getStats();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Watchlist: ${stats.watchlistArrived}/${stats.watchlistTotal}', style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 8),
              if (stats.watchlistMissing.isNotEmpty) Text('Gelmeyen: ${stats.watchlistMissing.join(", ")}'),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'İsim ekle (örn: LILLEY DAVID)'))),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: _add, child: const Text('Ekle')),
          ],
        ),
        const SizedBox(height: 12),
        if (wl.isEmpty) const Text('Watchlist boş.'),
        ...wl.map((n) => ListTile(
              title: Text(n),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () {
                  widget.session.watchlist.remove(n);
                  widget.session.rebuildWatchlistParts();
                  widget.onChanged();
                  setState(() {});
                },
              ),
            )),
      ],
    );
  }
}

class _ScanTab extends StatefulWidget {
  final FlightSession session;
  final VoidCallback onChanged;
  const _ScanTab({required this.session, required this.onChanged});

  @override
  State<_ScanTab> createState() => _ScanTabState();
}

class _ScanTabState extends State<_ScanTab> {
  final mockCtrl = TextEditingController(text: 'BA679|AKBULUT/FATIH MR|2D');
  ScanResult? last;

  @override
  void dispose() {
    mockCtrl.dispose();
    super.dispose();
  }

  Color _resultColor(ScanResultType t, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (t) {
      case ScanResultType.ok:
        return cs.primaryContainer;
      case ScanResultType.watchlistHit:
        return cs.tertiaryContainer;
      case ScanResultType.wrongFlight:
      case ScanResultType.duplicate:
      case ScanResultType.error:
        return cs.errorContainer;
    }
  }

  void _scan() {
    final r = widget.session.onMockScan(mockCtrl.text.trim());
    setState(() => last = r);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final entries = session.scans.entries.toList().reversed.toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Mock Scan', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text('Format: FLIGHT|NAME|SEAT (örn: BA679|LILLEY/DAVID MR|12A)'),
              const SizedBox(height: 12),
              TextField(controller: mockCtrl),
              const SizedBox(height: 12),
              ElevatedButton.icon(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan')),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        if (last != null)
          Card(
            color: _resultColor(last!.type, context),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Sonuç: ${last!.type.name.toUpperCase()}'),
                Text(last!.message),
                if (last!.passenger != null) Text('Yolcu: ${last!.passenger!.nameDisplay} • Seat: ${last!.passenger!.seat}'),
              ]),
            ),
          ),
        const SizedBox(height: 12),
        const Text('Tarananlar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (entries.isEmpty) const Text('Henüz tarama yok.'),
        ...entries.map((e) {
          final key = e.key;
          final ev = e.value;
          return Card(
            child: ListTile(
              title: Text('${ev.passenger.nameDisplay} • ${ev.passenger.seat}'),
              subtitle: Text('Scan: ${_hhmm(ev.passenger.scannedAt)}${ev.watchlistHit ? " • Watchlist" : ""}'),
              trailing: Wrap(
                spacing: 6,
                children: [
                  FilterChip(
                    label: const Text('DFT Seç'),
                    selected: ev.dftSelected,
                    onSelected: (_) {
                      setState(() => session.toggleDftSelected(key));
                      widget.onChanged();
                    },
                  ),
                  FilterChip(
                    label: const Text('DFT Arandı'),
                    selected: ev.dftSearched,
                    onSelected: (_) {
                      setState(() => session.toggleDftSearched(key));
                      widget.onChanged();
                    },
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _StaffTab extends StatefulWidget {
  final FlightSession session;
  final VoidCallback onChanged;
  const _StaffTab({required this.session, required this.onChanged});

  @override
  State<_StaffTab> createState() => _StaffTabState();
}

class _StaffTabState extends State<_StaffTab> {
  final nameCtrl = TextEditingController();
  final startCtrl = TextEditingController(text: '05:45');
  final endCtrl = TextEditingController(text: '09:00');
  StaffRole role = StaffRole.other;

  @override
  void dispose() {
    nameCtrl.dispose();
    startCtrl.dispose();
    endCtrl.dispose();
    super.dispose();
  }

  void _add() {
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    widget.session.addStaff(StaffAssignment(name: name, role: role, start: startCtrl.text.trim(), end: endCtrl.text.trim()));
    nameCtrl.clear();
    widget.onChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.session.staff;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Personel Ekle', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Ad Soyad')),
              const SizedBox(height: 12),
              DropdownButtonFormField<StaffRole>(
                value: role,
                decoration: const InputDecoration(labelText: 'Rol'),
                items: StaffRole.values.map((r) => DropdownMenuItem(value: r, child: Text(r.label))).toList(),
                onChanged: (v) => setState(() => role = v ?? StaffRole.other),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: TextField(controller: startCtrl, decoration: const InputDecoration(labelText: 'Başlangıç (HH:MM)'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: endCtrl, decoration: const InputDecoration(labelText: 'Bitiş (HH:MM)'))),
                ],
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(onPressed: _add, icon: const Icon(Icons.person_add), label: const Text('Ekle')),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Personel Listesi', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (list.isEmpty) const Text('Personel yok.'),
        ...List.generate(list.length, (i) {
          final s = list[i];
          return ListTile(
            title: Text('${s.name} • ${s.role.label}'),
            subtitle: Text('${s.start}–${s.end} • ${s.totalMinutes()} dk'),
            trailing: IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () {
                widget.session.removeStaffAt(i);
                widget.onChanged();
                setState(() {});
              },
            ),
          );
        }),
      ],
    );
  }
}

class _EquipmentTab extends StatefulWidget {
  final FlightSession session;
  final VoidCallback onChanged;
  const _EquipmentTab({required this.session, required this.onChanged});

  @override
  State<_EquipmentTab> createState() => _EquipmentTabState();
}

class _EquipmentTabState extends State<_EquipmentTab> {
  final tableCtrl = TextEditingController();
  final deskCtrl = TextEditingController();
  final etdSerialCtrl = TextEditingController();
  EtdModel etdModel = EtdModel.is600;

  @override
  void dispose() {
    tableCtrl.dispose();
    deskCtrl.dispose();
    etdSerialCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _addTable() {
    final ok = widget.session.addTableSerial(tableCtrl.text);
    if (!ok) _toast('Bu masa seri no zaten ekli (veya boş).');
    tableCtrl.clear();
    widget.onChanged();
    setState(() {});
  }

  void _addDesk() {
    final ok = widget.session.addDeskSerial(deskCtrl.text);
    if (!ok) _toast('Bu desk seri no zaten ekli (veya boş).');
    deskCtrl.clear();
    widget.onChanged();
    setState(() {});
  }

  void _addEtd() {
    try {
      widget.session.addEtd(EtdDevice(model: etdModel, serialNo: etdSerialCtrl.text));
      etdSerialCtrl.clear();
      widget.onChanged();
      setState(() {});
    } catch (e) {
      _toast(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tables = widget.session.tableSerials.toList()..sort();
    final desks = widget.session.deskSerials.toList()..sort();
    final etds = widget.session.etdDevices;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Masa (Serial No)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: tableCtrl, decoration: const InputDecoration(labelText: 'Masa seri no'))),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: _addTable, child: const Text('Ekle')),
              ]),
              const SizedBox(height: 10),
              if (tables.isEmpty) const Text('Masa yok.'),
              ...tables.map((t) => ListTile(
                    dense: true,
                    title: Text(t),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () {
                        widget.session.removeTableSerial(t);
                        widget.onChanged();
                        setState(() {});
                      },
                    ),
                  )),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Desk (Serial No)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: deskCtrl, decoration: const InputDecoration(labelText: 'Desk seri no'))),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: _addDesk, child: const Text('Ekle')),
              ]),
              const SizedBox(height: 10),
              if (desks.isEmpty) const Text('Desk yok.'),
              ...desks.map((d) => ListTile(
                    dense: true,
                    title: Text(d),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () {
                        widget.session.removeDeskSerial(d);
                        widget.onChanged();
                        setState(() {});
                      },
                    ),
                  )),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('ETD (Model + Seri No)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              DropdownButtonFormField<EtdModel>(
                value: etdModel,
                decoration: const InputDecoration(labelText: 'Model'),
                items: EtdModel.values.map((m) => DropdownMenuItem(value: m, child: Text(m.label))).toList(),
                onChanged: (v) => setState(() => etdModel = v ?? EtdModel.is600),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: etdSerialCtrl, decoration: const InputDecoration(labelText: 'ETD seri no (zorunlu)'))),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: _addEtd, child: const Text('Ekle')),
              ]),
              const SizedBox(height: 10),
              if (etds.isEmpty) const Text('ETD yok.'),
              ...List.generate(etds.length, (i) {
                final e = etds[i];
                return ListTile(
                  dense: true,
                  title: Text('${e.model.label} • ${e.serialNo}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () {
                      widget.session.removeEtdAt(i);
                      widget.onChanged();
                      setState(() {});
                    },
                  ),
                );
              }),
            ]),
          ),
        ),
      ],
    );
  }
}

/* =========================================================
   Helpers
========================================================= */

String normalizeFlight(String input) => input.toUpperCase().replaceAll(' ', '').trim();

String normalizeName(String input) {
  var s = input.trim().toUpperCase();

  const map = {
    'İ': 'I',
    'İ': 'I',
    'Ş': 'S',
    'Ğ': 'G',
    'Ü': 'U',
    'Ö': 'O',
    'Ç': 'C',
    'Â': 'A',
    'Ê': 'E',
    'Î': 'I',
    'Ô': 'O',
    'Û': 'U',
  };
  map.forEach((k, v) => s = s.replaceAll(k, v));

  const titles = [' MR', ' MRS', ' MS', ' MISS', ' MSTR', ' DR', ' PROF', ' SIR', ' MADAM', ' CHD', ' INF'];
  for (final t in titles) {
    s = s.replaceAll(t, '');
  }

  s = s.replaceAll('/', ' ');
  s = s.replaceAll(RegExp(r'[^A-Z0-9 ]'), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  return s;
}

String _nowHHMM() => _hhmm(DateTime.now());

String _hhmm(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

int? _parseHHMM(String s) {
  final m = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(s.trim());
  if (m == null) return null;
  final hh = int.parse(m.group(1)!);
  final mm = int.parse(m.group(2)!);
  if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return null;
  return hh * 60 + mm;
}
