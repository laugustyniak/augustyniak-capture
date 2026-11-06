import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../recordings/domain/recording.dart';
import '../data/http_daily_triage_service.dart';
import '../domain/daily_triage.dart';

/// Owns the daily triage digest: when it runs, which proposals are still worth
/// showing, and what accepting or rejecting one does.
///
/// **Running never changes a capture.** The service only reads, and the digest
/// goes to its own append-only log. A capture changes only when the user
/// accepts a proposal, and then through [TriageActions] — the same controller
/// entry points a hand edit uses.
class DailyTriageController extends ChangeNotifier {
  DailyTriageController({
    required DailyTriageService service,
    required TriageLog log,
    required List<Recording> Function() recordings,
    required TriageActions actions,
    Map<String, String> Function()? projectNames,
    DateTime Function()? clock,
  }) : _service = service,
       _log = log,
       _recordings = recordings,
       _actions = actions,
       _projectNames = projectNames ?? (() => const <String, String>{}),
       _clock = clock ?? DateTime.now;

  final DailyTriageService _service;
  final TriageLog _log;
  final List<Recording> Function() _recordings;
  final TriageActions _actions;
  final Map<String, String> Function() _projectNames;
  final DateTime Function() _clock;

  TriageDigest? _digest;
  final Set<String> _rejected = <String>{};
  final Set<String> _accepted = <String>{};
  bool _loaded = false;
  bool _historyUnreadable = false;
  bool _running = false;
  String? _error;

  /// Set by any run, successful or not, so a failing model is not asked again
  /// on every resume. The digest's own time covers the successful case across
  /// launches.
  DateTime? _lastAttemptAt;

  bool get isLoaded => _loaded;
  bool get historyUnreadable => _historyUnreadable;
  bool get isRunning => _running;
  String? get error => _error;
  TriageDigest? get digest => _digest;

  /// The digest's proposals the user still has to answer, checked against the
  /// live list: one citing a capture that is gone or already closed is hidden,
  /// and so is a re-rank the capture already has.
  List<TriageProposal> get proposals {
    final TriageDigest? digest = _digest;
    if (digest == null) return const <TriageProposal>[];
    final Map<String, Recording> live = <String, Recording>{
      for (final Recording recording in _recordings()) recording.id: recording,
    };
    return digest.proposals.where((TriageProposal proposal) {
      if (_rejected.contains(proposal.key)) return false;
      if (_accepted.contains(proposal.key)) return false;
      for (final String id in proposal.captureIds) {
        final Recording? recording = live[id];
        if (recording == null || recording.isProcessedByUser) return false;
      }
      if (proposal.kind == TriageKind.rerank &&
          live[proposal.captureIds.single]?.priority == proposal.priority) {
        return false;
      }
      return true;
    }).toList();
  }

  Future<void> load() async {
    try {
      final TriageHistory history = await _log.load();
      _digest = history.latest;
      _rejected
        ..clear()
        ..addAll(history.rejected);
      _accepted
        ..clear()
        ..addAll(history.accepted);
      _historyUnreadable = false;
    } catch (_) {
      // Without the rejections an automatic run would bring them all back.
      _historyUnreadable = true;
    }
    _loaded = true;
    notifyListeners();
  }

  /// The launch/resume trigger: runs only when the last digest (or failed
  /// attempt) is at least [triageInterval] old.
  Future<void> runIfDue() async {
    if (!_loaded || _historyUnreadable || _running) return;
    DateTime? last = _digest?.at;
    final DateTime? attempt = _lastAttemptAt;
    if (attempt != null && (last == null || attempt.isAfter(last))) {
      last = attempt;
    }
    if (!triageIsDue(last, _clock())) return;
    await run();
  }

  /// The manual "Run triage" action.
  Future<void> run() async {
    if (_running) return;
    _running = true;
    _error = null;
    _lastAttemptAt = _clock();
    notifyListeners();
    try {
      final TriageDigest digest = await _service.triage(
        List<Recording>.of(_recordings()),
        projectNames: _projectNames(),
      );
      _digest = digest;
      try {
        await _log.appendDigest(digest);
      } catch (_) {
        _error = 'The digest could not be saved; it is shown for now only.';
      }
    } catch (error) {
      _error = describeTriageFailure(error);
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> accept(TriageProposal proposal) async {
    _error = null;
    try {
      await _apply(proposal);
    } catch (error) {
      _error = 'Could not apply the proposal: $error';
      notifyListeners();
      return;
    }
    _accepted.add(proposal.key);
    await _remember(proposal, TriageOutcome.accepted);
  }

  Future<void> reject(TriageProposal proposal) async {
    _error = null;
    _rejected.add(proposal.key);
    await _remember(proposal, TriageOutcome.rejected);
  }

  Future<void> _apply(TriageProposal proposal) async {
    final Map<String, Recording> live = <String, Recording>{
      for (final Recording recording in _recordings()) recording.id: recording,
    };
    switch (proposal.kind) {
      case TriageKind.merge:
        // Keep the oldest capture; the duplicates close. Closing is the
        // existing, reversible entry point — nothing is deleted or rewritten.
        final List<Recording> group =
            <Recording>[
              for (final String id in proposal.captureIds)
                if (live[id] case final Recording recording) recording,
            ]..sort(
              (Recording a, Recording b) => a.createdAt.compareTo(b.createdAt),
            );
        for (final Recording recording in group.skip(1)) {
          if (!recording.isProcessedByUser) await _actions.close(recording.id);
        }
      case TriageKind.close:
      case TriageKind.stale:
        for (final String id in proposal.captureIds) {
          final Recording? recording = live[id];
          if (recording != null && !recording.isProcessedByUser) {
            await _actions.close(id);
          }
        }
      case TriageKind.rerank:
        await _actions.setPriority(
          proposal.captureIds.single,
          proposal.priority!,
        );
    }
  }

  Future<void> _remember(TriageProposal proposal, TriageOutcome outcome) async {
    try {
      await _log.appendDecision(
        TriageDecision(key: proposal.key, outcome: outcome, at: _clock()),
      );
    } catch (_) {
      _error = 'Your answer could not be saved and may be asked again.';
    }
    notifyListeners();
  }
}

/// One readable line for every way a run can fail.
String describeTriageFailure(Object error) => switch (error) {
  TriageNotConfiguredException() ||
  TriageResponseException() ||
  InsecureTriageEndpointException() => error.toString(),
  HttpException(:final String message) => message,
  _ => 'Triage failed: $error',
};
