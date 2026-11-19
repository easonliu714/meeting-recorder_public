import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_groq_ai_review_panel.dart';
import 'package:groq_stt_lab/lab_segmented_stt_bundle.dart';
import 'package:groq_stt_lab/lab_segmented_stt_zip_import.dart';

const sourceSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const wireSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

List<LabStagedChunk> stages() => [
  for (var i = 0; i < 3; i++)
    LabStagedChunk(
      file: File('fixture_chunk_$i.wav'),
      byteCount: 1920044,
      sha256Hex: wireSha,
      coreStartMs: i * 60000,
      coreEndMs: (i + 1) * 60000,
      wireStartMs: i == 0 ? 0 : i * 60000 - 2000,
      wireEndMs: (i + 1) * 60000,
    ),
];

String raw(String text, {bool outside = false}) => jsonEncode({
  'text': text,
  'language': 'zh',
  'segments': [{
    'start': outside ? 70.0 : 1.0,
    'end': outside ? 72.0 : 2.0,
    'text': text,
  }],
});

Map<int, String> samples() => {
  0: raw('會議開始'),
  1: raw('上一段可能重疊', outside: true),
  2: raw('會議結束'),
};

Map<int, String> hashes(Map<int, String> source) => source.map(
    (i, text) => MapEntry(i, sha256.convert(utf8.encode(text)).toString()));

void main() {
  test('ZIP retains all three SHA-verified Raw bytes and original text;'
      ' out-of-wire Provider segments do NOT block export', () {
    final inputs = samples();
    final originals = Map<int, String>.of(inputs);
    final bundle = LabSegmentedSttBundle.build(
      staged: stages(), sourceSha256: sourceSha,
      savedRawByIndex: inputs, savedRawShaByIndex: hashes(inputs),
      participants: '王經理', glossary: 'STT=語音轉文字',
    );
    expect(bundle.complete, isTrue);
    expect(bundle.chunks.length, 3);
    expect(bundle.chunks[1].overlapBeforeMs, 2000);
    expect(bundle.chunks[1].text, '上一段可能重疊');
    final zip = ZipDecoder().decodeBytes(bundle.encodeZip(), verify: true);
    final entries = {for (final file in zip.files) file.name: file};
    final manifest = jsonDecode(utf8.decode(entries['manifest.json']!.content))
        as Map<String, dynamic>;
    expect(manifest['complete'], isTrue);
    expect(manifest['raw_source'], 'SHA_VERIFIED_LOCAL_RECEIPTS');
    expect(manifest['provider_segment_clock'], 'NOT_VALIDATED_FOR_EXPORT');
    final receipt = utf8.decode(entries['raw/chunk_002.verbose.json']!.content);
    expect(receipt, inputs[1]);
    expect(sha256.convert(utf8.encode(receipt)).toString(), hashes(inputs)[1]);
    expect(utf8.decode(entries['transcripts/chunk_002.txt']!.content),
        '上一段可能重疊');
    expect(utf8.decode(entries['context/participants.txt']!.content),
        '王經理');
    expect(utf8.decode(entries['context/glossary.txt']!.content),
        'STT=語音轉文字');
    expect(inputs, originals); // neither Raw nor transcript modified
    expect(entries.keys.any((name) => name.endsWith('.wav')), isFalse);
    expect(entries.keys.any((name) => name.contains('api_key')), isFalse);
  });

  test('partial ZIP is explicit and never claims full STT', () {
    final raws = {0: samples()[0]!};
    final bundle = LabSegmentedSttBundle.build(
      staged: stages(), sourceSha256: sourceSha,
      savedRawByIndex: raws, savedRawShaByIndex: hashes(raws),
    );
    expect(bundle.complete, isFalse);
    expect(bundle.manifest['saved_chunks'], 1);
    expect(bundle.manifest['expected_chunks'], 3);
  });

  test('missing receipt, altered bytes and forged physical clocks HOLD', () {
    final raws = samples();
    final wrongSha = hashes(raws)..[1] = List.filled(64, 'f').join();
    expect(() => LabSegmentedSttBundle.build(
      staged: stages(), sourceSha256: sourceSha,
      savedRawByIndex: raws, savedRawShaByIndex: wrongSha,
    ), throwsStateError);
    expect(() => LabSegmentedSttBundle.build(
      staged: stages(), sourceSha256: sourceSha,
      savedRawByIndex: {0: raws[0]!, 2: raws[2]!},
      savedRawShaByIndex: hashes({0: raws[0]!, 2: raws[2]!}),
    ), throwsStateError);
    final forged = stages();
    forged[1] = LabStagedChunk(
      file: File('forged.wav'), byteCount: 1920044,
      sha256Hex: wireSha, coreStartMs: 60001, coreEndMs: 120000,
      wireStartMs: 58000, wireEndMs: 120000,
    );
    expect(() => LabSegmentedSttBundle.build(
      staged: forged, sourceSha256: sourceSha,
      savedRawByIndex: raws, savedRawShaByIndex: hashes(raws),
    ), throwsStateError);
  });

  test('ZIP importer verifies six-clock plan and SHA, never modifies Raw',
      () {
    final rawOriginal = samples();
    final preserved = Map<int, String>.of(rawOriginal);
    final bundle = LabSegmentedSttBundle.build(
      staged: stages(), sourceSha256: sourceSha,
      savedRawByIndex: rawOriginal, savedRawShaByIndex: hashes(rawOriginal),
    );
    final imported = LabSegmentedSttZipImport.parse(
      zipBytes: bundle.encodeZip(), staged: stages(),
      sourceSha256: sourceSha,
    );
    expect(imported.count, 3);
    expect(imported.rawByIndex, preserved);
    expect(imported.shaByIndex, hashes(preserved));
    expect(rawOriginal, preserved);
    final rerender = LabSegmentedSttBundle.build(
      staged: stages(), sourceSha256: sourceSha,
      savedRawByIndex: imported.rawByIndex,
      savedRawShaByIndex: imported.shaByIndex,
      unverifiedImportedZip: true,
    );
    expect(rerender.manifest['raw_source'],
        'IMPORTED_ZIP_SHA_MATCHED_ORIGIN_UNVERIFIED');
    expect(LabSegmentedSttZipImport.parse(
      zipBytes: rerender.encodeZip(),
      staged: stages(), sourceSha256: sourceSha,
    ).count, 3);
  });

  test('ZIP importer rejects different source, forged Raw and wrong clock',
      () {
    final rawOriginal = samples();
    final bundle = LabSegmentedSttBundle.build(
      staged: stages(), sourceSha256: sourceSha,
      savedRawByIndex: rawOriginal, savedRawShaByIndex: hashes(rawOriginal),
    );
    final packed = bundle.encodeZip();
    expect(() => LabSegmentedSttZipImport.parse(
      zipBytes: packed, staged: stages(),
      sourceSha256: List.filled(64, 'c').join(),
    ), throwsStateError);
    final alteredStage = stages();
    alteredStage[1] = LabStagedChunk(
      file: File('wrong.wav'), byteCount: 1920044,
      sha256Hex: wireSha,
      coreStartMs: 60000, coreEndMs: 120000,
      wireStartMs: 59000, wireEndMs: 120000,
    );
    expect(() => LabSegmentedSttZipImport.parse(
      zipBytes: packed, staged: alteredStage,
      sourceSha256: sourceSha,
    ), throwsStateError);
    final unpacked = ZipDecoder().decodeBytes(packed, verify: true);
    final forged = Archive();
    for (final file in unpacked.files) {
      forged.addFile(ArchiveFile.bytes(
        file.name,
        file.name == 'raw/chunk_002.verbose.json'
            ? utf8.encode('{"text":"forged","segments":[]}')
            : file.content,
      ));
    }
    final forgedZip = ZipEncoder().encodeBytes(forged);
    expect(() => LabSegmentedSttZipImport.parse(
      zipBytes: forgedZip, staged: stages(), sourceSha256: sourceSha,
    ), throwsStateError);
  });

  testWidgets('AI send disabled until key, Free confirmation and model test',
      (tester) async {
    final raws = samples();
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: SingleChildScrollView(child: LabGroqAiReviewPanel(
        staged: stages(), sourceSha256: sourceSha,
        savedRawByIndex: raws, savedRawShaByIndex: hashes(raws),
      )),
    )));
    await tester.tap(find.byKey(const Key('ai-review-panel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-import-zip')), findsOneWidget);
    expect(find.byKey(const Key('ai-export-zip')), findsOneWidget);
    expect(find.text('Gemini API Key（不保存）'), findsOneWidget);
    expect(find.textContaining('Gemini Free AI 草稿'), findsOneWidget);
    expect(find.textContaining('Google AI Studio'), findsOneWidget);
    expect(find.textContaining('Groq API Key（不保存）'), findsNothing);
    expect(tester.widget<FilledButton>(
        find.byKey(const Key('ai-run-whole'))).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(
        find.byKey(const Key('ai-run'))).onPressed, isNull);
    expect(find.textContaining('不必先通過完整 Provider 時間軸合併'),
        findsOneWidget);
  });
}
