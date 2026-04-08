# T-Skills CLI

T-Skills 是团队内部的 AI Agent 技能包管理工具，通过 Git 私有仓库作为存储源，提供轻量级 CLI 实现技能的自动化同步和注入。

## 功能特性

- **auth** - 配置 GitHub Personal Access Token，安全存储到系统 Keyring
- **add** - 从 GitHub 仓库添加技能源，验证元数据并创建软链接
- **sync** - 遍历所有技能源执行 git pull 并刷新软链接
- **link** - 在当前项目创建 .cursorrules 指向合并的技能内容

## 安装

```bash
npm install -g t-skills-cli
```

## 使用方法

### 配置权限

```bash
t-skills auth
```

### 添加技能源

```bash
t-skills add <owner>/<repo>
```

### 同步所有技能

```bash
t-skills sync
```

### 在项目创建规则文件

```bash
t-skills link
```

## 技能包结构

每个技能仓库必须遵循以下结构：

```
<repository-root>/
├── .t-skills.yaml          # 仓库元数据
└── skills/
    └── <skill-name>/       # 技能唯一标识
        ├── skill.yaml      # 触发逻辑与描述
        ├── instruction.md  # AI 核心指令
        └── tools/          # [可选] 关联脚本或 MCP 配置
```

### 元数据格式 (.t-skills.yaml)

```yaml
version: "1.0.0"
name: "技能包名称"
skills:
  - id: "team/skill-name"
    name: "技能显示名称"
    path: "skills/skill-name"
```

### 技能配置 (skill.yaml)

```yaml
id: "team-name/skill-name"
name: "Skill Display Name"
description: "Skill description for AI matching"
version: "1.0.0"
scope:
  file_patterns: ["pattern1", "pattern2"]
  tech_stack: ["Tech1", "Tech2"]
```

## 本地技能包

本仓库 (`yuanjing/skills`) 是 T-Skills 的示例技能包，包含以下可用技能：

| Skill 名称         | 描述                                                                                                                                                                             | 使用场景                                                                                                                                           |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| [nvm-auto](skills/nvm-auto/) | 自动化配置 Node 版本：检测项目所需版本，优先使用同大版本已安装的最高小版本，缺失则安装并生成 .nvmrc。每次执行自动检查并安装 shell hook（zsh/bash），之后 cd 进项目自动切换版本。 | 当用户提到 nvm、Node 版本、.nvmrc、进入新项目需要配置环境时，使用此技能。**直接执行 `bash nvm-auto.sh`，不要重写脚本逻辑或逐步执行命令。** |

## 贡献

欢迎贡献新技能或改进现有技能！