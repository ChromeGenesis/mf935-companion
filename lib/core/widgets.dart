library;

/// Widget barrel (SSOT): core primitives, dialogs, countdown widgets.
///
/// The former 955-line god file is now three cohesive modules; this file
/// only re-exports them so every existing `import 'widgets.dart'`
/// keeps working unchanged. Prefer importing the specific module in new
/// code (`ui_kit.dart`, `dialogs.dart`, `expiry_widgets.dart`).
export 'dialogs.dart';
export 'expiry_widgets.dart';
export 'ui_kit.dart';
