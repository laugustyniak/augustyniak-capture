import 'package:augustyniak_capture/features/recordings/domain/assistant_target.dart';
import 'package:flutter_test/flutter_test.dart';

const String _nasty = 'a&b=c #tag ?x\nline two\r\nzażółć gęślą jaźń';

void main() {
  group('prefill URLs', () {
    test('every service has its own prefill address', () {
      expect(
        AssistantTarget.claudeDesktop.launchFor('hi').uri.toString(),
        'claude://claude.ai/new?q=hi',
      );
      expect(
        AssistantTarget.claudeWeb.launchFor('hi').uri.toString(),
        'https://claude.ai/new?q=hi',
      );
      expect(
        AssistantTarget.chatgpt.launchFor('hi').uri.toString(),
        'https://chatgpt.com/?q=hi',
      );
      expect(
        AssistantTarget.perplexity.launchFor('hi').uri.toString(),
        'https://www.perplexity.ai/search?q=hi',
      );
    });

    test('reserved characters, newlines and Polish letters round-trip', () {
      for (final AssistantTarget target in AssistantTarget.values) {
        if (!target.supportsPrefill) continue;
        final AssistantLaunch launch = target.launchFor(_nasty);
        expect(launch.needsClipboard, isFalse, reason: target.name);
        expect(launch.uri.queryParameters['q'], _nasty, reason: target.name);
        expect(launch.uri.queryParameters.keys, <String>['q']);
        expect(launch.uri.fragment, isEmpty);
      }
    });

    test('gemini has no prefill and always needs the clipboard', () {
      final AssistantLaunch launch = AssistantTarget.gemini.launchFor('hi');
      expect(AssistantTarget.gemini.supportsPrefill, isFalse);
      expect(launch.needsClipboard, isTrue);
      expect(launch.uri.toString(), 'https://gemini.google.com/app');
    });
  });

  group('length limits', () {
    test('a web URL is measured encoded, so Polish text hits it early', () {
      // 1500 x ż is 1500 characters decoded but 9000 encoded (%C5%BC).
      final String polish = 'ż' * 1500;
      final AssistantLaunch launch = AssistantTarget.chatgpt.launchFor(polish);

      expect(launch.needsClipboard, isTrue);
      expect(launch.uri.toString(), 'https://chatgpt.com/');
      expect(launch.uri.hasQuery, isFalse);
    });

    test('the same length in ASCII still fits', () {
      final AssistantLaunch launch = AssistantTarget.chatgpt.launchFor(
        'a' * 1500,
      );
      expect(launch.needsClipboard, isFalse);
      expect(launch.uri.queryParameters['q'], 'a' * 1500);
    });

    test('the web limit is on the whole encoded URL', () {
      final AssistantLaunch fits = AssistantTarget.claudeWeb.launchFor(
        'a' * 7900,
      );
      final AssistantLaunch over = AssistantTarget.claudeWeb.launchFor(
        'a' * 8000,
      );
      expect(fits.needsClipboard, isFalse);
      expect(fits.uri.toString().length, lessThanOrEqualTo(8000));
      expect(over.needsClipboard, isTrue);
    });

    test('Claude Desktop is measured on the decoded prompt', () {
      // 12000 Polish letters would be 72000 encoded, and Desktop accepts it.
      final AssistantLaunch fits = AssistantTarget.claudeDesktop.launchFor(
        'ż' * 12000,
      );
      final AssistantLaunch over = AssistantTarget.claudeDesktop.launchFor(
        'ż' * 12001,
      );
      expect(fits.needsClipboard, isFalse);
      expect(fits.uri.queryParameters['q'], 'ż' * 12000);
      expect(over.needsClipboard, isTrue);
      expect(over.uri.toString(), 'claude://claude.ai/new');
    });
  });

  test('labels, domains and auto-submit flags', () {
    expect(AssistantTarget.chatgpt.label, 'ChatGPT');
    expect(AssistantTarget.chatgpt.domain, 'chatgpt.com');
    expect(AssistantTarget.perplexity.domain, 'www.perplexity.ai');
    expect(AssistantTarget.gemini.domain, 'gemini.google.com');
    expect(AssistantTarget.claudeDesktop.label, 'Claude Desktop');

    final Set<AssistantTarget> sends = <AssistantTarget>{
      for (final AssistantTarget t in AssistantTarget.values)
        if (t.autoSubmits) t,
    };
    expect(sends, <AssistantTarget>{
      AssistantTarget.claudeWeb,
      AssistantTarget.chatgpt,
      AssistantTarget.perplexity,
    });
  });

  test('the recorded route names the service and how it was reached', () {
    expect(AssistantTarget.chatgpt.routeTarget, 'ChatGPT · web');
    expect(AssistantTarget.claudeWeb.routeTarget, 'Claude · web');
    expect(AssistantTarget.claudeDesktop.routeTarget, 'Claude Desktop');
  });
}
