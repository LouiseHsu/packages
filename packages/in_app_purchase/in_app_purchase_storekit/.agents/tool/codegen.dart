// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

/// Outcome of running package code generation tools.
class CodeGenResult {
  /// Creates a [CodeGenResult].
  const CodeGenResult({required this.exitCode, required this.stdout, required this.stderr});

  /// The exit code of the code generation process.
  final int exitCode;

  /// Standard output produced during code generation.
  final String stdout;

  /// Standard error produced during code generation.
  final String stderr;

  /// Whether code generation completed successfully.
  bool get success => exitCode == 0;
}

/// Interface for executing package code generation (e.g. Pigeon).
abstract class CodeGenerator {
  /// Runs code generators applicable to [packagePath].
  Future<CodeGenResult> generate({required String packagePath, required String packageName});
}

/// Default code generator that handles Pigeon definitions and formatting.
class DefaultCodeGenerator implements CodeGenerator {
  /// Creates a [DefaultCodeGenerator].
  const DefaultCodeGenerator();

  @override
  Future<CodeGenResult> generate({required String packagePath, required String packageName}) async {
    final pigeonsDir = Directory('$packagePath/pigeons');
    if (!pigeonsDir.existsSync()) {
      return const CodeGenResult(
        exitCode: 0,
        stdout: 'No pigeons directory found; skipping code generation.',
        stderr: '',
      );
    }

    final List<File> pigeonFiles = pigeonsDir
        .listSync()
        .whereType<File>()
        .where((File file) => file.path.endsWith('.dart'))
        .toList();

    for (final file in pigeonFiles) {
      // Pre-flight check: ensure clean import syntax in pigeon definition
      final String content = file.readAsStringSync();
      if (content.contains("import 'package:pigeon/pigeon.") &&
          !content.contains("import 'package:pigeon/pigeon.dart';")) {
        final String sanitized = content.replaceAll(
          RegExp(r'''import\s+['"]package:pigeon/pigeon\b[^;]*;?'''),
          "import 'package:pigeon/pigeon.dart';",
        );
        file.writeAsStringSync(sanitized);
      }

      final relativePath = 'pigeons/${file.uri.pathSegments.last}';
      final ProcessResult result = await Process.run('dart', <String>[
        'run',
        'pigeon',
        '--input',
        relativePath,
      ], workingDirectory: packagePath);

      if (result.exitCode != 0) {
        return CodeGenResult(
          exitCode: result.exitCode,
          stdout: result.stdout as String? ?? '',
          stderr: result.stderr as String? ?? '',
        );
      }
    }

    await Process.run('dart', <String>['format', packagePath], workingDirectory: packagePath);

    final String nativeSummary = await formatNativeSources(packagePath);

    return CodeGenResult(
      exitCode: 0,
      stdout: 'Pigeon code generation completed successfully.\n$nativeSummary',
      stderr: '',
    );
  }

  /// Formats native sources this run modified, matching the repository's own
  /// format check (`script/tool format`).
  ///
  /// Pigeon emits unformatted output, but the checked-in `.g.m`/`.g.h`/
  /// `.g.swift` files are clang-format/swift-format clean. Without this step a
  /// single regeneration rewrites them in the generator's raw style, producing
  /// hundreds of lines of diff that have nothing to do with the fix and that
  /// fail the repository's format check.
  ///
  /// Only files this run actually changed are formatted. Reformatting the whole
  /// package would drag in unrelated churn whenever the local formatter version
  /// differs from the one that produced the committed files.
  ///
  /// Missing formatters are skipped rather than failed, so the harness still
  /// works on a machine without them (`swift-format` runs via `xcrun`, so it is
  /// macOS-only, which mirrors `script/tool`).
  ///
  /// Returns a human-readable summary of what was formatted or skipped.
  Future<String> formatNativeSources(String packagePath) async {
    final List<String> changed = await _changedFiles(packagePath);
    final List<String> clangFiles = changed
        .where((String f) => _clangExtensions.any(f.endsWith))
        .toList();
    final List<String> swiftFiles = changed.where((String f) => f.endsWith('.swift')).toList();

    final notes = <String>[];

    if (clangFiles.isNotEmpty) {
      if (await _hasExecutable('clang-format')) {
        // `--style=file` picks up the repository's root .clang-format.
        final ProcessResult result = await Process.run('clang-format', <String>[
          '-i',
          '--style=file',
          ...clangFiles,
        ], workingDirectory: packagePath);
        notes.add(
          result.exitCode == 0
              ? 'Formatted ${clangFiles.length} C/ObjC file(s).'
              : 'clang-format failed: ${result.stderr}',
        );
      } else {
        notes.add('Skipped C/ObjC formatting: clang-format not found on PATH.');
      }
    }

    if (swiftFiles.isNotEmpty) {
      if (Platform.isMacOS && await _hasExecutable('xcrun')) {
        final ProcessResult result = await Process.run('xcrun', <String>[
          'swift-format',
          '-i',
          ...swiftFiles,
        ], workingDirectory: packagePath);
        notes.add(
          result.exitCode == 0
              ? 'Formatted ${swiftFiles.length} Swift file(s).'
              : 'swift-format failed: ${result.stderr}',
        );
      } else {
        notes.add('Skipped Swift formatting: swift-format requires macOS/xcrun.');
      }
    }

    return notes.isEmpty ? 'No native sources needed formatting.' : notes.join(' ');
  }

  /// Absolute paths of native files added or modified under [packagePath].
  Future<List<String>> _changedFiles(String packagePath) async {
    final paths = <String>{};
    for (final args in <List<String>>[
      <String>['diff', '--name-only', 'HEAD'],
      <String>['ls-files', '--others', '--exclude-standard'],
    ]) {
      final ProcessResult result = await Process.run('git', args, workingDirectory: packagePath);
      if (result.exitCode != 0) {
        continue;
      }
      for (final String line in (result.stdout as String? ?? '').split('\n')) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.contains('/Pods/')) {
          continue;
        }
        paths.add(trimmed);
      }
    }

    // git reports paths relative to the repository root, which is above the
    // package, so resolve them before handing them to a formatter.
    final ProcessResult root = await Process.run('git', <String>[
      'rev-parse',
      '--show-toplevel',
    ], workingDirectory: packagePath);
    if (root.exitCode != 0) {
      return <String>[];
    }
    final String repoRoot = (root.stdout as String).trim();

    return paths
        .map((String p) => '$repoRoot/$p')
        .where((String p) => File(p).existsSync())
        .toList();
  }

  static const Set<String> _clangExtensions = <String>{'.m', '.mm', '.h', '.cc', '.cpp'};

  Future<bool> _hasExecutable(String name) async {
    final ProcessResult result = await Process.run('which', <String>[name]);
    return result.exitCode == 0;
  }
}
