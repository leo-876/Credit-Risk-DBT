/*
  Accounts flagged as charge_off dpd_bucket must have a positive
  estimated_loss_exposure_cad. Zero exposure on a charged-off account
  would indicate a modelling error in the mart.
*/

select
    snapshot_id,
    account_id,
    snapshot_month,
    dpd_bucket,
    estimated_loss_exposure_cad
from {{ ref('mart_credit_reporting_monthly') }}
where dpd_bucket = 'charge_off'
  and estimated_loss_exposure_cad <= 0
