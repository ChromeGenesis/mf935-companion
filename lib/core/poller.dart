import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'monitor_modes.dart';
import 'notifications.dart';
import 'zte_client.dart';

/// Periodic poller: one status GET per [interval], native toasts for the
/// things the stock site never tells you about — new SMS arrivals, full
/// battery, inbox nearly full, signal loss/recovery, month rollover,
/// and the MiFi dropping off the network.
///
/// Latching: every alert fires once per episode and re-arms when the
/// condition clears, so the tray never spams.
class ZtePoller {
  ZtePoller({
    required this._client,
    required this._notifications,
    this.interval = const Duration(seconds: 30),
    this.lowBatteryPercent = 20,
    this.lowDataMb,
    this.onStatus,
    this.onUnreachable,
    this.onDevices,
    this.onUsage,
  });

  final ZteClient _client;
  final FlutterLocalNotificationsPlugin _notifications;
  Duration interval;
  int lowBatteryPercent;
  double? lowDataMb;
  void Function(Map<String, dynamic> status)? onStatus;

  /// Phase 7 monitors: notification toggles + travel light mode
  /// (skips the inbox-capacity probe; the interval itself is owned by
  /// the dashboard via [interval]).
  bool lowBatteryNotify = true;
  bool fullBatteryNotify = true;
  bool lightMode = false;

  /// Fires once per unreachable episode (at the same 3-strike
  /// escalation as the toast) so smart-alert engines can record the
  /// outage window. Recovery is visible via the next [onStatus].
  void Function()? onUnreachable;

  /// Station snapshots for device intelligence, every 10th tick
  /// (~5 min, offset from the SMS-capacity probe to spread load).
  void Function(List<AttachedDevice> stations)? onDevices;

  /// Monthly-counter sample for the usage ledger, fired only when the
  /// firmware actually reported the counters (an unparseable pair
  /// sampled as 0 would read as a rollover and archive a healthy
  /// cycle — never invent the zero).
  void Function(double totalMb, double rxMb, double txMb)? onUsage;

  Timer? _timer;
  int _tickCount = 0;
  int _failStreak = 0;

  bool _lowBatteryNotified = false;
  bool _fullBatteryNotified = false;
  bool _prolongedFullNotified = false;
  DateTime? _fullSince;
  bool _lowDataNotified = false;
  bool _noSignalNotified = false;
  bool _unreachableNotified = false;
  bool _smsFullNotified = false;

  int? _lastUnread;
  double _lastMonthTotalMb = -1;

  /// Last persisted battery reading: the health series only grows when
  /// something actually changed — rewriting identical samples every
  /// 30 s teaches nothing and burns prefs writes.
  int? _lastBatteryPercent;
  bool? _lastBatteryCharging;

  bool get running => _timer?.isActive ?? false;

  void start() {
    stop();
    _tick(); // immediate first poll
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    _tickCount++;
    late final Map<String, dynamic> status;
    try {
      status = await _client.getStatus();
    } catch (_) {
      // Swallow poll errors; escalate only on a sustained outage.
      _failStreak++;
      if (_failStreak >= 3 && !_unreachableNotified) {
        _unreachableNotified = true;
        onUnreachable?.call();
        await _notify('MiFi unreachable',
            'No answer for ${_failStreak * interval.inSeconds}s. Check WiFi / power.');
      }
      return;
    }
    _failStreak = 0;
    _unreachableNotified = false;
    onStatus?.call(status);

    final battery = int.tryParse('${status['battery_vol_percent'] ?? ''}');
    final charging = '${status['battery_charging'] ?? ''}' == '1';
    final signal = int.tryParse('${status['signalbar'] ?? ''}');
    final unread = int.tryParse('${status['sms_unread_num'] ?? ''}');
    final rx = ZteClient.bytesToMb(status['monthly_rx_bytes'] ?? '0');
    final tx = ZteClient.bytesToMb(status['monthly_tx_bytes'] ?? '0');
    final usedMb = rx + tx;

    // Usage ledger feed — parse-guarded (see [onUsage]).
    final rxRaw = '${status['monthly_rx_bytes'] ?? ''}';
    final txRaw = '${status['monthly_tx_bytes'] ?? ''}';
    if (rxRaw.isNotEmpty || txRaw.isNotEmpty) {
      final rxMb = ZteClient.bytesToMb(rxRaw);
      final txMb = ZteClient.bytesToMb(txRaw);
      onUsage?.call(rxMb + txMb, rxMb, txMb);
    }

    // Battery sample for the health/drain readout (best-effort).
    // Unchanged readings are skipped: same percent, same plug state.
    if (battery != null &&
        (battery != _lastBatteryPercent ||
            charging != _lastBatteryCharging)) {
      _lastBatteryPercent = battery;
      _lastBatteryCharging = charging;
      try {
        final prefs = await SharedPreferences.getInstance();
        final cur = BatterySamples.decode(
          prefs.getString(BatterySamples.key),
        );
        final next = BatterySamples.added(
          cur,
          BatterySample(
            at: DateTime.now(),
            percent: battery,
            charging: charging,
          ),
        );
        await prefs.setString(
          BatterySamples.key,
          jsonEncode(next.map((s) => s.toJson()).toList()),
        );
      } catch (_) {}
    }

    // Low battery: only when unplugged.
    if (lowBatteryNotify &&
        battery != null &&
        !charging &&
        battery <= lowBatteryPercent) {
      if (!_lowBatteryNotified) {
        _lowBatteryNotified = true;
        await _notify('Battery low',
            'Battery at $battery% and unplugged. Plug in the MiFi.');
      }
    } else {
      _lowBatteryNotified = false;
    }

    // Fully charged: unplug to preserve cell health. Prolonged
    // 100%-while-plugged (>30 min) escalates once per episode.
    if (battery != null && charging && battery >= 100) {
      _fullSince ??= DateTime.now();
      if (fullBatteryNotify && !_fullBatteryNotified) {
        _fullBatteryNotified = true;
        await _notify('Battery full',
            'At 100% — unplug to preserve battery health.');
      }
      final heldMins = DateTime.now().difference(_fullSince!).inMinutes;
      if (fullBatteryNotify &&
          heldMins >= 30 &&
          !_prolongedFullNotified) {
        _prolongedFullNotified = true;
        await _notify('Held at 100%',
            'Plugged at full charge for ${heldMins}m — unplug; '
            'lithium cells age fastest at 100%.');
      }
    } else if (battery != null && battery < 100) {
      _fullBatteryNotified = false;
      _prolongedFullNotified = false;
      _fullSince = null;
    } else if (!charging) {
      _prolongedFullNotified = false;
      _fullSince = null;
    }

    // Signal lost / restored.
    if (signal != null && signal <= 0) {
      if (!_noSignalNotified) {
        _noSignalNotified = true;
        await _notify(
            'No signal', 'Signal bar is 0. Check placement/SIM.');
      }
    } else if (signal != null && signal > 0) {
      if (_noSignalNotified) {
        _noSignalNotified = false;
        await _notify('Back online', 'Signal restored ($signal/5).');
      }
    }

    // New SMS arrivals (unread count climbed since last poll).
    if (unread != null) {
      final prev = _lastUnread;
      if (prev != null && unread > prev) {
        await _notifyNewSms();
      }
      _lastUnread = unread;
    }

    // Month rollover: carrier counters dropped -> fresh month.
    if (_lastMonthTotalMb >= 0 && usedMb < _lastMonthTotalMb - 1) {
      _lowDataNotified = false; // re-arm the usage alert for the new month
      await _notify('New billing month',
          'Data counters reset. Usage tracking starts over.');
    }
    _lastMonthTotalMb = usedMb;

    // Monthly data usage vs threshold.
    if (lowDataMb != null) {
      if (usedMb >= lowDataMb! && !_lowDataNotified) {
        _lowDataNotified = true;
        await _notify('Data usage high',
            'Used ${usedMb.toStringAsFixed(0)} MB this month.');
      } else if (usedMb < lowDataMb!) {
        _lowDataNotified = false;
      }
    }

    // Station snapshot for device intel: every 10th tick (~5 min),
    // offset from the SMS-capacity probe to spread firmware load.
    if (_tickCount % 10 == 5) {
      try {
        final stations = await _client.getConnectedDevices();
        onDevices?.call(stations);
      } catch (_) {
        // Best-effort; next window retries.
      }
    }

    // Inbox nearly full: extra GET, but only every 10th tick (~5 min)
    // and never in travel light mode (radio stays quiet on the road).
    if (!lightMode && _tickCount % 10 == 0) {
      try {
        final cap = await _client.getSmsCapacity();
        final total =
            int.tryParse('${cap['sms_nv_total'] ?? ''}') ?? 0;
        final used =
            int.tryParse('${cap['sms_nv_rev_total'] ?? ''}') ?? 0;
        if (total > 0 && used >= total - 5) {
          if (!_smsFullNotified) {
            _smsFullNotified = true;
            await _notify('Inbox almost full',
                'Device store holds $used/$total SMS. Delete some or new mail bounces.');
          }
        } else {
          _smsFullNotified = false;
        }
      } catch (_) {
        // Capacity probe is best-effort; next window retries.
      }
    }
  }

  Future<void> _notify(String title, String body, {String? otpCode}) =>
      showAlert(_notifications, title, body, otpCode: otpCode);

  /// SMS ids already pushed as notifications (persists, capped): the
  /// same message is never announced twice, across polls or restarts.
  static const _notifiedSmsKey = 'sms_notified_ids';
  static const _maxNotifiedSms = 60;

  /// New arrivals, newest first, excluding everything already announced.
  /// Pure so the selection rule is testable without a modem.
  static List<SmsMessage> freshSms(
    List<SmsMessage> inbox,
    Set<String> notifiedIds,
  ) => inbox
      .where((m) => m.isNew && m.id.isNotEmpty && !notifiedIds.contains(m.id))
      .toList();

  /// Unread count climbed: fetch the inbox and announce each genuinely
  /// new message with its own body (sender as title) instead of a bare
  /// counter. OTPs get a copy action in the shade. Falls back to a
  /// plain counter note when the fetch fails.
  Future<void> _notifyNewSms() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen =
          (prefs.getStringList(_notifiedSmsKey) ?? const []).toSet();
      final inbox = await _client.listSms(perPage: 20);
      final fresh = freshSms(inbox, seen);
      if (fresh.isEmpty) {
        await _notify('New SMS', 'You have unread messages.');
        return;
      }
      for (final m in fresh.take(3)) {
        final body = m.content.trim();
        final shown = body.length > 140 ? '${body.substring(0, 140)}…' : body;
        await _notify(
          m.number.isEmpty ? 'New SMS' : m.number,
          shown.isEmpty ? 'New message received.' : shown,
          otpCode: body.isEmpty ? null : extractOtp(body),
        );
      }
      final updated = {
        for (final m in inbox)
          if (m.id.isNotEmpty) m.id,
        ...seen,
      }.take(_maxNotifiedSms).toList();
      await prefs.setStringList(_notifiedSmsKey, updated);
    } catch (_) {
      await _notify('New SMS', 'You have unread messages.');
    }
  }
}
