#!/bin/bash

# ==================== 配置区域 ====================
MYSQL_USER="root"
MYSQL_PASSWORD='N0mur@4$99!'
DATABASE_NAME="kpos"
IMAGES_SOURCE_DIR="/Wisdomount/Menusifu/data/static/images"
TOMCAT_WEBAPP_DIR="/opt/apache-tomcat-7.0.93/webapps/kpos"
TOMCAT_LOGS_DIR="/opt/apache-tomcat-7.0.93/logs"
BACKUP_DIR="/home/menu/backup"

# Google Drive 配置
RCLONE_REMOTE="gdrive"          # rclone 配置的 remote 名称
RCLONE_BACKUP_DIR="backup"      # 云端备份文件夹（根目录）
RCLONE_CONFIG_FILE="./rclone.conf"   # 配置文件位于脚本当前目录
RCLONE_CONFIG_PASS="262410ZXj."      # rclone 配置文件解密密码

# 互斥锁文件
LOCK_FILE="/tmp/kpos_backup.lock"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
# =================================================

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_success() {
    if [ $? -eq 0 ]; then
        info "$1 成功"
    else
        error "$1 失败"
        exit 1
    fi
}

# 退出时删除配置文件
cleanup() {
    if [ -f "$RCLONE_CONFIG_FILE" ]; then
        rm -f "$RCLONE_CONFIG_FILE"
        info "已删除配置文件: $RCLONE_CONFIG_FILE"
    fi
}
trap cleanup EXIT

# ==================== 自动安装/更新 rclone ====================
install_or_update_rclone() {
    info "检查 rclone 安装状态..."
    if command -v rclone &> /dev/null; then
        local rclone_path=$(which rclone)
        local version=$(rclone version --check-normal 2>/dev/null | head -1 | awk '{print $2}')
        info "已安装 rclone，路径: $rclone_path，版本: $version"
        if [[ "$rclone_path" == *"/snap/"* ]]; then
            warn "检测到 snap 安装的 rclone，该版本可能存在兼容性问题，正在卸载..."
            sudo snap remove rclone
            if [ $? -eq 0 ]; then
                info "snap 版 rclone 已卸载"
            else
                error "卸载 snap 版 rclone 失败，请手动执行 'sudo snap remove rclone' 后重试"
                exit 1
            fi
        else
            read -p "是否更新 rclone 到最新版本？(y/n，默认 n): " update_choice
            if [[ "$update_choice" == "y" || "$update_choice" == "Y" ]]; then
                info "开始更新 rclone..."
                sudo -v || { error "需要 sudo 权限更新 rclone"; exit 1; }
                curl https://rclone.org/install.sh | sudo bash
                if [ $? -eq 0 ]; then
                    info "rclone 更新成功"
                else
                    error "rclone 更新失败"
                    exit 1
                fi
            else
                info "跳过 rclone 更新，使用现有版本"
            fi
            return 0
        fi
    fi
    warn "未找到可用的 rclone，正在安装最新版本..."
    sudo -v || { error "需要 sudo 权限安装 rclone"; exit 1; }
    curl https://rclone.org/install.sh | sudo bash
    if [ $? -eq 0 ]; then
        info "rclone 安装成功"
        if command -v rclone &> /dev/null; then
            info "rclone 已安装至: $(which rclone)"
        else
            error "rclone 安装后仍无法找到命令，请检查 PATH"
            exit 1
        fi
    else
        error "rclone 安装失败"
        exit 1
    fi
}

# ==================== 其他依赖检查 ====================
check_dependencies() {
    local deps=("mysqldump" "mysql" "tar" "gzip" "zcat" "gunzip" "xz" "bunzip2" "sudo" "curl")
    for cmd in "${deps[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            error "命令 $cmd 未找到，请先安装"
            exit 1
        fi
    done
}

# ==================== rclone 配置与密码处理 ====================
setup_rclone() {
    if [ ! -f "$RCLONE_CONFIG_FILE" ]; then
        error "找不到 rclone 配置文件: $RCLONE_CONFIG_FILE"
        error "请将有效的 rclone.conf 放在脚本同目录下"
        exit 1
    fi
    export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"
    export RCLONE_CONFIG_PASS="$RCLONE_CONFIG_PASS"
    info "已设置 rclone 配置解密密码"

    if ! rclone lsd ${RCLONE_REMOTE}: &>/dev/null; then
        error "rclone 无法连接到 Google Drive，请检查配置文件或密码"
        exit 1
    fi
    info "Google Drive 连接