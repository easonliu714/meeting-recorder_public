import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'lab_audio_pipeline.dart';
import 'lab_groq_ai_review_panel.dart';
import 'lab_debug_log.dart';
import 'lab_groq_free_durable_journal.dart';
import 'lab_groq_free_stt_transport.dart';
import 'lab_groq_raw_receipt_store.dart';

/// Returns only the contiguous prefix beginning with Chunk 1.
/// Skips no missing receipt and never fabricates any unsent segment.
/// This is a read-only preview selection, not a completion/merge marker.
List<String> labGroqSavedRawPrefix({
  required Map<int, String> rawByIndex,
  required int chunkCount,
}) {
  if (chunkCount <= 0 || chunkCount > 1000 ||
      rawByIndex.keys.any((index) => index < 0 || index >= chunkCount)) {
    throw StateError('LAB_GROQ_PREFIX_INDEX_HOLD');
  }
  final raw = <String>[];
  for (var i = 0; i < chunkCount; i++) {
    final value = rawByIndex[i];
    if (value == null) break;
    if (value.isEmpty) throw StateError('LAB_GROQ_PREFIX_EMPTY_RAW_HOLD');
    raw.add(value);
  }
  return List<String>.unmodifiable(raw);
}

/// New LAB-2 only. Existing offline v0.3.1+4 paths are not changed.
/// The secret key lives in a TextEditingController only, never preferences,
/// raw receipts, the durable journal, or exported diagnostic logs.
class LabGroqSttPanel extends StatefulWidget {
  const LabGroqSttPanel({
    super.key,
    required this.sourceFile,
    required this.originalSourceSha256,
    required this.chunks,
    required this.onAvailableRawPrefix,
    required this.debugJournal,
  });

  final File sourceFile;
  final String originalSourceSha256;
  final List<LabStagedChunk> chunks;
  final ValueChanged<List<String>> onAvailableRawPrefix;
  final LabDebugJournal debugJournal;

  @override
  State<LabGroqSttPanel> createState() => _LabGroqSttPanelState();
}

// LAB-3 contains a user-confirmed offline ZIP and a saved whole-text draft.
// Keep this sliver child mounted when the long parent ListView scrolls away;
// otherwise a new State discards transient ZIP/import context on return.
class _LabGroqSttPanelState extends State<LabGroqSttPanel>
    with AutomaticKeepAliveClientMixin<LabGroqSttPanel> {
  @override
  bool get wantKeepAlive => true;

  final TextEditingController _key = TextEditingController();
  final _transport = LabGroqFreeSttTransport();
  LabGroqFreeDurableJournal? _journal;
  LabGroqRawReceiptStore? _rawStore;
  final Map<int, String> _receivedRaw = {};
  final Map<int, String> _receivedRawSha = {};
  bool _busy = true;
  int _index = 0;
  String _model = 'whisper-large-v3';
  String _status = '載入 Groq Free 持久化紀錄…';

  @override
  void initState() {
    super.initState();
    _restoreJournal();
  }

  @override
  void dispose() {
    _key.clear();
    _key.dispose();
    super.dispose();
  }

  void _publishAvailablePrefix() {
    final prefix = labGroqSavedRawPrefix(
      rawByIndex: _receivedRaw, chunkCount: widget.chunks.length,
    );
    if (prefix.isNotEmpty) widget.onAvailableRawPrefix(prefix);
  }

  Future<void> _restoreJournal() async {
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory(
          support.path + Platform.pathSeparator + 'groq_free_stt_lab_public_v21');
      final journal = await LabGroqFreeDurableJournal.open(
          File(root.path + Platform.pathSeparator + 'attempts.jsonl'));
      final store = LabGroqRawReceiptStore(Directory(
          root.path + Platform.pathSeparator + 'provider_raw'));
      final recovered = <int, String>{};
      final recoveredSha = <int, String>{};
      for (var i = 0; i < widget.chunks.length; i++) {
        final attempt = journal.attemptForWire(
            widget.originalSourceSha256, widget.chunks[i].sha256Hex);
        if (attempt == null) continue;
        // Crash after the immutable file rename but before journal commit:
        // reconcile local evidence only, never perform a second HTTP call.
        if (journal.phaseOf(attempt) == 'RAW_PENDING') {
          final receipt = await store.inspectComplete(attempt);
          if (receipt != null) {
            await journal.markRawSaved(
              attemptId: attempt,
              rawSha256: receipt.sha256Hex,
              rawBytes: receipt.byteCount,
            );
          }
        }
        final sha = journal.savedRawSha(attempt);
        if (sha != null) {
          recovered[i] = await store.readVerified(attempt, sha);
          recoveredSha[i] = sha;
        }
      }
      if (!mounted) return;
      setState(() {
        _journal = journal;
        _rawStore = store;
        _receivedRaw.addAll(recovered);
        _receivedRawSha.addAll(recoveredSha);
        _status = '已還原 ' + recovered.length.toString() +
            ' 段已保存的 Groq Raw；UNKNOWN 不會自動重新送出。';
        _busy = false;
      });
      // Rebuild visible partial STT from already saved local Raw on restart.
      // NO provider HTTP or retry is issued by this path.
      _publishAvailablePrefix();
      widget.debugJournal.record('GROQ_FREE_JOURNAL_OPEN', {
        'attempts': journal.attemptCount,
        'observed': journal.observedAttempts,
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'Groq Free 紀錄載入 HOLD：' +
            LabDebugJournal.failureCode(error);
        _busy = false;
      });
    }
  }

  Future<void> _sendSelectedChunk() async {
    final journal = _journal;
    final store = _rawStore;
    if (_busy || journal == null || store == null ||
        _receivedRaw.containsKey(_index)) return;
    if (!journal.canStartNewManualChunk(DateTime.now().toUtc())) {
      setState(() => _status =
          '目前停止或冷卻中：' + journal.statusAt(DateTime.now().toUtc()));
      return;
    }
    final chunkIndex = _index;
    final chunk = widget.chunks[chunkIndex];
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('確認傳送至 Groq Free STT'),
        content: Text('只傳送 Chunk ' + (chunkIndex + 1).toString() +
            '，實際大小 ' + chunk.byteCount.toString() +
            ' bytes。\n模型：' + _model +
            '\n錄音內容將離開手機並交由 Groq 處理。'
            '\n請確認 Groq 帳戶為 Free 方案；程式不升級方案、不自動重送。'
            '\n此同意只適用本次單一 Chunk。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('同意傳送此 Chunk')),
        ],
      ),
    );
    if (!mounted || approved != true) return;
    // Distinct attempt ID; a returned network failure never reuses it.
    final attemptId = 'lab_' +
        DateTime.now().toUtc().microsecondsSinceEpoch.toString() +
        '_' + chunkIndex.toString();
    setState(() {
      _busy = true;
      _status = '傳送 Chunk ' + (chunkIndex + 1).toString() +
          ' 至 Groq Free；中斷時保留 UNKNOWN，不會自動重送。';
    });
    widget.debugJournal.record('GROQ_FREE_SEND_CONSENT', {
      'chunk': chunkIndex + 1,
      'bytes': chunk.byteCount,
    });
    try {
      final result = await _transport.sendOne(
        attemptId: attemptId,
        sourceFile: widget.sourceFile,
        expectedSourceSha256: widget.originalSourceSha256,
        chunk: chunk,
        apiKey: _key.text.trim(),
        model: _model,
        explicitConsent: true,
        journal: journal,
        rawStore: store,
        onDiagnostic: (code, data) => widget.debugJournal.record(code, data),
      );
      if (!mounted) return;
      final raw = result.rawReceipt;
      if (raw != null) {
        final json = await store.readVerified(attemptId, raw.sha256Hex);
        if (!mounted) return;
        _receivedRaw[chunkIndex] = json;
        _receivedRawSha[chunkIndex] = raw.sha256Hex;
        widget.debugJournal.record('GROQ_FREE_RAW_SAVED', {
          'chunk': chunkIndex + 1,
          'status': result.httpStatus,
          'bytes': raw.byteCount,
          'sha12': raw.sha256Hex.substring(0, 12),
        });
        setState(() => _status = 'Chunk ' + (chunkIndex + 1).toString() +
            ' 的 Groq verbose_json 已保存並核對 SHA；' +
            _receivedRaw.length.toString() + '/' +
            widget.chunks.length.toString() + ' 段。');
        // Expose Chunk 1 immediately. Further contiguous chunks update the
        // same preview, retaining strict global clock/overlap checks.
        _publishAvailablePrefix();
      } else {
        widget.debugJournal.record('GROQ_FREE_HTTP_STOP', {
          'chunk': chunkIndex + 1, 'status': result.httpStatus,
          'cooldown_s': journal.cooldownSeconds(DateTime.now().toUtc()),
        });
        setState(() => _status = 'Groq HTTP ' +
            result.httpStatus.toString() + '；狀態：' +
            journal.statusAt(DateTime.now().toUtc()) +
            '。不會自動重新傳送。');
      }
    } catch (error) {
      widget.debugJournal.record('GROQ_FREE_SEND_HOLD', {
        'chunk': chunkIndex + 1,
        'code': LabDebugJournal.failureCode(error),
      });
      if (mounted) {
        setState(() => _status = 'Groq STT HOLD：' +
            LabDebugJournal.failureCode(error) +
            '。若結果不明，請先檢查 Journal，禁止重送。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Required to register keep-alive with the nearest SliverList.
    super.build(context);
    final journal = _journal;
    final now = DateTime.now().toUtc();
    final ready = journal?.canStartNewManualChunk(now) ?? false;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('LAB-2｜Groq Free 真實 STT（逐段確認）',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Text('API Key 僅在當次 APP 記憶體使用，不儲存、'
                '不寫入 Debug Log；不會自動上傳下一段。'),
            TextField(
              key: const Key('groq-live-key'),
              controller: _key,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Groq API Key（不保存）',
              ),
            ),
            DropdownButton<String>(
              key: const Key('groq-live-model'),
              isExpanded: true,
              value: _model,
              items: const [
                DropdownMenuItem(value: 'whisper-large-v3',
                    child: Text('Whisper Large V3（品質優先）')),
                DropdownMenuItem(value: 'whisper-large-v3-turbo',
                    child: Text('Whisper V3 Turbo（速度優先）')),
              ],
              onChanged: _busy ? null : (value) {
                if (value != null) setState(() => _model = value);
              },
            ),
            DropdownButton<int>(
              key: const Key('groq-live-chunk'),
              isExpanded: true,
              value: _index,
              items: [
                for (var i = 0; i < widget.chunks.length; i++)
                  DropdownMenuItem(value: i,
                    child: Text('Groq Chunk ' + (i + 1).toString() +
                        (_receivedRaw.containsKey(i) ? '｜已保存' : '')),
                  ),
              ],
              onChanged: _busy ? null : (value) {
                if (value != null) setState(() => _index = value);
              },
            ),
            Text('用量：觀測 ' + (journal?.observedAttempts ?? 0).toString() +
                ' 次；成功 ' + (journal?.successfulResponses ?? 0).toString() +
                ' 次；429 ' + (journal?.rateLimitedResponses ?? 0).toString() +
                ' 次；音訊 ' + (journal?.attemptedAudioMs ?? 0).toString() +
                ' ms（非計費數據）'),
            Text('持久化狀態：' +
                (journal?.statusAt(now) ?? 'NOT_LOADED') +
                '；冷卻剩餘 ' +
                (journal?.cooldownSeconds(now) ?? 0).toString() + ' 秒',
                key: const Key('groq-live-journal-status')),
            Text(_status, key: const Key('groq-live-status')),
            Wrap(spacing: 8, children: [
              FilledButton.icon(
                key: const Key('groq-live-send-one'),
                onPressed: _busy || !ready ||
                        _receivedRaw.containsKey(_index)
                    ? null : _sendSelectedChunk,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('確認並傳送此 Chunk'),
              ),
              OutlinedButton(
                key: const Key('groq-live-refresh'),
                onPressed: _busy ? null : () => setState(() {}),
                child: const Text('更新冷卻狀態'),
              ),
            ]),
            LabGroqAiReviewPanel(
              key: const Key('ai-segmented-stt-section'),
              staged: widget.chunks,
              sourceSha256: widget.originalSourceSha256,
              savedRawByIndex: Map.unmodifiable(_receivedRaw),
              savedRawShaByIndex: Map.unmodifiable(_receivedRawSha),
              onDiagnostic: (code, data) =>
                  widget.debugJournal.record(code, data),
            ),
          ],
        ),
      ),
    );
  }
}
