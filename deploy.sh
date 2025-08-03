#!/bin/bash

# VLAN拨号程序一键部署脚本
# 版本: 1.0.0
# 日期: $(date +'%Y-%m-%d')

# 配置参数
PROJECT_DIR="/root/test"
WEB_DIR="$PROJECT_DIR/web"
SERVER_SCRIPT="$WEB_DIR/server.js"
VLAN_SCRIPT="$PROJECT_DIR/vlan_dialer.sh"
CONFIG_FILE="$PROJECT_DIR/new_config.conf"
PACKAGE_FILE="$WEB_DIR/package.json"
SERVICE_NAME="vlan-dialer"
PORT=3000

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 检查是否以root用户运行
if [ "$EUID" -ne 0 ]
  then echo -e "${RED}请以root用户运行此脚本${NC}"
  exit 1
fi

# 显示欢迎信息
clear
cat << "EOF"
${BLUE}
   __     ______     ______   ______     __    __     ______     __  __
  /\ \   /\  ___\   /\__  _\ /\  ___\   /\ "-./  \   /\  ___\   /\ \/\ \
  \ \ \  \ \  __\   \/_/  \/ \ \  __\   \ \ \-./\ \  \ \  __\   \ \ \/ /
   \ \_\  \ \_____\    /\_\  \ \_____\  \ \_\ \ \_\  \ \_____\  \ \__/
    \/_/   \/_____/    \/_/   \/_____/   \/_/  \/_/   \/_____/   \/_/

${NC}欢迎使用VLAN拨号程序一键部署脚本

EOF

# 检查网络连接
echo -e "${YELLOW}正在检查网络连接...${NC}"
if ping -c 1 www.baidu.com > /dev/null 2>&1;
 then
  echo -e "${GREEN}网络连接正常${NC}"
 else
  echo -e "${RED}网络连接失败，请检查网络后重试${NC}"
  exit 1
fi

# 更新系统包
echo -e "${YELLOW}正在更新系统包...${NC}"
apt update -y && apt upgrade -y
if [ $? -ne 0 ];
 then
  echo -e "${RED}系统包更新失败${NC}"
  exit 1
fi

# 安装Node.js和npm
echo -e "${YELLOW}正在安装Node.js和npm...${NC}"
apt install nodejs npm -y
if [ $? -ne 0 ];
 then
  echo -e "${RED}Node.js和npm安装失败${NC}"
  exit 1
fi

# 验证Node.js和npm安装
node -v
npm -v
if [ $? -ne 0 ];
 then
  echo -e "${RED}Node.js或npm验证失败${NC}"
  exit 1
fi

# 安装项目依赖
echo -e "${YELLOW}正在安装项目依赖...${NC}"
cd $WEB_DIR
npm install
if [ $? -ne 0 ];
 then
  echo -e "${RED}项目依赖安装失败${NC}"
  exit 1
fi

# 配置VLAN拨号脚本权限
echo -e "${YELLOW}正在配置VLAN拨号脚本权限...${NC}"
chmod +x $VLAN_SCRIPT
if [ $? -ne 0 ];
 then
  echo -e "${RED}VLAN拨号脚本权限配置失败${NC}"
  exit 1
fi

# 创建系统服务
echo -e "${YELLOW}正在创建系统服务...${NC}"
cat > /etc/systemd/system/$SERVICE_NAME.service << EOF
[Unit]
Description=VLAN Dialer Service
After=network.target

[Service]
ExecStart=/usr/bin/node $SERVER_SCRIPT
WorkingDirectory=$WEB_DIR
Restart=always
RestartSec=5
User=root
Group=root
Environment=PATH=/usr/bin:/usr/local/bin

[Install]
WantedBy=multi-user.target
EOF

# 重新加载systemd配置
systemctl daemon-reload

# 启动服务并设置开机自启
echo -e "${YELLOW}正在启动服务并设置开机自启...${NC}"
systemctl start $SERVICE_NAME
systemctl enable $SERVICE_NAME

# 检查服务状态
echo -e "${YELLOW}正在检查服务状态...${NC}"
if systemctl is-active --quiet $SERVICE_NAME;
 then
  echo -e "${GREEN}服务启动成功${NC}"
 else
  echo -e "${RED}服务启动失败，请使用 'systemctl status $SERVICE_NAME' 查看详细信息${NC}"
  exit 1
fi

# 配置防火墙
echo -e "${YELLOW}正在配置防火墙...${NC}"
if command -v ufw &> /dev/null;
 then
  ufw allow $PORT/tcp
  ufw reload
  echo -e "${GREEN}防火墙配置完成，已开放$PORT端口${NC}"
 else
  echo -e "${YELLOW}未找到ufw防火墙，跳过防火墙配置${NC}"
fi

# 安装完成提示
clear
cat << "EOF"
${GREEN}
  _   _   _   _   _   _   _   _   _   _   _
 / \ / \ / \ / \ / \ / \ / \ / \ / \ / \ / \
( V | L | A | N | 拨 | 号 | 程 | 序 | 安 | 装 )
 \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/

${NC}恭喜！VLAN拨号程序安装成功！

服务已启动，配置已完成。
您可以通过以下地址访问Web界面：
${BLUE}http://<服务器IP>:$PORT${NC}

请确保您的服务器安全组已开放$PORT端口。

EOF

echo -e "${YELLOW}部署脚本执行完成！${NC}"