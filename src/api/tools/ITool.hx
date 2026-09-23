package api.tools;

import api.ToolDefinition;

/**
 * 可供 AI 调用的工具。
 *
 * 实现者需要提供：
 *  - `definition`：名称、描述、参数 JSON Schema（用于告知模型）；
 *  - `execute`：接收已解析的 JSON 参数，返回结果文本。
 */
interface ITool {
	/** 工具元数据，会被放进 ChatRequest.tools。 */
	var definition:ToolDefinition;

	/** 执行工具。args 为模型给出的、已解析为对象的参数。 */
	function execute(args:Dynamic):ToolResult;
}
