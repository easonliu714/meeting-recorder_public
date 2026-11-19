import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'lab_audio_pipeline.dart';

/// Offline, memory-only ZIP import. Checks manifest, source/physical clocks,
/// Raw/text hashes and ZIP CRC. Never modifies durable Groq Raw or Journal.
/// ZIP authenticity is NOT independently proven, even if hashes match.
final class LabImportedSegmentedStt {
  const LabImportedSegmentedStt(this.rawByIndex, this.shaByIndex);
  final Map<int, String> rawByIndex;
  final Map<int, String> shaByIndex;
  int get count => rawByIndex.length;
}

final class LabSegmentedSttZipImport {
  static const maxZipBytes = 20 * 1024 * 1024;
  static const maxInflatedBytes = 28 * 1024 * 1024;
  static final shaPattern = RegExp(r'^[a-f0-9]{64}$');

  static LabImportedSegmentedStt parse({
    required Uint8List zipBytes,
    required List<LabStagedChunk> staged,
    required String sourceSha256,
  }) {
    if (zipBytes.isEmpty || zipBytes.length > maxZipBytes ||
        staged.isEmpty || staged.length > 1000 ||
        !shaPattern.hasMatch(sourceSha256)) {
      throw StateError('LAB_ZIP_IMPORT_INPUT_HOLD');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    } catch (_) {
      throw StateError('LAB_ZIP_IMPORT_CRC_HOLD');
    }
    final files = <String, ArchiveFile>{};
    var inflated = 0;
    for (final entry in archive.files) {
      inflated += entry.size;
      if (!entry.isFile || entry.size < 0 ||
          entry.size > 4 * 1024 * 1024 || inflated > maxInflatedBytes ||
          entry.name.contains('..') || entry.name.contains('\\') ||
          entry.name.startsWith('/') ||
          files.containsKey(entry.name) ||
          archive.files.length > 2 * staged.length + 4) {
        throw StateError('LAB_ZIP_IMPORT_ENTRY_HOLD');
      }
      files[entry.name] = entry;
    }
    Uint8List read(String filename) {
      final file = files[filename];
      if (file == null) throw StateError('LAB_ZIP_IMPORT_MISSING_HOLD');
      return Uint8List.fromList(file.content as List<int>);
    }
    final dynamic manifest;
    try {
      manifest = jsonDecode(utf8.decode(read('manifest.json')));
    } catch (_) {
      throw StateError('LAB_ZIP_IMPORT_MANIFEST_HOLD');
    }
    if (manifest is! Map<String, dynamic> ||
        manifest['schema'] != 'MEETING_LAB_SEGMENTED_STT_V1' ||
        manifest['source_sha256'] != sourceSha256 ||
        manifest['expected_chunks'] != staged.length ||
        !const {'SHA_VERIFIED_LOCAL_RECEIPTS',
                'IMPORTED_ZIP_SHA_MATCHED_ORIGIN_UNVERIFIED'}
            .contains(manifest['raw_source']) ||
        manifest['provider_segment_clock'] != 'NOT_VALIDATED_FOR_EXPORT' ||
        manifest['ai_merged'] != false ||
        manifest['chunks'] is! List) {
      throw StateError('LAB_ZIP_IMPORT_SOURCE_HOLD');
    }
    final entries = manifest['chunks'] as List;
    final count = manifest['saved_chunks'];
    if (count is! int || count <= 0 || count > staged.length ||
        entries.length != count ||
        manifest['complete'] != (count == staged.length) ||
        files.length != count * 2 + 4) {
      throw StateError('LAB_ZIP_IMPORT_COUNT_HOLD');
    }
    for (final requiredName in [
      'context/participants.txt', 'context/glossary.txt', 'instructions.txt'
    ]) {
      if (!files.containsKey(requiredName)) {
        throw StateError('LAB_ZIP_IMPORT_MISSING_HOLD');
      }
    }
    final raws = <int, String>{}, shaMap = <int, String>{};
    for (var i = 0; i < count; i++) {
      final dynamic meta = entries[i];
      if (meta is! Map<String, dynamic>) {
        throw StateError('LAB_ZIP_IMPORT_CLOCK_HOLD');
      }
      final stage = staged[i];
      final n = (i + 1).toString().padLeft(3, '0');
      final rawName = 'raw/chunk_$n.verbose.json';
      final textName = 'transcripts/chunk_$n.txt';
      if (meta['index'] != i + 1 ||
          meta['raw_file'] != rawName ||
          meta['transcript_file'] != textName ||
          meta['core_start_ms'] != stage.coreStartMs ||
          meta['core_end_ms'] != stage.coreEndMs ||
          meta['wire_start_ms'] != stage.wireStartMs ||
          meta['wire_end_ms'] != stage.wireEndMs ||
          meta['wire_sha256'] != stage.sha256Hex ||
          meta['overlap_before_ms'] != stage.coreStartMs-stage.wireStartMs ||
          meta['provider_segment_clock'] != 'NOT_VALIDATED_FOR_EXPORT') {
        throw StateError('LAB_ZIP_IMPORT_CLOCK_HOLD');
      }
      final rawSha = meta['raw_sha256'];
      final txtSha = meta['text_sha256'];
      if (rawSha is! String || txtSha is! String ||
          !shaPattern.hasMatch(rawSha) || !shaPattern.hasMatch(txtSha)) {
        throw StateError('LAB_ZIP_IMPORT_SHA_HOLD');
      }
      final rawBytes = read(rawName), textBytes = read(textName);
      if (rawBytes.isEmpty ||
          sha256.convert(rawBytes).toString() != rawSha ||
          sha256.convert(textBytes).toString() != txtSha) {
        throw StateError('LAB_ZIP_IMPORT_SHA_HOLD');
      }
      try {
        final raw = utf8.decode(rawBytes, allowMalformed: false);
        final text = utf8.decode(textBytes, allowMalformed: false);
        final parsed = jsonDecode(raw);
        if (parsed is! Map<String, dynamic> ||
            parsed.containsKey('error') ||
            parsed['segments'] is! List ||
            parsed['text'] is! String || parsed['text'] != text) {
          throw StateError('LAB_ZIP_IMPORT_TEXT_HOLD');
        }
        raws[i] = raw;
        shaMap[i] = rawSha;
      } on StateError {
        rethrow;
      } catch (_) {
        throw StateError('LAB_ZIP_IMPORT_TEXT_HOLD');
      }
    }
    return LabImportedSegmentedStt(
        Map.unmodifiable(raws), Map.unmodifiable(shaMap));
  }
}
