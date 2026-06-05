// 키오스크관리 — 우리 플랫폼 연동 에이전트 (RustDesk 앱에 이식되는 우리 로직)
//  - 등록(코드) → deviceId/agentKey 저장
//  - 우리 서버(/panel/agent)에 상시 연결, 자기 RustDesk ID/무인비번 보고
//  - 'reboot' 명령 수신 → device-owner 리부트
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_hbb/models/platform_model.dart'; // bind
import 'package:flutter_hbb/common.dart'; // globalKey
import 'package:flutter_hbb/azit_pair.dart'; // AzitPairScreen (QR+6자리)

const String kAzitBase = 'https://remote.77azit.com/panel';
const String kAzitWs = 'wss://remote.77azit.com/panel/agent';
const MethodChannel _native = MethodChannel('azit/native');

class AzitAgent {
  static final AzitAgent instance = AzitAgent._();
  AzitAgent._();

  WebSocket? _ws;
  bool _stopped = false;
  Timer? _reconnectTimer;

  Future<void> start() async {
    // 키오스크는 항상 "피제어 가능" 상태여야 함. RustDesk 모바일은 기본이 제어자모드라
    // 서비스를 자동시작 안 함 → 코어가 hbbs에 등록 안 됨 → 외부에서 "offline".
    // 우리가 직접 서비스 시작 → hbbs 등록 + 화면수신 준비(권한은 device-owner/appops 사전부여).
    _ensureRustDeskService();

    String deviceId = '', agentKey = '';
    try {
      final creds = await _native.invokeMethod('get_creds');
      deviceId = (creds?['deviceId'] ?? '').toString();
      agentKey = (creds?['agentKey'] ?? '').toString();
    } catch (e) {
      debugPrint('AZIT: get_creds error $e');
    }
    if (deviceId.isEmpty || agentKey.isEmpty) {
      // 미등록 → QR+6자리 페어링 화면(제어자가 스캔/입력하면 클레임됨)
      WidgetsBinding.instance.addPostFrameCallback((_) => _showPairScreen());
      return;
    }
    _ensurePermanentPassword();
    _connect(deviceId, agentKey);
  }

  bool _serviceStarted = false;
  // RustDesk 서비스(코어 server + 화면캡처) 시작 → 기기가 hbbs에 등록되어 외부 접속 수신 가능
  void _ensureRustDeskService() {
    if (_serviceStarted) return;
    _serviceStarted = true;
    // FFI/엔진 초기화 여유를 두고 시작
    Future.delayed(const Duration(seconds: 2), () async {
      try {
        if (!gFFI.serverModel.isStart) {
          await gFFI.serverModel.startService();
          debugPrint('AZIT: RustDesk service started → hbbs 등록');
        }
      } catch (e) {
        debugPrint('AZIT: startService error $e');
      }
    });
  }

  void _showPairScreen() {
    final ctx = globalKey.currentContext;
    if (ctx == null) return;
    Navigator.of(ctx).push(
      MaterialPageRoute(builder: (_) => const AzitPairScreen()),
    );
  }

  // 피제어 기기 신원: 영구비번 보장 + 현재 RustDesk ID 반환(페어링 announce용)
  Future<Map<String, String>> prepareIdentity() async {
    final pw = _ensurePermanentPassword();
    String myId = '';
    try {
      myId = await bind.mainGetMyId();
    } catch (_) {}
    return {'id': myId, 'pw': pw};
  }

  // 페어링 클레임 성공 → 자격 저장 + 에이전트 연결 시작
  Future<void> onClaimed(String deviceId, String agentKey) async {
    if (deviceId.isEmpty || agentKey.isEmpty) return;
    try {
      await _native
          .invokeMethod('save_creds', {'deviceId': deviceId, 'agentKey': agentKey});
    } catch (_) {}
    _ensurePermanentPassword();
    _connect(deviceId, agentKey);
  }

  // 무인 접속용 영구 비밀번호 보장(없으면 생성·저장·적용)
  String _ensurePermanentPassword() {
    var pw = bind.mainGetLocalOption(key: 'azit_pw');
    if (pw.isEmpty) {
      final r = Random.secure();
      pw = List.generate(8, (_) => r.nextInt(10)).join();
      bind.mainSetLocalOption(key: 'azit_pw', value: pw);
    }
    try {
      bind.mainSetPermanentPasswordWithResult(password: pw);
    } catch (_) {}
    return pw;
  }

  Future<void> _connect(String deviceId, String agentKey) async {
    if (_stopped) return;
    try {
      debugPrint('AZIT: connecting $kAzitWs');
      final ws = await WebSocket.connect(kAzitWs);
      _ws = ws;
      final myId = await bind.mainGetMyId();
      final pw = _ensurePermanentPassword();
      debugPrint('AZIT: ws open, register rustdeskId=$myId');
      ws.add(jsonEncode({
        'type': 'register',
        'deviceId': deviceId,
        'agentKey': agentKey,
        'rustdeskId': myId,
        'rustdeskPassword': pw,
      }));
      ws.listen(
        (data) => _onMessage(data),
        onDone: () => _scheduleReconnect(deviceId, agentKey),
        onError: (_) => _scheduleReconnect(deviceId, agentKey),
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('AZIT: ws error $e');
      _scheduleReconnect(deviceId, agentKey);
    }
  }

  void _onMessage(dynamic data) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (m['type'] == 'command') {
      final cmd = m['command'];
      if (cmd == 'reboot') {
        _native.invokeMethod('reboot');
      } else if (cmd == 'set_volume') {
        _native.invokeMethod('set_volume', {'percent': (m['value'] ?? 50)});
      }
      _ws?.add(jsonEncode({'type': 'command-result', 'id': m['id'], 'ok': true}));
    }
  }

  void _scheduleReconnect(String deviceId, String agentKey) {
    _ws = null;
    if (_stopped) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () => _connect(deviceId, agentKey));
  }

  // 등록 코드 클레임 → 자격증명 저장 → 연결 시작
  Future<String?> enroll(String code) async {
    try {
      final r = await http.post(
        Uri.parse('$kAzitBase/api/enroll/claim'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'code': code.trim().toUpperCase()}),
      );
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) return d['error']?.toString() ?? '등록 실패';
      final deviceId = d['deviceId'] as String;
      final agentKey = d['agentKey'] as String;
      try {
        await _native.invokeMethod('save_creds', {'deviceId': deviceId, 'agentKey': agentKey});
      } catch (_) {}
      debugPrint('AZIT: enroll ok device=$deviceId');
      _ensurePermanentPassword();
      _connect(deviceId, agentKey); // 저장 재읽기 의존 없이 즉시 연결
      return null; // 성공
    } catch (e) {
      debugPrint('AZIT: enroll error $e');
      return '네트워크 오류';
    }
  }

  void _promptEnroll() {
    final ctx = globalKey.currentContext;
    if (ctx == null) return;
    final controller = TextEditingController();
    String? err;
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: const Text('키오스크 등록'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('관리자에게 받은 8자리 등록 코드를 입력하세요.'),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: '예: ABCD2345',
                  errorText: err,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () async {
                final e = await enroll(controller.text);
                if (e == null) {
                  Navigator.of(c).pop();
                } else {
                  setState(() => err = e);
                }
              },
              child: const Text('등록'),
            ),
          ],
        ),
      ),
    );
  }
}
