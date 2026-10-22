"""Local-only library, metadata, FFmpeg and LRC helpers (no GUI dependencies)."""
from dataclasses import asdict, dataclass, fields
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

AUDIO_EXTENSIONS = {'.mp3', '.aac', '.m4a', '.mp4', '.wav', '.aif', '.aiff', '.flac', '.alac', '.ogg', '.oga', '.opus', '.wma', '.wv', '.tta', '.au', '.caf', '.ape', '.dsf', '.dff', '.oma', '.aa3'}


class Cancelled(Exception):
    """A background import was canceled before committing library changes."""


def process_options():
    return {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}


def tool_path(name):
    executable = name + ('.exe' if os.name == 'nt' else '')
    roots = []
    if os.environ.get('BLUEWAVE_TOOLS'):
        roots.append(Path(os.environ['BLUEWAVE_TOOLS']))
    roots += [Path(getattr(sys, '_MEIPASS', Path(__file__).parent)) / 'resources' / 'Tools', Path(sys.executable).parent / 'resources' / 'Tools', Path(__file__).resolve().parent.parent / 'Vendor']
    for root in roots:
        candidate = root / executable
        if candidate.is_file():
            return str(candidate)
    raise FileNotFoundError('缺少内置工具：' + executable + '。请重新解压完整 Windows 应用包。')


def data_directory():
    override = os.environ.get('BLUEWAVE_DATA_DIRECTORY')
    if override:
        return Path(override)
    return Path(os.environ.get('LOCALAPPDATA', str(Path.home() / '.local' / 'share'))) / 'BlueWave'


@dataclass
class Track:
    id: str
    path: str
    title: str = ''
    artist: str = '未知艺人'
    album: str = '未知专辑'
    duration: float = 0.0
    sample_rate: int = 44100
    channels: int = 2
    codec: str = ''
    lyrics: str = ''
    favorite: bool = False
    last_played: float = 0.0
    metadata_source: str = '文件标签'

    @classmethod
    def from_path(cls, path, **kwargs):
        path = Path(path).expanduser().resolve()
        identity = os.path.normcase(str(path))
        return cls(id=hashlib.sha256(identity.encode('utf-8')).hexdigest()[:24], path=str(path), title=kwargs.pop('title', path.stem), **kwargs)


class Library:
    def __init__(self, root=None):
        self.root = Path(root) if root else data_directory()
        self.root.mkdir(parents=True, exist_ok=True)
        self.path = self.root / 'library.json'
        self.tracks = {}
        self.playlists = {}
        self.settings = {'normalize': False, 'crossfade': 0, 'rate': 0, 'precision': 32, 'online_covers': True, 'volume': 75, 'repeat': '列表循环', 'shuffle': False}
        if self.path.exists():
            try:
                payload = json.loads(self.path.read_text(encoding='utf-8'))
                if not isinstance(payload, dict) or not isinstance(payload.get('tracks'), list) or not isinstance(payload.get('playlists', {}), dict):
                    raise ValueError('invalid library structure')
                allowed = {field.name for field in fields(Track)}
                for item in payload['tracks']:
                    track = Track(**{k: v for k, v in item.items() if k in allowed})
                    self.tracks[track.id] = track
                self.playlists = payload.get('playlists', {})
                for playlist in self.playlists.values():
                    if not isinstance(playlist['name'], str) or not isinstance(playlist['tracks'], list):
                        raise ValueError('invalid playlist')
                self.settings.update({key: value for key, value in payload.get('settings', {}).items() if key in self.settings})
            except (ValueError, TypeError, KeyError, OSError) as error:
                raise ValueError('曲库文件无法读取，已保留原件：' + str(self.path) + '\n' + str(error)) from error

    def save(self):
        temporary = self.path.with_suffix('.json.tmp')
        temporary.write_text(json.dumps({'version': 1, 'tracks': [asdict(t) for t in self.tracks.values()], 'playlists': self.playlists, 'settings': self.settings}, ensure_ascii=False, indent=2), encoding='utf-8')
        os.replace(temporary, self.path)

    def add(self, tracks):
        for track in tracks:
            if track.id not in self.tracks:
                self.tracks[track.id] = track

    def remove(self, ids):
        for identity in ids:
            self.tracks.pop(identity, None)
        for playlist in self.playlists.values():
            playlist['tracks'] = [identity for identity in playlist['tracks'] if identity in self.tracks]
        self.save()

    def create_playlist(self, name):
        identity = uuid.uuid4().hex
        self.playlists[identity] = {'name': name.strip() or '新建播放列表', 'tracks': []}
        self.save()
        return identity

    def rename_playlist(self, identity, name):
        if name.strip():
            self.playlists[identity]['name'] = name.strip()
            self.save()

    def delete_playlist(self, identity):
        self.playlists.pop(identity, None)
        self.save()

    def playlist_add(self, identity, ids):
        playlist = self.playlists[identity]['tracks']
        playlist.extend(t for t in dict.fromkeys(ids) if t in self.tracks and t not in playlist)
        self.save()

    def playlist_remove(self, identity, ids):
        self.playlists[identity]['tracks'] = [t for t in self.playlists[identity]['tracks'] if t not in ids]
        self.save()

    def playlist_reorder(self, identity, ids):
        current = self.playlists[identity]['tracks']
        if len(ids) != len(current) or set(ids) != set(current):
            raise ValueError('排序必须保留列表中的所有歌曲。')
        self.playlists[identity]['tracks'] = list(ids)
        self.save()

    def backup(self):
        self.save()
        folder = self.root / 'Backups'
        folder.mkdir(exist_ok=True)
        path = folder / ('library-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.json')
        shutil.copy2(self.path, path)
        return path

    def clear(self, playlist=None):
        backup = self.backup()
        if playlist:
            self.playlists[playlist]['tracks'] = []
        else:
            self.tracks.clear()
            for item in self.playlists.values():
                item['tracks'] = []
        self.save()
        return backup


def discover_audio(paths):
    result = {}
    for value in paths:
        path = Path(value).expanduser()
        if path.is_dir():
            for root, dirs, files in os.walk(path, followlinks=False):
                dirs.sort()
                for name in sorted(files):
                    candidate = Path(root) / name
                    if candidate.suffix.lower() in AUDIO_EXTENSIONS:
                        candidate = candidate.resolve()
                        result[os.path.normcase(str(candidate))] = candidate
        elif path.suffix.lower() in AUDIO_EXTENSIONS and path.is_file():
            path = path.resolve()
            result[os.path.normcase(str(path))] = path
    return list(result.values())


def infer_filename_metadata(stem):
    """Conservative filename conventions; tags still override both inferred fields."""
    name = re.sub(r'^\s*\d{1,3}(?:\s*[-–—]\s+|[.、_]\s+|\s+)', '', stem).strip()
    # Standard Artist - Title uses spaces on both sides and must never be reversed.
    standard = re.fullmatch(r'(.+?)\s+[-–—]\s+(.+)', name)
    if standard:
        return standard.group(2).strip(), standard.group(1).strip()
    # A space only before the separator is the known Title -Artist convention.
    reversed_pair = re.fullmatch(r'(.+?)\s+[-–—](\S.*)', name)
    if reversed_pair:
        return reversed_pair.group(1).strip(), reversed_pair.group(2).strip()
    return name, '未知艺人'


def unknown_artist(value):
    return re.sub(r'\s+', '', (value or '').strip().casefold()) in ('', '未知艺人', '未知歌手', 'unknown', 'unknownartist')


def refresh_unknown_track(track):
    """Reprobe this one legacy entry; preserve all user identity/state references."""
    if not unknown_artist(track.artist):
        return track
    try:
        refreshed = probe(track.path)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return track
    refreshed.id = track.id
    refreshed.favorite = track.favorite
    refreshed.last_played = track.last_played
    return refreshed


def probe(path):
    completed = subprocess.run([tool_path('ffprobe'), '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(path)], capture_output=True, timeout=30, **process_options())
    if completed.returncode:
        raise ValueError(completed.stderr.decode('utf-8', errors='replace')[-1500:] or '无法读取音频')
    payload = json.loads(completed.stdout)
    stream = next((s for s in payload.get('streams', []) if s.get('codec_type') == 'audio'), None)
    if stream is None:
        raise ValueError('没有可播放的音轨')
    tags = {k.lower(): v for k, v in {**payload.get('format', {}).get('tags', {}), **stream.get('tags', {})}.items()}
    inferred_title, inferred_artist = infer_filename_metadata(Path(path).stem)
    title = tags.get('title') or inferred_title
    artist = tags.get('artist') or tags.get('album_artist') or inferred_artist
    album = tags.get('album') or Path(path).parent.name or '未知专辑'
    rate = int(stream.get('sample_rate') or 44100)
    return Track.from_path(path, title=title, artist=artist, album=album, duration=float(payload.get('format', {}).get('duration') or stream.get('duration') or 0), sample_rate=rate, channels=int(stream.get('channels') or 2), codec=stream.get('codec_name', ''), lyrics=next((v for k, v in tags.items() if 'lyrics' in k), ''), metadata_source=('标题：文件标签' if tags.get('title') else '标题：文件名推断 v2') + ('；艺人：文件标签' if tags.get('artist') or tags.get('album_artist') else '；艺人：文件名推断 v2' if inferred_artist != '未知艺人' else '；艺人未知') + ('；专辑：文件标签' if tags.get('album') else '；专辑：目录名推断'))


def output_rate(track, preference=0):
    return int(preference) or (176400 if track.codec.startswith('dsd') else max(8000, min(192000, track.sample_rate)))


def decoder_command(track, rate, start=0, normalize=False):
    command = [tool_path('ffmpeg'), '-nostdin', '-hide_banner', '-loglevel', 'error', '-ss', f'{max(0, start):.6f}', '-i', track.path, '-map', '0:a:0', '-vn']
    if normalize:
        command += ['-af', 'loudnorm=I=-18:TP=-1.5:LRA=11']
    return command + ['-ac', '2', '-ar', str(rate), '-f', 'f32le', '-acodec', 'pcm_f32le', 'pipe:1']


def decode_bytes(track, rate=48000, start=0, normalize=False):
    # Bounded-duration test helper; realtime playback streams stdout instead.
    completed = subprocess.run(decoder_command(track, rate, start, normalize), capture_output=True, timeout=30, **process_options())
    if completed.returncode:
        raise ValueError(completed.stderr.decode('utf-8', errors='replace'))
    return completed.stdout


def parse_lrc(text):
    offset_match = re.search(r'\[offset:([+-]?\d+)\]', text, re.I)
    offset = int(offset_match.group(1)) / 1000 if offset_match else 0
    result = []
    pattern = r'\[(\d+):(\d{1,2}(?:\.\d+)?)\]'
    for line in text.splitlines():
        stamps = re.findall(pattern, line)
        content = re.sub(pattern, '', line).strip()
        for minutes, seconds in stamps:
            result.append((round(max(0, int(minutes) * 60 + float(seconds) + offset), 3), content))
    return sorted(result, key=lambda value: value[0])


def format_lrc(lines):
    return '\n'.join(f'[{int(round(time * 100)) // 6000:02d}:{(int(round(time * 100)) % 6000) / 100:05.2f}]{text}' for time, text in lines) + '\n'


def read_text(path):
    raw = Path(path).read_bytes()
    for encoding in ('utf-8-sig', 'utf-16', 'gb18030'):
        try:
            return raw.decode(encoding)
        except UnicodeError:
            pass
    return raw.decode('utf-8', errors='replace')


def read_lyrics(track):
    path = Path(track.path).with_suffix('.lrc')
    if path.is_file():
        return read_text(path), '同名 LRC'
    if track.lyrics:
        return track.lyrics, '内嵌歌词'
    return '', ''


def cover_path(track, cache_root):
    cache_root = Path(cache_root)
    cache_root.mkdir(parents=True, exist_ok=True)
    cache = cache_root / (track.id + '.png')
    if cache.exists():
        return cache
    # map optional embedded cover explicitly; no video stream means no output.
    try:
        result = subprocess.run([tool_path('ffmpeg'), '-nostdin', '-loglevel', 'error', '-i', track.path, '-map', '0:v:0', '-frames:v', '1', '-c:v', 'png', '-vf', 'scale=600:600:force_original_aspect_ratio=decrease', '-y', str(cache)], capture_output=True, timeout=15, **process_options())
        if result.returncode == 0 and cache.is_file() and cache.stat().st_size:
            return cache
    except (OSError, subprocess.TimeoutExpired):
        pass
    cache.unlink(missing_ok=True)
    return existing_cover_path(track, cache_root)


def existing_cover_path(track, cache_root):
    """Disk-only sibling lookup: never decode or request a sibling online."""
    cached = Path(cache_root) / (track.id + ".png")
    if cached.is_file():
        return cached
    source = Path(track.path)
    preferred = [source.stem.lower(), 'cover', 'folder', 'front', '封面']
    try:
        images = [p for p in source.parent.iterdir() if p.suffix.lower() in {'.jpg', '.jpeg', '.png', '.webp'}]
        for name in preferred:
            found = next((p for p in images if p.stem.lower() == name), None)
            if found:
                return found
    except OSError:
        pass
    return None
