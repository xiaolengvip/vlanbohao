# VLAN拨号程序使用说明

## 一、程序简介

VLAN拨号程序是一个用于管理和监控虚拟WAN口的工具，它可以帮助用户轻松配置VLAN接口、监控网络流量，并提供Web界面进行管理。该程序支持PPPoE拨号和静态IP配置，适用于需要多线路网络接入的场景。

## 二、系统要求

- 操作系统：Ubuntu 18.04及以上版本
- Node.js：v12.0.0及以上版本
- npm：v6.0.0及以上版本
- 网络接口：至少一个物理网络接口
- 权限：需要root权限运行

## 三、安装步骤

1. **下载程序**
   将程序文件复制到服务器的`/root/test`目录下。

2. **运行一键部署脚本**
   ```bash
   cd /root/test
   chmod +x deploy.sh
   ./deploy.sh
   ```
   脚本将自动完成以下操作：
   - 检查并更新系统包
   - 安装Node.js和npm
   - 安装项目依赖
   - 配置VLAN拨号脚本权限
   - 创建并启动系统服务
   - 配置防火墙（如ufw存在）

3. **验证安装**
   安装完成后，可以通过访问`http://<服务器IP>:3000`来验证程序是否正常运行。

## 四、使用方法

### 1. 启动服务
   ```bash
   systemctl start vlan-dialer
   ```

### 2. 停止服务
   ```bash
   systemctl stop vlan-dialer
   ```

### 3. 重启服务
   ```bash
   systemctl restart vlan-dialer
   ```

### 4. 查看服务状态
   ```bash
   systemctl status vlan-dialer
   ```

### 5. 配置开机自启
   ```bash
   systemctl enable vlan-dialer
   ```

## 五、Web界面功能介绍

### 1. 网络接口管理
   - 查看所有网络接口
   - 识别物理接口和虚拟接口

### 2. VLAN配置
   - 添加新的VLAN接口
   - 删除已有的VLAN接口
   - 查看当前VLAN列表

### 3. 网络配置
   - PPPoE拨号配置
   - 静态IP配置
   - 保存和删除配置

### 4. 流量监控
   - 实时监控虚拟WAN口流量
   - 查看历史流量统计

## 六、API接口说明

### 1. 获取网络接口
   - URL: `/api/interfaces`
   - 方法: `GET`
   - 描述: 获取所有网络接口信息
   - 返回: `{ success: true, interfaces: [], physicalInterfaces: [], cached: boolean }`

### 2. 获取VLAN列表
   - URL: `/api/vlans`
   - 方法: `GET`
   - 描述: 获取已创建的VLAN接口列表
   - 返回: `{ success: true, vlans: [] }`

### 3. 添加VLAN
   - URL: `/api/vlans`
   - 方法: `POST`
   - 描述: 添加新的VLAN接口
   - 参数: `{ physicalInterface: string, vlanId: number }`
   - 返回: `{ success: boolean, message: string, output: string }`

### 4. 删除VLAN
   - URL: `/api/vlans/:physicalInterface/:vlanId`
   - 方法: `DELETE`
   - 描述: 删除指定的VLAN接口
   - 参数: `physicalInterface` (路径参数), `vlanId` (路径参数)
   - 返回: `{ success: boolean, message: string, output: string }`

### 5. 获取WAN口流量数据
   - URL: `/api/wan-stats`
   - 方法: `GET`
   - 描述: 获取虚拟WAN口的流量统计数据
   - 返回: `{ success: true, stats: [], cached: boolean }`

### 6. 启动/停止监控
   - URL: `/api/monitoring/start` 或 `/api/monitoring/stop`
   - 方法: `POST`
   - 描述: 启动或停止后台流量监控
   - 返回: `{ success: true, message: string }`

### 7. 获取/保存/删除配置
   - URL: `/api/config`
   - 方法: `GET` (获取), `POST` (保存), `DELETE` (删除)
   - 描述: 管理配置信息
   - 返回: 取决于具体方法

## 七、常见问题解答

1. **Q: 如何修改服务监听端口？**
   A: 编辑`/root/test/web/server.js`文件，修改`PORT`常量的值，然后重启服务。

2. **Q: 如何查看详细日志？**
   A: 使用命令`journalctl -u vlan-dialer -f`查看服务实时日志。

3. **Q: 配置文件保存在哪里？**
   A: 配置文件保存在`/root/test/new_config.conf`。

4. **Q: 为什么无法访问Web界面？**
   A: 请检查服务器防火墙是否开放了3000端口，以及服务是否正常运行。

## 八、故障排除

1. **服务启动失败**
   - 检查Node.js是否安装正确
   - 检查项目依赖是否安装完整
   - 查看服务日志获取详细错误信息

2. **无法获取流量数据**
   - 检查VLAN接口是否正确创建
   - 确保物理网络接口正常工作
   - 检查系统是否有`ip`命令工具

3. **Web界面响应缓慢**
   - 检查服务器资源使用情况
   - 检查网络连接是否稳定

## 九、联系我们

如果您在使用过程中遇到任何问题，请联系技术支持。

版本: 1.0.0
更新日期: $(date +'%Y-%m-%d')