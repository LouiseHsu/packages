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
    this.maxSymbols = 120,
    this.maxPerType = 6,
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

  /// Hard ceiling on symbols rendered into the prompt.
  ///
  /// Deliberately slack. On issue #7, the worst case measured, [maxPerType] is
  /// what actually binds and only 107 symbols are emitted, so this is a
  /// backstop against a pathological issue naming a dozen broad types rather
  /// than the knob that shapes normal output. Tuning selection with this number
  /// produced exactly the bug it was meant to prevent: a prefix cut that
  /// dropped `RenewalState` entirely.
  final int maxSymbols;

  /// Upper bound on how many members a single parent type may contribute.
  ///
  /// The real budget. Guards against one large type -- `Product` has well over
  /// a hundred members -- swallowing the prompt and pushing out the small
  /// nested types the agent actually needs.
  ///
  /// Six is empirical: it is the smallest value that emits every
  /// `RenewalState` case for issue #7 with room to spare, at roughly 19 KB of
  /// prompt. Five drops `subscribed`.
  final int maxPerType;

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
      maxPerType: maxPerType,
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

/// Members every Swift type inherits from the standard protocols.
///
/// On the issue #7 run these ate the budget: mentioning `Product` pulled in
/// `Product.==`, `Product.!=`, `Product.hashValue` and friends, and the cap
/// then truncated the block before it reached the `RenewalState` cases -- which
/// is the exact information the agent went on to get wrong.
const Set<String> _conformanceNoise = <String>{
  '==',
  '!=',
  '<',
  '<=',
  '>',
  '>=',
  'hash',
  'hashValue',
  'rawValue',
  'RawValue',
  'encode',
  'description',
  'debugDescription',
  'customMirror',
  'init(rawValue:)',
  'init(from:)',
  // `RawAttachmentValueRepresentable` plumbing. These two showed up inside
  // `RenewalState` and, being alphabetically ahead of `revoked` and
  // `subscribed`, pushed two real cases out of that type's budget.
  'makeFromRawAttachmentValue',
  'rawAttachmentValueRepresentation',
};

/// Strips argument labels from a path component so `==(_:_:)` matches `==`.
String _baseName(String component) {
  final int paren = component.indexOf('(');
  if (paren <= 0) {
    return component;
  }
  return component.substring(0, paren);
}

bool _isNoise(String lastComponent) =>
    _conformanceNoise.contains(lastComponent) ||
    _conformanceNoise.contains(_baseName(lastComponent));

/// Picks symbols worth showing the agent for the given [identifiers].
///
/// Selection runs in three relevance tiers, and [maxSymbols] is applied only
/// after ordering, so truncation drops the least useful entries:
///
///  0. symbols the issue names outright;
///  1. members of a type the issue names;
///  2. members of a type nested inside one the issue names.
///
/// Tier 2 is what makes this work in practice. An issue rarely names the enum
/// whose cases the agent will need: issue #7 mentioned `Product.SubscriptionInfo`
/// but never `RenewalState`, and the agent then wrote `inBillingRetry` for a
/// case actually called `inBillingRetryPeriod`. Reaching one level past the
/// named type puts those cases in front of it.
///
/// [maxPerType] bounds how many members a single parent type may contribute, so
/// a large type cannot consume the whole budget. See the fairness pass below.
List<Map<String, dynamic>> selectSymbols(
  List<Map<String, dynamic>> symbols,
  Set<String> identifiers, {
  int maxSymbols = 120,
  int maxPerType = 6,
}) {
  List<String> pathOf(Map<String, dynamic> s) =>
      (s['pathComponents'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList();

  // Types the issue names outright.
  final tier1Types = <String>{};
  for (final symbol in symbols) {
    final List<String> path = pathOf(symbol);
    if (path.isNotEmpty && identifiers.contains(path.last) && _isType(symbol)) {
      tier1Types.add(path.join('.'));
    }
  }

  // Types nested directly inside those.
  final tier2Types = <String>{};
  for (final symbol in symbols) {
    final List<String> path = pathOf(symbol);
    if (path.length < 2 || !_isType(symbol)) {
      continue;
    }
    if (tier1Types.contains(path.sublist(0, path.length - 1).join('.'))) {
      tier2Types.add(path.join('.'));
    }
  }

  final ranked = <MapEntry<int, Map<String, dynamic>>>[];
  final seen = <String>{};

  for (final symbol in symbols) {
    final List<String> path = pathOf(symbol);
    if (path.isEmpty) {
      continue;
    }
    final String key = path.join('.');
    if (seen.contains(key)) {
      continue;
    }
    final String last = path.last;
    final String parent = path.length > 1 ? path.sublist(0, path.length - 1).join('.') : '';

    int? tier;
    if (identifiers.contains(last)) {
      tier = 0;
    } else if (tier1Types.contains(parent)) {
      tier = 1;
    } else if (tier2Types.contains(parent)) {
      tier = 2;
    }
    if (tier == null) {
      continue;
    }

    // Boilerplate is dropped unless the issue asked for it by name.
    if (tier != 0 && _isNoise(last)) {
      continue;
    }

    seen.add(key);
    ranked.add(MapEntry<int, Map<String, dynamic>>(tier, symbol));
  }

  ranked.sort((MapEntry<int, Map<String, dynamic>> a, MapEntry<int, Map<String, dynamic>> b) {
    if (a.key != b.key) {
      return a.key.compareTo(b.key);
    }
    final int rankA = _memberRank(a.value);
    final int rankB = _memberRank(b.value);
    if (rankA != rankB) {
      return rankA.compareTo(rankB);
    }
    return pathOf(a.value).join('.').compareTo(pathOf(b.value).join('.'));
  });

  // Fairness pass: hand the budget out round-robin across parent types.
  //
  // A plain prefix cut is useless here. Measured on issue #7, whose text names
  // `Product`, `SubscriptionInfo` and `RenewalInfo`: 208 symbols matched, and
  // `inBillingRetryPeriod` -- the one name the agent got wrong -- sat at index
  // 172. A per-parent cap alone was not enough either: the budget was still
  // spent in path order, so `PurchaseError`, `PurchaseOption` and `ProductType`
  // exhausted it before the alphabetically later `RenewalState` was reached.
  //
  // Round-robin fixes both. Each parent contributes its first member, then its
  // second, and so on. Small types are the cheap ones and they finish early, so
  // a five-case enum lands in full while a hundred-member type is throttled to
  // the same handful of entries as everyone else.
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final entry in ranked) {
    final List<String> path = pathOf(entry.value);
    final String parent = path.length > 1 ? path.sublist(0, path.length - 1).join('.') : '';
    // Tier is part of the key so a type reached two different ways does not
    // share a quota.
    groups.putIfAbsent('${entry.key}|$parent', () => <Map<String, dynamic>>[]).add(entry.value);
  }

  // Within a round, serve the smallest types first.
  //
  // The final round is almost always partial, and whoever is served last in it
  // loses a member. Losing one member of a hundred-member type costs nothing;
  // losing the fifth case of a five-case enum defeats the entire purpose. Size
  // order makes the partial round fall on the types that can afford it. Tier
  // still leads, so a type the issue named outright is never starved by a
  // smaller type reached indirectly.
  int tierOf(String key) => int.parse(key.split('|').first);
  final List<String> order = groups.keys.toList()
    ..sort((String a, String b) {
      if (tierOf(a) != tierOf(b)) {
        return tierOf(a).compareTo(tierOf(b));
      }
      if (groups[a]!.length != groups[b]!.length) {
        return groups[a]!.length.compareTo(groups[b]!.length);
      }
      return a.compareTo(b);
    });

  final selected = <Map<String, dynamic>>[];
  for (var round = 0; round < maxPerType; round++) {
    var progressed = false;
    for (final key in order) {
      final List<Map<String, dynamic>> group = groups[key]!;
      if (round >= group.length) {
        continue;
      }
      progressed = true;
      selected.add(group[round]);
      if (selected.length >= maxSymbols) {
        break;
      }
    }
    if (!progressed || selected.length >= maxSymbols) {
      break;
    }
  }

  // Round-robin emits one member per type at a time, which would render as an
  // unreadable interleaving. Restore tier-then-path order for the prompt so the
  // block reads as a grouped listing per type.
  selected.sort(
    (Map<String, dynamic> a, Map<String, dynamic> b) =>
        pathOf(a).join('.').compareTo(pathOf(b).join('.')),
  );
  return selected;
}

/// Orders members of one type by how badly the agent needs to see them.
///
/// Closed sets of names come first. An enum case list is the thing a model
/// invents: it produced `inBillingRetry` for a case really called
/// `inBillingRetryPeriod`. A partial case list is worse than useless, because
/// it looks complete, so cases must win the per-type budget over methods.
///
/// Note that "enum case" is not enough of a test on its own. `RenewalState` is
/// a `RawRepresentable` struct, not an enum, and its cases are declared as
/// static properties -- `swift.type.property` -- which is why that kind ranks
/// alongside `swift.enum.case` here.
int _memberRank(Map<String, dynamic> symbol) {
  final dynamic kind = symbol['kind'];
  final String id = kind is Map ? (kind['identifier']?.toString() ?? '') : '';
  switch (id) {
    case 'swift.enum.case':
    case 'swift.type.property':
      return 0;
    case 'swift.property':
      return 1;
    default:
      return 2;
  }
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
