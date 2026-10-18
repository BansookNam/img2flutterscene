import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:img2flutterscene/img2flutterscene.dart';

import 'shell.dart';

/// The img2flutterscene checkout this app drives: the directory holding
/// SKILL.md and the forge generator.
bool isRepoRoot(String dir) =>
    File('$dir/SKILL.md').existsSync() && File('$dir/forge/stage3_build/generate_flutter_scene.py').existsSync();

/// Finds the checkout: `--dart-define=IMG2FLUTTERSCENE_ROOT`, the
/// environment variable of the same name, then the folders above the running
/// app (it is normally built inside the checkout, under tool/).
String? findRepoRoot() {
  const defined = String.fromEnvironment('IMG2FLUTTERSCENE_ROOT');
  for (final c in [defined, Platform.environment['IMG2FLUTTERSCENE_ROOT'] ?? '']) {
    if (c.isNotEmpty && isRepoRoot(c)) return c;
  }
  for (final start in [File(Platform.resolvedExecutable).parent, Directory.current]) {
    for (Directory? d = start; d != null; d = d.parent.path == d.path ? null : d.parent) {
      if (isRepoRoot(d.path)) return d.path;
    }
  }
  return null;
}

/// One reconstruction: a folder under work/ (gitignored, so local models
/// never collide with a `git pull`).
///
///   reference.ext            the input image (copied in)
///   job.json                 this app's bookkeeping (Claude session id, …)
///   object-sculpt-spec.json  written by the skill
///   model.scene.json         the previewed model (generator --format scene-json)
///   model.dart               the Dart factory to ship in an app
///   shots/                   lab and app screenshots
///   claude.jsonl             raw Claude Code event log
class WorkItem {
  WorkItem(this.dir);

  final Directory dir;

  String get id => dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  File get spec => File('${dir.path}/object-sculpt-spec.json');
  File get scene => File('${dir.path}/model.scene.json');
  File get draftScene => File('${dir.path}/preview.draft.scene.json');
  File get dart => File('${dir.path}/model.dart');
  File get jobFile => File('${dir.path}/job.json');
  File get claudeLog => File('${dir.path}/claude.jsonl');
  Directory get shots => Directory('${dir.path}/shots');

  File? get reference {
    if (!dir.existsSync()) return null;
    for (final f in dir.listSync().whereType<File>()) {
      if (f.uri.pathSegments.last.startsWith('reference.')) return f;
    }
    return null;
  }

  Map<String, Object?> readJob() {
    try {
      return (jsonDecode(jobFile.readAsStringSync()) as Map).cast();
    } catch (_) {
      return {};
    }
  }

  void writeJob(Map<String, Object?> update) {
    final job = {...readJob(), ...update};
    jobFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(job));
  }

  /// The repo-relative path the skill should use.
  String rel(String root, FileSystemEntity e) =>
      e.path.startsWith('$root/') ? e.path.substring(root.length + 1) : e.path;
}

/// What the preview shows for a work item, and why when it shows nothing.
class PreviewState {
  const PreviewState({this.scene, this.message, this.isError = false, this.draft = false});

  final SceneDescription? scene;
  final String? message;
  final bool isError;
  final bool draft;
}

/// The work/ folder: lists items, creates one from an image, and keeps the
/// selected item's preview in step with its spec.
class Workspace extends ChangeNotifier {
  Workspace(this.root) {
    refresh();
  }

  final String root;
  List<WorkItem> items = [];
  WorkItem? selected;
  PreviewState preview = const PreviewState(message: 'Add an image to start.');

  /// Preview the spec even while strict-quality blocks it (the generator's
  /// --allow-nonstrict). Shown as DRAFT; never evidence a pass is done.
  bool draft = false;

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _debounce;
  int _sceneStamp = 0;

  Directory get workDir => Directory('$root/work');

  void refresh() {
    items = workDir.existsSync()
        ? (workDir.listSync().whereType<Directory>().map(WorkItem.new).where((w) => !w.id.startsWith('.')).toList()
            ..sort((a, b) => b.dir.statSync().modified.compareTo(a.dir.statSync().modified)))
        : [];
    notifyListeners();
  }

  /// Copies [imagePath] into a new `work/slug-time/` and selects it.
  WorkItem create(String imagePath) {
    final name = imagePath.split('/').last;
    final dot = name.lastIndexOf('.');
    final stem = (dot > 0 ? name.substring(0, dot) : name).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    final ext = dot > 0 ? name.substring(dot).toLowerCase() : '.png';
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final slug = '${stem.isEmpty ? 'model' : stem}-${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}';
    final item = WorkItem(Directory('${workDir.path}/$slug'))..dir.createSync(recursive: true);
    File(imagePath).copySync('${item.dir.path}/reference$ext');
    item.writeJob({'created': now.toIso8601String(), 'source': imagePath});
    refresh();
    select(item);
    return item;
  }

  /// Deletes [item]'s folder (local work only — nothing tracked lives there).
  void delete(WorkItem item) {
    if (selected?.id == item.id) select(null);
    item.dir.deleteSync(recursive: true);
    refresh();
    if (selected == null && items.isNotEmpty) select(items.first);
  }

  void select(WorkItem? item) {
    selected = item;
    _watch?.cancel();
    if (item != null) {
      _watch = item.dir.watch().listen((e) {
        final n = e.path.split('/').last;
        if (n == 'object-sculpt-spec.json' || n.endsWith('.scene.json')) {
          _debounce?.cancel();
          _debounce = Timer(
            const Duration(milliseconds: 500),
            () => reloadPreview(regenerate: n.endsWith('spec.json')),
          );
        }
      });
    }
    reloadPreview(regenerate: true);
  }

  void setDraft(bool value) {
    draft = value;
    reloadPreview(regenerate: true);
  }

  /// Regenerates the preview from the spec (when asked and a spec exists),
  /// then loads it.
  Future<void> reloadPreview({bool regenerate = false}) async {
    final item = selected;
    if (item == null) {
      preview = const PreviewState(message: 'Add an image to start.');
      notifyListeners();
      return;
    }
    final stamp = ++_sceneStamp;
    String? blocked;
    if (regenerate && item.spec.existsSync()) {
      final out = draft ? item.draftScene : item.scene;
      final r = await runLogin([
        'python3',
        'forge/stage3_build/generate_flutter_scene.py',
        item.spec.path,
        '--format',
        'scene-json',
        '--out',
        out.path,
        '--force',
        '--allow-partial',
        if (draft) '--allow-nonstrict',
      ], cwd: root);
      if (r.exitCode != 0) blocked = blockedSummary(r.stderr as String);
    }
    if (stamp != _sceneStamp) return; // a newer reload started
    final file = draft ? item.draftScene : item.scene;
    if (!file.existsSync()) {
      preview = PreviewState(
        message:
            blocked ??
            (item.spec.existsSync()
                ? 'No preview yet.'
                : 'No sculpt spec yet. Press Convert to run the skill on this image.'),
        isError: blocked != null,
      );
    } else {
      try {
        final scene = SceneDescription.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, Object?>);
        preview = PreviewState(scene: scene, message: blocked, isError: blocked != null, draft: draft);
      } catch (e) {
        preview = PreviewState(message: 'Could not read ${file.path}: $e', isError: true);
      }
    }
    notifyListeners();
  }

  /// Writes the Dart factory for the current pass to `work/id/model.dart`.
  Future<String> exportDart() async {
    final item = selected!;
    final r = await runLogin([
      'python3',
      'forge/stage3_build/generate_flutter_scene.py',
      item.spec.path,
      '--out',
      item.dart.path,
      '--force',
      '--allow-partial',
    ], cwd: root);
    return r.exitCode == 0 ? item.dart.path : blockedSummary(r.stderr as String);
  }

  /// A short, readable reason from the generator's stderr (its BLOCKED
  /// report when there is one).
  static String blockedSummary(String stderr) {
    final i = stderr.indexOf('{');
    if (i >= 0) {
      try {
        final report = jsonDecode(stderr.substring(i, stderr.lastIndexOf('}') + 1)) as Map;
        final causes = (report['cause'] as List? ?? const []).take(6).map((c) => '• $c').join('\n');
        return 'Generator blocked (${report['gate']}):\n$causes';
      } catch (_) {}
    }
    final lines = stderr.trim().split('\n');
    return 'Generator failed:\n${lines.skip(lines.length > 8 ? lines.length - 8 : 0).join('\n')}';
  }

  @override
  void dispose() {
    _watch?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}
