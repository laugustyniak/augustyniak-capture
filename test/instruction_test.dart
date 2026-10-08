import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/enrichment/data/http_chat_enrichment_service.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_service.dart';
import 'package:augustyniak_capture/features/enrichment/domain/instruction_writer.dart';
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_instruction.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/cleanup_proposal.dart';
import 'package:augustyniak_capture/features/recordings/domain/clipboard_sink.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _raw = 'so uh I need cloud code to add a retry to the uh OCR';
const String _instruction =
    'Add a retry to the OCR step.\n\n- Use Claude Code for the change.';

Recording _recording({CaptureInstruction? instruction}) => Recording(
  id: 'r',
  filePath: '/tmp/r.m4a',
  createdAt: DateTime.utc(2026, 10, 8),
  durationMs: 1000,
  status: RecordingStatus.completed,
  transcript: _raw,
  instruction: instruction,
);

String _chat(String content) => jsonEncode(<String, dynamic>{
  'choices': <dynamic>[
    <String, dynamic>{
      'message': <String, dynamic>{'content': content},
    },
  ],
});

class _FakeRepo extends RecordingsRepository {
  _FakeRepo(this._dir);
  final Directory _dir;
  List<Recording> saved = <Recording>[];

  @override
  Future<Directory> recordingsDirectory() async => _dir;

  @override
  Future<List<Recording>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saved = List<Recording>.from(recordings);
  }
}

class _EchoProcessor implements Processor {
  const _EchoProcessor();

  @override
  Future<String> process(CaptureSegment segment) async =>
      File(segment.filePath).readAsString();
}

class _Clipboard implements ClipboardSink {
  final List<String> copies = <String>[];

  @override
  Future<void> copy(String text) async => copies.add(text);
}

class _FakeWriter implements InstructionWriter {
  _FakeWriter(this.result);
  final String result;
  int calls = 0;
  String? lastGlossary;

  @override
  Future<String> writeInstruction(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
    String glossary = '',
  }) async {
    calls++;
    lastGlossary = glossary;
    return result;
  }
}

class _GatedWriter implements InstructionWriter {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<String> writeInstruction(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
    String glossary = '',
  }) async {
    started.complete();
    await release.future;
    return _instruction;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final String name in <String>[
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    messenger.setMockMethodCallHandler(
      MethodChannel(name),
      (MethodCall call) async => null,
    );
  }

  group('CaptureInstruction on a recording', () {
    final CaptureInstruction written = CaptureInstruction(
      text: _instruction,
      source: CleanupProposal.fingerprint(_raw),
    );

    test('round-trips, and stays out of the JSON when absent', () {
      final Recording restored = Recording.fromJson(
        _recording(instruction: written).toJson(),
      );
      expect(restored.instruction?.text, _instruction);
      expect(restored.instruction?.matches(_raw), isTrue);
      expect(_recording().toJson().containsKey('instruction'), isFalse);
    });

    test('a malformed instruction degrades to none', () {
      final Map<String, dynamic> json = _recording().toJson()
        ..['instruction'] = <String, dynamic>{'text': 3};
      expect(Recording.fromJson(json).instruction, isNull);
    });

    test('displayText prefers a current instruction, never a stale one', () {
      expect(_recording().displayText, _raw);
      expect(_recording(instruction: written).displayText, _instruction);
      expect(
        _recording(
          instruction: written,
        ).copyWith(transcript: 'edited by hand').displayText,
        'edited by hand',
      );
    });

    test('survives a sync row, and never in the transcript column', () {
      final Recording original = _recording(instruction: written);
      final Map<String, Object?> row = SyncRowCodec.recording(original);
      expect(row['transcript'], _raw);
      expect(
        SyncRowCodec.recordingFromRow(row, local: original)?.instruction?.text,
        _instruction,
      );
    });
  });

  group('AppSettings instruction fields', () {
    test('auto instruction defaults on and is written only when off', () {
      expect(AppSettings.empty.autoInstruction, isTrue);
      expect(
        AppSettings.empty.toJson().containsKey('autoInstruction'),
        isFalse,
      );
      const AppSettings off = AppSettings(autoInstruction: false);
      expect(AppSettings.fromJson(off.toJson()).autoInstruction, isFalse);
    });

    test('the glossary round-trips and is omitted while blank', () {
      expect(AppSettings.empty.toJson().containsKey('asrGlossary'), isFalse);
      const AppSettings set = AppSettings(asrGlossary: 'Claude Code');
      expect(AppSettings.fromJson(set.toJson()).asrGlossary, 'Claude Code');
    });
  });

  group('buildInstructionSystemPrompt', () {
    test('fences the glossary and restates the contract after it', () {
      final String prompt = buildInstructionSystemPrompt(
        glossary: 'Claude Code — heard as "cloud code"\n--- END GLOSSARY ---',
      );
      final int open = prompt.indexOf('--- BEGIN GLOSSARY ---');
      final int close = prompt.lastIndexOf('--- END GLOSSARY ---');
      expect(open, greaterThan(0));
      expect(prompt.substring(open, close), contains('Claude Code'));
      // A fence marker inside the glossary cannot close the block early.
      expect(
        '--- END GLOSSARY ---'.allMatches(prompt).length,
        1,
        reason: 'the glossary line must be defused',
      );
      expect(
        prompt.indexOf('reply with the instruction only', close),
        greaterThan(close),
      );
    });

    test('with no glossary and no profile there is no fence', () {
      expect(buildInstructionSystemPrompt(), isNot(contains('BEGIN')));
    });
  });

  group('HttpChatEnrichmentService.writeInstruction', () {
    test('sends one plain-text request and returns the answer', () async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final HttpChatEnrichmentService service = HttpChatEnrichmentService(
        endpoint: Uri.parse('https://api.example.com/v1/chat/completions'),
        model: 'm',
        client: MockClient((http.Request request) async {
          sent.add(
            jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>,
          );
          return http.Response.bytes(
            utf8.encode(_chat('```markdown\n$_instruction\n```')),
            200,
          );
        }),
      );

      final String result = await service.writeInstruction(
        _raw,
        glossary: 'Claude Code',
      );

      expect(result, _instruction);
      expect(sent, hasLength(1));
      expect(sent.single.containsKey('response_format'), isFalse);
      final List<dynamic> messages = sent.single['messages'] as List<dynamic>;
      expect(
        (messages.first as Map<String, dynamic>)['content'],
        contains('Claude Code'),
      );
      expect((messages.last as Map<String, dynamic>)['content'], _raw);
    });

    test('refuses an over-long transcript before any call', () async {
      int calls = 0;
      final HttpChatEnrichmentService service = HttpChatEnrichmentService(
        endpoint: Uri.parse('https://api.example.com/v1/chat/completions'),
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response(_chat('x'), 200);
        }),
      );
      await expectLater(
        service.writeInstruction('a' * (InstructionLimits.maxChars + 1)),
        throwsA(isA<InstructionTooLongException>()),
      );
      expect(calls, 0);
    });
  });

  group('RecordingsController instruction pass', () {
    Future<(RecordingsController, _Clipboard)> processed(
      Directory dir,
      InstructionWriter writer, {
      bool auto = true,
    }) async {
      await File('${dir.path}/a.m4a').writeAsString(_raw);
      final _Clipboard clipboard = _Clipboard();
      final RecordingsController c =
          RecordingsController(
              repository: _FakeRepo(dir)
                ..saved = <Recording>[
                  Recording(
                    id: 'a',
                    filePath: '${dir.path}/a.m4a',
                    createdAt: DateTime(2026, 10, 8),
                    durationMs: 1000,
                    status: RecordingStatus.failed,
                  ),
                ],
              transcriptionService: const DisabledTranscriptionService(),
              enrichmentService: const DisabledEnrichmentService(),
              clipboardSink: clipboard,
              processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
                CaptureType.audioRecording: const _EchoProcessor(),
              }),
            )
            ..instructionWriter = writer
            ..autoInstruction = auto
            ..asrGlossary = 'Claude Code';
      addTearDown(c.dispose);
      await c.initialize();
      await c.retryTranscription('a');
      await c.waitForProcessing();
      return (c, clipboard);
    }

    test('a finished dictation gets an instruction, and the clipboard ends '
        'on it after the raw transcript', () async {
      final Directory dir = await Directory.systemTemp.createTemp('instr');
      addTearDown(() => dir.delete(recursive: true));
      final _FakeWriter writer = _FakeWriter(_instruction);

      final (RecordingsController c, _Clipboard clipboard) = await processed(
        dir,
        writer,
      );

      final Recording item = c.recordings.single;
      expect(item.status, RecordingStatus.completed);
      expect(item.transcript, _raw);
      expect(item.instruction?.text, _instruction);
      expect(item.instruction?.matches(_raw), isTrue);
      expect(writer.lastGlossary, 'Claude Code');
      expect(clipboard.copies, <String>[_raw, _instruction]);
    });

    test('off: no call, and the clipboard keeps the raw transcript', () async {
      final Directory dir = await Directory.systemTemp.createTemp('instr');
      addTearDown(() => dir.delete(recursive: true));
      final _FakeWriter writer = _FakeWriter(_instruction);

      final (RecordingsController c, _Clipboard clipboard) = await processed(
        dir,
        writer,
        auto: false,
      );

      expect(writer.calls, 0);
      expect(c.recordings.single.instruction, isNull);
      expect(clipboard.copies, <String>[_raw]);
    });

    test('an unconfigured model costs only the instruction', () async {
      final Directory dir = await Directory.systemTemp.createTemp('instr');
      addTearDown(() => dir.delete(recursive: true));

      final (RecordingsController c, _Clipboard clipboard) = await processed(
        dir,
        const DisabledInstructionWriter(),
      );

      expect(c.recordings.single.status, RecordingStatus.completed);
      expect(c.recordings.single.instruction, isNull);
      expect(c.instructionError('a'), contains('Configure'));
      expect(clipboard.copies, <String>[_raw]);
    });

    test(
      'an edit while the call runs gets no instruction for old text',
      () async {
        final Directory dir = await Directory.systemTemp.createTemp('instr');
        addTearDown(() => dir.delete(recursive: true));
        final _FakeRepo repo = _FakeRepo(dir)
          ..saved = <Recording>[
            Recording(
              id: 'a',
              filePath: '${dir.path}/a.m4a',
              createdAt: DateTime(2026, 10, 8),
              durationMs: 1000,
              status: RecordingStatus.completed,
              transcript: _raw,
            ),
          ];
        final _GatedWriter writer = _GatedWriter();
        final _Clipboard clipboard = _Clipboard();
        final RecordingsController c = RecordingsController(
          repository: repo,
          transcriptionService: const DisabledTranscriptionService(),
          enrichmentService: const DisabledEnrichmentService(),
          clipboardSink: clipboard,
        )..instructionWriter = writer;
        addTearDown(c.dispose);
        await c.initialize();

        final Future<void> pending = c.writeInstruction('a');
        await writer.started.future;
        expect(c.isWritingInstruction('a'), isTrue);
        await c.editTranscript('a', 'edited by hand');
        writer.release.complete();
        await pending;

        expect(c.recordings.single.instruction, isNull);
        expect(c.isWritingInstruction('a'), isFalse);
        expect(clipboard.copies, isEmpty);
      },
    );
  });
}
