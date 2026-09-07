import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Reads the installed bundle, never the checkout or a remote release.
class VersionFooter extends StatefulWidget {
  const VersionFooter({super.key});

  @override
  State<VersionFooter> createState() => _VersionFooterState();
}

class _VersionFooterState extends State<VersionFooter> {
  final Future<PackageInfo> _package = PackageInfo.fromPlatform();
  static const String _revision = String.fromEnvironment('APP_GIT_SHA');
  static final Uri _latest = Uri.parse(
    'https://github.com/laugustyniak/augustyniak-capture/releases/latest',
  );

  Future<void> _openLatest() async {
    try {
      if (await launchUrl(_latest, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {
      // The link remains available to copy when no browser can be opened.
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Could not open browser'),
        content: SelectableText(_latest.toString()),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        FutureBuilder<PackageInfo>(
          future: _package,
          builder: (BuildContext context, AsyncSnapshot<PackageInfo> snapshot) {
            final PackageInfo? info = snapshot.data;
            return SelectableText(
              info == null || info.version.isEmpty
                  ? snapshot.hasError || info != null
                        ? 'Installed version unavailable'
                        : 'Loading installed version…'
                  : 'Capture ${info.version} (build ${info.buildNumber})'
                        '${_revision.isEmpty ? '' : ' · $_revision'}',
              style: Theme.of(context).textTheme.bodySmall,
            );
          },
        ),
        TextButton.icon(
          onPressed: _openLatest,
          icon: const Icon(Icons.open_in_new, size: 14),
          label: const Text('Latest release & changelog'),
        ),
      ],
    );
  }
}
