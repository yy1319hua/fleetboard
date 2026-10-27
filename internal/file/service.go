// Package file 负责远程文件管理（SFTP）。
package file

import (
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
