import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_stt_demo_fixtures.dart';
import 'package:groq_stt_lab/lab_stt_raw_preview.dart';

final sha = 'a' * 64;
final wireSha = 'b' * 64;

void main() {
  test('two physical windows generate synthetic Groq raw JSON and overlap review', () {
    final chunks = [
      LabStagedChunk(
        file: File('fake1.wav'), byteCount: 1920044, sha256Hex: wireSha,
        coreStartMs: 0, coreEndMs: 60000, wireStartMs: 0, wireEndMs: 60000,
      ),
      LabStagedChunk(
        file: File('fake2.wav'), byteCount: 1984044, sha256Hex: wireSha,
        coreStartMs: 60000, coreEndMs: 120000,
        wireStartMs: 58000, wireEndMs: 120000,
      ),
    ];
    final json = LabSttDemoFixtures.buildForPhysicalChunks(chunks);
    expect(json, hasLength(2));
    final parsed = LabSttRawPreview.fromChunkVerboseJson(
        staged: chunks, originalSourceSha256: sha, rawJsonByChunk: json);
    expect(parsed.chunkCount, 2);
    expect(parsed.candidates, hasLength(3));
    expect(parsed.reviewRequired, 1);
    expect(parsed.candidates.first.rawText, contains('LAB_MOCK'));
    expect(parsed.candidates[1].requiresOverlapReview, true);
    expect(parsed.candidates[1].globalStartMs, 58150);
    expect(parsed.candidates[2].globalStartMs, 60200);
  });

  test('tiny windows without a valid segment are rejected', () {
    final chunks = [
      LabStagedChunk(file: File('tiny.wav'), byteCount: 45,
          sha256Hex: wireSha, coreStartMs: 0, coreEndMs: 10,
          wireStartMs: 0, wireEndMs: 10),
    ];
    expect(() => LabSttDemoFixtures.buildForPhysicalChunks(chunks),
        throwsStateError);
  });
}
