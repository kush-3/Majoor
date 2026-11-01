#!/usr/bin/env python3
"""
Majoor 2.0 Phase 2 step 2c — choose the tier L model.

Runs the three things tier L does (urgency triage of a message, JSON
extraction from an email, a one-paragraph summary) against every model you
name, through the same OpenAI-compatible endpoint the app uses, and scores
them. Twenty cases, deterministic rubric, no API keys needed for a local
server. Standard library only.

Run (with Ollama or LM Studio serving on this machine):
    python3 Scripts/local-model-eval.py qwen3:8b gemma3:12b
    python3 Scripts/local-model-eval.py --base-url http://127.0.0.1:1234/v1 some-model
    python3 Scripts/local-model-eval.py --repeat 3 --verbose qwen3:8b      # see every answer
    python3 Scripts/local-model-eval.py --json qwen3:8b > eval.json        # machine-readable

Flags: --base-url (default http://127.0.0.1:11434/v1), --api-key, --timeout,
--repeat N (run every case N times; the mean counts), --cases urgency,extract,
summary (subset), --no-json-mode (for servers that reject response_format),
--verbose, --json.

Scoring, per case 0..1:
  urgency  exact label match on {"urgency": 0..3}; an adjacent label scores 0.5
           where the case marks it acceptable. Invalid JSON scores 0.
  extract  valid JSON object with every required key, each compared exactly
           after normalization (strings lower-cased and stripped, nulls equal,
           numbers within 1 percent); partial credit per key.
  summary  one paragraph (no bullets, no newlines inside), 25-80 words, that
           mentions every must-have term; 0.6 for form, 0.4 for terms.

The winner is the highest total; ties go to the lower median latency. Record
the pick in docs/MAJOOR-2.0-PRD.md (D2 / open question 2 in PHASE-2-PLAN).
"""

import argparse
import json
import re
import statistics
import sys
import time
import urllib.error
import urllib.request

TODAY = "2026-11-03 (a Tuesday)"

URGENCY_SYSTEM = (
    "You triage messages for a busy person. Rate how urgently they must see "
    "this message: 0 = ignore or newsletter, 1 = can wait for the daily brief, "
    "2 = today, 3 = interrupt them now. Answer with exactly one JSON object: "
    '{"urgency": <0|1|2|3>, "reason": "<ten words or fewer>"}. No other text.'
)

EXTRACT_SYSTEM = (
    f"Today is {TODAY}. Extract the requested fields from the email as one JSON "
    "object with exactly the keys named in the instruction. Use null when a "
    "field is absent. Dates are ISO 8601 (YYYY-MM-DD). Amounts are numbers "
    "without currency symbols. Answer with the JSON object only."
)

SUMMARY_SYSTEM = (
    "Summarize the text for someone who has ten seconds. Write one paragraph "
    "of 25 to 80 words, plain prose, no bullet points, no headings, no preamble."
)

CASES = [
    # --- urgency (8) -------------------------------------------------------
    {"kind": "urgency", "id": "u1", "expect": 3, "input":
     "From: Priya (CTO)\nSubject: prod is down\n\nPayments API returning 500s for all customers since 14:02. Need you on the bridge call now."},
    {"kind": "urgency", "id": "u2", "expect": 0, "input":
     "From: Weekly Digest <noreply@substack.com>\nSubject: 5 productivity tips you missed this week\n\nUnsubscribe at any time."},
    {"kind": "urgency", "id": "u3", "expect": 2, "accept": [1], "input":
     "From: Alice (landlord)\nSubject: Lease renewal\n\nThe renewal form is due by end of day today or the unit goes back on the market. Can you sign the attached?"},
    {"kind": "urgency", "id": "u4", "expect": 1, "accept": [0], "input":
     "From: Bob\nSubject: Lunch next week?\n\nNo rush at all — want to grab lunch sometime next week? Any day works for me."},
    {"kind": "urgency", "id": "u5", "expect": 3, "accept": [2], "input":
     "iMessage from Mom: Dad fell and we're at the ER. Call me when you see this."},
    {"kind": "urgency", "id": "u6", "expect": 0, "input":
     "From: LinkedIn\nSubject: You appeared in 12 searches this week\n\nSee who's looking."},
    {"kind": "urgency", "id": "u7", "expect": 2, "input":
     "Slack #eng from Sam: the release train leaves at 5pm, your PR still has a failing check — can you take a look before then?"},
    {"kind": "urgency", "id": "u8", "expect": 1, "accept": [2], "input":
     "From: Dr. Chen's office\nSubject: Appointment reminder\n\nThis is a reminder of your appointment on Friday November 7 at 9:30. Reply CONFIRM or call to reschedule."},

    # --- extraction (6) ----------------------------------------------------
    {"kind": "extract", "id": "e1",
     "instruction": "Keys: sender_name, request, deadline (ISO date or null), amount (number or null).",
     "input": "Hi,\n\nThis is Dana from Northwind Accounting. Could you send the signed W-9 by Friday the 7th? We also need the $1,250.00 retainer settled before we file.\n\nThanks,\nDana",
     "expect": {"sender_name": "dana", "deadline": "2026-11-07", "amount": 1250.0},
     "required": ["sender_name", "request", "deadline", "amount"]},
    {"kind": "extract", "id": "e2",
     "instruction": "Keys: event_title, event_date (ISO date or null), start_time (HH:MM 24h or null), location (string or null).",
     "input": "Reminder: the Q4 planning offsite is next Thursday, November 13, 9am sharp at the Blue Bottle on Market St. Bring the roadmap doc.",
     "expect": {"event_date": "2026-11-13", "start_time": "09:00", "location": "blue bottle on market st"},
     "required": ["event_title", "event_date", "start_time", "location"]},
    {"kind": "extract", "id": "e3",
     "instruction": "Keys: order_id (string or null), total (number or null), delivery_date (ISO date or null), carrier (string or null).",
     "input": "Your order #A7K-2291 has shipped! Total charged: $84.19. UPS expects delivery on Nov 5, 2026. Track your package anytime.",
     "expect": {"order_id": "a7k-2291", "total": 84.19, "delivery_date": "2026-11-05", "carrier": "ups"},
     "required": ["order_id", "total", "delivery_date", "carrier"]},
    {"kind": "extract", "id": "e4",
     "instruction": "Keys: sender_name, request, deadline (ISO date or null), amount (number or null).",
     "input": "hey it's Marcus — no deadline on this, but whenever you get a sec could you review the deck I shared? no money involved, just want your eyes on it",
     "expect": {"sender_name": "marcus", "deadline": None, "amount": None},
     "required": ["sender_name", "request", "deadline", "amount"]},
    {"kind": "extract", "id": "e5",
     "instruction": "Keys: flight_number (string or null), departure_date (ISO date or null), departure_time (HH:MM 24h or null), origin (3-letter airport code or null), destination (3-letter airport code or null).",
     "input": "Confirmed: UA 1482 departs SFO Tuesday Nov 11 at 6:45 AM, arriving ATL 2:33 PM. Confirmation code QX7P2M.",
     "expect": {"flight_number": "ua 1482", "departure_date": "2026-11-11", "departure_time": "06:45", "origin": "sfo", "destination": "atl"},
     "required": ["flight_number", "departure_date", "departure_time", "origin", "destination"]},
    {"kind": "extract", "id": "e6",
     "instruction": "Keys: invoice_number (string or null), vendor (string or null), amount_due (number or null), due_date (ISO date or null), is_overdue (boolean).",
     "input": "SECOND NOTICE — Invoice INV-0092 from Lumen Studio for $3,400 was due October 20, 2026 and remains unpaid. Please remit immediately.",
     "expect": {"invoice_number": "inv-0092", "vendor": "lumen studio", "amount_due": 3400.0, "due_date": "2026-10-20", "is_overdue": True},
     "required": ["invoice_number", "vendor", "amount_due", "due_date", "is_overdue"]},

    # --- summary (6) -------------------------------------------------------
    {"kind": "summary", "id": "s1", "must": ["migration", "friday", "rollback"],
     "input": "Team, the database migration to the new cluster is scheduled for Friday night starting at 11pm Pacific. Expect about 40 minutes of read-only mode. We have a tested rollback that restores the old primary within 10 minutes if replication lag exceeds 30 seconds. Jordan is on call; please keep Slack open until the all-clear. No deploys Friday after 3pm."},
    {"kind": "summary", "id": "s2", "must": ["rent", "january", "3%"],
     "input": "Dear tenant, this letter serves as notice that effective January 1, 2027 the monthly rent for your unit will increase by 3%, from $2,400 to $2,472, in line with the regional index. All other terms of your lease remain unchanged. Please acknowledge receipt by replying to this email or signing the enclosed form within 30 days."},
    {"kind": "summary", "id": "s3", "must": ["sarah", "offer", "tuesday"],
     "input": "Hi! Quick recap of today's call with Sarah from Helix: they liked the demo, especially the offline mode, and want to move to a paid pilot with 25 seats. She'll send a formal offer by Tuesday; their legal needs our DPA and SOC 2 letter first. Open question from her side: can we support SSO via Okta before January? I said we'd confirm by end of week."},
    {"kind": "summary", "id": "s4", "must": ["battery", "recall", "refund"],
     "input": "Product safety notice: certain units of the AeroHeat portable heater sold between March and August 2026 may contain a battery pack that can overheat during charging. We have received 14 reports, no injuries. Stop using the device and visit our recall page to register for a free replacement or a full refund. Serial numbers beginning with AH26-03 through AH26-08 are affected."},
    {"kind": "summary", "id": "s5", "must": ["python", "deprecat", "december"],
     "input": "Engineering announcement: Python 3.10 support in our internal SDK is deprecated as of today and will be removed in the December release. Services still on 3.10 (currently billing-worker and the two legacy report jobs) must upgrade to 3.12 or pin SDK 4.x. The platform team will open PRs for the upgrade next week; owners only need to review and merge. Questions in #platform."},
    {"kind": "summary", "id": "s6", "must": ["flight", "delay", "hotel"],
     "input": "Travel update: your flight UA 1482 on Nov 11 has been delayed four hours due to crew availability, with a new departure of 10:45 AM. This means you'll miss the 1 PM customer meeting in Atlanta; the customer has offered to move it to 4 PM. The hotel has been notified of a late check-in and will hold the room. Reply to accept the new meeting time or to request rebooking on the 7:10 AM Delta flight."},
]


# --- transport ----------------------------------------------------------------

def chat(base_url, api_key, model, system, user, json_mode, timeout):
    body = {
        "model": model,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "max_tokens": 400,
        "temperature": 0,
    }
    if json_mode:
        body["response_format"] = {"type": "json_object"}
    data = json.dumps(body).encode()
    req = urllib.request.Request(base_url.rstrip("/") + "/chat/completions", data=data, method="POST",
                                 headers={"Content-Type": "application/json"})
    if api_key:
        req.add_header("Authorization", f"Bearer {api_key}")
    started = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.load(resp)
    latency = time.monotonic() - started
    content = payload["choices"][0]["message"].get("content") or ""
    content = re.sub(r"^\s*<think>.*?</think>\s*", "", content, flags=re.S)
    return content.strip(), latency


def list_models(base_url, api_key, timeout):
    req = urllib.request.Request(base_url.rstrip("/") + "/models")
    if api_key:
        req.add_header("Authorization", f"Bearer {api_key}")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return sorted(m["id"] for m in json.load(resp).get("data", []))


# --- scoring ------------------------------------------------------------------

def parse_json_object(text):
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        value = json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def normalize(value):
    if isinstance(value, str):
        return re.sub(r"\s+", " ", value.strip().lower().replace("#", ""))
    return value


def values_match(expected, got):
    if expected is None or got is None:
        return expected is None and got is None
    if isinstance(expected, bool) or isinstance(got, bool):
        return expected == got
    if isinstance(expected, (int, float)):
        try:
            got_number = float(str(got).replace(",", "").replace("$", ""))
        except ValueError:
            return False
        return abs(got_number - float(expected)) <= max(0.01, abs(float(expected)) * 0.01)
    expected, got = normalize(expected), normalize(str(got))
    return expected == got or expected in got or got in expected


def score(case, answer):
    kind = case["kind"]
    if kind == "urgency":
        obj = parse_json_object(answer)
        if obj is None or "urgency" not in obj:
            return 0.0, "invalid JSON"
        try:
            got = int(obj["urgency"])
        except (TypeError, ValueError):
            return 0.0, f"non-integer urgency {obj['urgency']!r}"
        if got == case["expect"]:
            return 1.0, f"{got} ok"
        if got in case.get("accept", []):
            return 0.5, f"{got} (acceptable, wanted {case['expect']})"
        return 0.0, f"{got} (wanted {case['expect']})"

    if kind == "extract":
        obj = parse_json_object(answer)
        if obj is None:
            return 0.0, "invalid JSON"
        required = case["required"]
        points, notes = 0.0, []
        for key in required:
            if key not in obj:
                notes.append(f"{key}: missing")
                continue
            if key in case["expect"]:
                if values_match(case["expect"][key], obj[key]):
                    points += 1
                else:
                    notes.append(f"{key}: {obj[key]!r} (wanted {case['expect'][key]!r})")
            else:
                points += 1 if obj[key] not in (None, "") else 0.5   # free-text key: present and non-empty
        return points / len(required), "; ".join(notes) or "all keys ok"

    if kind == "summary":
        text = answer.strip()
        words = len(text.split())
        form = 1.0
        notes = []
        if "\n" in text:
            form -= 0.5; notes.append("multiple paragraphs or lines")
        if re.search(r"^\s*([-*•]|\d+\.)\s", text, flags=re.M):
            form -= 0.5; notes.append("bullets")
        if not 25 <= words <= 80:
            form -= 0.5; notes.append(f"{words} words")
        form = max(form, 0.0)
        lower = text.lower()
        hits = sum(1 for term in case["must"] if term.lower() in lower)
        missing = [t for t in case["must"] if t.lower() not in lower]
        if missing:
            notes.append("missing " + ", ".join(missing))
        return 0.6 * form + 0.4 * hits / len(case["must"]), "; ".join(notes) or "ok"

    raise ValueError(kind)


def prompt_for(case):
    if case["kind"] == "urgency":
        return URGENCY_SYSTEM, case["input"]
    if case["kind"] == "extract":
        return EXTRACT_SYSTEM, f"{case['instruction']}\n\nEmail:\n{case['input']}"
    return SUMMARY_SYSTEM, case["input"]


# --- main ---------------------------------------------------------------------

def run_model(model, cases, args, verbose):
    results = []
    for case in cases:
        system, user = prompt_for(case)
        json_mode = args.json_mode and case["kind"] != "summary"
        scores, latencies, last_note, last_answer = [], [], "", ""
        for _ in range(args.repeat):
            try:
                answer, latency = chat(args.base_url, args.api_key, model, system, user, json_mode, args.timeout)
                value, note = score(case, answer)
            except urllib.error.HTTPError as e:
                body = e.read().decode(errors="replace")[:200]
                answer, latency, value, note = "", 0.0, 0.0, f"HTTP {e.code}: {body}"
            except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
                answer, latency, value, note = "", 0.0, 0.0, f"error: {e}"
            scores.append(value)
            latencies.append(latency)
            last_note, last_answer = note, answer
        mean = statistics.mean(scores)
        results.append({"id": case["id"], "kind": case["kind"], "score": mean,
                        "latency": statistics.median(latencies), "note": last_note, "answer": last_answer})
        if verbose:
            print(f"  {case['id']:<3} {mean:4.2f}  {results[-1]['latency']:5.1f}s  {last_note}")
            print("      " + last_answer.replace("\n", "\n      ")[:600])
    return results


def summarize(model, results):
    by_kind = {}
    for r in results:
        by_kind.setdefault(r["kind"], []).append(r["score"])
    total = statistics.mean(r["score"] for r in results) if results else 0.0
    valid_json = [r for r in results if r["kind"] != "summary"]
    json_ok = sum(1 for r in valid_json if "invalid JSON" not in r["note"] and not r["note"].startswith(("HTTP", "error")))
    return {
        "model": model,
        "total": total,
        "urgency": statistics.mean(by_kind.get("urgency", [0.0])),
        "extract": statistics.mean(by_kind.get("extract", [0.0])),
        "summary": statistics.mean(by_kind.get("summary", [0.0])),
        "json_valid_pct": 100.0 * json_ok / len(valid_json) if valid_json else 0.0,
        "median_latency": statistics.median(r["latency"] for r in results) if results else 0.0,
        "cases": results,
    }


def main():
    parser = argparse.ArgumentParser(description="Score tier L candidates on Majoor's own jobs.")
    parser.add_argument("models", nargs="+", help="model names as the server knows them (see /v1/models)")
    parser.add_argument("--base-url", default="http://127.0.0.1:11434/v1")
    parser.add_argument("--api-key", default="")
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--cases", default="urgency,extract,summary", help="comma-separated subset of kinds")
    parser.add_argument("--no-json-mode", dest="json_mode", action="store_false", help="do not send response_format")
    parser.add_argument("--verbose", action="store_true", help="print every answer")
    parser.add_argument("--json", dest="as_json", action="store_true", help="print one JSON document instead of the table")
    args = parser.parse_args()

    kinds = {k.strip() for k in args.cases.split(",") if k.strip()}
    cases = [c for c in CASES if c["kind"] in kinds]
    if not cases:
        sys.exit("no cases selected")

    try:
        available = list_models(args.base_url, args.api_key, args.timeout)
    except Exception as e:  # noqa: BLE001 — any failure here means the server is unreachable
        sys.exit(f"cannot list models at {args.base_url}: {e}\nIs the server running? For Ollama: `ollama serve`.")
    missing = [m for m in args.models if m not in available]
    if missing and not args.as_json:
        print(f"note: not in {args.base_url}/models: {', '.join(missing)} (available: {', '.join(available) or 'none'})", file=sys.stderr)

    reports = []
    for model in args.models:
        if not args.as_json:
            print(f"\n== {model} ({len(cases)} cases × {args.repeat}) ==")
        reports.append(summarize(model, run_model(model, cases, args, args.verbose and not args.as_json)))

    if args.as_json:
        json.dump({"base_url": args.base_url, "today": TODAY, "reports": reports}, sys.stdout, indent=2)
        print()
        return

    reports.sort(key=lambda r: (-r["total"], r["median_latency"]))
    print()
    print(f"{'model':<34} {'total':>6} {'urgency':>8} {'extract':>8} {'summary':>8} {'json ok':>8} {'latency':>8}")
    for r in reports:
        print(f"{r['model']:<34} {r['total']:6.2f} {r['urgency']:8.2f} {r['extract']:8.2f} {r['summary']:8.2f} "
              f"{r['json_valid_pct']:7.0f}% {r['median_latency']:7.1f}s")
    best = reports[0]
    print(f"\nPick: {best['model']} (total {best['total']:.2f}). Record it in the PRD (D2) and set it in Settings ▸ Models.")
    weak = [r for r in reports if r["json_valid_pct"] < 90]
    if weak:
        print("Warning: JSON validity under 90% for " + ", ".join(r["model"] for r in weak)
              + " — the job runner retries once on bad JSON, so this costs latency and reliability.")


if __name__ == "__main__":
    main()
