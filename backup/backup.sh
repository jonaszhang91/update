#!/bin/bash

# ==================== 配置区域 ====================
# 数据库配置
MYSQL_USER="root"
MYSQL_PASSWORD='N0mur@4$99!'
DATABASE_NAME="kpos"

# 文件夹配置（需要备份/恢复的静态资源目录）
IMAGES_SOURCE_DIR="/Wisdomount/Menusifu/data/static/images"

# 备份文件存储目录（可自定义）
BACKUP_BASE_DIR="/home/menu/backup"

# 日期时间后缀（用于备份文件名）
DATE_SUFFIX=$(date +%Y%m%d_%H%M%S)

# 备份文件名
SQL_BACKUP_FILE="${BACKUP_BASE_DIR}/${DATABASE_NAME}_${DATE_SUFFIX}.sql.gz"
IMAGES_BACKUP_FILE="${BACKUP_BASE_DIR}/images_${DATE_SUFFIX}.tar.gz"

# 恢复时需要使用的备份文件（交互式输入）
# =================================================

# 颜色输出（便于阅读）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印带颜色的消息
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查命令是否成功
check_success() {
    if [ $? -eq 0 ]; then
        info "$1 成功"
    else
        error "$1 失败"
        exit 1
    fi
}

# ==================== 备份函数 ====================
do_backup() {
    info "开始完整备份（数据库 + 文件夹）..."

    # 创建备份目录
    mkdir -p ${BACKUP_BASE_DIR}
    check_success "创建备份目录 ${BACKUP_BASE_DIR}"

    # 1. 备份数据库并压缩
    info "正在备份数据库 ${DATABASE_NAME}..."
    mysqldump -u${MYSQL_USER} -p${MYSQL_PASSWORD} \
        --single-transaction --quick --triggers --routines \
        ${DATABASE_NAME} | gzip > ${SQL_BACKUP_FILE}
    check_success "数据库备份（已压缩）: ${SQL_BACKUP_FILE}"

    # 2. 备份文件夹并压缩（可能需要 sudo）
    info "正在备份文件夹 ${IMAGES_SOURCE_DIR}..."
    # 检查文件夹是否存在
    if [ ! -d "${IMAGES_SOURCE_DIR}" ]; then
        error "文件夹 ${IMAGES_SOURCE_DIR} 不存在，跳过文件夹备份"
    else
        # 使用 sudo 确保有读取权限（如果需要）
        sudo tar -czf ${IMAGES_BACKUP_FILE} ${IMAGES_SOURCE_DIR}
        check_success "文件夹备份（已压缩）: ${IMAGES_BACKUP_FILE}"
    fi

    info "========== 备份完成 =========="
    info "数据库备份文件: ${SQL_BACKUP_FILE}"
    info "文件夹备份文件: ${IMAGES_BACKUP_FILE}"
}

# ==================== 恢复函数 ====================
do_restore() {
    info "开始恢复操作..."

    # 1. 选择要恢复的数据库备份文件
    echo ""
    warn "请提供数据库备份文件（.sql.gz）的完整路径："
    read -p "> " SQL_RESTORE_FILE
    if [ ! -f "${SQL_RESTORE_FILE}" ]; then
        error "文件 ${SQL_RESTORE_FILE} 不存在，请检查路径"
        exit 1
    fi

    # 2. 选择要恢复的文件夹备份文件
    echo ""
    warn "请提供文件夹备份文件（.tar.gz）的完整路径（如果不需要恢复文件夹，请直接回车跳过）："
    read -p "> " IMAGES_RESTORE_FILE

    # 3. 确认恢复操作（危险）
    echo ""
    warn "========================================"
    warn "恢复操作将覆盖现有数据库和文件夹数据！"
    warn "数据库: ${DATABASE_NAME}"
    warn "文件夹: ${IMAGES_SOURCE_DIR}"
    warn "========================================"
    read -p "确认继续？(输入 yes 继续): " confirm
    if [ "$confirm" != "yes" ]; then
        info "恢复操作已取消"
        exit 0
    fi

    # 4. 恢复数据库
    info "正在恢复数据库 ${DATABASE_NAME}..."
    # 确保数据库存在
    mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS ${DATABASE_NAME};"
    # 解压并导入，同时优化恢复速度
    zcat ${SQL_RESTORE_FILE} | mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} \
        --init-command="SET autocommit=0; SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET sql_log_bin=0;" \
        ${DATABASE_NAME}
    check_success "数据库恢复"

    # 5. 恢复文件夹（如果提供了文件）
    if [ -n "${IMAGES_RESTORE_FILE}" ] && [ -f "${IMAGES_RESTORE_FILE}" ]; then
        info "正在恢复文件夹到 ${IMAGES_SOURCE_DIR}..."
        # 解压到根目录（因为打包时包含了绝对路径）
        sudo tar -xzvf ${IMAGES_RESTORE_FILE} -C /
        check_success "文件夹恢复"
    else
        info "未提供文件夹备份文件，跳过文件夹恢复"
    fi

    info "========== 恢复完成 =========="
    info "请手动验证数据完整性"
}

# ==================== 主菜单 ====================
show_menu() {
    echo ""
    echo "====================================="
    echo "    MySQL + 文件夹 备份/恢复工具"
    echo "====================================="
    echo "1) 备份（数据库 + 文件夹）"
    echo "2) 恢复（数据库 + 文件夹）"
    echo "3) 退出"
    echo "====================================="
    read -p "请选择 [1-3]: " choice
    case $choice in
        1)
            do_backup
            ;;
        2)
            do_restore
            ;;
        3)
            info "退出程序"
            exit 0
            ;;
        *)
            error "无效选择，请输入 1, 2 或 3"
            show_menu
            ;;
    esac
}

# 检查必要命令是否存在
for cmd in mysqldump mysql tar gzip zcat sudo; do
    if ! command -v $cmd &> /dev/null; then
        error "命令 $cmd 未找到，请先安装"
        exit 1
    fi
done

# 检查是否以 root 运行（推荐，因为可能需要 sudo 操作文件夹）
if [ "$EUID" -eq 0 ]; then
    warn "当前以 root 用户运行，将自动拥有所有权限"
else
    warn "当前用户非 root，某些操作可能需要输入 sudo 密码"
fi

# 运行主菜单
show_menu