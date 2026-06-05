// 키오스크관리 — 페어링 UX (사용자 확정 그림)
//  · 피제어 기기(어르신 태블릿): 앱 켜면 QR + 6자리 표시 → 제어자가 스캔/입력하면 클레임됨
//  · 제어자(도우미 폰): 로그인 → QR 스캔 / 6자리 입력 → 우리 서버가 RustDesk 자격 중개 → 화면제어
//  서버 API: /api/pair/announce, /api/pair/redeem, /api/pair/status (pairing-qr-architecture)
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:flutter_hbb/models/platform_model.dart'; // bind
import 'package:flutter_hbb/common.dart'; // connect(), showToast
import 'package:flutter_hbb/azit_agent.dart'; // AzitAgent, kAzitBase

// ========================= 피제어 기기: QR + 6자리 표시 =========================
class AzitPairScreen extends StatefulWidget {
  const AzitPairScreen({Key? key}) : super(key: key);
  @override
  State<AzitPairScreen> createState() => _AzitPairScreenState();
}

class _AzitPairScreenState extends State<AzitPairScreen> {
  String _deviceKey = '';
  String? _code;
  String? _qrPayload;
  String _status = '준비 중...';
  bool _claimed = false;
  Timer? _pollTimer;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _deviceKey = _ensureDeviceKey();
    _announce();
  }

  String _ensureDeviceKey() {
    var k = bind.mainGetLocalOption(key: 'azit_device_key');
    if (k.isEmpty) {
      const cs = 'abcdefghijklmnopqrstuvwxyz0123456789';
      final r = Random.secure();
      k = 'dk-' + List.generate(28, (_) => cs[r.nextInt(cs.length)]).join();
      bind.mainSetLocalOption(key: 'azit_device_key', value: k);
    }
    return k;
  }

  Future<void> _announce() async {
    if (_claimed || !mounted) return;
    try {
      final ident = await AzitAgent.instance.prepareIdentity();
      final myId = ident['id'] ?? '';
      final pw = ident['pw'] ?? '';
      if (myId.isEmpty) {
        // RustDesk 엔진이 아직 ID서버 등록 전 → 잠시 후 재시도
        if (mounted) setState(() => _status = '서버 연결 준비 중...');
        Timer(const Duration(seconds: 2), _announce);
        return;
      }
      final r = await http.post(
        Uri.parse('$kAzitBase/api/pair/announce'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceKey': _deviceKey,
          'rustdeskId': myId,
          'rustdeskPassword': pw,
          'deviceName': 'Android 기기',
        }),
      );
      if (r.statusCode != 200) {
        if (mounted) setState(() => _status = '서버 오류 (${r.statusCode}) — 재시도');
        Timer(const Duration(seconds: 5), _announce);
        return;
      }
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      if (d['claimed'] == true) {
        _onClaimed(d);
        return;
      }
      if (!mounted) return;
      setState(() {
        _code = d['code']?.toString();
        _qrPayload = d['qrPayload']?.toString();
        _status = '아래 코드를 제어할 기기에서 스캔하거나 입력하세요';
      });
      _startPolling();
      // 5분 만료 전에 코드 갱신
      _refreshTimer?.cancel();
      _refreshTimer = Timer(const Duration(minutes: 4, seconds: 30), _announce);
    } catch (e) {
      debugPrint('AZIT pair announce error $e');
      if (mounted) setState(() => _status = '네트워크 오류 — 재시도');
      Timer(const Duration(seconds: 5), _announce);
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_claimed) return;
      try {
        final r = await http
            .get(Uri.parse('$kAzitBase/api/pair/status?deviceKey=$_deviceKey'));
        if (r.statusCode == 200) {
          final d = jsonDecode(r.body) as Map<String, dynamic>;
          if (d['claimed'] == true) _onClaimed(d);
        }
      } catch (_) {}
    });
  }

  void _onClaimed(Map<String, dynamic> d) {
    if (_claimed) return;
    _claimed = true;
    _pollTimer?.cancel();
    _refreshTimer?.cancel();
    AzitAgent.instance.onClaimed(
        (d['deviceId'] ?? '').toString(), (d['agentKey'] ?? '').toString());
    if (mounted) setState(() => _status = '연결되었습니다 ✓');
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('이 기기 연결하기',
                    style: TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black87)),
                const SizedBox(height: 8),
                Text(_status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 15, color: Colors.black54)),
                const SizedBox(height: 24),
                if (_claimed)
                  const Icon(Icons.check_circle, color: Color(0xFF22a06b), size: 120)
                else if (_qrPayload != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFe0e0e0)),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: QrImageView(
                      data: _qrPayload!,
                      version: QrVersions.auto,
                      size: 240,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text('또는 이 번호 입력',
                      style: TextStyle(fontSize: 14, color: Colors.black45)),
                  const SizedBox(height: 6),
                  Text(
                    _code ?? '------',
                    style: const TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 10,
                      color: Color(0xFF2d6cdf),
                    ),
                  ),
                ] else
                  const CircularProgressIndicator(),
                const SizedBox(height: 40),
                TextButton.icon(
                  icon: const Icon(Icons.cast_connected),
                  label: const Text('다른 기기 제어하기'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AzitControllerScreen()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ========================= 제어자: 로그인 → 스캔/입력 → 연결 =========================
class AzitControllerScreen extends StatefulWidget {
  const AzitControllerScreen({Key? key}) : super(key: key);
  @override
  State<AzitControllerScreen> createState() => _AzitControllerScreenState();
}

class _AzitControllerScreenState extends State<AzitControllerScreen> {
  final _email = TextEditingController();
  final _pin = TextEditingController();
  final _code = TextEditingController();
  String _token = '';
  String _msg = '';
  bool _busy = false;
  List<Map<String, dynamic>> _devices = [];

  @override
  void initState() {
    super.initState();
    _token = bind.mainGetLocalOption(key: 'azit_token');
    if (_token.isNotEmpty) _loadDevices();
  }

  Map<String, String> get _auth =>
      {'Content-Type': 'application/json', 'Authorization': 'Bearer $_token'};

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      final r = await http.post(
        Uri.parse('$kAzitBase/api/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': _email.text.trim(), 'pin': _pin.text.trim()}),
      );
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200) {
        _token = d['token'] as String;
        bind.mainSetLocalOption(key: 'azit_token', value: _token);
        await _loadDevices();
      } else {
        setState(() => _msg = d['error']?.toString() ?? '로그인 실패');
      }
    } catch (_) {
      setState(() => _msg = '네트워크 오류');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _logout() {
    bind.mainSetLocalOption(key: 'azit_token', value: '');
    setState(() {
      _token = '';
      _devices = [];
    });
  }

  Future<void> _loadDevices() async {
    try {
      final r = await http.get(Uri.parse('$kAzitBase/api/me'), headers: _auth);
      if (r.statusCode == 401) {
        _logout();
        return;
      }
      if (r.statusCode == 200) {
        final d = jsonDecode(r.body) as Map<String, dynamic>;
        final fleet = (d['fleet'] as List?) ?? [];
        final devs = <Map<String, dynamic>>[];
        for (final s in fleet) {
          for (final dev in ((s['devices'] as List?) ?? [])) {
            devs.add(dev as Map<String, dynamic>);
          }
        }
        if (mounted) setState(() => _devices = devs);
      }
    } catch (_) {}
  }

  Future<void> _redeem(String raw) async {
    final code = raw.replaceAll(RegExp(r'\D'), '');
    if (code.length != 6) {
      setState(() => _msg = '6자리 숫자를 입력하세요');
      return;
    }
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      final r = await http.post(
        Uri.parse('$kAzitBase/api/pair/redeem'),
        headers: _auth,
        body: jsonEncode({'code': code}),
      );
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200) {
        _code.clear();
        await _loadDevices();
        _connectTo(
            (d['rustdeskId'] ?? '').toString(), (d['password'] ?? '').toString());
      } else {
        setState(() => _msg = d['error']?.toString() ?? '연결 실패');
      }
    } catch (_) {
      setState(() => _msg = '네트워크 오류');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // 이미 페어링된 기기 재접속(로그인 PIN만으로) — 현재 RustDesk 자격을 서버에서 받아 연결
  Future<void> _reconnect(String deviceId) async {
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      final r = await http.get(
          Uri.parse('$kAzitBase/api/devices/$deviceId/rustdesk'),
          headers: _auth);
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200) {
        _connectTo(
            (d['rustdeskId'] ?? '').toString(), (d['password'] ?? '').toString());
      } else {
        setState(() => _msg = d['error']?.toString() ?? '재접속 실패');
      }
    } catch (_) {
      setState(() => _msg = '네트워크 오류');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _connectTo(String id, String password) {
    if (id.isEmpty) {
      showToast('기기가 아직 화면 준비가 안 됐어요. 잠시 후 다시.');
      return;
    }
    // RustDesk 네이티브 연결 경로 — 비번 자동 주입(프롬프트 없음)
    connect(context, id, password: password, isSharedPassword: false);
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const AzitScanPage()),
    );
    if (code != null && code.isNotEmpty) {
      _code.text = code;
      _redeem(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('기기 제어'),
        actions: [
          if (_token.isNotEmpty)
            IconButton(onPressed: _logout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: _token.isEmpty ? _buildLogin() : _buildControl(),
        ),
      ),
    );
  }

  Widget _buildLogin() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const Text('로그인',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
              labelText: '이메일', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pin,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration:
              const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        if (_msg.isNotEmpty)
          Text(_msg, style: const TextStyle(color: Colors.red)),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: _busy ? null : _login,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('로그인'),
          ),
        ),
      ],
    );
  }

  Widget _buildControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Text('새 기기 연결',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _busy ? null : _scan,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('QR 스캔하기'),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: '6자리 코드',
                  counterText: '',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            ElevatedButton(
              onPressed: _busy ? null : () => _redeem(_code.text),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                child: Text('연결'),
              ),
            ),
          ],
        ),
        if (_msg.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_msg, style: const TextStyle(color: Colors.red)),
          ),
        const Divider(height: 36),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('내 기기',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            IconButton(
                onPressed: _loadDevices, icon: const Icon(Icons.refresh)),
          ],
        ),
        if (_devices.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('아직 연결한 기기가 없어요. 위에서 QR/코드로 연결하세요.',
                style: TextStyle(color: Colors.black54)),
          )
        else
          ..._devices.map((d) {
            final online = d['online'] == true;
            return Card(
              child: ListTile(
                leading: Icon(Icons.devices,
                    color: online ? const Color(0xFF22a06b) : Colors.grey),
                title: Text(d['name']?.toString() ?? '기기'),
                subtitle: Text(online ? '온라인' : '오프라인'),
                trailing: ElevatedButton(
                  onPressed: (_busy || !online)
                      ? null
                      : () => _reconnect(d['id'].toString()),
                  child: const Text('접속'),
                ),
              ),
            );
          }),
      ],
    );
  }

  @override
  void dispose() {
    _email.dispose();
    _pin.dispose();
    _code.dispose();
    super.dispose();
  }
}

// ========================= QR 스캐너 (코드 문자열 반환) =========================
class AzitScanPage extends StatefulWidget {
  const AzitScanPage({Key? key}) : super(key: key);
  @override
  State<AzitScanPage> createState() => _AzitScanPageState();
}

class _AzitScanPageState extends State<AzitScanPage> {
  QRViewController? controller;
  final GlobalKey qrKey = GlobalKey(debugLabel: 'AzitQR');
  StreamSubscription? sub;
  bool _done = false;

  @override
  void reassemble() {
    super.reassemble();
    if (controller != null) {
      controller!.pauseCamera();
      controller!.resumeCamera();
    }
  }

  // azit://pair?c=123456&s=... → "123456", 아니면 숫자만 추출
  String? _extract(String raw) {
    try {
      if (raw.startsWith('azit://')) {
        final u = Uri.parse(raw);
        final c = u.queryParameters['c'];
        if (c != null && c.isNotEmpty) return c;
      }
    } catch (_) {}
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 6) return digits;
    return null;
  }

  void _onCreated(QRViewController c) {
    controller = c;
    sub = c.scannedDataStream.listen((data) {
      if (_done || data.code == null) return;
      final code = _extract(data.code!);
      if (code != null) {
        _done = true;
        c.pauseCamera();
        Navigator.of(context).pop(code);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QR 스캔')),
      body: Column(
        children: [
          Expanded(
            child: QRView(
              key: qrKey,
              onQRViewCreated: _onCreated,
              overlay: QrScannerOverlayShape(
                borderColor: const Color(0xFF2d6cdf),
                borderRadius: 10,
                borderLength: 30,
                borderWidth: 10,
                cutOutSize: 260,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('상대 기기의 QR을 사각형 안에 맞추세요',
                style: TextStyle(color: Colors.black54)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    sub?.cancel();
    controller?.dispose();
    super.dispose();
  }
}
