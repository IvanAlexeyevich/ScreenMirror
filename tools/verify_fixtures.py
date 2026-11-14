#!/usr/bin/env python3
"""Validate actual media, not UI or a second implementation of production logic."""
import json, subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
for path in sorted((root / 'Fixtures').glob('*.ts')):
    result = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)]))
    streams = {s['codec_type']: s for s in result['streams']}
    v, a = streams['video'], streams['audio']
    assert (v['codec_name'], v['width'], v['height'], v['r_frame_rate']) == ('h264', 1280, 720, '30/1'), path
    assert (a['codec_name'], a['sample_rate'], a['channels']) == ('aac', '48000', 2), path
    assert float(result['format']['duration']) >= 1.9, path
    subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'null', '-'], check=True, stdout=subprocess.DEVNULL)
    print(path.name, 'H.264 720p30 + AAC stereo: decode OK')
