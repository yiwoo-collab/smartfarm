import 'dart:convert';

import 'package:http/http.dart' as http;

import '../demo/demo_rmu.dart';
import '../models/rmu_status.dart';

/// RMU가 돌려준 오류 (401 로그인 필요, 409 자동 모드 잠금 등)
class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

/// RMU REST API 호출 (CLAUDE.md 6장).
/// 관리자 작업(제어·임계값·설정)은 로그인으로 받은 토큰이 필요하다.
class RmuApi {
  static const _timeout = Duration(seconds: 5); // 폰 와이파이는 PC보다 느릴 수 있다

  final String baseUrl;
  String? token; // 로그인하면 채워진다

  RmuApi(this.baseUrl);

  bool get loggedIn => token != null;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<Map<String, dynamic>> _send(
    String method,
    String path, [
    Object? body,
  ]) async {
    if (DemoRmu.isDemoUrl(baseUrl)) return _sendDemo(method, path, body);
    final uri = Uri.parse('$baseUrl$path');
    final encoded = body == null ? null : jsonEncode(body);
    final res = await switch (method) {
      'GET' => http.get(uri, headers: _headers),
      'POST' => http.post(uri, headers: _headers, body: encoded),
      _ => http.put(uri, headers: _headers, body: encoded),
    }.timeout(_timeout);
    final json = res.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      if (res.statusCode == 401) token = null; // 토큰이 만료되었으면 다시 로그인
      throw ApiException(
        res.statusCode,
        (json['error'] as String?) ?? 'HTTP ${res.statusCode}',
      );
    }
    return json;
  }

  /// 데모 모드: 앱 안의 모의 RMU가 응답한다 (서버·네트워크 없이 체험)
  Future<Map<String, dynamic>> _sendDemo(
    String method,
    String path,
    Object? body,
  ) async {
    final demo = DemoRmu.forAddress(baseUrl.substring('http://'.length));
    try {
      final result = demo.handle(method, path, body, token);
      // 실제 HTTP와 같은 모양(숫자 타입 등)이 되도록 JSON으로 한 번 바꿨다가 읽는다
      return jsonDecode(jsonEncode(result)) as Map<String, dynamic>;
    } on DemoRmuError catch (e) {
      if (e.statusCode == 401) token = null;
      throw ApiException(e.statusCode, e.message);
    } catch (e) {
      // 데모 RMU 코드 자체의 오류: "연결할 수 없음"으로 숨기지 않고 내용을 보여준다
      throw ApiException(500, '데모 RMU 오류: $e');
    }
  }

  Future<RmuStatus> fetchStatus() async =>
      RmuStatus.fromJson(await _send('GET', '/api/status'));

  Future<Map<String, dynamic>> fetchPower() => _send('GET', '/api/power');

  /// 이벤트 조회. lastId는 RMU의 마지막 이벤트 번호 (재시작 감지용)
  Future<({List<Map<String, dynamic>> events, int lastId})> fetchEvents(
    int since,
  ) async {
    final json = await _send('GET', '/api/events?since=$since');
    final events = [
      for (final e in json['events'] as List) e as Map<String, dynamic>,
    ];
    return (events: events, lastId: (json['last_id'] as int?) ?? since);
  }

  /// 센서 기록 (2단계). range: 1h, 6h, 24h, 7d
  Future<List<({DateTime time, double value})>> fetchHistory(
    String sensor,
    String range,
  ) async {
    final json = await _send('GET', '/api/history?sensor=$sensor&range=$range');
    return [
      for (final p in json['points'] as List)
        (
          time: DateTime.parse(p['time'] as String),
          value: (p['value'] as num).toDouble(),
        ),
    ];
  }

  Future<void> login(String username, String password) async {
    final json = await _send('POST', '/api/login', {
      'username': username,
      'password': password,
    });
    token = json['token'] as String;
  }

  void logout() => token = null;

  /// 장치 조작. device 예: aircon, aircon_setpoint, control_mode, restore_main_fan
  Future<void> control(String device, Object? value) =>
      _send('POST', '/api/control', {'device': device, 'value': value});

  Future<Map<String, dynamic>> fetchThresholds() =>
      _send('GET', '/api/thresholds');

  Future<Map<String, dynamic>> updateThresholds(Map<String, num> changes) =>
      _send('PUT', '/api/thresholds', changes);

  Future<Map<String, dynamic>> fetchSettings() => _send('GET', '/api/settings');

  /// 작물별 임계값 기본값 {작물: {임계값 이름: 값}}
  Future<Map<String, dynamic>> fetchCrops() => _send('GET', '/api/crops');

  Future<Map<String, dynamic>> updateSettings(Map<String, int> changes) =>
      _send('PUT', '/api/settings', changes);

  Future<List<Map<String, dynamic>>> fetchScenarios() async {
    final json = await _send('GET', '/api/simulate');
    return [
      for (final s in json['scenarios'] as List) s as Map<String, dynamic>,
    ];
  }

  Future<String> simulate(Map<String, dynamic> body) async {
    final json = await _send('POST', '/api/simulate', body);
    return json['message'] as String;
  }
}
