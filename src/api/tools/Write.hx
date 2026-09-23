package api.tools;

import api.ToolDefinition;
import haxe.io.Bytes;
import haxe.io.Path;

/**
 * Write 工具：把文本写入本机文件，供 AI 创建 / 覆盖 / 追加文件。
 *
 * 参数（JSON Schema）：
 *  - path        string   目标文件路径（绝对或相对当前工作目录）—— 必填
 *  - content     string   要写入的文本内容 —— 必填
 *  - append      boolean  true 表示追加到末尾，默认 false（覆盖）
 *  - create_dirs boolean  父目录不存在时是否自动创建，默认 true
 *
 * 注意：覆盖是整文件替换。若只需修改文件中的一小段，应配合 Read 读取后再写入。
 */
class Write implements ITool {
	public static inline var NAME = "Write";

	public var definition:ToolDefinition;

	public function new() {
		definition = {
			name: NAME,
			description: "将文本写入本机文件。默认覆盖已有内容；append=true 时追加到末尾。父目录不存在时默认会自动创建。",
			parameters: {
				type: "object",
				properties: {
					path: {type: "string", description: "目标文件路径（绝对或相对于当前工作目录）"},
					content: {type: "string", description: "要写入的文本内容"},
					append: {type: "boolean", description: "true 表示追加到文件末尾，默认 false（覆盖）"},
					create_dirs: {type: "boolean", description: "父目录不存在时是否自动创建，默认 true"}
				},
				required: ["path", "content"]
			}
		};
	}

	public function execute(args:Dynamic):ToolResult {
		if (args == null)
			return fail("缺少参数");

		var path:String = args.path != null ? Std.string(args.path) : null;
		if (path == null || StringTools.trim(path) == "")
			return fail("缺少 path 参数");
		if (args.content == null)
			return fail("缺少 content 参数");

		var content:String = Std.string(args.content);
		var append = boolArg(args.append, false);
		var createDirs = boolArg(args.create_dirs, true);

		// 目标不能是已存在的目录
		try {
			if (sys.FileSystem.exists(path) && sys.FileSystem.isDirectory(path))
				return fail('路径是一个目录，无法写入: $path');
		} catch (e:Dynamic) {
			return fail('无法访问路径: $path (' + Std.string(e) + ')');
		}

		// 处理父目录
		var dir = Path.directory(path);
		if (dir != null && dir != "" && !sys.FileSystem.exists(dir)) {
			if (!createDirs)
				return fail('父目录不存在: $dir（可设置 create_dirs=true）');
			try {
				mkdirs(dir);
			} catch (e:Dynamic) {
				return fail('创建目录失败: $dir (' + Std.string(e) + ')');
			}
		}

		var size = Bytes.ofString(content).length;
		try {
			// 用二进制模式读写，避免 Windows 文本模式把 \n 转成 \r\n
			var out = append ? sys.io.File.append(path, true) : sys.io.File.write(path, true);
			out.writeString(content);
			out.close();
		} catch (e:Dynamic) {
			return fail('写入失败: ' + Std.string(e));
		}

		return {content: '${append ? "追加" : "写入"}成功: $path（$size 字节，UTF-8）'};
	}

	// ------------------------------------------------------------------

	static function fail(message:String):ToolResult {
		return {content: message, isError: true};
	}

	/** 递归创建目录（sys.FileSystem.createDirectory 只创建单层）。 */
	static function mkdirs(dir:String):Void {
		if (dir == null || dir == "" || dir == "." || sys.FileSystem.exists(dir))
			return;
		var parent = Path.directory(dir);
		if (parent != null && parent != "" && parent != dir)
			mkdirs(parent);
		sys.FileSystem.createDirectory(dir);
	}

	static function boolArg(v:Dynamic, def:Bool):Bool {
		if (v == null) return def;
		if (Std.isOfType(v, Bool)) return v;
		var s = Std.string(v).toLowerCase();
		if (s == "true" || s == "1") return true;
		if (s == "false" || s == "0") return false;
		return def;
	}
}
