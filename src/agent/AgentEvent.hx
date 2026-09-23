package agent;

import api.ApiError;
import api.Usage;
import api.tools.ToolResult;

/**
 * Agent 循环对外暴露的事件。
 *
 * 相比底层 `api.StreamEvent`，这里补充了「工具执行」的信息，
 * 让 UI 能展示 Agent 的完整思考 / 行动过程。
 */
enum AgentEvent {
	/** 模型输出的正文增量。 */
	TextDelta(text:String);
	/** 模型输出的推理增量（deepseek-reasoner 等）。 */
	ReasoningDelta(text:String);
	/** 开始执行某个工具调用。 */
	ToolCallStarted(name:String, args:Dynamic);
	/** 工具执行结果。 */
	ToolCallResult(name:String, callId:String, result:ToolResult);
	/** 本回合最终回答完成（usage 可能为 null）。 */
	Done(content:String, usage:Usage);
	/** 出错。 */
	Error(error:ApiError);
}
