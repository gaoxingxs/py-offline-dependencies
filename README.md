# py-offline-dependencies

为 pypiserver 私服批量下载或构建 Python wheel 文件的 GitHub Action，支持 **linux amd64** 和 **linux aarch64** 双架构。

## 核心特性

- **自动解析传递依赖**：使用 `pip-compile` 解析完整依赖树，确保所有传递依赖都被下载/构建
- **智能下载策略**：优先从 PyPI 下载已有 wheel，仅对缺失的包从 sdist 构建
- **双架构并行构建**：x86_64 和 aarch64 同时构建，支持原生 ARM runner 或 QEMU 模拟
- **多 Python 版本支持**：一次运行可构建多个 Python 版本的 wheel

## 工作原理

```
requirements.txt / 内联依赖列表
        │
        ▼
┌─────────────────────────────┐
│  步骤0: 解析依赖树            │  pip-compile 解析所有传递依赖
│  (生成完整依赖列表)           │  Django → Django + asgiref + sqlparse + tzdata + ...
└─────────┬───────────────────┘
          │ 完整依赖列表
          ▼
┌─────────────────────────────┐
│  步骤1: 下载已有 wheel        │  pip download --only-binary=:all: --platform ...
│  (从 PyPI 直接下载)          │  主流包通常已有 wheel
└─────────┬───────────────────┘
          │ 缺失 wheel 的包
          ▼
┌─────────────────────────────┐
│  步骤2: 构建缺失 wheel        │  pip wheel --no-binary=<pkg> ...
│  (从 sdist 源码构建)         │  在目标平台环境或 QEMU 中构建
└─────────┬───────────────────┘
          │
          ▼
┌─────────────────────────────┐
│  步骤3: 上传 artifact        │  按 x86_64 / aarch64 分目录存储
│  (可下载或部署到私服)         │  附带构建报告和失败列表
└─────────────────────────────┘
```

## 传递依赖处理

**问题**：`requirements.txt` 声明的依赖通常还有传递依赖。例如：
```
Django>=4.2
  └── asgiref>=3.7.0
  └── sqlparse>=0.3.1
  └── tzdata (Windows only)
```

**解决方案**：
1. **步骤0** 使用 `pip-compile` 解析完整依赖树，生成包含所有传递依赖的锁定文件
2. 对锁定文件中的每个依赖下载/构建 wheel
3. 构建时使用 `--find-links` 指向已下载的 wheel，避免重复构建

## 快速开始

### 方式一：使用 workflow_dispatch 手动触发

1. 将本项目推送到 GitHub 仓库
2. 进入仓库 → Actions → "构建 Python Wheels"
3. 点击 "Run workflow"，填写参数：

```
依赖项列表:
Django>=4.2
psycopg2-binary
numpy
```

4. 等待构建完成，下载 Artifacts

### 方式二：在另一个仓库中引用

```yaml
jobs:
  build-wheels:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: your-org/py-offline-dependencies@main
        with:
          requirements: |
            Django>=4.2
            psycopg2-binary
            numpy
          architecture: 'both'
          python-version: '3.11'
          build-mode: 'auto'
```

## 参数说明

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `requirements` | 是 | - | 依赖项列表（每行一个）或 requirements.txt 文件路径 |
| `architecture` | 否 | `both` | 目标架构：`x86_64`、`aarch64`、`both` |
| `python-version` | 否 | `3.11` | Python 版本，多版本用逗号分隔（如 `3.9,3.10,3.11`） |
| `manylinux-version` | 否 | `manylinux2014` | manylinux 标准：`manylinux2014`(glibc≥2.17)、`manylinux_2_28`(glibc≥2.28) |
| `build-mode` | 否 | `auto` | `download-only`(仅下载)、`build-only`(仅构建)、`auto`(先下载再构建) |
| `aarch64-strategy` | 否 | `native` | `native`(原生ARM runner)、`qemu`(QEMU模拟) |
| `build-deps` | 否 | - | 额外系统构建依赖（apt 包，空格分隔） |
| `extra-index-url` | 否 | - | 额外 PyPI 索引 URL（如清华镜像源） |
| `build-timeout` | 否 | `30` | 单包构建超时（分钟） |

## 常见 C 扩展包的构建依赖

| 包名 | 需要 build-deps | 备注 |
|------|----------------|------|
| `psycopg2` | `libpq-dev` | 推荐用 `psycopg2-binary`（已有 wheel） |
| `lxml` | `libxml2-dev libxslt1-dev` | 新版已有 aarch64 wheel |
| `cryptography` | `libssl-dev libffi-dev` | 使用 abi3，已有 wheel |
| `mysqlclient` | `default-libmysqlclient-dev` | 常见仅 sdist 包 |
| `uWSGI` | - | 完全无 wheel，必须构建 |
| `Pillow` | `libjpeg-dev zlib1g-dev libfreetype6-dev` | 新版已有 aarch64 wheel |

## aarch64 构建策略选择

### native（推荐）

使用 GitHub 原生 ARM64 runner（`ubuntu-24.04-arm`），由 Arm Limited 提供。

- 速度快，无模拟开销
- 需要 GitHub Team/Enterprise 计划或公开仓库
- runner 标签：`ubuntu-24.04-arm`

### qemu

在 x86_64 runner 上通过 QEMU 用户空间模拟运行 aarch64 容器。

- 速度慢 5-10 倍
- 无需特殊 runner，任何仓库都可用

## manylinux 版本选择

| 版本 | glibc 最低版本 | 兼容系统 | 推荐场景 |
|------|---------------|---------|---------|
| `manylinux2014` | 2.17 | CentOS 7+, Ubuntu 16.04+ | 最大兼容性 |
| `manylinux_2_28` | 2.28 | Ubuntu 20.04+, Debian 11+ | 较新系统，更多特性 |

## 输出结构

```
wheelhouse/
├── x86_64/
│   ├── Django-4.2.11-py3-none-any.whl
│   ├── asgiref-3.8.1-py3-none-any.whl
│   ├── sqlparse-0.5.0-py3-none-any.whl
│   ├── numpy-2.4.4-cp311-cp311-manylinux2014_x86_64.whl
│   └── ...
└── aarch64/
    ├── Django-4.2.11-py3-none-any.whl    # 纯 Python 包与 x86_64 相同
    ├── asgiref-3.8.1-py3-none-any.whl
    ├── numpy-2.4.4-cp311-cp311-manylinux2014_aarch64.whl  # C 扩展包架构不同
    └── ...
```

## 部署到 pypiserver

构建完成后，将 wheel 文件上传到 pypiserver：

```bash
# 方式一：直接复制到 pypiserver 的 packages 目录
scp -r wheelhouse/* user@pypiserver:/path/to/packages/

# 方式二：通过 API 上传
find wheelhouse -name "*.whl" -exec curl -X POST \
  -u user:password \
  -F "package=@{}" \
  https://your-pypiserver/api/packages/ \;

# 方式三：在 GitHub Actions 中直接上传
- name: 上传到 pypiserver
  run: |
    find ./all-wheels -name "*.whl" -exec curl -X POST \
      -u ${{ secrets.PYPISERVER_USER }}:${{ secrets.PYPISERVER_PASS }} \
      -F "package=@{}" \
      ${{ secrets.PYPISERVER_URL }}/api/packages/ \;
```

## 示例

### 示例1：下载 Django 项目的所有依赖 wheel

```yaml
requirements: |
  Django>=4.2,<5.0
  djangorestframework
  celery
  redis
architecture: both
python-version: '3.11'
build-mode: auto
```

解析后将包含所有传递依赖：Django, asgiref, sqlparse, tzdata, djangorestframework, celery, kombu, billiard, vine, click, click-didyoumean, click-plugins, click-repl, python-dateutil, pytz, tzdata, redis 等。

### 示例2：构建需要编译的包

```yaml
requirements: |
  psycopg2
  uWSGI
architecture: aarch64
python-version: '3.11'
build-mode: auto
aarch64-strategy: native
build-deps: 'libpq-dev'
```

### 示例3：多 Python 版本 + 使用国内镜像

```yaml
requirements: |
  numpy
  pandas
  scikit-learn
architecture: both
python-version: '3.9,3.10,3.11'
build-mode: download-only
extra-index-url: 'https://pypi.tuna.tsinghua.edu.cn/simple'
```

## 注意事项

1. **传递依赖自动处理**：使用 `pip-compile` 解析完整依赖树，无需手动列出所有依赖
2. **纯 Python 包自动复用**：`py3-none-any` wheel 只需下载一次，两种架构通用
3. **主流 C 扩展包**（numpy, cryptography, cffi, lxml, grpcio 等）PyPI 上通常已有 aarch64 wheel，无需构建
4. **仅 sdist 的包**需要在目标平台原生环境中构建，构建速度取决于包的编译复杂度
5. **QEMU 模式**速度较慢，建议仅用于少量包的构建
6. 构建失败的包会在汇总报告中列出，可根据提示添加 `build-deps` 或调整 `build-timeout`

## 文件结构

```
py-offline-dependencies/
├── action.yml                    # Composite Action 定义
├── README.md                     # 本文档
├── scripts/
│   ├── download_wheels.sh        # 下载已有 wheel（含传递依赖解析）
│   └── build_wheels.sh           # 构建缺失的 wheel
└── .github/workflows/
    └── build-wheels.yml          # 完整 workflow
```
