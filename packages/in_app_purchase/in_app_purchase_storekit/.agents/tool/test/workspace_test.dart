// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../workspace.dart';

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

void main() {
  group('GitWorkspace', () {
    late Directory repo;
    // Opted in explicitly: every test here points at a throwaway repository
    // created in setUp, never the developer's checkout.
    const workspace = GitWorkspace(allowInTests: true);

    setUp(() {
      // Reverting is destructive by design, so it is only ever exercised
      // against a throwaway repository, never the developer's checkout.
      repo = Directory.systemTemp.createTempSync('workspace_repo_');
      _git(<String>['init', '--initial-branch=main'], repo.path);
      _git(<String>['config', 'user.email', 'harness@example.com'], repo.path);
      _git(<String>['config', 'user.name', 'Harness Test'], repo.path);
      File('${repo.path}/tracked.dart').writeAsStringSync('original\n');
      _git(<String>['add', '.'], repo.path);
      _git(<String>['commit', '-m', 'seed'], repo.path);
    });

    tearDown(() {
      if (repo.existsSync()) {
        repo.deleteSync(recursive: true);
      }
    });

    test('restores a modified tracked file', () async {
      File('${repo.path}/tracked.dart').writeAsStringSync('agent edit\n');

      await workspace.revert(repo.path, <String>{});

      expect(File('${repo.path}/tracked.dart').readAsStringSync(), 'original\n');
    });

    test('deletes untracked files the attempt created', () async {
      final Set<String> baseline = await workspace.untrackedFiles(repo.path);
      File('${repo.path}/created_by_agent.dart').writeAsStringSync('new\n');

      final RevertResult result = await workspace.revert(repo.path, baseline);

      expect(File('${repo.path}/created_by_agent.dart').existsSync(), isFalse);
      expect(result.removedFiles, contains('created_by_agent.dart'));
    });

    test('preserves untracked files that predate the attempt', () async {
      File('${repo.path}/developers_scratch.dart').writeAsStringSync('mine\n');
      final Set<String> baseline = await workspace.untrackedFiles(repo.path);
      File('${repo.path}/created_by_agent.dart').writeAsStringSync('new\n');

      final RevertResult result = await workspace.revert(repo.path, baseline);

      // Anything already untracked belongs to the developer. Deleting it would
      // destroy work the harness never made and cannot restore.
      expect(File('${repo.path}/developers_scratch.dart').existsSync(), isTrue);
      expect(File('${repo.path}/created_by_agent.dart').existsSync(), isFalse);
      expect(result.removedFiles, <String>['created_by_agent.dart']);
    });

    test('never reverts the harness own sources', () async {
      final agentsDir = Directory('${repo.path}/.agents/tool')..createSync(recursive: true);
      File('${agentsDir.path}/harness.dart').writeAsStringSync('v1\n');
      _git(<String>['add', '.'], repo.path);
      _git(<String>['commit', '-m', 'add tooling'], repo.path);

      File('${agentsDir.path}/harness.dart').writeAsStringSync('v2 in progress\n');
      File('${repo.path}/tracked.dart').writeAsStringSync('agent edit\n');

      await workspace.revert(repo.path, <String>{});

      // The harness lives inside the package it operates on, so a blanket
      // revert would discard the tool's own source while it is running.
      expect(File('${agentsDir.path}/harness.dart').readAsStringSync(), 'v2 in progress\n');
      expect(File('${repo.path}/tracked.dart').readAsStringSync(), 'original\n');
    });

    test('untrackedFiles excludes the harness own sources', () async {
      Directory('${repo.path}/.agents/tool').createSync(recursive: true);
      File('${repo.path}/.agents/tool/scratch.dart').writeAsStringSync('x\n');
      File('${repo.path}/elsewhere.dart').writeAsStringSync('y\n');

      final Set<String> untracked = await workspace.untrackedFiles(repo.path);

      expect(untracked, contains('elsewhere.dart'));
      expect(untracked.any((String p) => p.contains('.agents/')), isFalse);
    });

    test('reports a warning instead of throwing outside a repository', () async {
      final Directory plainDir = Directory.systemTemp.createTempSync('workspace_plain_');
      addTearDown(() => plainDir.deleteSync(recursive: true));

      final RevertResult result = await workspace.revert(plainDir.path, <String>{});

      expect(result.warnings, isNotEmpty);
      expect(result.warnings.first, contains('Could not revert'));
    });
    test('refuses to revert from a test process unless opted in', () async {
      const guarded = GitWorkspace();
      File('${repo.path}/tracked.dart').writeAsStringSync('uncommitted work\n');

      final RevertResult result = await guarded.revert(repo.path, <String>{});

      // The default must be inert under `flutter test`. A single test that
      // forgets to inject a fake would otherwise wipe the developer's tree.
      expect(File('${repo.path}/tracked.dart').readAsStringSync(), 'uncommitted work\n');
      expect(result.warnings.single, contains('Refused to revert'));
    });
  });
}
