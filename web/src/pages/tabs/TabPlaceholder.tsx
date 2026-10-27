import { EmptyState } from "@/components/ui/Feedback";

/** 标签页占位（后续小项逐个替换）。 */
export function TabPlaceholder({ title, note }: { title: string; note: string }) {
  return (
    <div className="rounded-card border border-border bg-surface-1">
      <EmptyState title={title} description={note} />
    </div>
  );
}
