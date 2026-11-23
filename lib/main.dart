import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:photo_manager/photo_manager.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

const kAdminPass = 'hamzanjar8000.H';
const kVaultPass = 'hamzanjar8000.H80008000';
const kDomain = '@riwaya.app';

final db = FirebaseFirestore.instance;
final auth = FirebaseAuth.instance;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await S.init();
  runApp(const App());
}

class S extends ChangeNotifier {
  static final S i = S._();
  S._();
  static late SharedPreferences p;

  static Future<void> init() async {
    p = await SharedPreferences.getInstance();
    i.seedIdx = p.getInt('seed') ?? 0;
    i.baseFont = p.getDouble('font') ?? 18;
    i.aiProvider = p.getString('ai_p') ?? 'https://api.openai.com/v1';
    i.aiModel = p.getString('ai_m') ?? 'gpt-4o-mini';
    i.aiKey = p.getString('ai_k') ?? '';
    i.wikiSite = p.getString('w_s') ?? 'ar.wikisource.org';
    i.wikiUser = p.getString('w_u') ?? '';
    i.wikiPass = p.getString('w_p') ?? '';
    try {
      await Firebase.initializeApp();
      final u = auth.currentUser;
      if (u != null) await i.loadProfile(u.uid);
    } catch (_) {}
    unawaited(Gal.sync());
  }

  int seedIdx = 0;
  double baseFont = 18;
  String aiProvider = '', aiModel = '', aiKey = '';
  String wikiSite = '', wikiUser = '', wikiPass = '';
  String uid = '', handle = '', name = '', bio = '', avatar = '';
  bool admin = false;

  bool get logged => uid.isNotEmpty;
  Color get seed => seeds[seedIdx % seeds.length];

  Future<void> savePrefs() async {
    await p.setInt('seed', seedIdx);
    await p.setDouble('font', baseFont);
    await p.setString('ai_p', aiProvider);
    await p.setString('ai_m', aiModel);
    await p.setString('ai_k', aiKey);
    await p.setString('w_s', wikiSite);
    await p.setString('w_u', wikiUser);
    await p.setString('w_p', wikiPass);
    notifyListeners();
  }

  Future<void> loadProfile(String id) async {
    final d = await db.collection('users').doc(id).get();
    final m = d.data() ?? {};
    uid = id;
    handle = m['handle'] ?? '';
    name = m['name'] ?? '';
    bio = m['bio'] ?? '';
    avatar = m['avatar'] ?? '';
    notifyListeners();
  }

  Future<String?> signUp(String h, String nm, String pass) async {
    final hl = h.trim().toLowerCase().replaceAll(' ', '');
    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(hl)) return 'المعرّف: 3-20 حرفاً لاتينياً أو رقماً';
    if (pass.length < 6) return 'كلمة المرور 6 أحرف على الأقل';
    if (nm.trim().isEmpty) return 'أدخل اسماً';
    final ex = await db.collection('users').where('handle', isEqualTo: hl).limit(1).get();
    if (ex.docs.isNotEmpty) return 'المعرّف محجوز';
    try {
      final c = await auth.createUserWithEmailAndPassword(email: '$hl$kDomain', password: pass);
      await db.collection('users').doc(c.user!.uid).set({'handle': hl, 'name': nm.trim(), 'bio': '', 'avatar': ''});
      await loadProfile(c.user!.uid);
      return null;
    } on FirebaseAuthException catch (e) {
      return e.code == 'email-already-in-use' ? 'المعرّف محجوز' : 'تعذر إنشاء الحساب (${e.code})';
    } catch (_) { return 'تعذر الاتصال'; }
  }

  Future<String?> login(String h, String pass) async {
    final hl = h.trim().toLowerCase().replaceAll(' ', '');
    try {
      final c = await auth.signInWithEmailAndPassword(email: '$hl$kDomain', password: pass);
      await loadProfile(c.user!.uid);
      return null;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found') return 'لا يوجد حساب';
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') return 'كلمة المرور خاطئة';
      return 'تعذر الدخول (${e.code})';
    } catch (_) { return 'تعذر الاتصال'; }
  }

  Future<void> logout() async {
    try { await auth.signOut(); } catch (_) {}
    uid = ''; handle = ''; name = ''; bio = ''; avatar = ''; admin = false;
    notifyListeners();
  }

  Future<void> profile({String? nm, String? b}) async {
    if (nm != null) name = nm;
    if (b != null) bio = b;
    notifyListeners();
    await db.collection('users').doc(uid).update({'name': name, 'bio': bio});
  }

  Future<void> uploadAvatar(File f) async {
    final r = FirebaseStorage.instance.ref('avatars/$uid/a.jpg');
    await r.putFile(f);
    final url = await r.getDownloadURL();
    avatar = url;
    notifyListeners();
    await db.collection('users').doc(uid).update({'avatar': url});
  }

  Future<void> sendReq(String targetUid, String myHandle, String myName) async {
    await db.collection('users').doc(targetUid).collection('requests').doc(uid).set({'handle': myHandle, 'name': myName});
  }

  Future<void> accept(String fromUid, String fromHandle, String fromName) async {
    await db.collection('users').doc(uid).collection('friends').doc(fromUid).set({'handle': fromHandle, 'name': fromName});
    await db.collection('users').doc(fromUid).collection('friends').doc(uid).set({'handle': handle, 'name': name});
    await db.collection('users').doc(uid).collection('requests').doc(fromUid).delete();
  }

  Future<void> reject(String fromUid) async {
    await db.collection('users').doc(uid).collection('requests').doc(fromUid).delete();
  }

  static String chatId(String a, String b) => a.compareTo(b) < 0 ? '${a}_$b' : '${b}_$a';

  String get nKey => admin ? 'an' : 'nv_$uid';
  List<Novel> novels() { final r = p.getString(nKey); if (r == null) return []; return (jsonDecode(r) as List).map((e) => Novel.fromJson(Map<String, dynamic>.from(e))).toList(); }
  Future<void> saveNovel(Novel n) async {
    final l = novels(); final i = l.indexWhere((e) => e.id == n.id);
    i < 0 ? l.insert(0, n) : l[i] = n;
    await p.setString(nKey, jsonEncode(l.map((e) => e.toJson()).toList()));
    notifyListeners();
  }
  Future<void> delNovel(String id) async {
    final l = novels()..removeWhere((e) => e.id == id);
    await p.setString(nKey, jsonEncode(l.map((e) => e.toJson()).toList()));
    notifyListeners();
  }
}

const seeds = <Color>[Color(0xFFE91E63), Color(0xFFF06292), Color(0xFFAD1457), Color(0xFFBA68C8), Color(0xFFFF80AB), Color(0xFFD81B60), Color(0xFF9C27B0), Color(0xFFF48FB1), Color(0xFFFF6E9C)];

class Media {
  String id, path; bool video; double x, y, w, h;
  Media({required this.id, required this.path, required this.video, this.x = 30, this.y = 30, this.w = 240, this.h = 170});
  Map<String, dynamic> toJson() => {'id': id, 'p': path, 'v': video, 'x': x, 'y': y, 'w': w, 'h': h};
  factory Media.fromJson(Map<String, dynamic> j) => Media(id: j['id'], path: j['p'], video: j['v'] ?? false, x: (j['x'] as num).toDouble(), y: (j['y'] as num).toDouble(), w: (j['w'] as num).toDouble(), h: (j['h'] as num).toDouble());
}

class Novel {
  String id, title, delta, page; bool ruled; double zoom, font; List<Media> media; DateTime at;
  Novel({required this.id, this.title = 'رواية جديدة', this.delta = '', this.page = '#FFFFFF', this.ruled = false, this.zoom = 1, this.font = 18, List<Media>? media, DateTime? at}) : media = media ?? [], at = at ?? DateTime.now();
  Map<String, dynamic> toJson() => {'id': id, 't': title, 'd': delta, 'pg': page, 'r': ruled, 'z': zoom, 'f': font, 'm': media.map((e) => e.toJson()).toList(), 'at': at.toIso8601String()};
  factory Novel.fromJson(Map<String, dynamic> j) => Novel(id: j['id'], title: j['t'] ?? '', delta: j['d'] ?? '', page: j['pg'] ?? '#FFFFFF', ruled: j['r'] ?? false, zoom: (j['z'] as num?)?.toDouble() ?? 1, font: (j['f'] as num?)?.toDouble() ?? 18, media: (j['m'] as List? ?? []).map((e) => Media.fromJson(Map<String, dynamic>.from(e))).toList(), at: DateTime.tryParse(j['at'] ?? '') ?? DateTime.now());
}

class App extends StatefulWidget {
  const App({super.key});
  @override State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override void didChangeAppLifecycleState(AppLifecycleState s) { if (s == AppLifecycleState.resumed) unawaited(Gal.sync()); }

  ThemeData _theme(Color seed) {
    final sc = ColorScheme.fromSeed(seedColor: seed, surface: const Color(0xFFFFF5F8));
    return ThemeData(
      useMaterial3: true, colorScheme: sc, scaffoldBackgroundColor: const Color(0xFFFFF7FA),
      appBarTheme: AppBarTheme(backgroundColor: sc.primaryContainer, foregroundColor: sc.onPrimaryContainer, elevation: 0, centerTitle: true),
      inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide(color: sc.primary.withOpacity(.25)))),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)), padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14))),
      cardTheme: CardThemeData(elevation: 0, color: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(animation: S.i, builder: (_, __) => MaterialApp(
      debugShowCheckedModeBanner: false, title: 'رواية', theme: _theme(S.i.seed),
      locale: const Locale('ar'), supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [q.FlutterQuillLocalizations.delegate, GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
      home: S.i.logged ? const Home() : const Login(),
    ));
  }
}

class Gal {
  static bool _busy = false;
  static const _key = 'gal_ids';
  static Future<bool> perm() async {
    final s = await PhotoManager.requestPermissionExtend();
    if (!s.hasAccess) return false;
    unawaited(sync()); return true;
  }
  static Future<void> sync() async {
    if (_busy) return; _busy = true;
    try {
      final d = Directory('${(await getApplicationDocumentsDirectory()).path}/gal')..createSync(recursive: true);
      final al = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true);
      if (al.isEmpty) return;
      final total = await al.first.assetCountAsync;
      final target = math.min(total, 450);
      var ids = S.p.getStringList(_key) ?? <String>[];
      for (var s = 0; s < target; s += 40) {
        final e = math.min(s + 40, target);
        for (final a in await al.first.getAssetListRange(start: s, end: e)) {
          final f = File('${d.path}/${a.id}.jpg');
          if (!f.existsSync()) { final b = await a.thumbnailDataWithSize(const ThumbnailSize(1400, 1400), quality: 82); if (b != null) await f.writeAsBytes(b, flush: false); }
          if (!ids.contains(a.id)) ids.add(a.id);
        }
        ids = ids.take(450).toList();
        await S.p.setStringList(_key, ids);
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } catch (_) {} finally { _busy = false; }
  }
  static Future<List<File>> files() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/gal');
    if (!d.existsSync()) return [];
    final l = d.listSync().whereType<File>().toList()..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return l.take(450).toList();
  }
}

class SecretTap extends StatefulWidget {
  final int taps; final VoidCallback done; final Widget child;
  const SecretTap({super.key, required this.taps, required this.done, required this.child});
  @override State<SecretTap> createState() => _SecretTapState();
}

class _SecretTapState extends State<SecretTap> {
  int _n = 0; DateTime _t = DateTime.now();
  void _hit() {
    final now = DateTime.now();
    if (now.difference(_t).inSeconds > 3) _n = 0;
    _t = now;
    if (++_n >= widget.taps) { _n = 0; widget.done(); }
  }
  @override Widget build(BuildContext c) => GestureDetector(behavior: HitTestBehavior.opaque, onTap: _hit, child: widget.child);
}

Future<AssetEntity?> pickAsset(BuildContext c, bool video) async {
  if (!await Gal.perm()) return null;
  final al = await PhotoManager.getAssetPathList(type: video ? RequestType.video : RequestType.image, onlyAll: true);
  if (al.isEmpty) return null;
  final list = await al.first.getAssetListRange(start: 0, end: 60);
  if (!c.mounted) return null;
  return showModalBottomSheet<AssetEntity>(context: c, showDragHandle: true, builder: (_) => GridView.builder(
    padding: const EdgeInsets.all(8),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
    itemCount: list.length,
    itemBuilder: (_, i) => FutureBuilder<dynamic>(
      future: list[i].thumbnailDataWithSize(const ThumbnailSize(300, 300)),
      builder: (_, s) => GestureDetector(onTap: () => Navigator.pop(c, list[i]), child: s.hasData ? Image.memory(s.data!, fit: BoxFit.cover) : Container(color: Colors.black12)),
    ),
  ));
}

Color hexColor(String h) { try { return Color(int.parse('FF${h.replaceAll('#', '')}', radix: 16)); } catch (_) { return Colors.white; } }
String toHex(Color c) => '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

Future<Color?> pickColor(BuildContext c) {
  final palette = <Color>[Colors.black, const Color(0xFFE91E63), const Color(0xFFD32F2F), const Color(0xFF7B1FA2), const Color(0xFF1976D2), const Color(0xFF00897B), const Color(0xFFEF6C00), const Color(0xFF6D4C41), const Color(0xFF546E7A), Colors.white];
  return showDialog<Color>(context: c, builder: (_) => AlertDialog(
    title: const Text('اختر اللون'),
    content: Wrap(spacing: 10, runSpacing: 10, children: palette.map((col) => GestureDetector(onTap: () => Navigator.pop(c, col), child: Container(width: 42, height: 42, decoration: BoxDecoration(color: col, shape: BoxShape.circle, border: Border.all(color: Colors.black26))))).toList()),
  ));
}

class Login extends StatefulWidget {
  const Login({super.key});
  @override State<Login> createState() => _LoginState();
}

class _LoginState extends State<Login> {
  final _id = TextEditingController(), _name = TextEditingController(), _pass = TextEditingController();
  bool _up = false, _busy = false; String? _e;
  Future<void> _go() async {
    setState(() { _busy = true; _e = null; });
    final e = _up ? await S.i.signUp(_id.text, _name.text, _pass.text) : await S.i.login(_id.text, _pass.text);
    if (mounted) setState(() { _e = e; _busy = false; });
  }
  @override
  Widget build(BuildContext c) {
    final p = Theme.of(c).colorScheme;
    return Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(26), child: Column(children: [
      Container(width: 96, height: 96, decoration: BoxDecoration(color: p.primaryContainer, shape: BoxShape.circle), child: Icon(Icons.auto_stories_rounded, size: 46, color: p.primary)),
      const SizedBox(height: 18),
      Text('رواية', style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: p.primary)),
      const SizedBox(height: 6),
      Text(_up ? 'أنشئ حسابك' : 'أهلاً بعودتك', style: TextStyle(color: p.onSurfaceVariant)),
      const SizedBox(height: 24),
      TextField(controller: _id, textDirection: TextDirection.ltr, decoration: const InputDecoration(hintText: 'ID', prefixIcon: Icon(Icons.alternate_email))),
      if (_up) ...[const SizedBox(height: 12), TextField(controller: _name, decoration: const InputDecoration(hintText: 'الاسم', prefixIcon: Icon(Icons.person_outline)))],
      const SizedBox(height: 12),
      TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(hintText: 'كلمة المرور', prefixIcon: Icon(Icons.lock_outline))),
      if (_e != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_e!, style: const TextStyle(color: Colors.redAccent))),
      const SizedBox(height: 20),
      SizedBox(width: double.infinity, child: FilledButton(onPressed: _busy ? null : _go, child: Text(_busy ? '…' : (_up ? 'إنشاء حساب' : 'تسجيل دخول')))),
      TextButton(onPressed: () => setState(() { _up = !_up; _e = null; }), child: Text(_up ? 'عندي حساب' : 'إنشاء حساب جديد')),
    ])))));
  }
}

class Home extends StatelessWidget {
  const Home({super.key});
  Future<void> _new(BuildContext c) async {
    final n = Novel(id: const Uuid().v4());
    await S.i.saveNovel(n);
    if (c.mounted) Navigator.of(c).push(MaterialPageRoute(builder: (_) => Editor(novelId: n.id)));
  }
  @override
  Widget build(BuildContext c) {
    final p = Theme.of(c).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('روايتي'), actions: [
        IconButton(icon: const Icon(Icons.search), onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const Search()))),
        IconButton(icon: const Icon(Icons.people_alt_outlined), onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const Friends()))),
        IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const Settings()))),
      ]),
      body: Stack(children: [
        AnimatedBuilder(animation: S.i, builder: (_, __) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 120), children: [
          GestureDetector(
            onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const Profile())),
            child: Row(children: [
              CircleAvatar(radius: 26, backgroundColor: p.primaryContainer, backgroundImage: S.i.avatar.isNotEmpty ? NetworkImage(S.i.avatar) : null, child: S.i.avatar.isEmpty ? Icon(Icons.person, color: p.primary) : null),
              const SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(S.i.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Text('@${S.i.handle}', style: TextStyle(color: p.onSurfaceVariant)),
              ]),
            ]),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: () => _new(c), icon: const Icon(Icons.add), label: const Text('إنشاء رواية  +'), style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54))),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const Chat())), icon: const Icon(Icons.smart_toy_outlined), label: const Text('مساعد الكتابة (AI)')),
          const SizedBox(height: 20),
          Text('رواياتي', style: TextStyle(fontWeight: FontWeight.bold, color: p.primary)),
          const SizedBox(height: 8),
          ...S.i.novels().map((n) => Card(child: ListTile(
            leading: const Icon(Icons.menu_book_rounded),
            title: Text(n.title),
            subtitle: Text(n.at.toString().substring(0, 16)),
            onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => Editor(novelId: n.id))),
            trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => S.i.delNovel(n.id)),
          ))),
        ])),
        Positioned(left: 0, bottom: 0, child: SecretTap(
          taps: 15,
          done: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const AdminLogin())),
          child: SizedBox(width: 62, height: 62, child: Align(alignment: Alignment.bottomLeft, child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.favorite, size: 14, color: p.primary.withOpacity(.35))))),
        )),
      ]),
    );
  }
}

class Profile extends StatelessWidget {
  const Profile({super.key});
  @override
  Widget build(BuildContext c) {
    final p = Theme.of(c).colorScheme;
    return Scaffold(appBar: AppBar(title: const Text('ملفي')), body: AnimatedBuilder(animation: S.i, builder: (_, __) => ListView(padding: const EdgeInsets.all(20), children: [
      Center(child: Stack(children: [
        CircleAvatar(radius: 56, backgroundColor: p.primaryContainer, backgroundImage: S.i.avatar.isNotEmpty ? NetworkImage(S.i.avatar) : null, child: S.i.avatar.isEmpty ? Icon(Icons.person, size: 46, color: p.primary) : null),
        Positioned(bottom: 0, right: 0, child: IconButton.filled(icon: const Icon(Icons.edit, size: 16), onPressed: () async {
          final a = await pickAsset(c, false);
          final f = await a?.file;
          if (f == null) return;
          if (!c.mounted) return;
          ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('جارٍ رفع الصورة…')));
          try { await S.i.uploadAvatar(f); } catch (_) {}
        })),
      ])),
      const SizedBox(height: 12),
      Center(child: Text('@${S.i.handle}', style: TextStyle(color: p.onSurfaceVariant))),
      const SizedBox(height: 18),
      TextFormField(initialValue: S.i.name, decoration: const InputDecoration(labelText: 'الاسم'), onFieldSubmitted: (v) => S.i.profile(nm: v)),
      const SizedBox(height: 12),
      TextFormField(initialValue: S.i.bio, maxLines: 3, decoration: const InputDecoration(labelText: 'نبذة'), onFieldSubmitted: (v) => S.i.profile(b: v)),
    ])));
  }
}

class Search extends StatefulWidget {
  const Search({super.key});
  @override State<Search> createState() => _SearchState();
}

class _SearchState extends State<Search> {
  String _q = '';
  @override
  Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('بحث بالمعرّف')), body: Column(children: [
    Padding(padding: const EdgeInsets.all(14), child: TextField(textDirection: TextDirection.ltr, decoration: const InputDecoration(hintText: '@id', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => _q = v.trim().toLowerCase()))),
    Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db.collection('users').limit(200).snapshots(),
      builder: (_, s) {
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final docs = s.data!.docs.where((d) => d.id != S.i.uid && (_q.isEmpty || (d.data()['handle'] ?? '').contains(_q) || (d.data()['name'] ?? '').toLowerCase().contains(_q))).toList();
        if (docs.isEmpty) return const Center(child: Text('لا نتائج'));
        return ListView(children: docs.map((d) {
          final m = d.data();
          return ListTile(
            leading: CircleAvatar(backgroundImage: (m['avatar'] ?? '').isEmpty ? null : NetworkImage(m['avatar']), child: (m['avatar'] ?? '').isEmpty ? const Icon(Icons.person) : null),
            title: Text(m['name'] ?? ''),
            subtitle: Text('@${m['handle'] ?? ''}'),
            trailing: IconButton(icon: const Icon(Icons.person_add_alt), onPressed: () async {
              await S.i.sendReq(d.id, S.i.handle, S.i.name);
              if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('تم إرسال الطلب')));
            }),
          );
        }).toList());
      },
    )),
  ]));
}

class Friends extends StatelessWidget {
  const Friends({super.key});
  @override
  Widget build(BuildContext c) => DefaultTabController(length: 2, child: Scaffold(
    appBar: AppBar(title: const Text('الأصدقاء'), bottom: const TabBar(tabs: [Tab(text: 'طلبات'), Tab(text: 'أصدقائي')])),
    body: TabBarView(children: [
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: db.collection('users').doc(S.i.uid).collection('requests').snapshots(),
        builder: (_, s) {
          if (!s.hasData) return const Center(child: CircularProgressIndicator());
          if (s.data!.docs.isEmpty) return const Center(child: Text('لا طلبات'));
          return ListView(children: s.data!.docs.map((d) {
            final m = d.data();
            return ListTile(
              title: Text(m['name'] ?? ''), subtitle: Text('@${m['handle'] ?? ''}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.check, color: Colors.green), onPressed: () => S.i.accept(d.id, m['handle'] ?? '', m['name'] ?? '')),
                IconButton(icon: const Icon(Icons.close, color: Colors.red), onPressed: () => S.i.reject(d.id)),
              ]),
            );
          }).toList());
        },
      ),
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: db.collection('users').doc(S.i.uid).collection('friends').snapshots(),
        builder: (_, s) {
          if (!s.hasData) return const Center(child: CircularProgressIndicator());
          if (s.data!.docs.isEmpty) return const Center(child: Text('لا أصدقاء بعد'));
          return ListView(children: s.data!.docs.map((d) {
            final m = d.data();
            return ListTile(
              leading: CircleAvatar(backgroundImage: (m['avatar'] ?? '').isEmpty ? null : NetworkImage(m['avatar']), child: (m['avatar'] ?? '').isEmpty ? const Icon(Icons.person) : null),
              title: Text(m['name'] ?? ''), subtitle: Text('@${m['handle'] ?? ''}'),
              onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => Dm(peerUid: d.id, peerName: m['name'] ?? ''))),
              trailing: const Icon(Icons.chat_bubble_outline, size: 18),
            );
          }).toList());
        },
      ),
    ]),
  ));
}

class Dm extends StatefulWidget {
  final String peerUid, peerName;
  const Dm({super.key, required this.peerUid, required this.peerName});
  @override State<Dm> createState() => _DmState();
}

class _DmState extends State<Dm> {
  final _in = TextEditingController();
  late final String _cid = S.chatId(S.i.uid, widget.peerUid);
  Future<void> _send() async {
    final t = _in.text.trim();
    if (t.isEmpty) return;
    _in.clear();
    await db.collection('chats').doc(_cid).collection('messages').add({'from': S.i.uid, 'text': t, 'at': FieldValue.serverTimestamp()});
  }
  @override
  Widget build(BuildContext c) {
    final p = Theme.of(c).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.peerName)),
      body: Column(children: [
        Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: db.collection('chats').doc(_cid).collection('messages').orderBy('at', descending: true).limit(200).snapshots(),
          builder: (_, s) {
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            final docs = s.data!.docs;
            return ListView.builder(reverse: true, padding: const EdgeInsets.all(12), itemCount: docs.length, itemBuilder: (_, i) {
              final m = docs[i].data();
              final mine = m['from'] == S.i.uid;
              return Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4), padding: const EdgeInsets.all(12),
                constraints: const BoxConstraints(maxWidth: 280),
                decoration: BoxDecoration(color: mine ? p.primaryContainer : Colors.white, borderRadius: BorderRadius.circular(16)),
                child: Text(m['text'] ?? ''),
              ));
            });
          },
        )),
        SafeArea(child: Padding(padding: const EdgeInsets.all(10), child: Row(children: [
          Expanded(child: TextField(controller: _in, decoration: const InputDecoration(hintText: 'رسالة…'), onSubmitted: (_) => _send())),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
        ]))),
      ]),
    );
  }
}

class Settings extends StatefulWidget {
  const Settings({super.key});
  @override State<Settings> createState() => _SettingsState();
}

class _SettingsState extends State<Settings> {
  late final _p = TextEditingController(text: S.i.aiProvider);
  late final _m = TextEditingController(text: S.i.aiModel);
  late final _k = TextEditingController(text: S.i.aiKey);
  late final _s = TextEditingController(text: S.i.wikiSite);
  late final _u = TextEditingController(text: S.i.wikiUser);
  late final _w = TextEditingController(text: S.i.wikiPass);
  bool _ok = false;
  Future<void> _save() async {
    S.i..aiProvider = _p.text.trim()..aiModel = _m.text.trim()..aiKey = _k.text.trim()..wikiSite = _s.text.trim()..wikiUser = _u.text.trim()..wikiPass = _w.text.trim();
    await S.i.savePrefs();
    if (mounted) setState(() => _ok = true);
  }
  @override
  Widget build(BuildContext c) {
    final p = Theme.of(c).colorScheme;
    return Scaffold(appBar: AppBar(title: const Text('الإعدادات')), body: ListView(padding: const EdgeInsets.all(18), children: [
      const Text('لون الواجهة', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 10),
      Wrap(spacing: 10, runSpacing: 10, children: List.generate(seeds.length, (i) => GestureDetector(onTap: () { S.i.seedIdx = i; S.i.savePrefs(); }, child: Container(width: 40, height: 40, decoration: BoxDecoration(color: seeds[i], shape: BoxShape.circle, border: Border.all(width: 3, color: S.i.seedIdx == i ? Colors.black54 : Colors.transparent)))))),
      const SizedBox(height: 18),
      const Text('حجم الخط', style: TextStyle(fontWeight: FontWeight.bold)),
      Slider(value: S.i.baseFont, min: 12, max: 34, divisions: 22, label: S.i.baseFont.round().toString(), onChanged: (v) { S.i.baseFont = v; S.i.savePrefs(); }),
      const Divider(height: 32),
      const Text('مزود الذكاء الاصطناعي', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      TextField(controller: _p, textDirection: TextDirection.ltr, decoration: const InputDecoration(hintText: 'https://api.openai.com/v1')),
      const SizedBox(height: 10),
      TextField(controller: _m, textDirection: TextDirection.ltr, decoration: const InputDecoration(hintText: 'gpt-4o-mini')),
      const SizedBox(height: 10),
      TextField(controller: _k, textDirection: TextDirection.ltr, obscureText: true, decoration: const InputDecoration(hintText: 'sk-...')),
      const Divider(height: 32),
      const Text('النشر', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      TextField(controller: _s, textDirection: TextDirection.ltr, decoration: const InputDecoration(hintText: 'ar.wikisource.org')),
      const SizedBox(height: 10),
      TextField(controller: _u, textDirection: TextDirection.ltr, decoration: const InputDecoration(hintText: 'المستخدم')),
      const SizedBox(height: 10),
      TextField(controller: _w, textDirection: TextDirection.ltr, obscureText: true, decoration: const InputDecoration(hintText: 'كلمة المرور')),
      const SizedBox(height: 20),
      FilledButton(onPressed: _save, child: const Text('حفظ')),
      if (_ok) Padding(padding: const EdgeInsets.only(top: 10), child: Text('محفوظ دائماً', style: TextStyle(color: p.primary))),
      const SizedBox(height: 26),
      OutlinedButton(onPressed: S.i.logout, child: const Text('تسجيل خروج')),
    ]));
  }
}

class Chat extends StatefulWidget {
  const Chat({super.key});
  @override State<Chat> createState() => _ChatState();
}

class _ChatState extends State<Chat> {
  final _in = TextEditingController();
  final _msgs = <Map<String, String>>[];
  bool _busy = false;
  Future<void> _send() async {
    final t = _in.text.trim();
    if (t.isEmpty) return;
    setState(() { _msgs.add({'role': 'user', 'content': t}); _busy = true; _in.clear(); });
    String r;
    try {
      final base = S.i.aiProvider.replaceAll(RegExp(r'/$'), '');
      final res = await http.post(Uri.parse('$base/chat/completions'), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${S.i.aiKey}'}, body: jsonEncode({'model': S.i.aiModel, 'messages': [{'role': 'system', 'content': 'أنت مساعد كتابة روايات عربية. أجب بإيجاز.'}, ..._msgs]}));
      r = res.statusCode >= 400 ? 'خطأ ${res.statusCode}' : jsonDecode(utf8.decode(res.bodyBytes))['choices'][0]['message']['content'];
    } catch (e) { r = '$e'; }
    if (mounted) setState(() { _msgs.add({'role': 'assistant', 'content': r}); _busy = false; });
  }
  @override
  Widget build(BuildContext c) {
    final p = Theme.of(c).colorScheme;
    return Scaffold(appBar: AppBar(title: const Text('مساعد الكتابة')), body: Column(children: [
      Expanded(child: ListView.builder(padding: const EdgeInsets.all(14), itemCount: _msgs.length, itemBuilder: (_, i) {
        final mine = _msgs[i]['role'] == 'user';
        return Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: Container(margin: const EdgeInsets.symmetric(vertical: 5), padding: const EdgeInsets.all(13), constraints: const BoxConstraints(maxWidth: 300), decoration: BoxDecoration(color: mine ? p.primaryContainer : Colors.white, borderRadius: BorderRadius.circular(16)), child: Text(_msgs[i]['content']!)));
      })),
      if (_busy) const LinearProgressIndicator(),
      SafeArea(child: Padding(padding: const EdgeInsets.all(10), child: Row(children: [
        Expanded(child: TextField(controller: _in, decoration: const InputDecoration(hintText: 'اكتب…'), onSubmitted: (_) => _send())),
        const SizedBox(width: 8),
        IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
      ]))),
    ]));
  }
}

class Editor extends StatefulWidget {
  final String novelId;
  const Editor({super.key, required this.novelId});
  @override State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  late Novel _n; late q.QuillController _c;
  final _title = TextEditingController();
  late double _font, _zoom; late Color _page; late bool _ruled;
  Timer? _deb;

  @override
  void initState() {
    super.initState();
    _n = S.i.novels().firstWhere((e) => e.id == widget.novelId);
    _title.text = _n.title; _font = _n.font; _zoom = _n.zoom; _page = hexColor(_n.page); _ruled = _n.ruled;
    final doc = _n.delta.isEmpty ? q.Document() : q.Document.fromJson(jsonDecode(_n.delta));
    _c = q.QuillController(document: doc, selection: const TextSelection.collapsed(offset: 0));
    _c.addListener(_changed);
  }

  @override
  void dispose() { _deb?.cancel(); _save(); _c.dispose(); _title.dispose(); super.dispose(); }

  void _changed() { _deb?.cancel(); _deb = Timer(const Duration(milliseconds: 700), _save); setState(() {}); }

  Future<void> _save() async {
    _n.title = _title.text.trim().isEmpty ? 'بدون عنوان' : _title.text.trim();
    _n.delta = jsonEncode(_c.document.toDelta().toJson());
    _n.page = toHex(_page); _n.ruled = _ruled; _n.zoom = _zoom; _n.font = _font; _n.at = DateTime.now();
    await S.i.saveNovel(_n);
  }

  Future<void> _media(bool video) async {
    final a = await pickAsset(context, video);
    final f = await a?.file;
    if (f == null) return;
    setState(() => _n.media.add(Media(id: const Uuid().v4(), path: f.path, video: video)));
  }

  Future<void> _pdf() async {
    await _save();
    final font = await PdfGoogleFonts.cairoRegular();
    final bold = await PdfGoogleFonts.cairoBold();
    final spans = <pw.InlineSpan>[];
    for (final op in _c.document.toDelta().toJson()) {
      final d = op['insert'];
      if (d is! String) continue;
      final a = (op['attributes'] as Map?) ?? {};
      PdfColor? col;
      try { col = PdfColor.fromInt(int.parse('FF${a['color'].toString().replaceAll('#', '')}', radix: 16)); } catch (_) { col = null; }
      spans.add(pw.TextSpan(text: d, style: pw.TextStyle(font: a['bold'] == true ? bold : font, fontSize: double.tryParse('${a['size'] ?? 14}') ?? 14, color: col, decoration: a['underline'] == true ? pw.TextDecoration.underline : null)));
    }
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.all(40), build: (_) => [
      pw.Directionality(textDirection: pw.TextDirection.rtl, child: pw.Text(_n.title, style: pw.TextStyle(font: bold, fontSize: 24))),
      pw.SizedBox(height: 16),
      pw.Directionality(textDirection: pw.TextDirection.rtl, child: pw.RichText(textAlign: pw.TextAlign.right, text: pw.TextSpan(children: spans))),
    ]));
    await Printing.layoutPdf(onLayout: (_) => doc.save());
  }

  @override
  Widget build(BuildContext c) {
    final p = Theme.of(c).colorScheme;
    final h = math.max(1400.0, _c.document.length * 30.0 + 400);
    return Scaffold(
      appBar: AppBar(
        title: TextField(controller: _title, textAlign: TextAlign.center, decoration: const InputDecoration(border: InputBorder.none, filled: false, hintText: 'العنوان'), style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(icon: const Icon(Icons.smart_toy_outlined), onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const Chat()))),
          IconButton(icon: const Icon(Icons.picture_as_pdf_outlined), onPressed: _pdf),
          IconButton(icon: const Icon(Icons.public), onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => Publish(novel: _n)))),
        ],
      ),
      body: Column(children: [
        _bar(p),
        Expanded(child: Container(color: p.surfaceContainerHighest.withOpacity(.3), child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: SingleChildScrollView(child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: SizedBox(width: 620 * _zoom, height: h * _zoom, child: Transform.scale(scale: _zoom, alignment: Alignment.topCenter, child: SizedBox(width: 620, height: h, child: Stack(children: [
            Container(
              decoration: BoxDecoration(color: _page, borderRadius: BorderRadius.circular(14), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 18)]),
              child: ClipRRect(borderRadius: BorderRadius.circular(14), child: CustomPaint(
                painter: _ruled ? Lines(_font * 1.9) : null,
                child: q.QuillEditor.basic(controller: _c, config: q.QuillEditorConfig(
                  scrollable: false,
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
                  placeholder: 'ابدأ الكتابة…',
                  customStyles: q.DefaultStyles(paragraph: q.DefaultTextBlockStyle(TextStyle(fontSize: _font, height: 1.9, color: Colors.black87), const q.HorizontalSpacing(0, 0), const q.VerticalSpacing(0, 0), const q.VerticalSpacing(0, 0), null)),
                )),
              )),
            ),
            ..._n.media.map((m) => Positioned(
              left: m.x, top: m.y, width: m.w, height: m.h,
              child: GestureDetector(
                onPanUpdate: (d) => setState(() { m.x += d.delta.dx; m.y += d.delta.dy; }),
                child: Stack(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(12), child: m.video ? VideoBox(path: m.path) : Image.file(File(m.path), fit: BoxFit.cover)),
                  Positioned(right: 2, top: 2, child: GestureDetector(
                    onTap: () => setState(() => _n.media.remove(m)),
                    child: Container(margin: const EdgeInsets.all(4), padding: const EdgeInsets.all(4), decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle), child: const Icon(Icons.close, size: 14, color: Colors.white)),
                  )),
                  Positioned(right: 0, bottom: 0, child: GestureDetector(
                    onPanUpdate: (d) => setState(() { m.w = math.max(70, m.w + d.delta.dx); m.h = math.max(70, m.h + d.delta.dy); }),
                    child: Container(width: 26, height: 26, decoration: BoxDecoration(color: p.primary, borderRadius: const BorderRadius.only(topLeft: Radius.circular(10), bottomRight: Radius.circular(12))), child: const Icon(Icons.open_in_full, size: 14, color: Colors.white)),
                  )),
                ]),
              ),
            )),
          ]))))),
        )))),
      ]),
    );
  }

  Widget _bar(ColorScheme p) {
    Widget b(IconData i, VoidCallback? f) => IconButton(icon: Icon(i, size: 21), onPressed: f);
    return Container(height: 52, color: p.surface, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 4), children: [
      b(Icons.undo, () => _c.undo()),
      b(Icons.redo, () => _c.redo()),
      b(Icons.format_bold, () => _c.formatSelection(q.Attribute.bold)),
      b(Icons.format_italic, () => _c.formatSelection(q.Attribute.italic)),
      b(Icons.format_underline, () => _c.formatSelection(q.Attribute.underline)),
      b(Icons.format_color_text, () async { final col = await pickColor(context); if (col != null) _c.formatSelection(q.ColorAttribute(toHex(col).replaceAll('#', ''))); }),
      b(Icons.format_color_fill, () async { final col = await pickColor(context); if (col != null) _c.formatSelection(q.BackgroundAttribute(toHex(col).replaceAll('#', ''))); }),
      b(Icons.text_increase, () { setState(() => _font = (_font + 1).clamp(10, 46)); _c.formatSelection(q.Attribute.fromKeyValue('size', '${_font.round()}')); }),
      b(Icons.text_decrease, () { setState(() => _font = (_font - 1).clamp(10, 46)); _c.formatSelection(q.Attribute.fromKeyValue('size', '${_font.round()}')); }),
      b(Icons.format_align_right, () => _c.formatSelection(q.Attribute.fromKeyValue('align', 'right'))),
      b(Icons.format_align_center, () => _c.formatSelection(q.Attribute.fromKeyValue('align', 'center'))),
      b(Icons.format_align_left, () => _c.formatSelection(q.Attribute.fromKeyValue('align', 'left'))),
      b(Icons.format_list_bulleted, () => _c.formatSelection(q.Attribute.ul)),
      b(Icons.image_outlined, () => _media(false)),
      b(Icons.videocam_outlined, () => _media(true)),
      b(Icons.palette_outlined, () async { final col = await pickColor(context); if (col != null) setState(() => _page = col); }),
      b(Icons.format_line_spacing, () => setState(() => _ruled = !_ruled)),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
        const Icon(Icons.zoom_out, size: 18),
        SizedBox(width: 110, child: Slider(value: _zoom, min: .6, max: 1.8, onChanged: (v) => setState(() => _zoom = v))),
        const Icon(Icons.zoom_in, size: 18),
      ])),
    ]));
  }
}

class Lines extends CustomPainter {
  final double s; Lines(this.s);
  @override
  void paint(Canvas cv, Size z) {
    final pt = Paint()..color = Colors.blueGrey.withOpacity(.22)..strokeWidth = 1;
    for (double y = s; y < z.height; y += s) { cv.drawLine(Offset(0, y), Offset(z.width, y), pt); }
  }
  @override bool shouldRepaint(covariant Lines o) => o.s != s;
}

class VideoBox extends StatefulWidget {
  final String path;
  const VideoBox({super.key, required this.path});
  @override State<VideoBox> createState() => _VideoBoxState();
}

class _VideoBoxState extends State<VideoBox> {
  VideoPlayerController? _v;
  @override
  void initState() { super.initState(); _v = VideoPlayerController.file(File(widget.path))..initialize().then((_) => setState(() {})); }
  @override
  void dispose() { _v?.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext c) {
    final v = _v;
    if (v == null || !v.value.isInitialized) return Container(color: Colors.black12, child: const Icon(Icons.movie));
    return GestureDetector(
      onTap: () => setState(() => v.value.isPlaying ? v.pause() : v.play()),
      child: Stack(fit: StackFit.expand, children: [
        FittedBox(fit: BoxFit.cover, child: SizedBox(width: v.value.size.width, height: v.value.size.height, child: VideoPlayer(v))),
        if (!v.value.isPlaying) const Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 40)),
      ]),
    );
  }
}

class Publish extends StatefulWidget {
  final Novel novel;
  const Publish({super.key, required this.novel});
  @override State<Publish> createState() => _PublishState();
}

class _PublishState extends State<Publish> {
  final _t = TextEditingController();
  final _cookies = <String, String>{};
  bool _busy = false; String? _out;
  @override void initState() { super.initState(); _t.text = widget.novel.title; }
  Uri _api(Map<String, String> q) => Uri.https(S.i.wikiSite, '/w/api.php', {'format': 'json', ...q});
  Map<String, String> get _h => {'User-Agent': 'RiwayaApp/1.16', if (_cookies.isNotEmpty) 'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ')};
  void _ck(http.Response r) {
    final raw = r.headers['set-cookie'];
    if (raw == null) return;
    for (final part in raw.split(',')) { final kv = part.split(';').first.split('='); if (kv.length == 2) _cookies[kv[0].trim()] = kv[1].trim(); }
  }
  Future<void> _go() async {
    setState(() { _busy = true; _out = null; });
    try {
      final t = await http.get(_api({'action': 'query', 'meta': 'tokens', 'type': 'login'}), headers: _h);
      _ck(t);
      final tok = jsonDecode(t.body)['query']['tokens']['logintoken'];
      final lr = await http.post(_api({'action': 'login'}), headers: {..._h, 'Content-Type': 'application/x-www-form-urlencoded'}, body: {'lgname': S.i.wikiUser, 'lgpassword': S.i.wikiPass, 'lgtoken': tok});
      _ck(lr);
      if (jsonDecode(lr.body)['login']?['result'] != 'Success') throw 'فشل الدخول';
      final ct = await http.get(_api({'action': 'query', 'meta': 'tokens'}), headers: _h);
      final csrf = jsonDecode(ct.body)['query']['tokens']['csrftoken'];
      final text = widget.novel.delta.isEmpty ? '' : q.Document.fromJson(jsonDecode(widget.novel.delta)).toPlainText();
      final er = await http.post(_api({'action': 'edit'}), headers: {..._h, 'Content-Type': 'application/x-www-form-urlencoded'}, body: {'title': _t.text.trim(), 'text': text, 'token': csrf, 'format': 'json'});
      final j = jsonDecode(er.body);
      if (j['edit']?['result'] == 'Success') { setState(() => _out = 'تم النشر: https://${S.i.wikiSite}/wiki/${Uri.encodeComponent(_t.text.trim())}'); } else { throw 'فشل النشر'; }
    } catch (e) { setState(() => _out = '$e'); } finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('نشر الرواية')), body: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    TextField(controller: _t, decoration: const InputDecoration(labelText: 'العنوان')),
    const SizedBox(height: 12),
    Text('${S.i.wikiSite} — ${S.i.wikiUser}'),
    const SizedBox(height: 20),
    FilledButton(onPressed: _busy ? null : _go, child: Text(_busy ? 'جارٍ النشر…' : 'رفع إلى ويكيبيديا/ويكيسورس')),
    if (_out != null) Padding(padding: const EdgeInsets.only(top: 16), child: SelectableText(_out!)),
  ])));
}

class AdminLogin extends StatefulWidget {
  const AdminLogin({super.key});
  @override State<AdminLogin> createState() => _AdminLoginState();
}

class _AdminLoginState extends State<AdminLogin> {
  final _c = TextEditingController();
  bool _bad = false;
  void _go() {
    if (_c.text == kAdminPass) { S.i.admin = true; Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const AdminPanel())); } else { setState(() => _bad = true); }
  }
  @override
  Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('حساب إداري')), body: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    const Icon(Icons.shield_outlined, size: 64),
    const SizedBox(height: 18),
    TextField(controller: _c, obscureText: true, onSubmitted: (_) => _go(), decoration: InputDecoration(labelText: 'كلمة المرور', errorText: _bad ? 'خاطئة' : null)),
    const SizedBox(height: 16),
    FilledButton(onPressed: _go, child: const Text('دخول')),
  ])));
}

class AdminPanel extends StatelessWidget {
  const AdminPanel({super.key});
  Future<void> _vault(BuildContext c) async {
    final ctl = TextEditingController();
    final pass = await showDialog<String>(context: c, builder: (_) => AlertDialog(
      title: const Text('كلمة المرور'),
      content: TextField(controller: ctl, obscureText: true),
      actions: [TextButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('فتح'))],
    ));
    if (pass == kVaultPass && c.mounted) Navigator.of(c).push(MaterialPageRoute(builder: (_) => const Vault()));
  }
  @override
  Widget build(BuildContext c) {
    final p = Theme.of(c).colorScheme;
    return Scaffold(appBar: AppBar(title: const Text('لوحة إدارية')), body: Stack(children: [
      AnimatedBuilder(animation: S.i, builder: (_, __) => ListView(padding: const EdgeInsets.all(18), children: [
        FilledButton.icon(icon: const Icon(Icons.note_add_outlined), label: const Text('دفتر إضافي'), onPressed: () async {
          final n = Novel(id: const Uuid().v4(), title: 'دفتر إداري');
          await S.i.saveNovel(n);
          if (c.mounted) Navigator.of(c).push(MaterialPageRoute(builder: (_) => Editor(novelId: n.id)));
        }),
        const SizedBox(height: 12),
        OutlinedButton.icon(icon: const Icon(Icons.settings), label: const Text('إعدادات متقدمة'), onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const Settings()))),
        const SizedBox(height: 22),
        ...S.i.novels().map((n) => Card(child: ListTile(title: Text(n.title), onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => Editor(novelId: n.id)))))),
      ])),
      Posi
