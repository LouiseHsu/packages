// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

/// Looks up authoritative Apple SDK symbol names, signatures and doc comments
/// so the agent does not have to invent them.
///
/// On the issue #7 run the agent emitted
/// `Product.SubscriptionInfo.RenewalState.inPadd`, which is not a real case --
/// the real ones are `subscribed`, `expired`, `inBillingRetryPeriod`,
/// `inGracePeriod` and `revoked`. Nothing in the repository lists them, so no
/// amount of package context could have prevented that. They come from the SDK.
///
/// The data is produced by `swift-symbolgraph-extract`, which ships with Xcode
/// and reads the `.swiftdoc` sidecar next to the module's `.swiftinterface`.
/// Nothing is scraped and nothing is vendored: the symbol graph is generated on
/// the machine running the harness, from that machine's own licensed SDK, into
/// a temporary directory.
///
/// Everything here fails soft. A missing SDK, a missing toolchain or a
/// malformed graph yields an empty context block, never an exception -- the
/// agent simply carries on without the hint, as it did before this existed.
class SymbolOracle {
  /// Creates an oracle for [moduleName].
  SymbolOracle({
    this.moduleName = 'StoreKit',
    this.target = 'arm64-apple-macos15.0',
    this.maxSymbols = 60,
    this.extractTimeout = const Duration(minutes: 3),
  });

  /// The Swift module to extract, e.g. `StoreKit`.
  final String moduleName;

  /// The target triple passed to `swift-symbolgraph-extract`.
  ///
  /// Deliberately a recent macOS version. Symbols gated behind newer
  /// availability annotations are omitted when the target is too old, and the
  /// subscription-status APIs are exactly that kind of symbol.
  final String target;

  /// Upper bound on symbols rendered into the prompt, to bound its size.
  final int maxSymbols;

  /// How long to wait for extraction before giving up.
  final Duration extractTimeout;

  /// Caches the parsed graph for the process.
  ///
  /// `generateFix` runs once per implementation attempt, up to five times per
  /// run. Extraction takes roughly 45 seconds, so without this the harness
  /// would spend nearly four minutes re-deriving a file that cannot change.
  List<Map<String, dynamic>>? _symbols;
  bool _attempted = false;

  /// Returns a prompt block describing SDK symbols mentioned in [issueText],
  /// or an empty string when nothing is available or nothing matches.
  Future<String> lookupForIssue(String issueText) async {
    final List<Map<String, dynamic>>? symbols = await _load();
    if (symbols == null || symbols.isEmpty) {
      return '';
    }
    final Set<String> identifiers = extractIdentifiers(issueText);
    if (identifiers.isEmpty) {
      return '';
    }
    final List<Map<String, dynamic>> selected = selectSymbols(
      symbols,
      identifiers,
      maxSymbols: maxSymbols,
    );
    return formatSymbolBlock(selected, moduleName: moduleName);
  }

  Future<List<Map<String, dynamic>>?> _load() async {
    if (_attempted) {
      return _symbols;
    }
    _attempted = true;

    if (!Platform.isMacOS) {
      return null;
    }

    try {
      final ProcessResult sdkResult = await Process.run('xcrun', <String>[
        '--show-sdk-path',
        '--sdk',
        'macosx',
      ]);
      if (sdkResult.exitCode != 0) {
        return null;
      }
      final String sdkPath = (sdkResult.stdout as String).trim();
      if (sdkPath.isEmpty) {
        return null;
      }

      // A stable directory keyed by module and target, so a rerun on the same
      // machine skips extraction entirely.
      final outDir = Directory(
        '${Directory.systemTemp.path}/harness_symbolgraph_${moduleName}_$target',
      );
      final graphFile = File('${outDir.path}/$moduleName.symbols.json');

      if (!graphFile.existsSync()) {
        outDir.createSync(recursive: true);
        final ProcessResult extract = await Process.run('xcrun', <String>[
          'swift-symbolgraph-extract',
          '-module-name',
          moduleName,
          '-target',
          target,
          '-sdk',
          sdkPath,
          '-output-dir',
          outDir.path,
        ]).timeout(extractTimeout, onTimeout: () => ProcessResult(0, 1, '', 'timed out'));
        if (extract.exitCode != 0 || !graphFile.existsSync()) {
          return null;
        }

        // Extraction also emits cross-module graphs such as
        // `_StoreKit_SwiftUI@StoreKit.symbols.json`, which alone is about
        // 79 MB. Nothing here reads them, and the cache is long-lived, so drop
        // them rather than leaving ~80 MB per module on the runner's disk.
        for (final FileSystemEntity entity in outDir.listSync()) {
          if (entity is File && entity.path != graphFile.path) {
            try {
              entity.deleteSync();
            } catch (_) {
              // Best effort only; a stale sibling file is harmless.
            }
          }
        }
      }

      // Read only the module's own graph. Extraction also emits cross-module
      // files such as `_StoreKit_SwiftUI@StoreKit.symbols.json`, which is about
      // 79 MB and holds nothing relevant here.
      final dynamic decoded = jsonDecode(graphFile.readAsStringSync());
      if (decoded is! Map) {
        return null;
      }
      final dynamic raw = decoded['symbols'];
      if (raw is! List) {
        return null;
      }
      _symbols = raw.whereType<Map<String, dynamic>>().toList();
      return _symbols;
    } catch (_) {
      // Any failure here is non-fatal: the agent just loses a hint.
      return null;
    }
  }
}

/// Extracts candidate Swift identifiers from free-form issue text.
///
/// Matches camelCase (`autoRenewPreference`) and PascalCase (`RenewalInfo`)
/// words, which is how Apple symbols appear when a reporter writes about them.
/// Single lowercase words are ignored because they match far too much prose.
Set<String> extractIdentifiers(String text) {
  final pattern = RegExp(r'\b[A-Za-z][A-Za-z0-9]*\b');
  final result = <String>{};
  for (final RegExpMatch match in pattern.allMatches(text)) {
    final String word = match.group(0)!;
    if (word.length < 4 || word.length > 60) {
      continue;
    }
    final bool hasInnerCapital = word.substring(1).contains(RegExp('[A-Z]'));
    final bool startsUpper = word[0].toUpperCase() == word[0] && word[0].toLowerCase() != word[0];
    if (hasInnerCapital || startsUpper) {
      result.add(word);
    }
  }
  return result;
}

/// Picks symbols worth showing the agent for the given [identifiers].
///
/// When an identifier names a type, every member of that type is included as
/// well. That sibling expansion is the point of the whole exercise: an issue
/// that mentions `RenewalState` causes all five of its real cases to be listed,
/// which is what makes an invented case like `inPadd` unlikely.
List<Map<String, dynamic>> selectSymbols(
  List<Map<String, dynamic>> symbols,
  Set<String> identifiers, {
  int maxSymbols = 60,
}) {
  List<String> pathOf(Map<String, dynamic> s) =>
      (s['pathComponents'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList();

  // Types directly named by the issue.
  final matchedTypePaths = <String>{};
  for (final symbol in symbols) {
    final List<String> path = pathOf(symbol);
    if (path.isEmpty) {
      continue;
    }
    if (identifiers.contains(path.last) && _isType(symbol)) {
      matchedTypePaths.add(path.join('.'));
    }
  }

  final selected = <Map<String, dynamic>>[];
  final seen = <String>{};

  void add(Map<String, dynamic> symbol) {
    final String key = pathOf(symbol).join('.');
    if (key.isEmpty || seen.contains(key)) {
      return;
    }
    seen.add(key);
    selected.add(symbol);
  }

  for (final symbol in symbols) {
    final List<String> path = pathOf(symbol);
    if (path.isEmpty) {
      continue;
    }
    final String last = path.last;
    final String parent = path.length > 1 ? path.sublist(0, path.length - 1).join('.') : '';

    final bool namedDirectly = identifiers.contains(last);
    final bool memberOfMatchedType = matchedTypePaths.contains(parent);
    if (namedDirectly || memberOfMatchedType) {
      add(symbol);
    }
  }

  // Deterministic and readable: group members under their parent type.
  selected.sort(
    (Map<String, dynamic> a, Map<String, dynamic> b) =>
        pathOf(a).join('.').compareTo(pathOf(b).join('.')),
  );

  if (selected.length > maxSymbols) {
    return selected.sublist(0, maxSymbols);
  }
  return selected;
}

bool _isType(Map<String, dynamic> symbol) {
  final dynamic kind = symbol['kind'];
  if (kind is! Map) {
    return false;
  }
  final String id = kind['identifier']?.toString() ?? '';
  return id == 'swift.struct' ||
      id == 'swift.enum' ||
      id == 'swift.class' ||
      id == 'swift.protocol' ||
      id == 'swift.typealias';
}

/// Renders [symbols] as a compact prompt block.
String formatSymbolBlock(List<Map<String, dynamic>> symbols, {required String moduleName}) {
  if (symbols.isEmpty) {
    return '';
  }
  final buffer = StringBuffer();
  buffer.writeln('AUTHORITATIVE $moduleName SDK SYMBOLS (generated from the installed Xcode SDK).');
  buffer.writeln(
    'These declarations are exact. Do NOT invent names that do not appear here; '
    'if a symbol you expect is absent, it does not exist on this SDK version.',
  );
  buffer.writeln();

  for (final symbol in symbols) {
    final List<dynamic> pathRaw = symbol['pathComponents'] as List<dynamic>? ?? <dynamic>[];
    final String path = pathRaw.map((dynamic e) => e.toString()).join('.');

    final List<dynamic> fragments = symbol['declarationFragments'] as List<dynamic>? ?? <dynamic>[];
    final String declaration = fragments
        .whereType<Map<String, dynamic>>()
        .map((Map<String, dynamic> f) => f['spelling']?.toString() ?? '')
        .join();

    buffer.writeln('- $path');
    if (declaration.isNotEmpty) {
      buffer.writeln('    $declaration');
    }

    final dynamic doc = symbol['docComment'];
    if (doc is Map) {
      final dynamic lines = doc['lines'];
      if (lines is List) {
        final String text = lines
            .whereType<Map<String, dynamic>>()
            .map((Map<String, dynamic> l) => l['text']?.toString() ?? '')
            .join(' ')
            .trim();
        if (text.isNotEmpty) {
          buffer.writeln('    // $text');
        }
      }
    }
  }
  return buffer.toString();
}
