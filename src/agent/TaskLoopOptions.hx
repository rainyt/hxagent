package agent;

/**
 * TaskLoop 的可选配置。
 */
typedef TaskLoopOptions = {
	/** 系统提示词。 */
	@:optional var systemPrompt:String;
	/** 覆盖默认模型。 */
	@:optional var model:String;
	@:optional var temperature:Float;
	@:optional var maxTokens:Int;
	/** 单回合内最多允许的工具调用轮次，防止死循环。默认 10。 */
	@:optional var maxIterations:Int;
}
