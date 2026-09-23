package api;

/**
 * 一条对话消息，是 Agent 与模型交互的基本单元。
 */
typedef Message = {
	/** 消息角色。 */
	var role:Role;
	/** 文本内容；assistant 发起工具调用时通常为空。 */
	@:optional var content:String;
	/** 可选名称。 */
	@:optional var name:String;
	/** assistant 消息中模型请求调用的工具。 */
	@:optional var toolCalls:Array<ToolCall>;
	/** role=tool 时，对应的工具调用 id。 */
	@:optional var toolCallId:String;
}
