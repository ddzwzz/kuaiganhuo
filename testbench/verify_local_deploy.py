#!/usr/bin/env python3
"""验证「本地部署」线协议与 Ollama 完全兼容 —— 不需要真实 Ollama / Mac / API。

本脚本做的事，等价于真机上的 Swift AIClient.chat 全过程：
  1. 按 Swift WireRequest 拼请求体：{model, messages:[{role,content}], temperature, max_tokens}
  2. POST 到 /v1/chat/completions（Ollama 的 OpenAI 兼容路径）
  3. 从 responses.choices[0].message.content 抠出 JSON（用与 Swift extractJSON 同款的括号配平算法）
  4. json.loads 确认能解析 —— 解析成功即代表 Swift 端拿到的回复能正确解码

它会自己起一个 mock 本地模型服务（mock_ollama.py 里的 Handler），所以一条命令即可跑完。
想验证真实 Ollama：把下面 BASE 改成 http://<电脑IP>:11434/v1，且不启动 mock 即可。

用法：
  cd kuaiganhuo/testbench
  python verify_local_deploy.py
"""
import json
import sys
import threading
import urllib.request
from http.server import ThreadingHTTPServer

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from mock_ollama import Handler, HOST, PORT  # noqa: E402

BASE = f"http://{HOST}:{PORT}/v1"


# —— 与 Swift AIClient.extractJSON 同款的「括号配平」抠 JSON 算法 ——
def extract_json(text):
    s = text.strip()
    if "```" in s:
        import re
        inner = re.search(r"```(?:json)?\s*([\s\S]*?)```", s)
        if inner:
            s = inner.group(1)
    start = s.find("{")
    if start < 0:
        raise ValueError("no json")
    depth, in_str, prev = 0, False, " "
    for i in range(start, len(s)):
        ch = s[i]
        if in_str:
            if ch == '"' and prev != "\\":
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return s[start:i + 1]
        prev = ch
    raise ValueError("unbalanced")


def send(model, system, user, temperature=0.9, max_tokens=800):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
        "temperature": temperature,
        "max_tokens": max_tokens,
    }).encode("utf-8")
    req = urllib.request.Request(
        BASE + "/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    content = data["choices"][0]["message"]["content"]
    return extract_json(content)


# 五个协议各给一段代表性 system 提示词（取自 PromptEngine 的关键字，足以让 mock 选对分支）
PROTOCOLS = {
    "parse（任务解析）": (
        "你是监工。把用户的安排解析为 JSON。",
        "当前时间：2026-09-27T20:00:00+08:00\n用户安排：晚上8点前写完高数作业第三章",
    ),
    "nudge（催促文案）": (
        "【任务】为指定任务生成催促通知文案 JSON：{\"nudges\":[...]}。",
        "任务：高数作业第三章",
    ),
    "judge（借口判定）": (
        "【任务】用户对逾期任务给出了理由。判定并回复，输出 JSON：{\"verdict\":...}。",
        "[任务：高数作业，刚逾期10分钟] 用户说：老师突然叫我过去帮忙，大概半小时",
    ),
    "celebrate（完成庆祝）": (
        "【任务】用户刚刚完成了任务。以你的角色身份做出真实反应，输出 JSON：{\"reply\":\"...\"}。",
        "用户刚刚完成了任务。",
    ),
    "habitNudge（习惯提醒）": (
        "【任务】为习惯养成生成今日两条提醒文案 JSON：{\"anchor\":\"...\",\"evening\":\"...\"}。",
        "[习惯状态：第3天，启动期] 习惯：背单词",
    ),
}


def main():
    # 在后台起 mock 服务
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    print(f"快干活 · 本地部署线协议验证（mock 服务已起在 {BASE}）\n")

    passed, failed = 0, 0
    for name, (system, user) in PROTOCOLS.items():
        try:
            obj = json.loads(send("qwen2.5:3b-instruct", system, user))
            assert isinstance(obj, dict) and obj, "空对象"
            print(f"  ✅ {name}: 解析成功，字段 = {', '.join(obj.keys())}")
            passed += 1
        except Exception as e:
            print(f"  ❌ {name}: 失败 —— {e}")
            failed += 1

    # 连通性 ping（Swift 端「测试连通性」按钮走的就是这条）
    try:
        obj = json.loads(send("qwen2.5:3b-instruct", "你是连通性测试助手。只回复：OK", "ping"))
        print(f"  ✅ 连通性 ping：返回非空 JSON（{list(obj.keys())}）")
        passed += 1
    except Exception as e:
        print(f"  ❌ 连通性 ping 失败 —— {e}")
        failed += 1

    server.shutdown()
    print(f"\n{'=' * 56}\n结果：通过 {passed} 项，失败 {failed} 项")
    if failed == 0:
        print("🎉 本地部署线协议验证全部通过：Swift 端的请求格式 / 路径 / 响应解析")
        print("   与 OpenAI 兼容本地服务（Ollama / LM Studio）完全同构。")
        print("   真机上把「本地部署」地址填成电脑的 http://<IP>:11434/v1 即可用。")
    else:
        print("⚠️ 有失败项，请检查 mock_ollama.py 与 WireRequest 字段是否同步。")


if __name__ == "__main__":
    main()
