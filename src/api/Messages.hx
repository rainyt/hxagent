package api;

/**
 * 构造 Message 的便捷工厂，避免到处写对象字面量。
 */
class Messages {
	public static inline function system(content:String, ?name:String):Message
		return {role: Role.System, content: content, name: name};

	public static inline function user(content:String, ?name:String):Message
		return {role: Role.User, content: content, name: name};

	public static inline function assistant(content:String, ?toolCalls:Array<ToolCall>, ?name:String):Message
		return {role: Role.Assistant, content: content, toolCalls: toolCalls, name: name};

	public static inline function tool(toolCallId:String, content:String, ?name:String):Message
		return {role: Role.Tool, content: content, toolCallId: toolCallId, name: name};
}
