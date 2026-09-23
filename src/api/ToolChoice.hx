package api;

/**
 * 工具选择策略。
 */
enum ToolChoice {
	/** 由模型自行决定（默认）。 */
	Auto;
	/** 禁止调用工具。 */
	None;
	/** 必须调用至少一个工具。 */
	Required;
	/** 必须调用指定名称的工具。 */
	Specific(name:String);
}
