import 'dart:convert';

import 'commitment.dart';
import 'recording.dart';

/// One open commitment and the capture it came from.
class CommitmentEntry {
  const CommitmentEntry(this.recording, this.commitment);

  final Recording recording;
  final Commitment commitment;
}

/// Every open commitment across [recordings], soonest due first. Undated ones
/// follow the dated ones, newest capture first, since nothing else ranks them.
List<CommitmentEntry> openCommitments(Iterable<Recording> recordings) {
  final List<CommitmentEntry> entries = <CommitmentEntry>[
    for (final Recording recording in recordings)
      for (final Commitment commitment
          in recording.commitments ?? const <Commitment>[])
        if (commitment.isOpen) CommitmentEntry(recording, commitment),
  ];
  entries.sort((CommitmentEntry a, CommitmentEntry b) {
    final DateTime? ad = a.commitment.due;
    final DateTime? bd = b.commitment.due;
    if (ad != null && bd != null) {
      final int byDue = ad.compareTo(bd);
      if (byDue != 0) return byDue;
    } else if (ad != null) {
      return -1;
    } else if (bd != null) {
      return 1;
    }
    return b.recording.createdAt.compareTo(a.recording.createdAt);
  });
  return entries;
}

/// A single-item iCalendar file for [commitment], for the user's own calendar
/// or reminders app to import — no calendar API, no token.
///
/// A dated commitment becomes an all-day `VEVENT` on its due date, which every
/// calendar imports; an undated one becomes a `VTODO`, since an event needs a
/// day. [stamp] is the `DTSTAMP` and is injected so the output is testable.
String commitmentToIcs(
  Commitment commitment, {
  required String recordingId,
  required DateTime stamp,
  String? captureTitle,
}) {
  final DateTime? due = commitment.due;
  final String component = due == null ? 'VTODO' : 'VEVENT';
  final String uid =
      '${_uidSafe(recordingId)}-${_fnv1a(commitment.key)}'
      '@capture.augustyniak.ai';
  final List<String> description = <String>[
    if (commitment.who != null) 'With: ${commitment.who}',
    if (captureTitle != null && captureTitle.trim().isNotEmpty)
      'From capture: ${captureTitle.trim()}',
  ];
  final List<String> lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Augustyniak Capture//Commitments//EN',
    'CALSCALE:GREGORIAN',
    'BEGIN:$component',
    'UID:$uid',
    'DTSTAMP:${_utcStamp(stamp)}',
    'SUMMARY:${_escape(commitment.text)}',
    if (description.isNotEmpty)
      'DESCRIPTION:${_escape(description.join('\n'))}',
    if (due != null) ...<String>[
      'DTSTART;VALUE=DATE:${_date(due)}',
      'DTEND;VALUE=DATE:${_date(DateTime(due.year, due.month, due.day + 1))}',
    ],
    'END:$component',
    'END:VCALENDAR',
  ];
  return '${lines.map(_fold).join('\r\n')}\r\n';
}

/// FNV-1a over the UTF-8 bytes: stable across runs and platforms, unlike
/// `String.hashCode`, so re-exporting the same commitment updates the event
/// a calendar already imported instead of adding a second one.
String _fnv1a(String value) {
  int hash = 0x811c9dc5;
  for (final int byte in utf8.encode(value)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String _uidSafe(String value) => value.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '');

String _date(DateTime date) => Commitment.formatDate(date).replaceAll('-', '');

String _utcStamp(DateTime stamp) {
  final DateTime utc = stamp.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${_date(utc)}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
}

/// RFC 5545 §3.3.11 TEXT escaping.
String _escape(String value) => value
    .replaceAll('\\', r'\\')
    .replaceAll(';', r'\;')
    .replaceAll(',', r'\,')
    .replaceAll(RegExp(r'\r\n|\n|\r'), r'\n');

/// RFC 5545 §3.1: lines longer than 75 octets are folded with CRLF + space,
/// and never inside a multi-byte UTF-8 sequence.
String _fold(String line) {
  if (utf8.encode(line).length <= 75) return line;
  final StringBuffer out = StringBuffer();
  int octets = 0;
  // The first line may hold 75 octets; a continuation spends one on its space.
  for (final int rune in line.runes) {
    final String char = String.fromCharCode(rune);
    final int size = utf8.encode(char).length;
    if (octets + size > 75) {
      out.write('\r\n ');
      octets = 1;
    }
    out.write(char);
    octets += size;
  }
  return out.toString();
}
