import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/rmu_event.dart';
import 'alerts_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

/// 하단 탭: 홈 / 알림 / 설정.
/// 제어는 홈의 [제어] 버튼으로 연다 (로그인 필요).
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _tab = 0; // 첫 화면은 홈
  StreamSubscription<RmuEvent>? _popupSub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 새 알림이 오면 어느 탭에 있든 화면 아래에 띄운다
    _popupSub ??= AppServices.of(context).alerts.popups.listen(_showPopup);
  }

  @override
  void dispose() {
    _popupSub?.cancel();
    super.dispose();
  }

  void _showPopup(RmuEvent e) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: eventColor(e),
        duration: Duration(seconds: e.level >= 3 ? 10 : 5),
        persist: false, // [보기] 버튼이 있어도 시간이 지나면 닫힌다
        content: Row(
          children: [
            Icon(eventIcon(e), color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '[${e.farmName}] ${e.message}',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: '보기',
          textColor: Colors.white,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => AlertDetailScreen(event: e)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final alerts = AppServices.of(context).alerts;
    return Scaffold(
      // IndexedStack: 탭을 옮겨도 각 화면 상태가 유지된다
      body: IndexedStack(
        index: _tab,
        children: const [HomeScreen(), AlertsScreen(), SettingsScreen()],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: alerts,
        builder: (context, _) {
          // 알림 탭 배지: 최근 경보(등급 1 이상 발생) 개수
          final count = alerts.events
              .where((e) => e.type == 'alarm' && e.level > 0)
              .length;
          return NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              const NavigationDestination(icon: Icon(Icons.home), label: '홈'),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: count > 0,
                  label: Text('$count'),
                  child: const Icon(Icons.notifications),
                ),
                label: '알림',
              ),
              const NavigationDestination(
                icon: Icon(Icons.settings),
                label: '설정',
              ),
            ],
          );
        },
      ),
    );
  }
}
