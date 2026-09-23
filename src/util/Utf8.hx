package util;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * UTF-8 安全转换工具。
 *
 * Haxe eval 上：
 *  - `Bytes.toString()` 遇到非法 UTF-8 字节会抛 `Invalid string`；
 *  - `Json.stringify` 遇到含非法 UTF-8 的字符串同样会抛 `Invalid string`。
 *
 * 本工具在无法直接解码时，用 U+FFFD（�）替换非法字节，保证总能得到合法字符串，
 * 避免把「编码问题」升级成「整轮请求失败」。
 */
class Utf8 {
	/** 把字节安全地转成字符串；非法序列替换为 U+FFFD，不抛异常。 */
	public static function safe(bytes:Bytes):String {
		if (bytes == null) return "";
		try {
			return bytes.toString(); // 合法 UTF-8 的快路径
		} catch (e:Dynamic) {
			// 含非法 UTF-8，走下面的替换路径
		}

		var out = new BytesBuffer();
		var i = 0;
		var len = bytes.length;
		while (i < len) {
			var n = seqLen(bytes, i, len);
			if (n == 0) {
				// 追加 U+FFFD 的 UTF-8 编码 EF BF BD
				out.addByte(0xEF);
				out.addByte(0xBF);
				out.addByte(0xBD);
				i++;
			} else {
				out.addBytes(bytes, i, n);
				i += n;
			}
		}
		return out.getBytes().toString();
	}

	/**
	 * 判断位置 i 是否是一个合法 UTF-8 序列，返回其字节长度；非法返回 0。
	 * 会拒绝过长编码、代理区、超出 U+10FFFF 的码点。
	 */
	static function seqLen(b:Bytes, i:Int, len:Int):Int {
		var c = b.get(i);
		if (c < 0x80) return 1;

		var n:Int;
		var min:Int;
		if ((c & 0xE0) == 0xC0) {
			n = 2;
			min = 0x80;
		} else if ((c & 0xF0) == 0xE0) {
			n = 3;
			min = 0x800;
		} else if ((c & 0xF8) == 0xF0) {
			n = 4;
			min = 0x10000;
		} else {
			return 0;
		}

		if (i + n > len) return 0;
		var cp = c & (0x7F >> n);
		for (k in 1...n) {
			var cb = b.get(i + k);
			if ((cb & 0xC0) != 0x80) return 0;
			cp = (cp << 6) | (cb & 0x3F);
		}
		if (cp < min) return 0; // 过长编码
		if (cp > 0x10FFFF) return 0;
		if (cp >= 0xD800 && cp <= 0xDFFF) return 0; // 代理区
		return n;
	}
}
