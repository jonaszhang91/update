# One_Dragon_Go - Ubuntu POS 运维一体化脚本

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash%2FSh-green.svg)]()

> ubuntu 系统软件使用的运维脚本 集成多版本的升级包和部分常用补丁（持续更新）




---

## ✨ 功能总览

| 主菜单项 | 子功能 | 说明 |
|---------|--------|------|
| **1. 升级** | 1.1 ~ 1.5 | 自动下载并执行对应 POS 版本升级脚本 |
| **2. 打补丁** | 2.1 / 2.2 | 安装 16.6 fast18 补丁 / 执行 SQL （166-167） 修复 |
| **3. 网络设置** | 3.1 ~ 3.4 | 静态 IP 追加、DHCP 重置、刷卡机/打印机扫描对比 |

---

### 安装与运行
- 执行以下命令

    cd ~ && rm -f /home/menu/One_Dragon_Go.sh&& wget https://github.com/jonaszhang91/update/raw/refs/heads/main/One_Dragon_Go.sh&& sudo bash /home/menu/One_Dragon_Go.sh


---
### 菜单

#### 一级菜单

1. 升级 (Fast0直接跑升级包)
2. 打补丁 
3. 网络设置
0. 退出

#### 二级菜单

- 1.1 升级 16.6 fast0
- 1.2 升级 16.7.1 fast0
- 1.3 升级 16.7.2 fast0
- 1.4 升级 30.13 （J1900 最高版本）
- 1.5 升级 30.14.9 （旧ui 最高版本）
- 2.1 16.6 fast18 补丁
- 2.2 166升级167_27more修复 
- 3.1 添加静态IP（追加模式）
- 3.2 重置网络（清除手动网段）
- 3.3 扫描刷卡机（端口10009设备和软件设置对比）
- 3.4 扫描打印机（端口9100设备和软件设置对比）