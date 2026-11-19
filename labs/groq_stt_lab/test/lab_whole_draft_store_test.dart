import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_whole_draft_store.dart';

const source = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final raws = List<String>.generate(6, (i) =>
    List.filled(64, (i + 1).toString()).join());

void main() {
  late Directory dir;
  late LabWholeDraftStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lab_whole_draft_');
    store = LabWholeDraftStore(Directory(dir.path + '/drafts'));
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('atomic save/readback and restart restore exact six-Raw identity',
      () async {
    final saved = await store.save(
        sourceSha256: source, rawSha256: raws,
        model: 'gemini-2.5-flash', transcript: '完整六段全文。');
    final restarted = LabWholeDraftStore(Directory(dir.path + '/drafts'));
    final restored = await restarted.latest(
        sourceSha256: source, rawSha256: raws);
    expect(restored?.text, saved.text);
    expect(restored?.model, 'gemini-2.5-flash');
    expect(restored?.sha256,
        sha256.convert(utf8.encode('完整六段全文。')).toString());
    final files = await Directory(dir.path + '/drafts').list().toList();
    expect(files.length, 1);
    expect(await (files.single as File).readAsString(),
        isNot(contains('api_key')));
  });

  test('wrong source or changed raw SHA cannot recover stale transcript',
      () async {
    await store.save(sourceSha256: source, rawSha256: raws,
        model: 'gemini-2.5-flash', transcript: '正本');
    expect(await store.latest(sourceSha256: source,
        rawSha256: [...raws.take(5), List.filled(64, 'f').join()]), isNull);
    expect(await store.latest(
        sourceSha256: List.filled(64, 'b').join(),
        rawSha256: raws), isNull);
    expect(() => LabWholeDraftStore.contextId(source, raws.take(5).toList()),
        throwsStateError);
  });

  test('tampered persisted transcript fails closed without a fake recovery',
      () async {
    await store.save(sourceSha256: source, rawSha256: raws,
        model: 'gemini-2.5-flash', transcript: '可恢復');
    final file = (await Directory(dir.path + '/drafts').list().toList())
        .single as File;
    final corrupt = jsonDecode(await file.readAsString())
        as Map<String, dynamic>;
    corrupt['transcript'] = '偽造';
    await file.writeAsString(jsonEncode(corrupt));
    expect(await store.latest(sourceSha256: source, rawSha256: raws), isNull);
    await expectLater(store.save(sourceSha256: source, rawSha256: raws,
        model: 'gemini-2.5-flash', transcript: ''), throwsStateError);
  });

  test('later response is append-only, old snapshot remains available',
      () async {
    await store.save(sourceSha256: source, rawSha256: raws,
        model: 'gemini-2.5-flash', transcript: '第一份');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await store.save(sourceSha256: source, rawSha256: raws,
        model: 'gemini-2.5-flash', transcript: '第二份');
    expect((await store.latest(sourceSha256: source,
        rawSha256: raws))?.text, '第二份');
    expect((await Directory(dir.path + '/drafts').list().toList()).length, 2);
  });
}
