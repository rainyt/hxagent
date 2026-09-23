class GrepTest {
	static var g = new api.tools.Grep();

	static function run(title:String, args:Dynamic) {
		Sys.println("======== " + title + " ========");
		var r = g.execute(args);
		Sys.print(r.content);
		Sys.println("");
	}

	static function main() {
		run("1. content + glob", {pattern: "ToolRegistry", glob: "*.hx", max_results: 5});
		run("2. ignore_case", {pattern: "toolregistry", ignore_case: true, glob: "*.hx", max_results: 3, output_mode: "count"});
		run("3. count", {pattern: "MAX_", output_mode: "count", glob: "*.hx"});
		run("4. files_with_matches", {pattern: "ITool", output_mode: "files_with_matches", path: "src"});
		run("5. 上下文", {pattern: "public var definition", context: 1, glob: "*.hx", max_results: 2});
		run("6. 非法正则", {pattern: "[unclosed"});
		run("7. fixed_strings", {pattern: "new EReg(", fixed_strings: true, glob: "*.hx", max_results: 3});
		run("8. 单文件", {pattern: "utf8", path: "src/Main.hx", ignore_case: true});
		run("9. 花括号 glob", {pattern: "hxagent", glob: "*.{hxml,json}", max_results: 5});
		run("10. 无匹配", {pattern: "zzzz_not_exist_zzz", path: "src"});
		run("11. 中文", {pattern: "少女", path: "test.txt"});
		run("12. 隐藏项/ignore", {pattern: "hxagent", include_hidden: true, max_results: 3});
		run("13. 截断提示", {pattern: ".", path: "src", max_results: 5});
	}
}
