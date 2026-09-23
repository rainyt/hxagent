package api;

/**
 * 一次对话补全的结果。
 */
typedef ChatResponse = {
	@:optional var id:String;
	@:optional var model:String;
	/** 模型回复（可能同时包含文本与工具调用）。 */
	var message:Message;
	/** 结束原因。 */
	var finishReason:FinishReason;
	@:optional var usage:Usage;
	/** 原始响应，访问未建模字段或排查厂商差异时使用。 */
	@:optional var raw:Dynamic;
}
