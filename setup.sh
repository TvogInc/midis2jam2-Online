#!/bin/bash
set -e

# 1. Detect Codespace Hardware Specs
CORES=$(nproc)
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')

echo "🔍 Detected Codespace Hardware: ${CORES} CPU Cores, ${RAM_MB}MB RAM"

if [ "$CORES" -ge 16 ]; then
    TIER="Ultra (16+ Cores)"
    RES="1280x720x24"
    GL_THREADS=$((CORES - 2))
    VNC_FLAGS="-wait 5 -defer 5"
    VNC_QUALITY="quality=8&compression=1"
    AUDIO_BITRATE="192k"
elif [ "$CORES" -ge 8 ]; then
    TIER="High (8 Cores)"
    RES="960x540x16"
    GL_THREADS=6
    VNC_FLAGS="-wait 10 -defer 10 -noxdamage"
    VNC_QUALITY="quality=5&compression=2"
    AUDIO_BITRATE="128k"
elif [ "$CORES" -ge 4 ]; then
    TIER="Standard (4 Cores)"
    RES="800x450x16"
    GL_THREADS=3
    VNC_FLAGS="-wait 20 -defer 20 -noxdamage"
    VNC_QUALITY="quality=3&compression=4"
    AUDIO_BITRATE="96k"
else
    TIER="Basic (2 Cores)"
    RES="640x360x16"
    GL_THREADS=2
    VNC_FLAGS="-wait 30 -defer 30 -noxdamage"
    VNC_QUALITY="quality=2&compression=6"
    AUDIO_BITRATE="64k"
fi

echo "⚙️ Applying optimal profile: ${TIER} | Res: ${RES} | OpenGL Threads: ${GL_THREADS}"

# 2. Install required system packages
sudo apt-get update
sudo apt-get install -y openjdk-17-jdk xvfb fluxbox x11vnc novnc websockify \
    pulseaudio ffmpeg python3-flask libgl1-mesa-dri mesa-utils

# 3. Start Virtual Audio Sink (PulseAudio)
pulseaudio --kill 2>/dev/null || true
pulseaudio --start --exit-idle-time=-1
pactl load-module module-null-sink sink_name=VirtualSpeaker sink_properties=device.description="VirtualSpeaker"
pactl set-default-sink VirtualSpeaker

# 4. Start Virtual Display & noVNC with hardware-tuned settings
pkill Xvfb 2>/dev/null || true
pkill x11vnc 2>/dev/null || true
pkill websockify 2>/dev/null || true

export DISPLAY=:1
Xvfb :1 -screen 0 ${RES} &
sleep 2
fluxbox &
x11vnc -display :1 -nopw -listen localhost -xkb -forever ${VNC_FLAGS} &
websockify --web=/usr/share/novnc/ 6080 localhost:5900 &

# 5. Build midis2jam2
chmod +x ./gradlew
./gradlew installDist

# 6. Generate Web Player & Audio Streamer (app.py)
mkdir -p uploads
cat << EOF > app.py
import os, subprocess
from flask import Flask, request, render_template_string, Response

app = Flask(__name__)
UPLOAD_FOLDER = os.path.abspath('uploads')
current_process = None

HTML = """
<!DOCTYPE html>
<html>
<head>
    <title>midis2jam2 Web Player (${TIER})</title>
    <style>
        body { font-family: sans-serif; background: #121212; color: white; margin: 0; display: flex; flex-direction: column; height: 100vh; }
        header { background: #1f1f1f; padding: 10px 20px; display: flex; align-items: center; gap: 15px; border-bottom: 1px solid #333; flex-wrap: wrap; }
        .badge { background: #2d2d2d; color: #4fc3f7; padding: 4px 10px; border-radius: 12px; font-size: 12px; font-weight: bold; }
        button { background: #0078d4; color: white; border: none; padding: 8px 14px; border-radius: 4px; cursor: pointer; font-weight: bold; }
        button:hover { background: #005a9e; }
        iframe { flex: 1; border: none; width: 100%; }
    </style>
</head>
<body>
    <header>
        <strong>🎹 midis2jam2 Online</strong>
        <span class="badge">${TIER} (${RES})</span>
        <form action="/upload" method="post" enctype="multipart/form-data" style="display:flex; gap:10px;">
            <input type="file" name="midi" accept=".mid,.midi" required>
            <button type="submit">Upload & Play</button>
        </form>
        <audio id="audio" controls autoplay src="/audio.mp3"></audio>
    </header>
    <iframe id="vnc" src=""></iframe>
    <script>
        const host = window.location.hostname.replace('-5000.', '-6080.');
        document.getElementById('vnc').src = \`https://\${host}/vnc.html?autoconnect=true&resize=scale&${VNC_QUALITY}\`;
    </script>
</body>
</html>
"""

@app.route('/')
def index():
    return render_template_string(HTML)

@app.route('/upload', methods=['POST'])
def upload():
    global current_process
    file = request.files['midi']
    if file:
        path = os.path.join(UPLOAD_FOLDER, file.filename)
        file.save(path)
        if current_process:
            current_process.terminate()
        env = os.environ.copy()
        env["DISPLAY"] = ":1"
        env["LIBGL_ALWAYS_SOFTWARE"] = "1"
        env["LP_NUM_THREADS"] = "${GL_THREADS}"
        bin_path = "./build/install/midis2jam2/bin/midis2jam2"
        current_process = subprocess.Popen([bin_path, path], env=env)
    return '<script>window.location.href="/";</script>'

@app.route('/audio.mp3')
def audio_stream():
    cmd = ["ffmpeg", "-fflags", "nobuffer", "-flags", "low_delay", "-f", "pulse", "-i", "VirtualSpeaker.monitor", "-ac", "2", "-f", "mp3", "-b:a", "${AUDIO_BITRATE}", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return Response(proc.stdout, mimetype="audio/mpeg")

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, threaded=True)
EOF

python3 app.py
