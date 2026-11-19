import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_gemini_free_ai_client.dart';
import 'package:groq_stt_lab/lab_segmented_stt_bundle.dart';

Uri loopback(HttpServer server) =>
    Uri.parse('http://127.0.0.1:' + server.port.toString() + '/v1beta/models');

Map<String, Object?> success(String text, {String finish = 'STOP'}) => {
  'candidates': [{
    'finishReason': finish,
    'content': {'role': 'model', 'parts': [{'text': text}]},
  }],
};

const fixtureChunk = LabSegmentedTextChunk(
  index: 1, text: '會議開始',
  coreStartMs: 60000, coreEndMs: 120000,
  wireStartMs: 58000, wireEndMs: 120000,
);

void main() {
  test('Gemini Key checks Google models, not Groq, no transcript or audio',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    server.listen((request) async {
      calls++;
      expect(request.method, 'GET');
      expect(request.uri.path, '/v1beta/models');
      expect(request.headers.value('x-goog-api-key'), 'test_gemini_key');
      expect(request.headers.value('authorization'), isNull);
      expect(await utf8.decodeStream(request), isEmpty);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'models': [
          {'name': 'models/gemini-2.5-flash',
            'supportedGenerationMethods': ['generateContent']},
          {'name': 'models/gemini-2.5-flash-lite',
            'supportedGenerationMethods': ['generateContent']},
          {'name': 'models/gemini-pro-paid-only',
            'supportedGenerationMethods': ['generateContent']},
          {'name': 'models/text-embedding-004',
            'supportedGenerationMethods': ['embedContent']},
          {'name': 'models/gemini-2.5-flash-image',
            'supportedGenerationMethods': ['generateContent']},
        ],
      }));
      await request.response.close();
    });
    final client = LabGeminiFreeAiClient(
      modelsUri: loopback(server), generateBaseUri: loopback(server));
    try {
      expect(await client.listModels('test_gemini_key'),
          ['gemini-2.5-flash', 'gemini-2.5-flash-lite']);
      expect(calls, 1);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('Gemini model list supports bounded pagination, excludes paid',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    server.listen((req) async {
      seen.add(req.uri.queryParameters['pageToken'] ?? 'FIRST');
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(seen.length == 1 ? {
        'models': [{
          'name': 'models/gemini-2.5-flash-lite',
          'supportedGenerationMethods': ['generateContent']
        }],
        'nextPageToken': 'page_two',
      } : {
        'models': [{
          'name': 'models/gemini-3.6-flash',
          'supportedGenerationMethods': ['generateContent']
        }],
      }));
      await req.response.close();
    });
    final client = LabGeminiFreeAiClient(
        modelsUri: loopback(server), generateBaseUri: loopback(server));
    try {
      expect(await client.listModels('test_gemini_key'),
          ['gemini-2.5-flash-lite', 'gemini-3.6-flash']);
      expect(seen, ['FIRST', 'page_two']);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('whole ZIP texts are locally preflighted and sent in ONE text-only POST',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final events = <Map<String, Object?>>[];
    var calls = 0;
    final chunks = List<LabSegmentedTextChunk>.generate(6, (i) =>
        LabSegmentedTextChunk(
          index: i, text: '演練第' + (i + 1).toString() + '段原文',
          coreStartMs: i * 60000, coreEndMs: (i + 1) * 60000,
          wireStartMs: i == 0 ? 0 : i * 60000 - 2000,
          wireEndMs: (i + 1) * 60000,
        ));
    server.listen((req) async {
      calls++;
      expect(req.method, 'POST');
      expect(req.uri.path, '/v1beta/models/gemini-2.5-flash:generateContent');
      expect(req.headers.value('x-goog-api-key'), 'only_session_key');
      final payload = jsonDecode(await utf8.decodeStream(req)) as Map;
      expect(payload['generationConfig'], {'responseMimeType': 'application/json'});
      final text = (payload['contents'] as List).first['parts'][0]['text'] as String;
      final input = jsonDecode(text) as Map;
      expect(input['mode'], 'WHOLE_TRANSCRIPT_TEXT_ONLY');
      expect(input['source_sha256'], List.filled(64, 'a').join());
      expect((input['chunks'] as List).length, 6);
      expect(input['time_alignment'], 'SEPARATE_LOCAL_FUTURE_GATE');
      expect(text, contains('overlap_before_ms'));
      expect(text, isNot(contains('verbose_json')));
      expect(text, isNot(contains('api_key')));
      expect(text, isNot(contains('audio_bytes')));
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(success(
          jsonEncode({'transcript': '第一段延續到第六段[重疊待複核]'}))));
      await req.response.close();
    });
    final client = LabGeminiFreeAiClient(
      generateBaseUri: loopback(server),
      onDiagnostic: (event, data) => events.add({'event': event, ...data}),
    );
    try {
      final output = await client.reviewWholeTranscript(
        apiKey: 'only_session_key', model: 'gemini-2.5-flash',
        sourceSha256: List.filled(64, 'a').join(),
        chunks: chunks, participants: '樓長', glossary: '避難引導班',
      );
      expect(output, '第一段延續到第六段[重疊待複核]');
      expect(calls, 1);
      expect(events.any((e) => e['event'] == 'GEMINI_GENERATION_OUTCOME' &&
          e['operation'] == 'REVIEW_WHOLE' && e['reason'] == 'STOP'), isTrue);
      expect(jsonEncode(events), isNot(contains('only_session_key')));
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('whole input rejects missing chunk and oversize without any HTTP',
      () {
    final small = List<LabSegmentedTextChunk>.generate(6, (i) =>
        LabSegmentedTextChunk(
          index: i, text: '本段逐字稿',
          coreStartMs: i * 60000, coreEndMs: (i + 1) * 60000,
          wireStartMs: i == 0 ? 0 : i * 60000 - 2000,
          wireEndMs: (i + 1) * 60000,
        ));
    final sha = List.filled(64, 'b').join();
    expect(() => LabGeminiFreeAiClient.checkWholeInput(
      sourceSha256: sha, chunks: small.take(5).toList(),
      participants: '', glossary: '',
    ), throwsA(isA<StateError>().having(
        (e) => e.message, 'reason',
        'LAB_AI_WHOLE_SOURCE_OR_CONTEXT_HOLD')));
    final huge = List<LabSegmentedTextChunk>.generate(6, (i) =>
        LabSegmentedTextChunk(
          index: i, text: List.filled(6000, '字').join(),
          coreStartMs: i * 60000, coreEndMs: (i + 1) * 60000,
          wireStartMs: i == 0 ? 0 : i * 60000 - 2000,
          wireEndMs: (i + 1) * 60000,
        ));
    expect(() => LabGeminiFreeAiClient.checkWholeInput(
      sourceSha256: sha, chunks: huge,
      participants: '', glossary: '',
    ), throwsA(isA<StateError>().having(
        (e) => e.message, 'reason', 'LAB_AI_WHOLE_INPUT_LIMIT_HOLD')));
  });
  test('Gemini probe and bounded transcript use selected Google model',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Map<String, dynamic>>[];
    server.listen((req) async {
      expect(req.method, 'POST');
      expect(req.uri.path, '/v1beta/models/gemini-2.5-flash:generateContent');
      expect(req.headers.value('x-goog-api-key'), 'test_gemini_key');
      expect(req.headers.value('authorization'), isNull);
      final payload = jsonDecode(await utf8.decodeStream(req))
          as Map<String, dynamic>;
      requests.add(payload);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(
          success(requests.length == 1 ? 'OK' :
              jsonEncode({'transcript': '會議開始[重疊待複核]'}))));
      await req.response.close();
    });
    final client = LabGeminiFreeAiClient(
        modelsUri: loopback(server), generateBaseUri: loopback(server));
    try {
      expect(await client.testSelectedModel(
        apiKey: 'test_gemini_key', model: 'gemini-2.5-flash'), isTrue);
      final draft = await client.reviewChunk(
        apiKey: 'test_gemini_key', model: 'gemini-2.5-flash',
        chunk: fixtureChunk,
        previousTail: '上一段結尾', nextHead: '第三段開頭',
        participants: '王小姐', glossary: 'STT=語音轉文字');
      expect(draft, contains('會議開始'));
      expect(requests.length, 2);
      expect((requests[0]['contents'] as List).first['role'], 'user');
      expect((requests[0]['generationConfig'] as Map)['maxOutputTokens'], 256);
      expect(((requests[0]['generationConfig'] as Map)['thinkingConfig']
          as Map)['thinkingBudget'], 0);
      expect(requests[1]['generationConfig'], {
        'responseMimeType': 'application/json',
      });
      expect((requests[1]['generationConfig'] as Map)
          .containsKey('maxOutputTokens'), isFalse);
      expect((requests[1]['generationConfig'] as Map)
          .containsKey('temperature'), isFalse);
      expect((requests[1]['generationConfig'] as Map)
          .containsKey('thinkingConfig'), isFalse);
      final userContent =
          (((requests[1]['contents'] as List).first['parts'] as List).first
              as Map)['text'] as String;
      expect(userContent, contains('"overlap_before_ms":2000'));
      expect(userContent, contains('王小姐'));
      expect(userContent, contains('STT=語音轉文字'));
      expect(userContent, isNot(contains('RIFF')));
      expect(userContent, isNot(contains('api_key')));
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('403 and 429 stop with no retry and no provider error disclosure',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    server.listen((req) async {
      calls++;
      await req.drain<void>();
      req.response.statusCode = calls == 1 ? 403 : 429;
      req.response.write('fake echoed secret from provider');
      await req.response.close();
    });
    final client = LabGeminiFreeAiClient(
        modelsUri: loopback(server), generateBaseUri: loopback(server));
    try {
      await expectLater(client.listModels('test_gemini_key'),
        throwsA(isA<StateError>().having(
          (e) => e.message, 'reason', 'LAB_AI_KEY_OR_ACCESS_HOLD')));
      expect(calls, 1);
      await expectLater(client.testSelectedModel(
        apiKey: 'test_gemini_key', model: 'gemini-2.5-flash'),
        throwsA(isA<StateError>().having(
          (e) => e.message, 'reason', 'LAB_AI_RATE_LIMIT_429_STOP')));
      expect(calls, 2);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('MAX_TOKENS responses rejected, cannot become accepted draft',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await req.drain<void>();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(success('partial', finish: 'MAX_TOKENS')));
      await req.response.close();
    });
    final client = LabGeminiFreeAiClient(
        modelsUri: loopback(server), generateBaseUri: loopback(server));
    try {
      await expectLater(client.testSelectedModel(
        apiKey: 'test_gemini_key', model: 'gemini-2.5-flash'),
        throwsA(isA<StateError>().having(
          (e) => e.message, 'reason', 'LAB_AI_MAX_TOKENS_STOP')));
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('review uses Main App JSON config and rejects MAX_TOKENS without retry',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    server.listen((req) async {
      calls++;
      final body = jsonDecode(await utf8.decodeStream(req))
          as Map<String, dynamic>;
      expect(body['generationConfig'], {'responseMimeType': 'application/json'});
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'candidates': [{
          'finishReason': 'MAX_TOKENS',
          'content': {'parts': [{'text': '{"transcript":"partial"}'}]},
        }],
        'usageMetadata': {
          'promptTokenCount': 2410,
          'candidatesTokenCount': 8090,
          'thoughtsTokenCount': 101,
        },
      }));
      await req.response.close();
    });
    final diagnostics = <Map<String, Object?>>[];
    final client = LabGeminiFreeAiClient(
      generateBaseUri: loopback(server),
      onDiagnostic: (event, data) => diagnostics.add({'event': event, ...data}),
    );
    try {
      await expectLater(client.reviewChunk(
        apiKey: 'test_gemini_key', model: 'gemini-2.5-flash',
        chunk: fixtureChunk,
        previousTail: '', nextHead: '', participants: '', glossary: '',
      ), throwsA(isA<StateError>().having(
          (e) => e.message, 'reason', 'LAB_AI_MAX_TOKENS_STOP')));
      expect(calls, 1);
      final metadata = diagnostics.singleWhere(
          (event) => event['event'] == 'GEMINI_GENERATION_OUTCOME');
      expect(metadata['reason'], 'MAX_TOKENS');
      expect(metadata['mode'], 'MAIN_TEXT_JSON_PARITY');
      expect(metadata['output_cap'], 0);
      expect(metadata['prompt_tokens'], 2410);
      expect(metadata['reply_tokens'], 8090);
      expect(metadata['thought_tokens'], 101);
      expect(jsonEncode(diagnostics), isNot(contains('test_gemini_key')));
      expect(jsonEncode(diagnostics), isNot(contains('partial')));
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('HTTP 200 STOP with invalid transcript JSON is HOLD, never merged',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    server.listen((req) async {
      calls++;
      await req.drain<void>();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(success('not json')));
      await req.response.close();
    });
    final client = LabGeminiFreeAiClient(generateBaseUri: loopback(server));
    try {
      await expectLater(client.reviewChunk(
        apiKey: 'test_gemini_key', model: 'gemini-2.5-flash',
        chunk: fixtureChunk,
        previousTail: '', nextHead: '', participants: '', glossary: '',
      ), throwsA(isA<StateError>().having(
          (e) => e.message, 'reason', 'LAB_AI_OUTPUT_JSON_HOLD')));
      expect(calls, 1);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('HTTP 200 SAFETY finish refuses AI draft and remains one-shot',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    server.listen((req) async {
      calls++;
      await req.drain<void>();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(success('blocked', finish: 'SAFETY')));
      await req.response.close();
    });
    final client = LabGeminiFreeAiClient(generateBaseUri: loopback(server));
    try {
      await expectLater(client.reviewChunk(
        apiKey: 'test_gemini_key', model: 'gemini-2.5-flash',
        chunk: fixtureChunk,
        previousTail: '', nextHead: '', participants: '', glossary: '',
      ), throwsA(isA<StateError>().having(
          (e) => e.message, 'reason', 'LAB_AI_SAFETY_HOLD')));
      expect(calls, 1);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('3.6 model probe is a SINGLE low-thinking request and redacted log',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final records = <Map<String, Object?>>[];
    var calls = 0;
    server.listen((req) async {
      calls++;
      final input = jsonDecode(await utf8.decodeStream(req)) as Map;
      expect(req.uri.path, '/v1beta/models/gemini-3.6-flash:generateContent');
      expect((input['generationConfig'] as Map)['maxOutputTokens'], 256);
      expect(((input['generationConfig'] as Map)['thinkingConfig']
          as Map)['thinkingLevel'], 'MINIMAL');
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(success('OK')));
      await req.response.close();
    });
    final client = LabGeminiFreeAiClient(
      generateBaseUri: loopback(server),
      onDiagnostic: (event, data) => records.add({'event': event, ...data}),
    );
    try {
      expect(await client.testSelectedModel(
        apiKey: 'test_gemini_key', model: 'gemini-3.6-flash'),
        isTrue);
      expect(calls, 1);
      expect(records.any((r) => r['event'] == 'GEMINI_HTTP_STATUS' &&
          r['status'] == 200), isTrue);
      expect(jsonEncode(records), isNot(contains('test_gemini_key')));
      expect(jsonEncode(records), isNot(contains('Reply with OK')));
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('HTTP 503 is explicit provider STOP and never automatically re-sent',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((req) async {
      requests++;
      await req.drain<void>();
      req.response.statusCode = 503;
      req.response.write('some key and transcript that must not be logged');
      await req.response.close();
    });
    final log = <Map<String, Object?>>[];
    final client = LabGeminiFreeAiClient(
      generateBaseUri: loopback(server),
      onDiagnostic: (event, data) => log.add({'event': event, ...data}),
    );
    try {
      await expectLater(client.testSelectedModel(
        apiKey: 'test_key', model: 'gemini-3.6-flash'),
        throwsA(isA<StateError>().having(
          (e) => e.message, 'reason', 'LAB_AI_PROVIDER_503_STOP')));
      expect(requests, 1);
      expect(log.any((e) => e['event'] == 'GEMINI_HTTP_STATUS'
          && e['status'] == 503), isTrue);
      expect(jsonEncode(log), isNot(contains('transcript')));
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('malformed HTTP 200 body is JSON HOLD, not unknown network',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await req.drain<void>();
      req.response.headers.contentType = ContentType.json;
      req.response.write('this is not JSON');
      await req.response.close();
    });
    final client = LabGeminiFreeAiClient(generateBaseUri: loopback(server));
    try {
      await expectLater(client.testSelectedModel(
        apiKey: 'test_key', model: 'gemini-3.6-flash'),
        throwsA(isA<StateError>().having(
          (e) => e.message, 'reason', 'LAB_AI_RESPONSE_JSON_HOLD')));
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('slow POST header response yields timeout-unknown without retry',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((req) async {
      requests++;
      await req.drain<void>();
      // Deliberately do not respond: the transport timeout must stop locally.
    });
    final seen = <Map<String, Object?>>[];
    final client = LabGeminiFreeAiClient(
      generateBaseUri: loopback(server),
      requestTimeout: const Duration(milliseconds: 180),
      onDiagnostic: (event, data) => seen.add({'event': event, ...data}),
    );
    try {
      await expectLater(client.testSelectedModel(
        apiKey: 'test_key', model: 'gemini-3.6-flash'),
        throwsA(isA<StateError>().having(
          (e) => e.message, 'reason',
          'LAB_AI_TIMEOUT_OUTCOME_UNKNOWN_STOP')));
      expect(requests, 1);
      expect(seen.any((e) => e['event'] == 'GEMINI_HTTP_TIMEOUT' &&
          e['phase'] == 'HEADERS'), isTrue);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('unlisted paid model and overlength transcript blocked locally',
      () {
    final client = LabGeminiFreeAiClient();
    try {
      expect(() => client.reviewChunk(
        apiKey: 'test_gemini_key', model: 'gemini-4-argon',
        chunk: fixtureChunk,
        previousTail: '', nextHead: '', participants: '', glossary: '',
      ), throwsStateError);
      expect(() => client.reviewChunk(
        apiKey: 'test_gemini_key', model: 'gemini-2.5-flash',
        chunk: LabSegmentedTextChunk(
          index: 0, text: List.filled(10501, 'a').join(),
          coreStartMs: 0, coreEndMs: 60000,
          wireStartMs: 0, wireEndMs: 60000,
        ),
        previousTail: '', nextHead: '', participants: '', glossary: '',
      ), throwsStateError);
    } finally {
      client.close();
    }
  });
}
