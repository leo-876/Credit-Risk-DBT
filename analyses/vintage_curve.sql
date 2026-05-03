/*
  Vintage curve: cumulative charge-off rate by months-on-book (MOB),
  grouped by the quarter the account was opened.

  Used to assess underwriting quality over time and detect portfolio
  deterioration early. Run via: dbt compile --select analyses/vintage_curve
*/

with base as (
    select
        account_id,
        opened_at,
        date_trunc('quarter', opened_at)                  as vintage_quarter,
        snapshot_month,
        datediff('month', opened_at, snapshot_month)      as mob,
        dpd_bucket,
        statement_balance_cad,
        estimated_loss_exposure_cad
    from {{ ref('mart_credit_reporting_monthly') }}
),

cumulative as (
    select
        vintage_quarter,
        mob,
        count(distinct account_id)                        as accounts_in_cohort,
        sum(case when dpd_bucket = 'charge_off' then 1 else 0 end)
                                                          as charged_off_count,
        sum(case when dpd_bucket = 'charge_off'
                 then estimated_loss_exposure_cad else 0 end)
                                                          as cumulative_loss_cad,
        sum(statement_balance_cad)                        as cohort_balance_cad,

        -- Cumulative charge-off rate (by balance)
        {{ safe_divide(
            "sum(case when dpd_bucket = 'charge_off' then estimated_loss_exposure_cad else 0 end)",
            "sum(statement_balance_cad)"
        ) }}                                              as cumulative_co_rate

    from base
    where mob between 0 and 24    -- cap at 24-month vintage window
    group by 1, 2
)

select *
from cumulative
order by vintage_quarter, mob
