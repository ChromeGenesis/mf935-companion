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
import '../core/log_store.dart';
import '../core/monitor_modes.dart';
import '../core/platform.dart';
import '../core/session_recovery.dart' as recovery;
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
    with WindowListener, TrayListener, WidgetsBindingObserver {
  late final ZteClient _client;
  ZtePoller? _poller;
  // Initialized once in main(); this handle only routes show() calls.
  final _notifications = FlutterLocalNotificationsPlugin();

  final _ipCtrl = TextEditingController(text: '192.168.0.1');
  final _passCtrl = TextEditingController();
  Map<String, dynamic> _status = {};

  /// When [_status] was polled. Drives the stale-data banner: after a
  /// session loss the numbers stay on screen (they are still true, just
  /// old), and this is what says how old.
  DateTime? _statusAt;

  /// Activity log. Lines live in RAM for display and in [_logStore] for
  /// good — a reboot incident is useless if the evidence dies with the
  /// window. Newest first.
  final List<String> _log = [];

  /// Durable log + typed session events (login, session lost, reboot…).
  /// Writes are batched; durability-critical lines flush immediately.
  final LogStore _logStore = LogStore();
  Timer? _logFlush;
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

  /// Background re-login watchdog (reboot recovery — see
  /// [recovery.looksAuthenticated] / [recovery.recoveryProbeDelay]):
  /// armed when the router stops answering or answers without a session,
  /// disarmed the moment it is ours again.
  bool _recoveryArmed = false;
  Timer? _recoveryTimer;
  bool _recovering = false;
  int _recoveryProbes = 0;

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
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    if (isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    _recoveryTimer?.cancel();
    _cooldownTimer?.cancel();
    _housekeeping?.cancel();
    _logFlush?.cancel();
    unawaited(_logStore.flush());
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
    // Restore the persisted log first so anything logged this session
    // lands under what came before it.
    var restored = <String>[];
    try {
      restored = (await _logStore.load())
          .map(formatLogLine)
          .toList(growable: false);
    } catch (_) {}
    if (!mounted) return;
    _alerts.lastFired.addAll(lastFired);
    _applyLocalApi(); // persisted toggle takes effect on launch
    setState(() {
      _log
        ..clear()
        ..addAll(restored);
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
          _statusAt = DateTime.now();
          _loginOk = true;
          _loginMessage = 'Session restored — no login needed.';
        });
        _event(LogKind.login, 'saved session still valid @ ${_client.gatewayIp}');
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
    _record(LogKind.info, line, stamp: true);
  }

  /// Log a typed session event (not just a line): the durable half that
  /// survives a restart and feeds incident reports. [stamp] adds the
  /// clock prefix for the display list.
  void _event(LogKind kind, String line, {bool durable = true}) {
    _record(kind, line, stamp: true, durable: durable);
  }

  void _record(
    LogKind kind,
    String line, {
    required bool stamp,
    bool durable = false,
  }) {
    final at = DateTime.now();
    if (durable) {
      _logStore.append(kind, line, at: at);
      _scheduleLogFlush();
    }
    if (!mounted) return;
    setState(() {
      _log.insert(0, stamp ? formatLogLine(SessionEvent(at: at, kind: kind, message: line)) : line);
      if (_log.length > 200) _log.removeLast();
    });
  }

  /// Batch the prefs write — a single incident logs several lines at
  /// once and each write is a disk hit. Durability-critical lines call
  /// [_flushLogNow] instead.
  void _scheduleLogFlush() {
    _logFlush?.cancel();
    _logFlush = Timer(const Duration(milliseconds: 600), _flushLogNow);
  }

  Future<void> _flushLogNow() async {
    _logFlush?.cancel();
    _logFlush = null;
    try {
      await _logStore.flush();
    } catch (_) {
      // A log that cannot be written is a degraded nicety, never a crash.
    }
  }

  /// Settings → clear log: RAM and storage together, so a cleared log
  /// does not resurrect itself on the next launch.
  Future<void> _clearLog() async {
    try {
      await _logStore.clear();
    } catch (_) {}
    if (mounted) setState(() => _log.clear());
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
    final typed = _ipCtrl.text.trim();
    if (typed.isNotEmpty) _client.gatewayIp = typed;
    final ok = await _login(_passCtrl.text, auto: false);
    if (ok) _stopSessionRecovery('login ok — watchdog stood down');
  }

  /// Background re-login used by the recovery watchdog. Same wire flow as
  /// the Settings button, but it reads the *saved* credentials (so a
  /// half-typed form can't break it), never blanks the login panel, and
  /// reports the outcome instead of only painting it.
  Future<bool> _autoRelogin() async {
    var password = _passCtrl.text;
    var ip = _ipCtrl.text.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      password = prefs.getString('admin_password') ?? password;
      ip = prefs.getString('gateway_ip') ?? ip;
    } catch (_) {
      // Prefs unavailable: fall back to whatever the form holds.
    }
    _client.gatewayIp = ip;
    _logLine('auto-login: reconnecting to $ip…');
    return _login(password, auto: true);
  }

  /// One login attempt ([auto] = fired by the watchdog, not the button).
  Future<bool> _login(String password, {required bool auto}) async {
    if (!mounted) return false;
    if (!auto) {
      setState(() {
        _busy = true;
        _loginMessage = '';
        _loginOk = null;
      });
    }
    try {
      final result = await _client.login(password);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('gateway_ip', _client.gatewayIp);
        await prefs.setString('admin_password', password);
      } catch (_) {
        // Non-fatal: the session itself already succeeded/failed.
      }
      if (!mounted) return result.success;
      setState(() {
        _loginOk = result.success;
        _loginMessage = result.success
            ? (auto
                  ? 'Session restored automatically — reconnected after the '
                      'router came back.'
                  : result.message)
            : '${result.message}${result.raw.isNotEmpty ? '\nRouter said: ${result.raw}' : ''}';
      });
      _logLine(
        result.success
            ? '${auto ? 'AUTO-LOGIN' : 'LOGIN'} ok @ ${_client.gatewayIp}'
            : '${auto ? 'AUTO-LOGIN' : 'LOGIN'} FAILED: ${result.message}',
      );
      // Login outcomes are the durable spine of the log: flushed at once
      // so a crash right after this still leaves the evidence behind.
      _logStore.append(
        auto ? LogKind.recovered : LogKind.login,
        result.success
            ? '${auto ? 'AUTO-LOGIN' : 'LOGIN'} ok @ ${_client.gatewayIp}'
            : '${auto ? 'AUTO-LOGIN' : 'LOGIN'} FAILED: ${result.message}',
      );
      unawaited(_flushLogNow());
      if (result.raw.isNotEmpty && !result.success) {
        _logLine('raw reply: ${result.raw}');
      }
      if (result.success) {
        _cooldownTimer?.cancel();
        _cooldownUntil = null;
        _startPoller();
        return true;
      }
      // Read the real lockout counters (free GET) instead of guessing.
      final (failsLeft, lockSecs) = await _client.getLoginCounters();
      final counterInfo = failsLeft >= 0
          ? ' Attempts left: $failsLeft${lockSecs > 0 ? ', lockout lifts in ${lockSecs}s' : ''}.'
          : '';
      if (!mounted) return false;
      setState(() {
        _loginMessage =
            '${_loginMessage.split('\n').first}$counterInfo'
            '${result.raw.isNotEmpty ? '\nRouter said: ${result.raw}' : ''}';
      });
      _logLine('counters: failsLeft=$failsLeft lockSecs=$lockSecs');
      _startCooldown(lockSecs > 0 ? lockSecs + 5 : 10);
      // Router never answered: keep the watchdog on it (the MiFi may still
      // be booting). A wrong password stays a manual Settings fix so the
      // firmware's attempt budget is never burned by an auto-retry loop.
      if (recovery.shouldKeepWatching(result)) {
        _armSessionRecovery(
          reason: 'router unreachable at login — watching for the link',
        );
      }
      return false;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _loginOk = false;
        _loginMessage = 'Unexpected error: $e';
      });
      _logLine('LOGIN error: $e');
      return false;
    } finally {
      if (!auto && mounted) setState(() => _busy = false);
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
      setState(() {
        _status = s;
        _statusAt = DateTime.now();
      });
      _logLine('status poll ok');
    } catch (e) {
      _logLine('status poll failed: $e');
      if (!mounted) return;
      setState(() => _loginOk = false);
    }
  }

  Future<void> _notifyNow(String title, String body) =>
      showAlert(_notifications, title, body);

  /// Fires one real notification through the full OS path so delivery
  /// can be verified on demand (Settings → Diagnostics → test alert).
  /// The snackbar confirms dispatch; the toast itself confirms the OS
  /// grant + channel. If no toast appears, the OS blocked it — see log.
  void _testAlertNow() {
    _notifyNow('MiFi Companion test', 'If you see this, alerts work.');
    _logLine('test alert dispatched — confirm the OS toast appeared');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Test alert sent — check for the system toast'),
        ),
      );
    }
  }

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
        if (mounted) {
          setState(() {
            _status = s;
            _statusAt = DateTime.now();
          });
        }
        _smartTick(s);
        _watchSession(s);
      },
      onUnreachable: _onPollerUnreachable,
      onDevices: _deviceTick,
    )..start();
    _applyMonitorSettings();
    _logLine('poller started — minimize to tray to keep polling');
  }

  /// Router out of reach for three straight polls: surface the smart-alert
  /// signal and hand over to the watchdog, so the session comes back by
  /// itself when the link does.
  void _onPollerUnreachable() {
    _smartUnreachable();
    _event(
      LogKind.unreachable,
      'router unreachable — watching for the link to return',
    );
    _armSessionRecovery(
      reason: 'router unreachable — watching for the link to return',
    );
  }

  /// A poll that reaches the router but carries none of the fields this
  /// firmware only returns to a logged-in caller: the MiFi rebooted and
  /// took the session cookie with it. Stop pretending everything is fine
  /// and let the watchdog re-authenticate.
  void _watchSession(Map<String, dynamic> s) {
    if (!recovery.looksHollow(s)) return;
    _event(
      LogKind.sessionLost,
      'status poll came back empty — session lost (router rebooted?)',
      durable: true,
    );
    unawaited(_flushLogNow());
    _poller?.stop();
    if (mounted) setState(() => _loginOk = false);
    _armSessionRecovery(
      reason: 'session gone — watching for the MiFi to come back',
    );
  }

  // ── Background re-login watchdog (reboot recovery) ────────────────

  /// Arm the watchdog (idempotent): probe until the router answers, then
  /// reuse the saved credentials to re-open the session. Never touches
  /// the firmware while its lockout counter is running.
  void _armSessionRecovery({String? reason}) {
    if (!mounted || _recoveryArmed) return;
    _recoveryArmed = true;
    _recoveryProbes = 0;
    _logLine(reason ?? 'session watchdog armed — auto re-login when online');
    unawaited(_runRecoveryProbe());
  }

  void _stopSessionRecovery(String reason) {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    if (!_recoveryArmed) return;
    _recoveryArmed = false;
    _recoveryProbes = 0;
    _logLine(reason);
  }

  /// One watchdog pass: is the router back, and if so, does our session
  /// still exist? Re-login only when the answer is "back, but logged out".
  Future<void> _runRecoveryProbe() async {
    if (!mounted || _recovering) return;
    _recovering = true;
    _recoveryProbes++;
    try {
      // Never spend a login attempt while the firmware lockout runs.
      if (_cooldownLeft > 0) return;
      Map<String, dynamic> probe;
      try {
        probe = await _client.getStatus(
          cmds: const ['battery_vol_percent', 'network_type'],
        );
      } catch (_) {
        // Link still down (router booting / WiFi re-associating).
        return;
      }
      if (!mounted) return;
      if (recovery.looksAuthenticated(probe)) {
        // The cookie survived: nothing to re-authenticate.
        setState(() => _loginOk = true);
        _event(
          LogKind.recovered,
          'router back — session still valid, no login needed',
        );
        _stopSessionRecovery('router back — session still valid, no login needed');
        _startPoller();
        await _notifyNow(
          'MiFi reconnected',
          'Router is answering again — monitoring resumed.',
        );
        return;
      }
      _logLine(
        'MiFi answered without a session — auto re-login '
        '(probe $_recoveryProbes)',
      );
      final ok = await _autoRelogin();
      if (ok) {
        _event(LogKind.recovered, 'auto re-login ok — session restored');
        _stopSessionRecovery('auto re-login ok — session restored');
        await _notifyNow(
          'MiFi reconnected',
          'Background auto-login restored the session after the reboot.',
        );
      }
    } finally {
      _recovering = false;
      // Keep watching (with a backing-off cadence) until the session is
      // ours again or the cooldown/watchdog is stood down.
      if (_recoveryArmed && mounted) {
        _recoveryTimer?.cancel();
        _recoveryTimer = Timer(
          recovery.recoveryProbeDelay(_recoveryProbes),
          () => unawaited(_runRecoveryProbe()),
        );
      }
    }
  }

  /// Devices rarely reboot while the app is in the foreground — coming
  /// back from the background is exactly when the link has returned, so
  /// probe immediately rather than waiting for the poller's next strike.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    if (_recoveryArmed) {
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
      unawaited(_runRecoveryProbe());
    } else if (!_connected && (_poller?.running ?? false)) {
      _armSessionRecovery(reason: 'app resumed — checking the router link');
    }
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
        _event(LogKind.reboot, 'scheduled reboot firing');
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
      setState(() {
        _status = s;
        _statusAt = DateTime.now();
      });
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
        statusAt: _statusAt,
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
      onClearLog: _clearLog,
      onExportDiagnostics: _exportDiagnostics,
      onTestAlert: _testAlertNow,
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
