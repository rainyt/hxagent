package api.tools;

import api.ToolDefinition;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Eof;
import util.Utf8;

/**
 * Read 工具：读取本机上的文本文件，供 AI 读取代码 / 文档 / 配置等。
 *
 * 参数（JSON Schema）：
 *  - path   string   文件路径（绝对或相对当前工作目录）—— 必填
 *  - offset integer  起始行号（1-based），默认 1
 *  - limit  integer  最多读取行数，默认 2000
 *
 * 返回带行号的文本（`行号→内容`），便于模型定位。
 * 出于上下文长度考虑，单次输出有字节上限，超出会截断并提示。
 */
class Read implements ITool {
	public static inline var NAME = "Read";

	/** 默认读取行数。 */
	static inline var DEFAULT_LIMIT = 2000;
	/** 单次返回内容的字节上限，避免撑爆上下文。 */
	static inline var MAX_BYTES = 256 * 1024;
	/** 二进制探测读取的头部字节数。 */
	static inline var SNIFF_BYTES = 8192;

	public var definition:ToolDefinition;

	public function new() {
		definition = {
			name: NAME,
			description: "读取本机上的文本文件内容。返回带行号的文本，便于定位；可用 offset/limit 分段读取大文件。",
			parameters: {
				type: "object",
				properties: {
					path: {type: "string", description: "要读取的文件路径（绝对或相对于当前工作目录）"},
					offset: {type: "integer", description: "起始行号（从 1 开始），默认 1"},
					limit: {type: "integer", description: "最多读取的行数，默认 " + DEFAULT_LIMIT}
				},
				required: ["path"]
			}
		};
	}

	public function execute(args:Dynamic):ToolResult {
		var path:String = args != null ? args.path : null;
		if (path == null || StringTools.trim(path) == "")
			return {content: "错误: 缺少 path 参数", isError: true};

		var offset = intArg(args.offset, 1);
		var limit = intArg(args.limit, DEFAULT_LIMIT);
		if (offset < 1) offset = 1;
		if (limit < 1) limit = DEFAULT_LIMIT;

		if (!sys.FileSystem.exists(path))
			return {content: '错误: 文件不存在: $path', isError: true};

		try {
			if (sys.FileSystem.isDirectory(path))
				return {content: '错误: 这是一个目录，不是文件: $path', isError: true};
		} catch (e:Dynamic) {
			return {content: '错误: 无法访问: $path (' + Std.string(e) + ')', isError: true};
		}

		try {
			if (looksBinary(path))
				return {content: '错误: 疑似二进制文件，无法作为文本读取: $path', isError: true};
			return {content: readLines(path, offset, limit)};
		} catch (e:Dynamic) {
			return {content: '错误: 读取失败: ' + Std.string(e), isError: true};
		}
	}

	// ------------------------------------------------------------------

	/** 读取指定行区间，返回带行号文本。 */
	static function readLines(path:String, offset:Int, limit:Int):String {
		var input = sys.io.File.read(path, true);
		var sb = new StringBuf();
		var lineBuf = new BytesBuffer();
		var lineNo = 0;
		var shown = 0;
		var bytes = 0;
		var truncated = false;

		// 逐字节读取并按 \n 切行，再用 Utf8.safe 宽容解码（支持非 UTF-8 文件）
		try {
			while (true) {
				var c = input.readByte();
				if (c != 10) {
					lineBuf.addByte(c);
					continue;
				}
				var line = Utf8.safe(lineBuf.getBytes());
				lineBuf = new BytesBuffer();
				if (StringTools.endsWith(line, "\r"))
					line = line.substr(0, line.length - 1);
				lineNo++;
				if (lineNo < offset) continue;
				if (shown >= limit || bytes >= MAX_BYTES) {
					truncated = true;
					break;
				}
				sb.add(lineNo);
				sb.add("→");
				sb.add(line);
				sb.add("\n");
				shown++;
				bytes += line.length + 1;
			}
		} catch (e:Eof) {
			// 文件末尾可能没有换行符
			if (lineBuf.length > 0) {
				var line = Utf8.safe(lineBuf.getBytes());
				if (StringTools.endsWith(line, "\r"))
					line = line.substr(0, line.length - 1);
				lineNo++;
				if (lineNo >= offset && shown < limit && bytes < MAX_BYTES) {
					sb.add(lineNo);
					sb.add("→");
					sb.add(line);
					sb.add("\n");
					shown++;
				} else if (lineNo >= offset) {
					truncated = true;
				}
			}
		}
		input.close();

		if (shown == 0)
			return '（没有内容：offset=$offset 超出文件末尾，共 $lineNo 行）';

		var header = '$path  [第 $offset-${offset + shown - 1} 行]';
		if (truncated) header += '（已截断，可用 offset 继续读取）';
		return header + "\n" + sb.toString();
	}

	/** 通过头部是否含 NUL 字节来粗略判断二进制文件。 */
	static function looksBinary(path:String):Bool {
		var input = sys.io.File.read(path, true);
		var head = Bytes.alloc(SNIFF_BYTES);
		var n = 0;
		try {
			n = input.readBytes(head, 0, SNIFF_BYTES);
		} catch (e:Eof) {
			// 文件比探测长度短，n 保持已读值
		}
		input.close();
		for (i in 0...n) {
			if (head.get(i) == 0)
				return true;
		}
		return false;
	}

	static function intArg(v:Dynamic, def:Int):Int {
		if (v == null) return def;
		if (Std.isOfType(v, Int)) return v;
		if (Std.isOfType(v, Float)) return Std.int(v);
		var n = Std.parseInt(Std.string(v));
		return n != null ? n : def;
	}
}
