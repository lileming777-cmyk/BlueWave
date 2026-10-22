import math
from pathlib import Path
import struct
import tempfile
import threading
import unittest
import wave

import numpy as np
from audio import AudioSession, quantize
from core import probe


class AudioTests(unittest.TestCase):
    def test_precision_quantizes_without_overflow(self):
        data = np.array([-2., -1., -.123456, 0., .123456, 1., 2.], dtype=np.float32)
        result = quantize(data, 16)
        self.assertGreaterEqual(result.min(), -1.)
        self.assertLess(result.max(), 1.)
        np.testing.assert_allclose(result * 32768, np.rint(result * 32768))

    def test_session_decodes_into_real_consumer_and_completes(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'a.wav'
            with wave.open(str(path), 'wb') as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(16000)
                out.writeframes(b''.join(struct.pack('<h', int(math.sin(i * .1) * 8000)) for i in range(3200)))
            blocks = []
            finished = []
            class Sink:
                def __init__(self, **kwargs):
                    pass
                def __enter__(self):
                    return self
                def write(self, block):
                    blocks.append(bytes(block))
                def __exit__(self, *args):
                    pass
            session = AudioSession(probe(path), {'rate': 48000, 'precision': 24}, 0, lambda *args: finished.append(args), Sink)
            session.start()
            session.thread.join(10)
            self.assertFalse(session.thread.is_alive())
            self.assertEqual(len(b''.join(blocks)), 9600 * 2 * 4)
            self.assertEqual(finished, [(session.token, '')])
            self.assertAlmostEqual(session.position, .2, places=2)

    def test_cancelled_session_does_not_complete_as_next_track(self):
        # Cancellation before the worker runs must not open a device or launch FFmpeg.
        finished = []
        session = AudioSession(None, {}, 0, lambda *args: finished.append(args))
        session.cancel()
        session.start()
        session.thread.join(2)
        self.assertFalse(session.thread.is_alive())
        self.assertFalse(finished)

class ActiveCancellationTests(unittest.TestCase):
    def test_cancel_paused_decoder_reaps_process_and_suppresses_completion(self):
        import time
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'paused.wav'
            with wave.open(str(path), 'wb') as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(16000)
                out.writeframes(b'\0\0' * 16000)
            completed, blocks = [], []
            class Sink:
                def __init__(self, **kwargs): pass
                def __enter__(self): return self
                def __exit__(self, *args): pass
                def write(self, data): blocks.append(bytes(data))
            session = AudioSession(probe(path), {'rate': 48000}, 0, lambda *args: completed.append(args), Sink)
            session.pause(True)
            session.start()
            deadline = time.monotonic() + 5
            while session.process is None and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertIsNotNone(session.process)
            self.assertFalse(blocks)
            session.cancel()
            session.thread.join(5)
            self.assertFalse(session.thread.is_alive())
            self.assertIsNotNone(session.process.poll())
            self.assertFalse(completed)


if __name__ == '__main__':
    unittest.main()
