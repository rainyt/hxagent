package api;

/**
 * 模型请求调用某个工具。
 */
typedef ToolCall = {
	/** 唯一 id，用于把执行结果回填到对应调用。 */
	var id:String;
	/** 工具名称，对应 ToolDefinition.name。 */
	var name:String;
	/** 已解析的参数对象（JSON）。 */
	var arguments:Dynamic;
	/** 原始参数 JSON 字符串，流式累积 / 调试用。 */
	@:optional var rawArguments:String;
}
