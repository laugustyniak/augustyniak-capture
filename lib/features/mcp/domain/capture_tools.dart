import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../projects/domain/project.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/domain/route_record.dart';
import 'capture_source.dart';

/// A malformed call: unknown tool, missing or mistyped argument. Surfaces as
/// JSON-RPC -32602, unlike a failure *inside* a tool, which is an `isError`
/// result the model can read and react to.
class InvalidParams implements Exception {
  InvalidParams(this.message);
  final String message;
}

/// A tool failed for a reason the agent should see (no database, unknown id).
class _ToolFailure implements Exception {
  _ToolFailure(this.message);
  final String message;
}

class CaptureTools {
  CaptureTools(this._source, {void Function(String)? log})
    : _log = log ?? ((String _) {});

  final CaptureSource _source;
  final void Function(String) _log;

  static const int _defaultLimit = 20;
  static const int _nextOpenDefaultLimit = 10;
  static const int _maxLimit = 100;
  static const int _snippetLength = 300;

  static Map<String, dynamic> _schema(
    Map<String, dynamic> properties,
    List<String> required,
  ) => <String, dynamic>{
    'type': 'object',
    'properties': properties,
    'required': required,
  };

  static const Map<String, dynamic> _limitProperty = <String, dynamic>{
    'type': 'integer',
    'minimum': 1,
    'maximum': _maxLimit,
    'description': 'Maximum results (default $_defaultLimit, max $_maxLimit).',
  };

  static const String _projectDescription =
      'Project id or name (case-insensitive).';

  List<Map<String, dynamic>> get definitions => <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'search_captures',
      'description':
          'Search the user\'s voice captures and notes. Case-insensitive '
          'substring match over title, summary, transcript and tags. '
          'Transcripts are cut to a snippet; use get_capture for the whole '
          'text. Read-only.',
      'inputSchema': _schema(
        <String, dynamic>{
          'query': <String, dynamic>{'type': 'string'},
          'project': <String, dynamic>{
            'type': 'string',
            'description': _projectDescription,
          },
          'since': <String, dynamic>{
            'type': 'string',
            'description': 'ISO date or date-time; only newer captures.',
          },
          'limit': _limitProperty,
        },
        <String>['query'],
      ),
    },
    <String, dynamic>{
      'name': 'get_capture',
      'description':
          'One capture in full: transcript, summary, tags, priority and '
          'route history. No source files. Read-only.',
      'inputSchema': _schema(
        <String, dynamic>{
          'id': <String, dynamic>{'type': 'string'},
        },
        <String>['id'],
      ),
    },
    <String, dynamic>{
      'name': 'list_project_captures',
      'description':
          'Newest captures of one project, optionally by status '
          '(saved, pendingTranscription, transcribing, completed, failed). '
          'Read-only.',
      'inputSchema': _schema(
        <String, dynamic>{
          'project': <String, dynamic>{
            'type': 'string',
            'description': _projectDescription,
          },
          'status': <String, dynamic>{'type': 'string'},
          'limit': _limitProperty,
        },
        <String>['project'],
      ),
    },
    <String, dynamic>{
      'name': 'next_open_captures',
      'description':
          'The work queue: completed captures the user has not marked '
          'processed, oldest first, with full transcript and enrichment. '
          'Each carries a version (sha256 of its stored payload). Pass the '
          'returned next as after for the following page; next is absent on '
          'the last page. Read-only.',
      'inputSchema': _schema(<String, dynamic>{
        'limit': <String, dynamic>{
          'type': 'integer',
          'minimum': 1,
          'maximum': _maxLimit,
          'default': _nextOpenDefaultLimit,
          'description':
              'Maximum results (default $_nextOpenDefaultLimit, '
              'max $_maxLimit).',
        },
        'after': <String, dynamic>{
          'type': 'string',
          'description': 'Opaque cursor: the next value of the previous page.',
        },
        'project': <String, dynamic>{
          'type': 'string',
          'description': _projectDescription,
        },
      }, <String>[]),
    },
  ];

  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> args,
  ) async {
    final Future<Object> Function(Map<String, dynamic>) handler;
    switch (name) {
      case 'search_captures':
        handler = _search;
      case 'get_capture':
        handler = _get;
      case 'list_project_captures':
        handler = _listProject;
      case 'next_open_captures':
        handler = _nextOpen;
      default:
        throw InvalidParams('Unknown tool: $name');
    }
    try {
      return _text(await handler(args), isError: false);
    } on _ToolFailure catch (e) {
      return _text(e.message, isError: true);
    } on InvalidParams {
      rethrow;
    } on CaptureStoreUnavailable catch (e) {
      // The detail names paths: stderr only, never the agent.
      _log('$name: ${e.detail}');
      return _text('Capture store unavailable.', isError: true);
    } catch (e) {
      _log('$name failed: $e');
      return _text('Internal error.', isError: true);
    }
  }

  Map<String, dynamic> _text(Object body, {required bool isError}) =>
      <String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'text',
            'text': body is String ? body : jsonEncode(body),
          },
        ],
        if (isError) 'isError': true,
      };

  Future<Object> _search(Map<String, dynamic> args) async {
    final String query = _string(args, 'query', required: true)!.toLowerCase();
    final String? projectRef = _string(args, 'project');
    final String? sinceRaw = _string(args, 'since');
    final DateTime? since = sinceRaw == null ? null : _parseSince(sinceRaw);
    if (sinceRaw != null && since == null) {
      throw InvalidParams('since must be an ISO date, got "$sinceRaw"');
    }
    final int limit = _limit(args);

    final List<Project> projects = await _source.projects();
    final Project? project = projectRef == null
        ? null
        : _resolve(projects, projectRef);
    final List<Recording> rows = await _source.recordings();
    return <Map<String, dynamic>>[
      for (final Recording r in rows)
        if ((project == null || r.projectId == project.id) &&
            (since == null || !r.createdAt.toUtc().isBefore(since)) &&
            _matches(r, query))
          _capture(r, projects, snippet: true),
    ].take(limit).toList();
  }

  Future<Object> _get(Map<String, dynamic> args) async {
    final String id = _string(args, 'id', required: true)!;
    final List<Recording> rows = await _source.recordings();
    for (final Recording r in rows) {
      if (r.id == id) return _capture(r, await _source.projects());
    }
    throw _ToolFailure('No capture with id "$id".');
  }

  Future<Object> _listProject(Map<String, dynamic> args) async {
    final String ref = _string(args, 'project', required: true)!;
    final String? status = _string(args, 'status');
    if (status != null &&
        !RecordingStatus.values.any((RecordingStatus s) => s.name == status)) {
      throw InvalidParams(
        'status must be one of '
        '${RecordingStatus.values.map((RecordingStatus s) => s.name).join(', ')}',
      );
    }
    final int limit = _limit(args);
    final List<Project> projects = await _source.projects();
    final Project project = _resolve(projects, ref);
    final List<Recording> rows = await _source.recordings();
    return <Map<String, dynamic>>[
      for (final Recording r in rows)
        if (r.projectId == project.id &&
            (status == null || r.status.name == status))
          _capture(r, projects, snippet: true),
    ].take(limit).toList();
  }

  Future<Object> _nextOpen(Map<String, dynamic> args) async {
    final int limit = _limit(args, defaultLimit: _nextOpenDefaultLimit);
    final String? afterRaw = _string(args, 'after');
    final ({int ms, String id})? cursor = afterRaw == null
        ? null
        : _decodeCursor(afterRaw);
    final String? projectRef = _string(args, 'project');
    final List<Project> projects = await _source.projects();
    final Project? project = projectRef == null
        ? null
        : _resolve(projects, projectRef);
    final List<({Recording recording, String payload})> rows =
        <({Recording recording, String payload})>[
          for (final ({Recording recording, String payload}) e
              in await _source.recordingsWithPayload())
            if (e.recording.status == RecordingStatus.completed &&
                !e.recording.isProcessedByUser &&
                (project == null || e.recording.projectId == project.id))
              e,
        ];
    int byOrder(
      ({Recording recording, String payload}) a,
      ({Recording recording, String payload}) b,
    ) {
      final int c = a.recording.createdAt.millisecondsSinceEpoch.compareTo(
        b.recording.createdAt.millisecondsSinceEpoch,
      );
      return c != 0 ? c : a.recording.id.compareTo(b.recording.id);
    }

    rows.sort(byOrder);
    final List<({Recording recording, String payload})> page =
        <({Recording recording, String payload})>[
          for (final ({Recording recording, String payload}) e in rows)
            if (cursor == null ||
                e.recording.createdAt.millisecondsSinceEpoch > cursor.ms ||
                (e.recording.createdAt.millisecondsSinceEpoch == cursor.ms &&
                    e.recording.id.compareTo(cursor.id) > 0))
              e,
        ];
    final bool more = page.length > limit;
    final List<({Recording recording, String payload})> taken = page
        .take(limit)
        .toList();
    return <String, dynamic>{
      'captures': <Map<String, dynamic>>[
        for (final ({Recording recording, String payload}) e in taken)
          <String, dynamic>{
            ..._capture(e.recording, projects),
            'version': sha256.convert(utf8.encode(e.payload)).toString(),
          },
      ],
      if (more)
        'next': base64Url.encode(
          utf8.encode(
            '${taken.last.recording.createdAt.millisecondsSinceEpoch}:'
            '${taken.last.recording.id}',
          ),
        ),
    };
  }

  ({int ms, String id}) _decodeCursor(String raw) {
    try {
      final String decoded = utf8.decode(base64Url.decode(raw));
      final int sep = decoded.indexOf(':');
      final int? ms = sep < 0 ? null : int.tryParse(decoded.substring(0, sep));
      final String id = sep < 0 ? '' : decoded.substring(sep + 1);
      if (ms != null && id.isNotEmpty) return (ms: ms, id: id);
    } catch (_) {}
    throw InvalidParams('after is not a valid cursor');
  }

  DateTime? _parseSince(String raw) {
    // A bare date has no zone; read it as UTC midnight so the answer does not
    // depend on the machine the server runs on.
    final bool dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw);
    return DateTime.tryParse(dateOnly ? '${raw}T00:00:00Z' : raw)?.toUtc();
  }

  /// Throws a [_ToolFailure] rather than returning null: an unknown project
  /// must read as an error, not as "this project has no captures".
  Project _resolve(List<Project> projects, String ref) {
    final String lower = ref.toLowerCase();
    for (final Project p in projects) {
      if (p.id == ref) return p;
    }
    for (final Project p in projects) {
      if (p.name.toLowerCase() == lower) return p;
    }
    throw _ToolFailure(
      'Unknown project "$ref". Known: '
      '${projects.map((Project p) => p.name).join(', ')}',
    );
  }

  bool _matches(Recording r, String lowerQuery) {
    bool hit(String? text) =>
        text != null && text.toLowerCase().contains(lowerQuery);
    return hit(r.title) ||
        hit(r.summary) ||
        hit(r.transcript) ||
        r.tags.any(hit);
  }

  Map<String, dynamic> _capture(
    Recording r,
    List<Project> projects, {
    bool snippet = false,
  }) {
    Project? project;
    for (final Project p in projects) {
      if (p.id == r.projectId) project = p;
    }
    String? transcript = r.transcript;
    if (snippet && transcript != null && transcript.length > _snippetLength) {
      transcript = '${transcript.substring(0, _snippetLength)}…';
    }
    // No filePath, thumbPath, segments or artifacts: the agent gets content,
    // never the location of the user's source files.
    return <String, dynamic>{
      'id': r.id,
      'createdAt': r.createdAt.toUtc().toIso8601String(),
      'type': r.type.name,
      'status': r.status.name,
      'title': ?r.title,
      'summary': ?r.summary,
      'transcript': ?transcript,
      'tags': r.tags,
      'priority': ?r.priority?.name,
      'priorityReason': ?r.priorityReason,
      'category': ?r.category?.name,
      'resurfaceAt': ?r.resurfaceAt?.toUtc().toIso8601String(),
      'repeatEveryDays': ?r.repeatEveryDays,
      if (project != null)
        'project': <String, dynamic>{'id': project.id, 'name': project.name},
      'routes': <Map<String, dynamic>>[
        for (final RouteRecord route in r.routes)
          <String, dynamic>{
            'kind': route.kind.name,
            'target': route.target,
            'at': route.at.toUtc().toIso8601String(),
            if (route.decision != null) 'decision': route.decision!.toJson(),
            if (route.outcome != null)
              'outcome': <String, dynamic>{
                'state': route.outcome!.state.name,
                if (route.outcome!.prUrl != null) 'prUrl': route.outcome!.prUrl,
              },
          },
      ],
    };
  }

  String? _string(
    Map<String, dynamic> args,
    String key, {
    bool required = false,
  }) {
    final Object? value = args[key];
    if (value == null) {
      if (required) throw InvalidParams('Missing required argument "$key"');
      return null;
    }
    if (value is! String || (required && value.isEmpty)) {
      throw InvalidParams('Argument "$key" must be a non-empty string');
    }
    return value;
  }

  int _limit(Map<String, dynamic> args, {int defaultLimit = _defaultLimit}) {
    final Object? value = args['limit'];
    if (value == null) return defaultLimit;
    if (value is! int) throw InvalidParams('limit must be an integer');
    return value.clamp(1, _maxLimit);
  }
}
