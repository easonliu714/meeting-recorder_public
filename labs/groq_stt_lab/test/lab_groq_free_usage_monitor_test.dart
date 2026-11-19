import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_groq_free_usage_monitor.dart';

void main() {
  final at = DateTime.utc(2026, 11, 17, 9, 0, 0);

  test('Free counts observed successes; RPD=0 is informational, not preflight', () {
    final monitor = LabGroqFreeUsageMonitor();
    expect(monitor.recordHttp(
      attemptId: 'chunk-1', statusCode: 200, wireBytes: 19261484,
      wireAudioMs: 601920, observedAt: at,
      headers: {'X-RateLimit-Remaining-Requests': '0'},
    ), isTrue);
    expect(monitor.observedAttempts, 1);
    expect(monitor.successfulResponses, 1);
    expect(monitor.attemptedBytes, 19261484);
    expect(monitor.attemptedWireAudioMs, 601920);
    expect(monitor.acceptedWireAudioMs, 601920);
    expect(monitor.remainingRequestsPerDay, 0);
    expect(monitor.canOfferNewManualSubmission(at), isTrue);
    expect(monitor.mayAutoRetry, isFalse);
    expect(monitor.recordHttp(
      attemptId: 'chunk-1', statusCode: 200, wireBytes: 19261484,
      wireAudioMs: 601920, observedAt: at,
    ), isFalse);
    expect(monitor.observedAttempts, 1);
  });

  test('429 uses server Retry-After and cannot auto-resend', () {
    final monitor = LabGroqFreeUsageMonitor();
    expect(monitor.recordHttp(
      attemptId: 'chunk-2', statusCode: 429, wireBytes: 19261484,
      wireAudioMs: 601920, observedAt: at,
      headers: {'ReTrY-AfTeR': '90', 'x-ratelimit-remaining-requests': '0'},
    ), isTrue);
    expect(monitor.rateLimitedResponses, 1);
    expect(monitor.successfulResponses, 0);
    expect(monitor.cooldownSeconds(at), 90);
    expect(monitor.statusAt(at), 'COOLING_DOWN');
    expect(monitor.canOfferNewManualSubmission(at.add(const Duration(seconds: 89))), isFalse);
    expect(monitor.canOfferNewManualSubmission(at.add(const Duration(seconds: 90))), isTrue);
    expect(monitor.mayAutoRetry, isFalse);
  });

  test('429 missing or malformed retry-after remains manual hold', () {
    for (final headers in <Map<String, String>>[
      <String, String>{},
      <String, String>{'retry-after': 'NaN'},
      <String, String>{'retry-after': '-1'},
      <String, String>{'retry-after': '9999999'},
    ]) {
      final monitor = LabGroqFreeUsageMonitor();
      monitor.recordHttp(
        attemptId: 'attempt1', statusCode: 429, wireBytes: 100,
        wireAudioMs: 1000, observedAt: at, headers: headers,
      );
      expect(monitor.statusAt(at), 'RETRY_AFTER_NOT_VERIFIED');
      expect(monitor.canOfferNewManualSubmission(at.add(const Duration(days: 3))), isFalse);
    }
  });

  test('429 can extend but never shorten existing cooldown', () {
    final monitor = LabGroqFreeUsageMonitor();
    monitor.recordHttp(
      attemptId: 'attempt1', statusCode: 429, wireBytes: 100,
      wireAudioMs: 1000, observedAt: at,
      headers: {'retry-after': '120'},
    );
    monitor.recordHttp(
      attemptId: 'attempt2', statusCode: 429, wireBytes: 100,
      wireAudioMs: 1000, observedAt: at.add(const Duration(seconds: 10)),
      headers: {'retry-after': '20'},
    );
    expect(monitor.cooldownSeconds(at), 120);
    expect(monitor.observedAttempts, 2);
  });

  test('413 stops batch; 5xx also stops and never retries', () {
    for (final status in [413, 401, 500, 503]) {
      final monitor = LabGroqFreeUsageMonitor();
      monitor.recordHttp(
        attemptId: 'a1', statusCode: status, wireBytes: 800,
        wireAudioMs: 10000, observedAt: at,
      );
      expect(monitor.failedResponses, 1);
      expect(monitor.canOfferNewManualSubmission(at.add(const Duration(days: 1))), isFalse);
      expect(monitor.holdReason, status == 413
          ? 'WIRE_TOO_LARGE_STOP' : 'HTTP_FAILURE_MANUAL_REVIEW');
      expect(monitor.mayAutoRetry, isFalse);
    }
  });

  test('network uncertainty is SUBMIT_UNKNOWN and idempotent', () {
    final monitor = LabGroqFreeUsageMonitor();
    expect(monitor.recordUnknown(
      attemptId: 'durable-1', wireBytes: 512, wireAudioMs: 30000,
    ), isTrue);
    expect(monitor.recordUnknown(
      attemptId: 'durable-1', wireBytes: 512, wireAudioMs: 30000,
    ), isFalse);
    expect(monitor.statusAt(at), 'SUBMIT_UNKNOWN');
    expect(monitor.observedAttempts, 1);
    expect(monitor.acceptedWireAudioMs, 0);
    expect(monitor.canOfferNewManualSubmission(at), isFalse);
  });

  test('bad counters, request IDs, and HTTP codes fail closed', () {
    final monitor = LabGroqFreeUsageMonitor();
    expect(() => monitor.recordHttp(
      attemptId: 'audio/file.wav', statusCode: 200, wireBytes: 1,
      wireAudioMs: 100, observedAt: at,
    ), throwsArgumentError);
    expect(() => monitor.recordHttp(
      attemptId: 'one', statusCode: 99, wireBytes: 1,
      wireAudioMs: 100, observedAt: at,
    ), throwsArgumentError);
    expect(() => monitor.recordUnknown(
      attemptId: 'two', wireBytes: -1, wireAudioMs: 100,
    ), throwsArgumentError);
    expect(monitor.observedAttempts, 0);
  });
}
