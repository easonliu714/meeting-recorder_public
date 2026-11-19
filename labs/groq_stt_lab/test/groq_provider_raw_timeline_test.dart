import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/groq_chunk_clock_contract.dart';
import 'package:groq_stt_lab/groq_provider_raw_timeline.dart';

GroqChunkClock window({
  String part = 'p1',
  String sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  int offset = 0,
  int duration = 240000,
  int coreStart = 0,
  int coreEnd = 120000,
  int wireStart = 0,
  int wireEnd = 120000,
}) => GroqChunkClock(
  partId: part,
  partSha256: sha,
  partGlobalStartMs: offset,
  partDurationMs: duration,
  coreStartMs: coreStart,
  coreEndMs: coreEnd,
  wireStartMs: wireStart,
  wireEndMs: wireEnd,
  byteCount: 1500000,
);

String raw(List<Map<String, Object?>> segments) =>
    jsonEncode({'segments': segments, 'text': 'provider original'});

void main() {
  final two = [
    window(),
    window(coreStart: 120000, coreEnd: 240000,
        wireStart: 118000, wireEnd: 240000),
  ];

  test('P3L provider timestamps use physical global offset and keep raw text',
      () {
    final original = raw([
      {'start': 10.2, 'end': 10.9, 'text': '  exact provider text  '}
    ]);
    final second = raw([
      {'start': 2.1, 'end': 3.0, 'text': 'next core'}
    ]);
    final inputs = [original, second];
    final output = GroqProviderRawTimeline.candidates(
        chunks: two, rawJsonByChunk: inputs);
    expect(output.length, 2);
    expect(output.first.rawText, '  exact provider text  ');
    expect(output.first.globalStartMs, 10200);
    expect(output.first.globalEndMs, 10900);
    expect(output.last.globalStartMs, 120100);
    expect(output.last.globalEndMs, 121000);
    expect(output.every((s) => s.coreOwned), isTrue);
    expect(inputs, [original, second]);
    expect(() => output.clear(), throwsUnsupportedError);
  });

  test('P3L 2s overlap duplicate is preserved and marked for review', () {
    final output = GroqProviderRawTimeline.candidates(
      chunks: two,
      rawJsonByChunk: [
        raw([{'start': 119.0, 'end': 119.8, 'text': 'repeated'}]),
        raw([{'start': 0.8, 'end': 1.8, 'text': 'repeated'}]),
      ],
    );
    expect(output.length, 2);
    expect(output[0].rawText, output[1].rawText);
    expect(output[0].requiresOverlapReview, isFalse);
    expect(output[1].requiresOverlapReview, isTrue);
    expect(output[1].globalStartMs, 118800);
  });

  test('P3L physical Part 2 uses verified accumulated global clock', () {
    final plan = [
      window(duration: 120000),
      window(part: 'p2',
          sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          offset: 120000, duration: 60000,
          coreEnd: 60000, wireEnd: 60000),
    ];
    final output = GroqProviderRawTimeline.candidates(
      chunks: plan,
      rawJsonByChunk: [
        raw([{'start': 1, 'end': 2, 'text': 'p1'}]),
        raw([{'start': 5, 'end': 6, 'text': 'p2'}]),
      ],
    );
    expect(output[1].partId, 'p2');
    expect(output[1].globalStartMs, 125000);
  });

  test('P3L invalid, missing or mismatched raw evidence fails closed', () {
    expect(() => GroqProviderRawTimeline.candidates(
        chunks: two, rawJsonByChunk: ['{}']), throwsStateError);
    expect(() => GroqProviderRawTimeline.candidates(
        chunks: two, rawJsonByChunk: ['{', '{}']), throwsStateError);
    expect(() => GroqProviderRawTimeline.candidates(
        chunks: two, rawJsonByChunk: [
          jsonEncode({'error': 'bad', 'segments': [
            {'start': 0, 'end': 1, 'text': 'bad'}
          ]}),
          raw([{'start': 1, 'end': 2, 'text': 'ok'}])
        ]), throwsStateError);
  });

  test('P3L invalid timestamps and malformed speech are rejected',
      () {
    for (final segment in [
      {'start': -1, 'end': 1, 'text': 'bad'},
      {'start': 1, 'end': 1, 'text': 'bad'},
      {'start': 121, 'end': 122, 'text': 'bad'},
      {'start': '1', 'end': 2, 'text': 'bad'},
      {'start': 1, 'end': 2, 'text': null},
      {'start': 4, 'end': 3, 'text': ' '},
    ]) {
      expect(() => GroqProviderRawTimeline.candidates(
        chunks: two,
        rawJsonByChunk: [
          raw([segment]),
          raw([{'start': 2, 'end': 3, 'text': 'ok'}])
        ],
      ), throwsStateError);
    }
  });

  test('P3L empty text with valid clock is silence not a missing receipt',
      () {
    final first = raw([
      {'start': 0.0, 'end': 0.0, 'text': ''},
      {'start': 1.0, 'end': 2.0, 'text': ' '},
    ]);
    final second = raw([
      {'start': 2.2, 'end': 3.0, 'text': 'spoken'},
    ]);
    // raw() uses a generic non-empty top-level text; make the first
    // provider's top-level string empty to represent genuinely silent audio.
    final silent = jsonEncode({
      'text': '',
      'segments': jsonDecode(first)['segments'],
    });
    final result = GroqProviderRawTimeline.candidates(
      chunks: two, rawJsonByChunk: [silent, second],
    );
    expect(result, hasLength(1));
    expect(result.single.rawText, 'spoken');
    expect(result.single.chunkIndex, 1);
    expect(result.single.globalStartMs, 120200);
  });

  test('P3L nonempty text with no valid timed words cannot disappear', () {
    final first = jsonEncode({
      'text': 'provider claims speech',
      'segments': [
        {'start': 0, 'end': 0, 'text': ' '},
      ],
    });
    expect(() => GroqProviderRawTimeline.candidates(
      chunks: two, rawJsonByChunk: [
        first,
        raw([{'start': 1, 'end': 2, 'text': 'untouched'}]),
      ],
    ), throwsStateError);
  });

  // P3S: the raw provider segment sequence is immutable evidence. Accept
  // chronological and same-start speech, but never silently sort reversed
  // segments into a seemingly trustworthy global timeline.
  test('P3S chronological and same-start speech preserves provider raw', () {
    final first = raw([
      {'start': 1.0, 'end': 2.0, 'text': ' first '},
      {'start': 1.0, 'end': 2.4, 'text': ' simultaneous '},
      {'start': 2.0, 'end': 3.0, 'text': ' later '},
    ]);
    final second = raw([
      {'start': 0.1, 'end': 0.8, 'text': ' next window '},
    ]);
    final original = [first, second];
    final result = GroqProviderRawTimeline.candidates(
      chunks: two, rawJsonByChunk: original);
    expect(result.map((s) => s.rawText).toList(),
      [' first ', ' simultaneous ', ' later ', ' next window ']);
    expect(result[0].globalStartMs, 1000);
    expect(result[1].globalStartMs, 1000);
    expect(result[2].globalStartMs, 2000);
    expect(original, [first, second]);
  });

  test('P3S reversed provider segment starts fail closed without sorting', () {
    final first = raw([
      {'start': 10.0, 'end': 11.0, 'text': ' earlier in response '},
      {'start': 9.0, 'end': 9.5, 'text': ' reversed timestamp '},
    ]);
    final second = raw([
      {'start': 1.0, 'end': 2.0, 'text': ' untouched '},
    ]);
    final original = [first, second];
    expect(
      () => GroqProviderRawTimeline.candidates(
        chunks: two, rawJsonByChunk: original),
      throwsA(isA<StateError>().having(
        (e) => e.message, 'reason', 'GROQ_PROVIDER_SEGMENT_ORDER_HOLD')),
    );
    expect(original, [first, second]);
  });

  // P4D: the independent read-only timeline must reject sub-ms reverse order
  // even when both provider starts round to the same global millisecond.
  test('P4D sub-ms reversed provider starts fail closed without raw mutation', () {
    final first = raw([
      {'start': 2.0004, 'end': 2.5, 'text': 'earlier in response'},
      {'start': 2.0003, 'end': 2.6, 'text': 'reversed by 0.1ms'},
    ]);
    final second = raw([
      {'start': 1.0, 'end': 2.0, 'text': 'untouched'},
    ]);
    final originals = [first, second];
    expect(
      () => GroqProviderRawTimeline.candidates(
          chunks: two, rawJsonByChunk: originals),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'reason', 'GROQ_PROVIDER_SEGMENT_ORDER_HOLD')),
    );
    expect(originals, [first, second]);
  });

  // P4D: rounding 120.0004s to 120000ms must not permit provider speech
  // outside a 120000ms attested wire. Raw receipts remain untouched.
  test('P4D sub-ms physical wire overrun fails closed', () {
    final first = raw([
      {'start': 119.9, 'end': 120.0004, 'text': 'overrun'},
    ]);
    final second = raw([
      {'start': 1.0, 'end': 2.0, 'text': 'untouched'},
    ]);
    final originals = [first, second];
    expect(
      () => GroqProviderRawTimeline.candidates(
          chunks: two, rawJsonByChunk: originals),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'reason', 'GROQ_PROVIDER_SEGMENT_OUTSIDE_WIRE')),
    );
    expect(originals, [first, second]);
  });

  // P4D: valid equal starts, increasing sub-ms starts and exact physical
  // wire end remain acceptable; the raw order and bytes are not rewritten.
  test('P4D equal starts and exact wire-end preserve original raw', () {
    final first = raw([
      {'start': 2.0003, 'end': 2.3, 'text': 'first'},
      {'start': 2.0003, 'end': 2.4, 'text': 'same start'},
      {'start': 2.0004, 'end': 2.5, 'text': 'later'},
      {'start': 119.5, 'end': 120.0, 'text': 'wire end'},
    ]);
    final second = raw([
      {'start': 1.0, 'end': 2.0, 'text': 'next'},
    ]);
    final originals = [first, second];
    final output = GroqProviderRawTimeline.candidates(
        chunks: two, rawJsonByChunk: originals);
    expect(output.map((s) => s.rawText).toList(),
        ['first', 'same start', 'later', 'wire end', 'next']);
    expect(output[0].globalStartMs, 2000);
    expect(output[1].globalStartMs, 2000);
    expect(output[2].globalStartMs, 2000);
    expect(output[3].globalEndMs, 120000);
    expect(originals, [first, second]);
  });
}
