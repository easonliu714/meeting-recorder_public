import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_groq_stt_panel.dart';
import 'package:groq_stt_lab/lab_stt_raw_preview.dart';

const originalSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const wireSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

List<LabStagedChunk> stagedThree() => [
  LabStagedChunk(
    file: File('chunk1.wav'), byteCount: 1920044, sha256Hex: wireSha,
    coreStartMs: 0, coreEndMs: 60000, wireStartMs: 0, wireEndMs: 60000,
  ),
  LabStagedChunk(
    file: File('chunk2.wav'), byteCount: 1984044, sha256Hex: wireSha,
    coreStartMs: 60000, coreEndMs: 120000, wireStartMs: 58000,
    wireEndMs: 120000,
  ),
  LabStagedChunk(
    file: File('chunk3.wav'), byteCount: 1984044, sha256Hex: wireSha,
    coreStartMs: 120000, coreEndMs: 180000, wireStartMs: 118000,
    wireEndMs: 180000,
  ),
];

// Uses placeholder File paths; no real audio is read or modified.

String raw(List<Map<String, Object>> segments) => jsonEncode({
  'text': segments.map((x) => x['text']).join(' '),
  'segments': segments,
});

void main() {
  final raw1 = raw([{'start': 58.4, 'end': 59.8, 'text': 'first saved'}]);
  final raw2 = raw([
    {'start': 0.9, 'end': 1.8, 'text': 'first saved'},
    {'start': 2.1, 'end': 3.0, 'text': 'second saved'},
  ]);

  test('one real Raw is previewable without fictitious later windows', () {
    final prefix = labGroqSavedRawPrefix(
      rawByIndex: {0: raw1}, chunkCount: 3,
    );
    expect(prefix, hasLength(1));
    final preview = LabSttRawPreview.fromSavedGroqPrefix(
      staged: stagedThree(), originalSourceSha256: originalSha,
      savedRawPrefix: prefix,
    );
    expect(preview.chunkCount, 1);
    expect(preview.candidates, hasLength(1));
    expect(preview.candidates.single.rawText, 'first saved');
    expect(preview.candidates.single.globalStartMs, 58400);
    expect(preview.reviewRequired, 0);
    expect(() => prefix.clear(), throwsUnsupportedError);
  });

  test('two saved Raw display real global clock and overlap review', () {
    final prefix = labGroqSavedRawPrefix(
      rawByIndex: {0: raw1, 1: raw2}, chunkCount: 3,
    );
    final preview = LabSttRawPreview.fromSavedGroqPrefix(
      staged: stagedThree(), originalSourceSha256: originalSha,
      savedRawPrefix: prefix,
    );
    expect(preview.chunkCount, 2);
    expect(preview.candidates, hasLength(3));
    expect(preview.candidates[1].globalStartMs, 58900);
    expect(preview.candidates[1].requiresOverlapReview, isTrue);
    expect(preview.reviewRequired, 1);
  });

  test('gap never reassigns Chunk 3 raw to Chunk 2', () {
    final prefix = labGroqSavedRawPrefix(
      rawByIndex: {0: raw1, 2: raw2}, chunkCount: 3,
    );
    expect(prefix, [raw1]);
    expect(labGroqSavedRawPrefix(
      rawByIndex: {1: raw2}, chunkCount: 3,
    ), isEmpty);
  });

  test('full timeline integrity applies even with only first Raw', () {
    final fullPlan = stagedThree();
    final forged = [
      ...fullPlan.take(2),
      LabStagedChunk(
        file: File('forged.wav'), byteCount: 1984044,
        sha256Hex: wireSha, coreStartMs: 120001, coreEndMs: 180000,
        wireStartMs: 118001, wireEndMs: 180000,
      ),
    ];
    expect(() => LabSttRawPreview.fromSavedGroqPrefix(
      staged: forged, originalSourceSha256: originalSha,
      savedRawPrefix: [raw1],
    ), throwsStateError);
    expect(() => LabSttRawPreview.fromChunkVerboseJson(
      staged: fullPlan, originalSourceSha256: originalSha,
      rawJsonByChunk: [raw1],
    ), throwsStateError);
  });

  test('invalid raw, out-of-wire timestamps and invalid indices HOLD', () {
    final windows = stagedThree();
    for (final bad in [
      raw([{'start': 61, 'end': 63, 'text': 'outside'}]),
      '{"text":"wrong","segments":[]}',
      '{"not":"verbose_json"}',
    ]) {
      expect(() => LabSttRawPreview.fromSavedGroqPrefix(
        staged: windows, originalSourceSha256: originalSha,
        savedRawPrefix: [bad],
      ), throwsStateError);
    }
    expect(() => labGroqSavedRawPrefix(
      rawByIndex: {-1: raw1}, chunkCount: 3,
    ), throwsStateError);
    expect(() => labGroqSavedRawPrefix(
      rawByIndex: {3: raw1}, chunkCount: 3,
    ), throwsStateError);
    expect(() => labGroqSavedRawPrefix(
      rawByIndex: {0: ''}, chunkCount: 3,
    ), throwsStateError);
  });
}
