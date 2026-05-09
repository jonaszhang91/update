#!/bin/bash

# ==================== 脚本菜单 ====================
# 一级菜单：升级 / 打补丁
# 二级菜单：具体版本
# =================================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查上一条命令是否成功
check_success() {
    if [ $? -eq 0 ]; then
        info "$1 成功"
    else
        error "$1 失败，脚本中止"
        exit 1
    fi
}

show_main_menu() {
    clear
    echo "========================================="
    echo "            主菜单"
    echo "========================================="
    echo "1) 升级"
    echo "2) 打补丁"
    echo "0) 退出"
    echo "========================================="
    read -p "请选择 [0-2]: " main_choice
    case $main_choice in
        1)
            show_upgrade_menu
            ;;
        2)
            show_patch_menu
            ;;
        0)
            echo "退出脚本"
            exit 0
            ;;
        *)
            warn "无效选择，按回车重试..."
            read
            show_main_menu
            ;;
    esac
}

show_upgrade_menu() {
    clear
    echo "========================================="
    echo "            升级菜单"
    echo "========================================="
    echo "1) 升级 16.6 fast0"
    echo "2) 升级 17.1 fast0"
    echo "0) 返回主菜单"
    echo "========================================="
    read -p "请选择 [0-2]: " upgrade_choice
    case $upgrade_choice in
        1)
            info "开始执行升级 16.6 fast0..."
            # 1.1 命令
            cd ~ || { error "无法切换到 home 目录"; exit 1; }
            rm -f /home/menu/POS_update_fast0.sh
            wget https://github.com/jonaszhang91/update/raw/refs/heads/main/16.6/POS_update_fast0.sh
            check_success "下载 POS_update_fast0.sh"
            sudo sh /home/menu/POS_update_fast0.sh
            check_success "执行升级脚本"
            info "升级 16.6 fast0 完成"
            ;;
        2)
            info "开始执行升级 17.1 fast0..."
            # 1.2 命令（注意：用户提供的链接是 16.7，但描述为 17.1 fast0，保持原样）
            cd ~ || { error "无法切换到 home 目录"; exit 1; }
            rm -f /home/menu/POS_update_fast0.sh
            wget https://github.com/jonaszhang91/update/raw/refs/heads/main/16.7/POS_update_fast0.sh
            check_success "下载 POS_update_fast0.sh"
            sudo sh /home/menu/POS_update_fast0.sh
            check_success "执行升级脚本"
            info "升级 17.1 fast0 完成"
            ;;
        0)
            show_main_menu
            return
            ;;
        *)
            warn "无效选择，按回车重试..."
            read
            show_upgrade_menu
            ;;
    esac
    echo ""
    read -p "按回车返回主菜单..."
    show_main_menu
}

show_patch_menu() {
    clear
    echo "========================================="
    echo "            打补丁菜单"
    echo "========================================="
    echo "1) 补丁 16.6 fast18"
    echo "0) 返回主菜单"
    echo "========================================="
    read -p "请选择 [0-1]: " patch_choice
    case $patch_choice in
        1)
            info "开始执行补丁 16.6 fast18..."
            # 2.1 命令
            cd ~ || { error "无法切换到 home 目录"; exit 1; }
            info "下载 pit-18 文件..."
            wget --no-check-certificate 'https://docs.google.com/uc?export=download&id=1-55kWzmMsctc06FCHlPrbgeQGU6jwS3X' -O pit-18
            check_success "下载 pit-18"
            info "解压 pit-18..."
            unzip pit-18
            check_success "解压"
            info "复制 kpos 文件夹到 Tomcat webapps..."
            sudo cp -rf /home/menu/1.8.0.30.16.6-fast-18-PIT-12780/kpos/* /opt/apache-tomcat-7.0.93/webapps/kpos/
            check_success "复制文件"
            info "执行 alter_terminal.sql..."
            mysql -u root --password='N0mur@4$99!' kpos < /home/menu/1.8.0.30.16.6-fast-18-PIT-12780/alter_terminal.sql
            check_success "导入 alter_terminal.sql"
            info "执行 0_db.sql..."
            mysql -u root --password='N0mur@4$99!' kpos < /home/menu/1.8.0.30.16.6-fast-18-PIT-12780/0_db.sql
            check_success "导入 0_db.sql"
            info "重启 Tomcat 服务..."
            sudo service tomcat restart
            check_success "重启 Tomcat"
            info "补丁 16.6 fast18 完成"
            ;;
        0)
            show_main_menu
            return
            ;;
        *)
            warn "无效选择，按回车重试..."
            read
            show_patch_menu
            ;;
    esac
    echo ""
    read -p "按回车返回主菜单..."
    show_main_menu
}

# 脚本入口
show_main_menu