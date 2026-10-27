// Package docker 负责 Docker 容器、镜像、网络与卷管理。
package docker

import (
	"encoding/json"
	"errors"
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
