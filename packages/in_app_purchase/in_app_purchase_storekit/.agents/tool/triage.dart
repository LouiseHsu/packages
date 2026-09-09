// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

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
    // Gemini Developer API endpoint (Local / API key testing)
    requestUri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
    );
  } else {
    throw StateError('No credentials found. Provide either GCP_ACCESS_TOKEN or GEMINI_API_KEY.');
  }

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
    final HttpClientRequest request = await httpClient.postUrl(requestUri);
    headers.forEach((String key, String value) {
      request.headers.set(key, value);
    });
    request.write(jsonEncode(requestBody));

    final HttpClientResponse response = await request.close();
    final String responseText = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      throw HttpException(
        'Gemini API request failed (${response.statusCode}): $responseText',
        uri: requestUri,
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
  } finally {
    httpClient.close();
  }
}

void writeGithubOutput(String key, String value) {
  final String? outputPath = Platform.environment['GITHUB_OUTPUT'];
  if (outputPath != null && outputPath.isNotEmpty) {
    File(outputPath).writeAsStringSync('$key=$value\n', mode: FileMode.append);
  }
}

Future<void> main(List<String> args) async {
  final Map<String, String> env = Platform.environment;

  // Retrieve issue information from env or args
  String title = env['ISSUE_TITLE'] ?? '';
  String body = env['ISSUE_BODY'] ?? '';
  int issueNumber = int.tryParse(env['ISSUE_NUMBER'] ?? '') ?? 0;

  // Optional JSON file payload support
  final String? eventPath = env['GITHUB_EVENT_PATH'];
  if (eventPath != null && File(eventPath).existsSync()) {
    try {
      final eventJson = jsonDecode(File(eventPath).readAsStringSync()) as Map<String, dynamic>;
      final issue = eventJson['issue'] as Map<String, dynamic>?;
      if (issue != null) {
        title = issue['title'] as String? ?? title;
        body = issue['body'] as String? ?? body;
        issueNumber = (issue['number'] as num?)?.toInt() ?? issueNumber;
      }
    } catch (e) {
      stderr.writeln('Warning: Failed to parse GITHUB_EVENT_PATH: $e');
    }
  }

  if (title.isEmpty && issueNumber > 0) {
    try {
      final ProcessResult result = Process.runSync('gh', <String>[
        'issue',
        'view',
        issueNumber.toString(),
        '--json',
        'title,body',
      ]);
      if (result.exitCode == 0) {
        final issueData = jsonDecode(result.stdout as String) as Map<String, dynamic>;
        title = issueData['title'] as String? ?? title;
        body = issueData['body'] as String? ?? body;
      }
    } catch (e) {
      stderr.writeln('Warning: Could not fetch issue via gh CLI: $e');
    }
  }

  if (title.isEmpty) {
    stderr.writeln('Error: Issue title is empty. Set ISSUE_TITLE or GITHUB_EVENT_PATH.');
    exitCode = 1;
    return;
  }

  stdout.writeln('=================== STOREKIT ISSUE TRIAGE ===================');
  stdout.writeln('Issue #$issueNumber: $title');

  // Step 1: Zero-cost regex gate
  if (!passesStaticGate(title, body)) {
    writeGithubOutput('accepted', 'false');
    writeGithubOutput('reason', 'heuristic_gate_filtered');
    stdout.writeln('Verdict: REJECTED (Failed Tier 1 regex heuristic)');
    return;
  }

  // Step 2: Gemini 2.5 Flash Structured Evaluation
  stdout.writeln('Querying Gemini 2.5 Flash structured evaluation...');
  try {
    final TriageVerdict verdict = await evaluateWithGemini(
      title: title,
      body: body,
      issueNumber: issueNumber,
      apiKey: env['GEMINI_API_KEY'],
      gcpAccessToken: env['GCP_ACCESS_TOKEN'],
      gcpProjectId: env['GCP_PROJECT_ID'] ?? 'flutter-dev',
      gcpLocation: env['GCP_LOCATION'] ?? 'us-central1',
      model: env['GEMINI_MODEL'] ?? 'gemini-2.5-flash-lite',
    );

    stdout.writeln('Evaluation Results:');
    stdout.writeln(' - Category: ${verdict.category}');
    stdout.writeln(' - Is Mechanical: ${verdict.isMechanical}');
    stdout.writeln(' - Suitability Score: ${verdict.suitabilityScore}/10');
    stdout.writeln(' - Target Files: ${verdict.targetFilesHint}');
    stdout.writeln(' - Reasoning: ${verdict.reasoning}');

    final bool accepted = verdict.isMechanical && verdict.suitabilityScore >= 7;

    writeGithubOutput('accepted', accepted ? 'true' : 'false');
    writeGithubOutput('score', verdict.suitabilityScore.toString());
    writeGithubOutput('category', verdict.category);
    writeGithubOutput('is_mechanical', verdict.isMechanical ? 'true' : 'false');
    writeGithubOutput('reasoning', verdict.reasoning.replaceAll('\n', ' '));

    if (accepted) {
      stdout.writeln('🚀 Verdict: ACCEPTED for automated resolution!');
    } else {
      stdout.writeln('❌ Verdict: REJECTED (Does not meet mechanical criteria)');
    }
  } catch (e, stack) {
    stderr.writeln('Error during triage evaluation: $e');
    stderr.writeln(stack);
    writeGithubOutput('accepted', 'false');
    writeGithubOutput('reason', 'evaluation_error');
    exitCode = 1;
  }
}
