import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_mic_capture.dart';
import 'package:groq_stt_lab/lab_mic_checkpoint.dart';
import 'package:groq_stt_lab/lab_mic_interrupt_probe.dart';
import 'package:groq_stt_lab/lab_debug_log.dart';

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

  test('restart recovery reads two real app-private WAVs by SHA and frames',
      () async {
    const store = LabMicCheckpointStore();
    final capture = await const LabMicCapture().capture(supportRoot: support);
    final before1 = await LabAudioPipeline.digest(first);
    final before2 = await LabAudioPipeline.digest(second);
    await store.save(capture, supportRoot: support);
    final recovered = await const LabMicCheckpointStore()
        .restore(supportRoot: support);
    expect(recovered.sessionId, session);
    expect(recovered.parts.map((p) => p.frameStart), [0, 48000]);
    expect(recovered.parts.map((p) => p.frameEnd), [48000, 96000]);
    expect(recovered.parts.map((p) => p.receipt.bytes), [96044, 96044]);
    await LabMicCapture.verify(recovered);
    expect(await LabAudioPipeline.digest(first), before1);
    expect(await LabAudioPipeline.digest(second), before2);
  });

  test('missing checkpoint and incomplete recorder session hold, retain WAV',
      () async {
    const store = LabMicCheckpointStore();
    await expectLater(
      store.restore(supportRoot: support),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
          'LAB_MIC_CHECKPOINT_MISSING_HOLD')),
    );
    final parent = Directory('${support.path}/lab_mic_capture_v1');
    await File('${parent.path}/latest_source_proof_v1.txt')
        .writeAsString(session, flush: true);
    await expectLater(store.restore(supportRoot: support),
        throwsStateError);
    expect(await first.exists() && await second.exists(), isTrue);
  });

  test('wrong pointer and forged session ID never escape local root',
      () async {
    const store = LabMicCheckpointStore();
    final capture = await const LabMicCapture().capture(supportRoot: support);
    await store.save(capture, supportRoot: support);
    final pointer = File(
      '${support.path}/lab_mic_capture_v1/latest_source_proof_v1.txt');
    for (final forged in ['../escape', List.filled(36, 'x').join(), List.filled(30, 'invalid').join()]) {
      await pointer.writeAsString(forged, flush: true);
      await expectLater(store.restore(supportRoot: support),
          throwsStateError);
    }
    await pointer.writeAsString(session, flush: true);
    expect((await store.restore(supportRoot: support)).sessionId, session);
  });

  test('altered or truncated source is rejected without deleting original',
      () async {
    const store = LabMicCheckpointStore();
    await store.save(
      await const LabMicCapture().capture(supportRoot: support),
      supportRoot: support,
    );
    final bytes = await second.readAsBytes();
    bytes[51] ^= 1;
    await second.writeAsBytes(bytes, flush: true);
    await expectLater(
      store.restore(supportRoot: support),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
          'LAB_MIC_CHECKPOINT_SOURCE_HOLD')),
    );
    expect(await first.exists() && await second.exists(), isTrue);
  });

  test('manifest forged frames, file, ID and SHA fail closed',
      () async {
    const store = LabMicCheckpointStore();
    await store.save(
      await const LabMicCapture().capture(supportRoot: support),
      supportRoot: support,
    );
    final manifest = File(
      '${support.path}/lab_mic_capture_v1/$session/source_proof_v1.json');
    final original = await manifest.readAsString();
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (o) => (o['parts'] as List)[1]['frameStart'] = 47000,
      (o) => (o['parts'] as List)[1]['index'] = 1,
      (o) => (o['parts'] as List)[1]['file'] = '../part_02.wav',
      (o) => (o['parts'] as List)[1]['sha256'] = List.filled(64, 'f').join(),
      (o) => o['sessionId'] = 'deadbeef-0000-4444-8000-123456789abc',
      (o) => o['sampleRate'] = 44100,
      (o) => o['endedMonoNs'] = 9000000000,
    ]) {
      final json = Map<String, dynamic>.from(jsonDecode(original) as Map);
      mutate(json);
      await manifest.writeAsString(jsonEncode(json), flush: true);
      await expectLater(store.restore(supportRoot: support), throwsStateError);
    }
    await manifest.writeAsString(original, flush: true);
    expect((await store.restore(supportRoot: support)).parts, hasLength(2));
  });

  test('immutable receipt cannot be overwritten and original remains',
      () async {
    const store = LabMicCheckpointStore();
    final captured = await const LabMicCapture().capture(supportRoot: support);
    await store.save(captured, supportRoot: support);
    final manifest = File(
      '${support.path}/lab_mic_capture_v1/$session/source_proof_v1.json');
    final digest = await LabAudioPipeline.digest(manifest);
    await expectLater(
      store.save(captured, supportRoot: support),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
          'LAB_MIC_CHECKPOINT_EXISTS_HOLD')),
    );
    expect(await LabAudioPipeline.digest(manifest), digest);
    expect(await first.exists() && await second.exists(), isTrue);
  });

  test('fresh install missing capture parent has exact missing HOLD', () async {
    final empty = Directory('${support.path}/fresh');
    await empty.create();
    await expectLater(
      const LabMicCheckpointStore().restore(supportRoot: empty),
      throwsA(isA<StateError>().having((e) => LabDebugJournal.failureCode(e),
          'safe code', 'LAB_MIC_CHECKPOINT_MISSING_HOLD')),
    );
    expect(await Directory('${empty.path}/lab_mic_capture_v1').exists(), isFalse);
  });

  Future<Directory> makeInterruptAttempt({bool committed = true}) async {
    final parent = Directory('${support.path}/lab_mic_interrupt_v1');
    final folder = Directory('${parent.path}/$session');
    await folder.create(recursive: true);
    await File('${parent.path}/latest_attempt_v1.txt')
        .writeAsString(session, flush: true);
    final wav = await makeWav(File('${folder.path}/part_01.wav'), 43);
    final manifest = {
      'schema': 1, 'sessionId': session, 'sampleRate': 16000,
      'index': 1, 'file': 'part_01.wav', 'bytes': 96044,
      'sha256': await LabAudioPipeline.digest(wav),
      'frameStart': 0, 'frameEnd': 48000,
    };
    await File('${folder.path}/${committed ? 'part_01_commit_v1.json' : 'part_01_commit.tmp'}')
        .writeAsString(jsonEncode(manifest), flush: true);
    await File('${folder.path}/part_02_inflight.pcm')
        .writeAsBytes(List<int>.generate(15360, (i) => i % 251), flush: true);
    return folder;
  }

  test('incomplete attempt recovers exactly committed Part 1, preserves tail',
      () async {
    final folder = await makeInterruptAttempt();
    final wav = File('${folder.path}/part_01.wav');
    final tail = File('${folder.path}/part_02_inflight.pcm');
    final before = await LabAudioPipeline.digest(wav);
    final tailSha = await LabAudioPipeline.digest(tail);
    final restored = await const LabMicInterruptProbe().recover(supportRoot: support);
    expect(restored.part.sha256, before);
    expect(restored.part.bytes, 96044);
    expect(restored.part.durationMs, 3000);
    expect(restored.part.logicalStartMs, 0);
    expect(restored.part.logicalEndMs, 3000);
    expect(restored.tailBytes, 15360);
    expect(await LabAudioPipeline.digest(wav), before);
    expect(await LabAudioPipeline.digest(tail), tailSha);
  });

  test('fresh interruption root and uncommitted receipt fail closed',
      () async {
    const probe = LabMicInterruptProbe();
    await expectLater(probe.recover(supportRoot: support),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
          'LAB_MIC_INTERRUPT_MISSING_HOLD')));
    final folder = await makeInterruptAttempt(committed: false);
    await expectLater(probe.recover(supportRoot: support),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
          'LAB_MIC_INTERRUPT_UNCOMMITTED_HOLD')));
    expect(await File('${folder.path}/part_01.wav').exists(), isTrue);
    expect(await File('${folder.path}/part_02_inflight.pcm').exists(), isTrue);
  });

  test('completed attempt is never described as interrupted recovery', () async {
    final folder = await makeInterruptAttempt();
    await File('${folder.path}/finished_v1.txt').writeAsString('completed');
    await expectLater(
      const LabMicInterruptProbe().recover(supportRoot: support),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
          'LAB_MIC_INTERRUPT_NOT_INCOMPLETE_HOLD')));
  });

  test('interrupted prefix mutation and forged receipt fail closed', () async {
    final folder = await makeInterruptAttempt();
    final commit = File('${folder.path}/part_01_commit_v1.json');
    final original = await commit.readAsString();
    for (final change in [
      {'frameEnd': 47999}, {'file': '../part_01.wav'}, {'index': 2},
      {'sampleRate': 8000}, {'sessionId': '../other'},
    ]) {
      final data = Map<String, dynamic>.from(jsonDecode(original) as Map);
      await commit.writeAsString(jsonEncode({...data, ...change}), flush: true);
      await expectLater(
        const LabMicInterruptProbe().recover(supportRoot: support),
        throwsA(isA<StateError>().having((e) => e.message, 'code',
            'LAB_MIC_INTERRUPT_FORMAT_HOLD')));
    }
    await commit.writeAsString(original, flush: true);
    final wav = File('${folder.path}/part_01.wav');
    final bytes = await wav.readAsBytes();
    bytes[52] ^= 1;
    await wav.writeAsBytes(bytes, flush: true);
    await expectLater(
      const LabMicInterruptProbe().recover(supportRoot: support),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
          'LAB_MIC_INTERRUPT_SOURCE_HOLD')));
    expect(await wav.exists(), isTrue);
  });

  test('interrupted tail is never resolved through an untrusted link', () async {
    final folder = await makeInterruptAttempt();
    final tail = File('${folder.path}/part_02_inflight.pcm');
    await tail.rename('${folder.path}/retained_tail.pcm');
    await Link(tail.path).create(first.path);
    await expectLater(
      const LabMicInterruptProbe().recover(supportRoot: support),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
          'LAB_MIC_INTERRUPT_PATH_HOLD')));
    expect(await first.exists(), isTrue);
  });

  test('interruption probe bridge requires explicit start and stop', () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'startLabMicInterruptProbe') {
        return {'status': 'stopped', 'committedParts': 1};
      }
      if (call.method == 'stopLabMicInterruptProbe') return null;
      throw PlatformException(code: 'UNEXPECTED_TEST_METHOD');
    });
    const probe = LabMicInterruptProbe();
    final folder = await makeInterruptAttempt();
    expect(folder.existsSync(), isTrue);
    await probe.recover(supportRoot: support);
    expect(methods, isEmpty);
    expect(await probe.start(), 'stopped');
    await probe.stop();
    expect(methods, ['startLabMicInterruptProbe', 'stopLabMicInterruptProbe']);
  });
}
