package api.tools;

import api.ToolDefinition;
import haxe.io.Bytes;
import sys.io.Process;
import util.Utf8;

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

	/** 调试日志开关（环境变量 HXAGENT_DEBUG=1/true 打开，或直接置 true）。 */
	public static var verbose:Bool = false;
	static var debugInited = false;

	/** 解析到的 bash 可执行文件；null 表示未找到。 */
	static var bashPath:String = null;
	static var bashResolved = false;

	static function initDebug():Void {
		if (debugInited) return;
		debugInited = true;
		var v = Sys.getEnv("HXAGENT_DEBUG");
		if (v == "1" || v == "true") verbose = true;
	}

	static function log(msg:String):Void {
		if (verbose) Sys.stderr().writeString("[bash] " + msg + "\n");
	}

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
		initDebug();
		log('execute: command="${oneLine(command)}" cwd=${cwd != null ? cwd : "(默认)"} timeout=${timeoutMs}ms');

		var bash = findBash();
		if (bash == null) {
			var diag = diagnose();
			Sys.stderr().writeString("[bash] 未找到 bash，诊断:\n" + diag + "\n");
			return fail("未找到 bash。本工具依赖 bash（Windows 请安装 Git Bash）。诊断:\n" + diag);
		}

		var script = buildScript(command, cwd, timeoutMs);
		log('使用 bash=$bash，脚本 ${Bytes.ofString(script).length} 字节');

		var start = Sys.time();
		var proc:Process;
		try {
			proc = new Process(bash, ["-c", script]);
		} catch (e:Dynamic) {
			log("启动失败: " + Std.string(e));
			return fail('无法启动 bash ($bash): ' + Std.string(e));
		}

		// stderr 已在脚本内合并到 stdout，只需读一路，不会死锁
		var output = "";
		try {
			output = Utf8.safe(proc.stdout.readAll());
		} catch (e:Dynamic) {
			log("读取输出异常: " + Std.string(e));
		}

		var code = 0;
		try {
			code = proc.exitCode();
		} catch (e:Dynamic) {}
		try proc.close() catch (e:Dynamic) {};

		var timedOut = code == 124;
		log('完成: exit=$code 超时=$timedOut 输出=${Bytes.ofString(output).length}字节 耗时=${Std.int((Sys.time() - start) * 1000)}ms');

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

	/** 定位 bash（结果缓存），首次定位时向 stderr 输出一行结果，便于排障。 */
	public static function findBash():Null<String> {
		if (bashResolved) return bashPath;
		bashResolved = true;
		initDebug();
		bashPath = locateBash();
		if (bashPath != null)
			Sys.stderr().writeString("[bash] 定位 bash: " + bashPath + "\n");
		else
			Sys.stderr().writeString("[bash] 未找到 bash\n" + diagnose() + "\n");
		return bashPath;
	}

	static function locateBash():Null<String> {
		log("系统=" + Sys.systemName() + " cwd=" + Sys.getCwd());

		// 1) 交给系统 PATH 查找
		if (probe("bash")) {
			bashPath = "bash";
			log("PATH 命中: bash");
			return bashPath;
		}
		if (probe("bash.exe")) {
			bashPath = "bash.exe";
			log("PATH 命中: bash.exe");
			return bashPath;
		}

		// 2) 遍历 PATH 各目录
		var envPath = Sys.getEnv("PATH");
		if (envPath != null) {
			var sep = Sys.systemName() == "Windows" ? ";" : ":";
			for (dir in envPath.split(sep)) {
				if (dir == null || StringTools.trim(dir) == "") continue;
				var cand = addSlash(dir) + "bash" + (Sys.systemName() == "Windows" ? ".exe" : "");
				if (sys.FileSystem.exists(cand) && probe(cand)) {
					bashPath = cand;
					log("PATH 目录命中: " + cand);
					return bashPath;
				}
			}
		}

		// 3) 常见 Git for Windows 安装位置
		for (cand in commonBashPaths()) {
			if (sys.FileSystem.exists(cand)) {
				if (probe(cand)) {
					bashPath = cand;
					log("常见位置命中: " + cand);
					return bashPath;
				}
				log("存在但不可用: " + cand);
			} else {
				log("不存在: " + cand);
			}
		}

		log("未找到 bash");
		return null;
	}

	/** 常见 bash 安装路径（供查找与诊断）。 */
	static function commonBashPaths():Array<String> {
		var out = new Array<String>();
		var pf = Sys.getEnv("ProgramFiles");
		var pf86 = Sys.getEnv("ProgramFiles(x86)");
		var local = Sys.getEnv("LOCALAPPDATA");
		if (pf != null) {
			out.push(slash(pf + "/Git/bin/bash.exe"));
			out.push(slash(pf + "/Git/usr/bin/bash.exe"));
		}
		if (pf86 != null) out.push(slash(pf86 + "/Git/bin/bash.exe"));
		if (local != null) out.push(slash(local + "/Programs/Git/bin/bash.exe"));
		out.push("C:/Program Files/Git/bin/bash.exe");
		out.push("C:/Program Files/Git/usr/bin/bash.exe");
		out.push("C:/msys64/usr/bin/bash.exe");
		return out;
	}

	/** 环境诊断信息（供 /diag 或排障）。 */
	public static function diagnose():String {
		var sb = new StringBuf();
		sb.add("- 系统: " + Sys.systemName() + "\n");
		sb.add("- cwd: " + Sys.getCwd() + "\n");
		var envPath = Sys.getEnv("PATH");
		if (envPath != null) {
			var sep = Sys.systemName() == "Windows" ? ";" : ":";
			var parts = envPath.split(sep);
			sb.add("- PATH(" + parts.length + " 项): " + parts.slice(0, 8).join(" | ") + (parts.length > 8 ? " ..." : "") + "\n");
		} else {
			sb.add("- PATH: (空)\n");
		}
		var found = findBash();
		sb.add("- bash: " + (found != null ? found : "未找到") + "\n");
		sb.add("- 常见位置检查:\n");
		for (cand in commonBashPaths())
			sb.add("    [" + (sys.FileSystem.exists(cand) ? "存在" : "缺失") + "] " + cand + "\n");
		return sb.toString();
	}

	static function addSlash(s:String):String {
		if (s.length == 0) return s;
		var c = s.charAt(s.length - 1);
		return (c == "/" || c == "\\") ? s : s + "/";
	}

	static function slash(s:String):String {
		return StringTools.replace(s, "\\", "/");
	}

	static function oneLine(s:String):String {
		var t = StringTools.replace(StringTools.replace(s, "\r", ""), "\n", " ⏎ ");
		return t.length > 120 ? t.substr(0, 120) + " ..." : t;
	}

	static function probe(exe:String):Bool {
		try {
			var p = new Process(exe, ["-c", "exit 0"]);
			var c = p.exitCode();
			p.close();
			return c == 0;
		} catch (e:Dynamic) {
			log("probe 失败: " + exe + " (" + Std.string(e) + ")");
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
