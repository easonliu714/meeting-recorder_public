import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Immutable raw Groq verbose_json receipt in the isolated Lab sandbox.
/// Files are never overwritten, deleted, or exported automatically.
final class LabGroqRawReceipt {
  const LabGroqRawReceipt({
    required this.file,
    required this.sha256Hex,
    required this.byteCount,
  });

  final File file;
  final String sha256Hex;
  final int byteCount;
}

final class LabGroqRawReceiptStore {
  const LabGroqRawReceiptStore(this.root);

  final Directory root;
  static const maxRawBytes = 4 * 1024 * 1024;
  static final _validAttempt = RegExp(r'^[A-Za-z0-9_-]{1,80}$');
  static final _sha = RegExp(r'^[0-9a-f]{64}$');

  File _fileFor(String attempt) {
    if (!_validAttempt.hasMatch(attempt)) {
      throw StateError('GROQ_RAW_ATTEMPT_INVALID');
    }
    return File(root.path + Platform.pathSeparator + attempt + '.verbose.json');
  }

  /// Writes response bytes before any final journal transition.
  /// A pre-existing partial or final receipt fails closed, never overwritten.
  Future<LabGroqRawReceipt> writeOnce(String attempt, List<int> bytes) async {
    final finalFile = _fileFor(attempt);
    if (bytes.isEmpty || bytes.length > maxRawBytes) {
      throw StateError('GROQ_RAW_SIZE_HOLD');
    }
    // Preserve the original response bytes BEFORE any UTF-8/JSON validation.
    await root.create(recursive: true);
    final partial = File(finalFile.path + '.pending');
    if (await finalFile.exists() || await partial.exists()) {
      throw StateError('GROQ_RAW_ALREADY_EXISTS_HOLD');
    }
    final hash = sha256.convert(bytes).toString();
    // No other writer may write this directory in parallel.
    await partial.writeAsBytes(bytes, mode: FileMode.writeOnly, flush: true);
    final readback = await partial.readAsBytes();
    if (readback.length != bytes.length ||
        sha256.convert(readback).toString() != hash) {
      throw StateError('GROQ_RAW_READBACK_HOLD');
    }
    if (await finalFile.exists()) {
      throw StateError('GROQ_RAW_ALREADY_EXISTS_HOLD');
    }
    await partial.rename(finalFile.path);
    // A complete but invalid provider response remains immutable for
    // evidence/recovery; journal remains RAW_PENDING (never auto-retry).
    _validateVerboseJson(await finalFile.readAsBytes());
    await readVerified(attempt, hash);
    return LabGroqRawReceipt(
      file: finalFile, sha256Hex: hash, byteCount: bytes.length,
    );
  }

  static void _validateVerboseJson(List<int> bytes) {
    final String body;
    try {
      body = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw StateError('GROQ_RAW_UTF8_HOLD');
    }
    final dynamic parsed;
    try {
      parsed = jsonDecode(body);
    } on FormatException {
      throw StateError('GROQ_RAW_JSON_HOLD');
    }
    if (parsed is! Map<String, dynamic> ||
        parsed.containsKey('error') ||
        parsed['text'] is! String ||
        parsed['segments'] is! List) {
      // Empty text is legitimate for a silent Chunk. The structural schema
      // remains mandatory, and the full immutable Raw is still preserved.

      throw StateError('GROQ_VERBOSE_JSON_REQUIRED');
    }
  }

  /// Recover a complete, already-renamed 2xx response after an app crash.
  /// This is local verification only; it NEVER triggers another HTTP request.
  Future<LabGroqRawReceipt?> inspectComplete(String attempt) async {
    final file = _fileFor(attempt);
    if (await File(file.path + '.pending').exists()) {
      throw StateError('GROQ_RAW_PARTIAL_HOLD');
    }
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > maxRawBytes) {
      throw StateError('GROQ_RAW_SIZE_HOLD');
    }
    _validateVerboseJson(bytes);
    final hash = sha256.convert(bytes).toString();
    await readVerified(attempt, hash);
    return LabGroqRawReceipt(
      file: file, sha256Hex: hash, byteCount: bytes.length,
    );
  }

  /// Verify source bytes and SHA before reading them into a preview.
  Future<String> readVerified(String attempt, String expectedSha) async {
    if (!_sha.hasMatch(expectedSha)) {
      throw StateError('GROQ_RAW_SHA_INVALID');
    }
    final file = _fileFor(attempt);
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > maxRawBytes ||
        sha256.convert(bytes).toString() != expectedSha) {
      throw StateError('GROQ_RAW_SHA_MISMATCH_HOLD');
    }
    return utf8.decode(bytes, allowMalformed: false);
  }
}
