package cli;

/**
 * 终端读取一行的结果。
 */
enum LineResult {
	/** 用户回车提交的一行内容（可能为空串）。 */
	Line(text:String);
	/** 输入流结束（Ctrl+D 或 stdin 关闭）。 */
	Eof;
	/** 用户按下 Ctrl+C。 */
	Interrupt;
}
