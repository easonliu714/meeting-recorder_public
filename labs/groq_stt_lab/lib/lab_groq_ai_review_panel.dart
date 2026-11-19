import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'lab_audio_pipeline.dart';
import 'lab_gemini_free_ai_client.dart';
import 'lab_segmented_stt_bundle.dart';
import 'lab_segmented_stt_zip_import.dart';
import 'lab_whole_draft_store.dart';
import 'lab_gemini_timestamped_export.dart';

/// Explicit, text-only Gemini Free AI draft and user-initiated offline ZIP.
/// Original immutable Raw receipts and Journal are never modified.
class LabGroqAiReviewPanel extends StatefulWidget {
  const LabGroqAiReviewPanel({
    super.key,
    required this.staged,
    required this.sourceSha256,
    required this.savedRawByIndex,
    required this.savedRawShaByIndex,
    this.client,
    this.onDiagnostic,
    this.draftDirectory,
    this.restoreDraftForTest,
  });

  final List<LabStagedChunk> staged;
  final String sourceSha256;
  final Map<int, String> savedRawByIndex;
  final Map<int, String> savedRawShaByIndex;
  final LabGeminiFreeAiClient? client;
  final void Function(String, Map<String, Object?>)? onDiagnostic;
  /// Production uses private app support; tests may inject a sandbox.
  final Directory? draftDirectory;
  /// Tests can inject a recovered record without OS file I/O in FakeAsync.
  /// Production always uses the app-private SHA-verified disk store.
  final Future<LabRecoveredWholeDraft?> Function(String, List<String>)?
      restoreDraftForTest;

  @override
  State<LabGroqAiReviewPanel> createState() => _LabGroqAiReviewPanelState();
}

class _LabGroqAiReviewPanelState extends State<LabGroqAiReviewPanel> {
  final _key = TextEditingController();
  final _participants = TextEditingController();
  final _glossary = TextEditingController();
  late final LabGeminiFreeAiClient _client;
  List<String> _models = const [];
  String? _model;
  bool _busy = false;
  bool _freeConfirmed = false;
  bool _modelTested = false;
  bool _attempted = false;
  String _status = '預設離線；僅按下模型測試或明確同意解析才會連線。';
  final Map<int, String> _drafts = {};
  String? _wholeDraft;
  String? _wholeDraftModel;
  bool _wholePersisted = false;
  LabImportedSegmentedStt? _offlineImport;

  @override
  void initState() {
    super.initState();
    _client = widget.client ??
        LabGeminiFreeAiClient(onDiagnostic: widget.onDiagnostic);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreWhole());
  }

  @override
  void didUpdateWidget(covariant LabGroqAiReviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceSha256 != widget.sourceSha256 ||
        oldWidget.staged.length != widget.staged.length) {
      _offlineImport = null;
      _drafts.clear();
      _wholeDraft = null;
      _wholeDraftModel = null;
      _wholePersisted = false;
      _restoreWhole();
      _attempted = false;
      _modelTested = false;
    }
  }

  @override
  void dispose() {
    _key.clear();
    _key.dispose();
    _participants.dispose();
    _glossary.dispose();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  Map<int, String> get _reviewRaw =>
      _offlineImport?.rawByIndex ?? widget.savedRawByIndex;
  Map<int, String> get _reviewSha =>
      _offlineImport?.shaByIndex ?? widget.savedRawShaByIndex;

  Future<Directory> _draftRoot() async {
    if (widget.draftDirectory != null) return widget.draftDirectory!;
    final app = await getApplicationSupportDirectory();
    return Directory(app.path + Platform.pathSeparator +
        'groq_lab_whole_drafts_v1');
  }

  List<String>? _rawFingerprints() {
    if (widget.staged.length != 6 || _reviewSha.length != 6) return null;
    final result = <String>[];
    for (var i = 0; i < 6; i++) {
      final value = _reviewSha[i];
      if (value == null) return null;
      result.add(value);
    }
    return result;
  }

  Future<void> _restoreWhole() async {
    final fingerprints = _rawFingerprints();
    if (!mounted || fingerprints == null || _wholeDraft != null) return;
    final source = widget.sourceSha256;
    try {
      final restored = widget.restoreDraftForTest == null
          ? await LabWholeDraftStore(await _draftRoot()).latest(
              sourceSha256: source, rawSha256: fingerprints)
          : await widget.restoreDraftForTest!(source, fingerprints);
      if (!mounted || restored == null || _wholeDraft != null ||
          source != widget.sourceSha256 ||
          _rawFingerprints()?.join(':') != fingerprints.join(':')) return;
      setState(() {
        _wholeDraft = restored.text;
        _wholeDraftModel = restored.model;
        _wholePersisted = true;
        _status = '已從本機保存檔恢復 Gemini 全文；不需重新呼叫 Provider。';
      });
    } catch (_) {
      if (mounted) setState(() => _status =
          '本機草稿恢復 HOLD；請保留原始 ZIP，未發出 Provider 請求。');
    }
  }

  LabSegmentedSttBundle _bundle() => LabSegmentedSttBundle.build(
        staged: widget.staged,
        sourceSha256: widget.sourceSha256,
        savedRawByIndex: _reviewRaw,
        savedRawShaByIndex: _reviewSha,
        participants: _participants.text,
        glossary: _glossary.text,
        unverifiedImportedZip: _offlineImport != null,
      );

  String _code(Object error) {
    if (error is StateError &&
        RegExp(r'^(LAB|GROQ)_[A-Z0-9_]{1,63}$').hasMatch(error.message.toString())) {
      return error.message.toString();
    }
    return 'LAB_AI_UNEXPECTED_HOLD';
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(message)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false),
                child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(dialog, true),
                child: const Text('明確同意')),
          ],
        ),
      ) == true;

  /// User-selected ZIP is read and validated in memory only. It never
  /// touches the live Groq Journal or silently submits anything to Gemini.
  Future<void> _importZip() async {
    if (_busy || widget.staged.isEmpty) return;
    final allowed = await _confirm('唯讀匯入先前匯出的分段 ZIP',
        '請先選取和該 ZIP 相同的原始音檔並完成本機切段。'
        '此動作只在手機本機驗證 ZIP CRC、來源 SHA、實體 Chunk 時間及 Raw/TXT SHA。'
        '匯入資料僅在當次畫面記憶體，來源身分標為未獨立驗證，'
        '不會寫入 Groq Journal、不上傳音檔、也不會自動送往 Gemini。');
    if (!mounted || !allowed) return;
    setState(() => _busy = true);
    try {
      final chosen = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['zip'], withData: false);
      if (chosen == null) {
        if (mounted) setState(() => _status = '已取消本機 ZIP 匯入。');
        return;
      }
      final path = chosen.files.single.path;
      if (path == null) throw StateError('LAB_ZIP_IMPORT_PATH_HOLD');
      final file = File(path);
      final byteCount = await file.length();
      if (byteCount <= 0 ||
          byteCount > LabSegmentedSttZipImport.maxZipBytes) {
        throw StateError('LAB_ZIP_IMPORT_INPUT_HOLD');
      }
      final imported = LabSegmentedSttZipImport.parse(
        zipBytes: Uint8List.fromList(await file.readAsBytes()),
        staged: widget.staged,
        sourceSha256: widget.sourceSha256,
      );
      if (!mounted) return;
      setState(() {
        _offlineImport = imported;
        _drafts.clear();
        _wholeDraft = null;
        _wholeDraftModel = null;
        _wholePersisted = false;
        _attempted = false;
        _modelTested = false;
        _status = 'ZIP 來源 SHA、Chunk 時間及 Raw/TXT 雜湊驗證通過：' +
            imported.count.toString() + '/' +
            widget.staged.length.toString() + ' 段。'
            '此為使用者匯入資料，Provider 身分未獨立驗證；'
            '需重新測試 Gemini 模型並明確同意才可解析。';
      });
      await _restoreWhole();
    } catch (error) {
      if (mounted) setState(() => _status =
          'ZIP 唯讀匯入 HOLD：' + _code(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportZip() async {
    if (_busy || _reviewRaw.isEmpty) return;
    final allowed = await _confirm('離線匯出分段 STT ZIP',
        'ZIP 包含 Groq 原始 verbose_json、逐段文字、Raw SHA、'
        '原始來源 SHA、Core／Wire 時間、以及您輸入的名單和字典。'
        '不包含原始錄音與 API Key。沒有網路傳輸；'
        '分享目的地由您選擇。不完整的段數會標示 INCOMPLETE。');
    if (!mounted || !allowed) return;
    setState(() => _busy = true);
    try {
      final bundle = _bundle();
      final bytes = bundle.encodeZip();
      final root = await getApplicationSupportDirectory();
      final dir = Directory(root.path + Platform.pathSeparator +
          'groq_lab_user_exports');
      await dir.create(recursive: true);
      final file = File(dir.path + Platform.pathSeparator +
          'segmented_stt_' +
          DateTime.now().toUtc().microsecondsSinceEpoch.toString() + '.zip');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await Share.shareXFiles(
          [XFile(file.path, mimeType: 'application/zip')],
          subject: '分段 STT 原始資料（請保護隱私）');
      if (mounted) setState(() => _status = '已開啟本機 ZIP 分享；'
          '保存 ' + bundle.chunks.length.toString() + '/' +
          bundle.expectedCount.toString() + ' 段，原始 Raw／Journal 未變更。');
    } catch (error) {
      if (mounted) setState(() => _status = 'ZIP 匯出 HOLD：' + _code(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _listModels() async {
    if (_busy || _key.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _models = const [];
      _model = null;
      _modelTested = false;
      _status = '只以 API Key 查詢模型清單；不傳會議文字。';
    });
    try {
      final list = await _client.listModels(_key.text);
      if (mounted) setState(() {
        _models = list;
        _status = 'Gemini API Key 可取得 Free Tier 候選模型清單；'
            '尚須明確確認 Free 專案、所選模型與推論連線。';
      });
    } catch (error) {
      if (mounted) setState(() => _status =
          'API Key 測試 HOLD：' + _code(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testModel() async {
    final selected = _model;
    if (_busy || !_freeConfirmed || selected == null) return;
    final allowed = await _confirm('測試所選 AI 模型',
        '將使用您提供的 API Key 與 ' + selected +
        ' 發出一次極少量文字的實際模型請求。'
        '不傳逐字稿與錄音；請先在 Google AI Studio 確認所選模型'
        '與 API Key 專案均可使用免費額度。');
    if (!mounted || !allowed) return;
    setState(() { _busy = true; _modelTested = false; });
    try {
      final valid = await _client.testSelectedModel(
          apiKey: _key.text, model: selected);
      if (mounted) setState(() {
        _modelTested = valid;
        _status = valid
            ? '所選模型文字推論 PASS；Free 身分仍由用戶確認。'
            : '模型不可用 HOLD';
      });
    } catch (error) {
      if (mounted) setState(() =>
          _status = 'Gemini 模型測試 HOLD：' + _code(error) +
              '；請匯出脫敏 Debug Log。'
              '失敗後不自動重送、不更換模型。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _analyze() async {
    final selected = _model;
    if (_busy || !_modelTested || !_freeConfirmed || _attempted ||
        selected == null ||
        _reviewRaw.length != widget.staged.length) return;
    final LabSegmentedSttBundle bundle;
    try {
      bundle = _bundle();
    } catch (error) {
      setState(() => _status = '原始資料 HOLD：' + _code(error));
      return;
    }
    if (!bundle.complete ||
        bundle.chunks.any((c) => c.text.length > 10500)) {
      setState(() => _status = 'LAB_AI_CHUNK_LIMIT_HOLD；'
          '不會截斷原文；可先離線匯出 ZIP。');
      return;
    }
    final allowed = await _confirm('明確同意 Gemini Free AI 解析',
        '將以模型 ' + selected + ' 分別送出至多 ' +
        bundle.chunks.length.toString() + ' 次文字請求。'
        '逐字稿、相鄰段落上下文、名單與字典將傳給 Google Gemini，'
        '不會傳 Raw JSON 或錄音。'
        '請先確認 Google AI Studio 的 API 專案與所選模型均在 Free Tier；'
        '免費額度與隱私政策依官方為準。'
        '本次逐字稿解析採正式 Meeting Recorder 文字模式：'
        'JSON 格式、模型預設溫度／思考／輸出上限、180 秒等待。'
        '不同於正式 App，Lab 不自動重送或換 Key。'
        '遇 429／413／回應不完整／網路結果不明就停止，'
        '不自動重試或換模型。結果是待人工複核的草稿，原文不修改。');
    if (!mounted || !allowed) return;
    setState(() {
      _busy = true;
      _attempted = true;
      _status = '開始文字 AI 草稿，最多各 Chunk 一次，不自動重送。';
    });
    try {
      final chunks = bundle.chunks;
      for (var i = 0; i < chunks.length; i++) {
        final current = chunks[i];
        if (current.text.trim().isEmpty) {
          _drafts[i] = '（此 Chunk 原始 STT 無文字；沒有呼叫 AI）';
          continue;
        }
        final before = i == 0 ? '' : chunks[i - 1].text;
        final after = i + 1 == chunks.length ? '' : chunks[i + 1].text;
        final output = await _client.reviewChunk(
          apiKey: _key.text, model: selected, chunk: current,
          previousTail: before.length <= 500
              ? before : before.substring(before.length - 500),
          nextHead: after.length <= 500
              ? after : after.substring(0, 500),
          participants: _participants.text, glossary: _glossary.text,
        );
        if (!mounted) return;
        setState(() {
          _drafts[i] = output;
          _status = '已完成 ' + _drafts.length.toString() + '/' +
              chunks.length.toString() + ' 段 AI 草稿（待人工複核）。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _status =
          'AI 解析 HOLD：' + _code(error) + '；已完成 ' +
          _drafts.length.toString() + '/' +
          bundle.chunks.length.toString() +
          ' 段。未自動重試，未覆寫原文。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _analyzeWhole() async {
    final selected = _model;
    if (_busy || !_modelTested || !_freeConfirmed || _attempted ||
        selected == null || _reviewRaw.length != widget.staged.length) return;
    final LabSegmentedSttBundle bundle;
    try {
      bundle = _bundle(); // Full local SHA/clock validation before consent.
      if (!bundle.complete || bundle.chunks.length != 6) {
        throw StateError('LAB_AI_WHOLE_SOURCE_OR_CONTEXT_HOLD');
      }
      // Runs BEFORE any network access: no truncated/silent partial output.
      LabGeminiFreeAiClient.checkWholeInput(
        sourceSha256: widget.sourceSha256,
        chunks: bundle.chunks,
        participants: _participants.text,
        glossary: _glossary.text,
      );
    } catch (error) {
      if (mounted) setState(() =>
          _status = '全文輸入 HOLD：' + _code(error));
      return;
    }
    final allowed = await _confirm('明確同意 Gemini 全文一次解析',
        '將六段 SHA 核對後的 STT 原文、Chunk 邊界與重疊資訊、'
        '選填與會者與字典一次傳送給 Google Gemini（模型：' +
        selected + '）。只發出一個全文文字請求，'
        '不傳原始 ZIP、錄音、Groq Raw JSON 或原有 AI 草稿。'
        'Google Free Tier 可能使用輸入資料改善產品，'
        '請先確認會議隱私、專案未啟用付費計費及模型可用額度。'
        '全文一次處理可能耗用更多 Token，鎖屏／網路中斷仍可能失敗。'
        '失敗時不自動重送或換 Key／模型；輸出為待人工複核的'
        '無時間戳全文草稿，Raw 與既有逐字稿一律不修改。');
    if (!mounted || !allowed) return;
    setState(() {
      _busy = true;
      _attempted = true;
      _status = 'Gemini 全文單次文字請求中；無自動重試。';
    });
    try {
      final output = await _client.reviewWholeTranscript(
        apiKey: _key.text,
        model: selected,
        sourceSha256: widget.sourceSha256,
        chunks: bundle.chunks,
        participants: _participants.text,
        glossary: _glossary.text,
      );
      // Save and verify the result before displaying a long preview.
      // If disk fails, retain the whole result in memory for immediate export.
      var persisted = false;
      try {
        final fingerprints = _rawFingerprints();
        if (fingerprints == null) {
          throw StateError('LAB_WHOLE_DRAFT_IDENTITY_HOLD');
        }
        await LabWholeDraftStore(await _draftRoot()).save(
            sourceSha256: widget.sourceSha256,
            rawSha256: fingerprints,
            model: selected,
            transcript: output);
        persisted = true;
      } catch (_) {
        persisted = false;
      }
      if (mounted) setState(() {
        _wholeDraft = output;
        _wholeDraftModel = selected;
        _wholePersisted = persisted;
        _status = persisted
            ? '六段全文已自動保存並核對；可在預覽上方匯出。時間戳尚未對齊。'
            : '警告：本機保存失敗！請立即按預覽上方的匯出按鈕。';
      });
    } catch (error) {
      if (mounted) setState(() =>
          _status = '全文 AI HOLD：' + _code(error) +
              '；不自動重送。既有 Raw／ZIP／草稿均不覆寫。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Explicit local-only report. Exact-source Groq segment time is attached
  /// solely to uniquely aligned Gemini text. Missing matches remain untimed.
  Future<void> _shareTimedWhole() async {
    if (_busy || _wholeDraft == null || _reviewRaw.length != 6) return;
    final allowed = await _confirm('匯出 Gemini 全文＋來源時間戳對照稿',
        '僅在手機本機從已核對的六段 Groq Raw 時間戳比對 Gemini 全文。'
        '只有唯一且依序精確匹配的文字可標註來源時間；'
        '修改、重複或重疊不明的字句標記未對齊，絕不杜撰時間。'
        '檔案同時保留完整、未修改的 Gemini 回覆作為對照。'
        '不傳網路、不修改原始 Raw／Journal。您將自行選擇分享目的地。');
    if (!mounted || !allowed) return;
    setState(() => _busy = true);
    try {
      final bundle = _bundle(); // SHA-verified source and all six Raw.
      final report = LabGeminiTimestampedExport.build(
          bundle: bundle,
          staged: widget.staged,
          sourceSha256: widget.sourceSha256,
          geminiText: _wholeDraft!);
      final root = await getApplicationSupportDirectory();
      final dir = Directory(root.path + Platform.pathSeparator +
          'groq_lab_user_exports');
      await dir.create(recursive: true);
      final file = File(dir.path + Platform.pathSeparator +
          'gemini_timed_review_' +
          DateTime.now().toUtc().microsecondsSinceEpoch.toString() + '.txt');
      await file.writeAsString(report, flush: true);
      if (!mounted) return;
      await Share.shareXFiles([XFile(file.path, mimeType: 'text/plain')],
          subject: 'Gemini 全文與 Groq 時間戳對照（待人工複核）');
      if (mounted) setState(() =>
          _status = '已產生來源時間戳對照稿；未對齊片段保留全文。'
              '原始 Raw／Journal 未變更。');
    } catch (error) {
      if (mounted) setState(() =>
          _status = '含時間戳匯出 HOLD：' + _code(error) +
              '；原 Gemini 全文仍可用上方無時間戳匯出。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareDraft() async {
    if (_busy || (_drafts.isEmpty && _wholeDraft == null)) return;
    final allowed = await _confirm('分享未驗證 AI 草稿',
        'AI 可能刪漏或改錯字詞，請自行對照原始逐字稿。'
        '您將主動選擇分享目的地。');
    if (!mounted || !allowed) return;
    setState(() => _busy = true);
    try {
      final buffer = StringBuffer('AI_DRAFT_UNVERIFIED\n')
        ..writeln('model=' + (_wholeDraftModel ?? _model ?? ''))
        ..writeln('source_sha256=' + widget.sourceSha256);
      if (_wholeDraft != null) {
        buffer.writeln('mode=WHOLE_CONTEXT_ONE_SHOT');
        buffer.writeln('input_chunks=' + widget.staged.length.toString());
        buffer.writeln('time_alignment=NOT_VERIFIED');
        buffer.writeln('\n全文 AI 草稿｜待複核（無時間戳）');
        buffer.writeln(_wholeDraft);
      } else {
        buffer.writeln('completed=' + _drafts.length.toString() +
            '/' + widget.staged.length.toString());
        for (var i = 0; i < widget.staged.length; i++) {
          if (_drafts.containsKey(i)) {
            buffer.writeln('\nChunk ' + (i + 1).toString() + '｜待複核');
            buffer.writeln(_drafts[i]);
          }
        }
      }
      final root = await getApplicationSupportDirectory();
      final dir = Directory(root.path + Platform.pathSeparator +
          'groq_lab_user_exports');
      await dir.create(recursive: true);
      final file = File(dir.path + Platform.pathSeparator +
          'ai_draft_' +
          DateTime.now().toUtc().microsecondsSinceEpoch.toString() + '.txt');
      await file.writeAsString(buffer.toString(), flush: true);
      if (!mounted) return;
      await Share.shareXFiles([XFile(file.path, mimeType: 'text/plain')],
          subject: 'AI 逐字稿草稿｜待人工複核');
    } catch (error) {
      if (mounted) setState(() =>
          _status = '草稿分享 HOLD：' + _code(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allSaved = _reviewRaw.length == widget.staged.length;
    return ExpansionTile(
      key: const Key('ai-review-panel'),
      // Hide children without disposing their preview/scroll/edit state.
      // The whole-text draft stays in its original app-private file.
      maintainState: true,
      title: const Text('LAB-3｜分段 STT ZIP＋Gemini Free AI 草稿'),
      childrenPadding: const EdgeInsets.all(12),
      children: [
        Text('已保存 Groq Raw：' +
            widget.savedRawByIndex.length.toString() + '/' +
            widget.staged.length.toString() + ' 段。'
            '不必先通過完整 Provider 時間軸合併。'),
        const Text('原始 Raw／逐字稿不修改；Groq 只負責 STT。'
            'Gemini 僅在您明確同意後接收逐段文字及可選上下文。'
            'Free Tier 可能允許 Google 用於改善產品，請先確認會議隱私。'
            '逐段 AI 採正式 App 的 JSON 生成參數，失敗時保留脫敏結束原因。'),
        TextField(
          key: const Key('ai-participants'),
          controller: _participants, maxLines: 2,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: '與會者名單（選填）'),
        ),
        TextField(
          key: const Key('ai-glossary'),
          controller: _glossary, maxLines: 2,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: '專業詞彙／字典（選填）'),
        ),
        OutlinedButton.icon(
          key: const Key('ai-import-zip'),
          onPressed: _busy || widget.staged.isEmpty ? null : _importZip,
          icon: const Icon(Icons.folder_open),
          label: const Text('唯讀匯入既有分段 STT ZIP（不重送 Groq）'),
        ),
        if (_offlineImport != null)
          Text('匯入 ZIP：' + _offlineImport!.count.toString() + '/' +
              widget.staged.length.toString() +
              ' 段；SHA 已核對，但 Provider 身分未獨立驗證。'),
        OutlinedButton.icon(
          key: const Key('ai-export-zip'),
          onPressed: _busy || widget.savedRawByIndex.isEmpty
              ? null : _exportZip,
          icon: const Icon(Icons.archive_outlined),
          label: const Text('離線封裝 ZIP（Raw／逐段原文）'),
        ),
        const Divider(),
        TextField(
          key: const Key('ai-api-key'), controller: _key,
          enabled: !_busy,
          obscureText: true, enableSuggestions: false, autocorrect: false,
          onChanged: (_) => setState(() {
            _freeConfirmed = false;
            _models = const [];
            _model = null;
            _modelTested = false;
          }),
          decoration: const InputDecoration(
              labelText: 'Gemini API Key（不保存）'),
        ),
        OutlinedButton(
          key: const Key('ai-list-models'),
          onPressed: _busy || _key.text.trim().isEmpty
              ? null : _listModels,
          child: const Text('測試 API Key／讀取模型清單'),
        ),
        if (_models.isNotEmpty)
          DropdownButton<String>(
            key: const Key('ai-select-model'),
            isExpanded: true, value: _model,
            hint: const Text('選擇文字模型'),
            items: [
              for (final model in _models)
                DropdownMenuItem(value: model, child: Text(model)),
            ],
            onChanged: _busy ? null : (model) => setState(() {
              _model = model;
              _freeConfirmed = false;
              _modelTested = false;
            }),
          ),
        CheckboxListTile(
          key: const Key('ai-free-confirmed'),
          value: _freeConfirmed,
          onChanged: _busy ? null : (value) => setState(() {
            _freeConfirmed = value ?? false;
            _modelTested = false;
          }),
          title: const Text('已在 Google AI Studio 確認 API 專案及所選模型為 Free'),
          subtitle: const Text('只顯示官方列有 Free Tier 的文字模型；'
              '請確認 API 專案未啟用付費計費及剩餘額度。'
              '模型清單不能證明帳務狀態；不自動換模型或重送。'),
        ),
        OutlinedButton(
          key: const Key('ai-model-test'),
          onPressed: _busy || !_freeConfirmed || _model == null
              ? null : _testModel,
          child: const Text('測試所選模型（少量文字請求）'),
        ),
        FilledButton(
          key: const Key('ai-run-whole'),
          onPressed: _busy || !_freeConfirmed || !_modelTested ||
                  _attempted || !allSaved ? null : _analyzeWhole,
          child: const Text('全文一次分析（六段文字／無時間戳）'),
        ),
        OutlinedButton(
          key: const Key('ai-run'),
          onPressed: _busy || !_freeConfirmed || !_modelTested ||
                  _attempted || !allSaved ? null : _analyze,
          child: const Text('舊版依段分析（最多六次請求）'),
        ),
        Text(_status, key: const Key('ai-status')),
        if (_wholeDraft != null) ...[
          const Divider(),
          Text(_wholePersisted
              ? '已本機保存；下方按鈕直接匯出，不必滑到全文底部。'
              : '本機保存失敗：請立即匯出，避免資料遺失。',
              key: const Key('ai-whole-save-status')),
          FilledButton.icon(
            key: const Key('ai-export-whole-timed-top'),
            onPressed: _busy || _reviewRaw.length != 6
                ? null : _shareTimedWhole,
            icon: const Icon(Icons.download_outlined),
            label: const Text('匯出 Gemini 全文＋來源時間戳對照稿'),
          ),
          OutlinedButton.icon(
            key: const Key('ai-share-whole-top'),
            onPressed: _busy ? null : _shareDraft,
            icon: const Icon(Icons.save_alt),
            label: const Text('立即匯出 Gemini 全文草稿（無時間戳）'),
          ),
          const Text('六段全文 AI 草稿｜待人工複核、時間戳尚未對齊'),
          SizedBox(
            height: 300,
            child: SingleChildScrollView(
              key: const Key('ai-whole-scroll-preview'),
              child: SelectableText(_wholeDraft!),
            ),
          ),
        ],
        if (_drafts.isNotEmpty) ...[
          Text('AI 草稿 ' + _drafts.length.toString() + '/' +
              widget.staged.length.toString() + ' 段，須人工複核。'),
          for (var i = 0; i < widget.staged.length; i++)
            if (_drafts.containsKey(i))
              ExpansionTile(
                title: Text('Chunk ' + (i + 1).toString() + ' AI 草稿'),
                children: [SelectableText(_drafts[i]!)],
              ),
        ],
        if (_wholeDraft != null || _drafts.isNotEmpty)
          OutlinedButton(
            key: const Key('ai-share-draft'),
            onPressed: _busy ? null : _shareDraft,
            child: const Text('分享 AI 草稿（不覆寫原文）'),
          ),
      ],
    );
  }
}
