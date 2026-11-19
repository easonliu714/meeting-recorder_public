import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_groq_free_durable_journal.dart';
import 'package:groq_stt_lab/lab_groq_free_stt_transport.dart';
import 'package:groq_stt_lab/lab_groq_raw_receipt_store.dart';

void main() {
  late Directory dir;
  late File source;
  late File wire;
  late String sourceSha;
  late LabStagedChunk chunk;
  late LabGroqFreeDurableJournal journal;
  late LabGroqRawReceiptStore receipts;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lab_groq_http_loopback_');
    source = File(dir.path + '/source.wav');
    wire = File(dir.path + '/chunk.wav');
    await source.writeAsBytes(utf8.encode('RIFF-test-source'), flush: true);
    await wire.writeAsBytes(utf8.encode('RIFF-test-chunk'), flush: true);
    sourceSha = sha256.convert(await source.readAsBytes()).toString();
    chunk = LabStagedChunk(
      file: wire,
      byteCount: await wire.length(),
      sha256Hex: sha256.convert(await wire.readAsBytes()).toString(),
      coreStartMs: 0, coreEndMs: 1000,
      wireStartMs: 0, wireEndMs: 1000,
    );
    journal = await LabGroqFreeDurableJournal.open(
        File(dir.path + '/journal.jsonl'));
    receipts = LabGroqRawReceiptStore(Directory(dir.path + '/receipts'));
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<LabGroqSttSendResult> call(
      Uri uri, {String id = 'attempt1',
        String? sourceHash, bool consent = true,
        String model = 'whisper-large-v3-turbo',
        void Function(String, Map<String, Object?>)? onDiagnostic}) {
    return LabGroqFreeSttTransport.forLoopbackTest(uri).sendOne(
      attemptId: id, sourceFile: source,
      expectedSourceSha256: sourceHash ?? sourceSha,
      chunk: chunk, apiKey: 'PUBLIC_LAB_TEST_TOKEN_1234567890',
      model: model, explicitConsent: consent,
      journal: journal, rawStore: receipts,
      onDiagnostic: onDiagnostic,
    );
  }

  test('real multipart loopback 200 stores immutable raw and releases gate', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final handled = server.first.then((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/openai/v1/audio/transcriptions');
      expect(request.headers.value('authorization'),
          'Bearer PUBLIC_LAB_TEST_TOKEN_1234567890');
      final body = await utf8.decodeStream(request);
      expect(body, contains('name="model"'));
      expect(body, contains('whisper-large-v3-turbo'));
      expect(body, contains('verbose_json'));
      expect(body, contains('name="file"'));
      expect(body, contains('RIFF-test-chunk'));
      final json = jsonEncode({
        'text': 'hello from loopback',
        'language': 'en',
        'segments': [
          {'start': 0.0, 'end': 0.8, 'text': 'hello from loopback'}
        ],
      });
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json);
      await request.response.close();
    });
    try {
      final result = await call(Uri.parse(
          'http://127.0.0.1:' + server.port.toString() +
          '/openai/v1/audio/transcriptions'));
      await handled;
      expect(result.httpStatus, 200);
      expect(result.rawReceipt, isNotNull);
      expect(journal.phaseOf('attempt1'), 'RAW_SAVED');
      final reread = await LabGroqFreeDurableJournal.open(
          File(dir.path + '/journal.jsonl'));
      expect(reread.successfulResponses, 1);
      expect(reread.phaseOf('attempt1'), 'RAW_SAVED');
      expect(reread.canStartNewManualChunk(DateTime.now().toUtc()), isTrue);
      expect(reread.mayAutoRetry, isFalse);
      final raw = await receipts.readVerified(
          'attempt1', result.rawReceipt!.sha256Hex);
      expect(jsonDecode(raw)['text'], 'hello from loopback');
      await expectLater(
          receipts.writeOnce('attempt1', utf8.encode(raw)), throwsStateError);
      final log = await File(dir.path + '/journal.jsonl').readAsString();
      expect(log, isNot(contains('PUBLIC_LAB_TEST_TOKEN_1234567890')));
      expect(log, isNot(contains('hello from loopback')));
    } finally {
      await server.close(force: true);
    }
  });

  test('gzip 200 verbose_json decompresses and logs only safe metadata', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final events = <String>[];
    final handled = server.first.then((request) async {
      await request.drain<void>();
      final payload = jsonEncode({
        'text': 'private fixture',
        'segments': [{'start': 0.0, 'end': 0.8, 'text': 'private fixture'}],
      });
      request.response.statusCode = 200;
      request.response.headers.set('content-encoding', 'gzip');
      request.response.add(gzip.encode(utf8.encode(payload)));
      await request.response.close();
    });
    try {
      final result = await call(Uri.parse(
          'http://127.0.0.1:' + server.port.toString() +
          '/openai/v1/audio/transcriptions'),
          onDiagnostic: (event, fields) {
            events.add(event + ' ' + fields.toString());
          });
      await handled;
      expect(result.rawReceipt, isNotNull);
      expect(journal.phaseOf('attempt1'), 'RAW_SAVED');
      final raw = await receipts.readVerified(
          'attempt1', result.rawReceipt!.sha256Hex);
      expect(jsonDecode(raw)['text'], 'private fixture');
      expect(events.join('\n'), contains('encoding: GZIP'));
      expect(events.join('\n'), contains('GROQ_RAW_BODY_RECEIVED'));
      expect(events.join('\n'), isNot(contains('private fixture')));
      expect(events.join('\n'), isNot(contains('PUBLIC_LAB_TEST_TOKEN_1234567890')));
    } finally {
      await server.close(force: true);
    }
  });

  test('200 malformed JSON retains original evidence and RAW_PENDING', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final reply = utf8.encode('{malformed-provider-json');
    final handled = server.first.then((request) async {
      await request.drain<void>();
      request.response.statusCode = 200;
      request.response.add(reply);
      await request.response.close();
    });
    try {
      final uri = Uri.parse(
          'http://127.0.0.1:' + server.port.toString() +
          '/openai/v1/audio/transcriptions');
      await expectLater(call(uri), throwsA(isA<StateError>()
          .having((e) => e.message, 'message', 'GROQ_RAW_JSON_HOLD')));
      await handled;
      final reread = await LabGroqFreeDurableJournal.open(
          File(dir.path + '/journal.jsonl'));
      expect(reread.phaseOf('attempt1'), 'RAW_PENDING');
      expect(reread.canStartNewManualChunk(DateTime.now().toUtc()), isFalse);
      final persisted = File(dir.path + '/receipts/attempt1.verbose.json');
      expect(await persisted.exists(), isTrue);
      expect(await persisted.readAsBytes(), reply);
      expect(reread.mayAutoRetry, isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('real loopback 429 stores cooldown and never sends again', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var seen = 0;
    final handled = server.first.then((request) async {
      seen++;
      await request.drain<void>();
      request.response.statusCode = 429;
      request.response.headers.set('retry-after', '90');
      request.response.headers.set(
          'x-ratelimit-remaining-requests', '0');
      await request.response.close();
    });
    try {
      final uri = Uri.parse(
          'http://127.0.0.1:' + server.port.toString() +
          '/openai/v1/audio/transcriptions');
      final result = await call(uri);
      await handled;
      expect(result.httpStatus, 429);
      expect(result.rawReceipt, isNull);
      expect(journal.rateLimitedResponses, 1);
      expect(journal.cooldownSeconds(DateTime.now().toUtc()),
          greaterThan(0));
      expect(journal.canStartNewManualChunk(DateTime.now().toUtc()), isFalse);
      await expectLater(call(uri), throwsStateError);
      expect(seen, 1);
    } finally {
      await server.close(force: true);
    }
  });

  test('server disconnect cannot reopen UNKNOWN or RAW_PENDING for retry', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final handled = server.first.then((request) async {
      await request.drain<void>();
      request.response.detachSocket().then((socket) => socket.destroy());
    });
    try {
      final uri = Uri.parse(
          'http://127.0.0.1:' + server.port.toString() +
          '/openai/v1/audio/transcriptions');
      await expectLater(call(uri), throwsA(anything));
      await handled;
      final reread = await LabGroqFreeDurableJournal.open(
          File(dir.path + '/journal.jsonl'));
      // Dart HttpServer.detachSocket can emit the default 200 headers before
      // destroying the socket; then the correct fail-closed phase is
      // RAW_PENDING rather than SUBMIT_UNKNOWN (no complete raw receipt).
      expect(reread.phaseOf('attempt1'),
          anyOf('SUBMIT_UNKNOWN', 'RAW_PENDING'));
      expect(reread.savedRawSha('attempt1'), isNull);
      expect(reread.canStartNewManualChunk(DateTime.now().toUtc()), isFalse);
      await expectLater(call(uri), throwsStateError);
    } finally {
      await server.close(force: true);
    }
  });

  test('wrong SHA and absent consent never reach HTTP socket', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final uri = Uri.parse(
          'http://127.0.0.1:' + server.port.toString() +
          '/openai/v1/audio/transcriptions');
      await expectLater(call(uri, consent: false), throwsStateError);
      await expectLater(call(uri, sourceHash: '0' * 64),
          throwsStateError);
      expect(await File(dir.path + '/journal.jsonl').exists(), isFalse);
      expect(journal.attemptCount, 0);
    } finally {
      await server.close(force: true);
    }
  });

  test('loopback URL refuses nonlocal and HTTPS replacement', () {
    expect(() => LabGroqFreeSttTransport.forLoopbackTest(
        Uri.parse('https://evil.example/audio/transcriptions')),
        throwsStateError);
    expect(() => LabGroqFreeSttTransport.forLoopbackTest(
        Uri.parse('http://evil.example/audio/transcriptions')),
        throwsStateError);
  });

  test('2xx raw saved before crash is reconciled without new HTTP', () async {
    await journal.prepare(
      attemptId: 'attempt1', sourceSha256: sourceSha,
      wireSha256: chunk.sha256Hex,
      accountScopeSha256: 'c' * 64, model: 'whisper-large-v3',
      wireBytes: chunk.byteCount, wireAudioMs: 1000,
      consentedAtUtc: DateTime.now().toUtc(), explicitConsent: true,
    );
    await journal.armBeforeSend('attempt1');
    await journal.observeHttp(
      attemptId: 'attempt1', statusCode: 200,
      receivedAtUtc: DateTime.now().toUtc(),
    );
    final raw = utf8.encode(jsonEncode({
      'text': 'accepted',
      'segments': [
        {'start': 0, 'end': 0.7, 'text': 'accepted'}
      ],
    }));
    await receipts.writeOnce('attempt1', raw);
    final restarted = await LabGroqFreeDurableJournal.open(
        File(dir.path + '/journal.jsonl'));
    expect(restarted.phaseOf('attempt1'), 'RAW_PENDING');
    final evidence = await receipts.inspectComplete('attempt1');
    expect(evidence, isNotNull);
    await restarted.markRawSaved(
        attemptId: 'attempt1',
        rawSha256: evidence!.sha256Hex,
        rawBytes: evidence.byteCount);
    final restored = await LabGroqFreeDurableJournal.open(
        File(dir.path + '/journal.jsonl'));
    expect(restored.phaseOf('attempt1'), 'RAW_SAVED');
    expect(restored.attemptForWire(sourceSha, chunk.sha256Hex), 'attempt1');
    expect(restored.canStartNewManualChunk(DateTime.now().toUtc()), isTrue);
    await expectLater(
      restored.prepare(
        attemptId: 'attempt2', sourceSha256: sourceSha,
        wireSha256: chunk.sha256Hex,
        accountScopeSha256: 'c' * 64, model: 'whisper-large-v3',
        wireBytes: chunk.byteCount, wireAudioMs: 1000,
        consentedAtUtc: DateTime.now().toUtc(), explicitConsent: true,
      ),
      throwsStateError,
    );
  });

  test('raw tamper fails SHA readback and preserves evidence', () async {
    final original = utf8.encode(jsonEncode({
      'text': 'safe',
      'segments': [{'start': 0, 'end': 0.1, 'text': 'safe'}],
    }));
    final receipt = await receipts.writeOnce('attempt1', original);
    await receipt.file.writeAsString('changed');
    await expectLater(
        receipts.readVerified('attempt1', receipt.sha256Hex),
        throwsStateError);
    expect(await receipt.file.readAsString(), 'changed');
  });
}
