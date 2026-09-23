package api;

/**
 * 统一的 API 错误。
 */
typedef ApiError = {
	var message:String;
	/** 厂商错误码 / 业务码。 */
	@:optional var code:String;
	/** HTTP 状态码。 */
	@:optional var status:Int;
	/** 错误类型，如 invalid_request_error、rate_limit_error。 */
	@:optional var type:String;
	/** 是否建议重试（限流、超时、5xx）。 */
	@:optional var retryable:Bool;
	/** 原始错误体。 */
	@:optional var raw:Dynamic;
}
