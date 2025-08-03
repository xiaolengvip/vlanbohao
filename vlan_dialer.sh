#!/bin/bash
#!/bin/bash
# VLAN拨号程序脚本
# 版本: 1.0
# 描述: 创建虚拟VLAN网卡并建立拨号连接，支持虚拟WAN口流量均衡

# 确保以bash运行
if [ -z "$BASH_VERSION" ]; then
    echo "请使用bash运行此脚本"
    exit 1
fi

# 只在调试模式下启用set -x
# 可以通过 export DEBUG=1 启用调试
if [ "$DEBUG" = "1" ]; then
    set -x
fi

# 存储已使用的MAC地址的文件
USED_MAC_FILE="/tmp/used_mac_addresses.txt"

# 生成随机MAC地址并确保不重复
function generate_unique_mac_address() {
    # 确保存储文件存在
    mkdir -p $(dirname $USED_MAC_FILE)
    touch $USED_MAC_FILE

    while true; do
        # 生成随机MAC地址（以52:54:00开头，这是QEMU/KVM的OUI）
        # 使用openssl生成随机字节，更可靠
        random_bytes=$(openssl rand -hex 3 | sed 's/../&:/g; s/:$//')
        mac_address="52:54:00:$random_bytes"

        # 确保第一个字节为偶数（符合MAC地址规范）
        first_byte=$(echo $mac_address | cut -d: -f1)
        first_byte=$((0x$first_byte & 0xFE))
        first_byte=$(printf "%02x" $first_byte)
        mac_address=$(echo $mac_address | sed "s/^[^:]*:/$first_byte:/")

        # 检查MAC地址是否已使用
        if ! grep -q "^$mac_address$" $USED_MAC_FILE; then
            # 添加到已使用列表
            echo $mac_address >> $USED_MAC_FILE
            echo $mac_address
            return 0
        fi
    done
}


# VLAN拨号程序
# 此脚本创建虚拟VLAN网卡并建立拨号连接，支持虚拟WAN口流量均衡
# 使用方法: ./vlan_dialer.sh {start|stop|restart|status|configure|add_vlan|delete_vlan|configure_load_balance}
# 此脚本创建虚拟VLAN网卡并建立拨号连接
# 使用方法: ./vlan_dialer.sh {start|stop|restart|status|configure|add_vlan|delete_vlan}

# 配置虚拟WAN口流量均衡
configure_load_balance() {
    # 优先从环境变量获取策略，如果没有则使用命令行参数
    local strategy=${LOAD_BALANCE_STRATEGY:-$1}
    local wan_interfaces=()
    local table_id=200  # 起始路由表ID

    if [ -z "$strategy" ]; then
        echo "请指定负载均衡策略: round-robin, weighted"
        echo "用法: ./vlan_dialer.sh configure_load_balance <策略> 或设置环境变量 LOAD_BALANCE_STRATEGY"
        exit 1
    fi

    # 检查策略是否支持
    if [ "$strategy" != "round-robin" ] && [ "$strategy" != "weighted" ]; then
        echo "不支持的负载均衡策略: $strategy"
        echo "支持的策略: round-robin, weighted"
        exit 1
    fi

    echo "开始配置虚拟WAN口流量均衡，策略: $strategy"

    # 检测所有虚拟WAN口
    echo "检测系统中的虚拟WAN口..."
    while IFS= read -r line; do
        if [[ $line == *"wan-"* ]]; then
            interface=$(echo $line | cut -d':' -f2 | tr -d ' ')
            wan_interfaces+=($interface)
            echo "找到虚拟WAN口: $interface"
        fi
    done < <(ip link show)

    if [ ${#wan_interfaces[@]} -eq 0 ]; then
        echo "未找到虚拟WAN口，请先添加VLAN"
        exit 1
    fi

    if [ ${#wan_interfaces[@]} -eq 1 ]; then
        echo "只有一个虚拟WAN口，无需配置流量均衡"
        exit 0
    fi

    # 启用IP转发
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "已启用IP转发"

    # 清除旧的策略路由规则和表
    echo "清除旧的策略路由规则和表..."
    # 清除特定表的规则而不是所有规则
    for table in $(grep -o '^[0-9]\+ .*wan-' /etc/iproute2/rt_tables 2>/dev/null | cut -d' ' -f1); do
        ip rule flush table $table 2> /dev/null
        ip route flush table $table 2> /dev/null
    done
    # 清除旧的负载均衡链
    iptables -t mangle -F WAN_LOAD_BALANCE 2> /dev/null
    iptables -t mangle -D PREROUTING -j WAN_LOAD_BALANCE 2> /dev/null
    iptables -t mangle -X WAN_LOAD_BALANCE 2> /dev/null
    # 刷新路由缓存
    ip route flush cache
    echo "旧的策略路由规则和表已清除"

    # 为每个虚拟WAN口配置路由表
    echo "为每个虚拟WAN口配置路由表..."
    # 先清空相关的路由表条目
    sed -i '/wan-/d' /etc/iproute2/rt_tables

    for interface in "${wan_interfaces[@]}"; do
        # 获取接口的IP地址和网关
        ip_addr=$(ip addr show $interface | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
        if [ -z "$ip_addr" ]; then
            echo "警告: 虚拟WAN口 $interface 没有IP地址，跳过"
            continue
        fi

        # 获取网关（从路由表中）
        gateway=$(ip route show dev $interface | grep default | awk '{print $3}')

        # 为接口创建路由表
        echo "配置虚拟WAN口 $interface 的路由表..."
        echo "$table_id $interface" >> /etc/iproute2/rt_tables
        if [ -n "$gateway" ]; then
            ip route add default via $gateway dev $interface table $table_id
        else
            ip route add default dev $interface table $table_id
        fi
        # 根据源IP设置规则，更加精确
        ip rule add from $(echo $ip_addr | cut -d'/' -f1) table $table_id
        ip rule add fwmark $table_id table $table_id
        echo "已配置路由表 $table_id 用于 $interface"

        table_id=$((table_id + 1))
    done

    # 配置负载均衡策略
    echo "配置负载均衡策略: $strategy"
    chain_name="WAN_LOAD_BALANCE"
    iptables -t mangle -N $chain_name
    iptables -t mangle -F $chain_name
    iptables -t mangle -A PREROUTING -j $chain_name

    if [ "$strategy" = "round-robin" ]; then
        # 使用iptables的statistic模块实现轮询
        echo "配置轮询负载均衡..."
        current_mark=200
        interface_count=${#wan_interfaces[@]}

        for ((i=0; i<interface_count; i++)); do
            iptables -t mangle -A $chain_name -m state --state NEW -m statistic --mode nth --every $interface_count --packet $i -j MARK --set-mark $((current_mark + i))
        done
    elif [ "$strategy" = "weighted" ]; then
        # 实现加权轮询
        echo "配置加权轮询负载均衡..."
        current_mark=200
        packet=0

        # 从配置文件或环境变量加载权重，如果没有则使用默认值1
        # 这里使用数组存储权重，索引对应wan_interfaces数组
        local weights=()
        for ((i=0; i<${#wan_interfaces[@]}; i++)); do
            # 尝试从环境变量加载权重，格式为 WEIGHT_wan-interface=值
            local if_weight_var="WEIGHT_${wan_interfaces[$i]}"
            local weight=${!if_weight_var:-1}
            weights+=($weight)
        done

        for ((i=0; i<${#wan_interfaces[@]}; i++)); do
            local interface=${wan_interfaces[$i]}
            local weight=${weights[$i]}
            echo "为 $interface 分配权重: $weight"
            iptables -t mangle -A $chain_name -m statistic --mode nth --every $((packet + weight)) --packet $packet -j MARK --set-mark $((current_mark + i))
            packet=$((packet + weight))
        done
    fi

    # 保存iptables规则
    echo "保存iptables规则..."
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    echo "iptables规则已保存"

    # 刷新路由缓存
    ip route flush cache
    echo "路由缓存已刷新"

    echo "虚拟WAN口流量均衡配置完成"
}

# 删除VLAN接口和对应的虚拟WAN口
delete_vlan_interface() {
    local vlan_interface=$1
    # 提取物理接口和VLAN ID
    local physical_interface=$(echo $vlan_interface | cut -d'.' -f1)
    local vlan_id=$(echo $vlan_interface | cut -d'.' -f2)
    local virtual_wan_interface="wan-${physical_interface}-${vlan_id}"

    echo "正在删除VLAN接口 $vlan_interface..."
    # 先检查VLAN接口是否存在
    if ip link show $vlan_interface &> /dev/null; then
        if ! ip link delete $vlan_interface; then
            echo "删除VLAN接口失败"
        else
            echo "VLAN接口已删除"
        fi
    else
        echo "VLAN接口不存在，跳过删除"
    fi

    # 删除对应的虚拟WAN口
    echo "正在删除虚拟WAN口 $virtual_wan_interface..."
    if ip link show $virtual_wan_interface &> /dev/null; then
        if ! ip link delete $virtual_wan_interface; then
            echo "删除虚拟WAN口失败"
        else
            echo "虚拟WAN口已删除"
        fi
    else
        echo "虚拟WAN口不存在，跳过删除"
    fi

    # 删除相关的iptables规则
    echo "正在清理相关的iptables规则..."
    iptables -D FORWARD -i $vlan_interface -o $virtual_wan_interface -j ACCEPT 2> /dev/null
    iptables -D FORWARD -i $virtual_wan_interface -o $vlan_interface -m state --state RELATED,ESTABLISHED -j ACCEPT 2> /dev/null
    echo "iptables规则清理完成"
}

# 配置文件路径
CONFIG_FILE="/etc/vlan_dialer.conf"

# 检查是否以root权限运行
if [ "$EUID" -ne 0 ]
  then echo "请以root权限运行此脚本"
  exit 1
fi

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "正在加载配置文件: $CONFIG_FILE"
        source "$CONFIG_FILE"
    else
        echo "未找到配置文件: $CONFIG_FILE"
        return 1
    fi

    # 检查基本配置是否完整
    if [ -z "$PHYSICAL_INTERFACE" ] || [ -z "$CONNECTION_TYPE" ]; then
        echo "配置不完整，请先运行 'configure' 命令"
        exit 1
    fi

    # 根据连接类型检查不同的配置参数
    if [ "$CONNECTION_TYPE" = "pppoe" ]; then
        if [ -z "$VLAN_ID" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
            echo "PPPoE配置不完整，请先运行 'configure' 命令"
            exit 1
        fi
        # 设置PPPoE相关变量
        VLAN_INTERFACE="${PHYSICAL_INTERFACE}.${VLAN_ID}"
        PPPOE_INTERFACE="ppp0"
    elif [ "$CONNECTION_TYPE" = "static" ]; then
        if [ -z "$STATIC_IP" ] || [ -z "$SUBNET_MASK" ] || [ -z "$GATEWAY" ] || [ -z "$DNS_SERVER" ]; then
            echo "静态IP配置不完整，请先运行 'configure' 命令"
            exit 1
        fi
    else
        echo "不支持的上网方式: $CONNECTION_TYPE"
        exit 1
    fi

    # 加载静态IP配置（如果有）
    if [ ! -z "$STATIC_IP" ]; then
        echo "检测到静态IP配置: $STATIC_IP"
    fi

    if [ ! -z "$SUBNET_MASK" ]; then
        echo "检测到子网掩码配置: $SUBNET_MASK"
    fi

    if [ ! -z "$GATEWAY" ]; then
        echo "检测到网关配置: $GATEWAY"
    fi

    if [ ! -z "$DNS_SERVER" ]; then
        echo "检测到DNS服务器配置: $DNS_SERVER"
    fi

    echo "配置加载成功"
    return 0
}

# 保存配置
save_config() {
    echo "正在保存配置到: $CONFIG_FILE"

    cat > "$CONFIG_FILE" << EOF
# VLAN拨号程序配置文件
PHYSICAL_INTERFACE="$PHYSICAL_INTERFACE"  # 物理网卡接口
VLAN_ID=$VLAN_ID                           # VLAN ID
USERNAME="$USERNAME"                       # 拨号用户名
PASSWORD="$PASSWORD"                       # 拨号密码
EOF

    if [ $? -ne 0 ]; then
        echo "保存配置失败"
        exit 1
    fi

    # 设置配置文件权限
    chmod 600 "$CONFIG_FILE"
    echo "配置保存成功，权限已设置为600"
}

# 配置向导
configure() {
    echo "===== VLAN拨号程序配置向导 ====="
    echo "可用的网络接口:"
    ip link show | grep -E '^[0-9]+:' | cut -d':' -f2 | tr -d ' '
    read -p "请输入物理网卡接口名称 (例如: eth0): " PHYSICAL_INTERFACE

    # 获取VLAN ID
    read -p "请输入VLAN ID (例如: 100): " VLAN_ID
    if ! [[ "$VLAN_ID" =~ ^[0-9]+$ ]] || [ "$VLAN_ID" -lt 1 ] || [ "$VLAN_ID" -gt 4094 ]; then
        echo "无效的VLAN ID，必须是1-4094之间的数字"
        exit 1
    fi

    # 获取拨号用户名和密码
    read -p "请输入拨号用户名: " USERNAME
    read -s -p "请输入拨号密码: " PASSWORD
    echo
    read -s -p "请再次输入拨号密码: " PASSWORD_CONFIRM
    echo

    if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
        echo "两次输入的密码不一致"
        exit 1
    fi

    # 保存配置
    save_config
}

# 检测系统类型，用于提供更准确的安装指导
detect_os() {
    if [ -f /etc/debian_version ]; then
        echo "检测到Debian/Ubuntu系统"
        OS_TYPE="debian"
    elif [ -f /etc/redhat-release ]; then
        echo "检测到CentOS/RHEL系统"
        OS_TYPE="redhat"
    elif [ -f /etc/arch-release ]; then
        echo "检测到Arch Linux系统"
        OS_TYPE="arch"
    else
        echo "未知系统类型"
        OS_TYPE="unknown"
    fi
}

# 安装依赖包
install_dependencies() {
    echo "正在安装必要的依赖包..."
    case $OS_TYPE in
        debian)
            apt-get update && apt-get install -y iproute2 pppoeconf
            ;;
        redhat)
            yum install -y iproute2 rp-pppoe
            ;;
        arch)
            pacman -S --noconfirm iproute2 rp-pppoe
            ;;
        *)
            echo "无法自动安装依赖包，请手动安装iproute2和pppoe相关工具"
            exit 1
            ;;
    esac

    if [ $? -ne 0 ]; then
        echo "安装依赖包失败，请手动安装"
        exit 1
    fi
    echo "依赖包安装成功"
}

# 检查是否安装了必要的工具
check_dependency() {
    if ! command -v $1 &> /dev/null
    then
        echo "错误: 未找到命令 $1"
        case $1 in
            pppoeconf|pon|poff)
                echo "请安装pppoeconf包"
                # 在非交互式环境中自动安装
                if [ -t 0 ];
                then
                    read -p "是否自动安装依赖包? (y/n): " choice
                    if [ "$choice" = "y" ] || [ "$choice" = "Y" ];
                    then
                        detect_os
                        install_dependencies
                    else
                        exit 1
                    fi
                else
                    echo "在非交互式环境中自动安装依赖包..."
                    detect_os
                    install_dependencies
                fi
                ;;
            ip)
                echo "请安装iproute2包"
                # 在非交互式环境中自动安装
                if [ -t 0 ];
                then
                    read -p "是否自动安装依赖包? (y/n): " choice
                    if [ "$choice" = "y" ] || [ "$choice" = "Y" ];
                    then
                        detect_os
                        install_dependencies
                    else
                        exit 1
                    fi
                else
                    echo "在非交互式环境中自动安装依赖包..."
                    detect_os
                    install_dependencies
                fi
                ;;
        esac
    fi
}

# 检查运行环境
if [ -t 0 ]
then
    echo "在交互式环境中运行，执行依赖检查..."
    check_dependency ip
    check_dependency pppoeconf
    check_dependency pon
    check_dependency poff
else
    echo "在非交互式环境中运行，跳过依赖检查..."
    # 确保所有依赖都已安装
    if ! command -v ip &> /dev/null || ! command -v pppoeconf &> /dev/null || ! command -v pon &> /dev/null || ! command -v poff &> /dev/null
    then
        echo "错误: 缺少必要的依赖工具"
        echo "在非交互式环境中自动安装依赖包..."
        detect_os
        install_dependencies
        # 再次检查依赖
        if ! command -v ip &> /dev/null || ! command -v pppoeconf &> /dev/null || ! command -v pon &> /dev/null || ! command -v poff &> /dev/null
        then
            echo "安装依赖包失败，请手动安装"
            exit 1
        fi
    fi
fi

# 创建VLAN接口并生成虚拟WAN口
create_vlan_interface() {
    echo "===== 创建VLAN接口开始 ====="
    local physical_interface=$1
    local vlan_id=$2
    local vlan_interface="${physical_interface}.${vlan_id}"
    local virtual_wan_interface="wan-${physical_interface}-${vlan_id}"
    echo "物理接口: $physical_interface"
    echo "VLAN ID: $vlan_id"
    echo "VLAN接口: $vlan_interface"
    echo "虚拟WAN口: $virtual_wan_interface"

    # 检查并启用物理接口
    echo "检查物理接口 ${physical_interface} 状态..."
    if ! ip link show ${physical_interface} | grep -q "state UP"; then
        echo "物理接口 ${physical_interface} 当前处于DOWN状态，尝试启用..."
        ip link set dev ${physical_interface} up
        if [ $? -ne 0 ]
        then
            echo "启用物理接口失败，无法继续创建VLAN接口"
            exit 1
        fi
        echo "物理接口已启用"
    else
        echo "物理接口已处于启用状态"
    fi

    # 检查VLAN接口是否已存在
    if ip link show $vlan_interface &> /dev/null; then
        echo "VLAN接口 ${vlan_interface} 已存在，将其删除后重新创建..."
        if ! ip link delete $vlan_interface; then
            echo "删除VLAN接口失败"
            exit 1
        fi
    fi

    echo "正在创建VLAN接口 ${vlan_interface}..."
    if ! ip link add link $physical_interface name $vlan_interface type vlan id $vlan_id; then
        echo "创建VLAN接口失败"
        exit 1
    fi
    echo "VLAN接口创建成功"

    echo "启用VLAN接口..."
    if ! ip link set dev $vlan_interface up; then
        echo "启用VLAN接口失败"
        exit 1
    fi
    echo "VLAN接口已启用"
    echo "VLAN接口信息:"
    ip link show $vlan_interface

    # 检查虚拟WAN口是否已存在
    if ip link show $virtual_wan_interface &> /dev/null; then
        echo "虚拟WAN口 ${virtual_wan_interface} 已存在，将其删除后重新创建..."
        ip link delete $virtual_wan_interface
    fi

    # 创建对应的虚拟WAN口（使用macvlan设备以支持MAC地址）
    echo "正在创建虚拟WAN口 ${virtual_wan_interface}..."
    # 创建macvlan虚拟接口
    ip link add link $vlan_interface name $virtual_wan_interface type macvlan mode bridge
    if [ $? -ne 0 ];
    then
        echo "创建虚拟WAN口失败"
        exit 1
    fi
    echo "虚拟WAN口创建成功"

    # 生成并设置唯一的MAC地址
    echo "正在为虚拟WAN口生成唯一MAC地址..."
    mac_address=$(generate_unique_mac_address)
    echo "生成的MAC地址: $mac_address"
    ip link set dev $virtual_wan_interface address $mac_address
    if [ $? -ne 0 ];
    then
        echo "设置MAC地址失败"
        exit 1
    fi
    echo "虚拟WAN口MAC地址已设置: $mac_address"

    # 启用虚拟WAN口
    echo "启用虚拟WAN口..."
    ip link set dev $virtual_wan_interface up
    if [ $? -ne 0 ];
    then
        echo "启用虚拟WAN口失败"
        exit 1
    fi
    echo "虚拟WAN口已启用"
    echo "虚拟WAN口信息:"
    ip link show $virtual_wan_interface

    # 配置VLAN接口与虚拟WAN口之间的路由
    echo "配置VLAN接口与虚拟WAN口之间的路由..."
    # 添加一条路由规则，将从VLAN接口来的流量路由到虚拟WAN口
    # 为简单起见，这里使用IP表进行转发
    echo 1 > /proc/sys/net/ipv4/ip_forward
    iptables -A FORWARD -i $vlan_interface -o $virtual_wan_interface -j ACCEPT
    iptables -A FORWARD -i $virtual_wan_interface -o $vlan_interface -m state --state RELATED,ESTABLISHED -j ACCEPT
    echo "路由配置完成"
}

# 配置PPPoE连接
configure_pppoe() {
    echo "正在配置PPPoE连接..."
    
    # 确保目录存在
    mkdir -p /etc/ppp/peers
    
    # 生成pppoe配置文件
    echo "创建PPPoE配置文件 /etc/ppp/peers/$PPPOE_INTERFACE..."
    if ! cat > /etc/ppp/peers/$PPPOE_INTERFACE << EOF
plugin rp-pppoe.so
$VLAN_INTERFACE
user "$USERNAME"
password "$PASSWORD"
noauth
persist
mtu 1492
noipdefault
defaultroute
replacedefaultroute
hide-password
lcp-echo-interval 20
lcp-echo-failure 3
usepeerdns
EOF
    then
        echo "创建PPPoE配置文件失败"
        exit 1
    fi
    
    echo "PPPoE配置文件已生成"
}

# 配置静态IP连接
configure_static_ip() {
    echo "正在配置静态IP连接..."

    # 启用物理接口
    echo "启用物理接口 $PHYSICAL_INTERFACE..."
    if ! ip link set dev $PHYSICAL_INTERFACE up; then
        echo "启用物理接口失败"
        exit 1
    fi
    echo "物理接口已启用"

    # 配置静态IP地址
    echo "配置静态IP地址 $STATIC_IP/$SUBNET_MASK..."
    if ! ip addr add $STATIC_IP/$SUBNET_MASK dev $PHYSICAL_INTERFACE; then
        echo "配置静态IP地址失败"
        exit 1
    fi
    echo "静态IP地址已配置"

    # 添加默认路由
    echo "添加默认路由到 $GATEWAY..."
    if ! ip route add default via $GATEWAY dev $PHYSICAL_INTERFACE; then
        echo "添加默认路由失败"
        exit 1
    fi
    echo "默认路由已添加"

    # 配置DNS服务器
    echo "正在配置DNS服务器..."
    # 备份并修改resolv.conf
    cp -f /etc/resolv.conf /etc/resolv.conf.bak
    echo "nameserver $DNS_SERVER" > /etc/resolv.conf
    echo "DNS服务器已配置"

    echo "静态IP连接配置完成"
}

# 建立PPPoE连接
establish_connection() {
    echo "正在建立PPPoE连接..."
    if ! pon $PPPOE_INTERFACE; then
        echo "建立PPPoE连接失败"
        exit 1
    fi
    echo "PPPoE连接已启动，等待连接建立..."

    # 等待连接建立，最多等待10秒
    local max_wait=10
    local wait_count=0
    while [ $wait_count -lt $max_wait ]; do
        if ip link show $PPPOE_INTERFACE &> /dev/null; then
            echo "PPPoE连接已成功建立: $PPPOE_INTERFACE"
            # 显示连接状态
            echo "连接状态:"
            ip addr show $PPPOE_INTERFACE
            return 0
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done

    echo "PPPoE连接建立超时（${max_wait}秒）"
    exit 1
}

# 断开连接
terminate_connection() {
    if [ "$CONNECTION_TYPE" = "pppoe" ]; then
        echo "正在断开PPPoE连接..."
        if ! poff $PPPOE_INTERFACE; then
            echo "断开PPPoE连接失败"
            exit 1
        fi
        echo "PPPoE连接已断开"

        echo "正在删除VLAN接口..."
        if ! ip link delete $VLAN_INTERFACE; then
            echo "删除VLAN接口失败"
            exit 1
        fi
        echo "VLAN接口已删除"
    elif [ "$CONNECTION_TYPE" = "static" ]; then
        echo "正在清除静态IP配置..."
        
        # 删除IP地址
        if ! ip addr del $STATIC_IP/$SUBNET_MASK dev $PHYSICAL_INTERFACE; then
            echo "删除IP地址失败"
            exit 1
        fi
        echo "IP地址已删除"
        
        # 删除默认路由
        if ! ip route del default via $GATEWAY dev $PHYSICAL_INTERFACE; then
            echo "删除默认路由失败"
            exit 1
        fi
        echo "默认路由已删除"
        
        # 禁用物理接口
        if ! ip link set dev $PHYSICAL_INTERFACE down; then
            echo "禁用物理接口失败"
            exit 1
        fi
        echo "物理接口已禁用"
    fi

    # 恢复DNS配置（如果有备份）
    if [ -f /etc/resolv.conf.bak ]; then
        echo "正在恢复DNS配置..."
        mv -f /etc/resolv.conf.bak /etc/resolv.conf
        echo "DNS配置已恢复"
    fi

    echo "连接已终止"
}

# 应用配置
apply_config() {
    echo "正在应用配置..."

    # 从环境变量获取配置参数
    local connection_type="${CONNECTION_TYPE}"
    local physical_interface="${PHYSICAL_INTERFACE}"
    local vlan_id="${VLAN_ID}"
    local username="${USERNAME}"
    local password="${PASSWORD}"
    local static_ip="${STATIC_IP}"
    local subnet_mask="${SUBNET_MASK}"
    local gateway="${GATEWAY}"
    local dns_server="${DNS_SERVER}"

    # 检查必要的配置参数
    if [ -z "$connection_type" ] || [ -z "$physical_interface" ] || [ -z "$vlan_id" ]; then
        echo "错误: 配置参数不完整"
        echo "需要的环境变量: CONNECTION_TYPE, PHYSICAL_INTERFACE, VLAN_ID"
        exit 1
    fi

    if [ "$connection_type" = "pppoe" ] && ([ -z "$username" ] || [ -z "$password" ]); then
        echo "错误: PPPoE配置参数不完整"
        echo "需要的环境变量: USERNAME, PASSWORD"
        exit 1
    fi

    if [ "$connection_type" = "static" ] && ([ -z "$static_ip" ] || [ -z "$subnet_mask" ] || [ -z "$gateway" ] || [ -z "$dns_server" ]); then
        echo "错误: 静态IP配置参数不完整"
        echo "需要的环境变量: STATIC_IP, SUBNET_MASK, GATEWAY, DNS_SERVER"
        echo "当前值:"
        echo "STATIC_IP: $static_ip"
        echo "SUBNET_MASK: $subnet_mask"
        echo "GATEWAY: $gateway"
        echo "DNS_SERVER: $dns_server"
        exit 1
    fi

    # 检查VLAN ID是否有效
    if ! [[ $vlan_id =~ ^[0-9]+$ ]] || [ $vlan_id -lt 1 ] || [ $vlan_id -gt 4094 ]; then
        echo "错误: 无效的VLAN ID，必须是1-4094之间的数字"
        exit 1
    fi

    # 检查物理接口是否存在
    if ! ip link show $physical_interface &> /dev/null; then
        echo "错误: 物理接口 $physical_interface 不存在"
        exit 1
    fi

    # 保存配置
    echo "正在保存配置..."
    cat > "$CONFIG_FILE" << EOF
# VLAN拨号程序配置文件
PHYSICAL_INTERFACE="$physical_interface"  # 物理网卡接口
VLAN_ID=$vlan_id                           # VLAN ID
USERNAME="$username"                       # 拨号用户名
PASSWORD="$password"                       # 拨号密码
CONNECTION_TYPE="$connection_type"         # 连接类型 (pppoe/static)
STATIC_IP="$static_ip"                     # 静态IP地址
SUBNET_MASK="$subnet_mask"                 # 子网掩码
GATEWAY="$gateway"                         # 默认网关
DNS_SERVER="$dns_server"                   # DNS服务器
EOF

    if [ $? -ne 0 ]; then
        echo "保存配置失败"
        exit 1
    fi

    echo "配置保存成功"

    # 应用配置
    if [ "$connection_type" = "pppoe" ]; then
        echo "应用PPPoE配置..."
        # 停止当前连接（如果有）
        if [ -f "$CONFIG_FILE" ]; then
            echo "停止当前连接..."
            source "$CONFIG_FILE"
            if [ ! -z "$VLAN_INTERFACE" ]; then
                delete_vlan_interface "$VLAN_INTERFACE"
            fi
            if [ ! -z "$PPPOE_INTERFACE" ]; then
                poff "$PPPOE_INTERFACE" 2> /dev/null
            fi
        fi

        # 创建VLAN接口
        create_vlan_interface "$physical_interface" "$vlan_id"

        # 配置PPPoE
        VLAN_INTERFACE="${physical_interface}.${vlan_id}"
        PPPOE_INTERFACE="ppp0"
        configure_pppoe

        # 建立连接
        establish_connection
    elif [ "$connection_type" = "static" ]; then
        echo "应用静态IP配置..."
        # 停止当前连接（如果有）
        if [ -f "$CONFIG_FILE" ]; then
            echo "停止当前连接..."
            source "$CONFIG_FILE"
            if [ ! -z "$VLAN_INTERFACE" ]; then
                delete_vlan_interface "$VLAN_INTERFACE"
            fi
        fi

        # 创建VLAN接口
        create_vlan_interface "$physical_interface" "$vlan_id"

        # 配置静态IP
        VLAN_INTERFACE="${physical_interface}.${vlan_id}"
        configure_static_ip

        # 建立连接
        echo "静态IP连接已建立"
        ifconfig $VLAN_INTERFACE
    else
        echo "错误: 不支持的连接类型: $connection_type"
        exit 1
    fi

    echo "配置应用成功"
}

# 配置静态IP
configure_static_ip() {
    echo "正在配置静态IP..."
    local vlan_interface="${VLAN_INTERFACE}"
    local static_ip="${STATIC_IP}"
    local subnet_mask="${SUBNET_MASK}"
    local gateway="${GATEWAY}"
    local dns_server="${DNS_SERVER}"
    # 获取物理接口和VLAN ID
    local physical_interface="${PHYSICAL_INTERFACE}"
    local vlan_id="${VLAN_ID}"
    # 虚拟WAN口名称
    local virtual_wan_interface="wan-${physical_interface}-${vlan_id}"

    # 确保VLAN接口和虚拟WAN口已启用
    ip link set dev $vlan_interface up
    if [ $? -ne 0 ]; then
        echo "启用VLAN接口失败"
        exit 1
    fi
    echo "VLAN接口已启用"

    ip link set dev $virtual_wan_interface up
    if [ $? -ne 0 ]; then
        echo "启用虚拟WAN口失败"
        exit 1
    fi
    echo "虚拟WAN口已启用"

    # 配置静态IP地址到虚拟WAN口
    ip addr add $static_ip/$subnet_mask dev $virtual_wan_interface
    if [ $? -ne 0 ]; then
        echo "配置静态IP地址失败"
        exit 1
    fi
    echo "静态IP地址已配置到虚拟WAN口: $static_ip/$subnet_mask"

    # 配置策略路由而不是替换默认路由
    echo "配置策略路由..."
    # 为每个VLAN创建唯一的路由表ID（基于VLAN ID）
    table_id=$((1000 + $vlan_id))
    
    # 直接添加默认路由到指定表（无需修改rt_tables文件）
    ip route add default via $gateway dev $virtual_wan_interface table $table_id
    if [ $? -ne 0 ]
    then
        echo "添加默认路由到路由表失败"
        exit 1
    fi
    
    # 添加策略路由规则，基于源IP地址
    ip rule add from $static_ip table $table_id
    if [ $? -ne 0 ]
    then
        echo "添加策略路由规则失败"
        exit 1
    fi
    echo "策略路由已配置: via $gateway dev $virtual_wan_interface table $table_id"

    # 配置DNS服务器
    echo "正在配置DNS服务器..."
    if [ -f /etc/resolv.conf ]; then
        # 备份当前DNS配置
        cp /etc/resolv.conf /etc/resolv.conf.bak
        echo "DNS配置已备份"
    fi

    # 写入新的DNS配置
    cat > /etc/resolv.conf << EOF
nameserver $dns_server
EOF

    if [ $? -ne 0 ]; then
        echo "配置DNS服务器失败"
        exit 1
    fi
    echo "DNS服务器已配置: $dns_server"

    echo "静态IP配置完成"
}

# 主函数
main() {
    # 首先检查是否以root用户运行
    if [ $UID -ne 0 ]; then
        echo "错误: 需要以root用户运行此脚本"
        exit 1
    fi

    # 检测操作系统
    if ! detect_os; then
        echo "错误: 不支持的操作系统"
        exit 1
    fi

    # 检查依赖
    check_dependency ip
    check_dependency iptables
    check_dependency grep
    check_dependency awk
    check_dependency sed
    check_dependency openssl  # 用于生成MAC地址

    # 获取命令和所有参数
    local command=$1
    local param1=$2
    local param2=$3

    case "$command" in
        start)
            echo "启动VLAN拨号程序..."
            if ! load_config; then
                echo "配置加载失败，请先运行 'configure' 命令"
                exit 1
            fi
            
            if [ "$CONNECTION_TYPE" = "pppoe" ]; then
                create_vlan_interface "$PHYSICAL_INTERFACE" "$VLAN_ID"
                VLAN_INTERFACE="${PHYSICAL_INTERFACE}.${VLAN_ID}"
                configure_pppoe
                establish_connection
            elif [ "$CONNECTION_TYPE" = "static" ]; then
                # 创建VLAN接口
                create_vlan_interface "$PHYSICAL_INTERFACE" "$VLAN_ID"
                VLAN_INTERFACE="${PHYSICAL_INTERFACE}.${VLAN_ID}"
                configure_static_ip
            else
                echo "错误: 不支持的连接类型: $CONNECTION_TYPE"
                exit 1
            fi
            ;;
        stop)
            echo "停止VLAN拨号程序..."
            if ! load_config; then
                echo "配置加载失败，请先运行 'configure' 命令"
                exit 1
            fi
            terminate_connection
            ;;
        restart)
            echo "重启VLAN拨号程序..."
            if ! load_config; then
                echo "配置加载失败，请先运行 'configure' 命令"
                exit 1
            fi
            if ! terminate_connection; then
                echo "警告: 停止拨号程序失败，尝试强制启动..."
            fi
            sleep 2
            create_vlan_interface "$PHYSICAL_INTERFACE" "$VLAN_ID"
            VLAN_INTERFACE="${PHYSICAL_INTERFACE}.${VLAN_ID}"
            configure_pppoe
            establish_connection
            ;;
        status)
            echo "查看VLAN拨号程序状态..."
            if ! load_config; then
                echo "配置加载失败，请先运行 'configure' 命令"
                exit 1
            fi
            
            if [ "$CONNECTION_TYPE" = "pppoe" ]; then
                if ip link show ppp0 &> /dev/null; then
                    echo "PPPoE连接已建立"
                    ip addr show ppp0
                else
                    echo "PPPoE连接未建立"
                fi
            elif [ "$CONNECTION_TYPE" = "static" ]; then
                if ip addr show $PHYSICAL_INTERFACE | grep -q $STATIC_IP; then
                    echo "静态IP连接已配置"
                    echo "物理接口: $PHYSICAL_INTERFACE"
                    echo "IP地址: $STATIC_IP/$SUBNET_MASK"
                    echo "网关: $GATEWAY"
                    echo "DNS服务器: $DNS_SERVER"
                    ip addr show $PHYSICAL_INTERFACE
                    ip route show
                else
                    echo "静态IP连接未配置"
                fi
            else
                echo "错误: 不支持的连接类型: $CONNECTION_TYPE"
            fi
            ;;
        configure)
            echo "配置VLAN拨号程序..."
            configure
            ;;
        apply_config)
            echo "应用配置..."
            apply_config
            ;;
        add_vlan)
            # 尝试从环境变量获取参数
            local physical_interface="${PHYSICAL_INTERFACE:-$param1}"
            local vlan_id="${VLAN_ID:-$param2}"

            # 检查是否提供了物理接口和VLAN ID
            if [ -z "$physical_interface" ] || [ -z "$vlan_id" ]
            then
                echo "用法: $0 add_vlan <物理接口> <VLAN ID> 或 设置PHYSICAL_INTERFACE和VLAN_ID环境变量"
                echo "例如: $0 add_vlan ens2 100 或 PHYSICAL_INTERFACE=ens2 VLAN_ID=100 $0 add_vlan"
                exit 1
            fi
            # 检查物理接口是否存在
            if ! ip link show $physical_interface &> /dev/null;
            then
                echo "错误: 物理接口 $physical_interface 不存在"
                exit 1
            fi
            # 检查VLAN ID是否有效
            if ! [[ $vlan_id =~ ^[0-9]+$ ]] || [ $vlan_id -lt 1 ] || [ $vlan_id -gt 4094 ];
            then
                echo "错误: 无效的VLAN ID，必须是1-4094之间的数字"
                exit 1
            fi
            echo "添加VLAN接口 $physical_interface.$vlan_id..."
            create_vlan_interface "$physical_interface" "$vlan_id"
            ;;
        help)
            echo "VLAN拨号程序使用帮助"
            echo "-------------------"
            echo "用法: $0 {start|stop|restart|status|configure|apply_config|add_vlan|help}"
            echo ""
            echo "命令说明:"
            echo "  start       - 启动VLAN拨号程序"
            echo "  stop        - 停止VLAN拨号程序"
            echo "  restart     - 重启VLAN拨号程序"
            echo "  status      - 查看VLAN拨号程序状态"
            echo "  configure   - 配置VLAN拨号程序"
            echo "  apply_config- 应用配置"
            echo "  add_vlan    - 添加VLAN接口 (用法: $0 add_vlan <物理接口> <VLAN ID>)"
            echo "  help        - 显示此帮助信息"
            echo ""
            echo "示例:"
            echo "  $0 start          # 启动拨号程序"
            echo "  $0 add_vlan eth0 100  # 添加VLAN 100到eth0"
            ;;
        *)
            echo "错误: 无效的命令 '$command'"
            echo "用法: $0 {start|stop|restart|status|configure|apply_config|add_vlan|help}"
            echo "使用 '$0 help' 查看详细帮助"
            exit 1
            ;;
    esac
}            
            exit 1
            fi
            create_vlan_interface $physical_interface $vlan_id
            ;;
        delete_vlan)
            echo "参数数量: $#"
            echo "参数1: $1"
            echo "参数2: $2"
            echo "参数3: $3"
            
            # 尝试从环境变量获取参数
            local physical_interface="${PHYSICAL_INTERFACE:-$2}"
            local vlan_id="${VLAN_ID:-$3}"
            
            # 检查是否提供了物理接口和VLAN ID
            if [ -z "$physical_interface" ] || [ -z "$vlan_id" ]
            then
                echo "用法: $0 delete_vlan <物理接口> <VLAN ID> 或 设置PHYSICAL_INTERFACE和VLAN_ID环境变量"
                echo "例如: $0 delete_vlan ens2 100 或 PHYSICAL_INTERFACE=ens2 VLAN_ID=100 $0 delete_vlan"
                exit 1
            fi
            # 构建VLAN接口名称
            local vlan_interface="${physical_interface}.${vlan_id}"
            echo "要删除的VLAN接口: $vlan_interface"
            delete_vlan_interface $vlan_interface
            ;;
        configure_load_balance)
            # 配置虚拟WAN口流量均衡
            configure_load_balance $param
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status|configure|add_vlan|delete_vlan|configure_load_balance|apply_config}"
            echo "  start     - 启动VLAN接口并建立PPPoE连接"
            echo "  stop      - 断开PPPoE连接并删除VLAN接口"
            echo "  restart   - 重启PPPoE连接和VLAN接口"
            echo "  status    - 查看PPPoE连接状态"
            echo "  configure - 运行配置向导"
            echo "  add_vlan  - 创建VLAN接口"
            echo "  delete_vlan - 删除VLAN接口"
            echo "  configure_load_balance - 配置虚拟WAN口流量均衡"
            echo "  apply_config - 应用配置"
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"