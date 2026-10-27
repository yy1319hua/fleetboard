package api

import (
	"database/sql"
	"errors"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/db"
)

type alertRuleRequest struct {
	ServerID       *int64  `json:"server_id"`
	Metric         string  `json:"metric" binding:"required"`
	Operator       string  `json:"operator"`
	Threshold      float64 `json:"threshold"`
	Severity       string  `json:"severity"`
	Enabled        bool    `json:"enabled"`
	NotifyChannels string  `json:"notify_channels"`
}

// createAlertRuleHandler 新建告警规则。
// POST /api/alert-rules
func createAlertRuleHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req alertRuleRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest(`请求体需含 metric，如 {"metric":"cpu_pct","operator":">","threshold":80,"severity":"warn","enabled":true}`))
			return
		}

		r, err := db.CreateAlertRule(d, db.AlertRuleInput{
			ServerID:       req.ServerID,
			Metric:         req.Metric,
			Operator:       req.Operator,
			Threshold:      req.Threshold,
			Severity:       req.Severity,
			Enabled:        req.Enabled,
			NotifyChannels: req.NotifyChannels,
		})
		if err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
		c.JSON(201, Response{Code: CodeOK, Msg: "ok", Data: r})
	}
}

// listAlertRulesHandler 返回全部规则。
// GET /api/alert-rules
func listAlertRulesHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		list, err := db.ListAlertRules(d)
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, list)
	}
}

// deleteAlertRuleHandler 删除规则。
// DELETE /api/alert-rules/:id
func deleteAlertRuleHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		err := db.DeleteAlertRule(d, id)
		if errors.Is(err, db.ErrRuleNotFound) {
			Fail(c, ErrNotFound("规则不存在"))
			return
		}
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, gin.H{"deleted": id})
	}
}
