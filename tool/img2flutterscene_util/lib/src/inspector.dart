import 'dart:io';

import 'package:flutter/material.dart';

import 'package:img2flutterscene/img2flutterscene.dart';

import 'claude_job.dart';
import 'shell.dart';
import 'view_settings.dart';
import 'workspace.dart';

final _statsCache = Expando<List<(String, int)>>();

/// Vertex count per part, heaviest first — where the budget goes.
List<Widget> _geometryStats(SceneDescription scene) {
  final stats = _statsCache[scene] ??= [for (final p in scene.parts) (p.name, buildPartGeometry(p).vertexCount)]
    ..sort((a, b) => b.$2.compareTo(a.$2));
  final total = stats.fold(0, (n, s) => n + s.$2);
  return [
    Text('$total vertices in ${stats.length} meshes', style: const TextStyle(fontWeight: FontWeight.w600)),
    const SizedBox(height: 4),
    for (final (name, n) in stats.take(8))
      Row(
        children: [
          Expanded(
            child: Text(name, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
          ),
          Text('$n', style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
  ];
}

/// The right-hand panel: convert, light, view, parts and info tabs.
class Inspector extends StatelessWidget {
  const Inspector({
    super.key,
    required this.workspace,
    required this.job,
    required this.settings,
    required this.orbit,
    required this.onMessage,
  });

  final Workspace workspace;
  final ClaudeJob job;
  final ViewSettings settings;
  final OrbitController orbit;
  final void Function(String message) onMessage;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      // Dev check: --dart-define=UTIL_TAB=3 opens on Parts (see UTIL_SHOT).
      initialIndex: const int.fromEnvironment('UTIL_TAB'),
      child: Column(
        children: [
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding: EdgeInsets.symmetric(horizontal: 12),
            tabs: [
              Tab(text: 'Convert'),
              Tab(text: 'Light'),
              Tab(text: 'View'),
              Tab(text: 'Parts'),
              Tab(text: 'Info'),
            ],
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([workspace, job, settings]),
              builder: (context, _) => TabBarView(
                children: [
                  _ConvertTab(workspace: workspace, job: job, onMessage: onMessage),
                  _LightTab(settings: settings),
                  _ViewTab(settings: settings, orbit: orbit),
                  _PartsTab(workspace: workspace, settings: settings),
                  _InfoTab(workspace: workspace),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _section(String title, List<Widget> children) => Padding(
  padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.1)),
      const SizedBox(height: 8),
      ...children,
    ],
  ),
);

/// A labelled slider showing its value.
Widget _slider(
  String label,
  double value,
  double min,
  double max,
  ValueChanged<double> onChanged, {
  String Function(double v)? format,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Text(
            format?.call(value) ?? value.toStringAsFixed(2),
            style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ],
      ),
      SliderTheme(
        data: const SliderThemeData(trackHeight: 3, overlayShape: RoundSliderOverlayShape(overlayRadius: 12)),
        child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
      ),
    ],
  );
}

Widget _switch(String label, bool value, ValueChanged<bool> onChanged, {String? subtitle}) => SwitchListTile(
  dense: true,
  contentPadding: EdgeInsets.zero,
  title: Text(label, style: const TextStyle(fontSize: 13)),
  subtitle: subtitle == null ? null : Text(subtitle, style: const TextStyle(fontSize: 11)),
  value: value,
  onChanged: onChanged,
);

class _ConvertTab extends StatefulWidget {
  const _ConvertTab({required this.workspace, required this.job, required this.onMessage});

  final Workspace workspace;
  final ClaudeJob job;
  final void Function(String) onMessage;

  @override
  State<_ConvertTab> createState() => _ConvertTabState();
}

class _ConvertTabState extends State<_ConvertTab> {
  final _notes = TextEditingController();
  final _ask = TextEditingController();
  late final _model = TextEditingController(text: widget.job.model);

  @override
  void dispose() {
    _notes.dispose();
    _ask.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.workspace;
    final job = widget.job;
    final item = ws.selected;
    if (item == null) {
      return const Center(child: Text('Add an image from the left panel.'));
    }
    final hasSession = item.readJob()['sessionId'] != null;
    final busyHere = job.running && job.runningFor == item.id;
    final busyElsewhere = job.running && !busyHere;
    return ListView(
      children: [
        _section('Reference', [
          if (item.reference != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(item.reference!, height: 150, fit: BoxFit.contain),
            ),
          const SizedBox(height: 6),
          Text(item.id, style: const TextStyle(fontSize: 12)),
        ]),
        _section('Run the skill', [
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              hintText: 'Notes for Claude (optional): what the object is, intended use, details that matter…',
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          if (busyHere)
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
              onPressed: job.stop,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            )
          else ...[
            FilledButton.icon(
              onPressed: busyElsewhere
                  ? null
                  : () => job.start(item, ClaudeJob.convertPrompt(ws.root, item, _notes.text), resume: false),
              icon: const Icon(Icons.auto_awesome),
              label: Text(hasSession ? 'Convert again (new session)' : 'Convert'),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: !hasSession || busyElsewhere
                  ? null
                  : () => job.start(item, ClaudeJob.continuePrompt(ws.root, item, ''), resume: true),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Continue'),
            ),
          ],
          if (busyElsewhere)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Running for ${job.runningFor}…', style: const TextStyle(fontSize: 12)),
            ),
        ]),
        _section('Ask Claude', [
          TextField(
            controller: _ask,
            minLines: 2,
            maxLines: 5,
            enabled: hasSession && !job.running,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: hasSession ? 'e.g. "The lid is too thin; the handle sits too low."' : 'Convert first.',
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: !hasSession || job.running || _ask.text.trim().isEmpty
                ? null
                : () {
                    job.start(item, ClaudeJob.continuePrompt(ws.root, item, _ask.text), resume: true);
                    _ask.clear();
                  },
            icon: const Icon(Icons.send),
            label: const Text('Send to this session'),
          ),
        ]),
        _section('Claude Code', [
          DropdownButtonFormField<ClaudePermissions>(
            initialValue: job.permissions,
            isDense: true,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Permissions'),
            items: [
              for (final p in ClaudePermissions.values)
                DropdownMenuItem(
                  value: p,
                  child: Text(p.label, style: const TextStyle(fontSize: 13)),
                ),
            ],
            onChanged: job.running ? null : (p) => job.permissions = p!,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _model,
            enabled: !job.running,
            onChanged: (v) => job.model = v,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'Model (empty = default)',
            ),
            style: const TextStyle(fontSize: 13),
          ),
        ]),
        _section('Preview', [
          _switch(
            'Draft preview',
            ws.draft,
            ws.setDraft,
            subtitle: 'Show the spec even while strict-quality blocks it. Never evidence a pass is done.',
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              OutlinedButton(onPressed: () => ws.reloadPreview(regenerate: true), child: const Text('Regenerate')),
              OutlinedButton(
                onPressed: !item.spec.existsSync()
                    ? null
                    : () async => widget.onMessage('Export: ${await ws.exportDart()}'),
                child: const Text('Export Dart'),
              ),
              OutlinedButton(onPressed: () => revealInFinder(item.dir.path), child: const Text('Reveal folder')),
            ],
          ),
        ]),
      ],
    );
  }
}

class _LightTab extends StatelessWidget {
  const _LightTab({required this.settings});

  final ViewSettings settings;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    return ListView(
      children: [
        _section('Key light', [
          _slider('Strength', s.keyIntensity, 0, 12, (v) => s.update((s) => s.keyIntensity = v)),
          _slider(
            'Direction',
            s.lightAzimuth,
            -180,
            180,
            (v) => s.update((s) => s.lightAzimuth = v),
            format: (v) => '${v.round()}°',
          ),
          _slider(
            'Height',
            s.lightElevation,
            -10,
            90,
            (v) => s.update((s) => s.lightElevation = v),
            format: (v) => '${v.round()}°',
          ),
          _switch(
            'Follows the camera',
            s.lightFollowsCamera,
            (v) => s.update((s) => s.lightFollowsCamera = v),
            subtitle: 'Off: the light stays fixed to the model while you orbit.',
          ),
        ]),
        _section('Environment', [
          _slider('Ambient (IBL)', s.environmentIntensity, 0, 3, (v) => s.update((s) => s.environmentIntensity = v)),
          _slider('Exposure', s.exposure, 0.25, 4, (v) => s.update((s) => s.exposure = v)),
          _switch('Filmic tone mapping (ACES)', s.toneMapping, (v) => s.update((s) => s.toneMapping = v)),
        ]),
        Padding(
          padding: const EdgeInsets.all(14),
          child: OutlinedButton(onPressed: s.resetLight, child: const Text('Reset light')),
        ),
      ],
    );
  }
}

class _ViewTab extends StatelessWidget {
  const _ViewTab({required this.settings, required this.orbit});

  final ViewSettings settings;
  final OrbitController orbit;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    return ListView(
      children: [
        _section('Surface', [
          RadioGroup<InspectView>(
            groupValue: s.view,
            onChanged: (v) => s.update((s) => s.view = v!),
            child: Column(
              children: [
                for (final v in InspectView.values)
                  RadioListTile<InspectView>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: v,
                    title: Text(v.label, style: const TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ),
          if (s.view.hint.isNotEmpty) Text(s.view.hint, style: const TextStyle(fontSize: 11)),
          _switch('Wireframe overlay  (W)', s.wireframe, (v) => s.update((s) => s.wireframe = v)),
        ]),
        _section('Camera', [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (label, yaw, pitch) in const [
                ('Front', 0.0, 0.0),
                ('Right', 90.0, 0.0),
                ('Back', 180.0, 0.0),
                ('Left', 270.0, 0.0),
                ('Top', 0.0, 89.0),
                ('¾', 35.0, 20.0),
              ])
                ActionChip(label: Text(label), onPressed: () => orbit.preset(yaw, pitch)),
              ActionChip(label: const Text('Reset'), onPressed: orbit.reset),
            ],
          ),
          const SizedBox(height: 8),
          _slider(
            'Field of view',
            s.fovDegrees,
            10,
            90,
            (v) => s.update((s) => s.fovDegrees = v),
            format: (v) => '${v.round()}°',
          ),
          _switch('Auto-rotate  (Space)', s.autoRotate, (v) => s.update((s) => s.autoRotate = v)),
          _switch('Floor grid  (G)', s.grid, (v) => s.update((s) => s.grid = v)),
        ]),
        _section('Backdrop', [
          Wrap(
            spacing: 6,
            children: [
              for (final b in Backdrop.values)
                ChoiceChip(
                  label: Text(b.label),
                  selected: s.backdrop == b,
                  onSelected: (_) => s.update((s) => s.backdrop = b),
                ),
            ],
          ),
        ]),
        _section('Reference image', [
          SegmentedButton<ReferenceMode>(
            segments: [for (final m in ReferenceMode.values) ButtonSegment(value: m, label: Text(m.label))],
            selected: {s.reference},
            onSelectionChanged: (v) => s.update((s) => s.reference = v.first),
            showSelectedIcon: false,
          ),
          if (s.reference == ReferenceMode.overlay)
            _slider('Overlay opacity', s.referenceOpacity, 0, 1, (v) => s.update((s) => s.referenceOpacity = v)),
          if (s.reference == ReferenceMode.overlay)
            const Text(
              'Tip: Front view (F) lines the model up with a front-facing photo.',
              style: TextStyle(fontSize: 11),
            ),
        ]),
      ],
    );
  }
}

class _PartsTab extends StatelessWidget {
  const _PartsTab({required this.workspace, required this.settings});

  final Workspace workspace;
  final ViewSettings settings;

  @override
  Widget build(BuildContext context) {
    final scene = workspace.preview.scene;
    final s = settings;
    if (scene == null) return const Center(child: Text('No model loaded.'));
    final depth = <String, int>{};
    for (final p in scene.parts) {
      depth[p.id] = p.parent == null ? 0 : (depth[p.parent] ?? 0) + 1;
    }
    return ListView(
      children: [
        _section('Layout', [
          _slider('Explode', s.explode, 0, 1, (v) => s.update((s) => s.explode = v)),
          _switch('Isolate selected part', s.isolate, (v) => s.update((s) => s.isolate = v)),
          _switch('Tint selected part', s.tintSelected, (v) => s.update((s) => s.tintSelected = v)),
          Row(
            children: [
              TextButton(onPressed: () => s.update((s) => s.hidden.clear()), child: const Text('Show all')),
              TextButton(onPressed: () => s.update((s) => s.selected = null), child: const Text('Clear selection')),
            ],
          ),
        ]),
        _section('Parts (${scene.parts.length})', [
          for (final p in scene.parts)
            Material(
              color: s.selected == p.id ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.18) : null,
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                onTap: () => s.update((s) => s.selected = s.selected == p.id ? null : p.id),
                child: Padding(
                  padding: EdgeInsets.only(left: 12.0 * depth[p.id]!),
                  child: Row(
                    children: [
                      IconButton(
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(s.hidden.contains(p.id) ? Icons.visibility_off : Icons.visibility),
                        onPressed: () =>
                            s.update((s) => s.hidden.contains(p.id) ? s.hidden.remove(p.id) : s.hidden.add(p.id)),
                      ),
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: Color(p.color), borderRadius: BorderRadius.circular(2)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.name, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                            Text('${p.id} · ${p.kind}', style: const TextStyle(fontSize: 11)),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Focus the camera on this part',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.center_focus_weak),
                        onPressed: () => s.update(
                          (s) => s
                            ..selected = p.id
                            ..focusRequest = p.id,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ]),
      ],
    );
  }
}

class _InfoTab extends StatelessWidget {
  const _InfoTab({required this.workspace});

  final Workspace workspace;

  @override
  Widget build(BuildContext context) {
    final item = workspace.selected;
    final scene = workspace.preview.scene;
    if (item == null) return const SizedBox();
    Widget file(String label, String path) {
      final exists = FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(exists ? Icons.description : Icons.remove_circle_outline, size: 18),
        title: Text(label, style: const TextStyle(fontSize: 13)),
        subtitle: Text(path.split('/').last, style: const TextStyle(fontSize: 11)),
        onTap: exists ? () => revealInFinder(path) : null,
      );
    }

    return ListView(
      children: [
        if (scene != null)
          _section('Model', [
            Text(scene.target, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('Pass: ${scene.pass}${workspace.preview.draft ? '  (DRAFT)' : ''}'),
            Text('Parts: ${scene.parts.length} · materials: ${scene.materials.length}'),
            Text('Factory: ${scene.factory}()'),
          ]),
        if (scene != null) _section('Geometry', _geometryStats(scene)),
        if (scene != null && scene.omitted.isNotEmpty)
          _section('Not built (unsupported yet)', [
            for (final o in scene.omitted) Text('• $o', style: TextStyle(fontSize: 12, color: Colors.red.shade300)),
          ]),
        if (scene != null && scene.unapplied.isNotEmpty)
          _section('Built without these refinements', [
            for (final o in scene.unapplied) Text('• $o', style: TextStyle(fontSize: 12, color: Colors.amber.shade300)),
          ]),
        _section('Files in ${item.id}/', [
          file('Reference', item.reference?.path ?? '${item.dir.path}/reference'),
          file('Sculpt spec', item.spec.path),
          file('Preview (scene-json)', item.scene.path),
          file('Dart factory', item.dart.path),
          file('Claude log', item.claudeLog.path),
          file('Screenshots', item.shots.path),
        ]),
      ],
    );
  }
}
