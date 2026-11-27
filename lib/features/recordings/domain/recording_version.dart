import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'recording.dart';

/// The version token of a capture: sha256 of its canonical JSON.
///
/// One function for both sides. The MCP server hands it out and the app checks
/// it before applying an agent's decision, so the two cannot drift: the stored
/// `json_payload` bytes can differ from what the app re-encodes after a
/// restart (key order, unknown keys, padding), the canonical form cannot.
String recordingVersion(Recording r) =>
    sha256.convert(utf8.encode(jsonEncode(r.toJson()))).toString();
