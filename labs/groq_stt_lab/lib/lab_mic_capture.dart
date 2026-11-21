import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'lab_audio_pipeline.dart';
import 'lab_part_roster.dart';

/// A physical 16kHz mono PCM16 WAV Part from one isolated LAB AudioRecord.
/// The frame offsets are relative to this LAB microphone stream, not the
/// Private Main Recorder's clock or a verified hardware timestamp.
final class LabMicPartEvidence {
  const LabMicPartEvidence({
    required this.receipt,
    required this.frameStart,
    required this.frameEnd,
  });
  final LabPartReceipt receipt;
  final int frameStart;
  final int frameEnd;
}

final class LabMicSessionEvidence {
  const LabMicSessionEvidence({
    required this.sessionId,
    required this.startedMonoNs,
    required this.endedMonoNs,
    required this.parts,
  });
  final String sessionId;
  final int startedMonoNs;
  final int endedMonoNs;
  final List<LabMicPartEvidence> parts;
}

/// Explicit-on-click native capture: two physical 3s WAV Parts from a single
/// AudioRecord instance. The app-private source files are never cleaned by
/// clearing the UI receipt; neither source paths nor PCM enter Debug Log.
final class LabMicCapture {
  const LabMicCapture({
    MethodChannel channel = const MethodChannel('groq_stt_lab/offline_audio'),
  }) : _channel = channel;

  final MethodChannel _channel;
  static final _sha = RegExp(r'^[0-9a-f]{64}$');
  static final _session = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  static int number(Map<String, dynamic> data, String key) {
    final v = data[key];
    if (v is! int) throw StateError('LAB_MIC_RECEIPT_HOLD');
    return v;
  }

  Future<LabMicSessionEvidence> capture({Directory? supportRoot}) async {
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'captureLabMicParts');
    if (response == null) throw StateError('LAB_MIC_RECEIPT_HOLD');
    final id = response['sessionId'];
    final rate = number(response, 'sampleRate');
    final startNs = number(response, 'startedMonoNs');
    final endNs = number(response, 'endedMonoNs');
    final raw = response['parts'];
    if (id is! String || !_session.hasMatch(id) ||
        rate != 16000 || startNs <= 0 ||
        endNs - startNs < 4000000000 ||
        endNs - startNs > 45000000000 ||
        raw is! List || raw.length != 2) {
      throw StateError('LAB_MIC_RECEIPT_HOLD');
    }
    final root = supportRoot ?? await getApplicationSupportDirectory();
    final parent = Directory(
        '${root.path}${Platform.pathSeparator}lab_mic_capture_v1');
    final canonicalParent = await parent.resolveSymbolicLinks();
    final folder = Directory(
        '${parent.path}${Platform.pathSeparator}$id');
    final canonicalFolder = await folder.resolveSymbolicLinks();
    if (canonicalFolder !=
        '$canonicalParent${Platform.pathSeparator}$id') {
      throw StateError('LAB_MIC_PATH_HOLD');
    }
    final parts = <LabPartReceipt>[];
    final results = <LabMicPartEvidence>[];
    for (var i = 0; i < raw.length; i++) {
      final partData = raw[i];
      if (partData is! Map) throw StateError('LAB_MIC_RECEIPT_HOLD');
      final part = Map<String, dynamic>.from(partData);
      final path = part['path'];
      final claimedSha = part['sha256'];
      final index = number(part, 'index');
      final bytes = number(part, 'bytes');
      final first = number(part, 'frameStart');
      final end = number(part, 'frameEnd');
      final expectedName = 'part_${(i + 1).toString().padLeft(2, '0')}.wav';
      final expectedPath =
          '$canonicalFolder${Platform.pathSeparator}$expectedName';
      if (path is! String || claimedSha is! String ||
          !_sha.hasMatch(claimedSha) || index != i + 1 ||
          first != i * 48000 || end != (i + 1) * 48000 ||
          bytes != 96044 || path != expectedPath) {
        throw StateError('LAB_MIC_RECEIPT_HOLD');
      }
      final source = File(path);
      if (await source.resolveSymbolicLinks() != expectedPath ||
          await source.length() != bytes ||
          await LabAudioPipeline.digest(source) != claimedSha) {
        throw StateError('LAB_MIC_SOURCE_CHANGED_HOLD');
      }
      final receipt = await LabPartRoster.append(
        source: source,
        probe: const LabAudioProbe(
            LabAudioKind.wavPcm16, 'audio/wav', null),
        previous: parts,
      );
      if (receipt.durationMs != 3000 ||
          receipt.bytes != bytes || receipt.sha256 != claimedSha) {
        throw StateError('LAB_MIC_RECEIPT_HOLD');
      }
      parts.add(receipt);
      results.add(LabMicPartEvidence(
        receipt: receipt, frameStart: first, frameEnd: end));
    }
    await LabPartRoster.verify(parts);
    return LabMicSessionEvidence(
      sessionId: id,
      startedMonoNs: startNs,
      endedMonoNs: endNs,
      parts: List.unmodifiable(results));
  }

  static Future<void> verify(LabMicSessionEvidence session) async {
    if (session.parts.length != 2 ||
        session.endedMonoNs <= session.startedMonoNs) {
      throw StateError('LAB_MIC_RECEIPT_HOLD');
    }
    final receipts = session.parts.map((e) => e.receipt).toList();
    await LabPartRoster.verify(receipts);
    for (var i = 0; i < 2; i++) {
      final p = session.parts[i];
      if (p.frameStart != i * 48000 ||
          p.frameEnd != (i + 1) * 48000 ||
          p.receipt.durationMs != 3000) {
        throw StateError('LAB_MIC_SESSION_CLOCK_HOLD');
      }
    }
  }
}
