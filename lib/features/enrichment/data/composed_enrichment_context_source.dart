import '../../projects/data/project_context_reader.dart';
import '../../projects/domain/project.dart';
import '../domain/enrichment_context.dart';
import 'soul_reader.dart';

/// Builds the enrichment context out of the two places it actually lives: the
/// user's profile in `settings.json`, and the project's own repository.
///
/// Wired from callbacks rather than from the two controllers because the
/// controllers are `ChangeNotifier`s bound to the shell's lifecycle, while this
/// object is read once per enrichment. Callbacks also keep the class testable
/// without building a settings repository or a projects repository.
class ComposedEnrichmentContextSource implements EnrichmentContextSource {
  ComposedEnrichmentContextSource({
    required String? Function() profile,
    required Project? Function(String projectId) projectById,
    String? Function()? soulPath,
    List<Project> Function()? projects,
    ProjectContextReader reader = const ProjectContextReader(),
    SoulReader soulReader = const SoulReader(),
  }) : _profile = profile,
       _soulPath = soulPath ?? (() => null),
       _projects = projects ?? (() => const <Project>[]),
       _projectById = projectById,
       _reader = reader,
       _soulReader = soulReader;

  final String? Function() _profile;

  /// Where the user's `SOUL.md` lives, read per call so a Config change
  /// reaches the next capture. Null or blank means the typed [_profile] is the
  /// soul, exactly as before this existed.
  final String? Function() _soulPath;
  final SoulReader _soulReader;
  final List<Project> Function() _projects;
  final Project? Function(String projectId) _projectById;
  final ProjectContextReader _reader;

  /// Never throws: enrichment is best-effort, and losing the context must cost
  /// a *better* title, never the enrichment itself. A caller that wants the
  /// reason logged reads [lastError] — the source cannot log for itself,
  /// because it is deliberately unaware of the `LogSink`.
  String? lastError;

  @override
  Future<EnrichmentContext> contextFor(String? projectId) async {
    lastError = null;
    final ResolvedSoul soul = await _soulReader.resolve(
      path: _soulPath(),
      typed: _profile() ?? '',
    );
    // A configured file that failed is reported, never thrown: the typed
    // profile stands in, and the capture is ranked against that instead.
    if (soul.origin.isFallback) {
      lastError =
          'Soul file ${soul.fileName} ${soul.origin.name}'
          '${soul.error == null ? '' : ': ${soul.error}'}'
          ' — using the typed profile';
    }
    final List<EnrichmentProjectOption> options = <EnrichmentProjectOption>[
      for (final Project candidate in _projects())
        EnrichmentProjectOption(
          id: candidate.id,
          name: candidate.name,
          description: candidate.description,
        ),
    ];
    final String profile = soul.text;
    final String? profileSource = soul.origin == SoulOrigin.file
        ? soul.fileName
        : null;
    final String? profileFallback = soul.origin.isFallback
        ? '${soul.fileName} ${soul.origin.name}'
        : null;

    if (projectId == null || projectId.isEmpty) {
      return EnrichmentContext(
        profile: profile,
        profileSource: profileSource,
        profileFallback: profileFallback,
        projects: options,
      );
    }

    // A project that was deleted after the capture was filed leaves a dangling
    // id on the item — the same shape as a dangling `activeProfileId`. The
    // profile layer still applies.
    final Project? project = _projectById(projectId);
    if (project == null) {
      return EnrichmentContext(
        profile: profile,
        profileSource: profileSource,
        profileFallback: profileFallback,
        projects: options,
      );
    }

    try {
      final ProjectContextDocument? document = await _reader.read(
        project.repoPath,
      );
      return EnrichmentContext(
        profile: profile,
        profileSource: profileSource,
        profileFallback: profileFallback,
        projects: options,
        // The project's own `description` is the fallback, not the primary:
        // it is a one-line label typed once, while the repository file is
        // maintained as the work changes. Using it when no file is found is
        // what makes the feature work for a project with no repo checked out.
        project: document?.text ?? project.description,
        projectSource:
            document?.fileName ??
            (project.description == null ? null : 'project description'),
      );
    } catch (exception) {
      lastError = 'Project context unreadable: $exception';
      return EnrichmentContext(
        profile: profile,
        profileSource: profileSource,
        profileFallback: profileFallback,
        projects: options,
        project: project.description,
        projectSource: project.description == null
            ? null
            : 'project description',
      );
    }
  }
}
