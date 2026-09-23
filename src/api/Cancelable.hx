package api;

/**
 * 可取消的异步请求句柄。
 */
typedef Cancelable = {
	/** 取消请求；取消后不应再触发任何回调。 */
	function cancel():Void;
}
