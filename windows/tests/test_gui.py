"""Real Qt event-loop checks. Run with QT_QPA_PLATFORM=offscreen in CI."""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from pathlib import Path
import tempfile
import time
import unittest
import wave
from unittest.mock import patch

from PySide6.QtWidgets import QApplication
from bluewave import Window
from core import Library, Track


class GuiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.path = self.root / '音乐.wav'
        with wave.open(str(self.path), 'wb') as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(16000)
            out.writeframes(b'\0\0' * 1600)
        self.library = Library(self.root / 'profile')
        self.window = Window(self.library)
        self.window.show()
        self.app.processEvents()

    def tearDown(self):
        self.window.close()
        self.window.pool.waitForDone(10000)
        self.app.processEvents()
        self.temp.cleanup()

    def wait_import(self):
        end = time.monotonic() + 10
        while self.window.import_job and time.monotonic() < end:
            self.app.processEvents()
            time.sleep(.01)
        self.assertIsNone(self.window.import_job)

    def test_import_search_playlist_reorder_and_restart(self):
        self.window.import_paths([self.path])
        self.wait_import()
        self.assertEqual(self.window.table.topLevelItemCount(), 1)
        identity = next(iter(self.library.tracks))
        other = Track.from_path(self.root / 'other.flac', title='Other')
        self.library.add([other])
        playlist = self.library.create_playlist('测试')
        self.library.playlist_add(playlist, [identity, other.id])
        self.window.refresh_navigation(playlist)
        self.window.move_playlist([identity], 1)
        self.assertEqual(self.library.playlists[playlist]['tracks'], [other.id, identity])
        self.window.search.setText('音乐')
        self.app.processEvents()
        self.assertEqual(self.window.visible_ids(), [identity])
        self.window.favorite([identity])
        self.assertTrue(Library(self.library.root).tracks[identity].favorite)

    def test_failed_replacement_keeps_previous_library_and_original_music(self):
        original = Track.from_path(self.path)
        self.library.add([original])
        invalid = self.root / 'broken.mp3'
        invalid.write_text('not music')
        self.window.import_paths([invalid], replace=True)
        self.wait_import()
        self.assertIn(original.id, self.library.tracks)
        self.assertTrue(self.path.exists())
        self.assertIn('原曲库已保留', self.window.status.text())

    def test_picker_cancel_never_changes_library(self):
        original = Track.from_path(self.path)
        self.library.add([original])
        with patch.object(self.window, 'pick_paths', return_value=[]):
            self.window.replace_import(True)
        self.assertIn(original.id, self.library.tracks)

    def test_replacement_target_deleted_mid_import_does_not_clear_library(self):
        original = Track.from_path(self.path)
        self.library.add([original])
        playlist = self.library.create_playlist('gone')
        self.window.refresh_navigation(playlist)
        self.window.import_paths([self.path], replace=True)
        self.library.delete_playlist(playlist)
        self.wait_import()
        self.assertIn(original.id, self.library.tracks)
        self.assertIn('已删除', self.window.status.text())

    def test_queue_removal_does_not_delete_original(self):
        original = Track.from_path(self.path)
        self.library.add([original])
        self.window.queue = [original.id, original.id]
        self.window.queue_index = 0
        self.window.refresh_queue()
        self.window.queue_list.setCurrentRow(1)
        self.window.remove_queue()
        self.assertEqual(self.window.queue, [original.id])
        self.assertTrue(self.path.exists())

    def test_successful_library_replacement_resets_playback_and_favorite(self):
        original = Track.from_path(self.root / 'old.wav')
        self.library.add([original])
        self.window.current = original
        self.window.queue = [original.id]
        self.window.queue_index = 0
        self.window.import_paths([self.path], replace=True)
        self.wait_import()
        self.assertNotIn(original.id, self.library.tracks)
        self.assertIsNone(self.window.current)
        self.assertEqual(self.window.queue, [])
        self.assertEqual(self.window.queue_index, -1)
        self.window.favorite_current()
        self.assertEqual(self.window.now.text(), '尚未播放\n导入本地音乐，随时开始')

    def test_removing_current_record_resets_playback(self):
        from PySide6.QtWidgets import QMessageBox
        original = Track.from_path(self.path)
        self.library.add([original])
        self.window.current = original
        self.window.queue = [original.id]
        self.window.queue_index = 0
        with patch.object(QMessageBox, 'question', return_value=QMessageBox.Yes):
            self.window.remove_tracks([original.id], False)
        self.assertIsNone(self.window.current)
        self.window.favorite_current()
        self.assertTrue(self.path.exists())

    def test_smoke_runs_without_console_streams(self):
        from bluewave import smoke_test
        with patch('sys.stdout', None), patch('sys.stderr', None):
            self.assertEqual(smoke_test(self.app), 0)

    def test_legacy_transcript_is_ignored_without_deleting_cache(self):
        import hashlib
        track = Track.from_path(self.path)
        self.window.current = track
        stat = self.path.stat()
        key = hashlib.sha256(f'{track.id}:{stat.st_size}:{stat.st_mtime_ns}:base-v1'.encode()).hexdigest()
        cache = self.library.root / 'Transcripts' / (key + '.lrc')
        cache.parent.mkdir()
        cache.write_text('[00:01.00]旧自动听写结果', encoding='utf-8')
        self.window.load_lyrics()
        self.assertEqual(self.window.lyric_text, '')
        self.assertEqual(self.window.lyric_list.count(), 0)
        self.assertIn('没有本地歌词', self.window.lyric_origin.text())
        self.assertEqual(cache.read_text(encoding='utf-8'), '[00:01.00]旧自动听写结果')

    def test_missing_lyrics_never_start_a_background_recognition_task(self):
        self.window.current = Track.from_path(self.path)
        with patch.object(self.window, 'start_job', side_effect=AssertionError('无歌词时不应启动后台识别任务')):
            self.window.load_lyrics()
        self.assertEqual(self.window.lyric_text, '')
        self.assertIn('没有本地歌词', self.window.lyric_origin.text())

    def test_embedded_and_sidecar_lyrics_remain_visible_and_exportable(self):
        from PySide6.QtWidgets import QFileDialog
        track = Track.from_path(self.path, lyrics='[00:02.00]内嵌歌词')
        self.window.current = track
        self.window.load_lyrics()
        self.assertEqual(self.window.lyric_origin.text(), '内嵌歌词')
        self.assertEqual(self.window.lyric_lines, [(2.0, '内嵌歌词')])
        sidecar = self.path.with_suffix('.lrc')
        sidecar.write_text('[00:03.00]本地歌词', encoding='utf-8')
        self.window.load_lyrics()
        self.assertEqual(self.window.lyric_origin.text(), '同名 LRC')
        self.assertEqual(self.window.lyric_lines, [(3.0, '本地歌词')])
        exported = self.root / 'exported.lrc'
        with patch.object(QFileDialog, 'getSaveFileName', return_value=(str(exported), '歌词 (*.lrc)')):
            self.window.export_lyrics()
        self.assertEqual(exported.read_text(encoding='utf-8'), '[00:03.00]本地歌词')

    def test_smoke_requires_only_audio_tools(self):
        import core
        from bluewave import smoke_test
        original = core.tool_path
        def audio_tool(name):
            if name not in ('ffmpeg', 'ffprobe'):
                raise AssertionError('smoke 不应需要语音识别工具或模型：' + name)
            return original(name)
        with patch('core.tool_path', side_effect=audio_tool), patch('bluewave.tool_path', side_effect=audio_tool, create=True):
            self.assertEqual(smoke_test(self.app), 0)

    def test_import_cancel_keeps_existing_library(self):
        original = Track.from_path(self.root / 'existing.wav')
        self.library.add([original])
        self.window.import_paths([self.path])
        self.window.cancel_import()
        self.wait_import()
        self.assertEqual(set(self.library.tracks), {original.id})
        self.assertTrue(self.path.exists())
        self.assertIn('取消', self.window.status.text())

    def wait_cover(self):
        deadline = time.monotonic() + 10
        while self.window.cover_job and time.monotonic() < deadline:
            self.app.processEvents()
            time.sleep(.01)
        self.assertIsNone(self.window.cover_job)

    def cover_fixture(self):
        from PySide6.QtGui import QImage
        from PySide6.QtCore import Qt
        image = QImage(2, 2, QImage.Format_RGB32)
        image.fill(Qt.blue)
        path = self.root / 'fixture-cover.png'
        self.assertTrue(image.save(str(path)))
        return path

    def test_cover_download_occurs_only_for_current_track_without_local_art(self):
        from unittest.mock import Mock
        from online_cover import CoverResult
        first = Track.from_path(self.path, artist='Fixture Singer', album='Fixture Album')
        other = Track.from_path(self.root / 'other.wav', artist='Other Singer')
        self.library.add([first, other])
        client = Mock()
        client.fetch.return_value = CoverResult(self.cover_fixture(), 'https://coverartarchive.org/fixture')
        self.window.online_cover = client
        self.window.refresh_tracks()
        self.assertFalse(client.fetch.called)
        self.window.current = first
        with patch('bluewave.cover_path', return_value=None):
            self.window.load_cover(first)
            self.wait_cover()
        client.fetch.assert_called_once()
        self.assertEqual(client.fetch.call_args.args[:3], (first.title, first.artist, first.album))
        self.assertFalse(self.window.cover.pixmap().isNull())
        self.assertIn('coverartarchive.org', self.window.cover.toolTip())

    def test_local_cover_prevents_online_request_and_disabled_setting_prevents_request(self):
        from unittest.mock import Mock
        track = Track.from_path(self.path, artist='Fixture Singer')
        self.window.current = track
        client = Mock()
        self.window.online_cover = client
        with patch('bluewave.cover_path', return_value=self.cover_fixture()):
            self.window.load_cover(track)
            self.wait_cover()
        self.assertFalse(client.fetch.called)
        self.library.settings['online_covers'] = False
        with patch('bluewave.cover_path', return_value=None):
            self.window.load_cover(track)
            self.wait_cover()
        self.assertFalse(client.fetch.called)

    def test_cancelled_old_cover_cannot_fill_new_track(self):
        import threading
        from online_cover import CoverResult
        started, release = threading.Event(), threading.Event()
        image = self.cover_fixture()
        class SlowClient:
            def fetch(self, *args):
                started.set()
                release.wait(5)
                return CoverResult(image, 'https://coverartarchive.org/old')
        old = Track.from_path(self.path, artist='Fixture Singer')
        new = Track.from_path(self.root / 'new.wav', artist='Other Singer')
        self.window.online_cover = SlowClient()
        self.window.current = old
        with patch('bluewave.cover_path', return_value=None):
            self.window.load_cover(old)
            self.assertTrue(started.wait(5))
            self.window.current = new
            self.window.cancel_job(self.window.cover_job)
            self.window.cover_job = None
            release.set()
            self.window.pool.waitForDone(5000)
            self.app.processEvents()
        self.assertEqual(self.window.cover.text(), old.title)
        self.assertNotIn('/old', self.window.cover.toolTip())

    def test_online_cover_setting_defaults_on_and_persists(self):
        from bluewave import Settings
        self.assertTrue(self.library.settings['online_covers'])
        dialog = Settings(self.library.settings, self.window)
        dialog.online_covers.setChecked(False)
        self.library.settings.update(dialog.values())
        self.library.save()
        self.assertFalse(Library(self.library.root).settings['online_covers'])

    def test_actual_playback_entry_retries_cover_after_stop_on_same_track(self):
        class SilentSession:
            def __init__(self, track, settings, start, completed):
                self.position, self.token = start, 'test-session'
            def start(self): pass
            def cancel(self): pass
            def pause(self, paused): pass
        track = Track.from_path(self.path, artist='Fixture Singer')
        self.library.add([track])
        with patch('bluewave.AudioSession', SilentSession), patch.object(self.window, 'load_cover') as lookup:
            self.window.play_track(track.id)
            self.window.stop()
            self.window.play_track(track.id)
        self.assertEqual(lookup.call_count, 2)
        self.assertTrue(all(call.args == (track,) for call in lookup.call_args_list))

    def test_current_legacy_unknown_artist_is_reprobed_without_changing_identity_or_playlist(self):
        import shutil
        from unittest.mock import Mock
        path = self.root / '01 趁早 -孙露.wav'
        shutil.copy2(self.path, path)
        legacy = Track.from_path(path, favorite=True)
        legacy.id = 'stable-import-id'
        self.library.add([legacy])
        playlist = self.library.create_playlist('保留列表')
        self.library.playlist_add(playlist, [legacy.id])
        self.window.current = legacy
        client = Mock()
        client.fetch.return_value = None  # Metadata refresh must persist even when online art is unavailable.
        self.window.online_cover = client
        with patch('bluewave.cover_path', return_value=None):
            self.window.load_cover(legacy)
            self.wait_cover()
        refreshed = self.library.tracks[legacy.id]
        self.assertEqual((refreshed.title, refreshed.artist), ('趁早', '孙露'))
        self.assertTrue(refreshed.favorite)
        self.assertEqual(refreshed.id, legacy.id)
        self.assertEqual(self.library.playlists[playlist]['tracks'], [legacy.id])
        self.assertEqual(client.fetch.call_args.args[:2], ('趁早', '孙露'))
        self.assertIn('孙露', self.window.now.text())
        self.assertEqual(Library(self.library.root).tracks[legacy.id].artist, '孙露')

    def test_metadata_refresh_preserves_paused_button_state(self):
        track = Track.from_path(self.path)
        self.window.paused = True
        self.window.update_track_display(track)
        self.assertEqual(self.window.play_button.text(), '播放')

    def test_no_cover_card_displays_song_title_instead_of_music_symbol(self):
        from unittest.mock import Mock
        track = Track.from_path(self.path, title='Fixture Song', artist='Fixture Singer')
        self.window.current = track
        self.window.online_cover = Mock()
        self.window.online_cover.fetch.return_value = None
        with patch('bluewave.cover_path', return_value=None):
            self.window.load_cover(track)
            self.wait_cover()
        self.assertEqual(self.window.cover.text(), 'Fixture Song')
        self.assertTrue(self.window.cover.wordWrap())
        self.window.reset_current()
        self.assertEqual(self.window.cover.text(), '♪')

    def test_same_known_album_uses_resolved_sibling_without_poisoning_own_cover(self):
        from unittest.mock import Mock
        from online_cover import CoverResult
        current = Track.from_path(self.path, title='Current Song', artist='Fixture Singer', album='Fixture Album')
        sibling = Track.from_path(self.root / 'sibling.wav', title='Other Song', artist=current.artist, album=current.album)
        self.library.add([current, sibling])
        self.window.current = current
        self.window.album_artworks[sibling.id] = CoverResult(self.cover_fixture(), '')
        client = Mock()
        client.fetch.return_value = None
        self.window.online_cover = client
        with patch('bluewave.cover_path', return_value=None):
            self.window.load_cover(current)
            self.wait_cover()
            self.assertFalse(self.window.cover.pixmap().isNull())
            self.assertIn('同专辑', self.window.cover.toolTip())
            self.assertNotIn(current.id, self.window.album_artworks)
            self.assertFalse((self.library.root / 'Covers' / (current.id + '.png')).exists())
            client.fetch.return_value = CoverResult(self.cover_fixture(), 'https://cdn-images.dzcdn.net/own.png', provider='Deezer')
            self.window.load_cover(current)
            self.wait_cover()
        self.assertEqual(client.fetch.call_count, 2)
        self.assertNotIn('同专辑', self.window.cover.toolTip())
        self.assertEqual(self.window.album_artworks[current.id].provider, 'Deezer')

    def test_cold_sibling_cache_and_directory_art_can_supply_album_fallback(self):
        from unittest.mock import Mock
        import shutil
        current = Track.from_path(self.path, title='Current Song', artist='Fixture Singer', album='Fixture Album')
        sibling = Track.from_path(self.root / 'other-directory' / 'sibling.wav', title='Other Song', artist=current.artist, album=current.album)
        self.library.add([current, sibling])
        self.window.current = current
        client = Mock()
        client.fetch.return_value = None
        self.window.online_cover = client
        image = self.cover_fixture()
        cached = self.library.root / 'Covers' / (sibling.id + '.png')
        cached.parent.mkdir(parents=True)
        shutil.copy2(image, cached)
        with patch('bluewave.cover_path', return_value=None):
            self.window.load_cover(current)
            self.wait_cover()
            self.assertFalse(self.window.cover.pixmap().isNull())
            self.assertIn('同专辑', self.window.cover.toolTip())
            cached.unlink()
            directory_image = Path(sibling.path).parent / 'folder.png'
            directory_image.parent.mkdir()
            shutil.copy2(image, directory_image)
            self.window.load_cover(current)
            self.wait_cover()
            self.assertFalse(self.window.cover.pixmap().isNull())
            directory_image.unlink()
            from test_online_cover import HTTP, Response, PNG, recording, Clock
            from online_cover import OnlineCover, RateLimiter
            clock = Clock()
            previous_session = OnlineCover(http=HTTP(Response({'data': []}), Response({'recordings': [recording(title=sibling.title)]}), Response(PNG)), limiter=RateLimiter(clock=clock, wait=clock.wait), clock=clock)
            self.assertIsNotNone(previous_session.fetch(sibling.title, sibling.artist, sibling.album, self.library.root / 'Covers', __import__('threading').Event()))
            self.window.load_cover(current)
            self.wait_cover()
            self.assertFalse(self.window.cover.pixmap().isNull())
            self.assertIn('同专辑', self.window.cover.toolTip())
        self.assertEqual(client.fetch.call_count, 3)  # Only current metadata; sibling is disk-only.
        self.assertTrue(all(call.args[:2] == (current.title, current.artist) for call in client.fetch.call_args_list))

    def test_unknown_album_or_different_artist_never_shares_sibling_art(self):
        from unittest.mock import Mock
        from online_cover import CoverResult
        for album, sibling_artist in [('未知专辑', 'Fixture Singer'), ('Fixture Album', 'Different Singer')]:
            with self.subTest(album=album):
                self.window.album_artworks.clear()
                self.library.tracks.clear()
                current = Track.from_path(self.path, title='Current Song', artist='Fixture Singer', album=album)
                sibling = Track.from_path(self.root / 'sibling.wav', title='Other Song', artist=sibling_artist, album=album)
                self.library.add([current, sibling])
                self.window.current = current
                self.window.album_artworks[sibling.id] = CoverResult(self.cover_fixture(), '')
                self.window.online_cover = Mock()
                self.window.online_cover.fetch.return_value = None
                with patch('bluewave.cover_path', return_value=None):
                    self.window.load_cover(current)
                    self.wait_cover()
                self.assertEqual(self.window.cover.text(), 'Current Song')

    def test_disabled_online_still_prefers_own_disk_cache_before_album_fallback(self):
        from unittest.mock import Mock
        from online_cover import OnlineCover, RateLimiter, CoverResult
        from test_deezer_cover import song
        from test_online_cover import HTTP, Response, PNG, Clock
        current = Track.from_path(self.path, title='Fixture Song', artist='Fixture Singer', album='Fixture Album')
        sibling = Track.from_path(self.root / 'sibling.wav', title='Other Song', artist=current.artist, album=current.album)
        self.library.add([current, sibling])
        self.window.current = current
        self.window.album_artworks[sibling.id] = CoverResult(self.cover_fixture(), '')
        clock = Clock()
        previous_session = OnlineCover(http=HTTP(Response({'data': [song()]}), Response(PNG)), limiter=RateLimiter(clock=clock, wait=clock.wait), clock=clock)
        own = previous_session.fetch(current.title, current.artist, current.album, self.library.root / 'Covers', __import__('threading').Event())
        self.assertIsNotNone(own)
        self.library.settings['online_covers'] = False
        client = Mock()
        self.window.online_cover = client
        with patch('bluewave.cover_path', return_value=None):
            self.window.load_cover(current)
            self.wait_cover()
        self.assertFalse(client.fetch.called)
        self.assertEqual(self.window.album_artworks[current.id].path, own.path)
        self.assertNotIn('同专辑', self.window.cover.toolTip())
