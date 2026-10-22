"""Bounded streaming playback. Workers own devices/processes; GUI owns scheduling."""
import subprocess
import tempfile
import threading
import uuid

import numpy as np

from core import decoder_command, output_rate, process_options


def quantize(samples, precision):
    if precision in (16, 24):
        scale = 2 ** (precision - 1)
        return (np.clip(np.rint(samples * scale), -scale, scale - 1) / scale).astype(np.float32)
    return samples


class AudioSession:
    def __init__(self, track, settings, start, completed, stream_factory=None):
        self.track = track
        self.settings = dict(settings)
        self.position = start
        self.gain = 1.0
        self.volume = float(settings.get('volume', 75)) / 100
        self.token = uuid.uuid4().hex
        self.completed = completed
        self.stream_factory = stream_factory
        self.stopped = threading.Event()
        self.running = threading.Event()
        self.running.set()
        self.process = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.thread.start()

    def pause(self, paused):
        if paused:
            self.running.clear()
        else:
            self.running.set()

    def cancel(self):
        self.stopped.set()
        self.running.set()
        process = self.process
        if process and process.poll() is None:
            try:
                process.kill()
            except OSError:
                pass

    def _run(self):
        if self.stopped.is_set():
            return
        error = ''
        try:
            if self.stream_factory is None:
                import sounddevice
                factory = sounddevice.RawOutputStream
            else:
                factory = self.stream_factory
            rate = output_rate(self.track, self.settings.get('rate', 0))
            frames = 2048
            # OS stdout pipe bounds decoded PCM; blocking device writes provide backpressure.
            # stderr goes to disk so an invalid decoder cannot deadlock either pipe.
            with tempfile.TemporaryFile() as diagnostic:
                self.process = subprocess.Popen(decoder_command(self.track, rate, self.position, self.settings.get('normalize', False)), stdout=subprocess.PIPE, stderr=diagnostic, **process_options())
                with factory(samplerate=rate, channels=2, dtype='float32', blocksize=frames, latency='high') as output:
                    while not self.stopped.is_set():
                        self.running.wait(.1)
                        if not self.running.is_set():
                            continue
                        block = self.process.stdout.read(frames * 8)
                        if not block:
                            break
                        if self.stopped.is_set():
                            break
                        # The last block can be smaller; stereo f32 always aligns to 8 bytes.
                        samples = np.frombuffer(block[:len(block) // 8 * 8], dtype='<f4')
                        samples = quantize(samples, self.settings.get('precision', 32))
                        output.write((samples * self.volume * self.gain).astype('<f4').tobytes())
                        self.position += len(samples) / 2 / rate
                code = self.process.wait(timeout=5)
                if code and not self.stopped.is_set():
                    diagnostic.seek(0)
                    error = diagnostic.read().decode('utf-8', errors='replace')[-1500:] or '解码失败'
        except Exception as exc:
            error = str(exc)
        finally:
            process = self.process
            if process:
                if process.poll() is None:
                    process.kill()
                process.wait()
                if process.stdout:
                    process.stdout.close()
            if not self.stopped.is_set():
                self.completed(self.token, error)
