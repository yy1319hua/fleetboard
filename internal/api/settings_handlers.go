package api

import (
	"fmt"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/alert"
	"github.com/yy1319hua/fleetboard/internal/settings"
)

// maskTail 掩码：只留尾 4 位。
func maskTail(v string) string {
	if v == "" {
		return ""
	}
	if len(v) <= 4 {
		return "****"
	}
	return "****" + v[len(v)-4:]
}

// readonlyView 组装只读展示区（M8.1c）：KEY 尾 4 位与端口。
func readonlyView(masterKey string, port int) gin.H {
	return gin.H{
		"key_masked": maskTail(masterKey),
		"port":       port,
	}
}

// getSettingsHandler 返回全部设置项。敏感项只回 {"masked":"****尾4位","set":bool}。
func getSettingsHandler(st *settings.Store, masterKey string, port int) gin.HandlerFunc {
	return func(c *gin.Context) {
		if st == nil {
			Fail(c, fmt.Errorf("设置存储未初始化"))
			return
		}
		view, err := st.MaskedView()
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, gin.H{"items": view, "readonly": readonlyView(masterKey, port)})
	}
}

// putSettingsHandler 批量更新设置项。请求体 {key: value,...}：
//   - 未知 key / 非法值 → 400，整批拒绝；
//   - 敏感项：掩码（****开头）或空串视为「未修改」，跳过；
//   - revision 为内部版本号，禁止修改。
func putSettingsHandler(st *settings.Store, masterKey string, port int) gin.HandlerFunc {
	return func(c *gin.Context) {
		if st == nil {
			Fail(c, fmt.Errorf("设置存储未初始化"))
			return
		}
		var body map[string]any
		if err := c.ShouldBindJSON(&body); err != nil || body == nil {
			Fail(c, ErrBadRequest("请求体需为 JSON 对象 {key: value}"))
			return
		}

		updates := map[string]string{}
		for k, raw := range body {
			vs, ok := raw.(string)
			if !ok {
				vs = fmt.Sprint(raw)
			}
			spec, known := settingSpec(k)
			if !known {
				Fail(c, ErrBadRequest(fmt.Sprintf("未知设置项: %s", k)))
				return
			}
			if spec.Secret {
				// 掩码回写或空值 = 未修改，跳过（前端会把 GET 到的 masked 原样回传）
				if strings.HasPrefix(vs, "****") || strings.TrimSpace(vs) == "" {
					continue
				}
			}
			updates[k] = vs
		}

		if len(updates) == 0 { // 全部为掩码/空值回写：无变更，不 bump revision
			view, err := st.MaskedView()
			if err != nil {
				Fail(c, err)
				return
			}
			OK(c, gin.H{"items": view, "readonly": readonlyView(masterKey, port)})
			return
		}
		if err := st.Set(updates); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
		view, err := st.MaskedView()
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, gin.H{"items": view, "readonly": readonlyView(masterKey, port)})
	}
}

// testChannelHandler 发送 PushPlus 测试推送（M8.1c）。
// 请求体 {"token":"..."} 可选：传了就测未保存的新 token，否则测当前已存的。
func testChannelHandler(st *settings.Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		if st == nil {
			Fail(c, fmt.Errorf("设置存储未初始化"))
			return
		}
		var body struct {
			Token string `json:"token"`
		}
		_ = c.ShouldBindJSON(&body) // 允许空体
		token := strings.TrimSpace(body.Token)
		if token == "" {
			v, ok, err := st.Get("pushplus.token")
			if err != nil {
				Fail(c, err)
				return
			}
			if !ok || strings.TrimSpace(v) == "" {
				Fail(c, ErrBadRequest("尚未配置 PushPlus token，无法发送测试"))
				return
			}
			token = v
		}
		if err := alert.SendPushPlus(token, "fleetboard 测试推送", "这是一条来自 fleetboard 的测试消息，收到即代表 token 有效。"); err != nil {
			Fail(c, ErrBadGateway("测试推送发送失败: "+err.Error()))
			return
		}
		OK(c, gin.H{"sent": true})
	}
}

// settingSpec 暴露 settings 包的注册表查询（仅本包用）。
func settingSpec(key string) (settings.Spec, bool) {
	return settings.Lookup(key)
}
