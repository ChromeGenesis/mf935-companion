library;

/// App bootstrap (SSOT): window/tray/notifications setup + [ZteApp].
/// The dashboard shell lives in `dashboard.dart`.
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'features/dashboard.dart';
import 'core/theme.dart';

final _notifications = FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  await windowManager.setTitle('MF935 Companion');
  await windowManager.setMinimumSize(const Size(1060, 700));

  const initSettings = InitializationSettings(
    linux: LinuxInitializationSettings(defaultActionName: 'Open'),
    windows: WindowsInitializationSettings(
      appName: 'MF935 Companion',
      appUserModelId: 'com.genesis.zte_mf935_app',
      guid: '8a3b5c1d-2e4f-4a6b-9c0d-1e2f3a4b5c6d',
    ),
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await _notifications.initialize(settings: initSettings);

  await trayManager.setToolTip('MF935 Companion');
  try {
    await trayManager.setIcon('assets/tray_icon.ico');
  } catch (_) {
    // No tray icon asset yet — tooltip + menu still work.
  }
  await trayManager.setContextMenu(
    Menu(
      items: [
        MenuItem(key: 'show', label: 'Show'),
        MenuItem(key: 'quit', label: 'Quit'),
      ],
    ),
  );

  runApp(const ZteApp());
}

class ZteApp extends StatelessWidget {
  const ZteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MF935 Companion',
      theme: buildZteTheme(),
      debugShowCheckedModeBanner: false,
      home: const DashboardPage(),
    );
  }
}
