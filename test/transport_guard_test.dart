import 'package:augustyniak_capture/core/http/transport_guard.dart';
import 'package:augustyniak_capture/features/command/domain/command_client.dart';
import 'package:augustyniak_capture/features/settings/data/settings_repository.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// One scheme-and-host judgement for every client that sends a bearer token
/// (#299). Provider profiles *report* it (`test/provider_endpoint_security_test.dart`
/// pins that path, and the Daily Connections service rides the active
/// enrichment profile, so it is covered there); the Command address *refuses*
/// it, because the fleet token opens a host that runs agents on the user's
/// repositories.
///
/// Loopback and the three private IPv4 ranges stay allowed for both: a model
/// server or a fleet aggregator on the user's own LAN is a choice, plain HTTP
/// to a host on the internet is almost always an accident.
class _FakeSettingsRepository extends SettingsRepository {
  AppSettings? stored;
  int saveCount = 0;

  @override
  Future<AppSettings?> load() async => stored;

  @override
  Future<void> save(AppSettings settings) async {
    stored = settings;
    saveCount++;
  }
}

void main() {
  group('transportIsInsecure', () {
    test('https is never insecure', () {
      expect(
        transportIsInsecure(Uri.parse('https://fleet.example.com')),
        isFalse,
      );
    });

    test('plain http to a public host is insecure', () {
      expect(
        transportIsInsecure(Uri.parse('http://fleet.example.com/api/hosts')),
        isTrue,
      );
    });

    test('loopback is not insecure', () {
      for (final String host in <String>[
        'localhost',
        'fleet.localhost',
        '127.0.0.1',
        '[::1]',
      ]) {
        expect(
          transportIsInsecure(Uri.parse('http://$host:8787')),
          isFalse,
          reason: host,
        );
      }
    });

    test('the user\'s own network is not insecure', () {
      for (final String host in <String>[
        '192.168.1.5',
        '10.0.0.5',
        '172.16.0.1',
        '172.31.255.255',
      ]) {
        expect(
          transportIsInsecure(Uri.parse('http://$host:8787')),
          isFalse,
          reason: host,
        );
      }
    });

    test('an address just outside the private range is insecure', () {
      // 172.15 and 172.32 are public; the 172.16/12 boundary leaking in the
      // permissive direction is what would make the guard useless.
      expect(transportIsInsecure(Uri.parse('http://172.32.0.1:8787')), isTrue);
      expect(transportIsInsecure(Uri.parse('http://172.15.0.1:8787')), isTrue);
    });

    test('a URI that reaches nothing is not insecure', () {
      expect(transportIsInsecure(Uri.parse('')), isFalse);
      expect(transportIsInsecure(Uri.parse('fleet.example.com')), isFalse);
      expect(transportIsInsecure(Uri.parse('mailto:x@example.com')), isFalse);
    });

    test('the scheme is read case-insensitively', () {
      expect(
        transportIsInsecure(Uri.parse('HTTP://fleet.example.com')),
        isTrue,
      );
    });
  });

  group('Command address', () {
    Future<(SettingsController, _FakeSettingsRepository)> controller() async {
      final _FakeSettingsRepository repo = _FakeSettingsRepository();
      final SettingsController controller = SettingsController(
        repository: repo,
      );
      await controller.initialize();
      return (controller, repo);
    }

    test('a public http address is refused and nothing is written', () async {
      final (SettingsController c, _FakeSettingsRepository repo) =
          await controller();
      await c.setCommandConfig(
        baseUrl: 'https://fleet.example.com',
        token: 't',
      );
      final int saves = repo.saveCount;

      await expectLater(
        c.setCommandConfig(baseUrl: 'http://203.0.113.10', token: 't2'),
        throwsA(isA<InsecureCommandAddress>()),
      );

      // Neither half of the pair moved: the token is not saved against an
      // address that was refused.
      expect(repo.saveCount, saves);
      expect(c.settings.commandBaseUrl, 'https://fleet.example.com');
      expect(c.settings.commandToken, 't');
    });

    test('a private-network http address is accepted', () async {
      final (SettingsController c, _FakeSettingsRepository repo) =
          await controller();

      await c.setCommandConfig(baseUrl: 'http://192.168.1.10', token: 't');

      expect(repo.stored?.commandBaseUrl, 'http://192.168.1.10');
      expect(c.commandClient.isConfigured, isTrue);
    });

    test('the 172.16/12 boundary is the same one providers use', () async {
      final (SettingsController c, _) = await controller();

      await c.setCommandConfig(baseUrl: 'http://172.16.0.1', token: 't');
      await c.setCommandConfig(baseUrl: 'http://172.31.255.255', token: 't');
      await expectLater(
        c.setCommandConfig(baseUrl: 'http://172.15.0.1', token: 't'),
        throwsA(isA<InsecureCommandAddress>()),
      );
      await expectLater(
        c.setCommandConfig(baseUrl: 'http://172.32.0.1', token: 't'),
        throwsA(isA<InsecureCommandAddress>()),
      );
    });

    test('the refusal names the address and says what to use instead', () {
      final String message = const InsecureCommandAddress(
        'http://203.0.113.10',
      ).toString();
      expect(message, contains('http://203.0.113.10'));
      expect(message, contains('https://'));
    });

    test(
      'a public http address stored before the guard yields a disabled client',
      () async {
        // The save-time refusal cannot reach a value already on disk; the
        // client itself is the second line, so the fleet token never leaves.
        final _FakeSettingsRepository repo = _FakeSettingsRepository()
          ..stored = AppSettings.empty.copyWith(
            commandBaseUrl: 'http://203.0.113.10',
            commandToken: 'fleet-token',
          );
        final SettingsController c = SettingsController(repository: repo);
        await c.initialize();

        expect(c.commandClient, isA<DisabledCommandClient>());
        expect(
          SettingsController.commandAddressIsInsecure('http://203.0.113.10'),
          isTrue,
        );
      },
    );
  });
}
