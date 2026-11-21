import 'package:flutter_test/flutter_test.dart';
import 'package:groq_stt_lab/lab_debug_log.dart';

void main() {
  test('exported filename is derived from actual APK identity', () {
    expect(LabBuildInfo.exportNameStem, 'groq_lab_v0_4_26_build31');
  });

  test('exported diagnostic is versioned, bounded and never includes paths', () {
    final journal = LabDebugJournal();
    journal.record('SOURCE_PROBE_OK',
        {'kind': 'aacM4a', 'bytes': 10240, 'path': '/secret/owner.wav'});
    journal.record('SOURCE_PROBE_HOLD',
        {'code': 'LAB_AUDIO_UNSUPPORTED_CODEC', 'token': 'Bearer secret'});
    final text = journal.snapshot();
    expect(text, contains('build_version=0.4.26+31'));
    expect(text, contains('source_commit='));
    expect(text, contains('app_id=com.example.meeting_recorder.public_lab_v31.groq_stt_lab'));
    expect(text, contains('SOURCE_PROBE_OK'));
    expect(text, contains('code=LAB_AUDIO_UNSUPPORTED_CODEC'));
    expect(text, contains('path=REDACTED'));
    expect(text, contains('token=REDACTED'));
    expect(text, isNot(contains('owner.wav')));
    expect(text, isNot(contains('Bearer secret')));
  });

  test('native PCM timing counters remain numeric, no raw path or audio', () {
    final journal = LabDebugJournal();
    journal.record('STAGE_PCM_WINDOW_METRICS', {
      'expected_frames': 240000,
      'decoded_frames': 239850,
      'first_pts_us': 23000,
      'last_pts_us': 14990000,
      'window_start_us': 0,
      'window_end_us': 15000000,
      'source_duration_us': 15000000,
      'leading_pts_limit_us': 66000,
      'source_sample_rate_hz': 16000,
      'raw_audio': '/storage/private/owner.wav',
    });
    final text = journal.snapshot();
    expect(text, contains('expected_frames=240000'));
    expect(text, contains('first_pts_us=23000'));
    expect(text, contains('leading_pts_limit_us=66000'));
    expect(text, contains('source_sample_rate_hz=16000'));
    expect(text, contains('raw_audio=REDACTED'));
    expect(text, isNot(contains('owner.wav')));
  });

  test('journal never grows beyond bounded event budget', () {
    final journal = LabDebugJournal();
    for (var i = 0; i < 410; i++) {
      journal.record('STAGE_CHUNK_OK', {'index': i});
    }
    final text = journal.snapshot();
    expect(text, contains('event_count=350'));
    expect(text, isNot(contains('index=0\n')));
    expect(text, contains('index=409'));
  });

  test('failure normalization hides private paths and raw exceptions', () {
    expect(LabDebugJournal.failureCode(
        StateError('SOURCE_IN_CACHE')), 'SOURCE_IN_CACHE');
    expect(LabDebugJournal.failureCode(
        FormatException('NOT_RIFF_WAVE')), 'NOT_RIFF_WAVE');
    expect(LabDebugJournal.failureCode(
        Exception('/storage/private/owner.wav')), 'UNEXPECTED_OPERATION_HOLD');
  });
}
