package api

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestLogsTicketRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodPost, "/api/servers/1/containers/abc/logs-ticket", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestLogsTicketInvalidContainerID(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/1/containers/a;b/logs-ticket", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400 body=%s", w.Code, w.Body)
	}
}

func TestLogsTicketIssued(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/3/containers/abc123/logs-ticket", tokens.AccessToken, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}

	var body struct {
		Code int `json:"code"`
		Data struct {
			Ticket    string `json:"ticket"`
			ExpiresIn int    `json:"expires_in"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Data.Ticket == "" {
		t.Error("票据为空")
	}
	if body.Data.ExpiresIn <= 0 || body.Data.ExpiresIn > 300 {
		t.Errorf("expires_in 异常: %d", body.Data.ExpiresIn)
	}
}

func TestWSWithoutCredentials(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	// 既无 Authorization 也无 ticket
	w := authReq(r, http.MethodGet, "/api/servers/1/containers/abc/logs", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestWSWithInvalidTicket(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodGet, "/api/servers/1/containers/abc/logs?ticket=bogus", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401 body=%s", w.Code, w.Body)
	}
}
