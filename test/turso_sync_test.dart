import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/core/sync/turso_sync_service.dart';

/// The pipeline protocol types every bound parameter, and a NULL column has a
/// type of its own. Getting that wrong is not a per-row problem: the server
/// rejects the **entire** batch with a 400 before executing anything, so one
/// capture with no title stops the whole queue from reaching the cloud.
void main() {
  group('TursoSyncService.encodeArg', () {
    test('a null column is sent as the null type, never as a null string', () {
      // The regression. Sending {'type': 'text', 'value': null} answered
      // "JSON parse error: invalid type: null, expected a string" for the
      // whole request — and pushToTurso reports that as a plain false, with
      // the pull half of syncTwoWay still printing its success line.
      expect(TursoSyncService.encodeArg(null), <String, dynamic>{'type': 'null'});
      expect(
        TursoSyncService.encodeArg(null, integer: true),
        <String, dynamic>{'type': 'null'},
      );
    });

    test('text is passed through as text', () {
      expect(
        TursoSyncService.encodeArg('abc'),
        <String, dynamic>{'type': 'text', 'value': 'abc'},
      );
    });

    test('integers are stringified, as the protocol requires', () {
      expect(
        TursoSyncService.encodeArg(42, integer: true),
        <String, dynamic>{'type': 'integer', 'value': '42'},
      );
    });

    test('an empty string is a value, not a null', () {
      // '' and null mean different things in a column that holds a title.
      expect(
        TursoSyncService.encodeArg(''),
        <String, dynamic>{'type': 'text', 'value': ''},
      );
    });

    test('zero is a value, not a null', () {
      expect(
        TursoSyncService.encodeArg(0, integer: true),
        <String, dynamic>{'type': 'integer', 'value': '0'},
      );
    });
  });
}
