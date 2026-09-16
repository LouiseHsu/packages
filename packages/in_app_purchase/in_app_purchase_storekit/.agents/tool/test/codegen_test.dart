// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../codegen.dart';

/// Badly formatted Objective-C that clang-format will rewrite.
///
/// Mirrors the shape of raw Pigeon output: over-long lines and a pointer star
/// on the wrong side.
const String _unformattedObjc = '''
#import "messages.g.h"

@implementation FIAThing
+ (instancetype)makeWithAlpha:(NSString *)alpha beta:(NSString *)beta gamma:(NSString *)gamma delta:(NSString *)delta {
  FIAThing* result = [[FIAThing alloc] init];
  return result;
}
@end
''';

void main() {
  group('DefaultCodeGenerator native formatting', () {
    late Directory repo;

    void git(List<String> args, {String? cwd}) {
      final ProcessResult result = Process.runSync('git', args, workingDirectory: cwd ?? repo.path);
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')} failed: ${result.stderr}');
      }
    }

    setUp(() {
      repo = Directory.systemTemp.createTempSync('codegen_fmt_test_');
      git(<String>['init', '-q']);
      git(<String>['config', 'user.email', 'test@example.com']);
      git(<String>['config', 'user.name', 'Test']);
      // clang-format resolves --style=file from a config in an ancestor dir.
      File('${repo.path}/.clang-format').writeAsStringSync(
        'BasedOnStyle: Google\n---\nLanguage: Cpp\nDerivePointerAlignment: false\n'
        'PointerAlignment: Left\nColumnLimit: 100\n',
      );
      File('${repo.path}/README.md').writeAsStringSync('seed\n');
      git(<String>['add', '.']);
      git(<String>['commit', '-q', '-m', 'seed']);
    });

    tearDown(() => repo.deleteSync(recursive: true));

    test('formats an Objective-C file the run modified', () async {
      if (Process.runSync('which', <String>['clang-format']).exitCode != 0) {
        markTestSkipped('clang-format not installed');
        return;
      }
      final file = File('${repo.path}/messages.g.m')..writeAsStringSync(_unformattedObjc);

      final String summary = await const DefaultCodeGenerator().formatNativeSources(repo.path);

      final String formatted = file.readAsStringSync();
      expect(summary, contains('Formatted 1 C/ObjC file(s).'));
      // Pointer star moves left, and the long signature gets wrapped.
      expect(formatted, contains('FIAThing *result'));
      expect(formatted, isNot(contains('alpha:(NSString *)alpha beta:')));
    });

    test('leaves files the run did not touch alone', () async {
      if (Process.runSync('which', <String>['clang-format']).exitCode != 0) {
        markTestSkipped('clang-format not installed');
        return;
      }
      // Committed, so it is not in `git diff HEAD` or the untracked list.
      final committed = File('${repo.path}/untouched.m')..writeAsStringSync(_unformattedObjc);
      git(<String>['add', '.']);
      git(<String>['commit', '-q', '-m', 'add untouched']);

      await const DefaultCodeGenerator().formatNativeSources(repo.path);

      // Reformatting the whole package would rewrite this and create churn
      // unrelated to the fix -- especially across formatter versions.
      expect(committed.readAsStringSync(), _unformattedObjc);
    });

    test('reports when there is nothing native to format', () async {
      File('${repo.path}/notes.txt').writeAsStringSync('not native\n');

      final String summary = await const DefaultCodeGenerator().formatNativeSources(repo.path);

      expect(summary, 'No native sources needed formatting.');
    });

    test('ignores CocoaPods vendored sources', () async {
      Directory('${repo.path}/example/macos/Pods').createSync(recursive: true);
      File('${repo.path}/example/macos/Pods/vendored.m').writeAsStringSync(_unformattedObjc);

      final String summary = await const DefaultCodeGenerator().formatNativeSources(repo.path);

      expect(summary, 'No native sources needed formatting.');
      expect(
        File('${repo.path}/example/macos/Pods/vendored.m').readAsStringSync(),
        _unformattedObjc,
      );
    });
  });
}
