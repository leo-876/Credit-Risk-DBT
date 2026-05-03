/*
  Custom singular test: payment_shortfall_cad should never be negative.
  A negative shortfall would indicate a data transformation bug where
  a borrower was credited for more than their statement balance.

  Returns rows that fail the assertion (dbt convention: >0 rows = test failure).
*/

select
    snapshot_id,
    account_id,
    snapshot_month,
    payment_shortfall_cad
from {{ ref('mart_credit_reporting_monthly') }}
where payment_shortfall_cad < 0
