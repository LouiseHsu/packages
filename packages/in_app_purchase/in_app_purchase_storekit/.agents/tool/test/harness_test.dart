// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../codegen.dart';
import '../gemini_agent.dart';
import '../guardrails.dart';
import '../harness.dart';
import '../native_analyzer.dart';
import '../publisher.dart';
import '../test_runner.dart';
import '../workspace.dart';

void main() {
  group('HarnessContext State Machine Transitions', () {
    test('enforces legal linear transitions', () {
      final context = HarnessContext(issueNumber: 123, isDryRun: true);

      expect(context.currentPhase, HarnessPhase.init);

      expect(context.transitionTo(HarnessPhase.redTest), isTrue);
      expect(context.currentPhase, HarnessPhase.redTest);

      expect(context.transitionTo(HarnessPhase.implementation), isTrue);
      expect(context.currentPhase, HarnessPhase.implementation);

      expect(context.transitionTo(HarnessPhase.validation), isTrue);
      expect(context.currentPhase, HarnessPhase.validation);

      expect(context.transitionTo(HarnessPhase.complete), isTrue);
      expect(context.currentPhase, HarnessPhase.complete);
    });

    test('blocks illegal state transitions and moves to failed', () {
      final context = HarnessContext(issueNumber: 123, isDryRun: true);

      expect(context.currentPhase, HarnessPhase.init);

      // Attempt illegal jump from init directly to validation
      expect(context.transitionTo(HarnessPhase.validation), isFalse);
      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.failureReason, contains('Illegal state transition'));
    });

    test('allows transition to failed from any active state', () {
      final context = HarnessContext(issueNumber: 123, isDryRun: true);
      context.transitionTo(HarnessPhase.redTest);

      expect(context.transitionTo(HarnessPhase.failed, reason: 'Test failed unexpectedly'), isTrue);
      expect(context.currentPhase, HarnessPhase.failed);
    });

    test('terminal state cannot transition to any other state', () {
      final context = HarnessContext(issueNumber: 123, isDryRun: true);
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);
      context.transitionTo(HarnessPhase.validation);
      context.transitionTo(HarnessPhase.complete);

      expect(context.transitionTo(HarnessPhase.init), isFalse);
      expect(context.currentPhase, HarnessPhase.failed);
    });
  });

  group('TestRunResult', () {
    test('reports passed and failure summary correctly', () {
      const success = TestRunResult(exitCode: 0, stdout: 'All tests passed!', stderr: '');
      expect(success.passed, isTrue);
      expect(success.failureSummary, 'Test passed (exit code 0)');

      const failure = TestRunResult(
        exitCode: 1,
        stdout: 'Expected: <true>\n  Actual: <false>',
        stderr: 'Test failed',
      );
      expect(failure.passed, isFalse);
      expect(failure.failureSummary, contains('Expected: <true>'));
      expect(failure.failureSummary, contains('Test failed'));
    });

    test('truncates failure summaries exceeding 50 lines', () {
      final String longOutput = List<String>.generate(
        60,
        (int i) => 'Line $i: Error details',
      ).join('\n');
      final result = TestRunResult(exitCode: 1, stdout: longOutput, stderr: '');

      expect(result.failureSummary, contains('... [truncated]'));
      expect(result.failureSummary, contains('Line 49: Error details'));
      expect(result.failureSummary, isNot(contains('Line 55: Error details')));
    });
  });

  group('Compiler directive hoisting', () {
    test('hoists the note that cost run 6 to the top', () {
      const swiftcOutput =
          'StoreKit2Translators.swift:87:5: error: switch must be exhaustive\n'
          ' 85 | extension Product.SubscriptionInfo.RenewalState {\n'
          ' 87 |     switch self {\n'
          '    |     `- error: switch must be exhaustive\n'
          ' 98 |     @unknown default:\n'
          "    |              `- note: remove '@unknown' to handle remaining values\n";

      final String hoisted = hoistCompilerDirectives(swiftcOutput);

      expect(hoisted, startsWith('REQUIRED CHANGES'));
      expect(hoisted, contains("remove '@unknown' to handle remaining values"));
    });

    test('returns empty string when the compiler offered no remedy', () {
      expect(hoistCompilerDirectives('error: cannot find type Foo in scope'), isEmpty);
    });

    test('de-duplicates a note repeated across several errors', () {
      const output =
          "a.swift:1:1: note: add 'default:'\n"
          "b.swift:2:2: note: add 'default:'\n";
      expect("add 'default:'".allMatches(hoistCompilerDirectives(output)).length, 1);
    });
  });

  group('Red test must have run', () {
    test('isCompileFailure recognises a suite that never loaded', () {
      expect(
        isCompileFailure(
          '00:01 +0 -1: loading test/foo_test.dart [E]\n'
          '  Failed to load "test/foo_test.dart":\n'
          "  lib/src/bar.dart:12:5: Error: The method 'baz' isn't defined.",
        ),
        isTrue,
      );
    });

    test('isCompileFailure is false for a test that ran and failed an assertion', () {
      expect(
        isCompileFailure(
          '00:02 +0 -1: subscription status [E]\n'
          '  Expected: <true>\n'
          '    Actual: <false>\n'
          '  package:test_api/src/expect/expect.dart 149:31  fail',
        ),
        isFalse,
      );
    });

    test('isCompileFailure is false for UnimplementedError from a skeleton stub', () {
      // The accept case: the skeleton compiled, the test ran, and it failed
      // because the behaviour behind the declarations is missing.
      expect(
        isCompileFailure('00:02 +0 -1: subscription status [E]\n  UnimplementedError'),
        isFalse,
      );
    });

    test('red test that did not compile is rejected rather than verified', () async {
      final context = HarnessContext(
        issueNumber: 7,
        isDryRun: false,
        skipAgent: true,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose StoreKit 2 subscription status',
      );
      context.transitionTo(HarnessPhase.redTest);

      final mockRunner = MockTestRunner(
        const TestRunResult(
          exitCode: 1,
          stdout:
              '00:01 +0 -1: loading test/in_app_purchase_storekit_2_platform_test.dart [E]\n'
              '  Failed to load "test/in_app_purchase_storekit_2_platform_test.dart":\n'
              "  Error: The method 'subscriptionStatus' isn't defined.",
          stderr: '',
        ),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        testRunner: mockRunner,
      );
      await harness.handleRedTest();

      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.failureReason, contains('did not compile'));
    });
  });

  group('FAIL_TO_PASS Gate Runner', () {
    test('transitions to implementation when test fails as expected on clean main', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        skipAgent: true,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);

      final mockRunner = MockTestRunner(
        const TestRunResult(
          exitCode: 1,
          stdout:
              "Error: The getter 'originalPurchaseDate' isn't defined for the class 'SK2Transaction'.",
          stderr: '',
        ),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
      );
      await harness.handleRedTest();

      expect(context.currentPhase, HarnessPhase.implementation);
      expect(context.lastTestFailureSummary, contains('originalPurchaseDate'));
      expect(mockRunner.lastRanTestFilePath, 'test/in_app_purchase_storekit_2_platform_test.dart');
      expect(context.logs, contains(contains('FAIL_TO_PASS verified')));
    });

    test(
      'violates FAIL_TO_PASS invariant and transitions to failed if test passes on clean main',
      () async {
        final context = HarnessContext(
          issueNumber: 3,
          isDryRun: false,
          skipAgent: true,
          testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
          issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
        );
        context.transitionTo(HarnessPhase.redTest);

        final mockRunner = MockTestRunner(
          const TestRunResult(exitCode: 0, stdout: '00:01 +10: All tests passed!', stderr: ''),
        );

        final harness = PackageHarness(
          context,
          nativeAnalyzer: MockNativeAnalyzer(),
          workspace: FakeWorkspace(),
          testRunner: mockRunner,
        );
        await harness.handleRedTest();

        expect(context.currentPhase, HarnessPhase.failed);
        expect(context.failureReason, contains('FAIL_TO_PASS Invariant Violated'));
        expect(context.logs, contains(contains('FAIL_TO_PASS Invariant Violated')));
      },
    );

    test('transitions to failed if target test file does not exist', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        skipAgent: true,
        testFilePath: 'test/non_existent_fake_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);

      final mockRunner = MockTestRunner(const TestRunResult(exitCode: 1, stdout: '', stderr: ''));

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
      );
      await harness.handleRedTest();

      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.failureReason, contains('Test file not found'));
      expect(mockRunner.lastRanTestFilePath, isNull);
    });

    test(
      'rejects red test that failed with hallucinated fromMap method on StoreKit 2 class',
      () async {
        final context = HarnessContext(
          issueNumber: 3,
          isDryRun: false,
          skipAgent: true,
          testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
          issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
        );
        context.transitionTo(HarnessPhase.redTest);

        final mockRunner = MockTestRunner(
          const TestRunResult(
            exitCode: 1,
            stdout:
                "test/in_app_purchase_storekit_2_platform_test.dart:755:40: Error: Member not found: 'SK2Transaction.fromMap'.",
            stderr: '',
          ),
        );

        final harness = PackageHarness(
          context,
          nativeAnalyzer: MockNativeAnalyzer(),
          workspace: FakeWorkspace(),
          testRunner: mockRunner,
        );
        await harness.handleRedTest();

        expect(context.currentPhase, HarnessPhase.failed);
        expect(context.failureReason, contains('hallucinated fromMap/toMap method'));
        expect(context.logs, contains(contains('hallucinated fromMap/toMap method')));
      },
    );
  });

  group('PackageHarness Dry Run Execution', () {
    test('successfully steps through all phases in dry-run mode', () async {
      final context = HarnessContext(
        issueNumber: 42,
        isDryRun: true,
        packageName: 'camera_android_camerax',
        issueTitle: 'Mock Mechanical Package Issue',
        issueBody: 'Expose mock property in package',
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
      );
      final HarnessPhase finalPhase = await harness.run();

      expect(finalPhase, HarnessPhase.complete);
      expect(context.logs, contains(contains('Starting Package Harness')));
      expect(context.logs, contains(contains('Harness completed successfully')));
    });
  });

  group('Guardrail and Diff Validator', () {
    test('checkForbiddenFiles flags pubspec.yaml modifications', () {
      final files = <String>['packages/in_app_purchase/in_app_purchase_storekit/pubspec.yaml'];
      final String? error = DefaultGuardrailValidator.checkForbiddenFiles(files);

      expect(error, isNotNull);
      expect(error, contains('pubspec.yaml are strictly prohibited'));
    });

    test('checkForbiddenFiles flags CHANGELOG.md modifications', () {
      final files = <String>['packages/in_app_purchase/in_app_purchase_storekit/CHANGELOG.md'];
      final String? error = DefaultGuardrailValidator.checkForbiddenFiles(files);

      expect(error, isNotNull);
      expect(error, contains('CHANGELOG.md are strictly prohibited'));
    });

    test('checkForbiddenFiles allows normal source code files', () {
      final files = <String>[
        'packages/in_app_purchase/in_app_purchase_storekit/lib/src/store_kit_2/sk2_transaction.dart',
        'packages/in_app_purchase/in_app_purchase_storekit/darwin/Classes/StoreKit2Platform.swift',
        'packages/in_app_purchase/in_app_purchase_storekit/test/in_app_purchase_storekit_2_platform_test.dart',
      ];
      final String? error = DefaultGuardrailValidator.checkForbiddenFiles(files);

      expect(error, isNull);
    });

    test('checkGeneratedFiles flags hand-edited Pigeon output', () {
      final files = <String>[
        'packages/in_app_purchase/in_app_purchase_storekit/lib/src/sk2_pigeon.g.dart',
      ];
      final String? error = DefaultGuardrailValidator.checkGeneratedFiles(files);

      expect(error, isNotNull);
      expect(error, contains('generated file'));
      expect(error, contains('pigeons/sk2_pigeon.dart'));
    });

    test('checkGeneratedFiles flags generated Swift messages', () {
      final files = <String>[
        'packages/in_app_purchase/in_app_purchase_storekit/darwin/StoreKit2/StoreKit2Messages.g.swift',
      ];

      expect(DefaultGuardrailValidator.checkGeneratedFiles(files), isNotNull);
    });

    test('checkGeneratedFiles allows the Pigeon source of truth', () {
      // The input to the generator is hand-edited by design; only its output
      // is off-limits.
      final files = <String>[
        'packages/in_app_purchase/in_app_purchase_storekit/pigeons/sk2_pigeon.dart',
        'packages/in_app_purchase/in_app_purchase_storekit/lib/src/sk2_transaction_wrapper.dart',
      ];

      expect(DefaultGuardrailValidator.checkGeneratedFiles(files), isNull);
    });

    test('isGeneratedFile does not match names that merely start with g', () {
      expect(DefaultGuardrailValidator.isGeneratedFile('lib/src/graphql_client.dart'), isFalse);
      expect(DefaultGuardrailValidator.isGeneratedFile('lib/src/foo.g.dart'), isTrue);
    });

    test('checkPackageBoundary flags modifications outside target package', () {
      final files = <String>['packages/camera/camera_android/lib/camera.dart'];
      final String? error = DefaultGuardrailValidator.checkPackageBoundary(
        files,
        packageName: 'in_app_purchase_storekit',
      );

      expect(error, isNotNull);
      expect(error, contains('is outside package boundary'));
    });

    test('checkPackageBoundary ignores internal .agents files', () {
      final files = <String>[
        'packages/in_app_purchase/in_app_purchase_storekit/.agents/tool/harness.dart',
      ];
      final String? error = DefaultGuardrailValidator.checkPackageBoundary(
        files,
        packageName: 'in_app_purchase_storekit',
      );

      expect(error, isNull);
    });

    test(
      'handleValidation transitions to complete and records modified files when valid',
      () async {
        final context = HarnessContext(
          issueNumber: 3,
          isDryRun: false,
          issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
        );
        context.transitionTo(HarnessPhase.redTest);
        context.transitionTo(HarnessPhase.implementation);
        context.transitionTo(HarnessPhase.validation);

        final mockValidator = MockGuardrailValidator(
          const ValidationResult(
            isValid: true,
            modifiedFiles: <String>[
              'lib/src/store_kit_2/sk2_transaction.dart',
              'test/in_app_purchase_storekit_2_platform_test.dart',
            ],
          ),
        );

        final harness = PackageHarness(
          context,
          nativeAnalyzer: MockNativeAnalyzer(),
          workspace: FakeWorkspace(),
          validator: mockValidator,
        );
        await harness.handleValidation();

        expect(context.currentPhase, HarnessPhase.complete);
        expect(
          context.validatedModifiedFiles,
          contains('lib/src/store_kit_2/sk2_transaction.dart'),
        );
        expect(mockValidator.lastValidatedPackageName, 'in_app_purchase_storekit');
        expect(context.logs, contains(contains('Validation & Guardrails passed cleanly')));
      },
    );

    test('handleValidation transitions to failed when guardrail check fails', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);
      context.transitionTo(HarnessPhase.validation);

      final mockValidator = MockGuardrailValidator(
        const ValidationResult(
          isValid: false,
          failureReason:
              'Guardrail Invariant Violated: Modifications to pubspec.yaml are strictly prohibited.',
        ),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        validator: mockValidator,
      );
      await harness.handleValidation();

      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.failureReason, contains('pubspec.yaml are strictly prohibited'));
      expect(context.logs, contains(contains('Guardrail Invariant Violated')));
    });
  });

  group('PASS_TO_PASS Implementation & CodeGen Runner', () {
    test('fails when code generator fails (e.g. Pigeon syntax error)', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        skipAgent: true,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockGen = MockCodeGenerator(
        const CodeGenResult(
          exitCode: 1,
          stdout: '',
          stderr: 'Pigeon error: syntax error in pigeons/sk2_pigeon.dart',
        ),
      );
      final mockRunner = MockTestRunner(const TestRunResult(exitCode: 0, stdout: '', stderr: ''));

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
      );
      await harness.handleImplementation();

      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.failureReason, contains('Code generation failed'));
      expect(context.failureReason, contains('Pigeon error'));
    });

    test(
      'violates PASS_TO_PASS invariant if target test still fails after implementation',
      () async {
        final context = HarnessContext(
          issueNumber: 3,
          isDryRun: false,
          skipAgent: true,
          testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
          issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
        );
        context.transitionTo(HarnessPhase.redTest);
        context.transitionTo(HarnessPhase.implementation);

        final mockGen = MockCodeGenerator(
          const CodeGenResult(exitCode: 0, stdout: 'Generated', stderr: ''),
        );
        final mockRunner = MockTestRunner(
          const TestRunResult(
            exitCode: 1,
            stdout: 'Expected: <DateTime> but was: <null>',
            stderr: '',
          ),
        );

        final harness = PackageHarness(
          context,
          nativeAnalyzer: MockNativeAnalyzer(),
          workspace: FakeWorkspace(),
          testRunner: mockRunner,
          codeGenerator: mockGen,
        );
        await harness.handleImplementation();

        expect(context.currentPhase, HarnessPhase.failed);
        expect(context.failureReason, contains('PASS_TO_PASS Invariant Violated'));
        expect(context.failureReason, contains('Expected: <DateTime>'));
      },
    );

    test('fails if regression suite fails even when target test passes', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        skipAgent: true,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockGen = MockCodeGenerator(
        const CodeGenResult(exitCode: 0, stdout: 'Generated', stderr: ''),
      );
      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 0, stdout: 'Target test passed', stderr: ''),
        suiteResultToReturn: const TestRunResult(
          exitCode: 1,
          stdout: 'Regression in other_test.dart',
          stderr: '',
        ),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
      );
      await harness.handleImplementation();

      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.failureReason, contains('Regression detected'));
      expect(context.failureReason, contains('Regression in other_test.dart'));
    });

    test(
      'successfully transitions to validation when code gen, target test, and suite all pass',
      () async {
        final context = HarnessContext(
          issueNumber: 3,
          isDryRun: false,
          skipAgent: true,
          testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
          issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
        );
        context.transitionTo(HarnessPhase.redTest);
        context.transitionTo(HarnessPhase.implementation);

        final mockGen = MockCodeGenerator(
          const CodeGenResult(exitCode: 0, stdout: 'Generated', stderr: ''),
        );
        final mockRunner = MockTestRunner(
          const TestRunResult(exitCode: 0, stdout: 'All tests passed', stderr: ''),
        );

        // Every collaborator is injected, including the validator. Left to its
        // default, `handleImplementation` would construct a
        // `DefaultGuardrailValidator` and run it over this very checkout, so
        // an unrelated edit anywhere outside the package -- a workflow file,
        // say -- would trip `checkPackageBoundary` and fail this test for
        // reasons that have nothing to do with what it asserts.
        final harness = PackageHarness(
          context,
          nativeAnalyzer: MockNativeAnalyzer(),
          workspace: FakeWorkspace(),
          testRunner: mockRunner,
          codeGenerator: mockGen,
          validator: MockGuardrailValidator(const ValidationResult(isValid: true)),
        );
        await harness.handleImplementation();

        expect(context.currentPhase, HarnessPhase.validation);
        expect(mockRunner.ranSuite, isTrue);
        expect(context.logs, contains(contains('PASS_TO_PASS verified')));
      },
    );
  });

  group('HarnessAgent & AI Generation Loop', () {
    test('handleRedTest invokes agent.generateRedTest when skipAgent is false', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);

      final mockAgent = MockHarnessAgent();
      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 1, stdout: 'Test failed as expected', stderr: ''),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        agent: mockAgent,
      );
      await harness.handleRedTest();

      expect(mockAgent.generatedRedTest, isTrue);
      expect(context.currentPhase, HarnessPhase.implementation);
      expect(context.logs, contains(contains('Applied red test patch')));
    });

    test('handleRedTest does not invoke agent when skipAgent is true', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        skipAgent: true,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);

      final mockAgent = MockHarnessAgent();
      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 1, stdout: 'Test failed as expected', stderr: ''),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        agent: mockAgent,
      );
      await harness.handleRedTest();

      expect(mockAgent.generatedRedTest, isFalse);
      expect(context.currentPhase, HarnessPhase.implementation);
    });

    test('handleRedTest transitions to failed when agent throws', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);

      final mockAgent = MockHarnessAgent(shouldThrow: true);
      final mockRunner = MockTestRunner(const TestRunResult(exitCode: 1, stdout: '', stderr: ''));

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        agent: mockAgent,
      );
      await harness.handleRedTest();

      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.failureReason, contains('Agent failed to generate red test'));
    });

    test('handleImplementation invokes agent.generateFix when skipAgent is false', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockAgent = MockHarnessAgent();
      final mockGen = MockCodeGenerator(const CodeGenResult(exitCode: 0, stdout: '', stderr: ''));
      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 0, stdout: 'All tests passed', stderr: ''),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
        validator: MockGuardrailValidator(const ValidationResult(isValid: true)),
      );
      await harness.handleImplementation();

      expect(mockAgent.generatedFix, isTrue);
      expect(context.currentPhase, HarnessPhase.validation);
      expect(context.logs, contains(contains('Applied 1 patch(es)')));
    });

    test('handleImplementation does not invoke agent when skipAgent is true', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        skipAgent: true,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockAgent = MockHarnessAgent();
      final mockGen = MockCodeGenerator(const CodeGenResult(exitCode: 0, stdout: '', stderr: ''));
      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 0, stdout: 'All tests passed', stderr: ''),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
        validator: MockGuardrailValidator(const ValidationResult(isValid: true)),
      );
      await harness.handleImplementation();

      expect(mockAgent.generatedFix, isFalse);
      expect(context.currentPhase, HarnessPhase.validation);
    });

    test('handleImplementation transitions to failed when agent throws', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockAgent = MockHarnessAgent(shouldThrow: true);
      final mockGen = MockCodeGenerator(const CodeGenResult(exitCode: 0, stdout: '', stderr: ''));
      final mockRunner = MockTestRunner(const TestRunResult(exitCode: 0, stdout: '', stderr: ''));

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
      );
      await harness.handleImplementation();

      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.failureReason, contains('Agent failed to generate implementation fix'));
    });

    test('sanitizeCodeContent strips markdown fences and normalizes newlines', () {
      const fencedDart = '```dart\nimport "package:pigeon/pigeon.dart";\nclass A {}\n```';
      expect(sanitizeCodeContent(fencedDart), 'import "package:pigeon/pigeon.dart";\nclass A {}\n');

      const fencedSwift = '```swift\nimport StoreKit\n```';
      expect(sanitizeCodeContent(fencedSwift), 'import StoreKit\n');

      const crlfCode = 'line1\r\nline2\r\n';
      expect(sanitizeCodeContent(crlfCode), 'line1\nline2\n');

      const rawCode = 'var x = 1;\n';
      expect(sanitizeCodeContent(rawCode), 'var x = 1;\n');
    });

    test('GeminiHarnessAgent defaults to resolved model with 5s exponential retry', () {
      final agent = GeminiHarnessAgent();
      expect(agent.model, isNotEmpty);
      expect(agent.retryDelay, const Duration(seconds: 5));
      expect(agent.maxNetworkRetries, 5);
    });

    test('normalizeModelName maps aliases to valid model identifiers', () {
      expect(normalizeModelName('gemini-2.5-flash'), 'gemini-flash-latest');
      expect(normalizeModelName('2.5-flash'), 'gemini-flash-latest');
      expect(normalizeModelName('2.5flash'), 'gemini-flash-latest');
      expect(normalizeModelName('flash'), 'gemini-flash-latest');
      expect(normalizeModelName('gemini-flash'), 'gemini-flash-latest');
      expect(normalizeModelName('gemini-2.5-pro'), 'gemini-pro-latest');
      expect(normalizeModelName('gemini-3.7-flash'), 'gemini-3.7-flash');
      expect(normalizeModelName('3.7-flash'), 'gemini-3.7-flash');
      expect(normalizeModelName('gemini-3.6-flash'), 'gemini-3.6-flash');
      expect(normalizeModelName('3.6-flash'), 'gemini-3.6-flash');
      expect(normalizeModelName('gemini-3.8-flash'), 'gemini-3.8-flash');
    });

    test('resolveDefaultModel resolves CLI flag, config file, and aliases', () {
      expect(resolveDefaultModel(cliModel: 'gemini-3.7-flash'), 'gemini-3.7-flash');
      expect(resolveDefaultModel(cliModel: 'gemini-3.6-flash'), 'gemini-3.6-flash');
      expect(resolveDefaultModel(cliModel: 'gemini-3.5-flash'), 'gemini-3.5-flash');
      expect(resolveDefaultModel(cliModel: '2.5-flash'), 'gemini-flash-latest');
      expect(resolveDefaultModel(cliModel: 'lite'), 'gemini-flash-lite-latest');
    });

    test('GeminiHarnessAgent normalizes nonexistent gemini-2.5-flash to gemini-flash-latest', () {
      final agent = GeminiHarnessAgent(model: 'gemini-2.5-flash');
      expect(agent.model, 'gemini-flash-latest');
    });

    test('resolveFallbackModels parses fallover_models from config and normalizes aliases', () {
      final Directory tempDir = Directory.systemTemp.createTempSync('config_test_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final configFile = File('${tempDir.path}/.agents/config.json');
      configFile.parent.createSync(recursive: true);
      configFile.writeAsStringSync('''
{
  "model": "3.6-flash",
  "fallover_models": [
    "3.7flash",
    "2.5pro",
    "3.6-flash"
  ]
}
''');

      final List<String> models = resolveFallbackModels(packageDir: tempDir.path);
      expect(models, <String>['gemini-3.7-flash', 'gemini-pro-latest', 'gemini-3.6-flash']);

      expect(resolveDefaultModel(packageDir: tempDir.path), 'gemini-3.6-flash');
    });

    test('resolveFallbackModels returns defaults when config file is missing', () {
      final List<String> defaults = resolveFallbackModels(packageDir: '/non_existent_path');
      expect(defaults, <String>['gemini-3.6-flash', 'gemini-3.7-flash', 'gemini-2.5-flash-lite']);
    });

    test(
      'HarnessContext resolves package directory and loads model and fallovers from config.json',
      () {
        final context = HarnessContext(issueNumber: 3, isDryRun: true);
        expect(context.model, 'gemini-3.6-flash');
        // `.agents/config.json` is gitignored, so this assertion reads a local
        // override on a developer machine and the hardcoded defaults in
        // `resolveFallbackModels` on CI. Keep the two lists identical or this
        // test passes in one place and fails in the other.
        expect(context.fallbackModels, <String>[
          'gemini-3.6-flash',
          'gemini-3.7-flash',
          'gemini-2.5-flash-lite',
        ]);
        expect(context.maxRetries, 5);
      },
    );

    test('injectTestCode inserts test block before final closing brace', () {
      const original = 'void main() {\n  test("existing", () {});\n}\n';
      const newTest = '  test("new", () {});';
      final String result = injectTestCode(original, newTest);

      expect(result, 'void main() {\n  test("existing", () {});\n\n  test("new", () {});\n}\n');
    });

    test('applyTargetedEdit performs exact and whitespace-tolerant replacement', () {
      const original = 'class Foo {\n  final int a;\n  final int b;\n}\n';
      const search = '  final int b;';
      const replace = '  final int b;\n  final int c;';

      final String result = applyTargetedEdit(
        originalContent: original,
        searchBlock: search,
        replaceBlock: replace,
      );
      expect(result, 'class Foo {\n  final int a;\n  final int b;\n  final int c;\n}\n');

      // Whitespace tolerant match with CRLF
      const crlfOriginal = 'class Bar {\r\n  final String x;   \r\n}\r\n';
      const cleanSearch = '  final String x;';
      const cleanReplace = '  final String x;\n  final String y;';
      final String crlfResult = applyTargetedEdit(
        originalContent: crlfOriginal,
        searchBlock: cleanSearch,
        replaceBlock: cleanReplace,
      );
      expect(crlfResult, 'class Bar {\n  final String x;\n  final String y;\n}\n');
    });

    test('applyTargetedEdit matches even when leading indentation differs', () {
      const original = 'class Foo {\n  final int a;\n  final int b;\n}\n';
      const searchWithoutIndent = 'final int b;';
      const replace = '  final int b;\n  final int c;';

      final String result = applyTargetedEdit(
        originalContent: original,
        searchBlock: searchWithoutIndent,
        replaceBlock: replace,
      );
      expect(result, 'class Foo {\n  final int a;\n  final int b;\n  final int c;\n}\n');
    });

    test('applyTargetedEdit throws StateError with filePath when search block is missing', () {
      const original = 'class Foo {\n  final int a;\n}\n';
      expect(
        () => applyTargetedEdit(
          originalContent: original,
          searchBlock: 'nonExistentCode();',
          replaceBlock: 'bar();',
          filePath: 'lib/foo.dart',
        ),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains("Targeted search_block not found in file 'lib/foo.dart'"),
          ),
        ),
      );
    });

    test(
      'applyTargetedEdit matches even with leading and trailing blank lines in search block',
      () {
        const original = 'class Foo {\n  final int a;\n  final int b;\n}\n';
        const searchWithBlankLines = '\n\n  final int b;\n\n';
        const replace = '  final int b;\n  final int c;';

        final String result = applyTargetedEdit(
          originalContent: original,
          searchBlock: searchWithBlankLines,
          replaceBlock: replace,
          filePath: 'lib/foo.dart',
        );
        expect(result, 'class Foo {\n  final int a;\n  final int b;\n  final int c;\n}\n');
      },
    );

    test('handleRedTest stops early when attempts keep failing identically', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);

      final mockAgent = MockHarnessAgent();
      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 0, stdout: 'All tests passed', stderr: ''),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        agent: mockAgent,
      );
      await harness.handleRedTest();

      // The agent produces the same test every time, so attempts 3 through 5
      // would be identical resamples. Each one costs a model call and a test
      // run, so the loop gives up once the failure repeats.
      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.logs, contains(contains('Red test attempt 1 of 5')));
      expect(context.logs, contains(contains('Red test attempt 2 of 5')));
      expect(context.logs, isNot(contains(contains('Red test attempt 3 of 5'))));
      expect(context.logs, contains(contains('failed the same way as the previous attempt')));
      expect(context.failureReason, contains('FAIL_TO_PASS Invariant Violated'));
    });

    test('handleRedTest recovers on attempt 2 when attempt 1 passes on clean main', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);

      final mockAgent = MockHarnessAgent();
      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 0, stdout: 'All tests passed', stderr: ''),
        resultToReturnNext: const TestRunResult(
          exitCode: 1,
          stdout: 'Error: The getter originalPurchaseDate is not defined',
          stderr: '',
        ),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        agent: mockAgent,
      );
      await harness.handleRedTest();

      expect(context.currentPhase, HarnessPhase.implementation);
      expect(context.logs, contains(contains('⚠️ Attempt 1 failed')));
      expect(context.logs, contains(contains('Red test attempt 2 of 5')));
      expect(context.logs, contains(contains('FAIL_TO_PASS verified')));
    });

    test('handleImplementation stops early when attempts keep failing identically', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockAgent = MockHarnessAgent();
      final mockGen = MockCodeGenerator(
        const CodeGenResult(exitCode: 1, stdout: '', stderr: 'Syntax error'),
        failAttemptsCount: 10,
      );
      final mockRunner = MockTestRunner(const TestRunResult(exitCode: 0, stdout: '', stderr: ''));

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
      );
      await harness.handleImplementation();

      // Codegen fails identically every time, so the remaining attempts would
      // each burn a model call and a full suite run to learn nothing.
      expect(context.currentPhase, HarnessPhase.failed);
      expect(mockAgent.generateFixCallCount, 2);
      expect(mockGen.generateCallCount, 2);
      expect(context.logs, contains(contains('Implementation attempt 1 of 5')));
      expect(context.logs, contains(contains('Implementation attempt 2 of 5')));
      expect(context.logs, isNot(contains(contains('Implementation attempt 3 of 5'))));
      expect(context.failureReason, contains('Code generation failed'));
    });

    test('handleImplementation uses the full retry budget when each failure differs', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockAgent = MockHarnessAgent();
      final mockGen = MockCodeGenerator(
        const CodeGenResult(exitCode: 1, stdout: '', stderr: 'Syntax error'),
        failAttemptsCount: 10,
        varyFailures: true,
      );
      final mockRunner = MockTestRunner(const TestRunResult(exitCode: 0, stdout: '', stderr: ''));

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
      );
      await harness.handleImplementation();

      // Each attempt fails differently, which is evidence the agent is still
      // exploring. Early abort must not cut that short.
      expect(context.currentPhase, HarnessPhase.failed);
      expect(mockGen.generateCallCount, 5);
      expect(context.logs, contains(contains('Implementation attempt 5 of 5')));
      expect(
        context.logs,
        isNot(contains(contains('failed the same way as the previous attempt'))),
      );
    });

    test('handleImplementation rejects a fix that edits a generated file', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockAgent = MockHarnessAgent(
        fixToReturn: const ImplementationFix(
          summary: 'Edit the generated Pigeon output directly',
          patches: <FilePatch>[
            FilePatch(filePath: 'lib/src/sk2_pigeon.g.dart', content: '// hand edited'),
          ],
        ),
      );
      final mockGen = MockCodeGenerator(const CodeGenResult(exitCode: 0, stdout: '', stderr: ''));
      final mockRunner = MockTestRunner(const TestRunResult(exitCode: 0, stdout: '', stderr: ''));

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
      );
      await harness.handleImplementation();

      // Rejected before code generation runs, which would otherwise overwrite
      // the hand edit and hide that it ever happened.
      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.failureReason, contains('generated file'));
      expect(mockGen.generateCallCount, 0);
    });

    test('handleImplementation rejects a fix whose native sources fail to type-check', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockAgent = MockHarnessAgent();
      final mockGen = MockCodeGenerator(
        const CodeGenResult(exitCode: 0, stdout: 'Generated', stderr: ''),
      );
      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 0, stdout: 'All tests passed', stderr: ''),
      );
      final mockNative = MockNativeAnalyzer(
        resultToReturn: const NativeAnalysisResult(
          exitCode: 1,
          stdout: '',
          stderr: "Translators.swift:14:20: error: cannot find 'originalBuyDate' in scope",
        ),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: mockNative,
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
      );
      await harness.handleImplementation();

      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.failureReason, contains('Native analysis failed'));
      expect(context.failureReason, contains('originalBuyDate'));
      // The Dart suite mocks the platform channel, so it would have passed
      // despite the broken Swift. The gate must run before it, and short
      // circuit it.
      expect(mockRunner.lastRanTestFilePath, isNull);
    });

    test('handleImplementation records why native analysis was skipped', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockAgent = MockHarnessAgent();
      final mockGen = MockCodeGenerator(
        const CodeGenResult(exitCode: 0, stdout: 'Generated', stderr: ''),
      );
      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 0, stdout: 'All tests passed', stderr: ''),
      );
      final mockNative = MockNativeAnalyzer(
        resultToReturn: const NativeAnalysisResult.skipped('Swift type-checking requires macOS.'),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: mockNative,
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
        validator: MockGuardrailValidator(const ValidationResult(isValid: true)),
      );
      await harness.handleImplementation();

      // A runner without Xcode must still be able to finish a run; the gap is
      // recorded rather than treated as either success or failure.
      expect(context.currentPhase, HarnessPhase.validation);
      expect(context.state.nativeAnalysisSkippedReason, contains('requires macOS'));
      expect(context.logs, contains(contains('Native analysis skipped')));
    });

    test('handleImplementation recovers on attempt 2 when attempt 1 fails codegen', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockAgent = MockHarnessAgent();
      final mockGen = MockCodeGenerator(
        const CodeGenResult(exitCode: 0, stdout: 'Generated', stderr: ''),
        failAttemptsCount: 1,
      );
      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 0, stdout: 'All tests passed', stderr: ''),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
        validator: MockGuardrailValidator(const ValidationResult(isValid: true)),
      );
      await harness.handleImplementation();

      expect(context.currentPhase, HarnessPhase.validation);
      expect(mockAgent.generateFixCallCount, 2);
      expect(mockGen.generateCallCount, 2);
      expect(context.logs, contains(contains('⚠️ Attempt 1 failed')));
      expect(context.logs, contains(contains('Implementation attempt 2 of 5')));
      expect(context.logs, contains(contains('PASS_TO_PASS verified')));
      expect(context.logs, contains(contains('(attempt 2/5)')));
    });

    test(
      'handleImplementation recovers on attempt 2 when attempt 1 fails static analysis',
      () async {
        final context = HarnessContext(
          issueNumber: 3,
          isDryRun: false,
          testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
          issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
        );
        context.transitionTo(HarnessPhase.redTest);
        context.transitionTo(HarnessPhase.implementation);

        final mockAgent = MockHarnessAgent();
        final mockGen = MockCodeGenerator(
          const CodeGenResult(exitCode: 0, stdout: 'Generated', stderr: ''),
        );
        final mockRunner = MockTestRunner(
          const TestRunResult(exitCode: 0, stdout: 'All tests passed', stderr: ''),
        );
        final mockValidator = MockGuardrailValidator(
          const ValidationResult(isValid: true, modifiedFiles: <String>['pigeons/sk2_pigeon.dart']),
          failAttemptsCount: 1,
        );

        final harness = PackageHarness(
          context,
          nativeAnalyzer: MockNativeAnalyzer(),
          workspace: FakeWorkspace(),
          testRunner: mockRunner,
          codeGenerator: mockGen,
          validator: mockValidator,
          agent: mockAgent,
        );
        await harness.handleImplementation();

        expect(context.currentPhase, HarnessPhase.validation);
        expect(mockAgent.generateFixCallCount, 2);
        expect(mockValidator.validateCallCount, 2);
        expect(context.logs, contains(contains('⚠️ Attempt 1 failed')));
        expect(context.logs, contains(contains('Static analysis or guardrail check failed')));
        expect(context.logs, contains(contains('Implementation attempt 2 of 5')));
        expect(context.logs, contains(contains('PASS_TO_PASS verified')));
        expect(context.logs, contains(contains('(attempt 2/5)')));
      },
    );

    test('handleImplementation respects custom maxRetries parameter', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        maxRetries: 2,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockAgent = MockHarnessAgent(shouldThrow: true);
      final mockGen = MockCodeGenerator(const CodeGenResult(exitCode: 0, stdout: '', stderr: ''));
      final mockRunner = MockTestRunner(const TestRunResult(exitCode: 0, stdout: '', stderr: ''));

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
      );
      await harness.handleImplementation();

      expect(context.currentPhase, HarnessPhase.failed);
      expect(mockAgent.generateFixCallCount, 2);
      expect(context.logs, contains(contains('Implementation attempt 1 of 2')));
      expect(context.logs, contains(contains('Implementation attempt 2 of 2')));
      expect(context.logs, isNot(contains(contains('Implementation attempt 3'))));
    });

    test('buildFixPrompt includes reproduction test code and failure stack trace', () {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
        issueBody: 'Please expose originalPurchaseDate.',
        redTestCode:
            "test('should expose originalPurchaseDate', () async {\n  expect(tx.originalPurchaseDate, isNotNull);\n});",
      );
      context.lastTestFailureSummary =
          "test/test.dart:42:5: Error: The getter 'originalPurchaseDate' isn't defined.\n"
          '  test/test.dart 42:5  main.<fn>';

      final String prompt = buildFixPrompt(
        context,
        fileContext: '=== FILE: pigeons/sk2_pigeon.dart ===\ncode',
      );

      expect(prompt, contains('ISSUE #3'));
      expect(prompt, contains('Title: Expose originalPurchaseDate in SK2Transaction'));
      expect(prompt, contains('REPRODUCTION TEST THAT FAILED:'));
      expect(prompt, contains("test('should expose originalPurchaseDate'"));
      expect(prompt, contains('TEST FAILURE & STACK TRACE:'));
      expect(
        prompt,
        contains("test/test.dart:42:5: Error: The getter 'originalPurchaseDate' isn't defined."),
      );
      expect(prompt, contains('test/test.dart 42:5  main.<fn>'));
      expect(prompt, contains('SOURCE FILES:'));
    });

    test('buildFixPrompt omits reproduction test section when redTestCode is null or empty', () {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.lastTestFailureSummary = 'Assertion failed';

      final String prompt = buildFixPrompt(context, fileContext: 'file content');

      expect(prompt, isNot(contains('REPRODUCTION TEST THAT FAILED:')));
      expect(prompt, contains('TEST FAILURE & STACK TRACE:'));
      expect(prompt, contains('Assertion failed'));
    });

    test(
      'handleRedTest captures redTestCode and saves it as artifact on failure verification',
      () async {
        final context = HarnessContext(
          issueNumber: 3,
          isDryRun: false,
          testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
          issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
        );
        context.transitionTo(HarnessPhase.redTest);

        final mockAgent = MockHarnessAgent();
        final mockRunner = MockTestRunner(
          const TestRunResult(
            exitCode: 1,
            stdout:
                'Expected: <true>\n  Actual: <false>\n  test/in_app_purchase_storekit_2_platform_test.dart 42:5  main.<fn>',
            stderr: '',
          ),
        );

        final harness = PackageHarness(
          context,
          nativeAnalyzer: MockNativeAnalyzer(),
          workspace: FakeWorkspace(),
          testRunner: mockRunner,
          agent: mockAgent,
        );
        await harness.handleRedTest();

        expect(context.redTestCode, isNotNull);
        expect(context.debugArtifacts, contains('red_test_attempt_1_code.dart'));
        expect(context.debugArtifacts['red_test_attempt_1_code.dart'], context.redTestCode);
        expect(
          context.lastTestFailureSummary,
          contains('test/in_app_purchase_storekit_2_platform_test.dart 42:5'),
        );
      },
    );
  });

  group('Step 6: PrPublisher & Draft PR Automation', () {
    test('DraftPrMetadata formats title, branch, and markdown body correctly', () {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.validatedModifiedFiles.addAll(<String>[
        'lib/src/store_kit_2_wrappers/sk2_transaction_wrapper.dart',
        'test/in_app_purchase_storekit_2_platform_test.dart',
      ]);

      final metadata = DraftPrMetadata.fromContext(context);

      expect(
        metadata.title,
        '[in_app_purchase_storekit] Expose originalPurchaseDate in SK2Transaction (fixes #3)',
      );
      expect(metadata.branchName, 'agent/fix-issue-3');
      expect(metadata.body, contains('Fixes #3: Expose originalPurchaseDate in SK2Transaction'));
      expect(
        metadata.body,
        contains('`lib/src/store_kit_2_wrappers/sk2_transaction_wrapper.dart`'),
      );
      expect(metadata.body, contains('Verified by the autonomous harness'));
      expect(metadata.body, contains('.agents/README.md'));
      // The checklist was removed: every box was true by construction, since a
      // failed gate aborts instead of publishing.
      expect(metadata.body, isNot(contains('- [x]')));
    });

    test('DraftPrMetadata includes the verified red failure as review evidence', () {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.state.verifiedRedFailureSummary =
          "Error: The getter 'originalPurchaseDate' isn't defined for the class 'SK2Transaction'.";

      final metadata = DraftPrMetadata.fromContext(context);

      // Lets a reviewer confirm the test failed for the right reason, rather
      // than merely that it failed.
      expect(metadata.body, contains('Verified failure before the fix'));
      expect(metadata.body, contains("The getter 'originalPurchaseDate' isn't defined"));
    });

    test('DraftPrMetadata omits the evidence block when no failure was captured', () {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );

      final metadata = DraftPrMetadata.fromContext(context);

      expect(metadata.body, isNot(contains('Verified failure before the fix')));
    });

    test('DraftPrMetadata warns when native sources were not type-checked', () {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.state.nativeAnalysisSkippedReason = 'Swift type-checking requires macOS.';

      final metadata = DraftPrMetadata.fromContext(context);

      // An absent check looks exactly like a passing one unless it is stated.
      expect(metadata.body, contains('not** type-checked'));
      expect(metadata.body, contains('requires macOS'));
    });

    test('DraftPrMetadata omits the native warning when the check ran', () {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );

      final metadata = DraftPrMetadata.fromContext(context);

      expect(metadata.body, isNot(contains('type-checked')));
    });

    test(
      'PackageHarness does not publish PR when publishPr is false (default safety guardrail)',
      () async {
        final context = HarnessContext(
          issueNumber: 42,
          isDryRun: true,
          issueTitle: 'Dry Run Issue',
        );

        final mockPublisher = MockPrPublisher();
        final harness = PackageHarness(
          context,
          nativeAnalyzer: MockNativeAnalyzer(),
          workspace: FakeWorkspace(),
          publisher: mockPublisher,
        );
        final HarnessPhase finalPhase = await harness.run();

        expect(finalPhase, HarnessPhase.complete);
        expect(mockPublisher.publishedPr, isFalse);
        expect(context.publishedPrUrl, isNull);
      },
    );

    test(
      'PackageHarness does not publish PR when isDryRun is true even if publishPr is true',
      () async {
        final context = HarnessContext(
          issueNumber: 42,
          isDryRun: true,
          publishPr: true,
          issueTitle: 'Dry Run Issue',
        );

        final mockPublisher = MockPrPublisher();
        final harness = PackageHarness(
          context,
          nativeAnalyzer: MockNativeAnalyzer(),
          workspace: FakeWorkspace(),
          publisher: mockPublisher,
        );
        final HarnessPhase finalPhase = await harness.run();

        expect(finalPhase, HarnessPhase.complete);
        expect(mockPublisher.publishedPr, isFalse);
        expect(context.publishedPrUrl, isNull);
      },
    );

    test(
      'PackageHarness publishes Draft PR when publishPr is true and validation completes',
      () async {
        final context = HarnessContext(
          issueNumber: 3,
          isDryRun: false,
          skipAgent: true,
          publishPr: true,
          testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
          issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
        );

        final mockRunner = MockTestRunner(
          const TestRunResult(exitCode: 1, stdout: 'Red test failed', stderr: ''),
          suiteResultToReturn: const TestRunResult(
            exitCode: 0,
            stdout: 'All tests passed',
            stderr: '',
          ),
          resultToReturnNext: const TestRunResult(exitCode: 0, stdout: 'Passed', stderr: ''),
        );
        final mockGen = MockCodeGenerator(const CodeGenResult(exitCode: 0, stdout: '', stderr: ''));
        final mockValidator = MockGuardrailValidator(
          const ValidationResult(isValid: true, modifiedFiles: <String>['lib/fix.dart']),
        );
        final mockPublisher = MockPrPublisher(
          resultToReturn: const PrPublishResult(
            success: true,
            prUrl: 'https://github.com/LouiseHsu/packages/pull/1234',
          ),
        );

        final harness = PackageHarness(
          context,
          nativeAnalyzer: MockNativeAnalyzer(),
          workspace: FakeWorkspace(),
          testRunner: mockRunner,
          codeGenerator: mockGen,
          validator: mockValidator,
          publisher: mockPublisher,
        );

        final HarnessPhase finalPhase = await harness.run();

        expect(finalPhase, HarnessPhase.complete);
        expect(mockPublisher.publishedPr, isTrue);
        expect(context.publishedPrUrl, 'https://github.com/LouiseHsu/packages/pull/1234');
        expect(
          context.logs,
          contains(contains('Draft PR published: https://github.com/LouiseHsu/packages/pull/1234')),
        );
      },
    );

    test('PackageHarness handles PR publishing failure gracefully', () async {
      // Publish failures now persist diagnostics, so redirect them to a temp
      // directory instead of polluting the package's real .agents/logs/.
      final Directory tempLogDir = Directory.systemTemp.createTempSync(
        'harness_pr_publish_failure_',
      );
      addTearDown(() {
        if (tempLogDir.existsSync()) {
          tempLogDir.deleteSync(recursive: true);
        }
      });

      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        skipAgent: true,
        publishPr: true,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      )..customLogParentDirectory = tempLogDir.path;

      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 1, stdout: 'Red test failed', stderr: ''),
        suiteResultToReturn: const TestRunResult(
          exitCode: 0,
          stdout: 'All tests passed',
          stderr: '',
        ),
        resultToReturnNext: const TestRunResult(exitCode: 0, stdout: 'Passed', stderr: ''),
      );
      final mockGen = MockCodeGenerator(const CodeGenResult(exitCode: 0, stdout: '', stderr: ''));
      final mockValidator = MockGuardrailValidator(
        const ValidationResult(isValid: true, modifiedFiles: <String>['lib/fix.dart']),
      );
      final mockPublisher = MockPrPublisher(
        resultToReturn: const PrPublishResult(
          success: false,
          failureReason: 'gh: authentication failed',
        ),
      );

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        validator: mockValidator,
        publisher: mockPublisher,
      );

      final HarnessPhase finalPhase = await harness.run();

      // The fix itself is verified, so the harness still reaches `complete`...
      expect(finalPhase, HarnessPhase.complete);
      expect(mockPublisher.publishedPr, isTrue);
      expect(context.publishedPrUrl, isNull);
      // ...but the failure must be recorded so runPipeline can exit non-zero
      // rather than reporting a misleading success.
      expect(context.prPublishFailureReason, 'gh: authentication failed');
      expect(context.debugArtifacts, contains('pr_publish_failure.txt'));
      expect(
        context.logs,
        contains(contains('Failed to publish Draft PR: gh: authentication failed')),
      );
    });

    test('PackageHarness records no publish failure when the PR succeeds', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        skipAgent: true,
        publishPr: true,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );

      final mockRunner = MockTestRunner(
        const TestRunResult(exitCode: 1, stdout: 'Red test failed', stderr: ''),
        suiteResultToReturn: const TestRunResult(
          exitCode: 0,
          stdout: 'All tests passed',
          stderr: '',
        ),
        resultToReturnNext: const TestRunResult(exitCode: 0, stdout: 'Passed', stderr: ''),
      );
      final mockGen = MockCodeGenerator(const CodeGenResult(exitCode: 0, stdout: '', stderr: ''));
      final mockValidator = MockGuardrailValidator(
        const ValidationResult(isValid: true, modifiedFiles: <String>['lib/fix.dart']),
      );
      final mockPublisher = MockPrPublisher();

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
        testRunner: mockRunner,
        codeGenerator: mockGen,
        validator: mockValidator,
        publisher: mockPublisher,
      );

      expect(await harness.run(), HarnessPhase.complete);
      expect(context.prPublishFailureReason, isNull);
      expect(context.publishedPrUrl, isNotNull);
    });
  });

  group('Failure Logging & Artifact Storage', () {
    test('does not save logs to disk when run succeeds', () async {
      final Directory tempDir = Directory.systemTemp.createTempSync('harness_log_test_success_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final context = HarnessContext(issueNumber: 42, isDryRun: true, issueTitle: 'Successful Run');
      context.customLogParentDirectory = tempDir.path;

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
      );
      final HarnessPhase finalPhase = await harness.run();

      expect(finalPhase, HarnessPhase.complete);
      expect(tempDir.listSync(), isEmpty);
    });

    test('saves timestamped failure logs and debug artifacts to disk on failure', () async {
      final Directory tempDir = Directory.systemTemp.createTempSync('harness_log_test_failure_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final context = HarnessContext(
        issueNumber: 42,
        isDryRun: false,
        skipAgent: true,
        testFilePath: 'test/non_existent.dart',
        issueTitle: 'Failing Run',
      );
      context.customLogParentDirectory = tempDir.path;
      context.recordArtifact('custom_error_trace.txt', 'Pigeon compiler error details');

      final harness = PackageHarness(
        context,
        nativeAnalyzer: MockNativeAnalyzer(),
        workspace: FakeWorkspace(),
      );
      final HarnessPhase finalPhase = await harness.run();

      expect(finalPhase, HarnessPhase.failed);
      expect(context.failureReason, isNotNull);

      final List<FileSystemEntity> logFolders = tempDir.listSync();
      expect(logFolders.length, 1);
      expect(logFolders.first, isA<Directory>());
      expect(logFolders.first.path, contains('run_issue_42_'));

      final savedDir = logFolders.first as Directory;
      final harnessLog = File('${savedDir.path}/harness.log');
      final failureReason = File('${savedDir.path}/failure_reason.txt');
      final customTrace = File('${savedDir.path}/custom_error_trace.txt');

      expect(harnessLog.existsSync(), isTrue);
      expect(harnessLog.readAsStringSync(), contains('Phase 1 (FAIL_TO_PASS)'));
      expect(failureReason.existsSync(), isTrue);
      expect(failureReason.readAsStringSync(), contains('Test file not found'));
      expect(customTrace.existsSync(), isTrue);
      expect(customTrace.readAsStringSync(), 'Pigeon compiler error details');
      expect(context.logs, contains(contains('Failure logs saved to:')));
    });
  });

  group('Skeleton edit destinations', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('skeleton_edits_');
      Directory('${tempDir.path}/lib/src').createSync(recursive: true);
      File('${tempDir.path}/lib/src/wrapper.dart').writeAsStringSync('class Wrapper {}\n');
      Directory('${tempDir.path}/test').createSync(recursive: true);
      File('${tempDir.path}/test/package_test.dart').writeAsStringSync('void main() {}\n');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('accepts edits against production files', () {
      expect(
        () => validateSkeletonEdits(
          edits: <Map<String, dynamic>>[
            <String, dynamic>{
              'file_path': 'lib/src/wrapper.dart',
              'search_block': 'class Wrapper {}',
              'replace_block': 'class Wrapper {}',
            },
          ],
          packageDir: tempDir.path,
          testFilePath: 'test/package_test.dart',
        ),
        returnsNormally,
      );
    });

    test('rejects an edit aimed at the test file, and says why', () {
      expect(
        () => validateSkeletonEdits(
          edits: <Map<String, dynamic>>[
            <String, dynamic>{
              'file_path': 'test/package_test.dart',
              'search_block': 'void main() {}',
              'replace_block': 'class Wrapper {}\nvoid main() {}',
            },
          ],
          packageDir: tempDir.path,
          testFilePath: 'test/package_test.dart',
        ),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            allOf(
              contains('targeted the test file'),
              // The message is fed back to the model verbatim, so it has to
              // name the destination. Run 7 spent four attempts failing because
              // the only feedback available was "did not compile".
              contains('lib/'),
            ),
          ),
        ),
      );
    });

    test('rejects an edit against a file that does not exist', () {
      expect(
        () => validateSkeletonEdits(
          edits: <Map<String, dynamic>>[
            <String, dynamic>{
              'file_path': 'lib/src/imaginary.dart',
              'search_block': 'x',
              'replace_block': 'y',
            },
          ],
          packageDir: tempDir.path,
          testFilePath: 'test/package_test.dart',
        ),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('File not found for skeleton stub'),
          ),
        ),
      );
    });

    test('rejects the whole batch before applying any of it', () {
      // A good edit ahead of a bad one must not reach the filesystem. The
      // harness only restores files it has snapshotted, so a partial apply
      // would leak into the next attempt.
      expect(
        () => validateSkeletonEdits(
          edits: <Map<String, dynamic>>[
            <String, dynamic>{
              'file_path': 'lib/src/wrapper.dart',
              'search_block': 'class Wrapper {}',
              'replace_block': 'class Wrapper { int? x; }',
            },
            <String, dynamic>{
              'file_path': 'test/package_test.dart',
              'search_block': 'void main() {}',
              'replace_block': 'void main() {}',
            },
          ],
          packageDir: tempDir.path,
          testFilePath: 'test/package_test.dart',
        ),
        throwsA(isA<StateError>()),
      );
      expect(File('${tempDir.path}/lib/src/wrapper.dart').readAsStringSync(), 'class Wrapper {}\n');
    });
  });

  group('Shared source context', () {
    test('the red test and implementation phases read the same files', () {
      // Both phases call readSurfaceFiles. The red test phase emits
      // search/replace edits against these files, so if the two lists ever
      // diverge it can be asked to edit a file it was never shown -- which is
      // exactly how run 7 failed.
      expect(storeKit2SurfaceFiles, contains('pigeons/sk2_pigeon.dart'));
      expect(storeKit2SurfaceFiles, contains('test/fakes/fake_storekit_platform.dart'));
      expect(
        storeKit2SurfaceFiles.where((String p) => p.endsWith('.g.dart')),
        isEmpty,
        reason: 'Pigeon owns generated files and a guardrail rejects hand edits to them.',
      );
    });

    test('skips files that are not present', () {
      final Directory tempDir = Directory.systemTemp.createTempSync('surface_files_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      expect(readSurfaceFiles(tempDir.path), isEmpty);
    });
  });
}

class MockTestRunner implements TestRunner {
  MockTestRunner(this.resultToReturn, {this.suiteResultToReturn, this.resultToReturnNext});

  final TestRunResult resultToReturn;
  final TestRunResult? suiteResultToReturn;
  final TestRunResult? resultToReturnNext;
  int runCount = 0;
  String? lastRanTestFilePath;
  String? lastWorkingDirectory;
  bool ranSuite = false;

  @override
  Future<TestRunResult> runTest({
    required String testFilePath,
    required String workingDirectory,
  }) async {
    lastRanTestFilePath = testFilePath;
    lastWorkingDirectory = workingDirectory;
    runCount++;
    if (runCount > 1 && resultToReturnNext != null) {
      return resultToReturnNext!;
    }
    return resultToReturn;
  }

  @override
  Future<TestRunResult> runSuite({required String workingDirectory}) async {
    ranSuite = true;
    lastWorkingDirectory = workingDirectory;
    return suiteResultToReturn ?? resultToReturn;
  }
}

class MockPrPublisher implements PrPublisher {
  MockPrPublisher({
    this.resultToReturn = const PrPublishResult(
      success: true,
      prUrl: 'https://github.com/LouiseHsu/packages/pull/999',
    ),
  });

  final PrPublishResult resultToReturn;
  bool publishedPr = false;
  HarnessContext? lastContext;

  @override
  Future<PrPublishResult> publishDraftPr(HarnessContext context) async {
    publishedPr = true;
    lastContext = context;
    return resultToReturn;
  }
}

class MockGuardrailValidator implements GuardrailValidator {
  MockGuardrailValidator(this.resultToReturn, {this.failAttemptsCount = 0});

  final ValidationResult resultToReturn;
  final int failAttemptsCount;
  int validateCallCount = 0;
  String? lastValidatedPackagePath;
  String? lastValidatedPackageName;

  @override
  Future<ValidationResult> validate({
    required String packagePath,
    required String packageName,
  }) async {
    validateCallCount++;
    lastValidatedPackagePath = packagePath;
    lastValidatedPackageName = packageName;
    if (validateCallCount <= failAttemptsCount) {
      return const ValidationResult(
        isValid: false,
        failureReason: 'Static analysis check failed: missing constructor initializer',
      );
    }
    return resultToReturn;
  }
}

/// A [Workspace] that records calls instead of touching git or the disk.
///
/// The real implementation runs `git checkout -- .`, which discards
/// uncommitted work. Pointed at the package under test -- which is this very
/// checkout -- it would delete the developer's changes as a side effect of
/// running the suite. [GitWorkspace] is covered by hermetic tests over
/// throwaway repositories in `workspace_test.dart` instead.
class FakeWorkspace implements Workspace {
  FakeWorkspace({this.untracked = const <String>{}});

  final Set<String> untracked;

  int revertCallCount = 0;

  @override
  Future<Set<String>> untrackedFiles(String targetDir) async => untracked;

  @override
  Future<RevertResult> revert(String targetDir, Set<String> baselineUntracked) async {
    revertCallCount++;
    return const RevertResult();
  }
}

/// A [NativeAnalyzer] that reports a canned result without running a compiler.
///
/// Injected everywhere a [PackageHarness] is built so the suite never shells
/// out to `swiftc`, which would make these tests depend on the developer's
/// Xcode install and on the working tree being free of Swift errors.
class MockNativeAnalyzer implements NativeAnalyzer {
  MockNativeAnalyzer({
    this.resultToReturn = const NativeAnalysisResult(exitCode: 0, stdout: '', stderr: ''),
  });

  final NativeAnalysisResult resultToReturn;

  int analyzeCallCount = 0;

  @override
  Future<NativeAnalysisResult> analyze({required String packagePath}) async {
    analyzeCallCount++;
    return resultToReturn;
  }
}

class MockCodeGenerator implements CodeGenerator {
  MockCodeGenerator(this.resultToReturn, {this.failAttemptsCount = 0, this.varyFailures = false});

  final CodeGenResult resultToReturn;
  final int failAttemptsCount;

  /// Whether each failure should differ, simulating an agent that tries
  /// something genuinely new each attempt rather than repeating itself.
  final bool varyFailures;
  int generateCallCount = 0;
  String? lastGeneratedPackagePath;
  String? lastGeneratedPackageName;

  @override
  Future<CodeGenResult> generate({required String packagePath, required String packageName}) async {
    generateCallCount++;
    lastGeneratedPackagePath = packagePath;
    lastGeneratedPackageName = packageName;
    if (generateCallCount <= failAttemptsCount) {
      return CodeGenResult(
        exitCode: 1,
        stdout: '',
        stderr: varyFailures
            // Varies by symbol name, not by a number: digits are normalized
            // away when comparing failures, since line numbers and durations
            // shift without the underlying failure changing.
            ? 'Pigeon syntax error: unexpected token '
                  '"${String.fromCharCode(96 + generateCallCount)}Symbol"'
            : 'Pigeon syntax error on attempt',
      );
    }
    return resultToReturn;
  }
}

class MockHarnessAgent implements HarnessAgent {
  MockHarnessAgent({
    this.redTestPatchToReturn,
    this.fixToReturn,
    this.shouldThrow = false,
    this.failAttemptsCount = 0,
  });

  final FilePatch? redTestPatchToReturn;
  final ImplementationFix? fixToReturn;
  final bool shouldThrow;
  final int failAttemptsCount;

  bool generatedRedTest = false;
  bool generatedFix = false;
  int generateFixCallCount = 0;

  @override
  Future<FilePatch> generateRedTest(HarnessContext context) async {
    if (shouldThrow) {
      throw StateError('Agent failed to generate red test');
    }
    generatedRedTest = true;
    context.redTestCode ??= '// Mock reproduction test';
    return redTestPatchToReturn ??
        FilePatch(
          filePath: context.testFilePath ?? 'test/in_app_purchase_storekit_2_platform_test.dart',
          content: '// Mock reproduction test',
        );
  }

  @override
  Future<ImplementationFix> generateFix(HarnessContext context) async {
    generateFixCallCount++;
    if (shouldThrow || generateFixCallCount <= failAttemptsCount) {
      throw StateError('Agent failed to generate implementation fix');
    }
    generatedFix = true;
    return fixToReturn ??
        const ImplementationFix(
          patches: <FilePatch>[
            FilePatch(
              filePath: 'lib/src/store_kit_2_wrappers/sk2_transaction_wrapper.dart',
              content: '// Mock fix',
            ),
          ],
          summary: 'Mock fix applied',
        );
  }
}
