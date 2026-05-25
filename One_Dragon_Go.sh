#!/bin/sh

# ======================== 依赖检查 ========================
check_dependencies() {
    for cmd in wget unzip mysql sudo; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            echo "错误：缺少命令 $cmd，请先安装"
            exit 1
        fi
    done
}

# ======================== 获取所有IPv4地址（含DHCP/虚拟标识） ========================
show_network_ips() {
    if ip -o -4 addr show > /dev/null 2>&1; then
        ip -o -4 addr show | grep -v LOOPBACK | grep -v "127.0.0.1" | while read line; do
            iface=$(echo "$line" | awk '{print $2}')
            ip_addr=$(echo "$line" | awk '{print $4}' | cut -d'/' -f1)
            case "$iface" in
                docker*|veth*|br-*|virbr*|lxc*|vnet*|tun*|tap*|lo*)
                    type="虚拟IP"
                    ;;
                *)
                    type="DHCP IP"
                    ;;
            esac
            echo "  $iface: $ip_addr ($type)"
        done
    else
        # 降级 ifconfig
        ifconfig | grep -E 'inet ' | grep -v '127.0.0.1' | while read line; do
            ip_addr=$(echo "$line" | awk '{print $2}')
            iface=$(echo "$line" | awk '{print $1}')
            case "$iface" in
                docker*|veth*|br-*|virbr*|lxc*|vnet*|tun*|tap*)
                    type="虚拟IP"
                    ;;
                *)
                    type="DHCP IP"
                    ;;
            esac
            echo "  $iface: $ip_addr ($type)"
        done
    fi
}

# ======================== 添加网段功能 ========================
add_network_segment() {
    NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
    BACKUP_FILE="/etc/netplan/50-cloud-init.yaml.bak"
    
    echo ">>> 开始配置网段（静态IP）"
    
    # 检测并安装 netplan（通常已安装）
    if ! command -v netplan > /dev/null 2>&1; then
        echo "错误：netplan 未安装，请先安装：sudo apt install netplan.io"
        read -p "按回车键继续..."
        return 1
    fi
    
    # 确定网卡名称（取第一个非lo的物理网卡）
    INTERFACE=$(ip link show | grep -v lo | grep -E '^[0-9]+: en|eth' | head -n1 | awk -F': ' '{print $2}')
    if [ -z "$INTERFACE" ]; then
        echo "未找到物理网卡，请手动指定。"
        read -p "请输入网卡名称（如 enp1s0）: " INTERFACE
    fi
    echo "使用的网卡: $INTERFACE"
    
    # 提示用户输入要添加的 IP/CIDR
    echo "请输入要添加的静态 IP 地址及掩码（格式如 192.168.1.199/24）"
    read -p "IP地址: " NEW_IP
    if [ -z "$NEW_IP" ]; then
        echo "未输入IP，取消操作。"
        read -p "按回车键继续..."
        return 0
    fi
    
    # 备份原文件
    if [ -f "$NETPLAN_FILE" ]; then
        sudo cp "$NETPLAN_FILE" "$BACKUP_FILE"
        echo "已备份原配置到 $BACKUP_FILE"
    fi
    
    # 处理 yaml 文件（使用 sed 修改，注意缩进均为2空格）
    if [ -f "$NETPLAN_FILE" ]; then
        # 检查是否已存在 addresses 行
        if grep -q "addresses:" "$NETPLAN_FILE"; then
            # 存在 addresses 行，提取现有 IP 列表（支持多行 - 格式或单行 [] 格式）
            # 简化处理：将 addresses 所在行的内容替换为新的列表格式（保留原有 IP + 新增 IP）
            # 先获取该行内容
            ADDR_LINE=$(grep -E "^\s+addresses:" "$NETPLAN_FILE" | head -n1)
            # 提取现有 IP（简单正则，不处理多行）
            EXISTING_IPS=$(echo "$ADDR_LINE" | sed -n 's/.*addresses:\s*\[\(.*\)\].*/\1/p')
            if [ -n "$EXISTING_IPS" ]; then
                # 格式为 [ip1, ip2]
                NEW_LIST="[$EXISTING_IPS, $NEW_IP]"
                # 替换整行
                sudo sed -i "s/^\s\+addresses:.*/    addresses: $NEW_LIST/" "$NETPLAN_FILE"
            else
                # 可能是多行列表（每行一个 - ip），或者没有 addresses
                # 简单处理：若找不到单行，则在缩进位置添加新的 addresses 行（保留原有）
                # 为避免复杂，我们直接覆盖整个文件，使用标准模板
                echo "检测到现有配置为多行 addresses 格式，将重建配置。"
                sudo cp "$NETPLAN_FILE" "$BACKUP_FILE"
                # 重建文件内容
                sudo bash -c "cat > $NETPLAN_FILE <<EOF
network:
  ethernets:
    $INTERFACE:
      dhcp4: true
      addresses:
        - $NEW_IP
  version: 2
EOF"
            fi
        else
            # 不存在 addresses，添加
            sudo sed -i "/dhcp4: true/a\      addresses:\n        - $NEW_IP" "$NETPLAN_FILE"
        fi
    else
        # 文件不存在，创建新文件
        echo "配置文件不存在，正在创建..."
        sudo mkdir -p /etc/netplan
        sudo bash -c "cat > $NETPLAN_FILE <<EOF
network:
  ethernets:
    $INTERFACE:
      dhcp4: true
      addresses:
        - $NEW_IP
  version: 2
EOF"
        echo "已创建配置文件: $NETPLAN_FILE"
    fi
    
    # 验证并应用配置
    echo "正在验证配置..."
    if sudo netplan try --timeout 10; then
        echo "配置应用成功。"
        sudo netplan apply
        echo "新 IP 已生效。"
    else
        echo "配置验证失败，已恢复备份。"
        if [ -f "$BACKUP_FILE" ]; then
            sudo cp "$BACKUP_FILE" "$NETPLAN_FILE"
            sudo netplan apply
        fi
        echo "请检查配置格式是否正确。"
    fi
    read -p "按回车键继续..."
}

# ======================== 升级函数（所有升级都会切换到 /home/menu 并使用 exec 替换进程） ========================
do_upgrade_16_6_fast0() {
    echo ">>> 正在执行升级 16.6 fast0，菜单将关闭..."
    cd /home/menu || exit
    rm -f POS_update.sh
    wget -O POS_update.sh https://github.com/jonaszhang91/update/raw/refs/heads/main/16.6/POS_update.sh
    exec sudo sh POS_update.sh
}

do_upgrade_16_7_1_fast0() {
    echo ">>> 正在执行升级 16.7.1 fast0，菜单将关闭..."
    cd /home/menu || exit
    rm -f POS_update.sh
    wget -O POS_update.sh https://github.com/jonaszhang91/update/raw/refs/heads/main/16.7.1/POS_update.sh
    exec sudo sh POS_update.sh
}

do_upgrade_16_7_2_fast0() {
    echo ">>> 正在执行升级 16.7.2 fast0，菜单将关闭..."
    cd /home/menu || exit
    rm -f POS_update.sh
    wget -O POS_update.sh https://github.com/jonaszhang91/update/raw/refs/heads/main/16.7.2/POS_update.sh
    exec sudo sh POS_update.sh
}

do_upgrade_30_13() {
    echo ">>> 正在执行升级 30.13，菜单将关闭..."
    cd /home/menu || exit
    rm -f POS_update.sh
    wget --user=baol22 --password="1qaz@WSX6788" -O POS_update.sh http://skymenu.menusifu.com.cn:29120/18030.13/POS_update.sh
    exec sudo sh POS_update.sh
}

do_upgrade_30_14_9() {
    echo ">>> 正在执行升级 30.14.9，菜单将关闭..."
    cd /home/menu || exit
    rm -f POS_update.sh
    wget --user=baol22 --password="1qaz@WSX6788" -O POS_update.sh http://skymenu.menusifu.com.cn:29120/18030.14/POS_update.sh
    exec sudo sh POS_update.sh
}

# ======================== 补丁函数 ========================
# 2.1 原有补丁
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

# 2.2 新增 SQL 修复补丁
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

# ======================== 菜单显示 ========================
show_main_menu() {
    clear
    echo "======================"
    echo "    主菜单"
    echo "======================"
    echo "网络IP列表："
    show_network_ips
    echo "======================"
    echo "1. 升级"
    echo "2. 打补丁"
    echo "3. 添加网段（静态IP）"
    echo "0. 退出"
    printf "请选择 [0-3]: "
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
    printf "请选择 [0-5]: "
}

show_patch_menu() {
    clear
    echo "======================"
    echo "    打补丁子菜单"
    echo "======================"
    echo "2.1 16.6 fast18 补丁"
    echo "2.2 166升级167_27more修复"
    echo "0. 返回主菜单"
    printf "请选择 [0-2]: "
}

# ======================== 菜单循环 ========================
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

# ======================== 主入口 ========================
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
            3) add_network_segment ;;
            0) echo "退出脚本。"; exit 0 ;;
            *) echo "无效输入，请重新选择！"; sleep 1 ;;
        esac
    done
}

main