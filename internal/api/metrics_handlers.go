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

		list, err := db.QueryMetrics(d, id, time.Now().Add(-span))
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, gin.H{"range": rng, "count": len(list), "points": list})
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
