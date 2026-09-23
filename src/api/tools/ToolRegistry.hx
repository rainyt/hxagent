package api.tools;

import api.ToolDefinition;

/**
 * 工具注册表：集中管理多个工具，向模型提供定义列表，并按名称分发调用。
 *
 * 典型用法（配合 IApi）：
 * ```haxe
 * var tools = new ToolRegistry().add(new Read());
 * api.chat({messages: history, tools: tools.definitions(), stream: true}, onEvent);
 * // 收到 ToolCall 后：
 * var result = tools.call(call.name, call.arguments);
 * ```
 */
class ToolRegistry {
	var order:Array<ITool> = [];
	var byName:Map<String, ITool> = new Map();

	public function new() {}

	/** 注册一个工具（同名覆盖，保留首次注册顺序）。 */
	public function add(tool:ITool):ToolRegistry {
		if (!byName.exists(tool.definition.name))
			order.push(tool);
		byName.set(tool.definition.name, tool);
		return this;
	}

	public function has(name:String):Bool {
		return byName.exists(name);
	}

	public function get(name:String):ITool {
		return byName.get(name);
	}

	/** 提供给 ChatRequest.tools 的定义列表（保持注册顺序）。 */
	public function definitions():Array<ToolDefinition> {
		return [for (t in order) t.definition];
	}

	/** 按名称执行工具；未知工具返回错误结果而不是抛异常。 */
	public function call(name:String, args:Dynamic):ToolResult {
		var t = byName.get(name);
		if (t == null)
			return {content: '错误: 未知工具 "$name"', isError: true};
		try {
			return t.execute(args);
		} catch (e:Dynamic) {
			return {content: '错误: 工具 "$name" 执行失败: ' + Std.string(e), isError: true};
		}
	}
}
