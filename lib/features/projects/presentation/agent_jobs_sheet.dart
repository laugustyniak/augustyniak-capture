import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../app/ui_kit.dart';
import '../data/native_agent_jobs.dart';
import '../domain/native_agent_types.dart';

Future<void> showAgentJobsSheet(
  BuildContext context, {
  required NativeAgentJobs jobs,
  String? focusJobId,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (BuildContext context) => ConsolePaletteScope(
    builder: (BuildContext context) =>
        AgentJobsSheet(jobs: jobs, focusJobId: focusJobId),
  ),
);

class AgentJobsSheet extends StatefulWidget {
  AgentJobsSheet({super.key, required this.jobs, this.focusJobId});

  final NativeAgentJobs jobs;
  final String? focusJobId;

  @override
  State<AgentJobsSheet> createState() => _AgentJobsSheetState();
}

class _AgentJobsSheetState extends State<AgentJobsSheet> {
  List<NativeAgentJob>? _jobs;
  String? _selectedId;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.focusJobId;
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final List<NativeAgentJob> jobs = await widget.jobs.list();
      if (!mounted) return;
      setState(() {
        _jobs = jobs;
        if (_selectedId != null &&
            !jobs.any((NativeAgentJob job) => job.handle.id == _selectedId)) {
          _selectedId = null;
        }
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _stop(String id) async {
    setState(() => _busy = true);
    try {
      await widget.jobs.stop(id);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _followUp(NativeAgentJob job) async {
    final String? prompt = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _FollowUpDialog(),
    );
    if (prompt == null || prompt.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final NativeAgentJobHandle child = await widget.jobs.followUp(
        job.handle.id,
        prompt,
      );
      _selectedId = child.id;
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<NativeAgentJob>? jobs = _jobs;
    NativeAgentJob? selected;
    if (_selectedId != null && jobs != null) {
      for (final NativeAgentJob job in jobs) {
        if (job.handle.id == _selectedId) selected = job;
      }
    }
    return Container(
      height: MediaQuery.sizeOf(context).height * .82,
      decoration: BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: Console.borderStrong)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('Agent jobs', style: ConsoleText.pageTitle)),
              IconButton(
                key: const ValueKey<String>('agent-jobs-refresh'),
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Refresh jobs',
              ),
            ],
          ),
          Text(
            'Runs on this device. Output stays here.',
            style: ConsoleText.micro,
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 10),
            ErrorBanner(message: _error!),
          ],
          const SizedBox(height: 14),
          Expanded(
            child: jobs == null
                ? Center(
                    child: CircularProgressIndicator(color: Console.accent),
                  )
                : jobs.isEmpty
                ? EmptyPanel(
                    icon: Icons.terminal_outlined,
                    title: 'No agent jobs yet.',
                    blurb: 'Background handoffs will appear here.',
                  )
                : selected == null
                ? ListView.separated(
                    itemCount: jobs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (BuildContext context, int index) {
                      final NativeAgentJob job = jobs[index];
                      final RoundedRectangleBorder shape =
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          );
                      return Material(
                        color: Console.surfaceRaised,
                        shape: shape,
                        child: ListTile(
                          key: ValueKey<String>('agent-job-${job.handle.id}'),
                          shape: shape,
                          leading: Icon(
                            Icons.terminal_rounded,
                            color: _statusColor(job.status),
                          ),
                          title: Text(
                            '${agentBackendLabel(job.handle.backend)} · ${job.projectName ?? p.basename(job.workspacePath)}',
                          ),
                          subtitle: Text(
                            '${job.status.name.toUpperCase()} · ${_jobTime(job.createdAt)} · ${_shortId(job.handle.id)}',
                            style: ConsoleText.micro,
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () =>
                              setState(() => _selectedId = job.handle.id),
                        ),
                      );
                    },
                  )
                : _JobDetail(
                    job: selected,
                    busy: _busy,
                    onBack: () => setState(() => _selectedId = null),
                    onStop: selected.isTerminal
                        ? null
                        : () => _stop(selected!.handle.id),
                    onFollowUp:
                        selected.isTerminal &&
                            selected.status != NativeAgentJobStatus.lost &&
                            selected.conversationId != null
                        ? () => _followUp(selected!)
                        : null,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Asks for the next instruction of a follow-up; null when cancelled.
Future<String?> promptAgentFollowUp(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (BuildContext context) => _FollowUpDialog(),
    );

class _FollowUpDialog extends StatefulWidget {
  _FollowUpDialog();

  @override
  State<_FollowUpDialog> createState() => _FollowUpDialogState();
}

class _FollowUpDialogState extends State<_FollowUpDialog> {
  final TextEditingController controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Follow up'),
    content: TextField(
      key: const ValueKey<String>('agent-job-follow-up-input'),
      controller: controller,
      minLines: 3,
      maxLines: 8,
      autofocus: true,
      decoration: const InputDecoration(hintText: 'Next instruction'),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('CANCEL'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(controller.text),
        child: const Text('SEND'),
      ),
    ],
  );
}

class _JobDetail extends StatelessWidget {
  _JobDetail({
    required this.job,
    required this.busy,
    required this.onBack,
    required this.onStop,
    required this.onFollowUp,
  });
  final NativeAgentJob job;
  final bool busy;
  final VoidCallback onBack;
  final VoidCallback? onStop;
  final VoidCallback? onFollowUp;

  @override
  Widget build(BuildContext context) => ListView(
    children: <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('ALL JOBS'),
        ),
      ),
      Row(
        children: <Widget>[
          Expanded(
            child: Text(
              agentBackendLabel(job.handle.backend),
              style: ConsoleText.cardTitle,
            ),
          ),
          StatusPill(
            label: job.status.name.toUpperCase(),
            color: _statusColor(job.status),
          ),
        ],
      ),
      const SizedBox(height: 8),
      SelectableText(
        job.handle.id,
        style: ConsoleText.micro.copyWith(fontFamily: ConsoleFont.mono),
      ),
      if (job.exitCode != null)
        Text('Exit code ${job.exitCode}', style: ConsoleText.micro),
      Text(
        '${job.workspacePath} · ${_jobTime(job.createdAt)}',
        style: ConsoleText.micro,
      ),
      if (job.approvalsOff) ...<Widget>[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: StatusPill(label: 'APPROVALS OFF', color: Console.red),
        ),
      ],
      if (onStop != null || onFollowUp != null) ...<Widget>[
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            if (onStop != null)
              OutlinedButton.icon(
                key: const ValueKey<String>('agent-job-stop'),
                onPressed: busy ? null : onStop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('STOP'),
              ),
            if (onFollowUp != null)
              FilledButton.icon(
                key: const ValueKey<String>('agent-job-follow-up'),
                onPressed: busy ? null : onFollowUp,
                icon: const Icon(Icons.reply_rounded),
                label: const Text('FOLLOW UP'),
              ),
          ],
        ),
      ],
      if (job.error != null) ...<Widget>[
        const SizedBox(height: 14),
        ErrorBanner(message: job.error!),
      ],
      if (job.result != null) ...<Widget>[
        const SizedBox(height: 16),
        SectionHeader(title: 'RESULT'),
        const SizedBox(height: 7),
        SelectableText(job.result!),
      ],
      const SizedBox(height: 16),
      SectionHeader(title: 'LOGS', trailing: 'LAST 256 KIB'),
      const SizedBox(height: 7),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Console.surfaceRaised,
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectableText(
          job.logs.isEmpty ? 'No output yet.' : job.logs,
          style: ConsoleText.micro.copyWith(fontFamily: ConsoleFont.mono),
        ),
      ),
    ],
  );
}

String agentBackendLabel(NativeAgentBackend backend) => switch (backend) {
  NativeAgentBackend.claude => 'Claude Code',
  NativeAgentBackend.codex => 'Codex',
  NativeAgentBackend.antigravity => 'Antigravity',
};

String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

String _jobTime(DateTime value) {
  final DateTime local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

Color _statusColor(NativeAgentJobStatus status) => switch (status) {
  NativeAgentJobStatus.completed => Console.green,
  NativeAgentJobStatus.failed || NativeAgentJobStatus.lost => Console.red,
  NativeAgentJobStatus.stopped ||
  NativeAgentJobStatus.stopping => Console.amber,
  NativeAgentJobStatus.starting ||
  NativeAgentJobStatus.running => Console.accent,
};
