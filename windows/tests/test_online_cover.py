"""Synthetic metadata and in-memory HTTP fixtures only; never query private songs."""
import struct
import zlib
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request

from online_cover import OnlineCover, RateLimiter, CoverRedirectHandler, allowed_art_url, normalized

def png_chunk(name, payload):
    return struct.pack('>I', len(payload)) + name + payload + struct.pack('>I', zlib.crc32(name + payload) & 0xffffffff)

PNG = (b'\x89PNG\r\n\x1a\n'
       + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0))
       + png_chunk(b'IDAT', zlib.compress((b'\0' + b'\x00\x70\xff' * 2) * 2))
       + png_chunk(b'IEND', b''))

RID = '12345678-1234-1234-1234-123456789abc'
OTHER = 'abcdefab-1234-1234-1234-123456789abc'


def credit(name='Fixture Singer', credited=None):
    return [{'name': credited or name, 'artist': {'name': name}}]


def release(artist='Fixture Singer', title='Fixture Album', score=100, identity=RID):
    return {'id': identity, 'title': title, 'score': score, 'status': 'Official', 'artist-credit': credit(artist)}


def recording(artist='Fixture Singer', title='Fixture Song', score=100, releases=None):
    return {'id': RID, 'title': title, 'score': score, 'artist-credit': credit(artist), 'releases': releases if releases is not None else [release()]}


class Response:
    def __init__(self, body, url=None, headers=None):
        self.stream = io.BytesIO(json.dumps(body).encode() if isinstance(body, dict) else body)
        self.url = url
        self.headers = headers or {}
    def read(self, size): return self.stream.read(size)
    def geturl(self): return self.url
    def __enter__(self): return self
    def __exit__(self, *args): self.stream.close()


class HTTP:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []
    def open(self, url, *, headers, timeout):
        self.calls.append((url, headers, timeout))
        if not self.responses:
            raise AssertionError('unexpected network request: ' + url)
        response = self.responses.pop(0)
        if isinstance(response, Exception): raise response
        if not response.url: response.url = url
        return response


class Clock:
    def __init__(self): self.now, self.waits = 0., []
    def __call__(self): return self.now
    def wait(self, delay, cancel):
        self.waits.append(delay)
        self.now += delay
        return cancel.is_set()


class MusicBrainzOnly(OnlineCover):
    """Isolate the MB fallback contract; provider-chain tests use actual OnlineCover."""
    def _deezer(self, *args):
        return None


class OnlineCoverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.cancel = threading.Event()
        self.clock = Clock()
        self.limiter = RateLimiter(clock=self.clock, wait=self.clock.wait)
    def tearDown(self): self.temp.cleanup()
    def client(self, http): return MusicBrainzOnly(http=http, limiter=self.limiter)
    def fetch(self, client, artist='Fixture Singer', album='Fixture Album', title='Fixture Song'):
        return client.fetch(title, artist, album, self.root, self.cancel)

    def test_unicode_case_punctuation_whitespace_are_normalized(self):
        self.assertEqual(normalized('  Ｆｉｘｔｕｒｅ—Singer! '), normalized('fixture singer'))
        self.assertEqual(normalized('Beyonce\u0301'), normalized('Beyoncé'))

    def test_exact_artist_title_download_and_metadata_only_request(self):
        http = HTTP(Response({'recordings': [recording()]}), Response(PNG, 'https://archive.org/fixture/front-500.png'))
        result = self.fetch(self.client(http))
        self.assertEqual(result.path.read_bytes(), PNG)
        self.assertEqual(result.source_url, f'https://coverartarchive.org/release/{RID}/front-500')
        self.assertEqual(len(http.calls), 2)
        query = parse_qs(urlsplit(http.calls[0][0]).query)['query'][0]
        self.assertIn('Fixture Singer', query)
        self.assertIn('Fixture Song', query)
        self.assertNotIn(str(self.root), http.calls[0][0])
        self.assertTrue(all(call[2] == 10 for call in http.calls))
        self.assertTrue(all(call[1]['User-Agent'].startswith('BlueWave/1.0.4') for call in http.calls))
        self.assertEqual(json.loads(result.path.with_suffix('.json').read_text())['source_url'], result.source_url)

    def test_different_singer_rejected_even_when_score_is_100(self):
        http = HTTP(Response({'recordings': [recording(artist='Other Singer')]}))
        self.assertIsNone(self.fetch(self.client(http)))
        self.assertTrue(all(url.startswith('https://musicbrainz.org/') for url, _, _ in http.calls))

    def test_same_song_title_from_another_singer_is_never_selected(self):
        http = HTTP(Response({'recordings': [recording('Other Singer'), recording('Fixture Singer', releases=[release(identity=OTHER)])]}), Response(PNG))
        result = self.fetch(self.client(http), album='未知专辑')
        self.assertIn(OTHER, result.source_url)
        self.assertNotIn(RID, result.source_url)

    def test_credited_name_or_canonical_name_matches_but_joint_artist_does_not(self):
        candidate = recording(artist='Canonical Artist')
        candidate['artist-credit'] = credit('Canonical Artist', 'Fixture Singer')
        http = HTTP(Response({'recordings': [candidate]}), Response(PNG))
        self.assertIsNotNone(self.fetch(self.client(http)))
        joint = recording()
        joint['artist-credit'] += credit('Other Singer')
        http = HTTP(Response({'recordings': [joint]}))
        # Different cache key prevents previous successful result from satisfying this request.
        self.assertIsNone(self.fetch(self.client(http), album='Different Fixture Album'))

    def test_wrong_title_and_low_score_do_not_trigger_art_download(self):
        http = HTTP(Response({'recordings': [recording(title='Different Song'), recording(score=89)]}))
        self.assertIsNone(self.fetch(self.client(http)))
        self.assertEqual(len(http.calls), 1)

    def test_recording_fallback_requires_exact_title_artist_score_and_official_release(self):
        bad = release()
        bad['status'] = 'Bootleg'
        wrong_release_artist = release(artist='Other Singer')
        http = HTTP(Response({'recordings': [recording(title='Different Song'), recording(score=89), recording(releases=[bad, wrong_release_artist])]}))
        self.assertIsNone(self.fetch(self.client(http), album='未知专辑'))
        self.assertEqual(len(http.calls), 1)

    def test_unknown_artist_never_queries(self):
        for artist in ('', '未知艺人', 'Unknown Artist', 'Various Artists'):
            http = HTTP()
            self.assertIsNone(self.fetch(self.client(http), artist=artist))
            self.assertFalse(http.calls)

    def test_successful_cache_hit_uses_no_network(self):
        result = self.fetch(self.client(HTTP(Response({'recordings': [recording()]}), Response(PNG))))
        offline = HTTP()
        cached = self.fetch(self.client(offline))
        self.assertEqual(cached.path, result.path)
        self.assertEqual(cached.source_url, result.source_url)
        self.assertFalse(offline.calls)

    def test_failed_network_keeps_placeholder_and_can_retry_next_time(self):
        self.assertIsNone(self.fetch(self.client(HTTP(URLError('offline')))))
        result = self.fetch(self.client(HTTP(Response({'recordings': [recording()]}), Response(PNG))))
        self.assertIsNotNone(result)

    def test_musicbrainz_requests_are_one_second_apart_without_real_sleep(self):
        for title in ('Fixture Song', 'Other Song'):
            http = HTTP(Response({'recordings': []}))
            self.assertIsNone(self.fetch(self.client(http), title=title))
        self.assertEqual(self.clock.waits, [1.0])

    def test_cancel_prevents_network_and_cache(self):
        self.cancel.set()
        http = HTTP()
        self.assertIsNone(self.fetch(self.client(http)))
        self.assertFalse(http.calls)
        self.assertFalse(list(self.root.rglob('*.image')))

    def test_oversized_content_length_and_stream_are_rejected(self):
        for response in (Response(PNG, headers={'Content-Length': str(8 * 1024 * 1024 + 1)}), Response(b'x' * (8 * 1024 * 1024 + 1))):
            http = HTTP(Response({'recordings': [recording()]}), response, Response({'recordings': []}))
            self.assertIsNone(self.fetch(self.client(http)))
            self.assertFalse(list(self.root.rglob('*.image')))

    def test_invalid_image_and_unapproved_final_url_are_rejected(self):
        for response in (Response(b'<html>not an image</html>'), Response(PNG, 'https://evil.example/cover.png'), Response(PNG, 'http://archive.org/cover.png')):
            http = HTTP(Response({'recordings': [recording()]}), response, Response({'recordings': []}))
            self.assertIsNone(self.fetch(self.client(http)))
            self.assertFalse(list(self.root.rglob('*.image')))

    def test_redirect_policy_blocks_http_lookalike_hosts_and_credentials(self):
        for url in ('http://archive.org/a', 'https://archive.org.evil.example/a', 'https://evilarchive.org/a', 'https://user:password@archive.org/a', 'https://archive.org:444/a', 'file:///private/tmp/a'):
            self.assertFalse(allowed_art_url(url), url)
            with self.assertRaises(URLError):
                CoverRedirectHandler('art').redirect_request(Request('https://coverartarchive.org/release/x/front-500'), None, 307, 'redirect', {}, url)
        for url in ('https://archive.org/a', 'https://ia800001.us.archive.org/a', 'https://coverartarchive.org/a'):
            self.assertTrue(allowed_art_url(url))
            self.assertEqual(CoverRedirectHandler('art').redirect_request(Request('https://coverartarchive.org/release/x/front-500'), None, 307, 'redirect', {}, url).full_url, url)

    def test_cancellation_during_image_read_does_not_commit_cache(self):
        cancel = self.cancel
        class CancelDuringRead(Response):
            def read(self, size):
                cancel.set()
                return super().read(size)
        http = HTTP(Response({'recordings': [recording()]}), CancelDuringRead(PNG))
        self.assertIsNone(self.fetch(self.client(http)))
        self.assertEqual(len(http.calls), 2)
        self.assertFalse(list(self.root.rglob('*.image')))
        self.assertFalse(list(self.root.rglob('*.json')))

    def test_ten_second_deadline_discards_a_slow_image(self):
        clock = self.clock
        class SlowResponse(Response):
            def read(self, size):
                clock.now += 11
                return super().read(size)
        http = HTTP(Response({'recordings': [recording()]}), SlowResponse(PNG), Response({'recordings': []}))
        client = MusicBrainzOnly(http=http, limiter=self.limiter, clock=clock)
        self.assertIsNone(self.fetch(client))
        self.assertFalse(list(self.root.rglob('*.image')))

    def test_corrupt_cached_image_is_not_displayed_and_can_be_replaced(self):
        previous = self.fetch(self.client(HTTP(Response({'recordings': [recording()]}), Response(PNG))))
        previous.path.write_bytes(b'not an image')
        http = HTTP(Response({'recordings': [recording()]}), Response(PNG))
        result = self.fetch(self.client(http))
        self.assertEqual(result.path.read_bytes(), PNG)
        self.assertEqual(len(http.calls), 2)

    def test_musicbrainz_redirect_cannot_send_metadata_to_other_hosts(self):
        request = Request('https://musicbrainz.org/ws/2/release/?query=fixture')
        for target in ('https://archive.org/a', 'https://evil.example/a', 'http://musicbrainz.org/a'):
            with self.assertRaises(URLError):
                CoverRedirectHandler('metadata').redirect_request(request, None, 307, 'redirect', {}, target)

    def test_two_clients_share_injected_limiter_and_canonical_artist_name_matches(self):
        candidate = recording()
        candidate['artist-credit'][0]['name'] = 'Other Credited Alias'
        first = HTTP(Response({'recordings': [candidate]}), Response(PNG))
        self.assertIsNotNone(self.fetch(self.client(first)))
        second = HTTP(Response({'recordings': []}))
        self.assertIsNone(self.fetch(self.client(second), title='Other Song'))
        self.assertEqual(self.clock.waits, [1.0])

    def test_pseudo_release_is_allowed_but_bootleg_still_rejected(self):
        translated = release()
        translated['status'] = 'Pseudo-Release'
        http = HTTP(Response({'recordings': [recording(releases=[translated])]}), Response(PNG))
        self.assertIsNotNone(self.fetch(self.client(http), album='未知专辑'))

    def test_metadata_503_or_429_retries_once_after_at_least_1_point_2_seconds(self):
        from urllib.error import HTTPError
        for status in (503, 429):
            with self.subTest(status=status):
                clock = Clock()
                http = HTTP(HTTPError('https://musicbrainz.org/ws/2/release/', status, 'temporary', {}, None), Response({'recordings': [recording(title='Fixture Song ' + str(status))]}), Response(PNG))
                client = MusicBrainzOnly(http=http, limiter=RateLimiter(clock=clock, wait=clock.wait), clock=clock, retry_wait=clock.wait)
                result = client.fetch('Fixture Song ' + str(status), 'Fixture Singer', 'Fixture Album', self.root, self.cancel)
                self.assertIsNotNone(result)
                self.assertEqual(len(http.calls), 3)
                self.assertEqual(http.calls[0][0], http.calls[1][0])
                self.assertGreaterEqual(sum(clock.waits), 1.2)

    def test_second_metadata_503_stops_and_caa_503_is_not_retried(self):
        from urllib.error import HTTPError
        clock = Clock()
        error = lambda: HTTPError('https://musicbrainz.org/ws/2/release/', 503, 'temporary', {}, None)
        http = HTTP(error(), error())
        client = MusicBrainzOnly(http=http, limiter=RateLimiter(clock=clock, wait=clock.wait), clock=clock, retry_wait=clock.wait)
        self.assertIsNone(self.fetch(client))
        self.assertEqual(len(http.calls), 2)
        self.assertEqual(len(clock.waits), 1)
        http = HTTP(Response({'recordings': [recording()]}), HTTPError('https://coverartarchive.org/release/x/front-500', 503, 'temporary', {}, None), Response({'recordings': []}))
        client = MusicBrainzOnly(http=http, limiter=RateLimiter(clock=clock, wait=clock.wait), clock=clock, retry_wait=clock.wait)
        self.assertIsNone(self.fetch(client))
        art_calls = [url for url, _, _ in http.calls if url.startswith('https://coverartarchive.org/')]
        self.assertEqual(len(art_calls), 1)

    def test_cancel_during_metadata_retry_delay_suppresses_retry(self):
        from urllib.error import HTTPError
        http = HTTP(HTTPError('https://musicbrainz.org/', 503, 'temporary', {}, None))
        def cancel_wait(delay, cancel):
            cancel.set()
            return True
        client = MusicBrainzOnly(http=http, limiter=self.limiter, retry_wait=cancel_wait)
        self.assertIsNone(self.fetch(client))
        self.assertEqual(len(http.calls), 1)
