#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
ffmpeg -v error -i Fixtures/test.ts -map 0:v:0 -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p -bf 0 -g 30 -x264-params aud=1 -f h264 "$TASK_TEST_DIR/video.h264"
ffmpeg -v error -i Fixtures/test.ts -map 0:a:0 -c copy -f adts "$TASK_TEST_DIR/audio.aac"
swiftc Shared/TSPacketPacer.swift Shared/LiveStreamBuffer.swift Shared/FrameSchedule.swift Broadcast/TransportStream.swift Tests/MuxHarness.swift -o "$TASK_TEST_DIR/mux"
"$TASK_TEST_DIR/mux" "$TASK_TEST_DIR/video.h264" "$TASK_TEST_DIR/audio.aac" "$TASK_TEST_DIR/native.ts"
ffmpeg -v error -xerror -i "$TASK_TEST_DIR/native.ts" -f null -
ffmpeg -v error -xerror -i "$TASK_TEST_DIR/native.ts.paced.ts" -f null -
ffmpeg -v error -i "$TASK_TEST_DIR/native.ts" -map 0:v:0 -f framemd5 "$TASK_TEST_DIR/before-video.md5"
ffmpeg -v error -i "$TASK_TEST_DIR/native.ts.paced.ts" -map 0:v:0 -f framemd5 "$TASK_TEST_DIR/after-video.md5"
ffmpeg -v error -i "$TASK_TEST_DIR/native.ts" -map 0:a:0 -f framemd5 "$TASK_TEST_DIR/before-audio.md5"
ffmpeg -v error -i "$TASK_TEST_DIR/native.ts.paced.ts" -map 0:a:0 -f framemd5 "$TASK_TEST_DIR/after-audio.md5"
cmp "$TASK_TEST_DIR/before-video.md5" "$TASK_TEST_DIR/after-video.md5"
cmp "$TASK_TEST_DIR/before-audio.md5" "$TASK_TEST_DIR/after-audio.md5"
echo "Paced vs immediate stream: decoded video and audio checksums match exactly"
ffprobe -v error -count_frames -show_streams -of json "$TASK_TEST_DIR/native.ts" > "$TASK_TEST_DIR/probe.json"
python3 - "$TASK_TEST_DIR/probe.json" <<'PY'
import json,sys
streams={s['codec_type']:s for s in json.load(open(sys.argv[1]))['streams']}
assert streams['video']['codec_name']=='h264'
assert int(streams['video']['nb_read_frames'])==360, streams['video']
assert streams['audio']['codec_name']=='aac'
assert streams['audio']['sample_rate']=='48000'
assert int(streams['audio']['nb_read_frames'])>=550,streams['audio']
print('Production Swift MPEG-TS decoded: 360 video frames + AAC audio OK')
PY
