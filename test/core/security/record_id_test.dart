import 'package:augustyniak_capture/core/security/record_id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

void main() {
  test('accepts the id shapes the app generates and the fixtures use', () {
    expect(isSafeRecordId(const Uuid().v4()), isTrue);
    expect(isSafeRecordId('rec-1'), isTrue);
    expect(isSafeRecordId('a' * 64), isTrue);
  });

  test('refuses anything that is not a single plain path segment', () {
    for (final id in [
      '..',
      'a/b',
      '/abs',
      r'a\b',
      '',
      'a' * 65,
      'a b',
      'a.b',
    ]) {
      expect(isSafeRecordId(id), isFalse, reason: 'id "$id"');
    }
  });
}
