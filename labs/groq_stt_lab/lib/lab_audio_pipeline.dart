import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'groq_wav_pcm_splitter.dart';

enum LabAudioKind { wavPcm16, mp3, aacM4a }

final class LabAudioProbe {
  const LabAudioProbe(this.kind, this.mime, this.durationUs);
  final LabAudioKind kind;
  final String mime;
  final int? durationUs;

  String get label {
    switch (kind) {
      case LabAudioKind.wavPcm16:
        return 'WAV PCM16';
      case LabAudioKind.mp3:
        return 'MP3';
      case LabAudioKind.aacM4a:
        return 'AAC / M4A';
    }
  }
}

final class LabAudioWindow {
  const LabAudioWindow(this.coreStartMs, this.coreEndMs, this.wireStartMs,
      this.wireEndMs);
  final int coreStartMs;
  final int coreEndMs;
  final int wireStartMs;
  final int wireEndMs;
}

/// 600s balanced core with 2s contextual overlap, milliseconds integral.
/// Chosen to guarantee decoded mono 16kHz PCM16 WAV <22.5 decimal MB.
final class LabCompressedWindowPlanner {
  const LabCompressedWindowPlanner._();
  static const int maximumCoreMs = 600000;
  static const int overlapMs = 2000;
  static const int minimumSourceMs = 10;
  static const int maxWindows = 300;

  static List<LabAudioWindow> plan(int durationUs) {
    if (durationUs < minimumSourceMs * 1000 ||
        durationUs > 48 * 3600 * 1000000) {
      throw StateError('LAB_AUDIO_DURATION_HOLD');
    }
    final durationMs = durationUs ~/ 1000;
    final count = (durationMs + maximumCoreMs - 1) ~/ maximumCoreMs;
    if (count == 0 || count > maxWindows) {
      throw StateError('LAB_AUDIO_WINDOW_COUNT_HOLD');
    }
    final result = <LabAudioWindow>[];
    for (var i = 0; i < count; i++) {
      final start = durationMs * i ~/ count;
      final end = durationMs * (i + 1) ~/ count;
      final wireStart = i == 0 ? 0 : start - overlapMs;
      if (start < 0 || end <= start || wireStart < 0 ||
          end - wireStart > maximumCoreMs + overlapMs ||
          (end - wireStart) * 32 + 44 >= 22500000) {
        throw StateError('LAB_AUDIO_WINDOW_LIMIT_HOLD');
      }
      result.add(LabAudioWindow(start, end, wireStart, end));
    }
    return List.unmodifiable(result);
  }
}

/// Accept only physical PCM backed by a bounded first-window PTS origin.
final class LabNativePcmCoverage {
  const LabNativePcmCoverage._();
  static bool accepts({
    required int outputFrames,
    required int expectedFrames,
    required int wireStartUs,
    required int wireEndUs,
    required int firstDecodedPtsUs,
    required int lastDecodedPtsUs,
    required int leadingPtsCompensationUs,
  }) {
    if (expectedFrames <= 0 || outputFrames <= 0 ||
        outputFrames > expectedFrames || wireStartUs < 0 ||
        wireEndUs <= wireStartUs || firstDecodedPtsUs < 0 ||
        lastDecodedPtsUs < firstDecodedPtsUs ||
        lastDecodedPtsUs < wireEndUs - 25000 ||
        leadingPtsCompensationUs < 0 ||
        leadingPtsCompensationUs > 50000) return false;
    if (wireStartUs == 0) {
      if (firstDecodedPtsUs != leadingPtsCompensationUs) return false;
    } else if (leadingPtsCompensationUs != 0 ||
        firstDecodedPtsUs > wireStartUs) return false;
    final primingFrames = leadingPtsCompensationUs * 16000 ~/ 1000000;
    return outputFrames + primingFrames >= expectedFrames - 320;
  }
}

final class LabStagedChunk {
  const LabStagedChunk({
    required this.file,
    required this.byteCount,
    required this.sha256Hex,
    required this.coreStartMs,
    required this.coreEndMs,
    required this.wireStartMs,
    required this.wireEndMs,
  });
  final File file;
  final int byteCount;
  final String sha256Hex;
  final int coreStartMs;
  final int coreEndMs;
  final int wireStartMs;
  final int wireEndMs;
}

/// Independent physical clock audit: no gap and exactly 2 seconds overlap.
final class LabCompressedChunkChain {
  const LabCompressedChunkChain._();
  static void verify(List<LabStagedChunk> chunks, int durationMs) {
    if (chunks.isEmpty || durationMs < 10 ||
        chunks.length > LabCompressedWindowPlanner.maxWindows) {
      throw StateError('LAB_AUDIO_CHAIN_CLOCK_HOLD');
    }
    var last = 0;
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      final expectedWire = i == 0
          ? 0 : last - LabCompressedWindowPlanner.overlapMs;
      if (c.coreStartMs != last || c.coreEndMs <= last ||
          c.wireStartMs != expectedWire || c.wireEndMs != c.coreEndMs ||
          c.byteCount < 45 || c.byteCount >= 22500000 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(c.sha256Hex)) {
        throw StateError('LAB_AUDIO_CHAIN_CLOCK_HOLD');
      }
      last = c.coreEndMs;
    }
    if (last != durationMs) throw StateError('LAB_AUDIO_CHAIN_CLOCK_HOLD');
  }
}

/// Lab-only local source probe & physical audio stage. Nothing transmits bytes.
final class LabAudioPipeline {
  const LabAudioPipeline({
    MethodChannel channel = const MethodChannel('groq_stt_lab/offline_audio'),
  }) : _channel = channel;

  final MethodChannel _channel;
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  static Future<String> digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<LabAudioProbe> probe(File source) async {
    if (!await source.exists() || await source.length() <= 0) {
      throw StateError('LAB_AUDIO_EMPTY_OR_MISSING_SOURCE');
    }
    final read = await source.open(mode: FileMode.read);
    late final List<int> prefix;
    try {
      prefix = await read.read(12);
    } finally {
      await read.close();
    }
    if (prefix.length == 12 &&
        String.fromCharCodes(prefix.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(prefix.sublist(8, 12)) == 'WAVE') {
      return const LabAudioProbe(
          LabAudioKind.wavPcm16, 'audio/wav', null);
    }
    final meta = await _channel.invokeMapMethod<String, dynamic>(
      'inspectAudio', {'sourcePath': source.path});
    if (meta == null || meta['durationUs'] is! int ||
        meta['sourceBytes'] != await source.length()) {
      throw StateError('LAB_AUDIO_PROBE_METADATA_HOLD');
    }
    final codec = meta['mime'];
    final int durationUs = meta['durationUs'] as int;
    if (codec != 'audio/mpeg' && codec != 'audio/mp4a-latm') {
      throw StateError('LAB_AUDIO_UNSUPPORTED_CODEC');
    }
    LabCompressedWindowPlanner.plan(durationUs);
    return LabAudioProbe(
        codec == 'audio/mpeg' ? LabAudioKind.mp3 : LabAudioKind.aacM4a,
        codec as String, durationUs);
  }

  static Future<void> verifyPcm16Wave(File file, int expectedBytes) async {
    final reader = await file.open(mode: FileMode.read);
    try {
      final header = await reader.read(44);
      if (header.length != 44 ||
          ascii.decode(header.sublist(0, 4)) != 'RIFF' ||
          ascii.decode(header.sublist(8, 12)) != 'WAVE' ||
          ascii.decode(header.sublist(12, 16)) != 'fmt ' ||
          ascii.decode(header.sublist(36, 40)) != 'data') {
        throw StateError('LAB_NATIVE_INVALID_WAV_HEADER');
      }
      final v = ByteData.sublistView(Uint8List.fromList(header));
      if (v.getUint32(4, Endian.little) != expectedBytes - 8 ||
          v.getUint32(16, Endian.little) != 16 ||
          v.getUint16(20, Endian.little) != 1 ||
          v.getUint16(22, Endian.little) != 1 ||
          v.getUint32(24, Endian.little) != 16000 ||
          v.getUint32(28, Endian.little) != 32000 ||
          v.getUint16(32, Endian.little) != 2 ||
          v.getUint16(34, Endian.little) != 16 ||
          v.getUint32(40, Endian.little) != expectedBytes - 44) {
        throw StateError('LAB_NATIVE_INVALID_PCM16_LAYOUT');
      }
    } finally {
      await reader.close();
    }
  }

  Future<List<LabStagedChunk>> stage({
    required File source,
    required LabAudioProbe probe,
    required String sourceSha,
    required Directory wavOutputRoot,
    required Directory nativeCacheRoot,
  }) async {
    if (!_hex64.hasMatch(sourceSha) ||
        await digest(source) != sourceSha) {
      throw StateError('LAB_SOURCE_CHANGED_BEFORE_STAGE');
    }
    final result = <LabStagedChunk>[];
    try {
    if (probe.kind == LabAudioKind.wavPcm16) {
      // FilePicker's selected source normally lives under Android cache/.
      // Stage WAV chunks under the separate appSupport/lab_wav_outputs root,
      // never within the same parent cache to avoid SOURCE_IN_CACHE.
      final parts = await GroqWavPcmSplitter.stage(
          source: source, cacheRoot: wavOutputRoot);
      for (final part in parts) {
        final bytes = await part.file.length();
        if (bytes < 45 || bytes >= 22500000) {
          throw StateError('LAB_WAV_OUTPUT_BYTES_HOLD');
        }
        result.add(LabStagedChunk(
          file: part.file,
          byteCount: bytes,
          sha256Hex: await digest(part.file),
          coreStartMs: part.coreStartMs,
          coreEndMs: part.coreEndMs,
          wireStartMs: part.wireStartMs,
          wireEndMs: part.wireEndMs,
        ));
      }
    } else {
      // A compressed probe must carry an explicit, bounded source clock.
      // Do not allow a missing or inconsistent native provenance to be
      // treated as a valid decoded PCM upload candidate.
      final durationUs = probe.durationUs;
      if (durationUs == null ||
          (probe.kind == LabAudioKind.mp3 && probe.mime != 'audio/mpeg') ||
          (probe.kind == LabAudioKind.aacM4a &&
              probe.mime != 'audio/mp4a-latm')) {
        throw StateError('LAB_COMPRESSED_PROBE_CONTRACT_HOLD');
      }
      final windows = LabCompressedWindowPlanner.plan(durationUs);
      final sourceBytes = await source.length();
      final allowedDir = Directory(
          '${nativeCacheRoot.path}${Platform.pathSeparator}groq_lab_native_pcm');
      // Android native creates this output directory only after validating
      // cache scope, available storage and the encoded source.
      for (final w in windows) {
        final meta = await _channel.invokeMapMethod<String, dynamic>(
          'decodeAudioWindow', {
            'sourcePath': source.path,
            'startMs': w.wireStartMs,
            'endMs': w.wireEndMs,
          },
        );
        if (meta == null || meta['outputPath'] is! String ||
            meta['bytes'] is! int || meta['wireSha256'] is! String ||
            meta['sourceSha256'] != sourceSha ||
            // Both the inspected source clock and source byte extent must
            // agree with each physical window's native decode receipt.
            // The SHA alone does not bind a reused/forged duration record.
            meta['sourceDurationUs'] != durationUs ||
            meta['sourceBytes'] != sourceBytes ||
            meta['requestedStartUs'] != w.wireStartMs * 1000 ||
            meta['requestedEndUs'] != w.wireEndMs * 1000 ||
            // These are explicitly NOT acoustic or Owner playback proof.
            meta['acousticTimingVerified'] != false ||
            meta['ownerPlaybackVerified'] != false ||
            meta['mime'] != 'audio/wav' ||
            meta['codec'] != 'audio/pcm' ||
            meta['sampleRate'] != 16000 ||
            meta['channels'] != 1 ||
            meta['bitsPerSample'] != 16 ||
            meta['decoderVerified'] != true ||
            meta['providerUploadAuthorized'] != false ||
            meta['firstDecodedPtsUs'] is! int ||
            meta['lastDecodedPtsUs'] is! int ||
            meta['leadingPtsCompensationUs'] is! int ||
            !_hex64.hasMatch(meta['wireSha256'] as String)) {
          throw StateError('LAB_NATIVE_OUTPUT_CONTRACT_HOLD');
        }
        final staged = File(meta['outputPath'] as String);
        final physicalParent = await staged.parent.resolveSymbolicLinks();
        final physicalDir = await allowedDir.resolveSymbolicLinks();
        final bytes = meta['bytes'] as int;
        if (physicalParent != physicalDir ||
            await staged.length() != bytes ||
            bytes < 45 || bytes >= 22500000 ||
            await digest(staged) != meta['wireSha256']) {
          throw StateError('LAB_NATIVE_OUTPUT_SHA_SCOPE_HOLD');
        }
        await verifyPcm16Wave(staged, bytes);
        final frames = meta['outputFrames'];
        final expectedFrames = (w.wireEndMs - w.wireStartMs) * 16;
        if (frames is! int ||
            !LabNativePcmCoverage.accepts(
              outputFrames: frames,
              expectedFrames: expectedFrames,
              wireStartUs: w.wireStartMs * 1000,
              wireEndUs: w.wireEndMs * 1000,
              firstDecodedPtsUs: meta['firstDecodedPtsUs'] as int,
              lastDecodedPtsUs: meta['lastDecodedPtsUs'] as int,
              leadingPtsCompensationUs: meta['leadingPtsCompensationUs'] as int,
            ) ||
            bytes != 44 + frames * 2) {
          throw StateError('LAB_NATIVE_INCOMPLETE_AUDIO_WINDOW_HOLD');
        }
        result.add(LabStagedChunk(
          file: staged,
          byteCount: bytes,
          sha256Hex: meta['wireSha256'] as String,
          coreStartMs: w.coreStartMs,
          coreEndMs: w.coreEndMs,
          wireStartMs: w.wireStartMs,
          wireEndMs: w.wireEndMs,
        ));
      }
    }
    if (probe.kind != LabAudioKind.wavPcm16) {
      final durationUs = probe.durationUs;
      if (durationUs == null) throw StateError('LAB_COMPRESSED_PROBE_CONTRACT_HOLD');
      LabCompressedChunkChain.verify(result, durationUs ~/ 1000);
    }
    if (await digest(source) != sourceSha) {
      throw StateError('LAB_SOURCE_CHANGED_AFTER_STAGE');
    }
    return List.unmodifiable(result);
    } catch (_) {
      // Only remove previously verified *temporary* PCM wires from this stage.
      // Never remove original audio, saved Raw, Notes or user preferences.
      if (probe.kind != LabAudioKind.wavPcm16) {
        final safeRoot = Directory(
          '${nativeCacheRoot.path}${Platform.pathSeparator}groq_lab_native_pcm');
        for (final c in result) {
          try {
            if (await c.file.exists() &&
                await c.file.parent.resolveSymbolicLinks() ==
                    await safeRoot.resolveSymbolicLinks()) {
              await c.file.delete();
            }
          } catch (_) { /* Preserve the initial stage exception. */ }
        }
      }
      rethrow;
    }
  }
}
).hasMatch(c.sha256Hex)) {
        throw StateError('LAB_AUDIO_CHAIN_CLOCK_HOLD');
      }
      last = c.coreEndMs;
    }
    if (last != durationMs) throw StateError('LAB_AUDIO_CHAIN_CLOCK_HOLD');
  }
}

/// Lab-only local source probe & physical audio stage. Nothing transmits bytes.
final class LabAudioPipeline {
  const LabAudioPipeline({
    MethodChannel channel = const MethodChannel('groq_stt_lab/offline_audio'),
  }) : _channel = channel;

  final MethodChannel _channel;
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  static Future<String> digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<LabAudioProbe> probe(File source) async {
    if (!await source.exists() || await source.length() <= 0) {
      throw StateError('LAB_AUDIO_EMPTY_OR_MISSING_SOURCE');
    }
    final read = await source.open(mode: FileMode.read);
    late final List<int> prefix;
    try {
      prefix = await read.read(12);
    } finally {
      await read.close();
    }
    if (prefix.length == 12 &&
        String.fromCharCodes(prefix.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(prefix.sublist(8, 12)) == 'WAVE') {
      return const LabAudioProbe(
          LabAudioKind.wavPcm16, 'audio/wav', null);
    }
    final meta = await _channel.invokeMapMethod<String, dynamic>(
      'inspectAudio', {'sourcePath': source.path});
    if (meta == null || meta['durationUs'] is! int ||
        meta['sourceBytes'] != await source.length()) {
      throw StateError('LAB_AUDIO_PROBE_METADATA_HOLD');
    }
    final codec = meta['mime'];
    final int durationUs = meta['durationUs'] as int;
    if (codec != 'audio/mpeg' && codec != 'audio/mp4a-latm') {
      throw StateError('LAB_AUDIO_UNSUPPORTED_CODEC');
    }
    LabCompressedWindowPlanner.plan(durationUs);
    return LabAudioProbe(
        codec == 'audio/mpeg' ? LabAudioKind.mp3 : LabAudioKind.aacM4a,
        codec as String, durationUs);
  }

  static Future<void> verifyPcm16Wave(File file, int expectedBytes) async {
    final reader = await file.open(mode: FileMode.read);
    try {
      final header = await reader.read(44);
      if (header.length != 44 ||
          ascii.decode(header.sublist(0, 4)) != 'RIFF' ||
          ascii.decode(header.sublist(8, 12)) != 'WAVE' ||
          ascii.decode(header.sublist(12, 16)) != 'fmt ' ||
          ascii.decode(header.sublist(36, 40)) != 'data') {
        throw StateError('LAB_NATIVE_INVALID_WAV_HEADER');
      }
      final v = ByteData.sublistView(Uint8List.fromList(header));
      if (v.getUint32(4, Endian.little) != expectedBytes - 8 ||
          v.getUint32(16, Endian.little) != 16 ||
          v.getUint16(20, Endian.little) != 1 ||
          v.getUint16(22, Endian.little) != 1 ||
          v.getUint32(24, Endian.little) != 16000 ||
          v.getUint32(28, Endian.little) != 32000 ||
          v.getUint16(32, Endian.little) != 2 ||
          v.getUint16(34, Endian.little) != 16 ||
          v.getUint32(40, Endian.little) != expectedBytes - 44) {
        throw StateError('LAB_NATIVE_INVALID_PCM16_LAYOUT');
      }
    } finally {
      await reader.close();
    }
  }

  Future<List<LabStagedChunk>> stage({
    required File source,
    required LabAudioProbe probe,
    required String sourceSha,
    required Directory wavOutputRoot,
    required Directory nativeCacheRoot,
  }) async {
    if (!_hex64.hasMatch(sourceSha) ||
        await digest(source) != sourceSha) {
      throw StateError('LAB_SOURCE_CHANGED_BEFORE_STAGE');
    }
    final result = <LabStagedChunk>[];
    if (probe.kind == LabAudioKind.wavPcm16) {
      // FilePicker's selected source normally lives under Android cache/.
      // Stage WAV chunks under the separate appSupport/lab_wav_outputs root,
      // never within the same parent cache to avoid SOURCE_IN_CACHE.
      final parts = await GroqWavPcmSplitter.stage(
          source: source, cacheRoot: wavOutputRoot);
      for (final part in parts) {
        final bytes = await part.file.length();
        if (bytes < 45 || bytes >= 22500000) {
          throw StateError('LAB_WAV_OUTPUT_BYTES_HOLD');
        }
        result.add(LabStagedChunk(
          file: part.file,
          byteCount: bytes,
          sha256Hex: await digest(part.file),
          coreStartMs: part.coreStartMs,
          coreEndMs: part.coreEndMs,
          wireStartMs: part.wireStartMs,
          wireEndMs: part.wireEndMs,
        ));
      }
    } else {
      // A compressed probe must carry an explicit, bounded source clock.
      // Do not allow a missing or inconsistent native provenance to be
      // treated as a valid decoded PCM upload candidate.
      final durationUs = probe.durationUs;
      if (durationUs == null ||
          (probe.kind == LabAudioKind.mp3 && probe.mime != 'audio/mpeg') ||
          (probe.kind == LabAudioKind.aacM4a &&
              probe.mime != 'audio/mp4a-latm')) {
        throw StateError('LAB_COMPRESSED_PROBE_CONTRACT_HOLD');
      }
      final windows = LabCompressedWindowPlanner.plan(durationUs);
      final sourceBytes = await source.length();
      final allowedDir = Directory(
          '${nativeCacheRoot.path}${Platform.pathSeparator}groq_lab_native_pcm');
      // Android native creates this output directory only after validating
      // cache scope, available storage and the encoded source.
      for (final w in windows) {
        final meta = await _channel.invokeMapMethod<String, dynamic>(
          'decodeAudioWindow', {
            'sourcePath': source.path,
            'startMs': w.wireStartMs,
            'endMs': w.wireEndMs,
          },
        );
        if (meta == null || meta['outputPath'] is! String ||
            meta['bytes'] is! int || meta['wireSha256'] is! String ||
            meta['sourceSha256'] != sourceSha ||
            // Both the inspected source clock and source byte extent must
            // agree with each physical window's native decode receipt.
            // The SHA alone does not bind a reused/forged duration record.
            meta['sourceDurationUs'] != durationUs ||
            meta['sourceBytes'] != sourceBytes ||
            meta['requestedStartUs'] != w.wireStartMs * 1000 ||
            meta['requestedEndUs'] != w.wireEndMs * 1000 ||
            // These are explicitly NOT acoustic or Owner playback proof.
            meta['acousticTimingVerified'] != false ||
            meta['ownerPlaybackVerified'] != false ||
            meta['mime'] != 'audio/wav' ||
            meta['codec'] != 'audio/pcm' ||
            meta['sampleRate'] != 16000 ||
            meta['channels'] != 1 ||
            meta['bitsPerSample'] != 16 ||
            meta['decoderVerified'] != true ||
            meta['providerUploadAuthorized'] != false ||
            meta['firstDecodedPtsUs'] is! int ||
            meta['lastDecodedPtsUs'] is! int ||
            meta['leadingPtsCompensationUs'] is! int ||
            !_hex64.hasMatch(meta['wireSha256'] as String)) {
          throw StateError('LAB_NATIVE_OUTPUT_CONTRACT_HOLD');
        }
        final staged = File(meta['outputPath'] as String);
        final physicalParent = await staged.parent.resolveSymbolicLinks();
        final physicalDir = await allowedDir.resolveSymbolicLinks();
        final bytes = meta['bytes'] as int;
        if (physicalParent != physicalDir ||
            await staged.length() != bytes ||
            bytes < 45 || bytes >= 22500000 ||
            await digest(staged) != meta['wireSha256']) {
          throw StateError('LAB_NATIVE_OUTPUT_SHA_SCOPE_HOLD');
        }
        await verifyPcm16Wave(staged, bytes);
        final frames = meta['outputFrames'];
        final expectedFrames = (w.wireEndMs - w.wireStartMs) * 16;
        if (frames is! int ||
            !LabNativePcmCoverage.accepts(
              outputFrames: frames,
              expectedFrames: expectedFrames,
              wireStartUs: w.wireStartMs * 1000,
              wireEndUs: w.wireEndMs * 1000,
              firstDecodedPtsUs: meta['firstDecodedPtsUs'] as int,
              lastDecodedPtsUs: meta['lastDecodedPtsUs'] as int,
              leadingPtsCompensationUs: meta['leadingPtsCompensationUs'] as int,
            ) ||
            bytes != 44 + frames * 2) {
          throw StateError('LAB_NATIVE_INCOMPLETE_AUDIO_WINDOW_HOLD');
        }
        result.add(LabStagedChunk(
          file: staged,
          byteCount: bytes,
          sha256Hex: meta['wireSha256'] as String,
          coreStartMs: w.coreStartMs,
          coreEndMs: w.coreEndMs,
          wireStartMs: w.wireStartMs,
          wireEndMs: w.wireEndMs,
        ));
      }
    }
    if (await digest(source) != sourceSha) {
      throw StateError('LAB_SOURCE_CHANGED_AFTER_STAGE');
    }
    return List.unmodifiable(result);
  }
}
