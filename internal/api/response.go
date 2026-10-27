// Package api 负责 HTTP 路由与统一响应/错误处理。
package api

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
)

// Response 是全局统一响应体：{code,msg,data}。
// code=0 表示成功；非 0 时与 HTTP 状态码含义对齐，便于前端统一判断。
type Response struct {
	Code int    `json:"code"`
	Msg  string `json:"msg"`
	Data any    `json:"data,omitempty"`
}

// 业务码常量（与 HTTP 状态码一致，成功为 0）。
const (
	CodeOK           = 0
	CodeBadRequest   = 400
	CodeUnauthorized = 401
	CodeForbidden    = 403
	CodeNotFound     = 404
	CodeConflict     = 409
	CodeInternal     = 500
	CodeBadGateway   = 502
)

// APIError 表示可安全返回给客户端的业务错误（HTTP 状态 + 业务码 + 文案）。
type APIError struct {
	Status int
	Code   int
	Msg    string
}

func (e *APIError) Error() string { return e.Msg }

// ErrBadRequest 400，请求参数非法。
func ErrBadRequest(msg string) *APIError {
	return &APIError{Status: http.StatusBadRequest, Code: CodeBadRequest, Msg: msg}
}

// ErrUnauthorized 401，未认证或凭证失效。
func ErrUnauthorized(msg string) *APIError {
	return &APIError{Status: http.StatusUnauthorized, Code: CodeUnauthorized, Msg: msg}
}

// ErrForbidden 403，无权限。
func ErrForbidden(msg string) *APIError {
	return &APIError{Status: http.StatusForbidden, Code: CodeForbidden, Msg: msg}
}

// ErrNotFound 404，资源不存在。
func ErrNotFound(msg string) *APIError {
	return &APIError{Status: http.StatusNotFound, Code: CodeNotFound, Msg: msg}
}

// ErrConflict 409，资源冲突（如重复注册、状态不允许）。
func ErrConflict(msg string) *APIError {
	return &APIError{Status: http.StatusConflict, Code: CodeConflict, Msg: msg}
}

// ErrBadGateway 502，上游（被管机 SSH/Docker）异常。
func ErrBadGateway(msg string) *APIError {
	return &APIError{Status: http.StatusBadGateway, Code: CodeBadGateway, Msg: msg}
}

// OK 写入成功响应。
func OK(c *gin.Context, data any) {
	c.JSON(http.StatusOK, Response{Code: CodeOK, Msg: "ok", Data: data})
}

// Fail 写入错误响应。
// 只有 *APIError 会按原状态与文案返回；其他 error 一律 500 且不暴露内部细节（防信息泄露）。
func Fail(c *gin.Context, err error) {
	var ae *APIError
	if errors.As(err, &ae) {
		c.JSON(ae.Status, Response{Code: ae.Code, Msg: ae.Msg})
		return
	}
	c.JSON(http.StatusInternalServerError, Response{Code: CodeInternal, Msg: "内部错误"})
}
