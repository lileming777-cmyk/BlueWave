"""Local format QA. Personal audio paths/results stay in ignored research/QA/."""
import json, math, os, struct, subprocess, wave, zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
qa = root / 'research' / 'QA'
qa.mkdir(parents=True, exist_ok=True)
generator = root / 'Downloads' / 'TestTools'
generator.mkdir(parents=True, exist_ok=True)
if (root / 'Downloads' / 'ffmpeg.zip').exists():
    with zipfile.ZipFile(root / 'Downloads' / 'ffmpeg.zip') as archive:
        archive.extract('ffmpeg', generator)
    full = generator / 'ffmpeg'
    full.chmod(0o755)
else:
    # Optional full encoder build for fixture generation; never bundled in the app.
    full = Path(os.environ.get('BLUEWAVE_QA_ENCODER', root / 'Vendor' / 'ffmpeg'))
source = qa / 'BlueWave synthetic test.wav'
with wave.open(str(source), 'wb') as wav:
    wav.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
    wav.writeframes(b''.join(struct.pack('<h', int(math.sin(i * 440 * 2 * math.pi / 48000) * 4000)) for i in range(48000)))
encodings = [('mp3','libmp3lame'),('m4a','aac'),('aiff','pcm_s24be'),('flac','flac'),('alac.m4a','alac'),('ogg','libvorbis'),('opus','libopus'),('wma','wmav2'),('wv','wavpack'),('tta','tta'),('au','pcm_s16be'),('caf','pcm_f32le')]
inputs = [('WAV', source)]
rate = 2822400
per_channel = rate // 8
block = 4096
padded = ((per_channel + block - 1) // block) * block
payload = bytes([0x69]) * (padded * 2)
dsf = qa / 'synthetic.dsf'
dsf.write_bytes(b'DSD ' + struct.pack('<QQQ', 28, 28 + 52 + 12 + len(payload), 0) + b'fmt ' + struct.pack('<QIIIIIIQII', 52, 1, 0, 2, 2, rate, 1, rate, block, 0) + b'data' + struct.pack('<Q', len(payload) + 12) + payload)
def chunk(tag, data):
    return tag + struct.pack('>Q', len(data)) + data + (b'\0' if len(data) % 2 else b'')
properties = b'SND ' + chunk(b'FS  ', struct.pack('>I', rate)) + chunk(b'CHNL', struct.pack('>H', 2) + b'SLFTSRGT') + chunk(b'CMPR', b'DSD ' + bytes([14]) + b'not compressed')
dff_payload = b'DSD ' + chunk(b'FVER', struct.pack('>I', 0x01050000)) + chunk(b'PROP', properties) + chunk(b'DSD ', bytes([0x69]) * (per_channel * 2))
dff = qa / 'synthetic.dff'
dff.write_bytes(b'FRM8' + struct.pack('>Q', len(dff_payload)) + dff_payload)
inputs += [('DSF', dsf), ('DFF', dff)]
for extension, codec in encodings:
    output = qa / ('合成测试 $blue.' + extension)
    result = subprocess.run([str(full),'-nostdin','-v','error','-y','-i',str(source),'-c:a',codec,str(output)], capture_output=True)
    if result.returncode:
        print('FIXTURE ERROR', extension, result.stderr.decode(errors='replace')[-200:]); continue
    inputs.append(('ALAC' if codec == 'alac' else extension.upper(), output))
needed = {'dsf','dff','ape'}
# Real fixtures are opt-in; default QA never searches personal/external volumes.
for volume in [Path(value) for value in os.environ.get('BLUEWAVE_QA_AUDIO_ROOTS', '').split(os.pathsep) if value]:
    for folder, _, files in os.walk(volume):
        for name in files:
            extension = Path(name).suffix[1:].lower()
            if extension in needed and not name.startswith('._'):
                inputs.append((extension.upper() + ' (real)', Path(folder) / name)); needed.remove(extension)
        if not needed: break
    if not needed: break
rows = []
for label, path in inputs:
    probe = subprocess.run([str(root/'Vendor/ffprobe'),'-v','error','-select_streams','a:0','-show_entries','stream=codec_name,sample_rate,channels:format=duration','-of','json',str(path)], capture_output=True, timeout=30)
    decode = subprocess.run([str(root/'Vendor/ffmpeg'),'-nostdin','-v','error','-i',str(path),'-map','0:a:0','-t','2','-ac','2','-ar','48000','-c:a','pcm_f32le','-f','f32le','pipe:1'], capture_output=True, timeout=45)
    passed = probe.returncode == 0 and decode.returncode == 0 and len(decode.stdout) > 10000
    rows.append({'format':label,'passed':passed,'sample':str(path),'metadata':json.loads(probe.stdout or b'{}'),'pcm_bytes':len(decode.stdout),'error':decode.stderr.decode(errors='replace')[-600:]})
    print(label, 'PASS' if passed else 'FAIL', len(decode.stdout), flush=True)
(qa/'formats.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2))
if not all(row['passed'] for row in rows): raise SystemExit(1)
