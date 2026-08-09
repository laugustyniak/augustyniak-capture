import 'package:flutter/material.dart';

import '../domain/milestone.dart';

/// The words, icon and colour for a crossed threshold.
///
/// Lives in `presentation/` rather than on [Milestone] because it is one
/// widget's concern and because `IconData`/`Color` would otherwise pull Flutter
/// into `domain/`. The threshold cascade below mirrors
/// [Milestone.isMilestoneCount]: 1, 10, 20, 50, 100, 200, 300, then every
/// further 100. If a threshold is added there, add its tier here — the fallback
/// will otherwise absorb it silently.
///
/// The raw hex colours are inherited verbatim from the previous location.
/// `CLAUDE.md` says every raw hex belongs in `ConsolePalette`; these do not yet,
/// and moving them is deliberately a separate change.
({String title, String description, IconData icon, Color color}) milestoneCopyFor(
  Milestone milestone,
) {
  final bool isDone = milestone.type == MilestoneType.captureDone;
  final int count = milestone.count;

  if (count == 1) {
    return (
      title: isDone ? 'FIRST ONE DONE!' : 'FIRST CAPTURE!',
      description: isDone
          ? 'You marked your first note as done. Great start!'
          : 'Your first capture is saved. Keep it up!',
      icon: isDone ? Icons.check_circle_outline_rounded : Icons.bolt_rounded,
      color: isDone ? const Color(0xFF10B981) : const Color(0xFF6366F1),
    );
  }

  if (count == 10) {
    return (
      title: isDone ? '10 DONE!' : '10 CAPTURES!',
      description: isDone
          ? '10 items ticked off! You are picking up pace.'
          : '10 thoughts and recordings captured. Good habit!',
      icon: isDone ? Icons.stars_rounded : Icons.auto_awesome_rounded,
      color: isDone ? const Color(0xFF059669) : const Color(0xFF8B5CF6),
    );
  }

  if (count == 20) {
    return (
      title: isDone ? '20 DONE!' : '20 CAPTURES!',
      description: isDone
          ? '20 items completed! Your inbox is clearing.'
          : '20 entries created. Your head is full of ideas!',
      icon: isDone ? Icons.emoji_events_rounded : Icons.local_fire_department_rounded,
      color: isDone ? const Color(0xFF10B981) : const Color(0xFFEC4899),
    );
  }

  if (count == 50) {
    return (
      title: isDone ? '50 DONE!' : '50 CAPTURES!',
      description: isDone
          ? 'Half a hundred closed! Remarkable productivity.'
          : '50 thoughts archived. The system is working.',
      icon: isDone ? Icons.workspace_premium_rounded : Icons.rocket_launch_rounded,
      color: isDone ? const Color(0xFFF59E0B) : const Color(0xFF3B82F6),
    );
  }

  if (count == 100) {
    return (
      title: isDone ? 'A HUNDRED DONE (100)!' : '100 CAPTURES!',
      description: isDone
          ? 'One hundred tasks completed! You are a master of closing.'
          : '100 entries in the database! Your personal brain is growing stronger.',
      icon: isDone ? Icons.military_tech_rounded : Icons.diamond_rounded,
      color: const Color(0xFFEAB308),
    );
  }

  if (count == 200) {
    return (
      title: isDone ? '200 DONE!' : '200 CAPTURES!',
      description: isDone
          ? '200 topics closed. A real work machine!'
          : '200 recordings and notes in the system. Remarkable!',
      icon: Icons.shield_rounded,
      color: const Color(0xFFA855F7),
    );
  }

  if (count == 300) {
    return (
      title: isDone ? '300 DONE!' : '300 CAPTURES!',
      description: isDone
          ? '300 items completed! Absolute expert level.'
          : '300 captures! Full flow of information.',
      icon: Icons.verified_rounded,
      color: const Color(0xFF06B6D4),
    );
  }

  // Every 100 further (400, 500, 600...)
  return (
    title: isDone ? '$count DONE!' : '$count CAPTURES!',
    description: isDone
        ? '$count tasks completed. Impressive consistency!'
        : '$count notes and recordings saved!',
    icon: Icons.celebration_rounded,
    color: const Color(0xFFF43F5E),
  );
}
