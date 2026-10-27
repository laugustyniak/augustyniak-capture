import '../../features/projects/data/executable_resolver.dart';

final PathExecutableResolver _resolver = PathExecutableResolver();

/// Absolute path of [name] when it can be found, otherwise [name] unchanged.
///
/// A bundled macOS app does not inherit the user's `PATH`, so a bare `ffmpeg`
/// (Homebrew) throws `No such file or directory` outside `flutter run` — see
/// [ExecutableResolver]. Falling back to the bare name keeps a genuinely missing
/// binary failing in the same, documented `ProcessException` way.
Future<String> resolveExecutable(String name) async {
  if (name.contains('/')) return name;
  return await _resolver.resolve(name) ?? name;
}
