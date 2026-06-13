#!/bin/bash

echo "======================检查环境变量======================"

if [ -z "$ADMIN_PASSWORD" ]; then
  echo "错误：没有设置 ADMIN_PASSWORD"
  exit 1
fi

if [ -z "$HF_TOKEN" ]; then
  echo "错误：没有设置 HF_TOKEN"
  exit 1
fi

HF_REPO_ID="${HF_REPO_ID:-q121351857/baidu-backup}"
HF_TARGET_DIR="${HF_TARGET_DIR:-baihu}"
HF_PRIVATE="${HF_PRIVATE:-false}"

echo "ADMIN_PASSWORD 已设置"
echo "HF_TOKEN 已设置"
echo "HF_REPO_ID=$HF_REPO_ID"
echo "HF_TARGET_DIR=$HF_TARGET_DIR"
echo "HF_PRIVATE=$HF_PRIVATE"


echo "======================安装浏览器环境======================"

# 设置 Playwright / cloakbrowser 环境
python -m pip install -U pip
python -m pip install -U cloakbrowser huggingface_hub

python -m cloakbrowser install || true
python -m cloakbrowser info || true

# 安装 Playwright 依赖
python -m playwright install-deps || true


echo "======================启动虚拟显示环境======================"

# 创建虚拟显示环境，如需调用 export DISPLAY=:99
if ! pgrep -f "Xvfb :99" >/dev/null 2>&1; then
  Xvfb :99 -screen 0 1920x1080x24 &
fi

export DISPLAY=:99


echo "======================安装 PM2 并启动白虎服务======================"

npm install pm2 -g

# 开启白虎服务
pm2 start "./baihu server" --name baihu || pm2 restart baihu

echo "10秒后开始恢复任务..."
sleep 10


echo "======================从日志中获取默认密码======================"

DEFAULT_PASSWORD=$(tail -n 200 ~/.pm2/logs/baihu-out.log 2>/dev/null \
    | grep -oP '密\s*码:\s*\K[^,[:space:]]+' \
    | tail -n 1 || true)

echo "默认用户名: admin"

if [ -n "$DEFAULT_PASSWORD" ]; then
  echo "已获取默认密码"
else
  echo "未获取到默认密码，可能服务已经初始化过或日志格式变化"
fi


echo "======================从 Hugging Face 下载最新备份======================"

mkdir -p /app/backup_tmp

export HF_TOKEN
export HF_REPO_ID
export HF_TARGET_DIR
export HF_PRIVATE

DOWNLOAD_RESULT_FILE="/app/backup_tmp/download_result.txt"
rm -f "$DOWNLOAD_RESULT_FILE"

python3 - <<'PY'
import os
from pathlib import Path
from huggingface_hub import HfApi, hf_hub_download

token = os.environ.get("HF_TOKEN")
repo_id = os.environ.get("HF_REPO_ID", "q121351857/baidu-backup")
target_dir = os.environ.get("HF_TARGET_DIR", "baihu").strip("/")

download_dir = Path("/app/backup_tmp")
download_dir.mkdir(parents=True, exist_ok=True)

result_file = download_dir / "download_result.txt"

api = HfApi(token=token)

print(f"正在读取 Hugging Face Dataset：{repo_id}")

try:
    files = api.list_repo_files(
        repo_id=repo_id,
        repo_type="dataset",
        token=token,
    )
except Exception as e:
    print(f"读取 Hugging Face 仓库失败：{e}")
    result_file.write_text("", encoding="utf-8")
    raise SystemExit(0)

if target_dir:
    prefix = target_dir.rstrip("/") + "/"
else:
    prefix = ""

backup_files = [
    f for f in files
    if f.startswith(prefix)
    and f.endswith(".zip")
    and Path(f).name.startswith("backup_")
]

backup_files = sorted(backup_files)

print("检测到的远程备份文件：")
for f in backup_files:
    print(f" - {f}")

if not backup_files:
    print("没有发现远程备份，跳过恢复")
    result_file.write_text("", encoding="utf-8")
    raise SystemExit(0)

latest_file = backup_files[-1]
print(f"选择最新备份：{latest_file}")

try:
    downloaded_path = hf_hub_download(
        repo_id=repo_id,
        filename=latest_file,
        repo_type="dataset",
        token=token,
        local_dir=str(download_dir),
        local_dir_use_symlinks=False,
    )
except TypeError:
    downloaded_path = hf_hub_download(
        repo_id=repo_id,
        filename=latest_file,
        repo_type="dataset",
        token=token,
        local_dir=str(download_dir),
    )

downloaded_path = Path(downloaded_path)

print(f"最新备份已下载到：{downloaded_path}")
result_file.write_text(str(downloaded_path), encoding="utf-8")
PY

LATEST_BACKUP_FILE="$(cat "$DOWNLOAD_RESULT_FILE" 2>/dev/null || true)"


echo "======================执行备份恢复======================"

if [ -n "$LATEST_BACKUP_FILE" ] && [ -f "$LATEST_BACKUP_FILE" ]; then
  echo "找到备份文件：$LATEST_BACKUP_FILE"
  echo "开始恢复备份..."

  ./baihu restore "$LATEST_BACKUP_FILE"

  echo "备份恢复完成，重启白虎服务..."
  pm2 restart baihu

  echo "等待白虎服务启动..."
  sleep 10

  echo "清理临时文件..."
  rm -rf /app/backup_tmp
else
  echo "没有可恢复的备份，按初次安装处理"
fi


echo "======================确认或重置白虎后台密码======================"

rm -f cookies.txt headers.txt login_response.txt

echo "先尝试使用 ADMIN_PASSWORD 登录..."

curl -c cookies.txt -s -D headers.txt -o login_response.txt \
  'http://localhost:8052/api/v1/auth/login' \
  -H 'content-type: application/json' \
  --data-raw "{\"username\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" || true

ADMIN_TOKEN="$(awk -F'[=;]' '/Set-Cookie: BHToken=/{print $2}' headers.txt 2>/dev/null || true)"

if [ -n "$ADMIN_TOKEN" ]; then
  echo "ADMIN_PASSWORD 登录成功，无需重置密码"
else
  echo "ADMIN_PASSWORD 登录失败，尝试使用默认密码重置..."

  if [ -z "$DEFAULT_PASSWORD" ]; then
    echo "没有获取到默认密码，无法自动重置密码"
    echo "如果你是从备份恢复的，请使用备份里的旧密码登录"
  else
    rm -f cookies.txt headers.txt login_response.txt

    curl -c cookies.txt -s -D headers.txt -o login_response.txt \
      'http://localhost:8052/api/v1/auth/login' \
      -H 'content-type: application/json' \
      --data-raw "{\"username\":\"admin\",\"password\":\"$DEFAULT_PASSWORD\"}" || true

    BHToken="$(awk -F'[=;]' '/Set-Cookie: BHToken=/{print $2}' headers.txt 2>/dev/null || true)"

    if [ -z "$BHToken" ]; then
      echo "默认密码登录失败，无法自动重置密码"
      echo "可能是备份里的密码不是默认密码，也不是 ADMIN_PASSWORD"
    else
      RESET_RESPONSE=$(
        curl -b cookies.txt -s \
          'http://localhost:8052/api/v1/settings/password' \
          -H 'content-type: application/json' \
          --data-raw "{\"old_password\":\"$DEFAULT_PASSWORD\",\"new_password\":\"$ADMIN_PASSWORD\"}"
      )

      echo "重置密码接口返回：$RESET_RESPONSE"
    fi
  fi
fi

rm -f cookies.txt headers.txt login_response.txt


echo "======================启动脚本执行完成======================"

tail -f /dev/null
