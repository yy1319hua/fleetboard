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

type containerActionRequest struct {
	Action string `json:"action" binding:"required"`
}

// containerActionHandler 对容器执行 start/stop/restart/rm（幂等）。
// POST /api/servers/:id/containers/:cid/actions  body: {"action":"start|stop|restart|rm"}
func containerActionHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		cid := c.Param("cid")

		var req containerActionRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest(`请求体需为 {"action":"start|stop|restart|rm"}`))
			return
		}

		cli, err := openSSH(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}

		out, err := docker.Action(cli, cid, req.Action)
		if err != nil {
			Fail(c, ErrBadGateway(err.Error()))
			return
		}
		OK(c, gin.H{"container": cid, "action": req.Action, "output": out})
	}
}

// listImagesHandler 返回本地镜像列表。
// GET /api/servers/:id/images
func listImagesHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
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
		list, err := docker.ListImages(cli)
		if err != nil {
			Fail(c, ErrBadGateway("获取镜像列表失败: "+err.Error()))
			return
		}
		OK(c, list)
	}
}

type pullImageRequest struct {
	Image string `json:"image" binding:"required"`
}

// pullImageHandler 拉取镜像。
// POST /api/servers/:id/images/pull  body: {"image":"nginx:alpine"}
func pullImageHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		var req pullImageRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest(`请求体需为 {"image":"repo:tag"}`))
			return
		}
		cli, err := openSSH(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		out, err := docker.PullImage(cli, req.Image)
		if err != nil {
			Fail(c, ErrBadGateway(err.Error()))
			return
		}
		OK(c, gin.H{"image": req.Image, "output": out})
	}
}

// removeImageHandler 删除镜像（不存在视为成功）。
// DELETE /api/servers/:id/images/:imageId
func removeImageHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		imageID := c.Param("imageId")
		cli, err := openSSH(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		out, err := docker.RemoveImage(cli, imageID)
		if err != nil {
			Fail(c, ErrBadGateway(err.Error()))
			return
		}
		OK(c, gin.H{"deleted": imageID, "output": out})
	}
}

// listNetworksHandler 返回 Docker 网络列表。
// GET /api/servers/:id/networks
func listNetworksHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
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
		list, err := docker.ListNetworks(cli)
		if err != nil {
			Fail(c, ErrBadGateway("获取网络列表失败: "+err.Error()))
			return
		}
		OK(c, list)
	}
}

// listVolumesHandler 返回 Docker 数据卷列表。
// GET /api/servers/:id/volumes
func listVolumesHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
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
		list, err := docker.ListVolumes(cli)
		if err != nil {
			Fail(c, ErrBadGateway("获取卷列表失败: "+err.Error()))
			return
		}
		OK(c, list)
	}
}
