import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// Stable build identity shown to Owner and embedded in every exported log.
final class LabBuildInfo {
  const LabBuildInfo._();
  static const versionName = '0.4.24';
  static const versionCode = 29;
  static const applicationId = 'com.example.meeting_recorder.public_lab_v29.groq_stt_lab';
  static const sourceSha = String.fromEnvironment('LAB_BUILD_SHA', defaultValue: 'UNPINNED_LOCAL');
  static String get exportNameStem =>
      'groq_lab_v' + versionName.replaceAll('.', '_') +
      '_build' + versionCode.toString();

  static String get display => 'v$versionName+$versionCode / ${sourceSha.length > 12 ? sourceSha.substring(0, 12) : sourceSha}';
}

/// Bounded local-only structured event journal; no raw paths, transcript, key,
/// full source filename or provider response may enter exported diagnostics.
final class LabDebugJournal {
  final List<String> _events = <String>[];
  static const maxEvents = 350;
  static final _code = RegExp(r'^[A-Z][A-Z0-9_]{1,63}$');
  static final _field = RegExp(r'^[a-z][a-z0-9_]{0,31}$');
  static final _safeValue = RegExp(r'^[A-Za-z0-9_+:.@-]{1,80}$');

  void record(String event, [Map<String, Object?> data = const {}]) {
    if (!_code.hasMatch(event)) throw ArgumentError('INVALID_LOG_EVENT');
    final fields = <String>[];
    final sorted = data.keys.toList()..sort();
    for (final key in sorted) {
      if (!_field.hasMatch(key)) continue;
      final value = data[key];
      final displayed = value == null ? 'NULL' : value.toString();
      fields.add('$key=${_safeValue.hasMatch(displayed) ? displayed : 'REDACTED'}');
    }
    _events.add('${DateTime.now().toUtc().toIso8601String()} $event ${fields.join(' ')}'.trimRight());
    if (_events.length > maxEvents) _events.removeAt(0);
  }

  static String failureCode(Object error) {
    final String? raw;
    if (error is StateError) {
      raw = error.message.toString();
    } else if (error is FormatException) {
      raw = error.message;
    } else if (error is PlatformException) {
      raw = error.code;
    } else if (error is FileSystemException) {
      raw = 'LOCAL_FILE_ACCESS_HOLD';
    } else {
      raw = null;
    }
    return raw != null && _code.hasMatch(raw) ? raw : 'UNEXPECTED_OPERATION_HOLD';
  }

  String snapshot() => [
    'GROQ_STT_LAB_DIAGNOSTIC_V1',
    'build_version=${LabBuildInfo.versionName}+${LabBuildInfo.versionCode}',
    'source_commit=${LabBuildInfo.sourceSha}',
    'app_id=${LabBuildInfo.applicationId}',
    'offline_only=false',
    'user_confirmed_groq_http_only=true',
    'api_key_not_persisted=true',
    'no_raw_audio_or_transcript=true',
    'event_count=${_events.length}',
    ..._events,
    '',
  ].join('\n');

  /// User-initiated Android share sheet. No automated transfer or HTTP.
  Future<void> export() async {
    record('LOG_EXPORT_REQUESTED');
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}${Platform.pathSeparator}groq_lab_debug_exports');
    await dir.create(recursive: true);
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final output = File('${dir.path}${Platform.pathSeparator}${LabBuildInfo.exportNameStem}_$stamp.log');
    await output.writeAsString(snapshot(), encoding: utf8, flush: true);
    await Share.shareXFiles([XFile(output.path, mimeType: 'text/plain')],
        subject: 'Groq Lab v0.4.24+29 diagnostic log');
  }
}
