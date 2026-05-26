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
    # 使用 -d 显示动态标志
    if ip -d -o -4 addr show > /dev/null 2>&1; then
        ip -d -o -4 addr show | grep -v LOOPBACK | grep -v "127.0.0.1" | while read line; do
            iface=$(echo "$line" | awk '{print $2}')
            ip_addr=$(echo "$line" | awk '{print $4}' | cut -d'/' -f1)
            # 检查是否有 dynamic 标志
            if echo "$line" | grep -q 'dynamic'; then
                type="DHCP IP"
            else
                # 根据接口名判断是否为虚拟接口
                case "$iface" in
                    docker*|veth*|br-*|virbr*|lxc*|vnet*|tun*|tap*|tunnel*|wg*|ovs*)
                        type="虚拟IP"
                        ;;
                    *)
                        type="静态IP"
                        ;;
                esac
            fi
            echo "  $iface: $ip_addr ($type)"
        done
    else
        # 降级 ifconfig（无 dynamic 信息，只能按接口名判断）
        ifconfig | grep -E 'inet ' | grep -v '127.0.0.1' | while read line; do
            ip_addr=$(echo "$line" | awk '{print $2}')
            iface=$(echo "$line" | awk '{print $1}')
            case "$iface" in
                docker*|veth*|br-*|virbr*|lxc*|vnet*|tun*|tap*)
                    type="虚拟IP"
                    ;;
                *)
                    type="静态IP"
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
    
    echo ">>> 开始配置网段（追加静态IP）"
    
    if ! command -v netplan > /dev/null 2>&1; then
        echo "错误：netplan 未安装，请先安装：sudo apt install netplan.io"
        read -p "按回车键继续..."
        return 1
    fi
    
    # 确定网卡名称
    INTERFACE=$(ip link show | grep -v lo | grep -E '^[0-9]+: en|eth' | head -n1 | awk -F': ' '{print $2}')
    if [ -z "$INTERFACE" ]; then
        echo "未找到物理网卡，请手动指定。"
        read -p "请输入网卡名称（如 enp1s0）: " INTERFACE
    fi
    echo "使用的网卡: $INTERFACE"
    
    # 输入新 IP
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
    
    # 处理文件内容
    if [ -f "$NETPLAN_FILE" ]; then
        # 检查该网卡下是否已有 addresses 配置
        # 提取从网卡定义开始到下一个网卡或 version 之前的块
        # 简单做法：使用 Python 风格的 yaml 处理较复杂，这里用 awk/sed 进行追加
        
        # 先判断是否存在 addresses 行（在该网卡缩进级别下）
        # 获取该网卡块的行范围（从 "网卡名:" 到下一个 "  [a-z]" 或 "version:"）
        START_LINE=$(grep -n "^\s*$INTERFACE:" "$NETPLAN_FILE" | cut -d: -f1)
        if [ -n "$START_LINE" ]; then
            # 找到 addresses: 所在行号
            ADDR_LINE=$(sed -n "${START_LINE},/^\s*[a-z]/p" "$NETPLAN_FILE" | grep -n "addresses:" | head -n1 | cut -d: -f1)
            if [ -n "$ADDR_LINE" ]; then
                # 获取绝对行号
                ABS_ADDR_LINE=$((START_LINE + ADDR_LINE - 1))
                # 检查是单行列表还是多行列表
                # 取 addresses: 后面的内容，去除首尾空格
                ADDR_CONTENT=$(sed -n "${ABS_ADDR_LINE}p" "$NETPLAN_FILE" | sed 's/.*addresses:\s*//')
                if echo "$ADDR_CONTENT" | grep -q '^\[.*\]$'; then
                    # 单行列表 [ip1, ip2]
                    EXISTING_IPS=$(echo "$ADDR_CONTENT" | sed 's/\[\(.*\)\]/\1/' | sed 's/ //g')
                    if [ -n "$EXISTING_IPS" ]; then
                        NEW_LIST="[$EXISTING_IPS, $NEW_IP]"
                    else
                        NEW_LIST="[$NEW_IP]"
                    fi
                    # 替换该行
                    sudo sed -i "${ABS_ADDR_LINE}s/.*/    addresses: $NEW_LIST/" "$NETPLAN_FILE"
                else
                    # 多行列表（- ip1 格式）或在同一行但无方括号，视为多行格式
                    # 在该 addresses: 行之后查找以 "    - " 开头的行，在末尾追加新项
                    # 获取该块结束行（下一个缩进小于当前的行，或文件尾）
                    # 简便方法：在 addresses: 行后直接插入一行 "- $NEW_IP"
                    # 为了避免重复插入，需确定是否已存在相同 IP，这里不做去重
                    # 查找最后一条 "- " 行，在其后插入
                    LAST_ITEM_LINE=$(sed -n "${ABS_ADDR_LINE},/^\s*[a-z]/p" "$NETPLAN_FILE" | grep -n "    - " | tail -n1 | cut -d: -f1)
                    if [ -n "$LAST_ITEM_LINE" ]; then
                        ABS_LAST_LINE=$((START_LINE + LAST_ITEM_LINE - 1))
                        sudo sed -i "${ABS_LAST_LINE}a\    - $NEW_IP" "$NETPLAN_FILE"
                    else
                        # 没有现有条目，在 addresses: 行后直接添加
                        sudo sed -i "${ABS_ADDR_LINE}a\    - $NEW_IP" "$NETPLAN_FILE"
                    fi
                fi
            else
                # 该网卡下没有 addresses 字段，添加
                # 找到网卡块内合适位置（通常在 dhcp4: true 之后）
                DHCP_LINE=$(sed -n "${START_LINE},/^\s*[a-z]/p" "$NETPLAN_FILE" | grep -n "dhcp4:" | head -n1 | cut -d: -f1)
                if [ -n "$DHCP_LINE" ]; then
                    ABS_DHCP_LINE=$((START_LINE + DHCP_LINE - 1))
                    sudo sed -i "${ABS_DHCP_LINE}a\      addresses:\n        - $NEW_IP" "$NETPLAN_FILE"
                else
                    # 没有 dhcp4，直接在网卡名称行后添加
                    sudo sed -i "${START_LINE}a\      dhcp4: true\n      addresses:\n        - $NEW_IP" "$NETPLAN_FILE"
                fi
            fi
        else
            # 网卡不存在于配置文件中，追加整个网卡配置
            sudo sed -i "/^network:/a\  ethernets:\n    $INTERFACE:\n      dhcp4: true\n      addresses:\n        - $NEW_IP" "$NETPLAN_FILE"
        fi
    else
        # 文件不存在，创建新文件
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
    
    # 验证并应用
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
reset_network() {
    NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
    echo ">>> 即将重置网络：删除 $NETPLAN_FILE 并应用 netplan 默认配置（DHCP）"
    read -p "确定要执行吗？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "操作已取消。"
        read -p "按回车键继续..."
        return 0
    fi
    
    if [ -f "$NETPLAN_FILE" ]; then
        sudo rm -f "$NETPLAN_FILE"
        echo "已删除配置文件 $NETPLAN_FILE"
    else
        echo "配置文件不存在，无需删除。"
    fi
    
    echo "正在应用 netplan 配置..."
    if sudo netplan apply; then
        echo "网络已重置，系统将自动通过 DHCP 获取 IP。"
        echo "新的 IP 信息如下："
        ip -4 addr show | grep inet | grep -v 127.0.0.1
    else
        echo "netplan apply 失败，请检查系统网络服务。"
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
    echo "3. 网络设置"
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

show_network_menu() {
    clear
    echo "======================"
    echo "    网络设置子菜单"
    echo "======================"
    echo "3.1 添加静态IP（追加模式）"
    echo "3.2 重置网络（恢复DHCP）"
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

network_menu_loop() {
    while true; do
        show_network_menu
        read sub_choice
        case $sub_choice in
            1) add_network_segment ;;
            2) reset_network ;;
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