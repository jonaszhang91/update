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

# ======================== 获取所有IPv4地址（正确识别 DHCP / 静态 / 虚拟） ========================
show_network_ips() {
    if ip -d -o -4 addr show > /dev/null 2>&1; then
        ip -d -o -4 addr show | grep -v LOOPBACK | grep -v "127.0.0.1" | while read line; do
            iface=$(echo "$line" | awk '{print $2}')
            ip_addr=$(echo "$line" | awk '{print $4}' | cut -d'/' -f1)
            if echo "$line" | grep -q 'dynamic'; then
                type="DHCP IP"
            else
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

# ======================== 获取可用网段列表（基于现有IP）返回格式：网段\n网段... ========================
get_network_segments() {
    # 使用 ip 命令获取所有非虚拟接口的 IP/CIDR，转换为网段格式（x.x.x.0/掩码）
    ip -o -4 addr show | grep -v LOOPBACK | grep -v docker | grep -v veth | grep -v br- | while read line; do
        cidr=$(echo "$line" | awk '{print $4}')   # 例如 192.168.1.100/24
        if [ -n "$cidr" ]; then
            # 提取 IP 和掩码位数
            ip_part=$(echo "$cidr" | cut -d'/' -f1)
            mask=$(echo "$cidr" | cut -d'/' -f2)
            # 将 IP 的最后一节替换为 0 得到网络地址
            network=$(echo "$ip_part" | sed 's/\.[0-9]*$/.0/')
            echo "${network}/${mask}"
        fi
    done | sort -u  # 去重
}

# ======================== 扫描指定端口 ========================
scan_port_on_network() {
    port=$1
    description=$2
    
    # 检查 nmap
    if ! command -v nmap > /dev/null 2>&1; then
        echo "nmap 未安装，是否安装？(y/n): "
        read install_nmap
        if [ "$install_nmap" = "y" ] || [ "$install_nmap" = "Y" ]; then
            sudo apt update && sudo apt install nmap -y
            if [ $? -ne 0 ]; then
                echo "安装 nmap 失败，请手动安装。"
                read -p "按回车键继续..."
                return 1
            fi
        else
            echo "未安装 nmap，无法扫描。"
            read -p "按回车键继续..."
            return 1
        fi
    fi
    
    # 获取网段列表（存储到变量，每行一个网段）
    segments=$(get_network_segments)
    if [ -z "$segments" ]; then
        echo "未找到有效网段，请手动输入。"
        read -p "请输入要扫描的网段（如 192.168.1.0/24）: " target
    else
        # 将网段列表转为行数组（使用 awk 编号）
        echo "检测到以下网段："
        seg_count=0
        # 使用临时文件存储网段，避免子 shell 问题
        tmp_file="/tmp/net_segments_$$"
        echo "$segments" > "$tmp_file"
        seg_count=$(wc -l < "$tmp_file")
        # 显示列表
        awk '{print "  " NR ") " $0}' "$tmp_file"
        echo "  0) 手动输入网段"
        printf "请选择要扫描的网段 [0-%d]: " "$seg_count"
        read choice
        if [ "$choice" = "0" ]; then
            read -p "请输入网段（如 192.168.1.0/24）: " target
        elif [ "$choice" -ge 1 ] && [ "$choice" -le "$seg_count" ]; then
            target=$(sed -n "${choice}p" "$tmp_file")
        else
            echo "无效选择。"
            rm -f "$tmp_file"
            read -p "按回车键继续..."
            return 1
        fi
        rm -f "$tmp_file"
    fi
    
    echo "正在扫描 $target 的 $description (端口 $port) ..."
    # 使用 nmap 扫描，仅显示开放的 IP
    result=$(sudo nmap -p $port --open -Pn -T4 "$target" 2>/dev/null | grep -E "^Nmap scan report for" | awk '{print $5}')
    if [ -z "$result" ]; then
        echo "未发现开放端口 $port 的设备。"
    else
        echo "发现以下设备开放 $description 端口 $port："
        echo "$result" | while read ip; do
            echo "  $ip"
        done
    fi
    read -p "按回车键继续..."
}

# ======================== 添加静态IP（追加模式） ========================
add_network_segment() {
    NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
    BACKUP_FILE="/etc/netplan/50-cloud-init.yaml.bak"
    
    echo ">>> 开始配置网段（追加静态IP）"
    
    if ! command -v netplan > /dev/null 2>&1; then
        echo "错误：netplan 未安装，请先安装：sudo apt install netplan.io"
        read -p "按回车键继续..."
        return 1
    fi
    
    INTERFACE=$(ip link show | grep -v lo | grep -E '^[0-9]+: en|eth' | head -n1 | awk -F': ' '{print $2}')
    if [ -z "$INTERFACE" ]; then
        echo "未找到物理网卡，请手动指定。"
        read -p "请输入网卡名称（如 enp1s0）: " INTERFACE
    fi
    echo "使用的网卡: $INTERFACE"
    
    echo "请输入要添加的静态 IP 地址及掩码（格式如 192.168.1.199/24）"
    read -p "IP地址: " NEW_IP
    if [ -z "$NEW_IP" ]; then
        echo "未输入IP，取消操作。"
        read -p "按回车键继续..."
        return 0
    fi
    
    if [ -f "$NETPLAN_FILE" ]; then
        sudo cp "$NETPLAN_FILE" "$BACKUP_FILE"
        echo "已备份原配置到 $BACKUP_FILE"
    fi
    
    if [ -f "$NETPLAN_FILE" ]; then
        START_LINE=$(grep -n "^\s*$INTERFACE:" "$NETPLAN_FILE" | cut -d: -f1)
        if [ -n "$START_LINE" ]; then
            ADDR_LINE=$(sed -n "${START_LINE},/^\s*[a-z]/p" "$NETPLAN_FILE" | grep -n "addresses:" | head -n1 | cut -d: -f1)
            if [ -n "$ADDR_LINE" ]; then
                ABS_ADDR_LINE=$((START_LINE + ADDR_LINE - 1))
                ADDR_CONTENT=$(sed -n "${ABS_ADDR_LINE}p" "$NETPLAN_FILE" | sed 's/.*addresses:\s*//')
                if echo "$ADDR_CONTENT" | grep -q '^\[.*\]$'; then
                    EXISTING_IPS=$(echo "$ADDR_CONTENT" | sed 's/\[\(.*\)\]/\1/' | sed 's/ //g')
                    if [ -n "$EXISTING_IPS" ]; then
                        NEW_LIST="[$EXISTING_IPS, $NEW_IP]"
                    else
                        NEW_LIST="[$NEW_IP]"
                    fi
                    sudo sed -i "${ABS_ADDR_LINE}s/.*/    addresses: $NEW_LIST/" "$NETPLAN_FILE"
                else
                    LAST_ITEM_LINE=$(sed -n "${ABS_ADDR_LINE},/^\s*[a-z]/p" "$NETPLAN_FILE" | grep -n "    - " | tail -n1 | cut -d: -f1)
                    if [ -n "$LAST_ITEM_LINE" ]; then
                        ABS_LAST_LINE=$((START_LINE + LAST_ITEM_LINE - 1))
                        sudo sed -i "${ABS_LAST_LINE}a\    - $NEW_IP" "$NETPLAN_FILE"
                    else
                        sudo sed -i "${ABS_ADDR_LINE}a\    - $NEW_IP" "$NETPLAN_FILE"
                    fi
                fi
            else
                DHCP_LINE=$(sed -n "${START_LINE},/^\s*[a-z]/p" "$NETPLAN_FILE" | grep -n "dhcp4:" | head -n1 | cut -d: -f1)
                if [ -n "$DHCP_LINE" ]; then
                    ABS_DHCP_LINE=$((START_LINE + DHCP_LINE - 1))
                    sudo sed -i "${ABS_DHCP_LINE}a\      addresses:\n        - $NEW_IP" "$NETPLAN_FILE"
                else
                    sudo sed -i "${START_LINE}a\      dhcp4: true\n      addresses:\n        - $NEW_IP" "$NETPLAN_FILE"
                fi
            fi
        else
            sudo sed -i "/^network:/a\  ethernets:\n    $INTERFACE:\n      dhcp4: true\n      addresses:\n        - $NEW_IP" "$NETPLAN_FILE"
        fi
    else
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

# ======================== 重置网络（删除50文件并恢复DHCP） ========================
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

# ======================== 升级函数 ========================
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
    wget --user=baol22 --password="1qaz@WSX6788" -O POS_update.sh http://menusifu.com.cn:29120/18030.13/POS_update.sh
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
    echo "3.3 扫描刷卡机（端口10009）"
    echo "3.4 扫描打印机（端口9100）"
    echo "0. 返回主菜单"
    printf "请选择 [0-4]: "
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
            3) scan_port_on_network 10009 "刷卡机" ;;
            4) scan_port_on_network 9100 "打印机" ;;
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
            3) network_menu_loop ;;
            0) echo "退出脚本。"; exit 0 ;;
            *) echo "无效输入，请重新选择！"; sleep 1 ;;
        esac
    done
}

main