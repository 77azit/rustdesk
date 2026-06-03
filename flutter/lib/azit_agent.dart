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
    final deviceId = bind.mainGetLocalOption(key: 'azit_device_id');
    final agentKey = bind.mainGetLocalOption(key: 'azit_agent_key');
    if (deviceId.isEmpty || agentKey.isEmpty) {
      // 미등록 → 첫 화면 뜬 뒤 등록 다이얼로그
      WidgetsBinding.instance.addPostFrameCallback((_) => _promptEnroll());
      return;
    }
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
    if (m['type'] == 'command' && m['command'] == 'reboot') {
      _native.invokeMethod('reboot');
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
      bind.mainSetLocalOption(key: 'azit_device_id', value: deviceId);
      bind.mainSetLocalOption(key: 'azit_agent_key', value: agentKey);
      debugPrint('AZIT: enroll ok device=$deviceId readback=${bind.mainGetLocalOption(key: 'azit_device_id')}');
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
