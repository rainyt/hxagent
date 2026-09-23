package;

import agent.AgentEvent;
import agent.TaskLoop;
import agent.TaskLoopOptions;
import ai.Provider;
import api.IApi;
import api.tools.Read;
import api.tools.ToolRegistry;
import api.tools.Write;
import api.tools.Edit;
import api.tools.Find;
import api.tools.Bash;
import api.tools.Tree;
import cli.LineResult;
import cli.Terminal;
import config.Config;

/**
 * 终端 Agent 入口：读取输入 -> TaskLoop（含工具调用闭环）-> 流式展示过程。
 * API 平台 / 密钥 / 模型等均来自 .hxagent/config.json。
 */
class Main {
	/** ANSI 转义符。 */
	static var ESC = String.fromCharCode(27);

	static var taskLoop:TaskLoop;

	static function main() {
		Terminal.setup(); // Windows 下切换控制台到 UTF-8，修复中文乱码

		// ---- 加载配置 ----
		var config:Config = null;
		try {
			config = Config.load();
		} catch (e:haxe.Exception) {
			Sys.println("配置错误: " + e.message);
			return;
		}
		if (config == null) {
			Sys.println("未找到配置文件，请创建: " + Config.defaultPath());
			Sys.println('示例: {"provider":"deepseek","deepseek":{"api_key":"sk-xxx"}}');
			return;
		}
		if (config.apiKey() == null || config.apiKey() == "") {
			Sys.println('警告: 平台 "${config.provider}" 未配置 api_key。');
		}

		// ---- 按平台创建 API ----
		var api:IApi;
		try {
			api = Provider.create(config);
		} catch (e:haxe.Exception) {
			Sys.println("初始化失败: " + e.message);
			return;
		}

		// ---- 注册工具 + 组装循环 ----
		var tools = new ToolRegistry().add(new Read()).add(new Write()).add(new Edit()).add(new Find()).add(new Bash()).add(new Tree());
		taskLoop = new TaskLoop(api, tools, {
			systemPrompt: config.systemPrompt(),
			model: config.model(),
			temperature: config.temperature(),
			maxTokens: config.maxTokens(),
			maxIterations: config.maxIterations()
		});

		var modelName = config.model();
		Sys.println('hxagent - 平台: ${config.provider}，模型: ${modelName != null ? modelName : "默认"}');
		Sys.println("输入内容后回车发送；/reset 清空上下文；Ctrl+C / Ctrl+D 退出。");
		Sys.println("");

		while (true) {
			switch (Terminal.readLine("you> ")) {
				case Line(text):
					var input = StringTools.trim(text);
					if (input == "")
						continue;

					switch (input) {
						case "/exit", "/quit":
							Sys.println("bye");
							break;
						case "/clear":
							Terminal.clear();
						case "/reset":
							taskLoop.reset();
							Sys.println("已清空上下文。");
						case "/diag":
							Sys.println(Bash.diagnose());
						default:
							handle(input);
					}

				case Eof:
					Sys.println("已退出（EOF）。");
					break;

				case Interrupt:
					Sys.println("已中断。");
					break;
			}
		}
	}

	/**
	 * 执行一轮：打印 Agent 的正文 / 思考 / 工具调用过程与最终回答。
	 */
	static function handle(input:String):Void {
		var gray = false;
		var needPrompt = false;

		function closeGray():Void {
			if (gray) {
				Sys.print(ESC + "[0m");
				gray = false;
			}
		}

		function continuePrompt():Void {
			if (needPrompt) {
				Sys.print("agent> ");
				needPrompt = false;
			}
		}

		Sys.print("agent> ");

		taskLoop.run(input, function(ev) {
			switch ev {
				case ReasoningDelta(t):
					continuePrompt();
					if (!gray) {
						Sys.print(ESC + "[90m"); // 灰色
						gray = true;
					}
					Sys.print(t);

				case TextDelta(t):
					closeGray();
					continuePrompt();
					Sys.print(t);

				case ToolCallStarted(name, args):
					closeGray();
					Sys.println("");
					Sys.println(ESC + "[36m  [工具] " + name + " " + haxe.Json.stringify(args) + ESC + "[0m");

				case ToolCallResult(name, callId, result):
					var preview = result.content != null ? result.content : "";
					if (preview.length > 160)
						preview = preview.substr(0, 160) + " ...";
					preview = StringTools.replace(StringTools.replace(preview, "\r", ""), "\n", " \u23ce ");
					Sys.println(ESC + "[90m  [结果] " + preview + ESC + "[0m");
					needPrompt = true;

				case Done(content, usage):
					closeGray();
					Sys.println("");
					if (usage != null)
						Sys.println(ESC + "[90m  [token " + usage.promptTokens + "+" + usage.completionTokens
							+ "=" + usage.totalTokens + "]" + ESC + "[0m");

				case Error(err):
					closeGray();
					Sys.println("");
					Sys.println("错误: " + err.message
						+ (err.status != null && err.status > 0 ? " (HTTP " + err.status + ")" : ""));
			}
		});
	}
}
