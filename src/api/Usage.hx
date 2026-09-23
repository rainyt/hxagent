package api;

/**
 * token 用量统计。
 */
typedef Usage = {
	@:optional var promptTokens:Int;
	@:optional var completionTokens:Int;
	@:optional var totalTokens:Int;
	/** 推理模型的思考 token。 */
	@:optional var reasoningTokens:Int;
}
