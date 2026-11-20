import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'groq_wav_balanced_core_plan.dart';

/// Balanced, local-only classic PCM16 RIFF/WAVE chunk staging for Groq.
/// Input is read only, staged output lives in an isolated owned cache folder.
class GroqWavPart {
  GroqWavPart(this.file, this.coreStartFrame, this.coreEndFrame,
      this.wireStartFrame, this.wireEndFrame, this.sampleRate);
  final File file;
  final int coreStartFrame, coreEndFrame, wireStartFrame, wireEndFrame, sampleRate;
  int get coreStartMs => coreStartFrame * 1000 ~/ sampleRate;
  int get coreEndMs => coreEndFrame * 1000 ~/ sampleRate;
  int get wireStartMs => wireStartFrame * 1000 ~/ sampleRate;
  int get wireEndMs => wireEndFrame * 1000 ~/ sampleRate;
}

class _PcmLayout {
  _PcmLayout(this.offset, this.size, this.sampleRate, this.channels);
  final int offset, size, sampleRate, channels;
  int get align => channels * 2;
}

class GroqWavPcmSplitter {
  static int _i32(List<int> data, int at) =>
      ByteData.sublistView(Uint8List.fromList(data)).getUint32(at, Endian.little);
  static int _i16(List<int> data, int at) =>
      ByteData.sublistView(Uint8List.fromList(data)).getUint16(at, Endian.little);

  static Future<_PcmLayout> _layout(RandomAccessFile f) async {
    final length = await f.length();
    if (length < 44) throw const FormatException('WAV_TOO_SHORT');
    final header = await f.read(12);
    if (header.length != 12 ||
        String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(header.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('NOT_RIFF_WAVE');
    }
    final riffEnd = 8 + _i32(header, 4);
    if (riffEnd < 44 || riffEnd > length) {
      throw const FormatException('RIFF_LENGTH_OUT_OF_BOUNDS');
    }
    // The RIFF size is the authoritative container extent. Any bytes after
    // that extent were not parsed or approved for staging; never silently
    // accept appended media, partial headers, or undeclared payload.
    if (riffEnd != length) {
      throw const FormatException('WAV_RIFF_UNDECLARED_TRAILER_HOLD');
    }
    int? sampleRate, channels, dataOffset, dataSize;
    var pos = 12;
    var count = 0;
    while (pos + 8 <= riffEnd && ++count <= 128) {
      await f.setPosition(pos);
      final h = await f.read(8);
      if (h.length != 8) throw const FormatException('WAV_CHUNK_TRUNCATED');
      final kind = String.fromCharCodes(h.sublist(0, 4));
      final bytes = _i32(h, 4);
      final next = pos + 8 + bytes;
      // RIFF chunk sizes exclude the mandatory pad byte after odd payloads.
      // Never accept an odd-size chunk whose pad extends past RIFF bounds.
      final paddedNext = next + (bytes.isOdd ? 1 : 0);
      if (next > riffEnd || paddedNext > riffEnd) {
        throw const FormatException('WAV_CHUNK_OVERRUN');
      }
      if (kind == 'fmt ') {
        if (sampleRate != null || bytes < 16 || bytes > 65536) {
          throw const FormatException('INVALID_WAV_FMT');
        }
        final fmt = await f.read(16);
        if (fmt.length != 16 || _i16(fmt, 0) != 1 ||
            _i16(fmt, 14) != 16) {
          throw const FormatException('UNSUPPORTED_NON_PCM16');
        }
        channels = _i16(fmt, 2);
        sampleRate = _i32(fmt, 4);
        if (channels < 1 || channels > 2 || sampleRate < 8000 ||
            _i16(fmt, 12) != channels * 2 ||
            _i32(fmt, 8) != sampleRate * channels * 2) {
          throw const FormatException('INVALID_PCM_LAYOUT');
        }
      } else if (kind == 'data') {
        if (dataOffset != null) throw const FormatException('MULTIPLE_WAV_DATA');
        dataOffset = pos + 8;
        dataSize = bytes;
      }
      pos = paddedNext;
    }
    // A partial 1..7 byte trailer or more than 128 RIFF subchunks must not
    // be silently ignored after a valid fmt/data pair. Fail closed before
    // ever staging or transmitting a byte of corrupted audio.
    if (pos != riffEnd) {
      throw const FormatException('WAV_RIFF_CHUNK_TRAILER_HOLD');
    }
    if (sampleRate == null || channels == null || dataOffset == null ||
        dataSize == null || dataSize <= 0 || dataSize % (channels * 2) != 0) {
      throw const FormatException('WAV_FORMAT_OR_DATA_MISSING');
    }
    return _PcmLayout(dataOffset, dataSize, sampleRate, channels);
  }

  /// Verify actual staged WAV files before handing them to any consumer.
  /// A pure frame plan is insufficient: the physical headers, file lengths,
  /// 2-second context and complete source Core coverage must also agree.
  /// This only reads new staged files and never changes the original source.
  static Future<void> verifyPhysicalStage({
    required List<GroqWavPart> parts,
    required int expectedTotalFrames,
    required int sampleRate,
    required int channels,
  }) async {
    if (parts.isEmpty || expectedTotalFrames <= 0 ||
        sampleRate < 8000 || sampleRate > 384000 ||
        channels < 1 || channels > 2) {
      throw StateError('WAV_PHYSICAL_CLOCK_OR_BYTES_HOLD');
    }
    var nextCore = 0;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final wireStart = i == 0 ? 0 : nextCore - 2 * sampleRate;
      if (part.sampleRate != sampleRate ||
          part.coreStartFrame != nextCore ||
          part.coreEndFrame <= nextCore ||
          part.coreEndFrame > expectedTotalFrames ||
          part.wireStartFrame != wireStart ||
          part.wireStartFrame < 0 ||
          part.wireEndFrame != part.coreEndFrame) {
        throw StateError('WAV_PHYSICAL_CLOCK_OR_BYTES_HOLD');
      }
      final reader = await part.file.open(mode: FileMode.read);
      late final List<int> header;
      late final int fileBytes;
      try {
        header = await reader.read(44);
        fileBytes = await reader.length();
      } finally {
        await reader.close();
      }
      final dataBytes =
          (part.wireEndFrame - part.wireStartFrame) * channels * 2;
      if (header.length != 44 ||
          String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' ||
          String.fromCharCodes(header.sublist(8, 12)) != 'WAVE' ||
          String.fromCharCodes(header.sublist(12, 16)) != 'fmt ' ||
          String.fromCharCodes(header.sublist(36, 40)) != 'data' ||
          _i32(header, 4) != 36 + dataBytes ||
          _i32(header, 16) != 16 ||
          _i16(header, 20) != 1 ||
          _i16(header, 22) != channels ||
          _i32(header, 24) != sampleRate ||
          _i32(header, 28) != sampleRate * channels * 2 ||
          _i16(header, 32) != channels * 2 ||
          _i16(header, 34) != 16 ||
          _i32(header, 40) != dataBytes ||
          fileBytes != 44 + dataBytes) {
        throw StateError('WAV_PHYSICAL_CLOCK_OR_BYTES_HOLD');
      }
      nextCore = part.coreEndFrame;
    }
    if (nextCore != expectedTotalFrames) {
      throw StateError('WAV_PHYSICAL_CLOCK_OR_BYTES_HOLD');
    }
  }

  static Uint8List _header(_PcmLayout p, int bytes) {
    final out = Uint8List(44);
    final b = ByteData.sublistView(out);
    void put(int at, String s) => out.setRange(at, at + s.length, s.codeUnits);
    put(0, 'RIFF');
    b.setUint32(4, 36 + bytes, Endian.little);
    put(8, 'WAVE');
    put(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little);
    b.setUint16(22, p.channels, Endian.little);
    b.setUint32(24, p.sampleRate, Endian.little);
    b.setUint32(28, p.sampleRate * p.align, Endian.little);
    b.setUint16(32, p.align, Endian.little);
    b.setUint16(34, 16, Endian.little);
    put(36, 'data');
    b.setUint32(40, bytes, Endian.little);
    return out;
  }

  /// H02B changed stage(): use minimum-count balanced Core windows, with
  /// no artificial Groq 10-second minimum; short tails are rebalanced,
  /// all actual wire WAV bytes strictly less than 22,500,000, <=700s Core,
  /// exactly 2s contextual overlap; never drop or rewrite the source Part.
  static Future<List<GroqWavPart>> stage({
    required File source,
    required Directory cacheRoot,
    int maxBytes = GroqWavBalancedCorePlanner.defaultWireBudget,
    int overlapSeconds = GroqWavBalancedCorePlanner.overlapSeconds,
    bool Function()? cancellationRequested,
  }) async {
    if (maxBytes < 65536 ||
        maxBytes > GroqWavBalancedCorePlanner.strictWireCeiling ||
        overlapSeconds != 2) {
      throw StateError('INVALID_BYTE_OVERLAP_POLICY');
    }
    if (cancellationRequested?.call() == true) {
      throw StateError('LAB_AUDIO_CANCELLED');
    }
    await cacheRoot.create(recursive: true);
    final original = await source.resolveSymbolicLinks();
    final cache = await cacheRoot.resolveSymbolicLinks();
    if (original == cache || original.startsWith(cache + Platform.pathSeparator)) {
      throw StateError('SOURCE_IN_CACHE');
    }
    final reader = await source.open(mode: FileMode.read);
    Directory? owned;
    try {
      final p = await _layout(reader);
      final plan = GroqWavBalancedCorePlanner.plan(
        totalFrames: p.size ~/ p.align,
        sampleRate: p.sampleRate,
        channels: p.channels,
        maxBytes: maxBytes,
      );
      owned = await cacheRoot.createTemp('groq_pcm_staged_');
      final result = <GroqWavPart>[];
      for (final window in plan.windows) {
        if (cancellationRequested?.call() == true) {
          throw StateError('LAB_AUDIO_CANCELLED');
        }
        final bytes = (window.coreEndFrame - window.wireStartFrame) * p.align;
        if (bytes + 44 != window.wireBytes ||
            bytes + 44 >= maxBytes ||
            bytes + 44 >= GroqWavBalancedCorePlanner.strictWireCeiling) {
          throw StateError('REAL_WAV_BYTE_LIMIT');
        }
        final file = File('${owned.path}/pcm_${result.length}.wav');
        final writer = await file.open(mode: FileMode.write);
        try {
          await writer.writeFrom(_header(p, bytes));
          await reader.setPosition(p.offset + window.wireStartFrame * p.align);
          var remaining = bytes;
          while (remaining > 0) {
            if (cancellationRequested?.call() == true) {
              throw StateError('LAB_AUDIO_CANCELLED');
            }
            final chunk = await reader.read(math.min(32768, remaining));
            if (chunk.isEmpty) throw StateError('TRUNCATED_SOURCE');
            await writer.writeFrom(chunk);
            remaining -= chunk.length;
          }
        } finally {
          await writer.close();
        }
        if (await file.length() != window.wireBytes) {
          throw StateError('OUTPUT_BYTE_MISMATCH');
        }
        result.add(GroqWavPart(file,
          window.coreStartFrame, window.coreEndFrame,
          window.wireStartFrame, window.coreEndFrame, p.sampleRate));
      }
      // Fail closed on physical clock/header/size drift. Existing catch
      // cleans only this invocation's new temporary Chunk directory.
      if (cancellationRequested?.call() == true) {
        throw StateError('LAB_AUDIO_CANCELLED');
      }
      await verifyPhysicalStage(
        parts: result,
        expectedTotalFrames: p.size ~/ p.align,
        sampleRate: p.sampleRate,
        channels: p.channels,
      );
      return result;
    } catch (_) {
      if (owned != null) await owned.delete(recursive: true);
      rethrow;
    } finally {
      await reader.close();
    }
  }
}
