/// Who the user is, and what the capture's project is about.
///
/// The two layers are kept apart rather than pre-joined into one string because
/// they have different origins, different lifetimes and different trust: the
/// [profile] is typed by the user in the Config tab, while [project] is *read
/// off disk* from a repository file the user did not necessarily write. The
/// prompt labels them separately for that reason.
class EnrichmentContext {
  const EnrichmentContext({this.profile, this.project, this.projectSource});

  static const EnrichmentContext none = EnrichmentContext();

  /// Free-form "this is me" text from the Config tab: goals, what gets
  /// captured, how it should be filed. Persisted in `settings.json`.
  final String? profile;

  /// The active project's own description, read from its repository — see
  /// `ProjectContextReader`. Null when the capture has no project, the repo is
  /// gone, or no context file exists in it.
  final String? project;

  /// Which file [project] came from (`CLAUDE.md`, `AGENTS.md`, `README.md`),
  /// for the log line. Carried here rather than logged at the read site so the
  /// controller can report it next to the item it actually enriched.
  final String? projectSource;

  /// Hard ceilings, applied here rather than only in the editor.
  ///
  /// [maxProjectChars] is the larger of the two and still much smaller than a
  /// real `CLAUDE.md`: this one is over 20 000 characters, and sending that on
  /// every capture would cost more than the enrichment it is meant to improve.
  /// The profile is hand-typed, so a smaller bound is enough.
  static const int maxProfileChars = 2000;
  static const int maxProjectChars = 4000;

  bool get isEmpty =>
      _blankToNull(profile) == null && _blankToNull(project) == null;

  /// Names the layers that were actually sent, for the log line. Null when
  /// nothing was — the caller then omits the segment entirely.
  ///
  /// Both layers are named, not only the project one. Reporting just the file
  /// makes "the profile went, there is no project" indistinguishable from "no
  /// context at all" — which is exactly the ambiguity this log exists to
  /// remove, and the state every capture is in until a project is created.
  String? get sourceSummary {
    final EnrichmentContext resolved = normalized();
    final List<String> layers = <String>[
      if (resolved.profile != null) 'profile',
      if (resolved.project != null) resolved.projectSource ?? 'project',
    ];
    return layers.isEmpty ? null : layers.join(' + ');
  }

  /// Trimmed, blank-collapsed and truncated. Called by the prompt builder, so
  /// no caller can bypass the ceilings by constructing the object directly.
  ///
  /// Truncation is **head-only**, deliberately unlike `truncateForEnrichment`.
  /// A transcript keeps its tail because the conclusion lives there; a README
  /// or a CLAUDE.md is front-loaded — what the project *is* comes first, and
  /// the tail is build flags and licence notes.
  EnrichmentContext normalized() => EnrichmentContext(
    profile: _clamp(defuseFenceMarkers(profile), maxProfileChars),
    project: _clamp(defuseFenceMarkers(project), maxProjectChars),
    projectSource: _blankToNull(projectSource),
  );

  /// A line shaped like one of the prompt's own fence markers, rewritten so it
  /// cannot close the block it sits inside.
  ///
  /// The fence in `_appendContext` is what separates *reference material* from
  /// *instructions*, and a fence made of a literal string is only as strong as
  /// the guarantee that the fenced text does not contain it. It does not: a
  /// `CLAUDE.md` is a file written to brief a model, and one line reading
  /// `--- END PROJECT CONTEXT ---` puts everything after it back at the top
  /// level of the system prompt, where the standing order not to follow
  /// instructions no longer applies to it.
  ///
  /// Narrow on purpose. Only a line that *is* a marker is rewritten — a
  /// horizontal rule, a YAML front-matter fence and a `--- BEGINNING ---`
  /// heading all survive, because the pattern requires `BEGIN` or `END` as a
  /// whole word between the dashes.
  static final RegExp _fenceMarker = RegExp(
    r'^[ \t]*-{3,}[ \t]*(BEGIN|END)\b.*$',
    multiLine: true,
    caseSensitive: false,
  );

  static const String fenceMarkerReplacement = '[removed: fence marker]';

  static String? defuseFenceMarkers(String? value) =>
      value?.replaceAll(_fenceMarker, fenceMarkerReplacement);

  static String? _clamp(String? value, int limit) {
    final String? trimmed = _blankToNull(value);
    if (trimmed == null) return null;
    if (trimmed.length <= limit) return trimmed;
    return '${trimmed.substring(0, limit)}\n[...]';
  }

  static String? _blankToNull(String? value) {
    final String trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Resolves the context for one capture.
///
/// A seam for the same reason as `ClipboardSink`: the real implementation
/// reads a file off the user's disk, and the pure-Dart suites must be able to
/// enrich without touching one. The default answers [EnrichmentContext.none],
/// so an install that has configured nothing behaves exactly as before.
///
/// Takes the capture's `projectId` rather than the whole `Recording` so this
/// layer stays independent of the recordings feature.
abstract interface class EnrichmentContextSource {
  Future<EnrichmentContext> contextFor(String? projectId);
}

class EmptyEnrichmentContextSource implements EnrichmentContextSource {
  const EmptyEnrichmentContextSource();

  @override
  Future<EnrichmentContext> contextFor(String? projectId) async =>
      EnrichmentContext.none;
}
