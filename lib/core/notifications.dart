import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Monotonic id: timestamp-seconds collide when two alerts fire in the
/// same second and the second silently replaces the first.
int _nextId = 1;

/// Dedup window: an alert identical (title + body) to the immediately
/// previous one is dropped when it fires inside this window. Kills
/// flap-spam like repeated "Placement degraded: 5/5 → 3/5" while still
/// letting a genuine re-occurrence through after the window lapses.
const notificationDedupWindow = Duration(minutes: 10);

String? _lastTitle;
String? _lastBody;
DateTime? _lastAt;

/// Pure + tested: true when this alert duplicates the previous one
/// inside [window]. Non-consecutive repeats (anything different fired
/// in between) always pass — only back-to-back spam is cut.
bool isDuplicateAlert({
  required String? lastTitle,
  required String? lastBody,
  required DateTime? lastAt,
  required String title,
  required String body,
  required DateTime now,
  Duration window = notificationDedupWindow,
}) {
  if (lastTitle == null || lastBody == null || lastAt == null) return false;
  if (lastTitle != title || lastBody != body) return false;
  final gap = now.difference(lastAt);
  if (gap.isNegative) return false; // clock skew: fail open, send it
  return gap <= window;
}

/// Test seam: clear dedup memory between cases.
void resetNotificationDedup() {
  _lastTitle = null;
  _lastBody = null;
  _lastAt = null;
}

/// OTP / verification code inside free text: 4–8 digits mentioned
/// alongside code words. The digit run must not touch `*` or `#`, so a
/// USSD code like *939*77*5# never matches. Null when there is no code
/// to copy.
String? extractOtp(String text) {
  if (!RegExp(
    r'otp|one[\s-]?time|verification|verify|passcode|confirm|\bcode\b|\bpin\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return null;
  }
  final m = RegExp(r'(?<![\d*#])\d{4,8}(?![\d*#])').firstMatch(text);
  return m?.group(0);
}

/// Copy-code action id + payload shape (`otp:<code>`).
const otpCopyActionId = 'copy_otp';

String otpPayload(String code) => 'otp:$code';

/// Handles notification taps when the app is alive. A tap on the copy
/// action drops just the code on the clipboard (the full message stays
/// in the SMS tab); a body tap does nothing — opening the app is the
/// platform default. Never throws: a failed copy must not crash boot.
Future<void> notificationResponseHandler(NotificationResponse r) async {
  try {
    if (r.actionId == otpCopyActionId &&
        (r.payload ?? '').startsWith('otp:')) {
      await Clipboard.setData(
        ClipboardData(text: r.payload!.substring('otp:'.length)),
      );
    }
  } catch (_) {}
}

/// Single place that knows how to raise a toast on every desktop target.
/// Main + poller + tabs all go through here (SSOT).
///
/// [otpCode] adds a "Copy code" action (Android) so a verification code
/// can be lifted straight from the notification shade. The payload
/// carries the code; [notificationResponseHandler] does the copying.
Future<void> showAlert(
  FlutterLocalNotificationsPlugin plugin,
  String title,
  String body, {
  String? otpCode,
}) async {
  final now = DateTime.now();
  if (isDuplicateAlert(
    lastTitle: _lastTitle,
    lastBody: _lastBody,
    lastAt: _lastAt,
    title: title,
    body: body,
    now: now,
  )) {
    return;
  }
  // Latch before show so concurrent duplicates collapse onto one toast.
  _lastTitle = title;
  _lastBody = body;
  _lastAt = now;
  final details = NotificationDetails(
    linux: const LinuxNotificationDetails(),
    android: AndroidNotificationDetails(
      'zte_status',
      'ZTE status',
      channelDescription: 'MiFi Companion modem alerts',
      importance: Importance.high,
      priority: Priority.high,
      actions: otpCode == null
          ? null
          : const [
              AndroidNotificationAction(
                otpCopyActionId,
                'Copy code',
                showsUserInterface: false,
                cancelNotification: false,
              ),
            ],
    ),
    windows: const WindowsNotificationDetails(),
  );
  return plugin.show(
    id: _nextId++,
    title: title,
    body: body,
    notificationDetails: details,
    payload: otpCode == null ? null : otpPayload(otpCode),
  );
}

/// Ask the OS for notification permission. Android 13+ requires an
/// explicit runtime grant — declared-in-manifest alone means every
/// show() is silently dropped, which is exactly the "never asks"
/// symptom. No-op (true) where no runtime grant exists. Never throws:
/// permission must not break boot.
Future<bool> requestNotificationPermission(
  FlutterLocalNotificationsPlugin plugin,
) async {
  try {
    final android = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin
    >();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    return true;
  } catch (_) {
    return false;
  }
}
