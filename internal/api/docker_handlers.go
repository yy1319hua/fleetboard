package api

import (
	"database/sql"
	"errors"
	"strings"

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

// removeVolumeHandler 删除数据卷（卷内数据一并删除）。
// DELETE /api/servers/:id/volumes/:name
func removeVolumeHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		name := c.Param("name")
		if err := docker.ValidateVolumeName(name); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
		cli, err := openSSH(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		out, err := docker.RemoveVolume(cli, name)
		if err != nil {
			// 被容器引用是「用户可自行解决」的冲突，给 409 并带上容器名；
			// 其余（SSH 断链、docker 报错）按网关错误处理。
			if errors.Is(err, docker.ErrVolumeInUse) {
				msg := strings.TrimPrefix(err.Error(), docker.ErrVolumeInUse.Error()+": ")
				Fail(c, ErrConflict("卷仍被容器占用："+msg+"（先删除或改造这些容器再清理）"))
				return
			}
			Fail(c, ErrBadGateway(err.Error()))
			return
		}
		OK(c, gin.H{"deleted": name, "output": out})
	}
}

// dockerPruneRequest 是空间回收请求体。
//
// targets 取 images / volumes / build_cache 的任意组合；必须显式给出，
// 不做「省略即全清」的默认值——破坏性操作不接受隐式扩大范围。
type dockerPruneRequest struct {
	Targets []string `json:"targets"`
}

// pruneDockerHandler 回收 Docker 占用的磁盘空间。
// POST /api/servers/:id/docker/prune
func pruneDockerHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		var req dockerPruneRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest(`请求体需为 {"targets":["images","volumes","build_cache"]}`))
			return
		}
		if len(req.Targets) == 0 {
			Fail(c, ErrBadRequest("targets 不能为空：请显式指定 images / volumes / build_cache"))
			return
		}
		for _, t := range req.Targets {
			if !docker.ValidPruneTarget(t) {
				Fail(c, ErrBadRequest("不支持的清理目标: "+t+"（可选 images / volumes / build_cache）"))
				return
			}
		}
		cli, err := openSSH(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		results, err := docker.Prune(cli, req.Targets)
		if err != nil {
			Fail(c, ErrBadGateway(err.Error()))
			return
		}
		OK(c, gin.H{"results": results})
	}
}

// dockerDFHandler 返回 Docker 各类型资源的空间占用与可回收量。
// GET /api/servers/:id/docker/df
func dockerDFHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
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
		list, err := docker.SystemDF(cli)
		if err != nil {
			Fail(c, ErrBadGateway("获取磁盘占用失败: "+err.Error()))
			return
		}
		OK(c, list)
	}
}

// unusedVolumesHandler 预览将被 `docker volume prune -a -f` 删除的卷清单。
// 只读，不执行任何删除；供 App/Web 在执行前把「会删哪些卷」摊给用户看。
// GET /api/servers/:id/docker/unused-volumes
func unusedVolumesHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
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
		preview, err := docker.PreviewUnusedVolumes(cli)
		if err != nil {
			Fail(c, ErrBadGateway("获取未使用卷清单失败: "+err.Error()))
			return
		}
		OK(c, preview)
	}
}

// containerStatsHandler 返回所有运行中容器的资源占用快照。
// GET /api/servers/:id/container-stats
func containerStatsHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
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
		list, err := docker.ContainerStats(cli)
		if err != nil {
			Fail(c, ErrBadGateway("获取资源占用失败: "+err.Error()))
			return
		}
		OK(c, list)
	}
}
