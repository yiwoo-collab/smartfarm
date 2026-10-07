import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../models/farm.dart';
import '../models/rmu_status.dart';
import '../services/farm_store.dart';
import '../services/rmu_api.dart';

/// 설정 > 농장 연결: 연동된 농장 목록 (추가·수정·삭제)
class FarmListScreen extends StatelessWidget {
  final FarmStore store;

  const FarmListScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final farms = store.farms;
        return Scaffold(
          appBar: AppBar(title: const Text('농장 연결')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openEditor(context, null),
            icon: const Icon(Icons.add),
            label: const Text('농장 추가'),
          ),
          body: ListView(
            children: [
              if (farms.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('연결된 농장이 없습니다. 아래 버튼으로 추가하세요.'),
                ),
              for (final farm in farms)
                ListTile(
                  leading: const Icon(Icons.agriculture),
                  title: Text(farm.name),
                  subtitle: Text('${farm.crop} · ${farm.rmuAddress}'),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _openEditor(context, farm),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.science),
                title: const Text('예시 농장 추가 (개발용)'),
                subtitle: Text(
                  kIsWeb
                      ? '모의 RMU ${Uri.base.host}:8080, 8081'
                      : '모의 RMU를 실행 중인 PC의 IP를 입력합니다',
                ),
                onTap: () => _addMockFarms(context),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 웹: 지금 열린 페이지의 PC 주소를 그대로 쓴다 (폰 브라우저에서도 동작)
  /// 앱(APK): PC의 IP를 물어본다
  Future<void> _addMockFarms(BuildContext context) async {
    if (kIsWeb) {
      await store.addMockFarms(Uri.base.host);
      return;
    }
    final controller = TextEditingController(text: '192.168.');
    final host = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('모의 RMU PC 주소'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'PC의 IP (시작하기.bat 창에 표시)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('추가'),
          ),
        ],
      ),
    );
    if (host != null && host.isNotEmpty) await store.addMockFarms(host);
  }

  void _openEditor(BuildContext context, Farm? farm) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FarmEditScreen(store: store, farm: farm),
      ),
    );
  }
}

/// 농장 추가 / 수정 화면. farm이 null이면 새 농장.
class FarmEditScreen extends StatefulWidget {
  final FarmStore store;
  final Farm? farm;

  const FarmEditScreen({super.key, required this.store, this.farm});

  @override
  State<FarmEditScreen> createState() => _FarmEditScreenState();
}

class _FarmEditScreenState extends State<FarmEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.farm?.name);
  late final _crop = TextEditingController(text: widget.farm?.crop);
  late final _address = TextEditingController(text: widget.farm?.rmuAddress);
  late final _community = TextEditingController(
    text: widget.farm?.community ?? 'public',
  );
  String? _testResult;

  @override
  void dispose() {
    _name.dispose();
    _crop.dispose();
    _address.dispose();
    _community.dispose();
    super.dispose();
  }

  Farm _buildFarm() {
    final values = (
      name: _name.text.trim(),
      crop: _crop.text.trim(),
      address: _address.text.trim(),
      community: _community.text.trim(),
    );
    final old = widget.farm;
    if (old != null) {
      return old.copyWith(
        name: values.name,
        crop: values.crop,
        rmuAddress: values.address,
        community: values.community,
      );
    }
    return Farm(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: values.name,
      crop: values.crop,
      rmuAddress: values.address,
      community: values.community,
    );
  }

  /// 입력한 주소로 /api/status 를 한 번 불러 본다
  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _testResult = '연결 확인 중...');
    try {
      final status = await RmuApi(_buildFarm().baseUrl).fetchStatus();
      if (!mounted) return;
      setState(
        () => _testResult =
            '연결 성공 (알람 등급: ${alarmLevelNames[status.alarmLevel.clamp(0, 3)]})',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _testResult = '연결 실패: 주소를 확인하세요');
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final farm = _buildFarm();
    if (widget.farm == null) {
      await widget.store.add(farm);
    } else {
      await widget.store.update(farm);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('농장 삭제'),
        content: Text('${widget.farm!.name} 연결을 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.remove(widget.farm!.id);
    if (mounted) Navigator.of(context).pop();
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? '입력해 주세요' : null;

  /// "IP:포트" 또는 "호스트:포트" 형식인지 확인
  String? _validateAddress(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return '입력해 주세요';
    final parts = value.split(':');
    if (parts.length != 2 || parts[0].isEmpty) return '예: 192.168.0.10:8080';
    final port = int.tryParse(parts[1]);
    if (port == null || port < 1 || port > 65535) return '포트 번호가 올바르지 않습니다';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.farm == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? '농장 추가' : '농장 수정'),
        actions: [
          if (!isNew)
            IconButton(
              tooltip: '삭제',
              icon: const Icon(Icons.delete),
              onPressed: _delete,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '농장 이름 (예: 방울토마토 1동)',
              ),
              validator: _required,
            ),
            TextFormField(
              controller: _crop,
              decoration: const InputDecoration(labelText: '작물 (예: 방울토마토)'),
              validator: _required,
            ),
            TextFormField(
              controller: _address,
              decoration: const InputDecoration(
                labelText: 'RMU 주소 (IP:포트)',
                hintText: '192.168.0.10:8080',
              ),
              validator: _validateAddress,
            ),
            TextFormField(
              controller: _community,
              decoration: const InputDecoration(labelText: 'SNMP 커뮤니티'),
              validator: _required,
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _testConnection,
              child: const Text('연결 테스트'),
            ),
            if (_testResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_testResult!, textAlign: TextAlign.center),
              ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('저장')),
          ],
        ),
      ),
    );
  }
}
