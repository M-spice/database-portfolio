# The Itoju Clinics document model

In a document database the shape of the data should follow the way it is read and written, not the way it is normalised. I started from the clinic's access patterns, then decided for each relationship whether to embed or to reference.

## Access patterns

| # | Who | What they do | How often | What it implies |
|---|---|---|---|---|
| A1 | Front desk | Find a patient by phone number or hospital number | All day, every branch | Patient documents with an index on the embedded phone numbers |
| A2 | Clinician | Open a patient: identity, allergies, then the latest visits with diagnoses, prescriptions and notes | Every consultation | One patient read plus one indexed range read of encounters, newest first |
| A3 | Clinician | Record a visit: vital signs, diagnoses, notes and prescriptions, all written in the same consultation | Every consultation | One encounter document holding everything written in that visit |
| A4 | Laboratory | Record a result whose shape depends on the test | Hundreds a day | A separate result document with a polymorphic `result` sub-document |
| A5 | Management | Monthly diagnosis counts per branch; laboratory turnaround | Monthly, weekly | Aggregation pipelines over encounters and results |
| A6 | Remote monitoring | Store many small, timestamped blood-pressure readings per patient and summarise them by hour or day | Continuous | A time-series collection |
| A7 | Medical director | Follow referral pathways: where one GP's patients end up, and who receives the most | Occasional | Referral edges traversed as a graph |
| A8 | Billing | Read and write an invoice with its lines and payments as one unit | Every visit | Lines and payments embedded in the invoice |
| A9 | Pharmacy | Decrement one branch's stock of one drug on every dispense, atomically with the invoice | Every dispense | Small stock documents updated inside multi-document transactions |

## Collections

| Collection | One document is | Embeds | References | Indexes |
|---|---|---|---|---|
| `patients` | A patient | name and address (composite), phones, allergies, next of kin, consents | registering branch by code | `_id`; `hospital_no` (unique); `phones.number` (multikey) |
| `encounters` | One visit | vital signs, diagnoses (code and description), prescriptions with items, notes and amendments, lab orders | patient by `patient_id`; clinician as `{staff_no, name}`; branch by code | `_id`; `(patient_id, started_at desc)`; `started_at`; `(diagnoses.code, started_at)` (multikey) |
| `lab_results` | One result or correction | test summary; a `result` that is either `{kind: numeric, value, unit, reference, flag}` or `{kind: qualitative, text}` | order, encounter, patient by id; the result it supersedes | `_id`; `ordered_at` |
| `invoices` | One bill | lines, payments | patient and encounter by id | `_id`; `invoice_no` (unique) |
| `stock` | One drug at one branch | – | branch and drug by code | `_id` (`"LAG-IKJ\|DRG-0002"`) |
| `clinicians` | A doctor or nurse | departments | branch by code | `_id`; `staff_no` (unique) |
| `referrals` | One referral (a graph edge) | – | `from` and `to` clinicians, patient | `from`, `to` |
| `bp_readings` | One home blood-pressure reading (time-series) | `meta: {patient_id, hospital_no, device}` | patient by id | automatic bucketing on `meta` and `taken_at` |
| `deid_encounters` | A view for analysts | – | – | – |

## From relations to documents

| Relationship in the relational design | Decision | Why |
|---|---|---|
| Patient – phones, allergies, next of kin, consents (multi-valued attributes and a weak entity) | Embed | Small, bounded lists, always read with the patient and never alone. A multikey index still finds a patient by any of their phone numbers (A1). |
| Patient – encounters (1:N) | Reference | Unbounded: the busiest patient has 138 visits, and the number only grows. Embedding them would rewrite an ever larger patient document on every visit and eventually meet the 16 MB document limit. |
| Encounter – vital signs, diagnoses, notes, prescriptions and items | Embed | Written in the same consultation, read together, bounded by one visit (A3). One read returns the whole visit, where the relational schema needs five joins. |
| Encounter – clinician | Extended reference (`staff_no` and name) | The timeline shows the clinician's name on every row, and copying it avoids a lookup per visit. The copy is also historically right: the record shows who saw the patient at the time. |
| Diagnosis code, drug – descriptions | Copy the description into the encounter | The catalogues change rarely; a copy keeps each visit readable on its own. |
| Lab order – result | Separate collection | Results arrive hours later from a different team, vary in shape by test, and are queried across many encounters for turnaround (A4, A5). |
| Clinical note – amendment (recursive) | Embed both, linked by `note_no` | An amendment belongs to the same visit; a validator checks every `amends_note_no` points at a note in the same document. |
| Invoice – lines, payments (weak entity, 1:N) | Embed | Always read and written together; a validator checks the total equals the sum of the lines (A8). |
| Branch – drug stock (M:N with a quantity) | Own small documents | The most frequently updated data in the system. Kept small and separate so a dispense touches one tiny document, inside a transaction with the invoice (A9). |
| Clinician – department (M:N) | Array in the clinician | Two or three values per clinician. |
| Clinician – clinician referral (M:N with attributes) | Edge collection | Traversed recursively with `$graphLookup` (A7). |
| Record access log, appointment status history | Not moved | Append-only audit trails that belong with the system of record, which stays relational. |

Every patient's encounters also carry `patient_key`, the same pseudonymous key the relational analyst views use, so the de-identified view can follow a patient across visits without exposing who they are.

## Rules the document model enforces

Each collection has a `$jsonSchema` validator for structure, and `$expr` checks for rules that compare fields within a document:

- a patient has at most one primary phone, in the synthetic +2340 range;
- an encounter has at most one primary diagnosis, uses a known encounter type, and every amendment points at a note in the same encounter;
- a numeric lab result is in its test's unit, a qualitative test takes text, and no result predates its order;
- an invoice's total equals the sum of its lines;
- stock can never go below zero, on updates as well as inserts.

What it cannot enforce is anything across documents. There is no foreign key, so an encounter could name a patient who does not exist. There is no exclusion constraint, so two documents could book the same clinician at the same time. And a rule like "someone stays on call" spans several documents. The relational design enforces all three, and that difference drives the conclusion in [suitability.md](suitability.md).

## Sample documents

Exactly as loaded from PostgreSQL ([outputs/p4-01-load.txt](outputs/p4-01-load.txt)): patient HN-0000001, their malaria visit of 5 October 2026, two of their laboratory results, and the first home blood-pressure reading.

**A patient (`patients`)**

```json
{
  "_id": 1,
  "hospital_no": "HN-0000001",
  "name": {
    "given": "Oluwaseun",
    "middle": "Adewale",
    "family": "Bankole"
  },
  "date_of_birth": "1978-04-12T00:00:00Z",
  "national_id": "99900000001",
  "address": {
    "line": "14 Allen Avenue",
    "city": "Ikeja",
    "state": "Lagos"
  },
  "registered": {
    "facility": "LAG-IKJ",
    "at": "2024-01-15T08:12:00Z"
  },
  "phones": [
    {
      "number": "+2340001000001",
      "primary": true
    },
    {
      "number": "+2340001000101",
      "primary": false
    }
  ],
  "allergies": [
    {
      "allergen": "Penicillin",
      "reaction": "Rash",
      "recorded_at": "2024-01-15T08:20:00Z"
    },
    {
      "allergen": "Sulfonamides",
      "reaction": "Hives",
      "recorded_at": "2024-01-15T08:20:00Z"
    }
  ],
  "next_of_kin": [
    {
      "phone": "+2340002000001",
      "kin_no": 1,
      "full_name": "Bisi Bankole",
      "relationship": "Spouse"
    }
  ],
  "consents": [
    {
      "purpose": "TREATMENT",
      "granted_at": "2024-01-15T08:12:00Z",
      "withdrawn_at": null
    },
    {
      "purpose": "SMS_REMINDERS",
      "granted_at": "2024-01-15T08:15:00Z",
      "withdrawn_at": null
    }
  ]
}
```

**One visit with everything written during it (`encounters`)**

```json
{
  "_id": 1,
  "patient_id": 1,
  "patient_key": "3c87ce9b129f6b76",
  "facility": "LAG-IKJ",
  "clinician": {
    "staff_no": "ST-00001",
    "name": "Adaeze Okafor"
  },
  "type": "CONSULTATION",
  "started_at": "2026-10-05T08:04:00Z",
  "ended_at": "2026-10-05T08:30:00Z",
  "appointment_id": 1,
  "vitals": [
    {
      "spo2_pct": 97,
      "height_cm": 176.0,
      "pulse_bpm": 102,
      "weight_kg": 82.4,
      "recorded_at": "2026-10-05T08:06:00Z",
      "systolic_mmhg": 128,
      "temperature_c": 38.6,
      "diastolic_mmhg": 84
    }
  ],
  "diagnoses": [
    {
      "code": "B54",
      "primary": true,
      "description": "Malaria, uncomplicated"
    }
  ],
  "prescriptions": [
    {
      "items": [
        {
          "name": "Artemether-lumefantrine",
          "dosage": "4 tablets twice daily for 3 days",
          "quantity": 24,
          "drug_code": "DRG-0001"
        },
        {
          "name": "Paracetamol",
          "dosage": "2 tablets three times daily for 3 days",
          "quantity": 18,
          "drug_code": "DRG-0002"
        }
      ],
      "issued_at": "2026-10-05T08:22:00Z",
      "prescription_id": 1
    }
  ],
  "notes": [
    {
      "body": "Two days of fever and headache. Malaria RDT positive. Start artemether-lumefantrine; paracetamol for fever.",
      "author": "ST-00001",
      "note_no": 1,
      "written_at": "2026-10-05T08:19:00Z",
      "amends_note_no": null,
      "amendment_reason": null
    }
  ],
  "lab_orders": [
    {
      "test_code": "LT-MPRDT",
      "ordered_at": "2026-10-05T08:14:00Z",
      "lab_order_id": 1
    }
  ]
}
```

**A qualitative result (`lab_results`)**

```json
{
  "_id": 1,
  "lab_order_id": 1,
  "encounter_id": 1,
  "patient_id": 1,
  "test": {
    "code": "LT-MPRDT",
    "name": "Malaria rapid diagnostic test",
    "unit": null,
    "target_hours": 1.0
  },
  "facility": "LAG-IKJ",
  "ordered_at": "2026-10-05T08:14:00Z",
  "recorded_at": "2026-10-05T08:54:00Z",
  "result": {
    "kind": "qualitative",
    "text": "Positive (P. falciparum)"
  },
  "supersedes": null,
  "correction_reason": null
}
```

**A corrected numeric result (`lab_results`)**

```json
{
  "_id": 6,
  "lab_order_id": 3,
  "encounter_id": 3,
  "patient_id": 3,
  "test": {
    "code": "LT-FBG",
    "name": "Fasting blood glucose",
    "unit": "mmol/L",
    "target_hours": 2.0
  },
  "facility": "KAN-NAS",
  "ordered_at": "2026-10-20T10:14:00Z",
  "recorded_at": "2026-10-20T12:09:00Z",
  "result": {
    "kind": "numeric",
    "value": 7.8,
    "unit": "mmol/L",
    "reference": {
      "low": 3.9,
      "high": 5.5
    },
    "flag": "high"
  },
  "supersedes": 2,
  "correction_reason": "Decimal point missed at entry"
}
```

**A home blood-pressure reading (`bp_readings`)**

```json
{
  "taken_at": "2026-10-31T05:00:00Z",
  "meta": {
    "device": "cuff-062",
    "hospital_no": "HN-0100818",
    "patient_id": 830
  },
  "pulse": 63,
  "systolic": 136,
  "diastolic": 88
}
```
