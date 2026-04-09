#!/bin/bash

# ==================== 配置区域 ====================
MYSQL_USER="root"
MYSQL_PASSWORD='N0mur@4$99!'
DATABASE_NAME="kpos"
IMAGES_SOURCE_DIR="/Wisdomount/Menusifu/data/static/images"
BACKUP_DIR="/home/menu/backup"          # 备份存储目录
LOCK_FILE="/var/run/backup_kpos.lock"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

# ==================== 备份函数 ====================
do_backup() {
    info "开始完整备份（数据库 + 文件夹）..."

    mkdir -p "${BACKUP_DIR}"
    check_success "创建备份目录 ${BACKUP_DIR}"

    DATE_SUFFIX=$(date +%Y%m%d_%H%M%S)_$$
    SQL_BACKUP_FILE="${BACKUP_DIR}/${DATABASE_NAME}_${DATE_SUFFIX}.sql.gz"
    IMAGES_BACKUP_FILE="${BACKUP_DIR}/images_${DATE_SUFFIX}.tar.gz"

    info "正在备份数据库 ${DATABASE_NAME}..."
    mysqldump -u${MYSQL_USER} -p${MYSQL_PASSWORD} \
        --single-transaction --quick --triggers --routines \
        ${DATABASE_NAME} | gzip > ${SQL_BACKUP_FILE}
    check_success "数据库备份: ${SQL_BACKUP_FILE}"

    if [ ! -d "${IMAGES_SOURCE_DIR}" ]; then
        warn "文件夹 ${IMAGES_SOURCE_DIR} 不存在，跳过文件夹备份"
    else
        info "正在备份文件夹 ${IMAGES_SOURCE_DIR}..."
        sudo tar -czf ${IMAGES_BACKUP_FILE} ${IMAGES_SOURCE_DIR}
        check_success "文件夹备份: ${IMAGES_BACKUP_FILE}"
    fi

    info "========== 备份完成 =========="
    info "文件保存在: ${BACKUP_DIR}"
}

# ==================== 恢复函数（含恢复前自动备份） ====================
do_restore() {
    info "开始恢复操作..."

    if [ ! -d "${BACKUP_DIR}" ]; then
        error "备份目录 ${BACKUP_DIR} 不存在，请先备份或修改 BACKUP_DIR 配置"
        exit 1
    fi

    # 列出数据库备份文件
    mapfile -t sql_files < <(find "${BACKUP_DIR}" -maxdepth 1 -name "${DATABASE_NAME}_*.sql.gz" 2>/dev/null | grep -v "pre_restore_" | sort)
    if [ ${#sql_files[@]} -eq 0 ]; then
        error "在 ${BACKUP_DIR} 中没有找到数据库备份文件（排除 pre_restore_ 文件）"
        exit 1
    fi

    echo ""
    warn "========== 可用的数据库备份文件 =========="
    for i in "${!sql_files[@]}"; do
        filename=$(basename "${sql_files[$i]}")
        size=$(du -h "${sql_files[$i]}" | cut -f1)
        echo "  [$((i+1))] ${filename} (${size})"
    done
    echo "  [0] 取消"
    read -p "请选择要恢复的数据库备份 [序号]: " sql_choice
    if [[ ! $sql_choice =~ ^[0-9]+$ ]] || [ $sql_choice -eq 0 ]; then
        info "取消恢复操作"
        return
    fi
    if [ $sql_choice -lt 1 ] || [ $sql_choice -gt ${#sql_files[@]} ]; then
        error "无效选择"
        return
    fi
    SQL_RESTORE_FILE="${sql_files[$((sql_choice-1))]}"
    info "已选择数据库备份: $(basename ${SQL_RESTORE_FILE})"

    # 列出文件夹备份文件
    mapfile -t images_files < <(find "${BACKUP_DIR}" -maxdepth 1 -name "images_*.tar.gz" 2>/dev/null | grep -v "pre_restore_" | sort)
    IMAGES_RESTORE_FILE=""
    if [ ${#images_files[@]} -gt 0 ]; then
        echo ""
        warn "========== 可用的文件夹备份文件 =========="
        echo "  [0] 跳过文件夹恢复"
        for i in "${!images_files[@]}"; do
            filename=$(basename "${images_files[$i]}")
            size=$(du -h "${images_files[$i]}" | cut -f1)
            echo "  [$((i+1))] ${filename} (${size})"
        done
        read -p "请选择要恢复的文件夹备份 [序号]: " img_choice
        if [[ $img_choice =~ ^[0-9]+$ ]] && [ $img_choice -gt 0 ] && [ $img_choice -le ${#images_files[@]} ]; then
            IMAGES_RESTORE_FILE="${images_files[$((img_choice-1))]}"
            info "已选择文件夹备份: $(basename ${IMAGES_RESTORE_FILE})"
        else
            info "跳过文件夹恢复"
        fi
    else
        warn "没有找到文件夹备份文件，将只恢复数据库"
    fi

    # ========== 恢复前备份当前状态 ==========
    echo ""
    warn "========== 安全措施：恢复前自动备份当前数据 =========="
    read -p "是否在恢复前备份当前数据？(yes/no，默认 yes): " pre_backup_confirm
    if [[ "$pre_backup_confirm" != "no" ]]; then
        info "开始执行恢复前备份..."
        PRE_RESTORE_SUFFIX="pre_restore_$(date +%Y%m%d_%H%M%S)_$$"
        SQL_PRE_BACKUP="${BACKUP_DIR}/${DATABASE_NAME}_${PRE_RESTORE_SUFFIX}.sql.gz"
        IMAGES_PRE_BACKUP="${BACKUP_DIR}/images_${PRE_RESTORE_SUFFIX}.tar.gz"
        
        info "备份当前数据库到: ${SQL_PRE_BACKUP}"
        mysqldump -u${MYSQL_USER} -p${MYSQL_PASSWORD} \
            --single-transaction --quick --triggers --routines \
            ${DATABASE_NAME} | gzip > ${SQL_PRE_BACKUP}
        if [ $? -eq 0 ]; then
            info "当前数据库备份成功"
        else
            warn "当前数据库备份失败，是否继续恢复？(yes/no)"
            read -p "" continue_restore
            if [[ "$continue_restore" != "yes" ]]; then
                info "已取消恢复操作"
                return
            fi
        fi
        
        if [ -d "${IMAGES_SOURCE_DIR}" ]; then
            info "备份当前文件夹到: ${IMAGES_PRE_BACKUP}"
            sudo tar -czf ${IMAGES_PRE_BACKUP} ${IMAGES_SOURCE_DIR}
            if [ $? -eq 0 ]; then
                info "当前文件夹备份成功"
            else
                warn "当前文件夹备份失败，但将继续恢复（建议手动检查）"
            fi
        fi
        info "恢复前备份完成，文件保存在: ${BACKUP_DIR}"
    else
        info "跳过恢复前备份（风险自担）"
    fi

    # 最终确认
    echo ""
    warn "========================================"
    warn "即将执行恢复操作，将覆盖现有数据！"
    warn "数据库: ${DATABASE_NAME}"
    if [ -n "${IMAGES_RESTORE_FILE}" ]; then
        warn "文件夹: ${IMAGES_SOURCE_DIR}"
    fi
    warn "========================================"
    read -p "确认继续？(输入 yes 继续): " confirm
    if [ "$confirm" != "yes" ]; then
        info "恢复操作已取消"
        return
    fi

    # 恢复数据库
    info "正在恢复数据库 ${DATABASE_NAME}..."
    mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS ${DATABASE_NAME};"
    zcat ${SQL_RESTORE_FILE} | mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} \
        --init-command="SET autocommit=0; SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET sql_log_bin=0;" \
        ${DATABASE_NAME}
    check_success "数据库恢复"

    if [ -n "${IMAGES_RESTORE_FILE}" ]; then
        info "正在恢复文件夹到 ${IMAGES_SOURCE_DIR}..."
        sudo tar -xzvf ${IMAGES_RESTORE_FILE} -C /
        check_success "文件夹恢复"
    fi

    info "========== 恢复完成 =========="
    info "恢复前备份已保存，如有问题可使用 pre_restore_ 文件回滚"
}

# ==================== 主菜单 ====================
show_menu() {
    echo ""
    echo "====================================="
    echo "    MySQL + 文件夹 备份/恢复工具"
    echo "    备份目录: ${BACKUP_DIR}"
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

# 互斥锁
exec 200> "$LOCK_FILE"
if ! flock -n 200; then
    error "另一个备份/恢复脚本正在运行，请稍后再试"
    exit 1
fi

# 检查必要命令
for cmd in mysqldump mysql tar gzip zcat sudo; do
    if ! command -v $cmd &> /dev/null; then
        error "命令 $cmd 未找到，请先安装"
        exit 1
    fi
done

show_menu