package api;

/**
 * 一次对话补全请求（厂商无关）。
 */
typedef ChatRequest = {
	/** 对话历史，按时间顺序排列，通常第一条是 system。 */
	var messages:Array<Message>;
	/** 覆盖客户端默认模型。 */
	@:optional var model:String;
	/** 可调用的工具列表。 */
	@:optional var tools:Array<ToolDefinition>;
	/** 工具选择策略，默认 Auto。 */
	@:optional var toolChoice:ToolChoice;
	@:optional var temperature:Float;
	@:optional var topP:Float;
	@:optional var maxTokens:Int;
	/** 停止序列。 */
	@:optional var stop:Array<String>;
	/** 是否流式返回。 */
	@:optional var stream:Bool;
	/** 厂商专有参数透传（如 reasoning_effort、response_format 等）。 */
	@:optional var extra:haxe.DynamicAccess<Dynamic>;
}
