"""
Credit Risk - Synthetic Data Generator
Generates realistic (anonymized) seed data for local dbt development.
"""

import csv
import random
import uuid
from datetime import date, timedelta
from pathlib import Path

random.seed(42)

SEEDS_DIR = Path(__file__).parent.parent / "seeds"
SEEDS_DIR.mkdir(exist_ok=True)

#  helpers 

def rand_date(start: date, end: date) -> date:
    delta = (end - start).days
    return start + timedelta(days=random.randint(0, delta))

def rand_id(prefix: str = "") -> str:
    return f"{prefix}{uuid.uuid4().hex[:12].upper()}"

PROVINCES = ["ON", "BC", "AB", "QC", "MB", "SK", "NS", "NB", "NL", "PE"]
PRODUCTS   = ["CREDIT_BUILDING", "CREDIT_LINE", "PREPAID_SECURED"]
STATUSES   = ["current", "delinquent_30", "delinquent_60", "delinquent_90", "charged_off", "closed"]
STATUS_WEIGHTS = [0.72, 0.10, 0.07, 0.05, 0.04, 0.02]

#  1. borrowers 

def gen_borrowers(n: int = 500) -> list[dict]:
    rows = []
    for _ in range(n):
        province = random.choice(PROVINCES)
        onboarded = rand_date(date(2022, 1, 1), date(2024, 6, 1))
        rows.append({
            "borrower_id":       rand_id("BRW"),
            "province_code":     province,
            "onboarded_at":      onboarded.isoformat(),
            "credit_score_band": random.choices(
                ["poor", "fair", "good", "very_good", "excellent"],
                weights=[0.10, 0.20, 0.35, 0.25, 0.10]
            )[0],
            "is_active":         random.choices([True, False], weights=[0.88, 0.12])[0],
        })
    return rows

#  2. accounts 

def gen_accounts(borrowers: list[dict]) -> list[dict]:
    rows = []
    for b in borrowers:
        num_accounts = random.choices([1, 2], weights=[0.80, 0.20])[0]
        onboarded = date.fromisoformat(b["onboarded_at"])
        for _ in range(num_accounts):
            opened = rand_date(onboarded, onboarded + timedelta(days=60))
            credit_limit = random.choice([500, 1000, 1500, 2000, 3000, 5000])
            status = random.choices(STATUSES, weights=STATUS_WEIGHTS)[0]
            closed_at = None
            if status in ("charged_off", "closed"):
                closed_at = rand_date(opened + timedelta(days=90), date(2025, 1, 1)).isoformat()
            rows.append({
                "account_id":       rand_id("ACC"),
                "borrower_id":      b["borrower_id"],
                "product_type":     random.choice(PRODUCTS),
                "opened_at":        opened.isoformat(),
                "closed_at":        closed_at or "",
                "credit_limit_cad": credit_limit,
                "account_status":   status,
                "cycle_due_day":    random.randint(1, 28),
            })
    return rows

#  3. monthly_balances 

def gen_monthly_balances(accounts: list[dict]) -> list[dict]:
    rows = []
    for acc in accounts:
        opened = date.fromisoformat(acc["opened_at"])
        limit  = acc["credit_limit_cad"]
        balance = round(random.uniform(0.05, 0.80) * limit, 2)
        # generate up to 18 monthly snapshots
        snap_date = date(opened.year, opened.month, 1)
        end_date  = date(2025, 4, 1)
        while snap_date <= end_date:
            utilization = round(balance / limit, 4)
            min_payment  = round(max(25, balance * 0.03), 2)
            paid_amount  = 0.0
            if acc["account_status"] == "current":
                paid_amount = round(random.uniform(min_payment, balance), 2)
            elif acc["account_status"].startswith("delinquent"):
                paid_amount = round(random.uniform(0, min_payment * 0.5), 2)
            rows.append({
                "balance_id":          rand_id("BAL"),
                "account_id":          acc["account_id"],
                "snapshot_month":      snap_date.isoformat(),
                "statement_balance_cad": round(balance, 2),
                "credit_limit_cad":    limit,
                "utilization_rate":    utilization,
                "minimum_payment_cad": min_payment,
                "amount_paid_cad":     paid_amount,
                "days_past_due":       max(0, round(random.gauss(
                    {"current": 0, "delinquent_30": 35, "delinquent_60": 65,
                     "delinquent_90": 95, "charged_off": 200, "closed": 0}
                    .get(acc["account_status"], 0), 5))),
            })
            # drift balance
            balance = min(limit, max(0, balance + round(random.uniform(-200, 300), 2)))
            # advance month
            month = snap_date.month + 1
            year  = snap_date.year + (1 if month > 12 else 0)
            snap_date = date(year, month % 12 or 12, 1)
    return rows

#  4. payments 

def gen_payments(accounts: list[dict]) -> list[dict]:
    rows = []
    for acc in accounts:
        opened = date.fromisoformat(acc["opened_at"])
        n_payments = random.randint(2, 24) if acc["account_status"] == "current" else random.randint(0, 8)
        for _ in range(n_payments):
            pay_date = rand_date(opened, date(2025, 3, 31))
            rows.append({
                "payment_id":      rand_id("PAY"),
                "account_id":      acc["account_id"],
                "payment_date":    pay_date.isoformat(),
                "payment_amount_cad": round(random.uniform(25, 500), 2),
                "payment_method":  random.choice(["eft", "interac", "pad", "manual"]),
                "payment_status":  random.choices(
                    ["settled", "returned", "pending"],
                    weights=[0.88, 0.07, 0.05]
                )[0],
            })
    return rows

#  5. risk_bands seed 

RISK_BANDS = [
    {"band_id": 1, "band_name": "poor",      "min_score": 300, "max_score": 559, "risk_label": "high"},
    {"band_id": 2, "band_name": "fair",      "min_score": 560, "max_score": 659, "risk_label": "medium_high"},
    {"band_id": 3, "band_name": "good",      "min_score": 660, "max_score": 724, "risk_label": "medium"},
    {"band_id": 4, "band_name": "very_good", "min_score": 725, "max_score": 759, "risk_label": "low_medium"},
    {"band_id": 5, "band_name": "excellent", "min_score": 760, "max_score": 900, "risk_label": "low"},
]

#  write CSVs 

def write_csv(name: str, rows: list[dict]):
    path = SEEDS_DIR / f"{name}.csv"
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    print(f"  wrote: {path.name}  ({len(rows):,} rows)")

if __name__ == "__main__":
    print("Generating synthetic credit data...")
    borrowers = gen_borrowers(500)
    accounts  = gen_accounts(borrowers)
    balances  = gen_monthly_balances(accounts)
    payments  = gen_payments(accounts)

    write_csv("raw_borrowers",       borrowers)
    write_csv("raw_accounts",        accounts)
    write_csv("raw_monthly_balances", balances)
    write_csv("raw_payments",        payments)
    write_csv("risk_bands",          RISK_BANDS)

    print(f"\nDone. {len(borrowers)} borrowers, {len(accounts)} accounts, "
          f"{len(balances):,} balance snapshots, {len(payments):,} payments")
