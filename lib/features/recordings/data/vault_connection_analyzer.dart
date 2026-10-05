import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../../enrichment/domain/enrichment_context.dart';
import '../domain/agent_artifact.dart';
import '../domain/capture_priority.dart';
import '../domain/connection_reasoner.dart';
import '../domain/note_vault.dart';
import '../domain/untrusted_markdown.dart';

/// Searches local Markdown, then writes a separate, capture-owned analysis note.
/// The ordinary mirror remains free to update its own note after this runs.
class VaultConnectionAnalyzer {
  const VaultConnectionAnalyzer();

  static const int _maxNoteBytes = 128 * 1024;
  static const int _maxCandidates = 5;
  static final Set<String> _stopWords =
      ('about after before could from have their there these those which would with '
              'oraz które która który przez tego też jest jako jego może będzie było '
              'mnie moim sobie tutaj teraz')
          .split(' ')
          .toSet();

  Future<AgentArtifact> analyze({
    required Directory vault,
    required VaultNote note,
    required String sourcePath,
    required ConnectionReasoner reasoner,
    required EnrichmentContext context,
    CapturePriority? priority,
    String? priorityReason,
  }) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(note.id)) {
      throw const FormatException('Capture id is unsafe for a vault path.');
    }
    final File output = File(
      p.join(p.dirname(sourcePath), 'Analysis', '${note.id}.md'),
    );
    if (await output.exists() &&
        !await _isOurs(await output.readAsString(), note.id)) {
      return _artifact(note.id, output, null, await output.lastModified());
    }
    final List<ConnectionCandidate> candidates = await _candidates(
      vault,
      note,
      sourcePath,
    );
    final ConnectionAdvice advice = await reasoner.assess(
      title: note.title,
      text: note.body,
      candidates: candidates,
      context: context,
      priority: priority,
      priorityReason: priorityReason,
    );
    final String body = _render(vault, note, sourcePath, candidates, advice);
    final String hash = await _hash(body);
    final String content =
        '---\nparent-capture: ${note.id}\n'
        'analysis-hash: $hash\n---\n$body';
    await output.parent.create(recursive: true);
    if (await output.exists()) {
      final String previous = await output.readAsString();
      if (previous != content && !await _isOurs(previous, note.id)) {
        return _artifact(note.id, output, null, await output.lastModified());
      }
      if (previous == content) {
        return _artifact(note.id, output, advice, await output.lastModified());
      }
    }
    final File temp = File('${output.path}.tmp');
    await temp.writeAsString(content, flush: true);
    await temp.rename(output.path);
    return _artifact(note.id, output, advice, await output.lastModified());
  }

  AgentArtifact _artifact(
    String id,
    File file,
    ConnectionAdvice? advice,
    DateTime at,
  ) => AgentArtifact(
    id: file.path,
    captureId: id,
    title: 'Connections and next step',
    path: file.path,
    updatedAt: at,
    kind: AgentArtifactKind.resultNote,
    snippet: advice?.reason,
  );

  Future<List<ConnectionCandidate>> _candidates(
    Directory vault,
    VaultNote note,
    String sourcePath,
  ) async {
    final Set<String> sourceTerms = _terms(
      '${note.title} ${note.summary ?? ''} ${note.tags.join(' ')} ${note.body}',
    );
    final List<({ConnectionCandidate candidate, int score})> ranked = [];
    await for (final File entity in _markdownFiles(vault, sourcePath)) {
      final String raw;
      try {
        final RandomAccessFile reader = await entity.open();
        try {
          raw = utf8.decode(
            await reader.read(_maxNoteBytes),
            allowMalformed: true,
          );
        } finally {
          await reader.close();
        }
      } catch (_) {
        continue;
      }
      final String text = _body(raw);
      final Match? heading = RegExp(
        r'^#\s+(.+)$',
        multiLine: true,
      ).firstMatch(text);
      final String title =
          heading?.group(1)?.trim() ?? p.basenameWithoutExtension(entity.path);
      final String excerpt = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final Set<String> titleTerms = _terms(title);
      final List<String> shared =
          sourceTerms.intersection(_terms('$title $text')).toList()..sort();
      final int titleHits = shared.where(titleTerms.contains).length;
      if (shared.length < 2 && titleHits == 0) continue;
      final int score = shared.length + titleHits * 2;
      ranked.add((
        candidate: ConnectionCandidate(
          path: entity.path,
          title: title,
          sharedTerms: shared.take(5).toList(),
          excerpt: excerpt.length <= 300
              ? excerpt
              : '${excerpt.substring(0, 300)}…',
        ),
        score: score,
      ));
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked.take(_maxCandidates).map((entry) => entry.candidate).toList();
  }

  Stream<File> _markdownFiles(Directory vault, String sourcePath) async* {
    final String analysisDir = p.join(p.dirname(sourcePath), 'Analysis');
    final List<Directory> pending = <Directory>[vault];
    while (pending.isNotEmpty) {
      final Directory directory = pending.removeLast();
      await for (final FileSystemEntity entity in directory.list()) {
        if (p.basename(entity.path).startsWith('.')) continue;
        if (entity is Directory) {
          if (!p.equals(entity.path, analysisDir)) pending.add(entity);
        } else if (entity is File &&
            entity.path.endsWith('.md') &&
            !p.equals(entity.path, sourcePath)) {
          yield entity;
        }
      }
    }
  }

  static Set<String> _terms(String text) =>
      RegExp(r'[\p{L}\p{N}]{5,}', unicode: true)
          .allMatches(text.toLowerCase())
          .map((Match match) => match.group(0)!)
          .where((String word) => !_stopWords.contains(word))
          .toSet();

  static String _body(String raw) {
    if (!raw.startsWith('---\n')) return raw;
    final int end = raw.indexOf('\n---\n', 3);
    return end < 0 ? raw : raw.substring(end + 5);
  }

  String _render(
    Directory vault,
    VaultNote note,
    String source,
    List<ConnectionCandidate> candidates,
    ConnectionAdvice advice,
  ) {
    final StringBuffer out = StringBuffer()
      ..writeln()
      ..writeln('# Connections: ${sanitizeUntrustedMarkdown(note.title)}')
      ..writeln()
      ..writeln('Source: ${_link(vault, source)}')
      ..writeln()
      ..writeln('## Related notes')
      ..writeln();
    if (candidates.isEmpty) {
      out.writeln('No related notes found by local keyword search.');
    } else {
      for (final ConnectionCandidate candidate in candidates) {
        out.writeln(
          '- ${_link(vault, candidate.path)} — shared terms: '
          '${candidate.sharedTerms.join(', ')}',
        );
      }
    }
    out
      ..writeln()
      ..writeln('## Assessment')
      ..writeln()
      ..writeln('Decision: ${advice.decision.name}')
      ..writeln()
      ..writeln(sanitizeUntrustedMarkdownBody(advice.reason))
      ..writeln()
      ..writeln('Next step: ${sanitizeUntrustedMarkdownBody(advice.nextStep)}');
    return out.toString();
  }

  String _link(Directory vault, String path) {
    final String relative = p
        .withoutExtension(p.relative(path, from: vault.path))
        .replaceAll('\\', '/');
    if (relative.contains(RegExp(r'[\[\]|#\r\n]'))) {
      return sanitizeUntrustedMarkdown(p.basename(path));
    }
    return '[[$relative]]';
  }

  Future<bool> _isOurs(String content, String captureId) async {
    if (!content.startsWith('---\n')) return false;
    final int end = content.indexOf('\n---\n', 3);
    if (end < 0) return false;
    final Match? marker = RegExp(
      r'^analysis-hash: ([0-9a-f]{64})$',
      multiLine: true,
    ).firstMatch(content.substring(4, end));
    return content
            .substring(4, end)
            .split('\n')
            .contains('parent-capture: $captureId') &&
        marker != null &&
        marker.group(1) == await _hash(content.substring(end + 5));
  }

  Future<String> _hash(String value) async {
    final Hash digest = await Sha256().hash(utf8.encode(value));
    return digest.bytes
        .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
