package api;

/**
 * Provider 适配器的通用配置。
 * 具体适配器可在此基础上扩展自己专有的字段。
 */
typedef ApiConfig = {
	/** API 根地址，如 https://api.openai.com/v1 。 */
	@:optional var baseUrl:String;
	/** 鉴权密钥。 */
	@:optional var apiKey:String;
	/** 默认模型，请求未指定 model 时使用。 */
	@:optional var defaultModel:String;
	/** 单次请求超时（毫秒）。 */
	@:optional var timeoutMs:Int;
	/** 失败重试次数（针对可重试错误）。 */
	@:optional var maxRetries:Int;
	/** 额外请求头。 */
	@:optional var headers:haxe.DynamicAccess<String>;
	/** 组织 / 项目标识（OpenAI 等使用）。 */
	@:optional var organization:String;
}
