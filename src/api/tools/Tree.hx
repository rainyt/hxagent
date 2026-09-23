package api.tools;

import api.ToolDefinition;
import haxe.io.Path;

/**
 * Tree 工具：以树状结构展示目录布局，供 AI 快速了解项目结构。
 *
 * 与 Find 的区别：Find 是「按名字找条目」，Tree 是「把目录布局整棵画出来」。
 *
 * 参数（JSON Schema）：
 *  - path           string   起始目录，默认当前工作目录
 *  - max_depth      integer  最大递归层数，默认 3，上限 10（防止超大工程刷屏）
 *  - dirs_only      boolean  只显示目录，默认 false
 *  - include_hidden boolean  是否包含以 . 开头的隐藏项，默认 false
 *  - show_size      boolean  是否显示文件大小，默认 false
 *  - ignore         string   额外忽略的名字，逗号分隔（附加在内置忽略表之上）
 *  - limit          integer  最多渲染的条目数，默认 500，上限 5000
 *
 * 输出：树状文本 + 目录/文件计数；条目触顶时标注「已截断」。
 * 目录名后带 `/`；无法读取的目录标注 `[无法访问]`。
 */
class Tree implements ITool {
	public static inline var NAME = "Tree";

	static inline var MAX_DEPTH = 10;
	static inline var MAX_LIMIT = 5000;
	static inline var DEFAULT_DEPTH = 3;
	static inline var DEFAULT_LIMIT = 500;

	/** 内置忽略项：版本控制目录与依赖/缓存等噪声，避免刷屏。 */
	static var DEFAULT_IGNORE = [".git", ".hg", ".svn", "node_modules", "__pycache__", ".DS_Store"];

	public var definition:ToolDefinition;

	public function new() {
		definition = {
			name: NAME,
			description: "以树状结构展示目录布局，用于快速了解项目结构（比 Find 更适合「看整体」）。"
				+ "默认递归 3 层，自动忽略 .git/node_modules 等噪声目录，可控制深度、只看目录、显示文件大小。",
			parameters: {
				type: "object",
				properties: {
					path: {type: "string", description: "起始目录，默认当前工作目录"},
					max_depth: {type: "integer", description: "最大递归层数，默认 " + DEFAULT_DEPTH + "，上限 " + MAX_DEPTH},
					dirs_only: {type: "boolean", description: "只显示目录，默认 false"},
					include_hidden: {type: "boolean", description: "是否包含以 . 开头的隐藏项，默认 false"},
					show_size: {type: "boolean", description: "是否显示文件大小，默认 false"},
					ignore: {type: "string", description: "额外忽略的名字，逗号分隔，如 build,dist,tmp"},
					limit: {type: "integer", description: "最多渲染的条目数，默认 " + DEFAULT_LIMIT + "，上限 " + MAX_LIMIT}
				},
				required: []
			}
		};
	}

	public function execute(args:Dynamic):ToolResult {
		if (args == null) args = {};

		var root:String = args.path != null ? Std.string(args.path) : ".";
		if (StringTools.trim(root) == "") root = ".";

		var maxDepth = intArg(pick(args, ["max_depth", "maxDepth"]), DEFAULT_DEPTH);
		if (maxDepth < 0) maxDepth = 0;
		if (maxDepth > MAX_DEPTH) maxDepth = MAX_DEPTH;

		var limit = intArg(pick(args, ["limit"]), DEFAULT_LIMIT);
		if (limit < 1) limit = DEFAULT_LIMIT;
		if (limit > MAX_LIMIT) limit = MAX_LIMIT;

		var dirsOnly = boolArg(pick(args, ["dirs_only", "dirsOnly"]), false);
		var includeHidden = boolArg(pick(args, ["include_hidden", "includeHidden"]), false);
		var showSize = boolArg(pick(args, ["show_size", "showSize"]), false);

		// 目录存在性检查
		if (!sys.FileSystem.exists(root))
			return fail('目录不存在: $root');
		try {
			if (!sys.FileSystem.isDirectory(root))
				return fail('不是目录: $root');
		} catch (e:Dynamic) {
			return fail('无法访问: $root (' + Std.string(e) + ')');
		}

		// 忽略表：内置 + 用户追加
		var ignore = new Map<String, Bool>();
		for (n in DEFAULT_IGNORE) ignore.set(n, true);
		if (args.ignore != null) {
			for (n in Std.string(args.ignore).split(",")) {
				var t = StringTools.trim(n);
				if (t != "") ignore.set(t, true);
			}
		}

		var ctx:Ctx = {
			maxDepth: maxDepth,
			limit: limit,
			dirsOnly: dirsOnly,
			includeHidden: includeHidden,
			showSize: showSize,
			ignore: ignore,
			count: 0,
			dirs: 0,
			files: 0,
			truncated: false
		};

		var children = build(root, 0, ctx);

		return {content: format(root, ctx, children)};
	}

	// ------------------------------------------------------------------
	// 递归构建
	// ------------------------------------------------------------------

	/**
	 * 读取 dir 的内容并递归构建子树。
	 * 返回 null 表示该目录无法读取（无权限等）。
	 */
	static function build(dir:String, depth:Int, ctx:Ctx):Array<Node> {
		var names:Array<String>;
		try {
			names = sys.FileSystem.readDirectory(dir);
		} catch (e:Dynamic) {
			return null;
		}

		var nodes:Array<Node> = [];
		for (name in names) {
			if (ctx.count >= ctx.limit) {
				ctx.truncated = true;
				break;
			}
			if (!ctx.includeHidden && name.charAt(0) == ".")
				continue;
			if (ctx.ignore.exists(name))
				continue;

			var full = Path.addTrailingSlash(dir) + name;
			var isDir = false;
			try isDir = sys.FileSystem.isDirectory(full) catch (e:Dynamic) {};

			if (!isDir && ctx.dirsOnly)
				continue;

			ctx.count++;
			var node:Node = {name: name, dir: isDir, size: 0, children: null, denied: false};

			if (isDir) {
				ctx.dirs++;
				if (depth < ctx.maxDepth) {
					var ch = build(full, depth + 1, ctx);
					if (ch == null) node.denied = true else node.children = ch;
				}
			} else {
				ctx.files++;
				if (ctx.showSize) {
					try node.size = sys.FileSystem.stat(full).size catch (e:Dynamic) {};
				}
			}
			nodes.push(node);
		}

		// 排序：目录在前，其后按名称（忽略大小写）升序
		nodes.sort(function(a, b) {
			if (a.dir != b.dir) return a.dir ? -1 : 1;
			return Reflect.compare(a.name.toLowerCase(), b.name.toLowerCase());
		});
		return nodes;
	}

	// ------------------------------------------------------------------
	// 渲染
	// ------------------------------------------------------------------

	static function format(root:String, ctx:Ctx, children:Array<Node>):String {
		var sb = new StringBuf();
		var rootLabel = root == "." ? "." : StringTools.replace(root, "\\", "/");
		sb.add(rootLabel + "/\n");

		if (children == null) {
			sb.add("（无法访问该目录）\n");
			return sb.toString();
		}
		if (children.length == 0)
			sb.add("（空目录）\n");
		else
			renderChildren(sb, children, "", ctx.showSize);

		var summary = '共 ${ctx.dirs} 个目录, ${ctx.files} 个文件';
		if (ctx.dirsOnly) summary += "（仅目录）";
		if (ctx.truncated) summary += '，已达到上限 ${ctx.limit} 个条目，可能被截断';
		sb.add(summary + "\n");
		return sb.toString();
	}

	static function renderChildren(sb:StringBuf, children:Array<Node>, prefix:String, showSize:Bool):Void {
		for (i in 0...children.length) {
			var c = children[i];
			var last = i == children.length - 1;
			sb.add(prefix);
			sb.add(last ? "└── " : "├── ");
			sb.add(c.name);
			if (c.dir) {
				sb.add("/");
				if (c.denied) sb.add("  [无法访问]");
			} else if (showSize) {
				sb.add("  " + humanSize(c.size));
			}
			sb.add("\n");
			if (c.dir && c.children != null && c.children.length > 0)
				renderChildren(sb, c.children, prefix + (last ? "    " : "│   "), showSize);
		}
	}

	static function humanSize(bytes:Int):String {
		if (bytes < 1024) return bytes + "B";
		var kb = bytes / 1024;
		if (kb < 1024) return round1(kb) + "K";
		var mb = kb / 1024;
		if (mb < 1024) return round1(mb) + "M";
		return round1(mb / 1024) + "G";
	}

	static function round1(v:Float):String {
		var r = Math.round(v * 10) / 10;
		return Std.string(r);
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

/** 树节点。 */
private typedef Node = {
	var name:String;
	var dir:Bool;
	var size:Int;
	var children:Null<Array<Node>>;
	var denied:Bool; // 目录存在但无法读取
}

/** 递归过程中的上下文与统计。 */
private typedef Ctx = {
	var maxDepth:Int;
	var limit:Int;
	var dirsOnly:Bool;
	var includeHidden:Bool;
	var showSize:Bool;
	var ignore:Map<String, Bool>;
	var count:Int;
	var dirs:Int;
	var files:Int;
	var truncated:Bool;
}
