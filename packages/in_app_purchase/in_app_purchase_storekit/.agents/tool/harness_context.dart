// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'gemini_agent.dart';

/// The lifecycle phases of the packages SWE-bench harness.
enum HarnessPhase {
  /// Initial setup: reads issue info, checks clean git working tree.
  init,

  /// Phase 1 (FAIL_TO_PASS): Writes unit test on clean main and asserts failure.
  redTest,

  /// Phase 2 (PASS_TO_PASS): Implements the fix and verifies test passes.
  implementation,

  /// Phase 3 (Hygiene): Formats code, runs static analysis, and checks guardrails.
  validation,

  /// Terminal success state: ready to open Draft PR.
  complete,

  /// Terminal failure state: aborted due to test failure or guardrail violation.
  failed,
}

/// Immutable inputs for a harness run.
///
/// Everything here is decided before the run starts and must not change while
/// it executes. Values that are discovered or updated during a run belong in
/// [RunState] instead.
class HarnessConfig {
  /// Creates a [HarnessConfig].
  HarnessConfig({
    required this.issueNumber,
    required this.isDryRun,
    this.packageName = 'in_app_purchase_storekit',
    this.packagePath,
    this.repo,
    this.skipAgent = false,
    this.publishPr = false,
    this.maxRetries = 5,
    String? model,
    List<String>? fallbackModels,
  }) : model = resolveDefaultModel(
         cliModel: model,
         packageDir: resolvePackageDirectory(packageName, packagePath),
       ),
       fallbackModels =
           fallbackModels ??
           resolveFallbackModels(packageDir: resolvePackageDirectory(packageName, packagePath));

  /// Target GitHub issue number.
  final int issueNumber;

  /// Target package name.
  final String packageName;

  /// Gemini model identifier.
  final String model;

  /// List of fallback/fallover models to try in sequence.
  final List<String> fallbackModels;

  /// Optional explicit directory path of the target package.
  final String? packagePath;

  /// Target repository (e.g. LouiseHsu/packages).
  final String? repo;

  /// Whether dry run mode is enabled.
  final bool isDryRun;

  /// Whether to skip automated agent generation (e.g. when tests/fixes are manually provided).
  final bool skipAgent;

  /// Whether to publish changes as a Draft PR upon successful completion.
  final bool publishPr;

  /// Maximum number of implementation fix attempts before giving up.
  final int maxRetries;

  /// Resolves the directory path of the target package.
  String resolvePackagePath() => resolvePackageDirectory(packageName, packagePath);

  /// Resolves the directory path of a target package.
  static String resolvePackageDirectory(String packageName, [String? explicitPath]) {
    if (explicitPath != null && Directory(explicitPath).existsSync()) {
      return explicitPath;
    }
    final Directory currentDir = Directory.current;
    if (currentDir.path.endsWith(packageName)) {
      return currentDir.path;
    }

    final direct = Directory('packages/$packageName');
    if (direct.existsSync()) {
      return direct.path;
    }

    final packagesDir = Directory('packages');
    if (packagesDir.existsSync()) {
      for (final FileSystemEntity group in packagesDir.listSync()) {
        if (group is Directory) {
          final candidate = Directory('${group.path}/$packageName');
          if (candidate.existsSync()) {
            return candidate.path;
          }
        }
      }
    }
    return currentDir.path;
  }
}

/// Mutable state produced while a harness run executes.
///
/// This is the single place to look to answer "what can change during a run?".
class RunState {
  /// Creates a [RunState] seeded with the issue text known at startup.
  RunState({this.issueTitle = '', this.issueBody = ''}) : currentPhase = HarnessPhase.init;

  /// Current execution phase.
  HarnessPhase currentPhase;

  /// Title of the GitHub issue, resolved during init if not supplied upfront.
  String issueTitle;

  /// Body of the GitHub issue, resolved during init if not supplied upfront.
  String issueBody;

  /// Relative or absolute path to the target test file.
  String? testFilePath;

  /// The reproduction unit test code generated or used in Phase 1 (FAIL_TO_PASS).
  String? redTestCode;

  /// Declarations-only stubs the agent supplied alongside the red test.
  ///
  /// Recorded for artifacts. This is the API shape the test demands, with no
  /// behaviour behind it, used to prove the test can actually run.
  String? skeletonCode;

  /// Original contents of every file the skeleton touched, keyed by path.
  ///
  /// The skeleton is a probe, not part of the fix, so it is undone once the
  /// red test has been judged. Implementation always starts from clean code.
  final Map<String, String> skeletonOriginals = <String, String>{};

  /// Reason recorded upon harness failure.
  String? failureReason;

  /// Summary of the most recent test failure output.
  ///
  /// This is the feedback handed to the agent for its next attempt, so it
  /// includes a digest of earlier attempts as well as the latest failure.
  String? lastTestFailureSummary;

  /// The failure output captured when the red test was verified to fail.
  ///
  /// Held separately from [lastTestFailureSummary], which is overwritten
  /// repeatedly during implementation. This is the evidence that the bug was
  /// real, so it survives to be reported in the Draft PR.
  String? verifiedRedFailureSummary;

  /// Why native type-checking did not run, or null if it ran.
  ///
  /// Surfaced in the Draft PR. A run on a machine without the Xcode toolchain
  /// still produces a fix, but its native half is unverified, and a reviewer
  /// has no way to tell that apart from a clean check unless it is stated.
  String? nativeAnalysisSkippedReason;

  /// Failure summaries from previous attempts within the current phase.
  final List<String> attemptFailures = <String>[];

  /// The original unmodified content of the target test file before execution.
  String? initialTestFileContent;

  /// The URL of the published Draft PR, if created.
  String? publishedPrUrl;

  /// Reason the Draft PR failed to publish, if publishing was requested and failed.
  ///
  /// The core SWE-bench verification (red test, fix, regressions, analysis) can
  /// succeed while publishing fails for environmental reasons (auth, push
  /// rejection). Recording it separately lets callers distinguish "verified but
  /// unpublished" from "fully successful" instead of silently reporting success.
  String? prPublishFailureReason;

  /// List of modified files detected and verified during Phase 3 validation.
  final List<String> validatedModifiedFiles = <String>[];

  /// Whether moving from [currentPhase] to [next] is a legal transition.
  bool canTransitionTo(HarnessPhase next) {
    if (next == HarnessPhase.failed) {
      return true;
    }
    switch (currentPhase) {
      case HarnessPhase.init:
        return next == HarnessPhase.redTest;
      case HarnessPhase.redTest:
        return next == HarnessPhase.implementation;
      case HarnessPhase.implementation:
        return next == HarnessPhase.validation;
      case HarnessPhase.validation:
        return next == HarnessPhase.complete;
      case HarnessPhase.complete:
      case HarnessPhase.failed:
        return false;
    }
  }

  /// Records [summary] as the failure of the attempt that just finished.
  ///
  /// Also rebuilds [lastTestFailureSummary] to include a digest of earlier
  /// attempts. Without this the agent only ever sees the previous failure, so
  /// it cannot tell that it has already tried and failed the same way twice.
  void recordAttemptFailure(String summary) {
    attemptFailures.add(summary);

    if (attemptFailures.length == 1) {
      lastTestFailureSummary = summary;
      return;
    }

    final buffer = StringBuffer()
      ..writeln('Attempt ${attemptFailures.length} failed:')
      ..writeln(summary)
      ..writeln()
      ..writeln(
        'You have already tried and failed the following approaches. '
        'Do not repeat them:',
      );
    for (var i = 0; i < attemptFailures.length - 1; i++) {
      final String previous = attemptFailures[i];
      final condensed = previous.length > 300 ? '${previous.substring(0, 300)}...' : previous;
      buffer.writeln('- Attempt ${i + 1}: ${condensed.replaceAll('\n', ' ')}');
    }
    lastTestFailureSummary = buffer.toString();
  }

  /// Whether the last two attempts failed in effectively the same way.
  ///
  /// Retries only help when each attempt explores something new. Once the same
  /// failure repeats, further attempts are near-certain to be more samples of
  /// the same misconception, and each one costs a full test suite run.
  bool get isRepeatingFailure {
    if (attemptFailures.length < 2) {
      return false;
    }
    return _normalize(attemptFailures[attemptFailures.length - 1]) ==
        _normalize(attemptFailures[attemptFailures.length - 2]);
  }

  /// Clears attempt history when moving between phases.
  ///
  /// Red test failures are not useful feedback for implementation attempts.
  void resetAttemptHistory() {
    attemptFailures.clear();
    lastTestFailureSummary = null;
  }

  /// Strips incidental variation so two reports of the same failure compare
  /// equal. Numbers cover line numbers, durations, and attempt counters.
  static String _normalize(String summary) =>
      summary.toLowerCase().replaceAll(RegExp(r'\d+'), '#').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Collects log output and debug artifacts for a run, and persists them.
///
/// Kept separate from run state so tests can redirect output to a temp
/// directory, and so persistence has one owner rather than being scattered.
class RunRecorder {
  /// Creates a [RunRecorder], optionally overriding where logs are written.
  RunRecorder({this.logParentDirectory, this.echoToStdout = true});

  /// Optional override for the parent directory where failure logs are stored.
  String? logParentDirectory;

  /// Whether log messages are also written to stdout as they arrive.
  final bool echoToStdout;

  /// Log messages generated during execution.
  final List<String> logs = <String>[];

  /// Debug artifacts (prompts, raw responses, failure traces) buffered in-memory.
  final Map<String, String> artifacts = <String, String>{};

  /// Appends a message to the log, optionally tagged with the current [phase].
  void log(String message, {HarnessPhase? phase}) {
    logs.add(message);
    if (echoToStdout) {
      stdout.writeln(phase != null ? '[$phase] $message' : message);
    }
  }

  /// Buffers a debug artifact in-memory for failure diagnosis.
  void recordArtifact(String fileName, String content) {
    artifacts[fileName] = content;
  }

  /// Writes logs, [failureReason], and all buffered artifacts to a timestamped
  /// directory. Returns the directory created, or null if writing failed.
  String? saveToDisk({
    required int issueNumber,
    required String defaultParentDirectory,
    String? failureReason,
  }) {
    try {
      final String parentDir = logParentDirectory ?? defaultParentDirectory;
      final String timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final logDirPath = '$parentDir/run_issue_${issueNumber}_$timestamp';
      Directory(logDirPath).createSync(recursive: true);

      File('$logDirPath/harness.log').writeAsStringSync('${logs.join('\n')}\n');
      File(
        '$logDirPath/failure_reason.txt',
      ).writeAsStringSync('${failureReason ?? "Unknown failure"}\n');
      artifacts.forEach((String name, String content) {
        File('$logDirPath/$name').writeAsStringSync(content);
      });

      return logDirPath;
    } catch (e) {
      log('⚠️ Failed to save failure logs to disk: $e');
      return null;
    }
  }
}

/// Composition root tying together the immutable [config], mutable [state], and
/// output [recorder] for a single harness run.
///
/// New code should prefer reaching through `context.config` / `context.state` /
/// `context.recorder`, which makes ownership explicit. The forwarding members
/// below exist so the large number of existing call sites keep compiling and
/// can migrate incrementally; note that config forwarders are getter-only, so
/// configuration can no longer be mutated mid-run.
class HarnessContext {
  /// Creates a [HarnessContext] and its underlying config, state, and recorder.
  HarnessContext({
    required int issueNumber,
    required bool isDryRun,
    String packageName = 'in_app_purchase_storekit',
    String? packagePath,
    String? testFilePath,
    String? redTestCode,
    String issueTitle = '',
    String issueBody = '',
    String? repo,
    bool skipAgent = false,
    bool publishPr = false,
    int maxRetries = 5,
    String? model,
    List<String>? fallbackModels,
    RunRecorder? recorder,
  }) : config = HarnessConfig(
         issueNumber: issueNumber,
         isDryRun: isDryRun,
         packageName: packageName,
         packagePath: packagePath,
         repo: repo,
         skipAgent: skipAgent,
         publishPr: publishPr,
         maxRetries: maxRetries,
         model: model,
         fallbackModels: fallbackModels,
       ),
       state = RunState(issueTitle: issueTitle, issueBody: issueBody),
       recorder = recorder ?? RunRecorder() {
    state.testFilePath = testFilePath;
    state.redTestCode = redTestCode;
  }

  /// Immutable inputs for this run.
  final HarnessConfig config;

  /// Mutable state accumulated during this run.
  final RunState state;

  /// Log and artifact sink for this run.
  final RunRecorder recorder;

  // --- Config forwarders (read-only) ---

  /// Target GitHub issue number.
  int get issueNumber => config.issueNumber;

  /// Target package name.
  String get packageName => config.packageName;

  /// Gemini model identifier.
  String get model => config.model;

  /// List of fallback/fallover models to try in sequence.
  List<String> get fallbackModels => config.fallbackModels;

  /// Optional explicit directory path of the target package.
  String? get packagePath => config.packagePath;

  /// Target repository (e.g. LouiseHsu/packages).
  String? get repo => config.repo;

  /// Whether dry run mode is enabled.
  bool get isDryRun => config.isDryRun;

  /// Whether automated agent generation is skipped.
  bool get skipAgent => config.skipAgent;

  /// Whether a Draft PR is published on success.
  bool get publishPr => config.publishPr;

  /// Maximum number of implementation fix attempts.
  int get maxRetries => config.maxRetries;

  /// Resolves the directory path of the target package.
  String resolvePackagePath() => config.resolvePackagePath();

  /// Resolves the directory path of a target package.
  static String resolvePackageDirectory(String packageName, [String? explicitPath]) =>
      HarnessConfig.resolvePackageDirectory(packageName, explicitPath);

  // --- State forwarders ---

  /// Current execution phase.
  HarnessPhase get currentPhase => state.currentPhase;
  set currentPhase(HarnessPhase value) => state.currentPhase = value;

  /// Title of the GitHub issue.
  String get issueTitle => state.issueTitle;
  set issueTitle(String value) => state.issueTitle = value;

  /// Body of the GitHub issue.
  String get issueBody => state.issueBody;
  set issueBody(String value) => state.issueBody = value;

  /// Relative or absolute path to the target test file.
  String? get testFilePath => state.testFilePath;
  set testFilePath(String? value) => state.testFilePath = value;

  /// The reproduction unit test code generated or used in Phase 1.
  String? get redTestCode => state.redTestCode;
  set redTestCode(String? value) => state.redTestCode = value;

  /// Declarations-only stubs supplied alongside the red test.
  String? get skeletonCode => state.skeletonCode;
  set skeletonCode(String? value) => state.skeletonCode = value;

  /// Original contents of every file the skeleton touched, keyed by path.
  Map<String, String> get skeletonOriginals => state.skeletonOriginals;

  /// Reason recorded upon harness failure.
  String? get failureReason => state.failureReason;
  set failureReason(String? value) => state.failureReason = value;

  /// Summary of the most recent test failure output.
  String? get lastTestFailureSummary => state.lastTestFailureSummary;
  set lastTestFailureSummary(String? value) => state.lastTestFailureSummary = value;

  /// The original unmodified content of the target test file.
  String? get initialTestFileContent => state.initialTestFileContent;
  set initialTestFileContent(String? value) => state.initialTestFileContent = value;

  /// The URL of the published Draft PR, if created.
  String? get publishedPrUrl => state.publishedPrUrl;
  set publishedPrUrl(String? value) => state.publishedPrUrl = value;

  /// Reason the Draft PR failed to publish, if requested and failed.
  String? get prPublishFailureReason => state.prPublishFailureReason;
  set prPublishFailureReason(String? value) => state.prPublishFailureReason = value;

  /// List of modified files detected and verified during Phase 3 validation.
  List<String> get validatedModifiedFiles => state.validatedModifiedFiles;

  // --- Recorder forwarders ---

  /// Log messages generated during execution.
  List<String> get logs => recorder.logs;

  /// Debug artifacts buffered in-memory.
  Map<String, String> get debugArtifacts => recorder.artifacts;

  /// Optional override for the parent directory where failure logs are stored.
  String? get customLogParentDirectory => recorder.logParentDirectory;
  set customLogParentDirectory(String? value) => recorder.logParentDirectory = value;

  /// Appends a message to the internal log.
  void log(String message) => recorder.log(message, phase: state.currentPhase);

  /// Buffers a debug artifact in-memory for failure diagnosis.
  void recordArtifact(String fileName, String content) =>
      recorder.recordArtifact(fileName, content);

  /// Saves full execution logs, failure reason, and all buffered artifacts to
  /// disk under a timestamped folder. Returns the directory path created.
  String? saveFailureLogsToDisk() => recorder.saveToDisk(
    issueNumber: config.issueNumber,
    defaultParentDirectory: '${config.resolvePackagePath()}/.agents/logs',
    failureReason: state.failureReason,
  );

  /// Transitions to the next phase, enforcing valid state machine DAG transitions.
  ///
  /// Coordinates [state] and [recorder]: validation is owned by [RunState], the
  /// resulting narration by [RunRecorder].
  bool transitionTo(HarnessPhase nextPhase, {String? reason}) {
    if (state.canTransitionTo(nextPhase)) {
      final suffix = reason != null ? ' ($reason)' : '';
      log('State transition: ${state.currentPhase} -> $nextPhase$suffix');
      state.currentPhase = nextPhase;
      return true;
    }
    final errorMsg = 'Illegal state transition from ${state.currentPhase} to $nextPhase';
    log('❌ ERROR: $errorMsg');
    state.failureReason = errorMsg;
    state.currentPhase = HarnessPhase.failed;
    return false;
  }
}
