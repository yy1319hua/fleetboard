// Package docker 负责 Docker 容器、镜像、网络与卷管理。
package docker

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

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

// UnusedVolume 是预览清单中的一项。
type UnusedVolume struct {
	Name string `json:"name"`
	// ComposeProject 来自 label com.docker.compose.project；空表示非 compose 卷。
	// 用于提示「删除后该 compose 栈下次 up 将丢失数据」。
	ComposeProject string `json:"compose_project,omitempty"`
}

// VolumePreview 是「执行前预览」：清单与 `docker volume prune -a -f` 的删除集合等价。
type VolumePreview struct {
	Volumes []UnusedVolume `json:"volumes"`
	// Count 是未使用卷数量（= len(Volumes)）。
	Count int `json:"count"`
	// TotalCount / InUseCount 用于向用户解释「为什么一个都删不掉」。
	TotalCount int `json:"total_count"`
	InUseCount int `json:"in_use_count"`
	// Reclaimable 与 docker system df 的 Local Volumes 行同源，避免口径割裂。
	Reclaimable  string `json:"reclaimable"`
	PruneCommand string `json:"prune_command"`
	SnapshotAt   string `json:"snapshot_at"` // RFC3339，便于前端提示清单新鲜度
}

// volumeEntry 是 `docker volume ls --format` 的一行（名字 + compose 项目）。
type volumeEntry struct {
	Name    string
	Project string
}

// ParseVolumeListWithProject 解析 `{{.Name}}\t{{.Label "com.docker.compose.project"}}` 输出。
// 卷名不含制表符，故按第一个 \t 切分；缺标签时第二段为空。忽略空行。
func ParseVolumeListWithProject(out string) []volumeEntry {
	entries := []volumeEntry{}
	for _, raw := range strings.Split(out, "\n") {
		line := strings.TrimRight(raw, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		name, project, _ := strings.Cut(line, "\t")
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		entries = append(entries, volumeEntry{Name: name, Project: strings.TrimSpace(project)})
	}
	return entries
}

// ParseVolumeNameList 解析 `docker volume ls -q` 的纯名字输出：忽略空行、
// 去重、按字典序排序（保证 UI 稳定与测试可断言）。恒返回非 nil 切片。
func ParseVolumeNameList(out string) []string {
	names := []string{}
	seen := make(map[string]struct{}, 8)
	for _, raw := range strings.Split(out, "\n") {
		name := strings.TrimSpace(raw)
		if name == "" {
			continue
		}
		if _, dup := seen[name]; dup {
			continue
		}
		seen[name] = struct{}{}
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// PreviewUnusedVolumes 列出当前无任何容器引用的卷（含命名卷 / compose 卷）。
//
// 判据与 `docker volume prune -a -f` 一致（dangling=true 的含义就是
// 「无任何容器引用，含已停止容器」），因此预览清单即删除集合。
func PreviewUnusedVolumes(cli *ssh.Client) (VolumePreview, error) {
	all, err := runErr(cli, `docker volume ls --format '{{.Name}}	{{.Label "com.docker.compose.project"}}'`)
	if err != nil {
		return VolumePreview{}, fmt.Errorf("docker volume ls 失败: %w", err)
	}
	danglingOut, err := runErr(cli, `docker volume ls -q --filter dangling=true`)
	if err != nil {
		return VolumePreview{}, fmt.Errorf("查询未使用卷失败: %w", err)
	}
	dangling := make(map[string]struct{}, 8)
	for _, n := range ParseVolumeNameList(danglingOut) {
		dangling[n] = struct{}{}
	}
	entries := ParseVolumeListWithProject(all)

	vols := make([]UnusedVolume, 0, len(dangling))
	for _, e := range entries {
		if _, ok := dangling[e.Name]; !ok {
			continue
		}
		vols = append(vols, UnusedVolume{Name: e.Name, ComposeProject: e.Project})
	}
	// dangling 里有、all 里没有的（两次命令之间新建又删除）按无项目补入，避免漏报。
	known := make(map[string]struct{}, len(entries))
	for _, e := range entries {
		known[e.Name] = struct{}{}
	}
	for name := range dangling {
		if _, ok := known[name]; !ok {
			vols = append(vols, UnusedVolume{Name: name})
		}
	}
	sort.Slice(vols, func(i, j int) bool { return vols[i].Name < vols[j].Name })

	return VolumePreview{
		Volumes:      vols,
		Count:        len(vols),
		TotalCount:   len(entries),
		InUseCount:   len(entries) - len(vols),
		Reclaimable:  volumeReclaimable(cli),
		PruneCommand: "docker volume prune -a -f",
		SnapshotAt:   time.Now().UTC().Format(time.RFC3339),
	}, nil
}

// volumeReclaimable 复用 system df 的 Local Volumes 可回收量；取不到返回空串（不阻断预览）。
func volumeReclaimable(cli *ssh.Client) string {
	rows, err := SystemDF(cli)
	if err != nil {
		return ""
	}
	for _, r := range rows {
		if strings.Contains(strings.ToLower(r.Type), "volume") {
			return r.Reclaimable
		}
	}
	return ""
}

// prune 的删除范围语义，随结果返回给调用方，避免「不知道删了什么」。
const (
	ModeDangling  = "dangling"   // 只删悬空对象（无 tag 的镜像等）
	ModeAllUnused = "all_unused" // 删全部无引用对象（含命名卷 / compose 卷）
)

// PruneResult 是单个目标的回收结果。
type PruneResult struct {
	Target    string `json:"target"`
	Command   string `json:"command"` // 实际执行的命令，便于审计与排障
	Mode      string `json:"mode"`    // dangling / all_unused
	Output    string `json:"output"`
	Reclaimed string `json:"reclaimed"` // 如 "1.234GB"；解析不到时为空串

	// DeletedItems 是本次实际删除的条目（卷名 / 镜像引用 / 缓存 ID）。
	DeletedItems []string `json:"deleted_items"`
	// DeletedCount 便于调用方直接判空，无需遍历。
	DeletedCount int `json:"deleted_count"`
	// NothingDeleted=true 表示「本次没有任何可删项」，与「删了但回收 0B」严格区分。
	NothingDeleted bool `json:"nothing_deleted"`
	// Error 是该项的失败原因；空串表示成功。单项失败不影响其余目标。
	Error string `json:"error"`
}

// ParseDeletedItems 解析 prune 输出中的「实际删除项」清单。
//
// prune 系列命令不支持 --format json，只能解析人读文本。兼容三种段头
// （大小写不敏感，段头 = 以 "deleted" 开头且以 ":" 结尾）：
//
//	Deleted Volumes:             → 卷名
//	Deleted Images:              → "untagged: nginx:1.19" / "deleted: sha256:..."
//	Deleted build cache objects: → 构建缓存对象 ID
//
// 边界：空输出、只有 "Total reclaimed space: 0B"、CRLF、段内前后空白、
// 有 Deleted 段但缺 Total 段、Total 之后混入告警 —— 均返回稳定结果。
// 返回值恒非 nil，便于 JSON 序列化为 []。
func ParseDeletedItems(out string) []string {
	items := []string{}
	inSection := false
	for _, raw := range strings.Split(out, "\n") {
		line := strings.TrimSpace(raw) // 同时吃掉 CRLF 的 \r
		if line == "" {
			inSection = false // 空行结束当前段
			continue
		}
		low := strings.ToLower(line)
		if strings.HasPrefix(low, "deleted") && strings.HasSuffix(low, ":") {
			inSection = true
			continue
		}
		if strings.HasPrefix(low, "total reclaimed space:") {
			inSection = false // 即使没有空行分隔也能正确收尾
			continue
		}
		if inSection {
			items = append(items, line)
		}
	}
	return items
}

// prunePlan 返回清理目标对应的确切命令与删除范围语义。
func prunePlan(target string) (cmd, mode string, err error) {
	switch PruneTarget(target) {
	case PruneImages:
		// 保持 -f（仅悬空镜像）。绝不使用 -a：会删掉「已 compose down 但保留镜像」
		// 的栈所用镜像，下次 up 重新 pull :latest 可能拉到不同 digest，
		// 属静默变更生产镜像；离线/内网环境则直接起不来。
		return "docker image prune -f", ModeDangling, nil
	case PruneVolumes:
		// Docker 23+ 的 volume prune 默认只删匿名卷，命名卷（含 compose 卷）必须 -a。
		return "docker volume prune -a -f", ModeAllUnused, nil
	case PruneBuildCache:
		return "docker builder prune -f", ModeAllUnused, nil
	}
	return "", "", fmt.Errorf("不支持的清理目标: %q", target)
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

// Prune 按目标逐项回收空间。
//
// 安全边界：images 只清悬空镜像（不带 -a）；volumes 用 -a 清全部无引用卷
// （命名卷 / compose 卷包含在内，删除前应由调用方用 PreviewUnusedVolumes 预览）。
// 单项失败不中断其余目标：失败原因写进该项的 Error，方便调用方逐项展示。
func Prune(cli *ssh.Client, targets []string) ([]PruneResult, error) {
	if len(targets) == 0 {
		return nil, errors.New("至少需要一个清理目标")
	}
	results := make([]PruneResult, 0, len(targets))
	for _, t := range targets {
		cmd, mode, err := prunePlan(t)
		if err != nil {
			return results, err
		}
		out, rerr := runErr(cli, cmd)
		r := PruneResult{Target: t, Command: cmd, Mode: mode, Output: out, Reclaimed: ParseReclaimed(out)}
		if rerr != nil {
			r.Error = rerr.Error()
			if strings.TrimSpace(out) != "" {
				r.Error = strings.TrimSpace(out) + ": " + r.Error
			}
			results = append(results, r)
			continue
		}
		r.DeletedItems = ParseDeletedItems(out)
		r.DeletedCount = len(r.DeletedItems)
		r.NothingDeleted = r.DeletedCount == 0
		results = append(results, r)
	}
	return results, nil
}

// prune 覆盖度：该行「可回收」能否被对应的 prune 目标完全清掉。
const (
	CoverageFull    = "full"    // 可完全清除
	CoveragePartial = "partial" // 只能清除一部分（Images：-f 只删悬空镜像）
	CoverageNone    = "none"    // 无对应 prune 目标（Containers）
)

// DiskUsage 是 `docker system df` 的一行（空间占用汇总）。
type DiskUsage struct {
	Type        string `json:"type"`
	TotalCount  string `json:"total_count"`
	Active      string `json:"active"`
	Size        string `json:"size"`
	Reclaimable string `json:"reclaimable"`

	// 以下为后端派生字段（不来自 docker 输出），用于对齐 UI 与 prune 的真实能力。
	PruneTarget   string `json:"prune_target"`   // images / volumes / build_cache；空=无对应目标
	PruneCoverage string `json:"prune_coverage"` // full / partial / none
}

type diskUsageLine struct {
	Type        string `json:"Type"`
	TotalCount  string `json:"TotalCount"`
	Active      string `json:"Active"`
	Size        string `json:"Size"`
	Reclaimable string `json:"Reclaimable"`
}

// pruneCoverageForType 把 system df 的行类型映射到本面板的 prune 能力。
//
// partial 是口径修复的核心：Images 行的可回收量包含「带 tag 但无容器引用」的镜像，
// 而 `docker image prune -f` 只删悬空镜像 —— 调用方据此提示「需逐条手动删除」。
func pruneCoverageForType(t string) (target, coverage string) {
	low := strings.ToLower(t)
	switch {
	case strings.Contains(low, "image"):
		return string(PruneImages), CoveragePartial
	case strings.Contains(low, "volume"):
		return string(PruneVolumes), CoverageFull
	case strings.Contains(low, "build"):
		return string(PruneBuildCache), CoverageFull
	}
	return "", CoverageNone
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
	d := &DiskUsage{
		Type:        p.Type,
		TotalCount:  p.TotalCount,
		Active:      p.Active,
		Size:        p.Size,
		Reclaimable: p.Reclaimable,
	}
	d.PruneTarget, d.PruneCoverage = pruneCoverageForType(p.Type)
	return d, nil
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
