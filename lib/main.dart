library;

/// App bootstrap (SSOT): window/tray/notifications setup + [ZteApp].
/// The dashboard shell lives in `dashboard.dart`.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'features/dashboard.dart';
import 'core/platform.dart';
import 'core/theme.dart';

final _notifications = FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop-only chrome. window_manager / tray_manager have no Android
  // implementation — calling them on mobile crashes boot.
  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    await windowManager.setTitle('MiFi Companion');
    await windowManager.setMinimumSize(const Size(1060, 700));
  }

  // Edge-to-edge on mobile: content draws under the transparent
  // status bar (see [ZSystemUI]) instead of a solid system band.
  // Desktop has no such chrome — skip it there.
  if (!isDesktop) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  const initSettings = InitializationSettings(
    linux: LinuxInitializationSettings(defaultActionName: 'Open'),
    windows: WindowsInitializationSettings(
      appName: 'MiFi Companion',
      appUserModelId: 'com.genesis.zte_mf935_app',
      guid: '8a3b5c1d-2e4f-4a6b-9c0d-1e2f3a4b5c6d',
    ),
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await _notifications.initialize(settings: initSettings);

  if (isDesktop) {
    await trayManager.setToolTip('MiFi Companion');
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
  }

  // Restore the saved theme mode before the first frame (system | light | dark).
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('theme_mode') ?? 'system';
  final initial = switch (saved) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  runApp(ZteApp(initialMode: initial));
}

class ZteApp extends StatefulWidget {
  final ThemeMode initialMode;

  const ZteApp({super.key, required this.initialMode});

  /// Change the app-wide theme and persist the choice.
  static void setThemeMode(BuildContext context, ThemeMode mode) {
    final state = context.findAncestorStateOfType<_ZteAppState>();
    state?._setMode(mode);
  }

  /// Current ThemeMode (for header toggle chips), or null when the
  /// state is not mounted below [ZteApp].
  static ThemeMode? maybeMode(BuildContext context) {
    final state = context.findAncestorStateOfType<_ZteAppState>();
    return state?._mode;
  }

  @override
  State<ZteApp> createState() => _ZteAppState();
}

class _ZteAppState extends State<ZteApp> {
  late ThemeMode _mode = widget.initialMode;

  void _setMode(ThemeMode mode) {
    setState(() => _mode = mode);
    SharedPreferences.getInstance().then(
      (p) => p.setString(
        'theme_mode',
        switch (mode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          _ => 'system',
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MiFi Companion',
      theme: buildZteTheme(brightness: Brightness.light),
      darkTheme: buildZteTheme(brightness: Brightness.dark),
      themeMode: _mode,
      debugShowCheckedModeBanner: false,
      home: const DashboardPage(),
    );
  }
}
