package;

import ai.deepseek.Deepseek;
import api.IApi;
import api.Message;
import api.Messages;
import cli.LineResult;
import cli.Terminal;

/**
 * 终端 Agent 入口：读取用户输入 -> 回车提交 -> 交给 DeepSeek 流式回复。
 */
class Main {
	/** ANSI 转义符（用于灰色显示推理过程）。 */
	static var ESC = String.fromCharCode(27);

	static var api:IApi;
	static var history:Array<Message> = [];

	static function main() {
		Terminal.setup(); // Windows 下切换控制台到 UTF-8，修复中文乱码

		var model = Sys.getEnv("DEEPSEEK_MODEL");
		api = new Deepseek({
			defaultModel: model != null ? model : "deepseek-chat",
			apiKey: "sk-5c311a3bb0be4289bb25380358cd53e3"
		});

		var key = Sys.getEnv("DEEPSEEK_API_KEY");
		if (key == null || key == "") {
			Sys.println("提示: 未设置 DEEPSEEK_API_KEY 环境变量，请求会返回 401。");
		}

		history.push(Messages.system("你是一个简洁的终端 AI 助手，请用中文回答。"));

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
							history = [Messages.system("你是一个简洁的终端 AI 助手，请用中文回答。")];
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
	 * 处理一次用户输入：追加到历史，调用 DeepSeek 并流式打印。
	 * 注：chat() 是同步阻塞的，事件在调用期间逐条回调。
	 */
	static function handle(input:String):Void {
		history.push(Messages.user(input));
		Sys.print("agent> ");

		var reasoningStarted = false;
		var textStarted = false;
		var finished = false;

		api.chat({messages: history, stream: true}, function(e) switch e {
			case Start(_, _):
			// 忽略

			case ReasoningDelta(t):
				if (!reasoningStarted) {
					reasoningStarted = true;
					Sys.print(ESC + "[90m"); // 灰色
				}
				Sys.print(t);

			case TextDelta(t):
				if (reasoningStarted && !textStarted) {
					Sys.print(ESC + "[0m"); // 结束灰色
					Sys.println("");
				}
				textStarted = true;
				Sys.print(t);

			case ToolCallDelta(_, _, _, _):
			// 测试阶段暂不处理工具调用

			case Done(r):
				finished = true;
				Sys.print(ESC + "[0m");
				Sys.println("");
				history.push(r.message);
				if (r.usage != null) {
					Sys.println(ESC + "[90m[token " + r.usage.promptTokens + "+" + r.usage.completionTokens
						+ "=" + r.usage.totalTokens + "]" + ESC + "[0m");
				}

			case Error(err):
				finished = true;
				Sys.print(ESC + "[0m");
				Sys.println("");
				Sys.println("错误: " + err.message
					+ (err.status != null && err.status > 0 ? " (HTTP " + err.status + ")" : ""));
				// 调用失败则回滚本轮用户消息，避免污染上下文
				history.pop();
		});

		if (!finished)
			Sys.println("");
	}
}
