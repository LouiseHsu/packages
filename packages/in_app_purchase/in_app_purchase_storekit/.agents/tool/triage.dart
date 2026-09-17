// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Represents the structured output from the triage evaluation.
class TriageVerdict {
  const TriageVerdict({
    required this.isMechanical,
    required this.suitabilityScore,
    required this.category,
    required this.targetFilesHint,
    required this.reasoning,
  });

  factory TriageVerdict.fromJson(Map<String, dynamic> json) {
    return TriageVerdict(
      isMechanical: json['is_mechanical'] as bool? ?? false,
      suitabilityScore: (json['suitability_score'] as num?)?.toInt() ?? 0,
      category: json['category'] as String? ?? 'unknown',
      targetFilesHint:
          (json['target_files_hint'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList() ??
          <String>[],
      reasoning: json['reasoning'] as String? ?? '',
    );
  }

  final bool isMechanical;
  final int suitabilityScore;
  final String category;
  final List<String> targetFilesHint;
  final String reasoning;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'is_mechanical': isMechanical,
    'suitability_score': suitabilityScore,
    'category': category,
    'target_files_hint': targetFilesHint,
    'reasoning': reasoning,
  };
}

/// Tier 1: Zero-cost heuristic pre-filter.
/// Drops issues that mention flaky behaviors, live sandbox receipts, TestFlight, etc.
bool passesStaticGate(String title, String body) {
  final String combinedText = '$title $body'.toLowerCase();
  const negativeKeywords = <String>[
    'flaky',
    'intermittent',
    'race condition',
    'testflight',
    'sandbox receipt',
    'memory leak',
  ];

  for (final keyword in negativeKeywords) {
    if (combinedText.contains(keyword)) {
      stdout.writeln('🛑 Tier 1 Gate: Dropped issue matching negative keyword: "$keyword"');
      return false;
    }
  }
  return true;
}

/// Tier 2: Queries Gemini 2.5 Flash with structured JSON output enforcement.
Future<TriageVerdict> evaluateWithGemini({
  required String title,
  required String body,
  required int issueNumber,
  String? apiKey,
  String? gcpAccessToken,
  String gcpProjectId = 'flutter-dev',
  String gcpLocation = 'us-central1',
  String model = 'gemini-2.5-flash-lite',
  int maxNetworkRetries = 3,
  Duration retryDelay = const Duration(seconds: 5),
  void Function(String message)? logger,
  // Test-only seam. Not annotated `@visibleForTesting` because this file is
  // reachable from `run.dart`, which CI invokes as a bare `dart run.dart` with
  // no `pub get`. Every library in that import graph must therefore stick to
  // `dart:` imports -- even `package:meta`, which is a direct dependency,
  // resolves at analysis time but fails at run time in CI.
  Uri? endpointOverride,
}) async {
  final Uri requestUri;
  final headers = <String, String>{'Content-Type': 'application/json'};

  if (gcpAccessToken != null && gcpAccessToken.isNotEmpty) {
    // Vertex AI endpoint (Keyless Workload Identity Federation)
    requestUri = Uri.parse(
      'https://$gcpLocation-aiplatform.googleapis.com/v1/projects/$gcpProjectId/locations/$gcpLocation/publishers/google/models/$model:generateContent',
    );
    headers['Authorization'] = 'Bearer $gcpAccessToken';
  } else if (apiKey != null && apiKey.isNotEmpty) {
    // Gemini Developer API endpoint (Local / API key testing).
    //
    // The key is sent as a header rather than a `?key=` query parameter on
    // purpose. A Uri carrying the key leaks it into `HttpException.toString()`,
    // which Dart renders as `..., uri = <full url>` -- and that string ends up
    // in saved run logs and in CI output, which is world-readable on a public
    // repository.
    requestUri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
    );
    headers['x-goog-api-key'] = apiKey;
  } else {
    throw StateError('No credentials found. Provide either GCP_ACCESS_TOKEN or GEMINI_API_KEY.');
  }

  // Redirects the origin only, deliberately preserving the path and query
  // string. A wholesale Uri replacement would discard the query, which would
  // hide a credential accidentally reintroduced into the URL -- exactly the
  // regression the tests here exist to catch.
  final Uri effectiveUri = endpointOverride == null
      ? requestUri
      : requestUri.replace(
          scheme: endpointOverride.scheme,
          host: endpointOverride.host,
          port: endpointOverride.port,
        );

  const systemInstruction = '''
You are an expert triage engineer for Flutter's in_app_purchase_storekit package.
Your task is to evaluate incoming GitHub issues and determine if they are suitable for autonomous, mechanical resolution.

We prefer mechanical, well-defined issues such as:
- Exposing missing StoreKit 2 properties or structs to Dart (e.g., Product, Transaction, RenewalInfo)
- Fixing explicit type mismatches in Pigeon definitions
- Repairing object mapping errors or basic null pointer checks in StoreKit2Translators.swift

We strictly avoid:
- Intermittent or flaky behaviors
- Issues requiring physical devices, live Apple Sandbox accounts, or TestFlight validation
- Wide-ranging feature design proposals or architectural refactors

Calibrated scoring reference (0-10):
- "Expose originalPurchaseDate from StoreKit 2 Transaction to Dart" -> score: 10, is_mechanical: true, category: "missing_field"
- "Crash on init when mapping StoreKit Transaction if productId is null" -> score: 8, is_mechanical: true, category: "mapping_error"
- "Purchases intermittently timeout on spotty cellular connection" -> score: 2, is_mechanical: false, category: "flaky"
- "Need support for family sharing verification in live TestFlight" -> score: 1, is_mechanical: false, category: "architectural"
''';

  final responseSchema = <String, dynamic>{
    'type': 'OBJECT',
    'properties': <String, dynamic>{
      'is_mechanical': <String, dynamic>{
        'type': 'BOOLEAN',
        'description':
            'True if the task is mechanical (exposing StoreKit 2 properties, fixing Pigeon mappings, or null checks).',
      },
      'suitability_score': <String, dynamic>{
        'type': 'INTEGER',
        'description': 'Suitability score from 0 to 10 for autonomous resolution.',
      },
      'category': <String, dynamic>{
        'type': 'STRING',
        'enum': <String>['missing_field', 'mapping_error', 'architectural', 'flaky', 'unrelated'],
      },
      'target_files_hint': <String, dynamic>{
        'type': 'ARRAY',
        'items': <String, dynamic>{'type': 'STRING'},
        'description':
            'Likely files needing changes (e.g. pigeons/sk2_pigeon.dart, StoreKit2Translators.swift).',
      },
      'reasoning': <String, dynamic>{
        'type': 'STRING',
        'description': 'Step-by-step reasoning explaining the score.',
      },
    },
    'required': <String>[
      'is_mechanical',
      'suitability_score',
      'category',
      'target_files_hint',
      'reasoning',
    ],
  };

  final requestBody = <String, dynamic>{
    'contents': <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{'text': 'ISSUE #$issueNumber TITLE:\n$title\n\nISSUE BODY:\n$body'},
        ],
      },
    ],
    'systemInstruction': <String, dynamic>{
      'parts': <Map<String, dynamic>>[
        <String, dynamic>{'text': systemInstruction},
      ],
    },
    'generationConfig': <String, dynamic>{
      'temperature': 0.0,
      'responseMimeType': 'application/json',
      'responseSchema': responseSchema,
    },
  };

  final httpClient = HttpClient();
  try {
    for (var attempt = 1; ; attempt++) {
      final HttpClientRequest request = await httpClient.postUrl(effectiveUri);
      headers.forEach((String key, String value) {
        request.headers.set(key, value);
      });
      // `request.write(String)` encodes with `request.encoding`, which defaults
      // to latin-1. A GitHub issue is arbitrary user text, so anything outside
      // that range -- an em dash, a curly quote, an emoji, an accented name,
      // any CJK -- throws `Invalid argument (string): Contains invalid
      // characters` before the request is even sent. Encoding to UTF-8 bytes
      // explicitly sidesteps the encoding attached to the request.
      request.add(utf8.encode(jsonEncode(requestBody)));

      final HttpClientResponse response = await request.close();
      final String responseText = await response.transform(utf8.decoder).join();

      // 503/429 are capacity signals, not verdicts about this model. Waiting is
      // the correct response; failing straight over to another model is not,
      // because a demand spike usually affects every model at once. Only give
      // up on this model once the retries are exhausted.
      final bool isTransient = response.statusCode == 503 || response.statusCode == 429;
      if (isTransient && attempt < maxNetworkRetries) {
        final String? retryAfterHeader = response.headers.value('retry-after');
        final int? parsedRetryAfter = retryAfterHeader != null
            ? int.tryParse(retryAfterHeader.trim())
            : null;
        final int exponentialSeconds = retryDelay == Duration.zero
            ? 0
            : math.min(60, (retryDelay.inSeconds * math.pow(2, attempt - 1)).toInt());
        final delay = Duration(seconds: parsedRetryAfter ?? exponentialSeconds);

        logger?.call(
          'Notice: Model "$model" busy (${response.statusCode}). '
          'Waiting ${delay.inSeconds}s before retry '
          '(attempt $attempt of $maxNetworkRetries)...',
        );
        if (delay > Duration.zero) {
          await Future<void>.delayed(delay);
        }
        continue;
      }

      if (response.statusCode != 200) {
        // Deliberately no `uri:` argument -- see the credential comment above.
        throw HttpException(
          'Gemini API request failed for model "$model" '
          '(${response.statusCode}): $responseText',
        );
      }

      final jsonResponse = jsonDecode(responseText) as Map<String, dynamic>;
      final candidates = jsonResponse['candidates'] as List<dynamic>?;
      if (candidates == null || candidates.isEmpty) {
        throw StateError('No candidates returned from Gemini API.');
      }

      final candidate = candidates.first as Map<String, dynamic>;
      final content = candidate['content'] as Map<String, dynamic>;
      final parts = content['parts'] as List<dynamic>;
      final firstPart = parts.first as Map<String, dynamic>;
      final rawJsonText = firstPart['text'] as String;

      final verdictMap = jsonDecode(rawJsonText) as Map<String, dynamic>;
      return TriageVerdict.fromJson(verdictMap);
    }
  } finally {
    // `force: true` because a plain `close()` only stops new connections and
    // waits for existing ones to drain. If the body threw part-way through
    // being written, that socket never completes, and the process sits there
    // holding the event loop open long after the error has been reported --
    // observed as an 11 minute CI step for a failure printed 17 seconds in.
    httpClient.close(force: true);
  }
}

void writeGithubOutput(String key, String value) {
  final String? outputPath = Platform.environment['GITHUB_OUTPUT'];
  if (outputPath != null && outputPath.isNotEmpty) {
    File(outputPath).writeAsStringSync('$key=$value\n', mode: FileMode.append);
  }
}
