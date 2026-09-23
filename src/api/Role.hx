package api;

/**
 * 聊天消息角色。
 * 以 String 为底层类型，便于在各厂商协议间直接映射。
 */
enum abstract Role(String) from String to String {
	/** 系统提示词，设定 Agent 的身份与行为准则。 */
	var System = "system";
	/** 用户输入。 */
	var User = "user";
	/** 模型回复。 */
	var Assistant = "assistant";
	/** 工具 / 函数执行结果。 */
	var Tool = "tool";
	/** 部分模型用 developer 替代 system。 */
	var Developer = "developer";
}
