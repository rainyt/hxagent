package api.tools;

/**
 * 工具执行结果，最终会作为 `role=tool` 的消息内容回填给模型。
 */
typedef ToolResult = {
	/** 返回给模型的结果文本。 */
	var content:String;
	/** 是否为错误结果（模型可据此重试或调整）。 */
	@:optional var isError:Bool;
}
