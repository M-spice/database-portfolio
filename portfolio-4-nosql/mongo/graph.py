"""A referral network between clinicians, traversed with $graphLookup and checked against a breadth-first search."""

import hashlib
from collections import defaultdict, deque
from datetime import datetime, timedelta, timezone

from pymongo import ASCENDING
from tabulate import tabulate

from common import check, log, mongo, section, summary

LAGOS = timezone(timedelta(hours=1))
HUB = {"Lagos": "LAG-IKJ", "Abuja": "ABJ-GRK", "Ibadan": "IBD-BOD", "Enugu": "ENU-IND", "Kano": "KAN-NAS"}
CITY = {"LAG": "Lagos", "ABJ": "Abuja", "IBD": "Ibadan", "ENU": "Enugu", "KAN": "Kano"}


def unit(*parts):
    digest = hashlib.sha256("|".join(map(str, parts)).encode()).digest()
    return int.from_bytes(digest[:8], "big") / 2 ** 64


def pick(options, *parts):
    return options[int(unit(*parts) * len(options))]


def build_referrals(db):
    clinicians = list(db.clinicians.find({}, {"staff_no": 1, "facility": 1, "departments": 1}).sort("staff_no", 1))
    by_role = defaultdict(list)
    for c in clinicians:
        for dept in c["departments"]:
            by_role[(c["facility"], dept)].append(c)
            by_role[(CITY[c["facility"][:3]], dept)].append(c)
            by_role[("any", dept)].append(c)
    patients = defaultdict(list)
    for p in db.patients.find({}, {"registered.facility": 1}).sort("_id", 1):
        patients[p["registered"]["facility"]].append(p["_id"])

    edges, n = [], 0

    def refer(source, targets, count, salt):
        nonlocal n
        for i in range(count):
            target = pick(targets, salt, source["staff_no"], i)
            if target["staff_no"] == source["staff_no"]:
                continue
            n += 1
            edges.append({
                "_id": n, "from": source["staff_no"], "to": target["staff_no"],
                "from_facility": source["facility"], "to_facility": target["facility"],
                "specialty": next(d for d in target["departments"] if d != "GP") if set(target["departments"]) - {"GP"} else "GP",
                "patient_id": pick(patients[source["facility"]], "patient", salt, source["staff_no"], i),
                "referred_at": datetime(2025, 1, 6, 9, tzinfo=LAGOS) + timedelta(days=int(680 * unit("day", salt, source["staff_no"], i))),
            })

    for c in clinicians:
        depts, city = set(c["departments"]), CITY[c["facility"][:3]]
        hub = HUB[city]
        if depts == {"GP"}:
            specialists = by_role[(hub, "IM")] + by_role[(hub, "PAED")] + by_role[(hub, "OBGYN")]
            refer(c, specialists or by_role[("any", "IM")], 3 + int(10 * unit("gp", c["staff_no"])), "gp")
        if "IM" in depts:
            refer(c, by_role[("any", "DERM")] + by_role[("any", "OPHTH")], 1 + int(5 * unit("im", c["staff_no"])), "im")
            if c["facility"] != "LAG-IKJ":
                refer(c, by_role[("LAG-IKJ", "IM")], int(3 * unit("tertiary", c["staff_no"])), "tertiary")
        if "OBGYN" in depts:
            refer(c, by_role[(city, "PAED")] or by_role[("any", "PAED")], 1 + int(4 * unit("obs", c["staff_no"])), "obs")
    return edges


def bfs(edges, start, max_depth):
    adjacency = defaultdict(list)
    for e in edges:
        adjacency[e["from"]].append(e)
    seen, depth_of, queue = set(), {}, deque([(start, 0)])
    visited_nodes = {start}
    while queue:
        node, depth = queue.popleft()
        if depth > max_depth:
            continue
        for e in adjacency[node]:
            if e["_id"] not in seen:
                seen.add(e["_id"])
                depth_of[e["_id"]] = depth
                if e["to"] not in visited_nodes:
                    visited_nodes.add(e["to"])
                    queue.append((e["to"], depth + 1))
    return depth_of


def main():
    db = mongo().itoju

    section("1. Building the referral network from the clinicians and their departments")
    db.drop_collection("referrals")
    edges = build_referrals(db)
    db.referrals.insert_many(edges)
    db.referrals.create_index([("from", ASCENDING)], name="referrals_from_ix")
    db.referrals.create_index([("to", ASCENDING)], name="referrals_to_ix")
    log("gr", f"{len(edges)} referrals between {len({e['from'] for e in edges} | {e['to'] for e in edges})} clinicians, "
              "indexed on from (the field $graphLookup follows) and to")

    section("2. Where do one GP's referrals lead? $graphLookup with maxDepth 2")
    gp_only = {c["staff_no"] for c in db.clinicians.find({"departments": ["GP"]}, {"staff_no": 1})}
    start = max((e["from"] for e in edges if e["from"] in gp_only),
                key=lambda s: (sum(1 for e in edges if e["from"] == s), s))
    pipeline = [
        {"$match": {"staff_no": start}},
        {"$graphLookup": {"from": "referrals", "startWith": "$staff_no", "connectFromField": "to",
                          "connectToField": "from", "as": "chain", "maxDepth": 2, "depthField": "depth"}},
        {"$unwind": "$chain"},
        {"$group": {"_id": "$chain.depth", "referrals": {"$sum": 1}, "clinicians": {"$addToSet": "$chain.to"},
                    "branches": {"$addToSet": "$chain.to_facility"}}},
        {"$sort": {"_id": 1}},
    ]
    rows = list(db.clinicians.aggregate(pipeline))
    print(tabulate([[r["_id"], r["referrals"], len(r["clinicians"]), ", ".join(sorted(r["branches"]))] for r in rows],
                   headers=["depth", "referrals followed", "clinicians reached", "branches reached"]))
    expected = bfs(edges, start, 2)
    by_depth = defaultdict(int)
    for depth in expected.values():
        by_depth[depth] += 1
    got = {int(r["_id"]): r["referrals"] for r in rows}
    log("gr", f"breadth-first search in Python over the same {len(edges)} edges: {dict(sorted(by_depth.items()))}")
    check("$graphLookup reaches the same referrals at each depth as a breadth-first search", got == dict(by_depth),
          f"start {start}")

    section("3. The same traversal restricted to referrals made in 2026")
    restricted = [dict(s) for s in pipeline]
    restricted[1] = {"$graphLookup": {**pipeline[1]["$graphLookup"],
                                      "restrictSearchWithMatch": {"referred_at": {"$gte": datetime(2026, 1, 1, tzinfo=LAGOS)}}}}
    rows_2026 = list(db.clinicians.aggregate(restricted))
    print(tabulate([[r["_id"], r["referrals"], len(r["clinicians"])] for r in rows_2026],
                   headers=["depth", "referrals followed", "clinicians reached"]))
    expected_2026 = bfs([e for e in edges if e["referred_at"] >= datetime(2026, 1, 1, tzinfo=LAGOS)], start, 2)
    counts_2026 = defaultdict(int)
    for depth in expected_2026.values():
        counts_2026[depth] += 1
    check("restrictSearchWithMatch limits the traversal to 2026 referrals",
          {int(r["_id"]): r["referrals"] for r in rows_2026} == dict(counts_2026))

    section("4. Which clinicians receive the most referrals?")
    top = list(db.referrals.aggregate([
        {"$group": {"_id": "$to", "referrals": {"$sum": 1}, "from_branches": {"$addToSet": "$from_facility"}}},
        {"$sort": {"referrals": -1, "_id": 1}}, {"$limit": 5},
        {"$lookup": {"from": "clinicians", "localField": "_id", "foreignField": "staff_no", "as": "c"}},
        {"$project": {"referrals": 1, "branches": {"$size": "$from_branches"}, "name": {"$first": "$c.name"},
                      "facility": {"$first": "$c.facility"}, "departments": {"$first": "$c.departments"}}},
    ]))
    print(tabulate([[r["_id"], r["name"], r["facility"], "/".join(r["departments"]), r["referrals"], r["branches"]] for r in top],
                   headers=["clinician", "name", "branch", "departments", "referrals received", "from branches"]))
    check("in-degree ranking found the busiest receiving clinicians", len(top) == 5)
    summary()


if __name__ == "__main__":
    main()
