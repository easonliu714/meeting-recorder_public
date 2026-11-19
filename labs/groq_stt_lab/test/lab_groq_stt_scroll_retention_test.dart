import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_debug_log.dart';
import 'package:groq_stt_lab/lab_groq_stt_panel.dart';

const originalSha =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final chunkSha = List<String>.generate(6, (i) =>
    List.filled(64, (i + 1).toString()).join());

final stages = List<LabStagedChunk>.generate(6, (i) => LabStagedChunk(
  file: File('not_read_by_ui_test.wav'),
  byteCount: 1920044,
  sha256Hex: chunkSha[i],
  coreStartMs: i * 60000,
  coreEndMs: (i + 1) * 60000,
  wireStartMs: i == 0 ? 0 : i * 60000 - 2000,
  wireEndMs: (i + 1) * 60000,
));

void main() {
  testWidgets(
      'LAB-3 keeps its input and imported-session widget alive after '
      'scrolling to the debug-log area and back',
      (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final debug = LabDebugJournal();

    // Deliberately put LAB-3 outside the initial SliverList viewport/cache.
    // If AutomaticKeepAliveClientMixin is removed, the owner-entered fields
    // and imported ZIP session are disposed when scrolling to the page top.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          controller: scroll,
          children: [
            const SizedBox(height: 1600, child: Text('Debug Log at top')),
            LabGroqSttPanel(
              key: const Key('lab-groq-stateful-session'),
              sourceFile: File('not_read_by_ui_test.wav'),
              originalSourceSha256: originalSha,
              chunks: stages,
              debugJournal: debug,
              onAvailableRawPrefix: (_) {},
            ),
            const SizedBox(height: 1800, child: Text('Below the session')),
          ],
        ),
      ),
    ));

    scroll.jumpTo(1700);
    await tester.pumpAndSettle();

    final panelFinder = find.byKey(
        const Key('lab-groq-stateful-session'));
    expect(panelFinder, findsOneWidget);
    final originalState = tester.state(panelFinder);

    final header = find.text('LAB-3｜分段 STT ZIP＋Gemini Free AI 草稿');
    await tester.ensureVisible(header);
    await tester.tap(header);
    await tester.pumpAndSettle();

    final participants = find.byKey(const Key('ai-participants'));
    await tester.ensureVisible(participants);
    await tester.enterText(participants, '本機使用者輸入應保留');
    await tester.pump();
    expect(tester.widget<TextField>(participants).controller!.text,
        '本機使用者輸入應保留');

    // The owner scrolls to the top Debug Log, switches through Android
    // share/screenshot UI, then returns to LAB-3.
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    scroll.jumpTo(1700);
    await tester.pumpAndSettle();

    final returnedState = tester.state(panelFinder);
    expect(identical(originalState, returnedState), isTrue,
        reason: 'Offscreen sliver cleanup must not discard LAB-3 State.');
    expect(tester.widget<TextField>(participants).controller!.text,
        '本機使用者輸入應保留');
    expect(tester.takeException(), isNull);
  });
}
