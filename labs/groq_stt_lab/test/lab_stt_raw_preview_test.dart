import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_stt_raw_preview.dart';

const sourceSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const wireSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

List<LabStagedChunk> twoWindows() => [
      LabStagedChunk(
        file: File('fixture_1.wav'),
        byteCount: 1920044,
        sha256Hex: wireSha,
        coreStartMs: 0,
        coreEndMs: 60000,
        wireStartMs: 0,
        wireEndMs: 60000,
      ),
      LabStagedChunk(
        file: File('fixture_2.wav'),
        byteCount: 1984044,
        sha256Hex: wireSha,
        coreStartMs: 60000,
        coreEndMs: 120000,
        wireStartMs: 58000,
        wireEndMs: 120000,
      ),
    ];

String raw(List<Map<String, Object>> segments) => jsonEncode({
      'text': segments.map((s) => s['text']).join(' '),
      'language': 'zh',
      'segments': segments,
    });

void main() {
  final windows = twoWindows();
  final first = raw([
    {'start': 58.4, 'end': 59.8, 'text': '會議開始'},
  ]);
  final second = raw([
    {'start': 0.9, 'end': 1.8, 'text': '會議開始'},
    {'start': 2.1, 'end': 3.0, 'text': '第二段接續'},
  ]);

  test('clock binding preserves both duplicate-looking segments for review', () {
    final receipts = [first, second];
    final preview = LabSttRawPreview.fromChunkVerboseJson(
        staged: windows,
        originalSourceSha256: sourceSha,
        rawJsonByChunk: receipts);
    expect(preview.chunkCount, 2);
    expect(preview.candidates, hasLength(3));
    expect(preview.candidates[0].globalStartMs, 58400);
    expect(preview.candidates[1].globalStartMs, 58900);
    expect(preview.candidates[1].globalEndMs, 59800);
    expect(preview.candidates[1].requiresOverlapReview, isTrue);
    expect(preview.candidates[2].globalStartMs, 60100);
    expect(preview.reviewRequired, 1);
    expect(preview.candidates[0].rawText,
        preview.candidates[1].rawText);
    expect(receipts, [first, second]);
    expect(() => preview.candidates.clear(), throwsUnsupportedError);
  });

  test('rejects missing, foreign and malformed provider receipts', () {
    for (final receipts in <List<String>>[
      [first],
      [first, '{"text":"fake"}'],
      [first, '{broken'],
      [first, '{"text":"bad","segments":[]}'],
      [first, '{"error":"403","text":"bad","segments":[]}'],
    ]) {
      expect(
        () => LabSttRawPreview.fromChunkVerboseJson(
          staged: windows,
          originalSourceSha256: sourceSha,
          rawJsonByChunk: receipts,
        ), throwsStateError,
      );
    }
    expect(
        () => LabSttRawPreview.fromChunkVerboseJson(
          staged: windows,
          originalSourceSha256: 'bad',
          rawJsonByChunk: [first, second],
        ), throwsStateError);
  });

  test('out of order/negative and beyond wire timestamps fail closed', () {
    for (final wrong in [
      raw([{'start': 10, 'end': 11, 'text': 'late'},
           {'start': 9, 'end': 10, 'text': 'reversed'}]),
      raw([{'start': -1, 'end': 1, 'text': 'negative'}]),
      raw([{'start': 63, 'end': 64, 'text': 'past wire'}]),
    ]) {
      expect(
        () => LabSttRawPreview.fromChunkVerboseJson(
          staged: windows,
          originalSourceSha256: sourceSha,
          rawJsonByChunk: [first, wrong],
        ), throwsStateError,
      );
    }
  });

  test('rejects forged wire duration, changed bytes and oversized raw', () {
    final bad = [
      windows.first,
      LabStagedChunk(
        file: File('wrong.wav'),
        byteCount: 22500000,
        sha256Hex: wireSha,
        coreStartMs: 60000,
        coreEndMs: 120000,
        wireStartMs: 58000,
        wireEndMs: 120000,
      ),
    ];
    expect(
        () => LabSttRawPreview.fromChunkVerboseJson(
          staged: bad,
          originalSourceSha256: sourceSha,
          rawJsonByChunk: [first, second],
        ), throwsStateError);
    expect(
        () => LabSttRawPreview.fromChunkVerboseJson(
          staged: windows,
          originalSourceSha256: sourceSha,
          rawJsonByChunk: [first, 'x' * (4 * 1024 * 1024 + 1)],
        ), throwsStateError);
  });

  test('rejects non-contiguous core or 2s overlap mismatch', () {
    final wrong = [
      windows.first,
      LabStagedChunk(
        file: File('wrong.wav'),
        byteCount: 1984044,
        sha256Hex: wireSha,
        coreStartMs: 60001,
        coreEndMs: 120000,
        wireStartMs: 58001,
        wireEndMs: 120000,
      )
    ];
    expect(
        () => LabSttRawPreview.fromChunkVerboseJson(
          staged: wrong,
          originalSourceSha256: sourceSha,
          rawJsonByChunk: [first, second],
        ), throwsStateError);
  });
}
