import 'package:flutter/material.dart';

import 'dart:async';

import '../../../app/ui_kit.dart';
import '../data/e2ee_service.dart';
import '../domain/e2ee_settings_store.dart';

/// Opens the passphrase flow for the followed account: set-up when the
/// server has no key for it, unlock when it has one this device lacks.
/// Resolves when the dialog closes, whether or not a key was activated —
/// the caller reads `E2eeService.isUnlocked` rather than a return value,
/// since the service is what the rest of the screen already listens to.
Future<void> showE2eePassphraseDialog(BuildContext context, E2eeService e2ee) {
  return showDialog<void>(
    context: context,
    // CANCEL is the way out: a tap beside the dialog must not drop the UI
    // while a key is being derived and activated.
    barrierDismissible: false,
    builder: (BuildContext dialogContext) => E2eePassphraseDialog(e2ee: e2ee),
  );
}

/// Two shapes in one widget, because each can turn into the other: a
/// device that loses the race to publish the first key is told so and
/// switched to the unlock form with its passphrase field kept, and a
/// device that thought it was locked (the lookup had failed) and is told
/// by the server there is nothing to unlock is switched to set-up.
class E2eePassphraseDialog extends StatefulWidget {
  E2eePassphraseDialog({super.key, required this.e2ee});

  final E2eeService e2ee;

  /// Shown before set-up can complete, verbatim from the plan: nothing on
  /// the server can open an envelope, so there is nobody to ask.
  static const String lossWarning =
      'Augustyniak Capture cannot recover your passphrase. If you forget it, '
      'all encrypted notes and recordings will be lost permanently.';

  static const String unlockHint =
      'This account is encrypted. Enter the passphrase you set up on your '
      'other device; cloud sync stays paused until it matches.';

  static const String alreadySetUp =
      'Encryption was already set up on another device. Enter that '
      'passphrase to unlock this one.';

  static const String notSetUpYet =
      'Encryption is not set up for this account yet. Choose a passphrase.';

  static const String failed =
      'Could not reach the server. Check the connection and try again.';

  static const String tooShort = 'Use at least 8 characters.';
  static const String mismatch = 'The two passphrases differ.';

  static const int minLength = 8;

  @override
  State<E2eePassphraseDialog> createState() => _E2eePassphraseDialogState();
}

class _E2eePassphraseDialogState extends State<E2eePassphraseDialog> {
  final TextEditingController _passphrase = TextEditingController();
  final TextEditingController _repeat = TextEditingController();

  /// Decided once at open from `keyOnServer`: set-up only when the server
  /// confirmed there is no row. Unknown opens unlock, the same label the
  /// banner showed; `unlock` re-reads the row and, if there is none, the
  /// form becomes a set-up. Either direction is safe because set-up inserts
  /// and never overwrites.
  late bool _setUp = widget.e2ee.keyOnServer == false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    _repeat.dispose();
    super.dispose();
  }

  String? get _validation {
    if (_passphrase.text.length < E2eePassphraseDialog.minLength) {
      return E2eePassphraseDialog.tooShort;
    }
    if (_setUp && _repeat.text != _passphrase.text) {
      return E2eePassphraseDialog.mismatch;
    }
    return null;
  }

  Future<void> _submit() async {
    if (_busy || _validation != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_setUp) {
        await widget.e2ee.enroll(_passphrase.text);
      } else {
        await widget.e2ee.unlock(_passphrase.text);
      }
      if (mounted) Navigator.of(context).pop();
    } on E2eeSettingsConflictException {
      if (!mounted) return;
      setState(() {
        _setUp = false;
        _error = E2eePassphraseDialog.alreadySetUp;
      });
    } on E2eeNotSetUpException {
      if (!mounted) return;
      setState(() {
        _setUp = true;
        _error = E2eePassphraseDialog.notSetUpYet;
      });
    } on InvalidE2eePassphraseException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on StateError catch (error) {
      // The identity moved on under the dialog: nothing to retry here.
      if (mounted) setState(() => _error = error.message);
    } on TimeoutException {
      if (mounted) setState(() => _error = E2eePassphraseDialog.failed);
    } catch (_) {
      // A server error's text is not for this surface; the state the
      // service settled on (`keyOnServer`) is what the Queue reports.
      if (mounted) setState(() => _error = E2eePassphraseDialog.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? validation = _validation;
    final bool typed = _passphrase.text.isNotEmpty;
    return AlertDialog(
      backgroundColor: Console.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Console.border),
      ),
      title: Text(
        _setUp ? 'SET UP END-TO-END ENCRYPTION' : 'UNLOCK END-TO-END ENCRYPTION',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (_setUp)
              ErrorBanner(message: E2eePassphraseDialog.lossWarning)
            else
              Text(
                E2eePassphraseDialog.unlockHint,
                style: ConsoleText.body.copyWith(color: Console.mutedSoft),
              ),
            const SizedBox(height: 14),
            ConsoleField(
              controller: _passphrase,
              hintText: 'Passphrase',
              obscureText: true,
              autofocus: true,
              textInputAction: _setUp ? TextInputAction.next : TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: _setUp ? null : (_) => _submit(),
            ),
            if (_setUp) ...<Widget>[
              const SizedBox(height: 8),
              ConsoleField(
                controller: _repeat,
                hintText: 'Repeat passphrase',
                obscureText: true,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
            ],
            if (typed && validation != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                validation,
                style: ConsoleText.chip.copyWith(color: Console.amber),
              ),
            ],
            if (_error case final String error) ...<Widget>[
              const SizedBox(height: 10),
              ErrorBanner(message: error),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: _busy || validation != null ? null : _submit,
          child: Text(
            _busy
                ? (_setUp ? 'SETTING UP…' : 'UNLOCKING…')
                : (_setUp ? 'SET UP' : 'UNLOCK'),
          ),
        ),
      ],
    );
  }
}
