import 'dart:convert';

import 'package:augustyniak_capture/features/mcp/domain/capture_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// The decoded JSON body of a successful tool result; fails the test when the
/// result is an `isError`.
Object? body(Map<String, dynamic> result) {
  expect(result['isError'], isNull, reason: 'tool failed: $result');
  final String text =
      ((result['content'] as List).single as Map<String, dynamic>)['text']
          as String;
  return jsonDecode(text);
}

Future<Object?> callBody(
  CaptureTools tools,
  String name,
  Map<String, dynamic> args,
) async => body(await tools.call(name, args));
