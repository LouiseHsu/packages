// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

/// What a [Workspace.revert] did, for the caller to log.
///
/// Returned rather than logged directly so the workspace stays free of any
/// dependency on the harness's context and stays trivially fakeable in tests.
class RevertResult {
  /// Creates a [RevertResult].
  const RevertResult({this.removedFiles = const <String>[], this.warnings = const <String>[]});

  /// Paths, relative to the target directory, deleted during the revert.
  final List<String> removedFiles;

  /// Non-fatal problems encountered while reverting.
  final List<String> warnings;
}

/// Interface for inspecting and restoring the state of a working tree.
///
/// Extracted behind a port because reverting is the harness's only destructive
/// operation: it discards uncommitted work by design. A test that exercises it
/// against a real checkout would delete the developer's changes, so the
/// concrete implementation is covered by hermetic tests over throwaway
/// repositories and faked everywhere else.
abstract class Workspace {
  /// Paths under [targetDir], relative to it, that are not tracked.
  Future<Set<String>> untrackedFiles(String targetDir);

  /// Restores [targetDir] to its committed state.
  ///
  /// Untracked files listed in [baselineUntracked] are preserved; untracked
  /// files created since are removed.
  Future<RevertResult> revert(String targetDir, Set<String> baselineUntracked);
}

/// A [Workspace] backed by git.
class GitWorkspace implements Workspace {
  /// Creates a [GitWorkspace].
  ///
  /// Set [allowInTests] only from a test that has pointed the workspace at a
  /// throwaway repository. See [_refusesToRun].
  const GitWorkspace({this.allowInTests = false});

  /// Whether reverting is permitted inside a test process.
  final bool allowInTests;

  /// Explains a refusal, and how a test should opt in when it really means it.
  static const String _refusalMessage =
      'Refused to revert the working tree from inside a test process. '
      'Inject a fake Workspace, or use GitWorkspace(allowInTests: true) '
      'against a throwaway repository.';

  /// Path fragment identifying the harness's own sources.
  ///
  /// The harness lives inside the package it operates on, so a blanket revert
  /// would discard the tool while it is running.
  static const String _toolingPath = '.agents';

  @override
  Future<Set<String>> untrackedFiles(String targetDir) async {
    try {
      final ProcessResult result = await Process.run('git', <String>[
        'ls-files',
        '--others',
        '--exclude-standard',
      ], workingDirectory: targetDir);
      if (result.exitCode != 0) {
        return <String>{};
      }
      return (result.stdout as String? ?? '')
          .split('\n')
          .map((String line) => line.trim())
          .where((String line) => line.isNotEmpty && !line.contains('$_toolingPath/'))
          .toSet();
    } on ProcessException {
      return <String>{};
    }
  }

  /// Whether this instance must refuse to touch the working tree.
  ///
  /// `flutter test` sets `FLUTTER_TEST`, so this is true exactly when a test
  /// process would be reverting a real checkout. Forgetting to inject a fake
  /// workspace in a single test is a silent, destructive mistake: it deletes
  /// the developer's uncommitted work as a side effect of running the suite.
  /// The dangerous path therefore fails closed instead of relying on every
  /// call site remembering.
  bool get _refusesToRun => !allowInTests && Platform.environment['FLUTTER_TEST'] == 'true';

  @override
  Future<RevertResult> revert(String targetDir, Set<String> baselineUntracked) async {
    if (_refusesToRun) {
      return const RevertResult(warnings: <String>[_refusalMessage]);
    }

    final warnings = <String>[];
    final removed = <String>[];

    // Ask git what is dirty rather than reverting a fixed list of files. A
    // hardcoded list silently fails to revert any file the agent was not
    // expected to touch, letting one attempt's edits leak into the next.
    final ProcessResult checkout = await Process.run('git', <String>[
      'checkout',
      '--',
      '.',
      ':(exclude)$_toolingPath',
    ], workingDirectory: targetDir);
    if (checkout.exitCode != 0) {
      warnings.add(
        'Could not revert tracked files: '
        '${(checkout.stderr as String? ?? '').trim()}',
      );
    }

    // Remove only files this run created. Untracked files that predate the
    // run belong to the developer and are left alone.
    final Set<String> nowUntracked = await untrackedFiles(targetDir);
    for (final String relPath in nowUntracked.difference(baselineUntracked)) {
      final file = File('$targetDir/$relPath');
      if (!file.existsSync()) {
        continue;
      }
      try {
        file.deleteSync();
        removed.add(relPath);
      } catch (e) {
        warnings.add('Could not remove $relPath: $e');
      }
    }

    return RevertResult(removedFiles: removed, warnings: warnings);
  }
}
