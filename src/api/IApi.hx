package api;

/**
 * 对接大模型 API 的统一接口。
 *
 * 设计约定：
 *  - 统一用「事件回调」暴露结果，天然支持流式；非流式请求也走同一套事件，
 *    最终只推送一个 Done。
 *  - 只使用厂商无关的类型（Message / ToolDefinition / ChatResponse），
 *    由各 Provider 适配器负责与 OpenAI、Anthropic 等具体协议互转。
 *  - 不抛异常，所有失败都通过 Error 事件或 ApiResult.Failure 返回。
 */
interface IApi {
	/**
	 * 发起一次对话补全。
	 * @param request 厂商无关的请求参数
	 * @param onEvent 接收 Start / Delta / Done / Error 事件
	 * @return 可取消句柄
	 */
	function chat(request:ChatRequest, onEvent:StreamEvent->Void):Cancelable;

	/**
	 * 查询可用模型列表（可选能力；不支持的适配器返回 Failure）。
	 */
	function listModels(onResult:ApiResult<Array<ModelInfo>>->Void):Cancelable;

	/** 释放底层资源（HTTP 连接等）。 */
	function dispose():Void;
}
