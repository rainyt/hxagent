# hxagent

用 Haxe 写的命令行 AI Agent：在终端里和模型对话，模型可以**调用本机工具**（读文件、写文件、精确替换、按名查找、看目录树、执行命令）来完成任务。

- 目标平台：`--interp`（Haxe eval），纯标准库实现，无第三方依赖、无需编译产物。
- 当前适配平台：**DeepSeek**（OpenAI 兼容协议）。通过 `IApi` 接口 + `Provider` 工厂，新增平台只需加一个适配器。
- 交互：流式输出正文与推理内容，工具调用过程实时展示，支持多轮工具闭环。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| Haxe | 4.3.7 及以上（开发使用 4.3.7） |
| 网络 | 能访问模型 API（如 `https://api.deepseek.com`） |
| Windows 额外要求 | 建议使用 Windows Terminal / UTF-8 控制台；`Bash` 工具依赖 **Git Bash**（`bash` 需在 `PATH` 中，找不到会明确报错） |

## 快速开始

1. 准备配置（密钥不要提交到仓库，`config.json` 已在 `.gitignore` 中）：

```bash
mkdir -p .hxagent
cp .hxagent/config.example.json .hxagent/config.json
# 然后把 config.json 里的 api_key 换成你自己的
```

2. 运行：

```bash
haxe build.hxml
```

`build.hxml` 内容很简单：

```hxml
--main Main
--class-path src
--interp
```

也可以直接 `haxe --main Main --class-path src --interp`。

3. 开始对话：

```
hxagent - 平台: deepseek，模型: deepseek-chat
输入内容后回车发送；/reset 清空上下文；Ctrl+C / Ctrl+D 退出。

you> 帮我看看 src 目录下有哪些工具
agent> ...
  [工具] Find {"pattern":"*.hx","path":"src/api/tools"}
  [结果] F src/api/tools/Read.hx ...
```

## 配置

默认读取**当前工作目录**下的 `.hxagent/config.json`（key 同时兼容 `snake_case` 与 `camelCase`，不读取任何环境变量）：

```json
{
  "provider": "deepseek",
  "deepseek": {
    "api_key": "sk-your-deepseek-api-key",
    "base_url": "https://api.deepseek.com",
    "model": "deepseek-chat",
    "temperature": 1.0,
    "max_tokens": 100000,
    "timeout_ms": 0,
    "max_retries": 2,
    "headers": { "X-Custom": "v" },
    "organization": "org-xxx"
  },
  "agent": {
    "system_prompt": "你是一个运行在终端里的 AI 助手…",
    "max_iterations": 10
  }
}
```

平台节字段：

| 字段 | 说明 |
| --- | --- |
| `api_key` | 鉴权密钥（必填） |
| `base_url` | API 根地址，默认 `https://api.deepseek.com` |
| `model` | 默认模型，请求未指定时使用 |
| `temperature` / `max_tokens` | 采样参数 |
| `timeout_ms` | 单次请求超时；`<= 0` 表示不超时（长任务 / 流式推荐） |
| `max_retries` | 可重试错误的重试次数 |
| `headers` / `organization` | 额外请求头、组织标识 |

`agent` 节（不分平台）：

| 字段 | 说明 |
| --- | --- |
| `system_prompt` | 系统提示词；运行时会自动追加「运行环境」信息（OS、工作目录、日期、可用工具） |
| `max_iterations` | 单回合内最多工具调用轮次，默认 10，防止死循环 |

## 内置工具

| 工具 | 作用 | 主要参数 |
| --- | --- | --- |
| `Read` | 读取文本文件，返回带行号内容，可分段 | `path`、`offset`、`limit` |
| `Write` | 写入文件，默认覆盖，可追加、可自动建父目录 | `path`、`content`、`append`、`create_dirs` |
| `Edit` | 精确字符串替换，默认要求唯一匹配 | `path`、`old_string`、`new_string`、`replace_all` |
| `Find` | 按名称查文件 / 目录，逐层 BFS，最大 6 层 | `pattern`、`path`、`max_depth`、`type`、`limit`、`include_hidden` |
| `Tree` | 树状展示目录布局，适合「看整体」 | `path`、`max_depth`、`dirs_only`、`show_size`、`ignore`、`limit` |
| `Bash` | 执行一条命令行，返回合并输出与退出码 | `command`、`cwd`、`timeout_ms`（默认 30s，超时退出码 124） |

约定与保护：

- 工具统一返回 `ToolResult{content, isError}`，错误以文本回填给模型，模型可自行重试或调整；未知工具、执行异常都不会让 Agent 崩溃。
- 输出有上限（`Read` 单次约 256 KB、`Bash` 约 64 KB），超出截断，避免撑爆上下文。
- `HXAGENT_DEBUG=1` 可打开 `Bash` 工具的调试日志（写入 stderr）。

## 交互命令

| 命令 | 说明 |
| --- | --- |
| 任意文本 | 发送给 Agent（进入工具闭环，直到得到最终回答） |
| `/reset` | 清空对话上下文（保留系统提示词） |
| `/clear` | 清屏 |
| `/diag` | 打印 `Bash` 工具的环境诊断信息（bash 路径等） |
| `/exit`、`/quit` | 退出 |
| `Ctrl+C` / `Ctrl+D` | 退出 |

## 项目结构

```
hxagent/
├── build.hxml                 # 构建入口（--interp）
├── .hxagent/
│   ├── config.example.json    # 配置模板
│   └── config.json            # 本地配置（含密钥，不提交）
└── src/
    ├── Main.hx                # 入口：读配置 -> 组装 Tools/TaskLoop -> 终端交互
    ├── agent/                 # Agent 循环
    │   ├── TaskLoop.hx        # 模型回复 ⇄ 工具执行的闭环驱动
    │   ├── TaskLoopOptions.hx # 循环参数（systemPrompt/model/maxIterations…）
    │   └── AgentEvent.hx      # 对外事件：正文/推理/工具开始/工具结果/Done/Error
    ├── ai/
    │   ├── Provider.hx        # 平台工厂：provider -> IApi
    │   └── deepseek/
    │       ├── Deepseek.hx    # DeepSeek 适配（SSE 流式、Function Calling、reasoning_content）
    │       └── RawHttp.hx     # 拷贝自 std 的 sys.Http，修复 eval 上 chunked+多字节解码问题
    ├── api/                   # 厂商无关的协议层
    │   ├── IApi.hx / ChatRequest.hx / ChatResponse.hx / StreamEvent.hx
    │   ├── Message.hx / Messages.hx / Role.hx / ToolCall.hx / Usage.hx …
    │   ├── ApiConfig.hx / ApiResult.hx / ApiError.hx / Cancelable.hx
    │   └── tools/             # 工具实现 + ToolRegistry + ITool/ToolResult
    ├── cli/                   # 终端行输入（Windows 编码处理）与结果类型
    ├── config/Config.hx       # .hxagent/config.json 读取
    └── util/Utf8.hx           # 宽容 UTF-8 解码（非法字节替换为 U+FFFD）
```

## 架构说明

数据流：

```
Main ──► TaskLoop ──► IApi.chat(Deepseek) ──► 事件回调 ──► AgentEvent ──► 终端渲染
             │                    ▲
             └──► ToolRegistry ───┘  （工具结果以 role=tool 回填历史，再次请求模型）
```

`TaskLoop.run()` 的闭环：

1. 把用户消息追加到历史；
2. 调用 `IApi.chat()`，流式转发 `ReasoningDelta` / `TextDelta`；
3. 若 `finish_reason == tool_calls`：按顺序执行工具，每个结果作为 `role=tool` 消息回填历史，回到第 2 步；
4. 否则视为最终回答，发出 `Done`（附 `usage`）；超过 `max_iterations` 则报错停止。

设计约定：

- `IApi` 不抛异常，失败一律通过 `Error` 事件 / `ApiResult` 返回，且只使用厂商无关类型，协议差异由各适配器承担。
- 当前 `chat()` 在 eval 上是**同步阻塞**的，因此 `run()` 会阻塞到整轮结束，期间靠回调逐步推送；返回的 `Cancelable` 只能在回调内部（同线程）取消。
- `deepseek/RawHttp.hx` 是 std `sys/Http` 的拷贝，只是把 chunk 解码改成 `Utf8.safe()`，修复中文 SSE 被 chunk 边界劈开时的 `Invalid string`；上游修复后可删除。
- 终端输入默认走 `stdin` 字节读取（`Sys.getChar` 在中文 Windows 控制台会按 GBK 返回字节导致乱码），启动时把控制台切到 UTF-8。

## 扩展新的 AI 平台

1. 在 `src/ai/<platform>/` 下实现 `IApi`（`chat` / `listModels` / `dispose`），参考 `Deepseek.hx`；
2. 在 `ai/Provider.hx` 的 `switch` 中加一个分支，并把它加入 `supported()`；
3. 在 `.hxagent/config.json` 里加同名平台配置节，并把 `provider` 指过去。

```haxe
case "openai":
    new OpenAi(apiCfg);
```

## 已知限制

- 只有 `--interp` 目标在使用和维护；没有生成可执行文件的构建配置。
- `chat()` 同步阻塞，长回答期间无法中途打断（`Ctrl+C` 会终止进程）。
- `Bash` 工具仅支持 bash（非 POSIX shell / cmd / PowerShell），依赖系统里存在 `bash`。
- 暂无会话持久化：上下文只在内存中，退出即丢失；`/reset` 会清空。
