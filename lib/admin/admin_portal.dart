import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _bg = Color(0xFF0B1018);
const _panel = Color(0xFF121B27);
const _panel2 = Color(0xFF1A2939);
const _line = Color(0xFF263445);
const _mint = Color(0xFF20E6B2);
const _text = Color(0xFFF4F7FA);
const _muted = Color(0xFF8D9AAA);
const _secureStorage = FlutterSecureStorage();

class AdminApi {
  static const String baseUrl = String.fromEnvironment('API_BASE_URL');
  static final http.Client _client = http.Client();
  static String get _base => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  static bool get configured => _base.isNotEmpty && !_base.contains('YOUR-WORKER');

  static Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    String? token,
  }) async {
    if (!configured) throw Exception('لم يتم ربط خادم Cloudflare بعد.');
    final uri = Uri.parse('$_base$path');
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (token != null) headers['Authorization'] = 'Bearer $token';
    http.Response response;
    try {
      if (method == 'POST') {
        response = await _client.post(uri, headers: headers, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 20));
      } else if (method == 'DELETE') {
        response = await _client.delete(uri, headers: headers).timeout(const Duration(seconds: 20));
      } else {
        response = await _client.get(uri, headers: headers).timeout(const Duration(seconds: 20));
      }
    } catch (_) {
      throw Exception('تعذر الاتصال بالخادم. تحقق من الإنترنت ورابط الخادم.');
    }
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      throw Exception('استجابة غير مفهومة من الخادم.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(data['error']?.toString() ?? 'فشل الطلب (${response.statusCode}).');
    }
    return data;
  }

  static Future<String> deriveVerifier(String password, String saltB64Url, int iterations) async {
    final salt = base64Url.decode(base64Url.normalize(saltB64Url));
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
    final key = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    return base64Encode(await key.extractBytes());
  }

  static Future<String> deriveLoginProof(String password, String saltB64Url, int iterations, String challengeId, String nonce, String otp) async {
    final salt = base64Url.decode(base64Url.normalize(saltB64Url));
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
    final key = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    final mac = await Hmac.sha256().calculateMac(utf8.encode('$challengeId.$nonce.$otp'), secretKey: key);
    return base64UrlEncode(mac.bytes).replaceAll('=', '');
  }

  static Future<String?> readSession() => _secureStorage.read(key: 'dfish_admin_session');
  static Future<void> saveSession(String token) => _secureStorage.write(key: 'dfish_admin_session', value: token);
  static Future<void> clearSession() => _secureStorage.delete(key: 'dfish_admin_session');
}

class AdminAccessScreen extends StatefulWidget {
  const AdminAccessScreen({super.key});
  @override
  State<AdminAccessScreen> createState() => _AdminAccessScreenState();
}

class _AdminAccessScreenState extends State<AdminAccessScreen> {
  final _password = TextEditingController();
  final _bootstrap = TextEditingController();
  final _otp = TextEditingController();
  final _passwordConfirm = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  bool _setupRequired = false;
  bool _showPassword = false;
  String? _setupSecret;
  String? _setupError;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  @override
  void dispose() {
    _password.dispose(); _bootstrap.dispose(); _otp.dispose(); _passwordConfirm.dispose();
    super.dispose();
  }

  Future<void> _checkStatus() async {
    try {
      final status = await AdminApi.request('/api/admin/status');
      if (!mounted) return;
      setState(() { _setupRequired = status['setupRequired'] == true; _loading = false; });
      if (!_setupRequired) {
        final token = await AdminApi.readSession();
        if (token != null && mounted) {
          try {
            await AdminApi.request('/api/admin/me', token: token);
            if (mounted) Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => AdminDashboardScreen(token: token)));
          } catch (_) { await AdminApi.clearSession(); }
        }
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _setupError = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  Future<void> _createAdmin() async {
    final password = _password.text;
    if (password.length < 20) { _message('استخدم كلمة مرور لا تقل عن 20 حرفاً.'); return; }
    if (password != _passwordConfirm.text) { _message('تأكيد كلمة المرور غير مطابق.'); return; }
    if (_bootstrap.text.trim().isEmpty) { _message('أدخل رمز التفعيل الذي ضبطته في Cloudflare.'); return; }
    setState(() => _busy = true);
    try {
      final challenge = await AdminApi.request('/api/admin/setup-challenge', method: 'POST', body: {'bootstrapToken': _bootstrap.text.trim()});
      final verifier = await AdminApi.deriveVerifier(password, challenge['salt'].toString(), (challenge['iterations'] as num).toInt());
      final result = await AdminApi.request('/api/admin/setup', method: 'POST', body: {
        'bootstrapToken': _bootstrap.text.trim(),
        'challengeId': challenge['challengeId'],
        'verifier': verifier,
      });
      if (!mounted) return;
      setState(() { _setupSecret = result['totpSecret']?.toString(); _setupRequired = false; });
      _message('تم إنشاء حساب الإدارة. احفظ مفتاح المصادقة الآن قبل المتابعة.', long: true);
    } catch (e) {
      _message(e.toString().replaceFirst('Exception: ', ''));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _login() async {
    if (_password.text.isEmpty || !RegExp(r'^\d{6}$').hasMatch(_otp.text.trim())) { _message('أدخل كلمة المرور ورمزاً صحيحاً من 6 أرقام.'); return; }
    setState(() => _busy = true);
    try {
      final challenge = await AdminApi.request('/api/admin/login-challenge');
      final proof = await AdminApi.deriveLoginProof(
        _password.text,
        challenge['salt'].toString(),
        (challenge['iterations'] as num).toInt(),
        challenge['challengeId'].toString(),
        challenge['nonce'].toString(),
        _otp.text.trim(),
      );
      final result = await AdminApi.request('/api/admin/login', method: 'POST', body: {
        'challengeId': challenge['challengeId'], 'proof': proof, 'otp': _otp.text.trim(),
      });
      final token = result['token']?.toString();
      if (token == null || token.isEmpty) throw Exception('لم يرجع الخادم جلسة دخول صالحة.');
      await AdminApi.saveSession(token);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => AdminDashboardScreen(token: token)));
    } catch (e) {
      _message(e.toString().replaceFirst('Exception: ', ''));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  void _message(String text, {bool long = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), duration: Duration(seconds: long ? 10 : 4)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _bg,
    appBar: AppBar(title: const Text('بوابة الإدارة', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
    body: _loading
      ? const Center(child: CircularProgressIndicator(color: _mint))
      : ListView(padding: const EdgeInsets.all(20), children: [
          const _AdminBrand(),
          const SizedBox(height: 20),
          if (_setupError != null) _AdminNotice(text: _setupError!, danger: true),
          if (_setupRequired && _setupSecret == null) ...[
            const _AdminNotice(text: 'هذه أول مرة يتم فيها إعداد لوحة الإدارة. أنشئ كلمة مرور طويلة، ثم اربط تطبيق المصادقة. لا ترسل أي سر إلى أي شخص.'),
            const SizedBox(height: 14),
            _field(_bootstrap, 'رمز التفعيل لمرة واحدة من Cloudflare', obscure: true),
            const SizedBox(height: 10),
            _field(_password, 'كلمة مرور الإدارة (20 حرفاً أو أكثر)', obscure: !_showPassword),
            const SizedBox(height: 10),
            _field(_passwordConfirm, 'تأكيد كلمة المرور', obscure: !_showPassword),
            SwitchListTile.adaptive(value: _showPassword, onChanged: (v) => setState(() => _showPassword = v), contentPadding: EdgeInsets.zero, activeThumbColor: _mint, title: const Text('إظهار كلمة المرور', style: TextStyle(color: _muted, fontSize: 12))),
            const SizedBox(height: 12),
            _primaryButton('إنشاء حساب الإدارة', _createAdmin),
          ] else if (_setupSecret != null) ...[
            Container(padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: _mint.withValues(alpha: .08), borderRadius: BorderRadius.circular(13), border: Border.all(color: _mint.withValues(alpha: .24))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('مفتاح التحقق الثنائي (Base32) — يظهر مرة واحدة فقط', style: TextStyle(color: _mint, fontWeight: FontWeight.w800, fontSize: 11)), const SizedBox(height: 8), SelectableText(_setupSecret!, style: const TextStyle(color: _text, fontWeight: FontWeight.w900, letterSpacing: 1.2)), TextButton.icon(onPressed: () { Clipboard.setData(ClipboardData(text: _setupSecret!)); _message('تم نسخ مفتاح المصادقة. احفظه في مكان آمن.'); }, icon: const Icon(LucideIcons.copy, size: 15), label: const Text('نسخ المفتاح')), const Text('أضفه يدوياً في تطبيق Aegis أو Google Authenticator واحفظ نسخة احتياطية. لن يعرض الخادم هذا المفتاح مرة أخرى.', style: TextStyle(color: _muted, fontSize: 10, height: 1.6)) ])),
            const SizedBox(height: 10),
            _field(_otp, 'رمز المصادقة الحالي المكون من 6 أرقام', numeric: true),
            const SizedBox(height: 12),
            _primaryButton('التحقق وفتح لوحة الإدارة', _login),
          ] else ...[
            const _AdminNotice(text: 'الدخول محمي بكلمة مرور طويلة ورمز تحقق متغير من تطبيق المصادقة. الرمز السري لا يُحفظ داخل APK.'),
            const SizedBox(height: 14),
            _field(_password, 'كلمة مرور الإدارة', obscure: !_showPassword),
            const SizedBox(height: 10),
            _field(_otp, 'رمز التحقق الثنائي (6 أرقام)', numeric: true),
            SwitchListTile.adaptive(value: _showPassword, onChanged: (v) => setState(() => _showPassword = v), contentPadding: EdgeInsets.zero, activeThumbColor: _mint, title: const Text('إظهار كلمة المرور', style: TextStyle(color: _muted, fontSize: 12))),
            const SizedBox(height: 12),
            _primaryButton('دخول لوحة الإدارة', _login),
          ],
          if (_busy) const Padding(padding: EdgeInsets.only(top: 18), child: Center(child: CircularProgressIndicator(color: _mint))),
          const SizedBox(height: 24),
          const Text('ملاحظة: نقطة الدخول المخفية ليست وسيلة حماية. جميع العمليات الحساسة تتحقق من صلاحيات الخادم.', textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 10, height: 1.7)),
        ]),
  );

  Widget _field(TextEditingController controller, String label, {bool obscure = false, bool numeric = false}) => TextField(
    controller: controller, obscureText: obscure, autocorrect: false, enableSuggestions: false, keyboardType: numeric ? TextInputType.number : TextInputType.text, maxLength: numeric ? 6 : null,
    style: const TextStyle(color: _text), decoration: InputDecoration(labelText: label, labelStyle: const TextStyle(color: _muted), filled: true, fillColor: _panel, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _line)), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _line)), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _mint))),
  );

  Widget _primaryButton(String label, VoidCallback action) => SizedBox(width: double.infinity, child: FilledButton(onPressed: _busy ? null : action, style: FilledButton.styleFrom(backgroundColor: _mint, foregroundColor: _bg, padding: const EdgeInsets.symmetric(vertical: 15)), child: Text(label, style: const TextStyle(fontWeight: FontWeight.w900))));
}

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key, required this.token});
  final String token;
  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  late Future<List<dynamic>> _matches;
  bool _busy = false;
  @override
  void initState() { super.initState(); _reload(); }
  void _reload() { _matches = AdminApi.request('/api/admin/matches', token: widget.token).then((v) => (v['response'] as List?) ?? const []); }

  Future<void> _logout() async {
    try { await AdminApi.request('/api/admin/logout', method: 'POST', token: widget.token); } catch (_) { }
    await AdminApi.clearSession();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _openEditor([Map<String, dynamic>? match]) async {
    final saved = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, backgroundColor: _panel, builder: (_) => _MatchEditor(token: widget.token, existing: match));
    if (saved == true && mounted) setState(_reload);
  }

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(backgroundColor: _panel, title: const Text('حذف المباراة؟'), content: const Text('سيتم حذف بيانات المباراة وروابطها من قائمة البث.'), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف'))]));
    if (confirm != true) return;
    try { await AdminApi.request('/api/admin/matches/$id', method: 'DELETE', token: widget.token); if (mounted) setState(_reload); }
    catch (e) { _snack(e.toString()); }
  }

  void _snack(String value) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value.replaceFirst('Exception: ', '')))); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _bg,
    appBar: AppBar(title: const Text('إدارة DFISH LIVE', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)), actions: [IconButton(onPressed: _logout, tooltip: 'تسجيل الخروج', icon: const Icon(LucideIcons.logOut, color: _muted))]),
    floatingActionButton: FloatingActionButton.extended(onPressed: () => _openEditor(), backgroundColor: _mint, foregroundColor: _bg, icon: const Icon(LucideIcons.plus), label: const Text('إضافة مباراة')),
    body: FutureBuilder<List<dynamic>>(future: _matches, builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: _mint));
      if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(LucideIcons.wifiOff, color: _muted, size: 32), const SizedBox(height: 10), Text(snapshot.error.toString(), textAlign: TextAlign.center), const SizedBox(height: 10), OutlinedButton(onPressed: () => setState(_reload), child: const Text('إعادة المحاولة'))])));
      final items = snapshot.data ?? [];
      if (items.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(30), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(LucideIcons.calendarPlus, size: 42, color: _mint), SizedBox(height: 12), Text('لا توجد مباريات مضافة', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)), SizedBox(height: 6), Text('أضف بيانات المباراة وروابط البث من هنا. ستظهر للمستخدمين بعد الحفظ.', textAlign: TextAlign.center, style: TextStyle(color: _muted, height: 1.6))])));
      return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
        const _AdminNotice(text: 'هذه لوحة الإدارة. كل عملية حفظ أو حذف تُرسل للخادم بعد التحقق من جلسة المدير. لا تشارك هاتفك أو رموز المصادقة.'),
        const SizedBox(height: 14),
        ...items.map((raw) {
          final m = Map<String, dynamic>.from(raw as Map);
          final sources = (m['sources'] as List?) ?? [];
          return Padding(padding: const EdgeInsets.only(bottom: 10), child: Container(decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(16), border: Border.all(color: _line)), child: Padding(padding: const EdgeInsets.all(13), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text('${m['home'] ?? ''} × ${m['away'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w900))), Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: m['enabled'] == true ? _mint.withValues(alpha: .13) : Colors.red.withValues(alpha: .12), borderRadius: BorderRadius.circular(8)), child: Text(m['enabled'] == true ? 'مفعلة' : 'مخفية', style: TextStyle(color: m['enabled'] == true ? _mint : Colors.redAccent, fontSize: 10))) ]),
            const SizedBox(height: 6),
            Text('${m['league'] ?? 'مباراة'} · ${m['date'] ?? ''} · ${m['time'] ?? ''} بتوقيت اليمن', style: const TextStyle(color: _muted, fontSize: 11)),
            Text('${sources.length} مصدر بث', style: const TextStyle(color: _mint, fontSize: 11)),
            const Divider(color: _line),
            Row(children: [TextButton.icon(onPressed: () => _openEditor(m), icon: const Icon(LucideIcons.pencil, size: 16), label: const Text('تعديل')), TextButton.icon(onPressed: () => _delete(m['id'].toString()), icon: const Icon(LucideIcons.trash2, size: 16, color: Colors.redAccent), label: const Text('حذف', style: TextStyle(color: Colors.redAccent))) ]),
          ]))));
        }),
      ]);
    }),
  );
}

class _MatchEditor extends StatefulWidget {
  const _MatchEditor({required this.token, this.existing});
  final String token;
  final Map<String, dynamic>? existing;
  @override
  State<_MatchEditor> createState() => _MatchEditorState();
}

class _MatchEditorState extends State<_MatchEditor> {
  late final TextEditingController _home, _away, _league, _date, _time, _homeLogo, _awayLogo, _leagueLogo, _commentator, _channel;
  late final List<TextEditingController> _sourceNames;
  late final List<TextEditingController> _sourceUrls;
  bool _enabled = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final m = widget.existing ?? {};
    _home = TextEditingController(text: m['home']?.toString() ?? '');
    _away = TextEditingController(text: m['away']?.toString() ?? '');
    _league = TextEditingController(text: m['league']?.toString() ?? '');
    _date = TextEditingController(text: m['date']?.toString() ?? DateTime.now().toUtc().add(const Duration(hours: 3)).toIso8601String().substring(0, 10));
    _time = TextEditingController(text: m['time']?.toString() ?? '20:00');
    _homeLogo = TextEditingController(text: m['homeLogo']?.toString() ?? '');
    _awayLogo = TextEditingController(text: m['awayLogo']?.toString() ?? '');
    _leagueLogo = TextEditingController(text: m['leagueLogo']?.toString() ?? '');
    _commentator = TextEditingController(text: m['commentator']?.toString() ?? '');
    _channel = TextEditingController(text: m['channel']?.toString() ?? '');
    _enabled = m['enabled'] != false;
    final sources = (m['sources'] as List?) ?? [];
    _sourceNames = List.generate(4, (i) => TextEditingController(text: i < sources.length ? sources[i]['name']?.toString() ?? '' : 'بث ${i + 1}'));
    _sourceUrls = List.generate(4, (i) => TextEditingController(text: i < sources.length ? sources[i]['url']?.toString() ?? '' : ''));
  }

  @override
  void dispose() {
    for (final c in [_home, _away, _league, _date, _time, _homeLogo, _awayLogo, _leagueLogo, _commentator, _channel, ..._sourceNames, ..._sourceUrls]) { c.dispose(); }
    super.dispose();
  }

  Future<void> _save() async {
    final sources = <Map<String, dynamic>>[];
    for (var i = 0; i < 4; i++) {
      final url = _sourceUrls[i].text.trim();
      if (url.isEmpty) continue;
      sources.add({'id': 'source_${i + 1}', 'name': _sourceNames[i].text.trim().isEmpty ? 'بث ${i + 1}' : _sourceNames[i].text.trim(), 'url': url, 'enabled': true});
    }
    setState(() => _saving = true);
    try {
      await AdminApi.request('/api/admin/matches', method: 'POST', token: widget.token, body: {
        if (widget.existing?['id'] != null) 'id': widget.existing!['id'],
        'home': _home.text.trim(), 'away': _away.text.trim(), 'league': _league.text.trim(),
        'date': _date.text.trim(), 'time': _time.text.trim(), 'homeLogo': _homeLogo.text.trim(), 'awayLogo': _awayLogo.text.trim(), 'leagueLogo': _leagueLogo.text.trim(),
        'commentator': _commentator.text.trim(), 'channel': _channel.text.trim(), 'enabled': _enabled, 'sources': sources,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) => SafeArea(child: Padding(padding: EdgeInsets.only(left: 18, right: 18, top: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 20), child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [Expanded(child: Text(widget.existing == null ? 'إضافة مباراة' : 'تعديل المباراة', style: const TextStyle(color: _text, fontWeight: FontWeight.w900, fontSize: 18))), IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(LucideIcons.x, color: _muted))]),
    const SizedBox(height: 8),
    _field(_home, 'الفريق الأول *'), const SizedBox(height: 9), _field(_away, 'الفريق الثاني *'), const SizedBox(height: 9), _field(_league, 'البطولة'),
    const SizedBox(height: 9), Row(children: [Expanded(child: _field(_date, 'التاريخ YYYY-MM-DD *')), const SizedBox(width: 8), Expanded(child: _field(_time, 'الوقت HH:MM *'))]),
    const SizedBox(height: 9), _field(_homeLogo, 'رابط شعار الفريق الأول HTTPS'), const SizedBox(height: 9), _field(_awayLogo, 'رابط شعار الفريق الثاني HTTPS'), const SizedBox(height: 9), _field(_leagueLogo, 'رابط شعار البطولة HTTPS'),
    const SizedBox(height: 9), _field(_commentator, 'المعلق (اختياري)'), const SizedBox(height: 9), _field(_channel, 'القناة الناقلة (اختياري)'),
    const SizedBox(height: 16), const Text('مصادر البث (حتى 4 روابط)', style: TextStyle(color: _text, fontWeight: FontWeight.w900)),
    const SizedBox(height: 5), const Text('استخدم فقط الروابط التي تملك إذناً بعرضها. الروابط المباشرة HLS بصيغة M3U8 تعمل داخل المشغل؛ صفحات HTTPS المسموح بها تُفتح داخل WebView مدمج، وقد تمنع بعض المواقع هذا النوع من التشغيل.', style: TextStyle(color: _muted, fontSize: 10, height: 1.6)),
    const SizedBox(height: 10),
    for (var i = 0; i < 4; i++) ...[
      _field(_sourceNames[i], 'اسم المصدر ${i + 1}'), const SizedBox(height: 7), _field(_sourceUrls[i], 'رابط HTTPS للمصدر ${i + 1}'), const SizedBox(height: 12),
    ],
    SwitchListTile.adaptive(value: _enabled, onChanged: (v) => setState(() => _enabled = v), title: const Text('إظهار المباراة للمستخدمين', style: TextStyle(color: _text, fontSize: 13)), activeThumbColor: _mint, contentPadding: EdgeInsets.zero),
    const SizedBox(height: 12), SizedBox(width: double.infinity, child: FilledButton(onPressed: _saving ? null : _save, style: FilledButton.styleFrom(backgroundColor: _mint, foregroundColor: _bg, padding: const EdgeInsets.symmetric(vertical: 15)), child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: _bg)) : const Text('حفظ المباراة', style: TextStyle(fontWeight: FontWeight.w900)))),
  ]))));

  Widget _field(TextEditingController controller, String label) => TextField(controller: controller, style: const TextStyle(color: _text, fontSize: 13), autocorrect: false, decoration: InputDecoration(labelText: label, labelStyle: const TextStyle(color: _muted, fontSize: 12), filled: true, fillColor: _panel2, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _mint))));
}

class _AdminBrand extends StatelessWidget {
  const _AdminBrand();
  @override
  Widget build(BuildContext context) => const Column(children: [Text.rich(TextSpan(children: [TextSpan(text: 'DFISH ', style: TextStyle(color: _text, fontSize: 25, fontWeight: FontWeight.w900)), TextSpan(text: 'LIVE', style: TextStyle(color: _mint, fontSize: 25, fontWeight: FontWeight.w900))])), SizedBox(height: 5), Text('بوابة الإدارة الآمنة', style: TextStyle(color: _muted, fontSize: 11))]);
}

class _AdminNotice extends StatelessWidget {
  const _AdminNotice({required this.text, this.danger = false});
  final String text;
  final bool danger;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: (danger ? Colors.redAccent : _mint).withValues(alpha: .08), borderRadius: BorderRadius.circular(13), border: Border.all(color: (danger ? Colors.redAccent : _mint).withValues(alpha: .24))), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(danger ? LucideIcons.alertTriangle : LucideIcons.shieldCheck, size: 19, color: danger ? Colors.redAccent : _mint), const SizedBox(width: 9), Expanded(child: Text(text, style: const TextStyle(color: _muted, fontSize: 11, height: 1.65)))]));
}
