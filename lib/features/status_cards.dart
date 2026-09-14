library;

/// Status-tab presentation barrel (SSOT): hero, balance and
/// device-management cards.
///
/// The former 1150-line `status_tab.dart` god file is now state
/// (`status_tab.dart`) plus three cohesive presentation modules; this
/// file only re-exports them so existing imports keep working.
/// Prefer importing the specific module in new code.
export 'status_balance.dart';
export 'status_devices.dart';
export 'status_hero.dart';
