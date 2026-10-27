import hashlib
import subprocess
import tempfile
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parent.parent
app = root / 'dist/BlueWave-1.0.7/BlueWave.app'
package = root / 'dist/BlueWave-1.0.7-arm64.pkg'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
with tempfile.TemporaryDirectory(prefix='bluewave-release-') as temp:
    expanded = Path(temp) / 'expanded'
    subprocess.run(['pkgutil', '--expand-full', str(package), str(expanded)], check=True)
    info = ET.parse(expanded / 'PackageInfo').getroot()
    assert info.attrib['install-location'] == '/Applications'
    assert not (expanded / 'Scripts').exists()
    installed = expanded / 'Payload/BlueWave.app'
    for relative in ['Contents/MacOS/BlueWave', 'Contents/Resources/Tools/ffmpeg', 'Contents/Resources/Tools/ffprobe']:
        assert hashlib.sha256((app / relative).read_bytes()).digest() == hashlib.sha256((installed / relative).read_bytes()).digest(), relative
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(installed)], check=True)
with zipfile.ZipFile(root / 'dist/BlueWave-1.0.7-source.zip') as archive:
    assert archive.testzip() is None
    names = archive.namelist()
    for suffix in ['Sources/BlueWave/BlueWaveApp.swift', 'scripts/build.sh', 'Sources/BlueWaveCore/CoverArt.swift', 'Tests/BlueWaveCoreTests/PlaybackTests.swift', 'third-party/ffmpeg/ffmpeg-9.0.2.tar.xz', 'windows/online_cover.py']:
        assert any(name.endswith(suffix) for name in names), suffix
    assert not any('/research/' in name or '/.git/' in name or '/handoff/' in name for name in names)
assert {p.name for p in (app / 'Contents/Resources/Tools').iterdir()} == {'ffmpeg', 'ffprobe'}
assert not any('LyricTranscriber.swift' in n or 'build-whisper.sh' in n for n in names)
checksums = []
for name in ['BlueWave-1.0.7-arm64.pkg', 'BlueWave-1.0.7-arm64.zip', 'BlueWave-1.0.7-source.zip']:
    path = root / 'dist' / name
    checksums.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + name)
(root / 'dist/SHA256SUMS.txt').write_text('\n'.join(checksums) + '\n')
print('PASS: app signature, installer payload and destination, bundled decoder tools without transcription model, source archive, release checksums')
