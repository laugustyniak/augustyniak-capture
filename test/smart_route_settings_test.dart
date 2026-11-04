import 'package:augustyniak_capture/features/recordings/domain/smart_route.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('smart route settings', () {
    test('legacy JSON defaults to auto with no Todoist command', () {
      final AppSettings legacy = AppSettings.fromJson(<String, dynamic>{});
      expect(legacy.smartRouteConfirm, SmartRouteConfirm.auto);
      expect(legacy.todoistAgentCommand, '');
    });

    test('defaults stay out of the JSON', () {
      final Map<String, dynamic> json = AppSettings.empty.toJson();
      expect(json.containsKey('smartRouteConfirm'), isFalse);
      expect(json.containsKey('todoistAgentCommand'), isFalse);
    });

    test('round-trips both fields', () {
      const AppSettings settings = AppSettings(
        smartRouteConfirm: SmartRouteConfirm.confirmEffects,
        todoistAgentCommand: 'claude --mcp-config ~/.claude/todoist.json',
      );
      final AppSettings back = AppSettings.fromJson(settings.toJson());
      expect(back.smartRouteConfirm, SmartRouteConfirm.confirmEffects);
      expect(
        back.todoistAgentCommand,
        'claude --mcp-config ~/.claude/todoist.json',
      );
    });

    test('an unknown confirm value degrades to auto', () {
      final AppSettings back = AppSettings.fromJson(<String, dynamic>{
        'smartRouteConfirm': 'sometimes',
      });
      expect(back.smartRouteConfirm, SmartRouteConfirm.auto);
    });

    test('copyWith changes only what it names', () {
      const AppSettings base = AppSettings(todoistAgentCommand: 'claude');
      final AppSettings next = base.copyWith(
        smartRouteConfirm: SmartRouteConfirm.confirmEffects,
      );
      expect(next.todoistAgentCommand, 'claude');
      expect(next.smartRouteConfirm, SmartRouteConfirm.confirmEffects);
    });
  });
}
