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
RCLONE_REMOTE="gdrive"
RCLONE_BACKUP_DIR="backup"
RCLONE_CONFIG_FILE="./rclone.conf"
RCLONE_CONFIG_PASS="262410ZXj."

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

cleanup() {
    if [ -f "$RCLONE_CONFIG_FILE" ]; then
        rm -f "$RCLONE_CONFIG_FILE"
        info "已删除配置文件: $RCLONE_CONFIG_FILE"
    fi
}
trap cleanup EXIT INT TERM

# Tomcat 服务控制统一封装（带超时强杀机制，防止卡死）
stop_tomcat() {
    info "正在停止 Tomcat 服务..."
    
    # 后台异步发起停止指令
    (sudo systemctl stop tomcat 2>/dev/null || sudo service tomcat stop 2>/dev/null) &
    local stop_pid=$!

    # 轮询等待最多 10 秒
    local timeout=10
    local count=0
    while kill -0 $stop_pid 2>/dev/null; do
        if [ $count -ge $timeout ]; then
            warn "Tomcat 未能在 ${timeout} 秒内正常停止，正在强制杀死进程..."
            break
        fi
        sleep 1
        count=$((count + 1))
    done

    # 兜底强杀，确保彻底断开数据库连接与写锁
    if pgrep -f "apache-tomcat" > /dev/null; then
        sudo pkill -9 -f "apache-tomcat" 2>/dev/null || true
        info "已强制终止 Tomcat 进程"
    else
        info "Tomcat 服务已正常停止"
    fi
}

start_tomcat() {
    info "正在启动/重启 Tomcat 服务..."
    sudo systemctl restart tomcat 2>/dev/null || sudo service tomcat restart 2>/dev/null || true
}

# ==================== 自动安装/更新 rclone ====================
install_or_update_rclone() {
    info "检查 rclone 安装状态..."
    if command -v rclone &> /dev/null; then
        local rclone_path
        rclone_path=$(which rclone)
        local version
        version=$(rclone version 2>/dev/null | head -1 | awk '{print $2}')
        info "已安装 rclone，路径: $rclone_path，版本: $version"
        if [[ "$rclone_path" == *"/snap/"* ]]; then
            warn "检测到 snap 安装的 rclone，正在卸载..."
            sudo snap remove rclone
            check_success "卸载 snap 版 rclone"
        else
            read -p "是否更新 rclone 到最新版本？(y/n，默认 n): " update_choice
            if [[ "$update_choice" == "y" || "$update_choice" == "Y" ]]; then
                info "开始更新 rclone..."
                sudo -v || { error "需要 sudo 权限更新 rclone"; exit 1; }
                curl -sSL https://rclone.org/install.sh | sudo bash
            fi
            return 0
        fi
    fi
    warn "未找到可用的 rclone，正在安装最新版本..."
    sudo -v || { error "需要 sudo 权限安装 rclone"; exit 1; }
    curl -sSL https://rclone.org/install.sh | sudo bash
}

check_dependencies() {
    local deps=("mysqldump" "mysql" "tar" "gzip" "zcat" "gunzip" "xz" "bunzip2" "sudo" "curl" "pgrep" "pkill")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            error "命令 $cmd 未找到，请先安装"
            exit 1
        fi
    done
}

setup_rclone() {
    if [ ! -f "$RCLONE_CONFIG_FILE" ]; then
        error "找不到 rclone 配置文件: $RCLONE_CONFIG_FILE"
        exit 1
    fi
    export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"
    export RCLONE_CONFIG_PASS="$RCLONE_CONFIG_PASS"

    if ! rclone lsd "${RCLONE_REMOTE}:" &>/dev/null; then
        error "rclone 无法连接到 Google Drive，请检查配置文件或密码"
        exit 1
    fi
    info "Google Drive 连接正常"
}

mkdir -p "$BACKUP_DIR"

# ==================== 备份函数 ====================
do_backup() {
    info "开始备份流程..."

    echo ""
    read -p "是否备份数据库？(y/n，默认 y): " backup_db
    backup_db=${backup_db:-y}
    read -p "是否备份图片文件夹 (${IMAGES_SOURCE_DIR})？(y/n，默认 y): " backup_images
    backup_images=${backup_images:-y}
    read -p "是否备份 Tomcat webapp 文件夹 (${TOMCAT_WEBAPP_DIR})？(y/n，默认 y): " backup_tomcat
    backup_tomcat=${backup_tomcat:-y}

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)_$$

    # 1. 备份数据库 (通过 MYSQL_PWD 变量安全传递密码，免疫特殊字符)
    if [[ "$backup_db" == "y" || "$backup_db" == "Y" ]]; then
        SQL_FILE="${DATABASE_NAME}_${TIMESTAMP}.sql.gz"
        SQL_LOCAL_PATH="${BACKUP_DIR}/${SQL_FILE}"
        info "正在备份数据库 ${DATABASE_NAME} ..."
        
        export MYSQL_PWD="${MYSQL_PASSWORD}"
        set -o pipefail
        mysqldump -u"${MYSQL_USER}" \
            --default-character-set=utf8mb4 \
            --single-transaction \
            --quick \
            --hex-blob \
            --triggers --routines --events \
            "${DATABASE_NAME}" | gzip > "${SQL_LOCAL_PATH}"
        local dump_status=$?
        set +o pipefail
        unset MYSQL_PWD

        if [ $dump_status -eq 0 ] && [ -s "${SQL_LOCAL_PATH}" ]; then
            info "数据库备份成功: ${SQL_LOCAL_PATH} ($(du -h "${SQL_LOCAL_PATH}" | cut -f1))"
            rclone copy "${SQL_LOCAL_PATH}" "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
        else
            error "数据库备份失败"
            rm -f "${SQL_LOCAL_PATH}"
            exit 1
        fi
    fi

    # 2. 备份图片
    if [[ "$backup_images" == "y" || "$backup_images" == "Y" ]]; then
        if [ ! -d "${IMAGES_SOURCE_DIR}" ]; then
            warn "图片文件夹 ${IMAGES_SOURCE_DIR} 不存在，跳过备份"
        else
            IMAGES_FILE="images_${TIMESTAMP}.tar.gz"
            IMAGES_LOCAL_PATH="${BACKUP_DIR}/${IMAGES_FILE}"
            info "正在备份图片文件夹 ..."
            sudo tar -P -czf "${IMAGES_LOCAL_PATH}" "${IMAGES_SOURCE_DIR}"
            if [ $? -eq 0 ] && [ -s "${IMAGES_LOCAL_PATH}" ]; then
                info "图片文件夹备份成功"
                rclone copy "${IMAGES_LOCAL_PATH}" "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
            fi
        fi
    fi

    # 3. 备份 Tomcat webapp
    if [[ "$backup_tomcat" == "y" || "$backup_tomcat" == "Y" ]]; then
        if [ ! -d "${TOMCAT_WEBAPP_DIR}" ]; then
            warn "Tomcat webapp 文件夹不存在，跳过备份"
        else
            TOMCAT_FILE="kpos_webapp_${TIMESTAMP}.tar.gz"
            TOMCAT_LOCAL_PATH="${BACKUP_DIR}/${TOMCAT_FILE}"
            info "正在备份 Tomcat webapp 文件夹 ..."
            sudo tar -P -czf "${TOMCAT_LOCAL_PATH}" "${TOMCAT_WEBAPP_DIR}"
            if [ $? -eq 0 ] && [ -s "${TOMCAT_LOCAL_PATH}" ]; then
                info "Tomcat webapp 备份成功"
                rclone copy "${TOMCAT_LOCAL_PATH}" "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
            fi
        fi
    fi

    info "========== 备份完成 =========="
}

# ==================== 恢复通用函数 ====================
restore_database_file() {
    local file_path="$1"
    info "正在恢复数据库从: $(basename "$file_path")"

    # 1. 恢复前强制停止 Tomcat，断开长连接与排他锁
    stop_tomcat

    # 2. 导出密码环境变量，彻底避开 Bash 命令解释器对密码中 $ ! 等符号的解析陷阱
    export MYSQL_PWD="${MYSQL_PASSWORD}"
    
    MYSQL_EXEC="mysql -u${MYSQL_USER} --default-character-set=utf8mb4 ${DATABASE_NAME}"
    INIT_CMDS="SET NAMES utf8mb4; SET autocommit=1; SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;"

    local file_type
    file_type=$(file -b "$file_path" | grep -oE 'gzip|XZ|bzip2' | head -1)
    
    set -o pipefail
    case "$file_type" in
        gzip)
            gunzip -c "$file_path" | $MYSQL_EXEC --init-command="$INIT_CMDS"
            ;;
        XZ)
            xz -d -c "$file_path" | $MYSQL_EXEC --init-command="$INIT_CMDS"
            ;;
        bzip2)
            bunzip2 -c "$file_path" | $MYSQL_EXEC --init-command="$INIT_CMDS"
            ;;
        *)
            $MYSQL_EXEC --init-command="$INIT_CMDS" < "$file_path"
            ;;
    esac
    local restore_status=$?
    set +o pipefail

    unset MYSQL_PWD

    if [ $restore_status -eq 0 ]; then
        info "数据库恢复成功，正在恢复约束设置、提交事务并刷新权限..."
        
        # 恢复约束与刷新权限
        export MYSQL_PWD="${MYSQL_PASSWORD}"
        mysql -u"${MYSQL_USER}" -e "SET FOREIGN_KEY_CHECKS=1; SET UNIQUE_CHECKS=1; COMMIT; FLUSH PRIVILEGES;"
        unset MYSQL_PWD
        
        # 恢复完成后重新拉起 Tomcat 服务
        start_tomcat
    else
        error "数据库恢复失败"
        start_tomcat # 即使失败也尝试拉起服务
        exit 1
    fi
}

restore_images_file() {
    local tar_file="$1"
    info "正在恢复图片文件夹到 ${IMAGES_SOURCE_DIR}..."
    sudo tar -P -xzvf "$tar_file" -C /
    if [ $? -eq 0 ]; then
        sudo chmod -R 777 "${IMAGES_SOURCE_DIR}"
        info "图片文件夹恢复成功，权限已修复"
    else
        warn "图片文件夹恢复失败，请手动检查"
    fi
}

restore_tomcat_file() {
    local tar_file="$1"
    stop_tomcat

    info "正在恢复 Tomcat webapp 文件夹到 ${TOMCAT_WEBAPP_DIR}..."
    sudo tar -P -xzvf "$tar_file" -C /
    
    if [ $? -eq 0 ]; then
        # 修正权限，保证 web 服务具备充分写权限
        sudo chmod -R 777 "${TOMCAT_WEBAPP_DIR}"
        info "Tomcat webapp 恢复成功"
        start_tomcat
    else
        warn "Tomcat webapp 文件夹恢复失败"
        start_tomcat
    fi
}

# ==================== 从本地恢复 ====================
restore_from_local() {
    info "扫描本地备份文件夹: ${BACKUP_DIR}"

    mapfile -t sql_files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.sql.gz" 2>/dev/null | sort)
    mapfile -t images_files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "images_*.tar.gz" 2>/dev/null | sort)
    mapfile -t tomcat_files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "kpos_webapp_*.tar.gz" 2>/dev/null | sort)

    echo ""
    warn "========== 选择要恢复的内容类型 =========="
    echo "1) 恢复数据库"
    echo "2) 恢复图片文件夹"
    echo "3) 恢复 Tomcat webapp 文件夹"
    echo "4) 恢复所有（依次选择最新备份）"
    echo "0) 返回主菜单"
    read -p "请选择 [0-4]: " type_choice

    case $type_choice in
        1)
            if [ ${#sql_files[@]} -eq 0 ]; then error "没有找到数据库备份文件"; return; fi
            for i in "${!sql_files[@]}"; do
                echo "  [$((i+1))] $(basename "${sql_files[$i]}") ($(du -h "${sql_files[$i]}" | cut -f1))"
            done
            read -p "请选择要恢复的数据库备份 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#sql_files[@]} ]; then
                restore_database_file "${sql_files[$((idx-1))]}"
            fi
            ;;
        2)
            if [ ${#images_files[@]} -eq 0 ]; then error "没有找到图片文件夹备份文件"; return; fi
            for i in "${!images_files[@]}"; do
                echo "  [$((i+1))] $(basename "${images_files[$i]}") ($(du -h "${images_files[$i]}" | cut -f1))"
            done
            read -p "请选择要恢复的图片备份 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#images_files[@]} ]; then
                restore_images_file "${images_files[$((idx-1))]}"
            fi
            ;;
        3)
            if [ ${#tomcat_files[@]} -eq 0 ]; then error "没有找到 Tomcat webapp 备份文件"; return; fi
            for i in "${!tomcat_files[@]}"; do
                echo "  [$((i+1))] $(basename "${tomcat_files[$i]}") ($(du -h "${tomcat_files[$i]}" | cut -f1))"
            done
            read -p "请选择要恢复的 Tomcat webapp 备份 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#tomcat_files[@]} ]; then
                restore_tomcat_file "${tomcat_files[$((idx-1))]}"
            fi
            ;;
        4)
            [ ${#sql_files[@]} -gt 0 ] && restore_database_file "${sql_files[-1]}"
            [ ${#images_files[@]} -gt 0 ] && restore_images_file "${images_files[-1]}"
            [ ${#tomcat_files[@]} -gt 0 ] && restore_tomcat_file "${tomcat_files[-1]}"
            ;;
        *) info "返回主菜单" ;;
    esac
}

# ==================== 从 Google Drive 恢复 ====================
restore_from_cloud() {
    info "从 Google Drive 获取备份文件列表..."
    local remote_files=()
    while IFS= read -r line; do 
        [ -n "$line" ] && remote_files+=("$line")
    done < <(rclone ls "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/" 2>/dev/null | sort -r)

    if [ ${#remote_files[@]} -eq 0 ]; then error "云端没有找到任何备份文件"; return 1; fi

    local sql_remote=() images_remote=() tomcat_remote=()
    for line in "${remote_files[@]}"; do
        filename=$(echo "$line" | awk '{$1=""; print substr($0,2)}')
        if [[ "$filename" == ${DATABASE_NAME}_*.sql.gz ]]; then sql_remote+=("$line");
        elif [[ "$filename" == images_*.tar.gz ]]; then images_remote+=("$line");
        elif [[ "$filename" == kpos_webapp_*.tar.gz ]]; then tomcat_remote+=("$line"); fi
    done

    echo ""
    warn "========== 选择要恢复的内容类型 =========="
    echo "1) 恢复数据库"
    echo "2) 恢复图片文件夹"
    echo "3) 恢复 Tomcat webapp 文件夹"
    echo "4) 恢复所有（下载最新备份）"
    echo "0) 返回主菜单"
    read -p "请选择 [0-4]: " type_choice

    local temp_dir="/tmp/kpos_restore_$$"
    mkdir -p "$temp_dir"

    case $type_choice in
        1)
            if [ ${#sql_remote[@]} -eq 0 ]; then error "云端没有找到数据库备份文件"; rm -rf "$temp_dir"; return; fi
            for i in "${!sql_remote[@]}"; do
                echo "  [$((i+1))] $(echo "${sql_remote[$i]}" | awk '{$1=""; print substr($0,2)}')"
            done
            read -p "请选择 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#sql_remote[@]} ]; then
                remote_filename=$(echo "${sql_remote[$((idx-1))]}" | awk '{$1=""; print substr($0,2)}')
                rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${remote_filename}" "$temp_dir/"
                restore_database_file "${temp_dir}/${remote_filename}"
            fi
            ;;
        2)
            if [ ${#images_remote[@]} -eq 0 ]; then error "云端没有找到图片备份文件"; rm -rf "$temp_dir"; return; fi
            for i in "${!images_remote[@]}"; do
                echo "  [$((i+1))] $(echo "${images_remote[$i]}" | awk '{$1=""; print substr($0,2)}')"
            done
            read -p "请选择 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#images_remote[@]} ]; then
                remote_filename=$(echo "${images_remote[$((idx-1))]}" | awk '{$1=""; print substr($0,2)}')
                rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${remote_filename}" "$temp_dir/"
                restore_images_file "${temp_dir}/${remote_filename}"
            fi
            ;;
        3)
            if [ ${#tomcat_remote[@]} -eq 0 ]; then error "云端没有找到 Tomcat 备份文件"; rm -rf "$temp_dir"; return; fi
            for i in "${!tomcat_remote[@]}"; do
                echo "  [$((i+1))] $(echo "${tomcat_remote[$i]}" | awk '{$1=""; print substr($0,2)}')"
            done
            read -p "请选择 [序号]: " idx
            if [[ $idx =~ ^[0-9]+$ ]] && [ $idx -ge 1 ] && [ $idx -le ${#tomcat_remote[@]} ]; then
                remote_filename=$(echo "${tomcat_remote[$((idx-1))]}" | awk '{$1=""; print substr($0,2)}')
                rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${remote_filename}" "$temp_dir/"
                restore_tomcat_file "${temp_dir}/${remote_filename}"
            fi
            ;;
        4)
            if [ ${#sql_remote[@]} -gt 0 ]; then
                latest=$(echo "${sql_remote[0]}" | awk '{$1=""; print substr($0,2)}')
                rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${latest}" "$temp_dir/"
                restore_database_file "${temp_dir}/${latest}"
            fi
            if [ ${#images_remote[@]} -gt 0 ]; then
                latest=$(echo "${images_remote[0]}" | awk '{$1=""; print substr($0,2)}')
                rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${latest}" "$temp_dir/"
                restore_images_file "${temp_dir}/${latest}"
            fi
            if [ ${#tomcat_remote[@]} -gt 0 ]; then
                latest=$(echo "${tomcat_remote[0]}" | awk '{$1=""; print substr($0,2)}')
                rclone copy "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/${latest}" "$temp_dir/"
                restore_tomcat_file "${temp_dir}/${latest}"
            fi
            ;;
        *) info "返回主菜单" ;;
    esac

    rm -rf "$temp_dir"
}

# ==================== 上传指定日期的日志文件 ====================
upload_logs() {
    info "上传 Tomcat 日志文件"

    read -p "请输入日期 (格式: 年-月-日，例如 2026-03-15): " log_date
    if ! [[ "$log_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        error "日期格式错误，请使用 YYYY-MM-DD 格式"
        return 1
    fi

    year=$(echo "$log_date" | cut -d'-' -f1)
    month=$(echo "$log_date" | cut -d'-' -f2)
    day=$(echo "$log_date" | cut -d'-' -f3)

    log_dir="${TOMCAT_LOGS_DIR}/${year}-${month}"
    if [ ! -d "$log_dir" ]; then
        error "日志目录不存在: $log_dir"
        return 1
    fi

    pattern="appserver-${month}-${day}-${year}-*.log"
    info "查找文件: $pattern"
    
    mapfile -t log_files < <(find "$log_dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null | sort)

    local include_appserver="n"
    if [ -f "${TOMCAT_LOGS_DIR}/appserver.log" ]; then
        read -p "是否同时包含当前的 appserver.log 文件？(y/n，默认 n): " include_appserver
        include_appserver=${include_appserver:-n}
    fi

    if [ ${#log_files[@]} -eq 0 ] && [[ "$include_appserver" != "y" && "$include_appserver" != "Y" ]]; then
        error "未在此目录下找到符合条件的日志文件"
        return 1
    fi

    local temp_work_dir="/tmp/kpos_logs_$$"
    mkdir -p "$temp_work_dir"

    for f in "${log_files[@]}"; do cp "$f" "$temp_work_dir/"; done
    if [[ "$include_appserver" == "y" || "$include_appserver" == "Y" ]]; then
        cp "${TOMCAT_LOGS_DIR}/appserver.log" "$temp_work_dir/"
    fi

    local archive_name="logs_${year}-${month}-${day}.tar.gz"
    local archive_path="${BACKUP_DIR}/${archive_name}"
    
    tar -czf "$archive_path" -C "$temp_work_dir" .
    rm -rf "$temp_work_dir"

    info "上传到 ${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/ ..."
    rclone copy "$archive_path" "${RCLONE_REMOTE}:${RCLONE_BACKUP_DIR}/"
    info "========== 日志上传完成 =========="
}

upgrade_script() {
    info "开始升级工具脚本 (One_Dragon_Go.sh)..."
    cd /home/menu || { error "无法切换到 /home/menu 目录"; return 1; }
    
    if wget -q -O One_Dragon_Go.sh https://github.com/jonaszhang91/update/raw/refs/heads/main/One_Dragon_Go.sh; then
        info "下载 One_Dragon_Go.sh 成功"
        chmod +x One_Dragon_Go.sh
        exec sudo bash /home/menu/One_Dragon_Go.sh
    else
        error "下载升级脚本失败"
        return 1
    fi
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
    echo "5) 升级工具脚本"
    echo "0) 退出"
    echo "========================================="
    read -p "请选择 [0-5]: " choice
    case $choice in
        1) do_backup ;;
        2) restore_from_local ;;
        3) restore_from_cloud ;;
        4) upload_logs ;;
        5) upgrade_script ;;
        0) info "退出程序"; exit 0 ;;
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