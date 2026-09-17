// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  group('Tier 2: Network behaviour', () {
    late HttpServer server;
    late List<HttpRequest> received;
    late List<String> receivedBodies;
    late List<int> responseCodes;

    /// Serves [responseCodes] in order, returning a valid verdict body for 200s.
    Future<void> startServer(List<int> codes) async {
      responseCodes = codes;
      received = <HttpRequest>[];
      receivedBodies = <String>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var index = 0;
      unawaited(() async {
        await for (final HttpRequest request in server) {
          received.add(request);
          receivedBodies.add(await utf8.decoder.bind(request).join());
          final int code = index < responseCodes.length ? responseCodes[index] : responseCodes.last;
          index++;
          request.response.statusCode = code;
          if (code == 200) {
            request.response.write(
              jsonEncode(<String, dynamic>{
                'candidates': <dynamic>[
                  <String, dynamic>{
                    'content': <String, dynamic>{
                      'parts': <dynamic>[
                        <String, dynamic>{
                          'text': jsonEncode(<String, dynamic>{
                            'is_mechanical': true,
                            'suitability_score': 9,
                            'category': 'missing_field',
                            'target_files_hint': <String>['pigeons/sk2_pigeon.dart'],
                            'reasoning': 'ok',
                          }),
                        },
                      ],
                    },
                  },
                ],
              }),
            );
          } else {
            request.response.write('{"error":{"code":$code,"status":"UNAVAILABLE"}}');
          }
          await request.response.close();
        }
      }());
    }

    tearDown(() async => server.close(force: true));

    test('never puts the API key in the request URL', () async {
      await startServer(<int>[200]);

      await evaluateWithGemini(
        title: 'Expose originalPurchaseDate',
        body: 'Add the field',
        issueNumber: 1,
        apiKey: 'SUPER_SECRET_KEY',
        endpointOverride: Uri.parse('http://${server.address.host}:${server.port}/'),
      );

      // The key must travel in a header. A Uri holding it leaks into
      // HttpException.toString(), and from there into logs and public CI output.
      expect(received.single.uri.toString(), isNot(contains('SUPER_SECRET_KEY')));
      expect(received.single.headers.value('x-goog-api-key'), 'SUPER_SECRET_KEY');
    });

    test('sends non-Latin-1 issue text without throwing', () async {
      await startServer(<int>[200]);

      // A real issue took CI down with exactly this. `HttpClientRequest.write`
      // encodes using the request's encoding, which defaults to latin-1, so an
      // em dash threw `Invalid argument (string): Contains invalid characters`
      // before anything was sent. GitHub issues are arbitrary user text: em
      // dashes, curly quotes, emoji and non-Latin scripts are all routine.
      const title = 'Can\u2019t tell if a transaction was refunded \u2014 SK2';
      const body =
          'Filed by Ren\u00e9e \u2014 \u201Crevoked\u201D purchases look valid. '
          '\u8FD4\u91D1 \u{1F4B8}';

      final TriageVerdict verdict = await evaluateWithGemini(
        title: title,
        body: body,
        issueNumber: 6,
        apiKey: 'k',
        endpointOverride: Uri.parse('http://${server.address.host}:${server.port}/'),
      );

      expect(verdict.suitabilityScore, 9);

      // Decoded as UTF-8 on the far end, so the characters must survive intact
      // rather than arriving mangled or replaced.
      final String sent = receivedBodies.single;
      expect(sent, contains('\u2014'));
      expect(sent, contains('Ren\u00e9e'));
      expect(sent, contains('\u8FD4\u91D1'));
      expect(sent, contains('\u{1F4B8}'));
    });

    test('retries a 503 on the same model instead of giving up', () async {
      await startServer(<int>[503, 503, 200]);
      final logs = <String>[];

      final TriageVerdict verdict = await evaluateWithGemini(
        title: 'Expose originalPurchaseDate',
        body: 'Add the field',
        issueNumber: 1,
        apiKey: 'k',
        retryDelay: Duration.zero,
        logger: logs.add,
        endpointOverride: Uri.parse('http://${server.address.host}:${server.port}/'),
      );

      expect(verdict.suitabilityScore, 9);
      expect(received.length, 3);
      expect(logs.where((String l) => l.contains('busy (503)')).length, 2);
    });

    test('gives up after exhausting retries so the caller can fail over', () async {
      await startServer(<int>[503]);

      await expectLater(
        evaluateWithGemini(
          title: 'Expose originalPurchaseDate',
          body: 'Add the field',
          issueNumber: 1,
          apiKey: 'SUPER_SECRET_KEY',
          maxNetworkRetries: 2,
          retryDelay: Duration.zero,
          endpointOverride: Uri.parse('http://${server.address.host}:${server.port}/'),
        ),
        throwsA(
          isA<HttpException>().having(
            // The thrown error is logged verbatim, so it must stay key-free.
            (HttpException e) => e.toString(),
            'message',
            allOf(contains('503'), isNot(contains('SUPER_SECRET_KEY'))),
          ),
        ),
      );
      expect(received.length, 2);
    });
  });
}
