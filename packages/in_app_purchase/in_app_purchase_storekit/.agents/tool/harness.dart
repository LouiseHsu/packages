// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'codegen.dart';
import 'gemini_agent.dart';
import 'guardrails.dart';
import 'harness_context.dart';
import 'native_analyzer.dart';
import 'publisher.dart';
import 'test_runner.dart';
import 'workspace.dart';

export 'harness_context.dart';

/// Whether [testOutput] shows the test failing to build rather than running.
///
/// The red gate needs this distinction and the exit code does not provide it:
/// `flutter test` exits 1 both when a test compiles and fails an assertion and
/// when it never compiled at all. Only the first is evidence about the test.
///
/// The markers are the ones the Dart test runner emits when it cannot load a
/// suite; an assertion failure produces neither.
bool isCompileFailure(String testOutput) {
  const markers = <String>[
    'Failed to load',
    'Compilation failed',
    'Compilation error',
    'Error when reading',
  ];
  return markers.any(testOutput.contains);
}

/// The deterministic controller that steps through each harness phase.
class PackageHarness {
  /// Creates a [PackageHarness] with an optional [testRunner], [validator], [codeGenerator], [nativeAnalyzer], [workspace], and [agent].
  PackageHarness(
    this.context, {
    this.testRunner = const FlutterTestRunner(),
    this.validator = const DefaultGuardrailValidator(),
    this.codeGenerator = const DefaultCodeGenerator(),
    this.nativeAnalyzer = const SwiftTypecheckAnalyzer(),
    this.workspace = const GitWorkspace(),
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

  /// Native (non-Dart) source analyzer instance.
  final NativeAnalyzer nativeAnalyzer;

  /// Working tree inspection and restoration.
  final Workspace workspace;

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
    if (!context.skipAgent) {
      await _revertWorkspace(
        context.resolvePackagePath(),
        await workspace.untrackedFiles(context.resolvePackagePath()),
      );
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

  /// Restores [targetDir] to its committed state, discarding whatever the
  /// agent changed during an attempt, and logs what happened.
  Future<void> _revertWorkspace(String targetDir, Set<String> baselineUntracked) async {
    final RevertResult result = await workspace.revert(targetDir, baselineUntracked);
    for (final String warning in result.warnings) {
      context.log('⚠️ $warning');
    }
    for (final String path in result.removedFiles) {
      context.log('Removed file created during the attempt: $path');
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
        _restoreSkeletonFiles(targetDir);

        context.log(
          'Red test attempt $attempt of $maxAttempts: querying Gemini to generate reproduction unit test for Issue #${context.issueNumber}...',
        );
        try {
          final FilePatch patch = await agent.generateRedTest(context);
          context.log('Applied red test patch: ${patch.filePath} (${patch.content.length} chars)');
          if (context.skeletonOriginals.isNotEmpty) {
            context.log(
              'Applied skeleton stubs to ${context.skeletonOriginals.length} file(s): '
              '${context.skeletonOriginals.keys.join(', ')}',
            );
          }
        } catch (e) {
          lastFailureReason = 'Agent failed to generate red test: $e';
          context.log('⚠️ Attempt $attempt failed: $lastFailureReason');
          context.state.recordAttemptFailure(lastFailureReason);
          context.recordArtifact('red_test_attempt_${attempt}_generation_error.txt', '$e');
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
        // Against a skeleton whose method bodies all throw, a passing test has
        // demonstrated that nothing it asserts depends on the missing feature.
        // This is exactly the null test that let run 5 through.
        lastFailureReason = context.skeletonOriginals.isEmpty
            ? 'FAIL_TO_PASS Invariant Violated: Test passed on clean main. '
                  'A reproduction test must fail before production changes are applied.'
            : 'FAIL_TO_PASS Invariant Violated: Test PASSED against a skeleton whose method '
                  'bodies all throw UnimplementedError. It therefore asserts nothing that the '
                  'missing feature controls. Construct-then-read-fields-back tests always pass '
                  'this way. Call the API and assert on what it returns.';
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
          'Test passed (exit code 0):\n${result.stdout}\n${result.stderr}'.trim(),
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

      // The test must have RUN. A compile error means no assertion ever
      // executed, so the failure says nothing about whether the test is any
      // good -- and for an additive API issue, a test naming a symbol that
      // does not exist yet ALWAYS fails this way. That is the whole reason
      // the skeleton exists.
      if (isCompileFailure(result.stdout + result.stderr)) {
        lastFailureReason = context.skeletonOriginals.isEmpty
            ? 'FAIL_TO_PASS Invariant Violated: The test did not compile, and you supplied no '
                  'skeleton. Provide declarations-only stubs in `skeleton` so the test can run '
                  'and fail on its assertions instead of on a compile error.'
            : 'FAIL_TO_PASS Invariant Violated: The test did not compile. Your skeleton is '
                  'incomplete -- it must declare every symbol the test names. Fix the errors '
                  'below by adding the missing declarations to `skeleton`.';
        context.log('⚠️ Attempt $attempt rejected: $lastFailureReason');
        context.state.recordAttemptFailure('$lastFailureReason\n$summary');
        context.recordArtifact('red_test_attempt_${attempt}_did_not_compile.txt', summary);
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
      if (context.skeletonCode != null) {
        context.recordArtifact('red_test_attempt_${attempt}_skeleton.txt', context.skeletonCode!);
      }
      context.lastTestFailureSummary = result.failureSummary;
      // Preserved for the Draft PR: this is the evidence the bug was real, and
      // the only way a reviewer can check the test failed for the right reason.
      context.state.verifiedRedFailureSummary = result.failureSummary;
      context.log(
        '✅ FAIL_TO_PASS verified: Red test ran and failed at runtime with exit code '
        '${result.exitCode}.',
      );
      context.log('Captured failure snippet:\n${result.failureSummary}');

      // The skeleton has served its purpose. Implementation starts from clean
      // code, so a half-written stub can never be mistaken for the fix.
      _restoreSkeletonFiles(targetDir);
      context.transitionTo(
        HarnessPhase.implementation,
        reason: 'FAIL_TO_PASS verified (test ran and failed at runtime)',
      );
      return;
    }

    testFile.writeAsStringSync(initialContent);
    _restoreSkeletonFiles(targetDir);
    context.failureReason =
        lastFailureReason ?? 'FAIL_TO_PASS verification failed after $maxAttempts attempt(s).';
    context.log('❌ ${context.failureReason}');
    context.transitionTo(HarnessPhase.failed, reason: context.failureReason);
  }

  /// Undoes the skeleton stubs, restoring every file the probe touched.
  void _restoreSkeletonFiles(String targetDir) {
    if (context.skeletonOriginals.isEmpty) {
      return;
    }
    context.skeletonOriginals.forEach((String path, String original) {
      final file = File(resolvePath(targetDir, path));
      file.writeAsStringSync(original);
    });
    context.log('Reverted skeleton stubs in ${context.skeletonOriginals.length} file(s).');
    context.skeletonOriginals.clear();
    context.skeletonCode = null;
  }

  /// Phase 2 (PASS_TO_PASS): Implementation verification.
  ///
  /// 1. Runs code generation (Pigeon) if applicable.
  /// 2. Type-checks native sources, which the Dart tests cannot cover.
  /// 3. Re-runs the target test to assert that it is now GREEN (passing).
  /// 4. Runs the package test suite to verify zero regressions.
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
    final Set<String> baselineUntracked = await workspace.untrackedFiles(targetDir);

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

      // 2. Type-check native sources.
      //
      // Runs after codegen, which rewrites the generated Swift bindings, and
      // before the Dart tests, which are slower and which mock the platform
      // channel -- so they can pass while the Swift is nonsense.
      final NativeAnalysisResult nativeResult = await nativeAnalyzer.analyze(
        packagePath: targetDir,
      );

      if (nativeResult.skipped) {
        context.log('Native analysis skipped: ${nativeResult.skippedReason}');
        context.state.nativeAnalysisSkippedReason = nativeResult.skippedReason;
      } else if (!nativeResult.success) {
        lastFailureReason =
            'Native analysis failed (exit code ${nativeResult.exitCode}):\n'
            '${nativeResult.failureSummary}';
        context.log('⚠️ Attempt $attempt failed: $lastFailureReason');
        context.state.recordAttemptFailure(lastFailureReason);
        context.recordArtifact(
          'implementation_attempt_${attempt}_native_analysis_failure.txt',
          nativeResult.failureSummary,
        );
        if (_shouldStopRetrying(attempt, maxAttempts)) {
          break;
        }
        continue;
      } else {
        context.log('✅ Native sources type-checked cleanly.');
        context.state.nativeAnalysisSkippedReason = null;
      }

      // 3. Re-run target test: assert GREEN
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

      // 4. Run full package test suite to verify zero regressions
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

      // 5. Run static analysis and guardrail verification
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
