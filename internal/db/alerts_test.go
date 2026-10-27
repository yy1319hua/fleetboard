package db

import (
	"errors"
	"testing"
)

func TestAlertRuleCRUD(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	r, err := CreateAlertRule(d, AlertRuleInput{
		Metric: "cpu_pct", Operator: ">", Threshold: 80, Severity: "warn", Enabled: true,
	})
	if err != nil {
		t.Fatalf("CreateAlertRule: %v", err)
	}
	if r.ID == 0 || !r.Enabled || r.Metric != "cpu_pct" {
		t.Errorf("%+v", r)
	}

	list, err := ListAlertRules(d)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 {
		t.Errorf("len=%d, want 1", len(list))
	}

	if err := DeleteAlertRule(d, r.ID); err != nil {
		t.Fatalf("DeleteAlertRule: %v", err)
	}
	if err := DeleteAlertRule(d, r.ID); !errors.Is(err, ErrRuleNotFound) {
		t.Errorf("重复删除应 ErrRuleNotFound，实际 %v", err)
	}
}

func TestAlertRuleDefaults(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	r, err := CreateAlertRule(d, AlertRuleInput{Metric: "mem_pct"})
	if err != nil {
		t.Fatal(err)
	}
	if r.Operator != ">" || r.Severity != "warn" || r.NotifyChannels != "inapp" {
		t.Errorf("默认值错误: %+v", r)
	}
}

func TestAlertEvents(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	id, err := InsertAlertEvent(d, nil, nil, "warn", "标题", "内容")
	if err != nil {
		t.Fatalf("InsertAlertEvent: %v", err)
	}

	list, err := ListAlertEvents(d, false, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].IsRead {
		t.Errorf("%+v", list)
	}

	if err := MarkAlertRead(d, id); err != nil {
		t.Fatal(err)
	}
	unread, err := ListAlertEvents(d, true, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(unread) != 0 {
		t.Errorf("标记已读后未读列表应为空，实际 %d", len(unread))
	}
}
