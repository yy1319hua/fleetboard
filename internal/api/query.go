package api

import (
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
)

// intQuery 读一个整数查询参数；缺省或非法时回退到 def。
//
// 放在这里而不是某个 handler 文件里：终端尺寸（terminal_ws.go）与升级日志尾
// （upgrade_handlers.go）都要用同一套「解析 + 夹紧」语义，各写一份迟早不一致。
func intQuery(c *gin.Context, key string, def int) int {
	v, err := strconv.Atoi(strings.TrimSpace(c.Query(key)))
	if err != nil {
		return def
	}
	return v
}

// clampInt 把 v 夹进 [lo, hi]。
func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
