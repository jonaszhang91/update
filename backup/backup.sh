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
    info "Google Drive 连接正常"
}

mkdir -p "$BACKUP_DIR"

# ==================== 备份函数 ====================
do_backup() {
    info "开始备份流程..."

    # 询问备份哪些内容
    echo ""
    read -p "是否备份数据库？(y/n，默认 y): " backup_db
    backup_db=${backup_db:-y}
    read -p "是否备份图片文件夹 (${IMAGES_SOURCE_DIR})？(y/n，默认 y): " backup_images
    backup_images=${backup_images:-y}
    read -p "是否备份 Tomcat webapp 文件夹 (${TOMCAT_WEBAPP_DIR})？(y/n，默认 y): " backup_tomcat
    backup_tomcat=${backup_tomcat:-y}

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)_$$

    # 备份数据库
    if [[ "$backup_db" == "y" || "$backup_db" == "Y" ]]; then
        SQL_FILE="${DATABASE_NAME}_${TIMESTAMP}.sql.gz"
        SQL_LOCAL_PATH="${BACKUP_DIR}/${SQL_FILE}"
        info "正在备份数据库 ${DATABASE_NAME} ..."
        mysqldump -u${MYSQL_USER} -p${MYSQL_PASSWORD} \
            --single-transaction --quick --triggers --routines \
            ${DATABASE_NAME} | gzip > ${SQL_LOCAL_PATH}
        if [ $? -eq 0 ] && [ -s ${SQL_LOCAL_PATH} ]; then
            info "数据库备份成功: ${SQL_LOCAL_PATH} ($(du -h ${SQL_LOCAL_PATH} | cut -f1))"
            info "上传数据库备份到云端..."
            rclone copy "${SQL_LOCAL_PATH}" "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
            if [ $? -eq 0 ]; then
                info "数据库备份上传成功"
            else
                error "数据库备份上传失败"
                exit 1
            fi
        else
            error "数据库备份失败"
            exit 1
        fi
    fi

    # 备份图片文件夹
    if [[ "$backup_images" == "y" || "$backup_images" == "Y" ]]; then
        if [ ! -d "${IMAGES_SOURCE_DIR}" ]; then
            warn "图片文件夹 ${IMAGES_SOURCE_DIR} 不存在，跳过备份"
        else
            IMAGES_FILE="images_${TIMESTAMP}.tar.gz"
            IMAGES_LOCAL_PATH="${BACKUP_DIR}/${IMAGES_FILE}"
            info "正在备份图片文件夹 ${IMAGES_SOURCE_DIR} ..."
            sudo tar -czf ${IMAGES_LOCAL_PATH} ${IMAGES_SOURCE_DIR}
            if [ $? -eq 0 ] && [ -s ${IMAGES_LOCAL_PATH} ]; then
                info "图片文件夹备份成功: ${IMAGES_LOCAL_PATH} ($(du -h ${IMAGES_LOCAL_PATH} | cut -f1))"
                info "上传图片备份到云端..."
                rclone copy "${IMAGES_LOCAL_PATH}" "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
                if [ $? -eq 0 ]; then
                    info "图片备份上传成功"
                else
                    warn "图片备份上传失败，请检查网络"
                fi
            else
                warn "图片文件夹备份失败"
                rm -f ${IMAGES_LOCAL_PATH}
            fi
        fi
    fi

    # 备份 Tomcat webapp 文件夹
    if [[ "$backup_tomcat" == "y" || "$backup_tomcat" == "Y" ]]; then
        if [ ! -d "${TOMCAT_WEBAPP_DIR}" ]; then
            warn "Tomcat webapp 文件夹 ${TOMCAT_WEBAPP_DIR} 不存在，跳过备份"
        else
            TOMCAT_FILE="kpos_webapp_${TIMESTAMP}.tar.gz"
            TOMCAT_LOCAL_PATH="${BACKUP_DIR}/${TOMCAT_FILE}"
            info "正在备份 Tomcat webapp 文件夹 ${TOMCAT_WEBAPP_DIR} ..."
            sudo tar -czf ${TOMCAT_LOCAL_PATH} ${TOMCAT_WEBAPP_DIR}
            if [ $? -eq 0 ] && [ -s ${TOMCAT_LOCAL_PATH} ]; then
                info "Tomcat webapp 备份成功: ${TOMCAT_LOCAL_PATH} ($(du -h ${TOMCAT_LOCAL_PATH} | cut -f1))"
                info "上传 Tomcat webapp 备份到云端..."
                rclone copy "${TOMCAT_LOCAL_PATH}" "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
                if [ $? -eq 0 ]; then
                    info "Tomcat webapp 备份上传成功"
                else
                    warn "Tomcat webapp 备份上传失败，请检查网络"
                fi
            else
                warn "Tomcat webapp 备份失败"
                rm -f ${TOMCAT_LOCAL_PATH}
            fi
        fi
    fi

    info "========== 备份完成 =========="
    info "本地备份文件保存在: ${BACKUP_DIR}"
    info "云端备份文件保存在: ${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
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
    info "正在恢复图片文件夹到 ${IMAGES_SOURCE_DIR}..."
    sudo tar -xzvf "$tar_file" -C /
    if [ $? -eq 0 ]; then
        info "图片文件夹恢复成功"
    else
        warn "图片文件夹恢复失败，请手动检查"
    fi
}

restore_tomcat_file() {
    local tar_file="$1"
    info "正在恢复 Tomcat webapp 文件夹到 ${TOMCAT_WEBAPP_DIR}..."
    warn "恢复 Tomcat webapp 可能需要重启 Tomcat 服务才能生效"
    sudo tar -xzvf "$tar_file" -C /
    if [ $? -eq 0 ]; then
        info "Tomcat webapp 文件夹恢复成功"
    else
        warn "Tomcat webapp 文件夹恢复失败，请手动检查"
    fi
}

# ==================== 从本地恢复 ====================
restore_from_local() {
    info "扫描本地备份文件夹: ${BACKUP_DIR}"

    # 列出数据库备份
    mapfile -t sql_files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.sql.gz" 2>/dev/null | sort)
    # 列出图片备份
    mapfile -t images_files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "images_*.tar.gz" 2>/dev/null | sort)
    # 列出 Tomcat webapp 备份
    mapfile -t tomcat_files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "kpos_webapp_*.tar.gz" 2>/dev/null | sort)

    # 选择要恢复的内容类型
    echo ""
    warn "========== 选择要恢复的内容类型 =========="
    echo "1) 恢复数据库"
    echo "2) 恢复图片文件夹"
    echo "3) 恢复 Tomcat webapp 文件夹"
    echo "4) 恢复所有（依次选择）"
    echo "0) 返回主菜单"
    read -p "请选择 [0-4]: " type_choice

    case $type_choice in
        1)
            if [ ${#sql_files[@]} -eq 0 ]; then
                error "没有找到数据库备份文件"
                return
            fi
            echo ""
            warn "可用的数据库备份文件："
            for i in "${!sql_files[@]}"; do
                filename=$(basename "${sql_files[$i]}")
                size=$(du -h "${sql_files[$i]}" | cut -f1)
                echo "  [$((i+1))] ${filename} (${size})"
            done
            read -p "请选择要恢复的数据库备份 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#sql_files[@]} ]; then
                selected="${sql_files[$((idx-1))]}"
                read -p "确认恢复数据库？(y/n): " confirm
                if [ "$confirm" = "y" ]; then
                    restore_database_file "$selected"
                fi
            fi
            ;;
        2)
            if [ ${#images_files[@]} -eq 0 ]; then
                error "没有找到图片文件夹备份文件"
                return
            fi
            echo ""
            warn "可用的图片文件夹备份文件："
            for i in "${!images_files[@]}"; do
                filename=$(basename "${images_files[$i]}")
                size=$(du -h "${images_files[$i]}" | cut -f1)
                echo "  [$((i+1))] ${filename} (${size})"
            done
            read -p "请选择要恢复的图片备份 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#images_files[@]} ]; then
                selected="${images_files[$((idx-1))]}"
                read -p "确认恢复图片文件夹？(y/n): " confirm
                if [ "$confirm" = "y" ]; then
                    restore_images_file "$selected"
                fi
            fi
            ;;
        3)
            if [ ${#tomcat_files[@]} -eq 0 ]; then
                error "没有找到 Tomcat webapp 备份文件"
                return
            fi
            echo ""
            warn "可用的 Tomcat webapp 备份文件："
            for i in "${!tomcat_files[@]}"; do
                filename=$(basename "${tomcat_files[$i]}")
                size=$(du -h "${tomcat_files[$i]}" | cut -f1)
                echo "  [$((i+1))] ${filename} (${size})"
            done
            read -p "请选择要恢复的 Tomcat webapp 备份 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#tomcat_files[@]} ]; then
                selected="${tomcat_files[$((idx-1))]}"
                read -p "确认恢复 Tomcat webapp 文件夹？(y/n): " confirm
                if [ "$confirm" = "y" ]; then
                    restore_tomcat_file "$selected"
                fi
            fi
            ;;
        4)
            # 恢复所有：依次执行数据库、图片、Tomcat
            if [ ${#sql_files[@]} -gt 0 ]; then
                echo "最新数据库备份：$(basename "${sql_files[-1]}")"
                read -p "恢复最新数据库？(y/n): " confirm
                [ "$confirm" = "y" ] && restore_database_file "${sql_files[-1]}"
            fi
            if [ ${#images_files[@]} -gt 0 ]; then
                echo "最新图片备份：$(basename "${images_files[-1]}")"
                read -p "恢复最新图片文件夹？(y/n): " confirm
                [ "$confirm" = "y" ] && restore_images_file "${images_files[-1]}"
            fi
            if [ ${#tomcat_files[@]} -gt 0 ]; then
                echo "最新 Tomcat webapp 备份：$(basename "${tomcat_files[-1]}")"
                read -p "恢复最新 Tomcat webapp 文件夹？(y/n): " confirm
                [ "$confirm" = "y" ] && restore_tomcat_file "${tomcat_files[-1]}"
            fi
            ;;
        *)
            info "返回主菜单"
            ;;
    esac
}

# ==================== 从 Google Drive 恢复 ====================
restore_from_cloud() {
    info "从 Google Drive 获取备份文件列表..."

    # 获取云端文件列表
    local remote_files=()
    while IFS= read -r line; do
        remote_files+=("$line")
    done < <(rclone ls "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/" | sort -r)

    if [ ${#remote_files[@]} -eq 0 ]; then
        error "云端没有找到任何备份文件"
        return 1
    fi

    # 按类型分类
    local sql_remote=()
    local images_remote=()
    local tomcat_remote=()
    for line in "${remote_files[@]}"; do
        filename=$(echo "$line" | awk '{$1=""; print substr($0,2)}')
        if [[ "$filename" == ${DATABASE_NAME}_*.sql.gz ]]; then
            sql_remote+=("$line")
        elif [[ "$filename" == images_*.tar.gz ]]; then
            images_remote+=("$line")
        elif [[ "$filename" == kpos_webapp_*.tar.gz ]]; then
            tomcat_remote+=("$line")
        fi
    done

    echo ""
    warn "========== 选择要恢复的内容类型 =========="
    echo "1) 恢复数据库"
    echo "2) 恢复图片文件夹"
    echo "3) 恢复 Tomcat webapp 文件夹"
    echo "4) 恢复所有（依次选择）"
    echo "0) 返回主菜单"
    read -p "请选择 [0-4]: " type_choice

    local temp_dir="/tmp/kpos_restore_$$"
    mkdir -p "$temp_dir"

    case $type_choice in
        1)
            if [ ${#sql_remote[@]} -eq 0 ]; then
                error "云端没有找到数据库备份文件"
                return
            fi
            echo ""
            warn "可用的云端数据库备份文件："
            for i in "${!sql_remote[@]}"; do
                filename=$(echo "${sql_remote[$i]}" | awk '{$1=""; print substr($0,2)}')
                size=$(echo "${sql_remote[$i]}" | awk '{print $1}')
                echo "  [$((i+1))] ${filename} (${size} bytes)"
            done
            read -p "请选择要恢复的数据库备份 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#sql_remote[@]} ]; then
                selected_line="${sql_remote[$((idx-1))]}"
                remote_filename=$(echo "$selected_line" | awk '{$1=""; print substr($0,2)}')
                local_file="${temp_dir}/${remote_filename}"
                info "下载 ${remote_filename} ..."
                rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${remote_filename}" "$temp_dir/"
                if [ -f "$local_file" ]; then
                    read -p "确认恢复数据库？(y/n): " confirm
                    [ "$confirm" = "y" ] && restore_database_file "$local_file"
                else
                    error "下载失败"
                fi
            fi
            ;;
        2)
            if [ ${#images_remote[@]} -eq 0 ]; then
                error "云端没有找到图片文件夹备份文件"
                return
            fi
            echo ""
            warn "可用的云端图片文件夹备份文件："
            for i in "${!images_remote[@]}"; do
                filename=$(echo "${images_remote[$i]}" | awk '{$1=""; print substr($0,2)}')
                size=$(echo "${images_remote[$i]}" | awk '{print $1}')
                echo "  [$((i+1))] ${filename} (${size} bytes)"
            done
            read -p "请选择要恢复的图片备份 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#images_remote[@]} ]; then
                selected_line="${images_remote[$((idx-1))]}"
                remote_filename=$(echo "$selected_line" | awk '{$1=""; print substr($0,2)}')
                local_file="${temp_dir}/${remote_filename}"
                info "下载 ${remote_filename} ..."
                rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${remote_filename}" "$temp_dir/"
                if [ -f "$local_file" ]; then
                    read -p "确认恢复图片文件夹？(y/n): " confirm
                    [ "$confirm" = "y" ] && restore_images_file "$local_file"
                else
                    error "下载失败"
                fi
            fi
            ;;
        3)
            if [ ${#tomcat_remote[@]} -eq 0 ]; then
                error "云端没有找到 Tomcat webapp 备份文件"
                return
            fi
            echo ""
            warn "可用的云端 Tomcat webapp 备份文件："
            for i in "${!tomcat_remote[@]}"; do
                filename=$(echo "${tomcat_remote[$i]}" | awk '{$1=""; print substr($0,2)}')
                size=$(echo "${tomcat_remote[$i]}" | awk '{print $1}')
                echo "  [$((i+1))] ${filename} (${size} bytes)"
            done
            read -p "请选择要恢复的 Tomcat webapp 备份 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#tomcat_remote[@]} ]; then
                selected_line="${tomcat_remote[$((idx-1))]}"
                remote_filename=$(echo "$selected_line" | awk '{$1=""; print substr($0,2)}')
                local_file="${temp_dir}/${remote_filename}"
                info "下载 ${remote_filename} ..."
                rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${remote_filename}" "$temp_dir/"
                if [ -f "$local_file" ]; then
                    read -p "确认恢复 Tomcat webapp 文件夹？(y/n): " confirm
                    [ "$confirm" = "y" ] && restore_tomcat_file "$local_file"
                else
                    error "下载失败"
                fi
            fi
            ;;
        4)
            # 恢复所有：依次处理
            if [ ${#sql_remote[@]} -gt 0 ]; then
                latest=$(echo "${sql_remote[0]}" | awk '{$1=""; print substr($0,2)}')
                read -p "恢复最新数据库备份 ${latest} ? (y/n): " confirm
                if [ "$confirm" = "y" ]; then
                    rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${latest}" "$temp_dir/"
                    restore_database_file "${temp_dir}/${latest}"
                fi
            fi
            if [ ${#images_remote[@]} -gt 0 ]; then
                latest=$(echo "${images_remote[0]}" | awk '{$1=""; print substr($0,2)}')
                read -p "恢复最新图片备份 ${latest} ? (y/n): " confirm
                if [ "$confirm" = "y" ]; then
                    rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${latest}" "$temp_dir/"
                    restore_images_file "${temp_dir}/${latest}"
                fi
            fi
            if [ ${#tomcat_remote[@]} -gt 0 ]; then
                latest=$(echo "${tomcat_remote[0]}" | awk '{$1=""; print substr($0,2)}')
                read -p "恢复最新 Tomcat webapp 备份 ${latest} ? (y/n): " confirm
                if [ "$confirm" = "y" ]; then
                    rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${latest}" "$temp_dir/"
                    restore_tomcat_file "${temp_dir}/${latest}"
                fi
            fi
            ;;
        *)
            info "返回主菜单"
            ;;
    esac

    # 清理临时目录
    rm -rf "$temp_dir"
}

# ==================== 上传指定日期的日志文件（可选择是否包含 appserver.log） ====================
upload_logs() {
    info "上传 Tomcat 日志文件"

    # 输入日期
    read -p "请输入日期 (格式: 年-月-日，例如 2026-03-15): " log_date
    if ! [[ "$log_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        error "日期格式错误，请使用 YYYY-MM-DD 格式"
        return 1
    fi

    year=$(echo "$log_date" | cut -d'-' -f1)
    month=$(echo "$log_date" | cut -d'-' -f2)
    day=$(echo "$log_date" | cut -d'-' -f3)

    # 构建日志目录路径
    log_dir="${TOMCAT_LOGS_DIR}/${year}-${month}"
    if [ ! -d "$log_dir" ]; then
        error "日志目录不存在: $log_dir"
        return 1
    fi

    # 查找匹配的日志文件: appserver-月-日-年-*.log
    pattern="appserver-${month}-${day}-${year}-*.log"
    info "查找文件: $pattern"
    
    mapfile -t log_files < <(find "$log_dir" -maxdepth 1 -type f -name "$pattern" | sort)
    
    if [ ${#log_files[@]} -eq 0 ]; then
        warn "在 $log_dir 中没有找到匹配的日志文件: $pattern"
    else
        echo ""
        info "找到 ${#log_files[@]} 个日志文件："
        for f in "${log_files[@]}"; do
            echo "  $(basename "$f")"
        done
    fi

    # 询问是否包含根目录下的 appserver.log
    include_appserver="n"
    if [ -f "${TOMCAT_LOGS_DIR}/appserver.log" ]; then
        read -p "是否同时包含当前的 appserver.log 文件？(y/n，默认 n): " include_appserver
        include_appserver=${include_appserver:-n}
    else
        warn "根目录下未找到 appserver.log 文件，将跳过"
    fi

    total_files=${#log_files[@]}
    if [ "$include_appserver" = "y" ] || [ "$include_appserver" = "Y" ]; then
        total_files=$((total_files + 1))
    fi

    if [ $total_files -eq 0 ]; then
        error "没有找到任何可打包的日志文件"
        return 1
    fi

    read -p "是否打包并上传这些日志文件？(y/n): " confirm
    if [ "$confirm" != "y" ]; then
        info "取消上传"
        return
    fi

    # 创建临时目录用于打包
    local temp_work_dir="/tmp/kpos_logs_$$"
    mkdir -p "$temp_work_dir"

    # 复制或链接日志文件到临时目录
    for f in "${log_files[@]}"; do
        cp "$f" "$temp_work_dir/"
    done
    if [ "$include_appserver" = "y" ] || [ "$include_appserver" = "Y" ]; then
        cp "${TOMCAT_LOGS_DIR}/appserver.log" "$temp_work_dir/"
    fi

    # 打包压缩
    local archive_name="logs_${year}-${month}-${day}.tar.gz"
    local archive_path="${BACKUP_DIR}/${archive_name}"
    info "正在打包日志文件到 ${archive_path} ..."
    pushd "$temp_work_dir" > /dev/null
    tar -czf "$archive_path" *
    popd > /dev/null
    if [ $? -eq 0 ] && [ -s "$archive_path" ]; then
        info "打包成功: $archive_path ($(du -h "$archive_path" | cut -f1))"
    else
        error "打包失败"
        rm -rf "$temp_work_dir"
        return 1
    fi

    # 清理临时目录
    rm -rf "$temp_work_dir"

    # 上传到 Google Drive 的 backup 根目录
    info "上传到 ${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/ ..."
    rclone copy "$archive_path" "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
    if [ $? -eq 0 ]; then
        info "日志文件上传成功"
    else
        error "上传失败"
        return 1
    fi

    # 可选：删除本地压缩包
    read -p "是否删除本地压缩包 ${archive_path}？(y/n): " del_choice
    if [ "$del_choice" = "y" ]; then
        rm -f "$archive_path"
        info "已删除本地压缩包"
    else
        info "本地压缩包保留在: $archive_path"
    fi

    info "========== 日志上传完成 =========="
}

# ==================== 主菜单 ====================
show_menu() {
    echo ""
    echo "========================================="
    echo "     数据库 + 文件夹 备份/恢复工具"
    echo "     本地备份目录: ${BACKUP_DIR}"
    echo "     云端目录: ${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}"
    echo "========================================="
    echo "1) 备份（交互式选择）"
    echo "2) 恢复（从本地备份目录）"
    echo "3) 恢复（从 Google Drive 下载）"
    echo "4) 上传指定日期的 Tomcat 日志文件"
    echo "5) 退出"
    echo "========================================="
    read -p "请选择 [1-5]: " choice
    case $choice in
        1) do_backup ;;
        2) restore_from_local ;;
        3) restore_from_cloud ;;
        4) upload_logs ;;
        5) info "退出程序"; exit 0 ;;
        *) error "无效选择"; show_menu ;;
    esac
}

# ==================== 脚本入口 ====================
install_or_update_rclone
check_dependencies
setup_rclone

exec 200> "$LOCK_FILE"
if ! flock -n 200; then
    error "另一个备份/恢复脚本正在运行，请稍后再试"
    exit 1
fi

show_menu