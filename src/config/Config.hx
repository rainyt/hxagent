package config;

import api.ApiConfig;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * 配置读取器：从 `.hxagent/config.json` 读取，按 AI 平台分节。
 *
 * 文件结构（snake_case，同时兼容 camelCase）：
 * ```json
 * {
 *   "provider": "deepseek",
 *   "deepseek": {
 *     "api_key": "sk-xxx",
 *     "base_url": "https://api.deepseek.com",
 *     "model": "deepseek-chat",
 *     "temperature": 1.0,
 *     "max_tokens": 4096,
 *     "timeout_ms": 120000,
 *     "max_retries": 2,
 *     "organization": "org-xxx",
 *     "headers": { "X-Custom": "v" }
 *   },
 *   "agent": {
 *     "system_prompt": "你是一个终端 AI 助手…",
 *     "max_iterations": 10
 *   }
 * }
 * ```
 *
 * 默认路径为「当前工作目录」下的 `.hxagent/config.json`；
 * 也可通过 `load(path)` 指定任意路径。不读取任何环境变量。
 */
class Config {
	public static inline var DIR_NAME = ".hxagent";
	public static inline var FILE_NAME = "config.json";

	/** 实际加载的文件路径。 */
	public var path:String;

	/** 原始 JSON。 */
	public var raw:Dynamic;

	/** 当前选中的 AI 平台，如 "deepseek"。 */
	public var provider:String;

	function new(path:String, raw:Dynamic, provider:String) {
		this.path = path;
		this.raw = raw;
		this.provider = provider;
	}

	// ------------------------------------------------------------------
	// 加载
	// ------------------------------------------------------------------

	/** 默认配置文件路径：<cwd>/.hxagent/config.json */
	public static function defaultPath():String {
		return Path.addTrailingSlash(Sys.getCwd()) + DIR_NAME + "/" + FILE_NAME;
	}

	public static function exists(?path:String):Bool {
		return FileSystem.exists(path != null ? path : defaultPath());
	}

	/**
	 * 加载配置。文件不存在返回 null；JSON 非法则抛 haxe.Exception。
	 * @param path 可选的自定义路径
	 * @param provider 可选的平台覆盖（默认读 provider 字段，缺省 "deepseek"）
	 */
	public static function load(?path:String, ?provider:String):Null<Config> {
		var p = path != null ? path : defaultPath();
		if (!FileSystem.exists(p))
			return null;

		var text = util.Utf8.safe(sys.io.File.getBytes(p));
		var raw:Dynamic;
		try {
			raw = Json.parse(text);
		} catch (e:Dynamic) {
			throw new haxe.Exception('配置文件解析失败 ($p): ' + Std.string(e));
		}
		if (raw == null)
			throw new haxe.Exception('配置文件内容为空: $p');

		var prov = provider != null ? provider : (raw.provider != null ? raw.provider : "deepseek");
		return new Config(p, raw, prov);
	}

	// ------------------------------------------------------------------
	// 平台分节读取
	// ------------------------------------------------------------------

	/** 获取某个平台的原始配置节（默认当前 provider）。 */
	public function section(?name:String):Dynamic {
		var key = name != null ? name : provider;
		if (key == null) return null;
		return Reflect.field(raw, key);
	}

	/** 获取某平台的名称（provider）。 */
	public function platformName(?name:String):String {
		return name != null ? name : provider;
	}

	/** 是否存在某平台配置节。 */
	public function hasPlatform(name:String):Bool {
		return section(name) != null;
	}

	// ------------------------------------------------------------------
	// 字段访问
	// ------------------------------------------------------------------

	/** 构造对应平台的 ApiConfig（连接 / 鉴权相关）。 */
	public function apiConfig(?name:String):ApiConfig {
		var s = section(name);
		if (s == null) return null;

		var cfg:ApiConfig = {};
		var key = pick(s, ["api_key", "apiKey"]);
		var base = pick(s, ["base_url", "baseUrl"]);
		var model = pick(s, ["model", "default_model", "defaultModel"]);
		var timeout = pick(s, ["timeout_ms", "timeoutMs"]);
		var retries = pick(s, ["max_retries", "maxRetries"]);
		var org = pick(s, ["organization", "org"]);

		if (key != null) cfg.apiKey = key;
		if (base != null) cfg.baseUrl = base;
		if (model != null) cfg.defaultModel = model;
		if (timeout != null) cfg.timeoutMs = Std.int(toFloat(timeout));
		if (retries != null) cfg.maxRetries = Std.int(toFloat(retries));
		if (org != null) cfg.organization = org;
		var h = headers(name);
		if (h != null) cfg.headers = h;

		return cfg;
	}

	public function apiKey(?name:String):String {
		var v = pick(section(name), ["api_key", "apiKey"]);
		return v != null ? Std.string(v) : null;
	}

	public function baseUrl(?name:String):String {
		var v = pick(section(name), ["base_url", "baseUrl"]);
		return v != null ? Std.string(v) : null;
	}

	public function model(?name:String):String {
		var v = pick(section(name), ["model", "default_model", "defaultModel"]);
		return v != null ? Std.string(v) : null;
	}

	public function temperature(?name:String):Null<Float> {
		var v = pick(section(name), ["temperature"]);
		return v != null ? toFloat(v) : null;
	}

	public function maxTokens(?name:String):Null<Int> {
		var v = pick(section(name), ["max_tokens", "maxTokens"]);
		return v != null ? Std.int(toFloat(v)) : null;
	}

	public function headers(?name:String):haxe.DynamicAccess<String> {
		var h = pick(section(name), ["headers"]);
		if (h == null) return null;
		var out:haxe.DynamicAccess<String> = {};
		for (k in Reflect.fields(h)) {
			var v = Reflect.field(h, k);
			if (v != null) out.set(k, Std.string(v));
		}
		return out;
	}

	// ---- agent 级配置（不分平台） ----

	function agentSection():Dynamic {
		return Reflect.field(raw, "agent");
	}

	public function systemPrompt():String {
		var v = pick(agentSection(), ["system_prompt", "systemPrompt"]);
		return v != null ? Std.string(v) : null;
	}

	public function maxIterations():Null<Int> {
		var v = pick(agentSection(), ["max_iterations", "maxIterations"]);
		return v != null ? Std.int(toFloat(v)) : null;
	}

	// ------------------------------------------------------------------

	static function pick(o:Dynamic, names:Array<String>):Dynamic {
		if (o == null) return null;
		for (n in names) {
			var v = Reflect.field(o, n);
			if (v != null) return v;
		}
		return null;
	}

	static function toFloat(v:Dynamic):Float {
		if (Std.isOfType(v, Float)) return v;
		if (Std.isOfType(v, Int)) return v;
		var f = Std.parseFloat(Std.string(v));
		return Math.isNaN(f) ? 0 : f;
	}
}
