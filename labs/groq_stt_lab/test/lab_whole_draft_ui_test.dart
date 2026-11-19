import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_groq_ai_review_panel.dart';
import 'package:groq_stt_lab/lab_whole_draft_store.dart';

const sourceSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final sixHashes = List<String>.generate(6, (i) =>
    List.filled(64, (i + 1).toString()).join());
final stages = List<LabStagedChunk>.generate(6, (i) => LabStagedChunk(
    file: File('chunk.wav'),
    byteCount: 1920044,
    sha256Hex: sixHashes[i],
    coreStartMs: i * 60000,
    coreEndMs: (i + 1) * 60000,
    wireStartMs: i == 0 ? 0 : i * 60000 - 2000,
    wireEndMs: (i + 1) * 60000));

void main() {
  testWidgets('restored whole draft has a share action ABOVE bounded preview',
      (tester) async {
    // The disk store is tested by pure async unit tests. WidgetTester uses
    // a fake clock; inject an already checksum-validated record here.
    final recovered = LabRecoveredWholeDraft(
      text: List.filled(400, '全段原文，不應因長頁捲動消失。').join(),
      model: 'gemini-2.5-flash',
      sha256: List.filled(64, 'a').join(),
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: SingleChildScrollView(child: LabGroqAiReviewPanel(
        staged: stages,
        sourceSha256: sourceSha,
        savedRawByIndex: const {},
        savedRawShaByIndex: {
          for (var i = 0; i < sixHashes.length; i++) i: sixHashes[i],
        },
        restoreDraftForTest: (source, raw) async {
          expect(source, sourceSha);
          expect(raw, sixHashes);
          return recovered;
        },
      )),
    )));
    await tester.tap(find.byKey(const Key('ai-review-panel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.byKey(const Key('ai-export-whole-timed-top')), findsOneWidget);
    expect(find.byKey(const Key('ai-share-whole-top')), findsOneWidget);
    expect(find.byKey(const Key('ai-whole-scroll-preview')), findsOneWidget);
    expect(find.textContaining('已從本機保存檔恢復'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(
        find.byKey(const Key('ai-share-whole-top'))).onPressed, isNotNull);
    final top = tester.getTopLeft(find.byKey(const Key('ai-share-whole-top')));
    final timed = tester.getTopLeft(find.byKey(const Key('ai-export-whole-timed-top')));
    final preview = tester.getTopLeft(
        find.byKey(const Key('ai-whole-scroll-preview')));
    expect(top.dy, lessThan(preview.dy));
    expect(timed.dy, lessThan(top.dy));
    // Regression: collapsing and expanding LAB-3 must not dispose the
    // long-form preview's Scrollable State or its saved draft.
    final previewScroll = find.descendant(
      of: find.byKey(const Key('ai-whole-scroll-preview')),
      matching: find.byType(Scrollable),
    ).first;
    final previewState = tester.state<ScrollableState>(previewScroll);
    final header = find.text('LAB-3｜分段 STT ZIP＋Gemini Free AI 草稿');
    await tester.ensureVisible(header);
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-share-whole-top')), findsNothing);
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(identical(
        previewState,
        tester.state<ScrollableState>(find.descendant(
          of: find.byKey(const Key('ai-whole-scroll-preview')),
          matching: find.byType(Scrollable),
        ).first)), isTrue);
    expect(find.textContaining('已從本機保存檔恢復'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
