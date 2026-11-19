import 'dart:convert';

import 'groq_chunk_clock_contract.dart';

/// P3L: read-only candidates from already saved provider verbose-JSON.
/// This never sends HTTP, modifies provider raw, deduplicates speech,
/// or writes a Note/transcript. Boundary-crossing speech needs human review.
class GroqRawSegmentCandidate {
  const GroqRawSegmentCandidate({
    required this.chunkIndex,
    required this.partId,
    required this.rawText,
    required this.globalStartMs,
    required this.globalEndMs,
    required this.coreOwned,
  });

  final int chunkIndex;
  final String partId;
  final String rawText;
  final int globalStartMs;
  final int globalEndMs;
  final bool coreOwned;
  bool get requiresOverlapReview => !coreOwned;
}

class GroqProviderRawTimeline {
  static int _milliseconds(Object? seconds) {
    if (seconds is! num || !seconds.toDouble().isFinite ||
        seconds < 0 || seconds > 86400) {
      throw StateError('GROQ_PROVIDER_SEGMENT_TIMESTAMP_INVALID');
    }
    return (seconds * 1000).round();
  }

  /// Requires a complete physical-Part clock plan and one immutable raw JSON
  /// response per window. Does not silently suppress duplicated phrases.
  static List<GroqRawSegmentCandidate> candidates({
    required List<GroqChunkClock> chunks,
    required List<String> rawJsonByChunk,
  }) {
    GroqChunkClockContract.verify(chunks);
    if (rawJsonByChunk.length != chunks.length) {
      throw StateError('GROQ_PROVIDER_RAW_WINDOW_COUNT_MISMATCH');
    }
    return _parseVerifiedPrefix(chunks, rawJsonByChunk);
  }

  /// Read-only progress preview: the entire actual physical clock plan is
  /// verified first, then only a contiguous prefix of saved Raw is parsed.
  /// Missing receipts are NEVER fabricated, skipped, submitted or marked done.
  static List<GroqRawSegmentCandidate> candidatesForSavedPrefix({
    required List<GroqChunkClock> allChunks,
    required List<String> savedRawPrefix,
  }) {
    GroqChunkClockContract.verify(allChunks);
    if (savedRawPrefix.isEmpty ||
        savedRawPrefix.length > allChunks.length) {
      throw StateError('GROQ_PROVIDER_RAW_PREFIX_COUNT_HOLD');
    }
    return _parseVerifiedPrefix(allChunks, savedRawPrefix);
  }

  static List<GroqRawSegmentCandidate> _parseVerifiedPrefix(
    List<GroqChunkClock> allChunks,
    List<String> rawJsonByChunk,
  ) {
    final result = <GroqRawSegmentCandidate>[];
    for (var i = 0; i < rawJsonByChunk.length; i++) {
      final chunk = allChunks[i];
      Object? decoded;
      try {
        decoded = jsonDecode(rawJsonByChunk[i]);
      } catch (_) {
        throw StateError('GROQ_PROVIDER_RAW_JSON_INVALID');
      }
      if (decoded is! Map<String, dynamic> ||
          decoded.containsKey('error') ||
          decoded['text'] is! String ||
          decoded['segments'] is! List) {
        throw StateError('GROQ_PROVIDER_RAW_SEGMENTS_MISSING');
      }
      // The provider can legitimately return no speech (empty text and
      // zero segments) for a silent final window. Keep its immutable Raw
      // receipt in the journal and allow the earlier five windows to merge.
      // Non-empty top-level speech with no segment clocks is ambiguous.
      if ((decoded['segments'] as List).isEmpty) {
        if ((decoded['text'] as String).trim().isNotEmpty) {
          throw StateError('GROQ_PROVIDER_TEXT_WITHOUT_SEGMENTS_HOLD');
        }
        continue;
      }
      // P3S: keep the provider's raw order; never silently sort timestamps.
      // Reversed starts are ambiguous for global overlap review.
      double? previousStartSeconds;
      var meaningfulSegments = 0;
      for (final item in decoded['segments'] as List) {
        if (item is! Map<String, dynamic> ||
            item['text'] is! String) {
          throw StateError('GROQ_PROVIDER_SEGMENT_TEXT_INVALID');
        }
        // Blank transcription text is not a malformed provider response:
        // silence/breathing can produce timed segments without actual words.
        // Still fully validate its timing and ordering before skipping it.
        final blankSpeech = (item['text'] as String).trim().isEmpty;
        final start = _milliseconds(item['start']);
        final end = _milliseconds(item['end']);
        // P4D: rounding to milliseconds is only for exported clock values.
        // Check raw seconds first: rounding can hide reversed segments and
        // sub-millisecond speech beyond the attested physical wire.
        final startSeconds = (item['start'] as num).toDouble();
        final endSeconds = (item['end'] as num).toDouble();
        if (endSeconds < startSeconds ||
            (!blankSpeech && (endSeconds <= startSeconds || end <= start))) {
          throw StateError('GROQ_PROVIDER_SEGMENT_INTERVAL_INVALID');
        }
        // A zero-length timing window can describe silence, not speech.
        // Negative/reversed/outside-wire windows remain invalid.
        if (previousStartSeconds != null &&
            startSeconds < previousStartSeconds) {
          throw StateError('GROQ_PROVIDER_SEGMENT_ORDER_HOLD');
        }
        previousStartSeconds = startSeconds;
        final wireDuration = chunk.wireEndMs - chunk.wireStartMs;
        if (endSeconds > wireDuration / 1000.0 || end > wireDuration) {
          throw StateError('GROQ_PROVIDER_SEGMENT_OUTSIDE_WIRE');
        }
        if (blankSpeech) continue; // Raw bytes remain unchanged/readable.
        meaningfulSegments++;
        final globalStart = GroqChunkClockContract.globalTimeMs(chunk, start);
        final globalEnd = GroqChunkClockContract.globalTimeMs(chunk, end);
        result.add(GroqRawSegmentCandidate(
          chunkIndex: i,
          partId: chunk.partId,
          rawText: item['text'] as String,
          globalStartMs: globalStart,
          globalEndMs: globalEnd,
          coreOwned: globalStart >= chunk.globalCoreStartMs &&
              globalEnd <= chunk.globalCoreEndMs,
        ));
      }
      if (meaningfulSegments == 0 &&
          (decoded['text'] as String).trim().isNotEmpty) {
        // Provider says speech exists but supplies no corresponding timed
        // words: never silently drop it from the six-part transcript.
        throw StateError('GROQ_PROVIDER_UNALIGNED_TEXT_HOLD');
      }
    }
    return List<GroqRawSegmentCandidate>.unmodifiable(result);
  }
}
