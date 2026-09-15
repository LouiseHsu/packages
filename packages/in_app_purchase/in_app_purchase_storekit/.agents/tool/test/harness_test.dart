// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../codegen.dart';
import '../gemini_agent.dart';
import '../guardrails.dart';
import '../harness.dart';
import '../publisher.dart';
import '../test_runner.dart';

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

      final harness = PackageHarness(context, testRunner: mockRunner);
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

        final harness = PackageHarness(context, testRunner: mockRunner);
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

      final harness = PackageHarness(context, testRunner: mockRunner);
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

        final harness = PackageHarness(context, testRunner: mockRunner);
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

      final harness = PackageHarness(context);
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

        final harness = PackageHarness(context, validator: mockValidator);
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

      final harness = PackageHarness(context, validator: mockValidator);
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

      final harness = PackageHarness(context, testRunner: mockRunner, codeGenerator: mockGen);
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

        final harness = PackageHarness(context, testRunner: mockRunner, codeGenerator: mockGen);
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

      final harness = PackageHarness(context, testRunner: mockRunner, codeGenerator: mockGen);
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

        final harness = PackageHarness(context, testRunner: mockRunner, codeGenerator: mockGen);
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

      final harness = PackageHarness(context, testRunner: mockRunner, agent: mockAgent);
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

      final harness = PackageHarness(context, testRunner: mockRunner, agent: mockAgent);
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

      final harness = PackageHarness(context, testRunner: mockRunner, agent: mockAgent);
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
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
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
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
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
      expect(models, <String>[
        'gemini-3.7-flash',
        'gemini-pro-latest',
        'gemini-3.6-flash',
      ]);

      expect(resolveDefaultModel(packageDir: tempDir.path), 'gemini-3.6-flash');
    });

    test('resolveFallbackModels returns defaults when config file is missing', () {
      final List<String> defaults = resolveFallbackModels(packageDir: '/non_existent_path');
      expect(defaults, <String>[
        'gemini-3.7-flash',
        'gemini-pro-latest',
        'gemini-3.6-flash',
      ]);
    });

    test('HarnessContext resolves package directory and loads model and fallovers from config.json', () {
      final context = HarnessContext(issueNumber: 3, isDryRun: true);
      expect(context.model, 'gemini-3.6-flash');
      expect(context.fallbackModels, <String>[
        'gemini-pro-latest',
        'gemini-3.7-flash',
        'gemini-3.6-flash',
      ]);
      expect(context.maxRetries, 5);
    });

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

    test('applyTargetedEdit matches even with leading and trailing blank lines in search block', () {
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
    });

    test('handleRedTest retries up to maxRetries when test passes on clean main', () async {
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

      final harness = PackageHarness(context, testRunner: mockRunner, agent: mockAgent);
      await harness.handleRedTest();

      expect(context.currentPhase, HarnessPhase.failed);
      expect(context.logs, contains(contains('Red test attempt 1 of 5')));
      expect(context.logs, contains(contains('Red test attempt 2 of 5')));
      expect(context.logs, contains(contains('Red test attempt 3 of 5')));
      expect(context.logs, contains(contains('Red test attempt 4 of 5')));
      expect(context.logs, contains(contains('Red test attempt 5 of 5')));
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

      final harness = PackageHarness(context, testRunner: mockRunner, agent: mockAgent);
      await harness.handleRedTest();

      expect(context.currentPhase, HarnessPhase.implementation);
      expect(context.logs, contains(contains('⚠️ Attempt 1 failed')));
      expect(context.logs, contains(contains('Red test attempt 2 of 5')));
      expect(context.logs, contains(contains('FAIL_TO_PASS verified')));
    });

    test('handleImplementation retries up to maxRetries (5 times) on failure before failing', () async {
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
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
      );
      await harness.handleImplementation();

      expect(context.currentPhase, HarnessPhase.failed);
      expect(mockAgent.generateFixCallCount, 5);
      expect(mockGen.generateCallCount, 5);
      expect(context.logs, contains(contains('Implementation attempt 1 of 5')));
      expect(context.logs, contains(contains('Implementation attempt 2 of 5')));
      expect(context.logs, contains(contains('Implementation attempt 3 of 5')));
      expect(context.logs, contains(contains('Implementation attempt 4 of 5')));
      expect(context.logs, contains(contains('Implementation attempt 5 of 5')));
      expect(context.failureReason, contains('Code generation failed'));
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
        testRunner: mockRunner,
        codeGenerator: mockGen,
        agent: mockAgent,
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

    test('handleImplementation recovers on attempt 2 when attempt 1 fails static analysis', () async {
      final context = HarnessContext(
        issueNumber: 3,
        isDryRun: false,
        testFilePath: 'test/in_app_purchase_storekit_2_platform_test.dart',
        issueTitle: 'Expose originalPurchaseDate in SK2Transaction',
      );
      context.transitionTo(HarnessPhase.redTest);
      context.transitionTo(HarnessPhase.implementation);

      final mockAgent = MockHarnessAgent();
      final mockGen = MockCodeGenerator(const CodeGenResult(exitCode: 0, stdout: 'Generated', stderr: ''));
      final mockRunner = MockTestRunner(const TestRunResult(exitCode: 0, stdout: 'All tests passed', stderr: ''));
      final mockValidator = MockGuardrailValidator(
        const ValidationResult(isValid: true, modifiedFiles: <String>['pigeons/sk2_pigeon.dart']),
        failAttemptsCount: 1,
      );

      final harness = PackageHarness(
        context,
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
    });

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
        redTestCode: "test('should expose originalPurchaseDate', () async {\n  expect(tx.originalPurchaseDate, isNotNull);\n});",
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
      expect(prompt, contains("test/test.dart:42:5: Error: The getter 'originalPurchaseDate' isn't defined."));
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

    test('handleRedTest captures redTestCode and saves it as artifact on failure verification', () async {
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
          stdout: 'Expected: <true>\n  Actual: <false>\n  test/in_app_purchase_storekit_2_platform_test.dart 42:5  main.<fn>',
          stderr: '',
        ),
      );

      final harness = PackageHarness(context, testRunner: mockRunner, agent: mockAgent);
      await harness.handleRedTest();

      expect(context.redTestCode, isNotNull);
      expect(context.debugArtifacts, contains('red_test_attempt_1_code.dart'));
      expect(context.debugArtifacts['red_test_attempt_1_code.dart'], context.redTestCode);
      expect(context.lastTestFailureSummary, contains('test/in_app_purchase_storekit_2_platform_test.dart 42:5'));
    });
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
      expect(metadata.body, contains('- [x] **FAIL_TO_PASS**'));
      expect(metadata.body, contains('- [x] **Monorepo Invariant**'));
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
        final harness = PackageHarness(context, publisher: mockPublisher);
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
        final harness = PackageHarness(context, publisher: mockPublisher);
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

      final context = HarnessContext(
        issueNumber: 42,
        isDryRun: true,
        issueTitle: 'Successful Run',
      );
      context.customLogParentDirectory = tempDir.path;

      final harness = PackageHarness(context);
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

      final harness = PackageHarness(context);
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

class MockCodeGenerator implements CodeGenerator {
  MockCodeGenerator(this.resultToReturn, {this.failAttemptsCount = 0});

  final CodeGenResult resultToReturn;
  final int failAttemptsCount;
  int generateCallCount = 0;
  String? lastGeneratedPackagePath;
  String? lastGeneratedPackageName;

  @override
  Future<CodeGenResult> generate({required String packagePath, required String packageName}) async {
    generateCallCount++;
    lastGeneratedPackagePath = packagePath;
    lastGeneratedPackageName = packageName;
    if (generateCallCount <= failAttemptsCount) {
      return const CodeGenResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Pigeon syntax error on attempt',
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
