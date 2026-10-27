package db

import "testing"

func TestInsertAndListAudit(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	sid := int64(7)
	if err := InsertAudit(d, 1, &sid, "POST /api/servers", "/api/servers", "ok"); err != nil {
		t.Fatalf("InsertAudit: %v", err)
	}
	if err := InsertAudit(d, 1, nil, "GET /api/servers", "/api/servers", "ok"); err != nil {
		t.Fatal(err)
	}

	list, err := ListAudit(d, 10)
	if err != nil {
		t.Fatalf("ListAudit: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("len=%d, want 2", len(list))
	}
	// 倒序：最新在前
	if list[0].Action != "GET /api/servers" {
		t.Errorf("latest action=%q", list[0].Action)
	}
	if list[1].ServerID == nil || *list[1].ServerID != 7 {
		t.Errorf("server_id=%v, want 7", list[1].ServerID)
	}
}

func TestListAuditLimit(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	for i := 0; i < 5; i++ {
		if err := InsertAudit(d, 1, nil, "act", "detail", "ok"); err != nil {
			t.Fatal(err)
		}
	}
	list, err := ListAudit(d, 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 3 {
		t.Errorf("len=%d, want 3", len(list))
	}
}
