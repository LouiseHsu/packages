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
      'resolves the real RenewalState cases from the installed SDK',
      () async {
        final oracle = SymbolOracle();
        final String block = await oracle.lookupForIssue(
          'Expose autoRenewPreference and willAutoRenew from RenewalState',
        );

        // Guards the exact regression from the issue #7 run, where the agent
        // emitted `RenewalState.inPadd`. Every real case must be present.
        expect(block, contains('subscribed'));
        expect(block, contains('expired'));
        expect(block, contains('inBillingRetryPeriod'));
        expect(block, contains('inGracePeriod'));
        expect(block, contains('revoked'));
        expect(block, isNot(contains('inPadd')));
      },
      // Needs Xcode; extraction is slow the first time and cached after.
      skip: !Platform.isMacOS,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });
}
