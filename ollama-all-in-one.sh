#!/bin/bash
#=============================================================
# Ollama + Open WebUI 全自动一键部署脚本
# 适配：WSL2 / Ubuntu，支持：
#   - 未安装 Ollama → 自动安装
#   - 已有 Windows Ollama 桌面版 → 自动对接
#   - 已有 WSL Ollama → 自动复用
#   - 无 Docker → 自动安装
# 用法：bash ollama-all-in-one.sh
#=============================================================

set -e

# ---------- 颜色输出 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  ▶ $*${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ok()    { echo -e "  ${GREEN}✔ $*${NC}"; }

# ---------- 全局配置 ----------
WEBUI_PORT=3000
OLLAMA_PORT=11434
SUGGEST_MODEL=""
OLLAMA_URL=""
OLLAMA_INSTALLED=false

# ---------- 工具函数 ----------
get_sudo() {
    if [ "$EUID" -eq 0 ]; then
        echo ""
    else
        echo "sudo"
    fi
}
SUDO=$(get_sudo)

# ================================================================
# 第 1 步：系统环境检查
# ================================================================
step "第 1 步 / 共 6 步：系统环境检查"

# 内存检测
TOTAL_MEM_GB=$(free -g | awk '/^Mem:/{print $2}')
AVAIL_MEM_GB=$(free -g | awk '/^Mem:/{print $7}')
info "系统总内存：${TOTAL_MEM_GB} GB，当前可用：${AVAIL_MEM_GB} GB"

# 推荐模型
if [ "$TOTAL_MEM_GB" -lt 8 ]; then
    SUGGEST_MODEL="qwen2.5-coder:3b"
    warn "内存偏小（<8GB），推荐轻量模型：${SUGGEST_MODEL}"
elif [ "$TOTAL_MEM_GB" -lt 16 ]; then
    SUGGEST_MODEL="qwen2.5-coder:7b"
    info "推荐模型：${SUGGEST_MODEL}（日常脚本/MES开发够用）"
elif [ "$TOTAL_MEM_GB" -lt 32 ]; then
    SUGGEST_MODEL="qwen2.5-coder:14b"
    info "推荐模型：${SUGGEST_MODEL}（业务理解更强，幻觉更少）"
else
    SUGGEST_MODEL="qwen2.5-coder:14b"
    info "硬件不错，推荐模型：${SUGGEST_MODEL}（可后续自行下载 32b）"
fi

# 磁盘空间检查
DISK_FREE_GB=$(df -BG . | awk 'NR==2{gsub("G","",$4); print $4}')
info "当前磁盘可用：${DISK_FREE_GB} GB"
if [ "$DISK_FREE_GB" -lt 10 ]; then
    warn "磁盘空间不足 10GB，模型下载可能不够（7B模型约需5GB）"
fi

# ================================================================
# 第 2 步：智能检测 Ollama（本地 / Windows桌面版 / 都没有）
# ================================================================
step "第 2 步 / 共 6 步：检测 Ollama 服务"

# 探测函数：尝试一个地址，成功返回0
probe_ollama() {
    local url="$1"
    curl -s --max-time 2 "$url/api/tags" > /dev/null 2>&1
    return $?
}

# 候选地址列表（优先级从高到低）
CANDIDATES=(
    "http://localhost:${OLLAMA_PORT}"
    "http://127.0.0.1:${OLLAMA_PORT}"
    "http://host.docker.internal:${OLLAMA_PORT}"
)
# 加上 WSL 网关 IP（Windows 主机）
WSL_HOST_IP=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}')
if [ -n "$WSL_HOST_IP" ]; then
    CANDIDATES+=("http://${WSL_HOST_IP}:${OLLAMA_PORT}")
fi

for url in "${CANDIDATES[@]}"; do
    info "探测 Ollama：$url ..."
    if probe_ollama "$url"; then
        OLLAMA_URL="$url"
        OLLAMA_INSTALLED=true
        ok "发现 Ollama 服务：$url"
        break
    fi
done

# 如果命令行有 ollama，说明 WSL 里装了
if command -v ollama &> /dev/null; then
    if [ "$OLLAMA_INSTALLED" = false ]; then
        warn "检测到 ollama 命令但服务未启动，尝试启动..."
        $SUDO systemctl start ollama 2>/dev/null || ollama serve &>/dev/null &
        sleep 3
        if probe_ollama "http://localhost:${OLLAMA_PORT}"; then
            OLLAMA_URL="http://localhost:${OLLAMA_PORT}"
            OLLAMA_INSTALLED=true
            ok "Ollama 服务已启动"
        fi
    fi
fi

# 都没找到 → 安装 Ollama
if [ "$OLLAMA_INSTALLED" = false ]; then
    warn "未检测到 Ollama，开始安装..."
    info "下载 Ollama 官方安装脚本..."
    curl -fsSL https://ollama.com/install.sh | $SUDO sh
    sleep 2

    # 配置 Ollama 允许外部访问（Docker 容器能连）
    info "配置 Ollama 监听 0.0.0.0:${OLLAMA_PORT}..."
    $SUDO mkdir -p /etc/systemd/system/ollama.service.d
    $SUDO tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
Environment="OLLAMA_ORIGINS=*"
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl restart ollama
    sleep 3

    if probe_ollama "http://localhost:${OLLAMA_PORT}"; then
        OLLAMA_URL="http://localhost:${OLLAMA_PORT}"
        OLLAMA_INSTALLED=true
        ok "Ollama 安装并启动成功"
    else
        error "Ollama 安装后仍无法连接，请手动检查：systemctl status ollama"
        exit 1
    fi
fi

# 打印已下载模型
info "当前 Ollama 已有模型："
MODEL_LIST=$(curl -s "$OLLAMA_URL/api/tags" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//' || true)
if [ -z "$MODEL_LIST" ]; then
    echo "    （暂无模型）"
else
    echo "$MODEL_LIST" | sed 's/^/    - /'
fi

# ================================================================
# 第 3 步：检查 / 安装 Docker
# ================================================================
step "第 3 步 / 共 6 步：检查 Docker 环境"

DOCKER=""
if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
        DOCKER="docker"
        ok "Docker 已就绪：$(docker --version)"
    else
        DOCKER="sudo docker"
        ok "Docker 已安装（需 sudo）"
    fi
else
    warn "未安装 Docker，开始安装..."
    $SUDO apt update -qq
    $SUDO apt install -y -qq docker.io docker-compose
    $SUDO systemctl enable --now docker
    $SUDO usermod -aG docker $USER 2>/dev/null || true
    DOCKER="sudo docker"
    ok "Docker 安装完成"
fi

# ================================================================
# 第 4 步：下载推荐模型
# ================================================================
step "第 4 步 / 共 6 步：下载推荐模型"

# 检查是否已有推荐模型
if echo "$MODEL_LIST" | grep -q "${SUGGEST_MODEL%%:*}"; then
    ok "推荐模型已存在，跳过下载"
else
    echo ""
    read -p "  是否下载推荐模型 ${SUGGEST_MODEL}？(y/n) [y]: " DL
    DL=${DL:-y}
    if [ "$DL" = "y" ] || [ "$DL" = "Y" ]; then
        info "开始下载 ${SUGGEST_MODEL}（首次下载需数分钟，请耐心等待）..."
        # 判断是WSL内还是远程Ollama，选择下载方式
        if [[ "$OLLAMA_URL" == "http://localhost:"* ]] || [[ "$OLLAMA_URL" == "http://127.0.0.1:"* ]]; then
            ollama pull "$SUGGEST_MODEL"
        else
            # 远程Ollama，用API下载
            curl -X POST "$OLLAMA_URL/api/pull" -d "{\"name\":\"$SUGGEST_MODEL\"}" || warn "API下载失败，请在Ollama客户端手动下载"
        fi
        ok "模型下载完成"
    else
        warn "跳过下载，稍后可在 Ollama 客户端或 WebUI 里自行下载"
    fi
fi

# ================================================================
# 第 5 步：部署 Open WebUI
# ================================================================
step "第 5 步 / 共 6 步：部署 Open WebUI"

# 清理旧容器
if $DOCKER ps -a --format '{{.Names}}' | grep -q '^open-webui$'; then
    info "发现旧容器，删除重建..."
    $DOCKER rm -f open-webui > /dev/null
fi

info "拉取 Open WebUI 镜像并启动..."
$DOCKER run -d \
  --name open-webui \
  --restart always \
  -p ${WEBUI_PORT}:8080 \
  --add-host=host.docker.internal:host-gateway \
  -e OLLAMA_BASE_URL=${OLLAMA_URL} \
  -e ENABLE_SIGNUP=true \
  -v open-webui:/app/backend/data \
  ghcr.io/open-webui/open-webui:main > /dev/null

ok "容器已创建，等待初始化（约10秒）..."
sleep 10

# 显示容器状态
$DOCKER ps --filter "name=open-webui" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# ================================================================
# 第 6 步：验证 & 完成
# ================================================================
step "第 6 步 / 共 6 步：验证部署结果"

# 验证 Ollama
if probe_ollama "$OLLAMA_URL"; then
    ok "Ollama 服务正常：$OLLAMA_URL"
else
    warn "Ollama 暂时无响应，可能还在启动"
fi

# 验证 WebUI
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:${WEBUI_PORT} || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" ]]; then
    ok "Open WebUI 正常运行：http://localhost:${WEBUI_PORT}"
else
    warn "WebUI 还在初始化，稍等 10 秒后刷新浏览器"
    $DOCKER logs --tail 15 open-webui 2>/dev/null || true
fi

# ================================================================
# 完成
# ================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          🎉  全部部署完成！                      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}🌐  访问地址：${NC}  http://localhost:${WEBUI_PORT}"
echo -e "  ${CYAN}🤖  对接后端：${NC}  ${OLLAMA_URL}"
echo -e "  ${CYAN}📦  推荐模型：${NC}  ${SUGGEST_MODEL}"
echo ""
echo -e "  ${YELLOW}首次使用：${NC}"
echo "  1. 浏览器打开 http://localhost:${WEBUI_PORT}"
echo "  2. 注册本地管理员账号（数据全在你自己机器上）"
echo "  3. 左上角模型下拉框选择已下载的模型"
echo ""
echo -e "  ${BLUE}常用命令：${NC}"
echo "    ollama list                  # 查看本地模型"
echo "    ollama pull <模型名>         # 下载新模型"
echo "    docker ps                    # 查看容器"
echo "    docker restart open-webui    # 重启 WebUI"
echo "    docker logs -f open-webui    # 查看实时日志"
echo ""
echo -e "  ${YELLOW}💡 MES开发提示：把数据库表结构、接口文档上传到知识库（RAG），效果翻倍${NC}"
echo ""
#（注：内容由AI生成）
