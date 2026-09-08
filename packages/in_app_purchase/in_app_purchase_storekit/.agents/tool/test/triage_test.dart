// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

import '../triage.dart';

void main() {
  group('Tier 1: Static Heuristic Gate', () {
    test('drops issues containing flaky or intermittent keywords', () {
      expect(
        passesStaticGate('Purchase fails', 'This is an intermittent bug on cellular'),
        isFalse,
      );
      expect(passesStaticGate('Flaky purchase behavior', 'Happens on some runs'), isFalse);
      expect(passesStaticGate('TestFlight sandbox receipt failure', 'Validating receipt'), isFalse);
      expect(
        passesStaticGate('App memory leak after 100 purchases', 'Profiling shows leak'),
        isFalse,
      );
    });

    test('allows mechanical StoreKit issues to pass', () {
      expect(
        passesStaticGate(
          'Expose originalPurchaseDate in StoreKit 2 Transaction',
          'Please expose originalPurchaseDate to Dart in SK2Transaction.',
        ),
        isTrue,
      );
      expect(
        passesStaticGate(
          'Null pointer crash when mapping productId',
          'StoreKit2Translators crashes if product ID is null in response.',
        ),
        isTrue,
      );
    });
  });

  group('TriageVerdict JSON Parsing', () {
    test('correctly parses structured JSON response from Gemini', () {
      const rawJson = '''
      {
        "is_mechanical": true,
        "suitability_score": 9,
        "category": "missing_field",
        "target_files_hint": ["pigeons/sk2_pigeon.dart", "StoreKit2Translators.swift"],
        "reasoning": "Standard mechanical property pipe-through from StoreKit 2 to Dart."
      }
      ''';

      final jsonMap = jsonDecode(rawJson) as Map<String, dynamic>;
      final verdict = TriageVerdict.fromJson(jsonMap);

      expect(verdict.isMechanical, isTrue);
      expect(verdict.suitabilityScore, 9);
      expect(verdict.category, 'missing_field');
      expect(verdict.targetFilesHint, <String>[
        'pigeons/sk2_pigeon.dart',
        'StoreKit2Translators.swift',
      ]);
      expect(
        verdict.reasoning,
        'Standard mechanical property pipe-through from StoreKit 2 to Dart.',
      );
    });
  });
}
