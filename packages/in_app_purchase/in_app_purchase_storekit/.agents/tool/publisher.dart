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
  const DraftPrMetadata({
    required this.title,
    required this.branchName,
    required this.body,
    this.baseBranch = defaultBaseBranch,
  });

  /// Generates [DraftPrMetadata] formatted according to Flutter monorepo standards.
  ///
  /// [baseBranch] defaults to the `AGENT_PR_BASE_BRANCH` environment variable when
  /// set, so forks whose trunk is not `main` do not need a code change.
  factory DraftPrMetadata.fromContext(HarnessContext context, {String? baseBranch}) {
    final title = '[${context.packageName}] ${context.issueTitle} (fixes #${context.issueNumber})';
    final branchName = 'agent/fix-issue-${context.issueNumber}';
    final String resolvedBase =
        baseBranch ?? Platform.environment['AGENT_PR_BASE_BRANCH'] ?? defaultBaseBranch;

    final buffer = StringBuffer();
    buffer.writeln('## Summary');
    buffer.writeln('Fixes #${context.issueNumber}: ${context.issueTitle}');
    buffer.writeln();

    buffer.writeln('## Implementation Overview');
    buffer.writeln('Automated fix verified through phased TDD loop in `${context.packageName}`.');
    buffer.writeln();

    final List<String> publishableFiles = context.validatedModifiedFiles
        .where((f) => !f.contains('.agents/'))
        .toList();
    if (publishableFiles.isNotEmpty) {
      buffer.writeln('### Modified Files');
      for (final file in publishableFiles) {
        buffer.writeln('- `$file`');
      }
      buffer.writeln();
    }

    // No verification checklist: every box would always be ticked, because the
    // harness aborts rather than publishing when a gate fails. A list of things
    // that are true by construction adds length without adding information.
    // What a reviewer cannot derive is how the test failed beforehand, so that
    // is what gets reported instead.
    buffer.writeln(
      'Verified by the autonomous harness: the reproduction test below failed on a '
      'clean checkout, then passed after this change, with no regressions and clean '
      'static analysis. `pubspec.yaml` and `CHANGELOG.md` are deliberately untouched. '
      'See `.agents/README.md` for what this does and does not guarantee.',
    );
    buffer.writeln();

    // The summary above asserts the test failed first; this shows *how*. A red
    // test can fail for the wrong reason (a typo, a hallucinated API, a bad
    // assertion), and the implementation phase would then faithfully satisfy a
    // wrong specification. Surfacing the output lets a reviewer judge that in
    // seconds instead of digging through run artifacts.
    final String? redFailure = context.state.verifiedRedFailureSummary;
    if (redFailure != null && redFailure.trim().isNotEmpty) {
      const maxLength = 2000;
      final String trimmed = redFailure.trim();
      final excerpt = trimmed.length > maxLength
          ? '${trimmed.substring(0, maxLength)}\n... (truncated, see run logs)'
          : trimmed;

      buffer.writeln('<details>');
      buffer.writeln(
        '<summary><b>Verified failure before the fix</b> '
        '(how the reproduction test failed on clean main)</summary>',
      );
      buffer.writeln();
      buffer.writeln('```');
      buffer.writeln(excerpt);
      buffer.writeln('```');
      buffer.writeln('</details>');
      buffer.writeln();
    }

    // Absence of a native check is indistinguishable from a passing one unless
    // it is stated. Said plainly so a reviewer knows to build the Swift half
    // themselves.
    final String? nativeSkipped = context.state.nativeAnalysisSkippedReason;
    if (nativeSkipped != null && nativeSkipped.trim().isNotEmpty) {
      buffer.writeln(
        '> [!WARNING]\n'
        '> Native sources were **not** type-checked on this run '
        '($nativeSkipped) so any Swift in this diff is unverified.',
      );
      buffer.writeln();
    }
    buffer.writeln('---');
    buffer.writeln('*Autonomous Draft PR created by `.agents/tool/harness.dart`*');

    return DraftPrMetadata(
      title: title,
      branchName: branchName,
      body: buffer.toString(),
      baseBranch: resolvedBase,
    );
  }

  /// Branch that Draft PRs target when no override is supplied.
  static const String defaultBaseBranch = 'main';

  /// The standardized commit and PR title.
  final String title;

  /// The git branch name for the PR.
  final String branchName;

  /// The markdown body of the PR.
  final String body;

  /// The branch the Draft PR merges into.
  final String baseBranch;
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
      final ProcessResult result = await Process.run('git', <String>[
        'rev-parse',
        '--show-toplevel',
      ], workingDirectory: startDir);
      if (result.exitCode == 0) {
        final String root = (result.stdout as String).trim();
        if (root.isNotEmpty && Directory(root).existsSync()) {
          return root;
        }
      }
    } catch (_) {}
    return startDir;
  }

  /// Extracts stderr text from a completed process.
  ///
  /// `ProcessResult.stderr` is typed `dynamic`, so every call site would
  /// otherwise repeat the same cast and null fallback.
  static String _stderrOf(ProcessResult result) => result.stderr as String? ?? '';

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

    // Publishing checks out a generated `agent/fix-issue-<n>` branch. Record the
    // caller's branch first so it can be restored: otherwise a local run leaves
    // the developer's repository parked on the agent branch, and whatever they
    // commit next silently lands there instead of on their own branch.
    final String? originalRef = await _currentRef(gitWorkingDir);

    try {
      return await _publishOnAgentBranch(context, metadata, packageDir, gitWorkingDir);
    } finally {
      await _restoreRef(context, gitWorkingDir, originalRef);
    }
  }

  /// Creates the agent branch, commits the validated files, pushes, and opens
  /// the Draft PR.
  ///
  /// Leaves the repository checked out on the agent branch; [publishDraftPr]
  /// owns restoring the caller's original branch.
  Future<PrPublishResult> _publishOnAgentBranch(
    HarnessContext context,
    DraftPrMetadata metadata,
    String packageDir,
    String gitWorkingDir,
  ) async {
    // 1. Create or checkout branch
    context.log('Creating branch ${metadata.branchName}...');
    final ProcessResult branchResult = await Process.run('git', <String>[
      'checkout',
      '-B',
      metadata.branchName,
    ], workingDirectory: gitWorkingDir);

    if (branchResult.exitCode != 0) {
      final String stderr = _stderrOf(branchResult);
      return PrPublishResult(
        success: false,
        stderr: stderr,
        failureReason: 'Failed to create git branch ${metadata.branchName}: $stderr',
      );
    }

    // 2. Stage validated files (excluding internal .agents tooling)
    final List<String> stageFiles = context.validatedModifiedFiles
        .where((f) => !f.contains('.agents/'))
        .toList();
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
        final String stderr = _stderrOf(addResult);
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
      final String stderr = _stderrOf(commitResult);
      return PrPublishResult(
        success: false,
        stderr: stderr,
        failureReason: 'Failed to commit changes: $stderr',
      );
    }

    // 4. Push branch to remote.
    //
    // Re-running the agent on the same issue rewrites `agent/fix-issue-<n>` via
    // `checkout -B`, so a plain push is rejected as non-fast-forward. Retry with
    // --force-with-lease, which replaces our own previous attempt but still
    // refuses if someone else pushed to the branch since we last fetched it.
    context.log('Pushing branch ${metadata.branchName} to remote...');
    ProcessResult pushResult = await Process.run('git', <String>[
      'push',
      '-u',
      'origin',
      metadata.branchName,
    ], workingDirectory: gitWorkingDir);

    if (pushResult.exitCode != 0) {
      final String firstStderr = _stderrOf(pushResult);
      final bool isRejected =
          firstStderr.contains('non-fast-forward') || firstStderr.contains('rejected');

      if (!isRejected) {
        return PrPublishResult(
          success: false,
          stderr: firstStderr,
          failureReason: 'Failed to push branch to origin: $firstStderr',
        );
      }

      context.log(
        'Branch ${metadata.branchName} already exists on remote; retrying with '
        '--force-with-lease (the previous agent attempt will be replaced)...',
      );
      pushResult = await Process.run('git', <String>[
        'push',
        '--force-with-lease',
        '-u',
        'origin',
        metadata.branchName,
      ], workingDirectory: gitWorkingDir);

      if (pushResult.exitCode != 0) {
        final String stderr = _stderrOf(pushResult);
        return PrPublishResult(
          success: false,
          stderr: stderr,
          failureReason:
              'Failed to push branch to origin. The remote branch ${metadata.branchName} has '
              'diverged and was not overwritten (it may contain commits not made by this '
              'agent): $stderr',
        );
      }
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
      metadata.baseBranch,
    ];
    if (context.repo != null && context.repo!.isNotEmpty) {
      ghArgs.addAll(<String>['--repo', context.repo!]);
    }

    final ProcessResult prResult = await Process.run('gh', ghArgs, workingDirectory: gitWorkingDir);
    final String stdout = prResult.stdout as String? ?? '';
    final String stderr = _stderrOf(prResult);

    if (prResult.exitCode != 0) {
      // On a re-run the branch already has an open PR. The push above already
      // updated it, so this is a successful update rather than a failure.
      if (stderr.contains('already exists')) {
        final String? existingUrl = await _findExistingPrUrl(
          branchName: metadata.branchName,
          repo: context.repo,
          workingDirectory: gitWorkingDir,
        );
        context.log('Existing Draft PR updated with new commit: ${existingUrl ?? '(url unknown)'}');
        return PrPublishResult(success: true, prUrl: existingUrl, stdout: stdout, stderr: stderr);
      }

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

  /// Returns the current branch name, or the commit SHA when HEAD is detached.
  static Future<String?> _currentRef(String workingDirectory) async {
    try {
      final ProcessResult branch = await Process.run('git', <String>[
        'symbolic-ref',
        '--quiet',
        '--short',
        'HEAD',
      ], workingDirectory: workingDirectory);
      if (branch.exitCode == 0) {
        final String name = (branch.stdout as String? ?? '').trim();
        if (name.isNotEmpty) {
          return name;
        }
      }

      // Detached HEAD: fall back to the SHA so the caller still lands where
      // they started.
      final ProcessResult sha = await Process.run('git', <String>[
        'rev-parse',
        'HEAD',
      ], workingDirectory: workingDirectory);
      if (sha.exitCode == 0) {
        final String value = (sha.stdout as String? ?? '').trim();
        if (value.isNotEmpty) {
          return value;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Returns the repository to [ref] after publishing.
  ///
  /// Deliberately uses a plain (non-forced) checkout. If publishing failed
  /// before committing, the generated fix is still uncommitted in the working
  /// tree, and `checkout -f` would destroy it. When the checkout is refused the
  /// repository is left on the agent branch and that is reported, which is
  /// recoverable; silently discarding the work would not be.
  static Future<void> _restoreRef(
    HarnessContext context,
    String workingDirectory,
    String? ref,
  ) async {
    if (ref == null) {
      return;
    }
    final String? current = await _currentRef(workingDirectory);
    if (current == ref) {
      return;
    }

    final ProcessResult result = await Process.run('git', <String>[
      'checkout',
      ref,
    ], workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      final String stderr = _stderrOf(result).trim();
      context.log(
        '⚠️ Could not return to "$ref"; the repository is still on '
        '"${current ?? 'the agent branch'}". Uncommitted changes were preserved '
        'rather than discarded. Switch back manually once they are handled: $stderr',
      );
      return;
    }
    context.log('Returned to "$ref".');
  }

  /// Looks up the URL of the open PR for [branchName], if one exists.
  static Future<String?> _findExistingPrUrl({
    required String branchName,
    required String? repo,
    required String workingDirectory,
  }) async {
    try {
      final ghArgs = <String>['pr', 'view', branchName, '--json', 'url', '--jq', '.url'];
      if (repo != null && repo.isNotEmpty) {
        ghArgs.addAll(<String>['--repo', repo]);
      }
      final ProcessResult result = await Process.run(
        'gh',
        ghArgs,
        workingDirectory: workingDirectory,
      );
      if (result.exitCode == 0) {
        final String url = (result.stdout as String? ?? '').trim();
        if (url.isNotEmpty) {
          return url;
        }
      }
    } catch (_) {
      // Best-effort lookup; the push already succeeded.
    }
    return null;
  }
}
