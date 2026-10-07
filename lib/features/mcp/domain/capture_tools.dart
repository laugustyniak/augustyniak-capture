import 'dart:convert';

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
      if (project != null)
        'project': <String, dynamic>{'id': project.id, 'name': project.name},
      'routes': <Map<String, dynamic>>[
        for (final RouteRecord route in r.routes)
          <String, dynamic>{
            'kind': route.kind.name,
            'target': route.target,
            'at': route.at.toUtc().toIso8601String(),
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

  int _limit(Map<String, dynamic> args) {
    final Object? value = args['limit'];
    if (value == null) return _defaultLimit;
    if (value is! int) throw InvalidParams('limit must be an integer');
    return value.clamp(1, _maxLimit);
  }
}
