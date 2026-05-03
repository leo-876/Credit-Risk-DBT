"""
Run a simplified version of the dbt pipeline in DuckDB directly,
then output JSON data for the dashboard.
"""

import json
import duckdb
import csv
from pathlib import Path

SEEDS = Path("seeds")
con = duckdb.connect(":memory:")

def load_csv(table, path):
    con.execute(f"CREATE TABLE {table} AS SELECT * FROM read_csv_auto('{path}')")

# Load seeds
load_csv("raw_borrowers",        SEEDS/"raw_borrowers.csv")
load_csv("raw_accounts",         SEEDS/"raw_accounts.csv")
load_csv("raw_monthly_balances", SEEDS/"raw_monthly_balances.csv")
load_csv("raw_payments",         SEEDS/"raw_payments.csv")
load_csv("risk_bands",           SEEDS/"risk_bands.csv")

#  staging 

con.execute("""
CREATE VIEW stg_borrowers AS
SELECT
    borrower_id,
    UPPER(province_code) AS province_code,
    CAST(onboarded_at AS DATE) AS onboarded_at,
    LOWER(credit_score_band) AS credit_score_band,
    CAST(is_active AS BOOLEAN) AS is_active,
    CASE WHEN datediff('day', CAST(onboarded_at AS DATE), CURRENT_DATE) < 90
         THEN TRUE ELSE FALSE END AS is_thin_file
FROM raw_borrowers WHERE borrower_id IS NOT NULL
""")

con.execute("""
CREATE VIEW stg_accounts AS
SELECT
    account_id, borrower_id, UPPER(product_type) AS product_type,
    CAST(opened_at AS DATE) AS opened_at,
    CASE WHEN NULLIF(CAST(closed_at AS VARCHAR), '') IS NOT NULL
         THEN CAST(closed_at AS DATE) ELSE NULL END AS closed_at,
    CAST(credit_limit_cad AS DECIMAL(12,2)) AS credit_limit_cad,
    LOWER(account_status) AS account_status,
    CAST(cycle_due_day AS INTEGER) AS cycle_due_day,
    CASE account_status
        WHEN 'current' THEN 0 WHEN 'delinquent_30' THEN 1
        WHEN 'delinquent_60' THEN 2 WHEN 'delinquent_90' THEN 3
        WHEN 'charged_off' THEN 4 WHEN 'closed' THEN -1 ELSE -99
    END AS delinquency_bucket,
    account_status IN ('delinquent_30','delinquent_60','delinquent_90','charged_off') AS is_delinquent,
    account_status = 'charged_off' AS is_charged_off
FROM raw_accounts WHERE account_id IS NOT NULL AND borrower_id IS NOT NULL
""")

con.execute("""
CREATE VIEW stg_monthly_balances AS
SELECT
    balance_id, account_id,
    CAST(snapshot_month AS DATE) AS snapshot_month,
    CAST(statement_balance_cad AS DECIMAL(12,2)) AS statement_balance_cad,
    CAST(credit_limit_cad AS DECIMAL(12,2)) AS credit_limit_cad,
    CAST(utilization_rate AS DECIMAL(6,4)) AS utilization_rate,
    CAST(minimum_payment_cad AS DECIMAL(12,2)) AS minimum_payment_cad,
    CAST(amount_paid_cad AS DECIMAL(12,2)) AS amount_paid_cad,
    CAST(days_past_due AS INTEGER) AS days_past_due,
    amount_paid_cad >= minimum_payment_cad AS paid_at_least_minimum,
    amount_paid_cad >= statement_balance_cad AS paid_in_full,
    amount_paid_cad = 0 AS made_no_payment,
    CASE
        WHEN days_past_due = 0 THEN 'current'
        WHEN days_past_due BETWEEN 1 AND 30 THEN 'dpd_1_30'
        WHEN days_past_due BETWEEN 31 AND 60 THEN 'dpd_31_60'
        WHEN days_past_due BETWEEN 61 AND 90 THEN 'dpd_61_90'
        WHEN days_past_due BETWEEN 91 AND 180 THEN 'dpd_91_180'
        WHEN days_past_due > 180 THEN 'charge_off'
        ELSE 'unknown'
    END AS dpd_bucket
FROM raw_monthly_balances
""")

con.execute("""
CREATE VIEW stg_payments AS
SELECT
    payment_id, account_id,
    CAST(payment_date AS DATE) AS payment_date,
    CAST(payment_amount_cad AS DECIMAL(12,2)) AS payment_amount_cad,
    LOWER(payment_method) AS payment_method,
    LOWER(payment_status) AS payment_status,
    payment_status = 'settled' AS is_settled,
    payment_status = 'returned' AS is_returned,
    payment_status = 'returned' AND payment_method = 'eft' AS is_nsf_return,
    date_trunc('month', CAST(payment_date AS DATE)) AS payment_month
FROM raw_payments WHERE payment_id IS NOT NULL
""")

#  portfolio risk summary 
print("Building portfolio risk summary...")

portfolio = con.execute("""
SELECT
    strftime(b.snapshot_month, '%Y-%m') AS month,
    a.product_type,
    b.dpd_bucket,
    COUNT(DISTINCT b.account_id) AS account_count,
    ROUND(SUM(b.statement_balance_cad), 2) AS total_balance_cad,
    ROUND(AVG(b.utilization_rate) * 100, 1) AS avg_utilization_pct,
    COUNT(CASE WHEN b.made_no_payment THEN 1 END) AS no_payment_count,
    COUNT(CASE WHEN b.paid_in_full THEN 1 END) AS paid_full_count,
    ROUND(SUM(CASE WHEN b.dpd_bucket = 'charge_off'
              THEN b.statement_balance_cad * 0.85 ELSE 0 END), 2) AS estimated_loss_cad
FROM stg_monthly_balances b
INNER JOIN stg_accounts a ON b.account_id = a.account_id
WHERE b.snapshot_month >= '2024-01-01'
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3
""").fetchdf()

#  delinquency trend over time 
delinq_trend = con.execute("""
SELECT
    strftime(b.snapshot_month, '%Y-%m') AS month,
    COUNT(DISTINCT CASE WHEN b.dpd_bucket = 'current' THEN b.account_id END) AS current_count,
    COUNT(DISTINCT CASE WHEN b.dpd_bucket = 'dpd_1_30' THEN b.account_id END) AS dpd_30_count,
    COUNT(DISTINCT CASE WHEN b.dpd_bucket = 'dpd_31_60' THEN b.account_id END) AS dpd_60_count,
    COUNT(DISTINCT CASE WHEN b.dpd_bucket = 'dpd_61_90' THEN b.account_id END) AS dpd_90_count,
    COUNT(DISTINCT CASE WHEN b.dpd_bucket IN ('dpd_91_180','charge_off') THEN b.account_id END) AS serious_delinq_count,
    COUNT(DISTINCT b.account_id) AS total_accounts,
    ROUND(COUNT(DISTINCT CASE WHEN b.dpd_bucket != 'current' THEN b.account_id END) * 100.0 /
          NULLIF(COUNT(DISTINCT b.account_id), 0), 2) AS delinquency_rate_pct
FROM stg_monthly_balances b
WHERE b.snapshot_month >= '2023-01-01'
GROUP BY 1
ORDER BY 1
""").fetchdf()

#  summary KPIs 
kpis = con.execute("""
SELECT
    COUNT(DISTINCT a.account_id) AS total_accounts,
    COUNT(DISTINCT a.borrower_id) AS total_borrowers,
    ROUND(SUM(b.statement_balance_cad), 2) AS total_portfolio_balance,
    ROUND(AVG(b.utilization_rate) * 100, 1) AS avg_utilization_pct,
    ROUND(COUNT(CASE WHEN a.is_delinquent THEN 1 END) * 100.0 /
          NULLIF(COUNT(*), 0), 2) AS delinquency_rate_pct,
    ROUND(COUNT(CASE WHEN a.is_charged_off THEN 1 END) * 100.0 /
          NULLIF(COUNT(*), 0), 2) AS charge_off_rate_pct,
    COUNT(CASE WHEN a.account_status = 'current' THEN 1 END) AS current_accounts,
    COUNT(CASE WHEN a.account_status LIKE 'delinquent%' THEN 1 END) AS delinquent_accounts,
    COUNT(CASE WHEN a.account_status = 'charged_off' THEN 1 END) AS charged_off_accounts
FROM stg_accounts a
LEFT JOIN (
    SELECT account_id, AVG(utilization_rate) AS utilization_rate,
           AVG(statement_balance_cad) AS statement_balance_cad
    FROM stg_monthly_balances
    GROUP BY account_id
) b ON a.account_id = b.account_id
""").fetchdf()

#  NSF trend 
nsf_trend = con.execute("""
SELECT
    strftime(payment_month, '%Y-%m') AS month,
    COUNT(*) AS total_payments,
    SUM(CASE WHEN is_nsf_return THEN 1 ELSE 0 END) AS nsf_count,
    ROUND(SUM(CASE WHEN is_nsf_return THEN 1 ELSE 0 END) * 100.0 /
          NULLIF(COUNT(*), 0), 3) AS nsf_rate_pct
FROM stg_payments
WHERE payment_month >= '2023-01-01'
GROUP BY 1
ORDER BY 1
""").fetchdf()

#  province breakdown 
province = con.execute("""
SELECT
    b.province_code,
    COUNT(DISTINCT a.account_id) AS account_count,
    ROUND(COUNT(CASE WHEN a.is_delinquent THEN 1 END) * 100.0 /
          NULLIF(COUNT(*), 0), 2) AS delinquency_rate_pct
FROM stg_accounts a
INNER JOIN stg_borrowers b ON a.borrower_id = b.borrower_id
GROUP BY 1
ORDER BY 2 DESC
""").fetchdf()

#  export 
output = {
    "kpis": kpis.to_dict(orient="records")[0],
    "delinquency_trend": delinq_trend.to_dict(orient="records"),
    "portfolio_summary": portfolio.to_dict(orient="records"),
    "nsf_trend": nsf_trend.to_dict(orient="records"),
    "province_breakdown": province.to_dict(orient="records"),
}

with open("dashboard/data.json", "w") as f:
    json.dump(output, f, indent=2, default=str)

print("dashboard/data.json written")
print(f"  KPIs: {kpis.to_dict(orient='records')[0]}")
