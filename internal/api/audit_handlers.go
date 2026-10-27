package api

import (
	"database/sql"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/db"
)

// listAuditHandler 返回最近的操作审计（倒序）。
func listAuditHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		limit := 100
		if v := c.Query("limit"); v != "" {
			if n, err := strconv.Atoi(v); err == nil {
				limit = n
			}
		}
		list, err := db.ListAudit(d, limit)
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, list)
	}
}
