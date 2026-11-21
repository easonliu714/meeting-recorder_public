import 'package:flutter/services.dart';

import 'lab_audio_pipeline.dart';
import 'lab_part_roster.dart';

/// A SHA-bound, *source-local* encoded-packet PTS observation.
/// The values cannot establish recorder-session origin or global Part order.
final class LabPartNativePtsReceipt {
  const LabPartNativePtsReceipt({
    required this.index,
    required this.kind,
    required this.sha256,
    required this.firstPtsUs,
    required this.lastPtsUs,
    required this.sampleCount,
    required this.maxGapUs,
    required this.durationUs,
  });

  final int index;
  final LabAudioKind kind;
  final String sha256;
  final int firstPtsUs;
  final int lastPtsUs;
  final int sampleCount;
  final int maxGapUs;
  final int durationUs;
}

/// Bounded Android MediaExtractor scan. Never uploads/rewrites a source.
/// The existing roster is verified both before and after all native reads.
final class LabPartNativePtsScanner {
  const LabPartNativePtsScanner({
    MethodChannel channel = const MethodChannel('groq_stt_lab/offline_audio'),
  }) : _channel = channel;

  final MethodChannel _channel;
  static const maxPackets = 750000;

  static int _field(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is! int) {
      throw StateError('LAB_PART_NATIVE_PTS_RECEIPT_HOLD');
    }
    return value;
  }

  Future<List<LabPartNativePtsReceipt>> scan(
      List<LabPartReceipt> parts) async {
    await LabPartRoster.verify(parts);
    if (parts.any((p) => p.kind == LabAudioKind.wavPcm16)) {
      throw StateError('LAB_PART_NATIVE_PTS_WAV_UNSUPPORTED_HOLD');
    }

    final results = <LabPartNativePtsReceipt>[];
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final data = await _channel.invokeMapMethod<String, dynamic>(
        'inspectPartPts', {'sourcePath': part.source.path});
      if (data == null) {
        throw StateError('LAB_PART_NATIVE_PTS_RECEIPT_HOLD');
      }
      final expectedMime = part.kind == LabAudioKind.mp3
          ? 'audio/mpeg' : 'audio/mp4a-latm';
      final bytes = _field(data, 'sourceBytes');
      final durationUs = _field(data, 'durationUs');
      final rate = _field(data, 'sampleRate');
      final first = _field(data, 'firstPtsUs');
      final last = _field(data, 'lastPtsUs');
      final count = _field(data, 'sampleCount');
      final maxGap = _field(data, 'maxGapUs');
      if (data['mime'] != expectedMime ||
          bytes != part.bytes ||
          durationUs ~/ 1000 != part.durationMs ||
          durationUs <= 0 || durationUs > 7200000000 ||
          rate < 8000 || rate > 48000 ||
          first < -130000 || last <= first ||
          last > durationUs + 500000 ||
          count < 2 || count > maxPackets ||
          maxGap <= 0 || maxGap > 1000000 ||
          maxGap > last - first) {
        throw StateError('LAB_PART_NATIVE_PTS_RECEIPT_HOLD');
      }
      results.add(LabPartNativePtsReceipt(
        index: i + 1,
        kind: part.kind,
        sha256: part.sha256,
        firstPtsUs: first,
        lastPtsUs: last,
        sampleCount: count,
        maxGapUs: maxGap,
        durationUs: durationUs,
      ));
    }
    await LabPartRoster.verify(parts);
    return List.unmodifiable(results);
  }
}
