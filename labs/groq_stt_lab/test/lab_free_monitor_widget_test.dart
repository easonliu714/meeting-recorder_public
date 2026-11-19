import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/main.dart';

void main() {
  testWidgets('Free cooldown UAT is explicit MOCK, never provider upload', (tester) async {
    await tester.pumpWidget(const GroqLabApp());
    await tester.ensureVisible(find.byKey(const Key('free-monitor-offline')));
    await tester.tap(find.byKey(const Key('free-monitor-offline')));
    await tester.pumpAndSettle();

    expect(find.textContaining('僅模擬 HTTP 回應'), findsOneWidget);
    expect(find.textContaining('觀測請求：0'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('free-mock-200')));
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('free-mock-200')));
    await tester.pump();
    expect(find.textContaining('觀測請求：1'), findsOneWidget);
    expect(find.textContaining('成功：1'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('free-mock-429')));
    await tester.tap(find.byKey(const Key('free-mock-429')));
    await tester.pump();
    expect(find.textContaining('觀測請求：2'), findsOneWidget);
    expect(find.textContaining('429：1'), findsOneWidget);
    expect(find.textContaining('COOLING_DOWN'), findsOneWidget);
  });

  testWidgets('413 is a visible permanent hold rather than retry', (tester) async {
    await tester.pumpWidget(const GroqLabApp());
    await tester.ensureVisible(find.byKey(const Key('free-monitor-offline')));
    await tester.tap(find.byKey(const Key('free-monitor-offline')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('free-mock-413')));
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('free-mock-413')));
    await tester.pump();
    expect(find.textContaining('WIRE_TOO_LARGE_STOP'), findsOneWidget);
    expect(find.textContaining('其他失敗：1'), findsOneWidget);
  });
}
