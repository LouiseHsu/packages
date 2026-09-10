// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'gemini_agent.dart';
import 'harness.dart';
import 'triage.dart';

/// Parsed options for the unified SWE-bench pipeline.
class PipelineOptions {
  /// Creates a [PipelineOptions].
  PipelineOptions({
    this.issueNumber,
    this.issueTitle = '',
    this.issueBody = '',
    this.repo = 'LouiseHsu/packages',
    this.packageName = 'in_app_purchase_storekit',
    this.packagePath,
    this.testFilePath,
    this.model,
    this.skipTriage = false,
    this.triageOnly = false,
    this.isDryRun = false,
    this.publishPr = false,
    this.maxRetries = 5,
    this.minTriageScore = 7,
  });

  /// Target GitHub issue number.
  int? issueNumber;

  /// Target issue title.
  String issueTitle;

  /// Target issue body.
  String issueBody;

  /// GitHub repository (e.g. LouiseHsu/packages).
  String repo;

  /// Target Flutter package name.
  String packageName;

  /// Target Flutter package directory path.
  String? packagePath;

  /// Target test file path.
  String? testFilePath;

  /// Gemini model name override.
  String? model;

  /// Whether to skip the two-tier triage step and jump straight to the harness.
  bool skipTriage;

  /// Whether to stop after the triage step and not execute the harness.
  bool triageOnly;

  /// Whether to run in dry-run mode (no mutating file writes, no PR creation).
  bool isDryRun;

  /// Whether to publish a Draft PR upon successful resolution.
  bool publishPr;

  /// Maximum number of implementation fix attempts in the harness.
  int maxRetries;

  /// Minimum triage suitability score (0-10) required to accept an issue.
  int minTriageScore;
}

/// Encapsulates the execution result of the two-tier triage pipeline.
class TriageExecutionResult {
  const TriageExecutionResult({
    required this.accepted,
    required this.reason,
    this.verdict,
  });

  final bool accepted;
  final String reason;
  final TriageVerdict? verdict;
}

/// Interface for fetching issue metadata (title & body) from GitHub.
typedef IssueFetcher = Future<Map<String, String>?> Function(int issueNumber, String? repo);

/// Interface for evaluating an issue through the triage pipeline.
typedef TriageEvaluator = Future<TriageExecutionResult> Function({
  required String title,
  required String body,
  required int issueNumber,
  String? apiKey,
  String? gcpAccessToken,
  String? gcpProjectId,
  String? gcpLocation,
  String? model,
  List<String>? fallbackModels,
  int minScore,
  void Function(String message)? logger,
});

/// Evaluates an issue through both Tier 1 and Tier 2 triage stages.
Future<TriageExecutionResult> defaultTriageEvaluator({
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
  final void Function(String) log = logger ?? stdout.writeln;

  // Step 1: Zero-cost regex gate
  if (!passesStaticGate(title, body)) {
    writeGithubOutput('accepted', 'false');
    writeGithubOutput('reason', 'heuristic_gate_filtered');
    log('Verdict: REJECTED (Failed Tier 1 regex heuristic)');
    return const TriageExecutionResult(
      accepted: false,
      reason: 'heuristic_gate_filtered',
    );
  }

  // Step 2: Gemini Structured Evaluation with failover
  final candidateModels = <String>[];
  for (final candidate in <String>[model ?? 'gemini-2.5-flash-lite', ...?fallbackModels]) {
    if (!candidateModels.contains(candidate)) {
      candidateModels.add(candidate);
    }
  }

  TriageVerdict? verdict;
  dynamic lastError;

  for (final activeModel in candidateModels) {
    try {
      log('Querying Gemini ($activeModel) structured evaluation...');
      verdict = await evaluateWithGemini(
        title: title,
        body: body,
        issueNumber: issueNumber,
        apiKey: apiKey,
        gcpAccessToken: gcpAccessToken,
        gcpProjectId: gcpProjectId ?? 'flutter-dev',
        gcpLocation: gcpLocation ?? 'us-central1',
        model: activeModel,
      );
      break;
    } catch (e) {
      lastError = e;
      final errString = e.toString();
      if (errString.contains('503') || errString.contains('429') || errString.contains('404')) {
        log('Notice: Model "$activeModel" unavailable ($errString). Falling back to next model...');
        continue;
      }
      break;
    }
  }

  if (verdict == null) {
    stderr.writeln('Error during triage evaluation: $lastError');
    writeGithubOutput('accepted', 'false');
    writeGithubOutput('reason', 'evaluation_error');
    return TriageExecutionResult(
      accepted: false,
      reason: 'evaluation_error: $lastError',
    );
  }

  log('Evaluation Results:');
  log(' - Category: ${verdict.category}');
  log(' - Is Mechanical: ${verdict.isMechanical}');
  log(' - Suitability Score: ${verdict.suitabilityScore}/10');
  log(' - Target Files: ${verdict.targetFilesHint}');
  log(' - Reasoning: ${verdict.reasoning}');

  final bool accepted = verdict.isMechanical && verdict.suitabilityScore >= minScore;

  writeGithubOutput('accepted', accepted ? 'true' : 'false');
  writeGithubOutput('score', verdict.suitabilityScore.toString());
  writeGithubOutput('category', verdict.category);
  writeGithubOutput('is_mechanical', verdict.isMechanical ? 'true' : 'false');
  writeGithubOutput('reasoning', verdict.reasoning.replaceAll('\n', ' '));

  if (accepted) {
    log('🚀 Verdict: ACCEPTED for automated resolution!');
  } else {
    log('❌ Verdict: REJECTED (Does not meet mechanical criteria)');
  }

  return TriageExecutionResult(
    accepted: accepted,
    reason: accepted ? 'accepted' : 'criteria_unmet',
    verdict: verdict,
  );
}

/// Interface for executing the package harness.
typedef HarnessRunner = Future<HarnessPhase> Function(HarnessContext context);

/// Fetches issue metadata via the GitHub CLI (`gh issue view`).
Future<Map<String, String>?> defaultIssueFetcher(int issueNumber, String? repo) async {
  try {
    final ghArgs = <String>[
      'issue',
      'view',
      issueNumber.toString(),
      '--json',
      'title,body',
    ];
    if (repo != null && repo.isNotEmpty) {
      ghArgs.addAll(<String>['--repo', repo]);
    }

    final ProcessResult result = await Process.run('gh', ghArgs);
    if (result.exitCode == 0) {
      final issueData = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      return <String, String>{
        'title': issueData['title'] as String? ?? '',
        'body': issueData['body'] as String? ?? '',
      };
    }
  } catch (_) {
    // Best-effort gh CLI fetch
  }
  return null;
}

/// Default harness runner that instantiates and runs [PackageHarness].
Future<HarnessPhase> defaultHarnessRunner(HarnessContext context) async {
  final harness = PackageHarness(context);
  return harness.run();
}

/// Prints CLI usage information.
void printPipelineUsage([void Function(String)? sink]) {
  final void Function(String) printLine = sink ?? stdout.writeln;
  printLine('Usage: dart run .agents/tool/run.dart [options]');
  printLine('');
  printLine('Options:');
  printLine('  --issue=<number>        Target GitHub issue number (fetches title & body via gh CLI)');
  printLine('  --title=<string>        Issue title (if specifying directly or testing offline)');
  printLine('  --body=<string>         Issue body (optional additional context)');
  printLine('  --repo=<owner/repo>     Target GitHub repository (default: LouiseHsu/packages)');
  printLine('  --package=<name>        Target package name (default: in_app_purchase_storekit)');
  printLine('  --package-path=<path>   Explicit directory path to package');
  printLine('  --test=<path>           Target test file path');
  printLine('  --model=<name>          Gemini model name');
  printLine('  --skip-triage           Skip triage evaluation and directly execute harness');
  printLine('  --triage-only           Run triage evaluation and exit with verdict without running harness');
  printLine('  --min-triage-score=<N>  Minimum score (0-10) required to accept issue in triage (default: 7)');
  printLine('  --dry-run               Dry run mode: skip mutating code generation and PR creation');
  printLine('  --publish-pr            Publish Draft PR upon successful resolution');
  printLine('  --max-retries=<number>  Max implementation attempts (default: 5)');
  printLine('  --help, -h              Show this help message');
}

/// Parses CLI arguments into a [PipelineOptions] instance.
PipelineOptions parsePipelineArgs(List<String> args, [Map<String, String>? environment]) {
  final Map<String, String> env = environment ?? Platform.environment;

  final options = PipelineOptions(
    issueTitle: env['ISSUE_TITLE'] ?? '',
    issueBody: env['ISSUE_BODY'] ?? '',
    repo: env['GITHUB_REPOSITORY'] ?? 'LouiseHsu/packages',
  );

  final String? envIssue = env['ISSUE_NUMBER'];
  if (envIssue != null && envIssue.isNotEmpty) {
    options.issueNumber = int.tryParse(envIssue);
  }

  // Parse GITHUB_EVENT_PATH if available
  final String? eventPath = env['GITHUB_EVENT_PATH'];
  if (eventPath != null && File(eventPath).existsSync()) {
    try {
      final eventJson = jsonDecode(File(eventPath).readAsStringSync()) as Map<String, dynamic>;
      final issue = eventJson['issue'] as Map<String, dynamic>?;
      if (issue != null) {
        options.issueTitle = issue['title'] as String? ?? options.issueTitle;
        options.issueBody = issue['body'] as String? ?? options.issueBody;
        final numVal = issue['number'] as num?;
        if (numVal != null) {
          options.issueNumber = numVal.toInt();
        }
      }
    } catch (_) {
      // Best-effort GITHUB_EVENT_PATH parsing
    }
  }

  for (final arg in args) {
    if (arg.startsWith('--issue=')) {
      options.issueNumber = int.tryParse(arg.substring('--issue='.length));
    } else if (arg.startsWith('--title=')) {
      options.issueTitle = arg.substring('--title='.length);
    } else if (arg.startsWith('--body=')) {
      options.issueBody = arg.substring('--body='.length);
    } else if (arg.startsWith('--repo=')) {
      options.repo = arg.substring('--repo='.length);
    } else if (arg.startsWith('--package=')) {
      options.packageName = arg.substring('--package='.length);
    } else if (arg.startsWith('--package-path=')) {
      options.packagePath = arg.substring('--package-path='.length);
    } else if (arg.startsWith('--test=')) {
      options.testFilePath = arg.substring('--test='.length);
    } else if (arg.startsWith('--model=')) {
      options.model = arg.substring('--model='.length);
    } else if (arg.startsWith('--min-triage-score=')) {
      options.minTriageScore = int.tryParse(arg.substring('--min-triage-score='.length)) ?? 7;
    } else if (arg.startsWith('--max-retries=')) {
      options.maxRetries = int.tryParse(arg.substring('--max-retries='.length)) ?? 5;
    } else if (arg == '--skip-triage') {
      options.skipTriage = true;
    } else if (arg == '--triage-only') {
      options.triageOnly = true;
    } else if (arg == '--dry-run') {
      options.isDryRun = true;
    } else if (arg == '--publish-pr') {
      options.publishPr = true;
    }
  }

  return options;
}

/// Executes the end-to-end SWE-bench pipeline: Ingestion -> Triage -> Harness -> Draft PR.
Future<int> runPipeline(
  List<String> args, {
  IssueFetcher? issueFetcher,
  TriageEvaluator? triageEvaluator,
  HarnessRunner? harnessRunner,
  void Function(String)? logger,
  void Function(String)? errorLogger,
  Map<String, String>? environment,
}) async {
  final void Function(String) log = logger ?? stdout.writeln;
  final void Function(String) errLog = errorLogger ?? stderr.writeln;
  final Map<String, String> env = environment ?? Platform.environment;

  if (args.contains('--help') || args.contains('-h')) {
    printPipelineUsage(log);
    return 0;
  }

  final PipelineOptions options = parsePipelineArgs(args, env);
  final IssueFetcher fetchIssue = issueFetcher ?? defaultIssueFetcher;
  final TriageEvaluator evaluateTriage = triageEvaluator ?? defaultTriageEvaluator;
  final HarnessRunner runHarness = harnessRunner ?? defaultHarnessRunner;

  // 1. Resolve Issue Metadata (Title & Body)
  if (options.issueTitle.isEmpty) {
    if (options.issueNumber == null) {
      errLog('Error: Missing issue specification. Provide --issue=<number> or --title="<title>".\n');
      printPipelineUsage(errLog);
      return 1;
    }

    log('Fetching issue #${options.issueNumber} metadata from GitHub (${options.repo})...');
    final Map<String, String>? fetched = await fetchIssue(options.issueNumber!, options.repo);
    if (fetched != null && fetched['title'] != null && fetched['title']!.isNotEmpty) {
      options.issueTitle = fetched['title']!;
      options.issueBody = fetched['body'] ?? '';
    } else {
      errLog(
        'Error: Could not resolve issue #${options.issueNumber} title from GitHub. '
        'Provide --title="<title>" to test locally, or authenticate via "gh auth login".',
      );
      return 1;
    }
  }

  final int effectiveIssueNumber = options.issueNumber ?? 0;

  // 2. Triage Phase (Tier 1 & Tier 2)
  if (!options.skipTriage) {
    log('=================== TWO-TIER ISSUE TRIAGE ===================');
    log('Issue #$effectiveIssueNumber: "${options.issueTitle}"');
    log('Target Package: ${options.packageName}');

    final String resolvedPackageDir = HarnessContext.resolvePackageDirectory(
      options.packageName,
      options.packagePath,
    );
    final String resolvedModel = resolveDefaultModel(
      cliModel: options.model,
      packageDir: resolvedPackageDir,
    );
    final List<String> fallbackModels = resolveFallbackModels(
      packageDir: resolvedPackageDir,
    );

    final TriageExecutionResult triageResult = await evaluateTriage(
      title: options.issueTitle,
      body: options.issueBody,
      issueNumber: effectiveIssueNumber,
      apiKey: env['GEMINI_API_KEY'],
      gcpAccessToken: env['GCP_ACCESS_TOKEN'],
      gcpProjectId: env['GCP_PROJECT_ID'],
      gcpLocation: env['GCP_LOCATION'],
      model: resolvedModel,
      fallbackModels: fallbackModels,
      minScore: options.minTriageScore,
      logger: log,
    );

    if (!triageResult.accepted) {
      log('🛑 Issue #$effectiveIssueNumber declined by triage (${triageResult.reason}).');
      log('Halting pipeline without modifying files.');
      return 0;
    }

    log('✅ Issue #$effectiveIssueNumber passed triage evaluation!');
    if (triageResult.verdict != null) {
      log('Triage Verdict: Category=${triageResult.verdict!.category}, Score=${triageResult.verdict!.suitabilityScore}/10');
    }

    if (options.triageOnly) {
      log('Triage-only mode enabled. Exiting before harness execution.');
      return 0;
    }
  } else {
    log('Notice: Triage evaluation skipped via --skip-triage flag.');
  }

  // 3. Autonomous Package Harness Execution
  log('=================== AUTONOMOUS PACKAGE HARNESS ===================');
  log('Issue #$effectiveIssueNumber: "${options.issueTitle}"');
  log('Package: ${options.packageName}');
  log('Dry Run: ${options.isDryRun}');
  log('Publish PR: ${options.publishPr}');

  final context = HarnessContext(
    issueNumber: effectiveIssueNumber,
    issueTitle: options.issueTitle,
    issueBody: options.issueBody,
    packageName: options.packageName,
    packagePath: options.packagePath,
    testFilePath: options.testFilePath,
    isDryRun: options.isDryRun,
    publishPr: options.publishPr,
    maxRetries: options.maxRetries,
    model: options.model,
    repo: options.repo,
  );

  final HarnessPhase finalPhase = await runHarness(context);

  if (finalPhase == HarnessPhase.complete) {
    log('=================== PIPELINE SUCCESS ===================');
    log('🎉 Autonomous resolution completed successfully for issue #$effectiveIssueNumber!');
    if (options.publishPr && context.publishedPrUrl != null) {
      log('🚀 Published Draft PR: ${context.publishedPrUrl}');
    }
    return 0;
  } else {
    errLog('=================== PIPELINE FAILURE ===================');
    errLog('🛑 Pipeline failed in phase $finalPhase: ${context.failureReason ?? "Unknown error"}');
    return 1;
  }
}

Future<void> main(List<String> args) async {
  final int exitStatus = await runPipeline(args);
  exitCode = exitStatus;
}
