package ai;

import ai.deepseek.Deepseek;
import api.IApi;
import config.Config;

/**
 * 平台工厂：根据配置里的 provider 创建对应的 IApi 实现。
 *
 * 目前支持 deepseek；新增平台时在这里加一个 case 即可，
 * 例如 `case "openai": new OpenAi(config.apiConfig("openai"));`。
 */
class Provider {
	/** 已知/支持的平台名。 */
	public static function supported():Array<String> {
		return ["deepseek"];
	}

	/**
	 * 根据配置创建 API。
	 * @param config 配置
	 * @param name 可选，覆盖要使用的平台（默认 config.provider）
	 */
	public static function create(config:Config, ?name:String):IApi {
		var key = name != null ? name : config.provider;
		if (key == null || key == "")
			throw new haxe.Exception("配置中未指定 provider（AI 平台）");

		var apiCfg = config.apiConfig(key);
		if (apiCfg == null)
			throw new haxe.Exception('配置中缺少平台 "$key" 的配置节');

		return switch (key) {
			case "deepseek":
				new Deepseek(apiCfg);
			// case "openai":
			//     new OpenAi(apiCfg);
			default:
				throw new haxe.Exception('暂不支持的 AI 平台: "$key"（支持: ' + supported().join(", ") + '）');
		}
	}
}
