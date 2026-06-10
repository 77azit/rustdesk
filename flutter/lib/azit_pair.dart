// 키오스크관리 — 페어링 UX (사용자 확정 그림)
//  · 피제어 기기(어르신 태블릿): 앱 켜면 QR + 6자리 표시 → 제어자가 스캔/입력하면 클레임됨
//  · 제어자(도우미 폰): 로그인 → QR 스캔 / 6자리 입력 → 우리 서버가 RustDesk 자격 중개 → 화면제어
//  서버 API: /api/pair/announce, /api/pair/redeem, /api/pair/status (pairing-qr-architecture)
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' as crypto; // sha256 (2차인증 해시)
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:flutter_hbb/models/platform_model.dart'; // bind
import 'package:flutter_hbb/common.dart'; // connect(), showToast, AndroidPermissionManager, gFFI
import 'package:flutter_hbb/consts.dart'; // kActionAccessibilitySettings
import 'package:flutter_hbb/azit_agent.dart'; // AzitAgent, kAzitBase

// 2차인증(PIN·패턴) 정본 서버 — db.77azit.com. (제어자 로그인 = 이 시스템 단독)
const String kAuthBase = 'https://db.77azit.com';

// 브랜드 색상
const Color kBrand = Color(0xFF0071FF);
const Color kBrandDark = Color(0xFF0059CC);

String _sha256hex(String s) =>
    crypto.sha256.convert(utf8.encode(s)).toString();

// pin_hash = sha256( canonical + salt ),  salt = sha256("77azit_"+email)[:16]
// canonical: 패턴 = 점인덱스 '-' join("0-4-8") / PIN = 숫자문자열("1234")
String azitPinHash(String secretCanonical, String email) {
  final salt = _sha256hex('77azit_${email.toLowerCase().trim()}').substring(0, 16);
  return _sha256hex(secretCanonical + salt);
}

// 앱 홈 상태: null=확인중, true=연결됨, false=미연결. AzitAgent가 갱신.
final ValueNotifier<bool?> azitClaimed = ValueNotifier<bool?>(null);

// ========================= 우리 자체 홈 (RustDesk HomePage 완전 대체) =========================
// 가림막이 아니라 진짜 교체 — 밑에 RustDesk 홈이 존재하지 않음.
class AzitHome extends StatelessWidget {
  const AzitHome({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool?>(
      valueListenable: azitClaimed,
      builder: (c, claimed, _) {
        if (claimed == null) {
          return const Scaffold(
            backgroundColor: Colors.white,
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return claimed ? const AzitConnectedScreen() : const AzitPairScreen();
      },
    );
  }
}

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
  bool _revealed = false; // 코드 표시 중인지(상시노출 X, 도움받기 누를 때만)
  int _secsLeft = 0;
  Timer? _pollTimer;
  Timer? _refreshTimer;
  Timer? _countdown;
  static const int kRevealSecs = 180; // 3분 표시 후 자동 숨김(노출 최소화)

  @override
  void initState() {
    super.initState();
    _deviceKey = _ensureDeviceKey();
    // 보안: 코드를 상시 띄우지 않음. 사용자가 [도움 받기]를 눌러야 표시.
  }

  void _reveal() {
    if (_revealed || _claimed) return;
    // 프라이버시: "도움 받기"를 눌렀을 때 비로소 피제어 서비스를 켬(이전엔 아무도 못 붙음)
    AzitAgent.instance.ensureRustDeskService();
    setState(() {
      _revealed = true;
      _status = '준비 중...';
      _secsLeft = kRevealSecs;
    });
    _announce();
    // 어르신 친화: 화면 터치 제어용 접근성 권한이 꺼져있으면 설정까지 안내(딥링크)
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _ensureInputPermissionGuide());
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _claimed) { t.cancel(); return; }
      setState(() => _secsLeft--);
      if (_secsLeft <= 0) { t.cancel(); _hide(); }
    });
  }

  // 화면 터치 제어(접근성) 권한이 꺼져있으면 친절히 안내 + 설정으로 직접 데려다줌.
  // (RustDesk처럼 사용자가 '설정 어디 가세요' 헤매지 않게)
  bool _inputGuideShown = false;
  void _ensureInputPermissionGuide() {
    if (_inputGuideShown || !mounted) return;
    bool ok = false;
    try { ok = gFFI.serverModel.inputOk; } catch (_) {}
    if (ok) return; // 이미 켜짐
    _inputGuideShown = true;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('터치 제어 권한 켜기'),
        content: const Text(
          '상대가 이 화면을 직접 만져서 도와드리려면\n'
          '권한 하나만 켜면 돼요.\n\n'
          '아래 [권한 켜기]를 누르면 설정이 열려요.\n'
          '거기서 "키오스크관리"를 찾아 켜주세요.',
          style: TextStyle(fontSize: 15, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('나중에'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(c).pop();
              try {
                AndroidPermissionManager.startAction(
                    kActionAccessibilitySettings);
              } catch (_) {}
            },
            child: const Text('권한 켜기'),
          ),
        ],
      ),
    );
  }

  void _hide() {
    _pollTimer?.cancel();
    _refreshTimer?.cancel();
    _countdown?.cancel();
    if (mounted) {
      setState(() { _revealed = false; _code = null; _qrPayload = null; });
    }
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

  bool _approvalShowing = false;

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_claimed) return;
      try {
        final r = await http
            .get(Uri.parse('$kAzitBase/api/pair/status?deviceKey=$_deviceKey'));
        if (r.statusCode == 200) {
          final d = jsonDecode(r.body) as Map<String, dynamic>;
          if (d['claimed'] == true) {
            _onClaimed(d);
          } else if (d['request'] != null && !_approvalShowing) {
            // 누군가 6자리로 연결을 요청함 → 기기 앞 사람이 허용해야 자격 발급(보안 핵심)
            _showApprovalDialog(d['request'] as Map<String, dynamic>);
          }
        }
      } catch (_) {}
    });
  }

  // 연결 승인 다이얼로그: 코드를 훔쳐봐도 여기서 [허용]을 안 누르면 못 붙음
  Future<void> _showApprovalDialog(Map<String, dynamic> req) async {
    if (_approvalShowing || _claimed || !mounted) return;
    _approvalShowing = true;
    final requestId = (req['requestId'] ?? '').toString();
    final verify = (req['verifyCode'] ?? '--').toString();
    final email = (req['accountEmail'] ?? '').toString();
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('연결 요청'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$email 님이 이 기기에 연결하려 합니다.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 16),
            const Text('상대 화면의 확인번호와 같은지 보세요',
                style: TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 6),
            Text(verify,
                style: const TextStyle(
                    fontSize: 44,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 8,
                    color: Color(0xFF2d6cdf))),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('거부', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('허용'),
          ),
        ],
      ),
    );
    try {
      // 허용 시 새 1회용 비번 회전 → 이번 연결용으로 발급(정적 비번 제거)
      final freshPw =
          approved == true ? AzitAgent.instance.rotatePassword() : '';
      await http.post(
        Uri.parse('$kAzitBase/api/pair/approve'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceKey': _deviceKey,
          'requestId': requestId,
          'approve': approved == true,
          'rustdeskPassword': freshPw,
        }),
      );
    } catch (_) {}
    _approvalShowing = false;
    // 허용했으면 다음 폴링에서 claimed 잡힘. 거부했으면 계속 코드 표시.
  }

  void _onClaimed(Map<String, dynamic> d) {
    if (_claimed) return;
    _claimed = true;
    _pollTimer?.cancel();
    _refreshTimer?.cancel();
    _countdown?.cancel();
    AzitAgent.instance.onClaimed(
        (d['deviceId'] ?? '').toString(), (d['agentKey'] ?? '').toString());
    if (mounted) setState(() => _status = '연결되었습니다 ✓');
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _refreshTimer?.cancel();
    _countdown?.cancel();
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
                const SizedBox(height: 12),
                if (_claimed) ...[
                  const Text('연결되었습니다 ✓',
                      style: TextStyle(fontSize: 15, color: Colors.black54)),
                  const SizedBox(height: 24),
                  const Icon(Icons.check_circle,
                      color: Color(0xFF22a06b), size: 120),
                ] else if (!_revealed) ...[
                  // 보안: 코드를 상시 노출하지 않음. 누군가 도와줄 때만 표시.
                  const Text('도움을 받을 때만 연결 코드를 보여주세요',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 15, color: Colors.black54)),
                  const SizedBox(height: 40),
                  SizedBox(
                    width: 260,
                    height: 64,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.qr_code_2, size: 28),
                      label: const Text('도움 받기 (연결 코드 보기)',
                          style: TextStyle(fontSize: 16)),
                      onPressed: _reveal,
                    ),
                  ),
                ] else ...[
                  Text(_status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 15, color: Colors.black54)),
                  const SizedBox(height: 20),
                  if (_qrPayload != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFe0e0e0)),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: QrImageView(
                        data: _qrPayload!,
                        version: QrVersions.auto,
                        size: 220,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('또는 이 번호 입력',
                        style: TextStyle(fontSize: 14, color: Colors.black45)),
                    const SizedBox(height: 6),
                    Text(
                      _code ?? '------',
                      style: const TextStyle(
                        fontSize: 50,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 10,
                        color: Color(0xFF2d6cdf),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text('$_secsLeft초 후 자동으로 숨겨집니다',
                        style: const TextStyle(fontSize: 12, color: Colors.black38)),
                    TextButton(onPressed: _hide, child: const Text('숨기기')),
                  ] else
                    const CircularProgressIndicator(),
                ],
                const SizedBox(height: 32),
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

// ========================= 연결된 기기: 상태 화면 + 연결 해제 =========================
class AzitConnectedScreen extends StatelessWidget {
  const AzitConnectedScreen({Key? key}) : super(key: key);

  Future<void> _unpair(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('연결 해제'),
        content: const Text(
          '이 기기의 원격 연결을 끊을까요?\n'
          '해제하면 더 이상 아무도 이 기기에 연결할 수 없어요.\n'
          '(다시 도움받으려면 "도움 받기"를 누르면 돼요)',
          style: TextStyle(fontSize: 15, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('연결 해제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AzitAgent.instance.unpair();
    // AzitHome이 azitClaimed=false를 감지해 자동으로 "도움 받기" 화면으로 전환(별도 네비 불필요)
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.verified_user,
                    color: Color(0xFF22a06b), size: 96),
                const SizedBox(height: 20),
                const Text('이 기기는 연결되어 있어요',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87)),
                const SizedBox(height: 10),
                const Text('필요할 때 원격으로 도와드릴 수 있어요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, color: Colors.black54)),
                const SizedBox(height: 40),
                SizedBox(
                  width: 260,
                  height: 56,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.touch_app),
                    label: const Text('도움 받을 준비하기',
                        style: TextStyle(fontSize: 16)),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0071FF),
                        foregroundColor: Colors.white),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const AzitPermissionScreen()),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 260,
                  height: 56,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.link_off, color: Colors.red),
                    label: const Text('연결 해제',
                        style: TextStyle(fontSize: 16, color: Colors.red)),
                    style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.red)),
                    onPressed: () => _unpair(context),
                  ),
                ),
                const SizedBox(height: 24),
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

// ===================== 도움 받을 준비 (어르신 친화 단계별 안내) =====================
// 전문용어 제거 · 큰 단계 · 권한 켜고 돌아오면 자동으로 '준비됨'으로 전환 · 무서운 '허용' 안심
class AzitPermissionScreen extends StatefulWidget {
  const AzitPermissionScreen({Key? key}) : super(key: key);
  @override
  State<AzitPermissionScreen> createState() => _AzitPermissionScreenState();
}

class _AzitPermissionScreenState extends State<AzitPermissionScreen> {
  static const _brand = Color(0xFF0071FF);
  static const _green = Color(0xFF1FA463);
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // 권한을 켜고 돌아오면 화면이 저절로 '준비됨'으로 바뀌도록 실시간 감지
    _poll = Timer.periodic(
        const Duration(milliseconds: 600), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool get _mediaOk {
    try { return gFFI.serverModel.mediaOk; } catch (_) { return false; }
  }
  bool get _inputOk {
    try { return gFFI.serverModel.inputOk; } catch (_) { return false; }
  }

  @override
  Widget build(BuildContext context) {
    final media = _mediaOk, input = _inputOk;
    final allDone = media && input;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('도움 받을 준비',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0.4,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 40),
          children:
              allDone ? _doneBody(context) : _setupBody(context, media, input),
        ),
      ),
    );
  }

  // ── 준비 완료 화면 ──
  List<Widget> _doneBody(BuildContext context) => [
        const SizedBox(height: 24),
        const Center(child: Icon(Icons.verified_rounded, color: _green, size: 92)),
        const SizedBox(height: 22),
        const Text('준비 다 됐어요! 🎉',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 26, fontWeight: FontWeight.bold, color: Colors.black87)),
        const SizedBox(height: 14),
        const Text('이제 멀리 있는 가족이\n언제든 이 기기를 도와드릴 수 있어요.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, height: 1.6, color: Colors.black54)),
        const SizedBox(height: 44),
        Center(
          child: SizedBox(
            width: 200,
            height: 56,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _brand,
                  foregroundColor: Colors.white,
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ];

  // ── 준비 중 화면 ──
  List<Widget> _setupBody(BuildContext context, bool media, bool input) => [
        const Text('가족이 멀리서도\n도와줄 수 있게 준비해요',
            style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.bold,
                height: 1.35,
                color: Colors.black87)),
        const SizedBox(height: 12),
        const Text('아래 단추만 누르면 제가 알려드릴게요.\n천천히 따라오시면 1분이면 끝나요. 😊',
            style: TextStyle(fontSize: 16, height: 1.55, color: Colors.black54)),
        const SizedBox(height: 30),
        _bigStep(
          done: media,
          icon: Icons.visibility_rounded,
          title: '화면 보여주기',
          desc: '가족이 이 화면을 볼 수 있어요',
          action: '켜기',
          onTap: () async {
            try { await gFFI.serverModel.toggleService(); } catch (_) {}
            if (mounted) setState(() {});
          },
        ),
        const SizedBox(height: 18),
        _bigStep(
          done: input,
          icon: Icons.touch_app_rounded,
          title: '대신 눌러주기',
          desc: '가족이 멀리서 화면을 대신 눌러줄 수 있어요',
          action: '준비하기',
          onTap: () => _showInputGuide(context),
        ),
        const SizedBox(height: 26),
        // 켰는데도 안 눌러지는 기기(키오스크 등)용 — 어르신껜 작게, 관리자만
        if (input)
          Center(
            child: TextButton(
              onPressed: () => _showAdvancedGuide(context),
              child: const Text('켰는데도 안 눌러지나요?',
                  style: TextStyle(fontSize: 14, color: Colors.black45)),
            ),
          ),
      ];

  Widget _bigStep({
    required bool done,
    required IconData icon,
    required String title,
    required String desc,
    required String action,
    required VoidCallback onTap,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: done ? const Color(0xFFF1FBF5) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: done ? const Color(0xFFBBE6CD) : const Color(0xFFE2E7EE),
            width: 1.6),
      ),
      child: Row(children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
              color: done
                  ? const Color(0xFFDDF3E6)
                  : const Color(0xFFE7F0FF),
              shape: BoxShape.circle),
          child: Icon(done ? Icons.check_rounded : icon,
              color: done ? _green : _brand, size: 30),
        ),
        const SizedBox(width: 16),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87)),
            const SizedBox(height: 4),
            Text(done ? '준비됐어요' : desc,
                style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: done ? _green : Colors.black54)),
          ]),
        ),
        const SizedBox(width: 10),
        if (!done)
          SizedBox(
            height: 50,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _brand,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13)),
                  padding: const EdgeInsets.symmetric(horizontal: 18)),
              onPressed: onTap,
              child: Text(action,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
      ]),
    );
  }

  // 접근성 켜는 법 — 어르신용 큰 단계 + 무서운 '허용' 안심
  void _showInputGuide(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('이렇게만 하면 돼요',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('잠시 후 설정 화면이 열려요.\n화면 보면서 천천히 따라 하세요.',
                  style: TextStyle(
                      fontSize: 15.5, height: 1.5, color: Colors.black54)),
              const SizedBox(height: 20),
              _gStep('1', '목록에서 ', '키오스크 입력제어', ' 를 손가락으로 누르세요'),
              _gStep('2', '맨 위 동그란 단추를 눌러 ', '켜세요', ' (파란색이 되면 켜진 거예요)'),
              _gStep('3', '', "'허용'", ' 을 누르세요'),
              _gNote('걱정 마세요 — 가족이 도와드리려고 켜는 거라 안전해요. 😊'),
              _gStep('4', '왼쪽 위 ', '← 화살표', ' 를 눌러 돌아오세요'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                    color: const Color(0xFFEFF5FF),
                    borderRadius: BorderRadius.circular(13)),
                child: Row(children: const [
                  Icon(Icons.auto_awesome_rounded, color: _brand, size: 22),
                  SizedBox(width: 11),
                  Expanded(
                      child: Text('다 하시면 이 화면이 저절로 "준비됐어요"로 바뀌어요!',
                          style: TextStyle(
                              fontSize: 14.5,
                              height: 1.45,
                              fontWeight: FontWeight.w500))),
                ]),
              ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('취소', style: TextStyle(fontSize: 16)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: _brand,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13))),
            onPressed: () {
              Navigator.pop(c);
              try {
                AndroidPermissionManager.startAction(
                    kActionAccessibilitySettings);
              } catch (_) {}
            },
            child: const Text('설정 열기',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _gStep(String n, String a, String b, String c) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 32,
            height: 32,
            decoration:
                const BoxDecoration(color: _brand, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(n,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text.rich(TextSpan(
                  style: const TextStyle(
                      fontSize: 16.5, height: 1.45, color: Colors.black87),
                  children: [
                    TextSpan(text: a),
                    TextSpan(
                        text: b,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: _brand)),
                    TextSpan(text: c),
                  ])),
            ),
          ),
        ]),
      );

  Widget _gNote(String t) => Padding(
        padding: const EdgeInsets.only(left: 45, bottom: 16),
        child:
            Text(t, style: const TextStyle(fontSize: 13.5, height: 1.4, color: _green)),
      );

  // 켰는데도 안 눌러지는 기기(KTC 등) — 관리자/기사용
  void _showAdvancedGuide(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('관리자 안내'),
        content: const SingleChildScrollView(
          child: Text(
            '일부 키오스크 화면은 보안 때문에 일반 터치를 막아요.\n'
            '이 기기는 설치 기사/관리자가 "고급 입력 모드"를 1회 설정하면 '
            '원격 터치가 동작합니다.\n\n'
            '(앱이 자동으로 설정하는 기능은 준비 중이에요.)',
            style: TextStyle(fontSize: 14.5, height: 1.55),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('확인')),
        ],
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
  // 2차인증 스테이지: 'email'(이메일 입력) | 'verify'(PIN/패턴) | 'nopin'(미설정 차단)
  String _stage = 'email';
  String _method = ''; // 'pin' | 'pattern'
  String _authedEmail = '';

  @override
  void initState() {
    super.initState();
    _token = bind.mainGetLocalOption(key: 'azit_token');
    if (_token.isNotEmpty) _loadDevices();
  }

  Map<String, String> get _auth =>
      {'Content-Type': 'application/json', 'Authorization': 'Bearer $_token'};

  // 1단계: 이메일 → 2차인증 설정 여부/방식 확인 (db.77azit.com)
  Future<void> _checkEmail() async {
    final email = _email.text.trim().toLowerCase();
    if (!email.contains('@')) {
      setState(() => _msg = '이메일을 정확히 입력하세요');
      return;
    }
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      final r = await http.get(Uri.parse(
          '$kAuthBase/api/auth/check-pin-exists?email=${Uri.encodeQueryComponent(email)}'));
      if (r.statusCode != 200) {
        setState(() => _msg = '확인 실패. 잠시 후 다시');
        return;
      }
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      if (d['exists'] == true) {
        setState(() {
          _authedEmail = email;
          _method = (d['method'] ?? 'pin').toString();
          _stage = 'verify';
          _pin.clear();
        });
      } else {
        setState(() => _stage = 'nopin');
      }
    } catch (_) {
      setState(() => _msg = '네트워크 오류');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // 2단계: PIN/패턴 → verify-pin → 토큰(스코프=토큰의 email). 해시 정본 azitPinHash.
  Future<void> _verify(String canonical) async {
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      final hash = azitPinHash(canonical, _authedEmail);
      final r = await http.post(
        Uri.parse('$kAuthBase/api/auth/verify-pin'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': _authedEmail, 'pin_hash': hash}),
      );
      if (r.statusCode == 200) {
        final d = jsonDecode(r.body) as Map<String, dynamic>;
        _token = (d['access_token'] ?? d['token'] ?? '').toString();
        bind.mainSetLocalOption(key: 'azit_token', value: _token);
        await _loadDevices();
        if (mounted) setState(() {});
      } else {
        setState(() => _msg = '2차인증이 맞지 않아요');
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
      _stage = 'email';
      _method = '';
      _authedEmail = '';
      _pin.clear();
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

  String _awaitVerify = ''; // 기기 승인 대기 중 표시할 확인번호

  Future<void> _redeem(String raw) async {
    final code = raw.replaceAll(RegExp(r'\D'), '');
    if (code.length != 6) {
      setState(() => _msg = '6자리 숫자를 입력하세요');
      return;
    }
    setState(() {
      _busy = true;
      _msg = '';
      _awaitVerify = '';
    });
    try {
      final r = await http.post(
        Uri.parse('$kAzitBase/api/pair/redeem'),
        headers: _auth,
        body: jsonEncode({'code': code}),
      );
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200 && d['pending'] == true) {
        _code.clear();
        if (mounted) setState(() => _awaitVerify = (d['verifyCode'] ?? '').toString());
        await _pollApproval((d['requestId'] ?? '').toString());
      } else {
        setState(() => _msg = d['error']?.toString() ?? '연결 실패');
      }
    } catch (_) {
      setState(() => _msg = '네트워크 오류');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // 기기 승인 폴링(최대 2분). 기기에서 [허용]하면 자격 받아 연결.
  Future<void> _pollApproval(String requestId) async {
    for (int i = 0; i < 60; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final r = await http.get(
            Uri.parse('$kAzitBase/api/pair/redeem/status?requestId=$requestId'),
            headers: _auth);
        if (r.statusCode != 200) {
          setState(() { _msg = '요청이 만료되었습니다'; _awaitVerify = ''; });
          return;
        }
        final d = jsonDecode(r.body) as Map<String, dynamic>;
        final st = d['status'];
        if (st == 'approved') {
          setState(() => _awaitVerify = '');
          await _loadDevices();
          _connectTo((d['rustdeskId'] ?? '').toString(),
              (d['password'] ?? '').toString());
          return;
        } else if (st == 'denied') {
          setState(() { _msg = '기기에서 연결을 거부했습니다'; _awaitVerify = ''; });
          return;
        }
        // pending → 계속 대기
      } catch (_) {}
    }
    if (mounted) setState(() { _msg = '승인 대기 시간이 초과됐어요. 다시 시도하세요'; _awaitVerify = ''; });
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

  // 기기 연결 해제(목록에서 제거)
  Future<void> _deleteDevice(String deviceId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('연결 해제'),
        content: Text('"$name"의 연결을 해제할까요? 목록에서 제거됩니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('해제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      final r = await http.delete(
          Uri.parse('$kAzitBase/api/devices/$deviceId'),
          headers: _auth);
      if (r.statusCode == 200) {
        await _loadDevices();
        setState(() => _msg = '연결 해제됨');
      } else {
        final d = jsonDecode(r.body) as Map<String, dynamic>;
        setState(() => _msg = d['error']?.toString() ?? '해제 실패');
      }
    } catch (_) {
      setState(() => _msg = '네트워크 오류');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      backgroundColor: const Color(0xFFF4F6FA),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: _token.isEmpty ? _buildLogin() : _buildControl(),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 디자인 헬퍼 ----------------
  Widget _card(Widget child) => Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 22,
                offset: const Offset(0, 8))
          ],
        ),
        child: child,
      );

  InputDecoration _dec(String hint, {Widget? icon}) => InputDecoration(
        hintText: hint,
        prefixIcon: icon,
        filled: true,
        fillColor: const Color(0xFFF1F4F8),
        counterText: '',
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      );

  Widget _primaryBtn(String label, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: kBrand,
              foregroundColor: Colors.white,
              elevation: 0,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          onPressed: (_busy || onTap == null) ? null : onTap,
          child: _busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(label),
        ),
      );

  Widget _ghostBtn(String label, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        height: 50,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
              foregroundColor: kBrand,
              side: const BorderSide(color: kBrand, width: 1.4),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          onPressed: (_busy || onTap == null) ? null : onTap,
          child: Text(label),
        ),
      );

  Widget _errText() => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(_msg,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFE03131), fontSize: 13)),
      );

  Widget _brandHeader() => Column(children: [
        Container(
          width: 66,
          height: 66,
          decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [kBrand, kBrandDark],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                    color: kBrand.withOpacity(0.35),
                    blurRadius: 18,
                    offset: const Offset(0, 8))
              ]),
          child:
              const Icon(Icons.cast_connected, color: Colors.white, size: 34),
        ),
        const SizedBox(height: 16),
        const Text('키오스크관리',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('원격 도움 · 안전하게 연결',
            style: TextStyle(color: Colors.black54, fontSize: 13)),
      ]);

  Widget _buildLogin() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 24),
      _brandHeader(),
      const SizedBox(height: 28),
      _card(_stage == 'nopin'
          ? _loginNoPin()
          : _stage == 'verify'
              ? _loginVerify()
              : _loginEmail()),
      const SizedBox(height: 24),
    ]);
  }

  Widget _loginEmail() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('로그인',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('철지트 계정 이메일로 들어갑니다',
              style: TextStyle(color: Colors.black54, fontSize: 13)),
          const SizedBox(height: 18),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _checkEmail(),
            decoration: _dec('이메일', icon: const Icon(Icons.mail_outline)),
          ),
          if (_msg.isNotEmpty) _errText(),
          const SizedBox(height: 18),
          _primaryBtn('다음', _checkEmail),
        ],
      );

  Widget _loginNoPin() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.lock_outline, size: 42, color: kBrand),
          const SizedBox(height: 14),
          const Text('2차인증을 먼저 설정하세요',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          const Text('철지트 관리자 페이지에서 PIN 또는 패턴을\n먼저 등록한 뒤 다시 시도해주세요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54, fontSize: 13, height: 1.5)),
          const SizedBox(height: 20),
          _ghostBtn('이메일 다시 입력', () => setState(() {
                _stage = 'email';
                _msg = '';
              })),
        ],
      );

  Widget _loginVerify() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            InkWell(
              onTap: _busy
                  ? null
                  : () => setState(() {
                        _stage = 'email';
                        _msg = '';
                      }),
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.arrow_back, size: 20)),
            ),
            const SizedBox(width: 8),
            Expanded(
                child: Text(_authedEmail,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 18),
          if (_method == 'pattern') ...[
            const Text('패턴을 그려주세요',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 18),
            Center(
              child: PatternPad(
                enabled: !_busy,
                onComplete: (dots) {
                  if (dots.length >= 4) {
                    _verify(dots.join('-'));
                  } else {
                    setState(() => _msg = '점을 4개 이상 이어주세요');
                  }
                },
              ),
            ),
            if (_busy)
              const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Center(
                      child: SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)))),
          ] else ...[
            const Text('PIN을 입력하세요',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            TextField(
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 26, letterSpacing: 10, fontWeight: FontWeight.w700),
              onSubmitted: (v) => _verify(v.trim()),
              decoration: _dec('· · · ·'),
            ),
            const SizedBox(height: 16),
            _primaryBtn('확인', () => _verify(_pin.text.trim())),
          ],
          if (_msg.isNotEmpty) _errText(),
        ],
      );

  Widget _buildControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [kBrand, kBrandDark]),
                borderRadius: BorderRadius.circular(12)),
            child:
                const Icon(Icons.cast_connected, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          const Expanded(
              child: Text('키오스크관리',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
          IconButton(
              onPressed: _logout,
              icon: const Icon(Icons.logout, size: 20),
              color: Colors.black45,
              tooltip: '로그아웃'),
        ]),
        const SizedBox(height: 18),
        _card(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('새 기기 연결',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('도움받는 기기 화면의 6자리 코드를 입력하세요',
                style: TextStyle(color: Colors.black54, fontSize: 12)),
            const SizedBox(height: 16),
            if (!isDesktop) ...[
              _ghostBtn('📷  QR 스캔하기', _scan),
              const SizedBox(height: 12),
            ],
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  style: const TextStyle(
                      fontSize: 20,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w700),
                  decoration: _dec('6자리 코드'),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: kBrand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(horizontal: 22)),
                  onPressed: (_busy || _awaitVerify.isNotEmpty)
                      ? null
                      : () => _redeem(_code.text),
                  child: const Text('연결',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
            if (_awaitVerify.isNotEmpty) _verifyBanner(),
            if (_msg.isNotEmpty) _errText(),
          ],
        )),
        const SizedBox(height: 22),
        Row(children: [
          const Text('내 기기',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const Spacer(),
          IconButton(
              onPressed: _busy ? null : _loadDevices,
              icon: const Icon(Icons.refresh, size: 20),
              color: Colors.black45),
        ]),
        const SizedBox(height: 6),
        if (_devices.isEmpty)
          _emptyDevices()
        else
          ..._devices.map(_deviceCard),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _verifyBanner() => Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFFEEF4FF),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBrand.withOpacity(0.4)),
        ),
        child: Column(children: [
          const Text('기기에서 [허용]을 눌러주세요',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 4),
          const Text('아래 확인번호가 기기 화면과 같은지 확인하세요',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 10),
          Text(_awaitVerify,
              style: const TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 10,
                  color: kBrand)),
          const SizedBox(height: 8),
          const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
      );

  Widget _emptyDevices() => Container(
        padding: const EdgeInsets.symmetric(vertical: 30),
        alignment: Alignment.center,
        child: Column(children: const [
          Icon(Icons.devices_other, size: 40, color: Colors.black26),
          SizedBox(height: 10),
          Text('아직 연결한 기기가 없어요',
              style: TextStyle(
                  color: Colors.black54,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          Text('위에서 6자리 코드로 기기를 연결하세요',
              style: TextStyle(color: Colors.black38, fontSize: 12)),
        ]),
      );

  Widget _deviceCard(Map<String, dynamic> d) {
    final online = d['online'] == true;
    final name = d['name']?.toString() ?? '기기';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 14,
              offset: const Offset(0, 4))
        ],
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
              color: (online ? kBrand : Colors.grey).withOpacity(0.12),
              borderRadius: BorderRadius.circular(12)),
          child: Icon(Icons.tablet_android,
              color: online ? kBrand : Colors.grey, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style:
                      const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Row(children: [
                Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                        color:
                            online ? const Color(0xFF22C55E) : Colors.grey,
                        shape: BoxShape.circle)),
                const SizedBox(width: 5),
                Text(online ? '온라인' : '오프라인',
                    style: TextStyle(
                        fontSize: 12,
                        color: online
                            ? const Color(0xFF16A34A)
                            : Colors.grey)),
              ]),
            ],
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: kBrand,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11)),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10)),
          onPressed:
              (_busy || !online) ? null : () => _reconnect(d['id'].toString()),
          child:
              const Text('접속', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        IconButton(
          tooltip: '연결 해제',
          icon: const Icon(Icons.more_vert, size: 20, color: Colors.black26),
          onPressed:
              _busy ? null : () => _deleteDevice(d['id'].toString(), name),
        ),
      ]),
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

// ========================= 패턴 입력 패드 (3×3 드래그, 점 0~8 = 정본 "0-4-8") =========
class PatternPad extends StatefulWidget {
  final bool enabled;
  final void Function(List<int> dots) onComplete;
  const PatternPad({Key? key, required this.onComplete, this.enabled = true})
      : super(key: key);
  @override
  State<PatternPad> createState() => _PatternPadState();
}

class _PatternPadState extends State<PatternPad> {
  static const double _size = 280;
  final List<int> _selected = [];
  Offset? _current;
  final List<Offset> _centers = [];

  void _initCenters() {
    if (_centers.isNotEmpty) return;
    const pad = 40.0;
    final step = (_size - pad * 2) / 2;
    for (int r = 0; r < 3; r++) {
      for (int c = 0; c < 3; c++) {
        _centers.add(Offset(pad + c * step, pad + r * step));
      }
    }
  }

  int? _hit(Offset p) {
    for (int i = 0; i < 9; i++) {
      if ((p - _centers[i]).distance < 28) return i;
    }
    return null;
  }

  void _update(Offset local) {
    _current = local;
    final h = _hit(local);
    if (h != null && !_selected.contains(h)) {
      _selected.add(h);
    }
    setState(() {});
  }

  void _end() {
    final dots = List<int>.from(_selected);
    setState(() {
      _selected.clear();
      _current = null;
    });
    if (dots.isNotEmpty) widget.onComplete(dots);
  }

  @override
  Widget build(BuildContext context) {
    _initCenters();
    return IgnorePointer(
      ignoring: !widget.enabled,
      child: GestureDetector(
        onPanStart: (d) {
          _selected.clear();
          _update(d.localPosition);
        },
        onPanUpdate: (d) => _update(d.localPosition),
        onPanEnd: (_) => _end(),
        child: CustomPaint(
          size: const Size(_size, _size),
          painter: _PatternPainter(_centers, _selected, _current),
        ),
      ),
    );
  }
}

class _PatternPainter extends CustomPainter {
  final List<Offset> centers;
  final List<int> selected;
  final Offset? current;
  _PatternPainter(this.centers, this.selected, this.current);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = kBrand
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (int i = 0; i < selected.length - 1; i++) {
      canvas.drawLine(centers[selected[i]], centers[selected[i + 1]], line);
    }
    if (selected.isNotEmpty && current != null) {
      canvas.drawLine(centers[selected.last], current!, line);
    }
    for (int i = 0; i < 9; i++) {
      final on = selected.contains(i);
      if (on) {
        canvas.drawCircle(
            centers[i],
            22,
            Paint()..color = kBrand.withOpacity(0.12));
      }
      canvas.drawCircle(centers[i], on ? 11 : 8,
          Paint()..color = on ? kBrand : const Color(0xFFB7C2D0));
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) =>
      old.selected.length != selected.length || old.current != current;
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
