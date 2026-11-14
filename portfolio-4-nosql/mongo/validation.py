"""Validators rejecting bad documents (with errInfo), a unique index, and a de-identified view for a least-privilege role."""

import copy
import json
import secrets

from pymongo.errors import DuplicateKeyError, OperationFailure, WriteError

from common import check, log, mongo, section, summary


def reasons(details, found=None):
    """Collect the failing operator and reason from MongoDB's nested errInfo."""
    found = [] if found is None else found
    if isinstance(details, dict):
        if "operatorName" in details and details.get("reason"):
            found.append(f"{details['operatorName']}: {details['reason']}")
        for value in details.values():
            reasons(value, found)
    elif isinstance(details, list):
        for value in details:
            reasons(value, found)
    return found


def rejected(collection, doc, label, expect_code=121, show_full=False):
    try:
        collection.insert_one(doc)
    except WriteError as exc:
        info = exc.details.get("errInfo", {})
        log("val", f"{label}: rejected, code {exc.code}: {exc.details.get('errmsg', '')}")
        for line in dict.fromkeys(reasons(info.get("details", {}))):
            log("val", f"    {line}")
        if show_full:
            print(json.dumps(info, indent=2, default=str))
        return exc.code == expect_code
    collection.delete_one({"_id": doc["_id"]})
    log("val", f"{label}: ACCEPTED")
    return False


def main():
    client = mongo()
    db = client.itoju

    section("1. Validators: one valid document accepted, then one bad document per rule")
    encounter = db.encounters.find_one({"notes.1": {"$exists": True}})
    good = copy.deepcopy(encounter)
    good["_id"] = 900000001
    db.encounters.insert_one(good)
    accepted = db.encounters.count_documents({"_id": good["_id"]}) == 1
    db.encounters.delete_one({"_id": good["_id"]})
    log("val", f"a copy of encounter {encounter['_id']} (with an amendment) was accepted")
    check("a valid encounter document is accepted", accepted)

    bad = copy.deepcopy(encounter)
    bad["_id"] = 900000002
    bad["notes"][-1]["amends_note_no"] = 99
    check("an amendment must point at a note in the same encounter",
          rejected(db.encounters, bad, "amendment pointing at note 99", show_full=True))

    bad = copy.deepcopy(encounter)
    bad["_id"] = 900000003
    bad["diagnoses"] = [{"code": "I10", "description": "Essential hypertension", "primary": True},
                        {"code": "E11.9", "description": "Type 2 diabetes mellitus", "primary": True}]
    check("an encounter has at most one primary diagnosis", rejected(db.encounters, bad, "two primary diagnoses"))

    bad = copy.deepcopy(encounter)
    bad["_id"] = 900000004
    bad["type"] = "HOUSE_CALL"
    check("the encounter type must be a known code", rejected(db.encounters, bad, "unknown encounter type"))

    numeric = db.lab_results.find_one({"result.kind": "numeric", "test.code": "LT-HB"})
    bad = copy.deepcopy(numeric)
    bad["_id"] = 900000005
    bad["result"]["unit"] = "mmol/L"
    check("a numeric result must be in its test's unit", rejected(db.lab_results, bad, "haemoglobin in mmol/L"))

    qualitative = db.lab_results.find_one({"result.kind": "qualitative"})
    bad = copy.deepcopy(qualitative)
    bad["_id"] = 900000006
    bad["result"] = {"kind": "numeric", "value": 1.0, "unit": "g/dL", "reference": None, "flag": "normal"}
    check("a qualitative test cannot take a numeric result", rejected(db.lab_results, bad, f"numeric result for {bad['test']['code']}"))

    bad = copy.deepcopy(numeric)
    bad["_id"] = 900000007
    bad["recorded_at"] = bad["ordered_at"].replace(year=2020)
    check("a result cannot be recorded before its order", rejected(db.lab_results, bad, "result dated before its order"))

    patient = db.patients.find_one({"_id": {"$gt": 100}})
    bad = copy.deepcopy(patient)
    bad["_id"], bad["hospital_no"] = 900000008, "HN-9999998"
    bad["phones"] = [{"number": "+2348031234567", "primary": True}]
    check("phone numbers must be in the synthetic range", rejected(db.patients, bad, "a real-looking phone number"))

    bad = copy.deepcopy(patient)
    bad["_id"], bad["hospital_no"] = 900000009, "HN-9999999"
    bad["phones"] = [{"number": "+2340199999991", "primary": True}, {"number": "+2340199999992", "primary": True}]
    check("a patient has at most one primary phone", rejected(db.patients, bad, "two primary phones"))

    invoice = db.invoices.find_one()
    bad = copy.deepcopy(invoice)
    bad["_id"], bad["invoice_no"] = 900000010, "INV-99999999"
    bad["total_kobo"] += 100
    check("an invoice total must equal the sum of its lines", rejected(db.invoices, bad, "total 100 kobo above its lines"))

    item = db.stock.find_one({"quantity": {"$gt": 0}})
    try:
        db.stock.update_one({"_id": item["_id"]}, {"$inc": {"quantity": -(item["quantity"] + 1)}})
        stock_refused = False
    except WriteError as exc:
        log("val", f"taking {item['quantity'] + 1} from {item['quantity']} in stock: rejected, code {exc.code}")
        stock_refused = exc.code == 121
    check("validation also applies to updates: stock cannot go negative", stock_refused)

    section("2. Unique index: a second patient with an existing hospital number")
    dup = copy.deepcopy(patient)
    dup["_id"] = 900000011
    try:
        db.patients.insert_one(dup)
        duplicate_refused = False
    except DuplicateKeyError as exc:
        log("val", f"rejected: {exc.details.get('errmsg')}")
        duplicate_refused = True
    check("hospital numbers are unique (patients_hospital_no_uk)", duplicate_refused)

    section("3. A de-identified view and a role that can read only that view")
    for name in ("deid_encounters",):
        db.drop_collection(name)
    db.command("create", "deid_encounters", viewOn="encounters", pipeline=[
        {"$project": {"_id": 0, "patient_key": 1, "facility": 1, "type": 1,
                      "month": {"$dateToString": {"format": "%Y-%m", "date": "$started_at", "timezone": "Africa/Lagos"}},
                      "diagnosis_codes": "$diagnoses.code"}}])
    for command, name in (("dropUser", "analyst"), ("dropRole", "itoju_analyst")):
        try:
            db.command(command, name)
        except OperationFailure:
            pass
    db.command("createRole", "itoju_analyst",
               privileges=[{"resource": {"db": "itoju", "collection": "deid_encounters"}, "actions": ["find"]}], roles=[])
    password = secrets.token_urlsafe(18)
    db.command("createUser", "analyst", pwd=password, roles=[{"role": "itoju_analyst", "db": "itoju"}])
    log("val", "created role itoju_analyst (find on deid_encounters only) and user analyst")

    analyst = mongo(username="analyst", password=password, auth_source="itoju").itoju
    sample = analyst.deid_encounters.find_one()
    log("ana", f"deid_encounters: {sample}")
    check("the analyst can read the de-identified view", sample is not None)
    check("the view carries no direct identifier",
          not {"patient_id", "_id", "clinician", "notes", "vitals"} & set(sample))
    for collection in ("encounters", "patients"):
        try:
            analyst[collection].find_one()
            denied = False
        except OperationFailure as exc:
            log("ana", f"find on {collection}: {exc.details.get('codeName')} (code {exc.code})")
            denied = exc.code == 13
        check(f"the analyst cannot read {collection}", denied)
    summary()


if __name__ == "__main__":
    main()
