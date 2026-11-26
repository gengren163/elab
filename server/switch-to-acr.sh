#!/usr/bin/env bash
# 在阿里云 ECS 上运行：把 /etc/elabftw.yml 的两个 image: 行切到 ACR，其余配置一律不动。
# 只需在首次接入时执行一次；以后换版本用 elab-update.sh，或重跑本脚本传新版本号。
#
# 用法（推荐：第三个参数直接填 ACR 控制台概览页上的 VPC 域名）：
#   ./switch-to-acr.sh <命名空间> <版本> <ACR-VPC域名>
#   ./switch-to-acr.sh elabmirror 6.1.0 crpi-xxxx-vpc.cn-hangzhou.personal.cr.aliyuncs.com
#
# 兼容 2024-09-04 之前创建的旧个人版实例（registry[-vpc].<region>.aliyuncs.com）：
#   ./switch-to-acr.sh elabmirror 6.1.0 cn-hangzhou              # 同地域 VPC
#   ./switch-to-acr.sh elabmirror 6.1.0 cn-hangzhou --public      # 公网
#
# 注意：2024-09-04 起新建的个人版实例使用独立域名 crpi-*.personal.cr.aliyuncs.com，
# 不要自己拼 registry-vpc.<region>.aliyuncs.com。一律以控制台「概览」页显示为准。
# CONF_FILE 环境变量可覆盖默认的 /etc/elabftw.yml。
set -euo pipefail

NS="${1:?用法: $0 <命名空间> <版本> <ACR域名或地域> [--public]}"
VER="${2:?请给出 eLabFTW 版本号，例如 6.1.0}"
TARGET="${3:?请给出 ACR 的 VPC 域名（从控制台概览页复制），或旧版实例的地域如 cn-hangzhou}"
MODE="${4:-}"
CONF_FILE="${CONF_FILE:-/etc/elabftw.yml}"

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行（sudo $0 ...）" >&2
  exit 1
fi
if [ ! -f "$CONF_FILE" ]; then
  echo "找不到配置文件 $CONF_FILE" >&2
  exit 1
fi
if [[ "$TARGET" == *.* ]]; then
  REG="$TARGET"
else
  if [ "$MODE" = "--public" ]; then
    REG="registry.${TARGET}.aliyuncs.com"
  else
    REG="registry-vpc.${TARGET}.aliyuncs.com"
  fi
fi

echo "检查 ACR 域名 $REG 是否可达 ..."
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${REG}/v2/" || true)
if [ "$code" != "401" ] && [ "$code" != "200" ]; then
  echo "ERROR: https://${REG}/v2/ 返回 ${code:-无响应}。" >&2
  echo "       请从 ACR 控制台「概览」页复制域名；同地域 ECS 用 VPC 域名，跨地域用公网域名。" >&2
  exit 1
fi

# 保留原有的 MySQL tag：跨大版本升级数据库有风险，不擅自改。
MYSQL_VER=$(grep -E '^[[:space:]]*image:' "$CONF_FILE" | grep -oE 'mysql:[0-9][^[:space:]]*' | head -n1 | cut -d: -f2 || true)
MYSQL_VER="${MYSQL_VER:-8.4}"

STAMP=$(date +%F_%H%M%S)
BAK="${CONF_FILE}.bak-acr-${STAMP}"
cp -a "$CONF_FILE" "$BAK"
echo "已备份原配置到 $BAK"

# 三类写法都兼容：elabftw/elabimg:X、<registry>/<ns>/elabimg:X、mysql:X / library/mysql:X / <registry>/<ns>/mysql:X
sed -i -E \
  -e "s#^([[:space:]]*image:[[:space:]]*)[^[:space:]]*/elabimg:[^[:space:]]+#\1${REG}/${NS}/elabimg:${VER}#" \
  -e "s#^([[:space:]]*image:[[:space:]]*)(docker\.io/)?(library/)?mysql:[^[:space:]]+#\1${REG}/${NS}/mysql:${MYSQL_VER}#" \
  -e "s#^([[:space:]]*image:[[:space:]]*)[^[:space:]]*/mysql:[^[:space:]]+#\1${REG}/${NS}/mysql:${MYSQL_VER}#" \
  "$CONF_FILE"

echo "--- 改动内容 ---"
diff -u "$BAK" "$CONF_FILE" || true
echo "----------------"

n=$(grep -c "${REG}/${NS}/" "$CONF_FILE" || true)
if [ "$n" -lt 2 ]; then
  echo "ERROR: 只替换了 $n 行，预期 2 行。请检查 image 行是否被注释，或是否用了 digest 固定写法（@sha256:...）。" >&2
  echo "原文件未丢失，可手动恢复：$BAK" >&2
  exit 1
fi
if grep -nE 'image:[[:space:]]*((docker\.io/)?elabftw/elabimg|(docker\.io/)?(library/)?mysql:)' "$CONF_FILE"; then
  echo "ERROR: 以上行仍指向 Docker Hub，elabctl update 会再次超时" >&2
  exit 1
fi

docker compose -f "$CONF_FILE" config -q
echo "YAML 校验通过。当前镜像配置："
grep -n 'image:' "$CONF_FILE"
echo
echo "下一步：确认 ACR 里已有 <命名空间>/elabimg:${VER} 和 <命名空间>/mysql:${MYSQL_VER}，"
echo "然后运行 ./elab-update.sh ${VER}"
