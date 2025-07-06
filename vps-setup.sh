#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# 色付き出力
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🚀 Logo Detection API VPS Setup v2${NC}"
echo "======================================"

# 1. 必要なパッケージをインストール
echo -e "${YELLOW}📦 Installing required packages...${NC}"
sudo apt update && sudo apt upgrade -y
sudo apt install -y ca-certificates curl gnupg lsb-release python3 python3-venv

# 2. Dockerのインストール（既にインストールされている場合はスキップ）
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}🐳 Installing Docker...${NC}"
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker $USER
else
    echo -e "${GREEN}✓ Docker already installed${NC}"
fi

# 3. アプリケーション用ディレクトリを作成
echo -e "${YELLOW}📁 Creating directories...${NC}"
sudo mkdir -p /opt/logo-detection/{logs,data}
cd /opt/logo-detection

# 4. 環境設定ファイルを作成（2コア2GB VPS向け）
echo -e "${YELLOW}⚙️ Creating environment configuration...${NC}"
cat <<'EOF' | sudo tee /opt/logo-detection/.env > /dev/null
# VPS Configuration for Logo Detection API
# Optimized for 2-core 2GB VPS

# Performance Settings
MAX_CONCURRENT_DETECTIONS=2
MAX_CONCURRENT_DOWNLOADS=15
MAX_BATCH_SIZE=30

# Environment
ENVIRONMENT=production
LOG_LEVEL=INFO

# API Settings
PORT=8000
EOF

# 5. Flask管理サーバーのセットアップ
echo -e "${YELLOW}🔧 Setting up management server...${NC}"
python3 -m venv /opt/logo-detection/venv
source /opt/logo-detection/venv/bin/activate
pip install --upgrade pip
pip install flask
deactivate

# 6. 管理APIサーバーを作成
cat <<'EOF' | sudo tee /opt/logo-detection/manager.py > /dev/null
from flask import Flask, jsonify, request
import subprocess
import os
import json
import time
from datetime import datetime

app = Flask(__name__)

# Configuration
DOCKER_IMAGE = "kentatsujikawadev/logo-detection-api:latest"
CONTAINER_NAME = "logo-detection-api"
API_PORT = 8000

def load_env():
    """Load environment variables from .env file"""
    env_vars = {}
    env_file = "/opt/logo-detection/.env"
    if os.path.exists(env_file):
        with open(env_file, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    env_vars[key.strip()] = value.strip()
    return env_vars

def run_docker_command(cmd):
    """Execute docker command and return result"""
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return {
        "command": " ".join(cmd),
        "stdout": result.stdout,
        "stderr": result.stderr,
        "returncode": result.returncode,
        "success": result.returncode == 0
    }

@app.route("/", methods=["GET"])
def index():
    """Dashboard with current status"""
    # Get container status
    ps_result = run_docker_command(["docker", "ps", "-a", "--filter", f"name={CONTAINER_NAME}", "--format", "json"])
    
    container_info = None
    if ps_result["stdout"]:
        try:
            container_info = json.loads(ps_result["stdout"].strip())
        except:
            pass
    
    # Get current configuration
    env_vars = load_env()
    
    # Check API health
    health_check = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", f"http://localhost:{API_PORT}/api/v1/health"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    api_healthy = health_check.stdout.strip() == "200"
    
    return jsonify({
        "timestamp": datetime.now().isoformat(),
        "container": {
            "name": CONTAINER_NAME,
            "info": container_info,
            "api_healthy": api_healthy
        },
        "configuration": env_vars,
        "endpoints": {
            "api": f"http://localhost:{API_PORT}",
            "docs": f"http://localhost:{API_PORT}/docs",
            "batch_ui": f"http://localhost:{API_PORT}/ui/batch"
        }
    }), 200

@app.route("/deploy", methods=["POST"])
def deploy():
    """Pull latest image and deploy/restart container"""
    results = {}
    
    # 1. Pull latest image
    print("Pulling latest image...")
    results["pull"] = run_docker_command(["docker", "pull", DOCKER_IMAGE])
    
    # 2. Stop existing container
    print("Stopping existing container...")
    results["stop"] = run_docker_command(["docker", "stop", CONTAINER_NAME])
    
    # 3. Remove existing container
    print("Removing existing container...")
    results["rm"] = run_docker_command(["docker", "rm", CONTAINER_NAME])
    
    # 4. Load environment variables
    env_vars = load_env()
    
    # 5. Build docker run command
    docker_cmd = [
        "docker", "run", "-d",
        "--name", CONTAINER_NAME,
        "--restart=always",
        "-p", f"{API_PORT}:8000",
        "-v", "/opt/logo-detection/logs:/app/logs",
        "-v", "/opt/logo-detection/data:/app/data"
    ]
    
    # Add environment variables
    for key, value in env_vars.items():
        docker_cmd.extend(["-e", f"{key}={value}"])
    
    docker_cmd.append(DOCKER_IMAGE)
    
    # 6. Start new container
    print("Starting new container...")
    results["run"] = run_docker_command(docker_cmd)
    
    # 7. Wait and check health
    time.sleep(5)
    health_check = subprocess.run(
        ["curl", "-s", f"http://localhost:{API_PORT}/api/v1/health"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    
    try:
        health_data = json.loads(health_check.stdout) if health_check.stdout else None
    except:
        health_data = None
    
    results["health"] = {
        "status_code": health_check.returncode,
        "data": health_data
    }
    
    # Determine overall success
    success = results["run"]["success"] and health_data is not None
    
    return jsonify({
        "success": success,
        "message": "Deployment successful" if success else "Deployment failed",
        "results": results
    }), 200 if success else 500

@app.route("/logs", methods=["GET"])
def logs():
    """Get container logs"""
    lines = request.args.get("lines", "100")
    follow = request.args.get("follow", "false").lower() == "true"
    
    cmd = ["docker", "logs", "--tail", lines]
    if follow:
        cmd.append("-f")
    cmd.append(CONTAINER_NAME)
    
    result = run_docker_command(cmd)
    
    return jsonify({
        "lines": lines,
        "logs": result["stdout"] + result["stderr"],
        "success": result["success"]
    }), 200

@app.route("/config", methods=["GET", "POST"])
def config():
    """Get or update configuration"""
    if request.method == "GET":
        return jsonify(load_env()), 200
    
    # POST - Update configuration
    new_config = request.json
    if not new_config:
        return jsonify({"error": "No configuration provided"}), 400
    
    # Load existing config
    env_vars = load_env()
    
    # Update with new values
    env_vars.update(new_config)
    
    # Write back to file
    with open("/opt/logo-detection/.env", "w") as f:
        f.write("# Logo Detection API Configuration\n")
        f.write(f"# Updated: {datetime.now().isoformat()}\n\n")
        for key, value in env_vars.items():
            f.write(f"{key}={value}\n")
    
    return jsonify({
        "message": "Configuration updated. Run /deploy to apply changes.",
        "config": env_vars
    }), 200

@app.route("/restart", methods=["POST"])
def restart():
    """Restart container without pulling new image"""
    results = {}
    
    results["restart"] = run_docker_command(["docker", "restart", CONTAINER_NAME])
    
    # Wait and check health
    time.sleep(5)
    health_check = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", f"http://localhost:{API_PORT}/api/v1/health"],
        stdout=subprocess.PIPE, text=True
    )
    
    results["health_check"] = {
        "http_code": health_check.stdout.strip(),
        "healthy": health_check.stdout.strip() == "200"
    }
    
    return jsonify(results), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
EOF

# 7. systemdサービスファイルを作成
echo -e "${YELLOW}🔧 Creating systemd service...${NC}"
cat <<EOF | sudo tee /etc/systemd/system/logo-detection-manager.service > /dev/null
[Unit]
Description=Logo Detection API Manager
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/opt/logo-detection/venv/bin/python /opt/logo-detection/manager.py
WorkingDirectory=/opt/logo-detection
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

# 8. パーミッション設定
echo -e "${YELLOW}🔐 Setting permissions...${NC}"
sudo chown -R $USER:$USER /opt/logo-detection
sudo chmod -R 755 /opt/logo-detection

# 9. サービスを開始
echo -e "${YELLOW}🚀 Starting services...${NC}"
sudo systemctl daemon-reload
sudo systemctl enable logo-detection-manager
sudo systemctl restart logo-detection-manager

# 10. 管理サーバーの起動を待つ
echo -e "${YELLOW}⏳ Waiting for management server...${NC}"
for i in {1..10}; do
    if curl -s http://localhost:8080/ > /dev/null; then
        echo -e "${GREEN}✓ Management server is running${NC}"
        break
    fi
    sleep 2
done

# 11. 初回デプロイ
echo -e "${YELLOW}🐳 Deploying Logo Detection API...${NC}"
curl -X POST http://localhost:8080/deploy

# 12. APIの起動を待つ
echo -e "${YELLOW}⏳ Waiting for API to start...${NC}"
for i in {1..20}; do
    if curl -s http://localhost:8000/api/v1/health > /dev/null; then
        echo -e "${GREEN}✓ API is running${NC}"
        break
    fi
    sleep 3
done

# 13. 最終確認
echo -e "${YELLOW}📊 Final status check...${NC}"
curl -s http://localhost:8080/ | python3 -m json.tool

# 14. 完了メッセージ
PUBLIC_IP=$(curl -s ifconfig.me)

echo ""
echo -e "${GREEN}🎉 Setup completed successfully!${NC}"
echo ""
echo -e "${GREEN}📍 Access Points:${NC}"
echo "  API: http://${PUBLIC_IP}:8000"
echo "  API Docs: http://${PUBLIC_IP}:8000/docs"
echo "  Batch UI: http://${PUBLIC_IP}:8000/ui/batch"
echo "  Manager: http://${PUBLIC_IP}:8080"
echo ""
echo -e "${GREEN}🔧 Management Commands:${NC}"
echo "  Status: curl http://localhost:8080/"
echo "  Deploy: curl -X POST http://localhost:8080/deploy"
echo "  Logs: curl http://localhost:8080/logs"
echo "  Config: curl http://localhost:8080/config"
echo ""
echo -e "${GREEN}📝 Configuration Update Example:${NC}"
echo '  curl -X POST http://localhost:8080/config \'
echo '    -H "Content-Type: application/json" \'
echo '    -d {"MAX_CONCURRENT_DETECTIONS":"3"}'
