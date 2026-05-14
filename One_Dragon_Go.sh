#!/bin/bash

# 检查必要的命令是否存在
check_dependencies() {
    local deps=("wget" "unzip" "mysql" "sudo")
    local missing=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -ne 0 ]; then
        echo "错误：缺少以下命令，请先安装：${missing[*]}"
        exit 1
    fi
}

# 升级 16.6 fast0（执行后直接退出脚本）
do_upgrade_16_6_fast0() {
    echo ">>> 正在执行升级 16.6 fast0 ..."
    cd ~ && \
    rm -f /home/menu/POS_update.sh && \
    wget https://github.com/jonaszhang91/update/raw/refs/heads/main/16.6/POS_update.sh && \
    sudo sh /home/menu/POS_update.sh
    if [ $? -eq 0 ]; then
        echo ">>> 升级 16.6 fast0 完成"
    else
        echo ">>> 升级 16.6 fast0 失败，请检查错误"
    fi
    echo "升级脚本已执行，脚本将退出。"
    exit 0
}

# 升级 16.7.1 fast0（执行后直接退出脚本）
do_upgrade_16_7_1_fast0() {
    echo ">>> 正在执行升级 16.7.1 fast0 ..."
    cd ~ && \
    rm -f /home/menu/POS_update.sh && \
    wget https://github.com/jonaszhang91/update/raw/refs/heads/main/16.7.1/POS_update.sh && \
    sudo sh /home/menu/POS_update.sh
    if [ $? -eq 0 ]; then
        echo ">>> 升级 16.7.1 fast0 完成"
    else
        echo ">>> 升级 16.7.1 fast0 失败，请检查错误"
    fi
    echo "升级脚本已执行，脚本将退出。"
    exit 0
}

# 升级 16.7.2 fast0（执行后直接退出脚本）
do_upgrade_16_7_2_fast0() {
    echo ">>> 正在执行升级 16.7.2 fast0 ..."
    cd ~ && \
    rm -f /home/menu/POS_update.sh && \
    wget https://github.com/jonaszhang91/update/raw/refs/heads/main/16.7.2/POS_update.sh && \
    sudo sh /home/menu/POS_update.sh
    if [ $? -eq 0 ]; then
        echo ">>> 升级 16.7.2 fast0 完成"
    else
        echo ">>> 升级 16.7.2 fast0 失败，请检查错误"
    fi
    echo "升级脚本已执行，脚本将退出。"
    exit 0
}

# 打补丁 16.6 fast18 补丁（需要等待按键，执行后返回子菜单）
do_patch_16_6_fast18() {
    echo ">>> 正在执行 16.6 fast18 补丁 ..."
    cd ~ && \
    sudo rm -rf /home/menu/pit && \
    wget --no-check-certificate 'https://docs.google.com/uc?export=download&id=1-55kWzmMsctc06FCHlPrbgeQGU6jwS3X' -O pit && \
    unzip pit && \
    sudo cp -rf /home/menu/1.8.0.30.16.6-fast-18-PIT-12780/kpos/* /opt/apache-tomcat-7.0.93/webapps/kpos/ && \
    mysql -u root --password='N0mur@4$99!' kpos < /home/menu/1.8.0.30.16.6-fast-18-PIT-12780/alter_terminal.sql && \
    mysql -u root --password='N0mur@4$99!' kpos < /home/menu/1.8.0.30.16.6-fast-18-PIT-12780/0_db.sql && \
    sudo service tomcat restart
    if [ $? -eq 0 ]; then
        echo ">>> 16.6 fast18 补丁完成"
    else
        echo ">>> 16.6 fast18 补丁失败，请检查错误"
    fi
    read -p "按回车键继续..."
}

# 显示一级菜单
show_main_menu() {
    clear
    echo "======================"
    echo "    主菜单"
    echo "======================"
    echo "1. 升级"
    echo "2. 打补丁"
    echo "0. 退出"
    echo -n "请选择 [0-2]: "
}

# 显示升级子菜单（不清屏，避免覆盖输出）
show_upgrade_menu() {
    echo "======================"
    echo "    升级子菜单"
    echo "======================"
    echo "1.1 升级 16.6 fast0"
    echo "1.2 升级 16.7.1 fast0"
    echo "1.3 升级 16.7.2 fast0"
    echo "0. 返回主菜单"
    echo -n "请选择 [0-3]: "
}

# 显示打补丁子菜单
show_patch_menu() {
    clear
    echo "======================"
    echo "    打补丁子菜单"
    echo "======================"
    echo "2.1 16.6 fast18 补丁"
    echo "0. 返回主菜单"
    echo -n "请选择 [0-1]: "
}

# 升级子菜单循环（注意：选择1.1/1.2/1.3后会直接退出脚本，不会返回）
upgrade_menu_loop() {
    while true; do
        show_upgrade_menu
        read -r sub_choice
        case $sub_choice in
            1)
                do_upgrade_16_6_fast0
                # 以上函数内部会 exit，以下代码不会执行
                ;;
            2)
                do_upgrade_16_7_1_fast0
                ;;
            3)
                do_upgrade_16_7_2_fast0
                ;;
            0)
                echo "返回主菜单..."
                sleep 1
                break
                ;;
            *)
                echo "无效输入，请重新选择！"
                sleep 1
                ;;
        esac
    done
}

# 打补丁子菜单循环
patch_menu_loop() {
    while true; do
        show_patch_menu
        read -r sub_choice
        case $sub_choice in
            1)
                do_patch_16_6_fast18
                ;;
            0)
                echo "返回主菜单..."
                sleep 1
                break
                ;;
            *)
                echo "无效输入，请重新选择！"
                sleep 1
                ;;
        esac
    done
}

# 主程序入口
main() {
    check_dependencies

    echo "注意：部分操作需要 sudo 权限，如果提示输入密码，请输入当前用户的密码。"
    sudo -v 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "警告：当前用户可能没有 sudo 权限，某些操作将失败。"
    fi

    while true; do
        show_main_menu
        read -r main_choice
        case $main_choice in
            1)
                upgrade_menu_loop
                # 升级子菜单返回后（仅当用户按0返回时）会继续主循环
                ;;
            2)
                patch_menu_loop
                ;;
            0)
                echo "退出脚本。"
                exit 0
                ;;
            *)
                echo "无效输入，请重新选择！"
                sleep 1
                ;;
        esac
    done
}

main