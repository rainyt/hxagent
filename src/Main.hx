package;

import cli.LineResult;
import cli.Terminal;

/**
 * 终端 Agent 入口：读取用户输入 -> 回车提交 -> 交给 Agent 处理。
 */
class Main {
	static function main() {
		Terminal.setup(); // Windows 下切换控制台到 UTF-8，修复中文乱码

		Sys.println("hxagent - 输入内容后回车发送；Ctrl+C / Ctrl+D 退出。");
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
	 * 处理一次用户输入。
	 *
	 * TODO: 接入 agent.TaskLoop —— 把 input 作为任务交给 Agent，
	 * 通过 IApi 的流式事件回调逐步打印回复，例如：
	 *
	 *   api.chat({messages: history, tools: tools, stream: true}, function(e) switch e {
	 *       case TextDelta(t): Sys.print(t);
	 *       case Done(r):      Sys.println("");
	 *       case Error(err):   Sys.println("错误: " + err.message);
	 *       case _:
	 *   });
	 */
	static function handle(input:String):Void {
		// 占位实现：先回显，后续替换为真正的 Agent 调用。
		Sys.println("agent> " + input);
	}
}
