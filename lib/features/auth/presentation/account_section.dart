import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../sync/data/e2ee_service.dart';
import '../../sync/presentation/e2ee_passphrase_dialog.dart';
import '../domain/auth_identity.dart';
import 'auth_controller.dart';

class AccountSection extends StatelessWidget {
  const AccountSection({super.key, this.controller, this.e2ee});

  final AuthController? controller;

  /// The signed-in account's end-to-end encryption key, when Supabase is
  /// configured: the card shows whether this device holds it and offers
  /// the passphrase flow, LOCK and FORGET KEY. Null hides the whole block.
  final E2eeService? e2ee;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(title: 'SUPABASE ACCOUNT'),
        const SizedBox(height: 12),
        if (controller case final AuthController auth)
          AnimatedBuilder(
            animation: auth,
            builder: (BuildContext context, Widget? _) =>
                _AccountCard(auth, e2ee: e2ee),
          )
        else
          _UnavailableCard(),
      ],
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard(this.controller, {this.e2ee});

  final AuthController controller;
  final E2eeService? e2ee;

  @override
  Widget build(BuildContext context) {
    final AuthIdentity? identity = controller.identity;
    return ConsoleCard(
      // The primary cloud block once signed in — same accent-on-active
      // treatment the Capture & AI tab's transcription card uses, so the two
      // "this is the thing that matters" cards read the same way.
      accent: identity == null ? Console.border : Console.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (identity == null) ...<Widget>[
            InfoRow(
              label: 'STATUS',
              value: 'SIGNED OUT',
              valueColor: Console.amber,
            ),
            const SizedBox(height: 8),
            Text(
              'Sign in with the Google account that will own this library. '
              'Local capture remains available while signed out.',
              style: ConsoleText.body.copyWith(color: Console.mutedSoft),
            ),
          ] else ...<Widget>[
            InfoRow(
              label: 'STATUS',
              value: 'SIGNED IN',
              valueColor: Console.green,
            ),
            InfoRow(label: 'ACCOUNT', value: identity.email),
            InfoRow(label: 'OWNER ID', value: identity.id, monospace: true),
            if (e2ee case final E2eeService e2ee)
              ListenableBuilder(
                listenable: e2ee,
                builder: (BuildContext context, Widget? _) =>
                    _EncryptionRows(e2ee: e2ee, ownerId: identity.id),
              ),
          ],
          if (controller.error case final String error) ...<Widget>[
            const SizedBox(height: 10),
            ErrorBanner(message: error),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: identity == null
                ? FilledButton.icon(
                    onPressed: controller.isBusy
                        ? null
                        : controller.signInWithGoogle,
                    icon: const Icon(Icons.login_rounded, size: 17),
                    label: Text(
                      controller.isBusy
                          ? 'OPENING GOOGLE…'
                          : 'CONTINUE WITH GOOGLE',
                    ),
                  )
                : TextButton.icon(
                    onPressed: controller.isBusy ? null : controller.signOut,
                    icon: const Icon(Icons.logout_rounded, size: 17),
                    label: Text(
                      controller.isBusy ? 'SIGNING OUT…' : 'SIGN OUT',
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// ENCRYPTION row plus its actions. Set-up and unlock open the same dialog
/// the Queue's banner does; LOCK drops the key from memory for this session;
/// FORGET KEY removes it from this device's keyring as well, after a
/// confirmation that says the passphrase is the only way back in.
class _EncryptionRows extends StatelessWidget {
  _EncryptionRows({required this.e2ee, required this.ownerId});

  final E2eeService e2ee;
  final String ownerId;

  static const String forgetWarning =
      'The encryption key is removed from this device only. Cloud sync stays '
      'paused until you unlock again with your passphrase; without it, the '
      'encrypted notes and recordings cannot be read on this device.';

  @override
  Widget build(BuildContext context) {
    final bool settled = e2ee.hasIdentity && !e2ee.isRestoring;
    final (String value, Color color) = switch (e2ee) {
      E2eeService(isUnlocked: true) => ('END-TO-END, UNLOCKED', Console.green),
      _ when !settled => ('CHECKING…', Console.muted),
      E2eeService(isLocked: true, keyOnServer: null) =>
        ('LOCKED, SERVER NOT REACHED', Console.red),
      E2eeService(isLocked: true) => ('LOCKED ON THIS DEVICE', Console.red),
      _ => ('NOT SET UP', Console.red),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        InfoRow(label: 'ENCRYPTION', value: value, valueColor: color),
        if (settled)
          Wrap(
            spacing: 4,
            children: <Widget>[
              if (e2ee.isUnlocked)
                TextButton.icon(
                  onPressed: e2ee.lock,
                  icon: const Icon(Icons.lock_outline_rounded, size: 16),
                  label: const Text('LOCK'),
                )
              else
                TextButton.icon(
                  onPressed: () => showE2eePassphraseDialog(context, e2ee),
                  icon: Icon(
                    e2ee.isLocked
                        ? Icons.lock_open_rounded
                        : Icons.enhanced_encryption_rounded,
                    size: 16,
                  ),
                  label: Text(e2ee.isLocked ? 'UNLOCK' : 'SET UP ENCRYPTION'),
                ),
              if (e2ee.isUnlocked || e2ee.keyOnServer == true)
                TextButton.icon(
                  onPressed: () => _forget(context),
                  icon: const Icon(Icons.delete_outline_rounded, size: 16),
                  label: const Text('FORGET KEY'),
                  style: TextButton.styleFrom(foregroundColor: Console.red),
                ),
            ],
          ),
      ],
    );
  }

  Future<void> _forget(BuildContext context) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Forget the encryption key on this device?',
      message: forgetWarning,
      confirmLabel: 'FORGET KEY',
    );
    if (!confirmed) return;
    try {
      await e2ee.forgetKey(userId: ownerId);
    } catch (_) {
      // `forgetKey` locks before it touches the keyring, so the device is
      // locked either way; a keyring that refuses the delete is the next
      // launch's problem, and this card has no error slot of its own.
    }
  }
}

class _UnavailableCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InfoRow(
            label: 'STATUS',
            value: 'CLOUD ACCOUNT UNAVAILABLE',
            valueColor: Console.muted,
          ),
          const SizedBox(height: 8),
          Text(
            'This build has no valid Supabase public configuration. '
            'Local capture remains available.',
            style: ConsoleText.body.copyWith(color: Console.mutedSoft),
          ),
        ],
      ),
    );
  }
}
