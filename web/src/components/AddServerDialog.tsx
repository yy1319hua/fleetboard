import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/Form";
import { useCreateServer } from "@/lib/queries";

const initial = {
  name: "",
  host: "",
  port: "22",
  ssh_user: "root",
  auth_method: "key" as "key" | "password",
  private_key: "",
  password: "",
  key_pass: "",
  tags: "",
};

/** 纳管服务器：填 IP + 凭据即可（零配置目标）。凭据经后端加密后落库，不回显。 */
export function AddServerDialog({
  open,
  onClose,
  onError,
}: {
  open: boolean;
  onClose: () => void;
  onError: (msg: string) => void;
}) {
  const [form, setForm] = useState(initial);
  const create = useCreateServer();

  const set = <K extends keyof typeof initial>(key: K, value: (typeof initial)[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }));

  const portNum = Number(form.port);
  const portValid = Number.isInteger(portNum) && portNum > 0 && portNum <= 65535;
  const canSubmit =
    form.name.trim() !== "" &&
    form.host.trim() !== "" &&
    portValid &&
    form.ssh_user.trim() !== "" &&
    (form.auth_method === "key" ? form.private_key.trim() !== "" : form.password !== "");

  const submit = () => {
    if (!canSubmit) return;
    create.mutate(
      {
        name: form.name.trim(),
        host: form.host.trim(),
        port: portNum,
        ssh_user: form.ssh_user.trim(),
        auth_method: form.auth_method,
        private_key: form.auth_method === "key" ? form.private_key : undefined,
        password: form.auth_method === "password" ? form.password : undefined,
        key_pass: form.auth_method === "key" && form.key_pass ? form.key_pass : undefined,
        tags: form.tags.trim() || undefined,
      },
      {
        onSuccess: () => {
          setForm(initial);
          onClose();
        },
        onError: (err) => onError(err instanceof Error ? err.message : "添加失败"),
      },
    );
  };

  return (
    <Dialog
      open={open}
      title="添加服务器"
      description="填入 SSH 连接信息即可纳管；凭据加密存储，不回显。"
      onClose={onClose}
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={create.isPending}>
            取消
          </Button>
          <Button variant="primary" onClick={submit} loading={create.isPending} disabled={!canSubmit}>
            添加
          </Button>
        </>
      }
    >
      <form
        className="space-y-3.5"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <div className="grid grid-cols-1 gap-3.5 sm:grid-cols-2">
          <Field label="名称" htmlFor="srv-name">
            <Input
              id="srv-name"
              value={form.name}
              onChange={(e) => set("name", e.target.value)}
              placeholder="vps-hk-1"
            />
          </Field>
          <Field label="主机（IP 或域名）" htmlFor="srv-host">
            <Input
              id="srv-host"
              value={form.host}
              onChange={(e) => set("host", e.target.value)}
              placeholder="10.0.0.10"
              autoCapitalize="none"
              spellCheck={false}
            />
          </Field>
          <Field label="端口" htmlFor="srv-port" error={form.port && !portValid ? "端口需为 1–65535" : null}>
            <Input
              id="srv-port"
              value={form.port}
              onChange={(e) => set("port", e.target.value)}
              inputMode="numeric"
              placeholder="22"
            />
          </Field>
          <Field label="SSH 用户" htmlFor="srv-user" hint="建议 root 或具备 docker 权限的账号">
            <Input
              id="srv-user"
              value={form.ssh_user}
              onChange={(e) => set("ssh_user", e.target.value)}
              placeholder="root"
              autoCapitalize="none"
              spellCheck={false}
            />
          </Field>
        </div>

        <Field label="认证方式" htmlFor="srv-auth">
          <Select
            id="srv-auth"
            value={form.auth_method}
            onChange={(e) => set("auth_method", e.target.value as "key" | "password")}
          >
            <option value="key">SSH 私钥</option>
            <option value="password">密码</option>
          </Select>
        </Field>

        {form.auth_method === "key" ? (
          <>
            <Field
              label="私钥（OpenSSH 格式）"
              htmlFor="srv-key"
              hint="仅上传到你的控制面并加密存储，绝不入库明文"
            >
              <Textarea
                id="srv-key"
                value={form.private_key}
                onChange={(e) => set("private_key", e.target.value)}
                placeholder="粘贴 id_ed25519 私钥全文"
                spellCheck={false}
                className="min-h-28"
              />
            </Field>
            <Field label="私钥口令（可选）" htmlFor="srv-keypass">
              <Input
                id="srv-keypass"
                type="password"
                value={form.key_pass}
                onChange={(e) => set("key_pass", e.target.value)}
                placeholder="私钥未加密则留空"
              />
            </Field>
          </>
        ) : (
          <Field label="登录密码" htmlFor="srv-pass">
            <Input
              id="srv-pass"
              type="password"
              value={form.password}
              onChange={(e) => set("password", e.target.value)}
              placeholder="SSH 登录密码"
            />
          </Field>
        )}

        <Field label="标签（可选）" htmlFor="srv-tags" hint="用于分组，如 生产 / 测试">
          <Input
            id="srv-tags"
            value={form.tags}
            onChange={(e) => set("tags", e.target.value)}
            placeholder="生产"
          />
        </Field>
      </form>
    </Dialog>
  );
}
