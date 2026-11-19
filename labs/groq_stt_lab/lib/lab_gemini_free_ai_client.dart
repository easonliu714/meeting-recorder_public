import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'lab_segmented_stt_bundle.dart';

/// Gemini Free-tier text review, separate from the Groq audio STT client.
/// Only user-approved requests. Never reads audio, Groq Key, Raw JSON or
/// durable Journal. No retry, automatic model fallback or paid-tier action.
final class LabGeminiFreeAiClient {
  LabGeminiFreeAiClient({
    Uri? modelsUri,
    Uri? generateBaseUri,
    HttpClient? client,
    this.onDiagnostic,
    this.requestTimeout = const Duration(seconds: 150),
  })  : modelsUri = modelsUri ??
            Uri.parse('https://generativelanguage.googleapis.com/v1beta/models'),
        generateBaseUri = generateBaseUri ??
            Uri.parse('https://generativelanguage.googleapis.com/v1beta/models'),
        _client = client ?? HttpClient();

  final Uri modelsUri;
  final Uri generateBaseUri;
  final HttpClient _client;
  /// Diagnostics expose ONLY method/phase/status/error code, never keys,
  /// prompts, response bodies, URL query strings or transcript.
  final void Function(String, Map<String, Object?>)? onDiagnostic;
  final Duration requestTimeout;

  // These text models have an explicitly published Standard Free tier at
  // https://ai.google.dev/gemini-api/docs/pricing (checked 2026-11-18).
  // Their live availability and the user's real quota remain independent
  // constraints. Never offer arbitrary potentially paid models from models.list.
  static const freeTextModels = <String>{
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
    'gemini-3.6-flash',
  };

  static const maxRequestChars = 14000;
  static const maxWholeRequestChars = 30000;
  static const maxResponseBytes = 300000;
  static const maxResponseChars = 30000;

  void close() => _client.close(force: true);

  static String _key(String value) {
    final key = value.trim();
    if (key.isEmpty || key.length > 400 || key.contains(RegExp(r'\s'))) {
      throw StateError('LAB_AI_KEY_INVALID');
    }
    return key;
  }

  // Only the production Gemini host and dedicated loopback test endpoints.
  // Prevent a redirect, alternate service, or URI-injected key destination.
  static void _checkEndpoint(Uri endpoint) {
    final prod = endpoint.scheme == 'https' &&
        endpoint.host == 'generativelanguage.googleapis.com' &&
        endpoint.port == 443;
    final test = endpoint.scheme == 'http' &&
        (endpoint.host == '127.0.0.1' || endpoint.host == 'localhost') &&
        endpoint.port > 0;
    if (!(prod || test) || endpoint.userInfo.isNotEmpty ||
        endpoint.fragment.isNotEmpty ||
        !endpoint.path.startsWith('/v1beta/models') ||
        (endpoint.hasQuery && endpoint.queryParameters.keys.any(
          (name) => name != 'pageToken'))) {
      throw StateError('LAB_AI_UNSAFE_ENDPOINT');
    }
  }

  Future<Map<String, dynamic>> _request({
    required String key,
    required String method,
    required Uri endpoint,
    Map<String, Object?>? payload,
    required String operation,
    Duration? operationTimeout,
  }) async {
    final timeout = operationTimeout ?? requestTimeout;
    _checkEndpoint(endpoint);
    final safeKey = _key(key);
    var phase = 'OPEN';
    void diagnostic(String event, [int? status]) {
      onDiagnostic?.call(event, {
        'operation': operation, 'phase': phase,
        if (status != null) 'status': status,
      });
    }
    diagnostic('GEMINI_HTTP_PHASE');
    try {
      final request = await _client.openUrl(method, endpoint)
          .timeout(timeout);
      request.followRedirects = false;
      request.headers.set('x-goog-api-key', safeKey);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (payload != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(payload)));
      }
      phase = 'HEADERS';
      diagnostic('GEMINI_HTTP_PHASE');
      final response = await request.close().timeout(timeout);
      diagnostic('GEMINI_HTTP_STATUS', response.statusCode);
      if (response.statusCode != HttpStatus.ok) {
        // Never export provider error bodies (which may echo user text).
        if (response.statusCode == 400 || response.statusCode == 401 ||
            response.statusCode == 403) {
          throw StateError('LAB_AI_KEY_OR_ACCESS_HOLD');
        }
        if (response.statusCode == 429) {
          throw StateError('LAB_AI_RATE_LIMIT_429_STOP');
        }
        if (response.statusCode == 413) {
          throw StateError('LAB_AI_PAYLOAD_413_STOP');
        }
        if (response.statusCode == 404) {
          throw StateError('LAB_AI_MODEL_OR_INPUT_HOLD');
        }
        if (response.statusCode == 402) {
          throw StateError('LAB_AI_BILLING_402_HOLD');
        }
        if (response.statusCode == 408 || response.statusCode == 504) {
          throw StateError('LAB_AI_PROVIDER_TIMEOUT_STOP');
        }
        if (response.statusCode == 503) {
          throw StateError('LAB_AI_PROVIDER_503_STOP');
        }
        if (response.statusCode >= 500) {
          throw StateError('LAB_AI_PROVIDER_5XX_STOP');
        }
        throw StateError('LAB_AI_HTTP_STOP');
      }
      phase = 'BODY';
      diagnostic('GEMINI_HTTP_PHASE');
      final bytes = BytesBuilder(copy: false);
      await for (final part in response.timeout(timeout)) {
        if (bytes.length + part.length > maxResponseBytes) {
          throw StateError('LAB_AI_RESPONSE_TOO_LARGE');
        }
        bytes.add(part);
      }
      phase = 'DECODE';
      diagnostic('GEMINI_HTTP_PHASE');
      final decoded = jsonDecode(
          utf8.decode(bytes.takeBytes(), allowMalformed: false));
      if (decoded is! Map<String, dynamic>) {
        throw StateError('LAB_AI_RESPONSE_SCHEMA_HOLD');
      }
      diagnostic('GEMINI_HTTP_OK', HttpStatus.ok);
      return decoded;
    } on StateError {
      diagnostic('GEMINI_HTTP_STOP');
      rethrow;
    } on FormatException {
      // A completely received 200 body can be malformed without a socket
      // problem. Do not mislabel a JSON or UTF-8 decode fault as network.
      diagnostic('GEMINI_HTTP_DECODE_HOLD');
      throw StateError('LAB_AI_RESPONSE_JSON_HOLD');
    } on TimeoutException {
      diagnostic('GEMINI_HTTP_TIMEOUT');
      // The server may have processed a POST despite no complete response.
      throw StateError('LAB_AI_TIMEOUT_OUTCOME_UNKNOWN_STOP');
    } on HandshakeException {
      diagnostic('GEMINI_HTTP_TLS_HOLD');
      throw StateError('LAB_AI_TLS_HANDSHAKE_HOLD');
    } on SocketException {
      diagnostic('GEMINI_HTTP_SOCKET_HOLD');
      throw StateError('LAB_AI_SOCKET_OUTCOME_UNKNOWN_STOP');
    } on HttpException {
      diagnostic('GEMINI_HTTP_STREAM_HOLD');
      throw StateError('LAB_AI_HTTP_STREAM_UNKNOWN_STOP');
    } catch (_) {
      // Never emit exception strings; they can contain URI/account details.
      diagnostic('GEMINI_HTTP_UNKNOWN_STOP');
      throw StateError('LAB_AI_NETWORK_OUTCOME_UNKNOWN_STOP');
    }
  }

  /// API Key / model discovery is not proof of billing tier or Free quota.
  /// Query only Google Gemini; return just documented Free-tier text models
  /// that the account currently lists as supporting generateContent.
  Future<List<String>> listModels(String apiKey) async {
    final selected = <String>{};
    String? pageToken;
    final seenTokens = <String>{};
    for (var page = 0; page < 5; page++) {
      final endpoint = pageToken == null
          ? modelsUri
          : modelsUri.replace(queryParameters: {'pageToken': pageToken});
      final response = await _request(
          key: apiKey, method: 'GET', endpoint: endpoint,
          operation: 'MODELS');
      final entries = response['models'];
      if (entries is! List) throw StateError('LAB_AI_MODELS_SCHEMA_HOLD');
      for (final entry in entries) {
        if (entry is! Map || entry['name'] is! String ||
            entry['supportedGenerationMethods'] is! List) continue;
        final name = entry['name'] as String;
        final methods = entry['supportedGenerationMethods'] as List;
        if (name.startsWith('models/') &&
            freeTextModels.contains(name.substring(7)) &&
            methods.contains('generateContent')) {
          selected.add(name.substring(7));
        }
      }
      final next = response['nextPageToken'];
      if (next == null || next == '') break;
      if (next is! String || next.length > 512 ||
          !seenTokens.add(next) || page == 4) {
        throw StateError('LAB_AI_MODELS_PAGINATION_HOLD');
      }
      pageToken = next;
    }
    if (selected.isEmpty) throw StateError('LAB_AI_FREE_MODELS_NOT_FOUND');
    return selected.toList()..sort();
  }

  /// The transcript path mirrors Main App text generation settings:
  /// JSON MIME; no temperature, maxOutputTokens or thinking override;
  /// 180-second HTTP phase timeout. The short connectivity probe remains
  /// distinct and must NOT be treated as proof of transcript quality.
  /// Unlike legacy Main, Lab NEVER retries or rotates keys/models.
  Future<String> _generate({
    required String apiKey,
    required String model,
    required String systemPrompt,
    required String text,
    required int maxOutputTokens,
    bool probe = false,
    bool wholeReview = false,
    int inputLimit = maxRequestChars,
  }) async {
    if (!freeTextModels.contains(model) ||
        text.length > inputLimit ||
        inputLimit > maxWholeRequestChars ||
        maxOutputTokens <= 0 || maxOutputTokens > 8192) {
      throw StateError('LAB_AI_MODEL_OR_INPUT_HOLD');
    }
    final endpoint = generateBaseUri.replace(
        path: generateBaseUri.path + '/' + model + ':generateContent');
    final response = await _request(
      key: apiKey,
      method: 'POST',
      endpoint: endpoint,
      operation: probe ? 'MODEL_PROBE' :
          (wholeReview ? 'REVIEW_WHOLE' : 'REVIEW_CHUNK'),
      operationTimeout: probe ? null : const Duration(seconds: 180),
      payload: {
        'systemInstruction': {
          'parts': [{
            'text': probe
                ? systemPrompt
                : '$systemPrompt '
                  '輸出必須為合法 JSON 物件，恰有一個名為 transcript 的字串欄位。'
                  '不要輸出 Markdown 程式碼圍欄、相鄰 Chunk 或任何額外欄位。'
                  'transcript 的內容僅代表本段 AI 草稿，禁止憑空補語音。'
          }],
        },
        'contents': [
          {'role': 'user', 'parts': [{'text': text}]},
        ],
        'generationConfig': probe
            ? {
                'temperature': 0,
                'maxOutputTokens': maxOutputTokens,
                'thinkingConfig': model == 'gemini-3.6-flash'
                    ? {'thinkingLevel': 'MINIMAL'}
                    : {'thinkingBudget': 0},
              }
            : <String, Object?>{
                // Exact matching fields used by Main App generateTextOnly().
                'responseMimeType': 'application/json',
              },
      },
    );
    final candidates = response['candidates'];
    final dynamic rawReason = candidates is List &&
            candidates.length == 1 && candidates.first is Map
        ? (candidates.first as Map)['finishReason']
        : null;
    const safeReasons = <String>{
      'STOP', 'MAX_TOKENS', 'SAFETY', 'RECITATION', 'OTHER',
      'BLOCKLIST', 'PROHIBITED_CONTENT', 'SPII',
      'FINISH_REASON_UNSPECIFIED', 'MALFORMED_FUNCTION_CALL',
      'UNEXPECTED_TOOL_CALL', 'TOO_MANY_TOOL_CALLS',
    };
    final reason = rawReason is String && safeReasons.contains(rawReason)
        ? rawReason : 'UNKNOWN';
    final usage = response['usageMetadata'];
    int? safeCount(String field) {
      final count = usage is Map ? usage[field] : null;
      return count is int && count >= 0 && count <= 10000000
          ? count : null;
    }
    // Metadata only; never record prompt, draft, API Key or response body.
    onDiagnostic?.call('GEMINI_GENERATION_OUTCOME', {
      'operation': probe ? 'MODEL_PROBE' :
          (wholeReview ? 'REVIEW_WHOLE' : 'REVIEW_CHUNK'),
      'reason': reason,
      'mode': probe ? 'PROBE' : 'MAIN_TEXT_JSON_PARITY',
      'output_cap': probe ? maxOutputTokens : 0, // 0 = unset.
      if (safeCount('promptTokenCount') != null)
        'prompt_tokens': safeCount('promptTokenCount'),
      if (safeCount('candidatesTokenCount') != null)
        'reply_tokens': safeCount('candidatesTokenCount'),
      if (safeCount('thoughtsTokenCount') != null)
        'thought_tokens': safeCount('thoughtsTokenCount'),
    });
    if (candidates is! List || candidates.length != 1 ||
        candidates.first is! Map || reason != 'STOP') {
      if (reason == 'MAX_TOKENS') {
        throw StateError('LAB_AI_MAX_TOKENS_STOP');
      }
      if (reason == 'SAFETY' || reason == 'BLOCKLIST' ||
          reason == 'PROHIBITED_CONTENT' || reason == 'SPII') {
        throw StateError('LAB_AI_SAFETY_HOLD');
      }
      throw StateError('LAB_AI_INCOMPLETE_RESPONSE_HOLD');
    }
    final candidate = candidates.first as Map;
    final content = candidate['content'];
    if (content is! Map || content['parts'] is! List) {
      throw StateError('LAB_AI_RESPONSE_SCHEMA_HOLD');
    }
    final parts = content['parts'] as List;
    if (parts.isEmpty ||
        parts.any((p) => p is! Map || p['text'] is! String)) {
      throw StateError('LAB_AI_RESPONSE_SCHEMA_HOLD');
    }
    final rawOutput = parts.map((p) => (p as Map)['text'] as String)
        .join().trim();
    if (rawOutput.isEmpty || rawOutput.length > maxResponseChars) {
      throw StateError('LAB_AI_EMPTY_OR_OVERSIZE_OUTPUT_HOLD');
    }
    if (probe) return rawOutput;
    // Main App asks Gemini for JSON; Lab additionally constrains the
    // schema to one transcript string so derived text is never misread
    // as raw model prose or used to mutate original Provider STT.
    final dynamic decoded;
    try {
      decoded = jsonDecode(rawOutput);
    } catch (_) {
      throw StateError('LAB_AI_OUTPUT_JSON_HOLD');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 1 || decoded['transcript'] is! String) {
      throw StateError('LAB_AI_OUTPUT_JSON_SCHEMA_HOLD');
    }
    final draft = (decoded['transcript'] as String).trim();
    if (draft.isEmpty || draft.length > maxResponseChars) {
      throw StateError('LAB_AI_EMPTY_OR_OVERSIZE_OUTPUT_HOLD');
    }
    return draft;
  }

  /// A real, tiny model inference with its own user-confirmed consent.
  /// Does NOT submit meeting data or prove Free billing.
  Future<bool> testSelectedModel({
    required String apiKey,
    required String model,
  }) async {
    final output = await _generate(
      apiKey: apiKey,
      model: model,
      systemPrompt: 'Connectivity test only. Reply with OK.',
      text: 'Reply with OK.',
      maxOutputTokens: 256,
      probe: true,
    );
    return output.toUpperCase().startsWith('OK');
  }

  /// Offline-only preflight: six pieces of text plus physical chunk clocks.
  /// No ZIP, source audio or Provider Raw ever sent to Gemini.
  static String checkWholeInput({
    required String sourceSha256,
    required List<LabSegmentedTextChunk> chunks,
    required String participants,
    required String glossary,
  }) {
    if (sourceSha256.length != 64 ||
        RegExp(r'[^a-f0-9]').hasMatch(sourceSha256) ||
        chunks.length != 6 || participants.length > 4000 ||
        glossary.length > 4000) {
      throw StateError('LAB_AI_WHOLE_SOURCE_OR_CONTEXT_HOLD');
    }
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      if (c.index != i || c.text.trim().isEmpty ||
          c.text.length > 10500 || c.coreStartMs < 0 ||
          c.coreEndMs <= c.coreStartMs || c.wireStartMs < 0 ||
          c.wireStartMs > c.coreStartMs ||
          c.wireEndMs < c.coreEndMs ||
          (i == 0 && c.coreStartMs != 0) ||
          (i > 0 && c.coreStartMs != chunks[i - 1].coreEndMs)) {
        throw StateError('LAB_AI_WHOLE_CHUNK_CLOCK_HOLD');
      }
    }
    final text = jsonEncode({
      'source_sha256': sourceSha256,
      'mode': 'WHOLE_TRANSCRIPT_TEXT_ONLY',
      'time_alignment': 'SEPARATE_LOCAL_FUTURE_GATE',
      'chunks': [
        for (final c in chunks) {
          'chunk_index': c.index + 1,
          'core_start_ms': c.coreStartMs,
          'core_end_ms': c.coreEndMs,
          'wire_start_ms': c.wireStartMs,
          'wire_end_ms': c.wireEndMs,
          'overlap_before_ms': c.overlapBeforeMs,
          'raw_transcript_text': c.text,
        },
      ],
      'known_participants_context_only': participants,
      'glossary_context_only': glossary,
    });
    if (text.length > maxWholeRequestChars) {
      throw StateError('LAB_AI_WHOLE_INPUT_LIMIT_HOLD');
    }
    return text;
  }

  /// Exactly one user-approved Gemini text inference across six STT chunks.
  Future<String> reviewWholeTranscript({
    required String apiKey,
    required String model,
    required String sourceSha256,
    required List<LabSegmentedTextChunk> chunks,
    required String participants,
    required String glossary,
  }) {
    final input = checkWholeInput(
      sourceSha256: sourceSha256, chunks: chunks,
      participants: participants, glossary: glossary,
    );
    return _generate(
      apiKey: apiKey, model: model, maxOutputTokens: 8192,
      inputLimit: maxWholeRequestChars, wholeReview: true,
      text: input,
      systemPrompt: '這六段為同一場會議的 Groq STT 原文。請依順序'
          '整合成完整連續的繁體中文逐字稿，不可摘要或杜撰。'
          '相鄰段音訊約有兩秒重疊，以實際 overlap_before_ms 為準；'
          '只能移除能確認的重複內容，不確定就保留並標記'
          '[重疊待複核]。參考名單和專業詞彙修正確定的字詞，'
          '無法從語音確認的怪異外語或非會議內容應原樣保留並標記'
          '[辨識疑點待錄音核對]。不可猜測來源錄音未出現的內容。'
          '不要產生時間戳；另由本機對照原 Raw。'
          '只輸出一個 transcript 字串欄位的合法 JSON 物件。'
          '輸出為待人工複核的草稿而不是驗證過的原文。',
    );
  }
  /// Exactly one user-authorized chunk. Only its own text and bounded
  /// neighbor context; do not delete ambiguous overlap or invent content.
  Future<String> reviewChunk({
    required String apiKey,
    required String model,
    required LabSegmentedTextChunk chunk,
    required String previousTail,
    required String nextHead,
    required String participants,
    required String glossary,
  }) {
    if (participants.length > 4000 || glossary.length > 4000 ||
        previousTail.length > 600 || nextHead.length > 600 ||
        chunk.text.isEmpty || chunk.text.length > 10500) {
      throw StateError('LAB_AI_CHUNK_LIMIT_HOLD');
    }
    final input = jsonEncode({
      'chunk_index': chunk.index + 1,
      'core_start_ms': chunk.coreStartMs,
      'core_end_ms': chunk.coreEndMs,
      'wire_start_ms': chunk.wireStartMs,
      'wire_end_ms': chunk.wireEndMs,
      'overlap_before_ms': chunk.overlapBeforeMs,
      'previous_tail_context_only': previousTail,
      'current_chunk_source_text': chunk.text,
      'next_head_context_only': nextHead,
      'known_participants_context_only': participants,
      'glossary_context_only': glossary,
    });
    if (input.length > maxRequestChars) {
      throw StateError('LAB_AI_CHUNK_LIMIT_HOLD');
    }
    return _generate(
      apiKey: apiKey,
      model: model,
      maxOutputTokens: 8192,
      systemPrompt: '你正在產生多段 STT 的可人工複核草稿。'
          '相鄰音訊可能約有兩秒重疊，請依實際 overlap_before_ms 判斷。'
          '只輸出當前 Chunk 的修訂文字，不輸出上下段上下文。'
          '僅刪除可明確確認的重複字句，不確定就保留並標示[重疊待複核]。'
          '依用戶提供的與會者、專業字典修正明確錯字和標點。'
          '發現奇怪的外語、食譜、雜音等疑似辨識幻覺時，'
          '保留來源並標示[辨識疑點待錄音核對]，不可憑空修正成會議內容。'
          '不得捏造發言、推測說話者或自行補音，'
          '不要把 AI 草稿宣稱為已驗證原文。',
      text: input,
    );
  }
}
