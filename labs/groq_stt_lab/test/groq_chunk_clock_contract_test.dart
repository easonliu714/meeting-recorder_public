import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/groq_chunk_clock_contract.dart';

GroqChunkClock c({
  String part = 'p1',
  String sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  int partStart = 0,
  int duration = 240000,
  int coreStart = 0,
  int coreEnd = 120000,
  int wireStart = 0,
  int wireEnd = 120000,
  int bytes = 1950000,
}) => GroqChunkClock(
  partId: part, partSha256: sha,
  partGlobalStartMs: partStart, partDurationMs: duration,
  coreStartMs: coreStart, coreEndMs: coreEnd,
  wireStartMs: wireStart, wireEndMs: wireEnd, byteCount: bytes);

void main() {
  test('L2C two adjacent windows preserve core and 2s wire overlap', () {
    final chunks = [
      c(), c(coreStart: 120000, coreEnd: 240000,
          wireStart: 118000, wireEnd: 240000),
    ];
    GroqChunkClockContract.verify(chunks);
    expect(GroqChunkClockContract.globalTimeMs(chunks[1], 2000), 120000);
    expect(GroqChunkClockContract.isCoreOwned(chunks[1], 120000), isTrue);
    expect(GroqChunkClockContract.isCoreOwned(chunks[0], 120000), isFalse);
  });

  test('L2C cross physical Part global clock exactly contiguous', () {
    final chunks = [
      c(),
      c(coreStart: 120000, coreEnd: 240000,
        wireStart: 118000, wireEnd: 240000),
      c(part: 'p2', partStart: 240000, duration: 60000,
        coreEnd: 60000, wireEnd: 60000),
    ];
    GroqChunkClockContract.verify(chunks);
    expect(GroqChunkClockContract.globalTimeMs(chunks[2], 12345), 252345);
  });

  test('L2C reject internal chunk gap or collision', () {
    expect(() => GroqChunkClockContract.verify([
      c(), c(coreStart: 120001, coreEnd: 240000,
        wireStart: 118001, wireEnd: 240000),
    ]), throwsStateError);
  });

  test('P0-C rejects replayed Part identity at a forged later offset', () {
    final chunks = [
      c(part: 'p1', duration: 60000, coreEnd: 60000,
        wireEnd: 60000, bytes: 1920044),
      c(part: 'p2', partStart: 60000, duration: 60000,
        coreEnd: 60000, wireEnd: 60000, bytes: 1920044),
      c(part: 'p1', partStart: 120000, duration: 60000,
        coreEnd: 60000, wireEnd: 60000, bytes: 1920044),
    ];
    expect(() => GroqChunkClockContract.verify(chunks),
      throwsA(isA<StateError>().having((e) => e.message, 'reason',
          'PART_ID_REUSED_NONCONTIGUOUS')));
  });

  test('L2C reject new Part offset gap', () {
    expect(() => GroqChunkClockContract.verify([
      c(duration: 120000),
      c(part: 'p2', partStart: 120100, duration: 100000,
        coreEnd: 100000, wireEnd: 100000),
    ]), throwsStateError);
  });

  test('L2C reject Part mutation SHA and wrong 2s overlap', () {
    expect(() => GroqChunkClockContract.verify([
      c(), c(sha:'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        coreStart: 120000, coreEnd: 240000, wireStart: 118000,
        wireEnd: 240000),
    ]), throwsStateError);
    expect(() => GroqChunkClockContract.verify([
      c(), c(coreStart: 120000, coreEnd: 240000,
        wireStart: 119000, wireEnd: 240000),
    ]), throwsStateError);
  });

  test('L2C strict 22.5MB and 702s encoded wire caps', () {
    expect(() => GroqChunkClockContract.verify([
      c(duration: 120000, bytes: 22500000),
    ]), throwsStateError);
    expect(() => GroqChunkClockContract.verify([
      c(duration: 710000, coreEnd: 710000, wireEnd: 710000),
    ]), throwsStateError);
  });

  test('L2C fail-closed timestamp beyond wire', () {
    expect(() => GroqChunkClockContract.globalTimeMs(c(), 120001),
      throwsStateError);
    expect(() => GroqChunkClockContract.globalTimeMs(c(), -1),
      throwsStateError);
  });

  test('L2C reject incomplete final Part', () {
    expect(() => GroqChunkClockContract.verify([c()]), throwsStateError);
  });
}
