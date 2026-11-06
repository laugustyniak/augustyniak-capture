import 'dart:convert';

import 'package:augustyniak_capture/features/enrichment/data/http_chat_enrichment_service.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_prompt.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_result.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/commitment.dart';
import 'package:augustyniak_capture/features/recordings/domain/commitment_list.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Recording _row({List<Commitment>? commitments, DateTime? createdAt}) =>
    Recording(
      id: 'r1',
      filePath: '/tmp/r1.txt',
      createdAt: createdAt ?? DateTime(2026, 11, 4, 9, 30),
      durationMs: 0,
      status: RecordingStatus.completed,
      type: CaptureType.text,
      transcript: 'I will send the offer by Friday',
      commitments: commitments,
    );

String _body(Map<String, dynamic> content) => jsonEncode(<String, dynamic>{
  'choices': <dynamic>[
    <String, dynamic>{
      'message': <String, dynamic>{'content': jsonEncode(content)},
    },
  ],
});

void main() {
  // Wednesday. Every relative phrase below is resolved against this, never
  // against the moment the test (or the enrichment) runs.
  final DateTime anchor = DateTime(2026, 11, 4, 9, 30);

  group('Recording.commitments persistence', () {
    test('absent stays absent and the key stays out of the JSON', () {
      final Map<String, dynamic> json = _row().toJson();
      expect(json.containsKey('commitments'), isFalse);
      expect(Recording.fromJson(json).commitments, isNull);
    });

    test('legacy JSON without the key reads as never extracted', () {
      final Map<String, dynamic> legacy = _row().toJson()
        ..remove('commitments');
      expect(Recording.fromJson(legacy).commitments, isNull);
    });

    test('an empty list means looked and found none, and survives', () {
      final Recording back = Recording.fromJson(
        jsonDecode(jsonEncode(_row(commitments: <Commitment>[]).toJson()))
            as Map<String, dynamic>,
      );
      expect(back.commitments, isNotNull);
      expect(back.commitments, isEmpty);
    });

    test('round-trips text, due, who and state', () {
      final Recording original = _row(
        commitments: <Commitment>[
          Commitment(
            text: 'Send the offer',
            due: DateTime(2026, 11, 6),
            who: 'Anna',
          ),
          const Commitment(text: 'Call the bank', state: CommitmentState.done),
          const Commitment(
            text: 'Book flights',
            state: CommitmentState.dismissed,
          ),
        ],
      );
      final Recording back = Recording.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      final List<Commitment> list = back.commitments!;
      expect(list, hasLength(3));
      expect(list[0].text, 'Send the offer');
      expect(list[0].due, DateTime(2026, 11, 6));
      expect(list[0].who, 'Anna');
      expect(list[0].state, CommitmentState.open);
      expect(list[1].due, isNull);
      expect(list[1].who, isNull);
      expect(list[1].state, CommitmentState.done);
      expect(list[2].state, CommitmentState.dismissed);
    });

    test('an unreadable entry is dropped alone, an unknown state is open', () {
      final Map<String, dynamic> json = _row().toJson()
        ..['commitments'] = <dynamic>[
          42,
          <String, dynamic>{'text': '   '},
          <String, dynamic>{'text': 'Keep me', 'due': 'not a date'},
          <String, dynamic>{'text': 'Future', 'state': 'snoozed'},
        ];
      final List<Commitment> list = Recording.fromJson(json).commitments!;
      expect(list.map((Commitment c) => c.text), <String>['Keep me', 'Future']);
      expect(list[0].due, isNull);
      expect(list[1].state, CommitmentState.open);
    });

    test('a non-list value degrades to never extracted', () {
      final Map<String, dynamic> json = _row().toJson()
        ..['commitments'] = 'oops';
      expect(Recording.fromJson(json).commitments, isNull);
    });

    test('copyWith keeps and replaces commitments', () {
      final Recording withOne = _row(
        commitments: const <Commitment>[Commitment(text: 'A')],
      );
      expect(withOne.copyWith(title: 'x').commitments, hasLength(1));
      expect(
        withOne.copyWith(commitments: <Commitment>[]).commitments,
        isEmpty,
      );
    });

    test('commitments ride the sync payload and come back', () {
      final Recording original = _row(
        commitments: <Commitment>[
          Commitment(
            text: 'Send the offer',
            due: DateTime(2026, 11, 6),
            state: CommitmentState.done,
          ),
        ],
      );
      final Recording back = SyncRowCodec.recordingFromRow(
        SyncRowCodec.recording(original),
      )!;
      expect(back.commitments!.single.text, 'Send the offer');
      expect(back.commitments!.single.state, CommitmentState.done);
      expect(back.commitments!.single.due, DateTime(2026, 11, 6));

      final Map<String, Object?> plain = SyncRowCodec.recording(_row());
      expect(
        (plain['payload']! as Map<String, Object?>).containsKey('commitments'),
        isFalse,
      );
      expect(SyncRowCodec.recordingFromRow(plain)!.commitments, isNull);
    });
  });

  group('resolveCommitmentDue against the capture time', () {
    DateTime? due(String? phrase) => resolveCommitmentDue(phrase, anchor);

    test('weekday names land on the next such day after the capture', () {
      expect(due('Friday'), DateTime(2026, 11, 6));
      expect(due('by friday'), DateTime(2026, 11, 6));
      expect(due('monday'), DateTime(2026, 11, 9));
      // Said on a Wednesday, a bare "Wednesday" means next week's.
      expect(due('wednesday'), DateTime(2026, 11, 11));
      expect(due('this wednesday'), DateTime(2026, 11, 4));
      expect(due('next friday'), DateTime(2026, 11, 13));
    });

    test('relative day and week phrases', () {
      expect(due('today'), DateTime(2026, 11, 4));
      expect(due('tonight'), DateTime(2026, 11, 4));
      expect(due('tomorrow'), DateTime(2026, 11, 5));
      expect(due('day after tomorrow'), DateTime(2026, 11, 6));
      expect(due('in 3 days'), DateTime(2026, 11, 7));
      expect(due('in two weeks'), DateTime(2026, 11, 18));
      expect(due('next week'), DateTime(2026, 11, 9));
      expect(due('end of week'), DateTime(2026, 11, 6));
      expect(due('end of the month'), DateTime(2026, 11, 30));
      expect(due('next month'), DateTime(2026, 12, 1));
    });

    test('an ISO date is taken as written', () {
      expect(due('2026-12-24'), DateTime(2026, 12, 24));
      expect(due('2026-12-24T10:00:00Z'), DateTime(2026, 12, 24));
    });

    test('nothing usable is no due date, never a guess', () {
      expect(due(null), isNull);
      expect(due(''), isNull);
      expect(due('soon'), isNull);
      expect(due('2026-13-40'), isNull);
    });

    test('the same phrase moves with the anchor, not with the clock', () {
      expect(
        resolveCommitmentDue('tomorrow', DateTime(2025, 12, 31, 23, 59)),
        DateTime(2026, 1, 1),
      );
      expect(
        resolveCommitmentDue('friday', DateTime(2026, 11, 7)),
        DateTime(2026, 11, 13),
      );
    });
  });

  group('mergeCommitments', () {
    test('the first extraction resolves due dates against createdAt', () {
      final List<Commitment>? merged = mergeCommitments(
        existing: null,
        extracted: const <CommitmentDraft>[
          CommitmentDraft(text: 'Send the offer', due: 'Friday', who: 'me'),
        ],
        anchor: anchor,
      );
      expect(merged!.single.due, DateTime(2026, 11, 6));
      expect(merged.single.who, 'me');
      expect(merged.single.state, CommitmentState.open);
    });

    test('a run that said nothing leaves the stored list alone', () {
      final List<Commitment> existing = <Commitment>[
        const Commitment(text: 'A', state: CommitmentState.done),
      ];
      expect(
        mergeCommitments(existing: existing, extracted: null, anchor: anchor),
        isNull,
      );
    });

    test('re-enrichment keeps the user done and dismissed state', () {
      final List<Commitment> existing = <Commitment>[
        const Commitment(text: 'Send the offer', state: CommitmentState.done),
        const Commitment(text: 'Call  Bank', state: CommitmentState.dismissed),
        const Commitment(text: 'Stale open one'),
        const Commitment(text: 'Gone but done', state: CommitmentState.done),
      ];
      final List<Commitment> merged = mergeCommitments(
        existing: existing,
        extracted: const <CommitmentDraft>[
          CommitmentDraft(text: 'send the offer', due: 'friday'),
          CommitmentDraft(text: 'call bank'),
          CommitmentDraft(text: 'New one', due: 'tomorrow'),
        ],
        anchor: anchor,
      )!;
      final Map<String, CommitmentState> byKey = <String, CommitmentState>{
        for (final Commitment c in merged) c.key: c.state,
      };
      expect(byKey['send the offer'], CommitmentState.done);
      expect(byKey['call bank'], CommitmentState.dismissed);
      expect(byKey['new one'], CommitmentState.open);
      // A decision the user made outlives the model forgetting the line.
      expect(byKey['gone but done'], CommitmentState.done);
      // An open line the model no longer sees is the model's to drop.
      expect(byKey.containsKey('stale open one'), isFalse);
      expect(
        merged.firstWhere((Commitment c) => c.key == 'send the offer').due,
        DateTime(2026, 11, 6),
      );
    });

    test('an empty extraction records "looked, found none"', () {
      expect(
        mergeCommitments(
          existing: null,
          extracted: const <CommitmentDraft>[],
          anchor: anchor,
        ),
        isEmpty,
      );
    });
  });

  group('parseResponse', () {
    test('absent key is no answer, list is parsed and bounded', () {
      expect(
        HttpChatEnrichmentService.parseResponse(
          _body(<String, dynamic>{'title': 'x'}),
        ).commitments,
        isNull,
      );
      final EnrichmentResult result = HttpChatEnrichmentService.parseResponse(
        _body(<String, dynamic>{
          'title': 'x',
          'commitments': <dynamic>[
            <String, dynamic>{'text': ' Send the offer ', 'due': 'Friday'},
            <String, dynamic>{'text': 'Call X', 'who': 'Marek', 'due': null},
            <String, dynamic>{'text': ''},
            'garbage',
          ],
        }),
      );
      expect(result.commitments, hasLength(2));
      expect(result.commitments![0].text, 'Send the offer');
      expect(result.commitments![0].due, 'Friday');
      expect(result.commitments![1].who, 'Marek');
      expect(result.commitments![1].due, isNull);
    });

    test('an explicit empty list is an answer', () {
      expect(
        HttpChatEnrichmentService.parseResponse(
          _body(<String, dynamic>{'commitments': <dynamic>[]}),
        ).commitments,
        isEmpty,
      );
    });

    test('the prompt asks for commitments with a phrase, not a date', () {
      final String prompt = buildEnrichmentSystemPrompt();
      expect(prompt, contains('"commitments"'));
    });
  });

  group('open commitments across captures', () {
    test('only open ones, sorted by due date with undated last', () {
      final Recording a = _row(
        commitments: <Commitment>[
          Commitment(text: 'Late', due: DateTime(2026, 11, 20)),
          const Commitment(text: 'Undated'),
          Commitment(
            text: 'Done',
            due: DateTime(2026, 11, 1),
            state: CommitmentState.done,
          ),
        ],
      );
      final Recording b = Recording(
        id: 'r2',
        filePath: '/tmp/r2.txt',
        createdAt: DateTime(2026, 11, 5),
        durationMs: 0,
        status: RecordingStatus.completed,
        commitments: <Commitment>[
          Commitment(text: 'Soon', due: DateTime(2026, 11, 6)),
        ],
      );
      final List<CommitmentEntry> entries = openCommitments(<Recording>[a, b]);
      expect(entries.map((CommitmentEntry e) => e.commitment.text), <String>[
        'Soon',
        'Late',
        'Undated',
      ]);
      expect(entries.first.recording.id, 'r2');
    });
  });

  group('ICS export', () {
    test('a dated commitment is an all-day event on its due date', () {
      final String ics = commitmentToIcs(
        Commitment(
          text: 'Send the offer, v2; final',
          due: DateTime(2026, 11, 6),
        ),
        recordingId: 'r1',
        stamp: DateTime.utc(2026, 11, 4, 10),
      );
      expect(ics, startsWith('BEGIN:VCALENDAR\r\n'));
      expect(ics, contains('BEGIN:VEVENT\r\n'));
      expect(ics, contains('DTSTART;VALUE=DATE:20261106\r\n'));
      expect(ics, contains('DTEND;VALUE=DATE:20261107\r\n'));
      expect(ics, contains(r'SUMMARY:Send the offer\, v2\; final'));
      expect(ics, contains('DTSTAMP:20261104T100000Z\r\n'));
      expect(ics, endsWith('END:VCALENDAR\r\n'));
    });

    test('an undated commitment is a to-do', () {
      final String ics = commitmentToIcs(
        const Commitment(text: 'Call the bank'),
        recordingId: 'r1',
        stamp: DateTime.utc(2026, 11, 4, 10),
      );
      expect(ics, contains('BEGIN:VTODO\r\n'));
      expect(ics, isNot(contains('DTSTART')));
    });

    test('long lines are folded under 75 octets', () {
      final String ics = commitmentToIcs(
        Commitment(text: 'ż' * 120, due: DateTime(2026, 11, 6)),
        recordingId: 'r1',
        stamp: DateTime.utc(2026, 11, 4, 10),
      );
      for (final String line in ics.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
      }
    });
  });
}
