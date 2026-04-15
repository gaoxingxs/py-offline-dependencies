#!/usr/bin/env bash
# download_wheels.sh - 从 PyPI 下载已有 wheel 文件
# 核心流程：
#   1. 用 pip-compile / pip install --dry-run 解析完整依赖树（含传递依赖）
#   2. 逐个下载已有 wheel
#   3. 记录缺失 wheel 的包供后续构建
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

# ========== 步骤1：解析完整依赖树 ==========
# pip download --platform 无法解析依赖，需要先在当前平台解析出完整依赖列表
# 使用 pip install --dry-run + pip-compile 等方式获取所有传递依赖

echo "========================================="
echo "  步骤1：解析完整依赖树"
echo "========================================="

# 方法：使用 pip-compile 生成带所有传递依赖的锁定文件
# pip-compile 能解析出完整的依赖树，包括版本约束
pip install pip-tools 2>/dev/null || true

RESOLVED_FILE="${OUTPUT_DIR}/.requirements_resolved.txt"

# 尝试用 pip-compile 解析
if command -v pip-compile &>/dev/null; then
  echo "  使用 pip-compile 解析依赖树..."
  # pip-compile 会解析所有传递依赖并输出带精确版本的 requirements
  pip-compile \
    ${INDEX_URL_ARGS} \
    --output-file "$RESOLVED_FILE" \
    --no-header \
    --no-emit-index-url \
    "$REQUIREMENTS_FILE" 2>/dev/null || {
      # pip-compile 可能因某些包的元数据问题失败，回退到 pip 方式
      echo "  pip-compile 解析失败，回退到 pip 方式..."
      RESOLVED_FILE="$REQUIREMENTS_FILE"
    }
else
  echo "  pip-compile 不可用，使用 pip 解析依赖树..."
  # 回退方案：用 pip install --dry-run 获取依赖列表
  # --dry-run 只解析不安装，--report 输出 JSON 格式的依赖信息
  REPORT_FILE="${OUTPUT_DIR}/.pip_install_report.json"
  pip install \
    ${INDEX_URL_ARGS} \
    --dry-run \
    --ignore-installed \
    --report "$REPORT_FILE" \
    -r "$REQUIREMENTS_FILE" 2>/dev/null || true

  if [[ -f "$REPORT_FILE" ]]; then
    echo "  从 pip install --report 提取依赖列表..."
    # 从 JSON report 中提取所有包名和版本
    python3 -c "
import json, sys
with open('$REPORT_FILE') as f:
    data = json.load(f)
for item in data.get('install', []):
    meta = item.get('metadata', {})
    name = meta.get('name', '')
    version = meta.get('version', '')
    if name and version:
        print(f'{name}=={version}')
" > "$RESOLVED_FILE" 2>/dev/null || {
      echo "  JSON 解析失败，使用原始 requirements 文件"
      RESOLVED_FILE="$REQUIREMENTS_FILE"
    }
  else
    echo "  pip install --report 不可用，使用原始 requirements 文件"
    RESOLVED_FILE="$REQUIREMENTS_FILE"
  fi
fi

# 统计解析出的依赖数量
if [[ -f "$RESOLVED_FILE" ]]; then
  RESOLVED_COUNT=$(grep -v '^\s*#' "$RESOLVED_FILE" | grep -v '^\s*-' | grep -v '^\s*$' | wc -l)
  echo "  解析出 ${RESOLVED_COUNT} 个依赖（含传递依赖）"
else
  echo "  警告：依赖解析失败，将使用原始 requirements 文件"
  RESOLVED_FILE="$REQUIREMENTS_FILE"
fi

# ========== 步骤2：逐个下载 wheel ==========

echo ""
echo "========================================="
echo "  步骤2：下载 wheel 文件"
echo "  平台: $PLATFORM"
echo "  Python 版本: $PYTHON_VERSIONS"
echo "  输出目录: $OUTPUT_DIR"
echo "========================================="

# 缺失 wheel 的包列表（全局，跨 Python 版本去重）
MISSING_FILE="${OUTPUT_DIR}/.missing_wheels.txt"
> "$MISSING_FILE"

# 已下载成功的包名集合（用于去重）
DOWNLOADED_FILE="${OUTPUT_DIR}/.downloaded_packages.txt"
> "$DOWNLOADED_FILE"

TOTAL_DOWNLOADED=0
TOTAL_MISSING=0

# 对每个 Python 版本分别下载
for PY_VER in $PYTHON_VERSIONS; do
  PY_VER_SHORT=$(echo "$PY_VER" | tr -d '.')

  echo ""
  echo "--- 下载 Python $PY_VER (cp${PY_VER_SHORT}) 的 wheel ---"

  # 逐行处理解析后的 requirements 文件
  while IFS= read -r line || [[ -n "$line" ]]; do
    # 跳过空行和注释
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [[ -z "$line" ]] && continue
    # 跳过选项行（如 -i, --index-url, -f, --find-links 等）
    [[ "$line" =~ ^- ]] && continue

    # 提取包名（去除版本约束和 extras）
    pkg_name=$(echo "$line" | sed 's/[<>=!].*//' | sed 's/\[.*//')
    # 标准化包名（小写，连字符/下划线/点统一）
    pkg_name_normalized=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]' | tr '_.' '-')

    # 检查是否已下载过该包（纯 Python 包跨版本通用）
    if grep -qxF "$pkg_name_normalized" "$DOWNLOADED_FILE" 2>/dev/null; then
      # 检查已下载的 wheel 是否是纯 Python 包（py3-none-any）
      if find "$OUTPUT_DIR" -name "*.whl" 2>/dev/null | grep -i "${pkg_name_normalized}" | grep -q "py3.none.any\|py2.py3.none.any\|none-any" 2>/dev/null; then
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
      echo "$pkg_name_normalized" >> "$DOWNLOADED_FILE"
      TOTAL_DOWNLOADED=$((TOTAL_DOWNLOADED + 1))
    else
      # 区分"没有 wheel"和"其他错误"
      if grep -q "No matching distribution" /tmp/pip_download_err.txt 2>/dev/null || \
         grep -q "is only available as an sdist" /tmp/pip_download_err.txt 2>/dev/null; then
        echo "  ✗ 无 wheel 可下载: $line"
      else
        echo "  ✗ 下载失败: $line"
        cat /tmp/pip_download_err.txt
      fi
      # 添加到缺失列表（去重）
      if ! grep -qxF "$line" "$MISSING_FILE" 2>/dev/null; then
        echo "$line" >> "$MISSING_FILE"
        TOTAL_MISSING=$((TOTAL_MISSING + 1))
      fi
    fi
  done < "$RESOLVED_FILE"
done

# ========== 步骤3：补充下载纯 Python 包 ==========
# 纯 Python 包（py3-none-any）不依赖平台，只需下载一次
# 但某些包在 --platform 模式下可能因 ABI 匹配问题下载失败
# 尝试不带 --platform 参数重新下载缺失列表中的纯 Python 包

echo ""
echo "--- 补充下载纯 Python 包（不带平台约束）---"

TEMP_MISSING="${OUTPUT_DIR}/.missing_wheels_remaining.txt"
cp "$MISSING_FILE" "$TEMP_MISSING"
> "$MISSING_FILE"

while IFS= read -r line || [[ -n "$line" ]]; do
  line=$(echo "$line" | xargs)
  [[ -z "$line" ]] && continue

  pkg_name=$(echo "$line" | sed 's/[<>=!].*//' | sed 's/\[.*//')
  pkg_name_normalized=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]' | tr '_.' '-')

  # 检查是否已经下载了
  if grep -qxF "$pkg_name_normalized" "$DOWNLOADED_FILE" 2>/dev/null; then
    echo "  跳过（已下载）: $line"
    continue
  fi

  # 不带 --platform 参数下载（当前平台，可能得到纯 Python wheel）
  if pip download \
    --only-binary=:all: \
    ${INDEX_URL_ARGS} \
    --dest "$OUTPUT_DIR" \
    "$line" 2>/tmp/pip_download_err2.txt; then
    # 检查下载的是否是纯 Python 包
    LATEST_WHL=$(find "$OUTPUT_DIR" -name "*.whl" -newer "$DOWNLOADED_FILE" | head -1)
    if [[ -n "$LATEST_WHL" ]] && echo "$LATEST_WHL" | grep -q "none-any"; then
      echo "  ✓ 补充下载成功（纯 Python 包）: $line"
      echo "$pkg_name_normalized" >> "$DOWNLOADED_FILE"
      TOTAL_DOWNLOADED=$((TOTAL_DOWNLOADED + 1))
      TOTAL_MISSING=$((TOTAL_MISSING - 1))
    else
      # 下载了当前平台的 wheel，但不是纯 Python 的，对目标平台无用
      echo "  ✗ 下载的是平台特定 wheel，不适用于目标平台: $line"
      # 删除不匹配的 wheel
      if [[ -n "$LATEST_WHL" ]]; then
        rm -f "$LATEST_WHL"
      fi
      echo "$line" >> "$MISSING_FILE"
    fi
  else
    echo "  ✗ 仍然无法下载: $line"
    echo "$line" >> "$MISSING_FILE"
  fi
done < "$TEMP_MISSING"

# 清理临时文件
rm -f "$TEMP_MISSING"

# ========== 汇总结果 ==========

echo ""
echo "========================================="
echo "  下载结果汇总"
echo "========================================="

WHEEL_COUNT=$(find "$OUTPUT_DIR" -name "*.whl" | wc -l)
FINAL_MISSING=$(grep -c '^' "$MISSING_FILE" 2>/dev/null || echo 0)
echo "  已下载 wheel: ${WHEEL_COUNT} 个"
echo "  缺失 wheel: ${FINAL_MISSING} 个包"

if [[ "$FINAL_MISSING" -gt 0 ]]; then
  echo ""
  echo "  缺失 wheel 的包列表（将从 sdist 构建）："
  cat "$MISSING_FILE" | while read -r pkg; do
    echo "    - $pkg"
  done
fi

echo "========================================="
