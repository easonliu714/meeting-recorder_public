import 'dart:convert';

import 'lab_audio_pipeline.dart';

/// Synthetic text, deliberately unrelated to any user's recording.
/// No provider call. Tests only the Groq verbose_json parsing contract.
final class LabSttDemoFixtures {
  const LabSttDemoFixtures._();

  static List<String> buildForPhysicalChunks(List<LabStagedChunk> chunks) {
    if (chunks.isEmpty || chunks.length > 1000) {
      throw StateError('LAB_STT_MOCK_CHUNKS_REQUIRED');
    }
    final out = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      final duration = c.wireEndMs - c.wireStartMs;
      if (duration < 20) throw StateError('LAB_STT_MOCK_WIRE_TOO_SHORT');
      final segments = <Map<String, Object>>[];
      if (i > 0 && duration >= 3000 && c.wireStartMs < c.coreStartMs) {
        // This text belongs to the previous window's 2s overlap,
        // and must remain visible for human review, not auto-deduplicated.
        segments.add({
          'id': 0, 'start': 0.15, 'end': 0.75,
          'text': '[LAB_MOCK] previous-context: review, not actual speech',
        });
      }
      final start = duration >= 3500
          ? 2.2
          : duration >= 1200
              ? 0.2
              : 0.0;
      final end = duration >= 3500
          ? 2.85
          : duration >= 1200
              ? 0.7
              : (duration / 1000) * 0.8;
      if (end <= start || end * 1000 > duration) {
        throw StateError('LAB_STT_MOCK_SEGMENT_CLOCK_HOLD');
      }
      segments.add({
        'id': segments.length,
        'start': start,
        'end': end,
        'text': '[LAB_MOCK] segment ${i + 1}: synthetic test text',
      });
      out.add(jsonEncode({
        'text': '[LAB_MOCK] synthetic test response, NOT Groq STT',
        'language': 'en',
        'segments': segments,
      }));
    }
    return List.unmodifiable(out);
  }
}
