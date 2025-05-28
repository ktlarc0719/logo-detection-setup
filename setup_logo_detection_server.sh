#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# 必要なパッケージ
sudo apt update
sudo apt upgrade -y --fix-missing
sudo apt install -y ca-certificates curl gnupg lsb-release python3 python3-venv

# 2. Dockerのインストール
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 3. ローカル用ディレクトリを作成
sudo mkdir -p /opt/logo_detection
cd /opt/logo_detection

# 4. Python 仮想環境作成 & Flask インストール
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask
deactivate

# 5. pull_restart_server.py を配置
cat <<EOF | sudo tee /opt/logo_detection/pull_restart_server.py > /dev/null
from flask import Flask, jsonify
import subprocess

app = Flask(__name__)

@app.route("/", methods=["GET"])
def pull_and_restart():
    pull = subprocess.run(
        ["docker", "pull", "kentatsujikawadev/logo-detection:latest"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    stop = subprocess.run(
        ["docker", "stop", "logo-detection"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    rm = subprocess.run(
        ["docker", "rm", "logo-detection"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    run = subprocess.run(
        ["docker", "run", "-dit", "--name", "logo-detection", "--restart=always", "-p", "10000:10000", "-p", "9000:9000", "kentatsujikawadev/logo-detection:latest"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    return jsonify({
        "pull": pull.stdout + pull.stderr,
        "stop": stop.stdout + stop.stderr,
        "rm": rm.stdout + rm.stderr,
        "run": run.stdout + run.stderr
    }), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF

# 6. systemd サービスファイル作成
cat <<EOF | sudo tee /etc/systemd/system/pull_restart_server.service > /dev/null
[Unit]
Description=Pull & Restart Docker Image via Flask API
After=network.target

[Service]
ExecStart=/opt/logo_detection/venv/bin/python /opt/logo_detection/pull_restart_server.py
WorkingDirectory=/opt/logo_detection
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 7. systemd サービス起動
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable pull_restart_server
sudo systemctl restart pull_restart_server

# 8. Flaskサーバの起動を待ってから初回リクエストを送信
for i in {1..10}; do
    if curl -s http://127.0.0.1:8080/ > /dev/null; then
        echo "✅ 初回のDocker起動リクエスト送信成功"
        break
    else
        echo "⌛ Flask起動待ち中 ($i/10)..."
        sleep 2
    fi
done

echo "🎉 Setup 完了"
