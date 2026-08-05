import 'package:flutter/material.dart';

enum MilestoneType {
  captureCreated,
  captureDone,
}

class Milestone {
  const Milestone({
    required this.id,
    required this.type,
    required this.count,
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
  });

  final String id;
  final MilestoneType type;
  final int count;
  final String title;
  final String description;
  final IconData icon;
  final Color color;

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
    final bool isDone = type == MilestoneType.captureDone;

    if (count == 1) {
      return Milestone(
        id: id,
        type: type,
        count: count,
        title: isDone ? 'PIERWSZE UKOŃCZONE!' : 'PIERWSZE PRZECHWYCENIE!',
        description: isDone
            ? 'Zaznaczono pierwszą notatkę jako wykonaną. Świetny start!'
            : 'Zapisano pierwsze przechwycenie w aplikacji. Tak trzymaj!',
        icon: isDone ? Icons.check_circle_outline_rounded : Icons.bolt_rounded,
        color: isDone ? const Color(0xFF10B981) : const Color(0xFF6366F1),
      );
    }

    if (count == 10) {
      return Milestone(
        id: id,
        type: type,
        count: count,
        title: isDone ? '10 ZROBIONYCH!' : '10 PRZECHWYCEŃ!',
        description: isDone
            ? '10 zadań odhaczonych! Zbierasz tempo.'
            : '10 przechwyconych myśli i nagrań. Dobry nawyk!',
        icon: isDone ? Icons.stars_rounded : Icons.auto_awesome_rounded,
        color: isDone ? const Color(0xFF059669) : const Color(0xFF8B5CF6),
      );
    }

    if (count == 20) {
      return Milestone(
        id: id,
        type: type,
        count: count,
        title: isDone ? '20 ZROBIONYCH!' : '20 PRZECHWYCEŃ!',
        description: isDone
            ? '20 ukończonych elementów! Twoja skrzynka czyszczeje.'
            : '20 utworzonych wpisów. Masz w głowie mnóstwo pomysłów!',
        icon: isDone ? Icons.emoji_events_rounded : Icons.local_fire_department_rounded,
        color: isDone ? const Color(0xFF10B981) : const Color(0xFFEC4899),
      );
    }

    if (count == 50) {
      return Milestone(
        id: id,
        type: type,
        count: count,
        title: isDone ? '50 ZROBIONYCH!' : '50 PRZECHWYCEŃ!',
        description: isDone
            ? 'Pół setki domkniętych spraw! Niesamowita produktywność.'
            : '50 zarchiwizowanych myśli. System działa znakomicie!',
        icon: isDone ? Icons.workspace_premium_rounded : Icons.rocket_launch_rounded,
        color: isDone ? const Color(0xFFF59E0B) : const Color(0xFF3B82F6),
      );
    }

    if (count == 100) {
      return Milestone(
        id: id,
        type: type,
        count: count,
        title: isDone ? 'SETKA ZROBIONA (100)!' : '100 PRZECHWYCEŃ!',
        description: isDone
            ? 'Sto zrealizowanych zadań! Jesteś mistrzem domykania.'
            : '100 wpisów w bazie! Twój osobisty mózg rośnie w siłę.',
        icon: isDone ? Icons.military_tech_rounded : Icons.diamond_rounded,
        color: const Color(0xFFEAB308),
      );
    }

    if (count == 200) {
      return Milestone(
        id: id,
        type: type,
        count: count,
        title: isDone ? '200 ZROBIONYCH!' : '200 PRZECHWYCEŃ!',
        description: isDone
            ? '200 zamkniętych tematów. Prawdziwa maszyna do pracy!'
            : '200 nagrań i notatek w systemie. Niezwykłe osiągnięcie!',
        icon: Icons.shield_rounded,
        color: const Color(0xFFA855F7),
      );
    }

    if (count == 300) {
      return Milestone(
        id: id,
        type: type,
        count: count,
        title: isDone ? '300 ZROBIONYCH!' : '300 PRZECHWYCEŃ!',
        description: isDone
            ? '300 ukończonych spraw! Absolutny poziom ekspercki.'
            : '300 przechwyceń! Pełny przepływ informacji.',
        icon: Icons.verified_rounded,
        color: const Color(0xFF06B6D4),
      );
    }

    // Every 100 further (400, 500, 600...)
    return Milestone(
      id: id,
      type: type,
      count: count,
      title: isDone ? '$count ZROBIONYCH!' : '$count PRZECHWYCEŃ!',
      description: isDone
          ? '$count ukończonych zadań. Imponująca konsekwencja!'
          : '$count zapisanych notatek i nagrań!',
      icon: Icons.celebration_rounded,
      color: const Color(0xFFF43F5E),
    );
  }
}
