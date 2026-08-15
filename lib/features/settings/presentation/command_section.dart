import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../command/domain/command_client.dart';
import 'settings_controller.dart';

/// Where the Command control plane lives, and the fleet token that reaches it.
///
/// Stateful for the same reason `VaultSection` is: two text fields have to
/// survive this controller's notifications, and a background save must never
/// overwrite what somebody is halfway through typing.
///
/// **The check button is the point of the section, not a garnish.** Everything
/// else here is a field the user types into and nothing answers back; binding a
/// project then fails inside a picker, several taps away, where a wrong address
/// and a wrong token produce the same empty dropdown. One `GET /api/hosts` from
/// the screen that owns the credentials separates them while the credentials
/// are still on screen.
class CommandSection extends StatefulWidget {
  CommandSection({super.key, required this.controller});

  final SettingsController controller;

  @override
  State<CommandSection> createState() => _CommandSectionState();
}

class _CommandSectionState extends State<CommandSection> {
  late final TextEditingController _url = TextEditingController(text: _storedUrl);
  late final TextEditingController _token = TextEditingController(
    text: _storedToken,
  );
  final FocusNode _urlFocus = FocusNode();
  final FocusNode _tokenFocus = FocusNode();

  late String _syncedUrl = _storedUrl;
  late String _syncedToken = _storedToken;

  /// What the last check said. A report of an action rather than a state of the
  /// control plane, so it deliberately does not survive a rebuild of the tab.
  String? _checked;
  String? _checkError;
  bool _checking = false;

  String get _storedUrl => widget.controller.settings.commandBaseUrl ?? '';

  /// The stored value, sealed blob included. Showing the blob is right: it is
  /// what is on disk, and a field that silently emptied itself would read as
  /// "the token is gone" when the truth is that this launch cannot open it.
  String get _storedToken => widget.controller.settings.commandToken ?? '';

  bool get _urlDirty => _url.text.trim() != _syncedUrl.trim();
  bool get _tokenDirty => _token.text.trim() != _syncedToken.trim();

  @override
  void initState() {
    super.initState();
    _urlFocus.addListener(() {
      if (!_urlFocus.hasFocus && _urlDirty) _commit();
    });
    _tokenFocus.addListener(() {
      if (!_tokenFocus.hasFocus && _tokenDirty) _commit();
    });
  }

  @override
  void didUpdateWidget(CommandSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_storedUrl != _syncedUrl && !_urlDirty) {
      _syncedUrl = _storedUrl;
      _url.text = _syncedUrl;
    }
    if (_storedToken != _syncedToken && !_tokenDirty) {
      _syncedToken = _storedToken;
      _token.text = _syncedToken;
    }
  }

  @override
  void dispose() {
    _urlFocus.dispose();
    _tokenFocus.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  /// Both fields in one save, like `setTursoConfig`: they are useless apart,
  /// and a pair written in two saves has a moment on disk where the token
  /// belongs to an address that is no longer there.
  Future<void> _commit() async {
    final String url = _url.text.trim();
    final String token = _token.text.trim();
    setState(() {
      _syncedUrl = url;
      _syncedToken = token;
      // A changed address makes the previous answer a claim about somewhere
      // else, so it goes rather than sitting there looking current.
      _checked = null;
      _checkError = null;
    });
    await widget.controller.setCommandConfig(baseUrl: url, token: token);
  }

  Future<void> _check() async {
    if (_checking) return;
    if (_urlDirty || _tokenDirty) await _commit();
    setState(() {
      _checking = true;
      _checked = null;
      _checkError = null;
    });
    try {
      final List<CommandHost> hosts = await widget.controller.commandClient
          .hosts();
      if (!mounted) return;
      setState(
        () => _checked = hosts.isEmpty
            // Reachable and empty is a real answer, and a different problem
            // from unreachable: the token works, the fleet has no host.
            ? 'Reachable — no hosts registered.'
            : 'Reachable — ${hosts.length} host${hosts.length == 1 ? '' : 's'}: '
                  '${hosts.map((CommandHost host) => host.label).join(', ')}',
      );
    } catch (exception) {
      if (!mounted) return;
      setState(() => _checkError = exception.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool configured = widget.controller.commandClient.isConfigured;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(title: 'COMMAND CONTROL PLANE'),
        const SizedBox(height: 12),
        ConsoleCard(
          accent: configured ? Console.accent : Console.border,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Where a project\'s agent work runs. With an address set, '
                      'a project can be bound to a host and workspace on the '
                      'fleet; without one the app behaves exactly as before and '
                      'agent sessions stay local to this machine.',
                      style: TextStyle(
                        color: Console.mutedSoft,
                        fontSize: 10,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    configured ? 'CONFIGURED' : 'OFF',
                    style: ConsoleText.micro.copyWith(
                      color: configured ? Console.accent : Console.dimText,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _label('AGGREGATOR ADDRESS'),
              const SizedBox(height: 6),
              ConsoleField(
                controller: _url,
                focusNode: _urlFocus,
                monospace: true,
                fontSize: 12,
                textInputAction: TextInputAction.next,
                onSubmitted: (String _) => _commit(),
                onChanged: (String _) => setState(() {}),
                hintText: 'https://fleet.example.com',
              ),
              const SizedBox(height: 12),
              _label('FLEET TOKEN'),
              const SizedBox(height: 6),
              ConsoleField(
                controller: _token,
                focusNode: _tokenFocus,
                monospace: true,
                fontSize: 12,
                textInputAction: TextInputAction.done,
                onSubmitted: (String _) => _commit(),
                onChanged: (String _) => setState(() {}),
                hintText: 'stored encrypted, like every other token here',
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Opacity(
                    // Disabled rather than hidden: the button is what tells the
                    // user a check is possible at all, and a control that
                    // disappears once an address is half-typed reads as a bug.
                    opacity: configured && !_checking ? 1 : .4,
                    child: ConsoleChip(
                      label: _checking ? 'CHECKING…' : 'CHECK',
                      selected: false,
                      onSelected: configured && !_checking ? _check : () {},
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (_urlDirty || _tokenDirty)
                    Text(
                      'UNSAVED',
                      style: ConsoleText.micro.copyWith(color: Console.amber),
                    ),
                ],
              ),
              if (_checked != null) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  _checked!,
                  style: ConsoleText.micro.copyWith(color: Console.accent),
                ),
              ],
              if (_checkError != null) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  _checkError!,
                  style: ConsoleText.micro.copyWith(color: Console.red),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _label(String text) =>
      Text(text, style: ConsoleText.micro.copyWith(color: Console.dimText));
}
