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

  group('SyncPathPolicy.sanitizePayload', () {
    test('re-roots the payload copy of the source path', () {
      // `RecordingsRepository.loadAll` prefers `json_payload` over the columns,
      // so sanitising the column alone would leave the attack untouched.
      final Map<String, dynamic> clean = SyncPathPolicy.sanitizePayload(
        <String, dynamic>{
          'id': 'abc',
          'filePath': '/Users/other/recordings/abc.m4a',
          'thumbPath': '/Users/other/recordings/abc.thumb.jpg',
        },
        recordingsDirectory: '/local/recordings',
      )!;

      expect(clean['filePath'], '/local/recordings/abc.m4a');
      expect(clean['thumbPath'], '/local/recordings/abc.thumb.jpg');
    });

    test('drops a poster path that cannot be reduced to a name', () {
      final Map<String, dynamic> clean = SyncPathPolicy.sanitizePayload(
        <String, dynamic>{
          'id': 'abc',
          'filePath': 'abc.m4a',
          'thumbPath': '..',
        },
        recordingsDirectory: '/local/recordings',
      )!;

      expect(clean['thumbPath'], isNull);
    });

    test('refuses the whole payload when the source path is unusable', () {
      // A recording with no name for its source cannot be re-rooted, and a row
      // pointing at a remote absolute path is exactly what this prevents.
      expect(
        SyncPathPolicy.sanitizePayload(
          <String, dynamic>{'id': 'abc', 'filePath': '/'},
          recordingsDirectory: '/local/recordings',
        ),
        isNull,
      );
    });

    test('strips agent artifacts, which name files on the other machine', () {
      // `AgentArtifactViewerModal` hands an artifact path to `open`, so a
      // synced artifact is a remote-controlled argument to the OS opener.
      final Map<String, dynamic> clean = SyncPathPolicy.sanitizePayload(
        <String, dynamic>{
          'id': 'abc',
          'filePath': 'abc.m4a',
          'artifacts': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'x', 'path': '/Applications/Calculator.app'},
          ],
        },
        recordingsDirectory: '/local/recordings',
      )!;

      expect(clean['artifacts'], isEmpty);
    });

    test('leaves everything that is not a path alone', () {
      final Map<String, dynamic> clean = SyncPathPolicy.sanitizePayload(
        <String, dynamic>{
          'id': 'abc',
          'filePath': 'abc.m4a',
          'title': 'Notatka',
          'transcript': 'treść',
          'tags': <String>['a', 'b'],
        },
        recordingsDirectory: '/local/recordings',
      )!;

      expect(clean['title'], 'Notatka');
      expect(clean['transcript'], 'treść');
      expect(clean['tags'], <String>['a', 'b']);
    });
  });

  test('every segment path is re-rooted, not just the first', () {
    final Map<String, dynamic>? clean = SyncPathPolicy.sanitizePayload(
      <String, dynamic>{
        'filePath': '/other/device/recordings/abc.m4a',
        'thumbPath': null,
        'segments': <dynamic>[
          <String, dynamic>{
            'index': 0,
            'filePath': '/other/device/recordings/abc.m4a',
          },
          <String, dynamic>{
            'index': 1,
            'filePath': '/other/device/recordings/abc-1.m4a',
          },
        ],
      },
      recordingsDirectory: '/local/recordings',
    );

    final List<dynamic> segments = clean!['segments'] as List<dynamic>;
    expect(
      (segments[0] as Map<String, dynamic>)['filePath'],
      '/local/recordings/abc.m4a',
    );
    expect(
      (segments[1] as Map<String, dynamic>)['filePath'],
      '/local/recordings/abc-1.m4a',
    );
  });

  test('a segment with an unusable name is dropped, not kept', () {
    final Map<String, dynamic>? clean = SyncPathPolicy.sanitizePayload(
      <String, dynamic>{
        'filePath': '/other/abc.m4a',
        'segments': <dynamic>[
          <String, dynamic>{'index': 0, 'filePath': '/other/abc.m4a'},
          <String, dynamic>{'index': 1, 'filePath': '..'},
        ],
      },
      recordingsDirectory: '/local/recordings',
    );

    expect(clean!['segments'] as List<dynamic>, hasLength(1));
  });
}
