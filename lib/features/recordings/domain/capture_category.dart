/// What an item *is*, expressed as the destination it will eventually be routed
/// to — Obsidian, Todoist, an agent queue — rather than as a topic. That
/// constraint is deliberate: a topic vocabulary grows without bound, while a
/// destination vocabulary stays small enough for a small model to classify
/// reliably.
///
/// Assigned by the enrichment stage, correctable by the user. Nothing consumes
/// it yet; export is a later phase.
enum CaptureCategory {
  /// Durable knowledge or reference material.
  note,

  /// Actionable by a human.
  task,

  /// A prompt or spec meant for an AI agent to execute.
  agentTask,

  /// A product or business idea, not yet actionable.
  idea,

  /// Attendees plus decisions.
  meetingNote,

  /// A paper, link or topic to chase later.
  researchLead,

  /// Unclassified — the model looked and could not place it. Also the landing
  /// point for a name this build does not know.
  capture;

  /// Same degrade-don't-throw rule as `CaptureType.fromName`: JSON from a newer
  /// build (or a model that invented a label) restores as [capture] instead of
  /// taking the whole row down with it.
  static CaptureCategory fromName(String? name) =>
      CaptureCategory.values.asNameMap()[name] ?? CaptureCategory.capture;

  /// The card chip and the edit-sheet dropdown label.
  String get label => switch (this) {
    CaptureCategory.note => 'NOTE',
    CaptureCategory.task => 'TASK',
    CaptureCategory.agentTask => 'AGENT TASK',
    CaptureCategory.idea => 'IDEA',
    CaptureCategory.meetingNote => 'MEETING',
    CaptureCategory.researchLead => 'RESEARCH',
    CaptureCategory.capture => 'CAPTURE',
  };
}
