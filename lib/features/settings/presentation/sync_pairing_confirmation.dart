import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../../core/sync/sync_pairing_payload.dart';

/// Asks before a scanned pairing code is believed.
///
/// **Pairing is the one settings change this app takes from whatever happened
/// to be in front of the camera**, and it is not a small one: the address it
/// names receives every capture from then on, including the ones already in
/// the queue, and the code also hands over an R2 secret. A QR code on a poster,
/// on a screen, or in an image someone sends is enough to present one.
///
/// So the scanner's job ends at producing a [SyncPairingPayload]; this is where
/// a human decides. The dialog leads with the **host**, because that is the
/// only field in a pairing code a reader can evaluate — a token is opaque by
/// construction, and "sync configured" says nothing about whose sync it is.
///
/// Dismissal answers false. This app reserves dialogs for destructive
/// confirmation, and adopting somebody else's sync destination is squarely in
/// that class: it is not reversible for anything already uploaded.
Future<bool> confirmSyncPairing(
  BuildContext context,
  SyncPairingPayload payload,
) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      backgroundColor: Console.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Console.border),
      ),
      title: const Text(
        'Pair this device?',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Every capture on this device will be uploaded to, and replaced '
            'from, this database:',
            style: ConsoleText.body,
          ),
          const SizedBox(height: 12),
          Text(
            payload.host,
            style: _address,
          ),
          if (payload.hasR2) ...<Widget>[
            const SizedBox(height: 12),
            Text('Media files go to the bucket:', style: ConsoleText.body),
            const SizedBox(height: 4),
            Text(
              '${payload.r2Bucket}',
              style: _address,
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Only continue if this is your own code.',
            style: ConsoleText.body.copyWith(color: Console.muted),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: TextButton.styleFrom(foregroundColor: Console.accent),
          child: const Text('PAIR'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// The one line in the dialog the decision actually rests on. Mono and accent
/// for the same reason a status pill is: it is the machine fact among prose.
TextStyle get _address => TextStyle(
  fontFamily: ConsoleFont.mono,
  fontSize: 13,
  fontWeight: FontWeight.w600,
  color: Console.accent,
);
