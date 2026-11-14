"""Collection definitions for the Itoju Clinics document model: validators, time-series options and base indexes."""

from pymongo import ASCENDING

DATE = {"bsonType": "date"}
STRING = {"bsonType": "string"}
INT = {"bsonType": ["int", "long"]}
NUMBER = {"bsonType": ["int", "long", "double", "decimal"]}
NULLABLE = lambda schema: {"bsonType": [*([schema["bsonType"]] if isinstance(schema["bsonType"], str) else schema["bsonType"]), "null"]}

PATIENTS = {
    "$jsonSchema": {
        "bsonType": "object",
        "required": ["_id", "hospital_no", "name", "date_of_birth", "address", "phones", "registered"],
        "properties": {
            "_id": INT,
            "hospital_no": {"bsonType": "string", "pattern": "^HN-[0-9]{7}$"},
            "name": {"bsonType": "object", "required": ["given", "family"],
                     "properties": {"given": STRING, "middle": NULLABLE(STRING), "family": STRING}},
            "date_of_birth": DATE,
            "national_id": {"bsonType": ["string", "null"], "pattern": "^999[0-9]{8}$"},
            "address": {"bsonType": "object", "required": ["line", "city", "state"]},
            "phones": {"bsonType": "array", "minItems": 1, "maxItems": 5,
                       "items": {"bsonType": "object", "required": ["number", "primary"],
                                 "properties": {"number": {"bsonType": "string", "pattern": "^\\+2340[0-9]{9}$"},
                                                "primary": {"bsonType": "bool"}}}},
            "allergies": {"bsonType": "array", "maxItems": 20},
            "next_of_kin": {"bsonType": "array", "maxItems": 5},
            "consents": {"bsonType": "array", "maxItems": 10},
        },
    },
    "$expr": {"$lte": [{"$size": {"$filter": {"input": "$phones", "cond": "$$this.primary"}}}, 1]},
}

ENCOUNTERS = {
    "$jsonSchema": {
        "bsonType": "object",
        "required": ["_id", "patient_id", "patient_key", "facility", "clinician", "type", "started_at", "diagnoses"],
        "properties": {
            "_id": INT,
            "patient_id": INT,
            "patient_key": STRING,
            "facility": {"bsonType": "string", "pattern": "^[A-Z]{3}-[A-Z]{3}$"},
            "clinician": {"bsonType": "object", "required": ["staff_no", "name"]},
            "type": {"enum": ["CONSULTATION", "FOLLOW_UP", "WALK_IN", "TELECONSULT"]},
            "started_at": DATE,
            "ended_at": NULLABLE(DATE),
            "vitals": {"bsonType": "array"},
            "diagnoses": {"bsonType": "array",
                          "items": {"bsonType": "object", "required": ["code", "primary"],
                                    "properties": {"code": {"bsonType": "string", "pattern": "^[A-Z][0-9]{2}(\\.[0-9])?$"},
                                                   "primary": {"bsonType": "bool"}}}},
            "prescriptions": {"bsonType": "array"},
            "notes": {"bsonType": "array",
                      "items": {"bsonType": "object", "required": ["note_no", "body", "written_at"]}},
        },
    },
    "$expr": {"$and": [
        {"$lte": [{"$size": {"$filter": {"input": "$diagnoses", "cond": "$$this.primary"}}}, 1]},
        {"$allElementsTrue": [{"$map": {
            "input": {"$ifNull": ["$notes", []]}, "as": "n",
            "in": {"$or": [{"$eq": [{"$ifNull": ["$$n.amends_note_no", None]}, None]},
                           {"$in": ["$$n.amends_note_no", {"$ifNull": ["$notes.note_no", []]}]}]}}}]},
    ]},
}

LAB_RESULTS = {
    "$jsonSchema": {
        "bsonType": "object",
        "required": ["_id", "lab_order_id", "encounter_id", "patient_id", "test", "ordered_at", "recorded_at", "result"],
        "properties": {
            "test": {"bsonType": "object", "required": ["code", "name"],
                     "properties": {"code": {"bsonType": "string", "pattern": "^LT-[A-Z0-9]{2,8}$"}}},
            "result": {"oneOf": [
                {"bsonType": "object", "required": ["kind", "value", "unit"], "additionalProperties": False,
                 "properties": {"kind": {"enum": ["numeric"]}, "value": NUMBER, "unit": STRING,
                                "reference": {"bsonType": ["object", "null"]}, "flag": {"enum": ["low", "normal", "high"]}}},
                {"bsonType": "object", "required": ["kind", "text"], "additionalProperties": False,
                 "properties": {"kind": {"enum": ["qualitative"]}, "text": STRING}},
            ]},
        },
    },
    # A result's shape must match its test: tests with a unit take a numeric value in that unit, others take text.
    "$expr": {"$and": [
        {"$gte": ["$recorded_at", "$ordered_at"]},
        {"$cond": [{"$eq": [{"$ifNull": ["$test.unit", None]}, None]},
                   {"$eq": ["$result.kind", "qualitative"]},
                   {"$and": [{"$eq": ["$result.kind", "numeric"]}, {"$eq": ["$result.unit", "$test.unit"]}]}]},
    ]},
}

INVOICES = {
    "$jsonSchema": {
        "bsonType": "object",
        "required": ["_id", "invoice_no", "patient_id", "facility", "issued_at", "total_kobo", "lines"],
        "properties": {
            "invoice_no": {"bsonType": "string", "pattern": "^INV-[0-9]{8}$"},
            "total_kobo": {"bsonType": ["int", "long"], "minimum": 0},
            "lines": {"bsonType": "array", "minItems": 1},
            "payments": {"bsonType": "array"},
        },
    },
    "$expr": {"$eq": ["$total_kobo", {"$sum": "$lines.amount_kobo"}]},
}

STOCK = {
    "$jsonSchema": {
        "bsonType": "object",
        "required": ["_id", "facility", "drug_code", "quantity"],
        "properties": {"quantity": {"bsonType": ["int", "long"], "minimum": 0}},
    },
}

DEFINITIONS = {
    "patients": PATIENTS,
    "encounters": ENCOUNTERS,
    "lab_results": LAB_RESULTS,
    "invoices": INVOICES,
    "stock": STOCK,
    "clinicians": None,
    "referrals": None,
}


def create_all(db):
    for name, validator in DEFINITIONS.items():
        options = {"validator": validator, "validationLevel": "strict", "validationAction": "error"} if validator else {}
        db.create_collection(name, **options)
    db.create_collection("bp_readings", timeseries={"timeField": "taken_at", "metaField": "meta", "granularity": "minutes"})
    db.patients.create_index([("hospital_no", ASCENDING)], unique=True, name="patients_hospital_no_uk")
    db.invoices.create_index([("invoice_no", ASCENDING)], unique=True, name="invoices_invoice_no_uk")
    db.clinicians.create_index([("staff_no", ASCENDING)], unique=True, name="clinicians_staff_no_uk")
