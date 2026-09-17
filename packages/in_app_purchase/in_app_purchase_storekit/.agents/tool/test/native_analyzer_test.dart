// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../native_analyzer.dart';

void main() {
  group('SwiftTypecheckAnalyzer', () {
    test('reports skipped rather than failed when it cannot run', () async {
      // A package with no darwin/ directory is not a broken package. Skipping
      // has to stay distinct from failing, or a run on a host without the
      // Apple toolchain would report every fix as broken.
      final Directory temp = Directory.systemTemp.createTempSync('no_darwin');
      addTearDown(() => temp.deleteSync(recursive: true));

      final NativeAnalysisResult result = await const SwiftTypecheckAnalyzer().analyze(
        packagePath: temp.path,
      );

      expect(result.exitCode, 0);
      expect(result.skippedReason, isNotNull);
    });

    test('gives the same verdict for a relative package path as an absolute one', () async {
      // `swiftc` is launched with `workingDirectory` set to the package path
      // while its include and source arguments are derived from that same
      // path. A relative path therefore resolved twice, so the bridging
      // header could not find the package's own ObjC headers and every
      // implementation attempt failed with what looked like a real compile
      // error.
      //
      // This only reproduces from a working directory the package path is
      // relative to -- the repository root, which is where CI invokes
      // run.dart from. Running inside the package, as a developer does,
      // happened to resolve correctly and hid the bug entirely.
      final ProcessResult topLevel = Process.runSync('git', <String>[
        'rev-parse',
        '--show-toplevel',
      ]);
      final String repoRoot = (topLevel.stdout as String).trim();
      final String packageAbsolute = Directory.current.absolute.path;
      final String packageRelative = packageAbsolute
          .replaceFirst(repoRoot, '')
          .replaceFirst(RegExp('^/'), '');

      // Guard against the derivation silently producing something useless.
      expect(packageRelative, isNotEmpty);
      expect(packageRelative, isNot(startsWith('/')));

      const analyzer = SwiftTypecheckAnalyzer();
      final Directory original = Directory.current;
      late NativeAnalysisResult fromRelative;
      late NativeAnalysisResult fromAbsolute;
      try {
        Directory.current = repoRoot;
        fromRelative = await analyzer.analyze(packagePath: packageRelative);
        fromAbsolute = await analyzer.analyze(packagePath: packageAbsolute);
      } finally {
        Directory.current = original;
      }

      // Deliberately compares the two rather than asserting success, so the
      // test keeps reporting on path handling even while the package's Swift
      // is mid-edit and genuinely failing.
      expect(fromRelative.exitCode, fromAbsolute.exitCode);
      expect(fromRelative.skippedReason, fromAbsolute.skippedReason);
    }, skip: Platform.isMacOS ? null : 'Swift type-checking requires macOS.');
  });
}
