# GtlControl4

GTL 智能家居 / 影音设备的 Control4 (DriverWorks) 驱动集合。

当前包含：

| 驱动 | 设备 | 通信方式 |
| --- | --- | --- |
| GTL2750 Matrix Amplifier (`driver.xml` / `driver.lua`) | GTL2750 4×4 矩阵功放 | TCP (Server :8234) / RS-232 (115200 8N1) |

## 仓库结构

```
.
├── driver.xml            # GTL2750 驱动清单
├── driver.lua            # GTL2750 驱动逻辑
├── icons/
│   ├── gen_icons.py      # 图标生成脚本 (Pillow)
│   ├── device_sm.png     # 生成产物：32×32 设备图标（本地构建）
│   └── device_lg.png     # 生成产物：300×300 设备图标（本地构建）
├── docs/
│   ├── 用户说明书.md
│   ├── 开发文档.md
│   └── 协议命令表.md
└── README.md
```

> **关于 PNG 图标**：由于此仓库的远程上传通道不支持二进制文件，PNG 没有提交到
> git，但提供了生成脚本 `icons/gen_icons.py`，可直接渲染出 Control4 风格的
> 32×32 / 300×300 PNG。打包 `.c4z` 之前先运行一次即可。

## 快速开始

1. 阅读 [`docs/用户说明书.md`](docs/用户说明书.md) 了解面向集成商的安装与使用。
2. 阅读 [`docs/开发文档.md`](docs/开发文档.md) 了解驱动结构与扩展方式。
3. 协议字段细节见 [`docs/协议命令表.md`](docs/协议命令表.md)。

## 打包为 .c4z

```bash
# 1. 先生成 PNG 图标（仅需安装 Pillow）
pip install Pillow
python3 icons/gen_icons.py
# → icons/device_sm.png, icons/device_lg.png

# 2. 打包驱动
zip -r gtl2750.c4z driver.xml driver.lua icons docs
```

将生成的 `gtl2750.c4z` 在 Composer Pro 中通过
*Tools → Add Driver* 导入即可。

## License

Proprietary © 2026 GTL.
