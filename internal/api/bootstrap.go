package api

import (
	"context"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/auth"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/model"
	"golang.org/x/sync/errgroup"
)

// bootstrapHandler 一次性聚合返回首屏所需数据：服务器列表、各机最新指标、
// 未读告警数、版本 / schema / ver。并行拉取，整体超时 9s，部分失败不整包失败。
// GET /api/bootstrap
func bootstrapHandler(opts RouterOptions) gin.HandlerFunc {
	return func(c *gin.Context) {
		ctx, cancel := context.WithTimeout(c.Request.Context(), 9*time.Second)
		defer cancel()

		var (
			servers []model.Server
			metrics map[int64]*model.ServerMetric
			unread  int
		)

		// 零值 errgroup：各 goroutine 互不取消，单查询失败不影响其它，实现部分容错。
		var g errgroup.Group
		g.Go(func() error {
			s, err := db.ListServers(opts.DB)
			if err != nil {
				return err
			}
			servers = s
			return nil
		})
		g.Go(func() error {
			m, err := db.LatestMetricsPerServer(opts.DB)
			if err != nil {
				return err
			}
			metrics = m
			return nil
		})
		g.Go(func() error {
			n, err := db.CountUnreadAlerts(opts.DB)
			if err != nil {
				return err
			}
			unread = n
			return nil
		})
		// 等待聚合完成；9s 超时上限（纯 DB 读，超时即降级为空数据，不整包 500）。
		done := make(chan error, 1)
		go func() { done <- g.Wait() }()
		select {
		case err := <-done:
			if err != nil {
				log.Printf("bootstrap 聚合部分失败: %v", err)
			}
		case <-ctx.Done():
			log.Printf("bootstrap 聚合超时（降级为空数据）")
		}

		// 某机 metric 缺失则该 key 不写入（留空），不整包失败。
		metricsMap := gin.H{}
		for _, s := range servers {
			if m, ok := metrics[s.ID]; ok && m != nil {
				metricsMap[strconv.FormatInt(s.ID, 10)] = m
			}
		}

		OK(c, gin.H{
			"servers":      servers,
			"metrics":      metricsMap,
			"unreadAlerts": unread,
			"version":      opts.Version,
			"schema":       parseSchemaInt(opts.Schema),
			"ver":          auth.JWT_EPOCH,
		})
	}
}

// parseSchemaInt 将迁移版本字符串（如 "0004_token_ver.sql"）的前导数字解析为 int。
func parseSchemaInt(s string) int {
	s = strings.TrimSpace(s)
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	if i == 0 {
		return 0
	}
	n, err := strconv.Atoi(s[:i])
	if err != nil {
		return 0
	}
	return n
}
