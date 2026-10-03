library;

/// Session-recovery policy (SSOT): pure decisions for the dashboard's
/// background re-login watchdog.
///
/// The MiFi's web session dies whenever the router reboots, but the app
/// keeps its cookie and every call afterwards fails in a *different* way
/// than a real disconnection:
///
///  - link down (device rebooting / WiFi re-associating): the HTTP call
///    itself throws — [ZteClient] surfaces that as `reachable: false`.
///  - link back up, session gone: the goform API answers `200` with an
///    empty body (or a lone error code), so a poll "succeeds" with none
///    of the fields this firmware only returns to a logged-in caller.
///
/// Those hollow answers are what used to leave the app stuck until the
/// user re-typed the password in Settings. [looksAuthenticated] gives the
/// watchdog one honest test for both cases, and [recoveryProbeDelay]
/// keeps the retry cadence polite: the firmware locks out after a few
/// rapid LOGIN attempts, so the watchdog must never hammer a booting
/// router.
import 'log_store.dart';
import 'models.dart';

/// True when a status reply carries any of the fields this firmware only
/// returns to an authenticated session. An empty map (or a map holding
/// nothing but a `result` code) is a logged-out / still-booting router.
bool looksAuthenticated(Map<String, dynamic> status) {
  for (final key in const [
    'battery_vol_percent',
    'network_type',
    'signalbar',
    'wa_inner_version',
  ]) {
    if ('${status[key] ?? ''}'.isNotEmpty) return true;
  }
  return false;
}

/// Inverse of [looksAuthenticated] — the signature of a rebooted router.
bool looksHollow(Map<String, dynamic> status) => !looksAuthenticated(status);

/// Should the watchdog keep watching after a failed login attempt?
/// Only connectivity failures are worth retrying: a wrong password would
/// just burn the firmware's attempt budget (5 tries, then a 300s lock)
/// and must stay a manual Settings fix.
bool shouldKeepWatching(LoginResult result) =>
    !result.success && !result.reachable;

/// Delay before probe number [probes] (1-based) while the session is
/// down. The first few probes are quick — a rebooting MF935 is usually
/// back within a minute — then the cadence settles to a steady tempo so
/// a router that stays off (travel, flat battery) is only touched every
/// 15s.
Duration recoveryProbeDelay(int probes) {
  if (probes <= 6) return const Duration(seconds: 5);
  return const Duration(seconds: 15);
}

// ── Stale-data honesty ─────────────────────────────────────────────

/// How much the numbers currently on screen can be trusted.
enum DataTrust {
  /// Polled within the current session: current.
  live,

  /// The session is gone but the last good poll is still on screen.
  /// True numbers, unknown age — must be labelled, never presented as
  /// if they were just measured.
  cached,

  /// Nothing has ever been read from the device.
  unknown,
}

/// Trust level of the status snapshot on screen. Pure + tested.
///
/// [lastAt] is when the displayed snapshot was polled (null = never),
/// [sessionLive] whether we currently hold a working session. A live
/// session with an old snapshot still counts as live — the poller owns
/// the cadence — while a dead session always downgrades whatever is left
/// on screen.
DataTrust trustOf({
  required bool sessionLive,
  DateTime? lastAt,
  DateTime? now,
}) {
  if (lastAt == null) return DataTrust.unknown;
  return sessionLive ? DataTrust.live : DataTrust.cached;
}

/// Banner text for the dashboard above stale values, or '' when there is
/// nothing to warn about. Never guesses: the age always comes from
/// [lastAt], so a snapshot from three hours ago says three hours ago.
String staleBannerText({
  required bool sessionLive,
  DateTime? lastAt,
  DateTime? now,
}) {
  final trust = trustOf(sessionLive: sessionLive, lastAt: lastAt, now: now);
  if (trust != DataTrust.cached) return '';
  final n = now ?? DateTime.now();
  final age = n.difference(lastAt!);
  if (age.isNegative || age.inSeconds < 60) {
    return 'Session lost — showing the last reading from ${formatClock(lastAt)}.';
  }
  if (age.inHours < 1) {
    return 'Session lost — showing the last reading from '
        '${formatClock(lastAt)} (${age.inMinutes} min ago).';
  }
  return 'Session lost — the reading below is from '
      '${formatClock(lastAt)}, ${age.inHours}h ago. Not live.';
}
