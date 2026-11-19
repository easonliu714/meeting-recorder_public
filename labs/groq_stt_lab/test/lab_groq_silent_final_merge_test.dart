import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_groq_merged_review.dart';
import 'package:groq_stt_lab/lab_groq_merge_review_panel.dart';
import 'package:groq_stt_lab/lab_groq_raw_receipt_store.dart';
import 'package:groq_stt_lab/lab_stt_raw_preview.dart';

const sourceSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const wireSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

List<LabStagedChunk> sixPhysicalWindows() => [
  for (var index = 0; index < 6; index++)
    LabStagedChunk(
      file: File('nonexistent_test_only_chunk_$index.wav'),
      byteCount: index == 0 ? 19197484 : 19261484,
      sha256Hex: wireSha,
      coreStartMs: index * 599920,
      coreEndMs: (index + 1) * 599920,
      wireStartMs: index == 0 ? 0 : index * 599920 - 2000,
      wireEndMs: (index + 1) * 599920,
    ),
];

String verbose(String text, List<Map<String, Object?>> segments) =>
    jsonEncode({'text': text, 'language': 'zh', 'segments': segments});

List<String> fiveSpeech() => [
  for (var i = 0; i < 5; i++)
    verbose('第' + (i + 1).toString() + '段有效語音', [
      {'start': 2.0, 'end': 3.5,
       'text': '第' + (i + 1).toString() + '段有效語音'},
    ]),
];

LabGroqMergedReview mergeSix(List<String> raws) =>
    LabGroqMergedReview.assemble(
      parsed: LabSttRawPreview.fromSavedGroqPrefix(
        staged: sixPhysicalWindows(),
        originalSourceSha256: sourceSha,
        savedRawPrefix: raws,
      ),
      expectedChunkCount: 6,
    );

void main() {
  test('six receipts: blank timed segments do not erase first five', () {
    final raw = [
      ...fiveSpeech(),
      verbose('', [
        {'start': 0.0, 'end': 0.0, 'text': ' '},
        {'start': 1.0, 'end': 2.0, 'text': ''},
      ]),
    ];
    final snapshot = List<String>.of(raw);
    final review = mergeSix(raw);
    expect(review.allRawReceived, isTrue);
    expect(review.isSixChunkMergeReady, isTrue);
    expect(review.chunksSaved, 6);
    expect(review.timeline, hasLength(5));
    expect(review.timeline.every((x) => x.chunkIndex < 5), isTrue);
    expect(review.textlessChunkIndices, [5]);
    final report = review.buildReviewText();
    for (var i = 1; i <= 5; i++) {
      expect(report, contains('第' + i.toString() + '段有效語音'));
    }
    expect(report, contains('已保存 Chunk：6/6'));
    expect(report, contains('Chunk 6'));
    expect(report, contains('不補造文字'));
    expect(raw, snapshot); // no mutation of immutable provider responses
  });

  test('six receipts: truly silent sixth with empty segments still completes', () {
    final review = mergeSix([...fiveSpeech(), verbose('', [])]);
    expect(review.allRawReceived, isTrue);
    expect(review.timeline, hasLength(5));
    expect(review.textlessChunkIndices, [5]);
    expect(review.buildReviewText(), contains('已保存 Chunk：6/6'));
  });

  test('six receipts: blank and real segments mixed in sixth preserve speech', () {
    final review = mergeSix([
      ...fiveSpeech(),
      verbose('第六段有效語音', [
        {'start': 0.0, 'end': 0.0, 'text': ''},
        {'start': 2.0, 'end': 3.0, 'text': '第六段有效語音'},
        {'start': 3.0, 'end': 3.0, 'text': '  '},
      ]),
    ]);
    expect(review.timeline, hasLength(6));
    expect(review.timeline.last.rawText, '第六段有效語音');
    expect(review.timeline.last.chunkIndex, 5);
    expect(review.timeline.last.globalStartMs, 2999600);
    expect(review.allRawReceived, isTrue);
  });

  test('five receipts cannot produce full merged report', () {
    final review = mergeSix(fiveSpeech());
    expect(review.chunksSaved, 5);
    expect(review.allRawReceived, isFalse);
    expect(() => review.buildReviewText(), throwsStateError);
  });

  test('non-string, missing clock and unaligned real speech remain HOLD', () {
    final cases = [
      verbose('nonempty', []),
      verbose('claimed speech', [
        {'start': 0, 'end': 0, 'text': ''},
      ]),
      jsonEncode({'text': '', 'segments': [
        {'start': 0, 'end': 1, 'text': null},
      ]}),
      jsonEncode({'text': '', 'segments': [
        {'end': 1, 'text': ' '},
      ]}),
      verbose('', [
        {'start': -1, 'end': 0, 'text': ''},
      ]),
      verbose('', [
        {'start': 3.0, 'end': 2.0, 'text': ' '},
      ]),
    ];
    for (final last in cases) {
      expect(() => mergeSix([...fiveSpeech(), last]), throwsStateError);
    }
  });

  test('silent receipt persisted and re-read by SHA without retry', () async {
    final dir = await Directory.systemTemp.createTemp('groq_blank_receipt_');
    try {
      final store = LabGroqRawReceiptStore(dir);
      final bytes = utf8.encode(verbose('', [
        {'start': 0.0, 'end': 0.0, 'text': ' '},
      ]));
      final receipt = await store.writeOnce('chunk6', bytes);
      expect(receipt.sha256Hex, sha256.convert(bytes).toString());
      final recovered = await store.inspectComplete('chunk6');
      expect(recovered, isNotNull);
      expect(recovered!.sha256Hex, receipt.sha256Hex);
      final raw = await store.readVerified('chunk6', receipt.sha256Hex);
      final review = mergeSix([...fiveSpeech(), raw]);
      expect(review.allRawReceived, isTrue);
      expect(review.timeline.length, 5);
      await expectLater(store.writeOnce('chunk6', bytes), throwsStateError);
    } finally {
      // Only test-owned sandbox, never owner audio, Raw or Journal.
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  testWidgets('six saved receipts with silent sixth enable full output', (tester) async {
    final review = mergeSix([...fiveSpeech(), verbose('', [])]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: SingleChildScrollView(
        child: LabGroqMergeReviewPanel(review: review),
      ),
    )));
    expect(find.textContaining('6/6 段'), findsOneWidget);
    expect(find.byKey(const Key('groq-merge-empty-chunks')), findsOneWidget);
    expect(find.textContaining('Chunk 6'), findsWidgets);
    final copy = find.byKey(const Key('groq-copy-full-merge'));
    expect(tester.widget<OutlinedButton>(copy).onPressed, isNotNull);
  });
}
