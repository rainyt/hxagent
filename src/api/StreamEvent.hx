package api;

/**
 * 流式事件。无论是否开启流式，最终都会收到 Done 或 Error。
 */
enum StreamEvent {
	/** 开始：返回响应 id 与模型名。 */
	Start(id:String, model:String);
	/** 文本增量。 */
	TextDelta(text:String);
	/** 思考 / 推理增量（推理模型）。 */
	ReasoningDelta(text:String);
	/**
	 * 工具调用增量。模型分片给出工具名与 JSON 参数，
	 * index 用于区分同一回复中的多个工具调用。
	 */
	ToolCallDelta(index:Int, id:String, name:String, argumentsDelta:String);
	/** 结束：携带聚合后的完整响应。 */
	Done(response:ChatResponse);
	/** 出错：流中途出错时可能已收到部分增量。 */
	Error(error:ApiError);
}
