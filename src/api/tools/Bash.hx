package api.tools;

import api.ToolDefinition;
import haxe.io.Bytes;
import sys.io.Process;

/**
 * Bash 工具：执行一条 POSIX shell 命令行，返回合并后的输出与退出码，供 AI 运行测试、构建、git 等。
 *
 * 参数（JSON Schema）：
 *  - command    string   要执行的命令 —— 必填
 *  - cwd        string   可选：工作目录
 *  - timeout_ms integer  超时毫秒，默认 30000；<= 0 表示不超时
 *
 * 设计说明（针对本项目 --interp/eval 目标）：
 *  - eval 的线程是协作式的，无法用后台线程中断阻塞读，因此**超时在 shell 内实现**：
 *    命令放到 `( … ) &` 子进程里，借助 `set -m` 进程组 + `sleep`/`kill` 整组终止（OS 级，可靠）。
 *  - 用 `exec 2>&1` 把 stderr 合并进 stdout，只读一路管道，避免读写两路导致死锁。
 *  - 超时以退出码 124 标识。
 *  - **仅支持 bash**（Windows 上需 Git Bash/msys 提供的 bash）；找不到 bash 会明确报错。
 */
class Bash implements ITool {
	public static inline var NAME = "Bash";

	static inline var DEFAULT_TIMEOUT = 30000;
	/** 输出上限（字节），超出会截断。 */
	static inline var MAX_OUTPUT = 64 * 1024;

	static var bashAvailable:Null<Bool> = null;

	public var definition:ToolDefinition;

	public function new() {
		definition = {
			name: NAME,
			description: "执行一条命令行并返回合并后的输出与退出码。使用 bash；带超时保护（默认 30 秒，在 shell 内整组终止）。"
				+ "仅支持 bash（Windows 需 Git Bash）。",
			parameters: {
				type: "object",
				properties: {
					command: {type: "string", description: "要执行的命令"},
					cwd: {type: "string", description: "可选：工作目录"},
					timeout_ms: {type: "integer", description: "超时毫秒，默认 " + DEFAULT_TIMEOUT + "，<=0 表示不限时"}
				},
				required: ["command"]
			}
		};
	}

	public function execute(args:Dynamic):ToolResult {
		if (args == null)
			return fail("缺少参数");

		var command:String = args.command != null ? Std.string(args.command) : null;
		if (command == null || StringTools.trim(command) == "")
			return fail("缺少 command 参数");

		var timeoutMs = intArg(pick(args, ["timeout_ms", "timeoutMs"]), DEFAULT_TIMEOUT);
		if (timeoutMs < 0) timeoutMs = 0;
		var cwd:String = args.cwd != null ? Std.string(args.cwd) : null;
		if (!hasBash())
			return fail("未找到 bash。本工具依赖 bash（Windows 上请安装 Git Bash 并确保其在 PATH 中）。");

		var script = buildScript(command, cwd, timeoutMs);

		var proc:Process;
		try {
			proc = new Process("bash", ["-c", script]);
		} catch (e:Dynamic) {
			return fail('无法启动 bash: ' + Std.string(e));
		}

		// stderr 已在脚本内合并到 stdout，只需读一路，不会死锁
		var output = "";
		try {
			output = proc.stdout.readAll().toString();
		} catch (e:Dynamic) {}

		var code = 0;
		try {
			code = proc.exitCode();
		} catch (e:Dynamic) {}
		try proc.close() catch (e:Dynamic) {};

		var timedOut = code == 124;

		return {
			content: render(output, code, timedOut, timeoutMs),
			isError: timedOut
		};
	}

	// ------------------------------------------------------------------
	// 脚本构造
	// ------------------------------------------------------------------

	static function buildScript(command:String, cwd:String, timeoutMs:Int):String {
		var sb = new StringBuf();
		sb.add("exec 2>&1\n"); // 合并 stderr 到 stdout，避免只读一路导致死锁
		sb.add("set -m\n"); // 后台任务各自成进程组，便于超时整组杀死

		if (cwd != null && StringTools.trim(cwd) != "")
			sb.add("cd " + shQuote(cwd) + " || exit 1\n");

		if (timeoutMs > 0) {
			var secs = timeoutMs / 1000;
			sb.add("(\n");
			sb.add(command);
			sb.add("\n) &\n__hxp=$!\n");
			// 看门狗：到点后整组终止（输出重定向到 /dev/null，不持有 stdout 管道）
			sb.add("(\n");
			sb.add("\tsleep " + Std.string(secs) + "\n");
			sb.add("\tkill -TERM -$__hxp 2>/dev/null\n");
			sb.add("\tsleep 0.5\n");
			sb.add("\tkill -KILL -$__hxp 2>/dev/null\n");
			sb.add(") >/dev/null 2>&1 &\n__hxw=$!\n");
			sb.add("wait $__hxp; __hxs=$?\n");
			sb.add("kill -KILL -$__hxp 2>/dev/null\n"); // 兜底：清理忽略 TERM 的子进程
			sb.add("kill -TERM -$__hxw 2>/dev/null\n");
			// 被信号终止（143=SIGTERM/137=SIGKILL）→ 用 124 标记超时
			sb.add("if [ $__hxs -eq 143 ] || [ $__hxs -eq 137 ]; then exit 124; fi\n");
			sb.add("exit $__hxs\n");
		} else {
			sb.add("(\n");
			sb.add(command);
			sb.add("\n)\n");
		}
		return sb.toString();
	}

	static function render(output:String, code:Int, timedOut:Bool, timeoutMs:Int):String {
		if (output == null) output = "";
		var sb = new StringBuf();
		if (timedOut) sb.add('[超时 ${timeoutMs}ms，已终止进程]\n');
		sb.add('[exit $code]\n');
		sb.add(output);

		var content = sb.toString();
		var bytes = Bytes.ofString(content);
		if (bytes.length > MAX_OUTPUT)
			content = truncateUtf8(bytes, MAX_OUTPUT) + '\n...(输出过长，已截断，共 ${bytes.length} 字节)';
		return content;
	}

	/** 按字节上限截断，且不切断多字节字符。 */
	static function truncateUtf8(bytes:Bytes, maxBytes:Int):String {
		var cut = maxBytes;
		while (cut > 0 && (bytes.get(cut) & 0xC0) == 0x80)
			cut--;
		return bytes.sub(0, cut).toString();
	}

	// ------------------------------------------------------------------
	// shell
	// ------------------------------------------------------------------

	static function hasBash():Bool {
		if (bashAvailable == null)
			bashAvailable = probe("bash");
		return bashAvailable;
	}

	static function probe(exe:String):Bool {
		try {
			var p = new Process(exe, ["-c", "exit 0"]);
			var c = p.exitCode();
			p.close();
			return c == 0;
		} catch (e:Dynamic) {
			return false;
		}
	}

	static function shQuote(s:String):String {
		return "'" + StringTools.replace(s, "'", "'\\''") + "'";
	}

	// ------------------------------------------------------------------

	static function fail(message:String):ToolResult {
		return {content: message, isError: true};
	}

	static function pick(o:Dynamic, names:Array<String>):Dynamic {
		if (o == null) return null;
		for (n in names) {
			var v = Reflect.field(o, n);
			if (v != null) return v;
		}
		return null;
	}

	static function intArg(v:Dynamic, def:Int):Int {
		if (v == null) return def;
		if (Std.isOfType(v, Int)) return v;
		if (Std.isOfType(v, Float)) return Std.int(v);
		var n = Std.parseInt(Std.string(v));
		return n != null ? n : def;
	}
}
