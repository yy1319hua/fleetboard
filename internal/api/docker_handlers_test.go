package api

import (
	"net/http"
	"testing"
)

func TestListContainersRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodGet, "/api/servers/1/containers", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestListContainersServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999/containers", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestListContainersConnectionError(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "x", "host": "unreachable", "auth_method": "key", "private_key": "K",
	})
	if cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d", cw.Code)
	}

	w := authReq(r, http.MethodGet, "/api/servers/1/containers", tokens.AccessToken, nil)
	if w.Code != http.StatusBadGateway {
		t.Errorf("status=%d, want 502 body=%s", w.Code, w.Body)
	}
}

func TestContainerActionRequiresBody(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/1/containers/abc/actions", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestContainerActionServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/999/containers/abc/actions", tokens.AccessToken,
		map[string]any{"action": "start"})
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestContainerActionConnectionError(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	if cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "x", "host": "unreachable", "auth_method": "key", "private_key": "K",
	}); cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d", cw.Code)
	}

	w := authReq(r, http.MethodPost, "/api/servers/1/containers/abc/actions", tokens.AccessToken,
		map[string]any{"action": "start"})
	if w.Code != http.StatusBadGateway {
		t.Errorf("status=%d, want 502 body=%s", w.Code, w.Body)
	}
}

func TestContainerActionRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodPost, "/api/servers/1/containers/abc/actions", "", map[string]any{"action": "start"})
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestLogsRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodGet, "/api/servers/1/containers/abc/logs", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestLogsBadTail(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/1/containers/abc/logs?tail=x", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestLogsServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999/containers/abc/logs", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestLogsConnectionError(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	if cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "x", "host": "unreachable", "auth_method": "key", "private_key": "K",
	}); cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d", cw.Code)
	}

	w := authReq(r, http.MethodGet, "/api/servers/1/containers/abc/logs", tokens.AccessToken, nil)
	if w.Code != http.StatusBadGateway {
		t.Errorf("status=%d, want 502 body=%s", w.Code, w.Body)
	}
}

func TestListImagesRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodGet, "/api/servers/1/images", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestPullImageRequiresBody(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/1/images/pull", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestPullImageServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/999/images/pull", tokens.AccessToken,
		map[string]any{"image": "nginx:alpine"})
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestRemoveImageServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodDelete, "/api/servers/999/images/sha256:abc", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestListNetworksServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999/networks", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestListVolumesServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999/volumes", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestListNetworksRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodGet, "/api/servers/1/networks", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestContainerStatsServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999/container-stats", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestContainerStatsRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodGet, "/api/servers/1/container-stats", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

// 卷删除：卷名先校验再连 SSH，非法名必须 400 而不是打到远端。
func TestRemoveVolumeRejectsBadName(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodDelete, "/api/servers/1/volumes/-bad-name", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400 body=%s", w.Code, w.Body)
	}
}

func TestRemoveVolumeRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodDelete, "/api/servers/1/volumes/vol1", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

// 空间回收：targets 必须显式给出，空数组与未知目标都必须在连远端前拒绝。
func TestPruneRejectsEmptyTargets(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/1/docker/prune", tokens.AccessToken, map[string]any{})
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400 body=%s", w.Code, w.Body)
	}
}

func TestPruneRejectsUnknownTarget(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/1/docker/prune", tokens.AccessToken, map[string]any{
		"targets": []string{"all"},
	})
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400 body=%s", w.Code, w.Body)
	}
}

func TestPruneRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodPost, "/api/servers/1/docker/prune", "", map[string]any{
		"targets": []string{"images"},
	})
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}
