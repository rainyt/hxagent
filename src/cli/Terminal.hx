package cli;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Eof;

/**
 * 终端行输入器。
 *
 * 编码要点（Windows）：
 *  - `Sys.getChar` 走的是 Windows 控制台 API，会把输入按本地代码页（中文系统为
 *    GBK/936）返回**字节**；若再用 `String.fromCharCode` 逐字节处理，每个字节会被
 *    重新按 UTF-8 编码，导致 `你好` -> `ÄãºÃ` 这类乱码。
 *  - `Sys.stdin()` 按字节读取则是原样透传，配合 UTF-8 终端即可正确处理中文。
 *
 * 因此默认使用 `readLine()`（基于 stdin 的字节读取）；只有在需要逐字符自定义编辑、
 * 且控制台编码已是 UTF-8 时，才使用 `readEditedLine()`。
 */
class Terminal {
	/**
	 * 初始化终端：在 Windows 下尽量把控制台代码页切到 UTF-8(65001)，
	 * 以修复中文输入 / 输出乱码。非 Windows 或失败时静默忽略。
	 */
	public static function setup():Void {
		#if sys
		if (Sys.systemName() == "Windows") {
			try Sys.command("chcp 65001 >nul") catch (e:Dynamic) {};
		}
		#end
	}

	/**
	 * 阻塞读取一行（推荐）。
	 *
	 * 从 stdin 按字节读取，原样保留终端送来的编码（UTF-8 终端下中文正常）。
	 * 行编辑（退格等）与回显由终端自身负责，适合标准行输入场景。
	 */
	public static function readLine(prompt:String = "> "):LineResult {
		if (prompt != "")
			Sys.print(prompt);

		var buf = new BytesBuffer();
		while (true) {
			var b:Int;
			try {
				b = Sys.stdin().readByte();
			} catch (e:Eof) {
				// 输入流结束：若已读到内容则返回该行，否则报告 EOF。
				return buf.length > 0 ? Line(buf.getBytes().toString()) : Eof;
			}

			if (b == 10) // '\n'
				break;
			if (b == 13) // '\r'（Windows CRLF）
				continue;

			buf.addByte(b);
		}
		return Line(buf.getBytes().toString());
	}

	/**
	 * 逐字符读取并自行编辑（退格 / 回车 / Ctrl+C / Ctrl+D）。
	 *
	 * 相比 `readLine` 能实时响应按键，但依赖 `Sys.getChar` 返回** UTF-8 字节 **。
	 * 在 Windows 上请先调用 `setup()`（chcp 65001），否则中文仍是 GBK 字节。
	 */
	public static function readEditedLine(prompt:String = "> "):LineResult {
		if (prompt != "")
			Sys.print(prompt);

		// 以原始字节累积，避免 fromCharCode 造成二次编码。
		var data:Array<Int> = [];

		while (true) {
			var code:Int;
			try {
				code = Sys.getChar(false); // false：关闭底层回显，由我们自己控制
			} catch (e:Eof) {
				return Eof;
			}

			// Windows 下方向键 / 功能键先返回 0 或 224，再跟一个扫描码，直接吞掉。
			if (code == 0 || code == 224) {
				try Sys.getChar(false) catch (e:Eof) {};
				continue;
			}

			switch (code) {
				case -1:
					return Eof;
				case 3: // Ctrl+C
					Sys.println("");
					return Interrupt;
				case 4: // Ctrl+D：仅当当前行为空时视为 EOF
					if (data.length == 0) {
						Sys.println("");
						return Eof;
					}
				case 10 | 13: // Enter（\n 或 \r）
					Sys.println("");
					return Line(bytesToString(data));
				case 8 | 127: // Backspace / DEL：按 UTF-8 码点整体删除
					var removed = eraseLastCodePoint(data);
					for (_ in 0...removed)
						writeRaw([8, 32, 8]); // 退格、空格覆盖、再退格
				default:
					if (code >= 32) {
						var b = code & 0xFF;
						data.push(b);
						writeRaw([b]);
					}
			}
		}
	}

	/** 供管道 / 重定向输入使用的整行读取（与 `readLine` 等价，保留以兼容旧调用）。 */
	public static function readLineFromStdin():LineResult {
		return readLine("");
	}

	/** ANSI 清屏并回到左上角（需要终端支持 ANSI）。 */
	public static function clear():Void {
		var esc = String.fromCharCode(27);
		Sys.print(esc + "[2J" + esc + "[H");
	}

	// ---- 内部工具 ----

	/** 把原始字节数组按原样写回终端（不重新编码）。 */
	static function writeRaw(bytes:Array<Int>):Void {
		var out = Bytes.alloc(bytes.length);
		for (i in 0...bytes.length)
			out.set(i, bytes[i] & 0xFF);
		Sys.print(out.toString());
	}

	/** 把字节数组还原成 Haxe 字符串（字节原样保留）。 */
	static function bytesToString(data:Array<Int>):String {
		var out = Bytes.alloc(data.length);
		for (i in 0...data.length)
			out.set(i, data[i] & 0xFF);
		return out.toString();
	}

	/**
	 * 删除最后一个 UTF-8 码点（含所有后续 continuation 字节），
	 * 返回实际删除的字节数。
	 */
	static function eraseLastCodePoint(data:Array<Int>):Int {
		if (data.length == 0)
			return 0;
		var i = data.length - 1;
		// 跳过 10xxxxxx 的 continuation 字节
		while (i > 0 && (data[i] & 0xC0) == 0x80)
			i--;
		var removed = data.length - i; // continuation 数 + 1 个首字节
		for (_ in 0...removed)
			data.pop();
		return removed;
	}
}
