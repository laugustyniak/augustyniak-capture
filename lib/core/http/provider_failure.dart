/// One line describing a failed provider call: what failed, the status code,
/// and as much of the body as diagnoses it.
///
/// **The body is bounded because it is not reliably the provider's own words.**
/// A 4xx from a chat endpoint routinely quotes the request back, and this app's
/// requests carry the transcript and the project context it read off disk. The
/// message then becomes the capture's `error` field, a line in the Logs tab,
/// and whatever the user copies out of there — three places a note is not
/// expected to reappear.
///
/// What actually diagnoses a failure lives at the front: `invalid_api_key`,
/// `model_not_found`, a rate-limit notice. [maxBodyChars] is generous enough
/// that a real provider error arrives whole and only bulk is lost.
String describeProviderFailure(String what, int statusCode, String body) {
  final String flattened = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  // A bare 502 from a proxy has no body at all, and `failed (502):` with
  // nothing after the colon reads as a bug in this app rather than a failure
  // at the other end.
  if (flattened.isEmpty) return '$what failed ($statusCode).';
  final String detail = flattened.length <= maxBodyChars
      ? flattened
      : '${flattened.substring(0, maxBodyChars).trimRight()}…';
  return '$what failed ($statusCode): $detail';
}

/// How much of a response body a failure message carries.
const int maxBodyChars = 300;
