// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';
import '../publisher.dart';

/// Runs [args] in [dir], throwing if the command fails.
///
/// Used for fixture setup only, where a silent failure would produce a
/// confusing assertion failure later instead of an obvious error here.
void _git(List<String> args, String dir) {
  final ProcessResult result = Process.runSync('git', args, workingDirectory: dir);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

/// Returns the branch currently checked out in [dir].
String _currentBranch(String dir) {
  final ProcessResult result = Process.runSync('git', <String>[
    'rev-parse',
    '--abbrev-ref',
    'HEAD',
  ], workingDirectory: dir);
  return (result.stdout as String).trim();
}

void main() {
  group('GitHubPrPublisher branch handling', () {
    late Directory repo;

    setUp(() {
      // Each test gets its own throwaway repository, so these tests are
      // hermetic and never touch the developer's real checkout.
      repo = Directory.systemTemp.createTempSync('publisher_repo_');
      _git(<String>['init', '--initial-branch=main'], repo.path);
      _git(<String>['config', 'user.email', 'harness@example.com'], repo.path);
      _git(<String>['config', 'user.name', 'Harness Test'], repo.path);
      File('${repo.path}/seed.txt').writeAsStringSync('seed\n');
      _git(<String>['add', 'seed.txt'], repo.path);
      _git(<String>['commit', '-m', 'seed'], repo.path);
    });

    tearDown(() {
      if (repo.existsSync()) {
        repo.deleteSync(recursive: true);
      }
    });

    test('returns to the original branch after publishing fails', () async {
      _git(<String>['checkout', '-b', 'my-feature'], repo.path);
      File('${repo.path}/fix.dart').writeAsStringSync('// generated fix\n');

      final context = HarnessContext(
        issueNumber: 7,
        isDryRun: false,
        publishPr: true,
        packagePath: repo.path,
      )..validatedModifiedFiles.add('fix.dart');

      // No 'origin' remote is configured, so publishing commits to the agent
      // branch and then fails at the push step.
      final PrPublishResult result = await const GitHubPrPublisher().publishDraftPr(context);

      expect(result.success, isFalse);
      expect(
        _currentBranch(repo.path),
        'my-feature',
        reason: 'A failed publish must not leave the caller on the agent branch.',
      );
    });

    test('leaves the generated commit on the agent branch', () async {
      _git(<String>['checkout', '-b', 'my-feature'], repo.path);
      File('${repo.path}/fix.dart').writeAsStringSync('// generated fix\n');

      final context = HarnessContext(
        issueNumber: 7,
        isDryRun: false,
        publishPr: true,
        packagePath: repo.path,
      )..validatedModifiedFiles.add('fix.dart');

      await const GitHubPrPublisher().publishDraftPr(context);

      // Restoring the branch must not move the agent's commit onto the
      // caller's branch, nor discard it.
      final ProcessResult featureLog = Process.runSync('git', <String>[
        'log',
        '--oneline',
        'my-feature',
      ], workingDirectory: repo.path);
      expect((featureLog.stdout as String).contains('issue #7'), isFalse);

      final ProcessResult agentFiles = Process.runSync('git', <String>[
        'ls-tree',
        '--name-only',
        'agent/fix-issue-7',
      ], workingDirectory: repo.path);
      expect((agentFiles.stdout as String).contains('fix.dart'), isTrue);
    });

    test('stays on the original branch when publishing is skipped', () async {
      _git(<String>['checkout', '-b', 'my-feature'], repo.path);

      final context = HarnessContext(issueNumber: 7, isDryRun: true, packagePath: repo.path);

      final PrPublishResult result = await const GitHubPrPublisher().publishDraftPr(context);

      expect(result.success, isTrue);
      expect(_currentBranch(repo.path), 'my-feature');
    });

    test('preserves uncommitted work when the restore checkout is refused', () async {
      _git(<String>['checkout', '-b', 'my-feature'], repo.path);
      // Nothing is staged, so the commit step fails and the agent branch keeps
      // this file as an uncommitted change.
      File('${repo.path}/scratch.txt').writeAsStringSync('unsaved work\n');

      final context = HarnessContext(
        issueNumber: 7,
        isDryRun: false,
        publishPr: true,
        packagePath: repo.path,
      );

      await const GitHubPrPublisher().publishDraftPr(context);

      expect(
        File('${repo.path}/scratch.txt').existsSync(),
        isTrue,
        reason: 'Restoring the branch must never discard uncommitted work.',
      );
      expect(File('${repo.path}/scratch.txt').readAsStringSync(), 'unsaved work\n');
    });
  });
}
