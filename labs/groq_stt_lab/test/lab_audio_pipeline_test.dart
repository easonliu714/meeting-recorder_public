import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';

Uint8List testWav({int rate = 8000, int seconds = 8}) {
  final bytes = 44 + rate * seconds * 2;
  final buffer = Uint8List(bytes);
  final d = ByteData.sublistView(buffer);
  void put(int at, String text) =>
      buffer.setRange(at, at + text.length, text.codeUnits);
  put(0, 'RIFF');
  d.setUint32(4, bytes - 8, Endian.little);
  put(8, 'WAVE');
  put(12, 'fmt ');
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, rate, Endian.little);
  d.setUint32(28, rate * 2, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  put(36, 'data');
  d.setUint32(40, bytes - 44, Endian.little);
  return buffer;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('groq_stt_lab/offline_audio');
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lab_v2_audio_test_');
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('FilePicker Android cache source stages under separate support directory', () async {
    final pickerCache = Directory('${root.path}/android_cache');
    await pickerCache.create(recursive: true);
    final source = File('${pickerCache.path}/selected.wav');
    final original = testWav();
    await source.writeAsBytes(original);
    const pipeline = LabAudioPipeline();
    final sha = await LabAudioPipeline.digest(source);
    final probe = await pipeline.probe(source);
    expect(probe.kind, LabAudioKind.wavPcm16);
    final chunks = await pipeline.stage(
      source: source,
      probe: probe,
      sourceSha: sha,
      wavOutputRoot: Directory('${root.path}/private_support/chunks'),
      nativeCacheRoot: pickerCache,
    );
    expect(chunks, isNotEmpty);
    expect(chunks.last.coreEndMs, 8000);
    expect(await source.readAsBytes(), original);
    expect(await LabAudioPipeline.digest(source), sha);
  });

  test('MP3 and AAC codec picked by native MIME rather than file suffix', () async {
    final source = File('${root.path}/unhelpful.bin');
    await source.writeAsBytes([0x49, 0x44, 0x33, 0x01, 0x02]);
    var codec = 'audio/mpeg';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => {
          'mime': codec, 'durationUs': 12 * 1000000,
          'sourceBytes': await source.length(), 'sampleRate': 44100,
          'channels': 2
        });
    const pipeline = LabAudioPipeline();
    expect((await pipeline.probe(source)).kind, LabAudioKind.mp3);
    codec = 'audio/mp4a-latm';
    expect((await pipeline.probe(source)).kind, LabAudioKind.aacM4a);
  });

  test('native decoded physical RIFF PCM16 is accepted only with digest/clock', () async {
    final cache = Directory('${root.path}/android_cache');
    final outputDir = Directory('${cache.path}/groq_lab_native_pcm');
    await outputDir.create(recursive: true);
    final source = File('${cache.path}/source.mp3');
    await source.writeAsBytes([0x49, 0x44, 0x33, 0, 1]);
    final output = File('${outputDir.path}/groq_lab_pcm_test.wav');
    await output.writeAsBytes(testWav(rate: 16000, seconds: 12));
    final sourceSha = await LabAudioPipeline.digest(source);
    final wireSha = await LabAudioPipeline.digest(output);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'inspectAudio') {
        return {'mime':'audio/mpeg','durationUs':12000000,
          'sourceBytes':await source.length(),'sampleRate':44100,'channels':2};
      }
      if (call.method == 'decodeAudioWindow') {
        return {
          'outputPath': output.path,'bytes':await output.length(),
          'wireSha256': wireSha,'sourceSha256': sourceSha,
          'sourceDurationUs':12000000,'sourceBytes':await source.length(),
          'inputSampleRateHz':44100,
          'requestedStartUs':0,'requestedEndUs':12000000,
          'acousticTimingVerified':false,'ownerPlaybackVerified':false,
          'mime':'audio/wav','codec':'audio/pcm','sampleRate':16000,
          'channels':1,'bitsPerSample':16,'decoderVerified':true,
          'providerUploadAuthorized':false,'outputFrames':192000,
          'firstDecodedPtsUs':0,'lastDecodedPtsUs':12000000,
          'leadingPtsCompensationUs':0,
        };
      }
      throw StateError('UNEXPECTED_NATIVE_METHOD');
    });
    const pipeline = LabAudioPipeline();
    final probe = await pipeline.probe(source);
    final chunks = await pipeline.stage(
        source:source,probe:probe,sourceSha:sourceSha,
        wavOutputRoot:Directory('${root.path}/support'),
        nativeCacheRoot:cache);
    expect(chunks, hasLength(1));
    expect(chunks.single.sha256Hex, wireSha);
    expect(chunks.single.coreEndMs, 12000);
  });

  test('compressed native receipt must match source byte extent and duration',
      () async {
    final cache = Directory('${root.path}/native_provenance_cache');
    final dir = Directory('${cache.path}/groq_lab_native_pcm');
    await dir.create(recursive: true);
    final source = File('${cache.path}/source.mp3');
    final original = <int>[0x49, 0x44, 0x33, 0, 7];
    await source.writeAsBytes(original, flush: true);
    final output = File('${dir.path}/compressed_receipt.wav');
    await output.writeAsBytes(testWav(rate: 16000, seconds: 12));
    final sourceSha = await LabAudioPipeline.digest(source);
    final outputSha = await LabAudioPipeline.digest(output);
    var alteredProof = 'valid';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'inspectAudio') {
        return {
          'mime':'audio/mpeg','durationUs':12000000,
          'sourceBytes':await source.length(),'sampleRate':44100,
        };
      }
      if (call.method == 'decodeAudioWindow') {
        return {
          'outputPath':output.path,'bytes':await output.length(),
          'wireSha256':outputSha,'sourceSha256':sourceSha,
          'sourceDurationUs':alteredProof == 'duration'
              ? 11000000 : 12000000,
          'sourceBytes':alteredProof == 'bytes'
              ? original.length + 1 : original.length,
          'inputSampleRateHz':alteredProof == 'rate' ? 16000 : 44100,
          'requestedStartUs':0,'requestedEndUs':12000000,
          'acousticTimingVerified':alteredProof == 'acoustic'
              ? true : false,
          'ownerPlaybackVerified':false,
          'mime':'audio/wav','codec':'audio/pcm','sampleRate':16000,
          'channels':1,'bitsPerSample':16,'decoderVerified':true,
          'providerUploadAuthorized':false,'outputFrames':192000,
          'firstDecodedPtsUs':0,'lastDecodedPtsUs':12000000,
          'leadingPtsCompensationUs':0,
        };
      }
      throw StateError('UNEXPECTED_NATIVE_METHOD');
    });
    const pipeline = LabAudioPipeline();
    final probe = await pipeline.probe(source);
    Future<List<LabStagedChunk>> stage() => pipeline.stage(
      source:source,probe:probe,sourceSha:sourceSha,
      wavOutputRoot:Directory('${root.path}/support'),
      nativeCacheRoot:cache,
    );
    // Positive full physical WAV/hash/clock receipt still succeeds.
    expect(await stage(), hasLength(1));
    for (final bad in ['duration', 'bytes', 'acoustic', 'rate']) {
      alteredProof = bad;
      await expectLater(
        stage(),
        throwsA(isA<StateError>().having((e) => e.message, 'code',
            'LAB_NATIVE_OUTPUT_CONTRACT_HOLD')),
      );
      expect(await source.readAsBytes(), original);
      expect(await LabAudioPipeline.digest(output), outputSha);
    }
  });

  test('compressed stage rejects a missing or contradictory source probe',
      () async {
    final cache = Directory('${root.path}/bad_probe_cache');
    await cache.create(recursive: true);
    final source = File('${cache.path}/source.mp3');
    await source.writeAsBytes([0x49, 0x44, 0x33, 0, 8]);
    final sha = await LabAudioPipeline.digest(source);
    const pipeline = LabAudioPipeline();
    for (final probe in [
      const LabAudioProbe(LabAudioKind.mp3, 'audio/mpeg', null),
      const LabAudioProbe(LabAudioKind.aacM4a, 'audio/mpeg', 12000000),
    ]) {
      await expectLater(
        pipeline.stage(
          source:source,probe:probe,sourceSha:sha,
          wavOutputRoot:Directory('${root.path}/support'),
          nativeCacheRoot:cache,
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'code',
            'LAB_COMPRESSED_PROBE_CONTRACT_HOLD')),
      );
    }
  });

  test('decoder rejects forged output SHA rather than trusting Android map', () async {
    final file = File('${root.path}/fake.wav');
    await file.writeAsBytes(testWav(rate:16000));
    final actualBytes = await file.length();
    expect(
      () => LabAudioPipeline.verifyPcm16Wave(file, actualBytes),
      returnsNormally,
    );
    final bad = await file.readAsBytes();
    bad[0] = 0;
    await file.writeAsBytes(bad);
    await expectLater(
      LabAudioPipeline.verifyPcm16Wave(file, actualBytes),
      throwsStateError,
    );
  });

  test('native MP3 AAC leading PTS and failure guards', () {
    bool ok({required int frames, required int first, required int last,
        required int end, required int origin, int start = 0,
        LabAudioKind kind = LabAudioKind.mp3, int rate = 44100}) =>
        LabNativePcmCoverage.accepts(
          outputFrames: frames,
          expectedFrames: (end - start) * 16 ~/ 1000,
          wireStartUs: start, wireEndUs: end,
          firstDecodedPtsUs: first, lastDecodedPtsUs: last,
          leadingPtsCompensationUs: origin,
          sourceKind: kind, sourceSampleRateHz: rate);
    // Owner v21 MP3 and M4A raw PTS, with physical frame-count models.
    expect(ok(frames: 240100, first: 40249, last: 15046507,
        end: 15046000, origin: 40249), isTrue);
    expect(ok(frames: 239629, first: 23219, last: 15000067,
        end: 15000000, origin: 23219,
        kind: LabAudioKind.aacM4a), isTrue);
    // A 16kHz AAC-LC 1024-sample priming frame is 64ms.
    expect(LabNativePcmCoverage.firstWireLeadingLimitUs(
        LabAudioKind.aacM4a, 16000), 66000);
    expect(ok(frames: 238976, first: 64000, last: 15000067,
        end: 15000000, origin: 64000,
        kind: LabAudioKind.aacM4a, rate: 16000), isTrue);
    expect(ok(frames: 238976, first: 70000, last: 15000067,
        end: 15000000, origin: 70000,
        kind: LabAudioKind.aacM4a, rate: 16000), isFalse);
    expect(ok(frames: 238000, first: 64000, last: 15000067,
        end: 15000000, origin: 64000,
        kind: LabAudioKind.aacM4a, rate: 16000), isFalse);
    expect(ok(frames: 238976, first: 64000, last: 15000067,
        end: 15000000, origin: 64000,
        kind: LabAudioKind.mp3, rate: 16000), isFalse);
    expect(LabNativePcmCoverage.firstWireLeadingLimitUs(
        LabAudioKind.aacM4a, 0), -1);
    expect(ok(frames: 239000, first: 23219, last: 15000067,
        end: 15000000, origin: 23219), isFalse);
    expect(ok(frames: 239629, first: 60000, last: 15000067,
        end: 15000000, origin: 60000), isFalse);
    expect(ok(frames: 239629, first: 23219, last: 15000067,
        end: 15000000, origin: 0), isFalse);
    expect(ok(frames: 239629, first: 23219, last: 14900000,
        end: 15000000, origin: 23219), isFalse);
    expect(ok(frames: 80000, first: 5010000, last: 10000000,
        start: 5000000, end: 10000000, origin: 0), isFalse);
  });

  test('long compressed files use contiguous 600s cores and 2s overlap', () {
    final windows = LabCompressedWindowPlanner.plan(2 * 3600 * 1000000);
    expect(windows.length, 12);
    var expectedStart = 0;
    for (var i = 0; i < windows.length; i++) {
      final w = windows[i];
      expect(w.coreStartMs, expectedStart);
      expect(w.wireStartMs, i == 0 ? 0 : expectedStart - 2000);
      expect(w.wireEndMs, w.coreEndMs);
      expect((w.wireEndMs - w.wireStartMs) * 32 + 44, lessThan(22500000));
      expectedStart = w.coreEndMs;
    }
    expect(expectedStart, 7200000);
    expect(() => LabCompressedWindowPlanner.plan(2000),
        throwsStateError);
  });

  test('late WAV stage rollback deletes only owned completed temporary wires',
      () async {
    final ownedRoot = Directory('${root.path}/app_support_wav');
    await ownedRoot.create(recursive: true);
    final staged = await ownedRoot.createTemp('groq_pcm_staged_');
    final wire = File('${staged.path}/pcm_0.wav');
    await wire.writeAsBytes(testWav());
    final external = File('${root.path}/source_keep.wav');
    final sourceBytes = testWav(seconds: 12);
    await external.writeAsBytes(sourceBytes);
    final forbidden = File('${root.path}/pcm_1.wav');
    await forbidden.writeAsBytes(sourceBytes);
    final chunks = [
      LabStagedChunk(file: wire, byteCount: await wire.length(),
        sha256Hex: await LabAudioPipeline.digest(wire),
        coreStartMs: 0, coreEndMs: 8000,
        wireStartMs: 0, wireEndMs: 8000),
      LabStagedChunk(file: forbidden, byteCount: await forbidden.length(),
        sha256Hex: await LabAudioPipeline.digest(forbidden),
        coreStartMs: 8000, coreEndMs: 12000,
        wireStartMs: 6000, wireEndMs: 12000),
    ];
    await LabAudioPipeline.rollbackVerifiedWavStage(chunks, ownedRoot);
    expect(await wire.exists(), isFalse);
    expect(await staged.exists(), isFalse);
    expect(await forbidden.exists(), isTrue);
    expect(await external.readAsBytes(), sourceBytes);
    expect(await ownedRoot.exists(), isTrue);
  });
}
