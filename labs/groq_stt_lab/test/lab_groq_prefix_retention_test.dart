import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_groq_merge_review_panel.dart';
import 'package:groq_stt_lab/lab_groq_merged_review.dart';
import 'package:groq_stt_lab/lab_stt_raw_preview.dart';

const sourceSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const wireSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

List<LabStagedChunk> physicalSix() => [
  for (var i = 0; i < 6; i++)
    LabStagedChunk(
      file: File('fixture_$i.wav'),
      byteCount: i == 0 ? 19197484 : 19261484,
      sha256Hex: wireSha,
      coreStartMs: 599920 * i,
      coreEndMs: 599920 * (i + 1),
      wireStartMs: i == 0 ? 0 : 599920 * i - 2000,
      wireEndMs: 599920 * (i + 1),
    ),
];

String raw(String text, double start, double end) => jsonEncode({
  'text': text,
  'language': 'zh',
  'segments': [{'start': start, 'end': end, 'text': text}],
});

List<String> sixRaws() => [
  raw('first genuine transcript', 1, 2),
  raw('second genuine transcript', 2.1, 3),
  // Third provider returns an untrusted end beyond its 601.920s wire.
  raw('unverified out of wire speech', 600, 602.5),
  raw('fourth not yet admissible', 1, 2),
  raw('fifth not yet admissible', 1, 2),
  raw('sixth not yet admissible', 1, 2),
];

LabGroqSavedPrefixResolution resolve(List<String> receipts) =>
    LabSttRawPreview.resolveSavedGroqPrefix(
      staged: physicalSix(),
      originalSourceSha256: sourceSha,
      savedRawPrefix: receipts,
    );

void main() {
  test('six Raw saved, third outside wire: retain two verified real transcripts', () {
    final originals = sixRaws();
    final copy = List<String>.of(originals);
    final result = resolve(originals);
    expect(result.rawSavedCount, 6);
    expect(result.preview.chunkCount, 2);
    expect(result.blockedChunkOneBased, 3);
    expect(result.holdCode, 'GROQ_PROVIDER_SEGMENT_OUTSIDE_WIRE');
    expect(result.complete, isFalse);
    expect(result.preview.candidates.map((x) => x.rawText),
        ['first genuine transcript', 'second genuine transcript']);
    final review = LabGroqMergedReview.assemble(
      parsed: result.preview, expectedChunkCount: 6,
    );
    expect(review.allRawReceived, isFalse);
    expect(review.timeline, hasLength(2));
    expect(() => review.buildReviewText(), throwsStateError);
    expect(originals, copy); // Raw content never clipped, deleted or rewritten
    expect(resolve(originals).preview.candidates.length, 2); // restart-safe
  });

  test('source and wire clock validation remains strictly fail closed', () {
    final raws = sixRaws();
    expect(() => LabSttRawPreview.fromSavedGroqPrefix(
      staged: physicalSix(), originalSourceSha256: sourceSha,
      savedRawPrefix: raws,
    ), throwsStateError);
    final broken = physicalSix();
    broken[4] = LabStagedChunk(
      file: File('forged.wav'), byteCount: 19261484,
      sha256Hex: wireSha, coreStartMs: 2399681,
      coreEndMs: 2999600, wireStartMs: 2397681,
      wireEndMs: 2999600,
    );
    expect(() => LabSttRawPreview.resolveSavedGroqPrefix(
      staged: broken, originalSourceSha256: sourceSha,
      savedRawPrefix: raws,
    ), throwsStateError);
  });

  test('invalid first Chunk never presents invented verified text', () {
    final raws = sixRaws();
    raws[0] = raw('invalid first', 599.8, 600.2);
    expect(() => resolve(raws), throwsStateError);
  });

  test('successful full six still enables full review; prefix never fakes six', () {
    final raws = sixRaws();
    raws[2] = raw('third genuine transcript', 599.8, 601.9);
    final all = resolve(raws);
    expect(all.complete, isTrue);
    expect(all.blockedChunkOneBased, isNull);
    expect(all.preview.chunkCount, 6);
    final review = LabGroqMergedReview.assemble(
      parsed: all.preview, expectedChunkCount: 6,
    );
    expect(review.allRawReceived, isTrue);
    expect(review.buildReviewText(), contains('sixth not yet admissible'));
    final prefix = resolve(raws.take(2).toList());
    expect(prefix.complete, isTrue); // 2 saved and all 2 parse valid
    expect(prefix.rawSavedCount, 2);
    expect(prefix.preview.chunkCount, 2);
    expect(LabGroqMergedReview.assemble(
      parsed: prefix.preview, expectedChunkCount: 6,
    ).allRawReceived, isFalse);
  });

  testWidgets('view distinguishes 6 saved raw from only 2 verified chunks',
      (tester) async {
    final result = resolve(sixRaws());
    final review = LabGroqMergedReview.assemble(
      parsed: result.preview, expectedChunkCount: 6,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: SingleChildScrollView(child: LabGroqMergeReviewPanel(
        review: review, actualSavedRawCount: result.rawSavedCount,
        blockedChunkOneBased: result.blockedChunkOneBased,
        holdCode: result.holdCode,
      )),
    )));
    expect(find.textContaining('Groq Raw 已保存：6/6'), findsOneWidget);
    expect(find.textContaining('已驗證逐字稿：2/6'), findsOneWidget);
    expect(find.byKey(const Key('groq-merge-prefix-hold')), findsOneWidget);
    expect(find.textContaining('GROQ_PROVIDER_SEGMENT_OUTSIDE_WIRE'),
        findsWidgets);
    final copy = find.byKey(const Key('groq-copy-full-merge'));
    expect(tester.widget<OutlinedButton>(copy).onPressed, isNull);
  });
}
