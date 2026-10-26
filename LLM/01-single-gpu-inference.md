# 第一课：Azure H100 单卡大模型推理

整理日期：2026-10-26。

本教程对应学习路线的第一阶段：

**单卡推理 → 单机双卡 → 多机扩吞吐 → 多机拆分模型 → 微调 → 小模型从零训练。**

## 目标和适用范围

创建一台 `Standard_NC80adis_H100_v5` Spot VM，只使用 GPU 0 运行
`Qwen/Qwen3-8B`，调用推理接口，并完成单并发性能测试。

本课配置：

| 项目 | 配置 |
| --- | --- |
| Region | Japan East |
| VM | Standard_NC80adis_H100_v5 |
| GPU | 2 × NVIDIA H100 NVL，每卡约 94 GB 显存 |
| 本课使用的 GPU | 仅 GPU 0 |
| OS | Ubuntu Server 22.04 LTS，x64，Gen2 |
| 推理引擎 | vLLM 官方容器，固定版本 v0.32.0 |
| 模型 | Qwen/Qwen3-8B |
| 精度 | BF16 |
| 最大上下文 | 输入与输出合计 8,192 token |
| 访问方式 | VM 本机访问，或通过 SSH 隧道从 Mac 访问 |

> 即使只使用一张 GPU，Azure 仍按整台双卡 VM 收费。
>
> 本文是操作指南，不代表资源已经创建或测试已经通过。整理时已核对相关官方资料和
> vLLM 镜像版本，但尚未在本人的 Azure VM 上实际执行验证。
> 订阅配额、实时 Spot 容量、实际价格和最终性能均需现场确认。

命令分为“Mac 本地终端”和“Azure VM 终端”，不要混用。每个检查点成功后再继续；
出现报错时先保留完整输出，不要跳过失败步骤。

## 1. 理解软件分层

```text
Ubuntu 宿主机
  ├─ NVIDIA 驱动：让操作系统识别 H100
  ├─ Docker + NVIDIA Container Toolkit：让容器访问 GPU
  └─ vLLM 容器：包含 PyTorch、CUDA 用户态依赖和推理引擎
```

本课不需要在宿主机另外安装完整 CUDA Toolkit，也不需要安装 Conda。

Ubuntu 24.04 并非不能使用，但本教程统一采用 22.04。后面的 NVIDIA 软件仓库地址
也专门对应 Ubuntu 22.04，不要直接用于其他版本的系统。

## 2. 在 Azure Portal 创建 VM

### 2.1 Basics

| Portal 字段 | 本课选择 | 说明 |
| --- | --- | --- |
| Subscription | 自己的实验订阅 | 确认预算和权限 |
| Resource group | 新建 `rg-llm-lab-jpe` | 独立归集实验资源和费用 |
| Virtual machine name | `vm-llm-h100-01` | 后续节点可以命名为 02、03 |
| Region | Japan East | 实际能否分配取决于配额和容量 |
| Availability options | No infrastructure redundancy required | 单机学习不配置可用性集或跨区冗余 |
| Security type | Standard | 简化本课的 GPU 驱动安装 |
| Image | Ubuntu Server 22.04 LTS - x64 Gen2 | 普通 Server 镜像，不需要桌面 |
| VM architecture | x64 | 不选 Arm64 |
| Size | Standard_NC80adis_H100_v5 | 确认没有误选其他 SKU |
| Run with Azure Spot discount | 勾选 | 接受可能随时被回收 |
| Eviction type | 根据价格容忍度选择，见下文 | 不要把当前价格当成固定价格 |
| Eviction policy | Stop / Deallocate | 初学阶段保留环境 |
| Authentication type | SSH public key | 不使用弱密码 |
| Username | azureuser | 后面的 SSH 命令沿用此账号 |

#### Security type 为什么选 Standard？

这是实验环境的简化选择，不是说 H100 必须关闭所有安全功能，也不是生产环境的通用建议。

Azure GPU 驱动扩展不支持开启 Secure Boot 的安装路径；手动安装涉及驱动签名等额外步骤。
本课先使用 Standard，避免把签名问题和模型部署问题混在一起。

#### Eviction type 怎么选？

- **Capacity only**：仍会因容量不足被回收，不因自定义价格上限触发回收；
  这不代表锁定当前 Spot 价格。
- **Price or capacity**：设置可接受的最高小时价格；价格超过上限或容量不足都会回收。
  上限太低也可能无法启动。

费用控制优先时，选择 Price or capacity，并填写自己能接受的小时上限。
如果接受价格浮动、希望减少价格触发的中断，可以选择 Capacity only。

原始截图的机型旁显示约 `$6.56650/hour`，不能仅凭这一处确认最终 Spot 价格。
创建前检查 Review + create 的 Spot 价格和费用估算。
若实际按这个数字运行，3 小时约 `$19.70`，另加磁盘、网络等费用。

#### SSH 密钥

可以使用已有公钥，也可以让 Azure 生成新密钥。
使用 Azure 生成的密钥时，下载并妥善保存私钥，不要提交到 Git。

### 2.2 Disks

| 字段 | 选择 |
| --- | --- |
| OS disk size | 256 GiB |
| OS disk type | Standard SSD LRS |
| Data disks | 暂时不加 |
| Ephemeral OS disk | 本课不使用 |

空间用于 OS、驱动、容器镜像及其解压内容、模型权重、缓存和测试结果。

第一次先把模型缓存在持久 OS 磁盘上，不急着使用本地 NVMe，也不要执行不明来源的
格式化磁盘命令。本地 NVMe 是临时存储，后续可以存放可重建缓存，不能作为唯一持久副本。

### 2.3 Networking

- VNet：新建实验 VNet。
- Subnet：默认即可。
- Public IP：本课为方便从 Mac 连接，可以创建。
- SSH TCP 22：只允许当前公网 IP，来源使用单个 IPv4 地址的 `/32`。
- 不开放 TCP 8000，也不开放 Ray、NCCL 等端口。
- Accelerated networking：支持且可选时开启。
- Load balancing：None。

如果创建页面只能选择“允许 SSH”，创建后检查：

**VM → Networking → Network settings → NSG inbound rules**

将 SSH 规则来源限制为自己的公网 IP，不要保留来源为 `Any` 的 SSH 规则。
如果本地网络切换导致公网 IP 改变，需要相应更新该规则。

访问模型时使用 SSH 隧道：

```text
Mac localhost:8000
       ↓ SSH 加密隧道
Azure VM localhost:8000
       ↓ Docker 端口映射
vLLM 容器
```

### 2.4 其他设置与创建前检查

- 开启 Boot diagnostics，便于排查启动问题。
- 设置 Auto-shutdown，并核对时区。
- 没有需求时，不额外添加 Backup 或其他付费服务。
- 不额外选择自动安装 GPU 驱动扩展；本课统一手动安装，避免混用两套方法。
- 预算告警不是消费硬上限。

创建前确认：

- [ ] Ubuntu 22.04、x64、Gen2、Standard。
- [ ] SKU 为 Standard_NC80adis_H100_v5。
- [ ] 已选择 Spot，并理解价格和回收策略。
- [ ] SSH 来源受限，未开放公网 8000。
- [ ] 已核对最终费用估算。

Portal 能选到 SKU 不代表一定能成功分配。配额不足和 Spot 容量不足是不同问题，
需要根据创建时的实际错误处理。

## 3. 从 Mac 登录并确认硬件

### 3.1 Mac 本地终端

下面假设私钥保存在 `~/.ssh/llm-lab.pem`。替换为自己的真实路径和 VM 公网 IP。

```bash
chmod 600 ~/.ssh/llm-lab.pem

ssh -i ~/.ssh/llm-lab.pem azureuser@你的VM公网IP
```

首次连接时核对 SSH 主机指纹后再接受。

### 3.2 Azure VM 终端

```bash
cat /etc/os-release
uname -m
lspci | grep -i nvidia
df -h /
```

检查点：

- OS 是 Ubuntu 22.04。
- 架构是 `x86_64`。
- PCI 设备中能看到 NVIDIA GPU。
- 根分区容量足够。

普通 Ubuntu 镜像刚创建时没有 NVIDIA 驱动是正常的。
此时 `nvidia-smi` 不存在，不代表没有 GPU。

如果 `lspci` 没有 NVIDIA 设备，先核对实际创建的 SKU，不继续安装后面的软件。

## 4. 安装 NVIDIA 驱动

以下方法来自 NVIDIA 官方 Ubuntu 驱动安装指南，使用 NVIDIA 软件仓库及适合
H100 的开放内核模块驱动。

> 仅用于本课新建、尚未安装其他 GPU 驱动的 Ubuntu 22.04 VM。
> 如果已经安装 GPU 驱动扩展或其他驱动，不要再直接叠加此流程。

以下命令在 **Azure VM 终端** 执行。

### 4.1 安装依赖

```bash
sudo apt-get update

sudo apt-get install -y \
  build-essential \
  linux-headers-$(uname -r) \
  ca-certificates \
  curl \
  wget \
  gnupg
```

### 4.2 添加 NVIDIA Ubuntu 22.04 仓库

```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb

sudo dpkg -i cuda-keyring_1.1-1_all.deb

sudo apt-get update
```

### 4.3 安装驱动并重启

```bash
sudo apt-get install -y nvidia-open
```

确认安装没有失败后：

```bash
sudo reboot
```

SSH 断开是正常现象。等待 VM 启动，再从 Mac 重新登录。

### 4.4 检查点：识别两张 H100

```bash
nvidia-smi

nvidia-smi \
  --query-gpu=index,name,memory.total,driver_version \
  --format=csv
```

预期：

- 有 GPU 0 和 GPU 1。
- GPU 型号为 H100 NVL。
- 每张显存约 94 GB；单位换算和保留空间可能使显示数值不同。

本课固定使用的 vLLM v0.32.0 官方默认镜像采用 CUDA 13。
先确认宿主机驱动为 **R580 或更新版本**。
如果驱动更旧，先处理驱动与镜像的匹配，不要通过反复安装宿主机 CUDA Toolkit 解决。

`nvidia-smi` 顶部的 `CUDA Version` 表示驱动支持的 CUDA 版本，
不代表宿主机安装了完整 CUDA Toolkit。

记录本次实际安装的驱动版本；软件仓库的默认版本会随时间变化。

## 5. 安装 Docker 和 NVIDIA Container Toolkit

以下命令仍在 **Azure VM 终端** 执行。

### 5.1 安装 Docker

```bash
sudo apt-get install -y docker.io

sudo systemctl enable --now docker

sudo docker run --rm hello-world
```

看到 Docker 成功提示后继续。
本课统一使用 `sudo docker`，不额外授予普通用户 Docker 组访问权限。

### 5.2 添加 NVIDIA Container Toolkit 仓库

先启用 Bash 管道错误传播；每段命令报错时停下，不要继续：

```bash
set -o pipefail
```

添加签名密钥：

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor \
      -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
```

添加仓库：

```bash
curl -fsSL \
  https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
```

### 5.3 安装并配置 Toolkit

```bash
sudo apt-get update

sudo apt-get install -y nvidia-container-toolkit

sudo nvidia-ctk runtime configure --runtime=docker

sudo systemctl restart docker
```

### 5.4 检查点：容器只能访问 GPU 0

```bash
sudo docker run --rm \
  --gpus device=0 \
  ubuntu:22.04 \
  nvidia-smi
```

容器应只看到分配给它的一张 GPU；宿主机执行 `nvidia-smi` 则仍能看到两张。

如果提示无法选择 GPU runtime，先排查 Container Toolkit。
如果提示驱动通信失败，先排查宿主机驱动。不要跳过此检查点。

## 6. 启动单卡 Qwen3-8B

以下命令在 **Azure VM 终端** 执行。

### 6.1 准备缓存和结果目录

```bash
mkdir -p "$HOME/llm-lab/hf-cache"
mkdir -p "$HOME/llm-lab/results"

sudo docker pull vllm/vllm-openai:v0.32.0
```

镜像较大，首次下载需要时间和足够的磁盘空间。
使用固定版本而不是会变化的 `latest`。

### 6.2 启动服务

```bash
sudo docker run -d \
  --name llm-single \
  --gpus device=0 \
  --shm-size 8g \
  -p 127.0.0.1:8000:8000 \
  -v "$HOME/llm-lab/hf-cache:/root/.cache/huggingface" \
  -v "$HOME/llm-lab/results:/results" \
  vllm/vllm-openai:v0.32.0 \
  --model Qwen/Qwen3-8B \
  --dtype bfloat16 \
  --tensor-parallel-size 1 \
  --max-model-len 8192 \
  --max-num-seqs 16 \
  --gpu-memory-utilization 0.60 \
  --generation-config vllm \
  --seed 42 \
  --host 0.0.0.0 \
  --port 8000
```

| 参数 | 含义 |
| --- | --- |
| `--gpus device=0` | 容器只能访问第一张卡 |
| `--tensor-parallel-size 1` | 单卡运行，不拆分模型 |
| `--dtype bfloat16` | 使用 BF16 |
| `--max-model-len 8192` | 每个请求输入与输出合计的 token 上限 |
| `--max-num-seqs 16` | 限制调度中的最大序列数，不代表压测并发固定为 16 |
| `--gpu-memory-utilization 0.60` | 引擎显存预算约为所用 GPU 显存的 60%，包含权重、KV Cache 等 |
| `--generation-config vllm` | 使用 vLLM 的默认生成配置，减少模型仓库默认生成参数的影响 |
| `--shm-size 8g` | 设置容器共享内存上限，不是预留 8 GB GPU 显存 |
| `-p 127.0.0.1:8000:8000` | 宿主机端口只监听本机 |

容器内部监听 `0.0.0.0` 是为了 Docker 端口转发；
宿主机仍只暴露到 `127.0.0.1`，两者不矛盾。

Qwen3-8B 是公开模型，通常不需要 Hugging Face token，仍需遵守模型许可证。
模型默认从仓库当前 revision 下载；后续做严格版本对照时，还应固定模型 commit，
不能只固定 vLLM 镜像和随机种子。

### 6.3 查看日志

```bash
sudo docker logs -f --tail 100 llm-single
```

首次启动会下载权重、加载模型、编译部分内核并分配 KV Cache，
可能需要数分钟或更久。容器存在不代表服务已经就绪。

按 `Ctrl+C` 只退出日志跟踪，不会停止容器。

### 6.4 检查点：健康检查与模型列表

```bash
curl -fsS http://127.0.0.1:8000/health
```

成功时可能没有响应正文，但命令应成功退出。

```bash
curl -fsS http://127.0.0.1:8000/v1/models
```

预期返回包含 `Qwen/Qwen3-8B` 的模型信息。

再检查：

```bash
nvidia-smi
```

预期 GPU 0 有推理进程和明显显存占用，GPU 1 基本空闲。

8B 模型 BF16 权重约 16 GB，但实际显存占用可以明显高于这个值，
因为引擎还为 KV Cache 等分配空间。

## 7. 发出第一次推理请求

### 7.1 在 Azure VM 本机调用

```bash
curl -fsS http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-8B",
    "messages": [
      {
        "role": "user",
        "content": "请用中文简洁解释，大模型推理中的 token 是什么，并给一个例子。"
      }
    ],
    "temperature": 0,
    "max_tokens": 256,
    "chat_template_kwargs": {
      "enable_thinking": false
    }
  }'
```

明确关闭 thinking，让首次实验不混入思考输出。

### 7.2 查看流式输出

```bash
curl -N -fsS http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-8B",
    "messages": [
      {
        "role": "user",
        "content": "请介绍 GPU 为什么适合运行大模型。"
      }
    ],
    "temperature": 0,
    "max_tokens": 256,
    "stream": true,
    "chat_template_kwargs": {
      "enable_thinking": false
    }
  }'
```

输出为 SSE 数据流。一个数据块不一定等于一个 token，
不能通过数终端输出行来计算 token/s。

### 7.3 从 Mac 建立 SSH 隧道

在 **Mac 本地另一个终端** 执行，替换私钥路径和公网 IP：

```bash
ssh -i ~/.ssh/llm-lab.pem \
  -N \
  -o ExitOnForwardFailure=yes \
  -L 8000:127.0.0.1:8000 \
  azureuser@你的VM公网IP
```

保持该终端开启。再在 Mac 的另一个终端执行：

```bash
curl -fsS http://127.0.0.1:8000/v1/models
```

前面的推理请求也可以原样在 Mac 执行，不需要开放公网 8000。
性能基准测试仍在 VM 内执行，以减少本地到 Azure 网络延迟的干扰。

## 8. 单请求性能测试

先成功执行几次推理作为预热。

以下命令在 **Azure VM 终端** 执行：

```bash
sudo docker exec llm-single \
  vllm bench serve \
    --backend vllm \
    --base-url http://127.0.0.1:8000 \
    --endpoint /v1/completions \
    --model Qwen/Qwen3-8B \
    --dataset-name random \
    --random-input-len 512 \
    --random-output-len 128 \
    --num-prompts 20 \
    --max-concurrency 1 \
    --request-rate inf \
    --ignore-eos \
    --seed 42 \
    --save-result \
    --result-dir /results \
    --result-filename single-gpu-c1-run1.json
```

参数说明：

- 合成输入长度配置为 512 token，输出长度配置为 128 token；以测试实际统计为准。
- `--ignore-eos` 避免模型提前结束而缩短指定输出。
- 总共 20 个请求，同一时间只允许一个请求。
- `--request-rate inf` 表示不额外设置到达间隔，不是无限并发；
  并发仍被 `--max-concurrency 1` 限制。
- 这是原始文本 completions 的合成性能基线，不是中文聊天质量测试。

### 8.1 记录指标

| 指标 | 解释 |
| --- | --- |
| Successful requests | 应全部成功 |
| Mean / Median TTFT | 从请求到首 token 的时间 |
| Mean TPOT | 首 token 后，每个输出 token 的平均耗时 |
| Output token throughput | 整段测试的输出 token 吞吐 |
| P95 延迟指标 | 观察尾部延迟和抖动 |

如果 Mean TPOT 为 10 ms，可以粗估稳态生成速度：

```text
1000 / 10 ≈ 100 token/s
```

这是单位换算示例，不是这台机器的性能承诺。
总输出吞吐还包含首 token、请求切换等开销，不一定等于 TPOT 的倒数。

重复执行三次，将结果文件名分别改成：

```text
single-gpu-c1-run1.json
single-gpu-c1-run2.json
single-gpu-c1-run3.json
```

结果通过挂载保存在 VM 的 `~/llm-lab/results` 目录，而不仅存在于容器可写层。
本课先不改并发、上下文和卡数，避免一次改变多个变量。

### 8.2 实验记录模板

| 项目 | 实际记录 |
| --- | --- |
| 实验日期 | 待填写 |
| Region / VM SKU | 待填写 |
| OS / 内核版本 | 待填写 |
| NVIDIA 驱动版本 | 待填写 |
| 容器版本 / digest | 待填写 |
| 模型 revision | 待填写 |
| GPU / 精度 | GPU 0 / BF16 |
| 最大上下文 / 显存预算 | 8192 / 0.60 |
| 输入 / 输出长度配置 | 512 / 128 |
| 压测并发 / 请求数 | 1 / 20 |
| 三次 TTFT / TPOT / 吞吐 | 待填写 |
| 是否有错误或后台 GPU 负载 | 待填写 |

可用以下命令记录部分环境信息：

```bash
uname -r

nvidia-smi \
  --query-gpu=index,name,memory.total,driver_version \
  --format=csv

sudo docker image inspect vllm/vllm-openai:v0.32.0 \
  --format '{{json .RepoDigests}}'
```

## 9. 停止服务与停止计算计费

### 9.1 停止容器

在 Azure VM 终端执行：

```bash
sudo docker stop llm-single
```

这只停止推理服务，VM 仍在收费。

### 9.2 释放 VM 计算资源

在 Azure Portal：

**VM → Stop → 等待状态变成 Stopped (deallocated)**

不要只在 Ubuntu 内执行 `shutdown` 就认为计算费用已经停止。

- Deallocate 后，持久磁盘等资源仍可能计费。
- Spot 回收后重新启动不保证有容量。
- 本课选择 Stop / Deallocate，不能把它等同于删除资源。
- 不再需要实验资源时，应检查后再删除明确属于实验的资源，不要误删其他环境。

### 9.3 下次恢复

在 Portal 启动 VM，检查公网 IP 是否变化，重新登录。

先确认 GPU 驱动正常，然后启动已有容器：

```bash
nvidia-smi

sudo docker start llm-single

sudo docker logs -f --tail 100 llm-single
```

健康检查成功后再使用服务。
不要重复执行同名的 `docker run`，否则会出现容器名称冲突。
持久磁盘里的模型缓存仍在时，通常不必重新下载全部权重。

## 10. 常见问题：先定位哪一层

| 现象 | 优先检查 |
| --- | --- |
| VM 创建失败 | 区分配额不足、SKU 限制和 Spot 容量不足，保留完整 Azure 错误 |
| SSH 连接超时 | VM 是否运行、公网 IP、NSG 来源 IP、本地网络 |
| `lspci` 看不到 NVIDIA | 实际 VM SKU 和硬件分配，不先折腾 CUDA |
| `nvidia-smi` 不存在或失败 | 驱动安装输出、重启情况、内核头文件、安全启动配置 |
| 容器无法选择 GPU runtime | Container Toolkit 安装、runtime 配置、Docker 是否重启 |
| CUDA 驱动版本不足 | 宿主机驱动与容器 CUDA 的兼容性，不盲目安装宿主机 Toolkit |
| 容器启动后立刻退出 | `sudo docker ps -a` 和 `sudo docker logs --tail 100 llm-single` |
| `/health` 连接失败 | 模型是否还在加载、容器状态、端口映射 |
| 下载模型失败 | DNS、出站网络、磁盘空间、模型仓库实际错误 |
| 显存不足 | 是否有其他进程、是否真的只用 GPU 0、模型/上下文/显存预算配置 |
| Mac 隧道提示端口占用 | 本地 8000 是否已有程序；可改本地端口并同步修改访问 URL |
| 停止后还有费用 | 是否真正 deallocated，以及磁盘、公网 IP 等剩余资源费用 |

不要把未经确认的错误当作成功，也不要混用驱动扩展、系统仓库驱动和其他手动安装器。

## 11. 本课验收与后续继续方式

- [ ] 宿主机能看到两张 H100。
- [ ] 测试容器只能访问 GPU 0。
- [ ] vLLM 健康检查和模型列表成功。
- [ ] 中文普通请求和流式请求成功。
- [ ] GPU 0 执行推理，GPU 1 基本空闲。
- [ ] 完成三次单并发压测并保存结果。
- [ ] 记录实际驱动、镜像和性能指标。
- [ ] 实验结束确认 VM 为 Stopped (deallocated)。

建议第一次先完成到第 4 节，确认 `nvidia-smi` 正确显示两张 H100，再继续。

后续开启新会话时，可以直接说明：

> 按照这篇教程继续。我已经完成到第 X 节，下面是对应检查点的输出。
> 请从这里继续，不重新创建 VM，也不要覆盖已有环境。

下一课在保留单卡基线的前提下，使用同一模型比较单机双卡 TP=2。
暂不提前改动本课的卡数、模型和并发。

## 官方参考

- [Azure NCads H100 v5 规格](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/gpu-accelerated/ncadsh100v5-series)
- [Azure Spot VM 行为和限制](https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms)
- [Azure Linux N-series GPU 驱动说明](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/n-series-driver-setup)
- [Azure NVIDIA GPU 驱动扩展和 Secure Boot 限制](https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/hpccompute-gpu-linux)
- [NVIDIA Ubuntu 驱动安装指南](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/ubuntu.html)
- [NVIDIA Container Toolkit 安装指南](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [vLLM Docker 部署说明](https://docs.vllm.ai/en/stable/deployment/docker/)
- [vLLM v0.32.0 发布](https://github.com/vllm-project/vllm/releases/tag/v0.32.0)
- [vLLM 在线服务压测参数](https://docs.vllm.ai/en/stable/cli/bench/serve/)
- [Qwen3-8B 模型与许可证](https://huggingface.co/Qwen/Qwen3-8B)
