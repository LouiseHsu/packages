// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'codegen.dart';
import 'gemini_agent.dart';
import 'guardrails.dart';
import 'harness_context.dart';
import 'publisher.dart';
import 'test_runner.dart';

export 'harness_context.dart';

/// The deterministic controller that steps through each harness phase.
class PackageHarness {
  /// Creates a [PackageHarness] with an optional [testRunner], [validator], [codeGenerator], and [agent].
  PackageHarness(
    this.context, {
    this.testRunner = const FlutterTestRunner(),
    this.validator = const DefaultGuardrailValidator(),
    this.codeGenerator = const DefaultCodeGenerator(),
    HarnessAgent? agent,
    PrPublisher? publisher,
  }) : agent =
           agent ??
           GeminiHarnessAgent(
             model: context.model,
             fallbackModels: context.fallbackModels,
             packageDir: context.resolvePackagePath(),
           ),
       publisher = publisher ?? const GitHubPrPublisher();

  /// The execution context.
  final HarnessContext context;

  /// Test runner instance.
  final TestRunner testRunner;

  /// Guardrail and hygiene validator instance.
  final GuardrailValidator validator;

  /// Code generator instance.
  final CodeGenerator codeGenerator;

  /// AI agent instance.
  final HarnessAgent agent;

  /// PR publisher instance.
  final PrPublisher publisher;

  /// Runs the full execution loop until reaching a terminal state.
  Future<HarnessPhase> run() async {
    context.log(
      'Starting Package Harness for Issue #${context.issueNumber} '
      '(${context.packageName})',
    );

    while (context.currentPhase != HarnessPhase.complete &&
        context.currentPhase != HarnessPhase.failed) {
      switch (context.currentPhase) {
        case HarnessPhase.init:
          await handleInit();
        case HarnessPhase.redTest:
          await handleRedTest();
        case HarnessPhase.implementation:
          await handleImplementation();
        case HarnessPhase.validation:
          await handleValidation();
        case HarnessPhase.complete:
        case HarnessPhase.failed:
          break;
      }
    }

    if (context.currentPhase == HarnessPhase.complete) {
      context.log('🎉 Harness completed successfully!');
      if (context.publishPr && !context.isDryRun) {
        context.log('Publishing Draft PR for Issue #${context.issueNumber}...');
        final PrPublishResult publishResult = await publisher.publishDraftPr(context);
        if (publishResult.success) {
          context.publishedPrUrl = publishResult.prUrl;
          context.log('🚀 Draft PR published: ${publishResult.prUrl}');
        } else {
          // The fix itself is verified, but there is no PR to show for it. Record
          // the reason so callers (CI) can fail loudly instead of reporting success.
          context.prPublishFailureReason =
              publishResult.failureReason ?? 'Unknown PR publishing failure.';
          context.log('⚠️ Failed to publish Draft PR: ${context.prPublishFailureReason}');
          context.recordArtifact(
            'pr_publish_failure.txt',
            '${context.prPublishFailureReason}\n\n'
                '--- stdout ---\n${publishResult.stdout}\n\n'
                '--- stderr ---\n${publishResult.stderr}\n',
          );
          final String? savedDir = context.saveFailureLogsToDisk();
          if (savedDir != null) {
            context.log('📁 PR publish failure logs saved to: $savedDir');
          }
        }
      }
    } else {
      context.log('🛑 Harness failed: ${context.failureReason}');
      if (context.initialTestFileContent != null && context.testFilePath != null) {
        final testFile = File(resolvePath(context.resolvePackagePath(), context.testFilePath!));
        if (testFile.existsSync()) {
          testFile.writeAsStringSync(context.initialTestFileContent!);
        }
      }
      final String? savedDir = context.saveFailureLogsToDisk();
      if (savedDir != null) {
        context.log('📁 Failure logs saved to: $savedDir');
      }
    }

    return context.currentPhase;
  }

  /// Handles the init phase: verifies issue data.
  Future<void> handleInit() async {
    context.log('Initializing workspace for issue #${context.issueNumber}...');

    // Ensure a clean baseline for the package's tracked source files.
    //
    // Only done when the agent is going to generate code into the tree. When
    // `skipAgent` is set the caller supplied the test/fix themselves, so wiping
    // their working tree would destroy the very input we were handed.
    //
    // `.agents` is excluded deliberately: the harness tooling lives there, and it
    // became a tracked path once it was committed. Without the exclusion this
    // discards the agent's own uncommitted source every time the harness starts.
    if (!context.skipAgent) {
      try {
        final String targetDir = context.resolvePackagePath();
        final ProcessResult reset = Process.runSync('git', <String>[
          'checkout',
          '--',
          '.',
          ':(exclude).agents',
        ], workingDirectory: targetDir);
        if (reset.exitCode != 0) {
          context.log(
            'Note: could not reset package files to a clean baseline: '
            '${(reset.stderr as String? ?? '').trim()}',
          );
        }
      } catch (_) {
        // Best-effort workspace hygiene
      }
    }

    if (context.issueTitle.isEmpty) {
      // Attempt to load via gh CLI if available
      try {
        final ghArgs = <String>[
          'issue',
          'view',
          context.issueNumber.toString(),
          '--json',
          'title,body',
        ];
        if (context.repo != null && context.repo!.isNotEmpty) {
          ghArgs.addAll(<String>['--repo', context.repo!]);
        }
        final ProcessResult result = Process.runSync('gh', ghArgs);
        if (result.exitCode == 0) {
          final issueData = jsonDecode(result.stdout as String) as Map<String, dynamic>;
          context.issueTitle = issueData['title'] as String? ?? '';
          context.issueBody = issueData['body'] as String? ?? '';
        }
      } catch (e) {
        context.log('Notice: Could not load issue metadata via gh CLI: $e');
      }
    }

    if (context.issueTitle.isEmpty) {
      context.failureReason = 'Issue #${context.issueNumber} title could not be resolved';
      context.transitionTo(HarnessPhase.failed, reason: context.failureReason);
      return;
    }

    context.log('Target Issue: "${context.issueTitle}"');
    context.transitionTo(HarnessPhase.redTest, reason: 'Init complete');
  }

  /// Resolves [filePath] against [targetDir] unless it is already absolute.
  static String resolvePath(String targetDir, String filePath) =>
      File(filePath).isAbsolute ? filePath : '$targetDir/$filePath';

  /// The test file used when the caller does not name one.
  String get _defaultTestFilePath => context.packageName == 'in_app_purchase_storekit'
      ? 'test/in_app_purchase_storekit_2_platform_test.dart'
      : 'test/${context.packageName}_test.dart';

  /// Returns the set of untracked files under [targetDir], relative to it.
  ///
  /// Recorded before the agent runs so that files it creates can be told apart
  /// from untracked files that were already there, which must not be deleted.
  Future<Set<String>> _untrackedFiles(String targetDir) async {
    try {
      final ProcessResult result = await Process.run('git', <String>[
        'ls-files',
        '--others',
        '--exclude-standard',
      ], workingDirectory: targetDir);
      if (result.exitCode != 0) {
        return <String>{};
      }
      return (result.stdout as String)
          .split('\n')
          .map((String line) => line.trim())
          .where((String line) => line.isNotEmpty && !line.contains('.agents/'))
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  /// Restores [targetDir] to its committed state, discarding whatever the agent
  /// changed during an attempt.
  ///
  /// Asks git what is dirty rather than reverting a fixed list of files. A
  /// hardcoded list silently fails to revert any file the agent was not
  /// expected to touch, which lets one attempt's edits leak into the next and
  /// lets stray edits survive a failed run.
  ///
  /// `.agents` is excluded because the harness's own source lives there, inside
  /// the package it operates on.
  Future<void> _revertWorkspace(String targetDir, Set<String> baselineUntracked) async {
    final ProcessResult checkout = await Process.run('git', <String>[
      'checkout',
      '--',
      '.',
      ':(exclude).agents',
    ], workingDirectory: targetDir);
    if (checkout.exitCode != 0) {
      context.log(
        '⚠️ Could not revert tracked files: ${(checkout.stderr as String? ?? '').trim()}',
      );
    }

    // Remove only files this run created. Untracked files that predate the run
    // belong to the developer and are left alone.
    final Set<String> nowUntracked = await _untrackedFiles(targetDir);
    for (final String relPath in nowUntracked.difference(baselineUntracked)) {
      final file = File('$targetDir/$relPath');
      if (file.existsSync()) {
        try {
          file.deleteSync();
          context.log('Removed file created during the attempt: $relPath');
        } catch (e) {
          context.log('⚠️ Could not remove $relPath: $e');
        }
      }
    }
  }

  /// Rewrites the target test file with the verified red test.
  ///
  /// Returns true if the file had drifted and was restored. Nothing stops
  /// [HarnessAgent.generateFix] from patching the test file, and a fix that
  /// weakens the test would otherwise pass every downstream gate. Rewriting it
  /// before the test runs makes the judge immune to the thing being judged.
  bool _restoreRedTest(String targetDir, String relativeTestFile, String verifiedRedTest) {
    final testFile = File(resolvePath(targetDir, relativeTestFile));
    if (!testFile.existsSync()) {
      testFile.writeAsStringSync(verifiedRedTest);
      return true;
    }
    if (testFile.readAsStringSync() == verifiedRedTest) {
      return false;
    }
    testFile.writeAsStringSync(verifiedRedTest);
    return true;
  }

  /// Whether to stop retrying after the attempt numbered [attempt].
  ///
  /// Stops when the last two attempts failed the same way. Each further attempt
  /// costs a model call plus a full test suite run, and an unchanged failure is
  /// strong evidence the model is resampling the same misconception rather than
  /// exploring something new.
  bool _shouldStopRetrying(int attempt, int maxAttempts) {
    if (attempt >= maxAttempts) {
      return true;
    }
    if (!context.state.isRepeatingFailure) {
      return false;
    }
    context.log(
      '⚠️ Attempt $attempt failed the same way as the previous attempt. '
      'Stopping early instead of using the remaining ${maxAttempts - attempt} attempt(s).',
    );
    return true;
  }

  /// Phase 1 (FAIL_TO_PASS): Red test verification.
  ///
  /// Executes the target test and asserts that it fails on clean code.
  /// If the test passes, the FAIL_TO_PASS invariant is violated and execution aborts.
  Future<void> handleRedTest() async {
    context.log('Phase 1 (FAIL_TO_PASS): Red Test Verification...');
    if (context.isDryRun) {
      context.log('Dry run enabled: skipping test generation.');
      context.transitionTo(HarnessPhase.implementation, reason: 'Dry run transition');
      return;
    }

    if (context.testFilePath == null || context.testFilePath!.isEmpty) {
      context.testFilePath = _defaultTestFilePath;
    }

    final String targetDir = context.resolvePackagePath();
    final String relativeTestFile = context.testFilePath!;
    final String resolvedPath = resolvePath(targetDir, relativeTestFile);

    final testFile = File(resolvedPath);
    if (!testFile.existsSync()) {
      context.failureReason = 'Test file not found: $relativeTestFile (resolved: $resolvedPath)';
      context.log('❌ ${context.failureReason}');
      context.transitionTo(HarnessPhase.failed, reason: context.failureReason);
      return;
    }

    final String initialContent = testFile.readAsStringSync();
    context.initialTestFileContent ??= initialContent;
    final int maxAttempts = context.skipAgent ? 1 : context.maxRetries;
    String? lastFailureReason;
    context.state.resetAttemptHistory();

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (!context.skipAgent) {
        // Revert file to clean content before each attempt
        testFile.writeAsStringSync(initialContent);

        context.log(
          'Red test attempt $attempt of $maxAttempts: querying Gemini to generate reproduction unit test for Issue #${context.issueNumber}...',
        );
        try {
          final FilePatch patch = await agent.generateRedTest(context);
          context.log('Applied red test patch: ${patch.filePath} (${patch.content.length} chars)');
        } catch (e) {
          lastFailureReason = 'Agent failed to generate red test: $e';
          context.log('⚠️ Attempt $attempt failed: $lastFailureReason');
          context.state.recordAttemptFailure(lastFailureReason);
          if (_shouldStopRetrying(attempt, maxAttempts)) {
            break;
          }
          continue;
        }
      }

      context.log('Running FAIL_TO_PASS test: $relativeTestFile in $targetDir');
      final TestRunResult result = await testRunner.runTest(
        testFilePath: relativeTestFile,
        workingDirectory: targetDir,
      );

      if (result.passed) {
        lastFailureReason =
            'FAIL_TO_PASS Invariant Violated: Test passed on clean main. '
            'A reproduction test must fail before production changes are applied.';
        context.log('⚠️ Attempt $attempt failed: $lastFailureReason');
        // Record the generated test alongside the reason. The reason alone is a
        // fixed string, so without this every attempt would look identical and
        // the repeat detector would stop after two genuinely different tests.
        context.state.recordAttemptFailure(
          '$lastFailureReason\n'
          'The test you generated was:\n${context.redTestCode ?? '(unavailable)'}',
        );
        context.recordArtifact(
          'red_test_attempt_${attempt}_passed_unexpectedly.txt',
          'Test passed on clean main (exit code 0):\n${result.stdout}\n${result.stderr}'.trim(),
        );
        if (_shouldStopRetrying(attempt, maxAttempts)) {
          break;
        }
        continue;
      }

      final String summary = result.failureSummary;
      if (summary.contains("Member not found: 'SK2Transaction.fromMap'") ||
          summary.contains('.fromMap') ||
          summary.contains('.toMap') ||
          summary.contains("Member not found: 'SKError.fromMap'")) {
        lastFailureReason =
            'FAIL_TO_PASS Invariant Violated: Red test called a hallucinated fromMap/toMap method. '
            'StoreKit 2 classes are strictly Pigeon-typed and do NOT have fromMap or toMap. '
            'Test via platform methods (e.g. SK2Transaction.unfinishedTransactions()) or the standard constructor.';
        context.log('⚠️ Attempt $attempt rejected: $lastFailureReason');
        context.state.recordAttemptFailure('$lastFailureReason\n$summary');
        context.recordArtifact('red_test_attempt_${attempt}_hallucinated_fromMap.txt', summary);
        if (_shouldStopRetrying(attempt, maxAttempts)) {
          break;
        }
        continue;
      }

      context.recordArtifact(
        'red_test_attempt_${attempt}_verified_failure.txt',
        result.failureSummary,
      );
      if (context.redTestCode != null) {
        context.recordArtifact('red_test_attempt_${attempt}_code.dart', context.redTestCode!);
      }
      context.lastTestFailureSummary = result.failureSummary;
      // Preserved for the Draft PR: this is the evidence the bug was real, and
      // the only way a reviewer can check the test failed for the right reason.
      context.state.verifiedRedFailureSummary = result.failureSummary;
      context.log(
        '✅ FAIL_TO_PASS verified: Red test failed as expected with exit code ${result.exitCode}.',
      );
      context.log('Captured failure snippet:\n${result.failureSummary}');
      context.transitionTo(
        HarnessPhase.implementation,
        reason: 'FAIL_TO_PASS verified (test failed as expected)',
      );
      return;
    }

    testFile.writeAsStringSync(initialContent);
    context.failureReason =
        lastFailureReason ?? 'FAIL_TO_PASS verification failed after $maxAttempts attempt(s).';
    context.log('❌ ${context.failureReason}');
    context.transitionTo(HarnessPhase.failed, reason: context.failureReason);
  }

  /// Phase 2 (PASS_TO_PASS): Implementation verification.
  ///
  /// 1. Runs code generation (Pigeon) if applicable.
  /// 2. Re-runs the target test to assert that it is now GREEN (passing).
  /// 3. Runs the package test suite to verify zero regressions.
  Future<void> handleImplementation() async {
    context.log('Phase 2 (PASS_TO_PASS): Implementation Verification...');
    if (context.isDryRun) {
      context.log('Dry run enabled: skipping implementation.');
      context.transitionTo(HarnessPhase.validation, reason: 'Dry run transition');
      return;
    }

    final String targetDir = context.resolvePackagePath();
    final String relativeTestFile = context.testFilePath ?? _defaultTestFilePath;

    final int maxAttempts = context.skipAgent ? 1 : context.maxRetries;
    String? lastFailureReason;
    context.state.resetAttemptHistory();

    // Baseline for reverting between attempts. Untracked files present now are
    // the developer's and must survive; anything the agent creates must not.
    final Set<String> baselineUntracked = await _untrackedFiles(targetDir);

    // The red test as verified in phase 1. Re-pinned before every test run so a
    // fix cannot pass by weakening the test that judges it.
    final String resolvedTestPath = resolvePath(targetDir, relativeTestFile);
    final String? verifiedRedTest = File(resolvedTestPath).existsSync()
        ? File(resolvedTestPath).readAsStringSync()
        : null;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      context.log('Implementation attempt $attempt of $maxAttempts...');

      if (!context.skipAgent) {
        // Revert to the committed baseline before each attempt, so one
        // attempt's edits never leak into the next.
        await _revertWorkspace(targetDir, baselineUntracked);
        if (verifiedRedTest != null) {
          _restoreRedTest(targetDir, relativeTestFile, verifiedRedTest);
        }

        context.log(
          'Querying Gemini to generate implementation fix for Issue #${context.issueNumber}...',
        );
        try {
          final ImplementationFix fix = await agent.generateFix(context);
          context.log('Applied ${fix.patches.length} patch(es): ${fix.summary}');
          for (final FilePatch patch in fix.patches) {
            context.log('  - ${patch.filePath} (${patch.content.length} chars)');
          }

          // Generated files must come from the generator. Checked here on the
          // proposed patches rather than on the final diff, because codegen
          // rewrites these files legitimately a few lines below.
          final String? generatedFileError = DefaultGuardrailValidator.checkGeneratedFiles(
            fix.patches.map((FilePatch patch) => patch.filePath),
          );
          if (generatedFileError != null) {
            lastFailureReason = generatedFileError;
            context.log('⚠️ Attempt $attempt rejected: $lastFailureReason');
            context.state.recordAttemptFailure(generatedFileError);
            context.recordArtifact(
              'implementation_attempt_${attempt}_edited_generated_file.txt',
              generatedFileError,
            );
            if (_shouldStopRetrying(attempt, maxAttempts)) {
              break;
            }
            continue;
          }
        } catch (e) {
          lastFailureReason = 'Agent failed to generate implementation fix: $e';
          context.log('⚠️ Attempt $attempt failed: $lastFailureReason');
          context.state.recordAttemptFailure(
            '$lastFailureReason\n'
            'Please ensure every search_block is an exact snippet copied directly from the provided source files without altering parameter modifiers.',
          );
          if (_shouldStopRetrying(attempt, maxAttempts)) {
            break;
          }
          continue;
        }

        // The fix may have patched the test file. Put the verified red test
        // back before it is used as the pass/fail gate.
        if (verifiedRedTest != null &&
            _restoreRedTest(targetDir, relativeTestFile, verifiedRedTest)) {
          context.log(
            '⚠️ The implementation patch modified the red test; restored the verified '
            'version. A fix must satisfy the test, not rewrite it.',
          );
          context.recordArtifact(
            'implementation_attempt_${attempt}_modified_red_test.txt',
            'The generated fix patched $relativeTestFile. The verified red test was '
                'restored before running, so this attempt was judged against the '
                'original test.',
          );
        }
      }

      // 1. Run code generator
      context.log('Running code generation for ${context.packageName}...');
      final CodeGenResult codeGenResult = await codeGenerator.generate(
        packagePath: targetDir,
        packageName: context.packageName,
      );

      if (!codeGenResult.success) {
        lastFailureReason =
            'Code generation failed (exit code ${codeGenResult.exitCode}):\n'
                    '${codeGenResult.stderr}\n${codeGenResult.stdout}'
                .trim();
        context.log('⚠️ Attempt $attempt failed: $lastFailureReason');
        context.state.recordAttemptFailure(lastFailureReason);
        context.recordArtifact(
          'implementation_attempt_${attempt}_codegen_failure.txt',
          lastFailureReason,
        );
        if (_shouldStopRetrying(attempt, maxAttempts)) {
          break;
        }
        continue;
      }

      // 2. Re-run target test: assert GREEN
      context.log('Running PASS_TO_PASS target test: $relativeTestFile in $targetDir');
      final TestRunResult targetResult = await testRunner.runTest(
        testFilePath: relativeTestFile,
        workingDirectory: targetDir,
      );

      if (!targetResult.passed) {
        lastFailureReason =
            'PASS_TO_PASS Invariant Violated: Target test is still failing after implementation:\n'
            '${targetResult.failureSummary}';
        context.log('⚠️ Attempt $attempt failed: $lastFailureReason');
        context.state.recordAttemptFailure(targetResult.failureSummary);
        context.recordArtifact(
          'implementation_attempt_${attempt}_target_test_failure.txt',
          targetResult.failureSummary,
        );
        if (_shouldStopRetrying(attempt, maxAttempts)) {
          break;
        }
        continue;
      }

      context.log('✅ Target test passed cleanly (GREEN)!');

      // 3. Run full package test suite to verify zero regressions
      context.log('Running full test suite in $targetDir to verify zero regressions...');
      final TestRunResult suiteResult = await testRunner.runSuite(workingDirectory: targetDir);

      if (!suiteResult.passed) {
        lastFailureReason =
            'Regression detected: Package test suite failed after implementation:\n'
            '${suiteResult.failureSummary}';
        context.log('⚠️ Attempt $attempt failed: $lastFailureReason');
        context.state.recordAttemptFailure(suiteResult.failureSummary);
        context.recordArtifact(
          'implementation_attempt_${attempt}_regression_failure.txt',
          suiteResult.failureSummary,
        );
        if (_shouldStopRetrying(attempt, maxAttempts)) {
          break;
        }
        continue;
      }

      // 4. Run static analysis and guardrail verification
      context.log('Running static analysis and guardrails check for ${context.packageName}...');
      final ValidationResult validationResult = await validator.validate(
        packagePath: targetDir,
        packageName: context.packageName,
      );

      if (!validationResult.isValid) {
        lastFailureReason =
            'Static analysis or guardrail check failed:\n${validationResult.failureReason}';
        context.log('⚠️ Attempt $attempt failed: $lastFailureReason');
        context.state.recordAttemptFailure(validationResult.failureReason ?? 'Validation failed');
        context.recordArtifact(
          'implementation_attempt_${attempt}_validation_failure.txt',
          validationResult.failureReason ?? 'Validation failed',
        );
        if (_shouldStopRetrying(attempt, maxAttempts)) {
          break;
        }
        continue;
      }

      context.validatedModifiedFiles.clear();
      context.validatedModifiedFiles.addAll(validationResult.modifiedFiles);

      context.log(
        '✅ PASS_TO_PASS verified: Target test passed, zero regressions, and static analysis clean (attempt $attempt/$maxAttempts).',
      );
      context.transitionTo(
        HarnessPhase.validation,
        reason: 'PASS_TO_PASS verified (green test, regression checks, and static analysis passed)',
      );
      return;
    }

    // Leave nothing behind on failure. The git revert also removes the red
    // test, returning the package to its committed state.
    if (!context.skipAgent) {
      await _revertWorkspace(targetDir, baselineUntracked);
    }

    context.failureReason =
        lastFailureReason ?? 'Implementation failed after $maxAttempts attempt(s).';
    context.log('❌ ${context.failureReason}');
    context.transitionTo(HarnessPhase.failed, reason: context.failureReason);
  }

  /// Phase 3 (Hygiene): Formats code, runs static analysis, and checks guardrails.
  Future<void> handleValidation() async {
    context.log('Phase 3: Validation & Guardrails...');
    if (context.isDryRun) {
      context.log('Dry run enabled: skipping validation.');
      context.transitionTo(HarnessPhase.complete, reason: 'Dry run transition');
      return;
    }

    final String targetDir = context.resolvePackagePath();
    context.log(
      'Validating guardrails and code hygiene for ${context.packageName} ($targetDir)...',
    );

    final ValidationResult result = await validator.validate(
      packagePath: targetDir,
      packageName: context.packageName,
    );

    if (!result.isValid) {
      context.failureReason = result.failureReason ?? 'Validation checks failed.';
      context.log('❌ ${context.failureReason}');
      context.transitionTo(HarnessPhase.failed, reason: context.failureReason);
      return;
    }

    context.validatedModifiedFiles.clear();
    context.validatedModifiedFiles.addAll(result.modifiedFiles);
    context.log('✅ Validation & Guardrails passed cleanly.');
    context.transitionTo(HarnessPhase.complete, reason: 'Guardrails verified');
  }
}

void printUsage() {
  stdout.writeln('Flutter Packages SWE-bench Execution Harness');
  stdout.writeln('Usage: dart harness.dart --issue=<issue_number> [--package=<name>] [--dry-run]');
  stdout.writeln();
  stdout.writeln('Options:');
  stdout.writeln('  --issue=<number>        GitHub issue number to triage/resolve (Required)');
  stdout.writeln(
    '  --package=<name>        Target package name (default: in_app_purchase_storekit)',
  );
  stdout.writeln('  --package-path=<path>   Target package directory path');
  stdout.writeln('  --test=<file>           Target test file path to run');
  stdout.writeln('  --repo=<owner/pkg>      Target repository (e.g. LouiseHsu/packages)');
  stdout.writeln(
    '  --dry-run               Step through state machine transitions without modifying files',
  );
  stdout.writeln('  --skip-agent            Skip automated LLM code/test generation');
  stdout.writeln('  --publish-pr            Create branch, commit, push, and open Draft PR via gh');
  stdout.writeln(
    '  --max-retries=<number>  Max implementation attempts before failing (default: 5)',
  );
  stdout.writeln('  --model=<name>          Gemini model name (default: gemini-flash-latest)');
  stdout.writeln('  --help, -h              Show this help message');
}

Future<void> main(List<String> args) async {
  int? issueNumber;
  String? repo = Platform.environment['GITHUB_REPOSITORY'] ?? 'LouiseHsu/packages';
  var packageName = 'in_app_purchase_storekit';
  String? packagePath;
  String? testFilePath;
  var isDryRun = false;
  var skipAgent = false;
  var publishPr = false;
  var maxRetries = 5;
  String? cliModel;

  for (final arg in args) {
    if (arg.startsWith('--issue=')) {
      issueNumber = int.tryParse(arg.substring('--issue='.length));
    } else if (arg.startsWith('--package=')) {
      packageName = arg.substring('--package='.length);
    } else if (arg.startsWith('--package-path=')) {
      packagePath = arg.substring('--package-path='.length);
    } else if (arg.startsWith('--test=')) {
      testFilePath = arg.substring('--test='.length);
    } else if (arg.startsWith('--repo=')) {
      repo = arg.substring('--repo='.length);
    } else if (arg.startsWith('--max-retries=')) {
      maxRetries = int.tryParse(arg.substring('--max-retries='.length)) ?? 5;
    } else if (arg.startsWith('--model=')) {
      cliModel = arg.substring('--model='.length);
    } else if (arg == '--dry-run') {
      isDryRun = true;
    } else if (arg == '--skip-agent') {
      skipAgent = true;
    } else if (arg == '--publish-pr') {
      publishPr = true;
    } else if (arg == '--help' || arg == '-h') {
      printUsage();
      return;
    }
  }

  final String resolvedPackageDir = HarnessContext.resolvePackageDirectory(
    packageName,
    packagePath,
  );
  final String model = resolveDefaultModel(cliModel: cliModel, packageDir: resolvedPackageDir);

  if (issueNumber == null) {
    stderr.writeln('Error: Missing required --issue argument.\n');
    printUsage();
    exitCode = 1;
    return;
  }

  final context = HarnessContext(
    issueNumber: issueNumber,
    isDryRun: isDryRun,
    skipAgent: skipAgent,
    publishPr: publishPr,
    maxRetries: maxRetries,
    model: model,
    packageName: packageName,
    packagePath: packagePath,
    testFilePath: testFilePath,
    repo: repo,
  );

  final harness = PackageHarness(context);
  final HarnessPhase finalPhase = await harness.run();

  if (finalPhase == HarnessPhase.complete) {
    exitCode = 0;
  } else {
    exitCode = 1;
  }
}
