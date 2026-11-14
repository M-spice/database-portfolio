# Relational schema

The Itoju Clinics database is one PostgreSQL schema, `itoju`, of 37 relations: 30 hold the organisation's data, six are code tables and one holds the private key used to pseudonymise patients for analysts. I mapped them from the [ER model](er-overview.svg) and normalised them to BCNF ([normalisation](normalisation.md)). Every business rule in the [requirements](requirements.md) that can be stated about data is enforced here by the DBMS, so an application bug, a script or a hurried manual fix cannot break it. The live catalogue is compared with this document by [`tests/catalogue_check.py`](../tests/catalogue_check.py) every time the database is rebuilt.

## From the ER model to relations

| ER construct | Mapping I used | Example |
|---|---|---|
| Strong entity | A relation with a surrogate key `<entity>_id` (`bigint GENERATED ALWAYS AS IDENTITY`), keeping the natural key as `UNIQUE` | `patient` (key `patient_id`, natural key `hospital_no`) |
| Weak entity | A relation keyed by the owner's key plus the partial key, with `ON DELETE CASCADE` to the owner | `next_of_kin (patient_id, kin_no)`, `invoice_line (invoice_id, line_no)` |
| 1:N relationship | A foreign key on the N side | `encounter.facility_id` |
| 1:1 relationship | A shared primary key, or a foreign key made `UNIQUE` | `clinician.clinician_id` is `staff.staff_id`; `encounter.appointment_id` is unique |
| M:N relationship | An associative relation keyed by both sides; the relationship's attributes become its columns | `clinician_department`, `prescription_item (quantity, dosage)`, `encounter_diagnosis (is_primary)`, `stock_on_hand (quantity)` |
| Relationship recording events | Its own relation with a surrogate key, because the same pair can meet many times | `record_access_log` (ACCESSES), `on_call_shift` (ON_CALL) |
| Recursive relationship | A self-referencing foreign key | `clinical_note.amends_note_id`, `lab_result.supersedes_result_id` |
| Multi-valued attribute | A relation keyed by owner and value | `patient_phone`, `patient_allergy` |
| Composite attribute | Flattened into its components | full name → `given_name`, `middle_name`, `family_name`; address → `address_line`, `address_city`, `address_state`; blood pressure → `systolic_mmhg`, `diastolic_mmhg` |
| Derived attribute | Not stored; computed when read | age and age band (`age_band`, `patient_record`), wait time (`encounter.started_at − lower(appointment.slot)`), lab turnaround, invoice balance |
| Coded attribute (status, type, method) | A code table and a foreign key | `appointment_status`, `movement_type`, `payment_method` |

FULFILS links a stock movement to the prescribed item it dispenses, so `stock_movement` references `prescription_item (prescription_id, drug_id)`. Reusing the movement's own `drug_id` in that key means a dispense can only ever be for the drug that was prescribed.

The one stored derived value is `invoice_line.amount_kobo`, a generated column (`quantity * unit_price_kobo`). PostgreSQL computes it, so it can never disagree with its inputs.

## Design conventions

**Keys.** Surrogate identity keys make joins cheap and stable. Natural keys (hospital number, staff number, facility code, drug code, invoice number, licence number) stay unique, because those are what people search by. Code tables are keyed by the code itself (`'BOOKED'`, `'DISPENSE'`), which keeps joins readable and statuses readable in raw rows.

**Codes as data.** Statuses, encounter types, movement types, payment methods, staff roles and consent purposes are rows in code tables, not `CHECK (… IN …)` lists. A new code is an insert rather than a schema change, every code carries its description, and behaviour that belongs to a code lives with it: `movement_type.direction` (+1 or −1) drives the stock ledger, `payment_method.requires_reference` drives the payment rule and `staff_role.is_clinical` decides who can be a clinician. A literal code appears in DDL in only one place: the predicate of the double-booking exclusion constraints (`appointment_status_code <> 'CANCELLED'`), because an exclusion constraint's predicate cannot look up another table.

**Time.** Every instant is `timestamptz` and the server runs in UTC. Appointment slots are `tstzrange` values, closed at the start and open at the end, so back-to-back slots do not overlap.

**Money.** Prices, totals and payments are integer kobo (`bigint`), which makes sums exact.

**Identity apart from clinical data.** Names, phones, address and national ID live only in `patient`, `patient_phone` and `next_of_kin`. Clinical relations carry `patient_id` and nothing else about the person, which is what makes de-identified views and the role design possible.

<a id="naming"></a>
**Naming.** Relations are singular and `snake_case`. Constraints are named `<table>_<column(s)>_<kind>`; a column whose name repeats the table name is not repeated (`facility.facility_code` gives `facility_code_uk`), and foreign keys drop the `_id` or `_code` suffix (`appointment.clinician_id` gives `appointment_clinician_fk`). The kinds are:

| Suffix | Kind |
|---|---|
| `pk` | primary key |
| `fk` | foreign key |
| `uk` | unique constraint or unique index |
| `ck` | check constraint |
| `ex` | exclusion constraint |
| `tg` | rule enforced by a trigger, reported under that name |
| `fn` | rule enforced inside a routine, reported under that name |

Because triggers and routines raise their errors with a constraint name, every refusal in the [test evidence](../outputs/) names the rule that caused it.

## Relations

Primary keys are <ins>underlined</ins> and foreign keys are in *italics*.

### Code tables

**staff_role** (<ins>staff_role_code</ins>, description, is_clinical)

**consent_purpose** (<ins>consent_purpose_code</ins>, description)

**appointment_status** (<ins>appointment_status_code</ins>, description)

**encounter_type** (<ins>encounter_type_code</ins>, description)

**movement_type** (<ins>movement_type_code</ins>, description, direction, requires_prescription, requires_transfer_ref)

**payment_method** (<ins>payment_method_code</ins>, description, requires_reference)

### Organisation and staff

**facility** (<ins>facility_id</ins>, facility_code, name, city, state, has_laboratory, opened_on)

**department** (<ins>department_id</ins>, department_code, name)

**staff** (<ins>staff_id</ins>, staff_no, given_name, family_name, *staff_role_code*, *home_facility_id*, employed_on, left_on)

**clinician** (<ins>*clinician_id*</ins>, licence_no)

**clinician_department** (<ins>*clinician_id*, *department_id*</ins>, assigned_on)

**on_call_shift** (<ins>on_call_shift_id</ins>, *facility_id*, *clinician_id*, shift_date, on_call)

### Patients

**patient** (<ins>patient_id</ins>, hospital_no, given_name, middle_name, family_name, date_of_birth, national_id, address_line, address_city, address_state, *registered_facility_id*, registered_at)

**patient_phone** (<ins>*patient_id*, phone_no</ins>, is_primary)

**patient_allergy** (<ins>*patient_id*, allergen</ins>, reaction, recorded_at)

**next_of_kin** (<ins>*patient_id*, kin_no</ins>, full_name, relationship, phone_no)

**consent** (<ins>consent_id</ins>, *patient_id*, *consent_purpose_code*, granted_at, withdrawn_at, *recorded_by*)

### Appointments and care

**appointment** (<ins>appointment_id</ins>, *patient_id*, *clinician_id*, *department_id*, *facility_id*, slot, *appointment_status_code*, booked_at, *booked_by*, request_key, reason)

**appointment_status_history** (<ins>appointment_status_history_id</ins>, *appointment_id*, *appointment_status_code*, changed_at, *changed_by*)

**encounter** (<ins>encounter_id</ins>, *patient_id*, *clinician_id*, *facility_id*, *appointment_id*, *encounter_type_code*, started_at, ended_at)

**vital_sign** (<ins>vital_sign_id</ins>, *encounter_id*, recorded_at, *recorded_by*, temperature_c, pulse_bpm, systolic_mmhg, diastolic_mmhg, spo2_pct, weight_kg, height_cm)

**diagnosis_code** (<ins>diagnosis_code</ins>, description, is_chronic)

**encounter_diagnosis** (<ins>*encounter_id*, *diagnosis_code*</ins>, is_primary)

**clinical_note** (<ins>clinical_note_id</ins>, *encounter_id*, *author_id*, written_at, body, *amends_note_id*, amendment_reason)

### Pharmacy and stock

**drug** (<ins>drug_id</ins>, drug_code, name, form, strength, unit_price_kobo, reorder_level)

**prescription** (<ins>prescription_id</ins>, *encounter_id*, *prescriber_id*, issued_at)

**prescription_item** (<ins>*prescription_id*, *drug_id*</ins>, quantity, dosage)

**stock_on_hand** (<ins>*facility_id*, *drug_id*</ins>, quantity, updated_at)

**stock_movement** (<ins>stock_movement_id</ins>, *facility_id*, *drug_id*, *movement_type_code*, quantity, moved_at, *moved_by*, transfer_ref, *prescription_id*, note)

### Laboratory

**lab_test** (<ins>lab_test_id</ins>, test_code, name, specimen, unit, reference_low, reference_high, price_kobo, target_turnaround)

**lab_order** (<ins>lab_order_id</ins>, *encounter_id*, *lab_test_id*, *facility_id*, *ordered_by*, ordered_at)

**lab_result** (<ins>lab_result_id</ins>, *lab_order_id*, recorded_at, *recorded_by*, value_numeric, value_text, *supersedes_result_id*, correction_reason)

### Billing

**invoice** (<ins>invoice_id</ins>, invoice_no, *patient_id*, *facility_id*, *encounter_id*, issued_at, *issued_by*, total_kobo)

**invoice_line** (<ins>*invoice_id*, line_no</ins>, description, *drug_id*, *lab_test_id*, quantity, unit_price_kobo, amount_kobo)

**payment** (<ins>payment_id</ins>, *invoice_id*, *payment_method_code*, amount_kobo, paid_at, *received_by*, reference)

### Audit and privacy

**record_access_log** (<ins>record_access_log_id</ins>, *staff_id*, *patient_id*, accessed_at, purpose, db_user)

**pseudonym_key** (<ins>pseudonym_key_id</ins>, secret)

## Keys and constraints

Every column is `NOT NULL` unless it is listed as optional. Every foreign key is `NO ACTION` on delete, so a referenced row cannot be removed while anything points at it, except the four marked *cascade*: phones, allergies and next of kin belong to the patient, and lines belong to their invoice, so they go with their owner. Clinical, stock and financial rows have no cascades, because deleting a patient or an invoice that has history must fail.

| Relation | Constraints | Optional columns | Rules |
|---|---|---|---|
| staff_role, consent_purpose, appointment_status, encounter_type, payment_method | `<table>_pk`, `<table>_code_ck` (upper-case code) | — | codes as data |
| movement_type | `movement_type_pk`, `movement_type_code_ck`, `movement_type_direction_ck` (−1 or +1) | — | R14 |
| facility | `facility_pk`, `facility_code_uk`, `facility_code_ck` (AAA-AAA) | — | R17 |
| department | `department_pk`, `department_code_uk`, `department_name_uk`, `department_code_ck` | — | R06 |
| staff | `staff_pk`, `staff_role_fk`, `staff_home_facility_fk`, `staff_no_uk`, `staff_no_ck`, `staff_left_on_ck` | left_on | R05, R19 |
| clinician | `clinician_pk`, `clinician_staff_fk`, `clinician_licence_no_uk`, `clinician_licence_no_ck`, `clinician_clinical_role_tg` | — | R05 |
| clinician_department | `clinician_department_pk`, `clinician_department_clinician_fk`, `clinician_department_department_fk` | — | R06 |
| on_call_shift | `on_call_shift_pk`, `on_call_shift_facility_fk`, `on_call_shift_clinician_fk`, `on_call_shift_facility_clinician_date_uk` | — | R20 |
| patient | `patient_pk`, `patient_registered_facility_fk`, `patient_hospital_no_uk`, `patient_national_id_uk`, `patient_hospital_no_ck`, `patient_national_id_ck`, `patient_date_of_birth_ck` | middle_name, national_id | R01 |
| patient_phone | `patient_phone_pk`, `patient_phone_patient_fk` (cascade), `patient_phone_no_ck`, `patient_phone_primary_uk` (unique index on primary rows) | — | R02 |
| patient_allergy | `patient_allergy_pk`, `patient_allergy_patient_fk` (cascade), `patient_allergy_allergen_ck` | reaction | R03 |
| next_of_kin | `next_of_kin_pk`, `next_of_kin_patient_fk` (cascade), `next_of_kin_kin_no_ck`, `next_of_kin_phone_no_ck` | — | R02 |
| consent | `consent_pk`, `consent_patient_fk`, `consent_purpose_fk`, `consent_recorded_by_fk`, `consent_withdrawn_at_ck`, `consent_patient_purpose_open_uk` (unique index on open rows) | withdrawn_at | R04 |
| appointment | `appointment_pk`, `appointment_patient_fk`, `appointment_clinician_department_fk`, `appointment_facility_fk`, `appointment_status_fk`, `appointment_booked_by_fk`, `appointment_request_key_uk`, `appointment_id_patient_uk`, `appointment_slot_ck`, `appointment_clinician_slot_ex`, `appointment_patient_slot_ex`, `appointment_status_history_tg` | booked_by, request_key, reason | R06, R07, R08, R09 |
| appointment_status_history | `appointment_status_history_pk`, `appointment_status_history_appointment_fk`, `appointment_status_history_status_fk`, `appointment_status_history_changed_by_fk`, `appointment_status_history_append_only_tg` | changed_by | R09 |
| encounter | `encounter_pk`, `encounter_patient_fk`, `encounter_clinician_fk`, `encounter_facility_fk`, `encounter_type_fk`, `encounter_appointment_fk` (appointment and patient together), `encounter_appointment_uk`, `encounter_id_patient_uk`, `encounter_ended_at_ck` | appointment_id, ended_at | R10 |
| vital_sign | `vital_sign_pk`, `vital_sign_encounter_fk`, `vital_sign_recorded_by_fk`, `vital_sign_any_ck`, `vital_sign_blood_pressure_ck`, `vital_sign_height_cm_ck`, `vital_sign_pulse_bpm_ck`, `vital_sign_spo2_pct_ck`, `vital_sign_temperature_c_ck`, `vital_sign_weight_kg_ck` | every measurement | R11 |
| diagnosis_code | `diagnosis_code_pk`, `diagnosis_code_ck` (ICD-10 style) | — | R12 |
| encounter_diagnosis | `encounter_diagnosis_pk`, `encounter_diagnosis_encounter_fk`, `encounter_diagnosis_diagnosis_fk`, `encounter_diagnosis_primary_uk` (unique index on primary rows) | — | R12 |
| clinical_note | `clinical_note_pk`, `clinical_note_encounter_fk`, `clinical_note_author_fk`, `clinical_note_amends_fk` (note and encounter together), `clinical_note_id_encounter_uk`, `clinical_note_amendment_ck`, `clinical_note_body_ck`, `clinical_note_append_only_tg` | amends_note_id, amendment_reason | R13 |
| drug | `drug_pk`, `drug_code_uk`, `drug_name_form_strength_uk`, `drug_code_ck`, `drug_reorder_level_ck`, `drug_unit_price_kobo_ck` | — | R18 |
| prescription | `prescription_pk`, `prescription_encounter_fk`, `prescription_prescriber_fk` | — | R15 |
| prescription_item | `prescription_item_pk`, `prescription_item_prescription_fk`, `prescription_item_drug_fk`, `prescription_item_quantity_ck` | — | R15 |
| stock_on_hand | `stock_on_hand_pk`, `stock_on_hand_facility_fk`, `stock_on_hand_drug_fk`, `stock_on_hand_quantity_ck`, `stock_on_hand_ledger_only_tg` | — | R14 |
| stock_movement | `stock_movement_pk`, `stock_movement_facility_fk`, `stock_movement_drug_fk`, `stock_movement_type_fk`, `stock_movement_moved_by_fk`, `stock_movement_prescription_item_fk`, `stock_movement_prescription_item_uk`, `stock_movement_transfer_ref_uk`, `stock_movement_quantity_ck`, `stock_movement_prescription_tg`, `stock_movement_transfer_ref_tg`, `stock_movement_transfer_pair_tg` (checked at commit), `stock_movement_append_only_tg` | transfer_ref, prescription_id, note | R14, R15, R16 |
| lab_test | `lab_test_pk`, `lab_test_code_uk`, `lab_test_code_ck`, `lab_test_price_kobo_ck`, `lab_test_qualitative_ck`, `lab_test_reference_range_ck`, `lab_test_target_turnaround_ck` | unit, reference_low, reference_high | R17 |
| lab_order | `lab_order_pk`, `lab_order_encounter_fk`, `lab_order_lab_test_fk`, `lab_order_facility_fk`, `lab_order_ordered_by_fk`, `lab_order_encounter_test_uk`, `lab_order_facility_laboratory_tg` | — | R17 |
| lab_result | `lab_result_pk`, `lab_result_lab_order_fk`, `lab_result_recorded_by_fk`, `lab_result_supersedes_fk` (result and order together), `lab_result_id_order_uk`, `lab_result_supersedes_uk`, `lab_result_correction_ck`, `lab_result_value_ck`, `lab_result_order_original_uk` (unique index on originals), `lab_result_value_kind_tg`, `lab_result_after_order_tg`, `lab_result_append_only_tg` | value_numeric, value_text, supersedes_result_id, correction_reason | R17 |
| invoice | `invoice_pk`, `invoice_patient_fk`, `invoice_facility_fk`, `invoice_issued_by_fk`, `invoice_encounter_fk` (encounter and patient together), `invoice_no_uk`, `invoice_encounter_uk`, `invoice_no_ck`, `invoice_total_kobo_ck`, `invoice_total_tg` (checked at commit) | encounter_id | R18 |
| invoice_line | `invoice_line_pk`, `invoice_line_invoice_fk` (cascade), `invoice_line_drug_fk`, `invoice_line_lab_test_fk`, `invoice_line_item_ck`, `invoice_line_line_no_ck`, `invoice_line_quantity_ck`, `invoice_line_unit_price_kobo_ck`, `invoice_line_total_tg` (checked at commit) | drug_id, lab_test_id | R18 |
| payment | `payment_pk`, `payment_invoice_fk`, `payment_method_fk`, `payment_received_by_fk`, `payment_amount_kobo_ck`, `payment_outstanding_tg`, `payment_reference_tg`, `payment_append_only_tg` | reference | R18 |
| record_access_log | `record_access_log_pk`, `record_access_log_staff_fk`, `record_access_log_patient_fk`, `record_access_log_purpose_ck`, `record_access_log_append_only_tg` | — | R19 |
| pseudonym_key | `pseudonym_key_pk`, `pseudonym_key_single_row_ck` | — | N02 |

Several cross-table rules use a composite foreign key onto a second unique key rather than a trigger. `encounter (appointment_id, patient_id)` references `appointment (appointment_id, patient_id)`, so an encounter can only use an appointment of the same patient; the same pattern keeps an amendment within its encounter, a correction within its order and an invoice with the patient whose encounter it bills. The extra unique constraints that make this possible (`appointment_id_patient_uk` and its siblings) are superkeys, so they add no new rule of their own.

Defaults: `appointment_status_code` starts as `BOOKED`; `has_laboratory` and `on_call` default to true; `is_primary` defaults to false; `stock_on_hand.quantity` starts at 0; `record_access_log.db_user` defaults to `session_user`; every event timestamp (`booked_at`, `written_at`, `ordered_at`, `recorded_at`, `issued_at`, `moved_at`, `paid_at`, `accessed_at`, `registered_at`) defaults to `now()`.

`patient_date_of_birth_ck` compares with `CURRENT_DATE`. PostgreSQL expects check constraints to be immutable, but this one is safe: a date of birth that is not in the future today can never move into the future later.

## Catalogue summary

These counts are compared with the live database on every rebuild. UI counts unique indexes that do not back a constraint (the partial unique rules), and TG counts the triggers on each relation.

| Relation | Columns | PK | FK | UK | CK | EX | UI | TG |
|---|---|---|---|---|---|---|---|---|
| `appointment` | 11 | 1 | 5 | 2 | 1 | 2 | 0 | 1 |
| `appointment_status` | 2 | 1 | 0 | 0 | 1 | 0 | 0 | 0 |
| `appointment_status_history` | 5 | 1 | 3 | 0 | 0 | 0 | 0 | 1 |
| `clinical_note` | 7 | 1 | 3 | 1 | 2 | 0 | 0 | 1 |
| `clinician` | 2 | 1 | 1 | 1 | 1 | 0 | 0 | 1 |
| `clinician_department` | 3 | 1 | 2 | 0 | 0 | 0 | 0 | 0 |
| `consent` | 6 | 1 | 3 | 0 | 1 | 0 | 1 | 0 |
| `consent_purpose` | 2 | 1 | 0 | 0 | 1 | 0 | 0 | 0 |
| `department` | 3 | 1 | 0 | 2 | 1 | 0 | 0 | 0 |
| `diagnosis_code` | 3 | 1 | 0 | 0 | 1 | 0 | 0 | 0 |
| `drug` | 7 | 1 | 0 | 2 | 3 | 0 | 0 | 0 |
| `encounter` | 8 | 1 | 5 | 2 | 1 | 0 | 0 | 0 |
| `encounter_diagnosis` | 3 | 1 | 2 | 0 | 0 | 0 | 1 | 0 |
| `encounter_type` | 2 | 1 | 0 | 0 | 1 | 0 | 0 | 0 |
| `facility` | 7 | 1 | 0 | 1 | 1 | 0 | 0 | 0 |
| `invoice` | 8 | 1 | 4 | 2 | 2 | 0 | 0 | 1 |
| `invoice_line` | 8 | 1 | 3 | 0 | 4 | 0 | 0 | 1 |
| `lab_order` | 6 | 1 | 4 | 1 | 0 | 0 | 0 | 1 |
| `lab_result` | 8 | 1 | 3 | 2 | 2 | 0 | 1 | 2 |
| `lab_test` | 9 | 1 | 0 | 1 | 5 | 0 | 0 | 0 |
| `movement_type` | 5 | 1 | 0 | 0 | 2 | 0 | 0 | 0 |
| `next_of_kin` | 5 | 1 | 1 | 0 | 2 | 0 | 0 | 0 |
| `on_call_shift` | 5 | 1 | 2 | 1 | 0 | 0 | 0 | 0 |
| `patient` | 12 | 1 | 1 | 2 | 3 | 0 | 0 | 0 |
| `patient_allergy` | 4 | 1 | 1 | 0 | 1 | 0 | 0 | 0 |
| `patient_phone` | 3 | 1 | 1 | 0 | 1 | 0 | 1 | 0 |
| `payment` | 7 | 1 | 3 | 0 | 1 | 0 | 0 | 2 |
| `payment_method` | 3 | 1 | 0 | 0 | 1 | 0 | 0 | 0 |
| `prescription` | 4 | 1 | 2 | 0 | 0 | 0 | 0 | 0 |
| `prescription_item` | 4 | 1 | 2 | 0 | 1 | 0 | 0 | 0 |
| `pseudonym_key` | 2 | 1 | 0 | 0 | 1 | 0 | 0 | 0 |
| `record_access_log` | 6 | 1 | 2 | 0 | 1 | 0 | 0 | 1 |
| `staff` | 8 | 1 | 2 | 1 | 2 | 0 | 0 | 0 |
| `staff_role` | 3 | 1 | 0 | 0 | 1 | 0 | 0 | 0 |
| `stock_movement` | 10 | 1 | 5 | 2 | 1 | 0 | 0 | 3 |
| `stock_on_hand` | 4 | 1 | 2 | 0 | 1 | 0 | 0 | 1 |
| `vital_sign` | 11 | 1 | 2 | 0 | 7 | 0 | 0 | 0 |

In total: 37 primary keys, 64 foreign keys, 23 unique constraints, 54 check constraints, 2 exclusion constraints, 4 partial unique indexes and 16 triggers, three of them constraint triggers deferred to commit.

## Views

| View | For | What it shows |
|---|---|---|
| `patient_directory` | reception, billing, the clinic application, clinicians | Hospital number, name, date of birth, primary phone and registering branch; no clinical data |
| `deid_patient` | analysts | A pseudonymous patient key, age band, state, registering branch and month of registration |
| `deid_encounter` | analysts | The pseudonymous patient key, branch and state, month of visit, encounter type, age band at the visit and diagnosis codes |

The pseudonymous key is the first eight bytes of SHA-256 over a secret held in `pseudonym_key` and the patient's internal ID. Analysts can follow one patient across visits without being able to recompute the key, because neither they nor the auditors can read the secret. The secret is regenerated on every rebuild, so keys do not survive a rebuild.

The views run with their owner's rights, and the restricted roles have no access to the base tables at all. I chose this over `security_invoker` views, which run with the caller's rights and would only work if analysts could read the underlying tables, which is exactly what they must not do.

## Roles and privileges

All roles are `NOLOGIN` group roles. People and services would log in as their own login roles and be granted membership of one of these, so privileges are managed per job rather than per person.

| Role | Purpose | Granted |
|---|---|---|
| `itoju_owner` | Owns the schema and every object in it | everything, by ownership |
| `itoju_app` | The clinic and booking application | read code tables, facilities, staff, the patient directory and appointments; execute `register_patient`, `book_appointment`, `reschedule_appointment`, `cancel_appointment` |
| `itoju_reception` | Front-desk staff | as `itoju_app`, plus insert phones, next of kin and consent |
| `itoju_clinician` | Doctors and nurses | insert encounters, vital signs, diagnoses, notes, prescriptions, lab orders and allergies; read appointments and the patient directory; read their own new row IDs; update `encounter.ended_at`; execute `patient_record`, `sign_off_on_call` |
| `itoju_pharmacy` | Pharmacists | read prescriptions, stock and the ledger; execute `receive_stock`, `dispense_prescription_item`, `transfer_stock` |
| `itoju_lab` | Laboratory scientists | read lab orders and results; execute `record_lab_result` |
| `itoju_billing` | Billing officers | read and insert invoices, lines and payments; read the patient directory, prescription items and lab orders; use the invoice-number sequence |
| `itoju_analyst` | Analysts | read `deid_patient` and `deid_encounter` only |
| `itoju_auditor` | Internal audit | read every table and view except `pseudonym_key`; no writes |

`PUBLIC` loses `USAGE` on the schema and `EXECUTE` on every function. No role has `UPDATE` or `DELETE` on clinical, stock or financial tables. Clinicians cannot read clinical tables directly, so every look at a patient's history goes through `patient_record`, which logs it first.

## Routines

Every routine that changes data is `SECURITY DEFINER`, owned by `itoju_owner` and pinned to `search_path = itoju, pg_temp`, so a caller cannot redirect it to their own objects by creating look-alike tables.

| Routine | Operation | Rules it applies |
|---|---|---|
| `register_patient` | Issues the next hospital number, creates the patient and their primary phone in one statement | R01, R02 |
| `book_appointment` | Books a slot; a repeated `request_key` returns the original booking instead of a second one | R06, R07, R08 |
| `reschedule_appointment` | Moves a booked appointment (`appointment_reschedule_fn`) | R07, R08 |
| `cancel_appointment` | Cancels a booked or checked-in appointment and so frees the slot (`appointment_cancel_fn`) | R08, R09 |
| `receive_stock` | Records a delivery | R14 |
| `dispense_prescription_item` | Dispenses exactly the prescribed quantity | R14, R15 |
| `transfer_stock` | Writes both legs of a transfer, locking the two stock rows in facility order so opposite transfers cannot deadlock (`stock_transfer_facilities_fn`) | R14, R16 |
| `record_lab_result` | Records a result or a superseding correction | R17 |
| `patient_record` | Logs the access, then returns the patient's details, allergies and latest 20 encounters as JSON (`record_access_active_staff_fn`) | R19 |
| `sign_off_on_call` | Takes a clinician off call if a colleague remains (`on_call_minimum_fn`, `on_call_shift_fn`) | R20 |
| `age_band` | Derives an age band from a date of birth | N02 |

## Physical design

The only indexes are the ones that enforce keys, uniqueness and the exclusion constraints (two GiST indexes on clinician or patient plus slot, which need the `btree_gist` extension). I add indexes for the workload only after measuring the queries at realistic volume, in [Portfolio 2](../../portfolio-2-query-optimisation/README.md), where each index has to earn its storage and write cost.

The cached `stock_on_hand.quantity` and the stored invoice total and line prices are deliberate denormalisations; the reasons are in [normalisation](normalisation.md#deliberate-denormalisation).
