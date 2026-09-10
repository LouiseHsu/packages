// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'harness.dart';

/// Outcome of attempting to publish a Draft PR.
class PrPublishResult {
  /// Creates a [PrPublishResult].
  const PrPublishResult({
    required this.success,
    this.prUrl,
    this.stdout = '',
    this.stderr = '',
    this.failureReason,
  });

  /// Whether the PR creation was successful.
  final bool success;

  /// The URL of the created PR, if available.
  final String? prUrl;

  /// Standard output from git and gh commands.
  final String stdout;

  /// Standard error from git and gh commands.
  final String stderr;

  /// Error message if publishing failed.
  final String? failureReason;
}

/// Metadata and markdown formatting for Draft PRs.
class DraftPrMetadata {
  /// Creates a [DraftPrMetadata].
  const DraftPrMetadata({required this.title, required this.branchName, required this.body});

  /// Generates [DraftPrMetadata] formatted according to Flutter monorepo standards.
  factory DraftPrMetadata.fromContext(HarnessContext context) {
    final title = '[${context.packageName}] ${context.issueTitle} (fixes #${context.issueNumber})';
    final branchName = 'agent/fix-issue-${context.issueNumber}';

    final buffer = StringBuffer();
    buffer.writeln('## Summary');
    buffer.writeln('Fixes #${context.issueNumber}: ${context.issueTitle}');
    buffer.writeln();

    buffer.writeln('## Implementation Overview');
    buffer.writeln('Automated fix verified through phased TDD loop in `${context.packageName}`.');
    buffer.writeln();

    final List<String> publishableFiles =
        context.validatedModifiedFiles.where((f) => !f.contains('.agents/')).toList();
    if (publishableFiles.isNotEmpty) {
      buffer.writeln('### Modified Files');
      for (final file in publishableFiles) {
        buffer.writeln('- `$file`');
      }
      buffer.writeln();
    }

    buffer.writeln('## SWE-bench Autonomous Verification Checklist');
    buffer.writeln('- [x] **FAIL_TO_PASS**: Reproduction unit test failed on clean main.');
    buffer.writeln(
      '- [x] **PASS_TO_PASS**: Target unit test passes after code change & Pigeon codegen.',
    );
    buffer.writeln('- [x] **Zero Regressions**: Full package test suite verified green.');
    buffer.writeln('- [x] **Static Analysis**: `dart analyze` reported 0 issues.');
    buffer.writeln('- [x] **Formatting**: Fully formatted with `dart format`.');
    buffer.writeln('- [x] **Monorepo Invariant**: `pubspec.yaml` and `CHANGELOG.md` untouched.');
    buffer.writeln();
    buffer.writeln('---');
    buffer.writeln('*Autonomous Draft PR created by `.agents/tool/harness.dart`*');

    return DraftPrMetadata(title: title, branchName: branchName, body: buffer.toString());
  }

  /// The standardized commit and PR title.
  final String title;

  /// The git branch name for the PR.
  final String branchName;

  /// The markdown body of the PR.
  final String body;
}

/// Interface for publishing Draft PRs to GitHub.
abstract class PrPublisher {
  /// Publishes a Draft PR using the artifacts and validated files in [context].
  Future<PrPublishResult> publishDraftPr(HarnessContext context);
}

/// Default publisher that invokes git and GitHub CLI (`gh pr create --draft`).
class GitHubPrPublisher implements PrPublisher {
  /// Creates a [GitHubPrPublisher].
  const GitHubPrPublisher();

  /// Resolves the root directory of the git repository (supports monorepos).
  static Future<String> resolveGitRoot(String startDir) async {
    try {
      final ProcessResult result = await Process.run(
        'git',
        <String>['rev-parse', '--show-toplevel'],
        workingDirectory: startDir,
      );
      if (result.exitCode == 0) {
        final String root = (result.stdout as String).trim();
        if (root.isNotEmpty && Directory(root).existsSync()) {
          return root;
        }
      }
    } catch (_) {}
    return startDir;
  }

  @override
  Future<PrPublishResult> publishDraftPr(HarnessContext context) async {
    final metadata = DraftPrMetadata.fromContext(context);
    final String packageDir = context.resolvePackagePath();
    final String gitWorkingDir = await resolveGitRoot(packageDir);

    if (context.isDryRun || !context.publishPr) {
      context.log('PR Publishing skipped (dry run or --publish-pr not set).');
      context.log('Proposed PR Title: ${metadata.title}');
      context.log('Proposed PR Branch: ${metadata.branchName}');
      return const PrPublishResult(success: true, prUrl: '(dry-run-skipped)');
    }

    // 1. Create or checkout branch
    context.log('Creating branch ${metadata.branchName}...');
    final ProcessResult branchResult = await Process.run('git', <String>[
      'checkout',
      '-B',
      metadata.branchName,
    ], workingDirectory: gitWorkingDir);

    if (branchResult.exitCode != 0) {
      final String stderr = branchResult.stderr as String? ?? '';
      return PrPublishResult(
        success: false,
        stderr: stderr,
        failureReason: 'Failed to create git branch ${metadata.branchName}: $stderr',
      );
    }

    // 2. Stage validated files (excluding internal .agents tooling)
    final List<String> stageFiles =
        context.validatedModifiedFiles.where((f) => !f.contains('.agents/')).toList();
    if (stageFiles.isNotEmpty) {
      context.log('Staging ${stageFiles.length} file(s)...');
      final gitAddArgs = <String>['add'];
      for (final file in stageFiles) {
        if (File(file).isAbsolute) {
          gitAddArgs.add(file);
        } else if (File('$gitWorkingDir/$file').existsSync()) {
          gitAddArgs.add(file);
        } else if (File('$packageDir/$file').existsSync()) {
          gitAddArgs.add('$packageDir/$file');
        } else {
          gitAddArgs.add(file);
        }
      }

      final ProcessResult addResult = await Process.run(
        'git',
        gitAddArgs,
        workingDirectory: gitWorkingDir,
      );
      if (addResult.exitCode != 0) {
        final String stderr = addResult.stderr as String? ?? '';
        return PrPublishResult(
          success: false,
          stderr: stderr,
          failureReason: 'Failed to stage files: $stderr',
        );
      }
    }

    // 3. Commit
    context.log('Committing changes...');
    final ProcessResult commitResult = await Process.run('git', <String>[
      'commit',
      '-m',
      metadata.title,
    ], workingDirectory: gitWorkingDir);

    if (commitResult.exitCode != 0) {
      final String stderr = commitResult.stderr as String? ?? '';
      return PrPublishResult(
        success: false,
        stderr: stderr,
        failureReason: 'Failed to commit changes: $stderr',
      );
    }

    // 4. Push branch to remote
    context.log('Pushing branch ${metadata.branchName} to remote...');
    final ProcessResult pushResult = await Process.run('git', <String>[
      'push',
      '-u',
      'origin',
      metadata.branchName,
    ], workingDirectory: gitWorkingDir);

    if (pushResult.exitCode != 0) {
      final String stderr = pushResult.stderr as String? ?? '';
      return PrPublishResult(
        success: false,
        stderr: stderr,
        failureReason: 'Failed to push branch to origin: $stderr',
      );
    }

    // 5. Create Draft PR via GitHub CLI
    context.log('Creating Draft PR via gh CLI...');
    final ghArgs = <String>[
      'pr',
      'create',
      '--draft',
      '--title',
      metadata.title,
      '--body',
      metadata.body,
      '--base',
      'main',
    ];
    if (context.repo != null && context.repo!.isNotEmpty) {
      ghArgs.addAll(<String>['--repo', context.repo!]);
    }

    final ProcessResult prResult = await Process.run('gh', ghArgs, workingDirectory: gitWorkingDir);
    final String stdout = prResult.stdout as String? ?? '';
    final String stderr = prResult.stderr as String? ?? '';

    if (prResult.exitCode != 0) {
      return PrPublishResult(
        success: false,
        stdout: stdout,
        stderr: stderr,
        failureReason: 'gh pr create failed: $stderr',
      );
    }

    final String prUrl = stdout.trim();
    return PrPublishResult(success: true, prUrl: prUrl, stdout: stdout, stderr: stderr);
  }
}
