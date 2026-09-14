library;

import 'dart:io' show Platform;

/// Desktop guard (SSOT): window_manager + tray_manager exist only on
/// Windows/Linux/macOS. Every call site must check [isDesktop] first —
/// calling them on Android/iOS crashes boot (MissingPluginException).
bool get isDesktop {
  try {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  } catch (_) {
    return false;
  }
}
