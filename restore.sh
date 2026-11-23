#!/bin/bash
# 台账系统一键恢复脚本 (新服务器上执行, 无需任何 AI 助手)
# 前提: 已 git clone 备份仓库, 已解密出 code.tar.gz 和 ledger.db, 且都在本目录
# 用法: bash restore.sh
set -e
echo "=== 台账系统恢复开始 $(date) ==="
[ -f code.tar.gz ] || { echo "缺少 code.tar.gz (先解密)"; exit 1; }
[ -f ledger.db ] || { echo "缺少 ledger.db (先解密)"; exit 1; }
# 1) 解压代码配置到原路径
tar xzf code.tar.gz -C /
# 2) 恢复数据库
mkdir -p /opt/scan-ledger
cp -f ledger.db /opt/scan-ledger/ledger.db
chmod 640 /opt/scan-ledger/ledger.db
# 3) 安装依赖 (阿里云AlibabaLinux/CentOS 或 Ubuntu 都支持)
if command -v dnf >/dev/null; then
  dnf install -y python3 python3-pip git openssl sqlite >/dev/null 2>&1 || true
else
  apt-get update -qq && apt-get install -y -qq python3 python3-pip python3-venv git openssl sqlite3 >/dev/null 2>&1 || true
fi
# 4) venv (与原系统一致; 失败则退回系统python)
if [ ! -x /opt/mpapi/venv/bin/python ]; then
  python3 -m venv /opt/mpapi/venv 2>/dev/null || echo "venv创建失败, 将使用系统python"
fi
PY=/opt/mpapi/venv/bin/python
[ -x "$PY" ] || PY=/usr/bin/python3
"$PY" -m pip install -q fastapi uvicorn
# 5) systemd 服务 (开机自启 + 崩溃自拉起)
cat > /etc/systemd/system/mpapi.service <<UNIT
[Unit]
Description=Ledger Web API
After=network.target
[Service]
WorkingDirectory=/opt/mpapi
ExecStart=$PY -m uvicorn app.ledger_web:app --host 0.0.0.0 --port 8100
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now mpapi
# 6) 恢复每日备份(脚本+cron), 密钥需要你手动放
mkdir -p /opt/backup/daily
cat > /opt/backup/backup_daily.sh <<'BK'
#!/bin/bash
set -e
umask 077
TS=$(date +%F)
D=/opt/backup/daily
mkdir -p "$D"
sqlite3 /opt/scan-ledger/ledger.db ".backup '$D/ledger_$TS.db'"
OK=$(sqlite3 "$D/ledger_$TS.db" "PRAGMA integrity_check;")
if [ "$OK" != "ok" ]; then echo "[$TS] integrity FAILED: $OK" >> "$D/backup.log"; exit 1; fi
tar czf "$D/code_$TS.tar.gz" /opt/mpapi/app/ledger_web.py /opt/mpapi/.env /opt/scan-ledger/ledger.py /opt/scan-ledger/yuyue_auto.py /var/www/nginx-conf/default.conf /root/.hermes/scripts/ledger_due.py 2>/dev/null || true
echo "[$(date '+%F %T')] OK integrity=$OK size=$(stat -c%s $D/ledger_$TS.db)" >> "$D/backup.log"
BK
chmod 700 /opt/backup/backup_daily.sh
echo "30 2 * * * root /opt/backup/backup_daily.sh" > /etc/cron.d/ledger-backup
chmod 644 /etc/cron.d/ledger-backup
echo ""
echo "=== 恢复完成! 验证: curl http://127.0.0.1:8100/ledger/ ==="
echo "浏览器访问: http://本服务器IP:8100/ledger/"
echo ""
echo "还需手动做2件事:"
echo "1. echo '你的解密密钥' > /opt/backup/.backup_pass && chmod 600 /opt/backup/.backup_pass"
echo "2. 建一个新 GitHub token, 然后:"
echo "   cd /opt/backup/ghrepo 2>/dev/null || git clone https://github.com/haveonename/ledger-backup.git /opt/backup/ghrepo"
echo "   cd /opt/backup/ghrepo && git remote set-url origin https://haveonename:新token@github.com/haveonename/ledger-backup.git"
