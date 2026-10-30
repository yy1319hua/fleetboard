package docker

import "testing"

func TestParsePSLine(t *testing.T) {
	line := `{"ID":"abc123","Names":"web","Image":"nginx:alpine","State":"running","Status":"Up 2 hours","CreatedAt":"2026-10-27 10:00:00","Ports":"0.0.0.0:80->80/tcp"}`

	c, err := ParsePSLine(line)
	if err != nil {
		t.Fatalf("ParsePSLine: %v", err)
	}
	if c.ID != "abc123" || c.Name != "web" || c.Image != "nginx:alpine" {
		t.Errorf("字段错误: %+v", c)
	}
	if c.State != "running" || c.Ports != "0.0.0.0:80->80/tcp" {
		t.Errorf("字段错误: %+v", c)
	}
}

func TestParsePSLineEmpty(t *testing.T) {
	c, err := ParsePSLine("   \n")
	if err != nil {
		t.Fatalf("空行不应报错: %v", err)
	}
	if c != nil {
		t.Errorf("空行应返回 nil，实际 %+v", c)
	}
}

func TestParsePSLineInvalid(t *testing.T) {
	if _, err := ParsePSLine("not-json"); err == nil {
		t.Error("非法 JSON 应报错")
	}
}

func TestParsePSLinePartial(t *testing.T) {
	c, err := ParsePSLine(`{"ID":"x","Names":"n"}`)
	if err != nil {
		t.Fatal(err)
	}
	if c.ID != "x" || c.Name != "n" {
		t.Errorf("%+v", c)
	}
}

func TestValidateContainerID(t *testing.T) {
	valid := []string{"abc123", "my_container-1", "a.b", "A9", "0f3a2b1c4d5e"}
	for _, id := range valid {
		if err := ValidateContainerID(id); err != nil {
			t.Errorf("%q 应合法，实际报错: %v", id, err)
		}
	}

	invalid := []string{"", "a b", "a;rm -rf /", "$(x)", "a/b", "a&&b", "a|b"}
	for _, id := range invalid {
		if err := ValidateContainerID(id); err == nil {
			t.Errorf("%q 应非法，实际通过", id)
		}
	}
}

func TestAllowedActions(t *testing.T) {
	for _, a := range []string{"start", "stop", "restart", "rm"} {
		if _, ok := allowedActions[a]; !ok {
			t.Errorf("缺少允许操作: %s", a)
		}
	}
	if _, ok := allowedActions["exec"]; ok {
		t.Error("exec 不应在允许列表")
	}
}

func TestLogsCommand(t *testing.T) {
	cmd, err := LogsCommand("abc123", "200")
	if err != nil {
		t.Fatalf("LogsCommand: %v", err)
	}
	if cmd != "docker logs -f --tail 200 abc123" {
		t.Errorf("命令错误: %q", cmd)
	}
}

func TestLogsCommandValidation(t *testing.T) {
	if _, err := LogsCommand("a;rm -rf /", "200"); err == nil {
		t.Error("非法容器 ID 应报错")
	}
	if _, err := LogsCommand("abc", "0"); err == nil {
		t.Error("tail=0 应报错")
	}
	if _, err := LogsCommand("abc", "99999"); err == nil {
		t.Error("tail 超上限应报错")
	}
	if _, err := LogsCommand("abc", "x"); err == nil {
		t.Error("tail 非数字应报错")
	}
}

func TestParseImageLine(t *testing.T) {
	line := `{"ID":"sha256:abc","Repository":"nginx","Tag":"alpine","Size":"23.4MB","CreatedSince":"2 days ago"}`
	img, err := ParseImageLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if img.ID != "sha256:abc" || img.Repository != "nginx" || img.Tag != "alpine" {
		t.Errorf("%+v", img)
	}

	if img, err := ParseImageLine("  "); err != nil || img != nil {
		t.Errorf("空行应返回 nil,nil: %v %v", img, err)
	}
}

func TestValidateImageRef(t *testing.T) {
	valid := []string{"nginx", "nginx:alpine", "ghcr.io/u/app:v1", "registry:5000/a/b:t", "img@sha256:abc"}
	for _, r := range valid {
		if err := ValidateImageRef(r); err != nil {
			t.Errorf("%q 应合法: %v", r, err)
		}
	}
	invalid := []string{"", "-bad", "a b", "a;rm -rf /", "$(x)", "a|b", "a&&b"}
	for _, r := range invalid {
		if err := ValidateImageRef(r); err == nil {
			t.Errorf("%q 应非法", r)
		}
	}
}

func TestValidateImageID(t *testing.T) {
	valid := []string{"sha256:abc", "abc123", "a_b-c.d"}
	for _, id := range valid {
		if err := ValidateImageID(id); err != nil {
			t.Errorf("%q 应合法: %v", id, err)
		}
	}
	invalid := []string{"", "a/b", "a b", "a;b", "$(x)"}
	for _, id := range invalid {
		if err := ValidateImageID(id); err == nil {
			t.Errorf("%q 应非法", id)
		}
	}
}

func TestParseNetworkLine(t *testing.T) {
	n, err := ParseNetworkLine(`{"ID":"n1","Name":"bridge","Driver":"bridge","Scope":"local"}`)
	if err != nil {
		t.Fatal(err)
	}
	if n.ID != "n1" || n.Name != "bridge" || n.Driver != "bridge" {
		t.Errorf("%+v", n)
	}

	if n, err := ParseNetworkLine(""); err != nil || n != nil {
		t.Errorf("空行应 nil,nil: %v %v", n, err)
	}
}

func TestParseVolumeLine(t *testing.T) {
	v, err := ParseVolumeLine(`{"Name":"data","Driver":"local","Mountpoint":"/var/lib/docker/volumes/data/_data"}`)
	if err != nil {
		t.Fatal(err)
	}
	if v.Name != "data" || v.Driver != "local" {
		t.Errorf("%+v", v)
	}

	if v, err := ParseVolumeLine(""); err != nil || v != nil {
		t.Errorf("空行应 nil,nil: %v %v", v, err)
	}
}

func TestParseStatsLine(t *testing.T) {
	line := `{"Container":"abc123","Name":"web","CPUPerc":"1.23%","MemUsage":"10MiB / 1GiB","MemPerc":"0.98%","NetIO":"1kB / 2kB","BlockIO":"0B / 0B","PIDs":"5"}`
	s, err := ParseStatsLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if s.Container != "abc123" || s.CPUPerc != "1.23%" || s.MemUsage != "10MiB / 1GiB" {
		t.Errorf("%+v", s)
	}

	if s, err := ParseStatsLine("  "); err != nil || s != nil {
		t.Errorf("空行应 nil,nil: %v %v", s, err)
	}
	if _, err := ParseStatsLine("not-json"); err == nil {
		t.Error("非法 JSON 应报错")
	}
}

func TestValidateVolumeName(t *testing.T) {
	valid := []string{
		"dockdeck_dockdeck-hub-data",
		"a",
		"vol.1",
		"9lives",
	}
	for _, name := range valid {
		if err := ValidateVolumeName(name); err != nil {
			t.Errorf("%q 应合法，却报错: %v", name, err)
		}
	}

	invalid := []string{
		"",
		"-leading",
		".hidden",
		"has space",
		"a; rm -rf /",
		"a$(id)",
		"a`id`",
		"路径/斜杠",
	}
	for _, name := range invalid {
		if err := ValidateVolumeName(name); err == nil {
			t.Errorf("%q 应判为非法，却通过了（有命令注入风险）", name)
		}
	}
}

func TestParseVolumeUsers(t *testing.T) {
	got := ParseVolumeUsers("web\napi\n\n  db  \n")
	want := []string{"web", "api", "db"}
	if len(got) != len(want) {
		t.Fatalf("数量不符: got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("第 %d 项: got %q want %q", i, got[i], want[i])
		}
	}

	// 无引用时必须是空切片而不是 nil，保证 JSON 序列化成 []
	empty := ParseVolumeUsers("\n  \n")
	if empty == nil {
		t.Error("空输入应返回空切片而非 nil")
	}
	if len(empty) != 0 {
		t.Errorf("空输入应返回 0 项，got %v", empty)
	}
}

func TestParseReclaimed(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "常规输出",
			in:   "Deleted Volumes:\nvol1\nvol2\n\nTotal reclaimed space: 1.234GB\n",
			want: "1.234GB",
		},
		{
			name: "无回收",
			in:   "Total reclaimed space: 0B\n",
			want: "0B",
		},
		{
			name: "没有该行",
			in:   "Deleted Images:\nuntagged: nginx:old\n",
			want: "",
		},
		{
			name: "大小写混排",
			in:   "TOTAL RECLAIMED SPACE:   512MB\n",
			want: "512MB",
		},
	}
	for _, c := range cases {
		if got := ParseReclaimed(c.in); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestValidPruneTarget(t *testing.T) {
	for _, ok := range []string{"images", "volumes", "build_cache"} {
		if !ValidPruneTarget(ok) {
			t.Errorf("%q 应受支持", ok)
		}
	}
	for _, bad := range []string{"", "all", "containers", "IMAGES", "images; rm -rf /"} {
		if ValidPruneTarget(bad) {
			t.Errorf("%q 不应受支持", bad)
		}
	}
}

func TestParseDiskUsageLine(t *testing.T) {
	line := `{"Type":"Images","TotalCount":"12","Active":"3","Size":"1.2GB","Reclaimable":"800MB (66%)"}`
	d, err := ParseDiskUsageLine(line)
	if err != nil {
		t.Fatalf("ParseDiskUsageLine: %v", err)
	}
	if d.Type != "Images" || d.TotalCount != "12" || d.Active != "3" {
		t.Errorf("字段错误: %+v", d)
	}
	if d.Size != "1.2GB" || d.Reclaimable != "800MB (66%)" {
		t.Errorf("容量字段错误: %+v", d)
	}

	if v, err := ParseDiskUsageLine("  "); err != nil || v != nil {
		t.Errorf("空行应返回 (nil,nil)，got (%v,%v)", v, err)
	}
	if _, err := ParseDiskUsageLine("not json"); err == nil {
		t.Error("非法 JSON 应报错")
	}
}
