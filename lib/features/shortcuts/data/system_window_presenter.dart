import 'package:window_manager/window_manager.dart';

import '../domain/window_presenter.dart';

/// Desktop implementation via `window_manager`.
///
/// The three calls are all needed and in this order: `show()` on its own leaves
/// a minimised window minimised, and a shown window still sits behind whatever
/// the user was typing in until `focus()` pulls it forward.
class SystemWindowPresenter implements WindowPresenter {
  const SystemWindowPresenter();

  @override
  Future<void> present() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }
}
