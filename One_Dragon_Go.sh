#!/bin/sh

check_dependencies() {
    for cmd in wget unzip mysql sudo; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            echo "错误：缺少命令 $cmd，请先安装"
            exit 1
        fi
    done
}

do_upgrade_16_6_fast0() {
    echo ">>> 正在启动升级 16.6 fast0（后台运行）..."
    cd /home/menu || exit
    rm -f /home/menu/POS_update.sh
    wget -O /home/menu/POS_update.sh https://github.com/jonaszhang91/update/raw/refs/heads/main/16.6/POS_update.sh
    exec sudo sh /home/menu/POS_update.sh
    echo "升级已在后台启动，当前菜单脚本关闭。"
    exit 0
}

do_upgrade_16_7_1_fast0() {
    echo ">>> 正在启动升级 16.7.1 fast0（后台运行）..."
    cd /home/menu || exit
    rm -f /home/menu/POS_update.sh
    wget -O /home/menu/POS_update.sh https://github.com/jonaszhang91/update/raw/refs/heads/main/16.7.1/POS_update.sh
    exec sudo sh /home/menu/POS_update.sh
    echo "升级已在后台启动，当前菜单脚本关闭。"
    exit 0
}

do_upgrade_16_7_2_fast0() {
    echo ">>> 正在启动升级 16.7.2 fast0（后台运行）..."
    cd /home/menu || exit
    rm -f /home/menu/POS_update.sh
    wget -O /home/menu/POS_update.sh https://github.com/jonaszhang91/update/raw/refs/heads/main/16.7.2/POS_update.sh
    exec sudo sh /home/menu/POS_update.sh
    echo "升级已在后台启动，当前菜单脚本关闭。"
    exit 0
}

do_upgrade_30_13() {
    echo ">>> 正在启动升级 30.13（后台运行）..."
    cd /home/menu || exit
    rm -f /home/menu/POS_update.sh
    wget --user=baol22 --password="1qaz@WSX6788" http://skymenu.menusifu.com.cn:29120/18030.13/POS_update.sh
    exec sudo sh /home/menu/POS_update.sh
    echo "升级已在后台启动，当前菜单脚本关闭。"
    exit 0
}

do_upgrade_30_14_9() {
    echo ">>> 正在执行升级 30.14.9，菜单将关闭..."
    cd /home/menu || exit
    rm -f POS_update.sh
    wget --user=baol22 --password="1qaz@WSX6788" -O POS_update.sh http://skymenu.menusifu.com.cn:29120/18030.14/POS_update.sh
    exec sudo sh POS_update.sh
}

do_patch_16_6_fast18() {
    echo ">>> 正在执行 16.6 fast18 补丁 ..."
    cd ~ || exit
    sudo rm -rf /home/menu/pit
    wget --no-check-certificate 'https://docs.google.com/uc?export=download&id=1-55kWzmMsctc06FCHlPrbgeQGU6jwS3X' -O pit
    unzip pit
    sudo cp -rf /home/menu/1.8.0.30.16.6-fast-18-PIT-12780/kpos/* /opt/apache-tomcat-7.0.93/webapps/kpos/
    mysql -u root --password='N0mur@4$99!' kpos < /home/menu/1.8.0.30.16.6-fast-18-PIT-12780/alter_terminal.sql
    mysql -u root --password='N0mur@4$99!' kpos < /home/menu/1.8.0.30.16.6-fast-18-PIT-12780/0_db.sql
    sudo service tomcat restart
    if [ $? -eq 0 ]; then
        echo ">>> 16.6 fast18 补丁完成"
    else
        echo ">>> 16.6 fast18 补丁失败，请检查错误"
    fi
    read -p "按回车键继续..."
}
# 166升级167_27more 修复
do_patch_166_to167_fix() {
    echo ">>> 正在执行 166升级167_27more 修复（向 kpos 库写入数据）..."
    SQL_COMMANDS="
-- 1. 修复 schema_version 记录
UPDATE schema_version SET success = 1 WHERE version = '1.8.0.471';

-- 2. 添加 terminal 表 user_name 字段
ALTER TABLE \`kpos\`.\`terminal\`
ADD COLUMN \`user_name\` varchar(128) NULL COMMENT 'worldline username' AFTER \`tablet_version\`;

-- 3. 添加 pat_config 表 enabled 字段
ALTER TABLE \`kpos\`.\`pat_config\`
ADD COLUMN \`enabled\` tinyint(1) NOT NULL DEFAULT 1 COMMENT '1 - enabled; 0- not' AFTER \`login_status\`;
"
    echo "$SQL_COMMANDS" | mysql -u root --password='N0mur@4$99!' kpos 2>&1
    if [ $? -eq 0 ]; then
        echo ">>> 166升级167_27more 修复完成"
    else
        echo ">>> 修复过程中出现部分错误（如字段已存在），请检查上方输出。"
    fi
    read -p "按回车键继续..."
}

show_main_menu() {
    clear
    echo "======================"
    echo "    主菜单"
    echo "======================"
    echo "1. 升级"
    echo "2. 打补丁"
    echo "0. 退出"
    printf "请选择 [0-2]: "
}

show_upgrade_menu() {
    echo "======================"
    echo "    升级子菜单"
    echo "======================"
    echo "1.1 升级 16.6 fast0"
    echo "1.2 升级 16.7.1 fast0"
    echo "1.3 升级 16.7.2 fast0"
    echo "1.4 升级 30.13"
    echo "1.5 升级 30.14.9"
    echo "0. 返回主菜单"
    printf "请选择 [0-4]: "
}

show_patch_menu() {
    clear
    echo "======================"
    echo "    打补丁子菜单"
    echo "======================"
    echo "2.1 16.6 fast18 补丁"
    echo "2.2 166升级167_27more修复"
    echo "0. 返回主菜单"
    printf "请选择 [0-1]: "
}

upgrade_menu_loop() {
    while true; do
        show_upgrade_menu
        read sub_choice
        case $sub_choice in
            1) do_upgrade_16_6_fast0 ;;
            2) do_upgrade_16_7_1_fast0 ;;
            3) do_upgrade_16_7_2_fast0 ;;
            4) do_upgrade_30_13 ;;
            5) do_upgrade_30_14_9 ;;
            0) echo "返回主菜单..."; sleep 1; break ;;
            *) echo "无效输入，请重新选择！"; sleep 1 ;;
        esac
    done
}

patch_menu_loop() {
    while true; do
        show_patch_menu
        read sub_choice
        case $sub_choice in
            1) do_patch_16_6_fast18 ;;
            2) do_patch_166_to167_fix ;;
            0) echo "返回主菜单..."; sleep 1; break ;;
            *) echo "无效输入，请重新选择！"; sleep 1 ;;
        esac
    done
}

main() {
    check_dependencies
    echo "注意：部分操作需要 sudo 权限，如果提示输入密码，请输入当前用户的密码。"
    sudo -v > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "警告：当前用户可能没有 sudo 权限，某些操作将失败。"
    fi
    while true; do
        show_main_menu
        read main_choice
        case $main_choice in
            1) upgrade_menu_loop ;;
            2) patch_menu_loop ;;
            0) echo "退出脚本。"; exit 0 ;;
            *) echo "无效输入，请重新选择！"; sleep 1 ;;
        esac
    done
}

main