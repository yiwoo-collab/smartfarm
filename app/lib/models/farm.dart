/// 연동된 농장 프로필 (이름, 작물, RMU 주소, 커뮤니티).
/// 임계값은 RMU에 저장하고 /api/thresholds 로 주고받는다.
class Farm {
  final String id; // 앱 안에서 농장을 구분하는 값 (만든 시각)
  final String name; // 예: 방울토마토 1동
  final String crop; // 예: 방울토마토
  final String rmuAddress; // 예: 192.168.0.10:8080
  final String community; // SNMP 커뮤니티 (예: public)

  const Farm({
    required this.id,
    required this.name,
    required this.crop,
    required this.rmuAddress,
    this.community = 'public',
  });

  /// REST API 기본 주소
  String get baseUrl => 'http://$rmuAddress';

  Farm copyWith({
    String? name,
    String? crop,
    String? rmuAddress,
    String? community,
  }) {
    return Farm(
      id: id,
      name: name ?? this.name,
      crop: crop ?? this.crop,
      rmuAddress: rmuAddress ?? this.rmuAddress,
      community: community ?? this.community,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'crop': crop,
    'rmu_address': rmuAddress,
    'community': community,
  };

  factory Farm.fromJson(Map<String, dynamic> json) => Farm(
    id: json['id'] as String,
    name: json['name'] as String,
    crop: json['crop'] as String,
    rmuAddress: json['rmu_address'] as String,
    community: (json['community'] as String?) ?? 'public',
  );
}
