package api

import (
	"database/sql"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/db"
)

// serverFactsHandler 返回主机静态配置（概览「系统配置」卡）。
// GET /api/servers/:id/facts
//
// 数据由后台每小时采集一次写入 server_facts；刚纳管的机器可能还没有记录，
// 此时返回 404 + 明确文案，而不是空对象——空对象会让前端画出满屏「—」，
// 看起来像功能坏了。
func serverFactsHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}

		f, err := db.GetFacts(d, id)
		if err != nil {
			Fail(c, err)
			return
		}
		if f == nil {
			Fail(c, ErrNotFound("尚未采集到这台主机的配置信息，纳管后约一分钟内会自动采集"))
			return
		}
		OK(c, f)
	}
}
