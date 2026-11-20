import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_audio_pipeline.dart';

Future<void> writePcm(File path, int frames) async {
  final h = Uint8List(44);
  final b = ByteData.sublistView(h);
  void str(int at, String s) => h.setRange(at, at + s.length, s.codeUnits);
  final bytes = frames * 2 + 44;
  str(0, 'RIFF');
  b.setUint32(4, bytes - 8, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 16000, Endian.little);
  b.setUint32(28, 32000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, bytes - 44, Endian.little);
  final f = await path.open(mode: FileMode.write);
  try {
    await f.writeFrom(h);
    await f.truncate(bytes); // Sparse synthetic PCM; no acoustic claim.
  } finally {
    await f.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('groq_stt_lab/offline_audio');
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lab_v23_clock_');
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('7200-second plan and physical chain reject 1ms missing overlap', () {
    final windows = LabCompressedWindowPlanner.plan(7200000000);
    expect(windows, hasLength(12));
    final chunks = windows.map((w) => LabStagedChunk(
      file: File('synthetic-not-physical.wav'),
      byteCount: 100000,
      sha256Hex: 'a'.padRight(64, 'a'),
      coreStartMs: w.coreStartMs, coreEndMs: w.coreEndMs,
      wireStartMs: w.wireStartMs, wireEndMs: w.wireEndMs,
    )).toList();
    expect(() => LabCompressedChunkChain.verify(chunks, 7200000),
        returnsNormally);
    final c = chunks[1];
    chunks[1] = LabStagedChunk(
      file: c.file, byteCount: c.byteCount, sha256Hex: c.sha256Hex,
      coreStartMs: c.coreStartMs, coreEndMs: c.coreEndMs,
      wireStartMs: c.wireStartMs + 1, wireEndMs: c.wireEndMs,
    );
    expect(() => LabCompressedChunkChain.verify(chunks, 7200000),
        throwsStateError);
    expect(() => LabCompressedChunkChain.verify(chunks, 7199999),
        throwsStateError);
  });

  test('601-second physical wires, original SHA, and later-window rollback',
      () async {
    final cache = Directory('${root.path}/cache');
    final native = Directory('${cache.path}/groq_lab_native_pcm');
    await native.create(recursive: true);
    final source = File('${cache.path}/sample.mp3');
    const original = <int>[73, 68, 51, 0, 8];
    await source.writeAsBytes(original);
    final sourceSha = await LabAudioPipeline.digest(source);
    const durationUs = 601000000;
    final windows = LabCompressedWindowPlanner.plan(durationUs);
    expect(windows, hasLength(2));
    final outputs = <File>[];
    final digests = <String>[];
    for (var i = 0; i < windows.length; i++) {
      final w = windows[i];
      final f = File('${native.path}/wire_$i.wav');
      await writePcm(f, (w.wireEndMs - w.wireStartMs) * 16);
      outputs.add(f);
      digests.add(await LabAudioPipeline.digest(f));
    }
    var index = 0;
    var failSecond = false;
    var forgedFirstReplay = false;
    var cancelAtFirst = false;
    var cancelNow = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'inspectAudio') {
        return {
          'mime': 'audio/mpeg', 'durationUs': durationUs,
          'sourceBytes': original.length, 'sampleRate': 44100,
          'channels': 2,
        };
      }
      if (call.method != 'decodeAudioWindow') {
        throw StateError('UNEXPECTED_NATIVE_METHOD');
      }
      final i = index++;
      if (cancelAtFirst && i == 0) cancelNow = true;
      if (failSecond && i == 1) {
        throw PlatformException(code: 'LAB_AUDIO_PCM_GAP');
      }
      final w = windows[i];
      expect(call.arguments['startMs'], w.wireStartMs);
      expect(call.arguments['endMs'], w.wireEndMs);
      return {
        'outputPath': outputs[i].path, 'bytes': await outputs[i].length(),
        'wireSha256': digests[i], 'sourceSha256': sourceSha,
        'sourceDurationUs': durationUs, 'sourceBytes': original.length,
        'inputSampleRateHz': 44100,
        'requestedStartUs': w.wireStartMs * 1000,
        'requestedEndUs': w.wireEndMs * 1000,
        'acousticTimingVerified': false, 'ownerPlaybackVerified': false,
        'mime': 'audio/wav', 'codec': 'audio/pcm', 'sampleRate': 16000,
        'channels': 1, 'bitsPerSample': 16, 'decoderVerified': true,
        'providerUploadAuthorized': false,
        'mp3OriginReplay': forgedFirstReplay || i == 1,
        'outputFrames': (w.wireEndMs - w.wireStartMs) * 16,
        'firstDecodedPtsUs': w.wireStartMs * 1000,
        'lastDecodedPtsUs': w.wireEndMs * 1000,
        'leadingPtsCompensationUs': 0,
      };
    });
    const pipeline = LabAudioPipeline();
    final probe = await pipeline.probe(source);
    Future<List<LabStagedChunk>> stage({
      bool Function()? cancellationRequested,
    }) => pipeline.stage(
      source: source, probe: probe, sourceSha: sourceSha,
      wavOutputRoot: Directory('${root.path}/support'),
      nativeCacheRoot: cache,
      cancellationRequested: cancellationRequested,
    );
    final actual = await stage();
    expect(actual, hasLength(2));
    expect(actual[0].mp3OriginReplay, isFalse);
    expect(actual[1].mp3OriginReplay, isTrue);
    expect(actual[1].coreStartMs, actual[0].coreEndMs);
    expect(actual[0].coreEndMs - actual[1].wireStartMs, 2000);
    expect(actual.last.coreEndMs, 601000);
    expect(await source.readAsBytes(), original);

    // Another invocation produces a fresh native output. A second window
    // decode failure must delete only its accepted first temp wire.
    final retry = File('${native.path}/fresh_first.wav');
    await writePcm(retry, (windows[0].wireEndMs - windows[0].wireStartMs) * 16);
    outputs[0] = retry;
    digests[0] = await LabAudioPipeline.digest(retry);
    index = 0;
    failSecond = true;
    await expectLater(stage(), throwsA(isA<PlatformException>()));
    expect(await retry.exists(), isFalse);
    expect(await outputs[1].exists(), isTrue);
    expect(await source.readAsBytes(), original);
    expect(await LabAudioPipeline.digest(source), sourceSha);

    // An origin-replay claim on the first window is never accepted as
    // verified physical PCM provenance, even if bytes/SHA appear valid.
    await writePcm(retry, (windows[0].wireEndMs - windows[0].wireStartMs) * 16);
    digests[0] = await LabAudioPipeline.digest(retry);
    index = 0;
    failSecond = false;
    forgedFirstReplay = true;
    await expectLater(
      stage(),
      throwsA(isA<StateError>().having(
        (e) => e.message, 'code', 'LAB_NATIVE_OUTPUT_CONTRACT_HOLD')),
    );
    expect(await LabAudioPipeline.digest(source), sourceSha);

    // Explicit cancellation after the first physically verified window must
    // not enqueue window 2 or retain the first new temporary output.
    final cancelledFirst = File('${native.path}/cancel_first.wav');
    await writePcm(cancelledFirst,
        (windows[0].wireEndMs - windows[0].wireStartMs) * 16);
    outputs[0] = cancelledFirst;
    digests[0] = await LabAudioPipeline.digest(cancelledFirst);
    index = 0;
    forgedFirstReplay = false;
    cancelAtFirst = true;
    cancelNow = false;
    await expectLater(
      stage(cancellationRequested: () => cancelNow),
      throwsA(isA<StateError>().having(
        (e) => e.message, 'code', 'LAB_AUDIO_CANCELLED')),
    );
    expect(index, 1);
    expect(await cancelledFirst.exists(), isFalse);
    expect(await outputs[1].exists(), isTrue);
    expect(await source.readAsBytes(), original);
    expect(await LabAudioPipeline.digest(source), sourceSha);
  });
}
