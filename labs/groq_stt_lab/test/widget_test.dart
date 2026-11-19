import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/main.dart';

/// Explicitly replaces Flutter's generated MyApp template smoke test.
void main() {
  testWidgets('Private Lab retains offline stage until a chunk is explicitly selected and consented',
      (tester) async {
    await tester.pumpWidget(const GroqLabApp());
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('Groq STT Lab｜Free＋離線'), findsOneWidget);
    expect(find.textContaining('支援原生 RIFF/WAV PCM16'), findsOneWidget);
    expect(find.byKey(const Key('stage-audio')), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('stage-audio'))).onPressed,
      isNull,
    );
  });
}
