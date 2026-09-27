#!/usr/bin/env python3
"""长程一致性压测 — 短用例测不出的问题都在这里暴露。

普通用例每轮都是"干净开局"，测不出真实使用中的三类退化：
  1. 人设漂移（聊久了变成通用 AI / 串到别的角色）
  2. 复读（句式用尽后开始自我复制）
  3. 记忆失效（说过的承诺、记过的档案，后面提都不提）

本脚本模拟一个用户连续 5 天、12 轮真实使用，自动统计上述指标。

用法：
  python longrun.py                       # mock 模式
  DEEPSEEK_API_KEY=sk-xxx python longrun.py --real
"""
import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from testbench import ROLES, MOODS, compose_system_prompt, call_llm, extract_json  # noqa: E402


# ------------------------------------------------------------------ 指标

def bigrams(text):
    return {text[i:i + 2] for i in range(len(text) - 1)}


def similarity(a, b):
    """2-gram Jaccard：衡量两句话有多像（用于复读检测）"""
    ga, gb = bigrams(a), bigrams(b)
    if not ga or not gb:
        return 0.0
    return len(ga & gb) / len(ga | gb)


# 人设漂移检测：伴侣模式不该出现的"别的角色味"词汇
DRIFT_WORDS = {
    "partner": ["妈", "爸", "绩效", "KPI", "下属", "员工", "领导"],
    "parent": ["绩效", "KPI", "下属", "老板"],
    "boss": ["妈", "爸", "宝贝", "亲爱的"],
}


# ------------------------------------------------------------------ 剧情

# (天数, 距今小时, 角色, 情绪, 协议, 用户说的话, 剧情备注)
SCRIPT = [
    (1, 0, "partner", "impatient", "judge", "今天社团迎新忙了一天，作业明天补行不行", "首次拖延"),
    (1, 0.3, "partner", "impatient", "judge", "真的不行，你别念了行不行", "抵触"),
    (2, 24, "partner", "impatient", "judge", "我昨天一直在忙社团的事，真的没时间", "逾期一天"),
    (2, 24.5, "partner", "impatient", "judge", "再给我半小时，我马上去写", "给出承诺"),
    (2, 25.2, "partner", "impatient", "judge", "我又刷了一会儿手机…还没开始", "承诺失信"),
    (3, 48, "partner", "gentle", "judge", "我今天生理期，肚子特别疼，真的写不了", "真实情况"),
    (3, 48.5, "partner", "gentle", "judge", "嗯…我肠胃一直不太好的，老毛病了", "档案确认"),
    (3, 72, "partner", "gentle", "judge", "今天肚子又疼了", "应记得档案"),
    (4, 97, "partner", "gentle", "judge", "失眠了，一点多还没睡，作业还是空白", "深夜场景"),
    (5, 120, "partner", "gentle", "celebrate", "（作业终于写完了）", "完成庆祝"),
]

TASK_TITLE = "写完英语作业第三章"
DEADLINE_ISO = "2026-09-27T22:00:00+08:00"


def build_user_content(turn, state, user_text, now_iso, overdue_desc):
    """按当前累积状态拼装判定输入（与 App 端注入顺序保持一致）"""
    parts = []
    if state["facts"]:
        parts.append("[用户已知情况：%s]\n" % "；".join(state["facts"]))
    if state["period"]:
        parts.append("[生理期情况：%s]\n" % state["period"])
    if state["tone_notes"]:
        parts.append("[语气反馈（此前记录，持续生效）：\n%s]\n" % "\n".join("- " + n for n in state["tone_notes"][-3:]))
    if state["promises"]:
        parts.append("[承诺记录：\n%s]\n" % "\n".join("- " + p for p in state["promises"]))
    if state["digests"]:
        parts.append("[任务事实摘要（跨角色共享的任务进展）：\n%s]\n" % "\n".join("- " + d for d in state["digests"][-8:]))
    if state["history"]:
        parts.append("[此前对话]\n%s\n" % "\n".join(state["history"][-10:]))
    parts.append("[历史借口记录：%s]\n" % ("、".join(state["excuses"]) or "无"))
    parts.append("[任务：%s %s，截止 %s]\n" % (TASK_TITLE, overdue_desc, DEADLINE_ISO))
    parts.append("当前时间：%s\n" % now_iso)
    if state["night"]:
        parts.append("[当前时段：现在是凌晨 %s，深夜]\n" % state["night"])
    parts.append("用户说：%s" % user_text)
    return "".join(parts)


def run(args):
    print("快干活 · 长程一致性压测 · 模式：%s\n" % ("MOCK" if args.mock else "真实 API"))
    state = {
        "facts": [], "period": None, "tone_notes": [], "promises": [],
        "digests": [], "history": [], "excuses": [], "night": None,
    }
    replies = []
    stats = {"repeat": 0, "drift": 0, "empty": 0, "verdicts": {"reasonable": 0, "excuse": 0}}
    base = datetime.now(timezone(timedelta(hours=8)))

    for idx, (day, hours, role, mood, proto, user_text, note) in enumerate(SCRIPT, 1):
        now = base + timedelta(hours=hours)
        state["night"] = now.strftime("%H:%M") if now.hour < 7 else None
        overdue_min = max(0, int((now - datetime.fromisoformat(DEADLINE_ISO)).total_seconds() // 60))
        if overdue_min < 60:
            overdue_desc = "刚逾期%d分钟" % overdue_min
        elif overdue_min < 1440:
            overdue_desc = "已逾期%d小时" % (overdue_min // 60)
        else:
            overdue_desc = "已逾期%d天%d小时" % (overdue_min // 1440, overdue_min % 1440 // 60)

        user = build_user_content(idx, state, user_text, now.isoformat(), overdue_desc)
        system = compose_system_prompt(role, mood, proto, user_gender="female", persona_gender="male")

        if proto == "celebrate":
            out = call_llm(compose_system_prompt(role, mood, "celebrate", "female", "male"),
                           "[任务：%s]\n按时完成：是\n用户说：%s" % (TASK_TITLE, user_text), args)
            v = extract_json(out)
            reply = v.get("reply", "")
            print("第%d天 · %s\n   监工：%s\n" % (day, note, reply))
            replies.append(reply)
            state["history"].append("监工：" + reply)
            continue

        out = call_llm(system, user, args)
        v = extract_json(out)
        if "reply" not in v:
            out = call_llm(system, user, args)
            v = extract_json(out)
        reply = v.get("reply", "")
        verdict = v.get("verdict", "?")
        if verdict in stats["verdicts"]:
            stats["verdicts"][verdict] += 1
        if not reply:
            stats["empty"] += 1

        # 复读检测
        if replies:
            sim = similarity(replies[-1], reply)
            if sim > 0.55:
                stats["repeat"] += 1
                print("   ⚠️ 复读嫌疑（与上一条相似度 %.2f）" % sim)
        # 人设漂移检测
        drift_hits = [w for w in DRIFT_WORDS.get(role, []) if w in reply]
        if drift_hits:
            stats["drift"] += 1
            print("   ⚠️ 人设漂移嫌疑：出现别的角色用词 %s" % drift_hits)

        print("第%d天 · %s\n   用户：%s\n   判定：%s（指数%s）宽限%s分钟\n   监工：%s\n"
              % (day, note, user_text, verdict, v.get("bullshit_index"), v.get("grace_minutes"), reply))

        replies.append(reply)
        state["history"].append("用户：" + user_text)
        state["history"].append("监工：" + reply)
        state["excuses"].append(user_text)
        if v.get("tone_note") and v["tone_note"] != "null":
            state["tone_notes"].append(v["tone_note"])
        if v.get("fact_digest") and v["fact_digest"] != "null":
            state["digests"].append(v["fact_digest"])
        if v.get("promise_claim") and v["promise_claim"] != "null":
            state["promises"].append("待兑现承诺：'%s'" % v["promise_claim"])
        if v.get("fact_candidate") and v["fact_candidate"] != "null":
            state["facts"].append(v["fact_candidate"])
        if "生理期" in user_text or "肚子" in user_text:
            state["period"] = "上次开始日期 3 天前，预测窗口内"

    print("=" * 64)
    print("长程压测汇总：共 %d 轮" % len(replies))
    print("  复读嫌疑：%d 轮" % stats["repeat"])
    print("  人设漂移嫌疑：%d 轮" % stats["drift"])
    print("  空回复：%d 轮" % stats["empty"])
    print("  判定分布：合理 %d / 狡辩 %d" % (stats["verdicts"]["reasonable"], stats["verdicts"]["excuse"]))
    print("  平均回复长度：%.0f 字" % (sum(len(r) for r in replies) / max(1, len(replies))))
    print("=" * 64)
    return stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--real", action="store_true")
    ap.add_argument("--base-url", default="https://api.deepseek.com")
    ap.add_argument("--model", default="deepseek-chat")
    ap.add_argument("--api-key", default=os.environ.get("DEEPSEEK_API_KEY", ""))
    args = ap.parse_args()
    if args.real and not args.api_key:
        sys.exit("真实模式需要 DEEPSEEK_API_KEY")
    args.mock = not args.real
    run(args)


if __name__ == "__main__":
    main()
