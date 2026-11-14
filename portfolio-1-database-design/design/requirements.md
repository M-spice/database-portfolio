# Requirements

Itoju Clinics needs one system of record that all twelve branches trust: a booking that cannot collide with another, a prescription that cannot be dispensed twice, a stock ledger that always explains what is on the shelf, and a clinical history that is never silently rewritten. I wrote the requirements below so that each one can be tested, and I trace every rule to the constraint, trigger or routine that enforces it.

## Purpose

The database supports outpatient care across the network: registering patients, booking clinicians' time, recording consultations, prescribing and dispensing, laboratory testing, stock control and billing. It is also the evidence base for the organisation's obligations under the Nigeria Data Protection Act 2023, which treats health data as sensitive personal data: it must show who saw which record, keep identity apart from clinical detail, and give analysts data they cannot trace back to a person.

## Users and what they do with the data

| User | Reads | Writes | Never sees |
|---|---|---|---|
| Receptionist | Patient directory (name, hospital number, date of birth, primary phone), appointments, clinicians' departments | Registers patients, adds phones, next of kin and consent; books, reschedules and cancels appointments | Diagnoses, notes, results, prescriptions |
| Clinician (doctor or nurse) | A patient's record and timeline, through an audited function; the day's appointments | Encounters, vital signs, diagnoses, notes and amendments, prescriptions, lab orders, allergies; signs off on call | Raw identity tables; stock levels |
| Pharmacist | Prescriptions and items, stock on hand, the movement ledger | Receipts, dispenses and transfers, through routines | Patient identities, clinical notes |
| Laboratory scientist | Lab orders and results | Results and corrections, through a routine | Patient identities, clinical notes |
| Billing officer | Invoices, lines, payments, prices, patient directory | Invoices, lines and payments | Clinical notes |
| Analyst | De-identified patient and encounter views | Nothing | Names, dates of birth, phone numbers, addresses, national IDs, internal keys |
| Internal auditor | Everything except the pseudonym key, including the record-access log | Nothing | The pseudonym key |
| Clinic application | Patient directory, appointments | Registration and booking, through routines | Clinical data |
| Database administrator | Everything | Schema, roles, maintenance | — |

Patients reach the database only through the booking app or the front desk.

## Data dictionary

Attributes in *italics* are composite, those marked † are multi-valued and those marked ‡ are derived (computed when read, never stored). The key of each entity is listed first.

| Entity | Meaning | Attributes |
|---|---|---|
| Patient | A person registered with the network | hospital_no, *full name* (given, middle, family), date_of_birth, age ‡, national_id, *address* (line, city, state), phone †, allergy †, registered_at |
| Next of kin (weak) | A contact for a patient, identified within that patient | kin_no (partial key), full_name, relationship, phone |
| Consent | A patient's permission for one purpose | consent_id, purpose, granted_at, withdrawn_at |
| Facility | A clinic branch | facility_code, name, city, state, has_laboratory, opened_on |
| Department | A clinical speciality | department_code, name |
| Staff | An employee | staff_no, *name* (given, family), role, home facility, employed_on, left_on |
| Clinician | A member of staff who sees patients (a doctor or nurse) | licence_no |
| Appointment | A booked period of a clinician's time | appointment_id, *slot* (start, end), status, booked_at, booked_by, request_key, reason |
| Encounter | A consultation that took place | encounter_id, type, started_at, ended_at, wait time ‡ |
| Vital sign | A set of measurements taken in an encounter | vital_sign_id, recorded_at, temperature, pulse, *blood pressure* (systolic, diastolic), SpO2, weight, height, BMI ‡ |
| Diagnosis | A catalogued condition code | diagnosis_code, description, is_chronic |
| Clinical note | Free text written by a clinician; amendments point to the note they correct | note_id, written_at, body, amendment_reason |
| Drug | A catalogued medicine | drug_code, name, form, strength, unit_price, reorder_level |
| Prescription | The medicines ordered in one encounter | prescription_id, issued_at |
| Stock movement | One change to one drug's stock at one branch | movement_id, type, quantity, moved_at, transfer_ref, note |
| Lab test | A catalogued test | test_code, name, specimen, unit, *reference range* (low, high), price, target_turnaround |
| Lab order | A test requested in an encounter | lab_order_id, ordered_at, turnaround ‡ |
| Lab result | The value reported for an order; a correction supersedes the original | lab_result_id, value, recorded_at, correction_reason |
| Invoice | A bill for a visit | invoice_no, issued_at, total, balance ‡ |
| Invoice line (weak) | One charge on an invoice | line_no (partial key), description, quantity, unit_price, amount ‡ |
| Payment | Money received against an invoice | payment_id, method, amount, paid_at, reference |

Several relationships carry attributes of their own: a clinician WORKS_IN a department (assigned_on), a prescription PRESCRIBES a drug (quantity, dosage), an encounter is DIAGNOSED_AS a condition (is_primary), a facility STOCKS a drug (quantity on hand), staff ACCESS a patient's record (accessed_at, purpose, database user) and a clinician is ON_CALL at a facility (shift date, on call). The full set of relationships and cardinalities is in the [ER model](er-overview.svg).

Money is held in whole kobo. Times are instants stored in UTC; local Lagos time is a matter of display.

## Business rules

| Rule | Statement |
|---|---|
| R01 | Every patient has a unique hospital number of the form HN-0000000. A national ID is optional but, when present, unique and in the synthetic 999 range. |
| R02 | A patient may have several phone numbers, at most one of them primary, all in the synthetic +2340 range. |
| R03 | Each allergen is recorded once per patient. |
| R04 | A patient holds at most one open consent per purpose, and a withdrawal always follows the grant. |
| R05 | A clinician is a member of staff with a clinical role and a unique licence number. |
| R06 | A clinician may work in several departments, and is booked only in a department they work in. |
| R07 | Neither a clinician nor a patient can be in two active appointments that overlap in time. |
| R08 | A slot lasts between 10 minutes and 2 hours. Cancelling an appointment frees its slot; only a booked appointment can be rescheduled. |
| R09 | Every change of appointment status is recorded with who made it and when, and that history cannot be altered. |
| R10 | An encounter comes from at most one appointment, and only from an appointment of the same patient. |
| R11 | A vital-sign record holds at least one measurement, every measurement lies in a physiologically possible range, and systolic pressure exceeds diastolic. |
| R12 | An encounter has at most one primary diagnosis, and every diagnosis comes from the catalogue. |
| R13 | Clinical notes are never edited or deleted. A correction is a new note that points to the note it amends, within the same encounter, and gives a reason. |
| R14 | Every stock change is a row in an append-only ledger. Stock on hand always equals the ledger total, never goes below zero, and changes only through the ledger. |
| R15 | A dispense cites a prescription item, takes exactly the prescribed quantity, and happens once per item. |
| R16 | A transfer between branches is one movement out and one movement in, for the same drug and quantity, committed together. |
| R17 | A test is ordered only at a branch with a laboratory. A result has a numeric value for a measured test and a text value for a qualitative one, is recorded after its order, is never edited, and is corrected only by a superseding result for the same order that gives a reason. |
| R18 | An invoice total equals the sum of its lines when the transaction commits. A payment never exceeds the amount outstanding, card, HMO and transfer payments carry a reference, and payments are never edited or deleted. |
| R19 | Every opening of a patient record by staff is logged with who, when, why and the database user. Staff who have left cannot open records, and the log cannot be altered. |
| R20 | At every rostered facility, at least one clinician stays on call each night. |

## Functional requirements

| Requirement | Operation | Provided by |
|---|---|---|
| F01 | Register a patient | `register_patient` |
| F02 | Book an appointment, safely retried with the same request key | `book_appointment` |
| F03 | Reschedule or cancel an appointment | `reschedule_appointment`, `cancel_appointment` |
| F04 | Record an encounter with vital signs, diagnoses and notes | inserts by the clinician role |
| F05 | Prescribe, then dispense from the branch pharmacy | inserts by the clinician role; `dispense_prescription_item` |
| F06 | Order a lab test and record its result or a correction | inserts by the clinician role; `record_lab_result` |
| F07 | Receive stock and transfer it between branches | `receive_stock`, `transfer_stock` |
| F08 | Invoice a visit and take payment | inserts by the billing role |
| F09 | Show a clinician a patient's record and timeline | `patient_record` (audited) |
| F10 | Produce a clinician's daily schedule | query on appointments |
| F11 | Produce the monthly diagnosis report per facility | query on encounters and diagnoses |
| F12 | Produce the pharmacy reorder report | query on stock on hand and drugs |
| F13 | Produce the lab turnaround report | query on orders and results |
| F14 | Reconcile stock on hand against the movement ledger | consistency check |
| F15 | Show who viewed a patient's record | the record-access log, read by auditors |
| F16 | Let a clinician sign off from the on-call rota | `sign_off_on_call` |

Reports F10 to F14 are written and tuned at realistic volume in [Portfolio 2](../../portfolio-2-query-optimisation/README.md).

## Non-functional requirements

| Requirement | Statement |
|---|---|
| N01 Integrity | Every rule that can be stated about the data is enforced by the DBMS, so no application, script or administrator's ad hoc statement can bypass it. |
| N02 Privacy | Identity data is kept apart from clinical data; each role sees only what its job needs; analysts see only de-identified data; every record opening is audited. |
| N03 Auditability | Clinical notes, lab results, payments, the stock ledger, the status history and the access log are append-only. |
| N04 Performance | Point lookups and a patient's timeline answer interactively at network volume; reports run without blocking bookings. |
| N05 Availability | Booking and clinical recording keep working when one server fails, without losing committed work. |
| N06 Reproducibility | The whole database can be rebuilt from scripts, and every test rerun, with identical results. |

## Traceability

Every entity and relationship in the ER model is covered by at least one rule, and every rule is enforced in the database. Constraint names follow `<table>_<column(s)>_<kind>`; the kinds are listed in the [relational schema](relational-schema.md#naming).

| Rule | Entities and relationships | Enforced by | Tested in |
|---|---|---|---|
| R01 | Patient | `patient_hospital_no_uk`, `patient_hospital_no_ck`, `patient_national_id_uk`, `patient_national_id_ck`, `register_patient` | constraints, routines |
| R02 | Patient (phone) | `patient_phone_pk`, `patient_phone_primary_uk`, `patient_phone_no_ck`, `next_of_kin_phone_no_ck` | constraints, routines |
| R03 | Patient (allergy) | `patient_allergy_pk`, `patient_allergy_allergen_ck` | constraints |
| R04 | Consent, GIVES | `consent_patient_purpose_open_uk`, `consent_withdrawn_at_ck` | constraints |
| R05 | Staff, Clinician, IS_A | `clinician_staff_fk`, `clinician_clinical_role_tg`, `clinician_licence_no_uk`, `clinician_licence_no_ck` | constraints |
| R06 | Clinician, Department, WORKS_IN, IN | `clinician_department_pk`, `appointment_clinician_department_fk` | constraints |
| R07 | Appointment, BOOKS, WITH | `appointment_clinician_slot_ex`, `appointment_patient_slot_ex` | constraints, routines, consistency |
| R08 | Appointment | `appointment_slot_ck`, the exclusion predicate, `reschedule_appointment`, `cancel_appointment` | constraints, routines |
| R09 | Appointment | `appointment_status_history_tg`, `appointment_status_history_append_only_tg` | constraints, routines, consistency |
| R10 | Appointment, Encounter, RESULTS_IN | `encounter_appointment_uk`, `encounter_appointment_fk` | constraints, consistency |
| R11 | Vital sign, MEASURES | `vital_sign_any_ck` and six range checks | constraints |
| R12 | Encounter, Diagnosis, DIAGNOSED_AS | `encounter_diagnosis_primary_uk`, `encounter_diagnosis_diagnosis_fk` | constraints |
| R13 | Clinical note, DOCUMENTS, AMENDS | `clinical_note_append_only_tg`, `clinical_note_amends_fk`, `clinical_note_amendment_ck` | constraints, consistency |
| R14 | Facility, Drug, STOCKS, Stock movement, MOVES, AT | `stock_movement_apply_tg`, `stock_on_hand_quantity_ck`, `stock_on_hand_ledger_only_tg`, `stock_movement_append_only_tg` | constraints, routines, consistency |
| R15 | Prescription, PRESCRIBES, FULFILS | `stock_movement_prescription_tg`, `stock_movement_prescription_item_fk`, `stock_movement_prescription_item_uk`, `dispense_prescription_item` | constraints, routines, consistency |
| R16 | Stock movement | `stock_movement_transfer_pair_tg`, `stock_movement_transfer_ref_tg`, `stock_movement_transfer_ref_uk`, `transfer_stock` | constraints, routines, consistency |
| R17 | Lab test, Lab order, Lab result, ORDERS, OF_TEST, PRODUCES, SUPERSEDES | `lab_order_facility_laboratory_tg`, `lab_result_value_kind_tg`, `lab_result_value_ck`, `lab_result_after_order_tg`, `lab_result_append_only_tg`, `lab_result_supersedes_fk`, `lab_result_correction_ck`, `lab_result_order_original_uk` | constraints, routines, consistency |
| R18 | Invoice, Invoice line, Payment, BILLED_TO, BILLS, CONTAINS, SETTLED_BY | `invoice_total_tg`, `invoice_line_total_tg`, `payment_outstanding_tg`, `payment_reference_tg`, `payment_append_only_tg`, `invoice_encounter_fk` | constraints, routines, consistency |
| R19 | Staff, Patient, ACCESSES | `patient_record`, `record_access_active_staff_fn`, `record_access_log_append_only_tg` | routines, privileges |
| R20 | Clinician, Facility, ON_CALL | `sign_off_on_call` (`on_call_minimum_fn`), `on_call_shift_facility_clinician_date_uk` | routines, consistency |

R20 is the one rule I enforce in a routine rather than declaratively, because it is a condition across several rows that no single-row constraint can express. That leaves it open to write skew under weaker isolation levels, which [Portfolio 3](../../portfolio-3-transactions-concurrency/README.md) demonstrates and fixes.
