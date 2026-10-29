package api

import (
	"database/sql"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/db"
)

// metricsHandler 返回历史采样曲线。
// GET /api/servers/:id/metrics?range=24h|7d
func metricsHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}

		rng := c.DefaultQuery("range", "24h")
		var span time.Duration
		switch rng {
		case "24h":
			span = 24 * time.Hour
		case "7d":
			span = 7 * 24 * time.Hour
		default:
			Fail(c, ErrBadRequest("range 仅支持 24h / 7d"))
			return
		}

		// 服务端分桶：24h 取 5 分钟桶（≈288 点）、7d 取 30 分钟桶（≈336 点）。
		// 原样返回 7d × 30s ≈ 2 万行会让手机端先卡在 JSON 解析上。
		// 客户端仍会再做一次 min-max 抽稀到绘制点数，两层各管一段。
		step := 300
		if rng == "7d" {
			step = 1800
		}
		list, err := db.QueryMetricsDownsampled(d, id, time.Now().Add(-span), step)
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, gin.H{"range": rng, "step_sec": step, "count": len(list), "points": list})
	}
}

// latestMetricHandler 返回最新一条采样。
// GET /api/servers/:id/metrics/latest
func latestMetricHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		m, err := db.LatestMetric(d, id)
		if err != nil {
			Fail(c, err)
			return
		}
		if m == nil {
			Fail(c, ErrNotFound("暂无采样数据"))
			return
		}
		OK(c, m)
	}
}
