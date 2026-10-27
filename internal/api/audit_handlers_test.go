package api

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestAuditRecordsOperations(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	// 触发一个受审计的操作
	cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "a", "host": "a",
	})
	if cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d body=%s", cw.Code, cw.Body)
	}

	w := authReq(r, http.MethodGet, "/api/audit", tokens.AccessToken, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}

	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Data) == 0 {
		t.Fatal("审计列表为空")
	}

	found := false
	for _, it := range resp.Data {
		if it["action"] == "POST /api/servers" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("未记录 'POST /api/servers' 审计，实际=%v", resp.Data)
	}
}

func TestAuditRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodGet, "/api/audit", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}
