package api.tools;

import api.ToolDefinition;

/**
 * Edit 工具：对本机文件做精确的字符串替换（局部修改），比 Write 整文件覆盖更安全。
 *
 * 参数（JSON Schema）：
 *  - path         string   目标文件路径（绝对或相对当前工作目录）—— 必填
 *  - old_string   string   要被替换的原文本 —— 必填，需与文件内容完全一致
 *  - new_string   string   替换后的新文本 —— 必填
 *  - replace_all  boolean  是否替换所有匹配，默认 false（要求唯一匹配）
 *  - start_line   integer  起始行号提示（1-based），多处匹配时用于就近消歧
 *
 * 行为约定（参考业界 Agent 的 Edit 工具）：
 *  - 默认要求 `old_string` 在文件中**唯一**，否则报错并提示补充上下文；
 *  - 提供 `start_line` 时，若多处匹配则选择离该行最近的一处（内容仍是最终依据）；
 *  - 结果会回报实际替换发生的行号，便于模型链式修改时自查；
 *  - `old_string` 与 `new_string` 不能相同；
 *  - 自动适配文件换行风格：模型给出的 `\n` 会按文件实际的 CRLF/LF 归一化后匹配与写入；
 *  - 保持 UTF-8，二进制写，不做任何换行转换。
 *
 * 建议用法：先用 Read 查看文件，再用足够的上下文构造唯一的 old_string。
 */
class Edit implements ITool {
	public static inline var NAME = "Edit";

	public var definition:ToolDefinition;

	public function new() {
		definition = {
			name: NAME,
			description: "在文件中做精确字符串替换。默认要求 old_string 唯一，否则报错；可用 replace_all=true 全部替换。"
				+ "当 old_string 多处匹配时，可用 start_line 指定附近行号来消歧。请先用 Read 读取文件。",
			parameters: {
				type: "object",
				properties: {
					path: {type: "string", description: "目标文件路径（绝对或相对于当前工作目录）"},
					old_string: {type: "string", description: "要被替换的原文本，需与文件内容完全一致"},
					new_string: {type: "string", description: "替换后的新文本"},
					replace_all: {type: "boolean", description: "是否替换全部匹配，默认 false（要求唯一匹配）"},
					start_line: {type: "integer", description: "起始行号提示（1-based）。当 old_string 多处匹配时用于就近消歧；仅为提示，仍以内容匹配为准"}
				},
				required: ["path", "old_string", "new_string"]
			}
		};
	}

	public function execute(args:Dynamic):ToolResult {
		if (args == null)
			return fail("缺少参数");

		var path:String = args.path != null ? Std.string(args.path) : null;
		if (path == null || StringTools.trim(path) == "")
			return fail("缺少 path 参数");
		if (args.old_string == null)
			return fail("缺少 old_string 参数");
		if (args.new_string == null)
			return fail("缺少 new_string 参数");

		var oldStr:String = Std.string(args.old_string);
		var newStr:String = Std.string(args.new_string);
		var replaceAll = boolArg(pick(args, ["replace_all", "replaceAll"]), false);
		var startLine = intArg(pick(args, ["start_line", "startLine"]));

		if (oldStr == "")
			return fail("old_string 不能为空");

		if (!sys.FileSystem.exists(path))
			return fail('文件不存在: $path');
		try {
			if (sys.FileSystem.isDirectory(path))
				return fail('路径是一个目录，无法编辑: $path');
		} catch (e:Dynamic) {
			return fail('无法访问路径: $path (' + Std.string(e) + ')');
		}

		// 二进制读取，保留原始换行
		var content:String;
		try {
			var input = sys.io.File.read(path, true);
			var raw = input.readAll();
			input.close();
			try {
				content = raw.toString();
			} catch (e:Dynamic) {
				return fail('文件不是有效 UTF-8 编码，无法安全编辑: $path');
			}
		} catch (e:Dynamic) {
			return fail('读取失败: ' + Std.string(e));
		}

		if (content.indexOf(String.fromCharCode(0)) >= 0)
			return fail('疑似二进制文件，无法编辑: $path');

		// 按文件换行风格归一化搜索/替换文本
		var crlf = content.indexOf("\r\n") >= 0;
		var search = crlf ? toCRLF(oldStr) : toLF(oldStr);
		var repl = crlf ? toCRLF(newStr) : toLF(newStr);

		if (search == repl)
			return fail("old_string 与 new_string 相同，无需修改");

		var hits = findAll(content, search);
		if (hits.length == 0)
			return fail('未找到要替换的内容: ' + excerpt(oldStr));

		var updated:String;
		var count:Int;
		var atLine:Int;

		if (replaceAll) {
			count = hits.length;
			atLine = lineOfIndex(content, hits[0]);
			updated = StringTools.replace(content, search, repl);
		} else if (hits.length == 1) {
			count = 1;
			atLine = lineOfIndex(content, hits[0]);
			updated = splice(content, hits[0], search.length, repl);
		} else if (startLine != null) {
			// 多处匹配：用 start_line 就近消歧
			var chosen = hits[0];
			var bestDist = -1;
			for (h in hits) {
				var d = lineOfIndex(content, h) - startLine;
				if (d < 0) d = -d;
				if (bestDist < 0 || d < bestDist) {
					bestDist = d;
					chosen = h;
				}
			}
			count = 1;
			atLine = lineOfIndex(content, chosen);
			updated = splice(content, chosen, search.length, repl);
		} else {
			return fail('匹配到 ${hits.length} 处，请补充更多上下文使其唯一，或提供 start_line 提示，或设置 replace_all=true');
		}

		try {
			var out = sys.io.File.write(path, true);
			out.writeString(updated);
			out.close();
		} catch (e:Dynamic) {
			return fail('写入失败: ' + Std.string(e));
		}

		var where = count > 1 ? '替换 $count 处，首处第 $atLine 行' : '第 $atLine 行起';
		return {content: '编辑成功: $path（$where）'};
	}

	// ------------------------------------------------------------------

	static function fail(message:String):ToolResult {
		return {content: message, isError: true};
	}

	static inline function toLF(s:String):String {
		return StringTools.replace(s, "\r\n", "\n");
	}

	static inline function toCRLF(s:String):String {
		return StringTools.replace(toLF(s), "\n", "\r\n");
	}

	static function findAll(s:String, sub:String):Array<Int> {
		var out = [];
		if (sub == "") return out;
		var i = 0;
		while (true) {
			var p = s.indexOf(sub, i);
			if (p < 0) break;
			out.push(p);
			i = p + sub.length;
		}
		return out;
	}

	/** 字符索引 -> 行号（1-based）。 */
	static function lineOfIndex(s:String, idx:Int):Int {
		var line = 1;
		var n = idx < s.length ? idx : s.length;
		for (i in 0...n)
			if (s.charCodeAt(i) == 10) line++;
		return line;
	}

	static function splice(s:String, pos:Int, len:Int, by:String):String {
		return s.substr(0, pos) + by + s.substr(pos + len);
	}

	static function excerpt(s:String):String {
		var e = StringTools.replace(StringTools.replace(s, "\r", "\\r"), "\n", "\\n");
		if (e.length > 60) e = e.substr(0, 60) + " ...";
		return '"' + e + '"';
	}

	static function pick(o:Dynamic, names:Array<String>):Dynamic {
		for (n in names) {
			var v = Reflect.field(o, n);
			if (v != null) return v;
		}
		return null;
	}

	static function boolArg(v:Dynamic, def:Bool):Bool {
		if (v == null) return def;
		if (Std.isOfType(v, Bool)) return v;
		var s = Std.string(v).toLowerCase();
		if (s == "true" || s == "1") return true;
		if (s == "false" || s == "0") return false;
		return def;
	}

	static function intArg(v:Dynamic):Null<Int> {
		if (v == null) return null;
		if (Std.isOfType(v, Int)) return v;
		if (Std.isOfType(v, Float)) return Std.int(v);
		return Std.parseInt(Std.string(v));
	}
}
