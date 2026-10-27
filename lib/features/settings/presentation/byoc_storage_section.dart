import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../sync/data/s3_media_store.dart';
import 'settings_controller.dart';

class ByocStorageSection extends StatefulWidget {
  const ByocStorageSection({super.key, required this.controller});

  final SettingsController controller;

  @override
  State<ByocStorageSection> createState() => _ByocStorageSectionState();
}

class _ByocStorageSectionState extends State<ByocStorageSection> {
  late final TextEditingController _endpoint = TextEditingController(text: _storedEndpoint);
  late final TextEditingController _bucket = TextEditingController(text: _storedBucket);
  late final TextEditingController _region = TextEditingController(text: _storedRegion);
  late final TextEditingController _accessKeyId = TextEditingController(text: _storedAccessKeyId);
  late final TextEditingController _secretAccessKey = TextEditingController(text: _storedSecretAccessKey);
  late final TextEditingController _prefix = TextEditingController(text: _storedPrefix);

  final FocusNode _endpointFocus = FocusNode();
  final FocusNode _bucketFocus = FocusNode();
  final FocusNode _regionFocus = FocusNode();
  final FocusNode _accessKeyIdFocus = FocusNode();
  final FocusNode _secretAccessKeyFocus = FocusNode();
  final FocusNode _prefixFocus = FocusNode();

  late String _syncedEndpoint = _storedEndpoint;
  late String _syncedBucket = _storedBucket;
  late String _syncedRegion = _storedRegion;
  late String _syncedAccessKeyId = _storedAccessKeyId;
  late String _syncedSecretAccessKey = _storedSecretAccessKey;
  late String _syncedPrefix = _storedPrefix;

  String? _checked;
  String? _checkError;
  bool _checking = false;

  String get _storedEndpoint => widget.controller.settings.s3Endpoint ?? '';
  String get _storedBucket => widget.controller.settings.s3Bucket ?? '';
  String get _storedRegion => widget.controller.settings.s3Region ?? '';
  String get _storedAccessKeyId => widget.controller.settings.s3AccessKeyId ?? '';
  String get _storedSecretAccessKey => widget.controller.settings.s3SecretAccessKey ?? '';
  String get _storedPrefix => widget.controller.settings.s3Prefix ?? '';

  bool get _endpointDirty => _endpoint.text.trim() != _syncedEndpoint.trim();
  bool get _bucketDirty => _bucket.text.trim() != _syncedBucket.trim();
  bool get _regionDirty => _region.text.trim() != _syncedRegion.trim();
  bool get _accessKeyIdDirty => _accessKeyId.text.trim() != _syncedAccessKeyId.trim();
  bool get _secretAccessKeyDirty => _secretAccessKey.text.trim() != _syncedSecretAccessKey.trim();
  bool get _prefixDirty => _prefix.text.trim() != _syncedPrefix.trim();

  bool get _isDirty =>
      _endpointDirty ||
      _bucketDirty ||
      _regionDirty ||
      _accessKeyIdDirty ||
      _secretAccessKeyDirty ||
      _prefixDirty;

  @override
  void initState() {
    super.initState();
    _endpointFocus.addListener(_onFocusChange);
    _bucketFocus.addListener(_onFocusChange);
    _regionFocus.addListener(_onFocusChange);
    _accessKeyIdFocus.addListener(_onFocusChange);
    _secretAccessKeyFocus.addListener(_onFocusChange);
    _prefixFocus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_endpointFocus.hasFocus &&
        !_bucketFocus.hasFocus &&
        !_regionFocus.hasFocus &&
        !_accessKeyIdFocus.hasFocus &&
        !_secretAccessKeyFocus.hasFocus &&
        !_prefixFocus.hasFocus &&
        _isDirty) {
      _commit();
    }
  }

  @override
  void didUpdateWidget(ByocStorageSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_storedEndpoint != _syncedEndpoint && !_endpointDirty) {
      _syncedEndpoint = _storedEndpoint;
      _endpoint.text = _syncedEndpoint;
    }
    if (_storedBucket != _syncedBucket && !_bucketDirty) {
      _syncedBucket = _storedBucket;
      _bucket.text = _syncedBucket;
    }
    if (_storedRegion != _syncedRegion && !_regionDirty) {
      _syncedRegion = _storedRegion;
      _region.text = _syncedRegion;
    }
    if (_storedAccessKeyId != _syncedAccessKeyId && !_accessKeyIdDirty) {
      _syncedAccessKeyId = _storedAccessKeyId;
      _accessKeyId.text = _syncedAccessKeyId;
    }
    if (_storedSecretAccessKey != _syncedSecretAccessKey && !_secretAccessKeyDirty) {
      _syncedSecretAccessKey = _storedSecretAccessKey;
      _secretAccessKey.text = _syncedSecretAccessKey;
    }
    if (_storedPrefix != _syncedPrefix && !_prefixDirty) {
      _syncedPrefix = _storedPrefix;
      _prefix.text = _syncedPrefix;
    }
  }

  @override
  void dispose() {
    _endpointFocus.dispose();
    _bucketFocus.dispose();
    _regionFocus.dispose();
    _accessKeyIdFocus.dispose();
    _secretAccessKeyFocus.dispose();
    _prefixFocus.dispose();

    _endpoint.dispose();
    _bucket.dispose();
    _region.dispose();
    _accessKeyId.dispose();
    _secretAccessKey.dispose();
    _prefix.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final String endpoint = _endpoint.text.trim();
    final String bucket = _bucket.text.trim();
    final String region = _region.text.trim();
    final String accessKeyId = _accessKeyId.text.trim();
    final String secretAccessKey = _secretAccessKey.text.trim();
    final String prefix = _prefix.text.trim();

    setState(() {
      _syncedEndpoint = endpoint;
      _syncedBucket = bucket;
      _syncedRegion = region;
      _syncedAccessKeyId = accessKeyId;
      _syncedSecretAccessKey = secretAccessKey;
      _syncedPrefix = prefix;
      _checked = null;
      _checkError = null;
    });

    await widget.controller.updateS3Storage(
      endpoint: endpoint,
      bucket: bucket,
      region: region,
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      prefix: prefix,
    );
  }

  Future<void> _check() async {
    if (_checking) return;
    if (_isDirty) await _commit();

    final settings = widget.controller.settings;
    if (!settings.hasCustomS3Storage) {
      setState(() {
        _checkError = 'Please fill in all required fields (Endpoint, Bucket, Access Key, Secret Key).';
        _checked = null;
      });
      return;
    }

    setState(() {
      _checking = true;
      _checked = null;
      _checkError = null;
    });

    try {
      final store = S3MediaStore(
        endpoint: settings.s3Endpoint!,
        bucket: settings.s3Bucket!,
        accessKeyId: settings.s3AccessKeyId!,
        secretAccessKey: settings.usableS3SecretAccessKey ?? '',
        region: settings.s3Region?.trim().isNotEmpty == true ? settings.s3Region! : 'auto',
        prefix: settings.s3Prefix?.trim().isNotEmpty == true ? settings.s3Prefix! : null,
      );
      
      await store.exists('healthcheck.probe').timeout(const Duration(seconds: 10));
      
      if (!mounted) return;
      setState(() {
        _checked = 'Connected';
      });
    } catch (exception) {
      if (!mounted) return;
      setState(() => _checkError = exception.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _clear() async {
    await widget.controller.clearS3Storage();
    if (!mounted) return;
    setState(() {
      _endpoint.clear();
      _bucket.clear();
      _region.clear();
      _accessKeyId.clear();
      _secretAccessKey.clear();
      _prefix.clear();
      _checked = null;
      _checkError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool configured = widget.controller.settings.hasCustomS3Storage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(title: 'BYOC S3 STORAGE'),
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
                      'Store media files on your own S3-compatible storage. '
                      'Requires an endpoint, bucket, access key ID, and secret access key.',
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
              _label('ENDPOINT *'),
              const SizedBox(height: 6),
              ConsoleField(
                controller: _endpoint,
                focusNode: _endpointFocus,
                monospace: true,
                fontSize: 12,
                textInputAction: TextInputAction.next,
                onSubmitted: (String _) => _commit(),
                onChanged: (String _) => setState(() {}),
                hintText: 'https://<account>.r2.cloudflarestorage.com',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _label('BUCKET *'),
                        const SizedBox(height: 6),
                        ConsoleField(
                          controller: _bucket,
                          focusNode: _bucketFocus,
                          monospace: true,
                          fontSize: 12,
                          textInputAction: TextInputAction.next,
                          onSubmitted: (String _) => _commit(),
                          onChanged: (String _) => setState(() {}),
                          hintText: 'my-bucket',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _label('REGION'),
                        const SizedBox(height: 6),
                        ConsoleField(
                          controller: _region,
                          focusNode: _regionFocus,
                          monospace: true,
                          fontSize: 12,
                          textInputAction: TextInputAction.next,
                          onSubmitted: (String _) => _commit(),
                          onChanged: (String _) => setState(() {}),
                          hintText: 'auto',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _label('ACCESS KEY ID *'),
              const SizedBox(height: 6),
              ConsoleField(
                controller: _accessKeyId,
                focusNode: _accessKeyIdFocus,
                monospace: true,
                fontSize: 12,
                textInputAction: TextInputAction.next,
                onSubmitted: (String _) => _commit(),
                onChanged: (String _) => setState(() {}),
              ),
              const SizedBox(height: 12),
              _label('SECRET ACCESS KEY *'),
              const SizedBox(height: 6),
              ConsoleField(
                controller: _secretAccessKey,
                focusNode: _secretAccessKeyFocus,
                monospace: true,
                fontSize: 12,
                textInputAction: TextInputAction.next,
                onSubmitted: (String _) => _commit(),
                onChanged: (String _) => setState(() {}),
                hintText: 'stored encrypted, like every other token here',
              ),
              const SizedBox(height: 12),
              _label('PREFIX (Optional)'),
              const SizedBox(height: 6),
              ConsoleField(
                controller: _prefix,
                focusNode: _prefixFocus,
                monospace: true,
                fontSize: 12,
                textInputAction: TextInputAction.done,
                onSubmitted: (String _) => _commit(),
                onChanged: (String _) => setState(() {}),
                hintText: 'capture/',
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Opacity(
                    opacity: configured && !_checking ? 1 : .4,
                    child: ConsoleChip(
                      label: _checking ? 'TESTING…' : 'TEST CONNECTION',
                      selected: false,
                      onSelected: configured && !_checking ? _check : () {},
                    ),
                  ),
                  const SizedBox(width: 10),
                  ConsoleChip(
                    label: 'CLEAR S3 CONFIG',
                    selected: false,
                    onSelected: _clear,
                  ),
                  const SizedBox(width: 10),
                  if (_isDirty)
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
