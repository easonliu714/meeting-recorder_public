import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_part_roster.dart';
import 'package:groq_stt_lab/lab_part_native_pts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('groq_stt_lab/offline_audio');
  late Directory root;
  late File file;
  late LabPartReceipt part;
  late Map<String, dynamic> native;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lab_native_pts_');
    file = File(root.path + '/synthetic.aac');
    await file.writeAsBytes([11, 22, 33, 44, 55], flush: true);
    part = await LabPartRoster.append(
      source: file,
      probe: const LabAudioProbe(LabAudioKind.aacM4a,
          'audio/mp4a-latm', 15000000, inputSampleRateHz: 44100),
      previous: const [],
    );
    native = {
      'mime': 'audio/mp4a-latm',
      'sourceBytes': 5,
      'durationUs': 15000000,
      'sampleRate': 44100,
      'firstPtsUs': 23000,
      'lastPtsUs': 14990000,
      'sampleCount': 650,
      'maxGapUs': 24000,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'inspectPartPts');
      expect(call.arguments['sourcePath'], file.path);
      return native;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('real file SHA-bound Android source-local PTS receipt, unchanged',
      () async {
    final sha = await LabAudioPipeline.digest(file);
    const scanner = LabPartNativePtsScanner();
    final found = await scanner.scan([part]);
    expect(found, hasLength(1));
    expect(found.single.kind, LabAudioKind.aacM4a);
    expect(found.single.firstPtsUs, 23000);
    expect(found.single.lastPtsUs, 14990000);
    expect(found.single.sampleCount, 650);
    expect(await LabAudioPipeline.digest(file), sha);
  });

  test('native forged MIME, bytes, clock, count, gaps all HOLD', () async {
    const scanner = LabPartNativePtsScanner();
    for (final bad in [
      {'mime': 'audio/mpeg'},
      {'sourceBytes': 6},
      {'durationUs': 14000000},
      {'sampleRate': 96000},
      {'firstPtsUs': -1},
      {'lastPtsUs': 0},
      {'lastPtsUs': 19000000},
      {'sampleCount': 1},
      {'sampleCount': 750001},
      {'maxGapUs': 1000001},
      {'maxGapUs': 0},
      {'sampleCount': 'not-int'},
    ]) {
      native = {...native, ...bad};
      await expectLater(
        scanner.scan([part]),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'code', 'LAB_PART_NATIVE_PTS_RECEIPT_HOLD')),
      );
      native = {
        'mime': 'audio/mp4a-latm',
        'sourceBytes': 5,
        'durationUs': 15000000,
        'sampleRate': 44100,
        'firstPtsUs': 23000,
        'lastPtsUs': 14990000,
        'sampleCount': 650,
        'maxGapUs': 24000,
      };
    }
  });

  test('source changed before native scan cannot pass', () async {
    await file.writeAsBytes([11, 22, 33, 99, 55], flush: true);
    await expectLater(const LabPartNativePtsScanner().scan([part]),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'code', 'LAB_PART_SOURCE_CHANGED_HOLD')));
    expect(await file.length(), 5);
  });

  test('native Android scan failure is not converted to fake PTS', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'LAB_PART_NATIVE_PTS_NON_MONOTONIC_HOLD');
    });
    await expectLater(const LabPartNativePtsScanner().scan([part]),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code',
            'LAB_PART_NATIVE_PTS_NON_MONOTONIC_HOLD')));
  });
}
