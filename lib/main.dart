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
import 'core/notifications.dart';
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
  // Android 13+ drops show() silently until the runtime grant exists —
  // ask once at boot so alerts actually appear.
  await requestNotificationPermission(_notifications);

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

  // Restore the saved theme mode + accent before the first frame.
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('theme_mode') ?? 'system';
  final initial = switch (saved) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
  final initialAccent = ZteAccent.values.firstWhere(
    (a) => a.name == prefs.getString('theme_accent'),
    orElse: () => ZteAccent.amber,
  );

  runApp(ZteApp(initialMode: initial, initialAccent: initialAccent));
}

class ZteApp extends StatefulWidget {
  final ThemeMode initialMode;
  final ZteAccent initialAccent;

  const ZteApp({
    super.key,
    required this.initialMode,
    this.initialAccent = ZteAccent.amber,
  });

  /// Change the app-wide theme and persist the choice.
  static void setThemeMode(BuildContext context, ThemeMode mode) {
    final state = context.findAncestorStateOfType<_ZteAppState>();
    state?._setMode(mode);
  }

  /// Change the app-wide accent palette and persist the choice.
  static void setAccent(BuildContext context, ZteAccent accent) {
    final state = context.findAncestorStateOfType<_ZteAppState>();
    state?._setAccent(accent);
  }

  /// Current ThemeMode (for header toggle chips), or null when the
  /// state is not mounted below [ZteApp].
  static ThemeMode? maybeMode(BuildContext context) {
    final state = context.findAncestorStateOfType<_ZteAppState>();
    return state?._mode;
  }

  /// Current accent palette (for the switcher's selected dot), or null
  /// when not mounted below [ZteApp].
  static ZteAccent? maybeAccent(BuildContext context) {
    final state = context.findAncestorStateOfType<_ZteAppState>();
    return state?._accent;
  }

  @override
  State<ZteApp> createState() => _ZteAppState();
}

class _ZteAppState extends State<ZteApp> {
  late ThemeMode _mode = widget.initialMode;
  late ZteAccent _accent = widget.initialAccent;

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

  void _setAccent(ZteAccent accent) {
    setState(() => _accent = accent);
    SharedPreferences.getInstance().then(
      (p) => p.setString('theme_accent', accent.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MiFi Companion',
      theme: buildZteTheme(brightness: Brightness.light, accent: _accent),
      darkTheme: buildZteTheme(brightness: Brightness.dark, accent: _accent),
      themeMode: _mode,
      debugShowCheckedModeBanner: false,
      home: const DashboardPage(),
    );
  }
}
