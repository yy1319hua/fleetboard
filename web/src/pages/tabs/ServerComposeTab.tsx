import { useEffect, useState } from "react";
import { useOutletContext } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import CodeMirror from "@uiw/react-codemirror";
import { yaml } from "@codemirror/lang-yaml";
import { EditorView } from "@codemirror/view";

import { Button } from "@/components/ui/Button";
import { EmptyState, ErrorState, InlineLoading, SkeletonRows } from "@/components/ui/Feedback";
import { toast } from "@/components/ui/Toast";
import {
  COMPOSE_ACTION_LABEL,
  composeAction,
  listCompose,
  readCompose,
  writeCompose,
  type ComposeAction,
} from "@/lib/compose";
import { formatBytes, formatDateTime } from "@/lib/format";
import { cn } from "@/lib/cn";
import type { Server } from "@/lib/types";

interface Ctx {
  server: Server;
}

/** 与 DESIGN token 对齐的编辑器主题（深色、琥珀光标/选中）。 */
const editorTheme = EditorView.theme(
  {
    "&": {
      backgroundColor: "var(--terminal)",
      color: "var(--text)",
      fontSize: "13px",
      height: "100%",
    },
    ".cm-content": { fontFamily: '"JetBrains Mono Variable", Menlo, Consolas, monospace', padding: "8px 0" },
    ".cm-gutters": {
      backgroundColor: "var(--terminal)",
      color: "var(--text-faint)",
      border: "none",
    },
    ".cm-activeLine": { backgroundColor: "rgba(232,163,61,0.06)" },
    ".cm-activeLineGutter": { backgroundColor: "rgba(232,163,61,0.10)", color: "var(--accent)" },
    "&.cm-focused .cm-cursor": { borderLeftColor: "var(--accent)" },
    "&.cm-focused .cm-selectionBackground, .cm-selectionBackground": {
      backgroundColor: "rgba(232,163,61,0.20) !important",
    },
    ".cm-scroller": { overflow: "auto" },
  },
  { dark: true },
);

export function ServerComposeTab() {
  const { server } = useOutletContext<Ctx>();
  const qc = useQueryClient();

  const [dir, setDir] = useState<string | undefined>(undefined);
  const [selected, setSelected] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [output, setOutput] = useState<{ action: string; text: string; ok: boolean } | null>(null);

  const list = useQuery({
    queryKey: ["compose", server.id, dir ?? "default"],
    queryFn: () => listCompose(server.id, dir),
  });

  const content = useQuery({
    queryKey: ["compose-content", server.id, selected],
    queryFn: () => readCompose(server.id, selected as string),
    enabled: Boolean(selected),
  });

  // 载入内容到草稿
  useEffect(() => {
    if (content.data && content.data.path === selected) {
      setDraft(content.data.content);
    }
  }, [content.data, selected]);

  const save = useMutation({
    mutationFn: () => writeCompose(server.id, selected as string, draft),
    onSuccess: () => {
      toast("已保存", "ok");
      void qc.invalidateQueries({ queryKey: ["compose-content", server.id, selected] });
      void qc.invalidateQueries({ queryKey: ["compose", server.id] });
    },
    onError: (e) => toast(e instanceof Error ? e.message : "保存失败", "danger"),
  });

  const act = useMutation({
    mutationFn: (action: ComposeAction) => composeAction(server.id, selected as string, action),
    onSuccess: (data, action) => {
      setOutput({ action, text: data.output || "（无输出）", ok: true });
      toast(`${COMPOSE_ACTION_LABEL[action]} 完成`, "ok");
      void qc.invalidateQueries({ queryKey: ["docker", server.id] });
    },
    onError: (e, action) => {
      setOutput({ action, text: e instanceof Error ? e.message : "执行失败", ok: false });
      toast("执行失败", "danger");
    },
  });

  const dirty = Boolean(content.data && draft !== content.data.content);
  const files = list.data?.files ?? [];
  const dirs = list.data?.dirs ?? [];

  // 当前实际浏览目录所属的白名单根：用于让下拉框跟随目录变化，
  // 否则进入子目录后下拉仍显示「默认」，用户会误判当前位置。
  const roots = list.data?.roots ?? [];
  const currentRoot = roots.find((r) => dir === r || dir?.startsWith(`${r}/`)) ?? "";

  return (
    <div className="grid grid-cols-1 gap-3 lg:grid-cols-[300px_minmax(0,1fr)]">
      {/* 文件选择 */}
      <div className="rounded-card border border-border bg-surface-1">
        <div className="flex items-center justify-between gap-2 border-b border-border px-3 py-2">
          <span className="eyebrow">compose 文件</span>
          <Button size="sm" variant="ghost" onClick={() => void list.refetch()} disabled={list.isFetching}>
            刷新
          </Button>
        </div>

        <div className="border-b border-border px-3 py-2">
          <label className="mb-1 block text-caption text-text-faint" htmlFor="compose-root">
            浏览根目录（白名单）
          </label>
          <select
            id="compose-root"
            value={currentRoot ?? ""}
            onChange={(e) => {
              setDir(e.target.value || undefined);
              setSelected(null);
            }}
            className="h-[32px] w-full rounded-control border border-border bg-surface-2 px-2 font-mono text-mono-sm text-text"
          >
            <option value="">默认（{list.data?.roots[0] ?? "/root"}）</option>
            {(list.data?.roots ?? []).map((r) => (
              <option key={r} value={r}>
                {r}
              </option>
            ))}
          </select>
        </div>

        <div className="max-h-[420px] overflow-y-auto">
          {list.isLoading ? (
            <SkeletonRows rows={4} cols={2} />
          ) : list.isError ? (
            <ErrorState
              message={list.error instanceof Error ? list.error.message : "读取失败"}
              onRetry={() => void list.refetch()}
            />
          ) : files.length === 0 && dirs.length === 0 ? (
            <EmptyState
              title="未找到 compose 文件"
              description="该目录下没有 docker-compose.yml / compose.yaml，可切换根目录再找，或用文件管理器上传。"
            />
          ) : (
            <ul className="divide-y divide-border">
              <li className="flex items-center justify-between px-3 py-1.5">
                <span className="font-mono text-caption text-text-faint">{list.data?.dir}</span>
                {dir ? (
                  <button
                    type="button"
                    className="text-caption text-accent hover:underline"
                    onClick={() => {
                      const cur = list.data?.dir ?? "";
                      const up = cur.replace(/\/[^/]+$/, "") || "/";
                      setDir(up);
                      setSelected(null);
                    }}
                  >
                    上一级
                  </button>
                ) : null}
              </li>
              {dirs.map((d) => (
                <li key={d}>
                  <button
                    type="button"
                    onClick={() => {
                      const cur = list.data?.dir ?? "/";
                      setDir(cur.endsWith("/") ? `${cur}${d}` : `${cur}/${d}`);
                      setSelected(null);
                    }}
                    className="flex w-full items-center gap-2 px-3 py-2 text-left font-mono text-mono-sm text-text-muted hover:bg-surface-2 hover:text-text"
                  >
                    📁 {d}
                  </button>
                </li>
              ))}
              {files.map((f) => (
                <li key={f.path}>
                  <button
                    type="button"
                    onClick={() => setSelected(f.path)}
                    className={cn(
                      "w-full px-3 py-2 text-left transition-colors duration-ui ease-ui hover:bg-surface-2",
                      selected === f.path ? "bg-accent-soft" : "",
                    )}
                  >
                    <div className="truncate font-mono text-mono-sm text-text">{f.name}</div>
                    <div className="tabular text-caption text-text-faint">
                      {formatBytes(f.size)} · {formatDateTime(f.mod_time)}
                    </div>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>

      {/* 编辑器 */}
      <div className="rounded-card border border-border bg-surface-1">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-border px-3 py-2">
          <div className="min-w-0">
            <span className="eyebrow">YAML 编辑</span>
            <div className="truncate font-mono text-mono-sm text-text-muted">
              {selected ?? "未选择文件"}
              {dirty ? <span className="ml-2 text-warn">未保存</span> : null}
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-1.5">
            <Button
              size="sm"
              variant="secondary"
              onClick={() => {
                setDraft(content.data?.content ?? "");
                toast("已还原为已保存内容", "info");
              }}
              disabled={!dirty}
            >
              还原
            </Button>
            <Button
              size="sm"
              variant="primary"
              onClick={() => save.mutate()}
              loading={save.isPending}
              disabled={!selected || !dirty}
            >
              保存
            </Button>
          </div>
        </div>

        {!selected ? (
          <EmptyState title="选择左侧的 compose 文件" description="可查看并编辑 YAML，或对选中文件执行 up / down / restart / ps。" />
        ) : content.isLoading ? (
          <div className="px-4 py-4">
            <InlineLoading label="读取文件" />
          </div>
        ) : content.isError ? (
          <ErrorState
            message={content.error instanceof Error ? content.error.message : "读取失败"}
            onRetry={() => void content.refetch()}
          />
        ) : (
          <>
            <div className="h-[380px] overflow-hidden">
              <CodeMirror
                value={draft}
                height="380px"
                theme={editorTheme}
                extensions={[yaml()]}
                basicSetup={{ lineNumbers: true, foldGutter: true, highlightActiveLine: true }}
                onChange={(v) => setDraft(v)}
              />
            </div>

            <div className="flex flex-wrap items-center gap-2 border-t border-border px-3 py-2">
              <span className="eyebrow mr-1">操作</span>
              {(["up", "down", "restart", "ps"] as ComposeAction[]).map((a) => (
                <Button
                  key={a}
                  size="sm"
                  variant={a === "up" ? "primary" : a === "down" ? "danger" : "secondary"}
                  loading={act.isPending && act.variables === a}
                  disabled={act.isPending || (dirty && a !== "ps")}
                  title={dirty && a !== "ps" ? "有未保存修改，请先保存再执行" : undefined}
                  onClick={() => {
                    if (a === "down" && !window.confirm("执行 docker compose down？该 compose 项目下的容器会被停止并移除。")) return;
                    act.mutate(a);
                  }}
                >
                  {COMPOSE_ACTION_LABEL[a]}
                </Button>
              ))}
            </div>

            {output ? (
              <div className="border-t border-border">
                <div className="flex items-center justify-between px-3 py-1.5">
                  <span className="eyebrow">{output.action} 输出</span>
                  <button
                    type="button"
                    className="text-caption text-text-faint hover:text-text"
                    onClick={() => setOutput(null)}
                  >
                    清除
                  </button>
                </div>
                <pre
                  className={cn(
                    "max-h-56 overflow-auto whitespace-pre-wrap break-all bg-[var(--terminal)] px-3 py-2 font-mono text-mono-sm",
                    output.ok ? "text-text" : "text-danger",
                  )}
                >
                  {output.text}
                </pre>
              </div>
            ) : null}
          </>
        )}
      </div>
    </div>
  );
}
