/// The profile text a fresh install starts with.
///
/// Shipped as a default rather than left blank because an empty profile is the
/// worst of the three states: the model falls back to generic filing, and
/// nothing on screen suggests that writing two paragraphs would fix it. A
/// default that is visibly *about someone* is also self-documenting — it shows
/// the shape of a good profile far better than a hint string can.
///
/// What it deliberately does **not** contain is anything about a specific
/// project. That layer is read from the repository (`ProjectContextReader`), so
/// repeating it here would send the same text twice and spend the profile's
/// ceiling on it.
///
/// The category rules carry the most weight. `CaptureCategory` values are
/// routing destinations, and the boundary between `task` and `agentTask` — do I
/// do this, or does an agent — is a personal convention no model can infer from
/// the enum names alone.
///
/// The trigger phrases stay in Polish on purpose even though the rest is
/// English: they have to match what is actually dictated, and an English
/// "let's do" never fires on "zróbmy".
abstract final class EnrichmentProfileDefaults {
  const EnrichmentProfileDefaults._();

  static const String text = '''I am a solo developer and AI consultant — Flutter/Dart, Python, LLM
integrations. I dictate in Polish, away from the keyboard, and triage later.

Route by what I must DO next, not by topic:
- agentTask: work for a coding agent — a repo or file name, a spec, an
  imperative aimed at a tool ("zróbmy", "dodaj", "napraw", "wejdź i zobacz").
  Most of what I dictate about my own apps is this.
- task: something I must do myself that is not code — a call, an invoice.
- idea: product or business direction, not yet actionable — "a gdyby".
- meetingNote: a call or meeting — names, arrangements, deadlines.
- researchLead: anything to look into later, and ANY open question. If the
  recording asks something I do not know yet ("czy...?", "jak rozwiązać",
  "dlaczego"), it is researchLead even when the subject sounds technical.
- note: durable knowledge — but only when I record an ANSWER, not a question:
  how something works, a gotcha I already solved.
- capture: only when none fits. Never use it to avoid deciding.

Title and summary in Polish. The title names the thing to act on, not the
recording: "Naprawić drenaż kolejki", not "Notatka o kolejce".

Dictation mangles names — repair them everywhere rather than repeating them:
"cloude koda" is Claude Code, "flater" is Flutter, "wisper" is Whisper,
"olama" is Ollama. My own app is Augustyniak Capture (heard as "Augustynia
Capture").

Tags name the THING a capture is about — never the activity performed on it
("testowanie", "implementacja"), never a word from the rules above
("sprawdzic", "napraw" are triggers), never an umbrella that fits everything
("technologia", "app", "praca", "projekt"). Ask: would this tag ever separate
two captures? If not, drop it. Lowercase, and English for technical terms
though I dictate in Polish — "optimisation" and "optymalizacja" must not be
two tags. Reuse: flutter, dart, macos, android, python, ai, llm, gpu, klient,
oferta.''';
}
