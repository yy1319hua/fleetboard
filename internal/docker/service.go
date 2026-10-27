// Package docker 负责 Docker 容器、镜像、网络与卷管理。
package docker

import (
	"encoding/json"
	"fmt"
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
