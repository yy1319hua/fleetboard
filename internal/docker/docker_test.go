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
