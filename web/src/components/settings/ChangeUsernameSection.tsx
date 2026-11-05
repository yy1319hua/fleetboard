import { useMutation } from "@tanstack/react-query";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { Field, Input } from "@/components/ui/Form";
import { toast } from "@/components/ui/Toast";
import { changeUsername } from "@/lib/system";
import { useAuth } from "@/store/auth";

/** 与后端 usernamePattern 对齐：3–32 位，字母或数字开头，仅字母数字 . _ - */
const USERNAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{2,31}$/;

/**
 * 修改用户名（B1）。
 *
 * 后端语义：改名不签发新 token、不 bump JWT ver —— 当前会话与其他已登录端都无感。
 * 所以这里成功后只更新本地显示名，不要求重新登录。
 */
export function ChangeUsernameSection() {
  const current = useAuth((s) => s.username);
  const setUsername = useAuth((s) => s.setUsername);

  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [pwd, setPwd] = useState("");
  const [err, setErr] = useState<string | null>(null);

  const mut = useMutation({
    mutationFn: () => changeUsername(name.trim(), pwd),
    onSuccess: () => {
      setUsername(name.trim());
      toast("用户名已修改，当前会话继续有效", "ok");
      setName("");
      setPwd("");
      setErr(null);
      setOpen(false);
    },
    onError: (e: Error) => {
      setErr(e.message);
      toast(e.message, "danger");
    },
  });

  const submit = () => {
    const v = name.trim();
    if (!USERNAME_RE.test(v)) {
      setErr("需 3–32 位，字母或数字开头，只允许字母、数字、下划线、点、短横线");
      return;
    }
    if (v === current) {
      setErr("新用户名与当前用户名相同");
      return;
    }
    if (!pwd) {
      setErr("请输入当前密码");
      return;
    }
    mut.mutate();
  };

  return (
    <div className="rounded-control border border-border bg-surface-2 p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="min-w-0">
          <div className="text-body-sm text-text-muted">用户名</div>
          <div className="font-mono text-mono text-text">{current ?? "—"}</div>
        </div>
        <Button
          variant="secondary"
          size="sm"
          onClick={() => {
            setOpen(!open);
            setErr(null);
          }}
        >
          {open ? "收起" : "修改用户名"}
        </Button>
      </div>

      {open ? (
        <div className="mt-3 space-y-3">
          <Field label="新用户名" htmlFor="new-username" error={err} hint="3–32 位，字母或数字开头">
            <Input
              id="new-username"
              value={name}
              autoComplete="username"
              onChange={(e) => setName(e.target.value)}
              placeholder="例如 ops-admin"
            />
          </Field>
          <Field label="当前密码（确认身份）" htmlFor="username-pwd">
            <Input
              id="username-pwd"
              type="password"
              autoComplete="current-password"
              value={pwd}
              onChange={(e) => setPwd(e.target.value)}
            />
          </Field>
          <Button variant="primary" loading={mut.isPending} onClick={submit}>
            确认修改
          </Button>
        </div>
      ) : null}
    </div>
  );
}
