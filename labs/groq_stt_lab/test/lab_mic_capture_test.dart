import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_mic_capture.dart';

Future<File> makeWav(File file, int seed) async {
  const frames = 48000;
  final bytes = Uint8List(44 + frames * 2);
  final view = ByteData.sublistView(bytes);
  void stringAt(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes[offset + i] = value.codeUnitAt(i);
    }
  }
  stringAt(0, 'RIFF');
  view.setUint32(4, bytes.length - 8, Endian.little);
  stringAt(8, 'WAVE');
  stringAt(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, 1, Endian.little);
  view.setUint32(24, 16000, Endian.little);
  view.setUint32(28, 32000, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  stringAt(36, 'data');
  view.setUint32(40, frames * 2, Endian.little);
  for (var n = 0; n < frames; n++) {
    view.setInt16(44 + n * 2,
        ((n * (seed + 127)) % 65536) - 32768, Endian.little);
  }
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('groq_stt_lab/offline_audio');
  const session = '1a2b3c4d-1111-4222-8333-123456789abc';
  late Directory support;
  late File first;
  late File second;
  late Map<String, dynamic> native;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('lab_mic_capture_');
    final folder = Directory(
      '${support.path}/lab_mic_capture_v1/$session');
    await folder.create(recursive: true);
    first = await makeWav(File('${folder.path}/part_01.wav'), 31);
    second = await makeWav(File('${folder.path}/part_02.wav'), 37);
    final sha1 = await LabAudioPipeline.digest(first);
    final sha2 = await LabAudioPipeline.digest(second);
    native = {
      'sessionId': session,
      'sampleRate': 16000,
      'startedMonoNs': 9000000000,
      'endedMonoNs': 15000000000,
      'parts': [
        {
          'index': 1, 'path': first.path, 'bytes': 96044,
          'sha256': sha1, 'frameStart': 0, 'frameEnd': 48000,
        },
        {
          'index': 2, 'path': second.path, 'bytes': 96044,
          'sha256': sha2, 'frameStart': 48000, 'frameEnd': 96000,
        },
      ],
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'captureLabMicParts');
        return native;
      });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null);
    if (await support.exists()) await support.delete(recursive: true);
  });

  test('two actual WAV physical files attest one 0–96000 sample clock',
      () async {
    final before1 = await LabAudioPipeline.digest(first);
    final before2 = await LabAudioPipeline.digest(second);
    final found = await const LabMicCapture().capture(supportRoot: support);
    expect(found.parts, hasLength(2));
    expect(found.parts.map((p) => p.frameStart), [0, 48000]);
    expect(found.parts.map((p) => p.frameEnd), [48000, 96000]);
    expect(found.parts.map((p) => p.receipt.durationMs), [3000, 3000]);
    expect(found.parts.last.receipt.logicalEndMs, 6000);
    await LabMicCapture.verify(found);
    expect(await LabAudioPipeline.digest(first), before1);
    expect(await LabAudioPipeline.digest(second), before2);
  });

  test('forged native sample clock and receipt metadata fail closed',
      () async {
    for (final change in [
      {'frameStart': 47000}, {'frameEnd': 92000},
      {'bytes': 96046}, {'index': 1},
      {'sha256': List.filled(64, 'f').join()},
    ]) {
      final parts = List<Map<String, dynamic>>.from(
          (native['parts'] as List).map((e) => Map<String, dynamic>.from(e)));
      parts[1] = {...parts[1], ...change};
      native = {...native, 'parts': parts};
      await expectLater(
        const LabMicCapture().capture(supportRoot: support),
        throwsStateError,
      );
      native = {...native, 'parts': [
        (native['parts'] as List).first, {
          ...parts[1],
          'index': 2, 'frameStart': 48000, 'frameEnd': 96000,
          'bytes': 96044,
          'sha256': await LabAudioPipeline.digest(second)
        }
      ]};
    }
  });

  test('forged session timeline and path cannot cross app-owned root',
      () async {
    for (final bad in [
      {...native, 'sampleRate': 44100},
      {...native, 'startedMonoNs': 0},
      {...native, 'endedMonoNs': 10000000000},
      {...native, 'sessionId': '../escape'},
      {...native, 'parts': [
        {...(native['parts'] as List).first, 'path': '/storage/emulated/0/a.wav'},
        (native['parts'] as List).last,
      ]},
    ]) {
      native = bad;
      await expectLater(
          const LabMicCapture().capture(supportRoot: support),
          throwsStateError);
    }
  });

  test('tampered local source SHA cannot become valid evidence', () async {
    final bytes = await second.readAsBytes();
    bytes[50] ^= 1;
    await second.writeAsBytes(bytes, flush: true);
    await expectLater(
        const LabMicCapture().capture(supportRoot: support),
        throwsA(isA<StateError>().having((e) => e.message, 'code',
            'LAB_MIC_SOURCE_CHANGED_HOLD')));
    expect(await second.exists(), isTrue);
  });

  test('permission denial never creates forged session receipt', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'LAB_MIC_PERMISSION_REQUIRED_HOLD');
      });
    await expectLater(
      const LabMicCapture().capture(supportRoot: support),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code',
          'LAB_MIC_PERMISSION_REQUIRED_HOLD')),
    );
  });
}
