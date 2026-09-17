library;

/// Dashboard shell (SSOT): session, polling, navigation and tab
/// composition. App bootstrap (`main()`, [ZteApp]) lives in `main.dart`.
/// Header is a collapsing sliver (TradeMum parity) — the countdown and
/// theme controls live in their feature cards, never in the header.
/// Connection + diagnostics panels live exclusively in Settings.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/poller.dart';
import '../core/capability.dart';
import '../core/advanced.dart';
import '../core/device_store.dart';
import '../core/diagnostics.dart';
import '../core/monitor_modes.dart';
import '../core/platform.dart';
import '../core/speed_history.dart';
import '../core/speed_test.dart';
import '../core/signal_locator.dart';
import '../core/smart_alerts.dart';
import 'bottom_nav.dart';
import 'info_tab.dart';
import 'settings_tab.dart';
import 'signal_locator_widgets.dart';
import '../core/notifications.dart';
import 'sidebar.dart';
import 'sms_tab.dart';
import 'status_tab.dart';
import '../core/theme.dart';
import 'ussd_tab.dart';
import '../core/widgets.dart';
import '../core/zte_client.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WindowListener, TrayListener {
  late final ZteClient _client;
  ZtePoller? _poller;
  // Initialized once in main(); this handle only routes show() calls.
  final _notifications = FlutterLocalNotificationsPlugin();

  final _ipCtrl = TextEditingController(text: '192.168.0.1');
  final _passCtrl = TextEditingController();
  Map<String, dynamic> _status = {};
  final List<String> _log = [];
  // Raw balance replies (MTN *323*4# / Airtel *323*1#): archived for
  // the Settings tab only — the primary screen surfaces parsed
  // results, never verbose modem text.
  final List<String> _balanceRawLog = [];
  String _loginMessage = '';
  bool? _loginOk;
  bool _busy = false;
  int _tab = 0;
  bool _narrow = false; // <640px: bottom nav; otherwise sidebar
  // Published balance feed (StatusTab writes; the dashboard balance
  // card reads it for the countdown pill).
  final ValueNotifier<DataBalance?> _balanceFeed = ValueNotifier<DataBalance?>(
    null,
  );
  final ValueNotifier<SignalSample?> _signalFeed = ValueNotifier<SignalSample?>(
    null,
  );
  Timer? _cooldownTimer;
  DateTime? _cooldownUntil;
  final CapabilityRegistry capabilities = CapabilityRegistry();

  /// Phase 9 loopback API server (lives while the toggle is on).
  final LocalApiServer _localApi = LocalApiServer();

  /// Phase 9 housekeeping: scheduled diagnostics + scheduled reboot,
  /// checked every minute.
  Timer? _housekeeping;

  /// Phase 5 smart-alert engine: fed by every poller tick, fires
  /// evidence-bearing notifications. Last-fired map is restored from
  /// prefs so the quiet period survives restarts.
  final SmartAlertEngine _alerts = SmartAlertEngine();

  /// Key into the Status tab for pull-to-refresh (its state owns the
  /// balance/devices/signal refresh legs).
  final _statusKey = GlobalKey<StatusTabState>();

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
    if (isDesktop) {
      windowManager.addListener(this);
      trayManager.addListener(this);
    }
    _client = ZteClient();
    _restoreSettings();
    _housekeeping = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _runHousekeeping(),
    );
  }

  @override
  void dispose() {
    if (isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    _cooldownTimer?.cancel();
    _housekeeping?.cancel();
    _localApi.stop();
    _balanceFeed.dispose();
    _signalFeed.dispose();
    _poller?.stop();
    _ipCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _restoreSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('gateway_ip') ?? '192.168.0.1';
    final pw = prefs.getString('admin_password') ?? 'admin';
    final lastFired = await SmartAlertStore.loadLastFired();
    if (!mounted) return;
    _alerts.lastFired.addAll(lastFired);
    _applyLocalApi(); // persisted toggle takes effect on launch
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

  /// Archive a raw balance reply for the Settings tab (verbose modem
  /// chatter never surfaces on the primary screen).
  void _logBalanceRaw(String reply) {
    if (reply.trim().isEmpty) return;
    setState(() {
      _balanceRawLog.insert(
        0,
        '${TimeOfDay.now().format(context)}  ${reply.trim()}',
      );
      if (_balanceRawLog.length > 60) _balanceRawLog.removeLast();
    });
  }

  /// Router signal locator: modal dialog on desktop, bottom sheet on
  /// mobile — grounded in RSRP/RSRQ/SINR metric analysis. Width-based
  /// (640px): desktop windows render the glass modal, phones get the
  /// opaque bottom sheet.
  Future<void> _openSignalLocator() async {
    final narrow = MediaQuery.sizeOf(context).width < 640;
    if (narrow) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black54,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        // Wrap-content: the sheet sizes itself to the readout, no
        // fixed 85% box with dead space underneath.
        builder: (_) => SignalLocatorSheet(
          signalFeed: _signalFeed,
          client: _client,
        ),
      );
    } else {
      await showGlassModal<void>(
        context,
        icon: Icons.explore_outlined,
        title: 'Router signal locator',
        subtitle: 'RSRP · RSRQ · SINR placement analysis',
        width: 620,
        body: SignalLocatorBody(
          signalFeed: _signalFeed,
          client: _client,
        ),
      );
    }
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

  /// Latch a firmware rejection once: capability matrix + log, no retries.
  void _markUnsupported(String goformId, String reason) {
    final isNew = capabilities.markUnsupported(goformId, reason);
    if (isNew) {
      _logLine('unsupported: $goformId — $reason (will not retry)');
      if (mounted) setState(() {});
    }
  }

  /// Phase 0 diagnostic export: app version + firmware + status +
  /// capability rejections + recent log. Copies to clipboard so it works
  /// on desktop and mobile without file access.
  Future<void> _exportDiagnostics() async {
    final text = buildDiagnosticText(
      appVersion: '1.0.0+1',
      gatewayIp: _client.gatewayIp,
      firmware: _status,
      status: _status,
      recentLog: _log,
      unsupported: capabilities.unsupported,
    );
    await Clipboard.setData(ClipboardData(text: text));
    _logLine(
      'diagnostic export copied (${text.length} chars, '
      '${capabilities.unsupported.length} unsupported cmds)',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Diagnostics copied to clipboard')),
      );
    }
  }

  void _startPoller() {
    _poller?.stop();
    _poller = ZtePoller(
      client: _client,
      notifications: _notifications,
      onStatus: (s) {
        if (mounted) setState(() => _status = s);
        _smartTick(s);
      },
      onUnreachable: _smartUnreachable,
      onDevices: _deviceTick,
    )..start();
    _applyMonitorSettings();
    _logLine('poller started — minimize to tray to keep polling');
  }

  /// Phase 7: apply Desk/Travel + battery-notification prefs to the
  /// running poller (restarts the timer when the interval changed).
  Future<void> _applyMonitorSettings() async {
    final p = _poller;
    if (p == null) return;
    try {
      final ms = await MonitorSettings.load();
      final want = monitorInterval(ms.mode);
      p.lowBatteryPercent = ms.lowBatteryPercent;
      p.lowBatteryNotify = ms.lowBatteryNotify;
      p.fullBatteryNotify = ms.fullBatteryNotify;
      p.lightMode = ms.mode == MonitorMode.travel;
      if (p.interval != want) {
        p.interval = want;
        if (p.running) {
          p.start(); // re-arm the periodic timer on the new cadence
          _logLine(
            'monitor mode: ${monitorModeLabel(ms.mode)} '
            '(${want.inSeconds}s polls)',
          );
        }
      }
    } catch (_) {}
  }

  /// Fold background station snapshots into device intel (fire-and-
  /// forget; merges are cheap, prefs writes are not awaited by polls).
  Future<void> _deviceTick(List<AttachedDevice> stations) async {
    try {
      final store = await DeviceStore.load();
      final merged = store.merge(stations);
      await merged.store.save();
      for (final e in merged.events.where((e) => !e.joined)) {
        final dev = merged.store.known[e.mac];
        if (dev != null && dev.important) {
          _logLine('important device left: ${e.name}');
          await _notifyNow('MiFi device left', '${e.name} disconnected.');
        }
      }
    } catch (_) {}
  }

  /// Feed one successful poll into the smart-alert engine and raise
  /// whatever fires (fire-and-forget: notification delivery must never
  /// block the poll loop).
  Future<void> _smartTick(Map<String, dynamic> s) async {
    try {
      final settings = await SmartAlertStore.loadSettings();
      final fired = _alerts.tick(
        reachable: true,
        bars: int.tryParse('${s['signalbar'] ?? ''}'),
        networkType: '${s['network_type'] ?? ''}',
        settings: settings,
      );
      await _raiseSmartAlerts(fired);
    } catch (_) {
      // Alert evaluation must never break polling.
    }
  }

  Future<void> _smartUnreachable() async {
    try {
      final settings = await SmartAlertStore.loadSettings();
      final fired = _alerts.tick(reachable: false, settings: settings);
      await _raiseSmartAlerts(fired);
    } catch (_) {}
  }

  Future<void> _raiseSmartAlerts(List<SmartAlert> fired) async {
    if (fired.isEmpty) return;
    await SmartAlertStore.appendHistory(fired);
    await SmartAlertStore.saveLastFired(_alerts.lastFired);
    for (final a in fired) {
      _logLine('smart alert: ${a.title} — ${a.body}');
      await _notifyNow('MiFi ${a.title}', a.body);
    }
  }

  /// Phase 9 housekeeping: fire the scheduled reboot once, then run
  /// the daily diagnostic snapshot when its hour arrives. All
  /// best-effort — a failure is logged, never thrown.
  Future<void> _runHousekeeping() async {
    if (!_connected) return;
    final now = DateTime.now();
    // One-shot reboot: clear BEFORE executing so a crash can't loop it.
    try {
      final rb = await ScheduledReboot.load();
      if (rb.dueAt(now)) {
        await const ScheduledReboot().save();
        _logLine('scheduled reboot firing');
        await _notifyNow('MiFi reboot', 'Scheduled reboot firing now.');
        try {
          await _client.reboot();
          _logLine('reboot sent');
        } catch (e) {
          _logLine('reboot sent (connection dropped as expected: $e)');
        }
        if (mounted) setState(() {});
      }
    } catch (_) {}
    // Daily diagnostic snapshot.
    try {
      final diag = await ScheduledDiag.load();
      if (!diag.dueAt(now)) return;
      final s = await _client.getStatus();
      final t = await _client.getTrafficStats();
      if (!mounted) return;
      setState(() => _status = s);
      _logLine(
        'scheduled diagnostic: signal ${s['signalbar'] ?? '?'}/5 '
        '${s['network_type'] ?? ''} · battery '
        '${s['battery_vol_percent'] ?? '?'}% · month '
        '${t['monthly_rx_bytes'] ?? '?'}B rx',
      );
      await _notifyNow(
        'MiFi diagnostic',
        'Daily snapshot captured — see the log.',
      );
      if (diag.autoSpeedTest) await _scheduledSpeedTest();
      await ScheduledDiag(
        enabled: diag.enabled,
        hour: diag.hour,
        autoSpeedTest: diag.autoSpeedTest,
        lastRunDay: ScheduledDiag.dayKey(now),
      ).save();
    } catch (e) {
      _logLine('scheduled diagnostic failed: $e');
    }
  }

  /// Headless Quick test for the scheduler: requires the first-run
  /// consent AND the explicit auto-test toggle — never a surprise.
  Future<void> _scheduledSpeedTest() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('speed_test_consent') != true) {
        _logLine('scheduled speed test skipped (no data consent)');
        return;
      }
      final runner = SpeedTestRunner();
      try {
        final r = await runner.run((_, _, _) {}, mode: SpeedTestMode.quick);
        if (r.error == null) {
          final history = await SpeedHistory.load();
          await history.added(SpeedRecord.fromResult(r)).save();
          _logLine(
            'scheduled speed test: ${r.latencyMs?.toStringAsFixed(0)} ms · '
            '${r.downloadBps == null ? '—' : (r.downloadBps! * 8 / 1e6).toStringAsFixed(1)} Mbps',
          );
        } else {
          _logLine('scheduled speed test failed: ${r.error}');
        }
      } finally {
        runner.dispose();
      }
    } catch (e) {
      _logLine('scheduled speed test error: $e');
    }
  }

  /// Phase 9: apply the loopback-API toggle immediately.
  Future<void> _applyLocalApi() async {
    try {
      final s = await LocalApiSettings.load();
      if (s.enabled) {
        await _localApi.start(port: s.port, snapshot: () => _status);
        _logLine('local API on http://127.0.0.1:${_localApi.port}/snapshot');
      } else {
        await _localApi.stop();
        _logLine('local API stopped');
      }
    } catch (e) {
      _logLine('local API failed: $e');
    }
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

  /// Status body: read-only + glanceable, wrapped in pull-to-refresh.
  /// Connection + diagnostics live exclusively in Settings — Status
  /// never duplicates them.
  Widget _statusBody() {
    final c = context.zc;
    return RefreshIndicator(
      color: c.accentText,
      backgroundColor: c.surfaceLifted,
      onRefresh: () => _statusKey.currentState?.refreshAll() ?? Future.value(),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 4),
        child: StatusTab(
          key: _statusKey,
          client: _client,
        connected: _connected,
        status: _status,
        log: _logLine,
        notify: _notifyNow,
        onRefreshNow: _refreshNow,
        balanceFeed: _balanceFeed,
        signalFeed: _signalFeed,
        onOpenSignalLocator: _openSignalLocator,
        onBalanceRaw: _logBalanceRaw,
        onJumpTab: (i) => setState(() => _tab = i),
        onUnsupported: _markUnsupported,
        ),
      ),
    );
  }

  /// All five tab bodies, index-aligned with the nav. They live in an
  /// [IndexedStack] so switching tabs never disposes state — scroll
  /// offsets, selections, text fields and loaded data are exactly
  /// where you left them.
  List<Widget> _tabBodies() => [
    _statusBody(),
    SmsTab(client: _client, connected: _connected, log: _logLine),
    UssdTab(
      client: _client,
      connected: _connected,
      log: _logLine,
      onUnsupported: _markUnsupported,
    ),
    InfoTab(client: _client, connected: _connected, log: _logLine),
    SettingsTab(
      client: _client,
      connected: _connected,
      ipCtrl: _ipCtrl,
      passCtrl: _passCtrl,
      busy: _busy,
      cooldownLeft: _cooldownLeft,
      loginMessage: _loginMessage,
      loginOk: _loginOk,
      onLogin: _doLogin,
      onTest: _testConnection,
      onPasswordSubmit: _doLogin,
      logLines: _log,
      onClearLog: () => setState(() => _log.clear()),
      onExportDiagnostics: _exportDiagnostics,
      unsupported: capabilities.unsupported,
      balanceRawLog: _balanceRawLog,
      onClearBalanceLog: () => setState(() => _balanceRawLog.clear()),
      log: _logLine,
      notify: _notifyNow,
      onMonitorChanged: _applyMonitorSettings,
      onApiChanged: _applyLocalApi,
      onUnsupported: _markUnsupported,
    ),
  ];

  @override
  void onWindowClose() async {
    if (!isDesktop) return;
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() async {
    if (!isDesktop) return;
    await windowManager.show();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (!isDesktop) return;
    if (menuItem.key == 'show') {
      await windowManager.show();
    } else if (menuItem.key == 'quit') {
      _poller?.stop();
      await windowManager.setPreventClose(false);
      await windowManager.close();
    }
  }

  // ── Layout: collapsing sliver header + tab body ──
  // TradeMum parity: the header is a SliverAppBar inside a
  // NestedScrollView, so it collapses/scrolls smoothly with the body
  // while each tab keeps its own scrollable. The header carries the
  // brand only — countdown + theme live in their feature cards.
  @override
  Widget build(BuildContext context) {
    _narrow = MediaQuery.sizeOf(context).width < 640;

    // AnnotatedRegion carries the transparent-status-bar style (see
    // [ZSystemUI]): it rebuilds with the theme, so toggling light/dark
    // in Settings flips the status-bar icons with it.
    // No SafeAreas anywhere: content scrolls full-bleed beneath the OS
    // status + system bars (both transparent via edge-to-edge).
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: ZSystemUI.overlay(context),
      // extendBody: the ambient background paints edge-to-edge behind
      // the floating dock — no flat Scaffold strip shows around it in
      // any theme. Tab scrolls carry bottom clearance so last rows
      // never hide under the pill.
      child: Scaffold(
      extendBody: true,
      body: AmbientBackground(
        child: _shell(
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: NestedScrollView(
              physics: const BouncingScrollPhysics(),
              headerSliverBuilder: (ctx, innerScrolled) =>
                  [const ZSliverHeader()],
              body: Padding(
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: _narrow ? 88 : 0,
                ),
                child: IndexedStack(index: _tab, children: _tabBodies()),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: _narrow
          // Floating dock: generous margins on all sides so the bar
          // hovers over the ambient background instead of striping
          // the screen edge. The bar itself is untouched.
          ? Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: BottomNavBar(
                selected: _tab,
                onSelect: (i) => setState(() => _tab = i),
              ),
            )
          : null,
      ),
    );
  }
}

/// Collapsing dashboard header (TradeMum `GlassSliverAppBar` parity):
/// transparent sliver, no pin — it scrolls away with the body and
/// reappears on scroll-up via the nested scroll coordination. Brand
/// only, full width: with the countdown + theme toggle relocated to
/// their feature cards, nothing competes for header space, so the
/// title never truncates. The text is additionally scale-down fitted
/// as a guard on very narrow phones.
class ZSliverHeader extends StatelessWidget {
  const ZSliverHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final narrow = MediaQuery.sizeOf(context).width < 640;
    return SliverAppBar(
      systemOverlayStyle: ZSystemUI.overlay(context),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      floating: false,
      pinned: false,
      automaticallyImplyLeading: false,
      titleSpacing: 0,
      toolbarHeight: 64,
      title: Row(
        mainAxisSize: MainAxisSize.max,
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
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'MiFi Companion',
                    maxLines: 1,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (!narrow)
                  Text(
                    'ZTE MiFi dashboard · battery · signal · data',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
