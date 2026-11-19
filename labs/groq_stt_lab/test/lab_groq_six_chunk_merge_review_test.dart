import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_groq_merged_review.dart';
import 'package:groq_stt_lab/lab_groq_merge_review_panel.dart';
import 'package:groq_stt_lab/lab_stt_raw_preview.dart';

const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const wireSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

List<LabStagedChunk> sixWindows() => [
  for (var i = 0; i < 6; i++)
    LabStagedChunk(
      file: File('fake_' + i.toString() + '.wav'),
      byteCount: i == 0 ? 1920044 : 1984044,
      sha256Hex: wireSha,
      coreStartMs: i * 60000,
      coreEndMs: (i + 1) * 60000,
      wireStartMs: i == 0 ? 0 : i * 60000 - 2000,
      wireEndMs: (i + 1) * 60000,
    ),
];

List<String> sixRaw() => [
  for (var i = 0; i < 6; i++)
    jsonEncode({
      'text': 'real part ${i + 1}',
      'language': 'zh',
      'segments': [
        if (i > 0)
          {'start': 0.8, 'end': 1.6, 'text': 'boundary from part ${i + 1}'},
        if (i == 0)
          {'start': 58.4, 'end': 59.8, 'text': 'first part ending'},
        if (i > 0)
          {'start': 2.2, 'end': 3.0, 'text': 'core of part ${i + 1}'},
      ],
    }),
];

LabSttRawPreview parsed(List<String> raws) =>
    LabSttRawPreview.fromSavedGroqPrefix(
      staged: sixWindows(),
      originalSourceSha256: sha,
      savedRawPrefix: raws,
    );

void main() {
  test('six Groq receipts form a complete chronological 11-segment review', () {
    final review = LabGroqMergedReview.assemble(
      parsed: parsed(sixRaw()), expectedChunkCount: 6,
    );
    expect(review.chunksSaved, 6);
    expect(review.isSixChunkMergeReady, isTrue);
    expect(review.allRawReceived, isTrue);
    expect(review.timeline, hasLength(11));
    expect(review.overlapReviewCount, 5);
    expect(review.status, 'ALL_RAW_SAVED_MERGED_REVIEW_REQUIRED');
    expect(review.timeline.first.globalStartMs, 58400);
    expect(review.timeline[1].globalStartMs, 58800);
    expect(review.timeline[1].requiresOverlapReview, isTrue);
    expect(review.timeline[2].globalStartMs, 60200);
    expect(review.timeline.last.chunkIndex, 5);
    final report = review.buildReviewText();
    expect(report, contains('已保存 Chunk：6/6'));
    expect(report, contains('00:00:58.400'));
    expect(report, contains('[重疊待複核]'));
    expect(report, contains('[Chunk 6]'));
    expect(report, isNot(contains('API Key')));
    expect(() => review.timeline.clear(), throwsUnsupportedError);
  });

  test('two saved Raw remain PARTIAL and cannot be exported as final six', () {
    final review = LabGroqMergedReview.assemble(
      parsed: parsed(sixRaw().take(2).toList()),
      expectedChunkCount: 6,
    );
    expect(review.chunksSaved, 2);
    expect(review.isSixChunkMergeReady, isFalse);
    expect(review.status, 'PARTIAL_RAW_PREVIEW');
    expect(review.timeline, hasLength(3));
    expect(() => review.buildReviewText(), throwsStateError);
  });

  test('missing/fabricated provider windows and forged clocks fail closed', () {
    expect(parsed(sixRaw().take(5).toList()).chunkCount, 5);
    expect(() => LabGroqMergedReview.assemble(
      parsed: parsed(sixRaw()), expectedChunkCount: 5,
    ), throwsStateError);
    final invalid = sixWindows();
    invalid[5] = LabStagedChunk(
      file: File('bad.wav'), byteCount: 1984044, sha256Hex: wireSha,
      coreStartMs: 300001, coreEndMs: 360000,
      wireStartMs: 298001, wireEndMs: 360000,
    );
    expect(() => LabSttRawPreview.fromSavedGroqPrefix(
      staged: invalid, originalSourceSha256: sha,
      savedRawPrefix: sixRaw(),
    ), throwsStateError);
    expect(() => parsed([...sixRaw(), sixRaw().last]), throwsStateError);
  });

  test('out-of-order provider segments do not become valid merge', () {
    final malformed = sixRaw();
    malformed[3] = jsonEncode({
      'text': 'out of order',
      'segments': [
        {'start': 12, 'end': 13, 'text': 'later'},
        {'start': 11, 'end': 12, 'text': 'earlier'},
      ],
    });
    expect(() => parsed(malformed), throwsStateError);
  });

  testWidgets('all six in-app review exposes entire timeline and user copy',
      (tester) async {
    final review = LabGroqMergedReview.assemble(
      parsed: parsed(sixRaw()), expectedChunkCount: 6,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: LabGroqMergeReviewPanel(review: review),
        ),
      ),
    ));
    expect(find.byKey(const Key('groq-merge-summary')), findsOneWidget);
    expect(find.textContaining('6/6 段'), findsOneWidget);
    expect(find.textContaining('重疊待複核：5'), findsOneWidget);
    expect(find.byKey(const Key('groq-merge-list')), findsOneWidget);
    final copy = find.byKey(const Key('groq-copy-full-merge'));
    expect(tester.widget<OutlinedButton>(copy).onPressed, isNotNull);
    expect(find.textContaining('全段合併檢視'), findsWidgets);
  });

  testWidgets('offline imported JSON review must disclose unverified origin',
      (tester) async {
    final review = LabGroqMergedReview.assemble(
      parsed: parsed(sixRaw()), expectedChunkCount: 6,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LabGroqMergeReviewPanel(
        review: review, verifiedProviderSource: false,
      )),
    ));
    expect(find.textContaining('Provider 身分未驗證'), findsWidgets);
    expect(find.textContaining('本機 JSON：6/6'), findsOneWidget);
    expect(review.buildReviewText(sourceVerified: false),
        contains('Provider 身分未驗證'));
    final copy = find.byKey(const Key('groq-copy-full-merge'));
    expect(tester.widget<OutlinedButton>(copy).onPressed, isNotNull);
  });

  testWidgets('two Raw can be previewed but full merged copy is disabled',
      (tester) async {
    final review = LabGroqMergedReview.assemble(
      parsed: parsed(sixRaw().take(2).toList()),
      expectedChunkCount: 6,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LabGroqMergeReviewPanel(review: review)),
    ));
    expect(find.textContaining('2/6 段'), findsOneWidget);
    expect(find.textContaining('尚未合併完成'), findsOneWidget);
    final copy = find.byKey(const Key('groq-copy-full-merge'));
    expect(tester.widget<OutlinedButton>(copy).onPressed, isNull);
  });
}
