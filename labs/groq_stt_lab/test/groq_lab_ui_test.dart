import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/main.dart';

void main() {
  testWidgets('LAB-0 starts offline, without a selected file or Groq call',
      (tester) async {
    await tester.pumpWidget(const GroqLabApp());
    expect(find.text('Groq STT Lab｜Free＋離線'), findsOneWidget);
    expect(find.byKey(const Key('choose-audio')), findsOneWidget);
    final stage = tester.widget<FilledButton>(
        find.byKey(const Key('stage-audio')));
    expect(stage.onPressed, isNull);
    expect(find.textContaining('只有在逐段明確確認後才會傳送'), findsOneWidget);
  });
}
