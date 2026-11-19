import 'groq_wav_balanced_core_plan.dart';

/// Offline Groq multi-Part / multi-window transcription clock contract.
/// No cloud calls, uploads, string dedup or modifications of provider raw STT.
class GroqChunkClock {
  const GroqChunkClock({
    required this.partId,
    required this.partSha256,
    required this.partGlobalStartMs,
    required this.partDurationMs,
    required this.coreStartMs,
    required this.coreEndMs,
    required this.wireStartMs,
    required this.wireEndMs,
    required this.byteCount,
  });
  final String partId;
  final String partSha256;
  final int partGlobalStartMs;
  final int partDurationMs;
  final int coreStartMs;
  final int coreEndMs;
  final int wireStartMs;
  final int wireEndMs;
  final int byteCount;

  int get globalCoreStartMs => partGlobalStartMs + coreStartMs;
  int get globalCoreEndMs => partGlobalStartMs + coreEndMs;
}

/// Validate actual Part identity/offset and guaranteed core coverage.
/// Overlap has exactly 2000ms unless source begins earlier than that.
/// H04B strict <22.5MB physical WAV/AAC wire and <=702s core+overlap.
class GroqChunkClockContract {
  static void verify(List<GroqChunkClock> chunks) {
    if (chunks.isEmpty) throw StateError('NO_CHUNKS');
    var expectedPartOffset = 0;
    var currentPartId = '';
    var currentSha = '';
    var currentPartDuration = 0;
    var expectedCoreStart = 0;
    var previousGlobalEnd = 0;
    final seenPartIds = <String>{};

    for (final c in chunks) {
      if (c.partId.trim().isEmpty || c.partSha256.length != 64 ||
          c.partGlobalStartMs < 0 || c.partDurationMs <= 0 ||
          c.coreStartMs < 0 || c.coreEndMs <= c.coreStartMs ||
          c.coreEndMs > c.partDurationMs ||
          // H04M long-audio: the physical wire's 702s cap is not a
          // substitute for the stricter 700s CORE budget (first wire
          // has no overlap and could otherwise admit a 701s core).
          c.coreEndMs - c.coreStartMs >
              GroqWavBalancedCorePlanner.maximumCoreSeconds * 1000 ||
          c.wireStartMs < 0 || c.wireEndMs != c.coreEndMs ||
          c.wireStartMs > c.coreStartMs ||
          c.wireEndMs - c.wireStartMs > (GroqWavBalancedCorePlanner.maximumCoreSeconds + GroqWavBalancedCorePlanner.overlapSeconds) * 1000 ||
          c.byteCount <= 0 || c.byteCount >= GroqWavBalancedCorePlanner.strictWireCeiling) {
        throw StateError('INVALID_SOURCE_OR_CHUNK_CONTRACT');
      }
      if (c.partId != currentPartId) {
        // A Part may own adjacent windows, but cannot reappear after another
        // Part: that would replay the same source at a forged global offset.
        if (!seenPartIds.add(c.partId)) {
          throw StateError('PART_ID_REUSED_NONCONTIGUOUS');
        }
        if (currentPartId.isNotEmpty) {
          if (expectedCoreStart != currentPartDuration) {
            throw StateError('PREVIOUS_PART_CORE_GAP');
          }
          expectedPartOffset += currentPartDuration;
        }
        if (c.partGlobalStartMs != expectedPartOffset ||
            c.coreStartMs != 0 || c.wireStartMs != 0) {
          throw StateError('PART_GLOBAL_OFFSET_OR_ORIGIN_GAP');
        }
        currentPartId = c.partId;
        currentSha = c.partSha256;
        currentPartDuration = c.partDurationMs;
        expectedCoreStart = 0;
      } else if (c.partGlobalStartMs != expectedPartOffset ||
          c.partDurationMs != currentPartDuration ||
          c.partSha256 != currentSha) {
        throw StateError('PART_SOURCE_IDENTITY_CHANGED');
      }
      if (c.coreStartMs != expectedCoreStart) {
        throw StateError('CHUNK_CORE_GAP_OR_COLLISION');
      }
      final expectedWireStart =
          c.coreStartMs > 2000 ? c.coreStartMs - 2000 : 0;
      if (c.wireStartMs != expectedWireStart) {
        throw StateError('CHUNK_WIRE_OVERLAP_MISMATCH');
      }
      if (c.globalCoreStartMs != previousGlobalEnd) {
        throw StateError('GLOBAL_STT_TIMELINE_GAP');
      }
      previousGlobalEnd = c.globalCoreEndMs;
      expectedCoreStart = c.coreEndMs;
    }
    if (expectedCoreStart != currentPartDuration) {
      throw StateError('FINAL_PART_INCOMPLETE');
    }
  }

  /// Map a provider timestamp relative to the *wire* chunk to Part-global
  /// milliseconds. This does NOT silently remove repeated phrases.
  static int globalTimeMs(GroqChunkClock chunk, int providerWireMs) {
    if (providerWireMs < 0 ||
        providerWireMs > chunk.wireEndMs - chunk.wireStartMs) {
      throw StateError('PROVIDER_TIMESTAMP_OUTSIDE_WIRE');
    }
    return chunk.partGlobalStartMs + chunk.wireStartMs + providerWireMs;
  }

  /// Only timeline ownership; cross-core speech still needs overlap-aware
  /// lexical/audio evidence review before any final transcript dedup.
  static bool isCoreOwned(GroqChunkClock chunk, int globalMs) =>
      globalMs >= chunk.globalCoreStartMs &&
      globalMs < chunk.globalCoreEndMs;
}
