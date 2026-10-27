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
