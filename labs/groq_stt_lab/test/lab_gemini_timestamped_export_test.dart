import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_gemini_timestamped_export.dart';
import 'package:groq_stt_lab/lab_segmented_stt_bundle.dart';

const original = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const wire = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

List<LabStagedChunk> physical() => [
  for (var i = 0; i < 6; i++)
    LabStagedChunk(file: File('offline.wav'), byteCount: 1920044,
      sha256Hex: wire, coreStartMs: i * 60000,
      coreEndMs: (i + 1) * 60000,
      wireStartMs: i == 0 ? 0 : i * 60000 - 2000,
      wireEndMs: (i + 1) * 60000),
];

String utterance(int i) => '第' +
    const ['一', '二', '三', '四', '五', '六'][i] + '段地震演練';

Map<int, String> rawSix({bool badClock = false, bool repeated = false}) => {
  for (var i = 0; i < 6; i++)
    i: jsonEncode({
      'text': repeated && i == 1 ? '第一段地震演練' : utterance(i),
      'segments': [
        {'start': badClock && i == 1 ? 90.0 : 1.0,
         'end': badClock && i == 1 ? 92.0 : 2.0,
         'text': repeated && i == 1 ? '第一段地震演練' : utterance(i)},
      ],
    }),
};

LabSegmentedSttBundle packed(Map<int, String> raws) =>
    LabSegmentedSttBundle.build(
      staged: physical(), sourceSha256: original,
      savedRawByIndex: raws,
      savedRawShaByIndex: raws.map((k, v) => MapEntry(
          k, sha256.convert(utf8.encode(v)).toString())),
    );

void main() {
  test('six real source clocks, normalized punctuation and intact Gemini text',
      () {
    final raws = rawSix();
    final gemini = '第一段地震演練，第二段地震演練。'
        '第三段地震演練、第四段地震演練；'
        '第五段地震演練，第六段地震演練。';
    final text = LabGeminiTimestampedExport.build(
        bundle: packed(raws), staged: physical(),
        sourceSha256: original, geminiText: gemini);
    expect(text, contains('[00:00:01.000–00:00:02.000]'));
    // Chunk 2 local 1s is at global wire 58s + 1s = 59s;
    // never fabricate 61s from the core start 60s.
    expect(text, contains('[00:00:59.000–00:01:00.000]'));
    expect(text, contains('OVERLAP_REVIEW_REQUIRED'));
    expect(text, contains('matched_segments=6'));
    expect(text.endsWith(gemini), isTrue);
  });

  test('edited Gemini material stays unaligned and is never thrown away', () {
    final gemini = '第一段地震演練。Gemini改寫了第二段。第三段地震演練';
    final text = LabGeminiTimestampedExport.build(
        bundle: packed(rawSix()), staged: physical(),
        sourceSha256: original, geminiText: gemini);
    expect(text, contains('[UNALIGNED_GEMINI_NO_TIMESTAMP]'));
    expect(text, contains('Gemini改寫了第二段'));
    expect(text, isNot(contains('matched_segments=6')));
    expect(text.endsWith(gemini), isTrue);
  });

  test('repeated ambiguous speech never gains a false single clock', () {
    final raws = rawSix(repeated: true);
    final transcript = '第一段地震演練。第三段地震演練。';
    final text = LabGeminiTimestampedExport.build(
        bundle: packed(raws), staged: physical(),
        sourceSha256: original, geminiText: transcript);
    expect(text, contains('ambiguous_repeated_source_segments=2'));
    expect(text, contains('matched_segments=1'));
    expect(text.endsWith(transcript), isTrue);
  });

  test('invalid provider segment outside physical wire fails closed', () {
    final raws = rawSix(badClock: true);
    expect(() => LabGeminiTimestampedExport.build(
        bundle: packed(raws), staged: physical(),
        sourceSha256: original, geminiText: '第一段地震演練'),
        throwsStateError);
  });

  test('incomplete receipts and forged source identity cannot export times',
      () {
    final raws = rawSix()..remove(5);
    expect(() => LabGeminiTimestampedExport.build(
        bundle: packed(raws), staged: physical(),
        sourceSha256: original, geminiText: '第一段地震演練'),
        throwsStateError);
    expect(() => LabGeminiTimestampedExport.build(
        bundle: packed(rawSix()), staged: physical(),
        sourceSha256: List.filled(64, 'f').join(),
        geminiText: '第一段地震演練'), throwsStateError);
  });
}
