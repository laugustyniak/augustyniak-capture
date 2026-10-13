/// Whether a request to [uri] would carry its bearer token in the clear to a
/// host that is not the user's own.
///
/// Shared by every client that puts a token in an `Authorization` header:
/// provider profiles report it as a `NO TLS` pill, the Command address refuses
/// it at save time. **Only a public host over plain `http` is insecure.**
/// `http://localhost:11434` (Ollama), `http://localhost:8080` (llama.cpp) and a
/// server on the desk under the LAN are first-class setups — flagging those
/// would train the warning away, which costs more than it buys.
///
/// A URI that reaches nothing at all (no host, or a scheme that is not `http`)
/// is not insecure: it already degrades to the disabled client, and a second
/// complaint about the same field would bury the first.
bool transportIsInsecure(Uri uri) {
  if (uri.host.isEmpty) return false;
  if (uri.scheme.toLowerCase() != 'http') return false;
  return !isOwnNetworkHost(uri.host);
}

/// Loopback, or one of the three private IPv4 ranges.
///
/// The `172.16/12` boundary is the one worth getting exactly right: 172.15
/// and 172.32 are public, and a range that leaks either way in the
/// permissive direction makes the warning above useless.
bool isOwnNetworkHost(String host) {
  final String name = host.toLowerCase();
  if (name == 'localhost' || name == '::1' || name.endsWith('.localhost')) {
    return true;
  }

  final List<String> octets = name.split('.');
  if (octets.length != 4) return false;
  final List<int?> parts = octets.map(int.tryParse).toList();
  if (parts.any((int? part) => part == null || part < 0 || part > 255)) {
    return false;
  }
  final int first = parts[0]!;
  final int second = parts[1]!;
  if (first == 127) return true;
  if (first == 10) return true;
  if (first == 192 && second == 168) return true;
  if (first == 172 && second >= 16 && second <= 31) return true;
  return false;
}
