import 'dart:convert';
import 'dart:io';

/// Quotes [arg] for zsh.
String shellQuote(String arg) => "'${arg.replaceAll("'", r"'\''")}'";

/// Starts [args] through a login zsh, so the user's PATH (python3, claude,
/// flutter) applies even though a GUI app starts with a bare one. `exec`
/// makes the child replace the shell, so killing the process kills the tool.
Future<Process> startLogin(List<String> args, {required String cwd}) =>
    Process.start('/bin/zsh', ['-lc', 'exec ${args.map(shellQuote).join(' ')}'], workingDirectory: cwd);

/// Runs [args] through a login zsh and collects its output.
Future<ProcessResult> runLogin(List<String> args, {required String cwd}) => Process.run(
  '/bin/zsh',
  ['-lc', 'exec ${args.map(shellQuote).join(' ')}'],
  workingDirectory: cwd,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

/// The native macOS file dialog for one image; null when cancelled.
Future<String?> chooseImage() async {
  final r = await Process.run('osascript', [
    '-e',
    'POSIX path of (choose file of type {"public.image"} with prompt "Choose a reference image")',
  ]);
  final path = (r.stdout as String).trim();
  return r.exitCode == 0 && path.isNotEmpty ? path : null;
}

/// The native macOS folder dialog; null when cancelled.
Future<String?> chooseFolder(String prompt) async {
  final r = await Process.run('osascript', ['-e', 'POSIX path of (choose folder with prompt "$prompt")']);
  final path = (r.stdout as String).trim();
  return r.exitCode == 0 && path.isNotEmpty ? path : null;
}

/// Shows [path] in Finder.
Future<void> revealInFinder(String path) => Process.run('open', ['-R', path]);
