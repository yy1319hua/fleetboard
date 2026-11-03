package api

import (
	"testing"
	"time"
)

func TestCreateWithOpReuse(t *testing.T) {
	s := NewJobStore(time.Hour)
	defer close(s.stop)

	first, reused := s.CreateWithOpReuse("op-1", "packages.update", 1, 7)
	if reused {
		t.Fatal("首次创建不应标记为复用")
	}

	second, reused := s.CreateWithOpReuse("op-1", "packages.update", 1, 7)
	if !reused {
		t.Fatal("同 opID 的活跃任务应复用")
	}
	if first.JobID != second.JobID {
		t.Errorf("复用应返回同一 job：%s vs %s", first.JobID, second.JobID)
	}

	// 终态任务不再复用：用户重试时应能真正再跑一次。
	first.finish(JobDone, "")
	third, reused := s.CreateWithOpReuse("op-1", "packages.update", 1, 7)
	if reused {
		t.Error("终态任务不应复用")
	}
	if third.JobID == first.JobID {
		t.Error("终态后应新建 job")
	}
}

func TestCreateWithOpEmptyIDAlwaysNew(t *testing.T) {
	s := NewJobStore(time.Hour)
	defer close(s.stop)

	a, reusedA := s.CreateWithOpReuse("", "packages.update", 1, 7)
	b, reusedB := s.CreateWithOpReuse("", "packages.update", 1, 7)
	if reusedA || reusedB {
		t.Error("未提供 opID 时不应复用")
	}
	if a.JobID == b.JobID {
		t.Error("未提供 opID 时应各自新建")
	}
}
