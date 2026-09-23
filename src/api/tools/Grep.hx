package api.tools;

import api.ToolDefinition;
import haxe.io.Bytes;
import haxe.io.Path;
import util.Utf8;

/**
 * Grep 工具：按「内容」在文件 / 目录树中搜索，返回带行号的匹配结果（类似 ripgrep）。
 *
 * 与其它工具的分工：Find 按「名字」找条目，Tree 看「整体结构」，Grep 找「文件内容」。
 * 有了它就不必再靠 Bash 去跑 grep/rg（那既依赖外部程序，输出也不可控）。
 *
 * 参数（JSON Schema）：
 *  - pattern         string   搜索内容，默认按正则；fixed_strings=true 时按字面量 —— 必填
 *  - path            string   起始目录或单个文件，默认当前工作目录
 *  - glob            string   只搜索文件名匹配该 glob 的文件，如 *.hx、*.{hx,hxml}；逗号分隔多个
 *  - output_mode     string   content（默认，列出匹配行）/ files_with_matches / count
 *  - ignore_case     boolean  忽略大小写，默认 false
 *  - fixed_strings   boolean  把 pattern 当纯文本（不解释正则元字符），默认 false
 *  - context         integer  同时设置前后上下文行数（下两项的默认值）
 *  - before_context  integer  每处匹配额外显示的前几行，默认 0
 *  - after_context   integer  每处匹配额外显示的后几行，默认 0
 *  - max_results     integer  最多返回多少条结果（匹配行 / 文件），默认 200，上限 5000
 *  - include_hidden  boolean  是否包含以 . 开头的隐藏项，默认 false
 *  - ignore          string   额外忽略的名字，逗号分隔（附加在内置忽略表之上）
 *  - max_file_size   integer  跳过大于该字节数的文件，默认 2MB，<=0 表示不限
 *
 * 行为约定：
 *  - 自动跳过内置噪声目录（.git / node_modules / __pycache__ 等）与含 NUL 的二进制文件；
 *  - 逐行匹配（不做跨行正则）；单行超长时截断显示，避免刷爆上下文；
 *  - content 模式输出 `路径:行号:内容`，上下文行用 `-` 连接（`路径-行号-内容`），
 *    相邻匹配块之间用 `--` 分隔；
 *  - 结果路径可直接再喂给 Read / Edit（相对当前工作目录或与入参一致）；
 *  - 整体输出有字节上限，超出会截断并提示；达标上限时也会标注「已达上限」。
 *
 * 建议用法：先用 Grep 定位到具体行，再用 Read 精读附近内容，最后用 Edit 修改。
 */
class Grep implements ITool {
	public static inline var NAME = "Grep";

	/** 默认最多返回的结果条数。 */
	static inline var DEFAULT_MAX_RESULTS = 200;
	static inline var MAX_RESULTS_LIMIT = 5000;
	/** 默认跳过的文件大小上限（2MB）。 */
	static inline var DEFAULT_MAX_FILE_SIZE = 2 * 1024 * 1024;
	/** 上下文行数上限，防止一次刷屏。 */
	static inline var MAX_CONTEXT = 50;
	/** 单次返回内容的字节上限。 */
	static inline var MAX_OUTPUT_BYTES = 128 * 1024;
	/** 二进制探测读取的头部字节数。 */
	static inline var SNIFF_BYTES = 8192;
	/** 单行最多显示多少个字符。 */
	static inline var MAX_LINE_CHARS = 400;

	/** 内置忽略项：版本控制目录与依赖 / 缓存等噪声。 */
	static var DEFAULT_IGNORE = [".git", ".hg", ".svn", "node_modules", "__pycache__", ".DS_Store"];

	public var definition:ToolDefinition;

	public function new() {
		definition = {
			name: NAME,
			description: "按内容搜索文件（类 ripgrep）。默认正则匹配，可限定 glob / 大小写 / 上下文行。"
				+ "output_mode: content（默认，返回带行号的匹配行）/ files_with_matches（只列文件）/ count（每文件匹配数）。"
				+ "自动跳过 .git / node_modules 等目录与二进制文件。若只想按文件名查找，请用 Find。",
			parameters: {
				type: "object",
				properties: {
					pattern: {type: "string", description: "搜索内容：默认按正则表达式；fixed_strings=true 时按字面量"},
					path: {type: "string", description: "起始目录或单个文件，默认当前工作目录"},
					glob: {type: "string", description: "只搜索文件名匹配该 glob 的文件，如 *.hx、*.{hx,hxml}；逗号分隔多个"},
					output_mode: {type: "string", description: "content | files_with_matches | count，默认 content"},
					ignore_case: {type: "boolean", description: "忽略大小写，默认 false"},
					fixed_strings: {type: "boolean", description: "把 pattern 当纯文本而非正则，默认 false"},
					context: {type: "integer", description: "同时设置前后上下文行数（before/after 的默认值），默认 0"},
					before_context: {type: "integer", description: "每处匹配额外显示的前几行，默认 0"},
					after_context: {type: "integer", description: "每处匹配额外显示的后几行，默认 0"},
					max_results: {type: "integer",
						description: "最多返回多少条结果（匹配行 / 文件），默认 " + DEFAULT_MAX_RESULTS + "，上限 " + MAX_RESULTS_LIMIT},
					include_hidden: {type: "boolean", description: "是否包含以 . 开头的隐藏项，默认 false"},
					ignore: {type: "string", description: "额外忽略的名字，逗号分隔，如 build,dist,tmp"},
					max_file_size: {type: "integer",
						description: "跳过大于该字节数的文件，默认 " + DEFAULT_MAX_FILE_SIZE + "，<=0 表示不限"}
				},
				required: ["pattern"]
			}
		};
	}

	public function execute(args:Dynamic):ToolResult {
		if (args == null) args = {};

		var pattern:String = args.pattern != null ? Std.string(args.pattern) : null;
		if (pattern == null || StringTools.trim(pattern) == "")
			return fail("缺少 pattern 参数（要搜索的内容不能为空）");

		var fixedStrings = boolArg(pick(args, ["fixed_strings", "fixedStrings", "literal"]), false);
		var ignoreCase = boolArg(pick(args, ["ignore_case", "ignoreCase"]), false);

		// 构造正则：字面量模式先转义，保证元字符按原样搜索
		var re:EReg;
		try {
			re = new EReg(fixedStrings ? EReg.escape(pattern) : pattern, ignoreCase ? "i" : "");
		} catch (e:Dynamic) {
			return fail('正则表达式无效: "$pattern"（若想按字面量搜索，请设置 fixed_strings=true）');
		}

		var root:String = args.path != null ? Std.string(args.path) : ".";
		if (StringTools.trim(root) == "") root = ".";
		if (!sys.FileSystem.exists(root))
			return fail('路径不存在: $root');

		var mode = args.output_mode != null ? Std.string(args.output_mode).toLowerCase() : "content";
		switch (mode) {
			case "content" | "files_with_matches" | "files" | "count":
			default:
				return fail('output_mode 只能是 content / files_with_matches / count（收到: "$mode"）');
		}
		if (mode == "files") mode = "files_with_matches";

		// 上下文行数：context 作为 before/after 的默认值，显式指定的优先
		var ctx = clampContext(intArg(pick(args, ["context", "-C"]), 0));
		var before = clampContext(intArg(pick(args, ["before_context", "beforeContext", "-B"]), ctx));
		var after = clampContext(intArg(pick(args, ["after_context", "afterContext", "-A"]), ctx));

		var maxResults = intArg(pick(args, ["max_results", "maxResults", "limit", "head_limit", "headLimit"]), DEFAULT_MAX_RESULTS);
		if (maxResults < 1) maxResults = DEFAULT_MAX_RESULTS;
		if (maxResults > MAX_RESULTS_LIMIT) maxResults = MAX_RESULTS_LIMIT;

		var maxFileSize = intArg(pick(args, ["max_file_size", "maxFileSize"]), DEFAULT_MAX_FILE_SIZE);

		var includeHidden = boolArg(pick(args, ["include_hidden", "includeHidden"]), false);

		var ignore = new Map<String, Bool>();
		for (n in DEFAULT_IGNORE) ignore.set(n, true);
		if (args.ignore != null) {
			for (n in Std.string(args.ignore).split(",")) {
				var t = StringTools.trim(n);
				if (t != "") ignore.set(t, true);
			}
		}

		var fileFilter:String->Bool = null;
		if (args.glob != null && StringTools.trim(Std.string(args.glob)) != "") {
			try {
				fileFilter = makeGlobFilter(Std.string(args.glob));
			} catch (e:Dynamic) {
				return fail('glob 无效: "' + Std.string(args.glob) + '"');
			}
		}

		var st:GrepState = {
			re: re,
			mode: mode,
			before: before,
			after: after,
			maxResults: maxResults,
			maxFileSize: maxFileSize,
			ignore: ignore,
			includeHidden: includeHidden,
			fileFilter: fileFilter,
			scanned: 0,
			hitFiles: 0,
			hits: 0,
			unreadable: 0,
			oversized: 0,
			truncated: false,
			body: new StringBuf()
		};

		// 单文件：直接搜，不套用 glob / 忽略表
		var isDir = false;
		try isDir = sys.FileSystem.isDirectory(root) catch (e:Dynamic) {};
		if (isDir)
			walk(root, st);
		else
			searchFile(st, root, true);

		return {content: render(root, pattern, fixedStrings, ignoreCase, st)};
	}

	// ------------------------------------------------------------------
	// 遍历
	// ------------------------------------------------------------------

	/** 递归遍历目录（同层按名称排序，保证结果可复现）。返回 true 表示已达上限。 */
	static function walk(dir:String, st:GrepState):Bool {
		var names:Array<String>;
		try {
			names = sys.FileSystem.readDirectory(dir);
		} catch (e:Dynamic) {
			st.unreadable++;
			return false;
		}
		names.sort(Reflect.compare);

		for (name in names) {
			if (st.ignore.exists(name))
				continue;
			if (!st.includeHidden && name.charAt(0) == ".")
				continue;

			var full = Path.addTrailingSlash(dir) + name;
			var isDir = false;
			try isDir = sys.FileSystem.isDirectory(full) catch (e:Dynamic) {};

			if (isDir) {
				if (walk(full, st)) return true;
			} else {
				if (searchFile(st, full, false)) return true;
			}
		}
		return false;
	}

	/**
	 * 搜索单个文件。
	 * @param explicit path 参数直接指定的文件：跳过 glob 过滤
	 * @return true 表示已达上限，应停止遍历
	 */
	static function searchFile(st:GrepState, full:String, explicit:Bool):Bool {
		if (!explicit && st.fileFilter != null && !st.fileFilter(Path.withoutDirectory(full)))
			return false;

		if (st.maxFileSize > 0) {
			var size = -1;
			try size = sys.FileSystem.stat(full).size catch (e:Dynamic) {};
			if (size > st.maxFileSize) {
				st.oversized++;
				return false;
			}
		}

		var bytes:Bytes;
		try {
			bytes = sys.io.File.getBytes(full);
		} catch (e:Dynamic) {
			st.unreadable++;
			return false;
		}
		st.scanned++;

		if (bytes.length == 0 || looksBinary(bytes))
			return false;

		var lines = splitLines(bytes);
		return switch (st.mode) {
			case "content": searchContent(st, full, lines);
			case "count": searchCount(st, full, lines);
			default: searchFiles(st, full, lines);
		};
	}

	/** content：输出匹配行（含上下文）。 */
	static function searchContent(st:GrepState, full:String, lines:Array<String>):Bool {
		var hits = new Array<Int>();
		for (i in 0...lines.length) {
			if (st.re.matchSub(lines[i], 0))
				hits.push(i);
		}
		if (hits.length == 0)
			return false;

		st.hitFiles++;
		var label = disp(full);
		var lastEnd = -1; // 已输出的最大行号（0-based）
		var wrote = false; // 是否已经输出过匹配块

		for (h in hits) {
			if (st.hits >= st.maxResults) {
				st.truncated = true;
				return true;
			}
			st.hits++;

			var from = h - st.before;
			if (from < 0) from = 0;
			var to = h + st.after;
			if (to > lines.length - 1) to = lines.length - 1;

			// 与上一个块不相邻才加分隔线
			if (wrote && from > lastEnd + 1)
				st.body.add("--\n");

			var i = from;
			while (i <= to) {
				if (i > lastEnd) {
					var sep = (i == h) ? ":" : "-"; // 匹配行用 ':'，上下文行用 '-'
					st.body.add(label + sep + (i + 1) + sep + clip(lines[i]) + "\n");
					lastEnd = i;
				}
				i++;
			}
			wrote = true;
		}
		return false;
	}

	/** count：每个命中文件输出一行 `路径:匹配数`。 */
	static function searchCount(st:GrepState, full:String, lines:Array<String>):Bool {
		var n = 0;
		for (line in lines) {
			if (st.re.matchSub(line, 0))
				n++;
		}
		if (n == 0)
			return false;

		st.hits += n;
		st.hitFiles++;
		st.body.add(disp(full) + ":" + n + "\n");

		if (st.hitFiles >= st.maxResults) {
			st.truncated = true;
			return true;
		}
		return false;
	}

	/** files_with_matches：每个命中文件输出一行路径。 */
	static function searchFiles(st:GrepState, full:String, lines:Array<String>):Bool {
		var found = false;
		for (line in lines) {
			if (st.re.matchSub(line, 0)) {
				found = true;
				break;
			}
		}
		if (!found)
			return false;

		st.hitFiles++;
		st.body.add(disp(full) + "\n");

		if (st.hitFiles >= st.maxResults) {
			st.truncated = true;
			return true;
		}
		return false;
	}

	// ------------------------------------------------------------------
	// 文件读取
	// ------------------------------------------------------------------

	/** 按字节切行并宽容解码（支持非 UTF-8 文件），\r\n 的 \r 会被去掉。 */
	static function splitLines(bytes:Bytes):Array<String> {
		var lines = new Array<String>();
		var len = bytes.length;
		var start = 0;
		var i = 0;
		while (i < len) {
			if (bytes.get(i) == 10) { // '\n'
				lines.push(decodeLine(bytes, start, i));
				start = i + 1;
			}
			i++;
		}
		if (start < len)
			lines.push(decodeLine(bytes, start, len));
		return lines;
	}

	static function decodeLine(bytes:Bytes, from:Int, to:Int):String {
		if (to > from && bytes.get(to - 1) == 13) // 去掉尾随 '\r'
			to--;
		if (to <= from)
			return "";
		return Utf8.safe(bytes.sub(from, to - from));
	}

	/** 通过头部是否含 NUL 字节来粗略判断二进制文件。 */
	static function looksBinary(bytes:Bytes):Bool {
		var n = bytes.length < SNIFF_BYTES ? bytes.length : SNIFF_BYTES;
		for (i in 0...n) {
			if (bytes.get(i) == 0)
				return true;
		}
		return false;
	}

	// ------------------------------------------------------------------
	// glob / 路径 / 渲染
	// ------------------------------------------------------------------

	/** 构造文件名过滤器：支持 `*`、`?`、`{a,b}`，逗号分隔多个，忽略大小写。 */
	static function makeGlobFilter(glob:String):String->Bool {
		var regexes = new Array<EReg>();
		for (p in glob.split(",")) {
			var t = StringTools.trim(p);
			if (t != "")
				regexes.push(new EReg(globToRegex(t), "i"));
		}
		if (regexes.length == 0)
			return null;
		return function(name:String):Bool {
			for (re in regexes) {
				if (re.matchSub(name, 0))
					return true;
			}
			return false;
		};
	}

	static function globToRegex(g:String):String {
		var sb = new StringBuf();
		var i = 0;
		while (i < g.length) {
			var c = g.charAt(i);
			switch (c) {
				case "*":
					sb.add(".*");
				case "?":
					sb.add(".");
				case "{":
					var close = g.indexOf("}", i);
					if (close < 0) {
						sb.add("\\{");
					} else {
						var alts = g.substr(i + 1, close - i - 1).split(",");
						sb.add("(");
						for (k in 0...alts.length) {
							if (k > 0) sb.add("|");
							sb.add(EReg.escape(alts[k]));
						}
						sb.add(")");
						i = close; // 跳到 '}'，循环末尾统一 i++
					}
				case "." | "+" | "(" | ")" | "[" | "]" | "^" | "$" | "|" | "\\":
					sb.add("\\" + c);
				default:
					sb.add(c);
			}
			i++;
		}
		return "^" + sb.toString() + "$";
	}

	/** 展示用路径：统一 / 分隔，去掉开头的 "./"。 */
	static function disp(p:String):String {
		var s = StringTools.replace(p, "\\", "/");
		while (StringTools.startsWith(s, "./"))
			s = s.substr(2);
		return s == "" ? "." : s;
	}

	static function render(root:String, pattern:String, fixedStrings:Bool, ignoreCase:Bool, st:GrepState):String {
		var where = root == "." ? "当前目录" : disp(root);
		var how = fixedStrings ? "字面量" : "正则";
		var flavor = how + (ignoreCase ? "，忽略大小写" : "，区分大小写");

		var sb = new StringBuf();
		if (st.hitFiles == 0) {
			sb.add('在 $where 下未找到匹配 "$pattern"（$flavor），已扫描 ${st.scanned} 个文件');
			if (st.unreadable > 0) sb.add('，跳过 ${st.unreadable} 个无法读取的条目');
			if (st.oversized > 0) sb.add('，跳过 ${st.oversized} 个超大文件');
			sb.add("。\n");
			return sb.toString();
		}

		var stat = switch (st.mode) {
			case "files_with_matches": '${st.hitFiles} 个文件含匹配';
			case "count": '共 ${st.hits} 处匹配，分布在 ${st.hitFiles} 个文件';
			default: '匹配 ${st.hits} 行 / ${st.hitFiles} 个文件';
		};

		sb.add('在 $where 下搜索 "$pattern"（$flavor）：$stat');
		if (st.truncated) sb.add('；已达上限 ${st.maxResults}，结果可能不完整');
		sb.add("\n\n");

		var body = st.body.toString();
		var bytes = Bytes.ofString(body);
		if (bytes.length > MAX_OUTPUT_BYTES)
			body = truncateUtf8(bytes, MAX_OUTPUT_BYTES) + '\n...（输出过长，已截断，共 ${bytes.length} 字节）\n';
		sb.add(body);

		if (st.unreadable > 0)
			sb.add('（另有 ${st.unreadable} 个无法读取的条目被跳过）\n');
		if (st.oversized > 0)
			sb.add('（另有 ${st.oversized} 个超过大小上限的文件被跳过）\n');
		return sb.toString();
	}

	/** 按字节上限截断，且不切断多字节字符。 */
	static function truncateUtf8(bytes:Bytes, maxBytes:Int):String {
		var cut = maxBytes;
		while (cut > 0 && (bytes.get(cut) & 0xC0) == 0x80)
			cut--;
		return bytes.sub(0, cut).toString();
	}

	/** 单行过长时截断，避免一行把上下文顶爆。 */
	static function clip(s:String):String {
		return s.length > MAX_LINE_CHARS ? s.substr(0, MAX_LINE_CHARS) + "…（本行已截断）" : s;
	}

	// ------------------------------------------------------------------

	static function fail(message:String):ToolResult {
		return {content: message, isError: true};
	}

	static function clampContext(v:Int):Int {
		if (v < 0) return 0;
		return v > MAX_CONTEXT ? MAX_CONTEXT : v;
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

/** 搜索过程中的上下文与统计。 */
private typedef GrepState = {
	var re:EReg;
	var mode:String;
	var before:Int;
	var after:Int;
	var maxResults:Int;
	var maxFileSize:Int;
	var ignore:Map<String, Bool>;
	var includeHidden:Bool;
	var fileFilter:String->Bool;
	/** 实际读取并搜索过的文件数。 */
	var scanned:Int;
	/** 命中的文件数。 */
	var hitFiles:Int;
	/** 命中行数（files 模式不统计）。 */
	var hits:Int;
	/** 无法读取的条目数（无权限等）。 */
	var unreadable:Int;
	/** 因超大小上限被跳过的文件数。 */
	var oversized:Int;
	/** 是否触达 maxResults 上限。 */
	var truncated:Bool;
	var body:StringBuf;
}
