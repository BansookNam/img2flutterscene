import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:img2flutterscene_util/src/claude_job.dart';
import 'package:img2flutterscene_util/src/view_settings.dart';
import 'package:img2flutterscene_util/src/workspace.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  group('Claude Code stream-json', () {
    test('a recorded headless run becomes text and a finished line', () {
      // test/fixtures/claude_stream.jsonl is real `claude -p --output-format
      // stream-json --verbose` output (account fields stripped).
      final entries = [
        for (final line in File('test/fixtures/claude_stream.jsonl').readAsLinesSync())
          ...ClaudeJob.parseClaudeEvent(line),
      ];
      expect(entries.map((e) => e.kind), [LogKind.text, LogKind.done]);
      expect(entries.first.text, 'OK');
      expect(entries.last.text, startsWith('Run finished · 1 turns · \$0.16'));
    });

    test('tool calls are summarised by their command or path', () {
      final line = jsonEncode({
        'type': 'assistant',
        'message': {
          'content': [
            {
              'type': 'tool_use',
              'name': 'Bash',
              'input': {'command': 'python3 forge/next.py --state work/x/.img2threejs/state.json', 'description': 'd'},
            },
          ],
        },
      });
      final [e] = ClaudeJob.parseClaudeEvent(line);
      expect(e.kind, LogKind.tool);
      expect(e.text, 'Bash  python3 forge/next.py --state work/x/.img2threejs/state.json');
    });

    test('failed tool results and failed runs are errors; noise is dropped', () {
      final denied = jsonEncode({
        'type': 'user',
        'message': {
          'content': [
            {'type': 'tool_result', 'is_error': true, 'content': 'Permission denied: rm'},
            {'type': 'tool_result', 'is_error': false, 'content': 'fine'},
          ],
        },
      });
      expect(ClaudeJob.parseClaudeEvent(denied).single.kind, LogKind.error);
      final failed = jsonEncode({'type': 'result', 'is_error': true, 'result': 'max turns'});
      expect(ClaudeJob.parseClaudeEvent(failed).single.kind, LogKind.error);
      expect(ClaudeJob.parseClaudeEvent(''), isEmpty);
      expect(ClaudeJob.parseClaudeEvent('not json').single.kind, LogKind.info);
    });
  });

  group('prompts keep the model local', () {
    late Directory repo;
    setUp(() => repo = Directory.systemTemp.createTempSync('i2fs_repo'));
    tearDown(() => repo.deleteSync(recursive: true));

    test('convert names work/<id>/ paths, the preview file and no-questions rule', () {
      final item = WorkItem(Directory('${repo.path}/work/chest-1018-1200'))..dir.createSync(recursive: true);
      File('${item.dir.path}/reference.jpg').writeAsStringSync('x');
      final p = ClaudeJob.convertPrompt(repo.path, item, 'It is a pirate chest.');
      expect(p, contains('reconstruct the object in work/chest-1018-1200/reference.jpg'));
      expect(p, contains('state at work/chest-1018-1200/.img2threejs/state.json'));
      expect(p, contains('--format scene-json --out work/chest-1018-1200/model.scene.json'));
      expect(p, contains('Do not edit tracked files'));
      expect(p, contains('Nobody can answer questions'));
      expect(p, contains('It is a pirate chest.'));
      expect(p, isNot(contains(repo.path)), reason: 'paths are repo-relative');
    });
  });

  group('workspace', () {
    late Directory repo;
    setUp(() => repo = Directory.systemTemp.createTempSync('i2fs_repo'));
    tearDown(() => repo.deleteSync(recursive: true));

    test('create copies the image into a new work/ folder; delete removes it', () {
      final image = File('${repo.path}/My Chest!.PNG')..writeAsBytesSync([1, 2, 3]);
      final ws = Workspace(repo.path);
      final item = ws.create(image.path);
      expect(item.id, matches(RegExp(r'^my-chest--\d{4}-\d{4}$')));
      expect(item.reference!.path, endsWith('/reference.png'));
      expect(item.reference!.readAsBytesSync(), [1, 2, 3]);
      expect(item.readJob()['source'], image.path);
      expect(ws.items.map((w) => w.id), [item.id]);
      ws.delete(item);
      expect(item.dir.existsSync(), isFalse);
      expect(ws.items, isEmpty);
      ws.dispose();
    });

    test('a BLOCKED report becomes a short reason', () {
      final stderr =
          'UNAPPLIED x\n${jsonEncode({
            'status': 'BLOCKED',
            'gate': 'strict-quality',
            'cause': ['no featureReviewTargets', 'one root only'],
          })}';
      expect(
        Workspace.blockedSummary(stderr),
        'Generator blocked (strict-quality):\n• no featureReviewTargets\n• one root only',
      );
    });
  });

  group('camera and light frame', () {
    void close(vm.Vector3 a, vm.Vector3 b) {
      for (var i = 0; i < 3; i++) {
        expect(a[i], closeTo(b[i], 1e-6), reason: 'axis $i of $a vs $b');
      }
    }

    test('front view: camera on −Z, +X on screen right', () {
      close(horizontalEye(0), vm.Vector3(0, 0, -1));
      close(screenRight(0), vm.Vector3(1, 0, 0));
      // Yaw 90 looks at the model's own right side (spec −X).
      close(horizontalEye(math.pi / 2), vm.Vector3(-1, 0, 0));
      for (final yaw in [0.0, 0.7, 2.5]) {
        expect(screenRight(yaw).dot(horizontalEye(yaw)), closeTo(0, 1e-9));
      }
    });

    test('light azimuth + comes from screen-right, 0 from behind the camera', () {
      final s = ViewSettings()
        ..lightElevation = 0
        ..lightAzimuth = 90;
      // Source on +X (screen right) => the light travels toward −X.
      close(s.lightDirection(0), vm.Vector3(-1, 0, 0));
      s.lightAzimuth = 0;
      close(s.lightDirection(0), vm.Vector3(0, 0, 1));
      s.lightElevation = 90;
      close(s.lightDirection(0), vm.Vector3(0, -1, 0));
    });

    test('following the camera keeps the light on the viewer side', () {
      final s = ViewSettings()
        ..lightElevation = 0
        ..lightAzimuth = 0;
      final yaw = math.pi / 2;
      // Camera on −X: a head-on light travels toward +X.
      close(s.lightDirection(yaw), vm.Vector3(1, 0, 0));
      s.lightFollowsCamera = false;
      close(s.lightDirection(yaw), vm.Vector3(0, 0, 1));
    });
  });
}
