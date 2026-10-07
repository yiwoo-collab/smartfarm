import 'package:flutter/material.dart';

import '../app_services.dart';
import 'farm_admin_screen.dart';
import 'farm_settings_screen.dart';

/// 설정 탭
///  - 화면 모드 (라이트/다크), 알림 받기/끄기 (앱 설정, 폰에 저장)
///  - 농장 연결 (농장 전환 방법 2)
///  - 농장별 RMU 관리: 야간 모드, 임계값, 시뮬레이션 (RMU 설정)
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final settings = services.settings;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, services.farms]),
      builder: (context, _) {
        final farms = services.farms.farms;
        return Scaffold(
          appBar: AppBar(title: const Text('설정')),
          body: ListView(
            children: [
              _header(context, '화면'),
              SwitchListTile(
                secondary: const Icon(Icons.dark_mode),
                title: const Text('다크 모드'),
                subtitle: Text(settings.darkMode ? '다크' : '라이트'),
                value: settings.darkMode,
                onChanged: settings.setDarkMode,
              ),

              _header(context, '알림'),
              SwitchListTile(
                secondary: const Icon(Icons.notifications),
                title: const Text('알림 받기'),
                subtitle: const Text('긴급 경보는 꺼도 항상 받습니다'),
                value: settings.notificationsOn,
                onChanged: settings.setNotificationsOn,
              ),
              if (services.notifier?.supported ?? false)
                SwitchListTile(
                  secondary: const Icon(Icons.phone_android),
                  title: const Text('휴대폰/브라우저 알림'),
                  subtitle: const Text(
                    '앱이 뒤에 있어도 알림창에 표시합니다. 앱이 완전히 꺼져 있을 때는 RMU 푸시(ntfy)를 쓰세요',
                  ),
                  value: settings.systemNotifications,
                  onChanged: (v) => _toggleSystemNotifications(context, v),
                ),
              for (final f in farms)
                SwitchListTile(
                  contentPadding: const EdgeInsets.only(left: 72, right: 16),
                  title: Text(f.name),
                  value:
                      settings.notificationsOn && !settings.isFarmMuted(f.id),
                  onChanged: settings.notificationsOn
                      ? (v) => settings.setFarmMuted(f.id, !v)
                      : null,
                ),
              ListTile(
                leading: const Icon(Icons.timer),
                title: const Text('같은 알림 최소 간격'),
                subtitle: const Text('긴급 경보는 해소될 때까지 1분마다 반복'),
                trailing: DropdownButton<int>(
                  value: settings.minIntervalMinutes,
                  items: [
                    for (final m in const [1, 5, 10, 30])
                      DropdownMenuItem(value: m, child: Text('$m분')),
                  ],
                  onChanged: (v) => settings.setMinInterval(v!),
                ),
              ),

              _header(context, '농장'),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('농장 연결'),
                subtitle: Text('연결된 농장 ${farms.length}개 · 추가·변경·삭제'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => FarmListScreen(store: services.farms),
                  ),
                ),
              ),

              _header(context, 'RMU 관리 (야간 모드 · 임계값 · 시뮬레이션)'),
              if (farms.isEmpty) const ListTile(title: Text('연결된 농장이 없습니다')),
              for (final f in farms)
                ListTile(
                  leading: const Icon(Icons.router),
                  title: Text(f.name),
                  subtitle: Text(f.rmuAddress),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FarmAdminScreen(
                        monitor: services.monitors.monitorFor(f.id)!,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 켤 때는 알림 권한을 먼저 받는다
  Future<void> _toggleSystemNotifications(BuildContext context, bool on) async {
    final services = AppServices.of(context);
    if (!on) {
      await services.settings.setSystemNotifications(false);
      return;
    }
    final granted = await services.notifier!.requestPermission();
    if (!context.mounted) return;
    if (granted) {
      await services.settings.setSystemNotifications(true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('알림 권한이 없습니다. 휴대폰/브라우저 설정에서 알림을 허용하세요')),
      );
    }
  }

  Widget _header(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
