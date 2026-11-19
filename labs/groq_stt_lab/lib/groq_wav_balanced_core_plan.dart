import 'dart:math' as math;

/// One physical PCM16 Part. Core windows cover every frame exactly once;
/// wire windows include 2s of context from the preceding core.
final class GroqBalancedWavWindow {
  const GroqBalancedWavWindow({
    required this.coreStartFrame,
    required this.coreEndFrame,
    required this.wireStartFrame,
    required this.wireBytes,
  });

  final int coreStartFrame;
  final int coreEndFrame;
  final int wireStartFrame;
  final int wireBytes;
}

final class GroqBalancedWavPlan {
  const GroqBalancedWavPlan({
    required this.windows,
    required this.shortOriginalException,
  });

  final List<GroqBalancedWavWindow> windows;
  /// Informational only: a whole original Part shorter than 10s can be a single core.
  /// Never used as a minimum Groq duration constraint.
  final bool shortOriginalException;
}

/// Pure offline, smallest-window-count planner for Groq PCM16 WAV.
///
/// Policy: strict wire length < 22,500,000 bytes (including RIFF header and
/// overlap); maximum core duration 700s; 2s overlap. Do not impose a
/// 10-second minimum, as Groq itself accepts shorter sources. Choose the
/// minimum feasible number of windows; balance tails when possible. Fail
/// closed if overlap cannot be represented or would exceed the core budget.
/// Never drop a tail or merge distinct original Parts.
final class GroqWavBalancedCorePlanner {
  const GroqWavBalancedCorePlanner._();
  static const int defaultWireBudget = 22500000;
  static const int strictWireCeiling = 22500000;
  // Advisory 10-second reference, never a hard Groq admission minimum.
  static const int advisoryCoreSeconds = 10;
  static const int overlapSeconds = 2;
  static const int maximumCoreSeconds = 700;
  static const int maximumWindows = 1000;

  static GroqBalancedWavPlan plan({
    required int totalFrames,
    required int sampleRate,
    required int channels,
    int maxBytes = defaultWireBudget,
  }) {
    if (sampleRate < 8000 || sampleRate > 384000 ||
        channels < 1 || channels > 2 || totalFrames <= 0 ||
        maxBytes < 65536 || maxBytes > strictWireCeiling) {
      throw StateError('INVALID_PCM_OR_BYTE_POLICY');
    }
    // Groq official input lower bound is 0.01 seconds, not 10 seconds.
    // Keep this distinct from any optional UX/model-fallback decision.
    if (totalFrames * 100 < sampleRate) {
      throw StateError('GROQ_MINIMUM_AUDIO_LENGTH');
    }
    final frameAlign = channels * 2;
    final overlapFrames = sampleRate * overlapSeconds;
    // bytes + 44 < maxBytes; hence maximum data frames below.
    final wireCapacity = (maxBytes - 45) ~/ frameAlign;
    final maximumCoreFrames = sampleRate * maximumCoreSeconds;
    final firstCapacity = math.min(maximumCoreFrames, wireCapacity);
    final repeatedCapacity = math.min(
        maximumCoreFrames, wireCapacity - overlapFrames);
    if (firstCapacity < 1) throw StateError('CORE_TOO_SMALL');

    // The original Part fits a single wire window: do not force a split.
    final oneWindow = totalFrames <= firstCapacity;
    final count = oneWindow
        ? 1
        : (repeatedCapacity <= 0
            ? maximumWindows + 1
            : 1 + (totalFrames - firstCapacity + repeatedCapacity - 1) ~/
                repeatedCapacity);
    if (count > maximumWindows) throw StateError('TOO_MANY_CHUNKS');

    // Reject impractical repeated windows whose new core would not cover
    // even one overlap interval; this is an efficiency rule, not a Groq
    // minimum duration. Exact source Part and Byte Budget are unchanged.
    if (!oneWindow && repeatedCapacity < overlapFrames) {
      throw StateError('OVERLAP_DOMINATES_CORE_HOLD');
    }

    final capacities = List<int>.generate(count,
        (i) => i == 0 ? firstCapacity : repeatedCapacity);

    // Max-min fair allocation with capacity-aware water filling. O(n log N),
    // rather than adding individual frames in a potentially multi-hour file.
    var low = 0;
    var high = firstCapacity;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      var accommodated = 0;
      for (final cap in capacities) {
        accommodated += math.min(cap, mid);
      }
      if (accommodated <= totalFrames) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    final sizes = capacities.map((c) => math.min(c, low)).toList();
    var leftover = totalFrames - sizes.fold<int>(0, (a, b) => a + b);
    for (var i = 0; i < count && leftover > 0; i++) {
      if (sizes[i] < capacities[i]) {
        sizes[i]++;
        leftover--;
      }
    }
    if (leftover != 0 || sizes.any((n) => n <= 0)) {
      throw StateError('BALANCED_ALLOCATION_HOLD');
    }
    if (count > 1 && (sizes.first < overlapFrames ||
        sizes.skip(1).any((n) => n < overlapFrames))) {
      throw StateError('OVERLAP_DOMINATES_CORE_HOLD');
    }

    final windows = <GroqBalancedWavWindow>[];
    var start = 0;
    for (var i = 0; i < count; i++) {
      final end = start + sizes[i];
      final wireStart = i == 0 ? 0 : start - overlapFrames;
      final wireFrames = end - wireStart;
      final wireBytes = 44 + wireFrames * frameAlign;
      if (wireStart < 0 || end > totalFrames ||
          wireBytes >= maxBytes || wireBytes >= strictWireCeiling ||
          sizes[i] > maximumCoreFrames ||
          wireFrames > sampleRate * (maximumCoreSeconds + overlapSeconds)) {
        throw StateError('BALANCED_WAV_BOUNDARY_HOLD');
      }
      windows.add(GroqBalancedWavWindow(
        coreStartFrame: start,
        coreEndFrame: end,
        wireStartFrame: wireStart,
        wireBytes: wireBytes,
      ));
      start = end;
    }
    if (start != totalFrames) throw StateError('BALANCED_WAV_COVERAGE_HOLD');
    return GroqBalancedWavPlan(
      windows: List.unmodifiable(windows),
      shortOriginalException: count == 1 &&
          totalFrames < sampleRate * advisoryCoreSeconds,
    );
  }
}
