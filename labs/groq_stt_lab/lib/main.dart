import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'lab_audio_pipeline.dart';
import 'lab_part_roster.dart';
import 'lab_part_native_pts.dart';
import 'lab_mic_capture.dart';
import 'lab_debug_log.dart';
import 'lab_groq_free_usage_monitor.dart';
import 'lab_groq_stt_panel.dart';
import 'lab_groq_merged_review.dart';
import 'lab_groq_merge_review_panel.dart';
import 'lab_stt_demo_fixtures.dart';
import 'lab_stt_raw_preview.dart';

void main() => runApp(const GroqLabApp());

/// Audited Public Lab-only v0.4: preserved offline chunks + consented Groq Free STT.
class GroqLabApp extends StatelessWidget {
  const GroqLabApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Groq STT Lab',
        debugShowCheckedModeBanner: false,
        home: const GroqLabHome(),
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      );
}

class GroqLabHome extends StatefulWidget {
  const GroqLabHome({super.key});

  @override
  State<GroqLabHome> createState() => _GroqLabHomeState();
}

class _GroqLabHomeState extends State<GroqLabHome> {
  final _pipeline = const LabAudioPipeline();
  final _nativePartPts = const LabPartNativePtsScanner();
  final _micRecorder = const LabMicCapture();
  final _debug = LabDebugJournal();
  final _freeMonitor = LabGroqFreeUsageMonitor();
  int _mockFreeResponseSerial = 0;
  File? _selectedSource;
  LabAudioProbe? _sourceProbe;
  String? _originalSha;
  int? _originalBytes;
  String _status = '預設離線；真實 Groq STT 僅在逐段明確同意後呼叫。';
  List<LabStagedChunk> _chunks = const [];
  final List<LabPartReceipt> _partRoster = [];
  List<LabPartNativePtsReceipt> _partPtsResults = const [];
  LabMicSessionEvidence? _micSession;
  bool _busy = false;
  bool _stagingAudio = false;
  bool _cancelStagingRequested = false;
  LabSttRawPreview? _sttPreview;
  LabGroqMergedReview? _mergedReview;
  bool _previewIsMock = false;
  bool _previewFromGroq = false;
  bool _previewFromLocalJson = false;
  int _groqRawSavedCount = 0;
  int? _groqBlockedChunkOneBased;
  String? _groqHoldCode;
  final Map<int, String> _importedJson = <int, String>{};
  int _currentJsonChunk = 0;

  @override
  void initState() {
    super.initState();
    _debug.record('LAB_APP_OPEN',
        {'version': '0.4.25+30', 'git': LabBuildInfo.sourceSha});
  }

  Future<void> _chooseAudio() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _selectedSource = null;
      _sourceProbe = null;
      _originalSha = null;
      _originalBytes = null;
      _chunks = const [];
      _groqRawSavedCount = 0;
      _groqBlockedChunkOneBased = null;
      _groqHoldCode = null;
      _sttPreview = null;
      _mergedReview = null;
      _importedJson.clear();
      _currentJsonChunk = 0;
      _status = '辨識本機音檔格式…';
    });
    _debug.record('SOURCE_PICK_START');
    try {
      // Android may place the imported file under app/cache. The stage output
      // therefore uses a distinct appSupport root, not filePicker's cache.
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
        withData: false,
      );
      if (!mounted) return;
      if (selection == null) {
        _debug.record('SOURCE_PICK_CANCELLED');
        setState(() => _status = '已取消選取。');
        return;
      }
      final path = selection.files.single.path;
      if (path == null || path.isEmpty) {
        throw StateError('LAB_AUDIO_PICKER_PATH_MISSING');
      }
      final input = File(path);
      final size = await input.length();
      if (size <= 0) throw StateError('LAB_AUDIO_EMPTY_SOURCE');
      final sha = await LabAudioPipeline.digest(input);
      final probe = await _pipeline.probe(input);
      if (!mounted) return;
      _debug.record('SOURCE_PROBE_OK', {
        'kind': probe.kind.name,
        'bytes': size,
        'sha12': sha.substring(0, 12),
        'duration_ms': probe.durationUs == null
            ? 'WAV_FROM_HEADER'
            : probe.durationUs! ~/ 1000,
      });
      setState(() {
        _selectedSource = input;
        _sourceProbe = probe;
        _originalBytes = size;
        _originalSha = sha;
        _status = '已辨識 ${probe.label}，可離線切檔。'
            ' 原始音檔不會修改。';
      });
    } catch (e) {
      final code = LabDebugJournal.failureCode(e);
      _debug.record('SOURCE_PROBE_HOLD', {'code': code});
      if (mounted) setState(() => _status = '格式辨識 HOLD：$code');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Independently selected Recorder Parts; in-memory only, no Provider I/O.
  Future<void> _appendRecorderPart() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '驗證原始 Recorder Part…';
    });
    _debug.record('PART_PICK_START');
    try {
      final selection = await FilePicker.platform.pickFiles(
          type: FileType.audio, allowMultiple: false, withData: false);
      if (selection == null) {
        _debug.record('PART_PICK_CANCELLED');
        if (mounted) setState(() => _status = '已取消加入 Part。');
        return;
      }
      final path = selection.files.single.path;
      if (path == null || path.isEmpty) {
        throw StateError('LAB_PART_PICKER_PATH_MISSING');
      }
      final source = File(path);
      final probe = await _pipeline.probe(source);
      final receipt = await LabPartRoster.append(
          source: source, probe: probe, previous: _partRoster);
      if (!mounted) return;
      _debug.record('PART_ROSTER_ADD_OK', {
        'index': _partRoster.length + 1,
        'kind': receipt.kind.name,
        'bytes': receipt.bytes,
        'sha12': receipt.sha256.substring(0, 12),
        'duration_ms': receipt.durationMs,
        'logical_start_ms': receipt.logicalStartMs,
        'logical_end_ms': receipt.logicalEndMs,
      });
      setState(() {
        _partRoster.add(receipt);
        _partPtsResults = const [];
        _status = '已加入 ' + _partRoster.length.toString() +
            ' 個來源 Part，未修改原檔。';
      });
    } catch (e) {
      final code = LabDebugJournal.failureCode(e);
      _debug.record('PART_ROSTER_HOLD', {'code': code});
      if (mounted) setState(() => _status = 'Part HOLD：' + code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyRecorderParts() async {
    if (_busy || _partRoster.isEmpty) return;
    setState(() => _busy = true);
    try {
      await LabPartRoster.verify(_partRoster);
      _debug.record('PART_ROSTER_VERIFY_OK', {
        'parts': _partRoster.length,
        'logical_end_ms': _partRoster.last.logicalEndMs,
      });
      if (mounted) setState(() => _status =
          'Part SHA與大小一致；邏輯時軸僅供預檢，非 Recorder PTS。');
    } catch (e) {
      final code = LabDebugJournal.failureCode(e);
      _debug.record('PART_ROSTER_HOLD', {'code': code});
      if (mounted) setState(() => _status = 'Part 驗證 HOLD：' + code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Optional evidence-only comparison. An ordinary Recorder Part boundary
  // need not contain a 2s overlap; HOLD does not imply audio corruption.
  Future<void> _verifyWavSeams() async {
    if (_busy || _partRoster.length < 2) return;
    setState(() {
      _busy = true;
      _status = '比對相鄰 WAV 的實際 2 秒 PCM16 重疊樣本…';
    });
    try {
      for (var i = 1; i < _partRoster.length; i++) {
        final bytes = await LabPartRoster.verifyWavBoundary(_partRoster, i);
        _debug.record('PART_WAV_SEAM_OK', {
          'boundary': i, 'overlap_ms': 2000, 'bytes': bytes,
        });
      }
      if (mounted) setState(() => _status =
          'WAV 實體重疊樣本相同；尚未驗證 Recorder 身分或跨 Part PTS。');
    } catch (e) {
      final code = LabDebugJournal.failureCode(e);
      _debug.record('PART_WAV_SEAM_HOLD', {'code': code});
      if (mounted) setState(() => _status = 'WAV 邊界比對 HOLD：' + code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// SHA-bound encoded packet timestamps from the selected MP3/M4A files.
  /// All PTS remain source-local and never imply cross-Part global time.
  Future<void> _scanNativePartPts() async {
    if (_busy || _partRoster.isEmpty) return;
    setState(() {
      _busy = true;
      _partPtsResults = const [];
      _status = '掃描 Android 壓縮音檔本機封包 PTS…';
    });
    _debug.record('PART_NATIVE_PTS_START', {'parts': _partRoster.length});
    try {
      final results = await _nativePartPts.scan(_partRoster);
      if (!mounted) return;
      for (final receipt in results) {
        _debug.record('PART_NATIVE_PTS_OK', {
          'index': receipt.index,
          'kind': receipt.kind.name,
          'sha12': receipt.sha256.substring(0, 12),
          'first_pts_us': receipt.firstPtsUs,
          'last_pts_us': receipt.lastPtsUs,
          'packets': receipt.sampleCount,
          'max_gap_us': receipt.maxGapUs,
        });
      }
      setState(() {
        _partPtsResults = results;
        _status = '已讀取 ' + results.length.toString() +
            ' 個來源檔封包 PTS；僅屬音檔內本機時間，'
            '不是 Recorder 跨 Part 全域時間戳。';
      });
    } catch (e) {
      final code = LabDebugJournal.failureCode(e);
      _debug.record('PART_NATIVE_PTS_HOLD', {'code': code});
      if (mounted) setState(() => _status = '來源封包 PTS HOLD：' + code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Explicit owner click only; separate from selected Recorder Parts.
  // Creates two actual WAVs in a fresh app-private Lab recording session.
  // Native sampler offsets are local to THIS Lab AudioRecord session.
  Future<void> _captureLabMicParts() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '僅本機錄製 6 秒麥克風（每段 3 秒），請持續說話…';
    });
    _debug.record('LAB_MIC_CAPTURE_START', {'parts': 2, 'seconds': 6});
    try {
      final captured = await _micRecorder.capture();
      if (!mounted) return;
      _debug.record('LAB_MIC_CAPTURE_OK', {
        'parts': captured.parts.length,
        'total_frames': 96000,
        'total_ms': 6000,
      });
      for (var i = 0; i < captured.parts.length; i++) {
        final part = captured.parts[i];
        _debug.record('LAB_MIC_PART_OK', {
          'index': i + 1,
          'frame_start': part.frameStart,
          'frame_end': part.frameEnd,
          'bytes': part.receipt.bytes,
          'sha12': part.receipt.sha256.substring(0, 12),
        });
      }
      setState(() {
        _micSession = captured;
        _status = 'Lab 麥克風已實際錄製 2 個 3 秒 WAV Part；'
            ' 已綁定同一錄製 Session 的 0–96000 樣本序號。'
            ' 這不是 Main Recorder 的全域 PTS。';
      });
    } catch (e) {
      final code = LabDebugJournal.failureCode(e);
      _debug.record('LAB_MIC_CAPTURE_HOLD', {'code': code});
      if (mounted) setState(() {
        _status = code == 'LAB_MIC_PERMISSION_REQUIRED_HOLD'
          ? '請在系統權限對話框允許麥克風，再次手動按錄製。'
            ' 授權後不會自動開始。'
          : 'Lab 錄音 HOLD：$code';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyLabMicParts() async {
    final session = _micSession;
    if (_busy || session == null) return;
    setState(() => _busy = true);
    try {
      await LabMicCapture.verify(session);
      _debug.record('LAB_MIC_VERIFY_OK', {
        'parts': session.parts.length,
        'total_frames': session.parts.last.frameEnd,
      });
      if (mounted) setState(() => _status =
          'Lab 原始 WAV SHA 與 0–96000 樣本序號重驗成功；'
          '來源仍是獨立 Lab，而非 Main Recorder。');
    } catch (e) {
      final code = LabDebugJournal.failureCode(e);
      _debug.record('LAB_MIC_VERIFY_HOLD', {'code': code});
      if (mounted) setState(() => _status = 'Lab 錄音重驗 HOLD：$code');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _clearRecorderParts() {
    if (_busy) return;
    setState(() {
      _partRoster.clear();
      _partPtsResults = const [];
      _status = '已清除記憶體中的 Part 清單，原始音檔不變。';
    });
    _debug.record('PART_ROSTER_CLEAR');
  }

  void _requestStageCancellation() {
    if (!_stagingAudio || _cancelStagingRequested) return;
    setState(() {
      _cancelStagingRequested = true;
      _status = '已要求取消：目前正在處理的 Chunk 完成後將安全停止，'
          '並回收本次暫存輸出。';
    });
    _debug.record('STAGE_CANCEL_REQUESTED');
  }

  Future<void> _stageAudio() async {
    final input = _selectedSource;
    final sha = _originalSha;
    final probe = _sourceProbe;
    if (_busy || input == null || sha == null || probe == null) return;
    setState(() {
      _busy = true;
      _stagingAudio = true;
      _cancelStagingRequested = false;
      _chunks = const [];
      _groqRawSavedCount = 0;
      _groqBlockedChunkOneBased = null;
      _groqHoldCode = null;
      _sttPreview = null;
      _mergedReview = null;
      _importedJson.clear();
      _currentJsonChunk = 0;
      _status = '離線實體切檔／必要時轉成 PCM16 WAV…';
    });
    _debug.record('STAGE_START', {'kind': probe.kind.name, 'sha12': sha.substring(0, 12)});
    try {
      final support = await getApplicationSupportDirectory();
      final temporary = await getTemporaryDirectory();
      final staged = await _pipeline.stage(
        source: input,
        probe: probe,
        sourceSha: sha,
        wavOutputRoot: Directory(
            '${support.path}${Platform.pathSeparator}groq_lab_wav_chunks_v2'),
        nativeCacheRoot: temporary,
        cancellationRequested: () => _cancelStagingRequested,
      );
      if (!mounted) return;
      for (var i = 0; i < staged.length; i++) {
        final chunk = staged[i];
        if (chunk.mp3OriginReplay) {
          _debug.record('STAGE_MP3_ORIGIN_REPLAY_OK', {
            'index': i + 1,
            'origin_ms': 0,
          });
        }
        _debug.record('STAGE_CHUNK_OK', {
          'index': i + 1,
          'bytes': chunk.byteCount,
          'core_start_ms': chunk.coreStartMs,
          'core_end_ms': chunk.coreEndMs,
          'wire_start_ms': chunk.wireStartMs,
          'wire_end_ms': chunk.wireEndMs,
          'sha12': chunk.sha256Hex.substring(0, 12),
        });
      }
      if (staged.length > 1) {
        _debug.record('STAGE_MULTIWINDOW_OK', {
          'chunks': staged.length,
          'overlap_ms': 2000,
          'final_core_end_ms': staged.last.coreEndMs,
        });
      }
      _debug.record('STAGE_DONE',
          {'count': staged.length, 'source_sha12': sha.substring(0, 12)});
      setState(() {
        _chunks = staged;
        _status = '已完成 ${staged.length} 段本地音訊切檔／轉檔。'
            ' 沒有 Groq HTTP 上傳或 STT。';
      });
    } catch (e) {
      // Public Lab v21: only native-decoder integer counters are permitted
      // in this diagnostic. Never export source paths, PCM, transcript, keys
      // or the native exception message; all failed stages stay HOLD.
      if (e is PlatformException && e.details is Map) {
        final details = e.details as Map;
        final counters = <String, Object?>{};
        for (final key in const [
          'expected_frames', 'decoded_frames', 'first_pts_us',
          'last_pts_us', 'window_start_us', 'window_end_us',
          'source_duration_us', 'last_input_pts_us',
          'input_packets_queued', 'input_eos_queued', 'output_eos_seen',
          'mp3_origin_replay_attempted',
          'leading_pts_limit_us', 'source_sample_rate_hz',
        ]) {
          final value = details[key];
          if (value is int && value >= -1 && value <= 172800000000) {
            counters[key] = value;
          }
        }
        if (counters.isNotEmpty) {
          _debug.record('STAGE_PCM_WINDOW_METRICS', counters);
        }
      }
      final code = LabDebugJournal.failureCode(e);
      _debug.record(code == 'LAB_AUDIO_CANCELLED'
          ? 'STAGE_CANCELLED' : 'STAGE_HOLD', {'code': code});
      if (mounted) setState(() => _status = '離線處理 HOLD：$code');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stagingAudio = false;
          _cancelStagingRequested = false;
        });
      }
    }
  }


  void _previewFromRaw(List<String> rawJson, {required bool simulated, bool fromGroq = false, bool localImportReview = false}) {
    final source = _originalSha;
    if (source == null || _chunks.isEmpty) return;
    try {
      // Preview the contiguous prefix of already saved Groq Raw receipts.
      // Missing chunks are never substituted and final merge stays separate.
      if (fromGroq && (rawJson.isEmpty || rawJson.length > _chunks.length)) {
        throw StateError('LAB_GROQ_PREVIEW_PREFIX_INVALID');
      }
      // Retain the full physical source duration and the complete verified
      // clock plan; only parse real Raw receipts that already exist.
      // Preserve the longest verified prefix even if a later, immutable Raw
      // has an invalid Provider clock. No invalid segment is admitted into
      // the chronology, and complete output remains blocked until all pass.
      final resolution = fromGroq
          ? LabSttRawPreview.resolveSavedGroqPrefix(
              staged: _chunks,
              originalSourceSha256: source,
              savedRawPrefix: rawJson,
            )
          : null;
      final candidate = resolution?.preview ??
          LabSttRawPreview.fromChunkVerboseJson(
            staged: _chunks,
            originalSourceSha256: source,
            rawJsonByChunk: rawJson,
          );
      if (resolution?.blockedChunkOneBased != null) {
        _debug.record('GROQ_VERIFIED_PREFIX_HOLD', {
          'raw_saved': resolution!.rawSavedCount,
          'verified': candidate.chunkCount,
          'blocked_chunk': resolution.blockedChunkOneBased,
          'code': resolution.holdCode,
        });
      }
      final review = fromGroq || localImportReview
          ? LabGroqMergedReview.assemble(
              parsed: candidate, expectedChunkCount: _chunks.length,
            )
          : null;
      if (review != null && review.allRawReceived) {
        // No transcript text in the diagnostic log.
        _debug.record(fromGroq
            ? 'GROQ_FULL_MERGE_REVIEW_READY'
            : 'STT_LOCAL_JSON_MERGE_REVIEW_READY', {
          'chunks': review.chunksSaved,
          'segments': review.timeline.length,
          'overlap_review': review.overlapReviewCount,
        });
      }
      _debug.record('STT_OFFLINE_JSON_PARSE_OK', {
        'kind': simulated ? 'SYNTHETIC' : fromGroq ? 'GROQ' : 'LOCAL_JSON',
        'chunks': candidate.chunkCount,
        'segments': candidate.candidates.length,
        'review': candidate.reviewRequired,
      });
      setState(() {
        _sttPreview = candidate;
        _mergedReview = review;
        _previewIsMock = simulated;
        _previewFromGroq = fromGroq;
        _previewFromLocalJson = localImportReview;
        _groqRawSavedCount = resolution?.rawSavedCount ?? 0;
        _groqBlockedChunkOneBased = resolution?.blockedChunkOneBased;
        _groqHoldCode = resolution?.holdCode;
        _status = simulated
            ? '合成 JSON 離線解析 PASS；此文字不是您音檔的辨識結果。'
            : fromGroq
                ? resolution!.blockedChunkOneBased != null
                    ? '已保存 Groq Raw ' + resolution.rawSavedCount.toString() +
                        '/' + _chunks.length.toString() + ' 段；僅前 ' +
                        candidate.chunkCount.toString() +
                        ' 段通過時間軸驗證。Chunk ' +
                        resolution.blockedChunkOneBased.toString() +
                        ' HOLD：' + resolution.holdCode.toString() +
                        '。保留既有逐字稿；完整合併及複製停用。'
                    : 'Groq Raw 已解析 ' + candidate.chunkCount.toString() +
                        '/' + _chunks.length.toString() +
                        ' 段；可在下方查看真實逐字稿。未收齊不代表合併完成。'
                : localImportReview
                    ? '本機 JSON 已匯入全部段落並完成時間軸合併；Provider 身分未驗證，沒有網路傳輸。'
                    : '本機 JSON 離線解析 PASS；未向 Groq 傳送任何資料。';
      });
    } catch (error) {
      final code = LabDebugJournal.failureCode(error);
      _debug.record('STT_OFFLINE_JSON_PARSE_HOLD', {'code': code});
      if (mounted) setState(() {
        // Never erase successfully parsed genuine STT on a later error.
        // A synthetic preview is NOT allowed to masquerade as Groq Raw.
        final keepRealPreview = fromGroq &&
            _previewFromGroq && _sttPreview != null;
        if (!keepRealPreview) {
          _sttPreview = null;
          _mergedReview = null;
        }
        _status = keepRealPreview
            ? '後續 Raw 解析 HOLD：$code；已保留先前通過驗證的'
                ' Groq 逐字稿。完整合併及複製停用。'
            : 'STT JSON 解析 HOLD：$code';
      });
    }
  }

  void _runSimulatedJson() {
    if (_busy || _chunks.isEmpty) return;
    try {
      final fixtures = LabSttDemoFixtures.buildForPhysicalChunks(_chunks);
      _previewFromRaw(fixtures, simulated: true);
    } catch (error) {
      final code = LabDebugJournal.failureCode(error);
      _debug.record('STT_MOCK_HOLD', {'code': code});
      setState(() => _status = '合成解析 HOLD：$code');
    }
  }

  Future<void> _importOneLocalJson() async {
    if (_busy || _chunks.isEmpty) return;
    final selectedIndex = _currentJsonChunk;
    setState(() => _busy = true);
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
        withData: false,
      );
      if (!mounted || selection == null) return;
      final path = selection.files.single.path;
      if (path == null || path.isEmpty) {
        throw StateError('LAB_STT_LOCAL_JSON_PATH_HOLD');
      }
      final file = File(path);
      final size = await file.length();
      if (size <= 0 ||
          size > LabSttRawPreview.maxRawJsonBytesPerChunk) {
        throw StateError('LAB_STT_LOCAL_JSON_BYTES_HOLD');
      }
      final json = await file.readAsString();
      if (!mounted) return;
      _importedJson[selectedIndex] = json;
      _debug.record('STT_LOCAL_JSON_SELECTED', {
        'chunk': selectedIndex + 1, 'bytes': size,
      });
      setState(() {
        _sttPreview = null;
      _mergedReview = null;
        _status = '已匯入 Chunk ${selectedIndex + 1} 的本機 JSON；'
            '共 ${_importedJson.length}/${_chunks.length} 份。'
            ' 不記錄原文或檔案路徑。';
      });
    } catch (error) {
      final code = LabDebugJournal.failureCode(error);
      _debug.record('STT_LOCAL_JSON_IMPORT_HOLD', {'code': code});
      if (mounted) setState(() => _status = '本機 JSON 匯入 HOLD：$code');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _previewImportedJson() {
    if (_busy || _chunks.isEmpty ||
        _importedJson.length != _chunks.length) return;
    final input = <String>[];
    for (var index = 0; index < _chunks.length; index++) {
      final source = _importedJson[index];
      if (source == null) {
        setState(() => _status = '尚缺 Chunk ${index + 1} 的 JSON。');
        return;
      }
      input.add(source);
    }
    _previewFromRaw(input, simulated: false, localImportReview: true);
  }

  // LAB-2 offline UAT only. These are synthetic HTTP outcomes, not requests.
  // Real transport must persist SUBMIT_UNKNOWN and require fresh consent.
  void _simulateFreeResponse(int statusCode) {
    if (_busy) return;
    final observed = DateTime.now().toUtc();
    _freeMonitor.recordHttp(
      attemptId: 'synthetic_${++_mockFreeResponseSerial}',
      statusCode: statusCode,
      wireBytes: 100000,
      wireAudioMs: 10000,
      observedAt: observed,
      headers: statusCode == 429
          ? const {'retry-after': '90', 'x-ratelimit-remaining-requests': '0'}
          : const {'x-ratelimit-remaining-requests': '100'},
    );
    _debug.record('FREE_MOCK_RESPONSE', {
      'status': statusCode,
      'attempts': _freeMonitor.observedAttempts,
      'cooldown_s': _freeMonitor.cooldownSeconds(observed),
    });
    setState(() {});
  }

  Future<void> _exportDebugLog() async {
    if (_busy) return;
    try {
      await _debug.export();
      if (mounted) setState(() => _status = '已開啟診斷紀錄分享視窗。'
          ' 請選擇儲存到檔案；分享前可自行檢閱內容。');
    } catch (_) {
      _debug.record('LOG_EXPORT_HOLD');
      if (mounted) setState(() => _status = '診斷紀錄匯出 HOLD：'
          '請確認檔案分享程式與儲存空間。');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Groq STT Lab｜Free＋離線')), 
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const Text('LAB-0/1/2/3｜獨立 Android 音訊與 Groq STT',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('版次：${LabBuildInfo.display}',
                key: const Key('lab-build-version')),
            const Text('支援原生 RIFF/WAV PCM16、Android 可解碼的 MP3 和 AAC/M4A。'
                ' 非 WAV 音訊會在手機內自動轉為可切割的 PCM16 WAV；'
                ' 輸入音檔只讀；Groq STT 只有在逐段明確確認後才會傳送。'),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('choose-audio'),
              onPressed: _busy ? null : _chooseAudio,
              icon: const Icon(Icons.folder_open),
              label: const Text('選擇音檔（WAV／MP3／M4A）'),
            ),
            FilledButton.tonal(
              key: const Key('stage-audio'),
              onPressed: _busy || _selectedSource == null
                  ? null : _stageAudio,
              child: const Text('離線轉檔與切檔'),
            ),
            if (_stagingAudio)
              OutlinedButton.icon(
                key: const Key('cancel-stage-audio'),
                onPressed: _cancelStagingRequested
                    ? null : _requestStageCancellation,
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('取消本次轉檔（當前 Chunk 完成後生效）'),
              ),
            OutlinedButton.icon(
              key: const Key('export-debug-log'),
              onPressed: _busy ? null : _exportDebugLog,
              icon: const Icon(Icons.bug_report_outlined),
              label: const Text('匯出脫敏 Debug Log'),
            ),
            const Text('診斷紀錄只包含版次、Commit、事件代碼、'
                ' 檔案大小、SHA 前 12 碼與切檔時間；不包含原始音檔、'
                ' 檔名／路徑、逐字稿或 API Key。匯出僅在您按鈕後發生。'),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(_status, key: const Key('lab-status')),
            const Divider(height: 24),
            ExpansionTile(
              key: const Key('recorder-part-roster'),
              title: const Text('LAB-1P｜Recorder Part 只讀驗證'),
              children: [
                const Text('依真正 Part 順序逐一加入；最長 2 小時／12 段。'
                    '只讀 SHA、大小、音訊時長；邏輯時間是累計選入時長，'
                    '不是 Recorder 真正 PTS。清除清單不刪檔，重開後不保存。'),
                FilledButton.tonal(
                  key: const Key('part-roster-add'),
                  onPressed: _busy ? null : _appendRecorderPart,
                  child: const Text('依序加入一個 Recorder Part')),
                OutlinedButton(
                  key: const Key('part-roster-verify'),
                  onPressed: _busy || _partRoster.isEmpty
                      ? null : _verifyRecorderParts,
                  child: const Text('重新驗證全部來源 Part')),
                OutlinedButton(
                  key: const Key('part-roster-seam'),
                  onPressed: _busy || _partRoster.length < 2
                      ? null : _verifyWavSeams,
                  child: const Text('檢查相鄰 WAV 的 2 秒實際重疊')),
                const Text('僅適用於原本預期共享 2 秒樣本的 PCM16 WAV。'
                    '一般 Recorder 分段未必有重疊；HOLD 不等於損壞，'
                    '且不是全域時間戳證明。'),
                OutlinedButton(
                  key: const Key('part-roster-native-pts'),
                  onPressed: _busy || _partRoster.isEmpty
                      ? null : _scanNativePartPts,
                  child: const Text('掃描已選 MP3／M4A 本機封包 PTS'),
                ),
                const Text('來源本機 PTS 是 Android MediaExtractor '
                    '對每個壓縮音檔讀出的封包時間；只支援 MP3／M4A。'
                    'WAV 會安全 HOLD，不能推導 Recorder 跨段 PTS。'),
                for (final r in _partPtsResults)
                  Text('Part ' + r.index.toString() + ' ' + r.kind.name +
                    ' ｜首末 PTS ' + r.firstPtsUs.toString() + '–' +
                    r.lastPtsUs.toString() + 'us' +
                    '；封包 ' + r.sampleCount.toString() +
                    '；最大間隔 ' + r.maxGapUs.toString() + 'us'),
                OutlinedButton(
                  key: const Key('part-roster-clear'),
                  onPressed: _busy || _partRoster.isEmpty
                      ? null : _clearRecorderParts,
                  child: const Text('清除清單（不刪原檔）')),
                Text('已選：' + _partRoster.length.toString() +
                    '；邏輯累計：' + (_partRoster.isEmpty ? '0' :
                    _partRoster.last.logicalEndMs.toString()) + ' ms'),
                for (var i = 0; i < _partRoster.length; i++)
                  Text('Part ' + (i + 1).toString() + ' ' +
                    _partRoster[i].kind.name + ' ' +
                    _partRoster[i].bytes.toString() + 'B SHA12 ' +
                    _partRoster[i].sha256.substring(0, 12) +
                    ' ｜邏輯 ' + _partRoster[i].logicalStartMs.toString() +
                    '–' + _partRoster[i].logicalEndMs.toString() + 'ms'),
              ],
            ),
            const Divider(height: 24),
            ExpansionTile(
              key: const Key('lab-mic-recorder'),
              title: const Text('LAB-1R｜真實麥克風 2-Part 來源測試'),
              children: [
                const Text('只有按下錄製才向系統要求麥克風權限；'
                    '首次授權後需要再次點擊。全程在前景，本機'
                    '單一 AudioRecord 連續擷取 6 秒，保留兩個實體 WAV'
                    '（各 3 秒）。不呼叫 Groq／Gemini，不傳送錄音。'
                    '原始 Part 留在獨立 Lab 私有資料夾，'
                    '重驗與清除其他清單都不會刪檔。'),
                FilledButton.tonal(
                  key: const Key('lab-mic-capture'),
                  onPressed: _busy ? null : _captureLabMicParts,
                  child: const Text('明確開始 6 秒本機麥克風錄音'),
                ),
                OutlinedButton(
                  key: const Key('lab-mic-verify'),
                  onPressed: _busy || _micSession == null
                      ? null : _verifyLabMicParts,
                  child: const Text('重新驗證本次 Lab 錄音 Part SHA'),
                ),
                const Text('同一 Lab AudioRecord 的連續樣本序號'
                  '僅代表本次實測錄製的來源順序；'
                  '尚不能證明 Main Recorder 跨段 PTS 或'
                  '1–2 小時連續錄音沒有遺失。'),
                if (_micSession != null) ...[
                  const Text('已建立本機 Lab 原始錄音 Session：2 個 WAV Part'),
                  for (var i = 0; i < _micSession!.parts.length; i++)
                    Text('Part ' + (i + 1).toString() +
                        '：樣本 ' +
                        _micSession!.parts[i].frameStart.toString() +
                        '–' + _micSession!.parts[i].frameEnd.toString() +
                        '；SHA12 ' +
                        _micSession!.parts[i].receipt.sha256.substring(0, 12) +
                        '；' +
                        _micSession!.parts[i].receipt.bytes.toString() + ' B'),
                ],
              ],
            ),
            const Divider(height: 24),
            ExpansionTile(
              key: const Key('free-monitor-offline'),
              title: const Text('LAB-2｜Groq Free 用量與冷卻（離線模擬）'),
              children: [
                const Text('僅模擬 HTTP 回應，不會發送音檔、讀取 API Key，'
                    ' 也不會依預估用量提前阻擋 Free 方案。'
                    ' 429 依 retry-after 冷卻；任何重送均需另行人工確認。'),
                Text('觀測請求：${_freeMonitor.observedAttempts}；'
                    ' 成功：${_freeMonitor.successfulResponses}；'
                    ' 429：${_freeMonitor.rateLimitedResponses}；'
                    ' 其他失敗：${_freeMonitor.failedResponses}',
                    key: const Key('free-monitor-counts')),
                Text('已觀測音訊：${_freeMonitor.attemptedWireAudioMs} ms；'
                    ' 已成功回應音訊：${_freeMonitor.acceptedWireAudioMs} ms'
                    '（非 Groq 計費量）'),
                Text('Free 回應狀態：${_freeMonitor.statusAt(DateTime.now().toUtc())}；'
                    ' 冷卻秒數：${_freeMonitor.cooldownSeconds(DateTime.now().toUtc())}',
                    key: const Key('free-monitor-state')),
                Wrap(spacing: 8, children: [
                  OutlinedButton(
                    key: const Key('free-mock-200'),
                    onPressed: _busy ? null : () => _simulateFreeResponse(200),
                    child: const Text('模擬 200'),
                  ),
                  OutlinedButton(
                    key: const Key('free-mock-429'),
                    onPressed: _busy ? null : () => _simulateFreeResponse(429),
                    child: const Text('模擬 429／冷卻 90 秒'),
                  ),
                  OutlinedButton(
                    key: const Key('free-mock-413'),
                    onPressed: _busy ? null : () => _simulateFreeResponse(413),
                    child: const Text('模擬 413／停止'),
                  ),
                ]),
              ],
            ),
            if (_originalBytes != null) ...[
              const SizedBox(height: 12),
              Text('來源：${_sourceProbe?.label ?? '未知'}'),
              Text('來源大小：$_originalBytes bytes'),
              const Text('來源 SHA256（僅本機畫面顯示）'),
              SelectableText(_originalSha ?? '', maxLines: 2),
            ],
            if (_chunks.isNotEmpty &&
                _selectedSource != null &&
                _originalSha != null)
              LabGroqSttPanel(
                key: ObjectKey(_chunks),
                sourceFile: _selectedSource!,
                originalSourceSha256: _originalSha!,
                chunks: _chunks,
                debugJournal: _debug,
                onAvailableRawPrefix: (json) => _previewFromRaw(
                    json, simulated: false, fromGroq: true),
              ),
            if (_chunks.isNotEmpty) ...[
              const Divider(height: 24),
              const Text('下一階段｜STT JSON 離線解析',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Text('以下為合成測試或您手動匯入的 JSON，'
                  ' 合成測試／匯入功能均維持離線；真實傳輸使用下方獨立同意介面。'),
              FilledButton.tonalIcon(
                key: const Key('stt-synthetic-preview'),
                onPressed: _busy ? null : _runSimulatedJson,
                icon: const Icon(Icons.science_outlined),
                label: const Text('測試合成 STT JSON 時間軸／重疊提示'),
              ),
              DropdownButton<int>(
                key: const Key('stt-json-chunk-picker'),
                isExpanded: true,
                value: _currentJsonChunk,
                items: [
                  for (var i = 0; i < _chunks.length; i++)
                    DropdownMenuItem(value: i,
                        child: Text('本機 JSON 對應 Chunk ${i + 1}')),
                ],
                onChanged: _busy ? null : (value) {
                  if (value != null) {
                    setState(() => _currentJsonChunk = value);
                  }
                },
              ),
              OutlinedButton.icon(
                key: const Key('stt-import-local-json'),
                onPressed: _busy ? null : _importOneLocalJson,
                icon: const Icon(Icons.file_open),
                label: const Text('匯入此 Chunk 的 verbose_json（本機）'),
              ),
              OutlinedButton(
                key: const Key('stt-parse-imported-json'),
                onPressed: _busy || _importedJson.length != _chunks.length
                    ? null : _previewImportedJson,
                child: Text('解析已匯入 ${_importedJson.length}/${_chunks.length} 份 JSON'),
              ),
              if (_sttPreview != null) ...[
                const Divider(height: 16),
                Text(_previewIsMock
                    ? '合成模擬結果（非真實 STT）'
                    : _previewFromGroq
                        ? 'Groq Free 真實 STT（已保存 ' + _sttPreview!.chunkCount.toString() + '/' + _chunks.length.toString() + ' 段；非自動去重）'
                        : '本機匯入 JSON 時間軸結果（未驗證 Provider 身分）',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('Chunk: ${_sttPreview!.chunkCount}；'
                    'Segments: ${_sttPreview!.candidates.length}；'
                    '待人工複核: ${_sttPreview!.reviewRequired}',
                    key: const Key('stt-review-summary')),
                if ((_previewFromGroq || _previewFromLocalJson) &&
                    _mergedReview != null)
                  LabGroqMergeReviewPanel(
                    key: const Key('groq-merged-review-panel'),
                    review: _mergedReview!,
                    verifiedProviderSource: _previewFromGroq,
                    actualSavedRawCount:
                        _previewFromGroq ? _groqRawSavedCount : null,
                    blockedChunkOneBased:
                        _previewFromGroq ? _groqBlockedChunkOneBased : null,
                    holdCode: _previewFromGroq ? _groqHoldCode : null,
                  )
                else ...[
                  for (final candidate in _sttPreview!.candidates.take(80))
                    ListTile(
                      dense: true,
                      title: Text(candidate.rawText,
                        maxLines: 3, overflow: TextOverflow.ellipsis),
                      subtitle: Text('Chunk ${candidate.chunkIndex + 1} / '
                          '${candidate.globalStartMs}–${candidate.globalEndMs} ms'),
                      trailing: candidate.requiresOverlapReview
                        ? const Icon(Icons.rule, color: Colors.deepOrange)
                        : const Icon(Icons.check_circle_outline),
                    ),
                  if (_sttPreview!.candidates.length > 80)
                    const Text('只顯示前 80 段；不代表其餘資料已刪除。'),
                ],
              ],
              const Divider(height: 24),
              const Text('離線實體 Chunk 結果',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              for (var i = 0; i < _chunks.length; i++)
                ListTile(
                  title: Text('Chunk ${i + 1}'),
                  subtitle: Text(
                      'core ${_chunks[i].coreStartMs}–${_chunks[i].coreEndMs} ms; '
                      'wire ${_chunks[i].wireStartMs}–${_chunks[i].wireEndMs} ms'),
                  trailing: Text('${_chunks[i].byteCount} B'),
                ),
            ],
          ]),
        ),
      );
}
