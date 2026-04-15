#!/usr/bin/env bash
# download_wheels.sh - 从 PyPI 下载已有 wheel 文件
# 对于只有 sdist 没有 wheel 的包，记录到缺失列表供后续构建
set -euo pipefail

# ========== 参数解析 ==========
REQUIREMENTS_FILE=""
PLATFORM=""
PYTHON_VERSIONS=""
OUTPUT_DIR=""
EXTRA_INDEX_URL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --requirements-file) REQUIREMENTS_FILE="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --python-versions) PYTHON_VERSIONS="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --extra-index-url) EXTRA_INDEX_URL="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# 校验必要参数
if [[ -z "$REQUIREMENTS_FILE" || -z "$PLATFORM" || -z "$PYTHON_VERSIONS" || -z "$OUTPUT_DIR" ]]; then
  echo "错误：缺少必要参数"
  echo "用法: download_wheels.sh --requirements-file <文件> --platform <平台> --python-versions <版本列表> --output-dir <目录>"
  exit 1
fi

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 构建额外索引 URL 参数
INDEX_URL_ARGS=""
if [[ -n "$EXTRA_INDEX_URL" ]]; then
  INDEX_URL_ARGS="--extra-index-url $EXTRA_INDEX_URL"
fi

# ========== 主逻辑 ==========

echo "========================================="
echo "  下载 wheel 文件"
echo "  平台: $PLATFORM"
echo "  Python 版本: $PYTHON_VERSIONS"
echo "  输出目录: $OUTPUT_DIR"
echo "========================================="

# 缺失 wheel 的包列表（全局，跨 Python 版本去重）
MISSING_FILE="${OUTPUT_DIR}/.missing_wheels.txt"
> "$MISSING_FILE"

# 已下载成功的包名集合（用于去重，避免重复下载纯 Python 包）
DOWNLOADED_FILE="${OUTPUT_DIR}/.downloaded_packages.txt"
> "$DOWNLOADED_FILE"

TOTAL_DOWNLOADED=0
TOTAL_MISSING=0

# 对每个 Python 版本分别下载
for PY_VER in $PYTHON_VERSIONS; do
  # 将 3.11 转为 311 格式
  PY_VER_SHORT=$(echo "$PY_VER" | tr -d '.')

  echo ""
  echo "--- 下载 Python $PY_VER (cp${PY_VER_SHORT}) 的 wheel ---"

  # 逐行处理 requirements 文件
  while IFS= read -r line || [[ -n "$line" ]]; do
    # 跳过空行和注释
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [[ -z "$line" ]] && continue
    # 跳过选项行（如 -i, --index-url, -f, --find-links 等）
    [[ "$line" =~ ^- ]] && continue

    # 提取包名（去除版本约束和 extras）
    pkg_name=$(echo "$line" | sed 's/[<>=!].*//' | sed 's/\[.*//')

    # 检查是否已下载过该包（纯 Python 包只需下载一次）
    if grep -qxF "$pkg_name" "$DOWNLOADED_FILE" 2>/dev/null; then
      # 已下载过，但需要检查是否需要当前 Python 版本的特定 wheel
      # 纯 Python 包（py3-none-any）不需要重复下载
      # 平台特定的包需要为每个 Python 版本下载
      if find "$OUTPUT_DIR" -name "*.whl" | grep -qi "${pkg_name}" | grep -q "py3.none.any\|py2.py3.none.any" 2>/dev/null; then
        echo "  跳过（纯 Python 包已下载）: $line"
        continue
      fi
    fi

    echo ""
    echo "  下载: $line"

    # 尝试下载 wheel
    if pip download \
      --only-binary=:all: \
      --platform "${PLATFORM}" \
      --python-version "${PY_VER_SHORT}" \
      --implementation cp \
      --abi "cp${PY_VER_SHORT}" \
      ${INDEX_URL_ARGS} \
      --dest "$OUTPUT_DIR" \
      "$line" 2>/tmp/pip_download_err.txt; then
      echo "  ✓ 下载成功: $line"
      echo "$pkg_name" >> "$DOWNLOADED_FILE"
      TOTAL_DOWNLOADED=$((TOTAL_DOWNLOADED + 1))
    else
      # 检查是否是因为没有 wheel（而非其他错误）
      if grep -q "No matching distribution" /tmp/pip_download_err.txt 2>/dev/null || \
         grep -q "is only available as an sdist" /tmp/pip_download_err.txt 2>/dev/null; then
        echo "  ✗ 无 wheel 可下载: $line"
        # 添加到缺失列表（去重）
        if ! grep -qxF "$line" "$MISSING_FILE" 2>/dev/null; then
          echo "$line" >> "$MISSING_FILE"
          TOTAL_MISSING=$((TOTAL_MISSING + 1))
        fi
      else
        # 其他错误（网络问题等），也记录为缺失
        echo "  ✗ 下载失败: $line"
        cat /tmp/pip_download_err.txt
        if ! grep -qxF "$line" "$MISSING_FILE" 2>/dev/null; then
          echo "$line" >> "$MISSING_FILE"
          TOTAL_MISSING=$((TOTAL_MISSING + 1))
        fi
      fi
    fi
  done < "$REQUIREMENTS_FILE"
done

# ========== 汇总结果 ==========

echo ""
echo "========================================="
echo "  下载结果汇总"
echo "========================================="

WHEEL_COUNT=$(find "$OUTPUT_DIR" -name "*.whl" | wc -l)
echo "  已下载 wheel: ${WHEEL_COUNT} 个"
echo "  缺失 wheel: ${TOTAL_MISSING} 个包"

if [[ "$TOTAL_MISSING" -gt 0 ]]; then
  echo ""
  echo "  缺失 wheel 的包列表："
  cat "$MISSING_FILE" | while read -r pkg; do
    echo "    - $pkg"
  done
fi

echo "========================================="
