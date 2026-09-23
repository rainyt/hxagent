package ai.deepseek;

import api.ApiConfig;
import api.ApiError;
import api.ApiResult;
import api.Cancelable;
import api.ChatRequest;
import api.ChatResponse;
import api.FinishReason;
import api.IApi;
import api.Message;
import api.ModelInfo;
import api.Role;
import api.StreamEvent;
import api.ToolCall;
import api.ToolChoice;
import api.ToolDefinition;
import api.Usage;
import haxe.Json;
import haxe.ds.IntMap;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import util.Utf8;

/**
 * 工具调用流式累积的中间态。
 */
private typedef ToolAcc = {
	var id:String;
	var name:String;
	var args:StringBuf;
}

/**
 * DeepSeek API 适配器（OpenAI 兼容协议）。
 *
 * 支持：
 *  - 流式（SSE）与非流式对话补全；
 *  - Function Calling（工具调用增量聚合）；
 *  - deepseek-reasoner 的 reasoning_content 推理增量；
 *  - 模型列表查询。
 *
 * 说明：`sys.Http` 在本项目目标（--interp / eval）上是**同步阻塞**的，
 * 因此 `chat()` 会在事件回调逐条推送期间阻塞，直到本次响应结束。
 * 这也意味着返回的 `Cancelable` 只能在回调内部（同一线程）取消；
 * 若后续需要跨线程取消，应改为 `sys.thread` 后台执行。
 *
 * 用法：
 * ```haxe
 * var api = new Deepseek({apiKey: Sys.getEnv("DEEPSEEK_API_KEY")});
 * api.chat({messages: [Messages.user("你好")], stream: true}, function(e) switch e {
 *     case TextDelta(t): Sys.print(t);
 *     case Done(r):      Sys.println("");
 *     case Error(err):   Sys.println("错误: " + err.message);
 *     case _:
 * });
 * ```
 */
class Deepseek implements IApi {
	static inline var DEFAULT_BASE_URL = "https://api.deepseek.com";
	static inline var DEFAULT_MODEL = "deepseek-chat";

	var config:ApiConfig;
	var baseUrl:String;
	var apiKey:String;
	var defaultModel:String;
	var timeoutMs:Int;

	public function new(config:ApiConfig) {
		this.config = config != null ? config : {};
		this.baseUrl = stripSlash(this.config.baseUrl != null ? this.config.baseUrl : DEFAULT_BASE_URL);
		this.defaultModel = this.config.defaultModel != null ? this.config.defaultModel : DEFAULT_MODEL;
		this.timeoutMs = this.config.timeoutMs != null ? this.config.timeoutMs : 120000;
		this.apiKey = this.config.apiKey != null ? this.config.apiKey : "";
	}

	// ------------------------------------------------------------------
	// IApi
	// ------------------------------------------------------------------

	public function chat(request:ChatRequest, onEvent:StreamEvent->Void):Cancelable {
		var cancelled = false;
		var stream = request.stream == true;
		var errorEmitted = false;

		// ---- 聚合状态 ----
		var accId:String = null;
		var accModel:String = null;
		var accText = new StringBuf();
		var accReasoning = new StringBuf();
		var accTools = new IntMap<ToolAcc>();
		var toolOrder:Array<Int> = [];
		var accFinish:FinishReason = FinishReason.Unknown;
		var accUsage:Usage = null;
		var lastRaw:Dynamic = null;
		var started = false;

		function ensureStart():Void {
			if (!started) {
				started = true;
				onEvent(Start(accId != null ? accId : "", accModel != null ? accModel : ""));
			}
		}

		function fail(message:String, ?raw:Dynamic):Void {
			if (errorEmitted) return;
			errorEmitted = true;
			onEvent(Error({message: message, raw: raw}));
		}

		function handleChunk(j:Dynamic):Void {
			lastRaw = j;
			if (j.id != null) accId = j.id;
			if (j.model != null) accModel = j.model;
			if (j.usage != null) accUsage = parseUsage(j.usage);
			ensureStart();

			var choices:Array<Dynamic> = j.choices;
			if (choices == null) return;

			for (i in 0...choices.length) {
				var c = choices[i];
				// 流式用 delta，非流式用 message
				var d = c.delta != null ? c.delta : c.message;
				if (d != null) {
					// deepseek-reasoner 的思考过程
					if (d.reasoning_content != null) {
						var t:String = d.reasoning_content;
						if (t.length > 0) {
							accReasoning.add(t);
							onEvent(ReasoningDelta(t));
						}
					}
					// 正文
					if (d.content != null) {
						var t:String = d.content;
						if (t.length > 0) {
							accText.add(t);
							onEvent(TextDelta(t));
						}
					}
					// 工具调用（增量）
					var tcs:Array<Dynamic> = d.tool_calls;
					if (tcs != null) {
						for (k in 0...tcs.length) {
							var tc = tcs[k];
							var idx:Int = tc.index != null ? (tc.index : Int) : k;
							var entry = accTools.get(idx);
							if (entry == null) {
								entry = {id: null, name: null, args: new StringBuf()};
								accTools.set(idx, entry);
								toolOrder.push(idx);
							}
							if (tc.id != null) entry.id = tc.id;

							var tname = "";
							var targs = "";
							var fn = tc.function;
							if (fn != null) {
								if (fn.name != null) {
									entry.name = fn.name;
									tname = fn.name;
								}
								if (fn.arguments != null) {
									targs = fn.arguments;
									entry.args.add(targs);
								}
							}
							onEvent(ToolCallDelta(idx, tc.id != null ? tc.id : "", tname, targs));
						}
					}
				}
				if (c.finish_reason != null)
					accFinish = c.finish_reason;
			}
		}

		function finalize():Void {
			if (cancelled || errorEmitted) return;
			ensureStart();

			var calls:Array<ToolCall> = [];
			for (idx in toolOrder) {
				var e = accTools.get(idx);
				var rawArgs = e.args.toString();
				var parsed:Dynamic = null;
				if (rawArgs != null && StringTools.trim(rawArgs) != "") {
					try parsed = Json.parse(rawArgs) catch (err:Dynamic) parsed = null;
				}
				if (parsed == null) parsed = {};
				calls.push({
					id: e.id != null ? e.id : ("call_" + idx),
					name: e.name != null ? e.name : "",
					arguments: parsed,
					rawArguments: rawArgs
				});
			}
			if (calls.length > 0 && (accFinish == FinishReason.Unknown || accFinish == FinishReason.Stop))
				accFinish = FinishReason.ToolCalls;

			var message:Message = {
				role: Role.Assistant,
				content: accText.toString(),
				toolCalls: calls.length > 0 ? calls : null
			};
			onEvent(Done({
				id: accId,
				model: accModel,
				message: message,
				finishReason: accFinish,
				usage: accUsage,
				raw: lastRaw
			}));
		}

		// SSE：只关心 `data:` 行
		function onSseLine(line:String):Void {
			if (cancelled || errorEmitted) return;
			var s = StringTools.trim(line);
			if (s == "" || s.charAt(0) == ":") return; // 空行 / 注释(keep-alive)
			if (!StringTools.startsWith(s, "data:")) return;
			var data = StringTools.trim(s.substr(5));
			if (data == "[DONE]") return;
			try {
				handleChunk(Json.parse(data));
			} catch (e:Dynamic) {
				fail("解析流式响应失败: " + Std.string(e), data);
			}
		}

		var sink:ResponseSink = null;
		sink = new ResponseSink(stream ? onSseLine : null, function() {
			if (cancelled || errorEmitted) return;
			if (!stream) {
				var bytes = sink.takeRaw();
				var body = bytes != null ? Utf8.safe(bytes) : "";
				if (StringTools.trim(body) == "") {
					fail("空响应");
					return;
				}
				try {
					handleChunk(Json.parse(body));
				} catch (e:Dynamic) {
					fail("解析响应失败: " + Std.string(e), body);
					return;
				}
			}
			finalize();
		});

		var http = new RawHttp(baseUrl + "/chat/completions");
		http.cnxTimeout = timeoutMs / 1000;
		http.setHeader("Content-Type", "application/json");
		http.setHeader("Accept", stream ? "text/event-stream" : "application/json");
		http.setHeader("Authorization", "Bearer " + apiKey);
		applyHeaders(http);
		var bodyJson:String;
		try {
			bodyJson = Json.stringify(buildPayload(request, stream));
		} catch (e:Dynamic) {
			fail("构造请求失败（历史中可能含非法 UTF-8）: " + Std.string(e));
			return {cancel: function() cancelled = true};
		}
		http.setPostData(bodyJson);
		http.onError = function(e:String) {
			if (cancelled || errorEmitted) return;
			errorEmitted = true;
			onEvent(Error(buildApiError(e, statusFromMessage(e), sink.bodyString())));
		};

		http.customRequest(true, sink);

		return {
			cancel: function() cancelled = true
		};
	}

	public function listModels(onResult:ApiResult<Array<ModelInfo>>->Void):Cancelable {
		var cancelled = false;
		var http = new RawHttp(baseUrl + "/models");
		http.cnxTimeout = timeoutMs / 1000;
		http.setHeader("Authorization", "Bearer " + apiKey);
		http.setHeader("Accept", "application/json");
		applyHeaders(http);

		var status = 0;
		var body:String = null;
		var failed = false;

		http.onStatus = function(s) status = s;
		http.onData = function(d) body = d;
		http.onError = function(e:String) {
			if (cancelled) return;
			failed = true;
			onResult(Failure(buildApiError(e, statusFromMessage(e), body)));
		};
		http.request(false);

		if (!failed) {
			if (body == null) {
				onResult(Failure({message: "空响应", status: status}));
			} else {
				try {
					var j:Dynamic = Json.parse(body);
					var list = new Array<ModelInfo>();
					var data:Array<Dynamic> = j.data;
					if (data != null) {
						for (m in data)
							list.push({id: m.id, ownedBy: m.owned_by, created: m.created});
					}
					onResult(Success(list));
				} catch (e:Dynamic) {
					onResult(Failure({message: "解析模型列表失败: " + Std.string(e), status: status, raw: body}));
				}
			}
		}

		return {
			cancel: function() cancelled = true
		};
	}

	public function dispose():Void {
		// sys.Http 不持有长连接，无需释放。
	}

	// ------------------------------------------------------------------
	// 请求构造
	// ------------------------------------------------------------------

	function buildPayload(request:ChatRequest, stream:Bool):Dynamic {
		var messages = new Array<Dynamic>();
		for (m in request.messages)
			messages.push(messageToJson(m));

		var o:Dynamic = {
			model: request.model != null ? request.model : defaultModel,
			messages: messages,
			stream: stream
		};
		if (request.temperature != null) o.temperature = request.temperature;
		if (request.topP != null) o.top_p = request.topP;
		if (request.maxTokens != null) o.max_tokens = request.maxTokens;
		if (request.stop != null) o.stop = request.stop;

		if (request.tools != null && request.tools.length > 0) {
			var tools = new Array<Dynamic>();
			for (t in request.tools)
				tools.push(toolToJson(t));
			o.tools = tools;
		}
		if (request.toolChoice != null) o.tool_choice = toolChoiceToJson(request.toolChoice);

		// 厂商专有参数透传
		if (request.extra != null) {
			for (k in request.extra.keys())
				Reflect.setField(o, k, request.extra.get(k));
		}
		return o;
	}

	function messageToJson(m:Message):Dynamic {
		var o:Dynamic = {role: (m.role : String)};
		if (m.content != null) o.content = m.content;
		if (m.name != null) o.name = m.name;
		if (m.toolCallId != null) o.tool_call_id = m.toolCallId;
		if (m.toolCalls != null && m.toolCalls.length > 0) {
			var arr = new Array<Dynamic>();
			for (c in m.toolCalls) {
				arr.push({
					id: c.id,
					type: "function",
					"function": {
						name: c.name,
						arguments: argumentsToString(c)
					}
				});
			}
			o.tool_calls = arr;
		}
		return o;
	}

	function toolToJson(t:ToolDefinition):Dynamic {
		var fn:Dynamic = {
			name: t.name,
			description: t.description,
			parameters: t.parameters
		};
		if (t.strict != null) fn.strict = t.strict;
		return {type: "function", "function": fn};
	}

	function toolChoiceToJson(tc:ToolChoice):Dynamic {
		var v:Dynamic;
		switch (tc) {
			case Auto: v = "auto";
			case None: v = "none";
			case Required: v = "required";
			case Specific(name): v = {type: "function", "function": {name: name}};
		}
		return v;
	}

	static function argumentsToString(c:ToolCall):String {
		if (c.rawArguments != null && c.rawArguments != "") return c.rawArguments;
		if (c.arguments == null) return "{}";
		return Json.stringify(c.arguments);
	}

	// ------------------------------------------------------------------
	// 响应解析
	// ------------------------------------------------------------------

	function parseUsage(u:Dynamic):Usage {
		var reasoning:Null<Int> = null;
		if (u.completion_tokens_details != null && u.completion_tokens_details.reasoning_tokens != null)
			reasoning = u.completion_tokens_details.reasoning_tokens;
		return {
			promptTokens: u.prompt_tokens,
			completionTokens: u.completion_tokens,
			totalTokens: u.total_tokens,
			reasoningTokens: reasoning
		};
	}

	function buildApiError(message:String, status:Int, body:String):ApiError {
		var err:ApiError = {
			message: message,
			status: status,
			retryable: status == 429 || status >= 500
		};
		if (body != null && StringTools.trim(body) != "") {
			try {
				var j:Dynamic = Json.parse(body);
				if (j.error != null) {
					if (j.error.message != null) err.message = j.error.message;
					if (j.error.type != null) err.type = j.error.type;
					if (j.error.code != null) err.code = Std.string(j.error.code);
				}
				err.raw = j;
			} catch (e:Dynamic) {
				err.raw = body;
			}
		}
		return err;
	}

	static function statusFromMessage(msg:String):Int {
		if (msg == null) return 0;
		var re = ~/#([0-9]+)/;
		if (re.match(msg)) {
			var s = re.matched(1);
			return s != null ? Std.parseInt(s) : 0;
		}
		return 0;
	}

	// ------------------------------------------------------------------
	// 工具
	// ------------------------------------------------------------------

	function applyHeaders(http:RawHttp):Void {
		if (config.headers == null) return;
		for (k in config.headers.keys()) {
			var v = config.headers.get(k);
			if (v != null) http.setHeader(k, v);
		}
	}

	static function stripSlash(s:String):String {
		while (s.length > 0 && s.charAt(s.length - 1) == "/")
			s = s.substr(0, s.length - 1);
		return s;
	}
}

/**
 * 把响应体按 `\n` 切行推送给 onLine（用于 SSE），同时缓存原始字节。
 * `RawHttp.customRequest` 会把响应边读边写入本 Output（RawHttp 是修复了 chunked
 * 多字节解码问题的 sys.Http 拷贝）。
 */
private class ResponseSink extends haxe.io.Output {
	var raw = new BytesBuffer();
	var lineBuf = new BytesBuffer();
	var onLine:String->Void;
	var onEnd:Void->Void;
	var rawTaken = false;

	public function new(onLine:String->Void, onEnd:Void->Void) {
		this.onLine = onLine;
		this.onEnd = onEnd;
	}

	override public function writeByte(c:Int):Void {
		var b = Bytes.alloc(1);
		b.set(0, c & 0xFF);
		writeBytes(b, 0, 1);
	}

	override public function writeBytes(buf:Bytes, pos:Int, len:Int):Int {
		raw.addBytes(buf, pos, len);
		if (onLine != null) {
			var start = 0;
			for (i in 0...len) {
				if (buf.get(pos + i) == 10) { // '\n'
					lineBuf.addBytes(buf, pos + start, i - start + 1);
					var line = Utf8.safe(lineBuf.getBytes());
					lineBuf = new BytesBuffer();
					onLine(line);
					start = i + 1;
				}
			}
			if (start < len)
				lineBuf.addBytes(buf, pos + start, len - start);
		}
		return len;
	}

	override public function close():Void {
		if (onLine != null && lineBuf.length > 0) {
			var line = Utf8.safe(lineBuf.getBytes());
			lineBuf = new BytesBuffer();
			onLine(line);
		}
		if (onEnd != null) onEnd();
	}

	/** 取出原始字节（只能取一次）。 */
	public function takeRaw():Bytes {
		if (rawTaken) return null;
		rawTaken = true;
		return raw.getBytes();
	}

	public function bodyString():String {
		var b = takeRaw();
		return b != null ? Utf8.safe(b) : "";
	}
}
