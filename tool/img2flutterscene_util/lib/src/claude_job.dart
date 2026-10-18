import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'shell.dart';
import 'workspace.dart';

enum LogKind { info, text, tool, toolResult, error, done }

class LogEntry {
  LogEntry(this.kind, this.text) : time = DateTime.now();

  final LogKind kind;
  final String text;
  final DateTime time;
}

/// How much Claude Code may do without asking. A headless run cannot answer
/// a permission prompt, so anything outside the allow-list is simply denied.
enum ClaudePermissions {
  /// Edits plus the commands the skill needs (python3, the lab capture,
  /// flutter/dart, a few file utilities).
  skill('Skill commands only'),

  /// Everything, no checks (`--permission-mode bypassPermissions`).
  bypass('Bypass all permissions (dangerous)');

  const ClaudePermissions(this.label);
  final String label;
}

const _skillTools = [
  'Read',
  'Write',
  'Edit',
  'Glob',
  'Grep',
  'Bash(python3:*)',
  'Bash(scripts/lab_shot.sh:*)',
  'Bash(./scripts/lab_shot.sh:*)',
  'Bash(flutter:*)',
  'Bash(dart:*)',
  'Bash(mkdir:*)',
  'Bash(cp:*)',
  'Bash(ls:*)',
  'Bash(sips:*)',
  'Bash(file:*)',
];

/// Runs the img2flutterscene skill through headless Claude Code
/// (`claude -p --output-format stream-json`) for one work item, one session
/// per item so "Continue" and refinements resume the same conversation.
class ClaudeJob extends ChangeNotifier {
  ClaudeJob(this.root);

  final String root;
  final List<LogEntry> log = [];
  Process? _process;
  String? runningFor;
  ClaudePermissions permissions = ClaudePermissions.skill;

  /// Empty = Claude Code's default model.
  String model = '';

  bool get running => _process != null;

  /// The prompt for a first conversion. The skill (SKILL.md) holds the
  /// pipeline; this only pins where the work lives and that nobody is there
  /// to answer questions.
  static String convertPrompt(String root, WorkItem item, String notes) {
    final w = item.rel(root, item.dir);
    final ref = item.reference == null ? '$w/reference.png' : item.rel(root, item.reference!);
    return '''
Use the img2flutterscene skill (SKILL.md at the repository root) to reconstruct the object in $ref as a procedural flutter_scene model.

This run is driven by the img2flutterscene util app. Keep the model local:
- Every artifact for this model lives in $w/ (gitignored): state at $w/.img2threejs/state.json, the spec at $w/object-sculpt-spec.json, intake and assessment files beside it, screenshots in $w/shots/.
- Do not edit tracked files (lab/lib/models/, forge/, runtime/, grimoire/, docs/) for this model.
- After each generation also write the preview the app shows live: `python3 forge/stage3_build/generate_flutter_scene.py $w/object-sculpt-spec.json --format scene-json --out $w/model.scene.json --force` (add --allow-partial only when blocked by unported features), and the Dart factory to $w/model.dart.
- Capture with `scripts/lab_shot.sh $w/model.scene.json <pass> 0,90,180,270 $w/shots`.
- Nobody can answer questions during this run. On a hard stop, or anything that needs the user, stop and say exactly what is needed in your final message.
${notes.trim().isEmpty ? '' : '\nNotes from the user:\n${notes.trim()}\n'}''';
  }

  static String continuePrompt(String root, WorkItem item, String message) {
    final w = item.rel(root, item.dir);
    return message.trim().isEmpty
        ? 'Continue the img2flutterscene reconstruction in $w/ from the local state gate (forge/next.py --state $w/.img2threejs/state.json). Same rules as before: keep everything in $w/, refresh $w/model.scene.json after each generation.'
        : 'About the img2flutterscene reconstruction in $w/ (same rules as before: keep everything in $w/, refresh $w/model.scene.json after each generation):\n\n${message.trim()}';
  }

  Future<void> start(WorkItem item, String prompt, {required bool resume}) async {
    if (running) return;
    final job = item.readJob();
    var session = job['sessionId'] as String?;
    final fresh = session == null || !resume;
    if (fresh) {
      session = _uuid();
      item.writeJob({'sessionId': session});
    }
    final args = [
      'claude',
      '-p',
      prompt,
      '--output-format',
      'stream-json',
      '--verbose',
      if (fresh) ...['--session-id', session] else ...['--resume', session],
      if (permissions == ClaudePermissions.bypass) ...[
        '--permission-mode',
        'bypassPermissions',
      ] else ...[
        '--permission-mode',
        'acceptEdits',
        '--allowed-tools',
        _skillTools.join(','),
      ],
      if (model.trim().isNotEmpty) ...['--model', model.trim()],
    ];
    log.clear();
    _add(LogKind.info, '${fresh ? 'Converting' : 'Continuing'} ${item.id} · session ${session.substring(0, 8)}');
    runningFor = item.id;
    item.writeJob({'lastRun': DateTime.now().toIso8601String(), 'status': 'running'});
    final Process p;
    try {
      p = await startLogin(args, cwd: root);
    } catch (e) {
      _add(LogKind.error, 'Could not start claude: $e');
      runningFor = null;
      notifyListeners();
      return;
    }
    _process = p;
    // Headless claude waits ~3 s for piped stdin unless it is closed.
    unawaited(p.stdin.close());
    notifyListeners();
    final raw = item.claudeLog.openWrite(mode: FileMode.append);
    final stderr = StringBuffer();
    final out = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      raw.writeln(line);
      for (final e in parseClaudeEvent(line)) {
        _add(e.kind, e.text);
      }
    });
    final err = p.stderr.transform(utf8.decoder).listen(stderr.write);
    final code = await p.exitCode;
    await out.asFuture<void>().catchError((_) {});
    await err.asFuture<void>().catchError((_) {});
    await raw.close();
    if (code != 0) {
      final msg = stderr.toString().trim();
      _add(
        LogKind.error,
        'claude exited with $code${msg.isEmpty ? '' : ':\n$msg'}'
        '${msg.contains('command not found') ? '\nIs Claude Code installed and on your login shell PATH?' : ''}',
      );
    }
    item.writeJob({'status': code == 0 ? 'done' : 'failed'});
    _process = null;
    runningFor = null;
    notifyListeners();
  }

  void stop() {
    _process?.kill(ProcessSignal.sigint);
    final p = _process;
    Timer(const Duration(seconds: 3), () {
      if (_process == p) p?.kill();
    });
    _add(LogKind.info, 'Stopping…');
  }

  /// The log lines one stream-json event becomes (Claude Code
  /// `--output-format stream-json --verbose`). Unknown events give none;
  /// a line that is not JSON is shown as-is.
  static List<LogEntry> parseClaudeEvent(String line) {
    Map<String, Object?> e;
    try {
      e = (jsonDecode(line) as Map).cast();
    } catch (_) {
      return line.trim().isEmpty ? const [] : [LogEntry(LogKind.info, line)];
    }
    final out = <LogEntry>[];
    switch (e['type']) {
      case 'assistant':
        final content = ((e['message'] as Map?)?['content'] as List?) ?? const [];
        for (final c in content.whereType<Map>()) {
          if (c['type'] == 'text' && '${c['text']}'.trim().isNotEmpty) {
            out.add(LogEntry(LogKind.text, '${c['text']}'.trim()));
          } else if (c['type'] == 'tool_use') {
            out.add(
              LogEntry(
                LogKind.tool,
                '${c['name']}  ${_summarize((c['input'] as Map?)?.cast<String, Object?>() ?? {})}',
              ),
            );
          }
        }
      case 'user':
        final content = ((e['message'] as Map?)?['content'] as List?) ?? const [];
        for (final c in content.whereType<Map>()) {
          if (c['type'] == 'tool_result' && c['is_error'] == true) {
            out.add(LogEntry(LogKind.error, _clip('${c['content']}', 400)));
          }
        }
      case 'result':
        final cost = e['total_cost_usd'];
        final turns = e['num_turns'];
        final failed = e['is_error'] == true;
        out.add(
          LogEntry(
            failed ? LogKind.error : LogKind.done,
            '${failed ? 'Run failed' : 'Run finished'}'
            '${turns == null ? '' : ' · $turns turns'}'
            '${cost is num ? ' · \$${cost.toStringAsFixed(2)}' : ''}'
            '${e['result'] == null ? '' : '\n\n${e['result']}'}',
          ),
        );
    }
    return out;
  }

  static String _summarize(Map<String, Object?> input) {
    for (final k in ['command', 'file_path', 'path', 'pattern', 'description']) {
      final v = input[k];
      if (v is String && v.isNotEmpty) return _clip(v.replaceAll('\n', ' '), 160);
    }
    return '';
  }

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  void _add(LogKind kind, String text) {
    log.add(LogEntry(kind, text));
    notifyListeners();
  }

  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  @override
  void dispose() {
    _process?.kill();
    super.dispose();
  }
}
