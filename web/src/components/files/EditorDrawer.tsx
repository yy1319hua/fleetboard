import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";

import { Button } from "@/components/ui/Button";
import { ErrorState, InlineLoading } from "@/components/ui/Feedback";
import { toast } from "@/components/ui/Toast";
import { readText, writeText } from "@/lib/files";
import { formatBytes } from "@/lib/format";
import { cn } from "@/lib/cn";

/** 在线编辑抽屉：读取文本 → 编辑 → 原子写回（后端保证权限属主不变）。 */
export function EditorDrawer({
  serverID,
  path,
  onClose,
  onSaved,
}: {
  serverID: number;
  path: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  const { data, isLoading, isError, error, refetch } = useQuery({
    queryKey: ["file-content", serverID, path],
    queryFn: () => readText(serverID, path),
  });

  const [draft, setDraft] = useState<string>("");
  const [saving, setSaving] = useState(false);
  const [loadedFor, setLoadedFor] = useState<string | null>(null);

  useEffect(() => {
    if (data && loadedFor !== data.path) {
      setDraft(data.content);
      setLoadedFor(data.path);
    }
  }, [data, loadedFor]);

  // Esc 关闭（有改动先确认）
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") requestClose();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draft, data]);

  const dirty = data ? draft !== data.content : false;

  function requestClose() {
    if (dirty && !window.confirm("有未保存的修改，确定关闭？")) return;
    onClose();
  }

  const save = async () => {
    setSaving(true);
    try {
      await writeText(serverID, path, draft);
      toast("已保存", "ok");
      onSaved();
    } catch (e) {
      toast(e instanceof Error ? e.message : "保存失败", "danger");
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="fixed inset-0 z-40 flex justify-end">
      <div className="absolute inset-0 bg-[#05070a]/60" onClick={requestClose} aria-hidden="true" />

      <div
        role="dialog"
        aria-modal="true"
        aria-label={`编辑 ${path}`}
        className="relative flex h-full w-full flex-col border-l border-border bg-surface-1 shadow-modal sm:w-[620px]"
      >
        <div className="flex items-start justify-between gap-3 border-b border-border px-4 py-3">
          <div className="min-w-0">
            <div className="eyebrow">编辑文件</div>
            <div className="mt-0.5 truncate font-mono text-mono text-text">{path}</div>
          </div>
          <div className="flex shrink-0 items-center gap-1.5">
            <Button variant="ghost" size="sm" onClick={requestClose}>
              关闭
            </Button>
            <Button variant="primary" size="sm" onClick={() => void save()} loading={saving} disabled={!dirty}>
              保存
            </Button>
          </div>
        </div>

        <div className="flex min-h-0 flex-1 flex-col">
          {isLoading ? (
            <div className="px-4 py-4">
              <InlineLoading label="读取文件" />
            </div>
          ) : isError ? (
            <ErrorState
              message={error instanceof Error ? error.message : "读取失败"}
              onRetry={() => void refetch()}
            />
          ) : (
            <textarea
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              spellCheck={false}
              className={cn(
                "min-h-0 flex-1 resize-none border-0 bg-[var(--terminal)] px-4 py-3",
                "font-mono text-mono text-text outline-none",
              )}
            />
          )}
        </div>

        <div className="flex items-center justify-between gap-2 border-t border-border px-4 py-2 text-caption text-text-faint">
          <span className="tabular font-mono">
            {formatBytes(new Blob([draft]).size)}
            {data ? ` / ${formatBytes(data.size)}` : ""}
          </span>
          <span>{dirty ? "未保存" : "已保存"}</span>
        </div>
      </div>
    </div>
  );
}
