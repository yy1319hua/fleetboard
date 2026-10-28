package api

import (
	"fmt"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/settings"
)

// getSettingsHandler 返回全部设置项。敏感项只回 {"masked":"****尾4位","set":bool}。
func getSettingsHandler(st *settings.Store) gin.HandlerFunc {
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
		OK(c, view)
	}
}

// putSettingsHandler 批量更新设置项。请求体 {key: value,...}：
//   - 未知 key / 非法值 → 400，整批拒绝；
//   - 敏感项：掩码（****开头）或空串视为「未修改」，跳过；
//   - revision 为内部版本号，禁止修改。
func putSettingsHandler(st *settings.Store) gin.HandlerFunc {
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
		if len(updates) == 0 {
			view, err := st.MaskedView()
			if err != nil {
				Fail(c, err)
				return
			}
			OK(c, view)
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
		OK(c, view)
	}
}

// settingSpec 暴露 settings 包的注册表查询（仅本包用）。
func settingSpec(key string) (settings.Spec, bool) {
	return settings.Lookup(key)
}
