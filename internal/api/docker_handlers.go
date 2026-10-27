package api

import (
	"database/sql"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/docker"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
)

// listContainersHandler 返回服务器上的全部容器。
// GET /api/servers/:id/containers
func listContainersHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}

		cli, err := openSSH(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}

		list, err := docker.List(cli)
		if err != nil {
			Fail(c, ErrBadGateway("获取容器列表失败: "+err.Error()))
			return
		}
		OK(c, list)
	}
}
