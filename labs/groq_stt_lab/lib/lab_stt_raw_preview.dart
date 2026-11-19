import 'dart:convert';

import 'groq_chunk_clock_contract.dart';
import 'groq_provider_raw_timeline.dart';
import 'lab_audio_pipeline.dart';

/// LAB-3 dry-run adapter. Consumes already-obtained verbose JSON ONLY.
/// It has no HTTP client, API key, provider consent or upload operation.
///
/// Every provider candidate is preserved. Duplicate-looking overlap text
/// is explicitly REVIEW_REQUIRED, never silently dropped or forged into
/// a final meeting transcript.
/// A verified transcript prefix can be shorter than the stored Raw sequence.
/// Raw preservation is independent of the Provider timestamp acceptance.
final class LabGroqSavedPrefixResolution {
  const LabGroqSavedPrefixResolution({
    required this.preview,
    required this.rawSavedCount,
    required this.blockedChunkOneBased,
    required this.holdCode,
  });

  final LabSttRawPreview preview;
  final int rawSavedCount;
  final int? blockedChunkOneBased;
  final String? holdCode;

  bool get complete => blockedChunkOneBased == null &&
      preview.chunkCount == rawSavedCount;
}

final class LabSttRawPreview {
  const LabSttRawPreview({
    required this.candidates,
    required this.reviewRequired,
    required this.chunkCount,
  });

  final List<GroqRawSegmentCandidate> candidates;
  final int reviewRequired;
  final int chunkCount;

  static const int maxRawJsonBytesPerChunk = 4 * 1024 * 1024;
  static final _sha = RegExp(r'^[a-f0-9]{64}$');

  static LabSttRawPreview fromChunkVerboseJson({
    required List<LabStagedChunk> staged,
    required String originalSourceSha256,
    required List<String> rawJsonByChunk,
    String physicalPartId = 'lab_import_part_1',
  }) => _verifyAndParse(
        staged: staged,
        originalSourceSha256: originalSourceSha256,
        rawJsonByChunk: rawJsonByChunk,
        physicalPartId: physicalPartId,
        savedPrefixOnly: false,
      );

  /// Verify *every* physical core/wire clock, but parse only immutable saved
  /// receipts beginning at Chunk 1. Never represent missing windows as done.
  static LabSttRawPreview fromSavedGroqPrefix({
    required List<LabStagedChunk> staged,
    required String originalSourceSha256,
    required List<String> savedRawPrefix,
    String physicalPartId = 'lab_import_part_1',
  }) => _verifyAndParse(
        staged: staged,
        originalSourceSha256: originalSourceSha256,
        rawJsonByChunk: savedRawPrefix,
        physicalPartId: physicalPartId,
        savedPrefixOnly: true,
      );

  /// Do not erase earlier trusted transcripts when a later saved Raw has
  /// an out-of-wire clock. Binary-search the longest validated contiguous
  /// prefix, never skip a rejected Chunk and never rewrite provider evidence.
  /// All underlying physical Chunk clocks are validated on every probe.
  static LabGroqSavedPrefixResolution resolveSavedGroqPrefix({
    required List<LabStagedChunk> staged,
    required String originalSourceSha256,
    required List<String> savedRawPrefix,
    String physicalPartId = 'lab_import_part_1',
  }) {
    LabSttRawPreview parse(int count) => fromSavedGroqPrefix(
          staged: staged,
          originalSourceSha256: originalSourceSha256,
          savedRawPrefix: savedRawPrefix.sublist(0, count),
          physicalPartId: physicalPartId,
        );
    try {
      final all = parse(savedRawPrefix.length);
      return LabGroqSavedPrefixResolution(
        preview: all,
        rawSavedCount: savedRawPrefix.length,
        blockedChunkOneBased: null,
        holdCode: null,
      );
    } catch (_) {
      var verifiedCount = 0;
      var failedCount = savedRawPrefix.length;
      LabSttRawPreview? verified;
      while (failedCount - verifiedCount > 1) {
        final probe = (verifiedCount + failedCount) ~/ 2;
        try {
          verified = parse(probe);
          verifiedCount = probe;
        } catch (_) {
          failedCount = probe;
        }
      }
      if (verifiedCount == 0 || verified == null) rethrow;
      var code = 'GROQ_PROVIDER_PREFIX_HOLD';
      try {
        parse(verifiedCount + 1);
      } catch (error) {
        if (error is StateError) {
          final candidate = error.message.toString();
          if (RegExp(r'^[A-Z][A-Z0-9_]{1,63}$').hasMatch(candidate)) {
            code = candidate;
          }
        }
      }
      return LabGroqSavedPrefixResolution(
        preview: verified,
        rawSavedCount: savedRawPrefix.length,
        blockedChunkOneBased: verifiedCount + 1,
        holdCode: code,
      );
    }
  }

  static LabSttRawPreview _verifyAndParse({
    required List<LabStagedChunk> staged,
    required String originalSourceSha256,
    required List<String> rawJsonByChunk,
    required String physicalPartId,
    required bool savedPrefixOnly,
  }) {
    if (!_sha.hasMatch(originalSourceSha256) ||
        staged.isEmpty ||
        staged.length > 1000 ||
        rawJsonByChunk.isEmpty ||
        rawJsonByChunk.length > staged.length ||
        (!savedPrefixOnly && rawJsonByChunk.length != staged.length) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(physicalPartId)) {
      throw StateError('LAB_STT_SOURCE_OR_RECEIPT_COUNT_HOLD');
    }
    final partDurationMs = staged.last.coreEndMs;
    if (partDurationMs <= 0 || partDurationMs > 48 * 3600 * 1000) {
      throw StateError('LAB_STT_SOURCE_DURATION_HOLD');
    }

    final clocks = <GroqChunkClock>[];
    for (var index = 0; index < staged.length; index++) {
      final chunk = staged[index];
      if (!_sha.hasMatch(chunk.sha256Hex) ||
          chunk.byteCount < 45 ||
          chunk.byteCount >= 22500000) {
        throw StateError('LAB_STT_PHYSICAL_CHUNK_HOLD');
      }
      if (index < rawJsonByChunk.length) {
        final raw = rawJsonByChunk[index];
        if (raw.isEmpty ||
            utf8.encode(raw).length > maxRawJsonBytesPerChunk) {
          throw StateError('LAB_STT_RAW_LENGTH_HOLD');
        }
        dynamic parsed;
        try {
          parsed = jsonDecode(raw);
        } catch (_) {
          throw StateError('LAB_STT_PROVIDER_JSON_INVALID');
        }
        if (parsed is! Map<String, dynamic> ||
            parsed['text'] is! String ||
            // Fully silent final Chunk is legitimate when the real provider
            // returns text="" with zero or blank segments.
            parsed['segments'] is! List ||
            parsed.containsKey('error')) {
          throw StateError('LAB_STT_VERBOSE_JSON_REQUIRED');
        }
      }
      clocks.add(GroqChunkClock(
        partId: physicalPartId,
        partSha256: originalSourceSha256,
        partGlobalStartMs: 0,
        partDurationMs: partDurationMs,
        coreStartMs: chunk.coreStartMs,
        coreEndMs: chunk.coreEndMs,
        wireStartMs: chunk.wireStartMs,
        wireEndMs: chunk.wireEndMs,
        byteCount: chunk.byteCount,
      ));
    }
    // This reuses the source-reviewed Private PR79 strict clock and Provider
    // Raw candidate parser. It never modifies the original JSON or dedups.
    final candidates = savedPrefixOnly
        ? GroqProviderRawTimeline.candidatesForSavedPrefix(
            allChunks: List.unmodifiable(clocks),
            savedRawPrefix: List.unmodifiable(rawJsonByChunk),
          )
        : GroqProviderRawTimeline.candidates(
            chunks: List.unmodifiable(clocks),
            rawJsonByChunk: List.unmodifiable(rawJsonByChunk),
          );
    return LabSttRawPreview(
      candidates: candidates,
      reviewRequired:
          candidates.where((c) => c.requiresOverlapReview).length,
      chunkCount: rawJsonByChunk.length,
    );
  }
}
