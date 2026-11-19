import 'dart:convert';

import 'lab_audio_pipeline.dart';
import 'lab_groq_merged_review.dart';
import 'lab_segmented_stt_bundle.dart';
import 'lab_stt_raw_preview.dart';

/// Conservative read-only partial alignment: only uniquely identifiable,
/// sequentially matched Gemini text receives a real Groq source timestamp.
/// Unmatched Gemini text is never assigned a fabricated time. Both the
/// original AI text and immutable provider evidence remain accessible.
final class LabGeminiTimestampedExport {
  const LabGeminiTimestampedExport._();

  static String build({
    required LabSegmentedSttBundle bundle,
    required List<LabStagedChunk> staged,
    required String sourceSha256,
    required String geminiText,
  }) {
    if (!bundle.complete || bundle.chunks.length != 6 ||
        staged.length != 6 || bundle.sourceSha256 != sourceSha256 ||
        geminiText.trim().isEmpty ||
        utf8.encode(geminiText).length > 1024 * 1024) {
      throw StateError('LAB_AI_TIMESTAMP_SOURCE_HOLD');
    }
    final raws = <String>[];
    for (var i = 0; i < staged.length; i++) {
      final name = 'raw/chunk_' + (i + 1).toString().padLeft(3, '0') +
          '.verbose.json';
      final bytes = bundle.files[name];
      if (bytes == null) throw StateError('LAB_AI_TIMESTAMP_RAW_HOLD');
      raws.add(utf8.decode(bytes, allowMalformed: false));
    }
    // Validates full physical clock, every actual provider segment, wire
    // bounds, ordering and Raw format before any timestamps are emitted.
    final parsed = LabSttRawPreview.fromChunkVerboseJson(
        staged: staged,
        originalSourceSha256: sourceSha256,
        rawJsonByChunk: raws);
    final merged = LabGroqMergedReview.assemble(
        parsed: parsed, expectedChunkCount: 6);
    if (!merged.allRawReceived) {
      throw StateError('LAB_AI_TIMESTAMP_INCOMPLETE_HOLD');
    }
    final normDraft = _Normalized(geminiText);
    final occurrences = <String, int>{};
    final normalizedSources = <List<int>>[];
    for (final segment in merged.timeline) {
      final terms = _Normalized(segment.rawText).values;
      normalizedSources.add(terms);
      if (terms.length >= 4) {
        final key = String.fromCharCodes(terms);
        occurrences[key] = (occurrences[key] ?? 0) + 1;
      }
    }
    final out = StringBuffer()
      ..writeln('GEMINI_WHOLE_TIMED_REVIEW_V1')
      ..writeln('source_sha256=' + sourceSha256)
      ..writeln('status=PARTIAL_EXACT_SOURCE_ALIGNMENT_NOT_AUDIO_VERIFIED')
      ..writeln('timing=ORIGINAL_GROQ_VERBOSE_JSON_GLOBAL_WIRE_CLOCK')
      ..writeln('all_gemini_text_preserved=true')
      ..writeln('note=僅唯一、依序精確匹配的 Gemini 字句附來源時間；'
          '未匹配內容不得推算時間；重疊需人工核對。')
      ..writeln();
    var startRune = 0;
    var startCodeUnit = 0;
    var matched = 0;
    var ambiguous = 0;
    for (var i = 0; i < merged.timeline.length; i++) {
      final raw = merged.timeline[i];
      final terms = normalizedSources[i];
      if (terms.length < 4) continue;
      final key = String.fromCharCodes(terms);
      if ((occurrences[key] ?? 0) > 1) {
        ambiguous++;
        continue;
      }
      final found = _indexOf(normDraft.values, terms, startRune);
      if (found < 0) continue;
      if (_indexOf(normDraft.values, terms, found + 1) >= 0) {
        ambiguous++;
        continue;
      }
      final firstUnit = normDraft.starts[found];
      final lastUnit = normDraft.ends[found + terms.length - 1];
      if (firstUnit < startCodeUnit) continue;
      if (firstUnit > startCodeUnit) {
        out.writeln('[UNALIGNED_GEMINI_NO_TIMESTAMP] ' +
            geminiText.substring(startCodeUnit, firstUnit));
      }
      final suffix = raw.requiresOverlapReview
          ? ' [OVERLAP_REVIEW_REQUIRED]' : '';
      out.writeln('[' + _clock(raw.globalStartMs) + '–' +
          _clock(raw.globalEndMs) + '] [Groq Chunk ' +
          (raw.chunkIndex + 1).toString() + ']' + suffix + ' ' +
          geminiText.substring(firstUnit, lastUnit));
      startRune = found + terms.length;
      startCodeUnit = lastUnit;
      matched++;
    }
    if (startCodeUnit < geminiText.length) {
      out.writeln('[UNALIGNED_GEMINI_NO_TIMESTAMP] ' +
          geminiText.substring(startCodeUnit));
    }
    out
      ..writeln()
      ..writeln('matched_segments=' + matched.toString())
      ..writeln('provider_segments=' + merged.timeline.length.toString())
      ..writeln('ambiguous_repeated_source_segments=' + ambiguous.toString())
      ..writeln('overlap_review_required=' +
          merged.overlapReviewCount.toString())
      ..writeln()
      ..writeln('=== GEMINI_ORIGINAL_FULL_DRAFT_UNMODIFIED ===')
      ..write(geminiText);
    return out.toString();
  }

  static int _indexOf(List<int> source, List<int> phrase, int from) {
    if (phrase.isEmpty) return -1;
    for (var i = from; i <= source.length - phrase.length; i++) {
      var equal = true;
      for (var j = 0; j < phrase.length; j++) {
        if (source[i + j] != phrase[j]) {
          equal = false;
          break;
        }
      }
      if (equal) return i;
    }
    return -1;
  }

  static String _clock(int ms) {
    if (ms < 0) throw StateError('LAB_AI_TIMESTAMP_NEGATIVE_HOLD');
    final hh = (ms ~/ 3600000).toString().padLeft(2, '0');
    final mm = (ms ~/ 60000 % 60).toString().padLeft(2, '0');
    final ss = (ms ~/ 1000 % 60).toString().padLeft(2, '0');
    final fractions = (ms % 1000).toString().padLeft(3, '0');
    return hh + ':' + mm + ':' + ss + '.' + fractions;
  }
}

final class _Normalized {
  _Normalized(String text) {
    var unit = 0;
    for (final rune in text.runes) {
      final next = unit + (rune > 0xffff ? 2 : 1);
      final normalized = _normalizeRune(rune);
      if (normalized != null) {
        values.add(normalized);
        starts.add(unit);
        ends.add(next);
      }
      unit = next;
    }
  }
  final List<int> values = [];
  final List<int> starts = [];
  final List<int> ends = [];

  static int? _normalizeRune(int c) {
    if (c >= 0x41 && c <= 0x5a) return c + 32;
    if ((c >= 0x30 && c <= 0x39) ||
        (c >= 0x61 && c <= 0x7a) ||
        (c >= 0x3400 && c <= 0x9fff) ||
        (c >= 0xf900 && c <= 0xfaff) ||
        (c >= 0x3040 && c <= 0x30ff) ||
        (c >= 0xac00 && c <= 0xd7af)) return c;
    return null;
  }
}
