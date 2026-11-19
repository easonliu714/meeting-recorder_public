/// Offline-only Groq Free response/usage policy for LAB-2.
/// No provider HTTP, API keys, automatic retries, or forecast-based quota gates.
final class LabGroqFreeUsageMonitor {
  final Set<String> _recordedAttemptIds = <String>{};
  static final RegExp _safeAttemptId = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  int observedAttempts = 0;
  int successfulResponses = 0;
  int rateLimitedResponses = 0;
  int failedResponses = 0;
  int attemptedBytes = 0;
  int attemptedWireAudioMs = 0;
  int acceptedWireAudioMs = 0;
  int? lastHttpStatus;
  int? remainingRequestsPerDay;
  DateTime? cooldownUntilUtc;
  String? holdReason;

  /// A response rate-limit is temporary for future *new, user-initiated*
  /// chunks. It never resends the failed or uncertain attempt.
  bool isCoolingDown(DateTime now) =>
      cooldownUntilUtc != null &&
      now.toUtc().isBefore(cooldownUntilUtc!);

  int cooldownSeconds(DateTime now) {
    if (!isCoolingDown(now)) return 0;
    final milliseconds =
        cooldownUntilUtc!.difference(now.toUtc()).inMilliseconds;
    return (milliseconds + 999) ~/ 1000;
  }

  bool canOfferNewManualSubmission(DateTime now) =>
      holdReason == null && !isCoolingDown(now);

  /// Never initiate retry automatically, even after cooldown expires.
  bool get mayAutoRetry => false;

  String statusAt(DateTime now) {
    if (holdReason != null) return holdReason!;
    if (isCoolingDown(now)) return 'COOLING_DOWN';
    return 'READY_FOR_NEW_MANUAL_SUBMISSION';
  }

  /// Observe the result of exactly one previously authorized HTTP attempt.
  /// Only numerical response metadata is retained; no raw server body or key.
  /// Returns false for duplicate attempt IDs (idempotent accounting).
  bool recordHttp({
    required String attemptId,
    required int statusCode,
    required int wireBytes,
    required int wireAudioMs,
    required DateTime observedAt,
    Map<String, String> headers = const <String, String>{},
  }) {
    _validateAttempt(attemptId, wireBytes, wireAudioMs);
    if (statusCode < 100 || statusCode > 599) {
      throw ArgumentError('INVALID_HTTP_STATUS');
    }
    if (!_recordedAttemptIds.add(attemptId)) return false;
    _addAttempt(wireBytes, wireAudioMs);
    lastHttpStatus = statusCode;
    final remaining = _header(headers, 'x-ratelimit-remaining-requests');
    final parsedRemaining = remaining == null ? null : int.tryParse(remaining);
    // Official Groq header is RPD; it is NOT remaining audio seconds.
    if (parsedRemaining != null && parsedRemaining >= 0) {
      remainingRequestsPerDay = parsedRemaining;
    }

    if (statusCode >= 200 && statusCode < 300) {
      successfulResponses++;
      acceptedWireAudioMs += wireAudioMs;
      return true;
    }
    if (statusCode == 429) {
      rateLimitedResponses++;
      final retry = _header(headers, 'retry-after');
      final seconds = retry == null ? null : int.tryParse(retry);
      if (seconds == null || seconds < 0 || seconds > 604800) {
        // A missing/malformed/unreasonably large duration cannot be guessed.
        holdReason ??= 'RETRY_AFTER_NOT_VERIFIED';
      } else {
        final candidate =
            observedAt.toUtc().add(Duration(seconds: seconds));
        if (cooldownUntilUtc == null ||
            candidate.isAfter(cooldownUntilUtc!)) {
          cooldownUntilUtc = candidate;
        }
      }
      return true;
    }

    failedResponses++;
    if (statusCode == 413) {
      holdReason ??= 'WIRE_TOO_LARGE_STOP';
    } else {
      // Authentication/server/client failure: halt this batch. No retries.
      holdReason ??= 'HTTP_FAILURE_MANUAL_REVIEW';
    }
    return true;
  }

  /// No reliable HTTP response after a possible send. Persisting a future
  /// SUBMIT_UNKNOWN journal is the transport's responsibility. This policy
  /// refuses to requeue it and blocks further automatic attempts.
  bool recordUnknown({
    required String attemptId,
    required int wireBytes,
    required int wireAudioMs,
  }) {
    _validateAttempt(attemptId, wireBytes, wireAudioMs);
    if (!_recordedAttemptIds.add(attemptId)) return false;
    _addAttempt(wireBytes, wireAudioMs);
    holdReason ??= 'SUBMIT_UNKNOWN';
    return true;
  }

  void _addAttempt(int wireBytes, int wireAudioMs) {
    observedAttempts++;
    attemptedBytes += wireBytes;
    attemptedWireAudioMs += wireAudioMs;
  }

  static void _validateAttempt(String attemptId, int bytes, int audioMs) {
    if (!_safeAttemptId.hasMatch(attemptId) ||
        bytes <= 0 ||
        audioMs <= 0) {
      throw ArgumentError('INVALID_GROQ_FREE_ATTEMPT_METADATA');
    }
  }

  static String? _header(Map<String, String> headers, String key) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == key) {
        return entry.value.trim();
      }
    }
    return null;
  }
}
