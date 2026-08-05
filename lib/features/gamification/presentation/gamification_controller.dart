import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/gamification_repository.dart';
import '../domain/gamification_stats.dart';
import '../domain/milestone.dart';

class GamificationController extends ChangeNotifier {
  GamificationController({GamificationRepository? repository})
      : _repository = repository ?? GamificationRepository();

  final GamificationRepository _repository;
  GamificationStats _stats = const GamificationStats();
  Milestone? _pendingMilestone;
  bool _initialized = false;

  GamificationStats get stats => _stats;
  Milestone? get pendingMilestone => _pendingMilestone;
  bool get isInitialized => _initialized;

  Future<void> initialize({int totalExistingCaptures = 0, int totalExistingDone = 0}) async {
    _stats = await _repository.load();
    
    // Sync current lifetime maximums if current active set is higher
    int captures = _stats.totalCapturesCreated;
    int done = _stats.totalCapturesDone;

    if (totalExistingCaptures > captures) {
      captures = totalExistingCaptures;
    }
    if (totalExistingDone > done) {
      done = totalExistingDone;
    }

    if (captures != _stats.totalCapturesCreated || done != _stats.totalCapturesDone) {
      _stats = _stats.copyWith(
        totalCapturesCreated: captures,
        totalCapturesDone: done,
      );
      unawaited(_repository.save(_stats));
    }

    _initialized = true;
    notifyListeners();
  }

  Future<void> onCaptureCreated(int currentCapturesCount) async {
    final int newTotal = mathMax(_stats.totalCapturesCreated + 1, currentCapturesCount);
    final Milestone? milestone = Milestone.check(
      type: MilestoneType.captureCreated,
      currentCount: newTotal,
      unlockedIds: _stats.unlockedMilestones,
    );

    Set<String> unlocked = _stats.unlockedMilestones;
    if (milestone != null) {
      unlocked = <String>{...unlocked, milestone.id};
      _pendingMilestone = milestone;
    }

    _stats = _stats.copyWith(
      totalCapturesCreated: newTotal,
      unlockedMilestones: unlocked,
    );
    unawaited(_repository.save(_stats));
    notifyListeners();
  }

  Future<void> onCaptureDone(int currentDoneCount) async {
    final int newTotal = mathMax(_stats.totalCapturesDone + 1, currentDoneCount);
    final Milestone? milestone = Milestone.check(
      type: MilestoneType.captureDone,
      currentCount: newTotal,
      unlockedIds: _stats.unlockedMilestones,
    );

    Set<String> unlocked = _stats.unlockedMilestones;
    if (milestone != null) {
      unlocked = <String>{...unlocked, milestone.id};
      _pendingMilestone = milestone;
    }

    _stats = _stats.copyWith(
      totalCapturesDone: newTotal,
      unlockedMilestones: unlocked,
    );
    unawaited(_repository.save(_stats));
    notifyListeners();
  }

  void dismissMilestone() {
    _pendingMilestone = null;
    notifyListeners();
  }

  static int mathMax(int a, int b) => a > b ? a : b;
}
