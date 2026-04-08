#!/bin/bash

# nvm-auto.sh - Node 版本管理自动化脚本
# 功能：检测项目 Node 版本，优先使用同大版本已安装的最高小版本，缺失则安装
#       支持自动安装 shell hook（zsh/bash），之后 cd 进项目自动切换版本

# 加载 nvm
if [ -n "$NVM_DIR" ] && [ -f "$NVM_DIR/nvm.sh" ]; then
    source "$NVM_DIR/nvm.sh"
elif [ -d "$HOME/.nvm" ]; then
    export NVM_DIR="$HOME/.nvm"
    source "$NVM_DIR/nvm.sh"
else
    echo "[ERROR] 未找到 nvm，请先安装：https://github.com/nvm-sh/nvm" >&2
    exit 1
fi

# 检查 nvm 是否加载成功
if ! command -v nvm &>/dev/null; then
    echo "[ERROR] nvm 命令不可用，请检查安装" >&2
    exit 1
fi

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# 提取大版本号（如 v18.16.0 -> 18）
get_major_version() {
    local version="$1"
    # 去掉 v 前缀，提取第一个数字
    echo "$version" | sed 's/^v//' | cut -d'.' -f1
}

# 从 package.json 依赖推断推荐版本
infer_version_from_deps() {
    local project_dir="${1:-.}"

    if [ ! -f "$project_dir/package.json" ]; then
        return 1
    fi

    # 检查是否有针对 Node 20+ 的依赖
    if grep -qE '"@types/node":\s*"[^"]*[2-9][0-9]' "$project_dir/package.json" 2>/dev/null; then
        echo "20"
        return 0
    fi

    # 检查是否有针对 Node 18+ 的依赖
    if grep -qE '"@types/node":\s*"[^"]*1[89]' "$project_dir/package.json" 2>/dev/null; then
        echo "18"
        return 0
    fi

    # 默认推荐 LTS 版本
    echo "18"
    return 0
}

# 获取本地已安装的最新稳定版本
get_latest_installed_version() {
    local installed_versions=$(nvm ls --no-colors 2>/dev/null)

    # 过滤出稳定版本（排除 iojs、lts/* 等），取最新的
    local latest_version=$(echo "$installed_versions" \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | grep -v '^v0\.' \
        | sort -t. -k1,1nr -k2,2nr -k3,3nr \
        | head -1)

    if [ -n "$latest_version" ]; then
        echo "$latest_version" | sed 's/^v//'
        return 0
    else
        return 1
    fi
}

# 检测项目所需 Node 版本
detect_node_version() {
    local project_dir="${1:-.}"
    local version=""

    # 1. 检查 .nvmrc
    if [ -f "$project_dir/.nvmrc" ]; then
        version=$(cat "$project_dir/.nvmrc" | tr -d '\n')
        log_info "从 .nvmrc 检测到 Node 版本：$version"
        echo "$version"
        return 0
    fi

    # 2. 检查 .node-version
    if [ -f "$project_dir/.node-version" ]; then
        version=$(cat "$project_dir/.node-version" | tr -d '\n')
        log_info "从 .node-version 检测到 Node 版本：$version"
        echo "$version"
        return 0
    fi

    # 3. 检查 package.json 的 engines.node 字段
    if [ -f "$project_dir/package.json" ]; then
        version=$(grep -o '"node"[[:space:]]*:[[:space:]]*"[^"]*"' "$project_dir/package.json" \
                  | head -1 \
                  | sed 's/.*"node"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        if [ -n "$version" ] && [ "$version" != "\"\"" ]; then
            # 清理版本号，去掉 ^ ~ >= 等前缀
            version=$(echo "$version" | sed 's/[\^~>=<]*//g' | head -1)
            log_info "从 package.json 检测到 Node 版本：$version"
            echo "$version"
            return 0
        fi

        # 4. 从依赖推断版本
        log_warn "未在 package.json 中找到 engines.node 字段，尝试推断..."
        local inferred_version
        inferred_version=$(infer_version_from_deps "$project_dir")
        if [ -n "$inferred_version" ]; then
            log_info "从依赖推断：建议使用 Node $inferred_version.x"
            echo "$inferred_version"
            return 0
        fi
    fi

    # 5. 使用本地已安装的最新版本
    log_warn "无法检测项目版本要求，使用本地已安装的最新版本"
    local installed_latest
    installed_latest=$(get_latest_installed_version) || true
    if [ -n "$installed_latest" ]; then
        echo "$installed_latest"
        return 0
    fi

    log_error "无法确定项目所需的 Node 版本，请手动指定"
    echo "用法：./nvm-auto.sh [项目目录] [版本]" >&2
    return 1
}

# 查找同大版本已安装的最高小版本
find_matching_major_version() {
    local target_version="$1"
    local target_major=$(get_major_version "$target_version")
    local installed_versions=$(nvm ls --no-colors 2>/dev/null)

    # 过滤出同大版本的已安装版本，按版本号排序，取最高的
    local matching_version=$(echo "$installed_versions" \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | while read ver; do
            major=$(get_major_version "$ver")
            if [ "$major" = "$target_major" ]; then
                echo "$ver"
            fi
        done \
        | sort -V \
        | tail -1)

    if [ -n "$matching_version" ]; then
        # 去掉 v 前缀
        echo "$matching_version" | sed 's/^v//'
        return 0
    fi
    return 1
}

# 安装指定版本
install_version() {
    local version="$1"
    log_info "正在安装 Node v$version..."
    if nvm install "$version"; then
        log_info "Node v$version 安装成功"
        return 0
    else
        log_error "Node v$version 安装失败"
        return 1
    fi
}

# 生成 .nvmrc 文件
create_nvmrc() {
    local version="$1"
    local project_dir="${2:-.}"
    local nvmrc_path="$project_dir/.nvmrc"

    echo "$version" > "$nvmrc_path"
    log_info "已生成 .nvmrc 文件：$nvmrc_path (Node $version)"
}

# 检查 zsh 配置文件中是否已配置自动 nvm use hook
zsh_hook_exists() {
    local hook_marker="# 自动调用 nvm use (Zsh)"
    if [ -f "$HOME/.zshrc" ] && grep -qF "$hook_marker" "$HOME/.zshrc"; then
        return 0
    fi
    return 1
}

# 检查 bash 配置文件中是否已配置自动 nvm use hook
bash_hook_exists() {
    local hook_marker="# nvm auto switch (Bash)"
    if [ -f "$HOME/.bashrc" ] && grep -qF "$hook_marker" "$HOME/.bashrc"; then
        return 0
    fi
    if [ -f "$HOME/.bash_profile" ] && grep -qF "$hook_marker" "$HOME/.bash_profile"; then
        return 0
    fi
    return 1
}

# 写入自动 nvm use hook 到对应的 shell 配置文件
write_shell_hook() {
    # Zsh 专用的 hook 内容
    local zsh_hook_content='
# 自动调用 nvm use (Zsh)
autoload -U add-zsh-hook
load-nvmrc() {
  local nvmrc_path="$(nvm_find_nvmrc)"

  if [ -n "$nvmrc_path" ]; then
    local nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")
    if [ "$nvmrc_node_version" = "N/A" ]; then
      nvm install
    elif [ "$nvmrc_node_version" != "$(nvm version)" ]; then
      nvm use
    fi
  elif [ "$(nvm version)" != "$(nvm version default)" ]; then
    echo "Reverting to nvm default version"
    nvm use default
  fi
}
add-zsh-hook chpwd load-nvmrc
load-nvmrc
'

    # Bash 专用的 hook 内容（通过重定义 cd 命令）
    local bash_hook_content='
# nvm auto switch (Bash) - 仅限当前目录，无 .nvmrc 时静默
nvm_auto_switch() {
  # 仅当当前目录存在 .nvmrc 时才执行后续逻辑
  if [ -f ".nvmrc" ]; then
    # 强制清洗版本号：只保留数字和小数点，过滤所有特殊字符
    local target_version=$(cat .nvmrc | tr -cd '"'"'0-9.'"'"' | head -n1)

    # 检查版本号是否有效
    if [ -z "$target_version" ]; then
      echo "[nvm] .nvmrc 格式错误，仅支持数字 + 点（如 16.20.0）"
      return 1
    fi

    # 读取当前 Node 版本和目标版本的安装状态
    local current_version=$(node -v 2>/dev/null | tr -cd '"'"'0-9.'"'"')
    local installed_version=$(nvm version "$target_version" 2>/dev/null | tr -cd '"'"'0-9.'"'"')

    # 版本未安装则自动安装
    if [ "$installed_version" = "" ]; then
      echo "[nvm] 安装 Node $target_version ..."
      nvm install "$target_version"
    # 版本不一致则切换
    elif [ "$current_version" != "$target_version" ]; then
      echo "[nvm] 切换到 Node $target_version (当前目录 .nvmrc)"
      nvm use "$target_version" > /dev/null 2>&1
    fi
  fi
  # 无 .nvmrc 时：什么都不做，不输出、不切回默认版本、无任何操作
}

# 重定义 cd 命令，仅 cd 成功时触发检查
cd() {
  builtin cd "$@"
  local exit_code=$?
  [ $exit_code -eq 0 ] && nvm_auto_switch
  return $exit_code
}

# 终端启动时，仅检查当前目录是否有 .nvmrc（无则静默）
nvm_auto_switch
'

    # 根据当前 shell 决定写入哪个文件
    local current_shell=$(ps -p $PPID -o comm= 2>/dev/null | tr -d ' ' || echo "unknown")
    if [ "$current_shell" = "zsh" ] || [ "$current_shell" = "-zsh" ]; then
        # 当前是 zsh
        if zsh_hook_exists; then
            log_info "Zsh 已配置 hook，执行 nvm use 切换当前版本"
            # zsh 已经有 hook，直接执行 nvm use
            local nvmrc_path
            nvmrc_path=$(nvm_find_nvmrc)
            if [ -n "$nvmrc_path" ]; then
                local nvmrc_node_version
                nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")
                if [ "$nvmrc_node_version" = "N/A" ]; then
                    nvm install
                elif [ "$nvmrc_node_version" != "$(nvm version)" ]; then
                    nvm use
                fi
            fi
            return 0
        fi
        # zsh 没有 hook，写入配置
        if [ ! -f "$HOME/.zshrc" ]; then
            echo "$zsh_hook_content" > "$HOME/.zshrc"
        else
            echo "$zsh_hook_content" >> "$HOME/.zshrc"
        fi
        log_info "已写入自动 nvm use hook 到 ~/.zshrc"
    elif [ "$current_shell" = "bash" ] || [ "$current_shell" = "-bash" ]; then
        # 当前是 bash
        if bash_hook_exists; then
            log_info "Bash 已配置 hook，执行 nvm auto switch 切换当前版本"
            # bash 已经有 hook，直接执行 nvm_auto_switch
            nvm_auto_switch
            return 0
        fi
        # bash 没有 hook，写入配置到 .bashrc
        echo "$bash_hook_content" >> "$HOME/.bashrc"
        log_info "已写入自动 nvm use hook 到 ~/.bashrc"

        # 同时写入 .bash_profile（确保登录 shell 也能加载）
        if [ -f "$HOME/.bash_profile" ]; then
            # 如果 .bash_profile 已存在，检查是否已包含 hook
            if ! grep -qF "# nvm auto switch (Bash)" "$HOME/.bash_profile"; then
                echo "$bash_hook_content" >> "$HOME/.bash_profile"
                log_info "已写入自动 nvm use hook 到 ~/.bash_profile"
            fi
        else
            # 如果 .bash_profile 不存在，创建它（先加载 .bashrc）
            cat > "$HOME/.bash_profile" << 'EOF'
# 加载 .bashrc
if [ -f "$HOME/.bashrc" ]; then
    source "$HOME/.bashrc"
fi

EOF
            echo "$bash_hook_content" >> "$HOME/.bash_profile"
            log_info "已创建 ~/.bash_profile 并写入自动 nvm use hook"
        fi
    else
        # 无法判断 shell 类型，尝试写入两个文件
        log_warn "无法判断当前 shell 类型，尝试同时配置 zsh 和 bash"
        if [ ! -f "$HOME/.zshrc" ]; then
            echo "$zsh_hook_content" > "$HOME/.zshrc"
        else
            echo "$zsh_hook_content" >> "$HOME/.zshrc"
        fi
        log_info "已写入自动 nvm use hook 到 ~/.zshrc"

        # bash: 写入 .bashrc
        echo "$bash_hook_content" >> "$HOME/.bashrc"
        log_info "已写入自动 nvm use hook 到 ~/.bashrc"

        # bash: 同时写入 .bash_profile
        if [ -f "$HOME/.bash_profile" ]; then
            if ! grep -qF "# nvm auto switch (Bash)" "$HOME/.bash_profile"; then
                echo "$bash_hook_content" >> "$HOME/.bash_profile"
                log_info "已写入自动 nvm use hook 到 ~/.bash_profile"
            fi
        else
            cat > "$HOME/.bash_profile" << 'EOF'
# 加载 .bashrc
if [ -f "$HOME/.bashrc" ]; then
    source "$HOME/.bashrc"
fi

EOF
            echo "$bash_hook_content" >> "$HOME/.bash_profile"
            log_info "已创建 ~/.bash_profile 并写入自动 nvm use hook"
        fi
    fi
}

# Bash 专用的 nvm_auto_switch 函数（用于 bash 已配置 hook 时直接调用）
nvm_auto_switch() {
  # 仅当当前目录存在 .nvmrc 时才执行后续逻辑
  if [ -f ".nvmrc" ]; then
    # 强制清洗版本号：只保留数字和小数点，过滤所有特殊字符
    local target_version=$(cat .nvmrc | tr -cd '0-9.' | head -n1)

    # 检查版本号是否有效
    if [ -z "$target_version" ]; then
      echo "[nvm] .nvmrc 格式错误，仅支持数字 + 点（如 16.20.0）"
      return 1
    fi

    # 读取当前 Node 版本和目标版本的安装状态
    local current_version=$(node -v 2>/dev/null | tr -cd '0-9.')
    local installed_version=$(nvm version "$target_version" 2>/dev/null | tr -cd '0-9.')

    # 版本未安装则自动安装
    if [ "$installed_version" = "" ]; then
      echo "[nvm] 安装 Node $target_version ..."
      nvm install "$target_version"
    # 版本不一致则切换
    elif [ "$current_version" != "$target_version" ]; then
      echo "[nvm] 切换到 Node $target_version (当前目录 .nvmrc)"
      nvm use "$target_version" > /dev/null 2>&1
    fi
  fi
  # 无 .nvmrc 时：什么都不做，不输出、不切回默认版本、无任何操作
}

# 主函数
main() {
    local project_dir="${1:-.}"
    local specified_version="${2:-}"

    log_info "开始检测项目 Node 版本..."
    log_info "项目目录：$(cd "$project_dir" && pwd)"

    # 如果.nvmrc 已存在，则不再执行任何逻辑
    if [ -f "$project_dir/.nvmrc" ]; then
        log_info ".nvmrc 已存在，跳过配置"
        exit 0
    fi

    # 检测所需版本
    local required_version=""
    if [ -n "$specified_version" ]; then
        required_version="$specified_version"
        log_info "使用用户指定的版本：$required_version"
    else
        required_version=$(detect_node_version "$project_dir") || true
        if [ -z "$required_version" ]; then
            log_error "无法确定项目所需的 Node 版本，请手动指定"
            echo "用法：./nvm-auto.sh [项目目录] [版本]" >&2
            exit 1
        fi
    fi

    # 优先检查同大版本已安装的最高小版本
    local use_version=$(find_matching_major_version "$required_version")
    local found_matching=$?

    if [ $found_matching -eq 0 ] && [ -n "$use_version" ]; then
        # 检查找到的版本是否就是目标版本（精确匹配）
        if [ "$use_version" = "$required_version" ] || [ "v$use_version" = "$required_version" ]; then
            log_info "Node v$use_version 已安装（精确匹配）"
        else
            log_info "找到同大版本已安装的最高版本：Node v$use_version（项目要求：v$required_version）"
            log_info "使用该版本可避免重复安装，如需精确匹配请删除已安装版本"
        fi
    else
        # 没有同大版本，需要安装
        log_warn "Node v$required_version 未安装，正在安装..."
        if ! install_version "$required_version"; then
            exit 1
        fi
        use_version="$required_version"
    fi

    # 生成.nvmrc（使用原始检测到的版本，保持项目一致性）
    create_nvmrc "$required_version" "$project_dir"

    # 切换到目标版本
    log_info "切换到 Node v$use_version..."
    cd "$project_dir"
    nvm use "$use_version"

    log_info "✅ Node 版本配置完成！"
    echo "当前 Node 版本：$(node -v)"
}

# 执行主函数
# 每次执行 script 时都执行 hook 检查和版本切换逻辑
write_shell_hook

# 然后执行主函数（配置当前项目的 Node 版本）
main "$@"
