package api

import (
	"context"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

// JobStatus 是 job 状态机的取值。
type JobStatus string

const (
	JobPending   JobStatus = "pending"
	JobRunning   JobStatus = "running"
	JobDone      JobStatus = "done"
	JobFailed    JobStatus = "failed"
	JobCancelled JobStatus = "cancelled"
)

// Job 表示一个后台任务（如软件包升级）。
// 底层执行 ctx 独立于 HTTP 请求 ctx：App 断连后升级仍可跑完，供 GET /api/jobs/:id 续接。
type Job struct {
	JobID     string    `json:"jobId"`
	Kind      string    `json:"kind"`
	Status    JobStatus `json:"status"`
	ServerID  int64     `json:"serverId"`
	UID       int64     `json:"uid"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
	Lines     []string  `json:"lines"`
	Err       string    `json:"error,omitempty"`

	mu     sync.Mutex
	ctx    context.Context
	cancel context.CancelFunc
}

// AppendLine 追加一行输出（底层升级回调），并刷新 UpdatedAt。
func (j *Job) AppendLine(line string) {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.Lines = append(j.Lines, line)
	j.UpdatedAt = time.Now()
}

// finish 将状态推进到终态；若已是终态（如已被取消）则不覆盖。
func (j *Job) finish(st JobStatus, errMsg string) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.Status == JobDone || j.Status == JobFailed || j.Status == JobCancelled {
		return
	}
	j.Status = st
	j.Err = errMsg
	j.UpdatedAt = time.Now()
}

// Cancel 取消底层 ctx（→ SIGINT 中断远端 apt），并将状态置为 cancelled（终态不覆盖）。
func (j *Job) Cancel() {
	j.cancel()
	j.mu.Lock()
	if j.Status != JobDone && j.Status != JobFailed && j.Status != JobCancelled {
		j.Status = JobCancelled
		j.UpdatedAt = time.Now()
	}
	j.mu.Unlock()
}

// Context 返回底层执行所用 ctx（context.Background 派生，独立于请求）。
func (j *Job) Context() context.Context { return j.ctx }

// Snapshot 返回一份字段拷贝，供 GET 序列化，避免与后台写入竞争。
func (j *Job) Snapshot() Job {
	j.mu.Lock()
	defer j.mu.Unlock()
	lines := make([]string, len(j.Lines))
	copy(lines, j.Lines)
	return Job{
		JobID:     j.JobID,
		Kind:      j.Kind,
		Status:    j.Status,
		ServerID:  j.ServerID,
		UID:       j.UID,
		CreatedAt: j.CreatedAt,
		UpdatedAt: j.UpdatedAt,
		Lines:     lines,
		Err:       j.Err,
	}
}

func (j *Job) isTerminal() bool {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.Status == JobDone || j.Status == JobFailed || j.Status == JobCancelled
}

// JobStore 进程内 job 注册表：map[jobID]*Job + RWMutex + 24h TTL 后台清理。
// 另维护 opID → jobID 索引以支持 X-Client-Op-Id 幂等。
type JobStore struct {
	mu      sync.RWMutex
	jobs    map[string]*Job
	opIndex map[string]string
	ttl     time.Duration
	stop    chan struct{}
}

// jobStore 是全局单例，供 handler 与后台升级 goroutine 共享。
var jobStore = NewJobStore(24 * time.Hour)

// NewJobStore 创建并启动清理 goroutine。
func NewJobStore(ttl time.Duration) *JobStore {
	s := &JobStore{
		jobs:    make(map[string]*Job),
		opIndex: make(map[string]string),
		ttl:     ttl,
		stop:    make(chan struct{}),
	}
	go s.sweep()
	return s
}

// Create 新建并登记一个 running 态 job，底层 ctx 独立于请求 ctx。
func (s *JobStore) Create(kind string, serverID, uid int64) *Job {
	return s.CreateWithOp("", kind, serverID, uid)
}

// CreateWithOp 同 Create，但若提供了 opID 且存在活跃（pending/running）的同 opID job，
// 直接返回既有 job（X-Client-Op-Id 幂等，避免重复 apt upgrade）。
func (s *JobStore) CreateWithOp(opID, kind string, serverID, uid int64) *Job {
	if opID != "" {
		if j := s.GetByOp(opID); j != nil {
			return j
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	j := &Job{
		JobID:     uuid.NewString(),
		Kind:      kind,
		Status:    JobRunning,
		ServerID:  serverID,
		UID:       uid,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
		Lines:     []string{},
		ctx:       ctx,
		cancel:    cancel,
	}

	s.mu.Lock()
	s.jobs[j.JobID] = j
	if opID != "" {
		s.opIndex[opID] = j.JobID
	}
	s.mu.Unlock()
	return j
}

// Get 按 jobID 取 job（无则 nil）。
func (s *JobStore) Get(jobID string) *Job {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.jobs[jobID]
}

// GetByOp 返回同 opID 且仍处于活跃（pending/running）的 job；否则清理陈旧索引并返回 nil。
func (s *JobStore) GetByOp(opID string) *Job {
	s.mu.RLock()
	jobID, ok := s.opIndex[opID]
	s.mu.RUnlock()
	if !ok {
		return nil
	}
	j := s.Get(jobID)
	if j == nil {
		return nil
	}
	j.mu.Lock()
	active := j.Status == JobPending || j.Status == JobRunning
	j.mu.Unlock()
	if !active {
		s.mu.Lock()
		if s.opIndex[opID] == jobID {
			delete(s.opIndex, opID)
		}
		s.mu.Unlock()
		return nil
	}
	return j
}

// Cancel 取消指定 job（调用方已做权限校验）。
func (s *JobStore) Cancel(jobID string) *Job {
	j := s.Get(jobID)
	if j == nil {
		return nil
	}
	j.Cancel()
	return j
}

// sweep 定期清理超过 TTL（创建超过 24h）的 job。
func (s *JobStore) sweep() {
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-t.C:
			cutoff := time.Now().Add(-s.ttl)
			s.mu.Lock()
			for id, j := range s.jobs {
				j.mu.Lock()
				stale := j.CreatedAt.Before(cutoff)
				j.mu.Unlock()
				if stale {
					delete(s.jobs, id)
				}
			}
			s.mu.Unlock()
		}
	}
}

// jobGetHandler 返回指定 job 的当前快照（含已收集输出行）。
// GET /api/jobs/:id
func jobGetHandler() gin.HandlerFunc {
	return func(c *gin.Context) {
		j := jobStore.Get(c.Param("id"))
		if j == nil {
			Fail(c, ErrNotFound("任务不存在"))
			return
		}
		OK(c, j.Snapshot())
	}
}

// jobDeleteHandler 触发取消指定 job：取消底层 ctx（→ SIGINT）并将状态置 cancelled。
// 返回前校验 job.UID == token.uid（纵深防御，避免取消他人任务）。
// DELETE /api/jobs/:id
func jobDeleteHandler() gin.HandlerFunc {
	return func(c *gin.Context) {
		id := c.Param("id")
		j := jobStore.Get(id)
		if j == nil {
			Fail(c, ErrNotFound("任务不存在"))
			return
		}
		if j.UID != CurrentUserID(c) {
			Fail(c, ErrForbidden("无权操作该任务"))
			return
		}
		jobStore.Cancel(id)
		OK(c, j.Snapshot())
	}
}
