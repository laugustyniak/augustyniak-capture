import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/ui_kit.dart';
import '../../projects/data/native_agent_jobs.dart';
import '../../projects/domain/native_agent_types.dart';
import '../../projects/presentation/agent_jobs_sheet.dart';
import '../domain/recording.dart';
import '../domain/route_record.dart';

/// The local agent jobs a capture was handed to, newest first, one per id.
///
/// Read-only over the capture's routes: nothing here ever writes to the
/// [Recording] row, and a job that cannot be read costs one card, not a screen.
List<NativeAgentJobHandle> agentJobHandles(Recording recording) {
  final Set<String> seen = <String>{};
  return <NativeAgentJobHandle>[
    for (final RouteRecord route in recording.routes.reversed)
      if (route.agentJob case final NativeAgentJobHandle handle
          when seen.add(handle.id))
        handle,
  ];
}

/// The last `https://github.com/<owner>/<repo>/pull/<n>` URL in a job's result:
/// an agent that mentions an earlier PR usually ends with the one it opened.
Uri? agentResultPrUrl(String? result) {
  if (result == null) return null;
  final Iterable<RegExpMatch> matches = RegExp(
    r'https://github\.com/[\w.-]+/[\w.-]+/pull/\d+',
  ).allMatches(result);
  return matches.isEmpty ? null : Uri.tryParse(matches.last.group(0)!);
}

/// Shows one job through the shared poller of [NativeAgentJobs.watch], so a
/// card, a pill and a section on the same job cost one read, not three. The
/// poll runs only while the job is non-terminal and ends with the last widget.
class AgentJobProbe extends StatefulWidget {
  AgentJobProbe({
    super.key,
    required this.jobs,
    required this.id,
    required this.builder,
  });

  final NativeAgentJobs jobs;
  final String id;
  final Widget Function(
    BuildContext context,
    NativeAgentJob? job,
    bool loading,
    Future<void> Function() refresh,
  )
  builder;

  @override
  State<AgentJobProbe> createState() => _AgentJobProbeState();
}

class _AgentJobProbeState extends State<AgentJobProbe> {
  late NativeAgentJobWatch _watch;

  @override
  void initState() {
    super.initState();
    _watch = _open();
  }

  NativeAgentJobWatch _open() => widget.jobs.watch(widget.id, () {
    if (mounted) setState(() {});
  });

  @override
  void didUpdateWidget(AgentJobProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jobs != widget.jobs || oldWidget.id != widget.id) {
      final NativeAgentJobWatch old = _watch;
      _watch = _open();
      old.release();
    }
  }

  @override
  void dispose() {
    _watch.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _watch.job, _watch.loading, _watch.refresh);
}

String _statusLabel(NativeAgentJobStatus status) => switch (status) {
  NativeAgentJobStatus.starting ||
  NativeAgentJobStatus.running ||
  NativeAgentJobStatus.stopping => 'RUNNING',
  NativeAgentJobStatus.completed => 'DONE',
  NativeAgentJobStatus.failed || NativeAgentJobStatus.lost => 'FAILED',
  NativeAgentJobStatus.stopped => 'STOPPED',
};

Color _statusColor(NativeAgentJobStatus status) => switch (status) {
  NativeAgentJobStatus.completed => Console.green,
  NativeAgentJobStatus.failed || NativeAgentJobStatus.lost => Console.red,
  NativeAgentJobStatus.stopped ||
  NativeAgentJobStatus.stopping => Console.amber,
  NativeAgentJobStatus.starting ||
  NativeAgentJobStatus.running => Console.accent,
};

/// `AGENT · RUNNING / DONE / FAILED` for the capture's newest local job.
/// Draws nothing until the job has been read, and nothing if it cannot be.
class AgentRunPill extends StatelessWidget {
  AgentRunPill({super.key, required this.jobs, required this.handle});

  final NativeAgentJobs jobs;
  final NativeAgentJobHandle handle;

  @override
  Widget build(BuildContext context) => AgentJobProbe(
    jobs: jobs,
    id: handle.id,
    builder:
        (
          BuildContext context,
          NativeAgentJob? job,
          bool loading,
          Future<void> Function() refresh,
        ) => job == null
        ? const SizedBox.shrink()
        : StatusPill(
            label: 'AGENT · ${_statusLabel(job.status)}',
            color: _statusColor(job.status),
            pulse: !job.isTerminal,
          ),
  );
}

/// AGENT RUNS: one card per local job linked through [RouteRecord.agentJob].
class AgentRunsSection extends StatelessWidget {
  AgentRunsSection({
    super.key,
    required this.recording,
    required this.jobs,
  });

  final Recording recording;
  final NativeAgentJobs? jobs;

  @override
  Widget build(BuildContext context) {
    final List<NativeAgentJobHandle> handles = agentJobHandles(recording);
    if (jobs == null || handles.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SectionHeader(title: 'AGENT RUNS'),
        const SizedBox(height: 6),
        for (final NativeAgentJobHandle handle in handles) ...<Widget>[
          AgentJobProbe(
            key: ValueKey<String>('agent-run-${handle.id}'),
            jobs: jobs!,
            id: handle.id,
            builder:
                (
                  BuildContext context,
                  NativeAgentJob? job,
                  bool loading,
                  Future<void> Function() refresh,
                ) => _AgentRunCard(
                  jobs: jobs!,
                  handle: handle,
                  job: job,
                  loading: loading,
                  refresh: refresh,
                ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _AgentRunCard extends StatefulWidget {
  _AgentRunCard({
    required this.jobs,
    required this.handle,
    required this.job,
    required this.loading,
    required this.refresh,
  });

  final NativeAgentJobs jobs;
  final NativeAgentJobHandle handle;
  final NativeAgentJob? job;
  final bool loading;
  final Future<void> Function() refresh;

  @override
  State<_AgentRunCard> createState() => _AgentRunCardState();
}

class _AgentRunCardState extends State<_AgentRunCard> {
  bool _expanded = false;
  bool _busy = false;
  String? _error;

  Future<void> _stop() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.jobs.stop(widget.handle.id);
      await widget.refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _followUp() async {
    final String? prompt = await promptAgentFollowUp(context);
    if (prompt == null || prompt.trim().isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final NativeAgentJobHandle child;
    try {
      child = await widget.jobs.followUp(widget.handle.id, prompt);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await showAgentJobsSheet(context, jobs: widget.jobs, focusJobId: child.id);
  }

  String? _elapsed(NativeAgentJob job) {
    final DateTime? end = job.isTerminal ? job.finishedAt : DateTime.now();
    if (end == null) return null;
    // A clock step or a coarse mtime must not show a negative duration.
    final Duration d = end.isBefore(job.createdAt)
        ? Duration.zero
        : end.difference(job.createdAt);
    if (d.inHours == 0) return formatDuration(d);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.inHours}:${two(d.inMinutes.remainder(60))}:'
        '${two(d.inSeconds.remainder(60))}';
  }

  @override
  Widget build(BuildContext context) {
    final NativeAgentJob? job = widget.job;
    final String backend = agentBackendLabel(widget.handle.backend);
    final String? result = job?.result?.trim().isEmpty ?? true
        ? null
        : job!.result!.trim();
    final Uri? pr = agentResultPrUrl(result);
    final String? elapsed = job == null ? null : _elapsed(job);
    final bool longResult =
        result != null &&
        (result.length > 160 || '\n'.allMatches(result).length >= 3);
    final bool canFollowUp =
        job != null &&
        job.isTerminal &&
        job.status != NativeAgentJobStatus.lost &&
        job.conversationId != null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Console.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusPill(
                label: job == null
                    ? (widget.loading ? 'CHECKING' : 'UNAVAILABLE')
                    : _statusLabel(job.status),
                color: job == null ? Console.muted : _statusColor(job.status),
                pulse: job != null && !job.isTerminal,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(backend, style: ConsoleText.cardMeta)),
              if (elapsed != null)
                Text(
                  elapsed,
                  style: ConsoleText.micro.copyWith(
                    fontFamily: ConsoleFont.mono,
                  ),
                ),
            ],
          ),
          if (result != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              result,
              maxLines: _expanded ? null : 3,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: ConsoleText.body.copyWith(fontSize: 13),
            ),
            if (longResult)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? 'SHOW LESS' : 'SHOW MORE'),
                ),
              ),
          ] else if (job?.error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              job!.error!,
              maxLines: _expanded ? null : 3,
              overflow: TextOverflow.ellipsis,
              style: ConsoleText.body.copyWith(
                fontSize: 13,
                color: Console.redSoft,
              ),
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              _error!,
              style: ConsoleText.micro.copyWith(color: Console.redSoft),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (pr != null)
                ConsoleChip(
                  label:
                      'PR ${pr.pathSegments[0]}/${pr.pathSegments[1]}'
                      '#${pr.pathSegments.last}',
                  selected: false,
                  onSelected: () => unawaited(
                    launchUrl(
                      pr,
                      mode: LaunchMode.externalApplication,
                    ).then((_) {}, onError: (_) {}),
                  ),
                ),
              TextButton.icon(
                onPressed: () => showAgentJobsSheet(
                  context,
                  jobs: widget.jobs,
                  focusJobId: widget.handle.id,
                ),
                icon: const Icon(Icons.terminal_rounded, size: 16),
                label: const Text('VIEW LOG'),
              ),
              if (job != null && !job.isTerminal)
                TextButton.icon(
                  onPressed: _busy ? null : _stop,
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: const Text('STOP'),
                ),
              if (canFollowUp)
                TextButton.icon(
                  onPressed: _busy ? null : _followUp,
                  icon: const Icon(Icons.reply_rounded, size: 16),
                  label: const Text('FOLLOW UP'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
