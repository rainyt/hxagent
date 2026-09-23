package;

import agent.AgentEvent;
import agent.TaskLoop;
import agent.TaskLoopOptions;
import ai.deepseek.Deepseek;
import api.IApi;
import api.tools.Read;
import api.tools.ToolRegistry;
import cli.LineResult;
import cli.Terminal;

/**
 * 终端 Agent 入口：读取用户输入 -> 交给 TaskLoop（含工具调用闭环）-> 流式展示过程。
 */
class Main {
	/** ANSI 转义符。 */
	static var ESC = String.fromCharCode(27);

	static var taskLoop:TaskLoop;

	static function main() {
		Terminal.setup(); // Windows 下切换控制台到 UTF-8，修复中文乱码

		var model = Sys.getEnv("DEEPSEEK_MODEL");
		var api:IApi = new Deepseek({
			defaultModel: model != null ? model : "deepseek-v4-flash"
		});

		var tools = new ToolRegistry().add(new Read());
		taskLoop = new TaskLoop(api, tools, {
			systemPrompt: "你是一个运行在终端里的 AI 助手。需要查看本机文件时请调用 Read 工具，再根据内容回答。请用中文简洁回答。"
		});

		var key = Sys.getEnv("DEEPSEEK_API_KEY");
		if (key == null || key == "") {
			Sys.println("提示: 未设置 DEEPSEEK_API_KEY 环境变量，请求会返回 401。");
		}

		Sys.println("hxagent - 输入内容后回车发送；/reset 清空上下文；Ctrl+C / Ctrl+D 退出。");
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
