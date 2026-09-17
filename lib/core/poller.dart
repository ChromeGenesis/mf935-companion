import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
  });

  final ZteClient _client;
  final FlutterLocalNotificationsPlugin _notifications;
  Duration interval;
  int lowBatteryPercent;
  double? lowDataMb;
  void Function(Map<String, dynamic> status)? onStatus;

  /// Fires once per unreachable episode (at the same 3-strike
  /// escalation as the toast) so smart-alert engines can record the
  /// outage window. Recovery is visible via the next [onStatus].
  void Function()? onUnreachable;

  /// Station snapshots for device intelligence, every 10th tick
  /// (~5 min, offset from the SMS-capacity probe to spread load).
  void Function(List<AttachedDevice> stations)? onDevices;

  Timer? _timer;
  int _tickCount = 0;
  int _failStreak = 0;

  bool _lowBatteryNotified = false;
  bool _fullBatteryNotified = false;
  bool _lowDataNotified = false;
  bool _noSignalNotified = false;
  bool _unreachableNotified = false;
  bool _smsFullNotified = false;

  int? _lastUnread;
  double _lastMonthTotalMb = -1;

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
        await _notify('MF935 unreachable',
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
    final rx = double.tryParse('${status['monthly_rx_bytes'] ?? '0'}') ?? 0;
    final tx = double.tryParse('${status['monthly_tx_bytes'] ?? '0'}') ?? 0;
    final usedMb = (rx + tx) / (1024 * 1024);

    // Low battery: only when unplugged.
    if (battery != null && !charging && battery <= lowBatteryPercent) {
      if (!_lowBatteryNotified) {
        _lowBatteryNotified = true;
        await _notify('MF935 battery low',
            'Battery at $battery% and unplugged. Plug in the MiFi.');
      }
    } else {
      _lowBatteryNotified = false;
    }

    // Fully charged: unplug to preserve cell health.
    if (battery != null && charging && battery >= 100) {
      if (!_fullBatteryNotified) {
        _fullBatteryNotified = true;
        await _notify('MF935 battery full',
            'At 100% — unplug to preserve battery health.');
      }
    } else if (battery != null && battery < 100) {
      _fullBatteryNotified = false;
    }

    // Signal lost / restored.
    if (signal != null && signal <= 0) {
      if (!_noSignalNotified) {
        _noSignalNotified = true;
        await _notify(
            'MF935 has no signal', 'Signal bar is 0. Check placement/SIM.');
      }
    } else if (signal != null && signal > 0) {
      if (_noSignalNotified) {
        _noSignalNotified = false;
        await _notify('MF935 back online', 'Signal restored ($signal/5).');
      }
    }

    // New SMS arrivals (unread count climbed since last poll).
    if (unread != null) {
      final prev = _lastUnread;
      if (prev != null && unread > prev) {
        final n = unread - prev;
        await _notify('MF935: $n new SMS',
            unread == 1 ? 'One unread message.' : '$unread unread messages.');
      }
      _lastUnread = unread;
    }

    // Month rollover: carrier counters dropped -> fresh month.
    if (_lastMonthTotalMb >= 0 && usedMb < _lastMonthTotalMb - 1) {
      _lowDataNotified = false; // re-arm the usage alert for the new month
      await _notify('MF935: new billing month',
          'Data counters reset. Usage tracking starts over.');
    }
    _lastMonthTotalMb = usedMb;

    // Monthly data usage vs threshold.
    if (lowDataMb != null) {
      if (usedMb >= lowDataMb! && !_lowDataNotified) {
        _lowDataNotified = true;
        await _notify('MF935 data usage high',
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

    // Inbox nearly full: extra GET, but only every 10th tick (~5 min).
    if (_tickCount % 10 == 0) {
      try {
        final cap = await _client.getSmsCapacity();
        final total =
            int.tryParse('${cap['sms_nv_total'] ?? ''}') ?? 0;
        final used =
            int.tryParse('${cap['sms_nv_rev_total'] ?? ''}') ?? 0;
        if (total > 0 && used >= total - 5) {
          if (!_smsFullNotified) {
            _smsFullNotified = true;
            await _notify('MF935 inbox almost full',
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

  Future<void> _notify(String title, String body) =>
      showAlert(_notifications, title, body);
}
