#!/usr/bin/env python3
"""快干活 · 本地部署联调用 Mock 服务（OpenAI 兼容 / 与 Ollama /v1 同构）

作用：在没有 Mac、没有真实 Ollama、没有 API 额度的情况下，也能验证「本地部署」这条链路——
  · 请求路径   /v1/chat/completions
  · 请求体字段 model / messages / temperature / max_tokens（Swift AIClient 就是这么发的）
  · 响应体结构 choices[].message.content（Swift AIClient 就是这么解析的）

它模拟一台跑在局域网里的本地大模型服务器，返回的 JSON 结构、关键字段与 Ollama 的
OpenAI 兼容接口完全一致。Swift 端 AppState.makeClient 在「本地部署」开关打开时，只会把
baseURL 换成 http://<电脑IP>:11434/v1，其余请求/解析逻辑与云端完全一致，因此本 Mock 通过
即代表真机指向真实 Ollama 也能用。

用法：
  cd kuaiganhuo/testbench
  python mock_ollama.py                 # 起服务，默认 http://127.0.0.1:11434/v1
  # 另开一个终端：
  python verify_local_deploy.py         # 发一条与 Swift 完全一致的请求做端到端验证
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.stdout.reconfigure(encoding="utf-8")

HOST, PORT = "127.0.0.1", 11434


def choose_reply(system: str, user: str) -> str:
    """根据 system 提示词判断当前协议，返回符合快干活 JSON 协议的回复。
    逻辑与 testbench.py 的 mock_llm 对齐，但走的是 HTTP/JSON 线协议（不是函数调用）。"""
    if "解析为 JSON" in system or "解析" in system:
        return json.dumps(
            {"tasks": [{"title": "高数作业第三章", "deadline": None,
                        "estimate_minutes": 60, "strictness": "normal"}],
             "clarification": None},
            ensure_ascii=False,
        )
    if "催促通知文案" in system:
        return json.dumps(
            {"nudges": [{"at_deadline": "该干活了。"},
                        {"at_deadline": "进度呢？别发呆。"},
                        {"grace_over": "宽限结束了，别糊弄。"}]},
            ensure_ascii=False,
        )
    if "习惯养成生成" in system or "习惯养成" in system:
        return json.dumps(
            {"anchor": "睡前啦，先背两个单词也算数。",
             "evening": "还没背呢？五分钟也算今天没断。"},
            ensure_ascii=False,
        )
    if "完成了任务" in system:
        return json.dumps({"reply": "干得漂亮，这一份质量我很满意。"}, ensure_ascii=False)
    if "判定" in system:
        reasonable = any(k in user for k in
                        ["查寝", "老师", "停电", "断网", "家里", "生理期", "肠胃", "突然"])
        verdict = "reasonable" if reasonable else "excuse"
        return json.dumps({
            "verdict": verdict,
            "bullshit_index": 15 if reasonable else 72,
            "reply": ("好，宽限你30分钟，到点我还会来查。" if reasonable
                      else "少来这套，现在就动笔，别磨蹭。"),
            "grace_minutes": 30 if reasonable else 0,
            "escalate": (not reasonable),
            "next_check_minutes": 35 if reasonable else 10,
            "excuse_type": "外部事件" if reasonable else "纯拖延",
        }, ensure_ascii=False)
    return json.dumps({"reply": "（mock 本地模型：未知协议）"}, ensure_ascii=False)


class Handler(BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # 安静一点
        pass

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path in ("/v1/models", "/models"):
            self._send({"object": "list", "data": [
                {"id": "qwen2.5:3b-instruct", "object": "model", "owned_by": "local"}]})
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/")
        if not path.endswith("/chat/completions"):
            self._send({"error": "only /v1/chat/completions supported"}, 404)
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(n) if n else b"{}"
            req = json.loads(raw or b"{}")
        except Exception as e:
            self._send({"error": "bad request: %s" % e}, 400)
            return

        # 这里只是确认 Swift 端发来的字段是 OpenAI 兼容格式（不强制使用）
        _model = req.get("model")
        _max_tokens = req.get("max_tokens")
        messages = req.get("messages", [])
        system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
        user = next((m.get("content", "") for m in messages if m.get("role") == "user"), "")

        reply = choose_reply(system, user)
        # 与 Ollama 的 OpenAI 兼容响应结构完全一致
        self._send({
            "id": "chatcmpl-mock-local",
            "object": "chat.completion",
            "model": _model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": reply},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        })


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"快干活 · 本地部署 Mock 服务已启动 → http://{HOST}:{PORT}/v1")
    print("Swift 端把「本地部署」地址填 http://127.0.0.1:11434/v1 即可连到本服务。Ctrl+C 退出。")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")


if __name__ == "__main__":
    main()
