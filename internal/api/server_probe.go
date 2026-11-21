package api

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/pkg/sftp"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/model"
	"github.com/yy1319hua/fleetboard/internal/monitor"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
	"golang.org/x/crypto/ssh"
)

// probeTimeout 是「一次体检」的总时限。
//
// 15 秒比普通采集（20 秒）紧一点：体检发生在用户点「保存」或「刷新配置」时，
// 是有人盯着界面的场景，宁可能快速失败让他重试，也不要转半分钟。
const probeTimeout = 15 * time.Second

// probeResult 是一次体检的产出。
type probeResult struct {
	Facts     *model.ServerFacts
	HasDocker int
	HasSFTP   int
	// Warnings 记录「主流程成功、个别项没探到」的情况。
	// 不把整次体检判失败：配置采到了就够画卡片，docker 探测失败
	// 只影响容器 Tab 是否显示，不该连累其他信息。
	Warnings []string
}

// probeServer 用一条 SSH 连接完成三件事：采系统配置、探 Docker、探 sftp。
//
// 为什么合成一次：这三项都只需要「连上并跑一条命令」，分成三次就是三次握手。
// serv00 这类虚拟主机会限制并发与频率，多连两次纯属自找限流。
//
// 只在首次添加服务器和用户手动刷新时调用；不做周期探测——
// CPU 型号、内存总量、有没有装 Docker 不会自己变。
func probeServer(ctx context.Context, d *sql.DB, masterKey string, pool *sshpool.Pool, s *model.Server) (*probeResult, error) {
	cred, err := db.GetDecryptedCredential(d, masterKey, s.ID)
	if err != nil {
		return nil, fmt.Errorf("读取凭据: %w", err)
	}

	cli, err := pool.Get(ctx, s.ID, sshpool.Config{
		Host:       s.Host,
		Port:       s.Port,
		User:       s.SSHUser,
		AuthMethod: cred.AuthMethod,
		Password:   cred.Password,
		PrivateKey: cred.PrivateKey,
		KeyPass:    cred.KeyPass,
	})
	if err != nil {
		return nil, fmt.Errorf("SSH 连接失败: %w", err)
	}

	res := &probeResult{HasDocker: -1, HasSFTP: -1}

	facts, err := monitor.CollectFacts(ctx, cli)
	if err != nil {
		// 配置采不到就没有写库的意义：空 facts 会把整张卡片写成一片「—」，
		// 比维持「未采集」状态更难排查。
		return nil, fmt.Errorf("采集系统配置失败: %w", err)
	}
	res.Facts = facts

	// Docker：命令能跑通但返回空 = 确实没装（记 0）；命令执行失败 = 未知（留 -1）。
	if out, err := monitor.RunScript(ctx, cli, "command -v docker 2>/dev/null || true"); err != nil {
		res.Warnings = append(res.Warnings, "探测 Docker 失败: "+err.Error())
	} else if strings.TrimSpace(string(out)) != "" {
		res.HasDocker = 1
	} else {
		res.HasDocker = 0
	}

	// sftp：服务端明确拒绝记 0（绝大多数情况就是没开子系统）；超时记未知并摘掉连接。
	has, err := probeSFTP(ctx, cli)
	switch {
	case err != nil:
		res.Warnings = append(res.Warnings, "探测 SFTP 失败: "+err.Error())
		pool.Close(s.ID)
	case has:
		res.HasSFTP = 1
	default:
		res.HasSFTP = 0
	}

	facts.ServerID = s.ID
	if err := db.UpsertFacts(d, facts); err != nil {
		return res, fmt.Errorf("写入系统配置: %w", err)
	}
	if err := db.UpdateCapabilities(d, s.ID, res.HasDocker, res.HasSFTP); err != nil {
		return res, fmt.Errorf("写入能力检测结果: %w", err)
	}
	// 回填到返回值，让创建响应能直接告诉前端这台机器有没有 docker。
	facts.HasDocker = res.HasDocker
	facts.HasSFTP = res.HasSFTP
	return res, nil
}

// probeSFTP 判断服务端是否提供 sftp 子系统。
//
// 与 openSFTP 一样用协程 + select 兜底：recvVersion 是阻塞读，
// 对端收下 subsystem 请求却不回 VERSION 时会一直挂着。
func probeSFTP(ctx context.Context, cli *ssh.Client) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, sftpHandshakeTimeout)
	defer cancel()

	done := make(chan sftpResult, 1)
	go func() {
		c, err := sftp.NewClient(cli)
		done <- sftpResult{client: c, err: err}
	}()

	select {
	case r := <-done:
		if r.err != nil {
			// 服务端回了拒绝，说明子系统不可用 —— 这是确定结论，不是探测失败。
			return false, nil
		}
		_ = r.client.Close()
		return true, nil
	case <-ctx.Done():
		return false, fmt.Errorf("sftp 握手超时: %w", ctx.Err())
	}
}

// serverProbeHandler 手动重新体检（针对已存在的机器，带 id）。
//
// 与 POST /servers/probe 的区别：那个是「纳管预检」，还没落库、只为确认能连；
// 这个是「已保存机器的体检」，会采配置并写库。
//
// POST /api/servers/:id/probe
func serverProbeHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		s, err := db.GetServer(d, id)
		if err != nil {
			Fail(c, err)
			return
		}

		ctx, cancel := context.WithTimeout(c.Request.Context(), probeTimeout)
		defer cancel()

		res, err := probeServer(ctx, d, masterKey, pool, s)
		if err != nil {
			Fail(c, ErrBadGateway("检测失败: "+err.Error()))
			return
		}
		OK(c, gin.H{
			"has_docker": res.HasDocker,
			"has_sftp":   res.HasSFTP,
			"facts":      res.Facts,
			"warnings":   res.Warnings,
		})
	}
}

// sampleServerHandler 给「仅保存」的机器做一次按需采样。
//
// POST /api/servers/:id/sample
//
// 纳管机器有 30 秒的后台采集，不需要调它；这里存在的原因只是「仅保存」
// 不能轮询——用户点一下，才连一次，把这一瞬间的四个值写进时序表。
// 因此曲线上的点是稀疏的：只有被点过的时刻才有数，不是历史回放。
func sampleServerHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		s, err := db.GetServer(d, id)
		if err != nil {
			Fail(c, err)
			return
		}
		cred, err := db.GetDecryptedCredential(d, masterKey, id)
		if err != nil {
			Fail(c, err)
			return
		}

		ctx, cancel := context.WithTimeout(c.Request.Context(), 20*time.Second)
		defer cancel()

		cli, err := pool.Get(ctx, id, sshpool.Config{
			Host:       s.Host,
			Port:       s.Port,
			User:       s.SSHUser,
			AuthMethod: cred.AuthMethod,
			Password:   cred.Password,
			PrivateKey: cred.PrivateKey,
			KeyPass:    cred.KeyPass,
		})
		if err != nil {
			Fail(c, ErrBadGateway("SSH 连接失败: "+err.Error()))
			return
		}

		snap, err := monitor.Collect(ctx, cli)
		if err != nil {
			Fail(c, ErrBadGateway("采样失败: "+err.Error()))
			return
		}
		if err := db.InsertMetric(d, id, snap.CPUPct, snap.MemPct, snap.DiskPct, snap.Load1); err != nil {
			Fail(c, ErrInternal("写入采样结果失败"))
			return
		}
		// 顺带把「最近心跳」刷新掉：仅保存的机器从不被轮询，这个字段
		// 否则会永远停在添加那一刻。
		_ = db.UpdateServerStatus(d, id, "online")

		OK(c, gin.H{
			"cpu_pct":  snap.CPUPct,
			"mem_pct":  snap.MemPct,
			"disk_pct": snap.DiskPct,
			"load1":    snap.Load1,
		})
	}
}
