# Windows 下 cocotb + Icarus Verilog 仿真环境安装手册

> 整理自 2026-09-04 在 Win11 上的实际安装过程（含全部踩坑记录）。
> 目标：在新 Windows 电脑上快速搭建可用的 cocotb Python 仿真验证环境。

---

## 0. 最终架构（先看结论）

| 组件 | 来源 | 说明 |
|------|------|------|
| Python 3.14 + **cocotb** + GNU make | conda 环境 `rtl` | conda 只负责 Python 侧 |
| **Icarus Verilog 14** (iverilog/vvp) + yosys + gtkwave | OSS CAD Suite（绿色免安装） | 仿真器必须用它，**不要用 conda 的 iverilog**（见坑 ①） |

一句话原理：cocotb 是 Python 库（pip 安装），但它必须挂在一个 Verilog 仿真器上跑；
Windows 上最可靠的仿真器来源是 YosysHQ 的 OSS CAD Suite。

---

## 1. 前置条件

- Miniconda/Anaconda 已安装（`C:\Users\<你>\miniconda3`）
- Git Bash（本文命令均在 Git Bash 下执行；CMD 等价命令见激活脚本）
- 磁盘空间：约 4 GB（压缩包 600MB + 解压后 3GB，装完可删压缩包）
- （仅网络受限时需要）可用的代理，见坑 ⑦

---

## 2. 安装步骤

### Step 1 — 创建 conda 环境（只装 Python 侧）

```bash
CONDA=/c/Users/<你>/miniconda3/Scripts/conda.exe

# 注意 --override-channels -c conda-forge：绕过 Anaconda 默认通道的 ToS 门槛（坑 ②）
$CONDA create -n rtl --override-channels -c conda-forge -y python pip make

# 安装 cocotb（conda-forge 没有 win-64 的 cocotb 包，坑 ③，必须 pip）
/c/Users/<你>/miniconda3/envs/rtl/python.exe -m pip install cocotb
```

验证：

```bash
/c/Users/<你>/miniconda3/envs/rtl/python.exe -c "import cocotb; print(cocotb.__version__)"
# 期望输出: 2.1.0（或更新）
```

### Step 2 — 下载并解压 OSS CAD Suite

最新版发布页：`https://github.com/YosysHQ/oss-cad-suite-build/releases`

选 `oss-cad-suite-windows-x64-<日期>.tgz`。**不要**下载任何 `.exe` 安装器（那是别的平台/格式的）。

```bash
mkdir -p /k/AI_Coding/tools && cd /k/AI_Coding/tools

# 直连下载（网络通畅时）
curl -L -o oss-cad-suite-windows-x64.tgz "<复制上面的下载链接>"

# 网络不通时走镜像（坑 ⑦：release-assets.githubusercontent.com 常被墙，且走代理也未必通）
curl -L -C - -o oss-cad-suite-windows-x64.tgz "https://ghfast.top/<完整github下载链接>"

# 解压（用 Windows 自带 tar，兼容性最好），完成后删压缩包省空间
/c/Windows/System32/tar.exe -xzf oss-cad-suite-windows-x64.tgz && rm oss-cad-suite-windows-x64.tgz
```

解压后得到 `oss-cad-suite/`，内有 `bin/`（iverilog.exe、vvp.exe、gtkwave.exe…）、`lib/`、`environment.bat` 等。

### Step 3 — 创建激活脚本（关键！不要手动拼 PATH，见坑 ④⑤）

保存为 `K:\AI_Coding\tools\activate_rtl_env.sh`（路径按自己机器调整）：

```bash
# RTL 仿真验证环境一键激活（Git Bash 用法: source activate_rtl_env.sh）
OSS="/k/AI_Coding/tools/oss-cad-suite"
RTL="/c/Users/<你>/miniconda3/envs/rtl"

# 注意顺序: oss-cad 的 bin/lib 必须在 conda Library/bin 之前，
# 否则 conda 的 DLL 会遮蔽 oss-cad 的导致工具启动失败(exit 127)
export PATH="$OSS/bin:$OSS/lib:$RTL:$RTL/Scripts:$RTL/Library/bin:$PATH"

# Icarus Verilog 子系统(ivl/ivlpp)目录
export IVL_HOME="$OSS/lib/ivl"

# 提示: 用 "python" (conda rtl env, 含 cocotb)。
# "python3" 会解析到 oss-cad 自带的 3.11 (不含 cocotb)，避免使用。
```

CMD 版 `activate_rtl_env.bat`：

```bat
@echo off
set OSS=K:\AI_Coding\tools\oss-cad-suite
set RTL=C:\Users\<你>\miniconda3\envs\rtl
set PATH=%OSS%\bin;%OSS%\lib;%RTL%;%RTL%\Scripts;%RTL%\Library\bin;%PATH%
set IVL_HOME=%OSS%\lib\ivl
```

### Step 4 — 冒烟测试（验证全链路）

新建临时目录，放三个文件：

**dut.v**
```verilog
`timescale 1ns/1ps
module dut (input wire [3:0] din, output wire [3:0] dout);
    assign dout = din + 4'd1;
endmodule
```

**test_dut.py**
```python
import cocotb
from cocotb.triggers import Timer

@cocotb.test()
async def smoke_test(dut):
    """Incrementer smoke test: dout must equal din+1."""
    dut._log.info("cocotb smoke test start")
    for i in range(4):
        dut.din.value = i
        await Timer(10, unit="ns")   # cocotb 2.x 用 unit=，旧的 units= 会报弃用警告
        assert int(dut.dout.value) == (i + 1) % 16
    dut._log.info("smoke test PASSED")
```

**Makefile**
```makefile
SIM = icarus
TOPLEVEL = dut
VERILOG_SOURCES = $(PWD)/dut.v
MODULE = test_dut          # cocotb 2.x 中等价写法为 COCOTB_TEST_MODULES
include $(shell cocotb-config --makefiles)/Makefile.sim
```

运行：

```bash
source /k/AI_Coding/tools/activate_rtl_env.sh
cd <冒烟测试目录> && make
```

期望输出核心行：

```
** TESTS=1 PASS=1 FAIL=0 ... **
```

---

## 3. ⚠️ 注意点汇总（每一条都是实际踩过的坑）

| # | 坑 | 现象 | 规避方法 |
|---|----|------|---------|
| ① | **conda-forge 的 Windows 版 iverilog 是坏的** | `.vpi` 模块（system.vpi 等）无法加载，报「不是有效的 Win32 应用程序」，连纯 Verilog 的 `$display` 都用不了；且该包 2020 年 11.0 后停更 | 仿真器一律用 OSS CAD Suite；conda env 里只装 python/pip/make/cocotb |
| ② | Anaconda 默认通道要求接受 ToS | `CondaToSNonInteractiveError` | 所有 conda 命令加 `--override-channels -c conda-forge` |
| ③ | cocotb 没有 win-64 的 conda 包 | `PackagesNotFoundError: cocotb` | 必须用 pip 装 |
| ④ | **PATH 顺序导致 DLL 遮蔽** | 工具 exit code 127 且无任何报错输出 | oss-cad 的 `bin` 必须排在 conda 的 `Library/bin` **之前**（conda 的 zlib/libstdc++ 等 DLL 会被 oss-cad 程序错误加载）。这也是为什么必须用激活脚本，不要手动拼 |
| ⑤ | **oss-cad 的 `lib` 目录也必须在 PATH** | `iverilog -V` 正常，但 `make` 编译时报 127 | 激活脚本里已包含 `$OSS/lib`（iverilog 编译时派生的 ivl.exe 依赖其中的 DLL） |
| ⑥ | `python` vs `python3` 混淆 | `import cocotb` 失败 | oss-cad 自带 python3.11（无 cocotb）。始终用 `python`（= conda rtl 环境） |
| ⑦ | GitHub 网络问题 | `github.com`/`release-assets.githubusercontent.com` 连接被重置 | git 操作：`git -c http.proxy=http://127.0.0.1:7897 ...`（端口按自己代理改，Clash 常见 7890/7897）；release 资产下载：镜像前缀 `https://ghfast.top/<完整github-url>`（备选 gh-proxy.com、ghproxy.net）。`api.github.com` 通常可直连，可用来查最新版本号 |
| ⑧ | conda 的 make 装在非标准位置 | 找不到 make | make 位于 `<env>/Library/bin/make.exe`，激活脚本已覆盖 |

---

## 4. 日常使用速查

```bash
# 每次开新终端先激活（Git Bash）
source /k/AI_Coding/tools/activate_rtl_env.sh

# 进入任意 cocotb 项目目录跑仿真
cd <项目目录> && make

# 跑单个 test
make COCOTB_TESTCASE=smoke_test

# 看波形（配合 cocotb 里 dump_wave 或 $dumpfile）
gtkwave dump.vcd
```

卸载/迁移：整个环境就是两块——conda env `rtl`（`conda env remove -n rtl`）+ `oss-cad-suite/` 目录（直接删除或拷走），无注册表无系统污染。
