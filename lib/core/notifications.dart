import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Single place that knows how to raise a toast on every desktop target.
/// Main + poller + tabs all go through here (SSOT).
Future<void> showAlert(
  FlutterLocalNotificationsPlugin plugin,
  String title,
  String body,
) {
  const details = NotificationDetails(
    linux: LinuxNotificationDetails(),
    android: AndroidNotificationDetails('zte_status', 'ZTE status'),
    windows: WindowsNotificationDetails(),
  );
  return plugin.show(
    id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    title: title,
    body: body,
    notificationDetails: details,
  );
}
