import 'package:flutter/material.dart';

import '../services/farm_monitor.dart';
import '../services/rmu_api.dart';

/// 제어·설정 같은 권한 작업 전에 부른다 (시나리오 20).
/// 이미 로그인했으면 바로 true, 아니면 로그인 창을 띄운다.
/// 로그인은 농장(RMU)마다 따로 한다.
Future<bool> ensureLoggedIn(BuildContext context, FarmMonitor monitor) async {
  if (monitor.api.loggedIn) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _LoginDialog(monitor: monitor),
  );
  return ok == true;
}

class _LoginDialog extends StatefulWidget {
  final FarmMonitor monitor;

  const _LoginDialog({required this.monitor});

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.monitor.api.login(_username.text.trim(), _password.text);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'RMU에 연결할 수 없습니다');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('관리자 로그인 · ${widget.monitor.farm.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('제어와 설정 변경은 로그인이 필요합니다.'),
          TextField(
            controller: _username,
            decoration: const InputDecoration(labelText: '아이디'),
          ),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: '비밀번호'),
            onSubmitted: (_) => _login(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _busy ? null : _login,
          child: const Text('로그인'),
        ),
      ],
    );
  }
}
