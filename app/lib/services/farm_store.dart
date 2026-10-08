import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/farm.dart';

/// 연동된 농장 목록을 들고 있고, 폰에 저장한다.
/// 목록이 바뀌면 notifyListeners()로 홈·설정 화면에 알린다.
class FarmStore extends ChangeNotifier {
  static const _key = 'farms';

  List<Farm> _farms = [];

  List<Farm> get farms => List.unmodifiable(_farms);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      _farms = (jsonDecode(raw) as List)
          .map((e) => Farm.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    notifyListeners();
  }

  Future<void> add(Farm farm) => _save([..._farms, farm]);

  Future<void> update(Farm farm) =>
      _save([for (final f in _farms) f.id == farm.id ? farm : f]);

  Future<void> remove(String id) =>
      _save(_farms.where((f) => f.id != id).toList());

  Future<void> _save(List<Farm> farms) async {
    _farms = farms;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_farms.map((f) => f.toJson()).toList()),
    );
  }

  /// 서버 없이 체험: 앱 안의 데모 RMU(demo:1, demo:2)에 연결한 농장을 넣는다.
  Future<void> addDemoFarms() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _save([
      ..._farms,
      Farm(
        id: '$now-d1',
        name: '방울토마토 1동 (데모)',
        crop: '방울토마토',
        rmuAddress: 'demo:1',
      ),
      Farm(id: '$now-d2', name: '상추 2동 (데모)', crop: '상추', rmuAddress: 'demo:2'),
    ]);
  }

  /// 개발용: 모의 RMU 두 개(8080, 8081)에 연결한 예시 농장을 넣는다.
  /// host: 모의 RMU가 돌고 있는 PC 주소 (PC 브라우저는 localhost, 폰은 PC의 IP)
  Future<void> addMockFarms([String host = 'localhost']) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _save([
      ..._farms,
      Farm(
        id: '$now-1',
        name: '방울토마토 1동',
        crop: '방울토마토',
        rmuAddress: '$host:8080',
      ),
      Farm(id: '$now-2', name: '상추 2동', crop: '상추', rmuAddress: '$host:8081'),
    ]);
  }
}
