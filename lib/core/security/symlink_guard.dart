import 'dart:io';

/// Refuse to write through a symbolic link at [path].
///
/// Throws [FileSystemException] when [path] is a link, dangling or not. A
/// non-existent path is fine: the caller is about to create it.
///
/// The app writes `inbox.md` and `.agent-tasks/<id>.md` into a repository on
/// the user's behalf. `p.isWithin` is lexical, so a link planted at either name
/// redirects the write anywhere the user can write (#310). Planting one needs
/// write access to the repository already, so this is defence in depth, not
/// the only wall.
Future<void> refuseSymlink(String path) async {
  if (await FileSystemEntity.isLink(path)) {
    throw FileSystemException(
      'Refusing to write through a symbolic link',
      path,
    );
  }
}
