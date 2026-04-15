#!/usr/bin/env bash
# build_wheels.sh - 从 sdist 构建 wheel 文件
# 支持原生构建和 QEMU 模拟 aarch64 构建
set -euo pipefail

# ========== 参数解析 ==========
REQUIREMENTS_FILE=""
OUTPUT_DIR=""
EXTRA_INDEX_URL=""
BUILD_MODE="auto"
BUILD_TIMEOUT="30"
USE_QEMU=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --requirements-file) REQUIREMENTS_FILE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --extra-index-url) EXTRA_INDEX_URL="$2"; shift 2 ;;
    --build-mode) BUILD_MODE="$2"; shift 2 ;;
    --build-timeout) BUILD_TIMEOUT="$2"; shift 2 ;;
    --qemu) USE_QEMU=true; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# 校验必要参数
if [[ -z "$REQUIREMENTS_FILE" || -z "$OUTPUT_DIR" ]]; then
  echo "错误：缺少必要参数"
  echo "用法: build_wheels.sh --requirements-file <文件> --output-dir <目录>"
  exit 1
fi

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 构建额外索引 URL 参数
INDEX_URL_ARGS=""
if [[ -n "$EXTRA_INDEX_URL" ]]; then
  INDEX_URL_ARGS="--extra-index-url $EXTRA_INDEX_URL"
fi

# ========== 工具函数 ==========

# 判断包是否已有 wheel（在输出目录中）
has_wheel() {
  local pkg_name="$1"
  # 将包名转为 wheel 文件名格式（小写，下划线替换连字符）
  local normalized
  normalized=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
  find "$OUTPUT_DIR" -name "${normalized}-*.whl" 2>/dev/null | head -1 | grep -q .
}

# 在 Docker 容器中构建 wheel（用于 QEMU aarch64 模拟）
build_in_docker() {
  local pkg_spec="$1"
  local timeout_sec=$((BUILD_TIMEOUT * 60))

  echo "  [QEMU/Docker] 构建: $pkg_spec"

  # 使用 manylinux 容器构建，确保 glibc 兼容性
  # manylinux2014_aarch64 对应 quay.io/pypa/manylinux2014_aarch64
  docker run --rm --platform linux/arm64 \
    -v "$(cd "$(dirname "$OUTPUT_DIR")" && pwd)/$(basename "$OUTPUT_DIR"):/output" \
    -v "$(pwd):/workspace" \
    --env "PKG_SPEC=${pkg_spec}" \
    --env "INDEX_URL_ARGS=${INDEX_URL_ARGS}" \
    --env "BUILD_TIMEOUT=${timeout_sec}" \
    python:3.11-slim \
    bash -c "
      set -e
      pip install --upgrade pip setuptools wheel build 2>&1
      echo '构建: '\${PKG_SPEC}
      timeout \${BUILD_TIMEOUT} pip wheel \
        --no-binary=:all: \
        \${INDEX_URL_ARGS} \
        --wheel-dir=/output \
        \"\${PKG_SPEC}\" 2>&1 && echo '构建成功' || echo '构建失败'
    "
}

# 在当前环境中构建 wheel
build_native() {
  local pkg_spec="$1"
  local timeout_sec=$((BUILD_TIMEOUT * 60))

  echo "  [原生] 构建: $pkg_spec"

  timeout "${timeout_sec}" pip wheel \
    --no-binary=:all: \
    ${INDEX_URL_ARGS} \
    --wheel-dir="$OUTPUT_DIR" \
    "$pkg_spec"
}

# ========== 主逻辑 ==========

echo "========================================="
echo "  构建 wheel 文件"
echo "  输出目录: $OUTPUT_DIR"
echo "  构建模式: $BUILD_MODE"
echo "  QEMU 模式: $USE_QEMU"
echo "  构建超时: ${BUILD_TIMEOUT} 分钟"
echo "========================================="

# 确定需要构建的包列表
PACKAGES_TO_BUILD=""

if [[ "$BUILD_MODE" == "build-only" ]]; then
  # 仅构建模式：所有包都尝试构建
  PACKAGES_TO_BUILD=$(grep -v '^\s*#' "$REQUIREMENTS_FILE" | grep -v '^\s*-' | grep -v '^\s*$' || true)
elif [[ "$BUILD_MODE" == "auto" ]]; then
  # 自动模式：只构建缺失 wheel 的包
  MISSING_FILE="${OUTPUT_DIR}/.missing_wheels.txt"
  if [[ -f "$MISSING_FILE" ]] && [[ -s "$MISSING_FILE" ]]; then
    PACKAGES_TO_BUILD=$(cat "$MISSING_FILE" | grep -v '^\s*$' || true)
    echo "  从缺失列表中读取到 $(echo "$PACKAGES_TO_BUILD" | wc -l) 个需要构建的包"
  else
    echo "  未找到缺失列表或列表为空，无需构建"
    exit 0
  fi
fi

if [[ -z "$PACKAGES_TO_BUILD" ]]; then
  echo "  没有需要构建的包"
  exit 0
fi

# 记录构建失败的包
FAILED_FILE="${OUTPUT_DIR}/.failed_packages.txt"
> "$FAILED_FILE"

# 逐个构建
BUILT_COUNT=0
FAILED_COUNT=0

while IFS= read -r pkg_spec || [[ -n "$pkg_spec" ]]; do
  # 跳过空行
  pkg_spec=$(echo "$pkg_spec" | xargs)
  [[ -z "$pkg_spec" ]] && continue

  # 提取包名（去除版本约束）
  pkg_name=$(echo "$pkg_spec" | sed 's/[<>=!].*//' | sed 's/\[.*//')

  # 如果已有 wheel，跳过
  if has_wheel "$pkg_name"; then
    echo "  跳过（已有 wheel）: $pkg_spec"
    continue
  fi

  echo ""
  echo "  构建: $pkg_spec"

  # 根据模式选择构建方式
  build_success=false
  if $USE_QEMU; then
    if build_in_docker "$pkg_spec"; then
      build_success=true
    fi
  else
    if build_native "$pkg_spec"; then
      build_success=true
    fi
  fi

  if $build_success; then
    echo "  ✓ 构建成功: $pkg_spec"
    BUILT_COUNT=$((BUILT_COUNT + 1))
  else
    echo "  ✗ 构建失败: $pkg_spec"
    echo "$pkg_spec" >> "$FAILED_FILE"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done <<< "$PACKAGES_TO_BUILD"

# ========== 汇总结果 ==========

echo ""
echo "========================================="
echo "  构建结果汇总"
echo "========================================="
echo "  构建成功: ${BUILT_COUNT} 个"
echo "  构建失败: ${FAILED_COUNT} 个"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  echo ""
  echo "  失败的包列表："
  cat "$FAILED_FILE" | while read -r pkg; do
    echo "    - $pkg"
  done
  echo ""
  echo "  提示：构建失败可能是因为："
  echo "    1. 缺少系统构建依赖（通过 build-deps 参数添加）"
  echo "    2. 构建超时（通过 build-timeout 参数增加）"
  echo "    3. 包本身不支持该平台"
fi

WHEEL_COUNT=$(find "$OUTPUT_DIR" -name "*.whl" | wc -l)
echo "  输出目录中共 ${WHEEL_COUNT} 个 wheel 文件"
echo "========================================="
