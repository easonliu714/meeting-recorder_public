import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'lab_audio_pipeline.dart';
import 'lab_mic_capture.dart';
import 'lab_part_roster.dart';

/// Immutable per-session Lab receipt with an atomic latest-session pointer.
/// Stored in the Lab's own app-private directory. No raw PCM is copied here.
/// This only proves re-readable bytes and source-relative frame ordering;
/// it is not a trusted Recorder-global PTS or hardware clock.
final class LabMicCheckpointStore {
  const LabMicCheckpointStore();

  static final _sessionId = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  static final _sha = RegExp(r'^[0-9a-f]{64}$');
  static const _directoryName = 'lab_mic_capture_v1';
  static const _manifestName = 'source_proof_v1.json';
  static const _pointerName = 'latest_source_proof_v1.txt';

  Future<Directory> _parent(Directory? root) async {
    final support = root ?? await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}$_directoryName');
  }

  static String _validId(Object? value) {
    if (value is! String || !_sessionId.hasMatch(value)) {
      throw StateError('LAB_MIC_CHECKPOINT_ID_HOLD');
    }
    return value;
  }

  static int _int(Map<String, dynamic> data, String key) {
    final v = data[key];
    if (v is! int) throw StateError('LAB_MIC_CHECKPOINT_FORMAT_HOLD');
    return v;
  }

  static String _shaField(Map<String, dynamic> data) {
    final value = data['sha256'];
    if (value is! String || !_sha.hasMatch(value)) {
      throw StateError('LAB_MIC_CHECKPOINT_FORMAT_HOLD');
    }
    return value;
  }

  static String _fileName(int index) =>
      'part_${index.toString().padLeft(2, '0')}.wav';

  Future<Directory> _sessionFolder(Directory parent, String id) async {
    final canonicalParent = await parent.resolveSymbolicLinks();
    final child = Directory('${parent.path}${Platform.pathSeparator}$id');
    if (!await child.exists() ||
        await child.resolveSymbolicLinks() !=
            '$canonicalParent${Platform.pathSeparator}$id') {
      throw StateError('LAB_MIC_CHECKPOINT_PATH_HOLD');
    }
    return child;
  }

  Future<void> save(
    LabMicSessionEvidence session, {
    Directory? supportRoot,
  }) async {
    _validId(session.sessionId);
    await LabMicCapture.verify(session);
    if (session.startedMonoNs <= 0 ||
        session.endedMonoNs - session.startedMonoNs < 4000000000 ||
        session.endedMonoNs - session.startedMonoNs > 45000000000) {
      throw StateError('LAB_MIC_CHECKPOINT_CLOCK_HOLD');
    }
    final parent = await _parent(supportRoot);
    final folder = await _sessionFolder(parent, session.sessionId);
    final canonicalFolder = await folder.resolveSymbolicLinks();
    for (var i = 0; i < 2; i++) {
      final part = session.parts[i];
      final expected = '$canonicalFolder${Platform.pathSeparator}${_fileName(i + 1)}';
      if (!await part.receipt.source.exists() ||
          await part.receipt.source.resolveSymbolicLinks() != expected ||
          part.receipt.bytes != 96044 ||
          part.receipt.kind != LabAudioKind.wavPcm16) {
        throw StateError('LAB_MIC_CHECKPOINT_SOURCE_HOLD');
      }
    }
    final manifest = File(
        '${folder.path}${Platform.pathSeparator}$_manifestName');
    // Immutable receipt: never overwrite a previous manifest, even when
    // retries or restored sessions are supplied to save().
    if (await manifest.exists()) {
      throw StateError('LAB_MIC_CHECKPOINT_EXISTS_HOLD');
    }
    final source = <String, Object>{
      'schema': 1,
      'sessionId': session.sessionId,
      'sampleRate': 16000,
      'startedMonoNs': session.startedMonoNs,
      'endedMonoNs': session.endedMonoNs,
      'parts': [
        for (var i = 0; i < 2; i++)
          {
            'index': i + 1,
            'file': _fileName(i + 1),
            'sha256': session.parts[i].receipt.sha256,
            'bytes': session.parts[i].receipt.bytes,
            'frameStart': session.parts[i].frameStart,
            'frameEnd': session.parts[i].frameEnd,
          },
      ],
    };
    await manifest.create(exclusive: true);
    await manifest.writeAsString(jsonEncode(source), flush: true);
    // Point to the new session only after the complete immutable receipt and
    // actual recorded WAV sources have passed verification.
    final pointer = File(
        '${parent.path}${Platform.pathSeparator}$_pointerName');
    final temp = File(
        '${parent.path}${Platform.pathSeparator}latest_${session.sessionId}.tmp');
    await temp.create(exclusive: true);
    await temp.writeAsString(session.sessionId, flush: true);
    await temp.rename(pointer.path);
  }

  Future<LabMicSessionEvidence> restore({Directory? supportRoot}) async {
    final parent = await _parent(supportRoot);
    // A fresh install has no capture directory. Classify absence before
    // canonical resolution; don't create directories during read-only restore.
    final parentType = await FileSystemEntity.type(parent.path, followLinks: false);
    if (parentType == FileSystemEntityType.notFound) {
      throw StateError('LAB_MIC_CHECKPOINT_MISSING_HOLD');
    }
    if (parentType != FileSystemEntityType.directory) {
      throw StateError('LAB_MIC_CHECKPOINT_PATH_HOLD');
    }
    final canonicalParent = await parent.resolveSymbolicLinks();
    final pointer = File(
        '${parent.path}${Platform.pathSeparator}$_pointerName');
    if (!await pointer.exists()) {
      throw StateError('LAB_MIC_CHECKPOINT_MISSING_HOLD');
    }
    if (await pointer.resolveSymbolicLinks() !=
        '$canonicalParent${Platform.pathSeparator}$_pointerName') {
      throw StateError('LAB_MIC_CHECKPOINT_PATH_HOLD');
    }
    final pointerBytes = await pointer.length();
    if (pointerBytes < 36 || pointerBytes > 38) {
      throw StateError('LAB_MIC_CHECKPOINT_ID_HOLD');
    }
    final id = _validId((await pointer.readAsString()).trim());
    final folder = await _sessionFolder(parent, id);
    final canonicalFolder = await folder.resolveSymbolicLinks();
    final manifest = File(
        '${folder.path}${Platform.pathSeparator}$_manifestName');
    if (!await manifest.exists() ||
        await manifest.resolveSymbolicLinks() !=
            '$canonicalFolder${Platform.pathSeparator}$_manifestName') {
      throw StateError('LAB_MIC_CHECKPOINT_MISSING_HOLD');
    }
    if (await manifest.length() > 4096) {
      throw StateError('LAB_MIC_CHECKPOINT_FORMAT_HOLD');
    }
    final Map<String, dynamic> saved;
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid checkpoint');
      }
      saved = decoded;
    } on FormatException {
      throw StateError('LAB_MIC_CHECKPOINT_FORMAT_HOLD');
    }
    final rows = saved['parts'];
    final startNs = _int(saved, 'startedMonoNs');
    final endNs = _int(saved, 'endedMonoNs');
    if (saved['schema'] != 1 || saved['sessionId'] != id ||
        saved['sampleRate'] != 16000 ||
        startNs <= 0 || endNs - startNs < 4000000000 ||
        endNs - startNs > 45000000000 ||
        rows is! List || rows.length != 2) {
      throw StateError('LAB_MIC_CHECKPOINT_FORMAT_HOLD');
    }
    final receipts = <LabPartReceipt>[];
    final parts = <LabMicPartEvidence>[];
    for (var i = 0; i < 2; i++) {
      final row = rows[i];
      if (row is! Map<String, dynamic>) {
        throw StateError('LAB_MIC_CHECKPOINT_FORMAT_HOLD');
      }
      final sha = _shaField(row);
      final expectedFile = _fileName(i + 1);
      if (_int(row, 'index') != i + 1 ||
          row['file'] != expectedFile ||
          _int(row, 'bytes') != 96044 ||
          _int(row, 'frameStart') != i * 48000 ||
          _int(row, 'frameEnd') != (i + 1) * 48000) {
        throw StateError('LAB_MIC_CHECKPOINT_FORMAT_HOLD');
      }
      final file = File(
          '$canonicalFolder${Platform.pathSeparator}$expectedFile');
      if (!await file.exists() ||
          await file.resolveSymbolicLinks() != file.path ||
          await file.length() != 96044 ||
          await LabAudioPipeline.digest(file) != sha) {
        throw StateError('LAB_MIC_CHECKPOINT_SOURCE_HOLD');
      }
      final receipt = await LabPartRoster.append(
        source: file,
        probe: const LabAudioProbe(
            LabAudioKind.wavPcm16, 'audio/wav', null),
        previous: receipts,
      );
      if (receipt.durationMs != 3000 ||
          receipt.bytes != 96044 || receipt.sha256 != sha) {
        throw StateError('LAB_MIC_CHECKPOINT_SOURCE_HOLD');
      }
      receipts.add(receipt);
      parts.add(LabMicPartEvidence(
        receipt: receipt,
        frameStart: i * 48000,
        frameEnd: (i + 1) * 48000,
      ));
    }
    final session = LabMicSessionEvidence(
      sessionId: id, startedMonoNs: startNs, endedMonoNs: endNs,
      parts: List.unmodifiable(parts));
    await LabMicCapture.verify(session);
    return session;
  }
}
