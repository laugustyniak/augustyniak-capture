import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/auth_identity.dart';
import 'auth_controller.dart';

class AccountSection extends StatelessWidget {
  const AccountSection({super.key, this.controller});

  final AuthController? controller;

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
            builder: (BuildContext context, Widget? _) => _AccountCard(auth),
          )
        else
          _UnavailableCard(),
      ],
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard(this.controller);

  final AuthController controller;

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
