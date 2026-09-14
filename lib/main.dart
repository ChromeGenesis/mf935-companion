import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'poller.dart';
import 'device_tab.dart';
import 'info_tab.dart';
import 'notifications.dart';
import 'sidebar.dart';
import 'sms_tab.dart';
import 'status_tab.dart';
import 'theme.dart';
import 'ussd_tab.dart';
import 'widgets.dart';
import 'zte_client.dart';

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

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WindowListener, TrayListener {
  late final ZteClient _client;
  ZtePoller? _poller;

  final _ipCtrl = TextEditingController(text: '192.168.0.1');
  final _passCtrl = TextEditingController();
  Map<String, dynamic> _status = {};
  final List<String> _log = [];
  String _loginMessage = '';
  bool? _loginOk;
  bool _busy = false;
  int _tab = 0;
  bool _narrow = false; // <640px: bottom nav; otherwise sidebar
  // Published balance feed (StatusTab writes, header fuse ring reads).
  final ValueNotifier<DataBalance?> _balanceFeed = ValueNotifier<DataBalance?>(
    null,
  );
  Timer? _cooldownTimer;
  DateTime? _cooldownUntil;

  bool get _connected => _loginOk == true;

  /// Seconds left before another LOGIN may be sent. The firmware locks out
  /// (result=3) after a few rapid failures — and every retry resets its
  /// timer — so the UI enforces the back-off instead of trusting willpower.
  int get _cooldownLeft {
    final until = _cooldownUntil;
    if (until == null) return 0;
    final left = until.difference(DateTime.now()).inSeconds;
    return left > 0 ? left : 0;
  }

  void _startCooldown(int seconds) {
    _cooldownTimer?.cancel();
    _cooldownUntil = DateTime.now().add(Duration(seconds: seconds));
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_cooldownLeft <= 0) {
        t.cancel();
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _client = ZteClient();
    _restoreSettings();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    _cooldownTimer?.cancel();
    _balanceFeed.dispose();
    _poller?.stop();
    _ipCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _restoreSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('gateway_ip') ?? '192.168.0.1';
    final pw = prefs.getString('admin_password') ?? 'admin';
    if (!mounted) return;
    setState(() {
      _ipCtrl.text = ip;
      _passCtrl.text = pw;
      _client.gatewayIp = ip;
    });
    _startupAuth();
  }

  /// Launch auth exactly like the browser UI behaves: if the saved session
  /// cookie is still valid, reuse it (no LOGIN needed); otherwise log in
  /// once with the remembered password (defaults to 'admin').
  Future<void> _startupAuth() async {
    try {
      final probe = await _client.getStatus(
        cmds: const ['battery_vol_percent'],
      );
      if (!mounted) return;
      if ('${probe['battery_vol_percent'] ?? ''}'.isNotEmpty) {
        setState(() {
          _status = probe;
          _loginOk = true;
          _loginMessage = 'Session restored — no login needed.';
        });
        _logLine('saved session still valid @ ${_client.gatewayIp}');
        _startPoller();
        return;
      }
    } catch (_) {
      // No usable session — fall through to auto-login.
    }
    if (!mounted) return;
    _logLine('no live session — auto-login…');
    await _doLogin();
  }

  void _logLine(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, '${TimeOfDay.now().format(context)}  $line');
      if (_log.length > 200) _log.removeLast();
    });
  }

  Future<void> _doLogin() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _loginMessage = '';
      _loginOk = null;
    });
    try {
      _client.gatewayIp = _ipCtrl.text.trim();
      final result = await _client.login(_passCtrl.text);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('gateway_ip', _client.gatewayIp);
      await prefs.setString('admin_password', _passCtrl.text);
      if (!mounted) return;
      setState(() {
        _loginOk = result.success;
        _loginMessage = result.success
            ? result.message
            : '${result.message}${result.raw.isNotEmpty ? '\nRouter said: ${result.raw}' : ''}';
      });
      _logLine(
        result.success
            ? 'LOGIN ok @ ${_client.gatewayIp}'
            : 'LOGIN FAILED: ${result.message}',
      );
      if (result.raw.isNotEmpty && !result.success) {
        _logLine('raw reply: ${result.raw}');
      }
      if (result.success) {
        _cooldownTimer?.cancel();
        _cooldownUntil = null;
        _startPoller();
      } else {
        // Read the real lockout counters (free GET) instead of guessing.
        final (failsLeft, lockSecs) = await _client.getLoginCounters();
        final counterInfo = failsLeft >= 0
            ? ' Attempts left: $failsLeft${lockSecs > 0 ? ', lockout lifts in ${lockSecs}s' : ''}.'
            : '';
        if (!mounted) return;
        setState(() {
          _loginMessage =
              '${_loginMessage.split('\n').first}$counterInfo'
              '${result.raw.isNotEmpty ? '\nRouter said: ${result.raw}' : ''}';
        });
        _logLine('counters: failsLeft=$failsLeft lockSecs=$lockSecs');
        _startCooldown(lockSecs > 0 ? lockSecs + 5 : 10);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loginOk = false;
        _loginMessage = 'Unexpected error: $e';
      });
      _logLine('LOGIN error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      _client.gatewayIp = _ipCtrl.text.trim();
      final (reachable, detail) = await _client.testConnection();
      String extra = '';
      if (reachable) {
        final caps = await _client.getAuthCaps();
        final ld = '${caps['LD'] ?? ''}';
        final rd = '${caps['RD'] ?? ''}';
        if (ld.isNotEmpty || rd.isNotEmpty) {
          extra = ' Auth tokens present (LD/RD) — firmware uses token login.';
        }
      }
      if (!mounted) return;
      setState(() {
        _loginMessage = '$detail$extra';
        if (!reachable) _loginOk = false;
      });
      _logLine(reachable ? 'REACHABLE: $detail$extra' : 'UNREACHABLE: $detail');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshNow() async {
    try {
      final s = await _client.getStatus();
      if (!mounted) return;
      setState(() => _status = s);
      _logLine('status poll ok');
    } catch (e) {
      _logLine('status poll failed: $e');
      if (!mounted) return;
      setState(() => _loginOk = false);
    }
  }

  Future<void> _notifyNow(String title, String body) =>
      showAlert(_notifications, title, body);

  void _startPoller() {
    _poller?.stop();
    _poller = ZtePoller(
      client: _client,
      notifications: _notifications,
      onStatus: (s) {
        if (mounted) setState(() => _status = s);
      },
    )..start();
    _logLine('poller started (30s) — minimize to tray to keep polling');
  }

  /// Shell: sidebar on desktop, bare content on mobile (which gets
  /// the bottom nav instead).
  Widget _shell(Widget content) {
    if (_narrow) return content;
    return Row(
      children: [
        AppSidebar(
          selected: _tab,
          onSelect: (i) => setState(() => _tab = i),
          connected: _connected,
          gatewayIp: _client.gatewayIp,
        ),
        Expanded(child: content),
      ],
    );
  }

  /// Header fuse ring: the "when does my data die" answer at title
  /// level, visible on every tab. Tapping jumps to Status. Renders
  /// nothing when there is no live bundle to count down to.
  Widget _expiryDial() {
    return ValueListenableBuilder<DataBalance?>(
      valueListenable: _balanceFeed,
      builder: (_, b, _) {
        final next = b?.nextExpiry;
        final exp = next?.expiry;
        if (!_connected || exp == null || !exp.isAfter(DateTime.now())) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ExpiryDial(
            bundle: next!,
            compact: _narrow,
            onTap: () => setState(() => _tab = 0),
          ),
        );
      },
    );
  }

  /// Status panes: side-by-side on desktop, stacked + scrollable on
  /// narrow screens. One composition path (SSOT) — no duplicated cards.
  Widget _statusFlex(List<Widget> panes) {
    if (!_narrow) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [panes[0], const SizedBox(width: 12), panes[1]],
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(children: [panes[0], const SizedBox(height: 12), panes[1]]),
    );
  }

  /// Flex child: scrollable pane on desktop (content can exceed the
  /// window — overflow used to paint over the nav bar in release builds),
  /// plain child in narrow mode (the outer scroll owns the height).
  Widget _pane({required int flex, required Widget child}) => _narrow
      ? child
      : Expanded(
          flex: flex,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 4),
            child: child,
          ),
        );

  /// Log box: fixed height everywhere (an Expanded would be unbounded
  /// inside the pane scroll and crash).
  Widget _fillPane({required Widget child}) =>
      SizedBox(height: 220, child: child);

  @override
  void onWindowClose() async {
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show') {
      await windowManager.show();
    } else if (menuItem.key == 'quit') {
      _poller?.stop();
      await windowManager.setPreventClose(false);
      await windowManager.close();
    }
  }

  // ── Layout: two panes, everything visible without scrolling ──
  @override
  Widget build(BuildContext context) {
    final c = context.zc;

    final pill = !_connected
        ? StatusPill(label: 'Disconnected', color: c.danger)
        : StatusPill(label: 'Connected · ${_client.gatewayIp}', color: c.live);

    _narrow = MediaQuery.sizeOf(context).width < 640;

    return Scaffold(
      body: AmbientBackground(
        child: _shell(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
            child: Column(
              children: [
                // ── Header ──
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c.accent.withAlpha(30),
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: c.accent.withAlpha(110)),
                      ),
                      child: Icon(
                        Icons.wifi_tethering,
                        color: c.accentText,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'MF935 Companion',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'ZTE MiFi dashboard · battery · signal · data',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    _expiryDial(),
                    pill,
                  ],
                ),
                const SizedBox(height: 12),
                // ── Tab content ──
                Expanded(
                  child: _tab == 0
                      ? _statusFlex([
                          // ── Left: status (owns its balance lifecycle) ──
                          _pane(
                            flex: 11,
                            child: StatusTab(
                              client: _client,
                              connected: _connected,
                              status: _status,
                              log: _logLine,
                              notify: _notifyNow,
                              onRefreshNow: _refreshNow,
                              balanceFeed: _balanceFeed,
                              onJumpTab: (i) => setState(() => _tab = i),
                            ),
                          ),
                          // ── Right: actions ──
                          _pane(
                            flex: 9,
                            child: Column(
                              children: [
                                GlassCard(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SectionLabel('Connection'),
                                      TextField(
                                        controller: _ipCtrl,
                                        decoration: const InputDecoration(
                                          labelText: 'Gateway IP',
                                          hintText: '192.168.0.1',
                                          isDense: true,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      TextField(
                                        controller: _passCtrl,
                                        obscureText: true,
                                        decoration: const InputDecoration(
                                          labelText: 'Admin password',
                                          hintText: 'Sticker on the MiFi',
                                          isDense: true,
                                        ),
                                        onSubmitted: (_) =>
                                            _busy ? null : _doLogin(),
                                      ),
                                      const SizedBox(height: 10),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: ElevatedButton.icon(
                                              onPressed:
                                                  (_busy || _cooldownLeft > 0)
                                                  ? null
                                                  : _doLogin,
                                              icon: const Icon(
                                                Icons.login,
                                                size: 15,
                                              ),
                                              label: Text(
                                                _cooldownLeft > 0
                                                    ? 'Wait ${_cooldownLeft}s'
                                                    : _connected
                                                    ? 'Re-login'
                                                    : 'Login & poll',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: OutlinedButton.icon(
                                              onPressed: _busy
                                                  ? null
                                                  : _testConnection,
                                              icon: const Icon(
                                                Icons.radar,
                                                size: 15,
                                              ),
                                              label: const Text(
                                                'Test',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (_loginMessage.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxHeight: 64,
                                          ),
                                          child: SingleChildScrollView(
                                            child: SelectableText(
                                              _loginMessage,
                                              style: TextStyle(
                                                color: _loginOk == true
                                                    ? c.live
                                                    : const Color(0xFFFCA5A5),
                                                fontSize: 12,
                                                height: 1.4,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),
                                _fillPane(
                                  child: GlassCard(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              'DIAGNOSTICS',
                                              style: TextStyle(
                                                color: c.textMuted,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: 1.6,
                                              ),
                                            ),
                                            const Spacer(),
                                            InkWell(
                                              onTap: () =>
                                                  setState(() => _log.clear()),
                                              child: Text(
                                                'clear',
                                                style: TextStyle(
                                                  color: c.textMuted,
                                                  fontSize: 11.5,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Expanded(
                                          child: _log.isEmpty
                                              ? Text(
                                                  'No events yet — log in to begin.',
                                                  style: TextStyle(
                                                    color: c.textMuted,
                                                    fontSize: 12,
                                                  ),
                                                )
                                              : SingleChildScrollView(
                                                  child: SelectableText(
                                                    _log.join('\n'),
                                                    style: const TextStyle(
                                                      fontFamily: 'Consolas',
                                                      fontSize: 11.5,
                                                      height: 1.55,
                                                      color: Color(0xFFCBD5E1),
                                                    ),
                                                  ),
                                                ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ])
                      : _tab == 1
                      ? SmsTab(
                          client: _client,
                          connected: _connected,
                          log: _logLine,
                        )
                      : _tab == 2
                      ? UssdTab(
                          client: _client,
                          connected: _connected,
                          log: _logLine,
                        )
                      : _tab == 3
                      ? InfoTab(
                          client: _client,
                          connected: _connected,
                          log: _logLine,
                        )
                      : DeviceTab(
                          client: _client,
                          connected: _connected,
                          log: _logLine,
                        ),
                ),
                if (_narrow) const SizedBox(height: 8),
                if (_narrow)
                  NavigationBar(
                    height: 56,
                    backgroundColor: Colors.transparent,
                    indicatorColor: c.accent.withAlpha(40),
                    selectedIndex: _tab,
                    onDestinationSelected: (i) => setState(() => _tab = i),
                    labelTextStyle: WidgetStatePropertyAll(
                      TextStyle(color: c.textSecondary, fontSize: 11),
                    ),
                    destinations: [
                      NavigationDestination(
                        icon: Icon(
                          Icons.dashboard_outlined,
                          color: c.textMuted,
                        ),
                        selectedIcon: Icon(
                          Icons.dashboard,
                          color: c.accentText,
                        ),
                        label: 'Status',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.sms_outlined, color: c.textMuted),
                        selectedIcon: Icon(Icons.sms, color: c.accentText),
                        label: 'SMS',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.dialpad_outlined, color: c.textMuted),
                        selectedIcon: Icon(Icons.dialpad, color: c.accentText),
                        label: 'USSD',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.info_outline, color: c.textMuted),
                        selectedIcon: Icon(Icons.info, color: c.accentText),
                        label: 'Info',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.settings_outlined, color: c.textMuted),
                        selectedIcon: Icon(Icons.settings, color: c.accentText),
                        label: 'Device',
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
