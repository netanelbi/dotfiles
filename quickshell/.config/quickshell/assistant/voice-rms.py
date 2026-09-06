#!/usr/bin/env python3
# voice-rms — live loudness for the voice capsule.
#
# Tails the recording wav itself (one process, killable directly — a
# `tail | python` pipeline would orphan both children when the shell dies) and
# prints one normalised RMS level per ~100 ms of audio, flush per line.
# The capsule treats stdout as an event stream — nothing polls.
#   argv : path to the wav pw-record is writing (s16le mono 16 kHz)
#   stdout: one float 0..1 per line, capped (x5 gain so speech sits mid-scale)
import os
import struct
import sys
import time

GAIN = 5.0
BLOCK = 3200  # 100 ms of samples

path = sys.argv[1]

# pw-record creates the file and writes the 44-byte RIFF header before any
# audio lands, so waiting for it to exist is the only sync needed.
while not os.path.exists(path):
    time.sleep(0.02)

with open(path, "rb") as f:
    f.seek(44)  # the RIFF header; data starts right behind it
    buf = b""
    while True:
        chunk = f.read(640)
        if chunk:
            buf += chunk
        else:
            time.sleep(0.03)  # stream is momentarily dry, recorder still alive
            continue
        while len(buf) >= BLOCK:
            block, buf = buf[:BLOCK], buf[BLOCK:]
            n = BLOCK // 2
            acc = 0
            for (x,) in struct.iter_unpack("<h", block):
                acc += x * x
            rms = (acc / n) ** 0.5 / 32768.0
            print(f"{min(1.0, rms * GAIN):.3f}", flush=True)