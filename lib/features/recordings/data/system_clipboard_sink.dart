import 'package:flutter/services.dart';

import '../domain/clipboard_sink.dart';

/// Real clipboard, wired by the `RecordingsPage` shell. Kept out of `domain/`
/// so the domain layer stays free of platform channels and stays testable
/// without a Flutter binding.
class SystemClipboardSink implements ClipboardSink {
  const SystemClipboardSink();

  @override
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));
}
