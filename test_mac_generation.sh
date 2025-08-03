#!/bin/bash

# 测试虚拟网卡MAC地址自动生成功能

# 确保脚本以root权限运行
if [ "$EUID" -ne 0 ]
  then echo "请以root权限运行此脚本"
  exit 1
fi

# 定义测试参数
PHYSICAL_INTERFACE="ens2"
VLAN_ID="105"

# 输出测试信息
echo "===== 开始测试虚拟网卡MAC地址自动生成功能 ======"
echo "物理接口: $PHYSICAL_INTERFACE"
echo "VLAN ID: $VLAN_ID"

# 删除已有的VLAN（如果存在）
echo "删除已有的VLAN（如果存在）..."
VLAN_INTERFACE="${PHYSICAL_INTERFACE}.${VLAN_ID}"
VIRTUAL_WAN_INTERFACE="wan-${PHYSICAL_INTERFACE}-${VLAN_ID}"

# 检查并删除VLAN接口
if ip link show $VLAN_INTERFACE &> /dev/null; then
    ip link delete $VLAN_INTERFACE
    echo "已删除VLAN接口: $VLAN_INTERFACE"
fi

# 检查并删除虚拟WAN口
if ip link show $VIRTUAL_WAN_INTERFACE &> /dev/null; then
    ip link delete $VIRTUAL_WAN_INTERFACE
    echo "已删除虚拟WAN口: $VIRTUAL_WAN_INTERFACE"
fi

# 清除已使用的MAC地址记录（用于测试）
rm -f /tmp/used_mac_addresses.txt

echo "创建新的VLAN..."
# 调用vlan_dialer.sh添加VLAN
PHYSICAL_INTERFACE=$PHYSICAL_INTERFACE VLAN_ID=$VLAN_ID /root/test/vlan_dialer.sh add_vlan

# 检查虚拟WAN口是否创建成功
if ip link show $VIRTUAL_WAN_INTERFACE &> /dev/null; then
    echo "虚拟WAN口创建成功: $VIRTUAL_WAN_INTERFACE"
    # 获取虚拟WAN口的MAC地址
    MAC_ADDRESS=$(ip link show $VIRTUAL_WAN_INTERFACE | grep -oP 'ether \K([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
    echo "虚拟WAN口MAC地址: $MAC_ADDRESS"
    # 检查MAC地址是否在已使用列表中
    if grep -q "^$MAC_ADDRESS$" /tmp/used_mac_addresses.txt; then
        echo "MAC地址已正确记录在已使用列表中"
    else
        echo "警告: MAC地址未记录在已使用列表中"
    fi
else
    echo "虚拟WAN口创建失败"
    exit 1
fi

# 创建第二个VLAN，测试MAC地址是否不同
VLAN_ID="106"
VLAN_INTERFACE="${PHYSICAL_INTERFACE}.${VLAN_ID}"
VIRTUAL_WAN_INTERFACE="wan-${PHYSICAL_INTERFACE}-${VLAN_ID}"

echo "\n创建第二个VLAN..."
PHYSICAL_INTERFACE=$PHYSICAL_INTERFACE VLAN_ID=$VLAN_ID /root/test/vlan_dialer.sh add_vlan

if ip link show $VIRTUAL_WAN_INTERFACE &> /dev/null; then
    echo "第二个虚拟WAN口创建成功: $VIRTUAL_WAN_INTERFACE"
    MAC_ADDRESS2=$(ip link show $VIRTUAL_WAN_INTERFACE | grep -oP 'ether \K([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
    echo "第二个虚拟WAN口MAC地址: $MAC_ADDRESS2"
    # 检查两个MAC地址是否不同
    if [ "$MAC_ADDRESS" != "$MAC_ADDRESS2" ]; then
        echo "测试通过: 两个虚拟WAN口的MAC地址不同"
    else
        echo "测试失败: 两个虚拟WAN口的MAC地址相同"
    fi
else
    echo "第二个虚拟WAN口创建失败"
    exit 1
fi

echo "\n===== 测试完成 ======"