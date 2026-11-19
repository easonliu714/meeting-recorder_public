import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'lab_groq_merged_review.dart';

/// In-app, read-only presentation of actual Groq Raw candidates.
/// A full report may be copied only after every physical Chunk has a Raw.
class LabGroqMergeReviewPanel extends StatelessWidget {
  const LabGroqMergeReviewPanel({super.key, required this.review,
      this.verifiedProviderSource = true, this.actualSavedRawCount,
      this.blockedChunkOneBased, this.holdCode});

  final LabGroqMergedReview review;
  final bool verifiedProviderSource;
  /// The immutable journal may have more saved receipts than the strictly
  /// verified transcript prefix. These counts must never be conflated.
  final int? actualSavedRawCount;
  final int? blockedChunkOneBased;
  final String? holdCode;

  @override
  Widget build(BuildContext context) {
    final rawSaved = actualSavedRawCount ?? review.chunksSaved;
    final prefixHold = verifiedProviderSource &&
        (rawSaved > review.chunksSaved || blockedChunkOneBased != null);
    final completed = review.allRawReceived && !prefixHold;
    final count = review.timeline.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              completed
                  ? (verifiedProviderSource
                      ? '真實 Groq STT 全段合併檢視（待人工複核）'
                      : '本機匯入 JSON 全段合併檢視（Provider 身分未驗證）')
                  : (verifiedProviderSource
                      ? '真實 Groq STT 已保存段落預覽（尚未合併完成）'
                      : '本機匯入 JSON 段落預覽（Provider 身分未驗證）'),
              key: const Key('groq-merge-title'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              prefixHold
                  ? 'Groq Raw 已保存：$rawSaved/${review.chunksExpected} 段；'
                      '已驗證逐字稿：${review.chunksSaved}/${review.chunksExpected} 段；'
                      '辨識段落：$count；重疊待複核：${review.overlapReviewCount}'
                  : (verifiedProviderSource ? 'Groq Raw：' : '本機 JSON：') +
                      '${review.chunksSaved}/${review.chunksExpected} 段；'
                      '時間軸辨識段落：$count；'
                      '重疊待複核：${review.overlapReviewCount}',
              key: const Key('groq-merge-summary'),
            ),
            Text(
              completed
                  ? (verifiedProviderSource
                      ? '已收齊全部實體 Chunk 的真實 Raw，以下依全域時間排序並保留重疊候選；仍須人工確認邊界與逐字稿，不代表自動去重完成。'
                      : '本機六份 JSON 已匯入；Provider 身分與原始來源綁定尚未驗證，僅供離線時間軸人工複核。')
                  : prefixHold
                      ? '後續 Raw 已保存但 Provider 時間戳未通過驗證。'
                          '已保留先前通過驗證的逐字稿；不會自動裁切時間、'
                          '捨棄原文或宣稱完整合併。'
                      : '部分段落尚未收齊，不會產生假文字。',
              key: const Key('groq-merge-state'),
            ),
            if (prefixHold)
              Text(
                'Chunk ${blockedChunkOneBased ?? review.chunksSaved + 1} '
                '解析 HOLD：${holdCode ?? 'GROQ_PROVIDER_PREFIX_HOLD'}；'
                '請保留原始 Raw／Journal，不要重送已成功的 Chunk。',
                key: const Key('groq-merge-prefix-hold'),
              ),
            if (review.textlessChunkIndices.isNotEmpty)
              Text(
                '已保存但未取得有效文字的段落：' +
                    review.textlessChunkIndices
                        .map((i) => 'Chunk ' + (i + 1).toString())
                        .join('、') +
                    '。可能是靜音或 Groq 空白片段；原始 Raw 未刪除。',
                key: const Key('groq-merge-empty-chunks'),
              ),
            const SizedBox(height: 8),
            SizedBox(
              height: 400,
              child: ListView.builder(
                key: const Key('groq-merge-list'),
                itemCount: count,
                itemBuilder: (context, index) {
                  final c = review.timeline[index];
                  return ListTile(
                    key: ValueKey('groq-segment-$index'),
                    dense: true,
                    title: Text(c.rawText),
                    subtitle: Text(
                      'Chunk ${c.chunkIndex + 1}｜'
                      '${_stamp(c.globalStartMs)} – '
                      '${_stamp(c.globalEndMs)}',
                    ),
                    trailing: c.requiresOverlapReview
                        ? const Tooltip(
                            message: '重疊邊界：需人工複核，未自動刪除',
                            child: Icon(Icons.rule, color: Colors.deepOrange),
                          )
                        : const Icon(Icons.check_circle_outline),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Text(
              completed
                  ? '可主動複製全部合併檢視文字供人工比對；'
                      '複製後內容會進入系統剪貼簿，請避免分享敏感錄音內容。'
                  : prefixHold
                      ? 'Raw 即使已保存 6/6，仍有時間軸未驗證；'
                          '完整合併文字複製功能停用。'
                      : '尚未收齊全部 Raw，完整合併文字複製功能停用。',
            ),
            OutlinedButton.icon(
              key: const Key('groq-copy-full-merge'),
              onPressed: completed
                  ? () async {
                      await Clipboard.setData(
                        ClipboardData(text: review.buildReviewText(
                            sourceVerified: verifiedProviderSource)),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已複製完整合併檢視文字')),
                        );
                      }
                    }
                  : null,
              icon: const Icon(Icons.copy),
              label: const Text('複製六段／全段合併 STT 檢視內容'),
            ),
          ],
        ),
      ),
    );
  }

  static String _stamp(int ms) {
    final hh = ms ~/ 3600000;
    final mm = ms ~/ 60000 % 60;
    final ss = ms ~/ 1000 % 60;
    final sub = ms % 1000;
    return '${hh.toString().padLeft(2, '0')}:'
        '${mm.toString().padLeft(2, '0')}:'
        '${ss.toString().padLeft(2, '0')}.'
        '${sub.toString().padLeft(3, '0')}';
  }
}
