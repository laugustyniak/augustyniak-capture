import 'package:augustyniak_capture/core/sync/sync_path_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// A path that arrived over the network names a file on **somebody else's**
/// machine, and this app deletes (`deleteArtifacts`), opens (`openSource`) and
/// copies (the vault attachment) whatever a row points at. So a synced row may
/// contribute a file *name*, never a location: the name is re-rooted under the
/// local recordings directory, and anything that cannot be reduced to a plain
/// name is refused outright.
void main() {
  group('SyncPathPolicy.localFileName', () {
    test('keeps the file name and discards the remote location', () {
      expect(
        SyncPathPolicy.localFileName('/Users/other/Documents/recordings/a.m4a'),
        'a.m4a',
      );
    });

    test('splits a Windows path too — the sender chose its own platform', () {
      expect(
        SyncPathPolicy.localFileName(r'C:\Users\other\recordings\a.m4a'),
        'a.m4a',
      );
    });

    test('a traversal attempt keeps only its last segment', () {
      // The row can name `id_rsa`; it cannot say where to look for it.
      expect(SyncPathPolicy.localFileName('../../.ssh/id_rsa'), 'id_rsa');
      expect(SyncPathPolicy.localFileName('/etc/passwd'), 'passwd');
    });

    test('a path with no file name at the end is refused', () {
      expect(SyncPathPolicy.localFileName('..'), isNull);
      expect(SyncPathPolicy.localFileName('.'), isNull);
      expect(SyncPathPolicy.localFileName('/tmp/'), isNull);
      expect(SyncPathPolicy.localFileName(''), isNull);
      expect(SyncPathPolicy.localFileName(null), isNull);
    });

    test('a NUL byte is refused rather than truncated at', () {
      // dart:io truncates at NUL on some platforms, so `a.m4a\u0000/etc/passwd`
      // must never become a name this app then joins onto a real directory.
      expect(SyncPathPolicy.localFileName('a.m4a\u0000.png'), isNull);
    });

    test('a non-string column value is refused', () {
      expect(SyncPathPolicy.localFileName(42), isNull);
    });
  });
}
