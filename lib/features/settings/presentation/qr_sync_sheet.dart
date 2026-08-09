import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/ui_kit.dart';
import '../../../core/database/app_database.dart';
import '../../../core/sync/sync_defaults.dart';
import '../../../core/sync/turso_sync_service.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../domain/app_settings.dart';
import 'settings_controller.dart';

/// Renders a QR code on Desktop for 1-tap mobile pairing.
class QrSyncDisplaySheet extends StatelessWidget {
  const QrSyncDisplaySheet({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> payload = <String, dynamic>{
      'type': 'augustyniak_sync_v1',
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

  void _onDetect(BarcodeCapture capture) async {
    if (_scanned) return;
    for (final Barcode barcode in capture.barcodes) {
      final String? rawValue = barcode.rawValue;
      if (rawValue == null || rawValue.isEmpty) continue;

      try {
        final dynamic decoded = jsonDecode(rawValue);
        if (decoded is Map<String, dynamic> &&
            decoded['type'] == 'augustyniak_sync_v1') {
          setState(() {
            _scanned = true;
          });

          final String? tursoUrl = decoded['tursoDbUrl'] as String?;
          final String? tursoToken = decoded['tursoAuthToken'] as String?;

          await widget.controller.setTursoConfig(
            url: tursoUrl,
            token: tursoToken,
            enabled: true,
          );

          await widget.controller.setR2Config(
            endpoint: decoded['r2Endpoint'] as String?,
            bucket: decoded['r2Bucket'] as String?,
            accessKeyId: decoded['r2AccessKeyId'] as String?,
            secretAccessKey: decoded['r2SecretAccessKey'] as String?,
            enabled: true,
          );

          if (tursoUrl != null && tursoToken != null) {
            final AppDatabase db = await AppDatabase.getInstance();
            final TursoSyncService syncService = TursoSyncService(db: db);
            await syncService.pullFromTurso(
              dbUrl: tursoUrl,
              authToken: tursoToken,
            );
            await widget.recordingsController?.reloadFromStorage();
          }

          if (mounted) {
            Navigator.of(context).pop(true);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('⚡ Sync paired & 103 notes downloaded successfully!'),
                backgroundColor: Console.green,
              ),
            );
          }
          break;
        }
      } catch (_) {}
    }
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
