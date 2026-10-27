import { useEffect, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";

import { Button } from "@/components/ui/Button";
import { Field, Input } from "@/components/ui/Form";
import { useAuth } from "@/store/auth";

interface LocationState {
  from?: string;
}

export function LoginPage() {
  const navigate = useNavigate();
  const location = useLocation();
  const login = useAuth((s) => s.login);
  const loggingIn = useAuth((s) => s.loggingIn);
  const error = useAuth((s) => s.error);
  const clearError = useAuth((s) => s.clearError);
  const access = useAuth((s) => s.access);

  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");

  const from = (location.state as LocationState | null)?.from ?? "/";

  // 已登录则直接回跳，避免重复登录
  useEffect(() => {
    if (access) navigate(from, { replace: true });
  }, [access, from, navigate]);

  const onSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!username || !password) return;
    try {
      await login(username.trim(), password);
      navigate(from, { replace: true });
    } catch {
      // 错误信息由 store 写入 error，下面统一展示
    }
  };

  return (
    <div className="flex min-h-full flex-col items-center justify-center bg-bg px-4 py-10">
      <div className="w-full max-w-[360px]">
        <div className="mb-6 flex items-center gap-2">
          <span className="inline-block h-2 w-2 rounded-full bg-accent" aria-hidden="true" />
          <span className="text-h1 tracking-tight text-text">fleetboard</span>
        </div>

        <div className="rounded-card border border-border bg-surface-1 p-5">
          <h1 className="text-h2 text-text">登录</h1>
          <p className="mt-1 text-body-sm text-text-muted">个人服务器管理控制台</p>

          <form className="mt-5 space-y-4" onSubmit={onSubmit}>
            <Field label="用户名" htmlFor="username">
              <Input
                id="username"
                name="username"
                autoComplete="username"
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
                value={username}
                onChange={(e) => {
                  setUsername(e.target.value);
                  if (error) clearError();
                }}
                placeholder="admin"
                disabled={loggingIn}
              />
            </Field>

            <Field label="密码" htmlFor="password">
              <Input
                id="password"
                name="password"
                type="password"
                autoComplete="current-password"
                value={password}
                onChange={(e) => {
                  setPassword(e.target.value);
                  if (error) clearError();
                }}
                placeholder="••••••••"
                disabled={loggingIn}
              />
            </Field>

            {error ? (
              <div
                role="alert"
                className="rounded-control border border-danger/40 bg-danger/10 px-3 py-2 text-body-sm text-danger"
              >
                {error}
              </div>
            ) : null}

            <Button
              type="submit"
              variant="primary"
              className="w-full"
              loading={loggingIn}
              disabled={!username || !password}
            >
              登录
            </Button>
          </form>
        </div>

        <p className="mt-4 text-caption text-text-faint">
          公网访问需先通过 Cloudflare Access 邮箱验证；本页仅校验控制台账号。
        </p>
      </div>
    </div>
  );
}
