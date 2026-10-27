// Package file 负责远程文件管理（SFTP）。
package file

import (
	"fmt"
	"io"
	"os"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/pkg/sftp"
)

// Entry 是目录项（含权限与属主信息）。
type Entry struct {
	Name    string    `json:"name"`
	Path    string    `json:"path"`
	Dir     bool      `json:"dir"`
	Size    int64     `json:"size"`
	Mode    string    `json:"mode"` // 如 "-rw-r--r--"
	UID     uint32    `json:"uid"`
	GID     uint32    `json:"gid"`
	ModTime time.Time `json:"mod_time"`
}

// List 读取目录内容（未排序）。
func List(sc *sftp.Client, dir string) ([]Entry, error) {
	infos, err := sc.ReadDir(dir)
	if err != nil {
		return nil, err
	}

	out := make([]Entry, 0, len(infos))
	for _, fi := range infos {
		e := Entry{
			Name:    fi.Name(),
			Path:    path.Join(dir, fi.Name()),
			Dir:     fi.IsDir(),
			Size:    fi.Size(),
			Mode:    fi.Mode().String(),
			ModTime: fi.ModTime(),
		}
		if st, ok := fi.Sys().(*sftp.FileStat); ok {
			e.UID = st.UID
			e.GID = st.GID
		}
		out = append(out, e)
	}
	return out, nil
}

// SortEntries 排序：目录始终优先；同类型按 field（name/size/mod_time）与 order（asc/desc）。
func SortEntries(entries []Entry, field, order string) {
	desc := strings.EqualFold(order, "desc")

	sort.SliceStable(entries, func(i, j int) bool {
		a, b := entries[i], entries[j]
		if a.Dir != b.Dir {
			return a.Dir // 目录优先，不受排序方向影响
		}

		var less bool
		switch field {
		case "size":
			less = a.Size < b.Size
		case "mod_time":
			less = a.ModTime.Before(b.ModTime)
		default: // name
			less = strings.ToLower(a.Name) < strings.ToLower(b.Name)
		}
		if desc {
			return !less
		}
		return less
	})
}

// Paginate 返回 [offset, offset+limit)。offset 越界返回空；limit<=0 默认 200。
func Paginate(entries []Entry, offset, limit int) []Entry {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 {
		limit = 200
	}
	if offset >= len(entries) {
		return []Entry{}
	}
	end := offset + limit
	if end > len(entries) {
		end = len(entries)
	}
	return entries[offset:end]
}

// Open 打开文件用于读取（实现 io.ReadSeeker，可用于 http.ServeContent 的 Range 支持）。
func Open(sc *sftp.Client, p string) (*sftp.File, error) {
	return sc.Open(p)
}

// OpenWrite 打开文件用于写入。
// offset==0 时截断重写；offset>0 时定位到该偏移续写（断点续传）。
func OpenWrite(sc *sftp.Client, p string, offset int64) (*sftp.File, error) {
	flags := os.O_WRONLY | os.O_CREATE
	if offset == 0 {
		flags |= os.O_TRUNC
	}

	f, err := sc.OpenFile(p, flags)
	if err != nil {
		return nil, err
	}
	if offset > 0 {
		if _, err := f.Seek(offset, io.SeekStart); err != nil {
			_ = f.Close()
			return nil, err
		}
	}
	return f, nil
}

// ReadText 读取文本内容；超过 maxBytes 返回错误（防止误开超大文件）。
func ReadText(sc *sftp.Client, p string, maxBytes int64) (string, error) {
	f, err := sc.Open(p)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()

	fi, err := f.Stat()
	if err != nil {
		return "", err
	}
	if fi.Size() > maxBytes {
		return "", fmt.Errorf("文件过大（%d 字节，上限 %d）", fi.Size(), maxBytes)
	}

	b, err := io.ReadAll(f)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// WriteAtomic 原子写：同目录临时文件 → 写入 → 还原权限/属主 → rename 覆盖。
// 任一环节失败都清理临时文件，不会留下半写状态。
func WriteAtomic(sc *sftp.Client, p, content string) error {
	dir := path.Dir(p)
	base := path.Base(p)

	var (
		perm     os.FileMode
		uid, gid uint32
		hasMeta  bool
	)
	if fi, err := sc.Stat(p); err == nil {
		perm = fi.Mode().Perm()
		if st, ok := fi.Sys().(*sftp.FileStat); ok {
			uid, gid = st.UID, st.GID
		}
		hasMeta = true
	}

	tmp := path.Join(dir, "."+base+".fleetboard.tmp")
	_ = sc.Remove(tmp) // 清理历史残留

	f, err := sc.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC)
	if err != nil {
		return err
	}
	if _, err := f.Write([]byte(content)); err != nil {
		_ = f.Close()
		_ = sc.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		_ = sc.Remove(tmp)
		return err
	}

	if hasMeta {
		_ = sc.Chmod(tmp, perm)
		_ = sc.Chown(tmp, int(uid), int(gid)) // 非 root 或服务端不支持时可能失败，保权限优先
	}

	if err := sc.Rename(tmp, p); err != nil {
		_ = sc.Remove(tmp)
		return err
	}
	return nil
}
