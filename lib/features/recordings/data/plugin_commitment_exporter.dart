import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../domain/commitment.dart';
import '../domain/commitment_list.dart';
import '../domain/recording.dart';

/// Hands one commitment to the user's own calendar as an `.ics` file (#251):
/// the share sheet where there is a real one, so "Add to Calendar" is one tap
/// away, and a save dialog on Linux and Windows, where `share_plus` has none.
///
/// The only place either plugin is touched for this; the file's contents come
/// from [commitmentToIcs], which is where the tests are. Errors propagate to
/// the caller, which logs them — an export never touches the capture.
Future<void> exportCommitmentWithPlugins(
  Recording recording,
  Commitment commitment,
) async {
  final String ics = commitmentToIcs(
    commitment,
    recordingId: recording.id,
    stamp: DateTime.now(),
    captureTitle: recording.title,
  );
  final String fileName = commitmentFileName(commitment);
  final Uint8List bytes = Uint8List.fromList(utf8.encode(ics));

  if (Platform.isLinux || Platform.isWindows) {
    final String? chosen = await FilePicker.saveFile(
      dialogTitle: 'Save commitment',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const <String>['ics'],
    );
    if (chosen != null) await File(chosen).writeAsBytes(bytes, flush: true);
    return;
  }

  final Directory staging = await Directory.systemTemp.createTemp('commitment');
  final File file = File(p.join(staging.path, fileName));
  await file.writeAsBytes(bytes, flush: true);
  await SharePlus.instance.share(
    ShareParams(
      files: <XFile>[XFile(file.path, mimeType: 'text/calendar')],
      subject: commitment.text,
    ),
  );
}

/// A file name built from the commitment's own words, reduced to characters
/// every filesystem accepts.
String commitmentFileName(Commitment commitment) {
  final String slug = commitment.key
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final String head = slug.length > 40 ? slug.substring(0, 40) : slug;
  return '${head.isEmpty ? 'commitment' : head}.ics';
}
