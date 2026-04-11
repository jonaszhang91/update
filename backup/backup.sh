#!/bin/bash

# ==================== 配置区域 ====================
MYSQL_USER="root"
MYSQL_PASSWORD='N0mur@4$99!'
DATABASE_NAME="kpos"
IMAGES_SOURCE_DIR="/Wisdomount/Menusifu/data/static/images"
BACKUP_DIR="/home/menu/backup"

# Google Drive 配置
RCLONE_REMOTE="gdrive"          # rclone 配置的 remote 名称
RCLONE_BACKUP_DIR="backup"      # 云端备份文件夹
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

    # 检查是否已安装 rclone
    if command -v rclone &> /dev/null; then
        local rclone_path=$(which rclone)
        local version=$(rclone version --check-normal 2>/dev/null | head -1 | awk '{print $2}')
        info "已安装 rclone，路径: $rclone_path，版本: $version"

        # 如果是 snap 安装的版本，提示并卸载（snap 版通常版本低且配置路径特殊）
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
            # 非 snap 版，询问是否更新到最新（可选，默认不更新，避免不必要的操作）
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

    # 未安装 rclone 或已卸载 snap 版，执行全新安装
    warn "未找到可用的 rclone，正在安装最新版本..."
    sudo -v || { error "需要 sudo 权限安装 rclone"; exit 1; }
    curl https://rclone.org/install.sh | sudo bash
    if [ $? -eq 0 ]; then
        info "rclone 安装成功"
        # 验证安装
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
    # 设置 rclone 配置文件路径
    if [ ! -f "$RCLONE_CONFIG_FILE" ]; then
        error "找不到 rclone 配置文件: $RCLONE_CONFIG_FILE"
        error "请将有效的 rclone.conf 放在脚本同目录下"
        exit 1
    fi
    export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"
    export RCLONE_CONFIG_PASS="$RCLONE_CONFIG_PASS"
    info "已设置 rclone 配置解密密码"

    # 测试 rclone 连接
    if ! rclone lsd ${RCLONE_REMOTE}: &>/dev/null; then
        error "rclone 无法连接到 Google Drive，请检查配置文件或密码"
        exit 1
    fi
    info "Google Drive 连接正常"
}

# 确保本地备份目录存在
mkdir -p "$BACKUP_DIR"

# ==================== 备份函数 ====================
do_backup() {
    info "开始完整备份（数据库 + 文件夹）..."

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)_$$
    SQL_FILE="${DATABASE_NAME}_${TIMESTAMP}.sql.gz"
    IMAGES_FILE="images_${TIMESTAMP}.tar.gz"
    SQL_LOCAL_PATH="${BACKUP_DIR}/${SQL_FILE}"
    IMAGES_LOCAL_PATH="${BACKUP_DIR}/${IMAGES_FILE}"

    # 1. 备份数据库
    info "正在备份数据库 ${DATABASE_NAME} ..."
    mysqldump -u${MYSQL_USER} -p${MYSQL_PASSWORD} \
        --single-transaction --quick --triggers --routines \
        ${DATABASE_NAME} | gzip > ${SQL_LOCAL_PATH}
    if [ $? -eq 0 ] && [ -s ${SQL_LOCAL_PATH} ]; then
        info "数据库备份成功: ${SQL_LOCAL_PATH} ($(du -h ${SQL_LOCAL_PATH} | cut -f1))"
    else
        error "数据库备份失败"
        exit 1
    fi

    # 2. 备份文件夹（如果存在）
    if [ -d "${IMAGES_SOURCE_DIR}" ]; then
        info "正在备份文件夹 ${IMAGES_SOURCE_DIR} ..."
        sudo tar -czf ${IMAGES_LOCAL_PATH} ${IMAGES_SOURCE_DIR}
        if [ $? -eq 0 ] && [ -s ${IMAGES_LOCAL_PATH} ]; then
            info "文件夹备份成功: ${IMAGES_LOCAL_PATH} ($(du -h ${IMAGES_LOCAL_PATH} | cut -f1))"
        else
            warn "文件夹备份失败，将只上传数据库备份"
            rm -f ${IMAGES_LOCAL_PATH}
        fi
    else
        warn "文件夹 ${IMAGES_SOURCE_DIR} 不存在，跳过文件夹备份"
    fi

    # 3. 上传到 Google Drive
    info "上传数据库备份到 ${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/ ..."
    rclone copy "${SQL_LOCAL_PATH}" "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
    if [ $? -eq 0 ]; then
        info "数据库备份上传成功"
    else
        error "数据库备份上传失败"
        exit 1
    fi

    if [ -f "${IMAGES_LOCAL_PATH}" ]; then
        info "上传文件夹备份到 ${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/ ..."
        rclone copy "${IMAGES_LOCAL_PATH}" "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
        if [ $? -eq 0 ]; then
            info "文件夹备份上传成功"
        else
            warn "文件夹备份上传失败，请检查网络"
        fi
    fi

    info "========== 备份完成 =========="
    info "本地文件保存在: ${BACKUP_DIR}"
    info "云端文件保存在: ${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
}

# ==================== 恢复通用函数 ====================
restore_database_file() {
    local file_path="$1"
    info "正在恢复数据库从: $(basename "$file_path")"

    local file_type
    file_type=$(file -b "$file_path" | grep -oE 'gzip|XZ|bzip2' | head -1)
    
    case "$file_type" in
        gzip)
            info "检测到 gzip 压缩格式"
            gunzip -c "$file_path" | mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
                --init-command="SET autocommit=0; SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET sql_log_bin=0;" \
                "${DATABASE_NAME}"
            ;;
        XZ)
            info "检测到 XZ 压缩格式"
            xz -d -c "$file_path" | mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
                --init-command="SET autocommit=0; SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET sql_log_bin=0;" \
                "${DATABASE_NAME}"
            ;;
        bzip2)
            info "检测到 bzip2 压缩格式"
            bunzip2 -c "$file_path" | mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
                --init-command="SET autocommit=0; SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET sql_log_bin=0;" \
                "${DATABASE_NAME}"
            ;;
        *)
            error "无法识别的压缩格式，尝试直接作为 SQL 文件导入"
            mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${DATABASE_NAME}" < "$file_path"
            ;;
    esac

    if [ $? -eq 0 ]; then
        info "数据库恢复成功"
    else
        error "数据库恢复失败"
        exit 1
    fi
}

restore_images_file() {
    local tar_file="$1"
    info "正在恢复文件夹到 ${IMAGES_SOURCE_DIR}..."
    sudo tar -xzvf "$tar_file" -C /
    if [ $? -eq 0 ]; then
        info "文件夹恢复成功"
    else
        warn "文件夹恢复失败，请手动检查"
    fi
}

# ==================== 从本地恢复 ====================
restore_from_local() {
    info "扫描本地备份文件夹: ${BACKUP_DIR}"

    mapfile -t sql_files < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.sql.gz" -o -name "*.sql.xz" -o -name "*.sql.bz2" \) | sort)
    if [ ${#sql_files[@]} -eq 0 ]; then
        error "在 ${BACKUP_DIR} 中没有找到数据库备份文件"
        return 1
    fi

    echo ""
    warn "========== 可用的本地数据库备份文件 =========="
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
    selected_sql="${sql_files[$((sql_choice-1))]}"
    info "已选择: $(basename "$selected_sql")"

    mapfile -t images_files < <(find "$BACKUP_DIR" -maxdepth 1 -name "images_*.tar.gz" 2>/dev/null | sort)
    restore_img="n"
    selected_images=""
    if [ ${#images_files[@]} -gt 0 ]; then
        echo ""
        warn "========== 可用的本地文件夹备份文件 =========="
        for i in "${!images_files[@]}"; do
            filename=$(basename "${images_files[$i]}")
            size=$(du -h "${images_files[$i]}" | cut -f1)
            echo "  [$((i+1))] ${filename} (${size})"
        done
        read -p "是否同时恢复文件夹备份？(输入序号或 n): " img_choice
        if [[ "$img_choice" =~ ^[0-9]+$ ]] && [ $img_choice -ge 1 ] && [ $img_choice -le ${#images_files[@]} ]; then
            selected_images="${images_files[$((img_choice-1))]}"
            restore_img="y"
        fi
    fi

    echo ""
    warn "========================================"
    warn "即将执行恢复操作，将覆盖现有数据！"
    warn "数据库: ${DATABASE_NAME}"
    [ "$restore_img" = "y" ] && warn "文件夹: ${IMAGES_SOURCE_DIR}"
    warn "========================================"
    read -p "确认继续？(输入 yes 继续): " confirm
    if [ "$confirm" != "yes" ]; then
        info "恢复操作已取消"
        return
    fi

    restore_database_file "$selected_sql"
    if [ "$restore_img" = "y" ] && [ -n "$selected_images" ]; then
        restore_images_file "$selected_images"
    fi

    info "========== 恢复完成 =========="
}

# ==================== 从 Google Drive 恢复 ====================
restore_from_cloud() {
    info "从 Google Drive 获取备份文件列表..."

    local remote_files=()
    while IFS= read -r line; do
        remote_files+=("$line")
    done < <(rclone ls "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/" | grep -E "\.sql\.(gz|xz|bz2)$" | sort -r)

    if [ ${#remote_files[@]} -eq 0 ]; then
        error "云端没有找到数据库备份文件"
        return 1
    fi

    echo ""
    warn "========== 可用的云端数据库备份文件 =========="
    for i in "${!remote_files[@]}"; do
        filename=$(echo "${remote_files[$i]}" | awk '{$1=""; print substr($0,2)}')
        size=$(echo "${remote_files[$i]}" | awk '{print $1}')
        echo "  [$((i+1))] ${filename} (${size} bytes)"
    done
    echo "  [0] 取消"
    read -p "请选择要恢复的数据库备份 [序号]: " sql_choice
    if [[ ! $sql_choice =~ ^[0-9]+$ ]] || [ $sql_choice -eq 0 ]; then
        info "取消恢复操作"
        return
    fi
    if [ $sql_choice -lt 1 ] || [ $sql_choice -gt ${#remote_files[@]} ]; then
        error "无效选择"
        return
    fi
    selected_line="${remote_files[$((sql_choice-1))]}"
    remote_filename=$(echo "$selected_line" | awk '{$1=""; print substr($0,2)}')
    info "已选择: ${remote_filename}"

    # 下载到临时目录
    local temp_dir="/tmp/kpos_restore_$$"
    mkdir -p "$temp_dir"
    local local_file="${temp_dir}/${remote_filename}"
    info "正在下载 ${remote_filename} ..."
    rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${remote_filename}" "$temp_dir/"
    if [ $? -ne 0 ] || [ ! -f "$local_file" ]; then
        error "下载失败"
        rm -rf "$temp_dir"
        return 1
    fi
    info "下载完成: $(du -h "$local_file" | cut -f1)"

    # 可选：列出云端文件夹备份
    local remote_images=()
    while IFS= read -r line; do
        remote_images+=("$line")
    done < <(rclone ls "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/" | grep "images_.*\.tar\.gz" | sort -r)

    restore_img="n"
    local images_local_file=""
    if [ ${#remote_images[@]} -gt 0 ]; then
        echo ""
        warn "========== 可用的云端文件夹备份文件 =========="
        for i in "${!remote_images[@]}"; do
            filename=$(echo "${remote_images[$i]}" | awk '{$1=""; print substr($0,2)}')
            size=$(echo "${remote_images[$i]}" | awk '{print $1}')
            echo "  [$((i+1))] ${filename} (${size} bytes)"
        done
        read -p "是否同时恢复文件夹备份？(输入序号或 n): " img_choice
        if [[ "$img_choice" =~ ^[0-9]+$ ]] && [ $img_choice -ge 1 ] && [ $img_choice -le ${#remote_images[@]} ]; then
            selected_img_line="${remote_images[$((img_choice-1))]}"
            remote_img_filename=$(echo "$selected_img_line" | awk '{$1=""; print substr($0,2)}')
            images_local_file="${temp_dir}/${remote_img_filename}"
            info "下载文件夹备份 ${remote_img_filename} ..."
            rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${remote_img_filename}" "$temp_dir/"
            if [ $? -eq 0 ] && [ -f "$images_local_file" ]; then
                restore_img="y"
            else
                warn "文件夹备份下载失败，将跳过"
            fi
        fi
    fi

    # 确认恢复
    echo ""
    warn "========================================"
    warn "即将执行恢复操作，将覆盖现有数据！"
    warn "数据库: ${DATABASE_NAME}"
    [ "$restore_img" = "y" ] && warn "文件夹: ${IMAGES_SOURCE_DIR}"
    warn "========================================"
    read -p "确认继续？(输入 yes 继续): " confirm
    if [ "$confirm" != "yes" ]; then
        info "恢复操作已取消"
        rm -rf "$temp_dir"
        return
    fi

    restore_database_file "$local_file"
    if [ "$restore_img" = "y" ] && [ -n "$images_local_file" ]; then
        restore_images_file "$images_local_file"
    fi

    # 清理临时目录
    rm -rf "$temp_dir"
    info "========== 恢复完成 =========="
}

# ==================== 主菜单 ====================
show_menu() {
    echo ""
    echo "========================================="
    echo "     数据库 + 文件夹 备份/恢复工具"
    echo "     本地备份目录: ${BACKUP_DIR}"
    echo "     云端目录: ${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}"
    echo "========================================="
    echo "1) 备份（本地 + 上传 Google Drive）"
    echo "2) 恢复（从本地备份目录）"
    echo "3) 恢复（从 Google Drive 下载）"
    echo "4) 退出"
    echo "========================================="
    read -p "请选择 [1-4]: " choice
    case $choice in
        1) do_backup ;;
        2) restore_from_local ;;
        3) restore_from_cloud ;;
        4) info "退出程序"; exit 0 ;;
        *) error "无效选择"; show_menu ;;
    esac
}

# ==================== 脚本入口 ====================
# 1. 自动安装/更新 rclone
install_or_update_rclone

# 2. 检查其他依赖
check_dependencies

# 3. 配置 rclone 连接
setup_rclone

# 4. 互斥锁检查
exec 200> "$LOCK_FILE"
if ! flock -n 200; then
    error "另一个备份/恢复脚本正在运行，请稍后再试"
    exit 1
fi

# 5. 运行主菜单
show_menu