package api;

/**
 * 暴露给模型的工具（函数）定义。
 */
typedef ToolDefinition = {
	/** 工具名称，需与 ToolCall.name 对应。 */
	var name:String;
	/** 用途说明，直接影响模型是否正确使用。 */
	var description:String;
	/** JSON Schema：描述入参结构。 */
	var parameters:Dynamic;
	/** 是否严格按 schema 输出（部分厂商支持）。 */
	@:optional var strict:Bool;
}
