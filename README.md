# Nezha Agent 一键安装脚本

Nezha Agent (哪吒探针) 一键安装脚本，支持自动检测系统架构，交互式配置，加固安全设置。

## 功能特性

- ✅ 自动检测系统架构（amd64/arm64/armv7）
- ✅ 交互式输入服务端地址、客户端密钥和 TLS 设置
- ✅ 自动备份原有配置文件
- ✅ 加固配置（禁用命令执行、禁用 NAT、禁用自动更新等）
- ✅ 安装并启动 systemd 服务
- ✅ 完整的彩色日志输出

## 使用方法

### 方式一：一键命令安装（推荐）

通过环境变量传递敏感信息，脚本本身不包含任何敏感配置：

```bash
NZ_SERVER="your-server.example.com:5555" NZ_CLIENT_SECRET="your-secret-key" NZ_TLS="true" curl -fsSL https://raw.githubusercontent.com/w243420707/nezha-agent-install/main/install_nezha_agent.sh | bash
```

### 方式二：手动下载执行

```bash
# 下载脚本
curl -O https://raw.githubusercontent.com/w243420707/nezha-agent-install/main/install_nezha_agent.sh

# 赋予执行权限
chmod +x install_nezha_agent.sh

# 设置环境变量运行
NZ_SERVER="your-server:5555" NZ_CLIENT_SECRET="your-secret" NZ_TLS="true" ./install_nezha_agent.sh
```

### 环境变量参数

| 变量名 | 必填 | 默认值 | 说明 |
|--------|------|--------|------|
| `NZ_SERVER` | **是** | 无 | Nezha 服务端地址（如: `server.example.com:5555`） |
| `NZ_CLIENT_SECRET` | **是** | 无 | 客户端密钥 |
| `NZ_TLS` | 否 | `true` | 是否启用 TLS |
| `AGENT_VERSION` | 否 | `v2.2.3` | Agent 版本 |
| `APT_LOCK_TIMEOUT` | 否 | `300` | apt/dpkg 锁等待秒数 |

## 加固配置

脚本默认启用以下安全加固选项：

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `disable_command_execute` | `true` | 禁用远程命令执行 |
| `disable_nat` | `true` | 禁用 NAT 穿透 |
| `disable_auto_update` | `true` | 禁用自动更新 |
| `disable_force_update` | `true` | 禁用强制更新 |

## 安装信息

- **安装路径**: `/opt/nezha-agent/`
- **配置文件**: `/opt/nezha-agent/config.yml`
- **配置权限**: `600`（仅 root 可读）

## 服务管理

```bash
# 查看服务状态
systemctl status nezha-agent

# 重启服务
systemctl restart nezha-agent

# 停止服务
systemctl stop nezha-agent

# 设置开机自启
systemctl enable nezha-agent
```

## 支持架构

- `amd64` (x86_64)
- `arm64` (aarch64)
- `armv7` (armv7l)

## 更新日志

### 2026-07-25

- 增加 apt/dpkg 锁等待能力，遇到 `unattended-upgr` 等系统自动更新占用锁时会等待释放后继续安装依赖。
- 增强 Debian/Ubuntu 依赖安装自愈能力：当 `apt-get update` 发现没有 Release 文件的失效软件源时，自动备份并禁用对应 `.list` / `.sources` 源后重试更新。
- 修复 Debian/Ubuntu 系统中失效 apt 软件源导致依赖安装中断的问题。现在 `apt-get update` 失败时会提示警告，并继续尝试安装缺少的依赖。

## 许可证

MIT License
