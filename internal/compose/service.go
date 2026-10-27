// Package compose 负责 Docker Compose 配置的浏览、编辑与动作编排。
package compose

import (
	"errors"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/pkg/sftp"
	"github.com/yy1319hua/fleetboard/internal/file"
)

// DefaultRoots 是 compose 文件可访问的根目录白名单（防止越权读写任意路径）。
var DefaultRoots = []string{"/root", "/opt", "/srv", "/home", "/etc", "/usr/local"}

// MaxComposeBytes 是单个 compose 文件允许读写的上限（YAML 文本，足够宽松）。
const MaxComposeBytes = 2 << 20 // 2 MiB

// ErrPathDenied 表示路径不在白名单内。
var ErrPathDenied = errors.New("路径不在允许的 compose 目录内")

// FileItem 是一个 compose 文件条目（供列表展示）。
type FileItem struct {
	Name    string    `json:"name"`
	Path    string    `json:"path"`
	Size    int64     `json:"size"`
	ModTime time.Time `json:"mod_time"`
}

// NormalizeRoots 清理并去空，返回规范化白名单；入参为空时用 DefaultRoots。
func NormalizeRoots(roots []string) []string {
	out := make([]string, 0, len(roots))
	for _, r := range roots {
		r = strings.TrimSpace(r)
		if r == "" {
			continue
		}
		out = append(out, path.Clean(r))
	}
	if len(out) == 0 {
		out = append(out, DefaultRoots...)
	}
	return out
}

// ValidatePath 校验 p 是绝对路径且位于白名单根目录之下。
// 先 path.Clean 归一化，因此 ".." 穿越会被解析后再判定，无法逃出白名单。
func ValidatePath(p string, roots []string) error {
	if strings.TrimSpace(p) == "" {
		return errors.New("路径为空")
	}
	if strings.ContainsRune(p, 0) {
		return errors.New("路径含非法字符")
	}
	clean := path.Clean(p)
	if !path.IsAbs(clean) {
		return errors.New("必须是绝对路径")
	}

	for _, root := range NormalizeRoots(roots) {
		if clean == root || strings.HasPrefix(clean, root+"/") {
			return nil
		}
	}
	return ErrPathDenied
}

// IsComposeFile 判断文件名是否像 compose 配置（docker-compose*.yml / compose*.yaml 等）。
func IsComposeFile(name string) bool {
	lower := strings.ToLower(name)
	if !strings.HasSuffix(lower, ".yml") && !strings.HasSuffix(lower, ".yaml") {
		return false
	}
	base := strings.TrimSuffix(strings.TrimSuffix(lower, ".yaml"), ".yml")
	return base == "compose" || base == "docker-compose" ||
		strings.HasPrefix(base, "compose.") || strings.HasPrefix(base, "compose-") ||
		strings.HasPrefix(base, "docker-compose.") || strings.HasPrefix(base, "docker-compose-")
}

// ListResult 是一次探测的结果：可浏览子目录 + 命中白名单的 compose 文件。
type ListResult struct {
	Dir     string     `json:"dir"`
	Dirs    []string   `json:"dirs"`  // 子目录名（供继续下钻）
	Files   []FileItem `json:"files"` // compose 文件
	Skipped int        `json:"skipped"`
}

// ListFiles 列出 dir 下的子目录与 compose 文件；dir 本身也要通过白名单校验。
func ListFiles(sc *sftp.Client, dir string, roots []string) (*ListResult, error) {
	if err := ValidatePath(dir, roots); err != nil {
		return nil, err
	}
	dir = path.Clean(dir)

	entries, err := file.List(sc, dir)
	if err != nil {
		return nil, err
	}

	res := &ListResult{Dir: dir, Dirs: []string{}, Files: []FileItem{}}
	for _, e := range entries {
		if e.Dir {
			res.Dirs = append(res.Dirs, e.Name)
			continue
		}
		if !IsComposeFile(e.Name) {
			res.Skipped++
			continue
		}
		res.Files = append(res.Files, FileItem{
			Name:    e.Name,
			Path:    e.Path,
			Size:    e.Size,
			ModTime: e.ModTime,
		})
	}

	sort.Strings(res.Dirs)
	sort.Slice(res.Files, func(i, j int) bool { return res.Files[i].Name < res.Files[j].Name })
	return res, nil
}

// Read 读取 compose 文件内容（先校验白名单，再限制大小）。
func Read(sc *sftp.Client, p string, roots []string) (string, error) {
	if err := ValidatePath(p, roots); err != nil {
		return "", err
	}
	return file.ReadText(sc, path.Clean(p), MaxComposeBytes)
}

// Write 原子写回 compose 文件（保留权限属主，失败不留半写状态）。
func Write(sc *sftp.Client, p, content string, roots []string) error {
	if err := ValidatePath(p, roots); err != nil {
		return err
	}
	if int64(len(content)) > MaxComposeBytes {
		return errors.New("内容超出上限（2MiB）")
	}
	return file.WriteAtomic(sc, path.Clean(p), content)
}
