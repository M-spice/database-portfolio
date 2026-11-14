"""Multi-document transactions: atomic dispense-and-invoice, abort, the same failure without a transaction, write conflicts."""

import threading
import time
from datetime import datetime, timezone

from pymongo.errors import OperationFailure, WriteError
from pymongo.read_concern import ReadConcern
from pymongo.write_concern import WriteConcern

from common import check, log, mongo, section, summary

ITEM = "LAG-IKJ|DRG-0002"
PRICE = 2000
TXN = {"read_concern": ReadConcern("snapshot"), "write_concern": WriteConcern("majority")}


class NotEnoughStock(Exception):
    pass


def next_invoice_no(db):
    last = db.invoices.find_one({"invoice_no": {"$regex": "^INV-9"}}, sort=[("invoice_no", -1)])
    return f"INV-{(int(last['invoice_no'][4:]) + 1) if last else 90000001:08d}"


def invoice(db, quantity):
    number = next_invoice_no(db)
    return {"_id": int(number[4:]) + 10_000_000, "invoice_no": number, "patient_id": 2, "facility": "LAG-IKJ",
            "encounter_id": None, "issued_at": datetime.now(timezone.utc), "issued_by": "ST-00019",
            "total_kobo": quantity * PRICE,
            "lines": [{"line_no": 1, "description": "Paracetamol 500 mg tablet", "drug_code": "DRG-0002",
                       "quantity": quantity, "unit_price_kobo": PRICE, "amount_kobo": quantity * PRICE}],
            "payments": []}


def dispense_and_invoice(db, session, quantity, invoice_first=False):
    doc = invoice(db, quantity)
    if invoice_first:
        db.invoices.insert_one(doc, session=session)
        log("A", f"inserted {doc['invoice_no']} for {quantity} tablets")
    result = db.stock.update_one({"_id": ITEM, "quantity": {"$gte": quantity}},
                                 {"$inc": {"quantity": -quantity}, "$set": {"updated_at": datetime.now(timezone.utc)}},
                                 session=session)
    if result.modified_count != 1:
        log("A", f"stock update matched no document: fewer than {quantity} tablets on the shelf")
        raise NotEnoughStock(quantity)
    log("A", f"took {quantity} tablets off {ITEM}")
    if not invoice_first:
        db.invoices.insert_one(doc, session=session)
        log("A", f"inserted {doc['invoice_no']} for {quantity} tablets")
    return doc


def stock(db):
    return db.stock.find_one({"_id": ITEM})["quantity"]


def main():
    client = mongo()
    db = client.itoju

    section("1. Dispense and invoice in one transaction")
    before, invoices_before = stock(db), db.invoices.count_documents({})
    with client.start_session() as s:
        s.start_transaction(**TXN)
        doc = dispense_and_invoice(db, s, 12)
        s.commit_transaction()
        log("A", "commitTransaction")
    check("stock fell by 12 and the invoice exists, together",
          stock(db) == before - 12 and db.invoices.count_documents({"_id": doc["_id"]}) == 1,
          f"stock {before} -> {stock(db)}")

    section("2. A dispense larger than the shelf: the transaction aborts and nothing is kept")
    before, invoices_before = stock(db), db.invoices.count_documents({})
    with client.start_session() as s:
        s.start_transaction(**TXN)
        try:
            dispense_and_invoice(db, s, before + 1, invoice_first=True)
            s.commit_transaction()
        except NotEnoughStock:
            s.abort_transaction()
            log("A", "abortTransaction")
    check("the invoice written earlier in the transaction is gone", db.invoices.count_documents({}) == invoices_before)
    check("stock is unchanged", stock(db) == before, f"{stock(db)}")

    section("3. The same failure without a transaction leaves the data inconsistent")
    before = stock(db)
    doc = invoice(db, before + 1)
    db.invoices.insert_one(doc)
    log("A", f"inserted {doc['invoice_no']} for {before + 1} tablets (no transaction: committed at once)")
    try:
        db.stock.update_one({"_id": ITEM}, {"$inc": {"quantity": -(before + 1)}})
        refused = False
    except WriteError as exc:
        log("A", f"stock update refused by the validator (code {exc.code}): the shelf cannot go negative")
        refused = True
    orphan = db.invoices.count_documents({"_id": doc["_id"]})
    check("without a transaction the invoice survives although nothing was dispensed",
          refused and orphan == 1 and stock(db) == before, f"{doc['invoice_no']} billed {before + 1} tablets never dispensed")
    db.invoices.delete_one({"_id": doc["_id"]})
    log("sys", f"removed {doc['invoice_no']} by hand to restore consistency")

    section("4. Two transactions write the same stock document: MongoDB fails the second at once")
    before = stock(db)
    a, b = client.start_session(), client.start_session()
    a.start_transaction(**TXN)
    db.stock.update_one({"_id": ITEM}, {"$inc": {"quantity": -1}}, session=a)
    log("A", "took 1 tablet (transaction open)")
    b.start_transaction(**TXN)
    t0 = time.perf_counter()
    try:
        db.stock.update_one({"_id": ITEM}, {"$inc": {"quantity": -1}}, session=b)
        conflict = None
    except OperationFailure as exc:
        conflict = exc
        log("B", f"{exc.details.get('codeName')} after {(time.perf_counter() - t0) * 1000:.0f} ms; "
                 f"labels {sorted(exc.details.get('errorLabels', []))}")
    b.abort_transaction()
    a.commit_transaction()
    log("A", "commitTransaction")
    check("the second writer fails immediately with WriteConflict instead of waiting",
          conflict is not None and conflict.details.get("codeName") == "WriteConflict"
          and "TransientTransactionError" in conflict.details.get("errorLabels", []))
    check("only the first transaction's change is kept", stock(db) == before - 1)

    section("5. with_transaction retries a transient conflict until it succeeds")
    before = stock(db)
    attempts = []
    a.start_transaction(**TXN)
    db.stock.update_one({"_id": ITEM}, {"$inc": {"quantity": -1}}, session=a)
    log("A", "took 1 tablet and holds the transaction open for 0.5 s")

    def callback(session):
        attempts.append(time.perf_counter())
        db.stock.update_one({"_id": ITEM}, {"$inc": {"quantity": -1}}, session=session)

    def worker():
        b.with_transaction(callback, **TXN)
        log("B", f"with_transaction succeeded after {len(attempts)} attempts")

    thread = threading.Thread(target=worker)
    thread.start()
    time.sleep(0.5)
    a.commit_transaction()
    log("A", "commitTransaction")
    thread.join()
    a.end_session(), b.end_session()
    check("the callback was retried after the conflict", len(attempts) > 1, f"{len(attempts)} attempts")
    check("both tablets were taken, once each", stock(db) == before - 2, f"stock {before} -> {stock(db)}")
    summary()


if __name__ == "__main__":
    main()
