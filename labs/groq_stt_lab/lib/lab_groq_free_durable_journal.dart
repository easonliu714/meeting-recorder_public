import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'lab_groq_free_usage_monitor.dart';

/// Persistent, append-only LAB-2 policy journal. It never sends HTTP.
/// No API key, raw audio, transcript, server body, or filename is retained.
/// Await armBeforeSend before a future transport can make a network attempt.
/// Torn/corrupt journals fail closed; automatic retry is never permitted.
final class LabGroqFreeDurableJournal {
  LabGroqFreeDurableJournal._(this.file);

  final File file;
  static const maxWireBytes = 20000000;
  static const maxEvents = 12000;
  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,80}$');
  static final _shaPattern = RegExp(r'^[a-f0-9]{64}$');
  static const _models = {'whisper-large-v3', 'whisper-large-v3-turbo'};
  final List<Map<String, dynamic>> _events = [];
  final Map<String, _Attempt> _attempts = {};
  LabGroqFreeUsageMonitor _usage = LabGroqFreeUsageMonitor();
  int _bytesOnDisk = 0;
  bool _writing = false;
  bool _writeFailed = false;

  static Future<LabGroqFreeDurableJournal> open(File file) async {
    final result = LabGroqFreeDurableJournal._(file);
    if (!await file.exists()) return result;
    final bytes = await file.readAsBytes();
    result._bytesOnDisk = bytes.length;
    if (bytes.isEmpty) throw StateError('FREE_JOURNAL_EMPTY_HOLD');
    final content = utf8.decode(bytes);
    if (!content.endsWith('\n')) {
      throw StateError('FREE_JOURNAL_TORN_WRITE_HOLD');
    }
    var previous = 'GENESIS';
    for (final line in content.split('\n')) {
      if (line.isEmpty) continue;
      if (result._events.length >= maxEvents) {
        throw StateError('FREE_JOURNAL_FULL_HOLD');
      }
      final item = jsonDecode(line);
      if (item is! Map<String, dynamic>) {
        throw StateError('FREE_JOURNAL_CORRUPT_HOLD');
      }
      final contentWithoutDigest = Map<String, dynamic>.from(item);
      final digest = contentWithoutDigest.remove('digest');
      if (item['version'] != 1 ||
          item['sequence'] != result._events.length + 1 ||
          item['previous'] != previous ||
          digest is! String ||
          sha256.convert(utf8.encode(jsonEncode(contentWithoutDigest))).toString() != digest) {
        throw StateError('FREE_JOURNAL_INTEGRITY_HOLD');
      }
      previous = digest;
      result._events.add(item);
    }
    result._replay(result._events, commit: true);
    return result;
  }

  int get attemptCount => _attempts.length;
  int get observedAttempts => _usage.observedAttempts;
  int get successfulResponses => _usage.successfulResponses;
  int get rateLimitedResponses => _usage.rateLimitedResponses;
  int get failedResponses => _usage.failedResponses;
  int get attemptedBytes => _usage.attemptedBytes;
  int get attemptedAudioMs => _usage.attemptedWireAudioMs;
  int get acceptedAudioMs => _usage.acceptedWireAudioMs;
  int? get remainingRequestsPerDay => _usage.remainingRequestsPerDay;
  DateTime? get cooldownUntilUtc => _usage.cooldownUntilUtc;
  bool get mayAutoRetry => false;
  String? phaseOf(String attemptId) => _attempts[attemptId]?.phase;

  /// A physical wire SHA is never submitted twice by this Lab, even across
  /// restarts or a different attempt ID. No unseen automatic retry.
  String? attemptForWire(String sourceSha, String wireSha) {
    for (final entry in _attempts.entries) {
      if (entry.value.sourceSha == sourceSha &&
          entry.value.wireSha == wireSha) {
        return entry.key;
      }
    }
    return null;
  }

  String? savedRawSha(String attemptId) {
    final attempt = _attempts[attemptId];
    return attempt?.phase == 'RAW_SAVED' ? attempt?.rawSha : null;
  }
  int cooldownSeconds(DateTime now) => _usage.cooldownSeconds(now);

  String statusAt(DateTime now) {
    if (_writeFailed) return 'FREE_JOURNAL_WRITE_HOLD';
    if (_writing) return 'FREE_JOURNAL_WRITE_IN_PROGRESS';
    if (_attempts.values.any((a) => a.phase == 'SUBMIT_UNKNOWN')) {
      return 'SUBMIT_UNKNOWN';
    }
    if (_attempts.values.any((a) => a.phase == 'RAW_PENDING')) {
      return 'PROVIDER_RAW_RECEIPT_PENDING';
    }
    if (_attempts.values.any((a) => a.phase == 'PREPARED')) {
      return 'PREPARED_REQUIRES_USER_ACTION';
    }
    return _usage.statusAt(now);
  }

  bool canStartNewManualChunk(DateTime now) =>
      statusAt(now) == 'READY_FOR_NEW_MANUAL_SUBMISSION';

  /// The foreground UI must supply explicit consent for each new attempt.
  /// accountScopeSha256 is a non-secret scope fingerprint, never an API key.
  Future<void> prepare({
    required String attemptId,
    required String sourceSha256,
    required String wireSha256,
    required String accountScopeSha256,
    required String model,
    required int wireBytes,
    required int wireAudioMs,
    required DateTime consentedAtUtc,
    required bool explicitConsent,
  }) async {
    if (!explicitConsent) throw StateError('FREE_CHUNK_CONSENT_REQUIRED');
    if (!_idPattern.hasMatch(attemptId) ||
        !_shaPattern.hasMatch(sourceSha256) ||
        !_shaPattern.hasMatch(wireSha256) ||
        !_shaPattern.hasMatch(accountScopeSha256) ||
        !_models.contains(model) ||
        wireBytes <= 0 || wireBytes >= maxWireBytes ||
        wireAudioMs <= 0 || wireAudioMs > 700000) {
      throw StateError('INVALID_FREE_CHUNK_PROVENANCE');
    }
    if (_attempts.containsKey(attemptId)) {
      throw StateError('FREE_ATTEMPT_ALREADY_EXISTS');
    }
    if (attemptForWire(sourceSha256, wireSha256) != null) {
      throw StateError('FREE_WIRE_ALREADY_RECORDED');
    }
    if (!canStartNewManualChunk(consentedAtUtc)) {
      throw StateError('FREE_PREPARE_BLOCKED');
    }
    await _append({
      'kind': 'PREPARED', 'attempt': attemptId,
      'source_sha': sourceSha256, 'wire_sha': wireSha256,
      'scope_sha': accountScopeSha256, 'model': model,
      'bytes': wireBytes, 'ms': wireAudioMs,
      'consent_utc': consentedAtUtc.toUtc().toIso8601String(),
    });
  }

  /// Call and await before invoking any HTTP client. An interrupted/unknown
  /// request remains UNKNOWN on every restart; never requeue that attempt.
  Future<void> armBeforeSend(String attemptId) async {
    if (_attempts[attemptId]?.phase != 'PREPARED') {
      throw StateError('FREE_NOT_PREPARED_OR_ALREADY_ARMED');
    }
    await _append({'kind': 'SUBMIT_UNKNOWN', 'attempt': attemptId});
  }

  /// Permanently binds a verified immutable raw receipt to an observed 2xx.
  /// The transport must write, flush and re-read raw bytes before this call.
  /// No raw text enters this status journal.
  Future<void> markRawSaved({
    required String attemptId,
    required String rawSha256,
    required int rawBytes,
  }) async {
    if (_attempts[attemptId]?.phase != 'RAW_PENDING') {
      throw StateError('FREE_RAW_NOT_PENDING');
    }
    if (!_shaPattern.hasMatch(rawSha256) ||
        rawBytes <= 0 || rawBytes > 4 * 1024 * 1024) {
      throw StateError('FREE_RAW_RECEIPT_INVALID');
    }
    await _append({
      'kind': 'RAW_SAVED', 'attempt': attemptId,
      'raw_sha': rawSha256, 'raw_bytes': rawBytes,
    });
  }

  /// Stores only status and numeric rate headers, not provider raw content.
  /// 2xx stays RAW_PENDING until a separate immutable raw-receipt gate exists.
  Future<void> observeHttp({
    required String attemptId,
    required int statusCode,
    required DateTime receivedAtUtc,
    Map<String, String> headers = const {},
  }) async {
    if (_attempts[attemptId]?.phase != 'SUBMIT_UNKNOWN') {
      throw StateError('FREE_RESPONSE_WITHOUT_UNKNOWN');
    }
    if (statusCode < 200 || statusCode > 599) {
      throw StateError('FREE_HTTP_STATUS_INVALID');
    }
    final retry = int.tryParse(_header(headers, 'retry-after') ?? '');
    final remaining = int.tryParse(
        _header(headers, 'x-ratelimit-remaining-requests') ?? '');
    await _append({
      'kind': 'HTTP_RESPONSE', 'attempt': attemptId, 'status': statusCode,
      'utc': receivedAtUtc.toUtc().toIso8601String(),
      'retry_s': retry != null && retry >= 0 && retry <= 604800 ? retry : null,
      'rpd': remaining != null && remaining >= 0 ? remaining : null,
    });
  }

  static String? _header(Map<String, String> headers, String name) {
    for (final h in headers.entries) {
      if (h.key.toLowerCase() == name) return h.value.trim();
    }
    return null;
  }

  Future<void> _append(Map<String, Object?> content) async {
    if (_writing || _writeFailed) {
      throw StateError('FREE_JOURNAL_WRITE_BLOCKED');
    }
    if (_events.length >= maxEvents) {
      throw StateError('FREE_JOURNAL_FULL_HOLD');
    }
    _writing = true;
    try {
      final exists = await file.exists();
      final length = exists ? await file.length() : 0;
      if (length != _bytesOnDisk || (exists && _events.isEmpty)) {
        throw StateError('FREE_JOURNAL_CONCURRENT_CHANGE_HOLD');
      }
      final withoutDigest = <String, Object?>{
        'version': 1, 'sequence': _events.length + 1,
        'previous': _events.isEmpty ? 'GENESIS' : _events.last['digest'],
        ...content,
      };
      final digest = sha256.convert(
          utf8.encode(jsonEncode(withoutDigest))).toString();
      final entry = <String, dynamic>{
        ...withoutDigest, 'digest': digest,
      };
      // Validate full resulting timeline *before* touching any file.
      _replay([..._events, entry], commit: false);
      final line = jsonEncode(entry) + '\n';
      await file.parent.create(recursive: true);
      await file.writeAsString(line, mode: FileMode.append, flush: true);
      _bytesOnDisk += utf8.encode(line).length;
      _events.add(entry);
      _replay(_events, commit: true);
    } catch (_) {
      // A failed write could have partially appended a record. Fail closed.
      _writeFailed = true;
      rethrow;
    } finally {
      _writing = false;
    }
  }

  void _replay(List<Map<String, dynamic>> records, {required bool commit}) {
    final attempts = <String, _Attempt>{};
    for (final event in records) {
      final id = event['attempt'];
      final kind = event['kind'];
      if (id is! String || !_idPattern.hasMatch(id)) {
        throw StateError('FREE_JOURNAL_EVENT_HOLD');
      }
      if (kind == 'PREPARED') {
        if (attempts.containsKey(id) ||
            event['source_sha'] is! String ||
            !_shaPattern.hasMatch(event['source_sha'] as String) ||
            event['wire_sha'] is! String ||
            !_shaPattern.hasMatch(event['wire_sha'] as String) ||
            event['scope_sha'] is! String ||
            !_shaPattern.hasMatch(event['scope_sha'] as String) ||
            !_models.contains(event['model']) ||
            event['bytes'] is! int || (event['bytes'] as int) <= 0 ||
            (event['bytes'] as int) >= maxWireBytes ||
            event['ms'] is! int || (event['ms'] as int) <= 0 ||
            (event['ms'] as int) > 700000 ||
            event['consent_utc'] is! String ||
            DateTime.tryParse(event['consent_utc'] as String) == null) {
          throw StateError('FREE_JOURNAL_PREPARED_HOLD');
        }
        final sourceSha = event['source_sha'] as String;
        final wireSha = event['wire_sha'] as String;
        if (attempts.values.any((a) =>
            a.sourceSha == sourceSha && a.wireSha == wireSha)) {
          throw StateError('FREE_JOURNAL_DUPLICATE_WIRE_HOLD');
        }
        attempts[id] = _Attempt(
          event['bytes'] as int, event['ms'] as int,
          sourceSha, wireSha,
        );
      } else if (kind == 'SUBMIT_UNKNOWN') {
        final attempt = attempts[id];
        if (attempt?.phase != 'PREPARED') {
          throw StateError('FREE_JOURNAL_UNKNOWN_HOLD');
        }
        attempt!.phase = 'SUBMIT_UNKNOWN';
      } else if (kind == 'HTTP_RESPONSE') {
        final attempt = attempts[id];
        final status = event['status'];
        if (attempt?.phase != 'SUBMIT_UNKNOWN' ||
            status is! int || status < 200 || status > 599 ||
            event['utc'] is! String ||
            DateTime.tryParse(event['utc'] as String) == null ||
            (event['retry_s'] != null &&
                (event['retry_s'] is! int ||
                 (event['retry_s'] as int) < 0 ||
                 (event['retry_s'] as int) > 604800)) ||
            (event['rpd'] != null &&
                (event['rpd'] is! int || (event['rpd'] as int) < 0))) {
          throw StateError('FREE_JOURNAL_RESPONSE_HOLD');
        }
        attempt!.phase = status < 300 ? 'RAW_PENDING' : 'RESPONDED';
        attempt.response = event;
      } else if (kind == 'RAW_SAVED') {
        final attempt = attempts[id];
        if (attempt?.phase != 'RAW_PENDING' ||
            event['raw_sha'] is! String ||
            !_shaPattern.hasMatch(event['raw_sha'] as String) ||
            event['raw_bytes'] is! int ||
            (event['raw_bytes'] as int) <= 0 ||
            (event['raw_bytes'] as int) > 4 * 1024 * 1024) {
          throw StateError('FREE_JOURNAL_RAW_RECEIPT_HOLD');
        }
        attempt!.phase = 'RAW_SAVED';
        attempt.rawSha = event['raw_sha'] as String;
      } else {
        throw StateError('FREE_JOURNAL_KIND_HOLD');
      }
    }
    final usage = LabGroqFreeUsageMonitor();
    for (final item in attempts.entries) {
      final attempt = item.value;
      if (attempt.phase == 'SUBMIT_UNKNOWN') {
        usage.recordUnknown(
          attemptId: item.key, wireBytes: attempt.bytes,
          wireAudioMs: attempt.ms,
        );
      } else if (attempt.response != null) {
        final response = attempt.response!;
        usage.recordHttp(
          attemptId: item.key, statusCode: response['status'] as int,
          wireBytes: attempt.bytes, wireAudioMs: attempt.ms,
          observedAt: DateTime.parse(response['utc'] as String),
          headers: {
            if (response['retry_s'] != null)
              'retry-after': response['retry_s'].toString(),
            if (response['rpd'] != null)
              'x-ratelimit-remaining-requests': response['rpd'].toString(),
          },
        );
      }
    }
    if (commit) {
      _attempts..clear()..addAll(attempts);
      _usage = usage;
    }
  }
}

final class _Attempt {
  _Attempt(this.bytes, this.ms, this.sourceSha, this.wireSha);
  final int bytes;
  final int ms;
  final String sourceSha;
  final String wireSha;
  String phase = 'PREPARED';
  Map<String, dynamic>? response;
  String? rawSha;
}
