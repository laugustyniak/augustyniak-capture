/// A threshold the user has just crossed.
///
/// This type carries the *fact* — which threshold, of which kind, and the
/// stable id that records it as unlocked. It deliberately carries no wording,
/// icon or colour: those are one widget's concern, they would drag
/// `package:flutter/material.dart` into `domain/`, and they are what a future
/// translation pass would have to reach into the domain to change. See
/// `presentation/milestone_copy.dart`.
enum MilestoneType {
  captureCreated,
  captureDone,
}

class Milestone {
  const Milestone({
    required this.id,
    required this.type,
    required this.count,
  });

  final String id;
  final MilestoneType type;
  final int count;

  static bool isMilestoneCount(int count) {
    if (count <= 0) return false;
    if (count == 1 ||
        count == 10 ||
        count == 20 ||
        count == 50 ||
        count == 100 ||
        count == 200 ||
        count == 300) {
      return true;
    }
    return count >= 400 && count % 100 == 0;
  }

  static Milestone? check({
    required MilestoneType type,
    required int currentCount,
    required Set<String> unlockedIds,
  }) {
    if (!isMilestoneCount(currentCount)) return null;

    final String prefix = type == MilestoneType.captureCreated ? 'capture' : 'done';
    final String id = '${prefix}_$currentCount';

    if (unlockedIds.contains(id)) return null;

    return create(type: type, count: currentCount, id: id);
  }

  static Milestone create({
    required MilestoneType type,
    required int count,
    required String id,
  }) {
    return Milestone(id: id, type: type, count: count);
  }
}
