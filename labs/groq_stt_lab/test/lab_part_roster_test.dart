import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';
import 'package:groq_stt_lab/lab_part_roster.dart';

Future<File> wav(String path, int secs) async {
  const rate = 8000;
  final count = 44 + rate * secs * 2;
  final data = Uint8List(count);
  final head = ByteData.sublistView(data);
  void put(int pos, String str) =>
      data.setRange(pos, pos + str.length, str.codeUnits);
  put(0, 'RIFF');
  head.setUint32(4, count - 8, Endian.little);
  put(8, 'WAVE');
  put(12, 'fmt ');
  head.setUint32(16, 16, Endian.little);
  head.setUint16(20, 1, Endian.little);
  head.setUint16(22, 1, Endian.little);
  head.setUint32(24, rate, Endian.little);
  head.setUint32(28, rate * 2, Endian.little);
  head.setUint16(32, 2, Endian.little);
  head.setUint16(34, 16, Endian.little);
  put(36, 'data');
  head.setUint32(40, count - 44, Endian.little);
  final file = File(path);
  await file.writeAsBytes(data, flush: true);
  return file;
}

Future<File> patternedWav(String path, int startSecond, int seconds) async {
  final source = await wav(path, seconds);
  final bytes = await source.readAsBytes();
  final data = ByteData.sublistView(bytes);
  for (var frame = 0; frame < 8000 * seconds; frame++) {
    data.setInt16(44 + frame * 2,
        ((startSecond * 8000 + frame) * 137) % 65536 - 32768, Endian.little);
  }
  await source.writeAsBytes(bytes, flush: true);
  return source;
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lab_parts_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  const probe = LabAudioProbe(LabAudioKind.wavPcm16, 'audio/wav', null);

  test('physical 2+3s WAV Parts attest SHA and contiguous duration clock',
      () async {
    final a = await wav(root.path + '/a.wav', 2);
    final b = await wav(root.path + '/b.wav', 3);
    final one = await LabPartRoster.append(
        source: a, probe: probe, previous: const []);
    final two = await LabPartRoster.append(
        source: b, probe: probe, previous: [one]);
    expect([one.logicalStartMs, one.logicalEndMs], [0, 2000]);
    expect([two.logicalStartMs, two.logicalEndMs], [2000, 5000]);
    expect(one.sha256, await LabAudioPipeline.digest(a));
    await LabPartRoster.verify([one, two]);
    expect(await a.exists() && await b.exists(), isTrue);
  });

  test('same-byte tamper blocks next receipt without deleting source',
      () async {
    final a = await wav(root.path + '/a.wav', 2);
    final b = await wav(root.path + '/b.wav', 3);
    final one = await LabPartRoster.append(
        source: a, probe: probe, previous: const []);
    final bytes = await a.readAsBytes();
    bytes[48] = 77;
    await a.writeAsBytes(bytes, flush: true);
    await expectLater(
        LabPartRoster.append(source: b, probe: probe, previous: [one]),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'code', 'LAB_PART_SOURCE_CHANGED_HOLD')));
    expect(await a.readAsBytes(), bytes);
    expect(await b.exists(), isTrue);
  });

  test('duplicate source hash blocks replay and preserves both files',
      () async {
    final a = await wav(root.path + '/a.wav', 2);
    final b = File(root.path + '/b.wav');
    await b.writeAsBytes(await a.readAsBytes());
    final one = await LabPartRoster.append(
        source: a, probe: probe, previous: const []);
    await expectLater(
        LabPartRoster.append(source: b, probe: probe, previous: [one]),
        throwsStateError);
    expect(await a.exists() && await b.exists(), isTrue);
  });

  test('corrupt RIFF and contradictory MP3 metadata remain HOLD', () async {
    final a = await wav(root.path + '/a.wav', 2);
    await a.writeAsBytes([1, 2, 3], flush: true);
    await expectLater(
        LabPartRoster.append(source: a, probe: probe, previous: const []),
        throwsFormatException);
    final b = File(root.path + '/b.mp3');
    await b.writeAsBytes([1, 2, 3, 4], flush: true);
    for (final wrong in [
      const LabAudioProbe(LabAudioKind.mp3, 'audio/mp4a-latm', 1000000,
          inputSampleRateHz: 16000),
      const LabAudioProbe(LabAudioKind.mp3, 'audio/mpeg', 1000000),
      const LabAudioProbe(LabAudioKind.mp3, 'audio/mpeg', 7200001000,
          inputSampleRateHz: 16000),
    ]) {
      await expectLater(
          LabPartRoster.append(source: b, probe: wrong, previous: const []),
          throwsStateError);
    }
    expect(await b.length(), 4);
  });

  test('two real WAVs with 2s shared samples attest without source writes',
      () async {
    final a = await patternedWav(root.path + '/a.wav', 0, 4);
    final b = await patternedWav(root.path + '/b.wav', 2, 4);
    final shaA = await LabAudioPipeline.digest(a);
    final shaB = await LabAudioPipeline.digest(b);
    final one = await LabPartRoster.append(
        source: a, probe: probe, previous: const []);
    final two = await LabPartRoster.append(
        source: b, probe: probe, previous: [one]);
    expect(await LabPartRoster.verifyWavBoundary([one, two], 1), 32000);
    expect(two.logicalEndMs, 8000); // not global Recorder PTS
    expect(await LabAudioPipeline.digest(a), shaA);
    expect(await LabAudioPipeline.digest(b), shaB);
  });

  test('mismatched audio and short segments HOLD safely', () async {
    final a = await patternedWav(root.path + '/a.wav', 0, 4);
    final b = await patternedWav(root.path + '/b.wav', 3, 4);
    final one = await LabPartRoster.append(
        source: a, probe: probe, previous: const []);
    final two = await LabPartRoster.append(
        source: b, probe: probe, previous: [one]);
    await expectLater(
      LabPartRoster.verifyWavBoundary([one, two], 1),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
          'LAB_PART_WAV_SEAM_MISMATCH_HOLD')));
    await expectLater(LabPartRoster.verifyWavBoundary([one, two], 0),
        throwsStateError);
    final shortA = await patternedWav(root.path + '/shortA.wav', 0, 1);
    final shortB = await patternedWav(root.path + '/shortB.wav', 1, 1);
    final sa = await LabPartRoster.append(
        source: shortA, probe: probe, previous: const []);
    final sb = await LabPartRoster.append(
        source: shortB, probe: probe, previous: [sa]);
    await expectLater(
      LabPartRoster.verifyWavBoundary([sa, sb], 1),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
          'LAB_PART_WAV_SEAM_SHORT_HOLD')));
    expect(await a.exists() && await b.exists(), isTrue);
  });

  test('identical silence is not acceptable acoustic evidence', () async {
    final a = await patternedWav(root.path + '/a.wav', 0, 4);
    final b = await patternedWav(root.path + '/b.wav', 2, 4);
    final ab = await a.readAsBytes();
    ab.fillRange(44 + 2 * 16000, 44 + 4 * 16000, 0);
    await a.writeAsBytes(ab, flush: true);
    final bb = await b.readAsBytes();
    bb.fillRange(44, 44 + 2 * 16000, 0);
    await b.writeAsBytes(bb, flush: true);
    final one = await LabPartRoster.append(
        source: a, probe: probe, previous: const []);
    final two = await LabPartRoster.append(
        source: b, probe: probe, previous: [one]);
    await expectLater(
      LabPartRoster.verifyWavBoundary([one, two], 1),
      throwsA(isA<StateError>().having((e) => e.message, 'code',
          'LAB_PART_WAV_SEAM_SILENCE_HOLD')));
  });

  test('reordered and deleted Part receipts never verify', () async {
    final a = await wav(root.path + '/a.wav', 2);
    final b = await wav(root.path + '/b.wav', 3);
    final one = await LabPartRoster.append(
        source: a, probe: probe, previous: const []);
    final two = await LabPartRoster.append(
        source: b, probe: probe, previous: [one]);
    await expectLater(LabPartRoster.verify([two, one]), throwsStateError);
    await b.delete();
    await expectLater(LabPartRoster.verify([one, two]), throwsStateError);
    expect(await a.exists(), isTrue);
  });
}
