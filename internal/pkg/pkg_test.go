package pkg

import (
	"strings"
	"testing"
)

func TestUpdateCommandShape(t *testing.T) {
	cmd := UpdateCommand

	// 必须是"先 update 再 upgrade"且非交互
	if !strings.Contains(cmd, "apt-get update") {
		t.Error("缺少 apt-get update")
	}
	if !strings.Contains(cmd, "upgrade") || !strings.Contains(cmd, "-y") {
		t.Error("缺少非交互 upgrade")
	}
	if !strings.Contains(cmd, "DEBIAN_FRONTEND=noninteractive") {
		t.Error("缺少 DEBIAN_FRONTEND=noninteractive，升级可能卡在交互提示")
	}
	// 配置文件冲突不弹问
	if !strings.Contains(cmd, "force-confdef") || !strings.Contains(cmd, "force-confold") {
		t.Error("缺少 dpkg 配置冲突处理参数")
	}

	// 顺序：update 必须在 upgrade 之前
	if strings.Index(cmd, "apt-get update") > strings.Index(cmd, "upgrade") {
		t.Error("apt-get update 应在 upgrade 之前")
	}
}

func TestUpdateCommandIsConstant(t *testing.T) {
	// 命令不接受任何外部输入：包内除这个常量外不应出现 Sprintf 拼接命令的痕迹。
	// 这里做一个语义守卫：命令中不应包含占位符。
	for _, token := range []string{"%s", "%d", "%v", "$1", "{}"} {
		if strings.Contains(UpdateCommand, token) {
			t.Errorf("更新命令不应含占位符 %q（必须为固定命令）", token)
		}
	}
}
