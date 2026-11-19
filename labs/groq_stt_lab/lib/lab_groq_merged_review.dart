import 'groq_provider_raw_timeline.dart';
import 'lab_stt_raw_preview.dart';

/// Read-only, complete-source chronological merge view.
/// No STT is sent, no raw is modified, and overlapping candidates are
/// preserved for explicit user review. This is not an approved final Note.
final class LabGroqMergedReview {
  const LabGroqMergedReview._({
    required this.chunksSaved,
    required this.chunksExpected,
    required this.timeline,
    required this.overlapReviewCount,
    required this.textlessChunkIndices,
  });

  final int chunksSaved;
  final int chunksExpected;
  final List<GroqRawSegmentCandidate> timeline;
  final int overlapReviewCount;

  /// Zero-based physical Chunk indices with a saved Raw but no timed words.
  /// This is an absence of usable STT text, not evidence of no recording.
  final List<int> textlessChunkIndices;

  bool get allRawReceived => chunksSaved == chunksExpected;
  bool get isSixChunkMergeReady => chunksExpected == 6 && allRawReceived;

  String get status => allRawReceived
      ? 'ALL_RAW_SAVED_MERGED_REVIEW_REQUIRED'
      : 'PARTIAL_RAW_PREVIEW';

  static LabGroqMergedReview assemble({
    required LabSttRawPreview parsed,
    required int expectedChunkCount,
  }) {
    if (expectedChunkCount <= 0 ||
        expectedChunkCount > 1000 ||
        parsed.chunkCount <= 0 ||
        parsed.chunkCount > expectedChunkCount) {
      throw StateError('GROQ_MERGE_RECEIPT_COUNT_HOLD');
    }
    // Stable chronological order; include every Provider segment including
    // overlap. Never use text similarity to silently discard content.
    final indexed = <({int original, GroqRawSegmentCandidate candidate})>[
      for (var i = 0; i < parsed.candidates.length; i++)
        (original: i, candidate: parsed.candidates[i]),
    ];
    indexed.sort((a, b) {
      final time = a.candidate.globalStartMs.compareTo(
        b.candidate.globalStartMs,
      );
      if (time != 0) return time;
      final chunk = a.candidate.chunkIndex.compareTo(
        b.candidate.chunkIndex,
      );
      if (chunk != 0) return chunk;
      return a.original.compareTo(b.original);
    });
    final merged = List<GroqRawSegmentCandidate>.unmodifiable(
      indexed.map((item) => item.candidate),
    );
    return LabGroqMergedReview._(
      chunksSaved: parsed.chunkCount,
      chunksExpected: expectedChunkCount,
      timeline: merged,
      overlapReviewCount: merged
          .where((item) => item.requiresOverlapReview).length,
      textlessChunkIndices: List<int>.unmodifiable([
        for (var i = 0; i < parsed.chunkCount; i++)
          if (!parsed.candidates.any((item) => item.chunkIndex == i)) i,
      ]),
    );
  }

  /// Full visible human-review report. Only called on explicit user copy;
  /// never written to Debug Log, sent to the provider or saved to disk.
  String buildReviewText({bool sourceVerified = true}) {
    if (!allRawReceived) {
      throw StateError('GROQ_MERGE_NOT_ALL_RAW_SAVED');
    }
    final b = StringBuffer()
      ..writeln(sourceVerified
          ? 'Groq STT 全段合併檢視（非自動去重／待人工複核）'
          : '本機匯入 JSON 全段合併檢視（Provider 身分未驗證／待人工複核）')
      ..writeln('已保存 Chunk：$chunksSaved/$chunksExpected；'
          '辨識段落：${timeline.length}；重疊待複核：$overlapReviewCount');
    if (textlessChunkIndices.isNotEmpty) {
      final label = textlessChunkIndices
          .map((i) => 'Chunk ' + (i + 1).toString())
          .join('、');
      b.writeln('已保存 Raw 但無有效時間戳文字：' +
          label + '；不補造文字，原始 JSON 保留');
    }
    for (final item in timeline) {
      final begin = _clock(item.globalStartMs);
      final end = _clock(item.globalEndMs);
      final flag = item.requiresOverlapReview ? '[重疊待複核] ' : '';
      b.writeln('[$begin–$end] [Chunk ${item.chunkIndex + 1}] '
          '$flag${item.rawText}');
    }
    return b.toString();
  }

  static String _clock(int ms) {
    if (ms < 0) throw StateError('GROQ_MERGE_TIMESTAMP_NEGATIVE');
    final hours = ms ~/ 3600000;
    final minutes = ms ~/ 60000 % 60;
    final seconds = ms ~/ 1000 % 60;
    final millis = ms % 1000;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
  }
}
