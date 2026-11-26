#!/usr/bin/env bash
# 每次升级在阿里云 ECS 上运行。解决 elabctl 两个坑：
#   1) elabctl update 的 docker compose pull 失败时不一定中止，还会打印「已是最新版本」；
#   2) 无法确认容器是否真的换成了新镜像。
# 本脚本先做 fail-fast 的 pull，再调 elabctl update，最后比对镜像 ID。
#
# 用法：
#   ./elab-update.sh 6.1.0
#
# ACR 域名默认自动从 CONF_FILE 的 image 行提取，兼容新个人版 crpi-*.personal.cr.aliyuncs.com
# 和旧个人版 registry[-vpc].<region>.aliyuncs.com，不需要手工拼。
# 可覆盖的环境变量：CONF_FILE（默认 /etc/elabftw.yml）、
#                   ELAB_WEB_CONTAINER_NAME（默认 elabftw）、ACR_REGISTRY（强制指定域名）
set -euo pipefail

VER="${1:?用法: $0 <eLabFTW版本>，例如 6.1.0}"
CONF_FILE="${CONF_FILE:-/etc/elabftw.yml}"
WEB_CONTAINER="${ELAB_WEB_CONTAINER_NAME:-elabftw}"

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行（sudo $0 ...）" >&2
  exit 1
fi
if [ ! -f "$CONF_FILE" ]; then
  echo "找不到配置文件 $CONF_FILE" >&2
  exit 1
fi

ACR_HINT="${ACR_REGISTRY:-}"
if [ -z "$ACR_HINT" ]; then
  ACR_HINT=$(grep -m1 'elabimg' "$CONF_FILE" | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s#/.*##; s/[[:space:]]*$//' || true)
fi
if [ -z "$ACR_HINT" ]; then
  echo "ERROR: 无法从 $CONF_FILE 提取 ACR 域名，请显式设置 ACR_REGISTRY=<域名>" >&2
  exit 1
fi

echo "== 1/4 检查是否还有指向 Docker Hub 的镜像 =="
if grep -nE 'image:[[:space:]]*((docker\.io/)?elabftw/elabimg|(docker\.io/)?(library/)?mysql:)' "$CONF_FILE"; then
  echo "ERROR: 以上行仍指向 Docker Hub，先运行 switch-to-acr.sh" >&2
  exit 1
fi
grep -n 'image:' "$CONF_FILE"

echo "== 2/4 预检 ACR 可达 =="
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${ACR_HINT}/v2/" || true)
echo "https://${ACR_HINT}/v2/ -> ${code:-无响应}"
if [ "$code" != "401" ] && [ "$code" != "200" ]; then
  echo "ERROR: ACR 不可达。请核对 ACR 控制台概览页上的 VPC 域名（同地域 ECS）或公网域名。" >&2
  echo "       也可通过 ACR_REGISTRY=<域名> 显式指定。" >&2
  exit 1
fi

echo "== 3/4 显式 pull（失败立即中止，不依赖 elabctl 的错误处理）=="
docker compose -f "$CONF_FILE" pull

echo "== 4/4 elabctl update（按提示回答备份 / 数据库迁移）=="
elabctl update

echo "== 结果校验：容器是否真的换了镜像 =="
EXPECTED=$(grep -m1 'elabimg' "$CONF_FILE" | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')
if ! docker image inspect "$EXPECTED" >/dev/null 2>&1; then
  echo "ERROR: 本地找不到镜像 $EXPECTED" >&2
  exit 1
fi
PULLED_ID=$(docker image inspect --format '{{.Id}}' "$EXPECTED")
RUNNING_ID=$(docker inspect --format '{{.Image}}' "$WEB_CONTAINER")
echo "目标镜像 : $EXPECTED"
echo "其镜像 ID: $PULLED_ID"
echo "容器镜像 ID: $RUNNING_ID"
if [ "$PULLED_ID" != "$RUNNING_ID" ]; then
  echo "ERROR: 容器仍在跑旧镜像！elabctl 打印的『已是最新版本』不可信，请检查上面的 pull 输出。" >&2
  exit 1
fi
echo "OK: 容器确实运行在 $EXPECTED"
echo "最后请在网页右下角确认版本号，并确认数据库迁移已执行（上一步选了 N 则手动跑 elabctl update-db-schema）。"
