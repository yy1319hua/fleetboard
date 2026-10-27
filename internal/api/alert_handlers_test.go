package api

import (
	"net/http"
	"testing"
)

func TestListAlertRulesRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodGet, "/api/alert-rules", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestCreateAlertRuleRequiresBody(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/alert-rules", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestCreateAlertRuleOK(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/alert-rules", tokens.AccessToken, map[string]any{
		"metric": "cpu_pct", "operator": ">", "threshold": 80, "severity": "warn", "enabled": true,
	})
	if w.Code != http.StatusCreated {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}

	lw := authReq(r, http.MethodGet, "/api/alert-rules", tokens.AccessToken, nil)
	if lw.Code != http.StatusOK {
		t.Fatalf("list status=%d", lw.Code)
	}
}

func TestDeleteAlertRuleNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodDelete, "/api/alert-rules/999", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}
