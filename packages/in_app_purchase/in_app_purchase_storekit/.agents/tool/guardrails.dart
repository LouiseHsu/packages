// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

/// Outcome of running Phase 3 validation and guardrail checks.
class ValidationResult {
  /// Creates a [ValidationResult].
  const ValidationResult({
    required this.isValid,
    this.failureReason,
    this.modifiedFiles = const <String>[],
  });

  /// Whether all guardrail and hygiene checks passed.
  final bool isValid;

  /// The reason for failure, if any.
  final String? failureReason;

  /// List of modified files detected during validation.
  final List<String> modifiedFiles;
}

/// Interface for validating guardrails, git diff boundaries, and code hygiene.
abstract class GuardrailValidator {
  /// Validates git diff against forbidden file patterns and checks hygiene.
  Future<ValidationResult> validate({required String packagePath, required String packageName});
}

/// Default validator enforcing repository invariants and code hygiene.
class DefaultGuardrailValidator implements GuardrailValidator {
  /// Creates a [DefaultGuardrailValidator].
  const DefaultGuardrailValidator();

  /// Inspects modified files for prohibited files (e.g. pubspec.yaml, CHANGELOG.md).
  static String? checkForbiddenFiles(Iterable<String> filePaths) {
    for (final path in filePaths) {
      if (path.endsWith('pubspec.yaml')) {
        return 'Guardrail Invariant Violated: Modifications to pubspec.yaml are strictly prohibited.';
      }
      if (path.endsWith('CHANGELOG.md')) {
        return 'Guardrail Invariant Violated: Modifications to CHANGELOG.md are strictly prohibited.';
      }
    }
    return null;
  }

  /// Ensures that all modified code files belong to the target package.
  static String? checkPackageBoundary(Iterable<String> filePaths, {required String packageName}) {
    for (final path in filePaths) {
      if (path.contains('.agents/')) {
        continue;
      }
      if (!path.contains(packageName)) {
        return 'Guardrail Invariant Violated: File "$path" is outside package boundary for "$packageName".';
      }
    }
    return null;
  }

  @override
  Future<ValidationResult> validate({
    required String packagePath,
    required String packageName,
  }) async {
    final modifiedFiles = <String>[];

    final ProcessResult diffResult = await Process.run('git', <String>[
      'diff',
      '--name-only',
      'HEAD',
    ]);
    if (diffResult.exitCode == 0) {
      final String output = diffResult.stdout as String? ?? '';
      for (final String line in output.split('\n')) {
        final String trimmed = line.trim();
        if (trimmed.isNotEmpty && !modifiedFiles.contains(trimmed)) {
          modifiedFiles.add(trimmed);
        }
      }
    }

    final ProcessResult untrackedResult = await Process.run('git', <String>[
      'ls-files',
      '--others',
      '--exclude-standard',
    ]);
    if (untrackedResult.exitCode == 0) {
      final String output = untrackedResult.stdout as String? ?? '';
      for (final String line in output.split('\n')) {
        final String trimmed = line.trim();
        if (trimmed.isNotEmpty && !modifiedFiles.contains(trimmed)) {
          modifiedFiles.add(trimmed);
        }
      }
    }

    // Never include internal .agents tooling files in package PRs or validation
    modifiedFiles.removeWhere((file) => file.contains('.agents/'));

    final String? forbiddenError = checkForbiddenFiles(modifiedFiles);
    if (forbiddenError != null) {
      return ValidationResult(
        isValid: false,
        failureReason: forbiddenError,
        modifiedFiles: modifiedFiles,
      );
    }

    final String? boundaryError = checkPackageBoundary(modifiedFiles, packageName: packageName);
    if (boundaryError != null) {
      return ValidationResult(
        isValid: false,
        failureReason: boundaryError,
        modifiedFiles: modifiedFiles,
      );
    }

    // Format package files to Flutter repo standards
    await Process.run('dart', <String>['format', packagePath]);

    final ProcessResult analyzeResult = await Process.run('dart', <String>['analyze', packagePath]);
    if (analyzeResult.exitCode != 0) {
      final String stderr = analyzeResult.stderr as String? ?? '';
      final String stdout = analyzeResult.stdout as String? ?? '';
      return ValidationResult(
        isValid: false,
        failureReason: 'Static analysis check failed for $packageName:\n$stderr\n$stdout',
        modifiedFiles: modifiedFiles,
      );
    }

    return ValidationResult(isValid: true, modifiedFiles: modifiedFiles);
  }
}
