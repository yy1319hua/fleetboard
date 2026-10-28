package api

// M9.0a 契约哨兵：调用 BuildRouter() 收集引擎真实路由，与 api/openapi.yaml、
// api/realtime-contract.yaml 做双向比对。任一方向不符即 t.Errorf 输出差异清单。
// 设计目标：后端新增/删除/改路径路由时，本测试在 CI（contract job）中立即红，
// 防止「代码与文档契约漂移」。

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"gopkg.in/yaml.v3"
)

// normalizePath 将 gin 路由风格（:param / *param）归一为 OpenAPI 风格 {param}，
// 使 engine.Routes() 与 openapi.yaml 的路径可直接做集合比对。
func normalizePath(p string) string {
	re := regexp.MustCompile(`:([A-Za-z0-9_]+)`)
	p = re.ReplaceAllString(p, "{$1}")
	re2 := regexp.MustCompile(`\*([A-Za-z0-9_]+)`)
	p = re2.ReplaceAllString(p, "{$1}")
	return p
}

// methodKey 归一 HTTP 方法为全大写。
func methodKey(m string) string { return strings.ToUpper(strings.TrimSpace(m)) }

// routeKey 生成用于比对的 "METHOD /path" 规范键。
func routeKey(method, path string) string { return methodKey(method) + " " + normalizePath(path) }

// httpMethods 是 OpenAPI 合法的 HTTP 方法键。路径项下的非方法键
// （如 parameters / summary / description）一律忽略，避免哨兵误报。
var httpMethods = map[string]bool{
	"get": true, "post": true, "put": true,
	"delete": true, "patch": true, "options": true, "head": true,
}

type openAPISpec struct {
	Paths map[string]yaml.Node `yaml:"paths"`
}

type realtimePath struct {
	Transport string `yaml:"x-transport"`
}

type realtimeSpec struct {
	Paths map[string]realtimePath `yaml:"paths"`
}

// collectEngineRoutes 调用 BuildRouter() 拿到完整引擎并收集全部 (METHOD, path) 规范键。
// BuildRouter() 需要运行期密钥（config.Validate 强校验 KEY），且 DB 落到临时目录避免污染仓库。
func collectEngineRoutes(t *testing.T) (routeSet map[string]struct{}, pathSet map[string]struct{}) {
	t.Helper()
	t.Setenv("KEY", "contract-test-encryption-key-0123456789abcdef")
	t.Setenv("DATA_DIR", t.TempDir())
	t.Setenv("DB_PATH", t.TempDir()+"/fleetboard.db")

	gin.SetMode(gin.TestMode)
	r := BuildRouter()

	routeSet = map[string]struct{}{}
	pathSet = map[string]struct{}{}
	for _, rt := range r.Routes() {
		k := routeKey(rt.Method, rt.Path)
		routeSet[k] = struct{}{}
		// 路径级集合（忽略 method），供 realtime 哨兵使用
		if idx := strings.Index(k, " "); idx >= 0 {
			pathSet[k[idx+1:]] = struct{}{}
		}
	}
	return routeSet, pathSet
}

func TestContract(t *testing.T) {
	engineRoutes, enginePaths := collectEngineRoutes(t)

	// ---- 1) 解析 openapi.yaml 的 paths ----
	yamlBytes, err := os.ReadFile("../../api/openapi.yaml")
	if err != nil {
		t.Fatalf("读取 api/openapi.yaml 失败: %v", err)
	}
	var spec openAPISpec
	if err := yaml.Unmarshal(yamlBytes, &spec); err != nil {
		t.Fatalf("解析 api/openapi.yaml 失败: %v", err)
	}
	yamlRoutes := map[string]struct{}{}
	for path, node := range spec.Paths {
		np := normalizePath(path)
		if node.Kind != yaml.MappingNode {
			continue
		}
		for i := 0; i+1 < len(node.Content); i += 2 {
			m := node.Content[i].Value
			if !httpMethods[strings.ToLower(m)] {
				continue
			}
			yamlRoutes[routeKey(m, np)] = struct{}{}
		}
	}

	// ---- 2) 双向集合比对 ----
	var drifts, gaps []string
	for k := range engineRoutes {
		if _, ok := yamlRoutes[k]; !ok {
			drifts = append(drifts, k)
		}
	}
	for k := range yamlRoutes {
		if _, ok := engineRoutes[k]; !ok {
			gaps = append(gaps, k)
		}
	}
	sort.Strings(drifts)
	sort.Strings(gaps)
	if len(drifts) > 0 {
		t.Errorf("路由漂移(drift)：engine 存在但 openapi.yaml 缺失：\n  - %s", strings.Join(drifts, "\n  - "))
	}
	if len(gaps) > 0 {
		t.Errorf("契约缺口(gap)：openapi.yaml 存在但 engine 缺失：\n  - %s", strings.Join(gaps, "\n  - "))
	}

	// ---- 3) WS/SSE 路径级哨兵：realtime-contract.yaml 标注 x-transport 的路径必须存在于引擎 ----
	rtBytes, err := os.ReadFile("../../api/realtime-contract.yaml")
	if err != nil {
		t.Fatalf("读取 api/realtime-contract.yaml 失败: %v", err)
	}
	var rt realtimeSpec
	if err := yaml.Unmarshal(rtBytes, &rt); err != nil {
		t.Fatalf("解析 api/realtime-contract.yaml 失败: %v", err)
	}
	var missing []string
	for path, p := range rt.Paths {
		if strings.TrimSpace(p.Transport) == "" {
			continue
		}
		np := normalizePath(path)
		if _, ok := enginePaths[np]; !ok {
			missing = append(missing, np)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf("实时传输缺口：realtime-contract.yaml 标注 x-transport 但 engine 无此路径：\n  - %s", strings.Join(missing, "\n  - "))
	}
}
