import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../../core/sync/cloud_sync_coordinator.dart';
import '../../../core/sync/r2_media_sync_service.dart';
import '../../../core/sync/sync_defaults.dart';
import '../../../core/sync/sync_endpoint.dart';
import '../../recordings/presentation/recordings_controller.dart';
import 'qr_sync_sheet.dart';
import 'settings_controller.dart';

/// Turso + Cloudflare R2, demoted beneath the Supabase account card in the
/// Sync & Cloud sub-tab. Supabase Auth (#187) carries sign-in only — no data
/// sync yet — so these two still do the only syncing that actually happens,
/// and every control here (both edit dialogs, the status rows, sealed-key
/// handling, the pairing flow) stays fully reachable. Only the visual weight
/// changes: one section header instead of three page-level ones, and a
/// small in-card label naming each provider where a `SectionHeader` used to.
class LegacySyncSection extends StatelessWidget {
  LegacySyncSection({
    super.key,
    required this.controller,
    required this.recordingsController,
    required this.report,
    required this.hasTurso,
    required this.hasR2,
    required this.tursoSealed,
    required this.r2Sealed,
  });

  final SettingsController controller;
  final RecordingsController? recordingsController;
  final CloudSyncReport? report;
  final bool hasTurso;
  final bool hasR2;
  final bool tursoSealed;
  final bool r2Sealed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(title: 'LEGACY SYNC', trailing: 'TURSO + R2'),
        const SizedBox(height: 6),
        Text(
          'Metadata syncs through Turso, capture files through Cloudflare '
          'R2. The Supabase account above carries sign-in only — it does not '
          'sync captures yet.',
          style: ConsoleText.hint,
        ),
        const SizedBox(height: 12),
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Synchronize metadata with Turso and capture files with '
                'Cloudflare R2 in one pass.',
                style: ConsoleText.body.copyWith(color: Console.mutedSoft),
              ),
              if (report case final CloudSyncReport r) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  r.message,
                  style: ConsoleText.body.copyWith(
                    color: r.success
                        ? Console.green
                        : r.partialSuccess
                        ? Console.amber
                        : Console.red,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Last attempt · ${_formatSyncTime(r.completedAt)}',
                  style: ConsoleText.micro.copyWith(color: Console.mutedSoft),
                ),
              ],
              // Why the action below is dead, on the card that owns it. The
              // same detection drives the Models tab's banner, but a user
              // whose sync stopped has no reason to go looking there.
              if (controller.syncSecretsUnreadable) ...<Widget>[
                const SizedBox(height: 10),
                ErrorBanner(
                  message:
                      'The stored sync credentials cannot be decrypted — the '
                      'master key was unreachable this launch, so cloud sync '
                      'is off even though every field below is set. '
                      'Re-enter the Turso token and the R2 secret access '
                      'key, or pair this device by QR, to store readable '
                      'copies.'
                      '${controller.tokenEncryptionIssue == null ? '' : '\n${controller.tokenEncryptionIssue}'}',
                ),
              ],
              const SizedBox(height: 12),
              _SyncNowButton(
                recordingsController: recordingsController,
                hasTurso: hasTurso,
                hasR2: hasR2,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('TURSO', style: ConsoleText.fieldLabel),
              const SizedBox(height: 10),
              InfoRow(
                label: 'DATABASE URL',
                value: controller.settings.tursoDbUrl ?? 'Not configured',
                valueColor: Console.accent,
                monospace: true,
              ),
              InfoRow(
                label: 'SYNC STATUS',
                value: tursoSealed
                    ? 'ENCRYPTED · Key unreachable'
                    : !hasTurso
                    ? 'DISABLED'
                    : report?.turso?.success == true
                    ? 'CONNECTED · Last sync succeeded'
                    : report?.turso?.success == false
                    ? 'ERROR · See sync result above'
                    // The resting state of a working install, not a warning
                    // — everything is set and there is simply nothing to
                    // report yet.
                    : 'CONFIGURED · Ready',
                valueColor: tursoSealed
                    ? Console.red
                    : !hasTurso
                    ? Console.mutedSoft
                    : report?.turso?.success == true
                    ? Console.green
                    : report?.turso?.success == false
                    ? Console.red
                    : Console.text,
              ),
              InfoRow(
                label: 'API TOKEN',
                value: controller.settings.tursoAuthToken != null
                    ? '•••• Encrypted at rest (AES-GCM)'
                    : 'Not set',
              ),
              const SizedBox(height: 8),
              Text(
                'Your SQLite database is synced with Turso Cloud Embedded '
                'Replica. Mobile, desktop, and web instances share '
                'real-time captures, clipboard, projects, and settings.',
                style: ConsoleText.hint,
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.edit, size: 14),
                  label: const Text('EDIT TURSO CREDENTIALS'),
                  style: TextButton.styleFrom(foregroundColor: Console.accent),
                  onPressed: () => _showEditTursoDialog(context, controller),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('CLOUDFLARE R2', style: ConsoleText.fieldLabel),
              const SizedBox(height: 10),
              InfoRow(
                label: 'BUCKET NAME',
                value: controller.settings.r2Bucket ?? 'Not configured',
                valueColor: Console.accent,
                monospace: true,
              ),
              InfoRow(
                label: 'MEDIA SYNC',
                value: r2Sealed
                    ? 'ENCRYPTED · Key unreachable'
                    : !hasR2
                    ? 'DISABLED'
                    : report?.r2?.success == true
                    ? 'CONNECTED · ${_r2Counts(report!.r2!)}'
                    : report?.r2?.success == false
                    ? 'ERROR · See sync result above'
                    : 'CONFIGURED · Ready',
                valueColor: r2Sealed
                    ? Console.red
                    : !hasR2
                    ? Console.mutedSoft
                    : report?.r2?.success == true
                    ? Console.green
                    : report?.r2?.success == false
                    ? Console.red
                    : Console.text,
              ),
              InfoRow(
                label: 'SECRET ACCESS KEY',
                value: controller.settings.r2SecretAccessKey != null
                    ? '•••• Encrypted at rest (AES-GCM)'
                    : 'Not set',
              ),
              const SizedBox(height: 8),
              Text(
                'Audio recordings (.m4a) and image captures are synced with '
                'Cloudflare R2 S3 Object Storage with zero bandwidth fees. '
                'Seamless streaming on mobile and desktop.',
                style: ConsoleText.hint,
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.edit, size: 14),
                  label: const Text('EDIT R2 CREDENTIALS'),
                  style: TextButton.styleFrom(foregroundColor: Console.accent),
                  onPressed: () => _showEditR2Dialog(context, controller),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // Pairs both Turso and R2 in one scan, so it belongs to the section
        // rather than to either card — it used to live inside the R2 card,
        // which made a Turso-only install's pairing button look like an R2
        // feature.
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.qr_code, size: 16),
            label: const Text('PAIR DEVICE VIA QR CODE'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Console.accent,
              foregroundColor: Console.ink,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: () => _pairDevice(context),
          ),
        ),
      ],
    );
  }

  void _pairDevice(BuildContext context) {
    final bool isMobile =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    if (isMobile) {
      Navigator.of(context).push(
        MaterialPageRoute<bool>(
          builder: (_) => QrSyncScannerSheet(
            controller: controller,
            recordingsController: recordingsController,
          ),
        ),
      );
    } else {
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Console.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => QrSyncDisplaySheet(settings: controller.settings),
      );
    }
  }
}

Future<void> _showEditTursoDialog(
  BuildContext context,
  SettingsController controller,
) async {
  final TextEditingController urlCtrl = TextEditingController(
    text: controller.settings.tursoDbUrl ?? SyncDefaults.tursoDbUrl ?? '',
  );
  final TextEditingController tokenCtrl = TextEditingController(
    text:
        controller.settings.tursoAuthToken ?? SyncDefaults.tursoAuthToken ?? '',
  );

  String? error;

  await showDialog<void>(
    context: context,
    builder: (BuildContext ctx) {
      return StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setDialogState) => AlertDialog(
          backgroundColor: Console.surface,
          title: const Text('Edit Turso Cloud Credentials'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'Turso Database URL',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tokenCtrl,
                decoration: const InputDecoration(labelText: 'Turso Auth Token'),
                maxLines: 3,
              ),
              if (error != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  error!,
                  style: ConsoleText.body.copyWith(color: Console.red),
                ),
              ],
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final String url = urlCtrl.text.trim();
                final String token = tokenCtrl.text.trim();

                // Refused *before* anything is stored, and inline rather than
                // as a failed sync afterwards: an `http://` address would
                // carry the bearer token and every transcript in the batch in
                // the clear, and `TursoSyncService` now declines it silently
                // at the point where the only visible symptom is "sync does
                // nothing".
                if (url.isNotEmpty && SyncEndpoint.normalize(url) == null) {
                  setDialogState(() {
                    error =
                        'The database URL must be an https:// or libsql:// '
                        'address with a host.';
                  });
                  return;
                }

                await controller.setTursoConfig(
                  url: url.isNotEmpty ? url : null,
                  token: token.isNotEmpty ? token : null,
                  enabled: url.isNotEmpty && token.isNotEmpty,
                );

                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      );
    },
  );
}

Future<void> _showEditR2Dialog(
  BuildContext context,
  SettingsController controller,
) async {
  final TextEditingController bucketCtrl = TextEditingController(
    text: controller.settings.r2Bucket ?? SyncDefaults.r2Bucket ?? '',
  );
  final TextEditingController endpointCtrl = TextEditingController(
    text: controller.settings.r2Endpoint ?? SyncDefaults.r2Endpoint ?? '',
  );
  final TextEditingController keyIdCtrl = TextEditingController(
    text: controller.settings.r2AccessKeyId ?? SyncDefaults.r2AccessKeyId ?? '',
  );
  final TextEditingController secretCtrl = TextEditingController(
    text:
        controller.settings.r2SecretAccessKey ??
        SyncDefaults.r2SecretAccessKey ??
        '',
  );

  await showDialog<void>(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        backgroundColor: Console.surface,
        title: const Text('Edit Cloudflare R2 Credentials'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: bucketCtrl,
                decoration: const InputDecoration(labelText: 'R2 Bucket Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: endpointCtrl,
                decoration: const InputDecoration(labelText: 'S3 Endpoint URL'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: keyIdCtrl,
                decoration: const InputDecoration(labelText: 'Access Key ID'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: secretCtrl,
                decoration: const InputDecoration(
                  labelText: 'Secret Access Key',
                ),
                obscureText: true,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await controller.setR2Config(
                bucket: bucketCtrl.text.trim().isNotEmpty
                    ? bucketCtrl.text.trim()
                    : null,
                endpoint: endpointCtrl.text.trim().isNotEmpty
                    ? endpointCtrl.text.trim()
                    : null,
                accessKeyId: keyIdCtrl.text.trim().isNotEmpty
                    ? keyIdCtrl.text.trim()
                    : null,
                secretAccessKey: secretCtrl.text.trim().isNotEmpty
                    ? secretCtrl.text.trim()
                    : null,
                enabled:
                    bucketCtrl.text.trim().isNotEmpty &&
                    secretCtrl.text.trim().isNotEmpty,
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
}

class _SyncNowButton extends StatefulWidget {
  const _SyncNowButton({
    required this.recordingsController,
    required this.hasTurso,
    required this.hasR2,
  });

  final RecordingsController? recordingsController;
  final bool hasTurso;
  final bool hasR2;

  @override
  State<_SyncNowButton> createState() => _SyncNowButtonState();
}

class _SyncNowButtonState extends State<_SyncNowButton> {
  bool _isSyncing = false;

  @override
  Widget build(BuildContext context) {
    final String label = switch ((widget.hasTurso, widget.hasR2)) {
      (true, true) => 'SYNC NOW',
      (true, false) => 'SYNC TURSO',
      (false, true) => 'SYNC MEDIA',
      (false, false) => 'CONFIGURE SYNC',
    };
    final bool canSync =
        widget.recordingsController != null &&
        (widget.hasTurso || widget.hasR2);
    return ElevatedButton.icon(
      icon: SyncSpinIcon(isSyncing: _isSyncing, size: 14, color: Console.ink),
      label: Text(_isSyncing ? 'SYNCING…' : label),
      style: ElevatedButton.styleFrom(
        backgroundColor: Console.green,
        foregroundColor: Console.ink,
        // No disabled overrides on purpose. Painting the disabled state in a
        // derived green with black text made a dead button indistinguishable
        // from a live one — it even keeps its ripple — so the only signal
        // left was the label, and CONFIGURE SYNC reads as an invitation to
        // tap. The theme's default disabled treatment is the whole fix.
      ),
      onPressed: _isSyncing || !canSync
          ? null
          : () async {
              setState(() => _isSyncing = true);
              try {
                final CloudSyncReport report = await widget
                    .recordingsController!
                    .syncCloud();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(report.message),
                      backgroundColor: report.success
                          ? Console.green
                          : report.partialSuccess
                          ? Console.amber
                          : Console.red,
                    ),
                  );
                }
              } finally {
                if (mounted) setState(() => _isSyncing = false);
              }
            },
    );
  }
}

String _r2Counts(R2SyncResult result) {
  final int total = result.uploaded + result.downloaded + result.unchanged;
  return '$total files reconciled';
}

String _formatSyncTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  final DateTime local = value.toLocal();
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
