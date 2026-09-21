// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../symbol_oracle.dart';

/// A miniature symbol graph shaped like the real
/// `swift-symbolgraph-extract` output, so the selection and rendering logic can
/// be tested without a 45 second extraction and without an Xcode install.
List<Map<String, dynamic>> _fakeGraph() {
  Map<String, dynamic> sym(List<String> path, String kind, String decl, {String? doc}) {
    return <String, dynamic>{
      'kind': <String, dynamic>{'identifier': kind},
      'pathComponents': path,
      'declarationFragments': <dynamic>[
        <String, dynamic>{'spelling': decl},
      ],
      if (doc != null)
        'docComment': <String, dynamic>{
          'lines': <dynamic>[
            <String, dynamic>{'text': doc},
          ],
        },
    };
  }

  return <Map<String, dynamic>>[
    sym(
      <String>['Product', 'SubscriptionInfo', 'RenewalState'],
      'swift.struct',
      'struct RenewalState',
    ),
    sym(
      <String>['Product', 'SubscriptionInfo', 'RenewalState', 'subscribed'],
      'swift.property',
      'static let subscribed: RenewalState',
    ),
    sym(
      <String>['Product', 'SubscriptionInfo', 'RenewalState', 'inGracePeriod'],
      'swift.property',
      'static let inGracePeriod: RenewalState',
    ),
    sym(
      <String>['Product', 'SubscriptionInfo', 'RenewalInfo', 'willAutoRenew'],
      'swift.property',
      'let willAutoRenew: Bool',
      doc: 'Whether the subscription will auto renew.',
    ),
    sym(<String>['Transaction', 'id'], 'swift.property', 'let id: UInt64'),
  ];
}

/// A deliberately unbalanced graph: one oversized type that sorts early, one
/// tiny type that sorts late, and one type whose methods sort ahead of its
/// cases.
///
/// This is the shape that broke in production. `Product` and `PurchaseError`
/// sorted ahead of `RenewalState` and consumed the whole budget, and within
/// `RenewalState` the conformance plumbing sorted ahead of `revoked` and
/// `subscribed`.
List<Map<String, dynamic>> _lopsidedGraph() {
  Map<String, dynamic> sym(List<String> path, String kind, String decl) {
    return <String, dynamic>{
      'kind': <String, dynamic>{'identifier': kind},
      'pathComponents': path,
      'declarationFragments': <dynamic>[
        <String, dynamic>{'spelling': decl},
      ],
    };
  }

  return <Map<String, dynamic>>[
    sym(<String>['Wrapper'], 'swift.struct', 'struct Wrapper'),
    sym(<String>['Wrapper', 'Alpha'], 'swift.struct', 'struct Alpha'),
    sym(<String>['Wrapper', 'Zeta'], 'swift.struct', 'struct Zeta'),
    for (int i = 0; i < 30; i++)
      sym(
        <String>['Wrapper', 'Alpha', 'm${i.toString().padLeft(2, '0')}'],
        'swift.property',
        'let m$i: Int',
      ),
    for (final String name in <String>['one', 'two', 'three'])
      sym(<String>['Wrapper', 'Zeta', name], 'swift.type.property', 'static let $name: Zeta'),
    sym(<String>['Holder'], 'swift.enum', 'enum Holder'),
    sym(<String>['Holder', 'aMethod(_:)'], 'swift.method', 'func aMethod(Int)'),
    sym(<String>['Holder', 'bMethod(_:)'], 'swift.method', 'func bMethod(Int)'),
    sym(<String>['Holder', 'zCase'], 'swift.enum.case', 'case zCase'),
  ];
}

void main() {
  group('extractIdentifiers', () {
    test('picks up camelCase and PascalCase but not ordinary prose', () {
      final Set<String> ids = extractIdentifiers(
        'The autoRenewPreference on RenewalInfo is never exposed to dart code.',
      );
      expect(ids, contains('autoRenewPreference'));
      expect(ids, contains('RenewalInfo'));
      // Lowercase prose words must not become lookup candidates, or the filter
      // matches most of the symbol graph and the prompt block is useless.
      expect(ids, isNot(contains('never')));
      expect(ids, isNot(contains('exposed')));
      expect(ids, isNot(contains('dart')));
    });

    test('ignores very short words', () {
      expect(extractIdentifiers('The API is OK'), isNot(contains('API')));
    });
  });

  group('selectSymbols', () {
    test('expands a named type to all of its members', () {
      // The point of the whole oracle: mentioning the type surfaces every real
      // case, which is what makes an invented case unlikely.
      final List<Map<String, dynamic>> selected = selectSymbols(_fakeGraph(), <String>{
        'RenewalState',
      });
      final List<String> paths = selected
          .map((Map<String, dynamic> s) => (s['pathComponents'] as List<dynamic>).join('.'))
          .toList();

      expect(paths, contains('Product.SubscriptionInfo.RenewalState.subscribed'));
      expect(paths, contains('Product.SubscriptionInfo.RenewalState.inGracePeriod'));
      expect(paths, isNot(contains('Transaction.id')));
    });

    test('matches a member named directly without pulling in the whole module', () {
      final List<Map<String, dynamic>> selected = selectSymbols(_fakeGraph(), <String>{
        'willAutoRenew',
      });
      expect(selected, hasLength(1));
      expect(
        (selected.single['pathComponents'] as List<dynamic>).join('.'),
        'Product.SubscriptionInfo.RenewalInfo.willAutoRenew',
      );
    });

    test('honours maxSymbols so the prompt cannot grow without bound', () {
      final List<Map<String, dynamic>> selected = selectSymbols(_fakeGraph(), <String>{
        'RenewalState',
      }, maxSymbols: 2);
      expect(selected, hasLength(2));
    });

    test('returns nothing when no identifier matches', () {
      expect(selectSymbols(_fakeGraph(), <String>{'NoSuchType'}), isEmpty);
    });

    test('spreads a tight budget across types instead of draining the first', () {
      // Regression test for the bug this whole pass exists to fix. `Alpha` is
      // huge and sorts first; `Zeta` is tiny and sorts last. A prefix cut gives
      // every slot to `Alpha` and `Zeta` disappears -- which is exactly what
      // happened to `RenewalState` behind `Product` and `PurchaseError`.
      final List<Map<String, dynamic>> selected = selectSymbols(
        _lopsidedGraph(),
        <String>{'Wrapper'},
        maxSymbols: 14,
        // Deliberately not the default, so this pins the behaviour rather than
        // tracking whatever the default is tuned to next.
        maxPerType: 4,
      );
      final List<String> paths = selected
          .map((Map<String, dynamic> s) => (s['pathComponents'] as List<dynamic>).join('.'))
          .toList();

      // The small type survives in full.
      expect(paths, contains('Wrapper.Zeta.one'));
      expect(paths, contains('Wrapper.Zeta.two'));
      expect(paths, contains('Wrapper.Zeta.three'));

      // The large type is throttled rather than allowed to take everything.
      final int alphaCount = paths.where((String p) => p.startsWith('Wrapper.Alpha.')).length;
      expect(alphaCount, lessThanOrEqualTo(4));
    });

    test('prefers case-like members over methods when a type is truncated', () {
      // A partial case list is worse than none: it looks complete. So when a
      // type cannot be shown in full, its cases must outrank its methods even
      // though the methods sort earlier alphabetically.
      final List<Map<String, dynamic>> selected = selectSymbols(_lopsidedGraph(), <String>{
        'Holder',
      }, maxPerType: 1);
      final List<String> paths = selected
          .map((Map<String, dynamic> s) => (s['pathComponents'] as List<dynamic>).join('.'))
          .toList();

      expect(paths, contains('Holder.zCase'));
      expect(paths, isNot(contains('Holder.aMethod(_:)')));
    });
  });

  group('formatSymbolBlock', () {
    test('renders declarations and doc comments, and warns against invention', () {
      final String block = formatSymbolBlock(
        selectSymbols(_fakeGraph(), <String>{'willAutoRenew'}),
        moduleName: 'StoreKit',
      );
      expect(block, contains('Product.SubscriptionInfo.RenewalInfo.willAutoRenew'));
      expect(block, contains('let willAutoRenew: Bool'));
      expect(block, contains('Whether the subscription will auto renew.'));
      expect(block, contains('Do NOT invent names'));
    });

    test('renders a symbol that has no doc comment without crashing', () {
      final String block = formatSymbolBlock(
        selectSymbols(_fakeGraph(), <String>{'RenewalState'}),
        moduleName: 'StoreKit',
      );
      expect(block, contains('static let subscribed: RenewalState'));
    });

    test('returns empty for no symbols so the prompt section is omitted', () {
      expect(formatSymbolBlock(<Map<String, dynamic>>[], moduleName: 'StoreKit'), isEmpty);
    });
  });

  group('SymbolOracle end to end', () {
    test(
      'supplies RenewalState cases for an issue that never names RenewalState',
      () async {
        // The verbatim issue #7 title. It says "renewal info" and names two
        // properties, but never mentions `RenewalState` -- the agent's use of
        // that enum was its own implementation choice.
        //
        // The first version of this test spelled out "RenewalState", so it
        // passed while the real run failed: the agent wrote `inBillingRetry`
        // for a case actually called `inBillingRetryPeriod`, and the cases had
        // been cut from the block entirely. Keep this wording verbatim.
        const issue =
            '[in_app_purchase_storekit] Expose StoreKit 2 subscription status '
            'and renewal info (autoRenewPreference, willAutoRenew). '
            'Product.SubscriptionInfo has a status(for:) lookup that yields a '
            'RenewalInfo.';

        final String block = await SymbolOracle().lookupForIssue(issue);

        expect(block, contains('autoRenewPreference'));
        expect(block, contains('willAutoRenew'));

        // The regression that actually bit us, twice.
        expect(
          block,
          contains('inBillingRetryPeriod'),
          reason: 'the agent invented `inBillingRetry`; the real case name must be present',
        );
        expect(block, contains('inGracePeriod'));
        expect(block, contains('subscribed'));
        expect(block, contains('revoked'));

        // Conformance boilerplate crowded out the useful symbols last time.
        expect(block, isNot(contains('static func == ')));
        expect(block, isNot(contains('hashValue')));
      },
      // Needs Xcode; extraction is slow the first time and cached after.
      skip: !Platform.isMacOS,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });

  group('Pseudo-enum detection', () {
    Map<String, dynamic> symbol(String path, String declaration, String kind) {
      return <String, dynamic>{
        'pathComponents': path.split('.'),
        'kind': <String, dynamic>{'identifier': kind},
        'declarationFragments': <Map<String, dynamic>>[
          <String, dynamic>{'spelling': declaration},
        ],
      };
    }

    test('flags a struct whose cases are static lets of its own type', () {
      final symbols = <Map<String, dynamic>>[
        symbol('Product.RenewalState', 'struct RenewalState', 'swift.struct'),
        symbol(
          'Product.RenewalState.subscribed',
          'static let subscribed: Product.RenewalState',
          'swift.type.property',
        ),
      ];

      expect(findPseudoEnums(symbols), contains('Product.RenewalState'));

      final String block = formatSymbolBlock(symbols, moduleName: 'StoreKit');
      expect(block, contains('is a STRUCT, not an enum'));
      expect(block, contains('@unknown default:'));
    });

    test('does not flag a real enum', () {
      final symbols = <Map<String, dynamic>>[
        symbol('Product.ProductType', 'enum ProductType', 'swift.enum'),
        symbol('Product.ProductType.consumable', 'case consumable', 'swift.enum.case'),
      ];

      expect(findPseudoEnums(symbols), isEmpty);
      expect(
        formatSymbolBlock(symbols, moduleName: 'StoreKit'),
        isNot(contains('is a STRUCT, not an enum')),
      );
    });

    test('does not flag a struct whose static members are a different type', () {
      // A static convenience constant is not an enum case.
      final symbols = <Map<String, dynamic>>[
        symbol('Product.Price', 'struct Price', 'swift.struct'),
        symbol(
          'Product.Price.maximumDigits',
          'static let maximumDigits: Int',
          'swift.type.property',
        ),
      ];

      expect(findPseudoEnums(symbols), isEmpty);
    });
  });
}
