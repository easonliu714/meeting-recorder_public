import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_groq_free_durable_journal.dart';

void main() {
  final clock = DateTime.utc(2026, 11, 17, 10, 0, 0);
  late Directory sandbox;
  late File ledgerFile;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('lab_free_journal_test_');
    ledgerFile = File(
        sandbox.path + Platform.pathSeparator + 'events.jsonl');
  });

  tearDown(() async {
    // Test-only generated temporary files; never user recordings or app data.
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<void> prepare(LabGroqFreeDurableJournal journal,
      {String id = 'chunk1', bool consent = true,
       DateTime? at, String model = 'whisper-large-v3-turbo',
       int bytes = 19261484, String? wireSha}) async {
    await journal.prepare(
      attemptId: id, sourceSha256: 'a' * 64, wireSha256: wireSha ?? 'b' * 64,
      accountScopeSha256: 'c' * 64, model: model, wireBytes: bytes,
      wireAudioMs: 601920, consentedAtUtc: at ?? clock,
      explicitConsent: consent,
    );
  }

  test('restart preserves UNKNOWN before any HTTP; never auto resends', () async {
    final first = await LabGroqFreeDurableJournal.open(ledgerFile);
    expect(first.canStartNewManualChunk(clock), isTrue);
    await prepare(first);
    expect(first.statusAt(clock), 'PREPARED_REQUIRES_USER_ACTION');
    expect(first.observedAttempts, 0);
    await first.armBeforeSend('chunk1');
    expect(first.phaseOf('chunk1'), 'SUBMIT_UNKNOWN');
    expect(first.observedAttempts, 1);
    final disk = await ledgerFile.readAsString();
    expect(disk, contains('SUBMIT_UNKNOWN'));
    expect(disk, isNot(contains('api_key')));
    expect(disk, isNot(contains('transcript')));
    expect(disk, isNot(contains('gsk_')));

    final restarted = await LabGroqFreeDurableJournal.open(ledgerFile);
    expect(restarted.statusAt(clock.add(const Duration(days: 10))),
        'SUBMIT_UNKNOWN');
    expect(restarted.attemptCount, 1);
    expect(restarted.observedAttempts, 1);
    expect(restarted.mayAutoRetry, isFalse);
    expect(restarted.canStartNewManualChunk(clock), isFalse);
    await expectLater(restarted.armBeforeSend('chunk1'),
        throwsStateError);
    await expectLater(prepare(restarted), throwsStateError);
  });

  test('429 cooldown and observed usage survive restart, RPD 0 is advisory', () async {
    final first = await LabGroqFreeDurableJournal.open(ledgerFile);
    await prepare(first);
    await first.armBeforeSend('chunk1');
    await first.observeHttp(
      attemptId: 'chunk1', statusCode: 429, receivedAtUtc: clock,
      headers: const {
        'Retry-After': '90',
        'X-Ratelimit-Remaining-Requests': '0',
      },
    );
    final restarted = await LabGroqFreeDurableJournal.open(ledgerFile);
    expect(restarted.rateLimitedResponses, 1);
    expect(restarted.observedAttempts, 1);
    expect(restarted.attemptedAudioMs, 601920);
    expect(restarted.attemptedBytes, 19261484);
    expect(restarted.remainingRequestsPerDay, 0);
    expect(restarted.cooldownSeconds(clock), 90);
    expect(restarted.canStartNewManualChunk(
        clock.add(const Duration(seconds: 89))), isFalse);
    expect(restarted.canStartNewManualChunk(
        clock.add(const Duration(seconds: 90))), isTrue);
    expect(restarted.mayAutoRetry, isFalse);
    // A new Chunk has a distinct physical wire SHA. The old Chunk remains
    // protected against retransmission after cooldown.
    await prepare(restarted, id: 'chunk2', wireSha: 'd' * 64,
        at: clock.add(const Duration(seconds: 90)));
    expect(restarted.attemptCount, 2);
  });

  test('HTTP 2xx requires an immutable raw receipt before next chunk', () async {
    final journal = await LabGroqFreeDurableJournal.open(ledgerFile);
    await prepare(journal);
    await journal.armBeforeSend('chunk1');
    await journal.observeHttp(
      attemptId: 'chunk1', statusCode: 200, receivedAtUtc: clock,
      headers: const {'x-ratelimit-remaining-requests': '0'},
    );
    final restarted = await LabGroqFreeDurableJournal.open(ledgerFile);
    expect(restarted.successfulResponses, 1);
    expect(restarted.acceptedAudioMs, 601920);
    expect(restarted.phaseOf('chunk1'), 'RAW_PENDING');
    expect(restarted.statusAt(clock), 'PROVIDER_RAW_RECEIPT_PENDING');
    expect(restarted.canStartNewManualChunk(clock), isFalse);
    await expectLater(restarted.observeHttp(
      attemptId: 'chunk1', statusCode: 200, receivedAtUtc: clock,
    ), throwsStateError);
  });

  test('413 and 5xx STOP state never clears on restart', () async {
    for (final status in [413, 401, 503]) {
      final file = File(
          sandbox.path + Platform.pathSeparator + 'errors_$status.jsonl');
      final journal = await LabGroqFreeDurableJournal.open(file);
      await prepare(journal);
      await journal.armBeforeSend('chunk1');
      await journal.observeHttp(
          attemptId: 'chunk1', statusCode: status,
          receivedAtUtc: clock);
      final restarted = await LabGroqFreeDurableJournal.open(file);
      expect(restarted.failedResponses, 1);
      expect(restarted.statusAt(clock), status == 413
          ? 'WIRE_TOO_LARGE_STOP' : 'HTTP_FAILURE_MANUAL_REVIEW');
      expect(restarted.canStartNewManualChunk(
          clock.add(const Duration(days: 10))), isFalse);
    }
  });

  test('429 missing or invalid retry-after holds after restart', () async {
    for (final header in <String>['', 'bad', '-1', '999999999']) {
      final file = File(sandbox.path + Platform.pathSeparator +
          'retry_' + header.replaceAll('-', '_') + '.jsonl');
      final journal = await LabGroqFreeDurableJournal.open(file);
      await prepare(journal);
      await journal.armBeforeSend('chunk1');
      await journal.observeHttp(
        attemptId: 'chunk1', statusCode: 429, receivedAtUtc: clock,
        headers: {'retry-after': header},
      );
      final restarted = await LabGroqFreeDurableJournal.open(file);
      expect(restarted.statusAt(clock), 'RETRY_AFTER_NOT_VERIFIED');
      expect(restarted.canStartNewManualChunk(
          clock.add(const Duration(days: 10))), isFalse);
    }
  });

  test('consent, model, max wire bytes and provenance gate are enforced', () async {
    final journal = await LabGroqFreeDurableJournal.open(ledgerFile);
    await expectLater(prepare(journal, consent: false), throwsStateError);
    await expectLater(prepare(journal, model: 'paid-model'), throwsStateError);
    await expectLater(prepare(journal, bytes: 20000000), throwsStateError);
    await expectLater(prepare(journal, bytes: 20000001), throwsStateError);
    await expectLater(journal.armBeforeSend('nonexistent'), throwsStateError);
    await expectLater(journal.observeHttp(
        attemptId: 'nonexistent', statusCode: 200,
        receivedAtUtc: clock), throwsStateError);
    expect(await ledgerFile.exists(), isFalse);
    expect(journal.observedAttempts, 0);
  });

  test('same physical wire cannot be uploaded under new attempt after restart', () async {
    final journal = await LabGroqFreeDurableJournal.open(ledgerFile);
    await prepare(journal);
    await journal.armBeforeSend('chunk1');
    await journal.observeHttp(
      attemptId: 'chunk1', statusCode: 200, receivedAtUtc: clock,
    );
    await journal.markRawSaved(
      attemptId: 'chunk1',
      rawSha256: 'd' * 64, rawBytes: 256,
    );
    final restarted = await LabGroqFreeDurableJournal.open(ledgerFile);
    expect(restarted.phaseOf('chunk1'), 'RAW_SAVED');
    expect(restarted.attemptForWire('a' * 64, 'b' * 64), 'chunk1');
    expect(restarted.savedRawSha('chunk1'), 'd' * 64);
    expect(restarted.canStartNewManualChunk(clock), isTrue);
    await expectLater(prepare(restarted, id: 'chunk2'), throwsStateError);
    expect(restarted.attemptCount, 1);
    expect(restarted.mayAutoRetry, isFalse);
  });

  test('crash after PREPARED does not become UNKNOWN automatically', () async {
    final first = await LabGroqFreeDurableJournal.open(ledgerFile);
    await prepare(first);
    final restarted = await LabGroqFreeDurableJournal.open(ledgerFile);
    expect(restarted.statusAt(clock), 'PREPARED_REQUIRES_USER_ACTION');
    expect(restarted.observedAttempts, 0);
    expect(restarted.canStartNewManualChunk(clock), isFalse);
  });

  test('truncated journal fails closed without rewriting user evidence', () async {
    final first = await LabGroqFreeDurableJournal.open(ledgerFile);
    await prepare(first);
    await ledgerFile.writeAsString('{"broken":', mode: FileMode.append);
    final sizeBefore = await ledgerFile.length();
    await expectLater(LabGroqFreeDurableJournal.open(ledgerFile),
        throwsStateError);
    expect(await ledgerFile.length(), sizeBefore);
  });

  test('digest mutation fails closed and preserves unchanged bytes', () async {
    final first = await LabGroqFreeDurableJournal.open(ledgerFile);
    await prepare(first);
    final body = await ledgerFile.readAsString();
    final damaged = body.replaceFirst('whisper-large-v3-turbo', 'whisper-large-v3-xxxxx');
    await ledgerFile.writeAsString(damaged, flush: true);
    await expectLater(LabGroqFreeDurableJournal.open(ledgerFile),
        throwsStateError);
    expect(await ledgerFile.readAsString(), damaged);
  });

  test('writer detects external append and refuses to race', () async {
    final first = await LabGroqFreeDurableJournal.open(ledgerFile);
    await prepare(first);
    await ledgerFile.writeAsString('junk\n', mode: FileMode.append);
    await expectLater(first.armBeforeSend('chunk1'), throwsStateError);
    expect(first.statusAt(clock), 'FREE_JOURNAL_WRITE_HOLD');
    expect(first.mayAutoRetry, isFalse);
  });
}
