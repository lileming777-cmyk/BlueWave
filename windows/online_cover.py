"""Exact artist + full-title metadata lookup: Deezer, then MusicBrainz / CAA.

No Track/path/audio object enters the HTTP layer. All network failures are normal
cover misses. Only successful images are cached; retries happen on later plays.
"""
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import threading
import time
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import uuid

from core import Cancelled

MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_JSON_BYTES = 1024 * 1024
TIMEOUT = 10
USER_AGENT = 'BlueWave/1.0.4 (local music player; metadata-only cover lookup)'


def normalized(value):
    return ''.join(char for char in unicodedata.normalize('NFKC', value or '').casefold() if unicodedata.category(char)[0] in ('L', 'N', 'M'))


def _host(url):
    try:
        parts = urlsplit(url)
        if parts.scheme != 'https' or parts.username is not None or parts.password is not None or parts.port not in (None, 443):
            return ''
        return (parts.hostname or '').lower()
    except ValueError:
        return ''


def _caa_art_url(url):
    host = _host(url)
    return any(host == domain or host.endswith('.' + domain) for domain in ('coverartarchive.org', 'archive.org'))


def _deezer_art_url(url):
    return _host(url) in ('cdn-images.dzcdn.net', 'e-cdns-images.dzcdn.net')


def allowed_art_url(url):
    return _caa_art_url(url) or _deezer_art_url(url)


def _allowed_metadata_url(url):
    return _host(url) in ('musicbrainz.org', 'api.deezer.com')


class CoverRedirectHandler(HTTPRedirectHandler):
    max_redirections = 5
    max_repeats = 2

    def __init__(self, kind):
        super().__init__()
        self.allowed = {'art': _caa_art_url, 'deezer-art': _deezer_art_url,
                        'metadata': lambda url: _host(url) == 'musicbrainz.org',
                        'deezer-metadata': lambda url: _host(url) == 'api.deezer.com'}[kind]

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urljoin(req.full_url, newurl)
        if not self.allowed(target):
            raise URLError('cover redirect rejected')
        return super().redirect_request(req, fp, code, msg, headers, target)


class SecureHTTP:
    def open(self, url, *, headers, timeout):
        kind = ('deezer-metadata' if _host(url) == 'api.deezer.com' else 'metadata') if _allowed_metadata_url(url) else ('deezer-art' if _deezer_art_url(url) else 'art')
        allowed = CoverRedirectHandler(kind).allowed
        if not allowed(url):
            raise URLError('cover URL rejected')
        # A separate opener prevents default urllib redirects bypassing the policy.
        return build_opener(CoverRedirectHandler(kind)).open(Request(url, headers=headers), timeout=timeout)


class RateLimiter:
    """One metadata request start per second across all providers and workers."""
    def __init__(self, clock=time.monotonic, wait=None):
        self.clock = clock
        self.wait = wait or (lambda delay, cancel: cancel.wait(delay))
        self.lock = threading.Lock()
        self.last = None

    def acquire(self, cancel):
        while not self.lock.acquire(timeout=.1):
            if cancel.is_set():
                raise Cancelled()
        try:
            while True:
                if cancel.is_set():
                    raise Cancelled()
                now = self.clock()
                delay = 0 if self.last is None else self.last + 1 - now
                if delay <= 0:
                    self.last = now
                    return
                if self.wait(delay, cancel):
                    raise Cancelled()
        finally:
            self.lock.release()


_SHARED_LIMITER = RateLimiter()


@dataclass(frozen=True)
class CoverResult:
    path: Path
    source_url: str
    provider: str = ''
    artist: str = ''
    title: str = ''
    album: str = ''
    track_url: str = ''


def _artist_matches(item, artist):
    # Do not mistake one member of a joint credit or compilation for the tag's singer.
    credits = item.get('artist-credit', [])
    if not isinstance(credits, list) or len(credits) != 1 or not isinstance(credits[0], dict):
        return False
    credited = credits[0]
    canonical = credited.get('artist', {})
    return normalized(artist) in {normalized(credited.get('name', '')), normalized(canonical.get('name', '') if isinstance(canonical, dict) else '')}


def _high_score(item):
    try:
        return float(item.get('score', 0)) >= 90
    except (TypeError, ValueError):
        return False


def _release_id(item):
    try:
        value = item.get('id', '')
        return str(uuid.UUID(value)) if isinstance(value, str) else None
    except ValueError:
        return None


def _literal(value):
    # Lucene quoted phrase: escape backslashes and quotation marks inside metadata.
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def _valid_image(data):
    # Reject SVG/HTML or arbitrary plugin data before Qt inspects a raster image.
    if not (data.startswith(b'\x89PNG\r\n\x1a\n') or data.startswith(b'\xff\xd8\xff') or (data.startswith(b'RIFF') and data[8:12] == b'WEBP')):
        return False
    from PySide6.QtCore import QByteArray, QBuffer, QIODevice
    from PySide6.QtGui import QImageReader
    buffer = QBuffer()
    buffer.setData(QByteArray(data))
    buffer.open(QIODevice.ReadOnly)
    reader = QImageReader(buffer)
    size = reader.size()
    if not size.isValid() or size.width() > 10000 or size.height() > 10000 or size.width() * size.height() > 20_000_000:
        return False
    return not reader.read().isNull()


class OnlineCover:
    def __init__(self, http=None, limiter=None, clock=time.monotonic, retry_wait=None):
        self.http = http if http is not None else SecureHTTP()
        self.limiter = limiter if limiter is not None else _SHARED_LIMITER
        self.clock = clock
        self.retry_wait = retry_wait or (lambda delay, cancel: cancel.wait(delay))

    def _read(self, url, limit, cancel, metadata=False):
        if cancel.is_set():
            raise Cancelled()
        allowed = (lambda target: _allowed_metadata_url(url) and _host(target) == _host(url)) if metadata else (_deezer_art_url if _deezer_art_url(url) else _caa_art_url)
        if not allowed(url):
            raise URLError('cover URL rejected')
        if metadata:
            self.limiter.acquire(cancel)
        headers = {'User-Agent': USER_AGENT, 'Accept': 'application/json' if metadata else 'image/jpeg,image/png,image/webp', 'Accept-Encoding': 'identity'}
        deadline = self.clock() + TIMEOUT
        with self.http.open(url, headers=headers, timeout=TIMEOUT) as response:
            final = response.geturl()
            if not allowed(final):
                raise URLError('cover response URL rejected')
            declared = response.headers.get('Content-Length')
            if declared is not None and (int(declared) < 0 or int(declared) > limit):
                raise ValueError('cover response exceeds size limit')
            encoding = response.headers.get('Content-Encoding', 'identity').lower()
            if encoding not in ('', 'identity'):
                raise ValueError('compressed cover response rejected')
            content = bytearray()
            while True:
                if cancel.is_set():
                    raise Cancelled()
                if self.clock() > deadline:
                    raise TimeoutError('cover request timed out')
                chunk = response.read(min(65536, limit + 1 - len(content)))
                if self.clock() > deadline:
                    raise TimeoutError('cover request timed out')
                if not chunk:
                    return bytes(content), final
                content.extend(chunk)
                if len(content) > limit:
                    raise ValueError('cover response exceeds size limit')

    def _json(self, url, cancel):
        for attempt in range(2):
            try:
                data, _ = self._read(url, MAX_JSON_BYTES, cancel, metadata=True)
                break
            except HTTPError as error:
                retry = error.code in (429, 503) and attempt == 0
                error.close()
                if not retry:
                    raise
                if self.retry_wait(1.2, cancel) or cancel.is_set():
                    raise Cancelled()
        payload = json.loads(data)
        if not isinstance(payload, dict):
            raise ValueError('invalid cover metadata')
        return payload

    def _search(self, kind, query, cancel):
        url = 'https://musicbrainz.org/ws/2/' + kind + '/?' + urlencode({'query': query, 'fmt': 'json', 'limit': 10})
        items = self._json(url, cancel).get('recordings', [])
        return [item for item in items if isinstance(item, dict)] if isinstance(items, list) else []

    @staticmethod
    def _cached(path):
        try:
            if path.stat().st_size > MAX_IMAGE_BYTES:
                return None
            with path.open('rb') as stream:
                data = stream.read(MAX_IMAGE_BYTES + 1)
            metadata = json.loads(path.with_suffix('.json').read_text(encoding='utf-8'))
            source = metadata['source_url']
            if len(data) > MAX_IMAGE_BYTES or not allowed_art_url(source) or not allowed_art_url(metadata['final_url']) or not _valid_image(data):
                return None
            return CoverResult(path, source, metadata.get('provider', 'MusicBrainz'),
                               metadata.get('matched_artist', ''), metadata.get('matched_title', ''),
                               metadata.get('matched_album', ''), metadata.get('track_url', ''))
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def _download(self, url, path, cancel, provider, artist, title, album, track_url):
        data, final = self._read(url, MAX_IMAGE_BYTES, cancel)
        if not _valid_image(data):
            raise ValueError('cover image is invalid')
        if cancel.is_set():
            raise Cancelled()
        path.parent.mkdir(parents=True, exist_ok=True)
        suffix = '.' + uuid.uuid4().hex + '.tmp'
        image_tmp = path.with_name(path.name + suffix)
        metadata = path.with_suffix('.json')
        metadata_tmp = metadata.with_name(metadata.name + suffix)
        try:
            image_tmp.write_bytes(data)
            metadata_tmp.write_text(json.dumps({'source_url': url, 'final_url': final, 'provider': provider,
                                               'matched_artist': artist, 'matched_title': title,
                                               'matched_album': album, 'track_url': track_url}, ensure_ascii=False, indent=2), encoding='utf-8')
            if cancel.is_set():
                raise Cancelled()
            os.replace(image_tmp, path)
            os.replace(metadata_tmp, metadata)
            return CoverResult(path, url, provider, artist, title, album, track_url)
        finally:
            image_tmp.unlink(missing_ok=True)
            metadata_tmp.unlink(missing_ok=True)

    def _deezer(self, title, artist, album, path, cancel):
        url = 'https://api.deezer.com/search?' + urlencode({'q': artist + ' ' + title, 'limit': 10})
        items = self._json(url, cancel).get('data', [])
        if not isinstance(items, list):
            return None
        matches = [item for item in items if isinstance(item, dict)
                   and isinstance(item.get('artist'), dict) and isinstance(item.get('album'), dict)
                   and normalized(item['artist'].get('name', '')) == normalized(artist)
                   and normalized(item.get('title', '')) == normalized(title)]
        matches.sort(key=lambda item: normalized(item['album'].get('title', '')) != normalized(album))
        attempts = 0
        for item in matches[:3]:
            identity = str(item.get('id', ''))
            if not identity.isdigit():
                continue
            track_url = 'https://www.deezer.com/track/' + identity
            urls = dict.fromkeys(item['album'].get(key, '') for key in ('cover_big', 'cover_medium'))
            for image_url in urls:
                if not _deezer_art_url(image_url):
                    continue
                attempts += 1
                try:
                    return self._download(image_url, path, cancel, 'Deezer', item['artist']['name'],
                                          item['title'], item['album'].get('title', ''), track_url)
                except (OSError, ValueError):
                    if cancel.is_set() or attempts >= 3:
                        return None
        return None

    def _musicbrainz(self, title, artist, album, path, cancel):
        # An album/artist release match alone cannot prove the requested song belongs to it.
        recordings = self._search('recording', 'artist:' + _literal(artist) + ' AND recording:' + _literal(title), cancel)
        candidates = []
        for item in recordings:
            recording_id = _release_id(item)
            if not recording_id or not _high_score(item) or not _artist_matches(item, artist) or normalized(item.get('title', '')) != normalized(title):
                continue
            for release in item.get('releases', []):
                if not isinstance(release, dict) or release.get('status', '').casefold() not in ('official', 'pseudo-release'):
                    continue
                if 'artist-credit' in release and not _artist_matches(release, artist):
                    continue
                identity = _release_id(release)
                if identity:
                    candidates.append((item, release, identity, recording_id))
        candidates.sort(key=lambda candidate: normalized(candidate[1].get('title', '')) != normalized(album))
        tried = set()
        for item, release, identity, recording_id in candidates:
            if identity in tried:
                continue
            tried.add(identity)
            try:
                return self._download(f'https://coverartarchive.org/release/{identity}/front-500', path, cancel,
                                      'MusicBrainz', artist, item['title'], release.get('title', ''),
                                      'https://musicbrainz.org/recording/' + recording_id)
            except (OSError, ValueError):
                if cancel.is_set() or len(tried) >= 3:
                    return None
        return None

    def fetch(self, title, artist, album, cache_root, cancel):
        """Return cached or jointly matched artwork. Never accept an artist-only result."""
        if cancel.is_set() or normalized(artist) in ('', '未知艺人', '未知歌手', 'unknown', 'unknownartist', 'variousartists') or normalized(title) in ('', '未知歌曲', '未知标题', 'unknown', 'unknowntitle', 'untitled'):
            return None
        # Preserve the prior on-disk key/layout so existing user caches remain usable.
        key = hashlib.sha256(json.dumps(['online-cover-v1', normalized(title), normalized(artist), normalized(album)], ensure_ascii=False).encode()).hexdigest()
        path = Path(cache_root) / 'Online' / (key + '.image')
        cached = self._cached(path)
        if cached:
            return cached
        try:
            try:
                result = self._deezer(title, artist, album, path, cancel)
                if result:
                    return result
            except (OSError, ValueError, KeyError, TypeError):
                pass
            if not cancel.is_set():
                return self._musicbrainz(title, artist, album, path, cancel)
        except (OSError, ValueError, KeyError, TypeError, Cancelled):
            return None
        return None


def cached_cover(title, artist, album, cache_root):
    """Read a sibling's prior successful cache without creating an HTTP client."""
    key = hashlib.sha256(json.dumps(['online-cover-v1', normalized(title), normalized(artist), normalized(album)], ensure_ascii=False).encode()).hexdigest()
    return OnlineCover._cached(Path(cache_root) / 'Online' / (key + '.image'))
