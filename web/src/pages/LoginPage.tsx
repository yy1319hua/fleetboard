import { Link } from "react-router-dom";

/** 登录页占位（M6.2 实现正式表单）。 */
export function LoginPage() {
  return (
    <div className="flex min-h-full items-center justify-center bg-bg px-4 py-10">
      <div className="w-full max-w-sm space-y-4">
        <div className="flex items-center gap-2">
          <span className="inline-block h-2 w-2 rounded-full bg-accent" aria-hidden="true" />
          <span className="text-h1 tracking-tight text-text">fleetboard</span>
        </div>
        <p className="text-body-sm text-text-muted">登录页将在 M6.2 实现。</p>
        <Link className="text-body-sm text-accent underline-offset-2 hover:underline" to="/">
          返回总览
        </Link>
      </div>
    </div>
  );
}
