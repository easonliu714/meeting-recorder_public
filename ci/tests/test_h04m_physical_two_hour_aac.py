"""H04M host-only physical AAC 2h integration, NOT Android native or Groq E2E.

Uses ffmpeg/ffprobe to generate and remux actual ISO-BMFF AAC bytes. This
checks independent physical-byte and time-budget assumptions; Android's
MediaExtractor/MediaMuxer, microphone fidelity, quota and STT remain untested.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


def _run(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, check=False)
    if result.returncode:
        raise AssertionError(f"host media fixture command failed: {args[0]}: {result.stderr[-400:]}")
    return result.stdout


def _digest(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _probe(path):
    data = json.loads(_run('ffprobe', '-v', 'error', '-show_entries',
                           'format=duration,size:stream=codec_name',
                           '-of', 'json', str(path)))
    if len(data['streams']) != 1 or data['streams'][0]['codec_name'] != 'aac':
        raise ValueError('AAC_CODEC_OR_TRACK_HOLD')
    return float(data['format']['duration']), int(data['format']['size'])


def _require_window(path, expected_seconds):
    duration, size = _probe(path)
    if not 0 < size < 22_500_000:
        raise ValueError('PHYSICAL_AAC_WIRE_BYTES_HOLD')
    if abs(duration - expected_seconds) > 0.15:
        raise ValueError('PHYSICAL_AAC_WIRE_DURATION_HOLD')
    return size


class TestH04MHostAacToolAvailability(unittest.TestCase):
    def test_ci_must_not_skip_physical_aac_regression(self):
        # GitHub Actions must execute the real-byte host regression; a local
        # developer without ffmpeg may still skip the media-only tests.
        import os
        if os.environ.get('GITHUB_ACTIONS', '').lower() == 'true':
            self.assertTrue(shutil.which('ffmpeg') and shutil.which('ffprobe'),
                            'H04M_PHYSICAL_AAC_CI_TOOL_MISSING')


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'),
                     'host physical AAC test requires ffmpeg and ffprobe')
class TestH04MPhysicalTwoHourAac(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='h04m_physical_aac_')
        cls.root = Path(cls.temp.name)
        cls.parts = []
        for i in (1, 2):
            part = cls.root / f'part_{i}.m4a'
            _run('ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
                 '-i', 'anullsrc=r=8000:cl=mono', '-t', '3600', '-c:a', 'aac',
                 '-b:a', '12k', '-metadata', f'title=H04M_PHYSICAL_PART_{i}',
                 '-y', str(part))
            cls.parts.append(part)
        cls.original_shas = [_digest(p) for p in cls.parts]

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def _window(self, part, start, end, suffix):
        path = self.root / f'wire_{suffix}.m4a'
        _run('ffmpeg', '-hide_banner', '-loglevel', 'error',
             '-ss', str(start), '-i', str(part), '-t', str(end - start),
             '-map', '0:a:0', '-c', 'copy', '-y', str(path))
        return path

    def test_two_real_hour_parts_twelve_aac_wires_global_clock_and_sha(self):
        self.assertNotEqual(*self.original_shas)
        timeline = []
        for part_index, part in enumerate(self.parts):
            self.assertAlmostEqual(_probe(part)[0], 3600, delta=0.15)
            for chunk in range(6):
                core_start = chunk * 600
                core_end = core_start + 600
                wire_start = max(0, core_start - 2)
                self.assertLessEqual(core_end - core_start, 700)
                self.assertEqual(core_start - wire_start, 0 if chunk == 0 else 2)
                wire = self._window(part, wire_start, core_end,
                                    f'{part_index}_{chunk}')
                self.assertGreater(_require_window(wire, core_end - wire_start), 0)
                timeline.append((part_index * 3600 + core_start,
                                 part_index * 3600 + core_end))
        self.assertEqual(len(timeline), 12)
        self.assertEqual(timeline[0], (0, 600))
        self.assertEqual(timeline[6], (3600, 4200))
        self.assertEqual(timeline[-1], (6600, 7200))
        self.assertTrue(all(a[1] == b[0] for a, b in zip(timeline, timeline[1:])))
        self.assertEqual([_digest(p) for p in self.parts], self.original_shas)

    def test_truncated_tail_cannot_masquerade_as_full_window(self):
        clipped = self._window(self.parts[0], 3599, 4201, 'truncated')
        with self.assertRaisesRegex(ValueError, 'PHYSICAL_AAC_WIRE_DURATION_HOLD'):
            _require_window(clipped, 602)
        self.assertEqual([_digest(p) for p in self.parts], self.original_shas)

    def test_physical_wire_sha_detects_post_stage_tamper(self):
        wire = self._window(self.parts[1], 598, 1200, 'tamper')
        _require_window(wire, 602)
        before = _digest(wire)
        with wire.open('r+b') as stream:
            stream.seek(32)
            old = stream.read(1)
            stream.seek(32)
            stream.write(bytes([old[0] ^ 1]))
        self.assertNotEqual(_digest(wire), before)
        self.assertEqual([_digest(p) for p in self.parts], self.original_shas)


if __name__ == '__main__':
    unittest.main()
