import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../recordings/domain/capture_type.dart';

/// Reads one user-initiated paste. File URLs take priority over image bytes and
/// text because file managers also advertise their selection as text.
class ClipboardCaptureReader {
  const ClipboardCaptureReader({
    MethodChannel channel = const MethodChannel(
      'ai.augustyniak.capture/clipboard',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<({File? file, CaptureType? type, String? mimeType, String? text, bool temporary})>
  read() async {
    try {
      final String? path = await _channel.invokeMethod<String>('getPasteFile');
      if (path != null && path.isNotEmpty) {
        final CaptureType detected = typeForExtension(p.extension(path)) ?? CaptureType.file;
        return (
          file: File(path),
          type: detected == CaptureType.audioRecording
              ? CaptureType.audioUpload
              : detected,
          mimeType: null,
          text: null,
          temporary: false,
        );
      }
      final String? image = await _channel.invokeMethod<String>(
        'getPasteImage',
      );
      if (image != null && image.isNotEmpty) {
        return (
          file: File(image),
          type: CaptureType.image,
          mimeType: 'image/png',
          text: null,
          temporary: true,
        );
      }
    } on MissingPluginException {
      // Mobile and Windows can still paste text through Flutter's clipboard.
    }

    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    return (file: null, type: null, mimeType: null, text: data?.text, temporary: false);
  }
}
