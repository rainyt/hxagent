package api.tools;

import api.ToolDefinition;
import haxe.io.Path;

/**
 * Find 工具：按名称在目录树中查找文件 / 目录。
 *
 * 关键行为：**逐层广度优先（BFS）**——先把当前层的所有目录列完并匹配，
 * 再统一进入下一层，查完第二层再进第三层，依此类推。
 * 最大搜索深度固定上限为 6 层（`max_depth` 超过 6 会被截断为 6）。
 *
 * 参数（JSON Schema）：
 *  - pattern        string   名称匹配。含 * / ? 时按通配符（全名匹配），否则按子串（不区分大小写）—— 必填
 *  - path           string   起始目录，默认当前工作目录
 *  - max_depth      integer  最大层数，默认 6，上限 6
 *  - type           string   file | dir | any（默认 any）
 *  - limit          integer  最多返回结果数，默认 200
 *  - include_hidden boolean  是否包含以 . 开头的隐藏项，默认 false
 *
 * 结果按「层号升序，同层按路径」排列，`F ` 表示文件、`D ` 表示目录。
 */
class Find implements ITool {
	public static inline var NAME = "Find";

	/** 最大搜索层数上限。 */
	static inline var MAX_DEPTH = 6;
	static inline var DEFAULT_LIMIT = 200;

	public var definition:ToolDefinition;

	public function new() {
		definition = {
			name: NAME,
			description: "在目录树中按名称查找文件/目录，逐层广度优先（BFS），最大 6 层。"
				+ "pattern 支持 * 和 ? 通配符（全名匹配）；不含通配符时按子串匹配（忽略大小写）。",
			parameters: {
				type: "object",
				properties: {
					pattern: {type: "string", description: "名称匹配式，如 *.hx、Main、config*"},
					path: {type: "string", description: "起始目录，默认当前工作目录"},
					max_depth: {type: "integer", description: "最大搜索层数，默认 6，上限 6"},
					type: {type: "string", description: "file | dir | any，默认 any"},
					limit: {type: "integer", description: "最多返回结果数，默认 " + DEFAULT_LIMIT},
					include_hidden: {type: "boolean", description: "是否包含以 . 开头的隐藏项，默认 false"}
				},
				required: ["pattern"]
			}
		};
	}

	public function execute(args:Dynamic):ToolResult {
		if (args == null)
			return fail("缺少参数");

		var pattern:String = args.pattern != null ? Std.string(args.pattern) : null;
		if (pattern == null || StringTools.trim(pattern) == "")
			return fail("缺少 pattern 参数");

		var root:String = args.path != null ? Std.string(args.path) : ".";
		var maxDepth = intArg(pick(args, ["max_depth", "maxDepth"]), MAX_DEPTH);
		if (maxDepth < 1) maxDepth = 1;
		if (maxDepth > MAX_DEPTH) maxDepth = MAX_DEPTH;

		var type = args.type != null ? Std.string(args.type).toLowerCase() : "any";
		var limit = intArg(pick(args, ["limit"]), DEFAULT_LIMIT);
		if (limit < 1) limit = DEFAULT_LIMIT;
		var includeHidden = boolArg(pick(args, ["include_hidden", "includeHidden"]), false);

		if (!sys.FileSystem.exists(root))
			return fail('目录不存在: $root');
		try {
			if (!sys.FileSystem.isDirectory(root))
				return fail('不是目录: $root');
		} catch (e:Dynamic) {
			return fail('无法访问: $root (' + Std.string(e) + ')');
		}

		var matcher = makeMatcher(pattern);
		var wantFile = type != "dir";
		var wantDir = type != "file";

		var results:Array<{rel:String, dir:Bool, depth:Int}> = [];
		var skipped = 0;

		// ---- 逐层 BFS ----
		// current 为「同一层」待扫描的目录；整个 current 处理完才进入 next（下一层）。
		var current:Array<{dir:String, rel:String, depth:Int}> = [{dir: root, rel: "", depth: 0}];

		while (current.length > 0 && results.length < limit) {
			var next:Array<{dir:String, rel:String, depth:Int}> = [];

			for (node in current) {
				var entries:Array<String>;
				try {
					entries = sys.FileSystem.readDirectory(node.dir);
				} catch (e:Dynamic) {
					skipped++;
					continue;
				}
				entries.sort(Reflect.compare);

				for (name in entries) {
					if (results.length >= limit) break;
					if (!includeHidden && name.charAt(0) == ".")
						continue;

					var full = Path.addTrailingSlash(node.dir) + name;
					var rel = node.rel == "" ? name : node.rel + "/" + name;

					var isDir = false;
					try isDir = sys.FileSystem.isDirectory(full) catch (e:Dynamic) {};

					if (matcher(name)) {
						if (isDir && wantDir)
							results.push({rel: rel, dir: true, depth: node.depth + 1});
						else if (!isDir && wantFile)
							results.push({rel: rel, dir: false, depth: node.depth + 1});
					}

					// 只有还没到最大层才把子目录排入下一层
					if (isDir && node.depth + 1 < maxDepth)
						next.push({dir: full, rel: rel, depth: node.depth + 1});
				}
			}

			current = next;
		}

		// 按层号再按路径排序（BFS 结果自然有序，这里再稳定一次）
		results.sort(function(a, b) {
			if (a.depth != b.depth) return a.depth - b.depth;
			return Reflect.compare(a.rel, b.rel);
		});

		return {content: format(root, pattern, maxDepth, limit, results, skipped)};
	}

	// ------------------------------------------------------------------

	static function format(root:String, pattern:String, maxDepth:Int, limit:Int,
			results:Array<{rel:String, dir:Bool, depth:Int}>, skipped:Int):String {
		if (results.length == 0)
			return '在 $root 下未找到匹配 "$pattern" 的条目（最大 $maxDepth 层）。';

		var sb = new StringBuf();
		sb.add('在 $root 下找到 ${results.length} 个匹配 "$pattern"（逐层 BFS，最大 $maxDepth 层）');
		if (results.length >= limit)
			sb.add('（已达上限 $limit，可能还有更多）');
		sb.add(":\n");
		for (r in results)
			sb.add((r.dir ? "D " : "F ") + r.rel + "\n");
		if (skipped > 0)
			sb.add('（跳过 $skipped 个无法访问的目录）\n');
		return sb.toString();
	}

	static function fail(message:String):ToolResult {
		return {content: message, isError: true};
	}

	/** 构造名称匹配函数：含通配符 -> glob 全名匹配；否则子串匹配（忽略大小写）。 */
	static function makeMatcher(pattern:String):String->Bool {
		if (pattern.indexOf("*") >= 0 || pattern.indexOf("?") >= 0) {
			var re = new EReg(globToRegex(pattern), "i");
			return function(name:String):Bool return re.match(name);
		}
		var p = pattern.toLowerCase();
		return function(name:String):Bool return name.toLowerCase().indexOf(p) >= 0;
	}

	static function globToRegex(g:String):String {
		var sb = new StringBuf();
		for (i in 0...g.length) {
			var c = g.charAt(i);
			switch (c) {
				case "*": sb.add(".*");
				case "?": sb.add(".");
				case "." | "+" | "(" | ")" | "[" | "]" | "{" | "}" | "^" | "$" | "|" | "\\":
					sb.add("\\" + c);
				default: sb.add(c);
			}
		}
		return "^" + sb.toString() + "$";
	}

	static function pick(o:Dynamic, names:Array<String>):Dynamic {
		if (o == null) return null;
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

	static function intArg(v:Dynamic, def:Int):Int {
		if (v == null) return def;
		if (Std.isOfType(v, Int)) return v;
		if (Std.isOfType(v, Float)) return Std.int(v);
		var n = Std.parseInt(Std.string(v));
		return n != null ? n : def;
	}
}
