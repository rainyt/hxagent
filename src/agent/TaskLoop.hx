package agent;

import api.ChatRequest;
import api.FinishReason;
import api.IApi;
import api.Message;
import api.Messages;
import api.ToolCall;
import api.ToolDefinition;
import api.Usage;
import api.tools.ToolRegistry;

/**
 * 任务循环：驱动「模型回复 →（若请求工具）执行工具并回填结果 → 再次请求模型」
 * 直到模型给出最终答案。这就是工具调用的闭环。
 *
 * 流程：
 * 1. 追加用户消息到历史；
 * 2. 调用 `IApi.chat`，流式转发正文 / 推理；
 * 3. 若 `finish_reason == tool_calls`：依次执行工具，把每个结果作为
 *    `role=tool` 消息追加到历史，回到第 2 步；
 * 4. 否则视为最终回答，发出 Done。
 *
 * 注意：`IApi.chat` 在本项目当前实现中是同步阻塞的，因此 `run()` 会阻塞到
 * 整轮结束；期间通过 `onEvent` 回调逐步推送。
 */
class TaskLoop {
	static inline var DEFAULT_MAX_ITERATIONS = 10;
	static inline var DEFAULT_SYSTEM_PROMPT = "你是一个运行在终端里的 AI 助手，可以使用工具读取/修改本机文件、执行命令。请用中文简洁回答。";

	var api:IApi;
	var tools:ToolRegistry;
	var options:TaskLoopOptions;
	var history:Array<Message>;
	var toolDefs:Array<ToolDefinition>;

	public function new(api:IApi, ?tools:ToolRegistry, ?options:TaskLoopOptions) {
		this.api = api;
		this.tools = tools != null ? tools : new ToolRegistry();
		this.options = options != null ? options : {};
		this.toolDefs = this.tools.definitions();
		reset();
	}

	/** 清空上下文，仅保留 system prompt（含运行环境信息）。 */
	public function reset():Void {
		var base = options.systemPrompt != null ? options.systemPrompt : DEFAULT_SYSTEM_PROMPT;
		history = [Messages.system(base + "\n\n" + environmentInfo())];
	}

	/** 组装当前运行环境参数，追加到 system prompt 末尾。 */
	function environmentInfo():String {
		var cwd = normalizePath(Sys.getCwd());
		var d = Date.now();
		var sb = new StringBuf();
		sb.add("## 运行环境");
		sb.add("\n- 操作系统: " + Sys.systemName());
		sb.add("\n- 当前工作目录: " + cwd);
		sb.add("\n- 路径风格: 统一使用 / 作为分隔符（例如 " + cwd + "/src）");
		sb.add("\n- 当前日期: " + d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate()));
		if (Sys.systemName() == "Windows")
			sb.add("\n- 备注: Windows 环境；Bash 工具依赖 Git Bash（bash 需在 PATH 中）。");
		if (toolDefs != null && toolDefs.length > 0) {
			var names = [for (t in toolDefs) t.name];
			sb.add("\n- 可用工具: " + names.join(", "));
		}
		return sb.toString();
	}

	static inline function normalizePath(p:String):String {
		var s = StringTools.replace(p, "\\", "/");
		while (s.length > 1 && s.charAt(s.length - 1) == "/" && s.charAt(s.length - 2) != ":")
			s = s.substr(0, s.length - 1);
		return s;
	}

	static function pad2(n:Int):String {
		return n < 10 ? "0" + n : "" + n;
	}

	public function getHistory():Array<Message> {
		return history;
	}

	/**
	 * 执行一轮用户请求，直到产出最终回答或达到最大工具轮次。
	 * @param userInput 用户输入
	 * @param onEvent 事件回调（正文 / 推理 / 工具 / 结束 / 错误）
	 */
	public function run(userInput:String, onEvent:AgentEvent->Void):Void {
		history.push(Messages.user(userInput));

		var maxIterations = options.maxIterations != null ? options.maxIterations : DEFAULT_MAX_ITERATIONS;
		var iteration = 0;

		while (true) {
			if (iteration >= maxIterations) {
				onEvent(AgentEvent.Error({
					message: '达到最大工具调用轮次 ($maxIterations)，已停止。',
					retryable: false
				}));
				return;
			}

			var pendingCalls:Array<ToolCall> = null;
			var finalContent:String = null;
			var usage:Usage = null;
			var failed = false;

			var request:ChatRequest = {
				messages: history,
				stream: true,
				tools: toolDefs.length > 0 ? toolDefs : null,
				model: options.model,
				temperature: options.temperature,
				maxTokens: options.maxTokens
			};

			try {
			api.chat(request, function(e) switch e {
				case Start(_, _):
				// 忽略
				case ReasoningDelta(t):
					onEvent(AgentEvent.ReasoningDelta(t));
				case TextDelta(t):
					onEvent(AgentEvent.TextDelta(t));
				case ToolCallDelta(_, _, _, _):
					// 使用 Done 中聚合好的完整 ToolCall，忽略增量
				case Done(r):
					usage = r.usage;
					history.push(r.message);
					if (r.finishReason == FinishReason.ToolCalls
						&& r.message.toolCalls != null
						&& r.message.toolCalls.length > 0) {
						pendingCalls = r.message.toolCalls;
					} else {
						finalContent = r.message.content != null ? r.message.content : "";
					}
				case Error(err):
					failed = true;
					onEvent(AgentEvent.Error(err));
			});
			} catch (e:Dynamic) {
				// 兜底：任何适配器抛出的异常（超时/网络等）都不应让整个 Agent 崩掉
				failed = true;
				onEvent(AgentEvent.Error({
					message: "请求异常: " + Std.string(e),
					retryable: false
				}));
			}

			if (failed)
				return;

			// 没有工具调用 -> 最终回答
			if (pendingCalls == null) {
				onEvent(AgentEvent.Done(finalContent != null ? finalContent : "", usage));
				return;
			}

			// 执行工具并把结果回填到历史
			for (call in pendingCalls) {
				onEvent(AgentEvent.ToolCallStarted(call.name, call.arguments));
				var result = tools.call(call.name, call.arguments);
				onEvent(AgentEvent.ToolCallResult(call.name, call.id, result));
				history.push(Messages.tool(call.id, result.content));
			}

			iteration++;
		}
	}
}
