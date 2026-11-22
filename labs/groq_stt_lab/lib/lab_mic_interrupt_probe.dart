import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'lab_audio_pipeline.dart';
import 'lab_part_roster.dart';

/// Only the first fully committed Lab WAV is recoverable. The tail is
/// uncommitted raw PCM: its byte count is evidence of storage, not audio validity.
final class LabMicInterruptedReceipt {
  const LabMicInterruptedReceipt(this.part, this.tailBytes);
  final LabPartReceipt part;
  final int tailBytes;
}

final class LabMicInterruptProbe {
  const LabMicInterruptProbe({
    MethodChannel channel = const MethodChannel('groq_stt_lab/offline_audio'),
  }) : _channel = channel;
  final MethodChannel _channel;
  static final _id = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  static final _sha = RegExp(r'^[0-9a-f]{64}$');

  Future<String> start() async {
    final response = await _channel.invokeMapMethod<String, dynamic>(
        'startLabMicInterruptProbe');
    final status = response?['status'];
    final count = response?['committedParts'];
    if ((status != 'stopped' && status != 'completed') ||
        count is! int || count < 0 || count > 1 ||
        (status == 'completed' && count != 1)) {
      throw StateError('LAB_MIC_INTERRUPT_RECEIPT_HOLD');
    }
    return status as String;
  }

  Future<void> stop() => _channel.invokeMethod<void>('stopLabMicInterruptProbe');

  static Future<FileSystemEntityType> _type(String path) =>
      FileSystemEntity.type(path, followLinks: false);

  static Future<File> _regular(Directory parent, String name,
      {required String missing}) async {
    final path = '${parent.path}${Platform.pathSeparator}$name';
    final type = await _type(path);
    if (type == FileSystemEntityType.notFound) throw StateError(missing);
    final file = File(path);
    if (type != FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() != path) {
      throw StateError('LAB_MIC_INTERRUPT_PATH_HOLD');
    }
    return file;
  }

  /// Manual, read-only recovery. Never infer the reason for a missing terminal
  /// marker (stop, process death, or other failure), or promote the tail.
  Future<LabMicInterruptedReceipt> recover({Directory? supportRoot}) async {
    final support = supportRoot ?? await getApplicationSupportDirectory();
    final canonicalSupport = await support.resolveSymbolicLinks();
    final parent = Directory(
        '$canonicalSupport${Platform.pathSeparator}lab_mic_interrupt_v1');
    final parentType = await _type(parent.path);
    if (parentType == FileSystemEntityType.notFound) {
      throw StateError('LAB_MIC_INTERRUPT_MISSING_HOLD');
    }
    if (parentType != FileSystemEntityType.directory ||
        await parent.resolveSymbolicLinks() != parent.path) {
      throw StateError('LAB_MIC_INTERRUPT_PATH_HOLD');
    }
    final pointer = await _regular(parent, 'latest_attempt_v1.txt',
        missing: 'LAB_MIC_INTERRUPT_MISSING_HOLD');
    if (await pointer.length() != 36) {
      throw StateError('LAB_MIC_INTERRUPT_ID_HOLD');
    }
    final id = await pointer.readAsString();
    if (!_id.hasMatch(id)) throw StateError('LAB_MIC_INTERRUPT_ID_HOLD');
    final folder = Directory('${parent.path}${Platform.pathSeparator}$id');
    if (await _type(folder.path) != FileSystemEntityType.directory ||
        await folder.resolveSymbolicLinks() != folder.path) {
      throw StateError('LAB_MIC_INTERRUPT_PATH_HOLD');
    }
    final terminal = '${folder.path}${Platform.pathSeparator}finished_v1.txt';
    if (await _type(terminal) != FileSystemEntityType.notFound) {
      throw StateError('LAB_MIC_INTERRUPT_NOT_INCOMPLETE_HOLD');
    }
    final commit = await _regular(folder, 'part_01_commit_v1.json',
        missing: 'LAB_MIC_INTERRUPT_UNCOMMITTED_HOLD');
    if (await commit.length() > 2048) {
      throw StateError('LAB_MIC_INTERRUPT_FORMAT_HOLD');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await commit.readAsString());
    } on FormatException {
      throw StateError('LAB_MIC_INTERRUPT_FORMAT_HOLD');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['schema'] != 1 || decoded['sessionId'] != id ||
        decoded['sampleRate'] != 16000 || decoded['index'] != 1 ||
        decoded['file'] != 'part_01.wav' || decoded['bytes'] != 96044 ||
        decoded['frameStart'] != 0 || decoded['frameEnd'] != 48000) {
      throw StateError('LAB_MIC_INTERRUPT_FORMAT_HOLD');
    }
    final sha = decoded['sha256'];
    if (sha is! String || !_sha.hasMatch(sha)) {
      throw StateError('LAB_MIC_INTERRUPT_FORMAT_HOLD');
    }
    final source = await _regular(folder, 'part_01.wav',
        missing: 'LAB_MIC_INTERRUPT_SOURCE_HOLD');
    if (await source.length() != 96044 ||
        await LabAudioPipeline.digest(source) != sha) {
      throw StateError('LAB_MIC_INTERRUPT_SOURCE_HOLD');
    }
    final receipt = await LabPartRoster.append(
        source: source,
        probe: const LabAudioProbe(LabAudioKind.wavPcm16, 'audio/wav', null),
        previous: const []);
    if (receipt.durationMs != 3000 || receipt.bytes != 96044 ||
        receipt.sha256 != sha) {
      throw StateError('LAB_MIC_INTERRUPT_SOURCE_HOLD');
    }
    final tailPath = '${folder.path}${Platform.pathSeparator}part_02_inflight.pcm';
    var tailBytes = 0;
    if (await _type(tailPath) != FileSystemEntityType.notFound) {
      final tail = await _regular(folder, 'part_02_inflight.pcm',
          missing: 'LAB_MIC_INTERRUPT_SOURCE_HOLD');
      tailBytes = await tail.length();
      if (tailBytes > 480000) {
        throw StateError('LAB_MIC_INTERRUPT_FORMAT_HOLD');
      }
    }
    await LabPartRoster.verify([receipt]);
    if (await pointer.readAsString() != id ||
        await _type(terminal) != FileSystemEntityType.notFound) {
      throw StateError('LAB_MIC_INTERRUPT_CHANGED_HOLD');
    }
    return LabMicInterruptedReceipt(receipt, tailBytes);
  }
}
