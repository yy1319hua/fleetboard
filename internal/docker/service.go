// Package docker 负责 Docker 容器、镜像、网络与卷管理。
package docker

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/crypto/ssh"
)

// Container 是容器摘要（对应 `docker ps` 一行）。
type Container struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Image     string `json:"image"`
	State     string `json:"state"`  // running / exited / paused / ...
	Status    string `json:"status"` // 人类可读状态串
	CreatedAt string `json:"created_at"`
	Ports     string `json:"ports"`
}

// psLine 是 `docker ps --format '{{json .}}'` 的原始字段。
type psLine struct {
	ID        string `json:"ID"`
	Names     string `json:"Names"`
	Image     string `json:"Image"`
	State     string `json:"State"`
	Status    string `json:"Status"`
	CreatedAt string `json:"CreatedAt"`
	Ports     string `json:"Ports"`
}

// ParsePSLine 解析 `docker ps --format json` 的单行输出；空行返回 (nil, nil)。
func ParsePSLine(line string) (*Container, error) {
	line = strings.TrimSpace(line)
	if line == "" {
		return nil, nil
	}

	var p psLine
	if err := json.Unmarshal([]byte(line), &p); err != nil {
		return nil, fmt.Errorf("解析容器行失败: %w", err)
	}

	return &Container{
		ID:        p.ID,
		Name:      p.Names,
		Image:     p.Image,
		State:     p.State,
		Status:    p.Status,
		CreatedAt: p.CreatedAt,
		Ports:     p.Ports,
	}, nil
}

// List 经 SSH 执行 `docker ps -a`，返回全部容器（含已停止）。
func List(cli *ssh.Client) ([]Container, error) {
	sess, err := cli.NewSession()
	if err != nil {
		return nil, err
	}
	defer func() { _ = sess.Close() }()

	out, err := sess.Output(`docker ps -a --format '{{json .}}'`)
	if err != nil {
		return nil, err
	}

	list := []Container{}
	for _, line := range strings.Split(string(out), "\n") {
		c, err := ParsePSLine(line)
		if err != nil {
			return nil, err
		}
		if c != nil {
			list = append(list, *c)
		}
	}
	return list, nil
}

// allowedActions 是允许的容器操作白名单（action → docker 子命令）。
var allowedActions = map[string]string{
	"start":   "start",
	"stop":    "stop",
	"restart": "restart",
	"rm":      "rm -f",
}

// ValidateContainerID 校验容器 ID/名称，防命令注入。
// 只允许字母、数字与 `_ - .`。
func ValidateContainerID(id string) error {
	if id == "" {
		return errors.New("容器 ID 不能为空")
	}
	for _, r := range id {
		ok := (r >= 'a' && r <= 'z') ||
			(r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') ||
			r == '_' || r == '-' || r == '.'
		if !ok {
			return fmt.Errorf("容器 ID 含非法字符: %q", string(r))
		}
	}
	return nil
}

// Action 对容器执行 start/stop/restart/rm，返回命令输出。
// 幂等：对不存在的容器执行 rm 视为成功。
func Action(cli *ssh.Client, containerID, action string) (string, error) {
	if err := ValidateContainerID(containerID); err != nil {
		return "", err
	}
	sub, ok := allowedActions[action]
	if !ok {
		return "", fmt.Errorf("不支持的操作: %q（允许 start/stop/restart/rm）", action)
	}

	sess, err := cli.NewSession()
	if err != nil {
		return "", err
	}
	defer func() { _ = sess.Close() }()

	out, err := sess.CombinedOutput(fmt.Sprintf("docker %s %s", sub, containerID))
	output := string(out)
	if err != nil {
		// 幂等：删除不存在的容器不视为失败
		if action == "rm" && strings.Contains(output, "No such container") {
			return output, nil
		}
		return output, fmt.Errorf("docker %s 失败: %w", action, err)
	}
	return output, nil
}

// LogsCommand 构造 `docker logs -f` 命令；容器 ID 与 tail 均校验后才拼接。
func LogsCommand(containerID, tail string) (string, error) {
	if err := ValidateContainerID(containerID); err != nil {
		return "", err
	}
	n, err := strconv.Atoi(tail)
	if err != nil || n <= 0 || n > 10000 {
		return "", errors.New("tail 需为 1-10000 的整数")
	}
	return fmt.Sprintf("docker logs -f --tail %d %s", n, containerID), nil
}

// Image 是镜像摘要。
type Image struct {
	ID           string `json:"id"`
	Repository   string `json:"repository"`
	Tag          string `json:"tag"`
	Size         string `json:"size"`
	CreatedSince string `json:"created_since"`
}

type imageLine struct {
	ID           string `json:"ID"`
	Repository   string `json:"Repository"`
	Tag          string `json:"Tag"`
	Size         string `json:"Size"`
	CreatedSince string `json:"CreatedSince"`
}

// ParseImageLine 解析 `docker images --format json` 的单行输出；空行返回 (nil, nil)。
func ParseImageLine(line string) (*Image, error) {
	line = strings.TrimSpace(line)
	if line == "" {
		return nil, nil
	}
	var p imageLine
	if err := json.Unmarshal([]byte(line), &p); err != nil {
		return nil, fmt.Errorf("解析镜像行失败: %w", err)
	}
	return &Image{
		ID:           p.ID,
		Repository:   p.Repository,
		Tag:          p.Tag,
		Size:         p.Size,
		CreatedSince: p.CreatedSince,
	}, nil
}

// run 在 SSH 上执行命令并返回合并输出。
func run(cli *ssh.Client, cmd string) (string, error) {
	sess, err := cli.NewSession()
	if err != nil {
		return "", err
	}
	defer func() { _ = sess.Close() }()
	out, _ := sess.CombinedOutput(cmd)
	return string(out), nil
}

// runErr 在 SSH 上执行命令，返回输出与错误。
func runErr(cli *ssh.Client, cmd string) (string, error) {
	sess, err := cli.NewSession()
	if err != nil {
		return "", err
	}
	defer func() { _ = sess.Close() }()
	out, err := sess.CombinedOutput(cmd)
	return string(out), err
}

// ListImages 返回全部本地镜像。
func ListImages(cli *ssh.Client) ([]Image, error) {
	out, err := runErr(cli, `docker images --format '{{json .}}'`)
	if err != nil {
		return nil, fmt.Errorf("docker images 失败: %w", err)
	}

	list := []Image{}
	for _, line := range strings.Split(out, "\n") {
		img, err := ParseImageLine(line)
		if err != nil {
			return nil, err
		}
		if img != nil {
			list = append(list, *img)
		}
	}
	return list, nil
}

// ValidateImageRef 校验镜像引用（repo[:tag][@digest]），防命令注入。
func ValidateImageRef(ref string) error {
	if ref == "" {
		return errors.New("镜像名不能为空")
	}
	if len(ref) > 255 {
		return errors.New("镜像名过长")
	}
	for i, r := range ref {
		ok := (r >= 'a' && r <= 'z') ||
			(r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') ||
			r == '_' || r == '-' || r == '.' || r == '/' || r == ':' || r == '@'
		if !ok {
			return fmt.Errorf("镜像名含非法字符: %q", string(r))
		}
		if i == 0 && !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			return errors.New("镜像名需以字母或数字开头")
		}
	}
	return nil
}

// ValidateImageID 校验镜像 ID（支持 sha256: 前缀）。
func ValidateImageID(id string) error {
	if id == "" {
		return errors.New("镜像 ID 不能为空")
	}
	for _, r := range id {
		ok := (r >= 'a' && r <= 'z') ||
			(r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') ||
			r == '_' || r == '-' || r == '.' || r == ':'
		if !ok {
			return fmt.Errorf("镜像 ID 含非法字符: %q", string(r))
		}
	}
	return nil
}

// PullImage 拉取镜像，返回输出。
func PullImage(cli *ssh.Client, ref string) (string, error) {
	if err := ValidateImageRef(ref); err != nil {
		return "", err
	}
	out, err := runErr(cli, "docker pull "+ref)
	if err != nil {
		return out, fmt.Errorf("docker pull 失败: %w", err)
	}
	return out, nil
}

// RemoveImage 删除镜像；不存在视为幂等成功。
func RemoveImage(cli *ssh.Client, id string) (string, error) {
	if err := ValidateImageID(id); err != nil {
		return "", err
	}
	out, err := runErr(cli, "docker rmi "+id)
	if err != nil {
		if strings.Contains(out, "No such image") {
			return out, nil
		}
		return out, fmt.Errorf("docker rmi 失败: %w", err)
	}
	return out, nil
}

// Network 是 Docker 网络摘要。
type Network struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Driver string `json:"driver"`
	Scope  string `json:"scope"`
}

type networkLine struct {
	ID     string `json:"ID"`
	Name   string `json:"Name"`
	Driver string `json:"Driver"`
	Scope  string `json:"Scope"`
}

// ParseNetworkLine 解析 `docker network ls --format json` 的单行。
func ParseNetworkLine(line string) (*Network, error) {
	line = strings.TrimSpace(line)
	if line == "" {
		return nil, nil
	}
	var p networkLine
	if err := json.Unmarshal([]byte(line), &p); err != nil {
		return nil, fmt.Errorf("解析网络行失败: %w", err)
	}
	return &Network{ID: p.ID, Name: p.Name, Driver: p.Driver, Scope: p.Scope}, nil
}

// ListNetworks 返回全部 Docker 网络。
func ListNetworks(cli *ssh.Client) ([]Network, error) {
	out, err := runErr(cli, `docker network ls --format '{{json .}}'`)
	if err != nil {
		return nil, fmt.Errorf("docker network ls 失败: %w", err)
	}

	list := []Network{}
	for _, line := range strings.Split(out, "\n") {
		n, err := ParseNetworkLine(line)
		if err != nil {
			return nil, err
		}
		if n != nil {
			list = append(list, *n)
		}
	}
	return list, nil
}

// Volume 是 Docker 数据卷摘要。
type Volume struct {
	Name       string `json:"name"`
	Driver     string `json:"driver"`
	Mountpoint string `json:"mountpoint"`
}

type volumeLine struct {
	Name       string `json:"Name"`
	Driver     string `json:"Driver"`
	Mountpoint string `json:"Mountpoint"`
}

// ParseVolumeLine 解析 `docker volume ls --format json` 的单行。
func ParseVolumeLine(line string) (*Volume, error) {
	line = strings.TrimSpace(line)
	if line == "" {
		return nil, nil
	}
	var p volumeLine
	if err := json.Unmarshal([]byte(line), &p); err != nil {
		return nil, fmt.Errorf("解析卷行失败: %w", err)
	}
	return &Volume{Name: p.Name, Driver: p.Driver, Mountpoint: p.Mountpoint}, nil
}

// ListVolumes 返回全部 Docker 数据卷。
func ListVolumes(cli *ssh.Client) ([]Volume, error) {
	out, err := runErr(cli, `docker volume ls --format '{{json .}}'`)
	if err != nil {
		return nil, fmt.Errorf("docker volume ls 失败: %w", err)
	}

	list := []Volume{}
	for _, line := range strings.Split(out, "\n") {
		v, err := ParseVolumeLine(line)
		if err != nil {
			return nil, err
		}
		if v != nil {
			list = append(list, *v)
		}
	}
	return list, nil
}

// Stats 是容器资源占用快照。
type Stats struct {
	Container string `json:"container"`
	Name      string `json:"name"`
	CPUPerc   string `json:"cpu_perc"`
	MemUsage  string `json:"mem_usage"`
	MemPerc   string `json:"mem_perc"`
	NetIO     string `json:"net_io"`
	BlockIO   string `json:"block_io"`
	PIDs      string `json:"pids"`
}

type statsLine struct {
	Container string `json:"Container"`
	Name      string `json:"Name"`
	CPUPerc   string `json:"CPUPerc"`
	MemUsage  string `json:"MemUsage"`
	MemPerc   string `json:"MemPerc"`
	NetIO     string `json:"NetIO"`
	BlockIO   string `json:"BlockIO"`
	PIDs      string `json:"PIDs"`
}

// ParseStatsLine 解析 `docker stats --format json` 的单行。
func ParseStatsLine(line string) (*Stats, error) {
	line = strings.TrimSpace(line)
	if line == "" {
		return nil, nil
	}
	var p statsLine
	if err := json.Unmarshal([]byte(line), &p); err != nil {
		return nil, fmt.Errorf("解析资源行失败: %w", err)
	}
	return &Stats{
		Container: p.Container,
		Name:      p.Name,
		CPUPerc:   p.CPUPerc,
		MemUsage:  p.MemUsage,
		MemPerc:   p.MemPerc,
		NetIO:     p.NetIO,
		BlockIO:   p.BlockIO,
		PIDs:      p.PIDs,
	}, nil
}

// ContainerStats 返回所有运行中容器的资源占用快照（--no-stream 单次采样）。
func ContainerStats(cli *ssh.Client) ([]Stats, error) {
	out, err := runErr(cli, `docker stats --no-stream --format '{{json .}}'`)
	if err != nil {
		return nil, fmt.Errorf("docker stats 失败: %w", err)
	}

	list := []Stats{}
	for _, line := range strings.Split(out, "\n") {
		s, err := ParseStatsLine(line)
		if err != nil {
			return nil, err
		}
		if s != nil {
			list = append(list, *s)
		}
	}
	return list, nil
}

// ─────────────────────── 卷删除与磁盘空间回收 ───────────────────────

// ErrVolumeInUse 表示卷仍被容器（含已停止容器）引用，不能删除。
var ErrVolumeInUse = errors.New("卷仍被容器占用")

// Docker 卷名规则：字母或数字开头，其后可含字母、数字、下划线、点、连字符。
var volumeNamePattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,254}$`)

// ValidateVolumeName 校验卷名，避免把任意字符串拼进 shell 命令。
func ValidateVolumeName(name string) error {
	if !volumeNamePattern.MatchString(name) {
		return fmt.Errorf("非法的卷名: %q", name)
	}
	return nil
}

// ParseVolumeUsers 解析 `docker ps -a --filter volume=<name> --format '{{.Names}}'` 输出。
// 空行忽略；无引用时返回空切片（非 nil，便于 JSON 序列化为 []）。
func ParseVolumeUsers(out string) []string {
	users := []string{}
	for _, line := range strings.Split(out, "\n") {
		if s := strings.TrimSpace(line); s != "" {
			users = append(users, s)
		}
	}
	return users
}

// VolumeUsers 返回引用该卷的容器名（含已停止容器，因为停止的容器恢复后仍会用该卷）。
func VolumeUsers(cli *ssh.Client, name string) ([]string, error) {
	if err := ValidateVolumeName(name); err != nil {
		return nil, err
	}
	out, err := runErr(cli, "docker ps -a --filter volume="+name+" --format '{{.Names}}'")
	if err != nil {
		return nil, fmt.Errorf("查询卷占用失败: %w", err)
	}
	return ParseVolumeUsers(out), nil
}

// RemoveVolume 删除数据卷（卷内数据一并删除）。
// 被容器引用时返回包裹 ErrVolumeInUse 的错误，消息里带容器名，供前端直接展示。
func RemoveVolume(cli *ssh.Client, name string) (string, error) {
	if err := ValidateVolumeName(name); err != nil {
		return "", err
	}
	users, err := VolumeUsers(cli, name)
	if err != nil {
		return "", err
	}
	if len(users) > 0 {
		return "", fmt.Errorf("%w: %s", ErrVolumeInUse, strings.Join(users, "、"))
	}
	out, err := runErr(cli, "docker volume rm "+name)
	if err != nil {
		if strings.Contains(strings.ToLower(out), "no such volume") {
			return out, nil // 已不存在，按成功处理（幂等）
		}
		return out, fmt.Errorf("docker volume rm 失败: %w", err)
	}
	return out, nil
}

// PruneTarget 是受支持的回收目标。
type PruneTarget string

const (
	PruneImages     PruneTarget = "images"      // 悬空镜像（无 tag、无容器引用）
	PruneVolumes    PruneTarget = "volumes"     // 无容器引用的卷
	PruneBuildCache PruneTarget = "build_cache" // 构建缓存
)

// ValidPruneTarget 判断目标是否受支持。
func ValidPruneTarget(t string) bool {
	switch PruneTarget(t) {
	case PruneImages, PruneVolumes, PruneBuildCache:
		return true
	}
	return false
}

// PruneResult 是单个目标的回收结果。
type PruneResult struct {
	Target    string `json:"target"`
	Output    string `json:"output"`
	Reclaimed string `json:"reclaimed"` // 如 "1.234GB"；解析不到时为空串
}

// ParseReclaimed 从 prune 输出里解析 "Total reclaimed space: 1.234GB"。
func ParseReclaimed(out string) string {
	const marker = "total reclaimed space:"
	best := ""
	for _, line := range strings.Split(out, "\n") {
		idx := strings.Index(strings.ToLower(line), marker)
		if idx < 0 {
			continue
		}
		if v := strings.TrimSpace(line[idx+len(marker):]); v != "" {
			best = v
		}
	}
	return best
}

// Prune 按目标逐项回收空间。任一目标失败即返回已完成的项与错误。
//
// 安全边界：images 只清悬空镜像（不带 -a），volumes 只清无容器引用的卷，
// 因此不会删掉仍在使用的资源。
func Prune(cli *ssh.Client, targets []string) ([]PruneResult, error) {
	if len(targets) == 0 {
		return nil, errors.New("至少需要一个清理目标")
	}
	results := []PruneResult{}
	for _, t := range targets {
		var cmd string
		switch PruneTarget(t) {
		case PruneImages:
			cmd = "docker image prune -f"
		case PruneVolumes:
			cmd = "docker volume prune -f"
		case PruneBuildCache:
			cmd = "docker builder prune -f"
		default:
			return results, fmt.Errorf("不支持的清理目标: %q", t)
		}
		out, err := runErr(cli, cmd)
		if err != nil {
			return results, fmt.Errorf("%s 清理失败: %w", t, err)
		}
		results = append(results, PruneResult{
			Target:    t,
			Output:    out,
			Reclaimed: ParseReclaimed(out),
		})
	}
	return results, nil
}

// DiskUsage 是 `docker system df` 的一行（空间占用汇总）。
type DiskUsage struct {
	Type        string `json:"type"`
	TotalCount  string `json:"total_count"`
	Active      string `json:"active"`
	Size        string `json:"size"`
	Reclaimable string `json:"reclaimable"`
}

type diskUsageLine struct {
	Type        string `json:"Type"`
	TotalCount  string `json:"TotalCount"`
	Active      string `json:"Active"`
	Size        string `json:"Size"`
	Reclaimable string `json:"Reclaimable"`
}

// ParseDiskUsageLine 解析 `docker system df --format json` 的单行。
func ParseDiskUsageLine(line string) (*DiskUsage, error) {
	line = strings.TrimSpace(line)
	if line == "" {
		return nil, nil
	}
	var p diskUsageLine
	if err := json.Unmarshal([]byte(line), &p); err != nil {
		return nil, fmt.Errorf("解析磁盘占用行失败: %w", err)
	}
	return &DiskUsage{
		Type:        p.Type,
		TotalCount:  p.TotalCount,
		Active:      p.Active,
		Size:        p.Size,
		Reclaimable: p.Reclaimable,
	}, nil
}

// SystemDF 返回 Docker 各类型资源的空间占用（镜像/容器/卷/构建缓存）。
func SystemDF(cli *ssh.Client) ([]DiskUsage, error) {
	out, err := runErr(cli, `docker system df --format '{{json .}}'`)
	if err != nil {
		return nil, fmt.Errorf("docker system df 失败: %w", err)
	}
	list := []DiskUsage{}
	for _, line := range strings.Split(out, "\n") {
		d, err := ParseDiskUsageLine(line)
		if err != nil {
			return nil, err
		}
		if d != nil {
			list = append(list, *d)
		}
	}
	return list, nil
}
