import '../../projects/data/project_context_reader.dart';
import '../../projects/domain/project.dart';
import '../domain/enrichment_context.dart';

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
    ProjectContextReader reader = const ProjectContextReader(),
  }) : _profile = profile,
       _projectById = projectById,
       _reader = reader;

  final String? Function() _profile;
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
    final String? profile = _profile();

    if (projectId == null || projectId.isEmpty) {
      return EnrichmentContext(profile: profile);
    }

    // A project that was deleted after the capture was filed leaves a dangling
    // id on the item — the same shape as a dangling `activeProfileId`. The
    // profile layer still applies.
    final Project? project = _projectById(projectId);
    if (project == null) return EnrichmentContext(profile: profile);

    try {
      final ProjectContextDocument? document = await _reader.read(
        project.repoPath,
      );
      return EnrichmentContext(
        profile: profile,
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
        project: project.description,
        projectSource: project.description == null
            ? null
            : 'project description',
      );
    }
  }
}
