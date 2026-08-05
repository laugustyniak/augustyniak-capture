import 'package:flutter/foundation.dart';

@immutable
class GamificationStats {
  const GamificationStats({
    this.totalCapturesCreated = 0,
    this.totalCapturesDone = 0,
    this.unlockedMilestones = const <String>{},
  });

  final int totalCapturesCreated;
  final int totalCapturesDone;
  final Set<String> unlockedMilestones;

  GamificationStats copyWith({
    int? totalCapturesCreated,
    int? totalCapturesDone,
    Set<String>? unlockedMilestones,
  }) {
    return GamificationStats(
      totalCapturesCreated: totalCapturesCreated ?? this.totalCapturesCreated,
      totalCapturesDone: totalCapturesDone ?? this.totalCapturesDone,
      unlockedMilestones: unlockedMilestones ?? this.unlockedMilestones,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'totalCapturesCreated': totalCapturesCreated,
      'totalCapturesDone': totalCapturesDone,
      'unlockedMilestones': unlockedMilestones.toList(),
    };
  }

  factory GamificationStats.fromJson(Map<String, dynamic> json) {
    return GamificationStats(
      totalCapturesCreated: (json['totalCapturesCreated'] as num?)?.toInt() ?? 0,
      totalCapturesDone: (json['totalCapturesDone'] as num?)?.toInt() ?? 0,
      unlockedMilestones: (json['unlockedMilestones'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toSet() ??
          const <String>{},
    );
  }
}
