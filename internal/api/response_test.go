package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func setup(t *testing.T, h gin.HandlerFunc) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/t", h)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/t", nil))
	return w
}

func decode(t *testing.T, body []byte) Response {
	t.Helper()
	var resp Response
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("解析响应失败: %v，body=%s", err, body)
	}
	return resp
}

func TestOK(t *testing.T) {
	w := setup(t, func(c *gin.Context) { OK(c, gin.H{"a": 1}) })

	if w.Code != http.StatusOK {
		t.Errorf("status=%d, want 200", w.Code)
	}
	resp := decode(t, w.Body.Bytes())
	if resp.Code != CodeOK || resp.Msg != "ok" {
		t.Errorf("resp=%+v", resp)
	}
}

func TestFailAPIError(t *testing.T) {
	cases := []struct {
		name   string
		err    *APIError
		status int
		code   int
	}{
		{"bad_request", ErrBadRequest("参数错误"), http.StatusBadRequest, CodeBadRequest},
		{"unauthorized", ErrUnauthorized("未登录"), http.StatusUnauthorized, CodeUnauthorized},
		{"forbidden", ErrForbidden("无权限"), http.StatusForbidden, CodeForbidden},
		{"not_found", ErrNotFound("不存在"), http.StatusNotFound, CodeNotFound},
		{"conflict", ErrConflict("冲突"), http.StatusConflict, CodeConflict},
		{"bad_gateway", ErrBadGateway("上游异常"), http.StatusBadGateway, CodeBadGateway},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := setup(t, func(c *gin.Context) { Fail(c, tc.err) })
			if w.Code != tc.status {
				t.Errorf("status=%d, want %d", w.Code, tc.status)
			}
			resp := decode(t, w.Body.Bytes())
			if resp.Code != tc.code || resp.Msg != tc.err.Msg {
				t.Errorf("resp=%+v", resp)
			}
		})
	}
}

func TestFailInternalHidesDetail(t *testing.T) {
	w := setup(t, func(c *gin.Context) { Fail(c, errors.New("数据库密码是 xxx")) })

	if w.Code != http.StatusInternalServerError {
		t.Errorf("status=%d, want 500", w.Code)
	}
	resp := decode(t, w.Body.Bytes())
	if resp.Code != CodeInternal {
		t.Errorf("code=%d, want %d", resp.Code, CodeInternal)
	}
	if resp.Msg != "内部错误" {
		t.Errorf("不应暴露内部错误细节，msg=%q", resp.Msg)
	}
}
