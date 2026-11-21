import 'dart:io';

import 'groq_wav_pcm_splitter.dart';
import 'lab_audio_pipeline.dart';

/// Volatile, read-only provenance for a user-selected audio Part.
/// The sequential clock is estimated from duration; it is not Recorder PTS.
final class LabPartReceipt {
  const LabPartReceipt({
    required this.source,
    required this.kind,
    required this.bytes,
    required this.sha256,
    required this.durationMs,
    required this.logicalStartMs,
    required this.logicalEndMs,
  });
  final File source;
  final LabAudioKind kind;
  final int bytes;
  final String sha256;
  final int durationMs;
  final int logicalStartMs;
  final int logicalEndMs;
}

final class LabPartRoster {
  const LabPartRoster._();
  static const maxParts = 12;
  static const maxTotalMs = 7200000;

  static Future<LabPartReceipt> append({
    required File source,
    required LabAudioProbe probe,
    required List<LabPartReceipt> previous,
  }) async {
    if (previous.length >= maxParts) {
      throw StateError('LAB_PART_COUNT_LIMIT_HOLD');
    }
    if (previous.isNotEmpty) await verify(previous);
    if (!await source.exists()) throw StateError('LAB_PART_MISSING_HOLD');
    final bytes = await source.length();
    if (bytes <= 0) throw StateError('LAB_PART_EMPTY_HOLD');

    final int durationMs;
    if (probe.kind == LabAudioKind.wavPcm16) {
      if (probe.mime != 'audio/wav') {
        throw StateError('LAB_PART_PROBE_CONTRACT_HOLD');
      }
      durationMs = await GroqWavPcmSplitter.readDurationMs(source);
    } else {
      final validMime = probe.kind == LabAudioKind.mp3
          ? 'audio/mpeg' : 'audio/mp4a-latm';
      final rate = probe.inputSampleRateHz;
      if (probe.mime != validMime || probe.durationUs == null ||
          probe.durationUs! <= 0 || rate == null ||
          rate < 8000 || rate > 48000) {
        throw StateError('LAB_PART_PROBE_CONTRACT_HOLD');
      }
      durationMs = probe.durationUs! ~/ 1000;
    }
    if (durationMs <= 0 || durationMs > maxTotalMs) {
      throw StateError('LAB_PART_DURATION_HOLD');
    }
    final sha = await LabAudioPipeline.digest(source);
    if (previous.any((part) => part.sha256 == sha)) {
      throw StateError('LAB_PART_DUPLICATE_SOURCE_HOLD');
    }
    final start = previous.isEmpty ? 0 : previous.last.logicalEndMs;
    final end = start + durationMs;
    if (end > maxTotalMs || start < 0) {
      throw StateError('LAB_PART_TOTAL_DURATION_HOLD');
    }
    if (await source.length() != bytes ||
        await LabAudioPipeline.digest(source) != sha) {
      throw StateError('LAB_PART_SOURCE_CHANGED_HOLD');
    }
    return LabPartReceipt(
      source: source, kind: probe.kind, bytes: bytes, sha256: sha,
      durationMs: durationMs, logicalStartMs: start, logicalEndMs: end);
  }

  /// Optional overlap witness for source WAVs known to share 2s of audio.
  /// Never use the result as evidence of Recorder-global timestamps.
  static Future<int> verifyWavBoundary(
      List<LabPartReceipt> parts, int rightIndex) async {
    if (rightIndex <= 0 || rightIndex >= parts.length) {
      throw StateError('LAB_PART_WAV_SEAM_INDEX_HOLD');
    }
    await verify(parts);
    final left = parts[rightIndex - 1];
    final right = parts[rightIndex];
    if (left.kind != LabAudioKind.wavPcm16 ||
        right.kind != LabAudioKind.wavPcm16) {
      throw StateError('LAB_PART_WAV_SEAM_CODEC_HOLD');
    }
    final matched = await GroqWavPcmSplitter.verifyExactPartOverlap(
        left: left.source, right: right.source);
    await verify(parts);
    return matched;
  }

  static Future<void> verify(List<LabPartReceipt> parts) async {
    if (parts.isEmpty || parts.length > maxParts) {
      throw StateError('LAB_PART_ROSTER_EMPTY_OR_OVERSIZE_HOLD');
    }
    var clock = 0;
    final seen = <String>{};
    for (final p in parts) {
      if (p.durationMs <= 0 || p.logicalStartMs != clock ||
          p.logicalEndMs != clock + p.durationMs ||
          p.logicalEndMs > maxTotalMs || !seen.add(p.sha256)) {
        throw StateError('LAB_PART_CLOCK_OR_DUPLICATE_HOLD');
      }
      if (!await p.source.exists() ||
          await p.source.length() != p.bytes ||
          await LabAudioPipeline.digest(p.source) != p.sha256) {
        throw StateError('LAB_PART_SOURCE_CHANGED_HOLD');
      }
      if (p.kind == LabAudioKind.wavPcm16 &&
          await GroqWavPcmSplitter.readDurationMs(p.source) != p.durationMs) {
        throw StateError('LAB_PART_WAV_CLOCK_CHANGED_HOLD');
      }
      clock = p.logicalEndMs;
    }
  }
}
