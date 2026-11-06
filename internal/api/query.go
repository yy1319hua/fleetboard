package api

import (
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
)

// intQuery 读一个整数查询参数；缺省或非法时回退到 def。
//
// 非法值不报错而是回退：这些参数只影响「取多少 / 多大」这类软约束，
// 为一个写错的 query 让整个终端握手或状态轮询失败，比按默认值继续更糟。
func intQuery(c *gin.Context, key string, def int) int {
	v, err := strconv.Atoi(strings.TrimSpace(c.Query(key)))
	if err != nil {
		return def
	}
	return v
}

// clampInt 把 v 夹到 [lo, hi]。
func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
