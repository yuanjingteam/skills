---
name: nvm-auto
description: 自动化配置 Node 版本：检测项目所需版本，优先使用同大版本已安装的最高小版本，缺失则安装并生成 .nvmrc。每次执行自动检查并安装 shell hook（zsh/bash），之后 cd 进项目自动切换版本。当用户提到 nvm、Node 版本、.nvmrc、进入新项目需要配置环境时，使用此技能。**直接执行 `bash nvm-auto.sh`，不要重写脚本逻辑或逐步执行命令。**
---

# NVM 自动化技能

## 使用方法

**执行命令（必须）：**
```bash
cd <项目目录> && bash $HOME/.claude/skills/nvm-auto/nvm-auto.sh
```

**禁止：**
- 不要逐步执行 grep、cat、nvm ls 等单个命令
- 不要重写脚本逻辑
- 只执行上述一条命令即可完成所有操作

## 技能目标

帮助用户在新项目目录下自动配置 Node.js 版本，替代手动执行 `nvm use` / `nvm install` 的重复操作。

## 核心功能

1. **检测项目所需 Node 版本** - 从多个配置源获取
2. **对比本地已安装版本** - 检查 nvm 已安装列表
3. **自动安装缺失版本** - 调用 nvm install
4. **生成 .nvmrc 文件** - 在项目根目录创建版本锁定
5. **自动安装 shell hook** - 每次执行时自动检查并安装 shell hook（支持 zsh 和 bash），之后 cd 进项目自动切换版本

## 版本检测优先级

按以下顺序查找 Node 版本（找到即停止）：

1. `.nvmrc` - 已存在的 nvmrc 文件
2. `.node-version` - 另一种常见的版本文件
3. `package.json` - `engines.node` 字段
4. 用户指定的版本

## Shell 脚本实现

创建脚本 `nvm-auto.sh`：

```bash
#!/bin/bash

# nvm-auto.sh - Node 版本管理自动化脚本

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
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
    local has_node20_deps=$(grep -E '"@types/node":\s*"[^"]*2[0-9]' "$project_dir/package.json" 2>/dev/null)
    if [ -n "$has_node20_deps" ]; then
        log_info "从 @types/node 推断：建议使用 Node 20.x"
        echo "20"
        return 0
    fi

    # 检查是否有针对 Node 18+ 的依赖
    local has_node18_deps=$(grep -E '"@types/node":\s*"[^"]*1[89]|[2-9][0-9]' "$project_dir/package.json" 2>/dev/null)
    if [ -n "$has_node18_deps" ]; then
        log_info "从依赖推断：建议使用 Node 18.x"
        echo "18"
        return 0
    fi

    # 默认推荐 LTS 版本
    log_info "未检测到版本线索，使用 Node 18.x (LTS)"
    echo "18"
    return 0
}

# 获取本地已安装的最新稳定版本
get_latest_installed_version() {
    local installed_versions=$(nvm ls --no-colors 2>/dev/null)

    # 过滤出稳定版本（排除 iojs、lts/* 等），取最新的
    local latest_version=$(echo "$installed_versions" \
        | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' \
        | grep -v '^v0\.' \
        | sort -t. -k1,1nr -k2,2nr -k3,3nr \
        | head -1)

    if [ -n "$latest_version" ]; then
        echo "$latest_version" | sed 's/^v//'
        return 0
    fi
    return 1
}

# 检测项目所需 Node 版本（增强版：支持降级推断）
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
        version=$(infer_version_from_deps "$project_dir")
        if [ $? -eq 0 ] && [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    fi

    # 5. 使用本地已安装的最新版本
    log_warn "无法检测项目版本要求，使用本地已安装的最新版本"
    version=$(get_latest_installed_version)
    if [ $? -eq 0 ] && [ -n "$version" ]; then
        echo "$version"
        return 0
    fi

    log_error "无法确定项目所需的 Node 版本，请手动指定"
    echo "用法：./nvm-auto.sh [项目目录] [版本]"
    return 1
}

# 提取大版本号（如 v18.16.0 -> 18）
get_major_version() {
    local version="$1"
    # 去掉 v 前缀，提取第一个数字
    echo "$version" | sed 's/^v//' | cut -d'.' -f1
}

# 检查版本是否已安装（精确匹配）
is_version_installed() {
    local target_version="$1"
    local installed_versions=$(nvm ls --no-colors 2>/dev/null)

    # 检查是否包含目标版本
    if echo "$installed_versions" | grep -qE "v?$target_version(\.|$)"; then
        return 0
    fi
    return 1
}

# 查找同大版本已安装的最高小版本
find_matching_major_version() {
    local target_version="$1"
    local target_major=$(get_major_version "$target_version")
    local installed_versions=$(nvm ls --no-colors 2>/dev/null)

    # 过滤出同大版本的已安装版本，按版本号排序，取最高的
    local matching_version=$(echo "$installed_versions" \
        | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' \
        | while read ver; do
            major=$(get_major_version "$ver")
            if [ "$major" = "$target_major" ]; then
                echo "$ver"
            fi
        done \
        | sort -t. -k1,1nr -k2,2nr -k3,3nr \
        | head -1)

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
    nvm install "$version"
    if [ $? -eq 0 ]; then
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

# 主函数
main() {
    local project_dir="${1:-.}"
    local specified_version="${2:-}"

    log_info "开始检测项目 Node 版本..."
    log_info "项目目录：$(cd "$project_dir" && pwd)"

    # 检测所需版本
    local required_version=""
    if [ -n "$specified_version" ]; then
        required_version="$specified_version"
        log_info "使用用户指定的版本：$required_version"
    else
        required_version=$(detect_node_version "$project_dir")
        if [ $? -ne 0 ] || [ -z "$required_version" ]; then
            log_error "无法确定项目所需的 Node 版本，请手动指定"
            echo "用法：./nvm-auto.sh [项目目录] [版本]"
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
        install_version "$required_version"
        if [ $? -ne 0 ]; then
            exit 1
        fi
        use_version="$required_version"
    fi

    # 生成/更新 .nvmrc（使用原始检测到的版本，保持项目一致性）
    if [ ! -f "$project_dir/.nvmrc" ]; then
        create_nvmrc "$required_version" "$project_dir"
    fi

    # 切换到目标版本
    log_info "切换到 Node v$use_version..."
    cd "$project_dir"
    nvm use "$use_version"

    log_info "✅ Node 版本配置完成！"
    echo "当前 Node 版本：$(node -v)"
}

# 执行主函数
main "$@"
```

## 使用方法

## 使用方法

### 基础用法

```bash
# 在当前目录运行
./nvm-auto.sh

# 指定项目目录
./nvm-auto.sh /path/to/project

# 指定版本（当无法自动检测时）
./nvm-auto.sh . 18.16.0
```

### 自动切换 hook（每次执行自动配置）

每次执行脚本时会自动检查并安装 shell hook：

- **Zsh**: 如果 `~/.zshrc` 已有 hook，直接执行 `nvm use` 切换当前版本
- **Bash**: 如果 `~/.bashrc` 已有 hook，直接执行 `nvm use` 切换当前版本

```bash
# 执行 skill 时自动配置 hook 并切换版本
./nvm-auto.sh

# 重新加载配置（首次执行后）
source ~/.zshrc   # zsh 用户
# 或
source ~/.bashrc  # bash 用户

# 之后进入任何项目目录自动切换 Node 版本
cd /path/to/project  # 自动检测 .nvmrc 并切换
```

### 集成到工作流

```bash
# 或使用 autoenv
echo "nvm-auto.sh" > .envrc
```

## 注意事项

1. **依赖 nvm** - 确保已安装 nvm：`curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash`
2. **脚本权限** - `chmod +x nvm-auto.sh`
3. **每次执行自动配置** - 脚本每次执行时都会检查 shell hook 是否已安装
4. **Zsh 已有 hook** - 如果 `~/.zshrc` 已有 hook 标记，直接执行 `nvm use` 切换版本
5. **Bash 已有 hook** - 如果 `~/.bashrc` 或 `~/.bash_profile` 已有 hook 标记，直接执行 `nvm use` 切换版本
6. **版本号格式** - 支持 `18`、`18.16`、`18.16.0`、`v18.16.0` 等格式
7. **package.json 解析** - 会清理 `^`、`~`、`>=` 等前缀
8. **大版本匹配** - 优先使用本地已安装的同大版本最高小版本（如项目要求 `16.14.0`，本地有 `16.18.0`，则直接使用 `16.18.0`）
9. **.nvmrc 内容** - 生成的 `.nvmrc` 保留原始检测到的版本号，保持项目一致性
10. **Shell 支持** - 自动识别 zsh 和 bash，写入对应的配置文件

## 扩展建议

- 添加 `--dry-run` 预览模式
- 添加 `.gitignore` 自动配置
- 支持 LTS 版本别名（如 `lts/hydrogen`）
- 添加版本冲突检测
