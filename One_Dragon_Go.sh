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
    ip -o -4 addr show | while read line; do
        iface=$(echo "$line" | awk '{print $2}')
        # 跳过回环和虚拟接口
        case "$iface" in
            lo|docker*|veth*|br-*|virbr*|lxc*|vnet*|tun*|tap*|tunnel*|wg*|ovs*)
                continue
                ;;
        esac
        cidr=$(echo "$line" | awk '{print $4}')
        if [ -n "$cidr" ]; then
            ip_part=$(echo "$cidr" | cut -d'/' -f1)
            mask=$(echo "$cidr" | cut -d'/' -f2)
            # 跳过回环地址段
            case "$ip_part" in
                127.*) continue ;;
            esac
            network=$(echo "$ip_part" | sed 's/\.[0-9]*$/.0/')
            echo "${network}/${mask}"
        fi
    done | sort -u
}

# ======================== 扫描指定端口（含数据库对比） ========================
scan_port_on_network() {
    port=$1
    description=$2
    
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
    
    segments=$(get_network_segments)
    if [ -z "$segments" ]; then
        echo "未自动检测到有效网段。"
        read -p "请手动输入要扫描的网段（如 192.168.1.0/24）: " target
    else
        tmp_file="/tmp/net_segments_$$"
        echo "$segments" > "$tmp_file"
        seg_count=$(wc -l < "$tmp_file")
        echo "检测到以下网段："
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
    result=$(sudo nmap -p $port --open -Pn -T4 -n "$target" 2>/dev/null | grep -E "^Nmap scan report for" | awk '{print $5}')
    
    # 刷卡机对比（端口10009）
    if [ "$port" = "10009" ]; then
        echo ""
        echo "========== 扫描结果与数据库PAX设备对比 =========="
        pax_devices=$(mysql -u root --password='N0mur@4$99!' kpos -sN -e "SELECT name, ip_address, model_name FROM device WHERE manufacturer_name = 'PAX' AND ip_address IS NOT NULL AND ip_address != '';" 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo "数据库查询失败，请检查MySQL连接及表结构。"
        else
            tmp_file_db="/tmp/pax_devices_$$.tmp"
            echo "$pax_devices" | while IFS=$'\t' read name ip model; do
                echo "$ip|$name|$model" >> "$tmp_file_db"
            done
            if [ -f "$tmp_file_db" ]; then
                echo "数据库中的PAX设备列表："
                cat "$tmp_file_db" | while IFS='|' read ip name model; do
                    echo "  IP: $ip | 名称: $name | 型号: $model"
                done
                echo ""
                if [ -n "$result" ]; then
                    echo "扫描到开放端口10009的设备："
                    scanned_ips="$result"
                    echo "$scanned_ips" | while read ip; do
                        matched=$(grep "^$ip|" "$tmp_file_db")
                        if [ -n "$matched" ]; then
                            info=$(echo "$matched" | cut -d'|' -f2-3)
                            echo "  ✓ $ip (数据库中已存在: $info)"
                        else
                            echo "  ✗ $ip (未在数据库中登记为PAX设备)"
                        fi
                    done
                    echo ""
                    echo "数据库中PAX设备但未扫描到的IP（可能离线或未开放端口）："
                    found=0
                    cat "$tmp_file_db" | while IFS='|' read ip name model; do
                        if ! echo "$scanned_ips" | grep -q "^$ip$"; then
                            echo "  ✗ $ip (名称: $name, 型号: $model)"
                            found=1
                        fi
                    done
                    if [ $found -eq 0 ]; then
                        echo "  无"
                    fi
                else
                    echo "扫描未发现任何开放10009端口的设备。"
                    echo ""
                    echo "数据库中PAX设备列表（但均未扫描到）："
                    cat "$tmp_file_db" | while IFS='|' read ip name model; do
                        echo "  IP: $ip | 名称: $name | 型号: $model"
                    done
                fi
                rm -f "$tmp_file_db"
            else
                echo "数据库中没有 manufacturer_name='PAX' 的设备记录。"
                if [ -n "$result" ]; then
                    echo "扫描到开放端口10009的设备："
                    echo "$result" | while read ip; do
                        echo "  $ip"
                    done
                else
                    echo "未发现开放端口10009的设备。"
                fi
            fi
        fi
        echo "=============================================="
    
    # 打印机对比（端口9100）—— 使用 interface_value 作为 IP
    elif [ "$port" = "9100" ]; then
        echo ""
        echo "========== 扫描结果与数据库网络打印机对比 =========="
        printer_devices=$(mysql -u root --password='N0mur@4$99!' kpos -sN -e "SELECT name, interface_value, interface_value FROM printer WHERE real_name != 'Display' AND is_network_printer = 1 AND interface_value IS NOT NULL AND interface_value != '';" 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo "数据库查询失败，请检查MySQL连接及表结构。"
        else
            tmp_file_db="/tmp/printer_devices_$$.tmp"
            echo "$printer_devices" | while IFS=$'\t' read name ip interface; do
                echo "$ip|$name|$interface" >> "$tmp_file_db"
            done
            if [ -f "$tmp_file_db" ]; then
                echo "数据库中的网络打印机列表："
                cat "$tmp_file_db" | while IFS='|' read ip name interface; do
                    echo "  IP: $ip | 名称: $name | 接口: $interface"
                done
                echo ""
                if [ -n "$result" ]; then
                    echo "扫描到开放端口9100的设备："
                    scanned_ips="$result"
                    echo "$scanned_ips" | while read ip; do
                        matched=$(grep "^$ip|" "$tmp_file_db")
                        if [ -n "$matched" ]; then
                            info=$(echo "$matched" | cut -d'|' -f2-3)
                            echo "  ✓ $ip (数据库中已存在: $info)"
                        else
                            echo "  ✗ $ip (未在数据库中登记为网络打印机)"
                        fi
                    done
                    echo ""
                    echo "数据库中网络打印机但未扫描到的IP（可能离线或未开放9100端口）："
                    found=0
                    cat "$tmp_file_db" | while IFS='|' read ip name interface; do
                        if ! echo "$scanned_ips" | grep -q "^$ip$"; then
                            echo "  ✗ $ip (名称: $name, 接口: $interface)"
                            found=1
                        fi
                    done
                    if [ $found -eq 0 ]; then
                        echo "  无"
                    fi
                else
                    echo "扫描未发现任何开放9100端口的设备。"
                    echo ""
                    echo "数据库中网络打印机列表（但均未扫描到）："
                    cat "$tmp_file_db" | while IFS='|' read ip name interface; do
                        echo "  IP: $ip | 名称: $name | 接口: $interface"
                    done
                fi
                rm -f "$tmp_file_db"
            else
                echo "数据库中没有符合条件的网络打印机记录（real_name != 'Display' 且 is_network_printer=1）。"
                if [ -n "$result" ]; then
                    echo "扫描到开放端口9100的设备："
                    echo "$result" | while read ip; do
                        echo "  $ip"
                    done
                else
                    echo "未发现开放端口9100的设备。"
                fi
            fi
        fi
        echo "=============================================="
    
    else
        if [ -z "$result" ]; then
            echo "未发现开放端口 $port 的设备。"
        else
            echo "发现以下设备开放 $description 端口 $port："
            i=1
            echo "$result" | while read ip; do
                echo "  $i) $ip"
                i=$((i+1))
            done
        fi
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

# ======================== 重启 Tomcat ========================
restart_tomcat() {
    echo ">>> 正在重启 Tomcat 服务..."
    sudo service tomcat restart
    if [ $? -eq 0 ]; then
        echo ">>> Tomcat 重启成功"
    else
        echo ">>> Tomcat 重启失败，请检查服务状态"
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

# ======================== 补丁函数（动态检测解压目录，修正路径错误） ========================
# 2.1 16.6 fast18 补丁
do_patch_16_6_fast18() {
    echo ">>> 正在执行 16.6 fast18 补丁 ..."
    cd /home/menu || exit
    sudo rm -rf pit
    sudo rm -rf 1.8.0.30.16.6-fast-18-PIT-12780
    wget --no-check-certificate 'https://docs.google.com/uc?export=download&id=1-55kWzmMsctc06FCHlPrbgeQGU6jwS3X' -O pit
    unzip pit > /dev/null
    # 获取解压出的第一个目录（排除 pit 自身）
    PATCH_DIR=$(ls -d */ 2>/dev/null | grep -v '^pit$' | head -1 | sed 's|/||')
    if [ -z "$PATCH_DIR" ]; then
        echo "无法确定解压后的目录，请检查补丁包。"
        read -p "按回车键继续..."
        return 1
    fi
    sudo cp -rf "$PATCH_DIR"/kpos/* /opt/apache-tomcat-7.0.93/webapps/kpos/
    mysql -u root --password='N0mur@4$99!' kpos < "$PATCH_DIR"/alter_terminal.sql
    mysql -u root --password='N0mur@4$99!' kpos < "$PATCH_DIR"/0_db.sql
    sudo service tomcat restart
    if [ $? -eq 0 ]; then
        echo ">>> 16.6 fast18 补丁完成"
    else
        echo ">>> 16.6 fast18 补丁失败，请检查错误"
    fi
    sudo rm -rf pit "$PATCH_DIR"
    read -p "按回车键继续..."
}

# 2.2 166升级167_27more修复（SQL，无文件操作）
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

# 2.3 17.2 fast0 补丁
do_patch_17_2_fast0() {
    echo ">>> 正在执行 17.2 fast0 补丁 ..."
    cd /home/menu || exit
    sudo rm -rf pit
    sudo rm -rf 1.8.0.30.16.7.2-fast-0-PIT-17982
    wget --no-check-certificate 'https://docs.google.com/uc?export=download&id=1FMq0TiQ3UWAnZfxOAFqTbHgenASFt3nE' -O pit
    unzip pit > /dev/null
    PATCH_DIR=$(ls -d */ 2>/dev/null | grep -v '^pit$' | head -1 | sed 's|/||')
    if [ -z "$PATCH_DIR" ]; then
        echo "无法确定解压后的目录，请检查补丁包。"
        read -p "按回车键继续..."
        return 1
    fi
    sudo cp -rf "$PATCH_DIR"/kpos/* /opt/apache-tomcat-7.0.93/webapps/kpos/
    sudo rm -rf pit "$PATCH_DIR"
    if [ $? -eq 0 ]; then
        echo ">>> 17.2 fast0 补丁完成"
    else
        echo ">>> 17.2 fast0 补丁失败，请检查错误"
    fi
    read -p "按回车键继续..."
}

# 2.4 16.7.2 fast16 补丁
do_patch_16_7_2_fast16() {
    echo ">>> 正在执行 16.7.2 fast16 补丁 ..."
    cd /home/menu || exit
    sudo rm -rf pit
    sudo rm -rf 1.8.0.30.16.7.2-fast-167-PIT-20035
    wget --no-check-certificate 'https://docs.google.com/uc?export=download&id=1dpHX3iNOux7or61DfjlJalECGYu2jTY0' -O pit
    unzip pit > /dev/null
    PATCH_DIR=$(ls -d */ 2>/dev/null | grep -v '^pit$' | head -1 | sed 's|/||')
    if [ -z "$PATCH_DIR" ]; then
        echo "无法确定解压后的目录，请检查补丁包。"
        read -p "按回车键继续..."
        return 1
    fi
    sudo cp -rf "$PATCH_DIR"/kpos/* /opt/apache-tomcat-7.0.93/webapps/kpos/
    sudo rm -rf pit "$PATCH_DIR"
    if [ $? -eq 0 ]; then
        echo ">>> 16.7.2 fast16 补丁完成"
    else
        echo ">>> 16.7.2 fast16 补丁失败，请检查错误"
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
    # 硬件信息
    cpu_model=$(lscpu | grep "Model name" | head -1 | cut -d':' -f2 | sed 's/^[ \t]*//')
    if [ -z "$cpu_model" ]; then
        cpu_model=$(cat /proc/cpuinfo | grep "model name" | head -1 | cut -d':' -f2 | sed 's/^[ \t]*//')
    fi
    mem_total=$(free -h | grep Mem | awk '{print $2}')
    echo "硬件信息："
    echo "  CPU: $cpu_model"
    echo "  内存: $mem_total"
    echo "======================"
    echo "1. 升级"
    echo "2. 打补丁"
    echo "3. 网络设置"
    echo "4. 重启 Tomcat"
    echo "0. 退出"
    printf "请选择 [0-4]: "
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
    echo "2.3 17.2 fast0 补丁"
    echo "2.4 16.7.2 fast16 补丁"
    echo "0. 返回主菜单"
    printf "请选择 [0-4]: "
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
            3) do_patch_17_2_fast0 ;;
            4) do_patch_16_7_2_fast16 ;;
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
            4) restart_tomcat ;;
            0) echo "退出脚本。"; exit 0 ;;
            *) echo "无效输入，请重新选择！"; sleep 1 ;;
        esac
    done
}

main