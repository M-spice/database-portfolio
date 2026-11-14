"""Generate the Chen-notation ER diagrams (DOT, SVG, PNG) for Itoju Clinics from one model definition."""

import os
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Attribute markers: _key, ~partial key (weak entity), +multi-valued, /derived, name(a,b) composite.
ENTITIES = {
    "Patient": dict(attrs=["_hospital_no", "full_name(given_name,middle_name,family_name)", "date_of_birth", "/age",
                           "national_id", "address(line,city,state)", "+phone", "+allergy", "registered_at"]),
    "NextOfKin": dict(weak=True, attrs=["~kin_no", "full_name", "relationship", "phone"]),
    "Consent": dict(attrs=["_consent_id", "purpose", "granted_at", "withdrawn_at"]),
    "Facility": dict(attrs=["_facility_code", "name", "city", "state", "has_laboratory", "opened_on"]),
    "Department": dict(attrs=["_department_code", "name"]),
    "Staff": dict(attrs=["_staff_no", "name(given_name,family_name)", "role", "employed_on", "left_on"]),
    "Clinician": dict(attrs=["_licence_no"]),
    "Appointment": dict(attrs=["_appointment_id", "slot(start,end)", "status", "booked_at", "request_key", "reason"]),
    "Encounter": dict(attrs=["_encounter_id", "type", "started_at", "ended_at", "/wait_time"]),
    "VitalSign": dict(attrs=["_vital_sign_id", "recorded_at", "temperature", "pulse",
                             "blood_pressure(systolic,diastolic)", "spo2", "weight", "height", "/bmi"]),
    "Diagnosis": dict(attrs=["_diagnosis_code", "description", "is_chronic"]),
    "ClinicalNote": dict(attrs=["_note_id", "written_at", "body", "amendment_reason"]),
    "Drug": dict(attrs=["_drug_code", "name", "form", "strength", "unit_price", "reorder_level"]),
    "Prescription": dict(attrs=["_prescription_id", "issued_at"]),
    "StockMovement": dict(attrs=["_movement_id", "type", "quantity", "moved_at", "transfer_ref", "note"]),
    "LabTest": dict(attrs=["_test_code", "name", "specimen", "unit", "reference_range(low,high)", "price",
                           "target_turnaround"]),
    "LabOrder": dict(attrs=["_lab_order_id", "ordered_at", "/turnaround"]),
    "LabResult": dict(attrs=["_lab_result_id", "value", "recorded_at", "correction_reason"]),
    "Invoice": dict(attrs=["_invoice_no", "issued_at", "total", "/balance"]),
    "InvoiceLine": dict(weak=True, attrs=["~line_no", "description", "quantity", "unit_price", "/amount"]),
    "Payment": dict(attrs=["_payment_id", "method", "amount", "paid_at", "reference"]),
}

# (name, [(entity, cardinality), ...], relationship attributes, identifying)
RELATIONSHIPS = [
    ("HAS_KIN", [("Patient", "1"), ("NextOfKin", "N")], [], True),
    ("GIVES", [("Patient", "1"), ("Consent", "N")], [], False),
    ("IS_A", [("Staff", "1"), ("Clinician", "1")], [], False),
    ("BASED_AT", [("Staff", "N"), ("Facility", "1")], [], False),
    ("WORKS_IN", [("Clinician", "M"), ("Department", "N")], ["assigned_on"], False),
    ("BOOKS", [("Patient", "1"), ("Appointment", "N")], [], False),
    ("WITH", [("Clinician", "1"), ("Appointment", "N")], [], False),
    ("IN", [("Department", "1"), ("Appointment", "N")], [], False),
    ("HELD_AT", [("Facility", "1"), ("Appointment", "N")], [], False),
    ("RESULTS_IN", [("Appointment", "1"), ("Encounter", "1")], [], False),
    ("ATTENDS", [("Patient", "1"), ("Encounter", "N")], [], False),
    ("CONDUCTS", [("Clinician", "1"), ("Encounter", "N")], [], False),
    ("HOSTS", [("Facility", "1"), ("Encounter", "N")], [], False),
    ("MEASURES", [("Encounter", "1"), ("VitalSign", "N")], [], False),
    ("DIAGNOSED_AS", [("Encounter", "M"), ("Diagnosis", "N")], ["is_primary"], False),
    ("DOCUMENTS", [("Encounter", "1"), ("ClinicalNote", "N")], [], False),
    ("AMENDS", [("ClinicalNote", "1"), ("ClinicalNote", "N")], [], False),
    ("ISSUES", [("Encounter", "1"), ("Prescription", "N")], [], False),
    ("PRESCRIBES", [("Prescription", "M"), ("Drug", "N")], ["quantity", "dosage"], False),
    ("STOCKS", [("Facility", "M"), ("Drug", "N")], ["quantity_on_hand"], False),
    ("MOVES", [("Drug", "1"), ("StockMovement", "N")], [], False),
    ("AT", [("Facility", "1"), ("StockMovement", "N")], [], False),
    ("FULFILS", [("Prescription", "1"), ("StockMovement", "N")], [], False),
    ("ORDERS", [("Encounter", "1"), ("LabOrder", "N")], [], False),
    ("OF_TEST", [("LabTest", "1"), ("LabOrder", "N")], [], False),
    ("PRODUCES", [("LabOrder", "1"), ("LabResult", "N")], [], False),
    ("SUPERSEDES", [("LabResult", "1"), ("LabResult", "1")], [], False),
    ("BILLED_TO", [("Patient", "1"), ("Invoice", "N")], [], False),
    ("BILLS", [("Encounter", "1"), ("Invoice", "1")], [], False),
    ("CONTAINS", [("Invoice", "1"), ("InvoiceLine", "N")], [], True),
    ("SETTLED_BY", [("Invoice", "1"), ("Payment", "N")], [], False),
    ("ACCESSES", [("Staff", "M"), ("Patient", "N")], ["accessed_at", "purpose", "db_user"], False),
    ("ON_CALL", [("Clinician", "M"), ("Facility", "N")], ["shift_date", "on_call"], False),
]

VIEWS = {
    "er-overview": dict(title="Itoju Clinics: entities and relationships", entities=list(ENTITIES), attrs=False),
    "er-patient-care": dict(title="Patients, staff and care",
                            entities=["Patient", "NextOfKin", "Consent", "Staff", "Clinician", "Department",
                                      "Facility", "Appointment", "Encounter", "VitalSign", "Diagnosis",
                                      "ClinicalNote"], attrs=True),
    "er-pharmacy-lab": dict(title="Pharmacy, stock and laboratory",
                            entities=["Encounter", "Prescription", "Drug", "Facility", "StockMovement",
                                      "LabTest", "LabOrder", "LabResult"], attrs=True),
    "er-billing-audit": dict(title="Billing, record access and on-call rota",
                             entities=["Patient", "Encounter", "Invoice", "InvoiceLine", "Payment", "Staff",
                                       "Clinician", "Facility"], attrs=True),
}


def attribute_nodes(owner, spec, counter):
    nodes, edges = [], []
    kind = spec[0] if spec[0] in "_~+/" else ""
    text = spec[1:] if kind else spec
    name, _, parts = text.partition("(")
    node = f"a{next(counter)}"
    label = f"<<u>{name}</u>>" if kind in ("_", "~") else f'"{name}"'
    style = {"+": "peripheries=2", "/": "style=dashed"}.get(kind, "")
    nodes.append(f'  {node} [shape=ellipse, label={label} {style}];')
    edges.append(f"  {owner} -- {node};")
    for part in filter(None, parts.rstrip(")").split(",")):
        sub = f"a{next(counter)}"
        nodes.append(f'  {sub} [shape=ellipse, label="{part}"];')
        edges.append(f"  {node} -- {sub};")
    return nodes, edges


def build(view):
    from itertools import count
    counter = count()
    spec = VIEWS[view]
    included = set(spec["entities"])
    lines = [
        "graph ER {",
        f'  graph [layout=neato, overlap=false, splines=true, sep="+12", fontname="Helvetica", '
        f'label="{spec["title"]}", labelloc=t, fontsize=20];',
        '  node [fontname="Helvetica", fontsize=11];',
        '  edge [fontname="Helvetica", fontsize=11, len=1.6];',
    ]
    for name in spec["entities"]:
        weak = ENTITIES[name].get("weak")
        lines.append(f'  {name} [shape=box, style=filled, fillcolor="#e8eef7"{", peripheries=2" if weak else ""}];')
        if spec["attrs"]:
            for attr in ENTITIES[name]["attrs"]:
                nodes, edges = attribute_nodes(name, attr, counter)
                lines += nodes + edges
    for rel, ends, rel_attrs, identifying in RELATIONSHIPS:
        if not all(e in included for e, _ in ends):
            continue
        rid = f"r_{rel}"
        lines.append(f'  {rid} [shape=diamond, label="{rel}", style=filled, fillcolor="#fdf1d8"'
                     f'{", peripheries=2" if identifying else ""}];')
        for entity, card in ends:
            lines.append(f'  {entity} -- {rid} [taillabel="{card}", labeldistance=1.6, labelangle=25];')
        if spec["attrs"]:
            for attr in rel_attrs:
                nodes, edges = attribute_nodes(rid, attr, counter)
                lines += nodes + edges
    lines.append("}")
    return "\n".join(lines) + "\n"


def dot_binary():
    found = shutil.which("dot") or os.environ.get("GRAPHVIZ_DOT")
    if found:
        return found
    fallback = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Graphviz" / "bin" / "dot.exe"
    if fallback.exists():
        return str(fallback)
    raise SystemExit("Graphviz dot not found; install Graphviz or set GRAPHVIZ_DOT")


def main():
    dot = dot_binary()
    for view in VIEWS:
        source = HERE / f"{view}.dot"
        source.write_text(build(view), encoding="utf-8", newline="\n")
        svg = HERE / f"{view}.svg"
        subprocess.run([dot, "-Tsvg", str(source), "-o", str(svg)], check=True)
        svg.write_bytes(svg.read_bytes().replace(b"\r\n", b"\n"))
        subprocess.run([dot, "-Tpng", "-Gdpi=110", str(source), "-o", str(HERE / f"{view}.png")], check=True)
        print(f"rendered {view}.dot -> .svg, .png")


if __name__ == "__main__":
    main()
