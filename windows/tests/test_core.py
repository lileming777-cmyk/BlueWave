import json
import math
from pathlib import Path
import struct
import tempfile
import unittest
import wave

from core import Library, Track, parse_lrc, format_lrc, discover_audio, probe, decoder_command, decode_bytes, tool_path, read_lyrics


class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.lib = Library(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def test_deduplicate_playlist_persistence_and_reorder(self):
        a = Track.from_path(self.root / 'a.flac', title='A')
        b = Track.from_path(self.root / 'b.flac', title='B')
        self.lib.add([a, b, a])
        self.assertEqual(len(self.lib.tracks), 2)
        pid = self.lib.create_playlist('旅途')
        self.lib.playlist_add(pid, [a.id, b.id, a.id])
        self.lib.playlist_reorder(pid, [b.id, a.id])
        self.lib.rename_playlist(pid, '旅行')
        self.lib.tracks[a.id].favorite = True
        self.lib.save()
        loaded = Library(self.root)
        self.assertEqual(loaded.playlists[pid]['tracks'], [b.id, a.id])
        self.assertEqual(loaded.playlists[pid]['name'], '旅行')
        self.assertTrue(loaded.tracks[a.id].favorite)
        self.lib.playlist_remove(pid, [a.id])
        self.assertEqual(self.lib.playlists[pid]['tracks'], [b.id])
        self.lib.delete_playlist(pid)
        self.assertFalse(self.lib.playlists)

    def test_clear_creates_backup_and_never_deletes_music(self):
        song = self.root / 'original.wav'
        song.write_bytes(b'original music')
        a = Track.from_path(song)
        self.lib.add([a])
        self.lib.save()
        backup = self.lib.clear()
        self.assertTrue(backup.exists())
        self.assertEqual(len(json.loads(backup.read_text())['tracks']), 1)
        self.assertEqual(song.read_bytes(), b'original music')
        self.assertFalse(Library(self.root).tracks)

    def test_corrupt_library_is_preserved_and_not_overwritten(self):
        path = self.root / 'library.json'
        path.write_text('{broken')
        with self.assertRaises(ValueError):
            Library(self.root)
        self.assertEqual(path.read_text(), '{broken')

    def test_legacy_auto_lyrics_preference_is_not_retained(self):
        self.lib.save()
        payload = json.loads(self.lib.path.read_text(encoding='utf-8'))
        payload['settings']['auto_lyrics'] = True
        self.lib.path.write_text(json.dumps(payload), encoding='utf-8')
        loaded = Library(self.root)
        self.assertNotIn('auto_lyrics', loaded.settings)
        loaded.save()
        self.assertNotIn('auto_lyrics', json.loads(loaded.path.read_text(encoding='utf-8'))['settings'])

    def test_remove_track_cleans_playlists_only(self):
        path = self.root / 'song.wav'
        path.write_bytes(b'original')
        track = Track.from_path(path)
        self.lib.add([track])
        pid = self.lib.create_playlist('test')
        self.lib.playlist_add(pid, [track.id])
        self.lib.remove([track.id])
        self.assertEqual(self.lib.playlists[pid]['tracks'], [])
        self.assertTrue(path.exists())


class LyricsTests(unittest.TestCase):
    def test_lrc_multiple_timestamps_offset_and_roundtrip(self):
        lyrics = parse_lrc('[ar:artist]\n[offset:-500]\n[00:01.50][01:02.003]hello\n[00:00.10]start')
        self.assertEqual(lyrics, [(0.0, 'start'), (1.0, 'hello'), (61.503, 'hello')])
        self.assertEqual(parse_lrc(format_lrc([(1.23, '你好')])), [(1.23, '你好')])

    def test_sidecar_precedes_embedded_lyrics(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'song.wav'
            path.with_suffix('.lrc').write_text('[00:01.00]sidecar', encoding='utf-8')
            track = Track.from_path(path, lyrics='embedded')
            text, origin = read_lyrics(track)
            self.assertIn('sidecar', text)
            self.assertEqual(origin, '同名 LRC')


class DecodeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / '测试 song.wav'
        with wave.open(str(self.path), 'wb') as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(16000)
            out.writeframes(b''.join(struct.pack('<h', int(math.sin(i * 0.12) * 12000)) for i in range(8000)))

    def tearDown(self):
        self.tmp.cleanup()

    def test_probe_and_decode_real_pcm(self):
        track = probe(self.path)
        self.assertAlmostEqual(track.duration, 0.5, places=2)
        self.assertEqual(track.sample_rate, 16000)
        self.assertEqual(track.channels, 1)
        pcm = decode_bytes(track, rate=48000)
        self.assertEqual(len(pcm), 24000 * 2 * 4)
        self.assertGreater(max(abs(x[0]) for x in struct.iter_unpack('<f', pcm)), .1)

    def test_decoder_command_uses_argument_list_and_normalizes_when_enabled(self):
        track = Track.from_path(self.path)
        command = decoder_command(track, 44100, start=2.5, normalize=True)
        self.assertIn(str(self.path.resolve()), command)
        self.assertIn('loudnorm=I=-18:TP=-1.5:LRA=11', command)
        self.assertIn('f32le', command)
        self.assertEqual(command[command.index('-ss') + 1], '2.500000')

    def test_discovery_deduplicates_and_ignores_non_audio(self):
        (self.path.parent / 'ignore.txt').write_text('x')
        self.assertEqual(discover_audio([self.path.parent, self.path]), [self.path.resolve()])

class CoverTests(unittest.TestCase):
    def test_embedded_cover_is_extracted_as_png(self):
        import base64
        import subprocess
        from core import cover_path, process_options
        encoders = subprocess.run([tool_path('ffmpeg'), '-hide_banner', '-encoders'], capture_output=True, **process_options()).stdout
        if b' png ' not in encoders:
            self.skipTest('local FFmpeg predates PNG encoder; Windows release build enables png')
        # Create a real FLAC, then insert its standard PICTURE metadata block.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wav = root / 'source.wav'
            with wave.open(str(wav), 'wb') as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(16000)
                out.writeframes(b'\0\0' * 1600)
            flac = root / 'song.flac'
            subprocess.run([tool_path('ffmpeg'), '-nostdin', '-loglevel', 'error', '-i', str(wav), '-c:a', 'flac', str(flac)], check=True, **process_options())
            png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4uoAAAAASUVORK5CYII=')
            mime = b'image/png'
            picture = struct.pack('>II', 3, len(mime)) + mime + struct.pack('>IIIII', 0, 1, 1, 16, 0) + struct.pack('>I', len(png)) + png
            raw = flac.read_bytes()
            # First streaminfo block is 34 bytes; keep its flags and insert non-last picture after it.
            first_end = 8 + int.from_bytes(raw[5:8], 'big')
            flac.write_bytes(raw[:first_end] + bytes([6]) + len(picture).to_bytes(3, 'big') + picture + raw[first_end:])
            cover = cover_path(probe(flac), root / 'cache')
            self.assertIsNotNone(cover)
            self.assertEqual(cover.suffix, '.png')
            self.assertTrue(cover.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'))

    def test_folder_cover_fallback(self):
        from core import cover_path
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ((root / 'cover.jpg').resolve()).write_bytes(b'cover')
            track = Track.from_path(root / 'missing.wav')
            self.assertEqual(cover_path(track, root / 'cache'), (root / 'cover.jpg').resolve())


class FilenameMetadataTests(unittest.TestCase):
    def test_real_untagged_wav_filename_variants(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name, title, artist in [
                ('01 趁早 -孙露.wav', '趁早', '孙露'),
                ('01 Fixture Singer - Fixture Song.wav', 'Fixture Song', 'Fixture Singer'),
                ('01 - Fixture Singer - Fixture Song.wav', 'Fixture Song', 'Fixture Singer'),
                ('Fixture Singer - Fixture Song.wav', 'Fixture Song', 'Fixture Singer'),
                ('01. Fixture Singer - Fixture Song.wav', 'Fixture Song', 'Fixture Singer'),
                ('01 Just a Song.wav', 'Just a Song', '未知艺人'),
            ]:
                with self.subTest(name=name):
                    path = root / name
                    with wave.open(str(path), 'wb') as output:
                        output.setnchannels(1)
                        output.setsampwidth(2)
                        output.setframerate(16000)
                        output.writeframes(b'\0\0' * 1600)
                    track = probe(path)
                    self.assertEqual(track.title, title)
                    self.assertEqual(track.artist, artist)

    def test_embedded_title_artist_override_filename_guess(self):
        import subprocess
        from core import process_options
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'input.wav'
            with wave.open(str(source), 'wb') as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(16000)
                output.writeframes(b'\0\0' * 1600)
            destination = root / '01 Filename Title -Filename Artist.wav'
            subprocess.run([tool_path('ffmpeg'), '-nostdin', '-v', 'error', '-i', str(source), '-c:a', 'pcm_s16le', '-metadata', 'title=Tagged Title', '-metadata', 'artist=Tagged Artist', str(destination)], check=True, **process_options())
            track = probe(destination)
            self.assertEqual(track.title, 'Tagged Title')
            self.assertEqual(track.artist, 'Tagged Artist')


if __name__ == '__main__':
    unittest.main()
