package api

import (
	"database/sql"
	"errors"
	"strconv"

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

// alertRulePatchRequest 是部分更新入参：字段为 null/缺省表示不修改。
//
// 为什么不用全量替换：App 里「改阈值」和「开关规则」是两个独立入口，
// 全量替换要求客户端把没改的字段（如 notify_channels）一并回传，漏传就被清空。
// 这与 PUT /api/settings 的 merge 语义保持一致。
type alertRulePatchRequest struct {
	Metric         *string  `json:"metric"`
	Operator       *string  `json:"operator"`
	Threshold      *float64 `json:"threshold"`
	Severity       *string  `json:"severity"`
	Enabled        *bool    `json:"enabled"`
	NotifyChannels *string  `json:"notify_channels"`
	// 只用于显式拒绝：改归属等同删旧建新，会让历史通知指向语义已变的规则。
	ServerID *int64 `json:"server_id"`
}

func validMetric(v string) bool {
	switch v {
	case "cpu_pct", "mem_pct", "disk_pct", "offline":
		return true
	}
	return false
}

func validOperator(v string) bool {
	switch v {
	case ">", ">=", "<", "<=", "=":
		return true
	}
	return false
}

func validSeverity(v string) bool {
	switch v {
	case "info", "warn", "critical":
		return true
	}
	return false
}

// updateAlertRuleHandler 部分更新告警规则（merge 语义）。
// PUT /api/alert-rules/:id
func updateAlertRuleHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		var req alertRulePatchRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest("请求体格式非法"))
			return
		}
		if req.ServerID != nil {
			Fail(c, ErrBadRequest("不支持修改规则归属的服务器；如需变更请删除后重建"))
			return
		}
		if req.Metric != nil && !validMetric(*req.Metric) {
			Fail(c, ErrBadRequest("metric 仅支持 cpu_pct / mem_pct / disk_pct / offline"))
			return
		}
		if req.Operator != nil && !validOperator(*req.Operator) {
			Fail(c, ErrBadRequest("operator 仅支持 > >= < <= ="))
			return
		}
		if req.Severity != nil && !validSeverity(*req.Severity) {
			Fail(c, ErrBadRequest("severity 仅支持 info / warn / critical"))
			return
		}
		if req.Threshold != nil && (*req.Threshold < 0 || *req.Threshold > 100) {
			Fail(c, ErrBadRequest("threshold 需在 0–100 之间"))
			return
		}

		r, err := db.UpdateAlertRule(d, id, db.AlertRulePatch{
			Metric:         req.Metric,
			Operator:       req.Operator,
			Threshold:      req.Threshold,
			Severity:       req.Severity,
			Enabled:        req.Enabled,
			NotifyChannels: req.NotifyChannels,
		})
		if errors.Is(err, db.ErrRuleNotFound) {
			Fail(c, ErrNotFound("规则不存在"))
			return
		}
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, r)
	}
}

// listAlertsHandler 通知中心列表。
// GET /api/alerts?unread=1&limit=100
func listAlertsHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		unread := c.Query("unread") == "1"
		limit := 100
		if v := c.Query("limit"); v != "" {
			if n, err := strconv.Atoi(v); err == nil {
				limit = n
			}
		}
		list, err := db.ListAlertEvents(d, unread, limit)
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, list)
	}
}

// markAlertReadHandler 标记通知已读。
// POST /api/alerts/:id/read
func markAlertReadHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		if err := db.MarkAlertRead(d, id); err != nil {
			Fail(c, err)
			return
		}
		OK(c, gin.H{"read": id})
	}
}
