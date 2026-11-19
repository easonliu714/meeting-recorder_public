import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'lab_audio_pipeline.dart';

/// Immutable export snapshot. This bypasses Provider segment time alignment,
/// never bypasses physical Stage clock checks or receipt SHA verification.
/// Export is user initiated; no HTTP, AI or persistent transcription change.
final class LabSegmentedSttBundle {
  LabSegmentedSttBundle._({
    required this.sourceSha256,
    required this.expectedCount,
    required this.chunks,
    required this.manifest,
    required this.files,
  });

  final String sourceSha256;
  final int expectedCount;
  final List<LabSegmentedTextChunk> chunks;
  final Map<String, Object?> manifest;
  final Map<String, Uint8List> files;

  bool get complete => chunks.length == expectedCount;
  static final _sha = RegExp(r'^[a-f0-9]{64}$');
  static const maxRawBytes = 4 * 1024 * 1024;
  static const maxContextChars = 4000;

  static LabSegmentedSttBundle build({
    required List<LabStagedChunk> staged,
    required String sourceSha256,
    required Map<int, String> savedRawByIndex,
    required Map<int, String> savedRawShaByIndex,
    String participants = '',
    String glossary = '',
    bool unverifiedImportedZip = false,
  }) {
    if (!_sha.hasMatch(sourceSha256) ||
        staged.isEmpty || staged.length > 1000 ||
        savedRawByIndex.isEmpty ||
        savedRawByIndex.length > staged.length ||
        savedRawByIndex.length != savedRawShaByIndex.length ||
        participants.length > maxContextChars ||
        glossary.length > maxContextChars) {
      throw StateError('LAB_ZIP_SOURCE_OR_CONTEXT_HOLD');
    }
    // Validate the entire physical Stage clock, independent of Provider
    // timestamps (which may legitimately be malformed and remain preserved).
    var coreEnd = 0;
    for (final stage in staged) {
      if (stage.coreStartMs != coreEnd ||
          stage.coreEndMs <= stage.coreStartMs ||
          stage.wireStartMs < 0 ||
          stage.wireStartMs > stage.coreStartMs ||
          stage.wireEndMs < stage.coreEndMs ||
          stage.wireEndMs > staged.last.coreEndMs ||
          !_sha.hasMatch(stage.sha256Hex) ||
          stage.byteCount < 45 || stage.byteCount >= 22500000) {
        throw StateError('LAB_ZIP_PHYSICAL_CLOCK_HOLD');
      }
      coreEnd = stage.coreEndMs;
    }
    final files = <String, Uint8List>{};
    final meta = <Map<String, Object?>>[];
    final texts = <LabSegmentedTextChunk>[];
    for (var i = 0; i < savedRawByIndex.length; i++) {
      final raw = savedRawByIndex[i];
      final expectedSha = savedRawShaByIndex[i];
      if (raw == null || expectedSha == null || !_sha.hasMatch(expectedSha)) {
        throw StateError('LAB_ZIP_RECEIPT_GAP_OR_SHA_HOLD');
      }
      final bytes = Uint8List.fromList(utf8.encode(raw));
      if (bytes.isEmpty || bytes.length > maxRawBytes ||
          sha256.convert(bytes).toString() != expectedSha) {
        throw StateError('LAB_ZIP_RECEIPT_SHA_MISMATCH');
      }
      final dynamic parsed;
      try {
        parsed = jsonDecode(raw);
      } catch (_) {
        throw StateError('LAB_ZIP_PROVIDER_JSON_HOLD');
      }
      if (parsed is! Map<String, dynamic> ||
          parsed.containsKey('error') ||
          parsed['text'] is! String ||
          parsed['segments'] is! List) {
        throw StateError('LAB_ZIP_PROVIDER_SCHEMA_HOLD');
      }
      final text = parsed['text'] as String;
      final number = (i + 1).toString().padLeft(3, '0');
      final rawFile = 'raw/chunk_$number.verbose.json';
      final textFile = 'transcripts/chunk_$number.txt';
      final stage = staged[i];
      files[rawFile] = bytes;
      files[textFile] = Uint8List.fromList(utf8.encode(text));
      final entry = LabSegmentedTextChunk(
        index: i,
        text: text,
        coreStartMs: stage.coreStartMs,
        coreEndMs: stage.coreEndMs,
        wireStartMs: stage.wireStartMs,
        wireEndMs: stage.wireEndMs,
      );
      texts.add(entry);
      meta.add({
        'index': i + 1,
        'core_start_ms': stage.coreStartMs,
        'core_end_ms': stage.coreEndMs,
        'wire_start_ms': stage.wireStartMs,
        'wire_end_ms': stage.wireEndMs,
        'overlap_before_ms': stage.coreStartMs - stage.wireStartMs,
        'wire_sha256': stage.sha256Hex,
        'raw_sha256': expectedSha,
        'text_sha256': sha256.convert(utf8.encode(text)).toString(),
        'raw_file': rawFile,
        'transcript_file': textFile,
        'provider_segment_clock': 'NOT_VALIDATED_FOR_EXPORT',
      });
    }
    final manifest = <String, Object?>{
      'schema': 'MEETING_LAB_SEGMENTED_STT_V1',
      'source_sha256': sourceSha256,
      'expected_chunks': staged.length,
      'saved_chunks': texts.length,
      'complete': texts.length == staged.length,
      'raw_source': unverifiedImportedZip
          ? 'IMPORTED_ZIP_SHA_MATCHED_ORIGIN_UNVERIFIED'
          : 'SHA_VERIFIED_LOCAL_RECEIPTS',
      'provider_segment_clock': 'NOT_VALIDATED_FOR_EXPORT',
      'ai_merged': false,
      'chunks': meta,
    };
    files['manifest.json'] =
        Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
    files['context/participants.txt'] =
        Uint8List.fromList(utf8.encode(participants));
    files['context/glossary.txt'] =
        Uint8List.fromList(utf8.encode(glossary));
    files['instructions.txt'] = Uint8List.fromList(utf8.encode(
      '這是多段 STT 原文，依 Chunk 編號與 Core/Wire 時間排序。'
      '相鄰音訊可能約有 2 秒重疊，以 manifest 實際 overlap_before_ms 為準。'
      '不得直接刪掉每段開頭固定秒數；只去除明確可確認的重複。'
      '參考使用者提供的與會人員／字典修正名稱與用詞，但不得捏造發言、'
      '臆測說話者或消除不確定內容。保留各段原文與來源對照，'
      '產生獨立 AI 草稿供人工複核；Raw 與原始逐字稿不可覆寫。'
    ));
    return LabSegmentedSttBundle._(
      sourceSha256: sourceSha256,
      expectedCount: staged.length,
      chunks: List.unmodifiable(texts),
      manifest: Map.unmodifiable(manifest),
      files: Map.unmodifiable(files),
    );
  }

  Uint8List encodeZip() {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    return ZipEncoder().encodeBytes(archive);
  }
}

final class LabSegmentedTextChunk {
  const LabSegmentedTextChunk({
    required this.index,
    required this.text,
    required this.coreStartMs,
    required this.coreEndMs,
    required this.wireStartMs,
    required this.wireEndMs,
  });

  final int index;
  final String text;
  final int coreStartMs;
  final int coreEndMs;
  final int wireStartMs;
  final int wireEndMs;

  int get overlapBeforeMs => coreStartMs - wireStartMs;
}
