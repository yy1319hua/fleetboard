import { EmptyState } from "@/components/ui/Feedback";

/** 通用占位页（后续小项逐个替换为真实页面）。 */
export function PlaceholderPage({ title, note }: { title: string; note?: string }) {
  return (
    <div className="space-y-4">
      <h1 className="text-h1 text-text">{title}</h1>
      <div className="rounded-card border border-border bg-surface-1">
        <EmptyState title="尚未实现" description={note ?? "该页面将在后续小项中实现。"} />
      </div>
    </div>
  );
}
