import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'lab_audio_pipeline.dart';
import 'lab_groq_free_durable_journal.dart';
import 'lab_groq_raw_receipt_store.dart';

/// Only one user-approved physical chunk is sent per call.
/// No background queue, retry, fallback, plan upgrade, or API-key persistence.
final class LabGroqSttSendResult {
  const LabGroqSttSendResult({
    required this.httpStatus,
    required this.attemptId,
    this.rawReceipt,
  });

  final int httpStatus;
  final String attemptId;
  final LabGroqRawReceipt? rawReceipt;
}

/// Real Groq audio/transcriptions streaming transport (Free only).
/// The default endpoint is fixed HTTPS. Loopback is supported solely to
/// exercise the full HTTP protocol with an in-process, offline test server.
final class LabGroqFreeSttTransport {
  LabGroqFreeSttTransport()
      : _endpoint = Uri.https(
            'api.groq.com', '/openai/v1/audio/transcriptions');

  LabGroqFreeSttTransport.forLoopbackTest(Uri endpoint)
      : _endpoint = endpoint {
    if (endpoint.scheme != 'http' ||
        !const {'127.0.0.1', 'localhost', '::1'}
            .contains(endpoint.host)) {
      throw StateError('GROQ_LOOPBACK_ENDPOINT_REQUIRED');
    }
  }

  final Uri _endpoint;
  static const int _maxWireBytes = 20000000;
  static const int _maxRawBytes = LabGroqRawReceiptStore.maxRawBytes;
  static final _tokenShape = RegExp(r'^[^\s\r\n]{12,512}$');

  /// Required call order: check source and real wire bytes/SHA, persist
  /// consent-bound PREPARED, persist UNKNOWN, then open the HTTP connection.
  /// If anything fails after UNKNOWN, it stays UNKNOWN/RAW_PENDING on disk.
  Future<LabGroqSttSendResult> sendOne({
    required String attemptId,
    required File sourceFile,
    required String expectedSourceSha256,
    required LabStagedChunk chunk,
    required String apiKey,
    required String model,
    required bool explicitConsent,
    required LabGroqFreeDurableJournal journal,
    required LabGroqRawReceiptStore rawStore,
    String? language,
    void Function(String, Map<String, Object?>)? onDiagnostic,
  }) async {
    if (!explicitConsent) throw StateError('GROQ_CHUNK_CONSENT_REQUIRED');
    if (!_tokenShape.hasMatch(apiKey)) {
      throw StateError('GROQ_KEY_INVALID_OR_MISSING');
    }
    if (language != null &&
        !RegExp(r'^[a-z]{2}$').hasMatch(language)) {
      throw StateError('GROQ_LANGUAGE_INVALID');
    }
    if (!journal.canStartNewManualChunk(DateTime.now().toUtc())) {
      throw StateError('GROQ_JOURNAL_GATE_HOLD');
    }
    final actualBytes = await chunk.file.length();
    if (actualBytes != chunk.byteCount ||
        actualBytes <= 0 || actualBytes >= _maxWireBytes) {
      throw StateError('GROQ_WIRE_BYTES_CHANGED');
    }
    final actualSourceSha = await LabAudioPipeline.digest(sourceFile);
    if (actualSourceSha != expectedSourceSha256) {
      throw StateError('GROQ_SOURCE_SHA_CHANGED');
    }
    final actualWireSha = await LabAudioPipeline.digest(chunk.file);
    if (actualWireSha != chunk.sha256Hex) {
      throw StateError('GROQ_WIRE_SHA_CHANGED');
    }
    final audioMs = chunk.wireEndMs - chunk.wireStartMs;
    final consentedAt = DateTime.now().toUtc();
    // Fingerprint of an explicitly entered key is not an account verification
    // and cannot reconstruct the key; the secret itself never reaches disk.
    final scopeFingerprint =
        sha256.convert(utf8.encode(apiKey)).toString();
    await journal.prepare(
      attemptId: attemptId,
      sourceSha256: actualSourceSha,
      wireSha256: actualWireSha,
      accountScopeSha256: scopeFingerprint,
      model: model,
      wireBytes: actualBytes,
      wireAudioMs: audioMs,
      consentedAtUtc: consentedAt,
      explicitConsent: true,
    );
    // MUST complete durable UNKNOWN before any socket connects.
    await journal.armBeforeSend(attemptId);

    final client = HttpClient()
      ..autoUncompress = true
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.postUrl(_endpoint)
          .timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ' + apiKey);
      final random = Random.secure();
      final boundary = 'labgroq' +
          List.generate(12, (_) =>
              random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      request.headers.set(HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=' + boundary);
      final fields = StringBuffer();
      void field(String name, String value) {
        fields.write('--' + boundary + '\r\n');
        fields.write('Content-Disposition: form-data; name="' +
            name + '"\r\n\r\n');
        fields.write(value + '\r\n');
      }
      field('model', model);
      field('response_format', 'verbose_json');
      field('timestamp_granularities[]', 'segment');
      if (language != null) field('language', language);
      fields.write('--' + boundary + '\r\n');
      fields.write('Content-Disposition: form-data; name="file"; ' +
          'filename="chunk.wav"\r\n');
      fields.write('Content-Type: audio/wav\r\n\r\n');
      final prefix = utf8.encode(fields.toString());
      final suffix = utf8.encode('\r\n--' + boundary + '--\r\n');
      request.contentLength = prefix.length + actualBytes + suffix.length;
      request.add(prefix);
      await request.addStream(chunk.file.openRead())
          .timeout(const Duration(minutes: 2));
      request.add(suffix);

      final response = await request.close()
          .timeout(const Duration(minutes: 4));
      final headers = <String, String>{
        if (response.headers.value('retry-after') != null)
          'retry-after': response.headers.value('retry-after')!,
        if (response.headers.value(
            'x-ratelimit-remaining-requests') != null)
          'x-ratelimit-remaining-requests': response.headers.value(
              'x-ratelimit-remaining-requests')!,
      };
      // Record the server status before reading a potentially incomplete body.
      await journal.observeHttp(
        attemptId: attemptId,
        statusCode: response.statusCode,
        receivedAtUtc: DateTime.now().toUtc(),
        headers: headers,
      );
      final encoding = response.headers.value(
          HttpHeaders.contentEncodingHeader);
      // Only fixed metadata values, never response body / audio / API key.
      onDiagnostic?.call('GROQ_HTTP_STATUS', <String, Object?>{
        'status': response.statusCode,
        'encoding': encoding == null ? 'IDENTITY'
            : encoding.toLowerCase() == 'gzip' ? 'GZIP' : 'OTHER',
      });
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Deliberately do not persist error bodies (could contain echo data).
        return LabGroqSttSendResult(
            httpStatus: response.statusCode, attemptId: attemptId);
      }
      final bytes = <int>[];
      await for (final packet in response.timeout(
          const Duration(seconds: 90))) {
        if (bytes.length + packet.length > _maxRawBytes) {
          throw StateError('GROQ_RAW_BYTES_LIMIT_HOLD');
        }
        bytes.addAll(packet);
      }
      onDiagnostic?.call('GROQ_RAW_BODY_RECEIVED',
          <String, Object?>{'bytes': bytes.length});
      final receipt = await rawStore.writeOnce(attemptId, bytes);
      onDiagnostic?.call('GROQ_RAW_VALIDATED_AND_STORED',
          <String, Object?>{'bytes': receipt.byteCount});
      await journal.markRawSaved(
        attemptId: attemptId,
        rawSha256: receipt.sha256Hex,
        rawBytes: receipt.byteCount,
      );
      return LabGroqSttSendResult(
        httpStatus: response.statusCode,
        attemptId: attemptId,
        rawReceipt: receipt,
      );
    } on TimeoutException {
      throw StateError('GROQ_HTTP_TIMEOUT_HOLD');
    } on SocketException {
      throw StateError('GROQ_HTTP_SOCKET_HOLD');
    } on HttpException {
      throw StateError('GROQ_HTTP_STREAM_HOLD');
    } finally {
      client.close(force: true);
    }
  }
}
