package api;

/**
 * 模型停止生成的原因。
 */
enum abstract FinishReason(String) from String to String {
	/** 正常结束。 */
	var Stop = "stop";
	/** 达到 max_tokens 上限。 */
	var Length = "length";
	/** 模型要求调用工具，需执行后继续对话。 */
	var ToolCalls = "tool_calls";
	/** 内容被安全策略过滤。 */
	var ContentFilter = "content_filter";
	/** 发生错误。 */
	var Error = "error";
	/** 未知 / 厂商特有原因。 */
	var Unknown = "unknown";
}
