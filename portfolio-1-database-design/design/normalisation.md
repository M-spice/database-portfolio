# Normalisation

Before the database existed, each branch kept a printed clinic visit report: one line per visit showing the patient, their phone numbers, the clinic, the clinician, the diagnoses and the medicines prescribed with their prices. It is the natural starting point for the design, and it shows clearly why that layout cannot be the database. I normalised it step by step to BCNF, naming the dependency removed at each step, and then proved on real rows that the decomposition loses nothing. The proof runs on every rebuild ([`tests/t_normalisation.sql`](../tests/t_normalisation.sql)); its output is in [`outputs/p1-normalisation.txt`](../outputs/p1-normalisation.txt).

## The unnormalised report

The report below is built from the sample data; the first three of its seven visits are shown.

| visit_no | visit_date | hospital_no | patient_name | date_of_birth | phones | facility_code | facility_name | facility_city | clinician_no | clinician_name | diagnoses | drugs |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2026-10-05 | HN-0000001 | Oluwaseun Bankole | 1978-04-12 | +2340001000001, +2340001000101 | LAG-IKJ | Itoju Clinics Ikeja | Lagos | ST-00001 | Adaeze Okafor | B54 Malaria, uncomplicated | DRG-0001 Artemether-lumefantrine x24 @ 15000; DRG-0002 Paracetamol x18 @ 2000 |
| 2 | 2026-10-12 | HN-0000004 | Tolulope Adeniran | 2019-06-01 | +2340001000004 | LAG-LEK | Itoju Clinics Lekki | Lagos | ST-00003 | Chiamaka Eze | J06.9 Acute upper respiratory infection | DRG-0002 Paracetamol x10 @ 2000 |
| 3 | 2026-10-20 | HN-0000003 | Amina Garba | 1985-02-14 | +2340001000003 | KAN-NAS | Itoju Clinics Nassarawa | Kano | ST-00004 | Ibrahim Musa | E11.9 Type 2 diabetes mellitus; I10 Essential hypertension | DRG-0004 Amlodipine x30 @ 5000; DRG-0005 Metformin x60 @ 4000 |

Phones, diagnoses and drugs are repeating groups: a cell holds a list rather than one value. That alone puts the report outside the relational model, but even with atomic cells it would suffer all three anomalies:

- **Insertion.** A new branch, or a drug that has never been prescribed, cannot be recorded until a visit mentions it. Surulere and Ibuprofen exist in the organisation but appear in no visit.
- **Update.** A price change for paracetamol must be made on every visit that prescribed it; in the sample that is three rows, at network volume it would be hundreds of thousands, and missing one leaves two prices for the same drug.
- **Deletion.** Visit 2 is the only visit at Lekki, the only one with Dr Chiamaka Eze and the only one diagnosing J06.9. Deleting it would also delete the fact that the Lekki branch exists, the clinician's name and the meaning of the code.

## Functional dependencies

I identified these from how the organisation works, then tested each one against the data; none is violated ([evidence](../outputs/p1-normalisation.txt)).

| | Dependency | Why it holds |
|---|---|---|
| FD1 | visit_no → visit_date, hospital_no, facility_code, clinician_no | A visit happens once, for one patient, at one branch, with one clinician |
| FD2 | hospital_no → patient_name, date_of_birth | The hospital number identifies the patient |
| FD3 | facility_code → facility_name, facility_city | The code identifies the branch |
| FD4 | clinician_no → clinician_name | The staff number identifies the clinician |
| FD5 | diagnosis_code → diagnosis_description | The catalogue defines each code once |
| FD6 | drug_code → drug_name, unit_price_kobo | The catalogue defines each drug and its current price |
| FD7 | visit_no, drug_code → quantity | A drug is prescribed once per visit, in one quantity |
| MV1 | hospital_no →→ phone_no | A patient has a set of phones, independent of any visit |

## First normal form

1NF requires every value to be atomic. I removed each repeating group into its own relation together with the key of the thing it describes: diagnoses and drugs describe the visit, so they take `visit_no`; phones describe the patient, not the visit, so they take `hospital_no`. Putting phones under the visit would repeat every patient's phones once per visit.

- VISIT (<ins>visit_no</ins>, visit_date, hospital_no, patient_name, date_of_birth, facility_code, facility_name, facility_city, clinician_no, clinician_name)
- PATIENT_PHONE (<ins>hospital_no, phone_no</ins>)
- VISIT_DIAGNOSIS (<ins>visit_no, diagnosis_code</ins>, diagnosis_description)
- VISIT_DRUG (<ins>visit_no, drug_code</ins>, drug_name, unit_price_kobo, quantity)

The test splits the report itself, not the base tables, and gets 7 visit rows, 8 phone rows, 8 diagnosis rows and 9 drug rows.

## Second normal form

2NF removes partial dependencies: a non-key attribute that depends on only part of a composite key. VISIT has a single-attribute key and PATIENT_PHONE has no non-key attributes, so both are already in 2NF. The two relations with composite keys are not:

- In VISIT_DIAGNOSIS, `diagnosis_description` depends on `diagnosis_code` alone (FD5). It moves to DIAGNOSIS (<ins>diagnosis_code</ins>, diagnosis_description), leaving VISIT_DIAGNOSIS (<ins>visit_no, diagnosis_code</ins>).
- In VISIT_DRUG, `drug_name` and `unit_price_kobo` depend on `drug_code` alone (FD6). They move to DRUG (<ins>drug_code</ins>, drug_name, unit_price_kobo), leaving VISIT_DRUG (<ins>visit_no, drug_code</ins>, quantity), where `quantity` depends on the whole key (FD7).

This step removes the paracetamol update anomaly: the price is now stored once.

## Third normal form

3NF removes transitive dependencies: a non-key attribute that depends on another non-key attribute. VISIT has three:

- visit_no → hospital_no → patient_name, date_of_birth (FD1, FD2)
- visit_no → facility_code → facility_name, facility_city (FD1, FD3)
- visit_no → clinician_no → clinician_name (FD1, FD4)

Each determinant becomes the key of its own relation: PATIENT (<ins>hospital_no</ins>, patient_name, date_of_birth), FACILITY (<ins>facility_code</ins>, facility_name, facility_city) and CLINICIAN (<ins>clinician_no</ins>, clinician_name). VISIT keeps the determinants as foreign keys: VISIT (<ins>visit_no</ins>, visit_date, hospital_no, facility_code, clinician_no).

This removes the insertion and deletion anomalies: Lekki, Dr Eze and J06.9 now exist independently of any visit. In the sample, the redundancy removed is small but visible: the 1NF relations stored 7 copies of 5 facility names, 7 copies of 5 clinician names, 9 copies of 6 drug names and prices and 8 copies of 7 diagnosis descriptions.

## Boyce–Codd normal form

BCNF requires every determinant to be a candidate key. In the final relations, the only non-trivial dependencies are from each relation's key:

| Relation | Key | Determinants | BCNF |
|---|---|---|---|
| PATIENT | hospital_no | hospital_no | yes |
| PATIENT_PHONE | hospital_no, phone_no | none (all-key) | yes |
| FACILITY | facility_code | facility_code | yes |
| CLINICIAN | clinician_no | clinician_no | yes |
| VISIT | visit_no | visit_no | yes |
| DIAGNOSIS | diagnosis_code | diagnosis_code | yes |
| VISIT_DIAGNOSIS | visit_no, diagnosis_code | none (all-key) | yes |
| DRUG | drug_code | drug_code | yes |
| VISIT_DRUG | visit_no, drug_code | visit_no, drug_code | yes |

The test confirms each key holds in the data: no relation has a duplicate key value.

In the full schema most relations have more than one candidate key: a surrogate key and a natural key (`patient_id` and `hospital_no`, `facility_id` and `facility_code`), and `drug` has a third, (`name`, `form`, `strength`). Each of them determines the whole row, so overlapping keys do not break BCNF here. A 3NF relation fails BCNF only when an attribute set that is not a candidate key determines part of a key, and none of these relations has such a dependency.

Addresses need a word. In real addresses a city usually implies a state, which would be a transitive dependency inside `patient` and `facility`. I record an address as a composite attribute of the patient, exactly as given, rather than deriving the state from a list of places, because place names are not guaranteed to be unique across states and a person's address is a fact to record, not a rule to enforce.

## Lossless decomposition

Every split above divides a relation on an attribute that is the key of one of the two parts (for example, VISIT and FACILITY share `facility_code`, the key of FACILITY). By Heath's theorem, such a decomposition is lossless: the natural join of the parts gives back exactly the original rows, with no spurious tuples (Silberschatz et al., 2020; Elmasri & Navathe, 2016). Every functional dependency also sits inside a single relation, so all of them are preserved and each can be enforced by a key.

I checked this on the data rather than relying on the theorem alone:

| Join tested | Rows before | Rows after | Rows differing | Result |
|---|---|---|---|---|
| VISIT ⋈ PATIENT ⋈ FACILITY ⋈ CLINICIAN = 1NF VISIT | 7 | 7 | 0 | lossless |
| VISIT_DIAGNOSIS ⋈ DIAGNOSIS = 1NF VISIT_DIAGNOSIS | 8 | 8 | 0 | lossless |
| VISIT_DRUG ⋈ DRUG = 1NF VISIT_DRUG | 9 | 9 | 0 | lossless |
| All BCNF relations rebuild the original report | 7 | 7 | 0 | lossless |

The comparison uses `EXCEPT ALL` in both directions, so duplicates as well as differences would be caught.

## From the decomposition to the implemented schema

The BCNF relations map onto the tables in the [relational schema](relational-schema.md): VISIT is `encounter`, PATIENT is `patient`, FACILITY is `facility`, CLINICIAN is `clinician` with `staff`, DIAGNOSIS is `diagnosis_code`, VISIT_DIAGNOSIS is `encounter_diagnosis`, DRUG is `drug`, VISIT_DRUG is `prescription_item` (with `prescription` grouping the items of one encounter) and PATIENT_PHONE is `patient_phone`. The full schema adds the entities the report never showed, such as appointments, stock, laboratory work and billing, and normalises them in the same way. Surrogate keys replace the natural keys as the primary keys, and the natural keys stay unique, so every dependency above still has a key behind it.

<a id="deliberate-denormalisation"></a>
## Deliberate denormalisation

Normalisation removes redundancy, but it is not free: every split adds a join, and some facts are read far more often than they change. I kept four controlled redundancies, each guarded so that it cannot drift from the facts it summarises.

1. **Stock on hand.** `stock_on_hand.quantity` is the sum of the movement ledger for that branch and drug, stored. Every dispense has to check the current level, and the reorder report needs every level at once; summing the ledger each time would mean reading every movement ever recorded. The ledger stays the source of truth: the cached quantity changes only through the trigger that applies each movement (`stock_movement_apply_tg`), a guard trigger refuses any direct change (`stock_on_hand_ledger_only_tg`), a check keeps it non-negative, and the consistency check reconciles the two after every build (73 stock lines, 0 differences).
2. **The price on an invoice line.** `invoice_line.unit_price_kobo` looks like a copy of `drug.unit_price_kobo`, but it is a different fact: the price charged on that day, determined by the invoice line, not by the drug. If the line only referenced the drug, a price rise next month would silently change every past invoice. Storing it keeps history true.
3. **The invoice total.** `invoice.total_kobo` is the amount on the issued bill, the figure payments are matched against. A deferred constraint trigger (`invoice_total_tg`) checks at commit that it equals the sum of the lines, so a transaction can build the invoice and its lines in any order but cannot commit them disagreeing.
4. **The patient on encounters and invoices.** When an encounter comes from an appointment, its `patient_id` repeats the appointment's. Walk-in encounters have no appointment, so the patient has to be on the encounter, and the composite foreign key `encounter_appointment_fk` makes the two agree whenever both exist. Invoices repeat the encounter's patient in the same way, guarded by `invoice_encounter_fk`.

`invoice_line.amount_kobo` is also derived, as quantity times unit price, but it is a generated column computed by PostgreSQL, so it carries no update anomaly. Portfolio 2 measures what the stock cache saves against summing the ledger at network volume.
