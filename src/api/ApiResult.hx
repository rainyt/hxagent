package api;

/**
 * 非流式请求的统一返回。
 */
enum ApiResult<T> {
	Success(value:T);
	Failure(error:ApiError);
}
