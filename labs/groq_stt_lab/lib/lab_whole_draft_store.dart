import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// App-private append-only snapshots for a successfully received Gemini
/// whole-context draft. API keys and immutable Groq Raw are never copied.
final class LabWholeDraftStore {
  const LabWholeDraftStore(this.directory);
  final Directory directory;
  static final _sha = RegExp(r'^[a-f0-9]{64}$');
  static const maxDraftBytes = 1024 * 1024;

  static String contextId(String sourceSha256, List<String> rawSha256) {
    if (!_sha.hasMatch(sourceSha256) || rawSha256.length != 6 ||
        rawSha256.any((value) => !_sha.hasMatch(value))) {
      throw StateError('LAB_WHOLE_DRAFT_IDENTITY_HOLD');
    }
    return sha256.convert(utf8.encode(
        [sourceSha256, ...rawSha256].join(':'))).toString();
  }

  Future<LabRecoveredWholeDraft> save({
    required String sourceSha256,
    required List<String> rawSha256,
    required String model,
    required String transcript,
  }) async {
    final id = contextId(sourceSha256, rawSha256);
    final bytes = utf8.encode(transcript);
    if (model.trim().isEmpty || model.length > 128 ||
        transcript.trim().isEmpty || bytes.length > maxDraftBytes) {
      throw StateError('LAB_WHOLE_DRAFT_CONTENT_HOLD');
    }
    final checksum = sha256.convert(bytes).toString();
    await directory.create(recursive: true);
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final target = File(directory.path + Platform.pathSeparator +
        'whole_' + id + '_' + stamp.toString() + '.json');
    final temp = File(target.path + '.pending');
    final content = jsonEncode({
      'schema': 'LAB_WHOLE_DRAFT_V1',
      'context_id': id,
      'source_sha256': sourceSha256,
      'model': model,
      'transcript_sha256': checksum,
      'transcript': transcript,
      'created_utc_us': stamp,
      'alignment': 'NOT_VERIFIED',
    });
    try {
      await temp.writeAsString(content, encoding: utf8, flush: true);
      await temp.rename(target.path);
      final checked = await _readFile(target, id);
      if (checked == null || checked.sha256 != checksum) {
        throw StateError('LAB_WHOLE_DRAFT_READBACK_HOLD');
      }
      return checked;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<LabRecoveredWholeDraft?> latest({
    required String sourceSha256,
    required List<String> rawSha256,
  }) async {
    final id = contextId(sourceSha256, rawSha256);
    if (!await directory.exists()) return null;
    final prefix = 'whole_' + id + '_';
    final files = (await directory.list(followLinks: false).toList())
        .whereType<File>()
        .where((file) => file.uri.pathSegments.last.startsWith(prefix) &&
            file.path.endsWith('.json')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final file in files.take(100)) {
      try {
        final saved = await _readFile(file, id);
        if (saved != null) return saved;
      } catch (_) {
        // Fail closed on incomplete files, never erase prior snapshots.
      }
    }
    return null;
  }

  static Future<LabRecoveredWholeDraft?> _readFile(
      File file, String contextId) async {
    if (await file.length() > maxDraftBytes * 2) return null;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> ||
        value['schema'] != 'LAB_WHOLE_DRAFT_V1' ||
        value['context_id'] != contextId ||
        value['model'] is! String ||
        value['transcript'] is! String ||
        value['transcript_sha256'] is! String) return null;
    final draft = value['transcript'] as String;
    final model = value['model'] as String;
    if (model.isEmpty || model.length > 128 || draft.trim().isEmpty ||
        utf8.encode(draft).length > maxDraftBytes) return null;
    final checksum = sha256.convert(utf8.encode(draft)).toString();
    if (checksum != value['transcript_sha256']) return null;
    return LabRecoveredWholeDraft(text: draft, model: model, sha256: checksum);
  }
}

final class LabRecoveredWholeDraft {
  const LabRecoveredWholeDraft({
    required this.text, required this.model, required this.sha256,
  });
  final String text;
  final String model;
  final String sha256;
}
