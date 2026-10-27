package pkg

import (
	"strings"
	"testing"
)

func TestPumpLines(t *testing.T) {
	in := "Reading package lists...\r\nBuilding dependency tree...\n\n最后一行的中文输出\n"

	var got []string
	PumpLines(strings.NewReader(in), func(line string) { got = append(got, line) })

	want := []string{"Reading package lists...", "Building dependency tree...", "", "最后一行的中文输出"}
	if len(got) != len(want) {
		t.Fatalf("got=%q want=%q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("第 %d 行: got=%q want=%q", i, got[i], want[i])
		}
	}
}

func TestPumpLinesDropsTrailingCR(t *testing.T) {
	var got []string
	PumpLines(strings.NewReader("进度 10%\r"), func(line string) { got = append(got, line) })
	if len(got) != 1 || got[0] != "进度 10%" {
		t.Errorf("行尾 \\r 应被去除，实际 %q", got)
	}
}

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
