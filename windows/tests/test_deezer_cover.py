"""Joint artist/title provider chain, with synthetic or public-fixture metadata only."""
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import URLError
from urllib.parse import parse_qs, urlsplit

from online_cover import OnlineCover, RateLimiter, allowed_art_url
from test_online_cover import HTTP, Response, Clock, PNG, release, recording

CDN = 'https://cdn-images.dzcdn.net/images/cover/fixture/500x500.jpg'
OTHER_CDN = 'https://e-cdns-images.dzcdn.net/images/cover/fixture2/500x500.jpg'


def song(artist='Fixture Singer', title='Fixture Song', album='Fixture Album', identity=123, cover=CDN):
    return {'id': identity, 'title': title, 'title_short': 'Fixture Song',
            'link': 'https://www.deezer.com/track/' + str(identity),
            'artist': {'name': artist}, 'album': {'title': album, 'cover_big': cover},
            'preview': 'https://audio-do-not-request.example/preview.mp3'}


class DeezerJointCoverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.cancel = threading.Event()
        self.clock = Clock()
    def tearDown(self): self.temp.cleanup()
    def client(self, http):
        return OnlineCover(http=http, limiter=RateLimiter(clock=self.clock, wait=self.clock.wait), clock=self.clock, retry_wait=self.clock.wait)
    def fetch(self, http, album='Fixture Album'):
        return self.client(http).fetch('Fixture Song', 'Fixture Singer', album, self.root, self.cancel)

    def test_wrong_first_title_is_skipped_and_correct_second_result_is_used(self):
        http = HTTP(Response({'data': [song(title='Other Song'), song(identity=456)]}), Response(PNG))
        result = self.fetch(http)
        self.assertIsNotNone(result)
        self.assertEqual(result.provider, 'Deezer')
        self.assertEqual(result.track_url, 'https://www.deezer.com/track/456')
        self.assertEqual((result.artist, result.title), ('Fixture Singer', 'Fixture Song'))
        self.assertEqual(result.path.read_bytes(), PNG)
        self.assertEqual(urlsplit(http.calls[0][0]).hostname, 'api.deezer.com')
        query = parse_qs(urlsplit(http.calls[0][0]).query)
        self.assertEqual(query['limit'], ['10'])
        self.assertIn('Fixture Singer', query['q'][0])
        self.assertIn('Fixture Song', query['q'][0])
        self.assertFalse(any('preview' in url or 'audio-do-not-request' in url for url, _, _ in http.calls))
        sidecar = json.loads(result.path.with_suffix('.json').read_text())
        self.assertEqual(sidecar['provider'], 'Deezer')
        self.assertEqual(sidecar['matched_title'], 'Fixture Song')
        self.assertEqual(sidecar['matched_artist'], 'Fixture Singer')
        self.assertEqual(sidecar['track_url'], result.track_url)

    def test_wrong_singer_and_full_title_mismatch_cannot_use_title_short(self):
        http = HTTP(Response({'data': [song(artist='Other Singer'), song(title='Fixture Song (Live)')]}), Response({'recordings': []}))
        self.assertIsNone(self.fetch(http))
        self.assertTrue(all(urlsplit(url).hostname in ('api.deezer.com', 'musicbrainz.org') for url, _, _ in http.calls))

    def test_matching_album_wins_among_joint_matches(self):
        http = HTTP(Response({'data': [song(album='Other Album', identity=1), song(identity=2, cover=OTHER_CDN)]}), Response(PNG))
        result = self.fetch(http)
        self.assertEqual(result.track_url, 'https://www.deezer.com/track/2')
        self.assertEqual(http.calls[1][0], OTHER_CDN)

    def test_medium_image_can_be_used_when_big_missing(self):
        item = song()
        item['album'].pop('cover_big')
        item['album']['cover_medium'] = CDN
        http = HTTP(Response({'data': [item]}), Response(PNG))
        self.assertIsNotNone(self.fetch(http))
        self.assertEqual(http.calls[1][0], CDN)

    def test_unapproved_image_host_is_rejected_and_musicbrainz_fallback_is_joint(self):
        http = HTTP(Response({'data': [song(cover='https://evil.example/cover.jpg')]}), Response({'recordings': [recording()]}), Response(PNG))
        result = self.fetch(http)
        self.assertEqual(result.provider, 'MusicBrainz')
        self.assertIn('musicbrainz.org/recording/', result.track_url)
        query = parse_qs(urlsplit(http.calls[1][0]).query)['query'][0]
        self.assertIn('recording:', query)
        self.assertIn('Fixture Song', query)
        self.assertFalse(any('evil.example' in url for url, _, _ in http.calls))

    def test_musicbrainz_album_match_alone_can_never_supply_art(self):
        http = HTTP(Response({'data': []}), Response({'recordings': [recording(title='Other Song', releases=[release()])]}))
        self.assertIsNone(self.fetch(http))
        self.assertFalse(any('coverartarchive.org' in url for url, _, _ in http.calls))

    def test_deezer_failure_falls_back_to_musicbrainz_without_audio_requests(self):
        http = HTTP(URLError('offline provider'), Response({'recordings': [recording()]}), Response(PNG))
        self.assertIsNotNone(self.fetch(http))
        self.assertEqual(len(http.calls), 3)

    def test_new_cache_preserves_provider_metadata_without_network_on_reload(self):
        result = self.fetch(HTTP(Response({'data': [song()]}), Response(PNG)))
        self.assertIsNotNone(result)
        offline = HTTP()
        cached = self.fetch(offline)
        self.assertEqual(cached.provider, 'Deezer')
        self.assertEqual(cached.track_url, result.track_url)
        self.assertEqual(cached.source_url, result.source_url)
        self.assertFalse(offline.calls)

    def test_only_exact_https_deezer_cdn_hosts_are_allowed(self):
        self.assertTrue(allowed_art_url(CDN))
        self.assertTrue(allowed_art_url(OTHER_CDN))
        for url in ('http://cdn-images.dzcdn.net/a', 'https://cdn-images.dzcdn.net.evil.example/a', 'https://evil.dzcdn.net/a', 'https://cdn-images.dzcdn.net:444/a'):
            self.assertFalse(allowed_art_url(url))

    def test_public_jiang_fixture_rejects_wrong_first_title(self):
        fixture = Path('/tmp/bluewave-deezer-joint-result.json')
        if not fixture.exists():
            self.skipTest('optional captured public response unavailable')
        payload = json.loads(fixture.read_text())
        http = HTTP(Response(payload), Response(PNG))
        result = self.client(http).fetch('味道', '江智民', '声音', self.root, self.cancel)
        self.assertIsNotNone(result)
        self.assertEqual(result.track_url, 'https://www.deezer.com/track/1854913177')
        self.assertEqual(result.album, '声音')

    def test_legacy_caa_cache_layout_is_preserved_without_network(self):
        result = self.fetch(HTTP(Response({'data': []}), Response({'recordings': [recording()]}), Response(PNG)))
        sidecar = result.path.with_suffix('.json')
        metadata = json.loads(sidecar.read_text())
        sidecar.write_text(json.dumps({key: metadata[key] for key in ('source_url', 'final_url')}))
        offline = HTTP()
        cached = self.fetch(offline)
        self.assertEqual(cached.path, result.path)
        self.assertEqual(cached.provider, 'MusicBrainz')
        self.assertFalse(offline.calls)

    def test_deezer_redirect_cannot_leave_exact_provider_cdn_hosts(self):
        from online_cover import CoverRedirectHandler
        from urllib.request import Request
        for target in ('https://archive.org/cover.png', 'https://coverartarchive.org/a', 'https://api.deezer.com/a', 'https://cdn-images.dzcdn.net.evil.example/a'):
            with self.assertRaises(URLError):
                CoverRedirectHandler('deezer-art').redirect_request(Request(CDN), None, 307, 'redirect', {}, target)
        self.assertEqual(CoverRedirectHandler('deezer-art').redirect_request(Request(CDN), None, 307, 'redirect', {}, OTHER_CDN).full_url, OTHER_CDN)

    def test_deezer_retry_and_musicbrainz_fallback_share_one_metadata_rate_limit(self):
        from urllib.error import HTTPError
        clock = self.clock
        stamps = []
        class TimedHTTP(HTTP):
            def open(self, url, *, headers, timeout):
                if urlsplit(url).hostname in ('api.deezer.com', 'musicbrainz.org'):
                    stamps.append(clock.now)
                return super().open(url, headers=headers, timeout=timeout)
        http = TimedHTTP(HTTPError('https://api.deezer.com/search', 503, 'temporary', {}, None), Response({'data': []}), Response({'recordings': [recording()]}), Response(PNG))
        self.assertIsNotNone(self.fetch(http))
        self.assertEqual(len(stamps), 3)
        self.assertTrue(all(b - a >= .999 for a, b in zip(stamps, stamps[1:])), stamps)
        self.assertGreaterEqual(stamps[1] - stamps[0], 1.2)
