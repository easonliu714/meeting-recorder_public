import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/groq_wav_pcm_splitter.dart';

Uint8List wav16({int rate = 8000, int seconds = 8, int format = 1,
    int channels = 1}) {
  final frames = rate * seconds;
  final data = frames * channels * 2;
  final b = Uint8List(44 + data);
  final d = ByteData.sublistView(b);
  void put(int i, String s) => b.setRange(i, i + s.length, s.codeUnits);
  put(0, 'RIFF');
  d.setUint32(4, data + 36, Endian.little);
  put(8, 'WAVE');
  put(12, 'fmt ');
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, format, Endian.little);
  d.setUint16(22, channels, Endian.little);
  d.setUint32(24, rate, Endian.little);
  d.setUint32(28, rate * channels * 2, Endian.little);
  d.setUint16(32, channels * 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  put(36, 'data');
  d.setUint32(40, data, Endian.little);
  for (var i = 0; i < data; i++) b[44 + i] = i % 251;
  return b;
}

/// Preserve a valid original WAV body and extend its RIFF length with
/// extra subchunks/trailers. Never alter the original input bytes in-place.
Uint8List appendRiffTail(Uint8List wave, List<int> tail) {
  final result = Uint8List.fromList([...wave, ...tail]);
  ByteData.sublistView(result).setUint32(4, result.length - 8, Endian.little);
  return result;
}

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('wav_gate_'));
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('WAV physical 8s source creates real bounded core chunks with 2s overlap', () async {
    final input = File(root.path + '/source.wav');
    final original = wav16();
    await input.writeAsBytes(original);
    final cache = Directory(root.path + '/isolated_cache');
    final chunks = await GroqWavPcmSplitter.stage(
      source: input, cacheRoot: cache, maxBytes: 65536);
    expect(chunks.length, greaterThan(1));
    expect(await input.readAsBytes(), original);
    var expectedFrame = 0;
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      expect(chunk.coreStartFrame, expectedFrame);
      expect(chunk.wireStartFrame,
          i == 0 ? 0 : expectedFrame - 16000);
      expect(chunk.wireEndFrame, chunk.coreEndFrame);
      final actual = await chunk.file.readAsBytes();
      expect(actual.length, lessThan(65536));
      expect(String.fromCharCodes(actual.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(actual.sublist(8, 12)), 'WAVE');
      final start = 44 + chunk.wireStartFrame * 2;
      expect(actual.sublist(44),
          original.sublist(start, start + actual.length - 44));
      expectedFrame = chunk.coreEndFrame;
    }
    expect(expectedFrame, 64000);
    expect(chunks.last.coreEndMs, 8000);
    await chunks.first.file.parent.delete(recursive: true);
    expect(await input.exists(), isTrue);
  });

  test('stereo 44100Hz two physical chunks preserve every source frame '
      'and exact 2s overlap', () async {
    final source = File(root.path + '/stereo_44100.wav');
    final original = wav16(rate: 44100, seconds: 8, channels: 2);
    await source.writeAsBytes(original, flush: true);
    final parts = await GroqWavPcmSplitter.stage(
      source: source,
      cacheRoot: Directory(root.path + '/stereo_out'),
      maxBytes: 900000,
    );
    expect(parts.length, greaterThan(1));
    await GroqWavPcmSplitter.verifyPhysicalStage(
      parts: parts,
      expectedTotalFrames: 44100 * 8,
      sampleRate: 44100,
      channels: 2,
    );
    var nextFrame = 0;
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      expect(p.coreStartFrame, nextFrame);
      expect(p.wireStartFrame,
          i == 0 ? 0 : p.coreStartFrame - 88200);
      final wav = await p.file.readAsBytes();
      final start = 44 + p.wireStartFrame * 4;
      expect(wav.sublist(44),
          original.sublist(start, start + wav.length - 44));
      nextFrame = p.coreEndFrame;
    }
    expect(nextFrame, 44100 * 8);
    expect(await source.readAsBytes(), original);
  });

  test('physical verification rejects forged Core gap or missing final part',
      () async {
    final source = File(root.path + '/clock.wav');
    final original = wav16();
    await source.writeAsBytes(original);
    final parts = await GroqWavPcmSplitter.stage(
      source: source,
      cacheRoot: Directory(root.path + '/clock_out'),
      maxBytes: 65536,
    );
    expect(parts.length, greaterThan(1));
    final second = parts[1];
    final forged = GroqWavPart(second.file, second.coreStartFrame + 1,
        second.coreEndFrame, second.wireStartFrame,
        second.wireEndFrame, second.sampleRate);
    await expectLater(
      GroqWavPcmSplitter.verifyPhysicalStage(
        parts: [parts.first, forged, ...parts.skip(2)],
        expectedTotalFrames: 64000, sampleRate: 8000, channels: 1),
      throwsA(isA<StateError>().having(
        (e) => e.message, 'code', 'WAV_PHYSICAL_CLOCK_OR_BYTES_HOLD')),
    );
    await expectLater(
      GroqWavPcmSplitter.verifyPhysicalStage(
        parts: parts.take(parts.length - 1).toList(),
        expectedTotalFrames: 64000, sampleRate: 8000, channels: 1),
      throwsStateError,
    );
    expect(await source.readAsBytes(), original);
  });

  test('physical verification rejects truncated Chunk and forged PCM header',
      () async {
    final source = File(root.path + '/corrupt_staged.wav');
    final original = wav16(seconds: 3);
    await source.writeAsBytes(original);
    final parts = await GroqWavPcmSplitter.stage(
      source: source,
      cacheRoot: Directory(root.path + '/physical_corrupt_out'),
      maxBytes: 65536,
    );
    final target = parts.first.file;
    final intact = await target.readAsBytes();
    await target.writeAsBytes(intact.sublist(0, intact.length - 2));
    await expectLater(
      GroqWavPcmSplitter.verifyPhysicalStage(
        parts: parts, expectedTotalFrames: 24000,
        sampleRate: 8000, channels: 1),
      throwsStateError,
    );
    final badHeader = Uint8List.fromList(intact);
    ByteData.sublistView(badHeader).setUint32(24, 16000, Endian.little);
    await target.writeAsBytes(badHeader);
    await expectLater(
      GroqWavPcmSplitter.verifyPhysicalStage(
        parts: parts, expectedTotalFrames: 24000,
        sampleRate: 8000, channels: 1),
      throwsStateError,
    );
    expect(await source.readAsBytes(), original);
  });

  test('WAV invalid RIFF size and unsupported float codec HOLD, no source deletion', () async {
    final input = File(root.path + '/invalid.wav');
    final bytes = wav16();
    final d = ByteData.sublistView(bytes);
    d.setUint32(4, 0x7fffffff, Endian.little);
    await input.writeAsBytes(bytes);
    final cache = Directory(root.path + '/isolated');
    await expectLater(
      GroqWavPcmSplitter.stage(source: input, cacheRoot: cache, maxBytes: 65536),
      throwsFormatException);
    expect(await input.exists(), isTrue);
    await input.writeAsBytes(wav16(format: 3));
    await expectLater(
      GroqWavPcmSplitter.stage(source: input, cacheRoot: cache, maxBytes: 65536),
      throwsFormatException);
  });

  test('RIFF odd-length auxiliary chunk with proper pad stays supported',
      () async {
    final file = File(root.path + '/padded.wav');
    final original = appendRiffTail(wav16(), [
      0x4a, 0x55, 0x4e, 0x4b, // JUNK
      3, 0, 0, 0,             // 3 payload bytes (not including pad)
      11, 22, 33, 0,         // one required pad byte
    ]);
    await file.writeAsBytes(original, flush: true);
    final parts = await GroqWavPcmSplitter.stage(
      source: file, cacheRoot: Directory(root.path + '/padded_out'),
      maxBytes: 65536,
    );
    expect(parts, isNotEmpty);
    expect(parts.last.coreEndMs, 8000);
    expect(await file.readAsBytes(), original);
  });

  test('RIFF odd-length subchunk missing pad is rejected, source retained',
      () async {
    final file = File(root.path + '/missing_pad.wav');
    final bytes = appendRiffTail(wav16(), [
      0x4a, 0x55, 0x4e, 0x4b, 3, 0, 0, 0, 11, 22, 33,
    ]);
    await file.writeAsBytes(bytes, flush: true);
    final cache = Directory(root.path + '/no_pad_out');
    await expectLater(
      GroqWavPcmSplitter.stage(
          source: file, cacheRoot: cache, maxBytes: 65536),
      throwsA(isA<FormatException>()),
    );
    expect(await file.readAsBytes(), bytes);
    expect(await cache.list().toList(), isEmpty);
  });

  test('RIFF appended bytes outside declared file extent fail closed',
      () async {
    final file = File(root.path + '/undeclared_suffix.wav');
    final canonical = wav16();
    // Keep the valid RIFF header and PCM body unchanged; append only bytes
    // that the RIFF header did not declare.
    final corrupt = Uint8List.fromList([...canonical, 0x4a, 0x55, 0x4e, 0x4b]);
    await file.writeAsBytes(corrupt, flush: true);
    final cache = Directory(root.path + '/undeclared_out');
    await expectLater(
      GroqWavPcmSplitter.stage(
          source: file, cacheRoot: cache, maxBytes: 65536),
      throwsA(isA<FormatException>().having(
          (error) => error.message, 'reason',
          'WAV_RIFF_UNDECLARED_TRAILER_HOLD')),
    );
    expect(await file.readAsBytes(), corrupt);
    expect(await cache.list().toList(), isEmpty);
  });

  test('RIFF declared extent exactly matches real file, stages without loss',
      () async {
    final file = File(root.path + '/canonical.wav');
    final original = wav16(seconds: 4);
    await file.writeAsBytes(original, flush: true);
    final cache = Directory(root.path + '/canonical_out');
    final chunks = await GroqWavPcmSplitter.stage(
        source: file, cacheRoot: cache, maxBytes: 65536);
    expect(chunks, isNotEmpty);
    expect(chunks.last.coreEndMs, 4000);
    expect(await file.readAsBytes(), original);
  });

  test('RIFF partial trailing header cannot be silently ignored',
      () async {
    final file = File(root.path + '/trailing_four.wav');
    final bytes = appendRiffTail(wav16(), [0x4a, 0x55, 0x4e, 0x4b]);
    await file.writeAsBytes(bytes, flush: true);
    final cache = Directory(root.path + '/trailer_out');
    await expectLater(
      GroqWavPcmSplitter.stage(
          source: file, cacheRoot: cache, maxBytes: 65536),
      throwsA(isA<FormatException>()),
    );
    expect(await file.readAsBytes(), bytes);
    expect(await cache.list().toList(), isEmpty);
  });

  test('RIFF subchunk count above 128 rejected after valid fmt/data',
      () async {
    final file = File(root.path + '/too_many_chunks.wav');
    final aux = <int>[];
    for (var i = 0; i < 129; i++) {
      aux.addAll([0x4a, 0x55, 0x4e, 0x4b, 0, 0, 0, 0]);
    }
    final bytes = appendRiffTail(wav16(), aux);
    await file.writeAsBytes(bytes, flush: true);
    final cache = Directory(root.path + '/count_out');
    await expectLater(
      GroqWavPcmSplitter.stage(
          source: file, cacheRoot: cache, maxBytes: 65536),
      throwsA(isA<FormatException>()),
    );
    expect(await file.readAsBytes(), bytes);
    expect(await cache.list().toList(), isEmpty);
  });

  test('WAV reject input located inside staging root, reject budget boundary', () async {
    final cache = Directory(root.path + '/isolated');
    await cache.create();
    final input = File(cache.path + '/source.wav');
    await input.writeAsBytes(wav16());
    await expectLater(
      GroqWavPcmSplitter.stage(source: input, cacheRoot: cache, maxBytes: 65536),
      throwsStateError);
    final outside = File(root.path + '/outside.wav');
    await outside.writeAsBytes(wav16());
    await expectLater(
      GroqWavPcmSplitter.stage(source: outside, cacheRoot: cache,
        maxBytes: 22500001), throwsStateError);
  });
}
