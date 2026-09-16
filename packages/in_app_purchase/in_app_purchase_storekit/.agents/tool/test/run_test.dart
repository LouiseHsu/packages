// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';
import '../run.dart';
import '../triage.dart';

void main() {
  group('Pipeline Argument Parsing', () {
    test('parses flags and parameters cleanly without hardcoding', () {
      final PipelineOptions options = parsePipelineArgs(<String>[
        '--issue=42',
        '--title=Expose transactionReason in SK2Transaction',
        '--body=Need transactionReason to distinguish purchases.',
        '--repo=my-org/custom-packages',
        '--package=in_app_purchase_storekit',
        '--package-path=/custom/path',
        '--test=test/custom_test.dart',
        '--model=gemini-2.5-pro',
        '--min-triage-score=8',
        '--max-retries=3',
        '--skip-triage',
        '--dry-run',
        '--publish-pr',
      ]);

      expect(options.issueNumber, 42);
      expect(options.issueTitle, 'Expose transactionReason in SK2Transaction');
      expect(options.issueBody, 'Need transactionReason to distinguish purchases.');
      expect(options.repo, 'my-org/custom-packages');
      expect(options.packageName, 'in_app_purchase_storekit');
      expect(options.packagePath, '/custom/path');
      expect(options.testFilePath, 'test/custom_test.dart');
      expect(options.model, 'gemini-2.5-pro');
      expect(options.minTriageScore, 8);
      expect(options.maxRetries, 3);
      expect(options.skipTriage, isTrue);
      expect(options.isDryRun, isTrue);
      expect(options.publishPr, isTrue);
    });

    test('defaults to null issueNumber when no issue is provided', () {
      final PipelineOptions options = parsePipelineArgs(<String>[]);
      expect(options.issueNumber, isNull);
      expect(options.issueTitle, isEmpty);
      expect(options.skipTriage, isFalse);
      expect(options.triageOnly, isFalse);
      expect(options.isDryRun, isFalse);
      expect(options.publishPr, isFalse);
    });

    test('parses issue metadata from environment variables', () {
      final PipelineOptions options = parsePipelineArgs(<String>[], <String, String>{
        'ISSUE_NUMBER': '77',
        'ISSUE_TITLE': 'Fix StoreKit crash',
        'ISSUE_BODY': 'Crashes on null receipt',
        'GITHUB_REPOSITORY': 'upstream/packages',
      });

      expect(options.issueNumber, 77);
      expect(options.issueTitle, 'Fix StoreKit crash');
      expect(options.issueBody, 'Crashes on null receipt');
      expect(options.repo, 'upstream/packages');
    });
  });

  group('Pipeline Orchestration & Triage Integration', () {
    test('returns 0 and prints usage when --help is passed', () async {
      final logs = <String>[];
      final int exitCode = await runPipeline(
        <String>['--help'],
        logger: logs.add,
      );

      expect(exitCode, 0);
      expect(logs.any((String line) => line.contains('Usage: dart run .agents/tool/run.dart')), isTrue);
    });

    test('fails with error 1 when no issue number or title is provided', () async {
      final errLogs = <String>[];
      final int exitCode = await runPipeline(
        <String>[],
        errorLogger: errLogs.add,
      );

      expect(exitCode, 1);
      expect(errLogs.any((String line) => line.contains('Error: Missing issue specification')), isTrue);
    });

    test('fails with error 1 when gh CLI fetch fails to resolve issue title', () async {
      final logs = <String>[];
      final errLogs = <String>[];

      final int exitCode = await runPipeline(
        <String>['--issue=999'],
        issueFetcher: (int issueNumber, String? repo) async => null,
        logger: logs.add,
        errorLogger: errLogs.add,
      );

      expect(exitCode, 1);
      expect(
        errLogs.any((String line) => line.contains('Could not resolve issue #999 title from GitHub')),
        isTrue,
      );
    });

    test('stops early when triage declines an issue (e.g. flaky keyword or score < 7)', () async {
      final logs = <String>[];
      var harnessCalled = false;

      final int exitCode = await runPipeline(
        <String>['--issue=50', '--title=Flaky purchase timeout on cellular'],
        triageEvaluator: ({
          required String title,
          required String body,
          required int issueNumber,
          String? apiKey,
          String? gcpAccessToken,
          String? gcpProjectId,
          String? gcpLocation,
          String? model,
          List<String>? fallbackModels,
          int minScore = 7,
          void Function(String message)? logger,
        }) async {
          return const TriageExecutionResult(
            accepted: false,
            reason: 'heuristic_gate_filtered',
          );
        },
        harnessRunner: (HarnessContext context) async {
          harnessCalled = true;
          return HarnessPhase.complete;
        },
        logger: logs.add,
      );

      expect(exitCode, 0);
      expect(harnessCalled, isFalse);
      expect(logs.any((String line) => line.contains('declined by triage (heuristic_gate_filtered)')), isTrue);
    });

    test('exits non-zero when triage errors rather than declining', () async {
      final logs = <String>[];
      var harnessCalled = false;

      final int exitCode = await runPipeline(
        <String>['--issue=51', '--title=Expose originalPurchaseDate on SK2Transaction'],
        triageEvaluator: ({
          required String title,
          required String body,
          required int issueNumber,
          String? apiKey,
          String? gcpAccessToken,
          String? gcpProjectId,
          String? gcpLocation,
          String? model,
          List<String>? fallbackModels,
          int minScore = 7,
          void Function(String message)? logger,
        }) async {
          return const TriageExecutionResult(
            accepted: false,
            reason: 'evaluation_error: 503 UNAVAILABLE',
            isError: true,
          );
        },
        harnessRunner: (HarnessContext context) async {
          harnessCalled = true;
          return HarnessPhase.complete;
        },
        logger: logs.add,
      );

      // A transient outage must not look like a successful run, or CI reports
      // green while the issue silently goes unassessed.
      expect(exitCode, 1);
      expect(harnessCalled, isFalse);
      expect(
        logs.any((String line) => line.contains('could not evaluate issue #51')),
        isTrue,
      );
      // It must not be described as a rejection.
      expect(logs.any((String line) => line.contains('declined by triage')), isFalse);
    });

    test('stops after triage when --triage-only is specified and issue is accepted', () async {
      final logs = <String>[];
      var harnessCalled = false;

      final int exitCode = await runPipeline(
        <String>[
          '--issue=12',
          '--title=Expose expirationDate in SK2Transaction',
          '--triage-only',
        ],
        triageEvaluator: ({
          required String title,
          required String body,
          required int issueNumber,
          String? apiKey,
          String? gcpAccessToken,
          String? gcpProjectId,
          String? gcpLocation,
          String? model,
          List<String>? fallbackModels,
          int minScore = 7,
          void Function(String message)? logger,
        }) async {
          return const TriageExecutionResult(
            accepted: true,
            reason: 'accepted',
            verdict: TriageVerdict(
              isMechanical: true,
              suitabilityScore: 9,
              category: 'missing_field',
              targetFilesHint: <String>['pigeons/sk2_pigeon.dart'],
              reasoning: 'Mechanical field addition.',
            ),
          );
        },
        harnessRunner: (HarnessContext context) async {
          harnessCalled = true;
          return HarnessPhase.complete;
        },
        logger: logs.add,
      );

      expect(exitCode, 0);
      expect(harnessCalled, isFalse);
      expect(logs.any((String line) => line.contains('Triage-only mode enabled')), isTrue);
    });

    test('skips triage evaluation when --skip-triage is specified', () async {
      final logs = <String>[];
      var triageCalled = false;
      var harnessCalled = false;

      final int exitCode = await runPipeline(
        <String>[
          '--issue=15',
          '--title=Expose offerID in SK2Transaction',
          '--skip-triage',
        ],
        triageEvaluator: ({
          required String title,
          required String body,
          required int issueNumber,
          String? apiKey,
          String? gcpAccessToken,
          String? gcpProjectId,
          String? gcpLocation,
          String? model,
          List<String>? fallbackModels,
          int minScore = 7,
          void Function(String message)? logger,
        }) async {
          triageCalled = true;
          return const TriageExecutionResult(accepted: true, reason: 'accepted');
        },
        harnessRunner: (HarnessContext context) async {
          harnessCalled = true;
          expect(context.issueNumber, 15);
          expect(context.issueTitle, 'Expose offerID in SK2Transaction');
          return HarnessPhase.complete;
        },
        logger: logs.add,
      );

      expect(exitCode, 0);
      expect(triageCalled, isFalse);
      expect(harnessCalled, isTrue);
      expect(logs.any((String line) => line.contains('Triage evaluation skipped via --skip-triage')), isTrue);
    });

    test('runs end-to-end: triage accepts -> harness executes -> draft PR logged', () async {
      final logs = <String>[];
      HarnessContext? executedContext;

      final int exitCode = await runPipeline(
        <String>[
          '--issue=21',
          '--title=Expose appAccountToken in SK2Product',
          '--publish-pr',
          '--dry-run',
        ],
        triageEvaluator: ({
          required String title,
          required String body,
          required int issueNumber,
          String? apiKey,
          String? gcpAccessToken,
          String? gcpProjectId,
          String? gcpLocation,
          String? model,
          List<String>? fallbackModels,
          int minScore = 7,
          void Function(String message)? logger,
        }) async {
          return const TriageExecutionResult(
            accepted: true,
            reason: 'accepted',
            verdict: TriageVerdict(
              isMechanical: true,
              suitabilityScore: 10,
              category: 'missing_field',
              targetFilesHint: <String>['pigeons/sk2_pigeon.dart'],
              reasoning: 'Mechanical addition.',
            ),
          );
        },
        harnessRunner: (HarnessContext context) async {
          executedContext = context;
          context.publishedPrUrl = 'https://github.com/LouiseHsu/packages/pull/555';
          return HarnessPhase.complete;
        },
        logger: logs.add,
      );

      expect(exitCode, 0);
      expect(executedContext, isNotNull);
      expect(executedContext!.issueNumber, 21);
      expect(executedContext!.issueTitle, 'Expose appAccountToken in SK2Product');
      expect(executedContext!.publishPr, isTrue);
      expect(executedContext!.isDryRun, isTrue);
      expect(logs.any((String line) => line.contains('Published Draft PR: https://github.com/LouiseHsu/packages/pull/555')), isTrue);
    });

    test('returns exit code 1 when harness fails', () async {
      final logs = <String>[];
      final errLogs = <String>[];

      final int exitCode = await runPipeline(
        <String>[
          '--issue=99',
          '--title=Impossible architectural change',
          '--skip-triage',
        ],
        harnessRunner: (HarnessContext context) async {
          context.failureReason = 'Max retries exceeded';
          return HarnessPhase.failed;
        },
        logger: logs.add,
        errorLogger: errLogs.add,
      );

      expect(exitCode, 1);
      expect(errLogs.any((String line) => line.contains('Pipeline failed in phase HarnessPhase.failed: Max retries exceeded')), isTrue);
    });

    test('returns exit code 1 when the fix is verified but the Draft PR fails to publish', () async {
      final logs = <String>[];
      final errLogs = <String>[];

      final int exitCode = await runPipeline(
        <String>[
          '--issue=7',
          '--title=Expose originalPurchaseDate in SK2Transaction',
          '--skip-triage',
          '--publish-pr',
        ],
        harnessRunner: (HarnessContext context) async {
          // Verification succeeded, but publishing did not.
          context.prPublishFailureReason = 'Failed to stage files: pathspec did not match';
          return HarnessPhase.complete;
        },
        logger: logs.add,
        errorLogger: errLogs.add,
      );

      expect(exitCode, 1);
      expect(
        errLogs.any((String line) => line.contains('Failed to stage files')),
        isTrue,
        reason: 'The publish failure reason must be surfaced to stderr.',
      );
      expect(
        logs.any((String line) => line.contains('PIPELINE SUCCESS')),
        isFalse,
        reason: 'A run with no published PR must not be reported as a success.',
      );
    });

    test('returns exit code 0 on publish failure when --publish-pr was not requested', () async {
      final logs = <String>[];

      final int exitCode = await runPipeline(
        <String>[
          '--issue=7',
          '--title=Expose originalPurchaseDate in SK2Transaction',
          '--skip-triage',
        ],
        harnessRunner: (HarnessContext context) async {
          context.prPublishFailureReason = 'stale value that should be ignored';
          return HarnessPhase.complete;
        },
        logger: logs.add,
        errorLogger: (_) {},
      );

      expect(exitCode, 0);
      expect(logs.any((String line) => line.contains('PIPELINE SUCCESS')), isTrue);
    });
  });
}
