import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/ui_kit.dart';
import '../../../core/database/app_database.dart';
import '../../../core/sync/sync_defaults.dart';
import '../../../core/sync/sync_pairing_payload.dart';
import '../../../core/sync/turso_sync_service.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../domain/app_settings.dart';
import 'settings_controller.dart';
import 'sync_pairing_confirmation.dart';

/// Renders a QR code on Desktop for 1-tap mobile pairing.
class QrSyncDisplaySheet extends StatelessWidget {
  const QrSyncDisplaySheet({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> payload = <String, dynamic>{
      // The scanner refuses any other marker, so the two halves are pinned to
      // one constant rather than to two matching literals.
      'type': SyncPairingPayload.typeMarker,
      'tursoDbUrl': settings.tursoDbUrl ?? SyncDefaults.tursoDbUrl,
      'tursoAuthToken': settings.tursoAuthToken ?? SyncDefaults.tursoAuthToken,
      'r2Endpoint': settings.r2Endpoint ?? SyncDefaults.r2Endpoint,
      'r2Bucket': settings.r2Bucket ?? SyncDefaults.r2Bucket,
      'r2AccessKeyId': settings.r2AccessKeyId ?? SyncDefaults.r2AccessKeyId,
      'r2SecretAccessKey':
          settings.r2SecretAccessKey ?? SyncDefaults.r2SecretAccessKey,
    };
    final String jsonPayload = jsonEncode(payload);

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                'PAIRS WITH MOBILE',
                style: TextStyle(
                  color: Console.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, color: Console.mutedSoft),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: jsonPayload,
              version: QrVersions.auto,
              size: 220.0,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Scan this QR code from Augustyniak Capture on your mobile phone to instantly pair Turso Cloud & Cloudflare R2 media sync.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Console.muted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// Mobile scanner sheet to scan Desktop QR code and pair instantly.
class QrSyncScannerSheet extends StatefulWidget {
  const QrSyncScannerSheet({
    super.key,
    required this.controller,
    this.recordingsController,
  });

  final SettingsController controller;
  final RecordingsController? recordingsController;

  @override
  State<QrSyncScannerSheet> createState() => _QrSyncScannerSheetState();
}

class _QrSyncScannerSheetState extends State<QrSyncScannerSheet> {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _scanned = false;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  /// A scanned code is **parsed, then confirmed, then applied** — three steps
  /// that used to be one.
  ///
  /// A QR code is input from whatever is in front of the camera, and applying
  /// one repoints where every future capture is uploaded. So nothing is written
  /// until [confirmSyncPairing] has named the host and the user has agreed;
  /// [SyncPairingPayload.parse] refuses a code that would send the token over
  /// plain http before the question is even asked.
  void _onDetect(BarcodeCapture capture) async {
    if (_scanned) return;

    // The whole frame is examined before anything is awaited: a code that is
    // not ours, or one that would send the token over plain http, is simply
    // not a candidate, and there is nothing the user could do about being told.
    SyncPairingPayload? payload;
    for (final Barcode barcode in capture.barcodes) {
      final String? rawValue = barcode.rawValue;
      if (rawValue == null || rawValue.isEmpty) continue;
      payload = SyncPairingPayload.parse(rawValue);
      if (payload != null) break;
    }
    if (payload == null) return;

    // Taken before the confirmation, so a camera holding the code steady
    // cannot stack a second dialog on top of the first.
    setState(() => _scanned = true);

    final bool agreed = await confirmSyncPairing(context, payload);
    if (!agreed) {
      // Back to scanning. A refusal is a decision about *this* code, not a
      // reason to close the scanner.
      if (mounted) setState(() => _scanned = false);
      return;
    }

    await _applyPairing(payload);
  }

  Future<void> _applyPairing(SyncPairingPayload payload) async {
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    await widget.controller.setTursoConfig(
      url: payload.tursoDbUrl,
      token: payload.tursoAuthToken,
      enabled: true,
    );

    if (payload.hasR2) {
      await widget.controller.setR2Config(
        endpoint: payload.r2Endpoint,
        bucket: payload.r2Bucket,
        accessKeyId: payload.r2AccessKeyId,
        secretAccessKey: payload.r2SecretAccessKey,
        enabled: true,
      );
    }

    final AppDatabase db = await AppDatabase.getInstance();
    final TursoSyncService syncService = TursoSyncService(db: db);
    final bool pulled = await syncService.pullFromTurso(
      dbUrl: payload.tursoDbUrl,
      authToken: payload.tursoAuthToken,
    );
    await widget.recordingsController?.reloadFromStorage();
    final int count = widget.recordingsController?.recordings.length ?? 0;

    if (!mounted) return;
    navigator.pop(true);
    messenger.showSnackBar(
      SnackBar(
        // Counted rather than claimed. This line used to report a hard-coded
        // "103 notes" whatever happened, including when the pull failed.
        content: Text(
          pulled ? '⚡ Sync paired · $count notes' : 'Paired, but the pull failed',
        ),
        backgroundColor: pulled ? Console.green : Console.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan Sync QR Code'),
        backgroundColor: Colors.black,
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _scannerController.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _scannerController.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          MobileScanner(
            controller: _scannerController,
            onDetect: _onDetect,
          ),
          // Only a build that was given credentials at compile time can offer
          // to pair without scanning anything. Everyone else scans the desktop
          // QR code above, which is the path that does not need a secret in the
          // source tree.
          if (SyncDefaults.hasTurso)
            Positioned(
              bottom: 30,
              left: 20,
              right: 20,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.bolt, color: Colors.black),
                label: const Text('1-CLICK CONNECT DEFAULT CLOUD'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Console.accent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () async {
                  // Both taken before the first await. Pairing does a network
                  // round trip and a full storage reload, and the `context`
                  // reachable here belongs to the builder rather than to this
                  // State — so `mounted` says nothing about whether it is still
                  // valid afterwards. Holding the two states instead makes the
                  // question moot: neither is looked up across the gap.
                  final NavigatorState navigator = Navigator.of(context);
                  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(
                    context,
                  );
                  final String tursoUrl = SyncDefaults.tursoDbUrl!;
                  final String tursoToken = SyncDefaults.tursoAuthToken!;

                  await widget.controller.setTursoConfig(
                    url: tursoUrl,
                    token: tursoToken,
                    enabled: true,
                  );

                  if (SyncDefaults.r2Bucket != null) {
                    await widget.controller.setR2Config(
                      endpoint: SyncDefaults.r2Endpoint ?? '',
                      bucket: SyncDefaults.r2Bucket!,
                      accessKeyId: SyncDefaults.r2AccessKeyId ?? '',
                      secretAccessKey: SyncDefaults.r2SecretAccessKey ?? '',
                      enabled: true,
                    );
                  }

                  final AppDatabase db = await AppDatabase.getInstance();
                  final TursoSyncService syncService = TursoSyncService(db: db);
                  await syncService.pullFromTurso(
                    dbUrl: tursoUrl,
                    authToken: tursoToken,
                  );
                  await widget.recordingsController?.reloadFromStorage();
                  final int count =
                      widget.recordingsController?.recordings.length ?? 0;

                  if (mounted) {
                    navigator.pop(true);
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text('⚡ Sync paired · $count notes'),
                        backgroundColor: Console.green,
                      ),
                    );
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}
