// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

/// Outcome of a native (non-Dart) static analysis pass.
class NativeAnalysisResult {
  /// Creates a result for a check that ran to completion.
  const NativeAnalysisResult({required this.exitCode, required this.stdout, required this.stderr})
    : skippedReason = null;

  /// Creates a result for a check that could not run.
  ///
  /// Skipping is deliberately not a failure. The toolchain this analyzer needs
  /// only exists on macOS, so a Linux CI runner must be able to complete a run
  /// without it rather than reporting a fix as broken.
  const NativeAnalysisResult.skipped(String reason)
    : exitCode = 0,
      stdout = '',
      stderr = '',
      skippedReason = reason;

  /// The exit code of the analysis process.
  final int exitCode;

  /// Standard output produced during analysis.
  final String stdout;

  /// Standard error produced during analysis.
  final String stderr;

  /// Why the check did not run, or null if it did.
  final String? skippedReason;

  /// Whether the sources type-checked cleanly.
  bool get success => exitCode == 0;

  /// Whether the check was unable to run at all.
  bool get skipped => skippedReason != null;

  /// Formatted diagnostics, capped so a wall of errors cannot swamp a prompt.
  String get failureSummary {
    if (success) {
      return 'Native analysis passed.';
    }
    final String combined = '$stderr\n$stdout'.trim();
    if (combined.isEmpty) {
      return 'Native analysis exited with code $exitCode without output.';
    }
    final List<String> lines = combined.split('\n');
    if (lines.length > 50) {
      return '${lines.take(50).join('\n')}\n... [truncated]';
    }
    return combined;
  }
}

/// Interface for type-checking a package's native (non-Dart) sources.
///
/// The Dart test suite mocks the platform channel, so it proves the Dart half
/// of a change and nothing about the native half. Without a check of this kind
/// the agent can write Swift that references APIs which do not exist and still
/// clear every other gate.
abstract class NativeAnalyzer {
  /// Type-checks the native sources belonging to the package at [packagePath].
  Future<NativeAnalysisResult> analyze({required String packagePath});
}

/// A [NativeAnalyzer] that never runs, for callers with no native sources.
class NoOpNativeAnalyzer implements NativeAnalyzer {
  /// Creates a [NoOpNativeAnalyzer].
  const NoOpNativeAnalyzer();

  @override
  Future<NativeAnalysisResult> analyze({required String packagePath}) async =>
      const NativeAnalysisResult.skipped('Native analysis disabled.');
}

/// Type-checks a Flutter darwin plugin's Swift sources with `swiftc -typecheck`.
///
/// Uses only tools a Flutter darwin developer already has: the Xcode SDK and
/// the `FlutterMacOS.xcframework` in the Flutter SDK's artifact cache. It
/// deliberately avoids CocoaPods, an Xcode project, and Swift Package Manager
/// resolution, none of which are needed merely to resolve types.
///
/// Sources are globbed rather than listed, so a Swift file the agent adds is
/// checked automatically instead of silently escaping the gate.
class SwiftTypecheckAnalyzer implements NativeAnalyzer {
  /// Creates a [SwiftTypecheckAnalyzer] targeting [target].
  const SwiftTypecheckAnalyzer({this.target = defaultTarget});

  /// The deployment target used for type-checking.
  ///
  /// This must be the package's *minimum* supported version, not the host's.
  /// Availability errors (`@available(macOS 14, *)` used unguarded) only
  /// surface when the compiler is told how old a system must be supported.
  static const String defaultTarget = 'arm64-apple-macos10.15';

  /// The `-target` triple passed to `swiftc`.
  final String target;

  @override
  Future<NativeAnalysisResult> analyze({required String packagePath}) async {
    if (!Platform.isMacOS) {
      return const NativeAnalysisResult.skipped('Swift type-checking requires macOS.');
    }

    final darwinDir = Directory('$packagePath/darwin');
    if (!darwinDir.existsSync()) {
      return const NativeAnalysisResult.skipped('No darwin/ directory found.');
    }

    final List<String> sources = _swiftSources(darwinDir);
    if (sources.isEmpty) {
      return const NativeAnalysisResult.skipped('No Swift sources found.');
    }

    final String? sdkPath = await _macosSdkPath();
    if (sdkPath == null) {
      return const NativeAnalysisResult.skipped('Could not locate the macOS SDK via xcrun.');
    }

    final String? frameworkDir = _flutterFrameworkDir();
    if (frameworkDir == null) {
      return const NativeAnalysisResult.skipped(
        'Could not locate FlutterMacOS.xcframework in the Flutter SDK cache.',
      );
    }

    final List<String> headers = _objcHeaders(darwinDir);
    Directory? scratch;
    try {
      final args = <String>['-typecheck', '-sdk', sdkPath, '-F', frameworkDir, '-target', target];

      if (headers.isNotEmpty) {
        // Swift reaches ObjC types through a bridging header. The checked-in
        // umbrella header does not cover the whole module, so synthesize one
        // that imports every public header instead.
        scratch = Directory.systemTemp.createTempSync('harness_swiftcheck');
        final bridgingHeader = File('${scratch.path}/bridging_header.h');
        bridgingHeader.writeAsStringSync(
          headers.map((String path) => '#import "${path.split('/').last}"').join('\n'),
        );
        args.addAll(<String>['-import-objc-header', bridgingHeader.path]);
        for (final String dir in _parentDirs(headers)) {
          args.addAll(<String>['-Xcc', '-I', '-Xcc', dir]);
        }
      }

      args.addAll(sources);

      final ProcessResult result = await Process.run('swiftc', args, workingDirectory: packagePath);
      return NativeAnalysisResult(
        exitCode: result.exitCode,
        stdout: result.stdout as String? ?? '',
        stderr: result.stderr as String? ?? '',
      );
    } on ProcessException catch (e) {
      return NativeAnalysisResult.skipped('Could not run swiftc: ${e.message}');
    } finally {
      if (scratch != null && scratch.existsSync()) {
        scratch.deleteSync(recursive: true);
      }
    }
  }

  /// Every Swift source under [darwinDir] except SwiftPM manifests.
  static List<String> _swiftSources(Directory darwinDir) =>
      darwinDir
          .listSync(recursive: true)
          .whereType<File>()
          .map((File file) => file.path)
          .where(
            (String path) => path.endsWith('.swift') && path.split('/').last != 'Package.swift',
          )
          .toList()
        ..sort();

  /// Every ObjC public header under [darwinDir].
  static List<String> _objcHeaders(Directory darwinDir) =>
      darwinDir
          .listSync(recursive: true)
          .whereType<File>()
          .map((File file) => file.path)
          .where((String path) => path.endsWith('.h'))
          .toList()
        ..sort();

  /// The unique directories containing [paths], for include search paths.
  static List<String> _parentDirs(List<String> paths) =>
      paths.map((String path) => File(path).parent.path).toSet().toList()..sort();

  /// The macOS SDK path reported by `xcrun`, or null if unavailable.
  static Future<String?> _macosSdkPath() async {
    try {
      final ProcessResult result = await Process.run('xcrun', <String>[
        '--show-sdk-path',
        '--sdk',
        'macosx',
      ]);
      if (result.exitCode != 0) {
        return null;
      }
      final String path = (result.stdout as String? ?? '').trim();
      return path.isEmpty ? null : path;
    } on ProcessException {
      return null;
    }
  }

  /// The directory holding `FlutterMacOS.framework`, or null if not found.
  static String? _flutterFrameworkDir() {
    final String? root = _flutterRoot();
    if (root == null) {
      return null;
    }
    final engineDir = Directory('$root/bin/cache/artifacts/engine');
    if (!engineDir.existsSync()) {
      return null;
    }

    // Any build mode resolves the same types; prefer debug for stability.
    final List<Directory> candidates = engineDir.listSync().whereType<Directory>().toList()
      ..sort((Directory a, Directory b) => a.path.length.compareTo(b.path.length));

    for (final candidate in candidates) {
      final xcframework = Directory('${candidate.path}/FlutterMacOS.xcframework');
      if (!xcframework.existsSync()) {
        continue;
      }
      for (final Directory slice in xcframework.listSync().whereType<Directory>()) {
        if (slice.path.split('/').last.startsWith('macos-')) {
          return slice.path;
        }
      }
    }
    return null;
  }

  /// The Flutter SDK root, from the environment or the `flutter` on PATH.
  static String? _flutterRoot() {
    final String? fromEnv = Platform.environment['FLUTTER_ROOT'];
    if (fromEnv != null && fromEnv.isNotEmpty) {
      return fromEnv;
    }
    try {
      final ProcessResult which = Process.runSync('which', <String>['flutter']);
      if (which.exitCode != 0) {
        return null;
      }
      final String path = (which.stdout as String? ?? '').trim();
      if (path.isEmpty) {
        return null;
      }
      // Resolves <root>/bin/flutter back to <root>.
      return File(path).resolveSymbolicLinksSync().split('/bin/flutter').first;
    } on ProcessException {
      return null;
    } on FileSystemException {
      return null;
    }
  }
}
