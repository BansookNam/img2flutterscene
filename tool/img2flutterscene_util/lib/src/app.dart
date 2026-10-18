import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'claude_job.dart';
import 'inspector.dart';
import 'shell.dart';
import 'view_settings.dart';
import 'viewer.dart';
import 'workspace.dart';

class UtilApp extends StatelessWidget {
  const UtilApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'img2flutterscene',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2E7DD7),
        visualDensity: VisualDensity.compact,
      ),
      home: const _RootGate(),
    );
  }
}

/// Finds the img2flutterscene checkout, or asks for it.
class _RootGate extends StatefulWidget {
  const _RootGate();

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> {
  String? _root = findRepoRoot();
  String? _error;

  Future<void> _choose() async {
    final dir = await chooseFolder('Choose your img2flutterscene checkout');
    if (dir == null) return;
    final clean = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
    setState(() {
      if (isRepoRoot(clean)) {
        _root = clean;
        _error = null;
      } else {
        _error = '$clean has no SKILL.md and forge/ generator.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final root = _root;
    if (root != null) return _Home(key: ValueKey(root), root: root, onChangeRoot: _choose);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Where is your img2flutterscene checkout?', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            const Text('Set IMG2FLUTTERSCENE_ROOT, or build this app inside the checkout, to skip this.'),
            const SizedBox(height: 16),
            FilledButton(onPressed: _choose, child: const Text('Choose folder…')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!)),
          ],
        ),
      ),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home({super.key, required this.root, required this.onChangeRoot});

  final String root;
  final VoidCallback onChangeRoot;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late final Workspace _ws = Workspace(widget.root);
  late final ClaudeJob _job = ClaudeJob(widget.root)..addListener(_onJob);
  final ViewSettings _settings = ViewSettings();
  final OrbitController _orbit = OrbitController();
  final GlobalKey _shotKey = GlobalKey();
  bool _logOpen = true;
  bool _wasRunning = false;

  final GlobalKey _windowKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    const pick = String.fromEnvironment('UTIL_SELECT');
    final start = _ws.items.where((w) => w.id == pick).firstOrNull ?? _ws.items.firstOrNull;
    if (start != null) _ws.select(start);
    const shot = String.fromEnvironment('UTIL_SHOT');
    if (shot.isNotEmpty) _selfShot(shot);
  }

  /// Dev check: `--dart-define=UTIL_SHOT=/abs/out.png` saves the whole window
  /// once the model has settled, then quits. `UTIL_SELECT=<id>` picks the model;
  /// `UTIL_SETUP=view=faces,wire,explode=0.5,yaw=35,pitch=20,ref=overlay,light=6,az=80,el=20,focus=<id>`
  /// applies view settings first.
  Future<void> _selfShot(String path) async {
    for (final kv in const String.fromEnvironment('UTIL_SETUP').split(',').where((e) => e.isNotEmpty)) {
      final [k, ...rest] = kv.split('=');
      final v = rest.join('=');
      switch (k) {
        case 'view':
          _settings.update((s) => s.view = InspectView.values.byName(v));
        case 'wire':
          _settings.update((s) => s.wireframe = true);
        case 'explode':
          _settings.update((s) => s.explode = double.parse(v));
        case 'ref':
          _settings.update((s) => s.reference = ReferenceMode.values.byName(v));
        case 'light':
          _settings.update((s) => s.keyIntensity = double.parse(v));
        case 'select':
          _settings.update((s) => s.selected = v);
        case 'focus':
          _settings.update((s) => s.focusRequest = v);
        case 'az':
          _settings.update((s) => s.lightAzimuth = double.parse(v));
        case 'el':
          _settings.update((s) => s.lightElevation = double.parse(v));
        case 'yaw':
        case 'pitch':
          final yaw = k == 'yaw' ? double.parse(v) : _orbit.yaw * 180 / 3.141592653589793;
          final pitch = k == 'pitch' ? double.parse(v) : _orbit.pitch * 180 / 3.141592653589793;
          _orbit.preset(yaw, pitch);
      }
    }
    await Future<void>.delayed(const Duration(seconds: 6));
    await WidgetsBinding.instance.endOfFrame;
    final boundary = _windowKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path).writeAsBytesSync(png!.buffer.asUint8List());
    debugPrint('UTIL_SHOT $path');
    exit(0);
  }

  void _onJob() {
    // When a run ends, pick up whatever it produced.
    if (_wasRunning && !_job.running) {
      _ws.refresh();
      _ws.reloadPreview(regenerate: true);
    }
    _wasRunning = _job.running;
  }

  void _toast(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 4)));

  Future<void> _addImage() async {
    final path = await chooseImage();
    if (path == null) return;
    _ws.create(path);
  }

  Future<void> _confirmDelete(WorkItem w) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${w.id}?'),
        content: const Text(
          'This removes its folder under work/ — the reference copy, spec, preview, '
          'Dart factory and screenshots. It cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) _ws.delete(w);
  }

  Future<void> _screenshot() async {
    final item = _ws.selected;
    if (item == null || _ws.preview.scene == null) return;
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final path = '${item.shots.path}/util_$stamp.png';
    await saveShot(_shotKey, path);
    _toast('Saved $path');
  }

  @override
  void dispose() {
    _job.dispose();
    _ws.dispose();
    _settings.dispose();
    _orbit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _windowKey,
      child: Scaffold(
        body: Row(
          children: [
            SizedBox(width: 250, child: _sidebar()),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  _toolbar(),
                  const Divider(height: 1),
                  Expanded(child: _viewport()),
                  const Divider(height: 1),
                  _logPanel(),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 330,
              child: Inspector(workspace: _ws, job: _job, settings: _settings, orbit: _orbit, onMessage: _toast),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebar() => ListenableBuilder(
    listenable: Listenable.merge([_ws, _job]),
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 4),
          child: Text('img2flutterscene', style: Theme.of(context).textTheme.titleMedium),
        ),
        InkWell(
          onTap: widget.onChangeRoot,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            child: Text(
              widget.root,
              style: const TextStyle(fontSize: 11, color: Colors.white54),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _addImage,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('New from image…'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 4, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'MODELS  ·  work/ (local, gitignored)',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1),
                ),
              ),
              IconButton(tooltip: 'Refresh', iconSize: 18, icon: const Icon(Icons.refresh), onPressed: _ws.refresh),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final w in _ws.items)
                ListTile(
                  dense: true,
                  selected: _ws.selected?.id == w.id,
                  leading: SizedBox(
                    width: 40,
                    height: 40,
                    child: w.reference == null
                        ? const Icon(Icons.image_not_supported_outlined)
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.file(w.reference!, fit: BoxFit.cover, cacheWidth: 80),
                          ),
                  ),
                  title: Text(w.id, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                  trailing: PopupMenuButton<String>(
                    iconSize: 18,
                    tooltip: 'More',
                    onSelected: (action) => action == 'reveal' ? revealInFinder(w.dir.path) : _confirmDelete(w),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'reveal', child: Text('Reveal in Finder')),
                      PopupMenuItem(value: 'delete', enabled: _job.runningFor != w.id, child: const Text('Delete…')),
                    ],
                  ),
                  subtitle: Text(_status(w), style: const TextStyle(fontSize: 11)),
                  onTap: () {
                    if (_ws.selected?.id != w.id) {
                      _orbit.reset();
                      _settings.update(
                        (s) => s
                          ..selected = null
                          ..hidden.clear(),
                      );
                    }
                    _ws.select(w);
                  },
                ),
            ],
          ),
        ),
      ],
    ),
  );

  String _status(WorkItem w) {
    if (_job.runningFor == w.id) return 'converting…';
    final status = w.readJob()['status'];
    if (w.scene.existsSync()) return 'preview ready${status == 'failed' ? ' · last run failed' : ''}';
    if (w.spec.existsSync()) return 'spec written';
    return status == null ? 'not converted' : '$status';
  }

  Widget _toolbar() => ListenableBuilder(
    listenable: _settings,
    builder: (context, _) {
      final s = _settings;
      Widget toggle(IconData icon, String tip, bool on, VoidCallback onTap) =>
          IconButton(tooltip: tip, isSelected: on, icon: Icon(icon, size: 20), onPressed: onTap);
      return SizedBox(
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (label, yaw, pitch) in const [
                      ('Front', 0.0, 0.0),
                      ('Right', 90.0, 0.0),
                      ('Back', 180.0, 0.0),
                      ('Left', 270.0, 0.0),
                      ('Top', 0.0, 89.0),
                    ])
                      TextButton(onPressed: () => _orbit.preset(yaw, pitch), child: Text(label)),
                    IconButton(
                      tooltip: 'Reset camera (0)',
                      icon: const Icon(Icons.center_focus_strong, size: 20),
                      onPressed: _orbit.reset,
                    ),
                    const VerticalDivider(indent: 10, endIndent: 10),
                    toggle(
                      Icons.threesixty,
                      'Auto-rotate (Space)',
                      s.autoRotate,
                      () => s.update((s) => s.autoRotate = !s.autoRotate),
                    ),
                    toggle(
                      Icons.grid_on,
                      'Wireframe (W)',
                      s.wireframe,
                      () => s.update((s) => s.wireframe = !s.wireframe),
                    ),
                    toggle(Icons.grid_4x4, 'Floor grid (G)', s.grid, () => s.update((s) => s.grid = !s.grid)),
                    toggle(
                      Icons.compare,
                      'Reference: ${s.reference.label}',
                      s.reference != ReferenceMode.off,
                      () => s.update(
                        (s) =>
                            s.reference = ReferenceMode.values[(s.reference.index + 1) % ReferenceMode.values.length],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            DropdownButton<InspectView>(
              value: s.view,
              underline: const SizedBox(),
              isDense: true,
              items: [for (final v in InspectView.values) DropdownMenuItem(value: v, child: Text(v.label))],
              onChanged: (v) => s.update((s) => s.view = v!),
            ),
            IconButton(
              tooltip: 'Save screenshot to shots/',
              icon: const Icon(Icons.photo_camera_outlined, size: 20),
              onPressed: _screenshot,
            ),
            const SizedBox(width: 8),
          ],
        ),
      );
    },
  );

  Widget _viewport() => ListenableBuilder(
    listenable: Listenable.merge([_ws, _settings]),
    builder: (context, _) {
      final p = _ws.preview;
      final ref = _ws.selected?.reference;
      final mode = _settings.reference;
      final Widget model = p.scene == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  p.message ?? '',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.isError ? Colors.red.shade300 : null),
                ),
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                ModelViewer(scene: p.scene!, settings: _settings, orbit: _orbit, shotKey: _shotKey),
                if (ref != null && mode == ReferenceMode.overlay)
                  IgnorePointer(
                    child: Opacity(
                      opacity: _settings.referenceOpacity,
                      child: Image.file(ref, fit: BoxFit.contain),
                    ),
                  ),
                Positioned(left: 10, top: 8, right: 10, child: _banner(p)),
              ],
            );
      return ColoredBox(
        color: _settings.backdrop.color,
        child: Row(
          children: [
            if (ref != null && mode == ReferenceMode.side)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Image.file(ref, fit: BoxFit.contain),
                ),
              ),
            Expanded(child: model),
          ],
        ),
      );
    },
  );

  Widget _banner(PreviewState p) {
    final scene = p.scene!;
    final chips = <Widget>[
      _chip('${scene.target} · ${scene.pass}', Colors.black54),
      if (p.draft) _chip('DRAFT — strict-quality skipped', Colors.orange.shade800),
      if (scene.omitted.isNotEmpty) _chip('${scene.omitted.length} not built', Colors.red.shade800),
      if (scene.unapplied.isNotEmpty) _chip('${scene.unapplied.length} approximate', Colors.amber.shade900),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 6, runSpacing: 4, children: chips),
        if (p.message != null)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            color: Colors.red.shade900.withValues(alpha: 0.85),
            child: Text('${p.message!}\n(showing the last good preview)', style: const TextStyle(fontSize: 12)),
          ),
      ],
    );
  }

  Widget _chip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
    child: Text(text, style: const TextStyle(fontSize: 11, color: Colors.white)),
  );

  Widget _logPanel() => ListenableBuilder(
    listenable: _job,
    builder: (context, _) {
      return Column(
        children: [
          InkWell(
            onTap: () => setState(() => _logOpen = !_logOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(_logOpen ? Icons.expand_more : Icons.expand_less, size: 18),
                  const SizedBox(width: 6),
                  const Text('Claude Code', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 10),
                  if (_job.running) ...[
                    const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Text('running for ${_job.runningFor}', style: const TextStyle(fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
          if (_logOpen)
            SizedBox(
              height: 200,
              child: _job.log.isEmpty
                  ? const Center(
                      child: Text('Convert an image to see Claude work here.', style: TextStyle(fontSize: 12)),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      itemCount: _job.log.length,
                      itemBuilder: (context, i) => _logLine(_job.log[_job.log.length - 1 - i]),
                    ),
            ),
        ],
      );
    },
  );

  Widget _logLine(LogEntry e) {
    final (icon, color) = switch (e.kind) {
      LogKind.tool => (Icons.terminal, Colors.lightBlue.shade200),
      LogKind.error => (Icons.error_outline, Colors.red.shade300),
      LogKind.done => (Icons.check_circle_outline, Colors.green.shade300),
      LogKind.text => (Icons.chat_bubble_outline, Colors.white),
      _ => (Icons.info_outline, Colors.white60),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              e.text,
              style: TextStyle(fontSize: 12, color: color, fontFamily: e.kind == LogKind.tool ? 'Menlo' : null),
            ),
          ),
        ],
      ),
    );
  }
}
