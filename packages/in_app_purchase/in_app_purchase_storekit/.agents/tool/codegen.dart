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

    return const CodeGenResult(
      exitCode: 0,
      stdout: 'Pigeon code generation completed successfully.',
      stderr: '',
    );
  }
}
